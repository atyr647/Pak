# tcl/optimize.tcl — MIPS peephole optimizer, scheduler, delay-slot filler.
# Operates on instruction RECORDS (Contract A: {i mnem ops...} / {label name} /
# {d kind ...} / {placeholder tag} / {verbatim line}). Assembly text is a debug
# dump: pak::optimize_asm is a thin wrapper around the record passes.
#
# Four passes, in order: const-fold, peephole, VR4300 scheduling, delay-slot
# filling, dead-label elimination.

namespace eval pak::opt {}
if {[info exists ::pak::_optimize_loaded]} { return }
set ::pak::_optimize_loaded 1

# The delay-slot filler has to know which mnemonics are pseudo-instructions
# that expand to more than one machine word, and tcl/n64enc.tcl is where that
# is decided. Asking it directly is the only way the two stay in agreement.
source [file join [file dirname [file normalize [info script]]] n64enc.tcl]

# ── Instruction pattern tables ───────────────────────────────────────────────
set ::pak::opt::BRANCH_OPS {beq bne beqz bnez bgez bgtz blez bltz bge bgt ble blt bc1t bc1f}
set ::pak::opt::JUMP_OPS {j jal jr jalr}
set ::pak::opt::LOAD_OPS {lw lh lb lhu lbu lwc1 ldc1 ld}
set ::pak::opt::MULT_OPS {mult multu}
set ::pak::opt::DIV_OPS {div divu}
set ::pak::opt::MFHILO_OPS {mflo mfhi}
# Ops whose first operand is the destination (written, not read).
set ::pak::opt::DST_FIRST {li la lui move addiu addi addu subu mul and or xor nor \
    sll srl sra slt sltu slti seq sne sle sge sgt sleu sgtu sgeu not sllv srav srlv \
    andi ori xori sltiu mflo mfhi}
set ::pak::opt::FPU_DST_FIRST {
    add.s sub.s mul.s div.s mov.s neg.s abs.s sqrt.s
    add.d sub.d mul.d div.d mov.d neg.d abs.d sqrt.d
    cvt.s.w cvt.w.s cvt.d.w cvt.w.d cvt.s.d cvt.d.s
    mfc1
}
set ::pak::opt::LOADW_OPS {lw lh lb lhu lbu lwc1 ldc1 ld}

proc pak::opt::in {item lst} { expr {[lsearch -exact $lst $item] >= 0} }

# ── Record accessors ─────────────────────────────────────────────────────────
proc pak::opt::is_instr {rec} { expr {[lindex $rec 0] eq "i"} }
proc pak::opt::is_label_rec {rec} { expr {[lindex $rec 0] eq "label"} }
proc pak::opt::mnem {rec} { lindex $rec 1 }
proc pak::opt::ops {rec} { lrange $rec 2 end }
proc pak::opt::label_name {rec} {
    if {[lindex $rec 0] eq "label"} { return [lindex $rec 1] }
    return ""
}

# How many machine words this record assembles to. Anything above one must
# never go in a branch delay slot: the delay slot is one word, so the rest of
# the expansion sits at the branch target's expense and is skipped whenever the
# branch is taken. `seq $v0,$t5,$t4` after a `j` left $v0 holding the raw
# difference instead of 0/1, and `li $v0, 0xA0125800` left the low half
# unwritten -- both silently, because the simulator runs records, not words.
proc pak::opt::expansion_words {rec} {
    if {![is_instr $rec]} { return 1 }
    set op [mnem $rec]
    # `la` is always lui+addiu (each half needs its own relocation), and
    # pak::enc::expand refuses to expand it outside the encoder.
    if {$op eq "la"} { return 2 }
    if {![pak::enc::is_pseudo $op]} { return 1 }
    if {[catch {set exp [pak::enc::expand $op [ops $rec]]}]} { return 2 }
    if {[llength $exp] == 0} { return 1 }
    return [llength $exp]
}

proc pak::opt::is_branch_or_jump {op} {
    return [expr {[in $op $::pak::opt::BRANCH_OPS] || [in $op $::pak::opt::JUMP_OPS]}]
}

proc pak::opt::regs_in {ops} {
    set regs {}
    set seen [dict create]
    foreach tok $ops {
        foreach m [regexp -all -inline {\$\w+} $tok] {
            if {![dict exists $seen $m]} { dict set seen $m 1; lappend regs $m }
        }
    }
    return $regs
}

proc pak::opt::drop_reg {regs item} {
    set idx [lsearch -exact $regs $item]
    if {$idx >= 0} { return [lreplace $regs $idx $idx] }
    return $regs
}

# Return a list of registers written.
proc pak::opt::regs_written {op ops} {
    if {[in $op $::pak::opt::LOADW_OPS] || [in $op $::pak::opt::DST_FIRST] \
            || [in $op $::pak::opt::FPU_DST_FIRST]} {
        if {[llength $ops] > 0} { return [list [lindex $ops 0]] }
        return {}
    }
    if {[in $op {mult multu div divu}]} {
        return {HI LO}
    }
    # An FP compare writes the coprocessor condition bit, which bc1t/bc1f read
    # and nothing else names. Without saying so, the delay-slot filler put
    # `c.lt.s` in the delay slot of the `bc1f` that tests it -- the branch was
    # decided on the previous comparison's result, so `if a < b` took the wrong
    # arm -- and the scheduler was free to move one across the other.
    if {[regexp {^c\.[a-z]+\.[sd]$} $op]} {
        return {FCC}
    }
    if {[in $op {jal jalr}]} {
        return {{$ra} {$v0} {$v1} {$a0}}
    }
    if {$op eq "mtc1" && [llength $ops] >= 2} {
        return [list [lindex $ops 1]]
    }
    return {}
}

# Return a list (deduped, in first-seen order) of registers read.
proc pak::opt::regs_read {op ops} {
    if {[in $op {bc1t bc1f}]} { return {FCC} }
    set regs [regs_in $ops]
    foreach w [regs_written $op $ops] { set regs [drop_reg $regs $w] }
    return $regs
}

# True if list a and list b share any element.
proc pak::opt::sets_overlap {a b} {
    foreach x $a { if {[lsearch -exact $b $x] >= 0} { return 1 } }
    return 0
}

# ── Peephole pass ────────────────────────────────────────────────────────────
proc pak::opt::peephole {recs} {
    set result {}
    set n [llength $recs]
    set i 0
    while {$i < $n} {
        set rec [lindex $recs $i]
        if {[is_instr $rec]} {
            set op [mnem $rec]
            set operands [ops $rec]

            # 1. li $reg, 0 -> move $reg, $zero
            if {$op eq "li" && [llength $operands] == 2} {
                set val [lindex $operands 1]
                if {[regexp {^-?\d+$} $val] && $val == 0} {
                    lappend result [list i move [lindex $operands 0] {$zero}]
                    incr i
                    continue
                }
            }
            # 2. move $reg, $reg -> drop
            if {$op eq "move" && [llength $operands] == 2} {
                if {[lindex $operands 0] eq [lindex $operands 1]} {
                    incr i
                    continue
                }
            }
            # 3. sw $r, off($sp) then lw $r, off($sp) -> keep only sw
            if {$op eq "sw" && $i + 1 < $n} {
                set nxt [lindex $recs [expr {$i + 1}]]
                if {[is_instr $nxt] && [mnem $nxt] eq "lw" \
                        && [ops $rec] eq [ops $nxt]} {
                    lappend result $rec
                    incr i 2
                    continue
                }
            }
            # 4. li $t, N + addu $d, $s, $t -> addiu $d, $s, N  (N fits i16)
            if {$op eq "li" && $i + 1 < $n && [llength $operands] == 2} {
                set li_reg [lindex $operands 0]
                set val [lindex $operands 1]
                set nxt [lindex $recs [expr {$i + 1}]]
                if {[is_instr $nxt] && [mnem $nxt] eq "addu" \
                        && [regexp {^-?\d+$} $val] \
                        && $val >= -32768 && $val <= 32767} {
                    lassign [ops $nxt] ad as at
                    if {$at eq $li_reg} {
                        lappend result [list i addiu $ad $as $val]
                        incr i 2
                        continue
                    }
                }
            }
        }
        lappend result $rec
        incr i
    }
    return $result
}

# ── Constant folding ────────────────────────────────────────────────────────
# Folds sequences like:
#   li $t, A
#   li $s, B
#   addu/subu/and/or/xor/slt $d, $t, $s    (or $d, $s, $t)
# → li $d, (A op B)                         (when both sources are known immediates)
proc pak::opt::const_fold {recs} {
    set known [dict create]
    set result {}
    foreach rec $recs {
        if {![is_instr $rec]} {
            if {[is_label_rec $rec]} { set known [dict create] }
            lappend result $rec
            continue
        }
        set op [mnem $rec]
        set parts [ops $rec]

        if {$op eq "li" && [llength $parts] == 2} {
            set reg [lindex $parts 0]
            set val [lindex $parts 1]
            if {[regexp {^-?\d+$} $val]} {
                dict set known $reg [expr {int($val)}]
                lappend result $rec
                continue
            }
        }

        set folded 0
        if {[llength $parts] == 3 && $op in {addu subu and or xor slt sltu}} {
            set dst [lindex $parts 0]
            set s1  [lindex $parts 1]
            set s2  [lindex $parts 2]
            if {[dict exists $known $s1] && [dict exists $known $s2]} {
                set v1 [dict get $known $s1]
                set v2 [dict get $known $s2]
                switch -- $op {
                    addu  { set r [expr {($v1 + $v2) & 0xFFFFFFFF}] }
                    subu  { set r [expr {($v1 - $v2) & 0xFFFFFFFF}] }
                    and   { set r [expr {$v1 & $v2}] }
                    or    { set r [expr {$v1 | $v2}] }
                    xor   { set r [expr {$v1 ^ $v2}] }
                    slt   { set r [expr {$v1 < $v2 ? 1 : 0}] }
                    sltu  { set r [expr {($v1 & 0xFFFFFFFF) < ($v2 & 0xFFFFFFFF) ? 1 : 0}] }
                }
                if {$r >= 0x80000000} { set r [expr {$r - 0x100000000}] }
                lappend result [list i li $dst $r]
                dict set known $dst $r
                set folded 1
            }
        }
        if {!$folded} {
            foreach w [regs_written $op $parts] { dict unset known $w }
            if {[is_branch_or_jump $op] || $op in {sw sh sb swc1 jal jalr syscall}} {
                set known [dict create]
            }
            lappend result $rec
        }
    }
    return $result
}

# ── Branch delay slot filling ────────────────────────────────────────────────
proc pak::opt::fill_delay_slots {recs} {
    set result {}
    set n [llength $recs]
    set i 0
    while {$i < $n} {
        if {$i + 2 < $n} {
            set prev [lindex $recs $i]
            set br   [lindex $recs [expr {$i + 1}]]
            set nop  [lindex $recs [expr {$i + 2}]]
            if {[is_instr $prev] && [is_instr $br] && [is_instr $nop] \
                    && [is_branch_or_jump [mnem $br]] && [mnem $nop] eq "nop"} {
                set prev_op [mnem $prev]
                if {![is_branch_or_jump $prev_op] \
                        && ![in $prev_op {nop mult multu div divu jal jalr sync}] \
                        && [expansion_words $prev] == 1 \
                        && ![string match ".*" $prev_op]} {
                    set prev_writes [regs_written $prev_op [ops $prev]]
                    set branch_reads [regs_read [mnem $br] [ops $br]]
                    if {![sets_overlap $prev_writes $branch_reads]} {
                        lappend result $br
                        lappend result $prev
                        incr i 3
                        continue
                    }
                }
            }
        }
        lappend result [lindex $recs $i]
        incr i
    }
    return $result
}

# ── VR4300 instruction scheduling ────────────────────────────────────────────
set ::pak::opt::MEM_OPS   {lw lh lb lhu lbu lwc1 ldc1 ld sw sh sb swc1 sdc1 sd}
set ::pak::opt::STORE_OPS {sw sh sb swc1 sdc1 sd}
set ::pak::opt::BARRIER_OPS {sync cache}

proc pak::opt::is_independent {rec_a rec_b} {
    if {![is_instr $rec_a] || ![is_instr $rec_b]} { return 0 }
    set op_a [mnem $rec_a]
    set op_b [mnem $rec_b]
    set operands_a [ops $rec_a]
    set operands_b [ops $rec_b]
    if {[is_branch_or_jump $op_b] || [in $op_b {nop sync syscall mul mult multu div divu mflo mfhi}]} {
        return 0
    }
    # Memory ordering. The scheduler compares registers only, so it cannot tell
    # that `lw $a0, 156($sp)` reads what `sw $t9, 156($sp)` just wrote, and it
    # has no idea that a store may be MMIO whose position is the whole point.
    # Stores therefore never move, and no memory access crosses a store or a
    # barrier.
    if {[in $op_b $::pak::opt::STORE_OPS]} { return 0 }
    if {[in $op_b $::pak::opt::MEM_OPS] \
            && ([in $op_a $::pak::opt::STORE_OPS] || [in $op_a $::pak::opt::BARRIER_OPS])} {
        return 0
    }
    set reads_a [regs_read $op_a $operands_a]
    set writes_a [regs_written $op_a $operands_a]
    set reads_b [regs_read $op_b $operands_b]
    set writes_b [regs_written $op_b $operands_b]
    if {[sets_overlap $writes_b $reads_a]} { return 0 }
    if {[sets_overlap $reads_b $writes_a]} { return 0 }
    if {[sets_overlap $writes_b $writes_a]} { return 0 }
    return 1
}

proc pak::opt::schedule_vr4300 {recs} {
    set blocks {}
    set current {}
    set prev_was_branch 0
    foreach rec $recs {
        if {[is_label_rec $rec]} {
            if {[llength $current] > 0} { lappend blocks $current }
            set current [list $rec]
            set prev_was_branch 0
        } elseif {[is_instr $rec] && [is_branch_or_jump [mnem $rec]]} {
            lappend current $rec
            set prev_was_branch 1
        } elseif {$prev_was_branch} {
            lappend current $rec
            lappend blocks $current
            set current {}
            set prev_was_branch 0
        } else {
            lappend current $rec
            set prev_was_branch 0
        }
    }
    if {[llength $current] > 0} { lappend blocks $current }

    set result {}
    foreach block $blocks {
        foreach r [schedule_block $block] { lappend result $r }
    }
    return $result
}

proc pak::opt::schedule_block {block} {
    set lines $block
    set i 0
    while {$i < [llength $lines]} {
        set rec [lindex $lines $i]
        if {![is_instr $rec]} { incr i; continue }
        set op [mnem $rec]
        set operands [ops $rec]

        # Load-use hazard: lw/lb/lh/etc followed by immediate use of loaded reg
        # stalls the R4300i pipeline for 1 cycle. Fill with an independent
        # instruction if available, otherwise insert nop.
        if {[in $op $::pak::opt::LOAD_OPS] && $i + 1 < [llength $lines]} {
            set written [regs_written $op $operands]
            set nxt [lindex $lines [expr {$i + 1}]]
            if {[is_instr $nxt]} {
                set next_reads [regs_read [mnem $nxt] [ops $nxt]]
                if {[sets_overlap $written $next_reads]} {
                    if {![find_and_move_between lines $i [expr {$i + 1}]]} {
                        set lines [linsert $lines [expr {$i + 1}] {i nop}]
                    }
                    incr i
                    continue
                }
            }
        }
        if {[in $op $::pak::opt::MULT_OPS] || [in $op $::pak::opt::DIV_OPS]} {
            fill_before_mfhilo lines $i 4
        }
        incr i
    }
    return $lines
}

proc pak::opt::find_and_move_between {lines_var load_idx use_idx} {
    upvar 1 $lines_var lines
    set n [llength $lines]
    for {set j [expr {$use_idx + 1}]} {$j < $n} {incr j} {
        set candidate [lindex $lines $j]
        if {![is_instr $candidate]} { continue }
        if {[is_label_rec $candidate] || [is_branch_or_jump [mnem $candidate]]} { break }
        set ok 1
        for {set k $load_idx} {$k < $j} {incr k} {
            if {![is_independent [lindex $lines $k] $candidate]} { set ok 0; break }
        }
        if {$ok} {
            set moved [lindex $lines $j]
            set lines [lreplace $lines $j $j]
            set lines [linsert $lines $use_idx $moved]
            return 1
        }
    }
    return 0
}

proc pak::opt::fill_before_mfhilo {lines_var mult_idx max_fill} {
    upvar 1 $lines_var lines
    set n [llength $lines]
    set mf_idx ""
    for {set k [expr {$mult_idx + 1}]} {$k < $n} {incr k} {
        set rec [lindex $lines $k]
        if {![is_instr $rec]} { continue }
        if {[is_label_rec $rec] || [is_branch_or_jump [mnem $rec]]} { return }
        if {[in [mnem $rec] $::pak::opt::MFHILO_OPS]} { set mf_idx $k; break }
    }
    if {$mf_idx eq "" || $mf_idx == $mult_idx + 1} {
        if {$mf_idx ne "" && $mf_idx == $mult_idx + 1} {
            set filled 0
            set search_start [expr {$mf_idx + 1}]
            for {set j $search_start} {$j < [llength $lines]} {incr j} {
                if {$filled >= $max_fill} { break }
                set candidate [lindex $lines $j]
                if {![is_instr $candidate]} { continue }
                if {[is_label_rec $candidate] || [is_branch_or_jump [mnem $candidate]]} { break }
                if {[in [mnem $candidate] $::pak::opt::MFHILO_OPS]} { break }
                set ok 1
                for {set k $mult_idx} {$k < $j} {incr k} {
                    if {![is_independent [lindex $lines $k] $candidate]} { set ok 0; break }
                }
                if {$ok} {
                    set moved [lindex $lines $j]
                    set lines [lreplace $lines $j $j]
                    set lines [linsert $lines [expr {$mult_idx + 1}] $moved]
                    incr filled
                }
            }
        }
        return
    }
    return
}

# ── Dead label elimination ───────────────────────────────────────────────────
proc pak::opt::eliminate_dead_labels {recs} {
    set defined {}
    foreach rec $recs {
        set nm [label_name $rec]
        if {$nm ne ""} { lappend defined $nm }
    }
    set referenced [dict create]
    foreach rec $recs {
        if {[is_label_rec $rec]} continue
        set blob [join [lrange $rec 1 end] " "]
        foreach label $defined {
            if {[string first $label $blob] >= 0} { dict set referenced $label 1 }
        }
    }
    set result {}
    foreach rec $recs {
        set nm [label_name $rec]
        if {$nm ne ""} {
            if {[string match ".*" $nm] && ![dict exists $referenced $nm]} { continue }
        }
        lappend result $rec
    }
    return $result
}

# ── Text ↔ records (debug dump only) ─────────────────────────────────────────
proc pak::opt::asm_to_records {asm_text} {
    set recs {}
    foreach raw [split $asm_text "\n"] {
        if {[regexp {^(\.\w+|[A-Za-z_]\w*):\s*$} $raw -> nm]} {
            lappend recs [list label $nm]
            continue
        }
        if {[regexp {^\s+(\S+)\s*(.*)$} $raw -> op rest]} {
            if {![string match ".*" $op] && ![string match "#*" $op]} {
                set ops {}
                foreach o [split $rest ,] {
                    set o [string trim $o]
                    if {$o ne ""} { lappend ops $o }
                }
                lappend recs [list i $op {*}$ops]
                continue
            }
        }
        lappend recs [list verbatim $raw]
    }
    return $recs
}

proc pak::records_to_asm {recs} {
    set lines {}
    foreach rec $recs {
        switch -- [lindex $rec 0] {
            i {
                set mnem [lindex $rec 1]
                set ops [lrange $rec 2 end]
                if {[llength $ops] == 0} {
                    lappend lines "    $mnem"
                } else {
                    lappend lines "    $mnem [join $ops {, }]"
                }
            }
            label {
                lappend lines "[lindex $rec 1]:"
            }
            placeholder {
                lappend lines "    # [lindex $rec 1]"
            }
            verbatim {
                lappend lines [lindex $rec 1]
            }
            d {
                set kind [lindex $rec 1]
                set rest [lrange $rec 2 end]
                switch -- $kind {
                    section { lappend lines "\t.section [lindex $rest 0]" }
                    globl   { lappend lines "\t.globl [lindex $rest 0]" }
                    extern  { lappend lines "\t.extern [lindex $rest 0]" }
                    type    { lappend lines "\t.type [lindex $rest 0], [lindex $rest 1]" }
                    size    { lappend lines "\t.size [lindex $rest 0], [join [lrange $rest 1 end] { }]" }
                    align   { lappend lines "\t.align [lindex $rest 0]" }
                    word    { lappend lines "\t.word [lindex $rest 0]" }
                    half    { lappend lines "\t.half [lindex $rest 0]" }
                    byte    { lappend lines "\t.byte [lindex $rest 0]" }
                    space   { lappend lines "\t.space [lindex $rest 0]" }
                    asciiz {
                        set s [join $rest " "]
                        set e [string map [list "\\" "\\\\" "\"" "\\\"" \
                            "\n" "\\n" "\r" "\\r" "\t" "\\t"] $s]
                        lappend lines "\t.asciiz \"$e\""
                    }
                    default { lappend lines "\t.$kind [join $rest { }]" }
                }
            }
            default {
                error "records_to_asm: unknown record tag '[lindex $rec 0]'"
            }
        }
    }
    return [join $lines "\n"]
}

# ── Public API ───────────────────────────────────────────────────────────────
proc pak::optimize_records {recs {peephole 1} {schedule 1} {fill_slots 1} {dead_labels 1} {const_fold 1}} {
    if {$const_fold}  { set recs [pak::opt::const_fold $recs] }
    if {$peephole}    { set recs [pak::opt::peephole $recs] }
    if {$schedule}    { set recs [pak::opt::schedule_vr4300 $recs] }
    if {$fill_slots}  { set recs [pak::opt::fill_delay_slots $recs] }
    if {$dead_labels} { set recs [pak::opt::eliminate_dead_labels $recs] }
    return $recs
}

proc pak::optimize_asm {asm_text {peephole 1} {schedule 1} {fill_slots 1} {dead_labels 1} {const_fold 1}} {
    set recs [pak::opt::asm_to_records $asm_text]
    set recs [pak::optimize_records $recs $peephole $schedule $fill_slots $dead_labels $const_fold]
    return [pak::records_to_asm $recs]
}
