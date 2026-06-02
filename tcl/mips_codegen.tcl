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

# ── Emitter — accumulates assembly lines (port of mips/emit.py) ─────────────────
oo::class create pak::Emitter {
    variable buf indent
    constructor {} { set buf {}; set indent "    " }
    method getvalue {} { return "[join $buf \n]\n" }
    method buf {} { return $buf }
    method setbuf {b} { set buf $b }
    method len {} { return [llength $buf] }
    method raw {line} { lappend buf $line }
    method instr {args} { lappend buf "$indent[join $args { }]" }
    method blank {} { lappend buf "" }
    method comment {t} { lappend buf "$indent# $t" }
    method label {name} { lappend buf "${name}:" }
    method section_text {}   { my raw "\t.section .text" }
    method section_data {}   { my raw "\t.section .data" }
    method section_rodata {} { my raw "\t.section .rodata" }
    method section_bss {}    { my raw "\t.section .bss" }
    method globl {s}     { my raw "\t.globl $s" }
    method type_func {s} { my raw "\t.type $s, @function" }
    method size_sym {s e} { my raw "\t.size $s, $e" }
    method align {n}     { my raw "\t.align $n" }
    method word {v}      { my raw "\t.word $v" }
    method half {v}      { my raw "\t.half $v" }
    method byte {v}      { my raw "\t.byte $v" }
    method space {n}     { my raw "\t.space $n" }
    method extern {s}    { my raw "\t.extern $s" }
    method asciiz {s} {
        set e [string map [list "\\" "\\\\" "\"" "\\\"" "\n" "\\n" "\r" "\\r" "\t" "\\t"] $s]
        my raw "\t.asciiz \"$e\""
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
    method sync {} { my instr "sync" }
    method verbatim {asm_text} {
        foreach line [split $asm_text "\n"] { lappend buf "$indent$line" }
    }
}

# ── Linear-scan register allocator (port of mips/registers.py RegAlloc) ─────────
# Temp pool is consumed from the END (pop) and returned by append, so the first
# borrowed temp is $t9 — this ordering is load-bearing for byte parity.
oo::class create pak::RegAlloc {
    variable free_temps free_saved used_saved promoted_saved
    constructor {} {
        set free_temps $::pak::CALLER_SAVED_GPRS
        set free_saved $::pak::CALLEE_SAVED_GPRS
        set used_saved {}
        set promoted_saved {}
    }
    method alloc_temp {} {
        if {[llength $free_temps] > 0} {
            set r [lindex $free_temps end]
            set free_temps [lrange $free_temps 0 end-1]
            return $r
        }
        if {[llength $free_saved] > 0} {
            set r [lindex $free_saved end]
            set free_saved [lrange $free_saved 0 end-1]
            if {$r ni $used_saved} { lappend used_saved $r }
            if {$r ni $promoted_saved} { lappend promoted_saved $r }
            return $r
        }
        return -code error "GPR temporary pool exhausted — need spilling logic"
    }
    method free_temp {r} {
        set i [lsearch -exact $promoted_saved $r]
        if {$i >= 0} {
            set promoted_saved [lreplace $promoted_saved $i $i]
            if {$r ni $free_saved} { lappend free_saved $r }
        } else {
            if {$r ni $free_temps} { lappend free_temps $r }
        }
    }
    method used_callee_gprs {} {
        return [lsort -command pak::gpr_cmp $used_saved]
    }
    method used_callee_fprs {} { return {} }
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

# ── Literal pool (port of mips/literals.py: strings + floats + static globals) ─────
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

# ── type layout (subset of mips/types.py) ──────────────────────────────────────
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
            pak::mips_unported "layout:option-nonptr"
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
    variable em pool ra ret_label scopes defers next_local loop_header loop_exit \
             globals consts label_n \
             tenv_layouts tenv_enum_values tenv_variant_decls \
             generic_fns mono_emitted

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
        set globals [dict create]
        set consts [dict create]
        set label_n 0
        set tenv_layouts [dict create]
        set tenv_enum_values [dict create]
        set tenv_variant_decls [dict create]
        set generic_fns [dict create]
        set mono_emitted [dict create]
    }
    destructor {
        $em destroy
        $pool destroy
        if {$ra ne ""} { catch {$ra destroy} }
    }

    # ── type environment (port of mips/types.py MipsTypeEnv) ─────────────────
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
                return [my mips_layout_name [pak::fval $type_tv name]]
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
    method declare_local {name layout} {
        set align [dict get $layout align]
        set next_local [expr {($next_local + $align - 1) & ~($align - 1)}]
        set off $next_local
        set next_local [expr {$next_local + [dict get $layout size]}]
        if {[llength $scopes] > 0} {
            set f [lindex $scopes end]; dict set f $name [list $off $layout]; lset scopes end $f
        }
        return $off
    }
    method lookup_local {name} {
        for {set i [expr {[llength $scopes]-1}]} {$i >= 0} {incr i -1} {
            set f [lindex $scopes $i]
            if {[dict exists $f $name]} { return [dict get $f $name] }
        }
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
        set ra [pak::RegAlloc new]
        set scopes {}
        set defers {}
        set next_local 16
        my push_scope
        # params: store $a0-$a3 into stack slots (BEFORE prologue, matching backend)
        set i 0
        foreach p [pak::items $params] {
            set p_layout [my mips_layout [pak::nfield $p type]]
            set off [my declare_local [pak::fval $p name] $p_layout]
            if {$i < 4} { my store_to_sp $off [lindex $::pak::ARG_GPRS $i] $p_layout }
            incr i
        }
        set frame_size 256
        set prologue_start [$em len]
        my emit_prologue_placeholder $frame_size
        set prologue_end [$em len]
        set ret_label [my fresh_label ".L${name}_ret"]
        my emit_block $body
        # Emit outer-scope (param) defers before patching prologue
        foreach d [my pop_scope] { my emit_stmt $d }
        my patch_prologue $frame_size $prologue_start $prologue_end
        $em label $ret_label
        my emit_epilogue $frame_size
        $em size_sym $name ". - $name"
    }

    method emit_prologue_placeholder {frame_size} {
        $em addiu {$sp} {$sp} -$frame_size
        $em sw {$ra} [expr {$frame_size - 4}] {$sp}
        $em sw {$fp} [expr {$frame_size - 8}] {$sp}
        $em addiu {$fp} {$sp} $frame_size
        $em raw "    # callee-saves-placeholder"
    }

    method patch_prologue {frame_size pstart pend} {
        set callee [$ra used_callee_gprs]
        set lines {}
        set i 0
        foreach reg $callee {
            lappend lines "    sw $reg, [expr {$frame_size - 12 - $i * 4}](\$sp)"
            incr i
        }
        set buf [$em buf]
        for {set idx $pstart} {$idx < $pend} {incr idx} {
            if {[string match "*callee-saves-placeholder*" [lindex $buf $idx]]} {
                set buf [concat [lrange $buf 0 [expr {$idx-1}]] $lines [lrange $buf [expr {$idx+1}] end]]
                break
            }
        }
        $em setbuf $buf
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
    method emit_typed_load {dst off base layout} {
        if {[dict get $layout is_float]} {
            if {[dict get $layout size] == 4} { $em lwc1 $dst $off $base } else { $em ldc1 $dst $off $base }
        } else {
            switch -- [dict get $layout size] {
                1 { if {[dict get $layout is_signed]} { $em lb $dst $off $base } else { $em lbu $dst $off $base } }
                2 { if {[dict get $layout is_signed]} { $em lh $dst $off $base } else { $em lhu $dst $off $base } }
                default { $em lw $dst $off $base }
            }
        }
    }
    method emit_typed_store {src off base layout} {
        if {[dict get $layout is_float]} {
            if {[dict get $layout size] == 4} { $em swc1 $src $off $base } else { $em sdc1 $src $off $base }
        } else {
            switch -- [dict get $layout size] {
                1 { $em sb $src $off $base }
                2 { $em sh $src $off $base }
                default { $em sw $src $off $base }
            }
        }
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
                set off [my declare_local [pak::fval $stmt name] $layout]
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} {
                    set lsz [dict get $layout size]
                    set lfields [expr {[dict exists $layout fields] ? [dict size [dict get $layout fields]] : 0}]
                    if {$lsz > 4 && $lfields > 0} {
                        # Large struct: expr returns a pointer; copy to stack slot
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
                if {[llength $loop_exit] > 0} { $em j [lindex $loop_exit end]; $em nop }
            }
            Continue {
                if {[llength $loop_header] > 0} { $em j [lindex $loop_header end]; $em nop }
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
            default    {}
        }
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
    }

    method emit_do_while {stmt} {
        set header [my fresh_label ".Ldow_h"]
        set exit_l [my fresh_label ".Ldow_x"]
        lappend loop_header $header; lappend loop_exit $exit_l
        $em label $header
        my emit_block [pak::nfield $stmt body]
        set cond [$ra alloc_temp]
        my emit_expr [pak::nfield $stmt condition] $cond
        $em bnez $cond $header
        $em nop
        $ra free_temp $cond
        $em label $exit_l
        set loop_header [lrange $loop_header 0 end-1]; set loop_exit [lrange $loop_exit 0 end-1]
    }

    method emit_loop {stmt} {
        set header [my fresh_label ".Lloop_h"]
        set exit_l [my fresh_label ".Lloop_x"]
        lappend loop_header $header; lappend loop_exit $exit_l
        $em label $header
        my emit_block [pak::nfield $stmt body]
        $em j $header
        $em nop
        $em label $exit_l
        set loop_header [lrange $loop_header 0 end-1]; set loop_exit [lrange $loop_exit 0 end-1]
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
        set exit_l [my fresh_label ".Lfor_x"]
        set counter_layout [my mips_layout_name i32]
        set counter_off [my declare_local [pak::fval $stmt binding] $counter_layout]
        set start_r [$ra alloc_temp]
        set end_r [$ra alloc_temp]
        my emit_expr [pak::nfield $it start] $start_r
        my store_to_sp $counter_off $start_r $counter_layout
        set end_tv [pak::nfield $it end]
        if {![pak::isnil $end_tv]} { my emit_expr $end_tv $end_r } else { $em li $end_r 2147483647 }
        lappend loop_header $header; lappend loop_exit $exit_l
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
    }

    # for item in slice — treat iterable as a fat pointer {ptr, len@+4}.
    method emit_for_each {stmt iterable} {
        set header [my fresh_label ".Lfeach_h"]
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

        lappend loop_header $header; lappend loop_exit $exit_l
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

        $em lw $idx_r $idx_off {$sp}
        $em addiu $idx_r $idx_r 1
        $em sw $idx_r $idx_off {$sp}
        $ra free_temp $len_r
        $ra free_temp $idx_r

        $em j $header
        $em nop
        $em label $exit_l
        set loop_header [lrange $loop_header 0 end-1]; set loop_exit [lrange $loop_exit 0 end-1]
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
                # Wildcard — always matches
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
                break
            } elseif {$pkind eq "EnumVariantAccess"} {
                # .CaseName — match enum integer value
                set case_val [my resolve_enum_case_value [pak::fval $pat name]]
                set case_r [$ra alloc_temp]
                $em li $case_r $case_val
                $em bne $val $case_r $skip_label
                $em nop
                $ra free_temp $case_r
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
                $em label $skip_label
            } elseif {$pkind eq "Call" && [pak::kindof [pak::nfield $pat func]] eq "EnumVariantAccess"} {
                # .VariantCase(binding) — variant tag + extract payload
                my emit_variant_arm $val $pat [pak::nfield $arm body] $skip_label $end_label
                $em label $skip_label
            } elseif {$pkind eq "IntLit"} {
                set case_r [$ra alloc_temp]
                $em li $case_r [pak::fval $pat value]
                $em bne $val $case_r $skip_label
                $em nop
                $ra free_temp $case_r
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
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
                $em label $skip_label
            } else {
                # Unknown pattern — always emit body
                my emit_block_or_stmt [pak::nfield $arm body]
                $em j $end_label
                $em nop
            }
        }

        $ra free_temp $val
        $em label $end_label
    }

    method emit_variant_arm {val_reg pat body skip_label end_label} {
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
        $em li {$t9} $tag_val
        $em bne $tag_r {$t9} $skip_label
        $em nop
        $ra free_temp $tag_r

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
                $em move $dst {$zero}
            }
            Ident     { my emit_ident_load [pak::fval $expr name] $dst }
            BinaryOp  { my emit_binop $expr $dst }
            UnaryOp   { my emit_unop $expr $dst }
            UndefinedLit { $em move $dst {$zero} }
            Deref {
                set ptr [$ra alloc_temp]
                my emit_expr [pak::nfield $expr expr] $ptr
                $em lw $dst 0 $ptr
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
                $em li {$t9} 1
                $em sb {$t9} $ok_off {$sp}
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
            RangeExpr {
                my emit_expr [pak::nfield $expr start] $dst
            }
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
                $em jal __pak_alloc
                $em nop
                $em move $dst {$v0}
            }
            FreeExpr {
                set ptr [$ra alloc_temp]
                my emit_expr [pak::nfield $expr ptr] $ptr
                $em move {$a0} $ptr
                $ra free_temp $ptr
                $em jal __pak_free
                $em nop
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
            default   { $em move $dst {$zero} }
        }
    }

    method emit_field_access {expr dst} {
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
            $em jal memset
            $em nop
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
        $em la {$t9} $name
        $em lw $dst 0 {$t9}
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
            # int → float: convert in $f12, GPR result gets 0 (matches Python)
            $em mtc1 $src {$f12}
            $em cvt_s_w {$f12} {$f12}
            $em move $dst {$zero}
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
            $em jal __pak_fix16_div
            $em nop
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
            $em jal memcpy
            $em nop
        }
    }

    method emit_binop {expr dst} {
        set op [pak::fval $expr op]
        set frac [my infer_frac_bits [pak::nfield $expr left]]
        if {$frac == 0} { set frac [my infer_frac_bits [pak::nfield $expr right]] }
        set lhs [$ra alloc_temp]
        set rhs [$ra alloc_temp]
        my emit_expr [pak::nfield $expr left] $lhs
        my emit_expr [pak::nfield $expr right] $rhs
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
            default { $em addu $dst $lhs $rhs }
        }
        $ra free_temp $rhs
        $ra free_temp $lhs
    }

    method emit_unop {expr dst} {
        set operand [$ra alloc_temp]
        my emit_expr [pak::nfield $expr operand] $operand
        switch -- [pak::fval $expr op] {
            -  { $em subu $dst {$zero} $operand }
            !  { $em sltiu $dst $operand 1 }
            ~  { $em not_ $dst $operand }
            default { pak::mips_unported "unop:[pak::fval $expr op]" }
        }
        $ra free_temp $operand
    }

    method emit_assign_target {target val_reg op} {
        if {$op ne "="} {
            set cur [$ra alloc_temp]
            if {[pak::kindof $target] eq "Ident"} {
                my emit_ident_load [pak::fval $target name] $cur
            } else {
                $em la {$t9} __cur
                $em lw $cur 0 {$t9}
            }
            switch -- $op {
                +=  { $em addu $val_reg $cur $val_reg }
                -=  { $em subu $val_reg $cur $val_reg }
                *=  { $em mul $val_reg $cur $val_reg }
                &=  { $em and_ $val_reg $cur $val_reg }
                |=  { $em or_ $val_reg $cur $val_reg }
                ^=  { $em xor $val_reg $cur $val_reg }
                default {}
            }
            $ra free_temp $cur
        }
        switch -- [pak::kindof $target] {
            Ident {
                set local [my lookup_local [pak::fval $target name]]
                if {$local ne ""} {
                    my store_to_sp [lindex $local 0] $val_reg [lindex $local 1]
                } else {
                    $em la {$t9} [pak::fval $target name]
                    $em sw $val_reg 0 {$t9}
                }
            }
            Deref {
                set ptr [$ra alloc_temp]
                my emit_expr [pak::nfield $target expr] $ptr
                $em sw $val_reg 0 $ptr
                $ra free_temp $ptr
            }
            IndexAccess { my emit_index_store $target $val_reg }
            DotAccess   { my emit_field_store $target $val_reg }
            default {}
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
            $em jal $fname
            $em nop
            if {$dst ne {$v0}} { $em move $dst {$v0} }
            return
        }
        # Indirect call: evaluate func into a temp and jalr
        my marshal_args [pak::nfield $expr args]
        set fptr [$ra alloc_temp]
        my emit_expr $func $fptr
        $em jalr $fptr
        $em nop
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

    # Save/restore all per-function state around a nested emit_fn (mono). The
    # outer ra is detached (set to "") so emit_fn won't destroy it.
    method save_fn_state {} {
        set s [dict create ra $ra scopes $scopes defers $defers \
            next_local $next_local ret_label $ret_label \
            loop_header $loop_header loop_exit $loop_exit]
        set ra ""
        set loop_header {}
        set loop_exit {}
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
    }

    method emit_method_call {access args_seq dst} {
        # Determine type name from the variable, fallback to capitalize
        set type_name ""
        set obj [pak::nfield $access obj]
        if {[pak::kindof $obj] eq "Ident"} {
            set local [my lookup_local [pak::fval $obj name]]
            if {$local ne ""} {
                set layout [lindex $local 1]
                # Check for embedded type name
                if {[dict exists $layout _type_name]} {
                    set type_name [dict get $layout _type_name]
                }
            }
            if {$type_name eq ""} {
                # Capitalize fallback
                set n [pak::fval $obj name]
                set type_name "[string toupper [string index $n 0]][string range $n 1 end]"
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
        $em jal $mangled
        $em nop
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
        $em jal $sym
        $em nop
        if {$dst ne {$v0}} { $em move $dst {$v0} }
    }

    method marshal_args {args_seq {start_idx 0}} {
        set arglist [pak::items $args_seq]
        set i 0
        foreach arg $arglist {
            set slot [expr {$i + $start_idx}]
            if {$slot < 4} {
                my emit_expr $arg [lindex $::pak::ARG_GPRS $slot]
            } else {
                set tmp [$ra alloc_temp]
                my emit_expr $arg $tmp
                $em sw $tmp [expr {($slot - 4) * 4 + 16}] {$sp}
                $ra free_temp $tmp
            }
            incr i
        }
    }
}

proc pak::mips_generate {program} {
    set cg [pak::MipsCodegen new]
    set out [$cg generate $program]
    $cg destroy
    return $out
}
