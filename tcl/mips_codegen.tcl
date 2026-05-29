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
    # comparison (pseudo)
    method slt {d s1 s2}  { my instr "slt" "$d," "$s1," $s2 }
    method sle {d s1 s2}  { my instr "sle" "$d," "$s1," $s2 }
    method sgt {d s1 s2}  { my instr "sgt" "$d," "$s1," $s2 }
    method sge {d s1 s2}  { my instr "sge" "$d," "$s1," $s2 }
    method seq {d s1 s2}  { my instr "seq" "$d," "$s1," $s2 }
    method sne {d s1 s2}  { my instr "sne" "$d," "$s1," $s2 }
    # branches
    method beqz {r lbl}   { my instr "beqz" "$r," $lbl }
    method bnez {r lbl}   { my instr "bnez" "$r," $lbl }
    method bge {s1 s2 lbl} { my instr "bge" "$s1," "$s2," $lbl }
    # typed loads / stores
    method lh {d off base}  { my instr "lh" "$d," "${off}($base)" }
    method lhu {d off base} { my instr "lhu" "$d," "${off}($base)" }
    method lb {d off base}  { my instr "lb" "$d," "${off}($base)" }
    method lbu {d off base} { my instr "lbu" "$d," "${off}($base)" }
    method sh {s off base}  { my instr "sh" "$s," "${off}($base)" }
    method sb {s off base}  { my instr "sb" "$s," "${off}($base)" }
    method lwc1 {d off base} { my instr "lwc1" "$d," "${off}($base)" }
    method swc1 {s off base} { my instr "swc1" "$s," "${off}($base)" }
    method sync {} { my instr "sync" }
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

# ── Literal pool (port of mips/literals.py: strings + static globals) ───────────
oo::class create pak::LiteralPool {
    variable strings counter order data_syms
    constructor {} { set strings [dict create]; set counter 0; set order {}; set data_syms {} }
    method intern_string {value} {
        if {![dict exists $strings $value]} {
            dict set strings $value ".Lstr$counter"
            lappend order $value
            incr counter
        }
        return [dict get $strings $value]
    }
    # init_value "" means uninitialized (.bss); otherwise an integer for .data.
    method add_static {name size align init_value} {
        lappend data_syms [list $name $size $align $init_value]
    }
    method has_content {} { return [expr {[dict size $strings] > 0}] }
    method emit_rodata {em} {
        if {![my has_content]} return
        $em blank
        $em section_rodata
        foreach value $order {
            $em align 0
            $em label [dict get $strings $value]
            $em asciiz $value
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
# Returns a dict: size align is_float is_signed is_ptr. Raises for types not yet
# handled (structs/enums/variants/slices/arrays) so unsupported files stay UNPORTED.
proc pak::mips_layout {type_tv} {
    if {[pak::isnil $type_tv]} { return [dict create size 0 align 1 is_float 0 is_signed 1 is_ptr 0] }
    switch -- [pak::kindof $type_tv] {
        TypeName {
            set n [pak::fval $type_tv name]
            if {[dict exists $::pak::MIPS_PRIM $n]} {
                lassign [dict get $::pak::MIPS_PRIM $n] sz al fl sg
                return [dict create size $sz align $al is_float $fl is_signed $sg is_ptr 0]
            }
            pak::mips_unported "layout:$n"
        }
        TypePointer { return [dict create size 4 align 4 is_float 0 is_signed 0 is_ptr 1] }
        default { pak::mips_unported "layout:[pak::kindof $type_tv]" }
    }
}
proc pak::mips_layout_name {n} { return [pak::mips_layout [pak::N TypeName name $n]] }

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
    variable em pool ra ret_label scopes next_local loop_header loop_exit \
             globals consts label_n

    constructor {} {
        set em [pak::Emitter new]
        set pool [pak::LiteralPool new]
        set ra ""
        set ret_label ""
        set scopes {}
        set next_local 16
        set loop_header {}
        set loop_exit {}
        set globals [dict create]
        set consts [dict create]
        set label_n 0
    }
    destructor {
        $em destroy
        $pool destroy
        if {$ra ne ""} { catch {$ra destroy} }
    }

    # ── label / scope / locals (port of FnCtx) ─────────────────────────────────
    method fresh_label {prefix} { set n $label_n; incr label_n; return "${prefix}_${n}" }
    method push_scope {} { lappend scopes [dict create] }
    method pop_scope {}  { set scopes [lrange $scopes 0 end-1] }
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
                    pak::mips_unported "generic-fn"
                }
                my emit_fn [pak::fval $decl name] [pak::nfield $decl params] [pak::nfield $decl body]
            }
            EntryBlock {
                my emit_fn main [pak::Seq {}] [pak::nfield $decl body]
            }
            StructDecl - EnumDecl - VariantDecl - UnionDecl - TraitDecl - UseDecl - ExternBlock - ModuleDecl - ExternConst {}
            ConstDecl   { my collect_const $decl }
            StaticDecl  { my emit_static $decl }
            ImplBlock - ImplTraitBlock { pak::mips_unported "impl/trait" }
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
        if {![pak::isnil $typ]} { set layout [pak::mips_layout $typ] } else { set layout [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0] }
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
        set next_local 16
        my push_scope
        # params: store $a0-$a3 into stack slots (BEFORE prologue, matching backend)
        set i 0
        foreach p [pak::items $params] {
            set p_layout [pak::mips_layout [pak::nfield $p type]]
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
            $em lwc1 $dst $off $base
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
            $em swc1 $src $off $base
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
        my pop_scope
    }

    method emit_stmt {stmt} {
        switch -- [pak::kindof $stmt] {
            LetDecl {
                set typ [pak::nfield $stmt type]
                if {![pak::isnil $typ]} { set layout [pak::mips_layout $typ] } else { set layout [dict create size 4 align 4 is_float 0 is_signed 1 is_ptr 0] }
                set off [my declare_local [pak::fval $stmt name] $layout]
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} {
                    if {[dict get $layout size] > 4} { pak::mips_unported "let:large" }
                    set tmp [$ra alloc_temp]
                    my emit_expr $v $tmp
                    my store_to_sp $off $tmp $layout
                    $ra free_temp $tmp
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
            Break {
                if {[llength $loop_exit] > 0} { $em j [lindex $loop_exit end]; $em nop }
            }
            Continue {
                if {[llength $loop_header] > 0} { $em j [lindex $loop_header end]; $em nop }
            }
            ExprStmt {
                set tmp [$ra alloc_temp]
                my emit_expr [pak::nfield $stmt expr] $tmp
                $ra free_temp $tmp
            }
            Block      { my emit_block $stmt }
            GotoStmt   { $em j [pak::fval $stmt label]; $em nop }
            LabelStmt  { $em label [pak::fval $stmt name] }
            DeferStmt  { pak::mips_unported "stmt:defer" }
            default    { pak::mips_unported "stmt:[pak::kindof $stmt]" }
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
        if {[pak::kindof $it] ne "RangeExpr"} { pak::mips_unported "for:each" }
        set header [my fresh_label ".Lfor_h"]
        set exit_l [my fresh_label ".Lfor_x"]
        set counter_layout [pak::mips_layout_name i32]
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
            set idx_layout [pak::mips_layout_name i32]
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

    method emit_expr {expr dst} {
        switch -- [pak::kindof $expr] {
            IntLit    { $em li $dst [pak::fval $expr value] }
            BoolLit   { $em li $dst [expr {[pak::fval $expr value] ? 1 : 0}] }
            NoneLit   { $em move $dst {$zero} }
            StringLit { $em la $dst [$pool intern_string [pak::fval $expr value]] }
            Ident     { my emit_ident_load [pak::fval $expr name] $dst }
            BinaryOp  { my emit_binop $expr $dst }
            UnaryOp   { my emit_unop $expr $dst }
            Assign {
                set val [$ra alloc_temp]
                my emit_expr [pak::nfield $expr value] $val
                my emit_assign_target [pak::nfield $expr target] $val [pak::fval $expr op]
                $em move $dst $val
                $ra free_temp $val
            }
            Call      { my emit_call $expr $dst }
            default   { pak::mips_unported "expr:[pak::kindof $expr]" }
        }
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

    method emit_binop {expr dst} {
        set op [pak::fval $expr op]
        set lhs [$ra alloc_temp]
        set rhs [$ra alloc_temp]
        my emit_expr [pak::nfield $expr left] $lhs
        my emit_expr [pak::nfield $expr right] $rhs
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
            default { pak::mips_unported "binop:$op" }
        }
        $ra free_temp $rhs
        $ra free_temp $lhs
    }

    method emit_unop {expr dst} {
        set operand [$ra alloc_temp]
        my emit_expr [pak::nfield $expr operand] $operand
        switch -- [pak::fval $expr op] {
            -  { $em subu $dst {$zero} $operand }
            ~  { $em not_ $dst $operand }
            default { pak::mips_unported "unop:[pak::fval $expr op]" }
        }
        $ra free_temp $operand
    }

    method emit_assign_target {target val_reg op} {
        if {$op ne "="} {
            set cur [$ra alloc_temp]
            if {[pak::kindof $target] eq "Ident"} { my emit_ident_load [pak::fval $target name] $cur } else { pak::mips_unported "compound-assign-target" }
            switch -- $op {
                +=  { $em addu $val_reg $cur $val_reg }
                -=  { $em subu $val_reg $cur $val_reg }
                *=  { $em mul $val_reg $cur $val_reg }
                &=  { $em and_ $val_reg $cur $val_reg }
                |=  { $em or_ $val_reg $cur $val_reg }
                ^=  { $em xor $val_reg $cur $val_reg }
                default { pak::mips_unported "compound-op:$op" }
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
        # module call: mod.fn(args) — func = DotAccess(Ident mod, fn)
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set mod [pak::fval [pak::nfield $func obj] name]
            set fn [pak::fval $func field]
            if {[dict exists $::pak::MIPS_API [list $mod $fn]]} {
                my emit_module_call $mod $fn [pak::nfield $expr args] $dst
                return
            }
            # variant ctor / method call on a typed receiver: not yet ported
            pak::mips_unported "call:method-or-dot"
        }
        if {[pak::kindof $func] ne "Ident"} { pak::mips_unported "call:indirect" }
        # direct call to a user function
        my marshal_args [pak::nfield $expr args]
        $em jal [pak::fval $func name]
        $em nop
        if {$dst ne {$v0}} { $em move $dst {$v0} }
    }

    method emit_module_call {mod fn args_seq dst} {
        my marshal_args $args_seq
        set sym [dict get $::pak::MIPS_API [list $mod $fn]]
        if {$sym eq ""} { set sym "${mod}_${fn}" }
        $em jal $sym
        $em nop
        if {$dst ne {$v0}} { $em move $dst {$v0} }
    }

    method marshal_args {args_seq} {
        set arglist [pak::items $args_seq]
        set i 0
        foreach arg $arglist {
            if {$i < 4} {
                my emit_expr $arg [lindex $::pak::ARG_GPRS $i]
            } else {
                pak::mips_unported "marshal:stack-arg"
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
