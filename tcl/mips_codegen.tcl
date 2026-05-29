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

# ── String literal pool (port of mips/literals.py, strings only for now) ────────
oo::class create pak::LiteralPool {
    variable strings counter order
    constructor {} { set strings [dict create]; set counter 0; set order {} }
    method intern_string {value} {
        if {![dict exists $strings $value]} {
            dict set strings $value ".Lstr$counter"
            lappend order $value
            incr counter
        }
        return [dict get $strings $value]
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
}

# ── orchestrator ────────────────────────────────────────────────────────────
oo::class create pak::MipsCodegen {
    variable em pool ra ret_label locals next_off

    constructor {} {
        set em [pak::Emitter new]
        set pool [pak::LiteralPool new]
        set ra ""
        set ret_label ""
        set locals [dict create]
        set next_off 0
    }
    destructor {
        $em destroy
        $pool destroy
        if {$ra ne ""} { catch {$ra destroy} }
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
            ConstDecl   { pak::mips_unported "const" }
            StaticDecl  { pak::mips_unported "static" }
            ImplBlock - ImplTraitBlock { pak::mips_unported "impl/trait" }
            AssetDecl   { $em extern [pak::fval $decl name] }
            CfgBlock    { my emit_top_decl [pak::nfield $decl decl] }
            default     { pak::mips_unported "decl:[pak::kindof $decl]" }
        }
    }

    method emit_fn {name params body} {
        if {[pak::isnil $body]} return
        $em blank
        $em section_text
        $em globl $name
        $em type_func $name
        $em label $name
        # fresh per-function allocator + locals
        if {$ra ne ""} { catch {$ra destroy} }
        set ra [pak::RegAlloc new]
        set locals [dict create]
        set next_off 0
        # params: only the no-param case is ported so far
        if {[llength [pak::items $params]] > 0} { pak::mips_unported "fn-params" }
        set frame_size 256
        set prologue_start [$em len]
        my emit_prologue_placeholder $frame_size
        set prologue_end [$em len]
        set ret_label ".L${name}_ret_0"
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

    method emit_block {block} {
        foreach stmt [pak::items [pak::nfield $block stmts]] { my emit_stmt $stmt }
    }

    method emit_stmt {stmt} {
        switch -- [pak::kindof $stmt] {
            ExprStmt {
                set tmp [$ra alloc_temp]
                my emit_expr [pak::nfield $stmt expr] $tmp
                $ra free_temp $tmp
            }
            Return {
                set v [pak::nfield $stmt value]
                if {![pak::isnil $v]} { my emit_expr $v {$v0} }
                $em j $ret_label
                $em nop
            }
            default { pak::mips_unported "stmt:[pak::kindof $stmt]" }
        }
    }

    method emit_expr {expr dst} {
        switch -- [pak::kindof $expr] {
            IntLit    { $em li $dst [pak::fval $expr value] }
            BoolLit   { $em li $dst [expr {[pak::fval $expr value] ? 1 : 0}] }
            NoneLit   { $em move $dst {$zero} }
            StringLit { $em la $dst [$pool intern_string [pak::fval $expr value]] }
            Call      { my emit_call $expr $dst }
            default   { pak::mips_unported "expr:[pak::kindof $expr]" }
        }
    }

    method emit_call {expr dst} {
        set func [pak::nfield $expr func]
        # module call: mod.fn(args)  where func = DotAccess(Ident mod, fn)
        if {[pak::kindof $func] eq "DotAccess" && [pak::kindof [pak::nfield $func obj]] eq "Ident"} {
            set mod [pak::fval [pak::nfield $func obj] name]
            set fn [pak::fval $func field]
            if {[dict exists $::pak::MIPS_API [list $mod $fn]]} {
                my emit_module_call $mod $fn [pak::nfield $expr args] $dst
                return
            }
        }
        pak::mips_unported "call"
    }

    method emit_module_call {mod fn args dst} {
        my marshal_args $args
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
