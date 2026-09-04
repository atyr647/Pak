# tcl/mips_sim.tcl — minimal MIPS-I/III text-format simulator.
#
# Executes the instruction subset emitted by the Pak MIPS backend, captures
# all byte (sb), halfword (sh) and word (sw) stores, and returns the result.
# Registers are stored as unsigned 32-bit integers; sign is applied only where
# the semantics require it (slt, div, sra, conditional branches).
#
# Public API:
#   pak::mips_sim_run text ?start? ?limit? ?preset?  ->  dict {mem_b mem_h mem_w insns}
#     text  — MIPS assembly text (.extern/.section/.globl etc. are skipped)
#     start — label to begin execution at (default: "main")
#     limit — instruction budget before forced halt (default: 20 000 000)
#   Return dict keys:
#     mem_b  — dict {byte_addr -> u8}   of all sb stores
#     mem_h  — dict {byte_addr -> u16}  of all sh stores
#     mem_w  — dict {byte_addr -> u32}  of all sw stores
#     insns  — count of instructions dispatched

namespace eval pak::mipsim {

# ── register-name → index (array for O(1) lookup) ────────────────────────────

variable REGNUM
array set REGNUM {
    zero 0  at 1   v0 2  v1 3
    a0 4    a1 5   a2 6  a3 7
    t0 8    t1 9   t2 10 t3 11 t4 12 t5 13 t6 14 t7 15
    s0 16   s1 17  s2 18 s3 19 s4 20 s5 21 s6 22 s7 23
    t8 24   t9 25  k0 26 k1 27 gp 28 sp 29 fp 30 ra 31
}

proc rn {name} {
    variable REGNUM
    set n [string trimleft $name {$}]
    if {[string is digit -strict [string index $n 0]]} { return [expr {int($n)}] }
    return $REGNUM($n)
}

# ── arithmetic helpers ────────────────────────────────────────────────────────

proc u32 {v} { expr {$v & 0xFFFFFFFF} }
proc s32 {v} {
    set u [expr {$v & 0xFFFFFFFF}]
    if {$u >= 0x80000000} { return [expr {$u - 0x100000000}] }
    return $u
}
proc trunc_div {a b} {
    if {$b == 0} { return 0 }
    set sign [expr {($a < 0) ^ ($b < 0)}]
    set q    [expr {abs($a) / abs($b)}]
    return   [expr {$sign ? -$q : $q}]
}
proc trunc_mod {a b} {
    if {$b == 0} { return 0 }
    expr {$a - $b * [trunc_div $a $b]}
}

# ── assembly text parser + pre-resolver ──────────────────────────────────────
# Each insn is a list {op tok tok ...} where:
#   - register tokens "$rN" are pre-resolved to integers (0-31)
#   - memory operands "off($base)" are pre-resolved to two-element lists {off reg_int}
#   - immediate/label tokens are kept as strings
# This eliminates all string operations from the hot simulation loop.

# Parse an assembly listing into {labels insns data_syms data_image}.
#
#   labels     — text label -> instruction index
#   insns      — the instruction stream
#   data_syms  — data label -> simulated RDRAM address (what `la` resolves to)
#   data_image — {address -> word} initial contents of .data/.rodata/.bss
#
# Data lives at DATA_BASE upward. The layout only has to be self-consistent:
# nothing in the simulator cares where a static actually lands on hardware, only
# that each one gets its own address and its initialiser is readable.
variable DATA_BASE 0x80300000

proc parse_asm {text} {
    variable REGNUM
    variable DATA_BASE
    set labels [dict create]
    set insns  [list]
    set data_syms [dict create]
    set data_image [dict create]

    set section .text
    set daddr $DATA_BASE
    set pending_labels {}

    # Write one byte into the data image, which is stored as aligned words so
    # the simulator's word loads can read it back directly.
    proc _dbyte {imgvar addr val} {
        upvar 1 $imgvar img
        set w [expr {$addr & ~3}]
        set shift [expr {(3 - ($addr & 3)) * 8}]
        set cur [expr {[dict exists $img $w] ? [dict get $img $w] : 0}]
        dict set img $w [expr {($cur & ~(0xFF << $shift)) | (($val & 0xFF) << $shift)}]
    }

    foreach raw [split $text "\n"] {
        set line [string trim [regsub {[#;].*$} $raw ""]]
        if {$line eq ""} continue

        # label: no internal whitespace, ends with ":"
        if {[string match "*:" $line] && [string first " " $line] < 0} {
            set name [string trimright $line ":"]
            if {$section eq ".text"} {
                dict set labels $name [llength $insns]
            } else {
                dict set data_syms $name $daddr
            }
            continue
        }

        # assembler directive (dot-prefixed, not a label)
        if {[string index $line 0] eq "."} {
            set parts [regexp -all -inline {\S+} $line]
            set d [lindex $parts 0]
            switch -- $d {
                .section { set section [lindex $parts 1] }
                .text    { set section .text }
                .data    { set section .data }
                .align {
                    if {$section ne ".text"} {
                        set a [expr {1 << [lindex $parts 1]}]
                        set daddr [expr {($daddr + $a - 1) & ~($a - 1)}]
                    }
                }
                .word {
                    if {$section ne ".text"} {
                        foreach v [lrange $parts 1 end] {
                            set v [string trimright $v ","]
                            if {![string is integer -strict $v]} { set v 0 }
                            for {set i 3} {$i >= 0} {incr i -1} {
                                _dbyte data_image $daddr [expr {($v >> ($i * 8)) & 0xFF}]
                                incr daddr
                            }
                        }
                    }
                }
                .half - .short {
                    if {$section ne ".text"} {
                        foreach v [lrange $parts 1 end] {
                            set v [string trimright $v ","]
                            if {![string is integer -strict $v]} { set v 0 }
                            _dbyte data_image $daddr [expr {($v >> 8) & 0xFF}]; incr daddr
                            _dbyte data_image $daddr [expr {$v & 0xFF}];        incr daddr
                        }
                    }
                }
                .byte {
                    if {$section ne ".text"} {
                        foreach v [lrange $parts 1 end] {
                            set v [string trimright $v ","]
                            if {![string is integer -strict $v]} { set v 0 }
                            _dbyte data_image $daddr $v
                            incr daddr
                        }
                    }
                }
                .space {
                    if {$section ne ".text"} {
                        set n [lindex $parts 1]
                        if {![string is integer -strict $n]} { set n 0 }
                        for {set i 0} {$i < $n} {incr i} {
                            _dbyte data_image $daddr 0
                            incr daddr
                        }
                    }
                }
                .asciiz - .ascii {
                    if {$section ne ".text"} {
                        # The string is everything after the directive, quoted.
                        if {[regexp {"((?:[^"\\]|\\.)*)"} $line -> str]} {
                            set str [subst -nocommands -novariables \
                                [string map {\\n \\n \\t \\t \\" \" \\\\ \\\\} $str]]
                            foreach ch [split $str ""] {
                                _dbyte data_image $daddr [scan $ch %c]
                                incr daddr
                            }
                        }
                        if {$d eq ".asciiz"} { _dbyte data_image $daddr 0; incr daddr }
                    }
                }
            }
            continue
        }

        # Only .text carries instructions.
        if {$section ne ".text"} continue

        # tokenise: split on whitespace, strip trailing commas
        set parts [list]
        foreach raw_tok [regexp -all -inline {\S+} $line] {
            set tok [string trimright $raw_tok ","]
            # pre-resolve register: $name → integer
            if {[regexp {^\$(\w+)$} $tok _ rname]} {
                if {[info exists REGNUM($rname)]} {
                    lappend parts $REGNUM($rname)
                } else {
                    lappend parts $tok  ;# unknown — keep as-is
                }
                continue
            }
            # pre-resolve memory operand: off($base) → {off reg_int}
            if {[regexp {^(-?(?:0x[0-9a-fA-F]+|\d+))\(\$?(\w+)\)$} $tok _ off bname]} {
                if {[info exists REGNUM($bname)]} {
                    lappend parts [list [expr {$off + 0}] $REGNUM($bname)]
                } else {
                    lappend parts $tok
                }
                continue
            }
            # keep immediates, labels, directives as strings
            lappend parts $tok
        }
        if {[llength $parts] == 0} continue
        lappend insns $parts
    }
    return [list $labels $insns $data_syms $data_image]
}

# ── instruction executor ──────────────────────────────────────────────────────
# State is accessed via upvar 1 from run (local variables, no proc-call penalty):
#   R   — array of 32 unsigned 32-bit registers
#   HI LO — multiply/divide results
#   mb  — dict byte_addr->u8   (sb stores)
#   mh  — dict byte_addr->u16  (sh stores)
#   mw  — dict byte_addr->u32  (sw stores)
#
# Pre-resolved args: register slots are already integers, memory ops are {off base_int}.
#
# Returns: ""       → advance PC by 1
#          "done"   → halt simulation
#          "jmp:L"  → branch/jump taken; caller executes delay slot then jumps

proc exec_insn {op args} {
    upvar 1 R R  HI HI  LO LO  mb mb  mh mh  mw mw  dsyms dsyms  mseq mseq  mseqi mseqi

    switch -- $op {
        nop - sync { return "" }

        li {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {[lindex $args 1] & 0xFFFFFFFF}] }
        }
        move {
            set n [lindex $args 0]
            if {$n} { set R($n) $R([lindex $args 1]) }
        }
        lui {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {([lindex $args 1] & 0xFFFF) << 16}] }
        }

        addiu - addi {
            set n [lindex $args 0];  set s [lindex $args 1]
            set i [lindex $args 2]
            if {$i > 32767}  { set i [expr {$i - 65536}] }
            if {$i < -32768} { set i [expr {$i + 65536}] }
            if {$n} { set R($n) [expr {($R($s) + $i) & 0xFFFFFFFF}] }
        }
        addu - add {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {($R([lindex $args 1]) + $R([lindex $args 2])) & 0xFFFFFFFF}] }
        }
        subu - sub {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {($R([lindex $args 1]) - $R([lindex $args 2])) & 0xFFFFFFFF}] }
        }
        mul {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {($R([lindex $args 1]) * $R([lindex $args 2])) & 0xFFFFFFFF}] }
        }
        and {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) & $R([lindex $args 2])}] }
        }
        or {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) | $R([lindex $args 2])}] }
        }
        xor {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) ^ $R([lindex $args 2])}] }
        }
        nor {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {(~($R([lindex $args 1]) | $R([lindex $args 2]))) & 0xFFFFFFFF}] }
        }
        slt {
            set n [lindex $args 0]
            if {$n} {
                set a $R([lindex $args 1]);  set b $R([lindex $args 2])
                set sa [expr {$a >= 0x80000000 ? $a - 0x100000000 : $a}]
                set sb [expr {$b >= 0x80000000 ? $b - 0x100000000 : $b}]
                set R($n) [expr {$sa < $sb ? 1 : 0}]
            }
        }
        sle - sgt - sge {
            # Signed comparison pseudo-instructions the backend emits alongside
            # slt; without them a comparison silently leaves its destination
            # register untouched and every guarded branch goes the wrong way.
            set n [lindex $args 0]
            if {$n} {
                set a $R([lindex $args 1]);  set b $R([lindex $args 2])
                set sa [expr {$a >= 0x80000000 ? $a - 0x100000000 : $a}]
                set sb [expr {$b >= 0x80000000 ? $b - 0x100000000 : $b}]
                switch -- $op {
                    sle { set R($n) [expr {$sa <= $sb ? 1 : 0}] }
                    sgt { set R($n) [expr {$sa >  $sb ? 1 : 0}] }
                    sge { set R($n) [expr {$sa >= $sb ? 1 : 0}] }
                }
            }
        }
        seq {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) == $R([lindex $args 2]) ? 1 : 0}] }
        }
        sne {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) != $R([lindex $args 2]) ? 1 : 0}] }
        }
        cache {
            # Cache maintenance has no effect on the simulator's flat memory.
        }
        sltu {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) < $R([lindex $args 2]) ? 1 : 0}] }
        }
        slti {
            set n [lindex $args 0];  set s [lindex $args 1];  set i [lindex $args 2]
            if {$i > 32767} { set i [expr {$i - 65536}] }
            set sa $R($s); if {$sa >= 0x80000000} { set sa [expr {$sa - 0x100000000}] }
            if {$n} { set R($n) [expr {$sa < $i ? 1 : 0}] }
        }
        sltiu {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) < ([lindex $args 2] & 0xFFFFFFFF) ? 1 : 0}] }
        }

        andi {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) & ([lindex $args 2] & 0xFFFF)}] }
        }
        ori {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) | ([lindex $args 2] & 0xFFFF)}] }
        }
        xori {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) ^ ([lindex $args 2] & 0xFFFF)}] }
        }

        sll {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {($R([lindex $args 1]) << ([lindex $args 2] & 0x1F)) & 0xFFFFFFFF}] }
        }
        srl {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) >> ([lindex $args 2] & 0x1F)}] }
        }
        sra {
            set n [lindex $args 0];  set s [lindex $args 1];  set sh [expr {[lindex $args 2] & 0x1F}]
            set sv $R($s); if {$sv >= 0x80000000} { set sv [expr {$sv - 0x100000000}] }
            if {$n} { set R($n) [expr {($sv >> $sh) & 0xFFFFFFFF}] }
        }
        sllv {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {($R([lindex $args 1]) << ($R([lindex $args 2]) & 0x1F)) & 0xFFFFFFFF}] }
        }
        srlv {
            set n [lindex $args 0]
            if {$n} { set R($n) [expr {$R([lindex $args 1]) >> ($R([lindex $args 2]) & 0x1F)}] }
        }
        srav {
            set n [lindex $args 0];  set sh [expr {$R([lindex $args 2]) & 0x1F}]
            set sv $R([lindex $args 1]); if {$sv >= 0x80000000} { set sv [expr {$sv - 0x100000000}] }
            if {$n} { set R($n) [expr {($sv >> $sh) & 0xFFFFFFFF}] }
        }

        div {
            set a $R([lindex $args 0]); if {$a >= 0x80000000} { set a [expr {$a - 0x100000000}] }
            set b $R([lindex $args 1]); if {$b >= 0x80000000} { set b [expr {$b - 0x100000000}] }
            if {$b != 0} {
                if {$a >= 0 && $b > 0} {
                    set LO [expr {$a / $b}];  set HI [expr {$a % $b}]
                } else {
                    set sign [expr {($a < 0) ^ ($b < 0)}]
                    set aa [expr {abs($a)}];  set ab [expr {abs($b)}]
                    set q  [expr {$aa / $ab}];  set r [expr {$aa % $ab}]
                    set LO [expr {($sign ? -$q : $q) & 0xFFFFFFFF}]
                    set HI [expr {($a < 0 ? -$r : $r) & 0xFFFFFFFF}]
                }
            }
        }
        divu {
            set a $R([lindex $args 0]);  set b $R([lindex $args 1])
            if {$b} { set LO [expr {$a / $b}];  set HI [expr {$a % $b}] }
        }
        mflo { set n [lindex $args 0]; if {$n} { set R($n) [expr {$LO & 0xFFFFFFFF}] } }
        mfhi { set n [lindex $args 0]; if {$n} { set R($n) [expr {$HI & 0xFFFFFFFF}] } }
        mtlo { set LO $R([lindex $args 0]) }
        mthi { set HI $R([lindex $args 0]) }

        sw {
            lassign [lindex $args 1] off base
            dict set mw [expr {($R($base) + $off) & 0xFFFFFFFF}] $R([lindex $args 0])
        }
        sh {
            lassign [lindex $args 1] off base
            dict set mh [expr {($R($base) + $off) & 0xFFFFFFFF}] [expr {$R([lindex $args 0]) & 0xFFFF}]
        }
        sb {
            # Byte store. Merge into the containing word so lbu (which reads
            # mem_w big-endian) sees the write, and keep mem_b so tests can
            # assert PIF command bytes without reconstructing words.
            lassign [lindex $args 1] off base
            set addr [expr {($R($base) + $off) & 0xFFFFFFFF}]
            set val  [expr {$R([lindex $args 0]) & 0xFF}]
            dict set mb $addr $val
            set w [expr {$addr & ~3}]
            set shift [expr {(3 - ($addr & 3)) * 8}]
            set cur [expr {[dict exists $mw $w] ? [dict get $mw $w] : 0}]
            dict set mw $w [expr {($cur & ~(0xFF << $shift)) | ($val << $shift)}]
        }

        lw {
            set n [lindex $args 0]
            lassign [lindex $args 1] off base
            set addr [expr {($R($base) + $off) & 0xFFFFFFFF}]
            # A preset address given a list of values models a register the
            # hardware changes under the program's feet: successive reads walk
            # the list and then hold the last value. Without it a wait loop that
            # spins on one register until it changes can never terminate.
            if {[dict exists $mseq $addr]} {
                set vals [dict get $mseq $addr]
                set i [dict get $mseqi $addr]
                if {$n} { set R($n) [lindex $vals $i] }
                if {$i + 1 < [llength $vals]} { dict set mseqi $addr [expr {$i + 1}] }
            } elseif {$n} {
                set R($n) [expr {[dict exists $mw $addr] ? [dict get $mw $addr] : 0}]
            }
        }
        lbu {
            set n [lindex $args 0]
            if {$n} {
                lassign [lindex $args 1] off base
                set addr [expr {($R($base) + $off) & 0xFFFFFFFF}]
                set w [expr {$addr & ~3}]
                set word [expr {[dict exists $mw $w] ? [dict get $mw $w] : 0}]
                set R($n) [expr {($word >> ((3 - ($addr & 3)) * 8)) & 0xFF}]
            }
        }
        lhu {
            set n [lindex $args 0]
            if {$n} {
                lassign [lindex $args 1] off base
                set addr [expr {($R($base) + $off) & 0xFFFFFFFF}]
                set R($n) [expr {[dict exists $mh $addr] ? [dict get $mh $addr] : 0}]
            }
        }
        lh {
            set n [lindex $args 0]
            if {$n} {
                lassign [lindex $args 1] off base
                set addr [expr {($R($base) + $off) & 0xFFFFFFFF}]
                set raw [expr {[dict exists $mh $addr] ? [dict get $mh $addr] : 0}]
                set R($n) [expr {$raw >= 0x8000 ? $raw - 0x10000 : $raw}]
            }
        }
        lb - lbu { set n [lindex $args 0]; if {$n} { set R($n) 0 } }

        beqz { if {$R([lindex $args 0]) == 0}  { return "jmp:[lindex $args 1]" } }
        bnez { if {$R([lindex $args 0]) != 0}  { return "jmp:[lindex $args 1]" } }
        beq  { if {$R([lindex $args 0]) == $R([lindex $args 1])} { return "jmp:[lindex $args 2]" } }
        bne  { if {$R([lindex $args 0]) != $R([lindex $args 1])} { return "jmp:[lindex $args 2]" } }
        blez {
            set v $R([lindex $args 0]); if {$v >= 0x80000000} { set v [expr {$v - 0x100000000}] }
            if {$v <= 0} { return "jmp:[lindex $args 1]" }
        }
        bgtz {
            set v $R([lindex $args 0]); if {$v >= 0x80000000} { set v [expr {$v - 0x100000000}] }
            if {$v >  0} { return "jmp:[lindex $args 1]" }
        }
        bltz {
            set v $R([lindex $args 0]); if {$v >= 0x80000000} { set v [expr {$v - 0x100000000}] }
            if {$v <  0} { return "jmp:[lindex $args 1]" }
        }
        bgez {
            set v $R([lindex $args 0]); if {$v >= 0x80000000} { set v [expr {$v - 0x100000000}] }
            if {$v >= 0} { return "jmp:[lindex $args 1]" }
        }
        bge {
            # Pseudo: slt $at, s1, s2; beq $at, $0, lbl  — branch if s1 >= s2.
            set a $R([lindex $args 0]); if {$a >= 0x80000000} { set a [expr {$a - 0x100000000}] }
            set b $R([lindex $args 1]); if {$b >= 0x80000000} { set b [expr {$b - 0x100000000}] }
            if {$a >= $b} { return "jmp:[lindex $args 2]" }
        }

        la {
            set n [lindex $args 0]
            set sym [lindex $args 1]
            if {$n} {
                set R($n) [expr {[dict exists $dsyms $sym] ? [dict get $dsyms $sym] : 0}]
            }
        }

        j    { return "jmp:[lindex $args 0]" }
        jal  { return "call:[lindex $args 0]" }
        jr {
            # The simulator works on an instruction list rather than addresses,
            # so $ra holds the index of the instruction after the call's delay
            # slot. `jr $ra` returns there; $ra starts out invalid, so the
            # outermost return ends the run. Computed jumps are not modelled.
            set n [lindex $args 0]
            if {$n eq "" || $R($n) == 0xFFFFFFFF} { return "done" }
            return "ret:$R($n)"
        }
        jalr { return "done" }
    }
    return ""
}

# ── public run procedure ──────────────────────────────────────────────────────

proc run {text {start "main"} {limit 20000000} {preset {}}} {
    lassign [parse_asm $text] labels insns dsyms dimage
    set n_insns [llength $insns]

    if {![dict exists $labels $start]} {
        error "pak::mips_sim: label '$start' not found"
    }

    # simulation state (local to run; exec_insn accesses via upvar 1)
    array set R {0 0 1 0 2 0 3 0 4 0 5 0 6 0 7 0
                 8 0 9 0 10 0 11 0 12 0 13 0 14 0 15 0
                 16 0 17 0 18 0 19 0 20 0 21 0 22 0 23 0
                 24 0 25 0 26 0 27 0 28 0 29 0 30 0 31 0}
    set R(29) [expr {0x80380000}]   ;# $sp — RDRAM top
    set R(31) 0xFFFFFFFF            ;# $ra — invalid, so the outermost jr halts
    set HI 0;  set LO 0
    set mh [dict create]   ;# sh stores
    set mb [dict create]   ;# sb stores
    # Seed memory with the data sections so a static's initialiser is readable,
    # then with any caller-supplied values. `preset` is how a test models MMIO
    # the program polls: without it a status register reads 0 forever and a
    # hardware wait loop never exits.
    set mw $dimage
    set mseq  [dict create]
    set mseqi [dict create]
    dict for {a v} $preset {
        set addr [expr {$a}]
        if {[llength $v] > 1} {
            set vals {}
            foreach e $v { lappend vals [expr {$e}] }
            dict set mseq $addr $vals
            dict set mseqi $addr 0
        } else {
            dict set mw $addr [expr {$v}]
        }
    }

    set pc    [dict get $labels $start]
    set count 0

    while {$pc < $n_insns && $count < $limit} {
        incr count
        set instr  [lindex $insns $pc]
        set result [exec_insn {*}$instr]

        if {$result eq "done"} break

        if {[string match "jmp:*" $result] || [string match "call:*" $result]} {
            # MIPS branch delay slot: instruction at PC+1 always executes
            set ds [lindex $insns [expr {$pc + 1}]]
            if {[llength $ds]} { incr count; exec_insn {*}$ds }
            if {[string match "call:*" $result]} {
                set R(31) [expr {$pc + 2}]
                set lbl [string range $result 5 end]
            } else {
                set lbl [string range $result 4 end]
            }
            if {![dict exists $labels $lbl]} break   ;# external symbol — halt
            set new_pc [dict get $labels $lbl]
            if {$new_pc == $pc} break                ;# self-loop = infinite loop; halt
            set pc $new_pc
        } elseif {[string match "ret:*" $result]} {
            set ds [lindex $insns [expr {$pc + 1}]]
            if {[llength $ds]} { incr count; exec_insn {*}$ds }
            set pc [string range $result 4 end]
        } else {
            incr pc
        }
    }

    return [dict create mem_b $mb mem_h $mh mem_w $mw insns $count]
}

} ;# namespace eval pak::mipsim

proc pak::mips_sim_run {args} { pak::mipsim::run {*}$args }
