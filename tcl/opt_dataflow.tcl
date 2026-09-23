# tcl/opt_dataflow.tcl — copy/constant propagation and dead-instruction
# removal over the MIPS backend's records, one function at a time.
#
# The codegen routes every value through a scratch register and then copies
# it where it belongs (`li $t9, 0` / `move $s0, $t9`), reads a register-
# promoted local by copying it first (`move $t7, $s0` / `sll $t7, $t7, 2`),
# and materializes small constants that an immediate form could have carried
# (`li $t9, 1` / `addu $t9, $t8, $t9`). Two passes clean that up:
#
#   propagate  forward, per basic block: a read of a register that is a copy
#              of another reads the original; a read of a register holding a
#              known 16-bit constant turns the instruction into its immediate
#              form where one exists.
#   dce        backward liveness over the function's control-flow graph; a
#              side-effect-free instruction whose result nothing reads is
#              deleted. Loads are never deleted (a volatile read of a hardware
#              register can have side effects the records do not show).
#
# Runs before scheduling and delay-slot filling, but does not assume delay
# slots are empty: the instruction after a branch is in the branch's block,
# and after a jal it executes before the call.
#
# A function is left exactly as emitted when it contains anything this model
# does not understand: inline assembly, a jump through a register other than
# $ra, or an unknown mnemonic.

namespace eval pak::opt::df {}

set ::pak::opt::df::GPR_RE {^\$(zero|at|v[01]|a[0-3]|t[0-9]|s[0-7]|k[01]|gp|sp|fp|ra)$}
set ::pak::opt::df::MEM_RE {^(-?[0-9A-Za-z_.+-]*)\((\$[a-z0-9]+)\)$}

set ::pak::opt::df::A3  {addu subu and or xor nor slt sltu sllv srlv srav mul seq sne sgt sgtu sge sgeu sle sleu}
set ::pak::opt::df::A2  {addiu andi ori xori slti sltiu sll srl sra move not negu}
set ::pak::opt::df::D1  {li la lui}
set ::pak::opt::df::LD  {lw lh lhu lb lbu}
set ::pak::opt::df::ST  {sw sh sb}
set ::pak::opt::df::FMEM {lwc1 ldc1 swc1 sdc1}
set ::pak::opt::df::MD  {mult multu div divu}
set ::pak::opt::df::BR  {beq bne beqz bnez bltz bgez blez bgtz bge bgt ble blt bgeu bgtu bleu bltu}
set ::pak::opt::df::NOGPR {nop sync j bc1t bc1f
    add.s sub.s mul.s div.s mov.s neg.s abs.s sqrt.s
    add.d sub.d mul.d div.d mov.d neg.d abs.d sqrt.d
    cvt.s.w cvt.w.s cvt.d.w cvt.w.d cvt.s.d cvt.d.s trunc.w.s
    c.eq.s c.lt.s c.le.s c.eq.d c.lt.d c.le.d}
# Deletable when every register they write is dead. `mul` is not: it also
# writes LO, and `mult`/`div` write nothing a GPR liveness can see.
set ::pak::opt::df::PURE {addu subu and or xor nor slt sltu sllv srlv srav
    seq sne sgt sgtu sge sgeu sle sleu addiu andi ori xori slti sltiu sll srl sra
    move not negu li la lui mflo mfhi mfc1}

set ::pak::opt::df::ARGS    {{$a0} {$a1} {$a2} {$a3}}
set ::pak::opt::df::CLOBBER {{$at} {$v0} {$v1} {$a0} {$a1} {$a2} {$a3}
    {$t0} {$t1} {$t2} {$t3} {$t4} {$t5} {$t6} {$t7} {$t8} {$t9} {$ra}}
set ::pak::opt::df::EXIT_LIVE {{$v0} {$v1} {$sp} {$fp} {$ra} {$gp}
    {$s0} {$s1} {$s2} {$s3} {$s4} {$s5} {$s6} {$s7}}
set ::pak::opt::df::ALL {{$at} {$v0} {$v1} {$a0} {$a1} {$a2} {$a3}
    {$t0} {$t1} {$t2} {$t3} {$t4} {$t5} {$t6} {$t7} {$t8} {$t9}
    {$s0} {$s1} {$s2} {$s3} {$s4} {$s5} {$s6} {$s7} {$k0} {$k1}
    {$gp} {$sp} {$fp} {$ra}}

proc pak::opt::df::is_gpr {t} { regexp $::pak::opt::df::GPR_RE $t }

# Positions (operand indexes) a mnemonic reads as a whole GPR, and whether
# operand 1's memory base is read. Returns {kind use_positions base_pos} or
# {kind} for the special kinds.
proc pak::opt::df::shape {op ops} {
    variable A3; variable A2; variable D1; variable LD; variable ST
    variable FMEM; variable MD; variable BR; variable NOGPR
    if {$op in $A3}    { return {alu {1 2} {}} }
    if {$op in $A2}    { return {alu {1} {}} }
    if {$op in $D1}    { return {alu {} {}} }
    if {$op in {mflo mfhi mfc1}} { return {alu {} {}} }
    if {$op in $LD}    { return {load {} 1} }
    if {$op in $ST}    { return {store {0} 1} }
    if {$op in $FMEM}  { return {fmem {} 1} }
    if {$op eq "mtc1"} { return {use {0} {}} }
    if {$op eq "cache"} { return {use {} 1} }
    if {$op in $MD} {
        set pos {}
        for {set i 0} {$i < [llength $ops]} {incr i} { lappend pos $i }
        return [list use $pos {}]
    }
    if {$op in $BR} {
        set pos {}
        for {set i 0} {$i < [llength $ops] - 1} {incr i} { lappend pos $i }
        return [list branch $pos {}]
    }
    if {$op in $NOGPR} {
        if {$op eq "j"} { return {jump {} {}} }
        if {$op in {bc1t bc1f}} { return {branch {} {}} }
        return {use {} {}}
    }
    if {$op eq "jal"}  { return {call {} {}} }
    if {$op eq "jalr"} { return {call {} {}} }
    if {$op eq "jr"}   { return {ret {} {}} }
    return {unknown}
}

# {defs uses} for one instruction, GPRs only. Calls and returns are handled by
# the callers, which know where the delay slot is.
proc pak::opt::df::defuse {op ops} {
    lassign [shape $op $ops] kind pos base
    set uses {}
    foreach p $pos {
        set t [lindex $ops $p]
        if {[is_gpr $t] && $t ne {$zero}} { lappend uses $t }
    }
    if {$base ne ""} {
        if {[regexp $::pak::opt::df::MEM_RE [lindex $ops $base] -> _ b]} {
            if {$b ne {$zero}} { lappend uses $b }
        }
    }
    set defs {}
    if {$kind in {alu load}} {
        set d [lindex $ops 0]
        if {[is_gpr $d] && $d ne {$zero}} { lappend defs $d }
    }
    return [list $defs $uses]
}

# Split the record stream into functions: a function starts at a label that
# is not local (.L*) and runs to the next such label. Directives and data
# between functions stay where they are.
proc pak::opt::df::run {recs} {
    set out {}
    set cur {}
    foreach r $recs {
        if {[lindex $r 0] eq "label" && ![string match .L* [lindex $r 1]]} {
            if {[llength $cur]} { lappend out {*}[optimize_fn $cur] }
            set cur {}
        }
        lappend cur $r
    }
    if {[llength $cur]} { lappend out {*}[optimize_fn $cur] }
    return $out
}

proc pak::opt::df::optimize_fn {recs} {
    # Bisection hook: set DEBUG_FILTER to a command prefix that takes a function
    # name and returns 0 to leave that function as emitted. A miscompile that
    # only shows on hardware was found by halving the optimized set this way.
    if {[info exists ::pak::opt::df::DEBUG_FILTER]} {
        if {![{*}$::pak::opt::df::DEBUG_FILTER [lindex $recs 0 1]]} { return $recs }
    }
    # Only code: a chunk that is data (a .word table, a string) has no
    # instructions and passes through.
    set labels [dict create]
    set has_instr 0
    foreach r $recs {
        switch -- [lindex $r 0] {
            label { dict set labels [lindex $r 1] 1 }
            i {
                set has_instr 1
                set op [lindex $r 1]
                set ops [lrange $r 2 end]
                set k [lindex [shape $op $ops] 0]
                if {$k eq "unknown"} { return $recs }
                if {$k eq "ret" && [lindex $ops 0] ne {$ra}} { return $recs }
            }
            verbatim - placeholder { return $recs }
        }
    }
    if {!$has_instr} { return $recs }
    # A branch to a label outside this chunk (a tail jump) is fine for `j`,
    # which is then treated as an exit, but a conditional branch leaving the
    # function is something this model has never seen emitted.
    foreach r $recs {
        if {[lindex $r 0] ne "i"} continue
        set op [lindex $r 1]
        if {$op in $::pak::opt::df::BR} {
            if {![dict exists $labels [lindex $r end]]} { return $recs }
        }
    }
    set recs [propagate $recs]
    for {set pass 0} {$pass < 4} {incr pass} {
        lassign [dce $recs] recs changed
        if {!$changed} break
    }
    set recs [leaf_rename $recs]
    return [trim_frame $recs]
}

# ── leaf functions: callee-saved registers become scratch ───────────────────
# A function that makes no call has no use for $s registers: nothing it does
# can clobber a $t or $a register behind its back. A promoted parameter that
# is only ever a copy of its $aN (`move $s1, $a0` and $a0 never written again)
# simply becomes $aN; any other $s register is renamed to a caller-saved
# register the function never mentions. Either way its save/restore pair is
# then all that names it, and trim_frame drops that.
proc pak::opt::df::mentions {r} {
    return [regexp -all -inline {\$[a-z0-9]+} [join [lrange $r 2 end] " "]]
}

proc pak::opt::df::rename_reg {recs from to} {
    set out {}
    foreach r $recs {
        if {[lindex $r 0] eq "i"} {
            set ops {}
            foreach t [lrange $r 2 end] {
                if {$t eq $from} {
                    set t $to
                } elseif {[regexp $::pak::opt::df::MEM_RE $t -> off b] && $b eq $from} {
                    set t "${off}($to)"
                }
                lappend ops $t
            }
            set r [list i [lindex $r 1] {*}$ops]
        }
        lappend out $r
    }
    return $out
}

proc pak::opt::df::leaf_rename {recs} {
    foreach r $recs {
        if {[lindex $r 0] eq "i" && [lindex $r 1] in {jal jalr}} { return $recs }
    }
    foreach sreg {{$s0} {$s1} {$s2} {$s3} {$s4} {$s5} {$s6} {$s7}} {
        # Locate the save (first mention, a `sw` to a $sp slot) and every
        # restore from that same slot; anything else naming $sreg is its use.
        set save_idx -1
        set slot ""
        set restores {}
        set defs {}
        set ok 1
        set n [llength $recs]
        for {set i 0} {$i < $n} {incr i} {
            set r [lindex $recs $i]
            if {[lindex $r 0] ne "i"} continue
            if {[lsearch -exact [mentions $r] $sreg] < 0} continue
            set op [lindex $r 1]
            if {$save_idx < 0} {
                if {$op ne "sw" || [lindex $r 2] ne $sreg || ![string match "*(\$sp)" [lindex $r 3]]} {
                    set ok 0; break
                }
                set save_idx $i
                set slot [lindex $r 3]
                continue
            }
            if {$op eq "lw" && [lindex $r 2] eq $sreg && [lindex $r 3] eq $slot} {
                lappend restores $i
                continue
            }
            if {$op eq "sw" && [lindex $r 3] eq $slot} { set ok 0; break }
            lassign [defuse $op [lrange $r 2 end]] d u
            if {$sreg in $d} { lappend defs $i }
        }
        if {!$ok || $save_idx < 0 || [llength $restores] == 0} continue
        # Every mention of every register in the function, after the save
        # and restores are set aside.
        set used [dict create]
        for {set i 0} {$i < $n} {incr i} {
            set r [lindex $recs $i]
            if {[lindex $r 0] ne "i"} continue
            if {$i == $save_idx || $i in $restores} continue
            foreach m [mentions $r] { dict set used $m 1 }
        }
        set to ""
        # A single `move $sreg, $aN` whose $aN nothing else writes: use $aN.
        if {[llength $defs] == 1} {
            set dr [lindex $recs [lindex $defs 0]]
            if {[lindex $dr 1] eq "move" && [lindex $dr 3] in $::pak::opt::df::ARGS} {
                set a [lindex $dr 3]
                set a_written 0
                foreach r $recs {
                    if {[lindex $r 0] ne "i"} continue
                    lassign [defuse [lindex $r 1] [lrange $r 2 end]] d u
                    if {$a in $d} { set a_written 1; break }
                }
                if {!$a_written} { set to $a }
            }
        }
        if {$to eq ""} {
            foreach cand {{$t0} {$t1} {$t2} {$t3} {$t4} {$t5} {$t6} {$t7} {$t8} {$t9}
                          {$v1} {$a0} {$a1} {$a2} {$a3}} {
                if {![dict exists $used $cand]} { set to $cand; break }
            }
        }
        if {$to eq ""} continue
        set keep {}
        for {set i 0} {$i < $n} {incr i} {
            if {$i == $save_idx || $i in $restores} {
                # A restore in a delay slot leaves a nop behind.
                set p [lindex $recs [expr {$i - 1}]]
                if {$i > 0 && [lindex $p 0] eq "i" && [pak::opt::is_branch_or_jump [lindex $p 1]]} {
                    lappend keep {i nop}
                }
                continue
            }
            lappend keep [lindex $recs $i]
        }
        set recs [rename_reg $keep $sreg $to]
        # `move $a0, $a0` left behind by the parameter case.
        set out {}
        foreach r $recs {
            if {[lindex $r 0] eq "i" && [lindex $r 1] eq "move" && [lindex $r 2] eq [lindex $r 3]} {
                set p [lindex $out end]
                if {[llength $out] && [lindex $p 0] eq "i" && [pak::opt::is_branch_or_jump [lindex $p 1]]} {
                    lappend out {i nop}
                }
                continue
            }
            lappend out $r
        }
        set recs $out
    }
    return $recs
}

# ── prologue / epilogue trimming ────────────────────────────────────────────
# Once dead code is gone, a callee-saved register the body no longer touches
# does not need saving; $ra does not need saving in a function that makes no
# call; and a frame nothing addresses does not need allocating. Each save is
# `sw R, K($sp)` and each restore `lw R, K($sp)`; R is dropped only when
# those are the only instructions naming it (plus `jr $ra` for $ra).
proc pak::opt::df::trim_frame {recs} {
    set mentions [dict create]
    set calls 0
    foreach r $recs {
        if {[lindex $r 0] ne "i"} continue
        set op [lindex $r 1]
        if {$op in {jal jalr}} { set calls 1 }
        foreach t [lrange $r 2 end] {
            foreach m [regexp -all -inline {\$[a-z0-9]+} $t] { dict incr mentions $m }
        }
    }
    set drop [dict create]
    foreach reg {{$s0} {$s1} {$s2} {$s3} {$s4} {$s5} {$s6} {$s7} {$fp} {$ra}} {
        if {$reg eq {$ra} && $calls} continue
        set saves 0; set others 0
        foreach r $recs {
            if {[lindex $r 0] ne "i"} continue
            set op [lindex $r 1]
            set ops [lrange $r 2 end]
            if {[lsearch -exact [regexp -all -inline {\$[a-z0-9]+} [join $ops " "]] $reg] < 0} continue
            if {$op in {sw lw} && [lindex $ops 0] eq $reg && [string match "*(\$sp)" [lindex $ops 1]]} {
                incr saves
            } elseif {$reg eq {$ra} && $op eq "jr" && [lindex $ops 0] eq {$ra}} {
            } else {
                incr others
            }
        }
        if {$saves > 0 && $others == 0} { dict set drop $reg 1 }
    }
    if {[dict size $drop] == 0} { return $recs }
    set out {}
    foreach r $recs {
        if {[lindex $r 0] eq "i" && [lindex $r 1] in {sw lw} && [dict exists $drop [lindex $r 2]] \
                && [string match "*(\$sp)" [lindex $r 3]]} continue
        lappend out $r
    }
    # The frame itself: only `addiu $sp, $sp, +-N` left naming $sp.
    set adj 0; set other_sp 0
    foreach r $out {
        if {[lindex $r 0] ne "i"} continue
        set ops [lrange $r 2 end]
        if {[lsearch -exact [regexp -all -inline {\$[a-z0-9]+} [join $ops " "]] {$sp}] < 0} continue
        if {[lindex $r 1] eq "addiu" && [lindex $ops 0] eq {$sp} && [lindex $ops 1] eq {$sp}} {
            incr adj
        } else {
            incr other_sp
        }
    }
    if {$other_sp == 0 && $adj > 0} {
        set out2 {}
        set n [llength $out]
        for {set i 0} {$i < $n} {incr i} {
            set r [lindex $out $i]
            if {[lindex $r 0] eq "i" && [lindex $r 1] eq "addiu" \
                    && [lindex $r 2] eq {$sp} && [lindex $r 3] eq {$sp}} {
                set p [lindex $out [expr {$i - 1}]]
                if {$i > 0 && [lindex $p 0] eq "i" && [pak::opt::is_branch_or_jump [lindex $p 1]]} {
                    lappend out2 {i nop}
                }
                continue
            }
            lappend out2 $r
        }
        set out $out2
    }
    return $out
}

# ── forward copy / constant propagation ─────────────────────────────────────

proc pak::opt::df::imm16 {v} { expr {[string is entier -strict $v] && $v >= -32768 && $v <= 32767} }
proc pak::opt::df::uimm16 {v} { expr {[string is entier -strict $v] && $v >= 0 && $v <= 65535} }

# Forget everything that mentions register $r (as the copy or the source).
proc pak::opt::df::kill {copyVar constVar r} {
    upvar 1 $copyVar copy $constVar const
    dict unset copy $r
    dict unset const $r
    foreach k [dict keys $copy] {
        if {[dict get $copy $k] eq $r} { dict unset copy $k }
    }
}

proc pak::opt::df::propagate {recs} {
    set out {}
    set copy [dict create]
    set const [dict create]
    set n [llength $recs]
    set pending_call 0
    set end_after 0
    for {set i 0} {$i < $n} {incr i} {
        set r [lindex $recs $i]
        if {[lindex $r 0] ne "i"} {
            if {[lindex $r 0] eq "label"} {
                set copy [dict create]; set const [dict create]
            }
            lappend out $r
            continue
        }
        set op [lindex $r 1]
        set ops [lrange $r 2 end]
        lassign [shape $op $ops] kind pos base
        # Rewrite reads.
        foreach p $pos {
            set t [lindex $ops $p]
            if {[dict exists $copy $t]} { lset ops $p [dict get $copy $t] }
        }
        if {$base ne ""} {
            set m [lindex $ops $base]
            if {[regexp $::pak::opt::df::MEM_RE $m -> off b] && [dict exists $copy $b]} {
                lset ops $base "${off}([dict get $copy $b])"
            }
        }
        if {$kind eq "call" && $op eq "jalr"} {
            set t [lindex $ops end]
            if {[dict exists $copy $t]} { lset ops end [dict get $copy $t] }
        }
        # Immediate forms for a known constant operand.
        lassign [strength $op $ops $const] op ops
        set r [list i $op {*}$ops]
        lappend out $r
        # Update what is known.
        lassign [defuse $op $ops] defs uses
        foreach d $defs { kill copy const $d }
        if {$op eq "move" && [llength $defs] == 1} {
            set d [lindex $ops 0]
            set s [lindex $ops 1]
            if {$d ne $s && $d ni {{$sp} {$fp} {$ra} {$gp}} && [is_gpr $s]} {
                if {$s eq {$zero}} {
                    dict set const $d 0
                } elseif {[dict exists $const $s]} {
                    dict set const $d [dict get $const $s]
                } else {
                    dict set copy $d $s
                }
            }
        }
        if {$op eq "li" && [llength $defs] == 1 && [string is entier -strict [lindex $ops 1]]} {
            dict set const [lindex $ops 0] [expr {[lindex $ops 1]}]
        }
        if {$pending_call} {
            foreach c $::pak::opt::df::CLOBBER { kill copy const $c }
            set pending_call 0
        }
        if {$end_after} {
            set copy [dict create]; set const [dict create]
            set end_after 0
        }
        if {$kind eq "call"} { set pending_call 1 }
        if {$kind in {branch jump ret call}} {
            # The next instruction is the delay slot; the block ends after it.
            if {$kind ne "call"} { set end_after 1 }
        }
    }
    return $out
}

# `addu $d, $a, $k` with $k a known 16-bit constant -> `addiu $d, $a, K`, and
# the same for the other ALU ops with an immediate twin. A `move` from a
# constant becomes `li`, so the constant's own `li` can die.
proc pak::opt::df::strength {op ops const} {
    set kv {}
    if {[llength $ops] == 3} {
        lassign $ops d a b
        set ka [expr {[dict exists $const $a] ? [dict get $const $a] : ""}]
        set kb [expr {[dict exists $const $b] ? [dict get $const $b] : ""}]
        switch -- $op {
            addu {
                if {$kb ne "" && [imm16 $kb]} { return [list addiu [list $d $a $kb]] }
                if {$ka ne "" && [imm16 $ka]} { return [list addiu [list $d $b $ka]] }
            }
            subu {
                if {$kb ne "" && [imm16 [expr {-$kb}]]} { return [list addiu [list $d $a [expr {-$kb}]]] }
            }
            slt  { if {$kb ne "" && [imm16 $kb]} { return [list slti [list $d $a $kb]] } }
            sltu { if {$kb ne "" && [imm16 $kb]} { return [list sltiu [list $d $a $kb]] } }
            and - or - xor {
                set iop [dict get {and andi or ori xor xori} $op]
                if {$kb ne "" && [uimm16 $kb]} { return [list $iop [list $d $a $kb]] }
                if {$ka ne "" && [uimm16 $ka]} { return [list $iop [list $d $b $ka]] }
            }
            sllv - srlv - srav {
                set iop [dict get {sllv sll srlv srl srav sra} $op]
                if {$kb ne "" && [string is entier -strict $kb]} {
                    return [list $iop [list $d $a [expr {$kb & 31}]]]
                }
            }
        }
    }
    if {$op eq "move" && [llength $ops] == 2} {
        lassign $ops d s
        if {[dict exists $const $s] && [imm16 [dict get $const $s]]} {
            return [list li [list $d [dict get $const $s]]]
        }
    }
    return [list $op $ops]
}

# ── dead-instruction removal ────────────────────────────────────────────────

proc pak::opt::df::setadd {setVar items} {
    upvar 1 $setVar s
    foreach x $items { dict set s $x 1 }
}
proc pak::opt::df::setdel {setVar items} {
    upvar 1 $setVar s
    foreach x $items { dict unset s $x }
}

# Basic blocks as lists of record indexes. Returns {blocks succs label_block}.
proc pak::opt::df::cfg {recs} {
    set n [llength $recs]
    set blocks {}
    set cur {}
    set term {}
    set i 0
    while {$i < $n} {
        set r [lindex $recs $i]
        if {[lindex $r 0] eq "label" && [llength $cur]} {
            lappend blocks $cur; lappend term ""
            set cur {}
        }
        lappend cur $i
        if {[lindex $r 0] eq "i"} {
            set op [lindex $r 1]
            set k [lindex [shape $op [lrange $r 2 end]] 0]
            if {$k in {branch jump ret}} {
                # Take the delay slot along, then end the block.
                if {$i + 1 < $n && [lindex [lindex $recs [expr {$i + 1}]] 0] eq "i"} {
                    incr i
                    lappend cur $i
                }
                lappend blocks $cur; lappend term $k
                set cur {}
            }
        }
        incr i
    }
    if {[llength $cur]} { lappend blocks $cur; lappend term "" }

    set label_block [dict create]
    set bi 0
    foreach b $blocks {
        foreach idx $b {
            set r [lindex $recs $idx]
            if {[lindex $r 0] eq "label"} { dict set label_block [lindex $r 1] $bi }
        }
        incr bi
    }
    set succs {}
    set nb [llength $blocks]
    for {set bi 0} {$bi < $nb} {incr bi} {
        set s {}
        set k [lindex $term $bi]
        set tgt ""
        foreach idx [lindex $blocks $bi] {
            set r [lindex $recs $idx]
            if {[lindex $r 0] eq "i"} {
                set kk [lindex [shape [lindex $r 1] [lrange $r 2 end]] 0]
                if {$kk in {branch jump}} { set tgt [lindex $r end] }
            }
        }
        switch -- $k {
            branch {
                if {[dict exists $label_block $tgt]} { lappend s [dict get $label_block $tgt] }
                if {$bi + 1 < $nb} { lappend s [expr {$bi + 1}] }
            }
            jump {
                if {[dict exists $label_block $tgt]} {
                    lappend s [dict get $label_block $tgt]
                } else {
                    lappend s EXIT_ALL
                }
            }
            ret { lappend s EXIT }
            default { if {$bi + 1 < $nb} { lappend s [expr {$bi + 1}] } else { lappend s EXIT_ALL } }
        }
        lappend succs $s
    }
    return [list $blocks $succs]
}

# Walk one block backwards from live-out, calling $visit (if given) with each
# instruction index and the set live AFTER it. Returns live-in.
proc pak::opt::df::walk_block {recs block live_out {visitVar ""}} {
    if {$visitVar ne ""} { upvar 1 $visitVar dead }
    set live $live_out
    set idxs [lreverse $block]
    set m [llength $idxs]
    for {set j 0} {$j < $m} {incr j} {
        set idx [lindex $idxs $j]
        set r [lindex $recs $idx]
        if {[lindex $r 0] ne "i"} continue
        set op [lindex $r 1]
        set ops [lrange $r 2 end]
        # Is this instruction the delay slot of a jal/jalr just before it?
        # Then the call's own effect comes after it in time.
        set prev [expr {$idx - 1}]
        set prev_r [lindex $recs $prev]
        set after_call [expr {$prev >= 0 && [lindex $prev_r 0] eq "i" \
                               && [lindex $prev_r 1] in {jal jalr}}]
        if {$after_call} {
            setdel live $::pak::opt::df::CLOBBER
            setadd live $::pak::opt::df::ARGS
            setadd live {{$sp} {$gp}}
            if {[lindex $prev_r 1] eq "jalr"} {
                set t [lindex $prev_r end]
                if {[is_gpr $t]} { setadd live [list $t] }
            }
        }
        set k [lindex [shape $op $ops] 0]
        if {$k eq "call"} {
            # Effect already applied at its delay slot -- unless the jal has no
            # delay-slot instruction in the records at all.
            set nxt [lindex $recs [expr {$idx + 1}]]
            if {[lindex $nxt 0] ne "i"} {
                setdel live $::pak::opt::df::CLOBBER
                setadd live $::pak::opt::df::ARGS
                setadd live {{$sp} {$gp}}
                if {$op eq "jalr"} {
                    set t [lindex $ops end]
                    if {[is_gpr $t]} { setadd live [list $t] }
                }
            }
            continue
        }
        if {$k eq "ret"} {
            setadd live $::pak::opt::df::EXIT_LIVE
            continue
        }
        lassign [defuse $op $ops] defs uses
        if {$visitVar ne "" && $op in $::pak::opt::df::PURE && [llength $defs] > 0} {
            set any 0
            foreach d $defs { if {[dict exists $live $d]} { set any 1 } }
            if {!$any} { dict set dead $idx 1 }
        }
        setdel live $defs
        setadd live $uses
    }
    return $live
}

proc pak::opt::df::dce {recs} {
    lassign [cfg $recs] blocks succs
    set nb [llength $blocks]
    set exit_live [dict create]
    setadd exit_live $::pak::opt::df::EXIT_LIVE
    set all_live [dict create]
    setadd all_live $::pak::opt::df::ALL
    set live_in {}
    for {set bi 0} {$bi < $nb} {incr bi} { lappend live_in [dict create] }
    set changed 1
    while {$changed} {
        set changed 0
        for {set bi [expr {$nb - 1}]} {$bi >= 0} {incr bi -1} {
            set out [dict create]
            foreach s [lindex $succs $bi] {
                switch -- $s {
                    EXIT     { set out [dict merge $out $exit_live] }
                    EXIT_ALL { set out [dict merge $out $all_live] }
                    default  { set out [dict merge $out [lindex $live_in $s]] }
                }
            }
            set in [walk_block $recs [lindex $blocks $bi] $out]
            if {[dict size $in] != [dict size [lindex $live_in $bi]]} {
                lset live_in $bi $in
                set changed 1
            }
        }
    }
    set dead [dict create]
    for {set bi 0} {$bi < $nb} {incr bi} {
        set out [dict create]
        foreach s [lindex $succs $bi] {
            switch -- $s {
                EXIT     { set out [dict merge $out $exit_live] }
                EXIT_ALL { set out [dict merge $out $all_live] }
                default  { set out [dict merge $out [lindex $live_in $s]] }
            }
        }
        walk_block $recs [lindex $blocks $bi] $out dead
    }
    if {[dict size $dead] == 0} { return [list $recs 0] }
    set res {}
    set n [llength $recs]
    for {set i 0} {$i < $n} {incr i} {
        if {[dict exists $dead $i]} {
            # A dead instruction in a delay slot becomes a nop; the slot has to
            # hold something.
            set p [lindex $recs [expr {$i - 1}]]
            if {$i > 0 && [lindex $p 0] eq "i" && [pak::opt::is_branch_or_jump [lindex $p 1]]} {
                lappend res {i nop}
            }
            continue
        }
        lappend res [lindex $recs $i]
    }
    return [list $res 1]
}
