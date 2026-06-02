# tcl/optimize.tcl — MIPS peephole optimizer, scheduler, delay-slot filler.
# Byte-exact Tcl port of pak/mips/optimize.py. Operates on assembly TEXT
# (a post-processing pass over MipsCodegen output), not a structured IR.
#
# Four passes, in order: peephole, VR4300 scheduling, delay-slot filling,
# dead-label elimination. See pak/mips/optimize.py for the rationale.

namespace eval pak::opt {}
if {[info exists ::pak::_optimize_loaded]} { return }
set ::pak::_optimize_loaded 1

# ── Instruction pattern tables ───────────────────────────────────────────────
set ::pak::opt::BRANCH_OPS {beq bne beqz bnez bgez bgtz blez bltz bge bgt ble blt}
set ::pak::opt::JUMP_OPS {j jal jr jalr}
set ::pak::opt::LOAD_OPS {lw lh lb lhu lbu lwc1}
set ::pak::opt::MULT_OPS {mult multu}
set ::pak::opt::DIV_OPS {div divu}
set ::pak::opt::MFHILO_OPS {mflo mfhi}
# Ops whose first operand is the destination (written, not read).
set ::pak::opt::DST_FIRST {li la move addiu addu subu mul and or xor sll srl sra \
    slt sltu seq sne sle sge sgt not sllv srav srlv andi ori xori sltiu mflo mfhi}
set ::pak::opt::LOADW_OPS {lw lh lb lhu lbu lwc1}

proc pak::opt::in {item lst} { expr {[lsearch -exact $lst $item] >= 0} }

# Parse an instruction line into {op operands} or "" (None).
proc pak::opt::parse_line {line} {
    if {[regexp {^\s+(\w+)\s*(.*)} $line -> op rest]} {
        return [list $op [string trim $rest]]
    }
    return ""
}

proc pak::opt::is_label {line} {
    return [regexp {^(\.\w+|[A-Za-z_]\w*):\s*$} $line]
}

proc pak::opt::label_name {line} {
    if {[regexp {^(\.\w+|[A-Za-z_]\w*):\s*$} $line -> nm]} { return $nm }
    return ""
}

proc pak::opt::is_branch_or_jump {op} {
    return [expr {[in $op $::pak::opt::BRANCH_OPS] || [in $op $::pak::opt::JUMP_OPS]}]
}

# Return a list (deduped, in first-seen order) of registers read.
proc pak::opt::regs_read {op operands} {
    set regs {}
    set seen [dict create]
    foreach m [regexp -all -inline {\$\w+} $operands] {
        if {![dict exists $seen $m]} { dict set seen $m 1; lappend regs $m }
    }
    if {[in $op $::pak::opt::LOADW_OPS] || [in $op $::pak::opt::DST_FIRST]} {
        set parts [split $operands ,]
        if {[llength $parts] > 0} {
            set dst [string trim [lindex $parts 0]]
            set idx [lsearch -exact $regs $dst]
            if {$idx >= 0} { set regs [lreplace $regs $idx $idx] }
        }
    }
    return $regs
}

# Return a list of registers written.
proc pak::opt::regs_written {op operands} {
    set written {}
    if {[in $op {lw lh lb lhu lbu lwc1 li la move addiu addu subu mul and or \
                  xor sll srl sra slt sltu seq sne sle sge sgt not sllv srav \
                  srlv andi ori xori sltiu mflo mfhi}]} {
        set parts [split $operands ,]
        if {[llength $parts] > 0} { lappend written [string trim [lindex $parts 0]] }
    } elseif {[in $op {mult multu div divu}]} {
        lappend written HI LO
    } elseif {[in $op {jal jalr}]} {
        lappend written {$ra} {$v0} {$v1} {$a0}
    }
    return $written
}

# True if list a and list b share any element.
proc pak::opt::sets_overlap {a b} {
    foreach x $a { if {[lsearch -exact $b $x] >= 0} { return 1 } }
    return 0
}

# ── Peephole pass ────────────────────────────────────────────────────────────
proc pak::opt::peephole {lines} {
    set result {}
    set n [llength $lines]
    set i 0
    while {$i < $n} {
        set line [lindex $lines $i]
        set parsed [parse_line $line]
        if {$parsed ne ""} {
            lassign $parsed op operands

            # 1. li $reg, 0 -> move $reg, $zero
            if {$op eq "li"} {
                if {[regexp {li\s+(\$\w+),\s*(-?\d+)} "li $operands" -> reg val] && $val == 0} {
                    lappend result [string map [list "li $operands" "move $reg, \$zero"] $line]
                    incr i
                    continue
                }
            }
            # 2. move $reg, $reg -> drop
            if {$op eq "move"} {
                if {[regexp {move\s+(\$\w+),\s*(\$\w+)} "move $operands" -> r1 r2] && $r1 eq $r2} {
                    incr i
                    continue
                }
            }
            # 3. sw $r, off($sp) then lw $r, off($sp) -> keep only sw
            if {$op eq "sw" && $i + 1 < $n} {
                if {[regexp {sw\s+(\$\w+),\s*(-?\d+)\((\$\w+)\)} "sw $operands" -> sr so sb]} {
                    set np [parse_line [lindex $lines [expr {$i+1}]]]
                    if {$np ne "" && [lindex $np 0] eq "lw"} {
                        if {[regexp {lw\s+(\$\w+),\s*(-?\d+)\((\$\w+)\)} "lw [lindex $np 1]" -> lr lo lb] \
                                && $sr eq $lr && $so eq $lo && $sb eq $lb} {
                            lappend result $line
                            incr i 2
                            continue
                        }
                    }
                }
            }
            # 4. li $t, N + addu $d, $s, $t -> addiu $d, $s, N  (N fits i16)
            if {$op eq "li" && $i + 1 < $n} {
                if {[regexp {li\s+(\$\w+),\s*(-?\d+)} "li $operands" -> li_reg val]} {
                    set np [parse_line [lindex $lines [expr {$i+1}]]]
                    if {$np ne "" && [lindex $np 0] eq "addu"} {
                        if {[regexp {addu\s+(\$\w+),\s*(\$\w+),\s*(\$\w+)} "addu [lindex $np 1]" -> ad as at]} {
                            if {$at eq $li_reg && $val >= -32768 && $val <= 32767} {
                                regexp {^(\s*)} $line -> indent
                                lappend result "${indent}addiu $ad, $as, $val"
                                incr i 2
                                continue
                            }
                        }
                    }
                }
            }
        }
        lappend result $line
        incr i
    }
    return $result
}

# ── Branch delay slot filling ────────────────────────────────────────────────
proc pak::opt::fill_delay_slots {lines} {
    set result {}
    set n [llength $lines]
    set i 0
    while {$i < $n} {
        if {$i + 2 < $n} {
            set prev [parse_line [lindex $lines $i]]
            set br   [parse_line [lindex $lines [expr {$i+1}]]]
            set nop  [parse_line [lindex $lines [expr {$i+2}]]]
            if {$prev ne "" && $br ne "" && $nop ne "" \
                    && [is_branch_or_jump [lindex $br 0]] && [lindex $nop 0] eq "nop"} {
                lassign $prev prev_op prev_operands
                lassign $br br_op br_operands
                if {![is_branch_or_jump $prev_op] \
                        && ![in $prev_op {nop mult multu div divu jal jalr sync}] \
                        && ![string match ".*" $prev_op]} {
                    set prev_writes [regs_written $prev_op $prev_operands]
                    set branch_reads [regs_read $br_op $br_operands]
                    if {![sets_overlap $prev_writes $branch_reads]} {
                        lappend result [lindex $lines [expr {$i+1}]]
                        lappend result [lindex $lines $i]
                        incr i 3
                        continue
                    }
                }
            }
        }
        lappend result [lindex $lines $i]
        incr i
    }
    return $result
}

# ── VR4300 instruction scheduling ────────────────────────────────────────────
proc pak::opt::is_independent {line_a line_b} {
    set pa [parse_line $line_a]
    set pb [parse_line $line_b]
    if {$pa eq "" || $pb eq ""} { return 0 }
    lassign $pa op_a operands_a
    lassign $pb op_b operands_b
    if {[is_branch_or_jump $op_b] || [in $op_b {nop sync syscall mult multu div divu mflo mfhi}]} {
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

proc pak::opt::schedule_vr4300 {lines} {
    set blocks {}
    set current {}
    set prev_was_branch 0
    foreach line $lines {
        set parsed [parse_line $line]
        if {[is_label $line]} {
            if {[llength $current] > 0} { lappend blocks $current }
            set current [list $line]
            set prev_was_branch 0
        } elseif {$parsed ne "" && [is_branch_or_jump [lindex $parsed 0]]} {
            lappend current $line
            set prev_was_branch 1
        } elseif {$prev_was_branch} {
            lappend current $line
            lappend blocks $current
            set current {}
            set prev_was_branch 0
        } else {
            lappend current $line
            set prev_was_branch 0
        }
    }
    if {[llength $current] > 0} { lappend blocks $current }

    set result {}
    foreach block $blocks {
        foreach l [schedule_block $block] { lappend result $l }
    }
    return $result
}

proc pak::opt::schedule_block {block} {
    upvar 0 block lines
    set lines $block
    set i 0
    while {$i < [llength $lines]} {
        set parsed [parse_line [lindex $lines $i]]
        if {$parsed eq ""} { incr i; continue }
        lassign $parsed op operands

        # Load-use hazard
        if {[in $op $::pak::opt::LOAD_OPS] && $i + 1 < [llength $lines]} {
            set written [regs_written $op $operands]
            set np [parse_line [lindex $lines [expr {$i+1}]]]
            if {$np ne ""} {
                set next_reads [regs_read [lindex $np 0] [lindex $np 1]]
                if {[sets_overlap $written $next_reads]} {
                    if {[find_and_move_between lines $i [expr {$i+1}]]} {
                        incr i
                        continue
                    }
                }
            }
        }
        # Multiply / Divide -> mflo/mfhi hazard
        if {[in $op $::pak::opt::MULT_OPS] || [in $op $::pak::opt::DIV_OPS]} {
            fill_before_mfhilo lines $i 4
        }
        incr i
    }
    return $lines
}

# Operates on a list var (by name). Returns 1 if a move happened.
proc pak::opt::find_and_move_between {lines_var load_idx use_idx} {
    upvar 1 $lines_var lines
    set n [llength $lines]
    for {set j [expr {$use_idx + 1}]} {$j < $n} {incr j} {
        set candidate [lindex $lines $j]
        set cp [parse_line $candidate]
        if {$cp eq ""} { continue }
        if {[is_label $candidate] || [is_branch_or_jump [lindex $cp 0]]} { break }
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

# Operates on a list var (by name). Mirrors _fill_before_mfhilo.
proc pak::opt::fill_before_mfhilo {lines_var mult_idx max_fill} {
    upvar 1 $lines_var lines
    set n [llength $lines]
    set mf_idx ""
    for {set k [expr {$mult_idx + 1}]} {$k < $n} {incr k} {
        set kp [parse_line [lindex $lines $k]]
        if {$kp eq ""} { continue }
        if {[is_label [lindex $lines $k]] || [is_branch_or_jump [lindex $kp 0]]} { return }
        if {[in [lindex $kp 0] $::pak::opt::MFHILO_OPS]} { set mf_idx $k; break }
    }
    if {$mf_idx eq "" || $mf_idx == $mult_idx + 1} {
        if {$mf_idx ne "" && $mf_idx == $mult_idx + 1} {
            set filled 0
            set search_start [expr {$mf_idx + 1}]
            for {set j $search_start} {$j < [llength $lines]} {incr j} {
                if {$filled >= $max_fill} { break }
                set candidate [lindex $lines $j]
                set cp [parse_line $candidate]
                if {$cp eq ""} { continue }
                if {[is_label $candidate] || [is_branch_or_jump [lindex $cp 0]]} { break }
                if {[in [lindex $cp 0] $::pak::opt::MFHILO_OPS]} { break }
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
proc pak::opt::eliminate_dead_labels {lines} {
    set defined {}
    foreach line $lines {
        set nm [label_name $line]
        if {$nm ne ""} { lappend defined $nm }
    }
    set referenced [dict create]
    foreach line $lines {
        set parsed [parse_line $line]
        if {$parsed ne ""} {
            set operands [lindex $parsed 1]
            foreach label $defined {
                if {[string first $label $operands] >= 0} { dict set referenced $label 1 }
            }
        }
        if {![is_label $line]} {
            foreach label $defined {
                if {[string first $label $line] >= 0} { dict set referenced $label 1 }
            }
        }
    }
    set result {}
    foreach line $lines {
        set nm [label_name $line]
        if {$nm ne ""} {
            if {[string match ".*" $nm] && ![dict exists $referenced $nm]} { continue }
        }
        lappend result $line
    }
    return $result
}

# ── Public API ───────────────────────────────────────────────────────────────
proc pak::optimize_asm {asm_text {peephole 1} {schedule 1} {fill_slots 1} {dead_labels 1}} {
    set lines [split $asm_text "\n"]
    if {$peephole}   { set lines [pak::opt::peephole $lines] }
    if {$schedule}   { set lines [pak::opt::schedule_vr4300 $lines] }
    if {$fill_slots} { set lines [pak::opt::fill_delay_slots $lines] }
    if {$dead_labels} { set lines [pak::opt::eliminate_dead_labels $lines] }
    return [join $lines "\n"]
}
