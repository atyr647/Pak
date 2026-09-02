# tcl/mips_codegen.tcl — Pak → MIPS assembly backend, Tcl port of
# pak/mips/ (incremental, UNOPTIMIZED).
#
# The MIPS backend is the largest, most complex stage (register allocation,
# o32 ABI, frame layout, an instruction-scheduling optimizer). This port is
# incremental and targets the *unoptimized* output (the optimizer is a separate
# concern): the parity oracle calls MipsCodegen(optimize=False) directly, just
# as the other dump oracles call the Python API. Any construct not yet lowered
# raises MIPSUNPORTED, so a file is reported UNPORTED rather than producing
# wrong assembly (mirroring the parser/codegen port methodology).
#
# This first increment ports the Emitter, the linear-scan RegAlloc (temp pool
# order matters for byte parity), the string LiteralPool, and the orchestrator
# slice for the simplest path: entry/fn prologue+epilogue, module-API calls with
# argument marshalling, and string/int literals.

set _mcghere [file dirname [file normalize [info script]]]
source [file join $_mcghere ast.tcl]
source [file join $_mcghere mips_tables.tcl]

namespace eval pak {}
if {[info exists ::pak::_mips_codegen_loaded]} { return }
set ::pak::_mips_codegen_loaded 1

proc pak::mips_unported {what} { return -code error "MIPSUNPORTED\t$what" }

# ── register name constants (o32) ──────────────────────────────────────────────
namespace eval pak::reg {
    variable ZERO {$zero}  AT {$at}  V0 {$v0}  V1 {$v1}
    variable A0 {$a0}  A1 {$a1}  A2 {$a2}  A3 {$a3}
    variable SP {$sp}  FP {$fp}  RA {$ra}
}
set ::pak::CALLER_SAVED_GPRS {{$t0} {$t1} {$t2} {$t3} {$t4} {$t5} {$t6} {$t7} {$t8} {$t9}}
set ::pak::CALLEE_SAVED_GPRS {{$s0} {$s1} {$s2} {$s3} {$s4} {$s5} {$s6} {$s7}}
set ::pak::ARG_GPRS {{$a0} {$a1} {$a2} {$a3}}
# Stack area where live caller-saved temps are parked across a call; one slot
# per register in CALLER_SAVED_GPRS. See MipsCodegen's frame-layout comment.
set ::pak::CALL_SAVE_BASE 96

# ── Emitter — accumulates assembly lines and their binary records ───────────────
oo::class create pak::Emitter {
    variable buf indent recs
    constructor {} { set buf {}; set indent "    "; set recs {} }
    method getvalue {} { return "[join $buf \n]\n" }
    method buf {} { return $buf }
    method setbuf {b} { set buf $b }
    method getrecords {} { return $recs }
    method setrecords {r} { set recs $r }
    method len {} { return [llength $buf] }
    method raw {line} { lappend buf $line }
    method instr {args} {
        lappend buf "$indent[join $args { }]"
        set cleaned [lindex $args 0]
        foreach tok [lrange $args 1 end] { lappend cleaned [string trimright $tok ,] }
        lappend recs [list i {*}$cleaned]
    }
    method blank {} { lappend buf "" }
    method comment {t} { lappend buf "$indent# $t" }
    # A splice point patched later (e.g. prologue callee-saves). Emits a comment
    # line in the text buffer AND a structured sentinel in the record stream so
    # patch_prologue can rewrite both consistently.
    method placeholder {tag} { my raw "    # $tag"; lappend recs [list placeholder $tag] }
    method label {name} { lappend buf "${name}:"; lappend recs [list label $name] }
    method section_text {}   { my raw "\t.section .text";   lappend recs [list d section .text] }
    method section_data {}   { my raw "\t.section .data";   lappend recs [list d section .data] }
    method section_rodata {} { my raw "\t.section .rodata"; lappend recs [list d section .rodata] }
    method section_bss {}    { my raw "\t.section .bss";    lappend recs [list d section .bss] }
    method globl {s}     { my raw "\t.globl $s";          lappend recs [list d globl $s] }
    method type_func {s} { my raw "\t.type $s, @function"; lappend recs [list d type $s @function] }
    method size_sym {s e} { my raw "\t.size $s, $e";       lappend recs [list d size $s $e] }
    method align {n}     { my raw "\t.align $n";           lappend recs [list d align $n] }
    method word {v}      { my raw "\t.word $v";            lappend recs [list d word $v] }
    method half {v}      { my raw "\t.half $v";            lappend recs [list d half $v] }
    method byte {v}      { my raw "\t.byte $v";            lappend recs [list d byte $v] }
    method space {n}     { my raw "\t.space $n";           lappend recs [list d space $n] }
    method extern {s}    { my raw "\t.extern $s";          lappend recs [list d extern $s] }
    method asciiz {s} {
        set e [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $s]
        my raw "\t.asciiz \"$e\""
        lappend recs [list d asciiz $s]
    }
    method nop {}          { my instr "nop" }
    method move {dst src}  { my instr "move" "$dst," $src }
    method li {dst imm}    { my instr "li" "$dst," $imm }
    method la {dst lbl}    { my instr "la" "$dst," $lbl }
    method addiu {dst s1 imm} { my instr "addiu" "$dst," "$s1," $imm }
    method lw {dst off base}  { my instr "lw" "$dst," "${off}($base)" }
    method sw {src off base}  { my instr "sw" "$src," "${off}($base)" }
    method j {lbl}    { my instr "j" $lbl }
    method jal {lbl}  { my instr "jal" $lbl }
    method jr {reg}   { my instr "jr" $reg }
    method jalr {reg {link {$ra}}} { my instr "jalr" "$link," $reg }
    # arithmetic / logic
    method addu {d s1 s2} { my instr "addu" "$d," "$s1," $s2 }
    method subu {d s1 s2} { my instr "subu" "$d," "$s1," $s2 }
    method mul {d s1 s2}  { my instr "mul" "$d," "$s1," $s2 }
    method mult {s1 s2}   { my instr "mult" "$s1," $s2 }
    method div {s1 s2}    { my instr "div" "$s1," $s2 }
    method mflo {d}       { my instr "mflo" $d }
    method mfhi {d}       { my instr "mfhi" $d }
    method and_ {d s1 s2} { my instr "and" "$d," "$s1," $s2 }
    method or_ {d s1 s2}  { my instr "or" "$d," "$s1," $s2 }
    method xor {d s1 s2}  { my instr "xor" "$d," "$s1," $s2 }
    method nor {d s1 s2}  { my instr "nor" "$d," "$s1," $s2 }
    method not_ {d s}     { my instr "nor" "$d," "$s," {$zero} }
    method sllv {d s sh}  { my instr "sllv" "$d," "$s," $sh }
    method srav {d s sh}  { my instr "srav" "$d," "$s," $sh }
    method sll {d s sh}   { my instr "sll" "$d," "$s," $sh }
    method srl {d s sh}   { my instr "srl" "$d," "$s," $sh }
    method sra {d s sh}   { my instr "sra" "$d," "$s," $sh }
    method andi {d s imm} { my instr "andi" "$d," "$s," $imm }
    method ori {d s imm}  { my instr "ori" "$d," "$s," $imm }
    # comparison (pseudo)
    method slt {d s1 s2}  { my instr "slt" "$d," "$s1," $s2 }
    method sle {d s1 s2}  { my instr "sle" "$d," "$s1," $s2 }
    method sgt {d s1 s2}  { my instr "sgt" "$d," "$s1," $s2 }
    method sge {d s1 s2}  { my instr "sge" "$d," "$s1," $s2 }
    method seq {d s1 s2}  { my instr "seq" "$d," "$s1," $s2 }
    method sne {d s1 s2}  { my instr "sne" "$d," "$s1," $s2 }
    method sltu {d s1 s2} { my instr "sltu" "$d," "$s1," $s2 }
    method sltiu {d s imm} { my instr "sltiu" "$d," "$s," $imm }
    # branches
    method beqz {r lbl}   { my instr "beqz" "$r," $lbl }
    method bnez {r lbl}   { my instr "bnez" "$r," $lbl }
    method bge {s1 s2 lbl} { my instr "bge" "$s1," "$s2," $lbl }
    method bne {s1 s2 lbl} { my instr "bne" "$s1," "$s2," $lbl }
    # typed loads / stores
    method lh {d off base}  { my instr "lh" "$d," "${off}($base)" }
    method lhu {d off base} { my instr "lhu" "$d," "${off}($base)" }
    method lb {d off base}  { my instr "lb" "$d," "${off}($base)" }
    method lbu {d off base} { my instr "lbu" "$d," "${off}($base)" }
    method sh {s off base}  { my instr "sh" "$s," "${off}($base)" }
    method sb {s off base}  { my instr "sb" "$s," "${off}($base)" }
    method lwc1 {d off base} { my instr "lwc1" "$d," "${off}($base)" }
    method swc1 {s off base} { my instr "swc1" "$s," "${off}($base)" }
    method ldc1 {d off base} { my instr "ldc1" "$d," "${off}($base)" }
    method sdc1 {s off base} { my instr "sdc1" "$s," "${off}($base)" }
    # FPU moves / conversions / arithmetic (single & double)
    method mtc1 {gpr fpr} { my instr "mtc1" "$gpr," $fpr }
    method mfc1 {gpr fpr} { my instr "mfc1" "$gpr," $fpr }
    method cvt_s_w {fd fs} { my instr "cvt.s.w" "$fd," $fs }
    method cvt_w_s {fd fs} { my instr "cvt.w.s" "$fd," $fs }
    method cvt_d_w {fd fs} { my instr "cvt.d.w" "$fd," $fs }
    method cvt_w_d {fd fs} { my instr "cvt.w.d" "$fd," $fs }
    method add_s {fd fs ft} { my instr "add.s" "$fd," "$fs," $ft }
    method sub_s {fd fs ft} { my instr "sub.s" "$fd," "$fs," $ft }
    method mul_s {fd fs ft} { my instr "mul.s" "$fd," "$fs," $ft }
    method div_s {fd fs ft} { my instr "div.s" "$fd," "$fs," $ft }
    method neg_s {fd fs}    { my instr "neg.s" "$fd," $fs }
    method mov_s {fd fs}    { my instr "mov.s" "$fd," $fs }
    method abs_s {fd fs}    { my instr "abs.s" "$fd," $fs }
    method c_eq_s {fs ft}   { my instr "c.eq.s" "$fs," $ft }
    method c_lt_s {fs ft}   { my instr "c.lt.s" "$fs," $ft }
    method c_le_s {fs ft}   { my instr "c.le.s" "$fs," $ft }
    method bc1t   {label}   { my instr "bc1t" $label }
    method bc1f   {label}   { my instr "bc1f" $label }
    method sync {} { my instr "sync" }
    method verbatim {asm_text} {
        foreach line [split $asm_text "\n"] {
            lappend buf "$indent$line"
            lappend recs [list verbatim $line]
        }
    }
}

# ── Linear-scan register allocator with stack spilling ────────────────────────
# Temp pool is consumed from the END (pop) and returned by append, so the first
# borrowed temp is $t9 — this ordering is load-bearing for byte parity.
#
# Spilling design: when all 18 GPRs are in use, the OLDEST allocated register
# (alloc_order[0]) is saved to a pre-reserved stack slot and returned to the
# caller as if it were a fresh register. When the borrower calls free_temp on
# that register, the original value is restored from the slot and the reg
# goes back to alloc_order (for the original owner's eventual use). This
# works correctly for the LIFO allocation pattern used by emit_expr: deeper
# recursion always frees borrowed regs before the outer level uses them.
#
# 8 spill slots (32 bytes) are pre-reserved in each function's stack frame
# at offsets spill_base..spill_base+28. This supports up to 26 simultaneous
# live temporaries (18 regs + 8 spill slots) — sufficient for any real code.
oo::class create pak::RegAlloc {
    variable free_temps free_saved used_saved promoted_saved
    variable alloc_order spill_locs free_spill_slots host

    constructor {host_obj spill_base} {
        set free_temps $::pak::CALLER_SAVED_GPRS
        set free_saved $::pak::CALLEE_SAVED_GPRS
        set used_saved {}
        set promoted_saved {}
        set alloc_order {}
        set spill_locs [dict create]
        set host $host_obj
        # Pre-reserve 8 spill slots in the function's stack frame.
        set free_spill_slots {}
        for {set i 0} {$i < 8} {incr i} {
            lappend free_spill_slots [expr {$spill_base + $i * 4}]
        }
    }

    method alloc_temp {} {
        if {[llength $free_temps] > 0} {
            set r [lindex $free_temps end]
            set free_temps [lrange $free_temps 0 end-1]
            lappend alloc_order $r
            return $r
        }
        if {[llength $free_saved] > 0} {
            set r [lindex $free_saved end]
            set free_saved [lrange $free_saved 0 end-1]
            if {$r ni $used_saved} { lappend used_saved $r }
            if {$r ni $promoted_saved} { lappend promoted_saved $r }
            lappend alloc_order $r
            return $r
        }
        # All 18 GPRs in use — spill the oldest allocated register.
        if {[llength $alloc_order] > 0 && [llength $free_spill_slots] > 0} {
            set victim [lindex $alloc_order 0]
            set slot   [lindex $free_spill_slots 0]
            set free_spill_slots [lrange $free_spill_slots 1 end]
            dict set spill_locs $victim $slot
            # Remove victim from front of alloc_order (original owner's slot)
            set alloc_order [lrange $alloc_order 1 end]
            # Emit the save — borrower will overwrite victim's contents.
            $host emit_spill_store $victim $slot
            # Borrower "allocates" victim — add to end of alloc_order.
            lappend alloc_order $victim
            return $victim
        }
        return -code error "GPR temporary pool exhausted (18 regs + 8 spill slots all in use)"
    }

    method free_temp {r} {
        # Check if this free is a spill release (borrower is done with a stolen reg).
        if {[dict exists $spill_locs $r]} {
            set slot [dict get $spill_locs $r]
            dict unset spill_locs $r
            # Restore original value from spill slot.
            $host emit_spill_load $r $slot
            lappend free_spill_slots $slot
            # Remove borrower's entry from alloc_order.
            set idx [lsearch -exact $alloc_order $r]
            if {$idx >= 0} { set alloc_order [lreplace $alloc_order $idx $idx] }
            # Re-insert at front — original owner is "oldest" again.
            set alloc_order [linsert $alloc_order 0 $r]
            return
        }
        # Normal free: remove from alloc_order, return to proper pool.
        set idx [lsearch -exact $alloc_order $r]
        if {$idx >= 0} { set alloc_order [lreplace $alloc_order $idx $idx] }
        set i [lsearch -exact $promoted_saved $r]
        if {$i >= 0} {
            set promoted_saved [lreplace $promoted_saved $i $i]
            if {$r ni $free_saved} { lappend free_saved $r }
        } else {
            if {$r ni $free_temps} { lappend free_temps $r }
        }
    }

    method alloc_order {} { return $alloc_order }

    method used_callee_gprs {} {
        return [lsort -command pak::gpr_cmp $used_saved]
    }
    method used_callee_fprs {} { return {} }
    method spill_count {} { return [expr {8 - [llength $free_spill_slots]}] }
}
set ::pak::GPR_NUMBER [dict create {$s0} 16 {$s1} 17 {$s2} 18 {$s3} 19 \
    {$s4} 20 {$s5} 21 {$s6} 22 {$s7} 23]
proc pak::gpr_cmp {a b} {
    expr {[dict get $::pak::GPR_NUMBER $a] - [dict get $::pak::GPR_NUMBER $b]}
}

# ── Float bit-pattern conversion (IEEE 754 big-endian, matching Python struct.pack) ─
proc pak::float_to_bits {f} {
    binary scan [binary format R $f] I bits
    return [expr {$bits & 0xFFFFFFFF}]
}

# ── Fixed-point fractional bits for primitive type names ─────────────────────
proc pak::frac_bits_for {n} {
    switch -- $n {
        fix16.16 { return 16 }
        fix10.5  { return 5 }
        fix1.15  { return 15 }
        default  { return 0 }
    }
}

# ── Literal pool: interned strings + float constants + static globals ─────────────
oo::class create pak::LiteralPool {
    variable strings floats counter str_order float_order data_syms
    constructor {} {
        set strings [dict create]
        set floats  [dict create]
        set counter 0
        set str_order {}
        set float_order {}
        set data_syms {}
    }
    method intern_string {value} {
        if {![dict exists $strings $value]} {
            dict set strings $value ".Lstr$counter"
            lappend str_order $value
            incr counter
        }
        return [dict get $strings $value]
    }
    method intern_float {value} {
        if {![dict exists $floats $value]} {
            dict set floats $value ".Lf32$counter"
            lappend float_order $value
            incr counter
        }
        return [dict get $floats $value]
    }
    # init_value "" means uninitialized (.bss); otherwise an integer for .data.
    method add_static {name size align init_value} {
        lappend data_syms [list $name $size $align $init_value]
    }
    method has_content {} {
        return [expr {[dict size $strings] > 0 || [dict size $floats] > 0}]
    }
    method emit_rodata {em} {
        if {![my has_content]} return
        $em blank
        $em section_rodata
        foreach value $str_order {
            $em align 0
            $em label [dict get $strings $value]
            $em asciiz $value
        }
        foreach value $float_order {
            $em align 2
            $em label [dict get $floats $value]
            $em word [pak::float_to_bits $value]
        }
    }
    method emit_data {em} {
        if {[llength $data_syms] == 0} return
        set inited {}; set uninited {}
        foreach s $data_syms {
            if {[lindex $s 3] ne ""} { lappend inited $s } else { lappend uninited $s }
        }
        if {[llength $inited] > 0} {
            $em blank
            $em section_data
            foreach s $inited {
                lassign $s name size align iv
                $em align [pak::log2_align $align]
                $em globl $name
                $em label $name
                pak::emit_init $em $size $iv
            }
        }
        if {[llength $uninited] > 0} {
            $em blank
            $em section_bss
            foreach s $uninited {
                lassign $s name size align iv
                $em align [pak::log2_align $align]
                $em globl $name
                $em label $name
                $em space $size
            }
        }
    }
}
# log2 of alignment, matching (align-1).bit_length() for power-of-two aligns.
proc pak::log2_align {align} {
    set v [expr {$align - 1}]
    set n 0
    while {$v > 0} { incr n; set v [expr {$v >> 1}] }
    return $n
}
proc pak::emit_init {em size value} {
    if {$size == 8} {
        $em word [expr {($value >> 32) & 0xFFFFFFFF}]
        $em word [expr {$value & 0xFFFFFFFF}]
    } elseif {$size == 4} {
        $em word [expr {$value & 0xFFFFFFFF}]
    } elseif {$size == 2} {
        $em half [expr {$value & 0xFFFF}]
    } elseif {$size == 1} {
        $em byte [expr {$value & 0xFF}]
    } else {
        set off 0
        while {$off + 4 <= $size} { $em word 0; incr off 4 }
        while {$off < $size} { $em byte 0; incr off }
    }
}

# ── type layout: primitives, pointers and arrays ───────────────────────────────
# Global proc handles only primitives/pointers/arrays — user-defined types are
# handled by the MipsCodegen method mips_layout (which checks tenv first).
proc pak::mips_layout {type_tv} {
    if {[pak::isnil $type_tv]} { return [dict create size 0 align 1 is_float 0 is_signed 1 is_ptr 0 fields {}] }
    switch -- [pak::kindof $type_tv] {
        TypeName {
            set n [pak::fval $type_tv name]
            if {[dict exists $::pak::MIPS_PRIM $n]} {
                lassign [dict get $::pak::MIPS_PRIM $n] sz al fl sg
                return [dict create size $sz align $al is_float $fl is_signed $sg is_ptr 0 fields {}]
            }
            pak::mips_unported "layout:$n"
        }
        TypePointer { return [dict create size 4 align 4 is_float 0 is_signed 0 is_ptr 1 fields {}] }
        TypeArray {
            set inner [pak::mips_layout [pak::nfield $type_tv inner]]
            set sz [pak::nfield $type_tv size]
            if {[pak::kindof $sz] eq "IntLit"} { set n [pak::fval $sz value] } else { set n 0 }
            return [dict create size [expr {[dict get $inner size] * $n}] align [dict get $inner align] is_float 0 is_signed 1 is_ptr 0 fields {}]
        }
        TypeOption {
            set inner [pak::mips_layout [pak::nfield $type_tv inner]]
            if {[dict get $inner is_ptr]} { return [dict create size 4 align 4 is_float 0 is_signed 0 is_ptr 1 fields {}] }
            # Non-pointer Option(T): 1-byte tag (_tag=0 for none, 1 for some) + padding + payload
            set inner_size  [dict get $inner size]
            set inner_align [expr {max([dict get $inner align], 1)}]
            set payload_off [expr {(1 + $inner_align - 1) & ~($inner_align - 1)}]
            set total_size  [expr {$payload_off + $inner_size}]
            set total_align [expr {max($inner_align, 4)}]
            set total_size  [expr {($total_size + $total_align - 1) & ~($total_align - 1)}]
            set fields [dict create \
                _tag [dict create name _tag offset 0           size 1           align 1           type_node ""] \
                _val [dict create name _val offset $payload_off size $inner_size align $inner_align type_node ""]]
            return [dict create size $total_size align $total_align is_float 0 is_signed 1 is_ptr 0 \
                fields $fields field_order {_tag _val}]
        }
        default { pak::mips_unported "layout:[pak::kindof $type_tv]" }
    }
}
proc pak::mips_layout_name {n} { return [pak::mips_layout [pak::N TypeName name $n]] }

# truncate / extend between integer sizes (port of builtins.emit_int_cast).
# Masks are emitted in decimal to match Python's str(0xFFFF) = 65535.
proc pak::emit_int_cast {em dst src to_size to_signed} {
    if {$to_size >= 4} {
        if {$dst ne $src} { $em move $dst $src }
        return
    }
    if {$to_size == 2} {
        if {$to_signed} { $em sll $dst $src 16; $em sra $dst $dst 16 } else { $em andi $dst $src 65535 }
        return
    }
    if {$to_size == 1} {
        if {$to_signed} { $em sll $dst $src 24; $em sra $dst $dst 24 } else { $em andi $dst $src 255 }
    }
}

# annotation strings of a node, or {} if it has no annotations field.
proc pak::mips_annlist {node} {
    set k [pak::kindof $node]
    if {$k eq "" || [lsearch -exact [dict get $::pak::SCHEMA $k] annotations] < 0} { return {} }
    set out {}
    foreach a [pak::items [pak::nfield $node annotations]] { lappend out [pak::sval $a] }
    return $out
}

# ── orchestrator ────────────────────────────────────────────────────────────
oo::class create pak::MipsCodegen {
    variable em pool ra ret_label scopes defers next_local loop_header loop_exit loop_defer_depth \
             loop_result \
             globals consts label_n fmtstr_counter \
             tenv_layouts tenv_enum_values tenv_variant_decls \
             generic_fns generic_structs mono_emitted type_nodes

    constructor {} {
        set em [pak::Emitter new]
        set pool [pak::LiteralPool new]
        set ra ""
        set ret_label ""
        set scopes {}
        set defers {}
        set next_local 16
        set loop_header {}
        set loop_exit {}
        set loop_defer_depth {}
        set loop_result {}
        set globals [dict create]
        set consts [dict create]
        set label_n 0
        set fmtstr_counter 0
        set tenv_layouts [dict create]
        set tenv_enum_values [dict create]
        set tenv_variant_decls [dict create]
        set generic_fns [dict create]
        set generic_structs [dict create]
        set mono_emitted [dict create]
        set type_nodes [dict create]
    }
    destructor {
        $em destroy
        $pool destroy
        if {$ra ne ""} { catch {$ra destroy} }
    }

    # ── type environment: user-defined and well-known external types ─────────
    # Well-known external types (tiny3d / libdragon), pre-registered so user
    # structs containing e.g. Vec3 fields resolve. Mirrors _EXTERNAL_TYPES.
    method register_external_types {} {
        foreach {name sz al fl} {
            Vec3        12  4 1
            Mat4        64  4 1
            Quat        16  4 1
            Color        4  4 0
            T3DMat4FP  128 16 0
            T3DViewport 128 16 0
        } {
            if {![dict exists $tenv_layouts $name]} {
                dict set tenv_layouts $name [dict create size $sz align $al \
                    is_float $fl is_signed 1 is_ptr 0 fields {} frac_bits 0]
            }
        }
        # ButtonState: 14 bool fields at consecutive byte offsets 0-13, size=14, align=1
        if {![dict exists $tenv_layouts ButtonState]} {
            set bs_fields [dict create]
            set bs_off 0
            foreach fname {a b z start up down left right l r c_up c_down c_left c_right} {
                dict set bs_fields $fname [dict create name $fname offset $bs_off \
                    size 1 align 1 type_node ""]
                incr bs_off
            }
            dict set tenv_layouts ButtonState [dict create size 14 align 1 \
                is_float 0 is_signed 0 is_ptr 0 fields $bs_fields \
                field_order {a b z start up down left right l r c_up c_down c_left c_right}]
        }
        # ControllerState: held/pressed/released (*ButtonState pointers) + stick_x/y (i32)
        if {![dict exists $tenv_layouts ControllerState]} {
            set cs_fields [dict create]
            set bs_ptr [pak::N TypePointer inner [pak::N TypeName name ButtonState] nullable 0 mutable 0]
            set i32_tn [pak::N TypeName name i32]
            dict set cs_fields held     [dict create name held     offset 0  size 4 align 4 type_node $bs_ptr]
            dict set cs_fields pressed  [dict create name pressed  offset 4  size 4 align 4 type_node $bs_ptr]
            dict set cs_fields released [dict create name released offset 8  size 4 align 4 type_node $bs_ptr]
            dict set cs_fields stick_x  [dict create name stick_x  offset 12 size 4 align 4 type_node $i32_tn]
            dict set cs_fields stick_y  [dict create name stick_y  offset 16 size 4 align 4 type_node $i32_tn]
            dict set tenv_layouts ControllerState [dict create size 20 align 4 \
                is_float 0 is_signed 1 is_ptr 0 fields $cs_fields \
                field_order {held pressed released stick_x stick_y}]
        }
        # joypad_status_t is the libdragon spelling used in Pak source. On the
        # standalone path `controller.read` lowers to joypad_get_status, which
        # returns a *ControllerState, so the value is pointer-shaped (4 bytes)
        # while still exposing ControllerState's fields for `pad.held.a` etc.
        if {![dict exists $tenv_layouts joypad_status_t]} {
            set cs [dict get $tenv_layouts ControllerState]
            dict set tenv_layouts joypad_status_t [dict create size 4 align 4 \
                is_float 0 is_signed 0 is_ptr 1 frac_bits 0 \
                fields [dict get $cs fields] field_order [dict get $cs field_order]]
        }
    }

    method register_program {program} {
        my register_external_types
        set enums {}; set structs {}; set variants {}
        foreach decl [pak::items [pak::nfield $program decls]] {
            switch -- [pak::kindof $decl] {
                EnumDecl    { lappend enums    $decl }
                StructDecl  { lappend structs  $decl }
                VariantDecl { lappend variants $decl }
            }
        }
        foreach e $enums    { my register_enum    $e }
        foreach s $structs  { my register_struct  $s }
        foreach v $variants { my register_variant $v }
    }

    method register_enum {decl} {
        set base_type_node [pak::nfield $decl base_type]
        if {[pak::isnil $base_type_node]} {
            set base i32
        } elseif {[pak::kindof $base_type_node] eq "TypeName"} {
            set base [pak::fval $base_type_node name]
        } elseif {[lindex $base_type_node 0] eq "lit"} {
            set base [pak::sval $base_type_node]
        } else {
            set base i32
        }
        if {[dict exists $::pak::MIPS_PRIM $base]} {
            lassign [dict get $::pak::MIPS_PRIM $base] sz al fl sg
        } else {
            set sz 4; set al 4; set fl 0; set sg 1
        }
        set layout [dict create size $sz align $al is_float $fl is_signed $sg is_ptr 0 fields {}]
        dict set tenv_layouts [pak::fval $decl name] $layout

        set val 0
        set case_map [dict create]
        foreach v [pak::items [pak::nfield $decl variants]] {
            set explicit_v [pak::nfield $v value]
            if {![pak::isnil $explicit_v] && [pak::kindof $explicit_v] eq "IntLit"} {
                set val [pak::fval $explicit_v value]
            }
            dict set case_map [pak::fval $v name] $val
            incr val
        }
        dict set tenv_enum_values [pak::fval $decl name] $case_map
    }

    method register_struct {decl} {
        if {[llength [pak::items [pak::nfield $decl type_params]]] > 0} {
            dict set generic_structs [pak::fval $decl name] $decl
            return
        }
        set fields [dict create]
        set order {}
        set offset 0
        set max_align 1

        foreach sf [pak::items [pak::nfield $decl fields]] {
            set fl [my mips_layout [pak::nfield $sf type]]
            set a [dict get $fl align]
            if {$a > $max_align} { set max_align $a }
            set offset [expr {($offset + $a - 1) & ~($a - 1)}]
            set fi [dict create name [pak::fval $sf name] offset $offset \
                size [dict get $fl size] align $a type_node [pak::nfield $sf type]]
            dict set fields [pak::fval $sf name] $fi
            lappend order [pak::fval $sf name]
            incr offset [dict get $fl size]
        }

        foreach ann [pak::mips_annlist $decl] {
            if {[string match "aligned(*" $ann]} {
                set n [string range $ann [expr {[string first ( $ann]+1}] [expr {[string first ) $ann]-1}]]
                if {[string is integer -strict $n] && $n > $max_align} { set max_align $n }
            }
        }

        set total [expr {($offset + $max_align - 1) & ~($max_align - 1)}]
        if {$total == 0} { set total $max_align }

        set layout [dict create size $total align $max_align is_float 0 is_signed 1 is_ptr 0 \
            fields $fields field_order $order]
        dict set tenv_layouts [pak::fval $decl name] $layout
    }

    method register_variant {decl} {
        set max_payload_size 0
        set max_payload_align 1
        set n_cases [llength [pak::items [pak::nfield $decl cases]]]

        if {$n_cases <= 256} {
            set tag_size 1; set tag_align 1
        } elseif {$n_cases <= 65536} {
            set tag_size 2; set tag_align 2
        } else {
            set tag_size 4; set tag_align 4
        }

        foreach case [pak::items [pak::nfield $decl cases]] {
            set case_size 0; set case_align 1
            foreach sf [pak::items [pak::nfield $case fields]] {
                # sf is either: a Seq([Lit(name), type]) for named fields,
                # or a type node directly for positional fields
                set ftype [my variant_field_type $sf]
                set fl [my mips_layout $ftype]
                set fa [dict get $fl align]
                if {$fa > $case_align} { set case_align $fa }
                set case_size [expr {($case_size + $fa - 1) & ~($fa - 1)}]
                incr case_size [dict get $fl size]
            }
            if {$case_size > $max_payload_size} { set max_payload_size $case_size }
            if {$case_align > $max_payload_align} { set max_payload_align $case_align }
        }

        set payload_offset [expr {($tag_size + $max_payload_align - 1) & ~($max_payload_align - 1)}]
        set total_align [expr {max($tag_align, $max_payload_align)}]
        set total_size [expr {($payload_offset + $max_payload_size + $total_align - 1) & ~($total_align - 1)}]
        if {$total_size == 0} { set total_size $total_align }

        set layout [dict create size $total_size align $total_align is_float 0 is_signed 1 is_ptr 0 \
            fields {} tag_offset 0 tag_size $tag_size]
        dict set tenv_layouts [pak::fval $decl name] $layout
        dict set tenv_variant_decls [pak::fval $decl name] $decl
    }

    # ── method-level mips_layout (checks tenv first, then primitives) ──────────
    method mips_layout {type_tv} {
        if {[pak::isnil $type_tv]} {
            return [dict create size 0 align 1 is_float 0 is_signed 1 is_ptr 0 fields {} frac_bits 0]
        }
        switch -- [pak::kindof $type_tv] {
            TypeName {
                set n [pak::fval $type_tv name]
                if {[dict exists $tenv_layouts $n]} {
                    return [dict get $tenv_layouts $n]
                }
                if {[dict exists $::pak::MIPS_PRIM $n]} {
                    lassign [dict get $::pak::MIPS_PRIM $n] sz al fl sg
                    return [dict create size $sz align $al is_float $fl is_signed $sg is_ptr 0 \
                        fields {} frac_bits [pak::frac_bits_for $n]]
                }
                pak::mips_unported "layout:$n"
            }
            TypePointer {
                return [dict create size 4 align 4 is_float 0 is_signed 0 is_ptr 1 fields {} frac_bits 0]
            }
            TypeArray {
                set inner [my mips_layout [pak::nfield $type_tv inner]]
                set sz [pak::nfield $type_tv size]
                if {[pak::kindof $sz] eq "IntLit"} { set n [pak::fval $sz value] } else { set n 0 }
                return [dict create size [expr {[dict get $inner size] * $n}] \
                    align [dict get $inner align] is_float 0 is_signed 1 is_ptr 0 fields {} frac_bits 0]
            }
            TypeSlice {
                # Fat pointer: {ptr@0, len@4}
                set ptr_fi [dict create name ptr offset 0 size 4 align 4 type_node ""]
                set len_fi [dict create name len offset 4 size 4 align 4 type_node ""]
                return [dict create size 8 align 4 is_float 0 is_signed 1 is_ptr 0 \
                    fields [dict create ptr $ptr_fi len $len_fi] frac_bits 0]
            }
            TypeOption {
                set inner [my mips_layout [pak::nfield $type_tv inner]]
                if {[dict get $inner is_ptr]} {
                    return [dict create size 4 align 4 is_float 0 is_signed 0 is_ptr 1 fields {} frac_bits 0]
                }
                set ia [dict get $inner align]
                set pay_off [expr {(1 + $ia - 1) & ~($ia - 1)}]
                set total_align [expr {max(1, $ia)}]
                set total_size [expr {($pay_off + [dict get $inner size] + $total_align - 1) & ~($total_align - 1)}]
                set total_size [expr {max($total_size, $total_align)}]
                return [dict create size $total_size align $total_align is_float 0 is_signed 1 is_ptr 0 fields {} frac_bits 0]
            }
            TypeResult {
                set ok_l  [my mips_layout [pak::nfield $type_tv ok]]
                set err_l [my mips_layout [pak::nfield $type_tv err]]
                set payload_size  [expr {max([dict get $ok_l size], [dict get $err_l size])}]
                set payload_align [expr {max([dict get $ok_l align], [dict get $err_l align])}]
                set pay_off [expr {(1 + $payload_align - 1) & ~($payload_align - 1)}]
                set total_align [expr {max(1, $payload_align)}]
                set total_size [expr {($pay_off + $payload_size + $total_align - 1) & ~($total_align - 1)}]
                set total_size [expr {max($total_size, $total_align)}]
                set ok_fi  [dict create name is_ok  offset 0 size 1 align 1 type_node ""]
                set pay_fi [dict create name payload offset $pay_off size $payload_size align $payload_align type_node ""]
                return [dict create size $total_size align $total_align is_float 0 is_signed 1 is_ptr 0 \
                    fields [dict create is_ok $ok_fi payload $pay_fi] \
                    tag_offset 0 tag_size 1 frac_bits 0]
            }
            TypeGeneric {
                set gname [pak::fval $type_tv name]
                set gargs [pak::items [pak::nfield $type_tv args]]
                # Built-in containers
                if {$gname in {FixedList Pool}} {
                    set elem_layout [my mips_layout [lindex $gargs 0]]
                    set esz [dict get $elem_layout size]
                    set eal [dict get $elem_layout align]
                    set cap_arg [lindex $gargs 1]
                    set cap [expr {[pak::kindof $cap_arg] eq "IntLit" ? [pak::fval $cap_arg value] : 0}]
                    set data_sz [expr {$esz * $cap}]
                    set len_off [expr {($data_sz + 3) & ~3}]
                    set total [expr {$len_off + 4}]
                    set total_align [expr {max($eal, 4)}]
                    set total [expr {($total + $total_align - 1) & ~($total_align - 1)}]
                    set df [dict create name data offset 0 size $data_sz align $eal type_node [lindex $gargs 0]]
                    set lf [dict create name len  offset $len_off size 4 align 4 type_node ""]
                    return [dict create size $total align $total_align is_float 0 is_signed 1 is_ptr 0 \
                        fields [dict create data $df len $lf] field_order {data len} frac_bits 0 \
                        _container FixedList _elem_size $esz _cap $cap]
                }
                if {$gname eq "Vec"} {
                    return [dict create size 12 align 4 is_float 0 is_signed 1 is_ptr 0 fields {} frac_bits 0 _container Vec]
                }
                if {$gname eq "RingBuffer"} {
                    set elem_layout [my mips_layout [lindex $gargs 0]]
                    set esz [dict get $elem_layout size]
                    set eal [dict get $elem_layout align]
                    set cap_arg [lindex $gargs 1]
                    set cap [expr {[pak::kindof $cap_arg] eq "IntLit" ? [pak::fval $cap_arg value] : 0}]
                    set data_sz [expr {$esz * $cap}]
                    set ctrl_off [expr {($data_sz + 3) & ~3}]
                    set total [expr {$ctrl_off + 12}]
                    set total_align [expr {max($eal, 4)}]
                    set total [expr {($total + $total_align - 1) & ~($total_align - 1)}]
                    set df   [dict create name data offset 0         size $data_sz align $eal type_node ""]
                    set hf   [dict create name head offset $ctrl_off size 4 align 4 type_node ""]
                    set tf   [dict create name tail offset [expr {$ctrl_off+4}] size 4 align 4 type_node ""]
                    set lf   [dict create name len  offset [expr {$ctrl_off+8}] size 4 align 4 type_node ""]
                    return [dict create size $total align $total_align is_float 0 is_signed 1 is_ptr 0 \
                        fields [dict create data $df head $hf tail $tf len $lf] \
                        field_order {data head tail len} frac_bits 0 \
                        _container RingBuffer _elem_size $esz _cap $cap]
                }
                if {$gname eq "FixedMap"} {
                    set kl [my mips_layout [lindex $gargs 0]]
                    set vl [my mips_layout [lindex $gargs 1]]
                    set cap_arg [lindex $gargs 2]
                    set cap [expr {[pak::kindof $cap_arg] eq "IntLit" ? [pak::fval $cap_arg value] : 0}]
                    set ksz [dict get $kl size]; set kal [dict get $kl align]
                    set vsz [dict get $vl size]; set val_al [dict get $vl align]
                    set keys_sz [expr {$ksz * $cap}]
                    set pair_al [expr {max($kal,$val_al)}]
                    set vals_off [expr {($keys_sz + $pair_al - 1) & ~($pair_al - 1)}]
                    set vals_sz  [expr {$vsz * $cap}]
                    set occ_off  [expr {$vals_off + $vals_sz}]
                    set len_off  [expr {($occ_off + $cap + 3) & ~3}]
                    set total [expr {$len_off + 4}]
                    set tal [expr {max($kal, $val_al, 4)}]
                    set total [expr {($total + $tal - 1) & ~($tal - 1)}]
                    set kf [dict create name keys     offset 0        size $keys_sz align $kal  type_node ""]
                    set vf [dict create name values   offset $vals_off size $vals_sz align $val_al type_node ""]
                    set of [dict create name occupied offset $occ_off  size $cap    align 1      type_node ""]
                    set lf [dict create name len      offset $len_off  size 4       align 4      type_node ""]
                    return [dict create size $total align $tal is_float 0 is_signed 1 is_ptr 0 \
                        fields [dict create keys $kf values $vf occupied $of len $lf] \
                        field_order {keys values occupied len} frac_bits 0 \
                        _container FixedMap _key_size $ksz _val_size $vsz _cap $cap]
                }
                # User-defined generic struct
                if {[dict exists $generic_structs $gname]} {
                    set mangled [my monomorphize_struct $gname $gargs]
                    return [dict get $tenv_layouts $mangled]
                }
                return [my mips_layout_name $gname]
            }
            TypeVolatile {
                return [my mips_layout [pak::nfield $type_tv inner]]
            }
            TypeFn {
                # Function pointer is just a 32-bit pointer
                return [dict create size 4 align 4 is_float 0 is_signed 0 is_ptr 1 fields {} frac_bits 0]
            }
            default {
                # Fallback: treat as a 4-byte word (matches Python)
                return [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {} frac_bits 0]
            }
        }
    }

    method mips_layout_name {n} {
        if {[dict exists $tenv_layouts $n]} { return [dict get $tenv_layouts $n] }
        return [pak::mips_layout_name $n]
    }

    # ── variant / enum helpers ────────────────────────────────────────────────
    method resolve_enum_case_value {case_name} {
        dict for {_enum cases} $tenv_enum_values {
            if {[dict exists $cases $case_name]} { return [dict get $cases $case_name] }
        }
        return 0
    }

    method resolve_variant_name_for_case {case_name} {
        dict for {vname decl} $tenv_variant_decls {
            foreach case [pak::items [pak::nfield $decl cases]] {
                if {[pak::fval $case name] eq $case_name} { return $vname }
            }
        }
        return ""
    }

    method resolve_variant_tag {case_name} {
        dict for {_vname decl} $tenv_variant_decls {
            set i 0
            foreach case [pak::items [pak::nfield $decl cases]] {
                if {[pak::fval $case name] eq $case_name} { return $i }
                incr i
            }
        }
        return 0
    }

    # Helper: sf is either a Seq([Lit(name), type]) for named fields,
    # or a type node directly for positional fields. Returns the type node.
    method variant_field_type {sf} {
        if {[lindex $sf 0] eq "seq"} {
            set items [pak::items $sf]
            if {[llength $items] == 2 && [lindex [lindex $items 0] 0] eq "lit"} {
                return [lindex $items 1]
            }
        }
        return $sf
    }

    method variant_field_name {sf idx} {
        if {[lindex $sf 0] eq "seq"} {
            set items [pak::items $sf]
            if {[llength $items] == 2 && [lindex [lindex $items 0] 0] eq "lit"} {
                return [pak::sval [lindex $items 0]]
            }
        }
        return "_field$idx"
    }

    method variant_case_fields {vname case_name} {
        if {![dict exists $tenv_variant_decls $vname]} { return {} }
        set decl [dict get $tenv_variant_decls $vname]
        foreach case [pak::items [pak::nfield $decl cases]] {
            if {[pak::fval $case name] eq $case_name} {
                set fields {}
                set offset 0
                set idx 0
                foreach sf [pak::items [pak::nfield $case fields]] {
                    set ftype [my variant_field_type $sf]
                    set fname [my variant_field_name $sf $idx]
                    set fl [my mips_layout $ftype]
                    set fa [dict get $fl align]
                    set offset [expr {($offset + $fa - 1) & ~($fa - 1)}]
                    lappend fields [dict create name $fname \
                        offset $offset size [dict get $fl size] align $fa type_node $ftype]
                    incr offset [dict get $fl size]
                    incr idx
                }
                return $fields
            }
        }
        return {}
    }

    # ── struct field resolution ───────────────────────────────────────────────
    method resolve_field_info {expr} {
        set obj [pak::nfield $expr obj]
        set fname [pak::fval $expr field]
        # First check local variable's layout
        if {[pak::kindof $obj] eq "Ident"} {
            set local [my lookup_local [pak::fval $obj name]]
            if {$local ne ""} {
                set layout [lindex $local 1]
                if {[dict exists $layout fields]} {
                    set fields [dict get $layout fields]
                    if {[dict exists $fields $fname]} { return [dict get $fields $fname] }
                }
            }
        }
        # Fall back: search all registered struct layouts
        dict for {_name layout} $tenv_layouts {
            if {[dict exists $layout fields]} {
                set fields [dict get $layout fields]
                if {[dict exists $fields $fname]} { return [dict get $fields $fname] }
            }
        }
        return ""
    }

    # ── label / scope / locals (port of FnCtx) ─────────────────────────────────
    method fresh_label {prefix} { set n $label_n; incr label_n; return "${prefix}_${n}" }
    method push_scope {} {
        lappend scopes [dict create]
        lappend defers {}
    }
    method pop_scope {} {
        # Pop and return LIFO defer list for this scope
        set d [lindex $defers end]
        set defers [lrange $defers 0 end-1]
        set scopes [lrange $scopes 0 end-1]
        set result {}
        for {set i [expr {[llength $d]-1}]} {$i >= 0} {incr i -1} {
            lappend result [lindex $d $i]
        }
        return $result
    }
    method add_defer {body} {
        if {[llength $defers] > 0} {
            set last [lindex $defers end]
            lappend last $body
            lset defers end $last
        }
    }
    # Emit defers for all scopes at index >= base_depth (innermost first).
    # Used by break/continue to run defers declared inside the current loop.
    method emit_defers_from {base_depth} {
        for {set i [expr {[llength $defers]-1}]} {$i >= $base_depth} {incr i -1} {
            set scope_d [lindex $defers $i]
            for {set j [expr {[llength $scope_d]-1}]} {$j >= 0} {incr j -1} {
                my emit_stmt [lindex $scope_d $j]
            }
        }
    }
    method declare_local {name layout {type_node ""}} {
        set align [dict get $layout align]
        set next_local [expr {($next_local + $align - 1) & ~($align - 1)}]
        set off $next_local
        set next_local [expr {$next_local + [dict get $layout size]}]
        if {[llength $scopes] > 0} {
            set f [lindex $scopes end]; dict set f $name [list $off $layout]; lset scopes end $f
        }
        if {$type_node ne ""} { dict set type_nodes $name $type_node }
        return $off
    }
    method lookup_local {name} {
        for {set i [expr {[llength $scopes]-1}]} {$i >= 0} {incr i -1} {
            set f [lindex $scopes $i]
            if {[dict exists $f $name]} { return [dict get $f $name] }
        }
        return ""
    }
    method lookup_type_node {name} {
        if {[dict exists $type_nodes $name]} { return [dict get $type_nodes $name] }
        return ""
    }

    method generate {program} {
        my register_program $program
        $em raw "# Generated by PAK MIPS backend"
        $em raw "# .set mips3"
        $em raw "# .set noreorder"
        $em blank
        my emit_externs
        $em blank
        foreach decl [pak::items [pak::nfield $program decls]] { my emit_top_decl $decl }
        $pool emit_rodata $em
        $pool emit_data $em
        return [$em getvalue]
    }

    # Structured record stream for the in-process binary encoder. Must be called
    # after `generate`. The records mirror the (unoptimized) text output; the
    # peephole/scheduler passes run only on text, so the encoded binary is
    # correct but not delay-slot-optimized (see tcl/n64enc.tcl).
    method getrecords {} { return [$em getrecords] }

    method emit_externs {} {
        foreach sym $::pak::MIPS_EXTERNS { $em extern $sym }
    }

    method emit_top_decl {decl} {
        switch -- [pak::kindof $decl] {
            FnDecl {
                if {[llength [pak::items [pak::nfield $decl type_params]]] > 0} {
                    # Generic function: defer until a monomorphized call is seen.
                    dict set generic_fns [pak::fval $decl name] $decl
                } else {
                    my emit_fn [pak::fval $decl name] [pak::nfield $decl params] [pak::nfield $decl body]
                }
            }
            EntryBlock {
                my emit_fn main [pak::Seq {}] [pak::nfield $decl body]
            }
            StructDecl - EnumDecl - VariantDecl - UnionDecl - TraitDecl - UseDecl - ExternBlock - ModuleDecl - ExternConst {}
            ConstDecl   { my collect_const $decl }
            StaticDecl  { my emit_static $decl }
            ImplBlock - ImplTraitBlock {
                set type_name [pak::fval $decl type_name]
                foreach m [pak::items [pak::nfield $decl methods]] {
                    set mangled "${type_name}_[pak::fval $m name]"
                    my emit_fn $mangled [pak::nfield $m params] [pak::nfield $m body]
                }
            }
            AssetDecl   { $em extern [pak::fval $decl name] }
            CfgBlock    { my emit_top_decl [pak::nfield $decl decl] }
            default     { pak::mips_unported "decl:[pak::kindof $decl]" }
        }
    }

    method collect_const {decl} {
        set v [my eval_const_expr [pak::nfield $decl value]]
        if {$v ne ""} { dict set consts [pak::fval $decl name] $v }
    }

    method emit_static {decl} {
        set typ [pak::nfield $decl type]
        if {![pak::isnil $typ]} { set layout [my mips_layout $typ] } else { set layout [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}] }
        set init ""
        set v [pak::nfield $decl value]
        if {![pak::isnil $v]} { set init [my eval_const_expr $v] }
        set align [dict get $layout align]
        foreach ann [pak::mips_annlist $decl] {
            if {[string match "aligned(*" $ann]} {
                set n [string range $ann [expr {[string first ( $ann]+1}] [expr {[string first ) $ann]-1}]]
                if {[string is integer -strict $n] && $n > $align} { set align $n }
            }
        }
        $pool add_static [pak::fval $decl name] [dict get $layout size] $align $init
        dict set globals [pak::fval $decl name] [list 0 $layout]
    }

    method emit_fn {name params body} {
        if {[pak::isnil $body]} return
        $em blank
        $em section_text
        $em globl $name
        $em type_func $name
        $em label $name
        if {$ra ne ""} { catch {$ra destroy} }
        # Frame layout: $sp+0..15 = O32 home area; $sp+16..63 = outgoing stack args
        # (up to 12 extra args beyond the 4 register args); $sp+64..95 = 8 spill
        # slots; $sp+96..135 = 10 call-save slots, one per caller-saved temp;
        # $sp+136+ = local variables.  Keeping the spill and call-save areas
        # above the O32 outgoing-arg area prevents marshal_args from clobbering
        # either.
        set spill_base 64
        set ra [pak::RegAlloc new [self] $spill_base]
        set scopes {}
        set defers {}
        set loop_header {}
        set loop_exit {}
        set loop_defer_depth {}
        set loop_result {}
        set next_local [expr {$::pak::CALL_SAVE_BASE + 10 * 4}]
        my push_scope
        # Declare param stack slots (allocate offsets, no emission yet).
        # Stores happen AFTER the prologue so that $sp-relative offsets are
        # consistent between the stores and all later loads.
        set i 0
        set float_param_n 0
        set param_info {}
        foreach p [pak::items $params] {
            set p_layout [my mips_layout [pak::nfield $p type]]
            set off [my declare_local [pak::fval $p name] $p_layout [pak::nfield $p type]]
            lappend param_info [list $off $p_layout $float_param_n $i]
            if {[dict get $p_layout is_float]} { incr float_param_n }
            incr i
        }
        set frame_size 320
        set prologue_start [$em len]
        my emit_prologue_placeholder $frame_size
        set prologue_end [$em len]
        # Store params to frame AFTER prologue.
        # o32 ABI: 1st float in $f12, 2nd float in $f14, 3rd+ at $fp+(N*4)
        # (fp = old_sp = callee's frame top; caller put extra floats in its
        # outgoing-arg area at sp+0, sp+4, sp+8 ... = fp+0, fp+4, fp+8 ...).
        foreach pi $param_info {
            lassign $pi off p_layout fpn idx
            if {[dict get $p_layout is_float]} {
                if {$fpn == 0} {
                    my store_to_sp $off {} $p_layout
                } elseif {$fpn == 1} {
                    $em mov_s {$f12} {$f14}
                    my store_to_sp $off {} $p_layout
                } else {
                    # 3rd+ float: arrived at caller's sp+(fpn*4) = fp+(fpn*4)
                    $em lwc1 {$f12} [expr {$fpn * 4}] {$fp}
                    my store_to_sp $off {} $p_layout
                }
            } elseif {$idx < 4} {
                my store_to_sp $off [lindex $::pak::ARG_GPRS $idx] $p_layout
            } else {
                # 5th+ integer arg: arrived at caller's sp+($idx*4) = fp+($idx*4)
                set tmp [$ra alloc_temp]
                $em lw $tmp [expr {$idx * 4}] {$fp}
                my store_to_sp $off $tmp $p_layout
                $ra free_temp $tmp
            }
        }
        set ret_label [my fresh_label ".L${name}_ret"]
        my emit_block $body
        # Emit outer-scope (param) defers before patching prologue
        foreach d [my pop_scope] { my emit_stmt $d }
        my patch_prologue $frame_size $prologue_start $prologue_end
        $em label $ret_label
        my emit_epilogue $frame_size
        $em size_sym $name ". - $name"
    }

    # Called by RegAlloc during alloc_temp / free_temp when spilling.
    method emit_spill_store {reg slot} { $em sw $reg $slot {$sp} }
    method emit_spill_load  {reg slot} { $em lw $reg $slot {$sp} }

    # ── calls ─────────────────────────────────────────────────────────────────
    # $t0-$t9 are caller-saved: a callee is free to destroy them. Any temp still
    # holding a live value across a call therefore has to go to the stack first,
    # or an expression like `f(a) | g(b)` loses f's result inside g.
    #
    # One flat save area is enough. Saves, the call and the reloads are emitted
    # contiguously, so a nested call inside argument evaluation has already
    # finished and released its own saves by the time the outer call is emitted.
    method live_caller_saved {} {
        set live {}
        foreach r [$ra alloc_order] {
            if {$r in $::pak::CALLER_SAVED_GPRS} { lappend live $r }
        }
        return $live
    }

    method emit_call_saves {} {
        set live [my live_caller_saved]
        set i 0
        foreach r $live {
            $em sw $r [expr {$::pak::CALL_SAVE_BASE + $i * 4}] {$sp}
            incr i
        }
        return $live
    }

    method emit_call_restores {live} {
        set i 0
        foreach r $live {
            $em lw $r [expr {$::pak::CALL_SAVE_BASE + $i * 4}] {$sp}
            incr i
        }
    }

    method emit_jal {target} {
        set live [my emit_call_saves]
        $em jal $target
        $em nop
        my emit_call_restores $live
    }

    method emit_jalr_reg {reg} {
        set live [my emit_call_saves]
        $em jalr $reg
        $em nop
        my emit_call_restores $live
    }

    method emit_prologue_placeholder {frame_size} {
        $em addiu {$sp} {$sp} -$frame_size
        $em sw {$ra} [expr {$frame_size - 4}] {$sp}
        $em sw {$fp} [expr {$frame_size - 8}] {$sp}
        $em addiu {$fp} {$sp} $frame_size
        $em placeholder "callee-saves-placeholder"
    }

    method patch_prologue {frame_size pstart pend} {
        set callee [$ra used_callee_gprs]
        set lines {}
        set rlines {}
        set i 0
        foreach reg $callee {
            set off [expr {$frame_size - 12 - $i * 4}]
            lappend lines "    sw $reg, ${off}(\$sp)"
            lappend rlines [list i sw $reg "${off}(\$sp)"]
            incr i
        }
        # Patch the text buffer: replace the placeholder comment within the
        # current function's prologue region [pstart, pend).
        set buf [$em buf]
        for {set idx $pstart} {$idx < $pend} {incr idx} {
            if {[string match "*callee-saves-placeholder*" [lindex $buf $idx]]} {
                set buf [concat [lrange $buf 0 [expr {$idx-1}]] $lines [lrange $buf [expr {$idx+1}] end]]
                break
            }
        }
        $em setbuf $buf
        # Patch the record stream: the first unconsumed placeholder sentinel is
        # this function's (prior functions' sentinels were already replaced).
        set recs [$em getrecords]
        for {set idx 0} {$idx < [llength $recs]} {incr idx} {
            set r [lindex $recs $idx]
            if {[lindex $r 0] eq "placeholder" && [lindex $r 1] eq "callee-saves-placeholder"} {
                set recs [concat [lrange $recs 0 [expr {$idx-1}]] $rlines [lrange $recs [expr {$idx+1}] end]]
                break
            }
        }
        $em setrecords $recs
    }

    method emit_epilogue {frame_size} {
        set callee [$ra used_callee_gprs]
        set n [llength $callee]
        for {set i 0} {$i < $n} {incr i} {
            set ri [expr {$n - 1 - $i}]
            set reg [lindex $callee $ri]
            $em lw $reg [expr {$frame_size - 12 - $ri * 4}] {$sp}
        }
        $em lw {$fp} [expr {$frame_size - 8}] {$sp}
        $em lw {$ra} [expr {$frame_size - 4}] {$sp}
        $em addiu {$sp} {$sp} $frame_size
        $em jr {$ra}
        $em nop
    }

    # ── typed memory ──────────────────────────────────────────────────────────
    # Float convention: all scalar f32 values reside in $f12 (the float
    # accumulator).  The GPR dst/src argument is ignored for float ops —
    # swc1/lwc1 always target $f12.  FPU arithmetic (add.s/sub.s/mul.s/div.s)
    # and comparisons (c.eq.s/c.lt.s/c.le.s + bc1t/bc1f) are fully supported.
    method emit_typed_load {dst off base layout {volatile 0}} {
        if {$volatile} { $em sync }
        if {[dict get $layout is_float]} {
            if {[dict get $layout size] == 4} { $em lwc1 {$f12} $off $base } else { $em ldc1 {$f12} $off $base }
        } else {
            switch -- [dict get $layout size] {
                1 { if {[dict get $layout is_signed]} { $em lb $dst $off $base } else { $em lbu $dst $off $base } }
                2 { if {[dict get $layout is_signed]} { $em lh $dst $off $base } else { $em lhu $dst $off $base } }
                default { $em lw $dst $off $base }
            }
        }
        if {$volatile} { $em sync }
    }
    method emit_typed_store {src off base layout {volatile 0}} {
        if {$volatile} { $em sync }
        if {[dict get $layout is_float]} {
            if {[dict get $layout size] == 4} { $em swc1 {$f12} $off $base } else { $em sdc1 {$f12} $off $base }
        } else {
            switch -- [dict get $layout size] {
                1 { $em sb $src $off $base }
                2 { $em sh $src $off $base }
                default { $em sw $src $off $base }
            }
        }
        if {$volatile} { $em sync }
    }
    # Resolve {layout volatile} of what a pointer expression points to, so a
    # Deref load/store picks the correct width and emits volatile sync barriers.
    # `*volatile u16` parses as TypeVolatile(TypePointer(u16)); unwrap the outer
    # volatile, then take the pointee from the inner TypePointer.
    method pointee_layout {ptr_expr} {
        set ptr_type ""
        switch -- [pak::kindof $ptr_expr] {
            Cast  { set ptr_type [pak::nfield $ptr_expr type] }
            Ident { set ptr_type [my lookup_type_node [pak::fval $ptr_expr name]] }
        }
        set volatile 0
        if {$ptr_type ne "" && ![pak::isnil $ptr_type] && [pak::kindof $ptr_type] eq "TypeVolatile"} {
            set volatile 1
            set ptr_type [pak::nfield $ptr_type inner]
        }
        if {$ptr_type ne "" && ![pak::isnil $ptr_type] && [pak::kindof $ptr_type] eq "TypePointer"} {
            set inner [pak::nfield $ptr_type inner]
            if {![pak::isnil $inner] && [pak::kindof $inner] eq "TypeVolatile"} {
                set volatile 1
                set inner [pak::nfield $inner inner]
            }
            return [list [my mips_layout $inner] $volatile]
        }
        return [list [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}] 0]
    }
    method load_from_sp {off dst layout}  { my emit_typed_load $dst $off {$sp} $layout }
    method store_to_sp {off src layout}   { my emit_typed_store $src $off {$sp} $layout }

    method emit_block {block} {
        my push_scope
        foreach stmt [pak::items [pak::nfield $block stmts]] { my emit_stmt $stmt }
        foreach d [my pop_scope] { my emit_stmt $d }
    }

    method emit_block_or_stmt {node} {
        if {[pak::kindof $node] eq "Block"} {
            my emit_block $node
        } else {
            my emit_stmt $node
        }
    }

    method emit_stmt {stmt} {
        switch -- [pak::kindof $stmt] {
            LetDecl {
                set typ [pak::nfield $stmt type]
                if {![pak::isnil $typ]} { set layout [my mips_layout $typ] } else { set layout [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}] }
                set tn [expr {[pak::isnil $typ] ? "" : $typ}]
                set v [pak::nfield $stmt value]
                # Infer type node from RHS when no explicit annotation is given.
                # This enables correct method-call name mangling (TypeName_method)
                # for variables like: let mut p = Player { ... }
                if {$tn eq "" && ![pak::isnil $v]} {
                    if {[pak::kindof $v] eq "StructLit"} {
                        set sname [pak::fval $v type_name]
                        if {$sname ne ""} {
                            set tn [pak::N TypeName name $sname]
                            if {[dict exists $tenv_layouts $sname]} {
                                set layout [dict get $tenv_layouts $sname]
                            }
                        }
                    } elseif {[pak::kindof $v] eq "VariantCons"} {
                        set vname [pak::fval $v name]
                        if {$vname ne "" && [dict exists $tenv_variant_decls $vname]} {
                            set tn [pak::N TypeName name $vname]
                        }
                    }
                }
                if {[pak::fval $stmt name] eq "_"} {
                    if {![pak::isnil $v]} {
                        set tmp [$ra alloc_temp]
                        my emit_expr $v $tmp
                        $ra free_temp $tmp
                    }
                    continue
                }
                set off [my declare_local [pak::fval $stmt name] $layout $tn]
                if {![pak::isnil $v]} {
                    # loop-as-expression: let x = loop { ... break val ... }
                    if {[pak::kindof $v] in {LoopStmt WhileStmt}} {
                        # Initialize result slot to 0
                        set ztmp [$ra alloc_temp]
                        $em li $ztmp 0
                        my store_to_sp $off $ztmp $layout
                        $ra free_temp $ztmp
                        # Push result info; Break will store into this slot
                        lappend loop_result [list $off $layout]
                        if {[pak::kindof $v] eq "LoopStmt"} {
                            my emit_loop $v
                        } else {
                            my emit_while $v
                        }
                        set loop_result [lrange $loop_result 0 end-1]
                        # Result is already in $off from Break's store_to_sp — nothing more to do
                    } else {
                        set lsz [dict get $layout size]
                        # Determine if the RHS expression returns a pointer to a
                        # multi-word value on the stack (struct lit, variant ctor,
                        # array lit, tuple lit, etc.).  Conditions:
                        #   • size > 4 — multi-word value
                        #   • has fields/tag_size/_container — it's an aggregate type
                        set is_aggregate [expr {
                            ([dict exists $layout fields]     && [dict size [dict get $layout fields]] > 0) ||
                            [dict exists $layout tag_size]    ||
                            [dict exists $layout _container]
                        }]
                        if {$lsz > 4 && $is_aggregate} {
                            # Large aggregate: expr returns a pointer; copy to stack slot
                            set src_ptr [$ra alloc_temp]
                            set dst_ptr [$ra alloc_temp]
                            my emit_expr $v $src_ptr
                            $em addiu $dst_ptr {$sp} $off
                            my emit_memcpy $dst_ptr $src_ptr $lsz
                            $ra free_temp $dst_ptr
                            $ra free_temp $src_ptr
                        } else {
                            set tmp [$ra alloc_temp]
                            my emit_expr $v $tmp
                            my store_to_sp $off $tmp $layout
                            $ra free_temp $tmp
                        }
                    }
                }
            }
            StaticDecl { my emit_static $stmt }
            Assign {
                set val [$ra alloc_temp]
                my emit_expr [pak::nfield $stmt value] $val
                my emit_assign_target [pak::nfield $stmt target] $val [pak::fval $stmt op]
                $ra free_temp $val
            }
            Return {
                # Emit all pending defers (all scopes, innermost first) before jump
                for {set i [expr {[llength $defers]-1}]} {$i >= 0} {incr i -1} {
                    set scope_d [lindex $defers $i]
                    for {set j [expr {[llength $scope_d]-1}]} {$j >= 0} {incr j -1} {
                        my emit_stmt [lindex $scope_d $j]
                    }
                }
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} { my emit_expr $v {$v0} }
                $em j $ret_label
                $em nop
            }
            IfStmt    { my emit_if $stmt }
            WhileStmt { my emit_while $stmt }
            DoWhileStmt { my emit_do_while $stmt }
            LoopStmt  { my emit_loop $stmt }
            ForStmt   { my emit_for $stmt }
            MatchStmt { my emit_match $stmt }
            Break {
                set bv [pak::nfield $stmt value]
                if {![pak::isnil $bv] && [llength $loop_result] > 0} {
                    # loop-as-expression: store break value into the result slot
                    set res_info [lindex $loop_result end]
                    set res_off  [lindex $res_info 0]
                    set res_lay  [lindex $res_info 1]
                    set tmp [$ra alloc_temp]
                    my emit_expr $bv $tmp
                    my store_to_sp $res_off $tmp $res_lay
                    $ra free_temp $tmp
                }
                if {[llength $loop_exit] > 0} {
                    my emit_defers_from [lindex $loop_defer_depth end]
                    $em j [lindex $loop_exit end]; $em nop
                }
            }
            Continue {
                if {[llength $loop_header] > 0} {
                    my emit_defers_from [lindex $loop_defer_depth end]
                    $em j [lindex $loop_header end]; $em nop
                }
            }
            DeferStmt {
                my add_defer [pak::nfield $stmt body]
            }
            ExprStmt {
                set tmp [$ra alloc_temp]
                my emit_expr [pak::nfield $stmt expr] $tmp
                $ra free_temp $tmp
            }
            Block      { my emit_block $stmt }
            GotoStmt   { $em j [pak::fval $stmt label]; $em nop }
            LabelStmt  { $em label [pak::fval $stmt name] }
            AsmStmt {
                foreach line [pak::items [pak::nfield $stmt lines]] {
                    $em verbatim [lindex $line 1]
                }
            }
            ComptimeIf {
                set val [my eval_const_expr [pak::nfield $stmt condition]]
                if {$val ne "" && $val} {
                    my emit_block_or_stmt [pak::nfield $stmt then]
                } else {
                    set eb [pak::nfield $stmt else_branch]
                    if {![pak::isnil $eb]} { my emit_block_or_stmt $eb }
                }
            }
            NullCheckStmt { my emit_null_check_stmt $stmt }
            default    { pak::mips_unported "stmt:[pak::kindof $stmt]" }
        }
    }

    method emit_null_check_stmt {stmt} {
        set else_label [my fresh_label .Lnull_else]
        set end_label  [my fresh_label .Lnull_end]
        set val [$ra alloc_temp]
        my emit_expr [pak::nfield $stmt expr] $val
        $em beqz $val $else_label
        $em nop
        set bind_off [my declare_local [pak::fval $stmt binding] [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]]
        $em sw $val $bind_off {$sp}
        my emit_block [pak::nfield $stmt then]
        $em j $end_label
        $em nop
        $em label $else_label
        set eb [pak::nfield $stmt else_branch]
        if {![pak::isnil $eb]} { my emit_block $eb }
        $em label $end_label
        $ra free_temp $val
    }

    # ── control flow ──────────────────────────────────────────────────────────
    method emit_if {stmt} {
        set end_label [my fresh_label ".Lif_end"]
        set has_else [expr {![pak::isnil [pak::nfield $stmt else_branch]]}]
        set elifs [pak::items [pak::nfield $stmt elif_branches]]
        if {$has_else || [llength $elifs] > 0} { set else_label [my fresh_label ".Lif_else"] } else { set else_label $end_label }
        set cond [$ra alloc_temp]
        my emit_expr [pak::nfield $stmt condition] $cond
        $em beqz $cond $else_label
        $em nop
        $ra free_temp $cond
        my emit_block [pak::nfield $stmt then]
        if {[llength $elifs] > 0 || $has_else} { $em j $end_label; $em nop }
        set current_else $else_label
        foreach pair $elifs {
            set p [pak::items $pair]
            $em label $current_else
            set next_else [my fresh_label ".Lelif_else"]
            set cond [$ra alloc_temp]
            my emit_expr [lindex $p 0] $cond
            $em beqz $cond $next_else
            $em nop
            $ra free_temp $cond
            my emit_block [lindex $p 1]
            $em j $end_label
            $em nop
            set current_else $next_else
        }
        set eb [pak::nfield $stmt else_branch]
        if {$has_else} {
            $em label $current_else
            my emit_block $eb
        } elseif {[llength $elifs] > 0} {
            $em label $current_else
        }
        $em label $end_label
    }

    method emit_while {stmt} {
        set header [my fresh_label ".Lwhile_h"]
        set exit_l [my fresh_label ".Lwhile_x"]
        lappend loop_header $header; lappend loop_exit $exit_l
        lappend loop_defer_depth [llength $defers]
        $em label $header
        set cond [$ra alloc_temp]
        my emit_expr [pak::nfield $stmt condition] $cond
        $em beqz $cond $exit_l
        $em nop
        $ra free_temp $cond
        my emit_block [pak::nfield $stmt body]
        $em j $header
        $em nop
        $em label $exit_l
        set loop_header [lrange $loop_header 0 end-1]; set loop_exit [lrange $loop_exit 0 end-1]
        set loop_defer_depth [lrange $loop_defer_depth 0 end-1]
    }

    method emit_do_while {stmt} {
        set header [my fresh_label ".Ldow_h"]
        set exit_l [my fresh_label ".Ldow_x"]
        lappend loop_header $header; lappend loop_exit $exit_l
        lappend loop_defer_depth [llength $defers]
        $em label $header
        my emit_block [pak::nfield $stmt body]
        set cond [$ra alloc_temp]
        my emit_expr [pak::nfield $stmt condition] $cond
        $em bnez $cond $header
        $em nop
        $ra free_temp $cond
        $em label $exit_l
        set loop_header [lrange $loop_header 0 end-1]; set loop_exit [lrange $loop_exit 0 end-1]
        set loop_defer_depth [lrange $loop_defer_depth 0 end-1]
    }

    method emit_loop {stmt} {
        set header [my fresh_label ".Lloop_h"]
        set exit_l [my fresh_label ".Lloop_x"]
        lappend loop_header $header; lappend loop_exit $exit_l
        lappend loop_defer_depth [llength $defers]
        $em label $header
        my emit_block [pak::nfield $stmt body]
        $em j $header
        $em nop
        $em label $exit_l
        set loop_header [lrange $loop_header 0 end-1]; set loop_exit [lrange $loop_exit 0 end-1]
        set loop_defer_depth [lrange $loop_defer_depth 0 end-1]
    }

    method emit_for {stmt} {
        set it [pak::nfield $stmt iterable]
        if {[pak::kindof $it] eq "RangeExpr"} {
            my emit_for_range $stmt $it
        } else {
            my emit_for_each $stmt $it
        }
    }

    method emit_for_range {stmt it} {
        set header [my fresh_label ".Lfor_h"]
        set incr_l [my fresh_label ".Lfor_i"]
        set exit_l [my fresh_label ".Lfor_x"]
        set counter_layout [my mips_layout_name i32]
        set counter_off [my declare_local [pak::fval $stmt binding] $counter_layout]
        set start_r [$ra alloc_temp]
        set end_r [$ra alloc_temp]
        my emit_expr [pak::nfield $it start] $start_r
        my store_to_sp $counter_off $start_r $counter_layout
        set end_tv [pak::nfield $it end]
        if {![pak::isnil $end_tv]} { my emit_expr $end_tv $end_r } else { $em li $end_r 2147483647 }
        # continue must jump to the INCREMENT label (not the header) so the
        # counter advances before the next iteration check.
        lappend loop_header $incr_l; lappend loop_exit $exit_l
        lappend loop_defer_depth [llength $defers]
        $em label $header
        set ctr [$ra alloc_temp]
        my load_from_sp $counter_off $ctr $counter_layout
        $em bge $ctr $end_r $exit_l
        $em nop
        set idx [pak::nfield $stmt index]
        if {![pak::isnil $idx]} {
            set idx_layout [my mips_layout_name i32]
            set existing [my lookup_local [pak::sval $idx]]
            if {$existing eq ""} { set idx_off [my declare_local [pak::sval $idx] $idx_layout] } else { set idx_off [lindex $existing 0] }
            my store_to_sp $idx_off $ctr $idx_layout
        }
        my emit_block [pak::nfield $stmt body]
        $em label $incr_l
        my load_from_sp $counter_off $ctr $counter_layout
        $em addiu $ctr $ctr 1
        my store_to_sp $counter_off $ctr $counter_layout
        $ra free_temp $ctr
        $em j $header
        $em nop
        $ra free_temp $end_r
        $ra free_temp $start_r
        $em label $exit_l
        set loop_header [lrange $loop_header 0 end-1]; set loop_exit [lrange $loop_exit 0 end-1]
        set loop_defer_depth [lrange $loop_defer_depth 0 end-1]
    }

    # for item in slice — treat iterable as a fat pointer {ptr, len@+4}.
    method emit_for_each {stmt iterable} {
        set header [my fresh_label ".Lfeach_h"]
        set incr_l [my fresh_label ".Lfeach_i"]
        set exit_l [my fresh_label ".Lfeach_x"]
        set ptr_layout [my mips_layout_name i32]
        set ptr_off [my declare_local __for_ptr $ptr_layout]
        set len_off [my declare_local __for_len $ptr_layout]
        set idx_off [my declare_local __for_idx $ptr_layout]

        set slice_base [$ra alloc_temp]
        my emit_expr $iterable $slice_base
        $em sw $slice_base $ptr_off {$sp}
        set len_r [$ra alloc_temp]
        $em lw $len_r 4 $slice_base
        $em sw $len_r $len_off {$sp}
        $ra free_temp $len_r
        $ra free_temp $slice_base
        $em sw {$zero} $idx_off {$sp}

        # continue jumps to the increment label, not the header
        lappend loop_header $incr_l; lappend loop_exit $exit_l
        lappend loop_defer_depth [llength $defers]
        $em label $header

        set idx_r [$ra alloc_temp]
        set len_r [$ra alloc_temp]
        $em lw $idx_r $idx_off {$sp}
        $em lw $len_r $len_off {$sp}
        $em bge $idx_r $len_r $exit_l
        $em nop

        set binding_off [my declare_local [pak::fval $stmt binding] $ptr_layout]
        set ptr_r [$ra alloc_temp]
        set elem_r [$ra alloc_temp]
        $em lw $ptr_r $ptr_off {$sp}
        $em sll $elem_r $idx_r 2
        $em addu $ptr_r $ptr_r $elem_r
        $em lw $elem_r 0 $ptr_r
        $em sw $elem_r $binding_off {$sp}
        $ra free_temp $elem_r
        $ra free_temp $ptr_r

        set idx [pak::nfield $stmt index]
        if {![pak::isnil $idx]} {
            set existing [my lookup_local [pak::sval $idx]]
            if {$existing eq ""} { set idx2_off [my declare_local [pak::sval $idx] $ptr_layout] } else { set idx2_off [lindex $existing 0] }
            $em sw $idx_r $idx2_off {$sp}
        }

        my emit_block [pak::nfield $stmt body]

        $em label $incr_l
        $em lw $idx_r $idx_off {$sp}
        $em addiu $idx_r $idx_r 1
        $em sw $idx_r $idx_off {$sp}
        $ra free_temp $len_r
        $ra free_temp $idx_r

        $em j $header
        $em nop
        $em label $exit_l
        set loop_header [lrange $loop_header 0 end-1]; set loop_exit [lrange $loop_exit 0 end-1]
        set loop_defer_depth [lrange $loop_defer_depth 0 end-1]
    }

    # Emit guard check for a match arm: if guard is present and false, jump to skip_label.
    method emit_arm_guard {arm skip_label} {
        set guard [pak::nfield $arm guard]
        if {[pak::isnil $guard]} return
        set gr [$ra alloc_temp]
        my emit_expr $guard $gr
        $em beqz $gr $skip_label
        $em nop
        $ra free_temp $gr
    }

    method emit_match {stmt} {
        set end_label [my fresh_label ".Lmatch_end"]
        set val [$ra alloc_temp]
        my emit_expr [pak::nfield $stmt expr] $val

        foreach arm [pak::items [pak::nfield $stmt arms]] {
            # Allocate both labels per arm for label counter parity with Python
            set body_label [my fresh_label ".Larm"]
            set skip_label [my fresh_label ".Larm_skip"]

            set pat [pak::nfield $arm pattern]
            set pkind [pak::kindof $pat]

            if {$pkind eq "Ident" && [pak::fval $pat name] eq "_"} {
                # Wildcard — always matches (guard still evaluated if present)
                my emit_arm_guard $arm $skip_label
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
                if {![pak::isnil [pak::nfield $arm guard]]} { $em label $skip_label }
                break
            } elseif {$pkind eq "EnumVariantAccess"} {
                # .CaseName — match enum integer value
                set case_val [my resolve_enum_case_value [pak::fval $pat name]]
                set case_r [$ra alloc_temp]
                $em li $case_r $case_val
                $em bne $val $case_r $skip_label
                $em nop
                $ra free_temp $case_r
                my emit_arm_guard $arm $skip_label
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
                $em label $skip_label
            } elseif {$pkind eq "Call" && [pak::kindof [pak::nfield $pat func]] eq "EnumVariantAccess"} {
                # .VariantCase(binding) — variant tag + extract payload
                my emit_variant_arm $val $pat [pak::nfield $arm body] $skip_label $end_label $arm
                $em label $skip_label
            } elseif {$pkind eq "DotAccess"} {
                # EnumName.case or VariantName.Case(binding)
                set variant [pak::fval $pat field]
                set binding [pak::nfield $pat binding]
                if {![pak::isnil $binding] && $binding ne ""} {
                    # DotAccess with a single binding — treat as single-arg Call
                    set fake_call [pak::N Call func [pak::N EnumVariantAccess name $variant] \
                        args [pak::Seq [list [pak::N Ident name [pak::sval $binding]]]] type_args {}]
                    my emit_variant_arm $val $fake_call [pak::nfield $arm body] $skip_label $end_label $arm
                } else {
                    set case_val [my resolve_enum_case_value $variant]
                    set case_r [$ra alloc_temp]
                    $em li $case_r $case_val
                    $em bne $val $case_r $skip_label
                    $em nop
                    $ra free_temp $case_r
                    my emit_arm_guard $arm $skip_label
                    my emit_block_or_stmt [pak::nfield $arm body]
                    $em j $end_label
                    $em nop
                }
                $em label $skip_label
            } elseif {$pkind eq "IntLit"} {
                set case_r [$ra alloc_temp]
                $em li $case_r [pak::fval $pat value]
                $em bne $val $case_r $skip_label
                $em nop
                $ra free_temp $case_r
                my emit_arm_guard $arm $skip_label
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
                $em label $skip_label
            } elseif {$pkind eq "BoolLit"} {
                set case_r [$ra alloc_temp]
                $em li $case_r [expr {[pak::fval $pat value] ? 1 : 0}]
                $em bne $val $case_r $skip_label
                $em nop
                $ra free_temp $case_r
                my emit_arm_guard $arm $skip_label
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
                $em label $skip_label
            } else {
                # Unknown pattern — always emit body
                my emit_arm_guard $arm $skip_label
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
                if {![pak::isnil [pak::nfield $arm guard]]} { $em label $skip_label }
            }
        }

        $ra free_temp $val
        $em label $end_label
    }

    method emit_variant_arm {val_reg pat body skip_label end_label {arm ""}} {
        set case_name [pak::fval [pak::nfield $pat func] name]
        set tag_val   [my resolve_variant_tag $case_name]
        set vname     [my resolve_variant_name_for_case $case_name]
        set layout ""
        if {$vname ne "" && [dict exists $tenv_layouts $vname]} {
            set layout [dict get $tenv_layouts $vname]
        }
        set tag_size [expr {$layout ne "" && [dict exists $layout tag_size] ? [dict get $layout tag_size] : 1}]

        set tag_r [$ra alloc_temp]
        if {$tag_size == 1} { $em lbu $tag_r 0 $val_reg } \
        elseif {$tag_size == 2} { $em lhu $tag_r 0 $val_reg } \
        else { $em lw $tag_r 0 $val_reg }
        set cmp_r [$ra alloc_temp]
        $em li $cmp_r $tag_val
        $em bne $tag_r $cmp_r $skip_label
        $em nop
        $ra free_temp $cmp_r
        $ra free_temp $tag_r
        if {$arm ne ""} { my emit_arm_guard $arm $skip_label }

        # Bind payload fields
        set args [pak::items [pak::nfield $pat args]]
        if {[llength $args] > 0 && $vname ne ""} {
            set case_fields [my variant_case_fields $vname $case_name]
            set payload_align 4
            if {[llength $case_fields] > 0} {
                set payload_align 1
                foreach cf $case_fields {
                    set a [dict get $cf align]
                    if {$a > $payload_align} { set payload_align $a }
                }
            }
            set payload_offset [expr {($tag_size + $payload_align - 1) & ~($payload_align - 1)}]

            set i 0
            foreach arg $args {
                if {[pak::kindof $arg] eq "Ident" && [pak::fval $arg name] ne "_"} {
                    if {$i < [llength $case_fields]} {
                        set cf [lindex $case_fields $i]
                        set ftype [dict get $cf type_node]
                        if {$ftype ne "" && ![pak::isnil $ftype]} {
                            set fl [my mips_layout $ftype]
                        } else {
                            set fl [dict create size [dict get $cf size] align [dict get $cf align] \
                                is_float 0 is_signed 1 is_ptr 0 fields {}]
                        }
                        set field_r [$ra alloc_temp]
                        my emit_typed_load $field_r \
                            [expr {$payload_offset + [dict get $cf offset]}] $val_reg $fl
                        set bind_off [my declare_local [pak::fval $arg name] $fl]
                        my store_to_sp $bind_off $field_r $fl
                        $ra free_temp $field_r
                    } else {
                        set field_r [$ra alloc_temp]
                        $em lw $field_r [expr {$payload_offset + $i * 4}] $val_reg
                        set def_layout [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]
                        set bind_off [my declare_local [pak::fval $arg name] $def_layout]
                        $em sw $field_r $bind_off {$sp}
                        $ra free_temp $field_r
                    }
                }
                incr i
            }
        }

        my emit_block_or_stmt $body
        $em j $end_label
        $em nop
    }

    method emit_variant_constructor {vname case_name args_seq dst} {
        if {![dict exists $tenv_layouts $vname]} { pak::mips_unported "variant:$vname" }
        set layout [dict get $tenv_layouts $vname]
        set tag_val [my variant_tag $vname $case_name]
        set case_fields [my variant_case_fields $vname $case_name]

        set off [my declare_local __variant_lit $layout]
        # Zero-init
        for {set w 0} {$w < [dict get $layout size]} {incr w 4} {
            $em sw {$zero} [expr {$off + $w}] {$sp}
        }

        # Store tag
        set tag_size [dict get $layout tag_size]
        if {$tag_size < 1} { set tag_size 1 }
        set tmp [$ra alloc_temp]
        $em li $tmp $tag_val
        if {$tag_size == 1} { $em sb $tmp $off {$sp} } \
        elseif {$tag_size == 2} { $em sh $tmp $off {$sp} } \
        else { $em sw $tmp $off {$sp} }
        $ra free_temp $tmp

        # Payload alignment
        if {[llength $case_fields] > 0} {
            set payload_align 1
            foreach cf $case_fields {
                set a [dict get $cf align]
                if {$a > $payload_align} { set payload_align $a }
            }
        } else {
            set payload_align 4
        }
        set payload_start [expr {($tag_size + $payload_align - 1) & ~($payload_align - 1)}]

        set args [pak::items $args_seq]
        set i 0
        foreach arg $args {
            if {$i < [llength $case_fields]} {
                set cf [lindex $case_fields $i]
                set ftype [dict get $cf type_node]
                if {$ftype ne "" && ![pak::isnil $ftype]} {
                    set fl [my mips_layout $ftype]
                } else {
                    set fl [dict create size [dict get $cf size] align [dict get $cf align] \
                        is_float 0 is_signed 1 is_ptr 0 fields {}]
                }
                set tmp [$ra alloc_temp]
                my emit_expr $arg $tmp
                my emit_typed_store $tmp \
                    [expr {$off + $payload_start + [dict get $cf offset]}] {$sp} $fl
                $ra free_temp $tmp
            }
            incr i
        }

        $em addiu $dst {$sp} $off
    }

    method variant_tag {vname case_name} {
        if {![dict exists $tenv_variant_decls $vname]} { return 0 }
        set decl [dict get $tenv_variant_decls $vname]
        set i 0
        foreach case [pak::items [pak::nfield $decl cases]] {
            if {[pak::fval $case name] eq $case_name} { return $i }
            incr i
        }
        return 0
    }

    method emit_expr {expr dst} {
        switch -- [pak::kindof $expr] {
            IntLit    { $em li $dst [pak::fval $expr value] }
            BoolLit   { $em li $dst [expr {[pak::fval $expr value] ? 1 : 0}] }
            NoneLit   { $em move $dst {$zero} }
            StringLit { $em la $dst [$pool intern_string [pak::fval $expr value]] }
            FloatLit {
                set lbl [$pool intern_float [pak::fval $expr value]]
                set addr [$ra alloc_temp]
                $em la $addr $lbl
                $em lwc1 {$f12} 0 $addr
                $ra free_temp $addr
                # Float value lives in $f12; $dst (GPR) is not used for floats.
            }
            Ident     { my emit_ident_load [pak::fval $expr name] $dst }
            BinaryOp  { my emit_binop $expr $dst }
            UnaryOp   { my emit_unop $expr $dst }
            UndefinedLit { $em move $dst {$zero} }
            Deref {
                lassign [my pointee_layout [pak::nfield $expr expr]] dl dvol
                set ptr [$ra alloc_temp]
                my emit_expr [pak::nfield $expr expr] $ptr
                my emit_typed_load $dst 0 $ptr $dl $dvol
                $ra free_temp $ptr
            }
            AddrOf { my emit_addr_of $expr $dst }
            IndexAccess { my emit_index_access $expr $dst }
            DotAccess { my emit_field_access $expr $dst }
            Cast {
                set src [$ra alloc_temp]
                my emit_expr [pak::nfield $expr expr] $src
                my emit_cast $src $dst [pak::nfield $expr type]
                $ra free_temp $src
            }
            StructLit { my emit_struct_lit $expr $dst }
            SizeOf {
                set l [my mips_layout [pak::nfield $expr operand]]
                $em li $dst [dict get $l size]
            }
            AlignOf {
                set l [my mips_layout [pak::nfield $expr operand]]
                $em li $dst [dict get $l align]
            }
            OffsetOf {
                set layout [my mips_layout_name [pak::fval $expr type_name]]
                set fname [pak::fval $expr field]
                set off 0
                if {[dict exists $layout fields]} {
                    set fields [dict get $layout fields]
                    if {[dict exists $fields $fname]} { set off [dict get [dict get $fields $fname] offset] }
                }
                $em li $dst $off
            }
            ArrayLit {
                set elems [pak::items [pak::nfield $expr elements]]
                set n [llength $elems]
                set arr_off [my declare_local __arr_lit [dict create size [expr {$n*4}] align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]]
                set i 0
                foreach elem $elems {
                    set tmp [$ra alloc_temp]
                    my emit_expr $elem $tmp
                    $em sw $tmp [expr {$arr_off + $i*4}] {$sp}
                    $ra free_temp $tmp
                    incr i
                }
                $em addiu $dst {$sp} $arr_off
            }
            TupleLit {
                set elems [pak::items [pak::nfield $expr elements]]
                set n [llength $elems]
                set tup_off [my declare_local __tup [dict create size [expr {$n*4}] align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]]
                set i 0
                foreach elem $elems {
                    set er [$ra alloc_temp]
                    my emit_expr $elem $er
                    $em sw $er [expr {$tup_off + $i*4}] {$sp}
                    $ra free_temp $er
                    incr i
                }
                $em addiu $dst {$sp} $tup_off
            }
            TupleAccess {
                set base [$ra alloc_temp]
                my emit_expr [pak::nfield $expr obj] $base
                $em lw $dst [expr {[pak::fval $expr index] * 4}] $base
                $ra free_temp $base
            }
            AsmExpr { my emit_asm_expr $expr $dst }
            SliceExpr { my emit_slice $expr $dst }
            OkExpr {
                # Result layout: {is_ok: bool@0, payload@4, size=8}
                set ok_layout [dict create size 8 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]
                set ok_off [my declare_local __ok_tmp $ok_layout]
                # Zero-init (2 words)
                $em sw {$zero} $ok_off {$sp}
                $em sw {$zero} [expr {$ok_off + 4}] {$sp}
                # Set is_ok flag at offset 0
                $em li $dst 1
                $em sb $dst $ok_off {$sp}
                # Store value at offset 4
                set val [$ra alloc_temp]
                my emit_expr [pak::nfield $expr value] $val
                $em sw $val [expr {$ok_off + 4}] {$sp}
                $ra free_temp $val
                $em addiu $dst {$sp} $ok_off
            }
            ErrExpr {
                set err_layout [dict create size 8 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]
                set err_off [my declare_local __err_tmp $err_layout]
                $em sw {$zero} $err_off {$sp}
                $em sw {$zero} [expr {$err_off + 4}] {$sp}
                # is_ok = 0 already (zero-init); store error value at offset 4
                $em sb {$zero} $err_off {$sp}
                set val [$ra alloc_temp]
                my emit_expr [pak::nfield $expr value] $val
                $em sw $val [expr {$err_off + 4}] {$sp}
                $ra free_temp $val
                $em addiu $dst {$sp} $err_off
            }
            VariantLit {
                set vname [pak::fval $expr variant_type]
                set case_name [pak::fval $expr case_name]
                if {![dict exists $tenv_layouts $vname]} { pak::mips_unported "VariantLit:$vname" }
                set layout [dict get $tenv_layouts $vname]
                set tag_val [my variant_tag $vname $case_name]
                set case_fields [my variant_case_fields $vname $case_name]

                set off [my declare_local __variant_lit $layout]
                for {set w 0} {$w < [dict get $layout size]} {incr w 4} {
                    $em sw {$zero} [expr {$off + $w}] {$sp}
                }
                # Store tag
                set tag_size [dict get $layout tag_size]
                if {$tag_size < 1} { set tag_size 1 }
                set tmp [$ra alloc_temp]
                $em li $tmp $tag_val
                if {$tag_size == 1} { $em sb $tmp $off {$sp} } \
                elseif {$tag_size == 2} { $em sh $tmp $off {$sp} } \
                else { $em sw $tmp $off {$sp} }
                $ra free_temp $tmp
                # Payload offset
                if {[llength $case_fields] > 0} {
                    set payload_align 1
                    foreach cf $case_fields {
                        set a [dict get $cf align]
                        if {$a > $payload_align} { set payload_align $a }
                    }
                } else { set payload_align 4 }
                set payload_start [expr {($tag_size + $payload_align - 1) & ~($payload_align - 1)}]
                # Store named fields by matching name to case_fields
                foreach pair [pak::items [pak::nfield $expr fields]] {
                    set pitems [pak::items $pair]
                    set fname [pak::sval [lindex $pitems 0]]
                    set fval  [lindex $pitems 1]
                    set fi -1; set i 0
                    foreach cf $case_fields {
                        if {[dict get $cf name] eq $fname} { set fi $i; break }
                        incr i
                    }
                    if {$fi >= 0} {
                        set cf [lindex $case_fields $fi]
                        set ftype [dict get $cf type_node]
                        if {$ftype ne "" && ![pak::isnil $ftype]} {
                            set fl [my mips_layout $ftype]
                        } else {
                            set fl [dict create size [dict get $cf size] align [dict get $cf align] \
                                is_float 0 is_signed 1 is_ptr 0 fields {}]
                        }
                        set tmp [$ra alloc_temp]
                        my emit_expr $fval $tmp
                        my emit_typed_store $tmp [expr {$off + $payload_start + [dict get $cf offset]}] {$sp} $fl
                        $ra free_temp $tmp
                    }
                }
                $em addiu $dst {$sp} $off
            }
            RangeExpr { pak::mips_unported "RangeExpr-as-expr (only valid in for-loop)" }
            EnumVariantAccess {
                set val [my resolve_enum_case_value [pak::fval $expr name]]
                $em li $dst $val
            }
            AllocExpr {
                set inner [my mips_layout [pak::nfield $expr type_node]]
                $em li {$a0} [dict get $inner size]
                set count [pak::nfield $expr count]
                if {![pak::isnil $count]} {
                    set cnt [$ra alloc_temp]
                    my emit_expr $count $cnt
                    $em mul {$a0} {$a0} $cnt
                    $ra free_temp $cnt
                }
                my emit_jal __pak_alloc
                $em move $dst {$v0}
            }
            FreeExpr {
                set ptr [$ra alloc_temp]
                my emit_expr [pak::nfield $expr ptr] $ptr
                $em move {$a0} $ptr
                $ra free_temp $ptr
                my emit_jal __pak_free
                $em move $dst {$zero}
            }
            Assign {
                set val [$ra alloc_temp]
                my emit_expr [pak::nfield $expr value] $val
                my emit_assign_target [pak::nfield $expr target] $val [pak::fval $expr op]
                $em move $dst $val
                $ra free_temp $val
            }
            Call      { my emit_call $expr $dst }
            FmtStr    { my emit_fmtstr $expr $dst }
            Closure {
                set name [my emit_closure $expr]
                $em la $dst $name
            }
            CatchExpr { my emit_catch $expr $dst }
            default   { pak::mips_unported "expr:[pak::kindof $expr]" }
        }
    }

    method emit_fmtstr {expr dst} {
        set parts [pak::items [pak::nfield $expr parts]]
        # Check if all parts are literals (pure string, no interpolation)
        set has_expr 0
        foreach part $parts {
            if {[lindex $part 0] ne "lit"} { set has_expr 1; break }
        }
        if {!$has_expr} {
            # Pure literal: load the interned string label
            set text ""
            foreach part $parts { append text [lindex $part 1] }
            $em la $dst [$pool intern_string $text]
            return
        }
        # Interpolated format string: emit snprintf(buf, 256, fmt, args...)
        # Build the format string from literal + %spec parts.
        set fmt_text ""
        set expr_parts {}
        foreach part $parts {
            if {[lindex $part 0] eq "lit"} {
                # Escape backslashes and double-quotes in the literal segment
                set seg [lindex $part 1]
                set seg [string map {\\ \\\\ \" \\\"} $seg]
                append fmt_text $seg
            } else {
                set sub_expr $part
                if {[my infer_is_float $sub_expr]} {
                    append fmt_text "%f"
                } else {
                    append fmt_text "%d"
                }
                lappend expr_parts $sub_expr
            }
        }
        set fmt_lbl [$pool intern_string $fmt_text]
        set buf_name "__pak_fmtbuf_$fmtstr_counter"
        incr fmtstr_counter
        $pool add_static $buf_name 256 1 ""
        # Evaluate all expression arguments into temp registers
        set arg_regs {}
        foreach ep $expr_parts {
            set t [$ra alloc_temp]
            my emit_expr $ep $t
            lappend arg_regs $t
        }
        # Set up snprintf call: $a0=buf, $a1=256, $a2=fmt, $a3=arg0, sp+16=arg1, ...
        $em la {$a0} $buf_name
        $em li {$a1} 256
        $em la {$a2} $fmt_lbl
        set i 0
        foreach t $arg_regs {
            if {$i == 0} {
                $em move {$a3} $t
            } else {
                set off [expr {16 + ($i - 1) * 4}]
                $em sw $t $off {$sp}
            }
            incr i
        }
        foreach t $arg_regs { $ra free_temp $t }
        my emit_jal snprintf
        $em la $dst $buf_name
    }

    method emit_closure {expr} {
        set name [my fresh_label __closure]
        set body [pak::nfield $expr body]
        if {[pak::kindof $body] ne "Block"} {
            set body [pak::N Block stmts [pak::Seq [list [pak::N Return value $body]]]]
        }
        set saved [my save_fn_state]
        my emit_fn $name [pak::nfield $expr params] $body
        my restore_fn_state $saved
        return $name
    }

    method emit_catch {expr dst} {
        set ok_label [my fresh_label .Lcatch_ok]
        # Result layout: {is_ok@0, payload@4}
        set t_off 0
        set p_off 4
        set result_ptr [$ra alloc_temp]
        my emit_expr [pak::nfield $expr expr] $result_ptr
        set ok_flag [$ra alloc_temp]
        $em lbu $ok_flag $t_off $result_ptr
        $em bnez $ok_flag $ok_label
        $em nop
        $ra free_temp $ok_flag
        set handler [pak::nfield $expr handler]
        if {![pak::isnil $handler]} {
            set binding_node [pak::nfield $expr binding]
            if {![pak::isnil $binding_node]} {
                set binding [pak::sval $binding_node]
                set err_val [$ra alloc_temp]
                $em lw $err_val $p_off $result_ptr
                set bind_off [my declare_local $binding [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]]
                $em sw $err_val $bind_off {$sp}
                $ra free_temp $err_val
            }
            my emit_expr $handler $dst
        }
        $em label $ok_label
        $em lw $dst $p_off $result_ptr
        $ra free_temp $result_ptr
    }

    method emit_field_access {expr dst} {
        # Handle variant zero-arg constructor: Shape.point → emit_variant_constructor
        set obj [pak::nfield $expr obj]
        if {[pak::kindof $obj] eq "Ident"} {
            set obj_name [pak::fval $obj name]
            set field_name [pak::fval $expr field]
            if {[dict exists $tenv_variant_decls $obj_name]} {
                my emit_variant_constructor $obj_name $field_name [pak::Seq {}] $dst
                return
            }
            # Also handle EnumName.CaseName as a raw integer enum value
            if {[dict exists $tenv_enum_values $obj_name]} {
                set cases [dict get $tenv_enum_values $obj_name]
                if {[dict exists $cases $field_name]} {
                    $em li $dst [dict get $cases $field_name]
                    return
                }
            }
        }
        set base [$ra alloc_temp]
        my emit_expr $obj $base
        set fi [my resolve_field_info $expr]
        if {$fi ne ""} {
            set type_node [dict get $fi type_node]
            if {$type_node ne "" && ![pak::isnil $type_node]} {
                set fl [my mips_layout $type_node]
            } else {
                set fl [dict create size [dict get $fi size] align [dict get $fi align] \
                    is_float 0 is_signed 1 is_ptr 0 fields {}]
            }
            my emit_typed_load $dst [dict get $fi offset] $base $fl
        } else {
            $em lw $dst 0 $base
        }
        $ra free_temp $base
    }

    method emit_field_store {expr val} {
        set base [$ra alloc_temp]
        my emit_expr [pak::nfield $expr obj] $base
        set fi [my resolve_field_info $expr]
        if {$fi ne ""} {
            set type_node [dict get $fi type_node]
            if {$type_node ne "" && ![pak::isnil $type_node]} {
                set fl [my mips_layout $type_node]
            } else {
                set fl [dict create size [dict get $fi size] align [dict get $fi align] \
                    is_float 0 is_signed 1 is_ptr 0 fields {}]
            }
            my emit_typed_store $val [dict get $fi offset] $base $fl
        } else {
            $em sw $val 0 $base
        }
        $ra free_temp $base
    }

    method emit_asm_expr {expr dst} {
        # Inputs: evaluate each into a temp that is immediately freed (so they
        # reuse the same register — matches the Python oracle's per-iter borrow).
        set input_regs {}
        foreach inp [pak::items [pak::nfield $expr inputs]] {
            set iexpr [lindex [pak::items $inp] 1]
            set inp_r [$ra alloc_temp]
            my emit_expr $iexpr $inp_r
            $ra free_temp $inp_r
            lappend input_regs $inp_r
        }
        # Substitute %0 (output/dst), %1.. (inputs) sequentially.
        set template [lindex [pak::nfield $expr template] 1]
        set all_regs [concat [list $dst] $input_regs]
        set j 0
        foreach reg $all_regs {
            set template [string map [list "%$j" $reg] $template]
            incr j
        }
        foreach line [split $template "\n"] {
            set line [string trim $line]
            if {$line ne ""} { $em verbatim $line }
        }
        set outputs [pak::items [pak::nfield $expr outputs]]
        set inputs  [pak::items [pak::nfield $expr inputs]]
        if {[llength $outputs] > 0} {
            $em move $dst {$v0}
        } elseif {[llength $inputs] == 0 && [llength $outputs] == 0} {
            $em move $dst {$v0}
        }
    }

    method emit_slice {expr dst} {
        set slice_off [my declare_local __slice [dict create size 8 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]]
        set base [$ra alloc_temp]
        my emit_expr [pak::nfield $expr obj] $base
        set start [pak::nfield $expr start]
        if {![pak::isnil $start]} {
            set s [$ra alloc_temp]
            my emit_expr $start $s
            $em sll $s $s 2
            $em addu $base $base $s
            $ra free_temp $s
        }
        $em sw $base $slice_off {$sp}
        set end [pak::nfield $expr end]
        if {![pak::isnil $end]} {
            set end_r [$ra alloc_temp]
            set start_r [$ra alloc_temp]
            my emit_expr $end $end_r
            if {![pak::isnil $start]} {
                my emit_expr $start $start_r
                $em subu $end_r $end_r $start_r
            }
            $em sw $end_r [expr {$slice_off + 4}] {$sp}
            $ra free_temp $start_r
            $ra free_temp $end_r
        } else {
            $em sw {$zero} [expr {$slice_off + 4}] {$sp}
        }
        $ra free_temp $base
        $em addiu $dst {$sp} $slice_off
    }

    method emit_struct_lit {expr dst} {
        set tname [pak::fval $expr type_name]
        set type_args [pak::items [pak::nfield $expr type_args]]
        if {[llength $type_args] > 0 && [dict exists $generic_structs $tname]} {
            set tname [my monomorphize_struct $tname $type_args]
        }
        if {[dict exists $tenv_layouts $tname]} {
            set layout [dict get $tenv_layouts $tname]
        } else {
            set layout [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]
        }
        set off [my declare_local __struct_lit $layout]
        set sz [dict get $layout size]

        # Zero-init
        if {$sz <= 32} {
            for {set w 0} {$w < $sz} {incr w 4} {
                $em sw {$zero} [expr {$off + $w}] {$sp}
            }
        } else {
            $em addiu {$a0} {$sp} $off
            $em move {$a1} {$zero}
            $em li {$a2} $sz
            my emit_jal memset
        }

        # Per-field stores
        foreach field_seq [pak::items [pak::nfield $expr fields]] {
            set items [pak::items $field_seq]
            set fname [pak::sval [lindex $items 0]]
            set fval_node [lindex $items 1]
            if {[dict exists $layout fields]} {
                set fields [dict get $layout fields]
                if {[dict exists $fields $fname]} {
                    set fi [dict get $fields $fname]
                    set ftype [dict get $fi type_node]
                    if {$ftype ne "" && ![pak::isnil $ftype]} {
                        set fl [my mips_layout $ftype]
                    } else {
                        set fl [dict create size [dict get $fi size] align [dict get $fi align] \
                            is_float 0 is_signed 1 is_ptr 0 fields {}]
                    }
                    set tmp [$ra alloc_temp]
                    my emit_expr $fval_node $tmp
                    my emit_typed_store $tmp [expr {$off + [dict get $fi offset]}] {$sp} $fl
                    $ra free_temp $tmp
                }
            }
        }

        $em addiu $dst {$sp} $off
    }

    method emit_ident_load {name dst} {
        if {[dict exists $consts $name]} { $em li $dst [dict get $consts $name]; return }
        set local [my lookup_local $name]
        if {$local ne ""} {
            my load_from_sp [lindex $local 0] $dst [lindex $local 1]
            return
        }
        $em la $dst $name
        $em lw $dst 0 $dst
    }

    # element layout for array/slice access — always 4-byte (matches backend).
    method resolve_elem_layout {obj_expr} { return [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}] }

    method emit_index_addr {obj index} {
        set elem [my resolve_elem_layout $obj]
        set base [$ra alloc_temp]
        set idx [$ra alloc_temp]
        my emit_expr $obj $base
        my emit_expr $index $idx
        switch -- [dict get $elem size] {
            4 { $em sll $idx $idx 2 }
            2 { $em sll $idx $idx 1 }
            1 {}
            default {
                set sz [$ra alloc_temp]
                $em li $sz [dict get $elem size]
                $em mul $idx $idx $sz
                $ra free_temp $sz
            }
        }
        $em addu $base $base $idx
        return [list $base $idx $elem]
    }

    method emit_index_access {expr dst} {
        lassign [my emit_index_addr [pak::nfield $expr obj] [pak::nfield $expr index]] base idx elem
        my emit_typed_load $dst 0 $base $elem
        $ra free_temp $idx
        $ra free_temp $base
    }

    method emit_index_store {target val} {
        lassign [my emit_index_addr [pak::nfield $target obj] [pak::nfield $target index]] base idx elem
        my emit_typed_store $val 0 $base $elem
        $ra free_temp $idx
        $ra free_temp $base
    }

    method emit_cast {src dst type_node} {
        set to [my mips_layout $type_node]
        set frac [expr {[dict exists $to frac_bits] ? [dict get $to frac_bits] : 0}]
        if {$frac > 0} {
            # int → fixed: shift left by frac_bits
            $em sll $dst $src $frac
            return
        }
        if {[dict get $to is_float]} {
            # int → float: convert into $f12 (the float accumulator register).
            $em mtc1 $src {$f12}
            $em cvt_s_w {$f12} {$f12}
            return
        }
        pak::emit_int_cast $em $dst $src [dict get $to size] [dict get $to is_signed]
    }

    method emit_addr_of {expr dst} {
        set inner [pak::nfield $expr expr]
        if {[pak::kindof $inner] eq "Ident"} {
            set local [my lookup_local [pak::fval $inner name]]
            if {$local ne ""} {
                $em addiu $dst {$sp} [lindex $local 0]
                return
            }
            $em la $dst [pak::fval $inner name]
        } else {
            set layout [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]
            set off [my declare_local __addrof $layout]
            set tmp [$ra alloc_temp]
            my emit_expr $inner $tmp
            $em sw $tmp $off {$sp}
            $ra free_temp $tmp
            $em addiu $dst {$sp} $off
        }
    }

    method infer_frac_bits {expr} {
        switch -- [pak::kindof $expr] {
            Ident {
                set n [pak::fval $expr name]
                set local [my lookup_local $n]
                if {$local ne ""} {
                    set lay [lindex $local 1]
                    if {[dict exists $lay frac_bits]} { return [dict get $lay frac_bits] }
                }
                if {[dict exists $globals $n]} {
                    set lay [lindex [dict get $globals $n] 1]
                    if {[dict exists $lay frac_bits]} { return [dict get $lay frac_bits] }
                }
                return 0
            }
            Cast {
                set tl [my mips_layout [pak::nfield $expr type]]
                if {[dict exists $tl frac_bits]} { return [dict get $tl frac_bits] }
                return 0
            }
            BinaryOp {
                set l [my infer_frac_bits [pak::nfield $expr left]]
                if {$l > 0} { return $l }
                return [my infer_frac_bits [pak::nfield $expr right]]
            }
            UnaryOp { return [my infer_frac_bits [pak::nfield $expr operand]] }
            DotAccess {
                set fi [my resolve_field_info $expr]
                if {$fi ne ""} {
                    set tn [dict get $fi type_node]
                    if {$tn ne "" && ![pak::isnil $tn]} {
                        set tl [my mips_layout $tn]
                        if {[dict exists $tl frac_bits]} { return [dict get $tl frac_bits] }
                    }
                }
                return 0
            }
            default { return 0 }
        }
    }

    # Returns 1 if the expression has float type (f32).
    method infer_is_float {expr} {
        switch -- [pak::kindof $expr] {
            FloatLit { return 1 }
            Ident {
                set n [pak::fval $expr name]
                set local [my lookup_local $n]
                if {$local ne ""} {
                    set lay [lindex $local 1]
                    if {[dict exists $lay is_float] && [dict get $lay is_float]} { return 1 }
                }
                if {[dict exists $globals $n]} {
                    set lay [lindex [dict get $globals $n] 1]
                    if {[dict exists $lay is_float] && [dict get $lay is_float]} { return 1 }
                }
                return 0
            }
            Cast {
                set tl [my mips_layout [pak::nfield $expr type]]
                return [expr {[dict get $tl is_float] ? 1 : 0}]
            }
            BinaryOp {
                # Comparisons and logical connectives yield a 0/1 integer, no
                # matter how the operands are typed: `a > 1.0 or b < 2.0` is an
                # integer `or` of two integer results, not a float operation.
                if {[pak::fval $expr op] in {== != < <= > >= && || and or}} { return 0 }
                if {[my infer_is_float [pak::nfield $expr left]]}  { return 1 }
                return [my infer_is_float [pak::nfield $expr right]]
            }
            UnaryOp {
                if {[pak::fval $expr op] in {! not}} { return 0 }
                return [my infer_is_float [pak::nfield $expr operand]]
            }
            DotAccess {
                set fi [my resolve_field_info $expr]
                if {$fi ne ""} {
                    set tn [dict get $fi type_node]
                    if {$tn ne "" && ![pak::isnil $tn]} {
                        set tl [my mips_layout $tn]
                        return [expr {[dict get $tl is_float] ? 1 : 0}]
                    }
                }
                return 0
            }
            default { return 0 }
        }
    }

    # Emit a binary operation where at least one operand is f32.
    # Convention: left operand ends up in $f14, right in $f12, result in $f12.
    # For comparison ops the result (0 or 1) goes into the GPR $dst.
    method emit_float_binop {expr dst op} {
        set tmp_lhs [$ra alloc_temp]
        my emit_expr [pak::nfield $expr left] $tmp_lhs
        # $f12 now holds left; save to $f14
        $em mov_s {$f14} {$f12}
        set tmp_rhs [$ra alloc_temp]
        my emit_expr [pak::nfield $expr right] $tmp_rhs
        # $f12 now holds right; $f14 holds left
        $ra free_temp $tmp_rhs
        $ra free_temp $tmp_lhs
        switch -- $op {
            + { $em add_s {$f12} {$f14} {$f12} }
            - { $em sub_s {$f12} {$f14} {$f12} }
            * { $em mul_s {$f12} {$f14} {$f12} }
            / { $em div_s {$f12} {$f14} {$f12} }
            == {
                set done [my fresh_label .Lfeq]
                $em c_eq_s {$f14} {$f12}
                $em li $dst 0
                $em bc1f $done
                $em nop
                $em li $dst 1
                $em label $done
            }
            != {
                set done [my fresh_label .Lfne]
                $em c_eq_s {$f14} {$f12}
                $em li $dst 1
                $em bc1f $done
                $em nop
                $em li $dst 0
                $em label $done
            }
            < {
                set done [my fresh_label .Lflt]
                $em c_lt_s {$f14} {$f12}
                $em li $dst 0
                $em bc1f $done
                $em nop
                $em li $dst 1
                $em label $done
            }
            <= {
                set done [my fresh_label .Lfle]
                $em c_le_s {$f14} {$f12}
                $em li $dst 0
                $em bc1f $done
                $em nop
                $em li $dst 1
                $em label $done
            }
            > {
                # a > b  ↔  b < a
                set done [my fresh_label .Lfgt]
                $em c_lt_s {$f12} {$f14}
                $em li $dst 0
                $em bc1f $done
                $em nop
                $em li $dst 1
                $em label $done
            }
            >= {
                # a >= b  ↔  b <= a
                set done [my fresh_label .Lfge]
                $em c_le_s {$f12} {$f14}
                $em li $dst 0
                $em bc1f $done
                $em nop
                $em li $dst 1
                $em label $done
            }
            default { pak::mips_unported "float-binop:$op" }
        }
    }

    method emit_fixmul {dst lhs rhs frac_bits} {
        $em mult $lhs $rhs
        if {$frac_bits >= 32} {
            $em mfhi $dst
        } else {
            set tmp_hi [$ra alloc_temp]
            set tmp_lo [$ra alloc_temp]
            $em mflo $tmp_lo
            $em mfhi $tmp_hi
            $em srl $tmp_lo $tmp_lo $frac_bits
            $em sll $tmp_hi $tmp_hi [expr {32 - $frac_bits}]
            $em or_ $dst $tmp_lo $tmp_hi
            $ra free_temp $tmp_lo
            $ra free_temp $tmp_hi
        }
    }

    method emit_fixdiv {dst lhs rhs frac_bits} {
        if {$frac_bits == 16} {
            $em move {$a0} $lhs
            $em move {$a1} $rhs
            my emit_jal __pak_fix16_div
            if {$dst ne {$v0}} { $em move $dst {$v0} }
        } else {
            set tmp [$ra alloc_temp]
            $em sll $tmp $lhs $frac_bits
            $em div $tmp $rhs
            $em mflo $dst
            $ra free_temp $tmp
        }
    }

    method emit_memcpy {dst_reg src_reg nbytes} {
        if {$nbytes <= 0} return
        if {$nbytes <= 32} {
            set tmp [$ra alloc_temp]
            set off 0
            while {$off + 4 <= $nbytes} {
                $em lw $tmp $off $src_reg
                $em sw $tmp $off $dst_reg
                incr off 4
            }
            while {$off + 2 <= $nbytes} {
                $em lhu $tmp $off $src_reg
                $em sh $tmp $off $dst_reg
                incr off 2
            }
            while {$off < $nbytes} {
                $em lbu $tmp $off $src_reg
                $em sb $tmp $off $dst_reg
                incr off
            }
            $ra free_temp $tmp
        } else {
            $em move {$a0} $dst_reg
            $em move {$a1} $src_reg
            $em li {$a2} $nbytes
            my emit_jal memcpy
        }
    }

    # Returns 1 if expr contains at least one function Call node.
    # Used by emit_binop to determine evaluation order so that the JAL
    # from a function call does not clobber caller-saved temp registers
    # holding the other operand's value.
    method expr_has_call {expr} {
        switch -- [pak::kindof $expr] {
            Call     { return 1 }
            BinaryOp {
                if {[my expr_has_call [pak::nfield $expr left]]}  { return 1 }
                return [my expr_has_call [pak::nfield $expr right]]
            }
            UnaryOp  { return [my expr_has_call [pak::nfield $expr operand]] }
            default  { return 0 }
        }
    }

    method emit_binop {expr dst} {
        set op [pak::fval $expr op]
        # Float path: dispatch to FPU arithmetic / comparisons
        if {[my infer_is_float [pak::nfield $expr left]] || \
            [my infer_is_float [pak::nfield $expr right]]} {
            my emit_float_binop $expr $dst $op
            return
        }
        set frac [my infer_frac_bits [pak::nfield $expr left]]
        if {$frac == 0} { set frac [my infer_frac_bits [pak::nfield $expr right]] }
        set left_expr  [pak::nfield $expr left]
        set right_expr [pak::nfield $expr right]
        # Evaluate the side containing a function call FIRST so that the
        # subsequent JAL does not clobber the caller-saved temp register
        # that holds the other operand (e.g. n * factorial(n-1)).
        if {[my expr_has_call $right_expr] && ![my expr_has_call $left_expr]} {
            set rhs [$ra alloc_temp]
            my emit_expr $right_expr $rhs
            set lhs [$ra alloc_temp]
            my emit_expr $left_expr $lhs
        } elseif {[my expr_has_call $left_expr] && ![my expr_has_call $right_expr]} {
            set lhs [$ra alloc_temp]
            my emit_expr $left_expr $lhs
            set rhs [$ra alloc_temp]
            my emit_expr $right_expr $rhs
        } else {
            set lhs [$ra alloc_temp]
            my emit_expr $left_expr $lhs
            set rhs [$ra alloc_temp]
            my emit_expr $right_expr $rhs
        }
        if {$frac > 0 && $op eq "*"} {
            my emit_fixmul $dst $lhs $rhs $frac
            $ra free_temp $rhs; $ra free_temp $lhs
            return
        }
        if {$frac > 0 && $op eq "/"} {
            my emit_fixdiv $dst $lhs $rhs $frac
            $ra free_temp $rhs; $ra free_temp $lhs
            return
        }
        switch -- $op {
            +  { $em addu $dst $lhs $rhs }
            -  { $em subu $dst $lhs $rhs }
            *  { $em mul $dst $lhs $rhs }
            /  { $em div $lhs $rhs; $em mflo $dst }
            %  { $em div $lhs $rhs; $em mfhi $dst }
            &  { $em and_ $dst $lhs $rhs }
            |  { $em or_ $dst $lhs $rhs }
            ^  { $em xor $dst $lhs $rhs }
            <<  { $em sllv $dst $lhs $rhs }
            >>  { $em srav $dst $lhs $rhs }
            ==  { $em seq $dst $lhs $rhs }
            !=  { $em sne $dst $lhs $rhs }
            <   { $em slt $dst $lhs $rhs }
            <=  { $em sle $dst $lhs $rhs }
            >   { $em sgt $dst $lhs $rhs }
            >=  { $em sge $dst $lhs $rhs }
            && {
                set tmp [$ra alloc_temp]
                $em sltiu $tmp $lhs 1
                $em sltiu $dst $rhs 1
                $em or_ $dst $tmp $dst
                $em sltiu $dst $dst 1
                $ra free_temp $tmp
            }
            || {
                set tmp [$ra alloc_temp]
                $em or_ $tmp $lhs $rhs
                $em sltu $dst {$zero} $tmp
                $ra free_temp $tmp
            }
            default { pak::mips_unported "binop:$op" }
        }
        $ra free_temp $rhs
        $ra free_temp $lhs
    }

    method emit_unop {expr dst} {
        set operand [$ra alloc_temp]
        my emit_expr [pak::nfield $expr operand] $operand
        set op [pak::fval $expr op]
        if {$op eq "-" && [my infer_is_float [pak::nfield $expr operand]]} {
            $em neg_s {$f12} {$f12}
            $ra free_temp $operand
            return
        }
        switch -- $op {
            -  { $em subu $dst {$zero} $operand }
            !  { $em sltiu $dst $operand 1 }
            ~  { $em not_ $dst $operand }
            default { pak::mips_unported "unop:$op" }
        }
        $ra free_temp $operand
    }

    method emit_assign_target {target val_reg op} {
        if {$op ne "="} {
            # For float compound assigns: $f12 holds the RHS value.
            # Save RHS to $f14, load target into $f12, apply FPU op, result in $f12.
            set target_is_float 0
            if {[pak::kindof $target] eq "Ident"} {
                set tlocal [my lookup_local [pak::fval $target name]]
                if {$tlocal ne "" && [dict get [lindex $tlocal 1] is_float]} { set target_is_float 1 }
            } elseif {[pak::kindof $target] eq "DotAccess"} {
                set fi [my resolve_field_info $target]
                if {$fi ne ""} {
                    set ftype [dict get $fi type_node]
                    if {$ftype ne "" && ![pak::isnil $ftype]} {
                        set fl [my mips_layout $ftype]
                        if {[dict get $fl is_float]} { set target_is_float 1 }
                    }
                }
            }
            if {$target_is_float && $op in {+= -= *= /=}} {
                $em mov_s {$f14} {$f12}
                if {[pak::kindof $target] eq "Ident"} {
                    set cur [$ra alloc_temp]
                    my emit_ident_load [pak::fval $target name] $cur
                    $ra free_temp $cur
                } else {
                    # DotAccess: load the field value into $f12
                    set cur [$ra alloc_temp]
                    my emit_field_access $target $cur
                    $ra free_temp $cur
                }
                switch -- $op {
                    += { $em add_s {$f12} {$f12} {$f14} }
                    -= { $em sub_s {$f12} {$f12} {$f14} }
                    *= { $em mul_s {$f12} {$f12} {$f14} }
                    /= { $em div_s {$f12} {$f12} {$f14} }
                }
            } else {
                set cur [$ra alloc_temp]
                if {[pak::kindof $target] eq "Ident"} {
                    my emit_ident_load [pak::fval $target name] $cur
                } elseif {[pak::kindof $target] eq "DotAccess"} {
                    my emit_field_access $target $cur
                } else {
                    $em la $cur __cur
                    $em lw $cur 0 $cur
                }
                switch -- $op {
                    +=  { $em addu $val_reg $cur $val_reg }
                    -=  { $em subu $val_reg $cur $val_reg }
                    *=  { $em mul $val_reg $cur $val_reg }
                    /=  { $em div $cur $val_reg; $em mflo $val_reg }
                    %=  { $em div $cur $val_reg; $em mfhi $val_reg }
                    <<= { $em sllv $val_reg $cur $val_reg }
                    >>= { $em srav $val_reg $cur $val_reg }
                    &=  { $em and_ $val_reg $cur $val_reg }
                    |=  { $em or_ $val_reg $cur $val_reg }
                    ^=  { $em xor $val_reg $cur $val_reg }
                    default { pak::mips_unported "compound-assign:$op" }
                }
                $ra free_temp $cur
            }
        }
        switch -- [pak::kindof $target] {
            Ident {
                set local [my lookup_local [pak::fval $target name]]
                if {$local ne ""} {
                    my store_to_sp [lindex $local 0] $val_reg [lindex $local 1]
                } else {
                    set addr_r [$ra alloc_temp]
                    $em la $addr_r [pak::fval $target name]
                    # Use float store if the global is declared as float
                    set glay {}
                    if {[dict exists $globals [pak::fval $target name]]} {
                        set glay [lindex [dict get $globals [pak::fval $target name]] 1]
                    }
                    if {$glay ne {} && [dict get $glay is_float]} {
                        $em swc1 {$f12} 0 $addr_r
                    } else {
                        $em sw $val_reg 0 $addr_r
                    }
                    $ra free_temp $addr_r
                }
            }
            Deref {
                lassign [my pointee_layout [pak::nfield $target expr]] dl dvol
                set ptr [$ra alloc_temp]
                my emit_expr [pak::nfield $target expr] $ptr
                my emit_typed_store $val_reg 0 $ptr $dl $dvol
                $ra free_temp $ptr
            }
            IndexAccess { my emit_index_store $target $val_reg }
            DotAccess   { my emit_field_store $target $val_reg }
            default { pak::mips_unported "assign-target:[pak::kindof $target]" }
        }
    }

    method eval_const_expr {expr} {
        switch -- [pak::kindof $expr] {
            IntLit  { return [pak::fval $expr value] }
            BoolLit { return [expr {[pak::fval $expr value] ? 1 : 0}] }
            Ident {
                set n [pak::fval $expr name]
                if {[dict exists $consts $n]} { return [dict get $consts $n] }
                return ""
            }
            UnaryOp {
                set v [my eval_const_expr [pak::nfield $expr operand]]
                if {$v eq ""} { return "" }
                switch -- [pak::fval $expr op] { - { return [expr {-$v}] } ~ { return [expr {~$v}] } default { return "" } }
            }
            BinaryOp {
                set l [my eval_const_expr [pak::nfield $expr left]]
                set r [my eval_const_expr [pak::nfield $expr right]]
                if {$l eq "" || $r eq ""} { return "" }
                switch -- [pak::fval $expr op] {
                    +  { return [expr {$l + $r}] }
                    -  { return [expr {$l - $r}] }
                    *  { return [expr {$l * $r}] }
                    /  { if {$r == 0} { return "" }; return [expr {$l / $r}] }
                    default { return "" }
                }
            }
        }
        return ""
    }

    method emit_call {expr dst} {
        set func [pak::nfield $expr func]

        # module call: n64.mod.fn(args) — func = DotAccess(DotAccess, fn)
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "DotAccess"} {
            set mod [pak::fval [pak::nfield $func obj] field]
            set fn [pak::fval $func field]
            my emit_module_call $mod $fn [pak::nfield $expr args] $dst
            return
        }
        # DotAccess(Ident, field) — module call, variant ctor, or method call
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set obj_name [pak::fval [pak::nfield $func obj] name]
            set fn [pak::fval $func field]
            # Check if this is a module API call
            if {[dict exists $::pak::MIPS_API [list $obj_name $fn]]} {
                my emit_module_call $obj_name $fn [pak::nfield $expr args] $dst
                return
            }
            # Check if this is a variant constructor: Shape.circle(r)
            if {[dict exists $tenv_variant_decls $obj_name]} {
                my emit_variant_constructor $obj_name $fn [pak::nfield $expr args] $dst
                return
            }
            # CStr / Str / container built-in methods
            set receiver_type_node [my lookup_type_node $obj_name]
            if {![pak::isnil $receiver_type_node] && $receiver_type_node ne ""} {
                if {[pak::kindof $receiver_type_node] eq "TypeName"} {
                    set tnn [pak::fval $receiver_type_node name]
                    if {$tnn in {CStr c_char}} {
                        my emit_cstr_method $obj_name $fn [pak::nfield $expr args] $dst
                        return
                    }
                    if {$tnn in {Str PakStr}} {
                        my emit_pakstr_method $obj_name $fn [pak::nfield $expr args] $dst
                        return
                    }
                }
                if {[pak::kindof $receiver_type_node] eq "TypeGeneric"} {
                    set gn [pak::fval $receiver_type_node name]
                    if {$gn in {FixedList Pool RingBuffer FixedMap Vec}} {
                        my emit_container_method $obj_name $receiver_type_node $fn \
                            [pak::nfield $expr args] $dst
                        return
                    }
                }
            }
            # Method call: foo.method(args) → TypeName_method(&foo, args...)
            my emit_method_call $func [pak::nfield $expr args] $dst
            return
        }
        # EnumVariantAccess as func: .Circle(r) → variant constructor
        if {[pak::kindof $func] eq "EnumVariantAccess"} {
            set case_name [pak::fval $func name]
            set vname [my resolve_variant_name_for_case $case_name]
            if {$vname ne ""} {
                my emit_variant_constructor $vname $case_name [pak::nfield $expr args] $dst
                return
            }
        }
        if {[pak::kindof $func] eq "Ident"} {
            set fname [pak::fval $func name]
            # Variant constructor via bare name: Circle(r)
            set vname [my resolve_variant_name_for_case $fname]
            if {$vname ne ""} {
                my emit_variant_constructor $vname $fname [pak::nfield $expr args] $dst
                return
            }
            # Generic monomorphization: identity<i32>(42) -> identity__i32
            set type_args [pak::items [pak::nfield $expr type_args]]
            if {[llength $type_args] == 0} {
                set type_args [pak::items [pak::nfield $func type_args]]
            }
            if {[llength $type_args] > 0 && [dict exists $generic_fns $fname]} {
                set fname [my monomorphize $fname $type_args]
            }
            my marshal_args [pak::nfield $expr args]
            my emit_jal $fname
            if {$dst ne {$v0}} { $em move $dst {$v0} }
            return
        }
        # Indirect call: evaluate func into a temp and jalr
        my marshal_args [pak::nfield $expr args]
        set fptr [$ra alloc_temp]
        my emit_expr $func $fptr
        my emit_jalr_reg $fptr
        $ra free_temp $fptr
        if {$dst ne {$v0}} { $em move $dst {$v0} }
    }

    # ── generic monomorphization (port of _monomorphize / _subst_*) ───────────
    method monomorphize {generic_name type_args_items} {
        set arg_names {}
        foreach ta $type_args_items {
            if {[lindex $ta 0] eq "lit"} {
                lappend arg_names [lindex $ta 1]
            } elseif {[pak::kindof $ta] eq "TypeName"} {
                lappend arg_names [pak::fval $ta name]
            } else {
                lappend arg_names T
            }
        }
        set mangled "${generic_name}__[join $arg_names _]"
        if {[dict exists $mono_emitted $mangled]} { return $mangled }
        if {![dict exists $generic_fns $generic_name]} { return $generic_name }
        set template [dict get $generic_fns $generic_name]
        set subst [dict create]
        set tps [pak::items [pak::nfield $template type_params]]
        set i 0
        foreach tp $tps {
            if {$i < [llength $type_args_items]} {
                dict set subst [lindex $tp 1] [lindex $type_args_items $i]
            }
            incr i
        }
        set spec_params [my subst_params [pak::nfield $template params] $subst]
        dict set mono_emitted $mangled 1
        set saved [my save_fn_state]
        my emit_fn $mangled $spec_params [pak::nfield $template body]
        my restore_fn_state $saved
        return $mangled
    }

    method subst_type {type_node subst} {
        if {[pak::isnil $type_node]} { return $type_node }
        set k [pak::kindof $type_node]
        if {$k eq "TypeName"} {
            set nm [pak::fval $type_node name]
            if {[dict exists $subst $nm]} {
                set repl [dict get $subst $nm]
                if {[pak::kindof $repl] eq "TypeName"} { return $repl }
                if {[lindex $repl 0] eq "lit"} { return [pak::N TypeName name [lindex $repl 1]] }
                return [pak::N TypeName name $repl]
            }
            return $type_node
        }
        if {$k eq "TypePointer"} {
            return [pak::N TypePointer inner [my subst_type [pak::nfield $type_node inner] $subst] \
                nullable [pak::fval $type_node nullable] mutable [pak::fval $type_node mutable]]
        }
        if {$k eq "TypeSlice"} {
            return [pak::N TypeSlice inner [my subst_type [pak::nfield $type_node inner] $subst] \
                mutable [pak::fval $type_node mutable]]
        }
        if {$k eq "TypeArray"} {
            return [pak::N TypeArray size [pak::nfield $type_node size] \
                inner [my subst_type [pak::nfield $type_node inner] $subst]]
        }
        return $type_node
    }

    method subst_params {params_seq subst} {
        set out {}
        foreach p [pak::items $params_seq] {
            lappend out [pak::N Param name [pak::fval $p name] \
                type [my subst_type [pak::nfield $p type] $subst] \
                mutable [pak::fval $p mutable] \
                default_value [pak::nfield $p default_value]]
        }
        return [pak::Seq $out]
    }

    method monomorphize_struct {sname type_args} {
        set arg_names {}
        foreach ta $type_args {
            if {[lindex $ta 0] eq "lit"} {
                lappend arg_names [lindex $ta 1]
            } elseif {[pak::kindof $ta] eq "TypeName"} {
                lappend arg_names [pak::fval $ta name]
            } else {
                lappend arg_names T
            }
        }
        set mangled "${sname}__[join $arg_names _]"
        if {[dict exists $tenv_layouts $mangled]} { return $mangled }
        if {![dict exists $generic_structs $sname]} { return $sname }
        set template [dict get $generic_structs $sname]
        set subst [dict create]
        set tps [pak::items [pak::nfield $template type_params]]
        set i 0
        foreach tp $tps {
            if {$i < [llength $type_args]} {
                dict set subst [lindex $tp 1] [lindex $type_args $i]
            }
            incr i
        }
        set fields [dict create]
        set order {}
        set offset 0
        set max_align 1
        foreach sf [pak::items [pak::nfield $template fields]] {
            set concrete_type [my subst_type [pak::nfield $sf type] $subst]
            set fl [my mips_layout $concrete_type]
            set a [dict get $fl align]
            if {$a > $max_align} { set max_align $a }
            set offset [expr {($offset + $a - 1) & ~($a - 1)}]
            dict set fields [pak::fval $sf name] [dict create name [pak::fval $sf name] \
                offset $offset size [dict get $fl size] align $a type_node $concrete_type]
            lappend order [pak::fval $sf name]
            incr offset [dict get $fl size]
        }
        set total [expr {($offset + $max_align - 1) & ~($max_align - 1)}]
        if {$total == 0} { set total $max_align }
        set layout [dict create size $total align $max_align is_float 0 is_signed 1 is_ptr 0 \
            fields $fields field_order $order frac_bits 0]
        dict set tenv_layouts $mangled $layout
        return $mangled
    }

    # Save/restore all per-function state around a nested emit_fn (mono). The
    # outer ra is detached (set to "") so emit_fn won't destroy it.
    method save_fn_state {} {
        set s [dict create ra $ra scopes $scopes defers $defers \
            next_local $next_local ret_label $ret_label \
            loop_header $loop_header loop_exit $loop_exit \
            loop_defer_depth $loop_defer_depth loop_result $loop_result]
        set ra ""
        set loop_header {}
        set loop_exit {}
        set loop_defer_depth {}
        set loop_result {}
        return $s
    }
    method restore_fn_state {s} {
        if {$ra ne ""} { catch {$ra destroy} }
        set ra [dict get $s ra]
        set scopes [dict get $s scopes]
        set defers [dict get $s defers]
        set next_local [dict get $s next_local]
        set ret_label [dict get $s ret_label]
        set loop_header [dict get $s loop_header]
        set loop_exit [dict get $s loop_exit]
        set loop_defer_depth [dict get $s loop_defer_depth]
        set loop_result [dict get $s loop_result]
    }

    method emit_method_call {access args_seq dst} {
        # Determine type name from the variable's declared type node, then
        # from an embedded _type_name in its layout, then fall back to
        # capitalizing the variable name (last resort only).
        set type_name ""
        set obj [pak::nfield $access obj]
        if {[pak::kindof $obj] eq "Ident"} {
            set var_name [pak::fval $obj name]
            # Primary: use the stored type node (set by declare_local via LetDecl/params)
            set tn [my lookup_type_node $var_name]
            if {$tn ne "" && ![pak::isnil $tn]} {
                if {[pak::kindof $tn] eq "TypeName"} {
                    set type_name [pak::fval $tn name]
                } elseif {[pak::kindof $tn] eq "TypePointer"} {
                    set inner [pak::nfield $tn inner]
                    if {![pak::isnil $inner] && [pak::kindof $inner] eq "TypeName"} {
                        set type_name [pak::fval $inner name]
                    }
                }
            }
            # Secondary: layout-embedded _type_name
            if {$type_name eq ""} {
                set local [my lookup_local $var_name]
                if {$local ne ""} {
                    set layout [lindex $local 1]
                    if {[dict exists $layout _type_name]} {
                        set type_name [dict get $layout _type_name]
                    }
                }
            }
            # Tertiary: capitalize variable name (best-effort for single-char names)
            if {$type_name eq ""} {
                set type_name "[string toupper [string index $var_name 0]][string range $var_name 1 end]"
            }
        }
        set mangled "${type_name}_[pak::fval $access field]"

        # Compute &self as $a0
        set self_ptr [$ra alloc_temp]
        if {[pak::kindof $obj] eq "Ident"} {
            set local [my lookup_local [pak::fval $obj name]]
            if {$local ne ""} {
                $em addiu $self_ptr {$sp} [lindex $local 0]
            } else {
                $em la $self_ptr [pak::fval $obj name]
            }
        } else {
            set tmp [$ra alloc_temp]
            my emit_expr $obj $tmp
            set tmp_layout [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0 fields {}]
            set off [my declare_local __self $tmp_layout]
            $em sw $tmp $off {$sp}
            $ra free_temp $tmp
            $em addiu $self_ptr {$sp} $off
        }
        $em move {$a0} $self_ptr
        $ra free_temp $self_ptr

        my marshal_args $args_seq 1
        my emit_jal $mangled
        if {$dst ne {$v0}} { $em move $dst {$v0} }
    }

    method emit_module_call {mod fn args_seq dst} {
        my marshal_args $args_seq
        if {[dict exists $::pak::MIPS_API [list $mod $fn]]} {
            set sym [dict get $::pak::MIPS_API [list $mod $fn]]
        } else {
            set sym "${mod}_${fn}"
        }
        if {$sym eq ""} { set sym "${mod}_${fn}" }
        my emit_jal $sym
        if {$dst ne {$v0}} { $em move $dst {$v0} }
    }

    # ── CStr (const char *) built-in methods ────────────────────────────────
    method emit_cstr_method {var_name method args_seq dst} {
        set args [pak::items $args_seq]
        set local [my lookup_local $var_name]
        set str_r [$ra alloc_temp]
        if {$local ne ""} {
            $em lw $str_r [lindex $local 0] {$sp}
        } else {
            $em la $str_r $var_name
        }
        switch -- $method {
            len {
                $em move {$a0} $str_r
                my emit_jal strlen
                if {$dst ne {$v0}} { $em move $dst {$v0} }
            }
            is_empty {
                $em lb $dst 0 $str_r
                $em sltiu $dst $dst 1
            }
            contains {
                $em move {$a0} $str_r
                my marshal_args $args_seq 1
                my emit_jal strstr
                $em sltu $dst {$zero} {$v0}
                if {$dst ne {$v0}} { $em move $dst {$v0}; $em sltu $dst {$zero} $dst }
            }
            starts_with {
                set arg0_r [$ra alloc_temp]
                my emit_expr [lindex $args 0] $arg0_r
                # strlen(arg0) → a2
                $em move {$a0} $arg0_r
                my emit_jal strlen
                $em move {$a2} {$v0}
                $em move {$a0} $str_r
                $em move {$a1} $arg0_r
                my emit_jal strncmp
                $em seq $dst {$v0} {$zero}
                $ra free_temp $arg0_r
            }
            ends_with {
                set arg0_r [$ra alloc_temp]
                my emit_expr [lindex $args 0] $arg0_r
                # nlen = strlen(arg0)
                $em move {$a0} $arg0_r
                my emit_jal strlen
                set nlen_r [$ra alloc_temp]
                $em move $nlen_r {$v0}
                # slen = strlen(str)
                $em move {$a0} $str_r
                my emit_jal strlen
                set slen_r [$ra alloc_temp]
                $em move $slen_r {$v0}
                # end_ptr = str + slen - nlen
                set ep_r [$ra alloc_temp]
                $em addu $ep_r $str_r $slen_r
                $em subu $ep_r $ep_r $nlen_r
                $em move {$a0} $ep_r
                $em move {$a1} $arg0_r
                my emit_jal strcmp
                $em seq $dst {$v0} {$zero}
                $ra free_temp $arg0_r; $ra free_temp $nlen_r
                $ra free_temp $slen_r; $ra free_temp $ep_r
            }
            eq {
                $em move {$a0} $str_r
                my marshal_args $args_seq 1
                my emit_jal strcmp
                $em seq $dst {$v0} {$zero}
            }
            find {
                $em move {$a0} $str_r
                my marshal_args $args_seq 1
                my emit_jal strstr
                set lbl_found [my fresh_label .Lsf]
                set lbl_end   [my fresh_label .Lsfe]
                $em bne {$v0} {$zero} $lbl_found
                $em nop
                $em li $dst -1
                $em j $lbl_end
                $em nop
                $em label $lbl_found
                $em subu $dst {$v0} $str_r
                $em label $lbl_end
            }
            slice {
                set off_r [$ra alloc_temp]
                my emit_expr [lindex $args 0] $off_r
                $em addu $dst $str_r $off_r
                $ra free_temp $off_r
            }
            to_pakstr {
                set ps_off [my declare_local __ps [dict create size 8 align 4 is_float 0 is_signed 1 is_ptr 0 fields {} frac_bits 0]]
                $em sw $str_r $ps_off {$sp}
                $em move {$a0} $str_r
                my emit_jal strlen
                $em sw {$v0} [expr {$ps_off + 4}] {$sp}
                $em addiu $dst {$sp} $ps_off
            }
            default {
                $em move {$a0} $str_r
                my marshal_args $args_seq 1
                my emit_jal "cstr_${method}"
                if {$dst ne {$v0}} { $em move $dst {$v0} }
            }
        }
        $ra free_temp $str_r
    }

    # ── Str / PakStr fat-string built-in methods ──────────────────────────────
    method emit_pakstr_method {var_name method args_seq dst} {
        set local [my lookup_local $var_name]
        set base_off [lindex $local 0]
        set args [pak::items $args_seq]
        switch -- $method {
            len      { $em lw $dst [expr {$base_off + 4}] {$sp} }
            is_empty {
                set tmp [$ra alloc_temp]
                $em lw $tmp [expr {$base_off + 4}] {$sp}
                $em seq $dst $tmp {$zero}
                $ra free_temp $tmp
            }
            data     { $em lw $dst $base_off {$sp} }
            eq {
                # pak_str_eq(a, b): pass both PakStr {ptr,len} via $a0-$a3
                $em lw {$a0} $base_off {$sp}
                $em lw {$a1} [expr {$base_off + 4}] {$sp}
                set arg_r [$ra alloc_temp]
                my emit_expr [lindex $args 0] $arg_r
                $em lw {$a2} 0 $arg_r
                $em lw {$a3} 4 $arg_r
                $ra free_temp $arg_r
                my emit_jal pak_str_eq
                if {$dst ne {$v0}} { $em move $dst {$v0} }
            }
            default {
                $em lw {$a0} $base_off {$sp}
                $em lw {$a1} [expr {$base_off + 4}] {$sp}
                my marshal_args $args_seq 2
                my emit_jal "pak_str_${method}"
                if {$dst ne {$v0}} { $em move $dst {$v0} }
            }
        }
    }

    # ── Container (FixedList/Pool/RingBuffer/FixedMap/Vec) methods ────────────
    method emit_container_method {var_name type_node method args_seq dst} {
        set gname [pak::fval $type_node name]
        set layout [my mips_layout $type_node]
        set local [my lookup_local $var_name]
        set base_off [lindex $local 0]
        set args [pak::items $args_seq]

        if {$gname in {FixedList Pool}} {
            set esz     [dict get $layout _elem_size]
            set cap     [dict get $layout _cap]
            set len_fi  [dict get [dict get $layout fields] len]
            set len_off [expr {$base_off + [dict get $len_fi offset]}]
            switch -- $method {
                len {
                    $em lw $dst $len_off {$sp}
                }
                is_empty {
                    set tmp [$ra alloc_temp]
                    $em lw $tmp $len_off {$sp}
                    $em seq $dst $tmp {$zero}
                    $ra free_temp $tmp
                }
                is_full {
                    set tmp [$ra alloc_temp]
                    $em lw $tmp $len_off {$sp}
                    $em li $dst $cap
                    $em seq $dst $tmp $dst
                    $ra free_temp $tmp
                }
                push {
                    set lbl_skip [my fresh_label .Lpush]
                    set len_r [$ra alloc_temp]
                    $em lw $len_r $len_off {$sp}
                    set cap_r [$ra alloc_temp]
                    $em li $cap_r $cap
                    $em bge $len_r $cap_r $lbl_skip
                    $em nop
                    set item_r [$ra alloc_temp]
                    my emit_expr [lindex $args 0] $item_r
                    set addr_r [$ra alloc_temp]
                    $em li $addr_r $esz
                    $em mul $addr_r $len_r $addr_r
                    $em addiu $addr_r $addr_r $base_off
                    $em addu $addr_r {$sp} $addr_r
                    $em sw $item_r 0 $addr_r
                    $em addiu $len_r $len_r 1
                    $em sw $len_r $len_off {$sp}
                    $em li $dst 1
                    $ra free_temp $item_r; $ra free_temp $addr_r; $ra free_temp $cap_r
                    $em label $lbl_skip
                    $ra free_temp $len_r
                }
                pop {
                    set len_r [$ra alloc_temp]
                    $em lw $len_r $len_off {$sp}
                    $em addiu $len_r $len_r -1
                    $em sw $len_r $len_off {$sp}
                    set addr_r [$ra alloc_temp]
                    $em li $addr_r $esz
                    $em mul $addr_r $len_r $addr_r
                    $em addiu $addr_r $addr_r $base_off
                    $em addu $addr_r {$sp} $addr_r
                    $em lw $dst 0 $addr_r
                    $ra free_temp $len_r; $ra free_temp $addr_r
                }
                get {
                    set idx_r [$ra alloc_temp]
                    my emit_expr [lindex $args 0] $idx_r
                    set addr_r [$ra alloc_temp]
                    $em li $addr_r $esz
                    $em mul $addr_r $idx_r $addr_r
                    $em addiu $addr_r $addr_r $base_off
                    $em addu $addr_r {$sp} $addr_r
                    $em lw $dst 0 $addr_r
                    $ra free_temp $idx_r; $ra free_temp $addr_r
                }
                remove_at {
                    set len_r [$ra alloc_temp]
                    $em lw $len_r $len_off {$sp}
                    $em addiu $len_r $len_r -1
                    $em sw $len_r $len_off {$sp}
                    # src = data[len]
                    set src_r [$ra alloc_temp]
                    $em li $src_r $esz
                    $em mul $src_r $len_r $src_r
                    $em addiu $src_r $src_r $base_off
                    $em addu $src_r {$sp} $src_r
                    set val_r [$ra alloc_temp]
                    $em lw $val_r 0 $src_r
                    # dst_addr = data[i]
                    set idx_r [$ra alloc_temp]
                    my emit_expr [lindex $args 0] $idx_r
                    set dst_r [$ra alloc_temp]
                    $em li $dst_r $esz
                    $em mul $dst_r $idx_r $dst_r
                    $em addiu $dst_r $dst_r $base_off
                    $em addu $dst_r {$sp} $dst_r
                    $em sw $val_r 0 $dst_r
                    $em move $dst $val_r
                    $ra free_temp $len_r; $ra free_temp $src_r; $ra free_temp $val_r
                    $ra free_temp $idx_r; $ra free_temp $dst_r
                }
                acquire {
                    $em addiu {$a0} {$sp} $base_off
                    my emit_jal pak_pool_acquire
                    if {$dst ne {$v0}} { $em move $dst {$v0} }
                }
                release {
                    $em addiu {$a0} {$sp} $base_off
                    my marshal_args $args_seq 1
                    my emit_jal pak_pool_release
                }
                default {
                    $em addiu {$a0} {$sp} $base_off
                    my marshal_args $args_seq 1
                    my emit_jal "_PakList_${method}"
                    if {$dst ne {$v0}} { $em move $dst {$v0} }
                }
            }
            return
        }

        if {$gname eq "RingBuffer"} {
            set esz     [dict get $layout _elem_size]
            set cap     [dict get $layout _cap]
            set fields  [dict get $layout fields]
            set head_off [expr {$base_off + [dict get [dict get $fields head] offset]}]
            set tail_off [expr {$base_off + [dict get [dict get $fields tail] offset]}]
            set len_off  [expr {$base_off + [dict get [dict get $fields len]  offset]}]
            switch -- $method {
                len     { $em lw $dst $len_off {$sp} }
                is_empty {
                    set tmp [$ra alloc_temp]
                    $em lw $tmp $len_off {$sp}
                    $em seq $dst $tmp {$zero}
                    $ra free_temp $tmp
                }
                push {
                    set tail_r [$ra alloc_temp]
                    $em lw $tail_r $tail_off {$sp}
                    set item_r [$ra alloc_temp]
                    my emit_expr [lindex $args 0] $item_r
                    set addr_r [$ra alloc_temp]
                    $em li $addr_r $esz
                    $em mul $addr_r $tail_r $addr_r
                    $em addiu $addr_r $addr_r $base_off
                    $em addu $addr_r {$sp} $addr_r
                    $em sw $item_r 0 $addr_r
                    $em addiu $tail_r $tail_r 1
                    set cap_r [$ra alloc_temp]
                    $em li $cap_r $cap
                    $em div $tail_r $cap_r
                    $em mfhi $tail_r
                    $em sw $tail_r $tail_off {$sp}
                    set len_r [$ra alloc_temp]
                    $em lw $len_r $len_off {$sp}
                    set lbl_full [my fresh_label .Lrbf]
                    $em bge $len_r $cap_r $lbl_full
                    $em nop
                    $em addiu $len_r $len_r 1
                    $em sw $len_r $len_off {$sp}
                    $em label $lbl_full
                    $ra free_temp $tail_r; $ra free_temp $item_r
                    $ra free_temp $addr_r; $ra free_temp $cap_r; $ra free_temp $len_r
                }
                pop {
                    set head_r [$ra alloc_temp]
                    $em lw $head_r $head_off {$sp}
                    set addr_r [$ra alloc_temp]
                    $em li $addr_r $esz
                    $em mul $addr_r $head_r $addr_r
                    $em addiu $addr_r $addr_r $base_off
                    $em addu $addr_r {$sp} $addr_r
                    $em lw $dst 0 $addr_r
                    $em addiu $head_r $head_r 1
                    set cap_r [$ra alloc_temp]
                    $em li $cap_r $cap
                    $em div $head_r $cap_r
                    $em mfhi $head_r
                    $em sw $head_r $head_off {$sp}
                    set len_r [$ra alloc_temp]
                    $em lw $len_r $len_off {$sp}
                    set lbl_empty [my fresh_label .Lrbe]
                    $em beqz $len_r $lbl_empty
                    $em nop
                    $em addiu $len_r $len_r -1
                    $em sw $len_r $len_off {$sp}
                    $em label $lbl_empty
                    $ra free_temp $head_r; $ra free_temp $addr_r
                    $ra free_temp $cap_r;  $ra free_temp $len_r
                }
                peek {
                    set n_r [$ra alloc_temp]
                    if {[llength $args] > 0} { my emit_expr [lindex $args 0] $n_r } else { $em li $n_r 0 }
                    set tail_r [$ra alloc_temp]
                    $em lw $tail_r $tail_off {$sp}
                    set cap_r [$ra alloc_temp]
                    $em li $cap_r $cap
                    $em subu $tail_r $tail_r $n_r
                    $em addiu $tail_r $tail_r -1
                    $em addu $tail_r $tail_r $cap_r
                    $em div $tail_r $cap_r
                    $em mfhi $tail_r
                    set addr_r [$ra alloc_temp]
                    $em li $addr_r $esz
                    $em mul $addr_r $tail_r $addr_r
                    $em addiu $addr_r $addr_r $base_off
                    $em addu $addr_r {$sp} $addr_r
                    $em lw $dst 0 $addr_r
                    $ra free_temp $n_r; $ra free_temp $tail_r
                    $ra free_temp $cap_r; $ra free_temp $addr_r
                }
                default {
                    $em addiu {$a0} {$sp} $base_off
                    my marshal_args $args_seq 1
                    my emit_jal "_PakRBuf_${method}"
                    if {$dst ne {$v0}} { $em move $dst {$v0} }
                }
            }
            return
        }

        if {$gname eq "FixedMap"} {
            set cap    [dict get $layout _cap]
            set fields [dict get $layout fields]
            switch -- $method {
                set {
                    $em addiu {$a0} {$sp} $base_off
                    $em li {$a1} $cap
                    my marshal_args $args_seq 2
                    my emit_jal pak_map_set
                }
                get {
                    $em addiu {$a0} {$sp} $base_off
                    $em li {$a1} $cap
                    my marshal_args $args_seq 2
                    my emit_jal pak_map_get
                    if {$dst ne {$v0}} { $em move $dst {$v0} }
                }
                has {
                    $em addiu {$a0} {$sp} $base_off
                    $em li {$a1} $cap
                    my marshal_args $args_seq 2
                    my emit_jal pak_map_has
                    if {$dst ne {$v0}} { $em move $dst {$v0} }
                }
                remove {
                    $em addiu {$a0} {$sp} $base_off
                    $em li {$a1} $cap
                    my marshal_args $args_seq 2
                    my emit_jal pak_map_remove
                }
                len {
                    set lo [expr {$base_off + [dict get [dict get $fields len] offset]}]
                    $em lw $dst $lo {$sp}
                }
                default {
                    $em addiu {$a0} {$sp} $base_off
                    $em li {$a1} $cap
                    my marshal_args $args_seq 2
                    my emit_jal "pak_map_${method}"
                    if {$dst ne {$v0}} { $em move $dst {$v0} }
                }
            }
            return
        }

        if {$gname eq "Vec"} {
            switch -- $method {
                push {
                    $em addiu {$a0} {$sp} $base_off
                    my marshal_args $args_seq 1
                    my emit_jal _pak_vec_push
                }
                len {
                    $em lw $dst [expr {$base_off + 4}] {$sp}
                }
                is_empty {
                    set tmp [$ra alloc_temp]
                    $em lw $tmp [expr {$base_off + 4}] {$sp}
                    $em seq $dst $tmp {$zero}
                    $ra free_temp $tmp
                }
                default {
                    $em addiu {$a0} {$sp} $base_off
                    my marshal_args $args_seq 1
                    my emit_jal "_pak_vec_${method}"
                    if {$dst ne {$v0}} { $em move $dst {$v0} }
                }
            }
            return
        }
    }

    method marshal_args {args_seq {start_idx 0}} {
        set arglist [pak::items $args_seq]
        set n [llength $arglist]
        if {$n == 0} return
        # Count float args so each knows its float-index.
        set float_total 0
        foreach arg $arglist { if {[my infer_is_float $arg]} { incr float_total } }
        # Evaluate in REVERSE order to avoid save/reload patterns that the
        # VR4300 memory scheduler (which lacks alias analysis) would reorder.
        # After reverse evaluation:
        #   float 0 stays in $f12      (evaluated last, never overwritten)
        #   float 1 moved to $f14 via mov.s immediately after its eval
        #   float 2+ stored to sp+(N*4) outgoing arg area right after eval
        # Integer args use position-based slots; reverse order only affects
        # side-effect sequencing (pure-expression args are unaffected).
        set fi_counter $float_total
        for {set i [expr {$n - 1}]} {$i >= 0} {incr i -1} {
            set arg [lindex $arglist $i]
            set slot [expr {$i + $start_idx}]
            if {[my infer_is_float $arg]} {
                incr fi_counter -1
                set fi $fi_counter
                my emit_expr $arg {$zero}   ;# result in $f12
                if {$fi == 1} {
                    $em mov_s {$f14} {$f12}
                } elseif {$fi >= 2} {
                    $em swc1 {$f12} [expr {$fi * 4}] {$sp}
                }
                # fi==0: 1st float stays in $f12 (evaluated last, correct at call)
            } else {
                if {$slot < 4} {
                    my emit_expr $arg [lindex $::pak::ARG_GPRS $slot]
                } else {
                    set tmp [$ra alloc_temp]
                    my emit_expr $arg $tmp
                    $em sw $tmp [expr {($slot - 4) * 4 + 16}] {$sp}
                    $ra free_temp $tmp
                }
            }
        }
    }
}

proc pak::mips_generate {program} {
    set cg [pak::MipsCodegen new]
    set out [$cg generate $program]
    $cg destroy
    return $out
}

# Generate the structured record stream (for the binary encoder). Returns the
# same instruction/directive records that back the text output.
proc pak::mips_generate_records {program} {
    set cg [pak::MipsCodegen new]
    $cg generate $program
    set recs [$cg getrecords]
    $cg destroy
    return $recs
}
