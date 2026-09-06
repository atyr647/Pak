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
    s8 30
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
# ── single-precision floating point ──────────────────────────────────────────
# FP registers hold the 32-bit IEEE-754 bit pattern, the way the hardware does,
# so a value that moves through mtc1/mfc1 or lwc1/swc1 round-trips exactly.
# Arithmetic converts out to a Tcl double and back, which rounds to nearest --
# the VR4300's default rounding mode.
proc fbits_to_double {bits} {
    binary scan [binary format Iu [expr {$bits & 0xFFFFFFFF}]] R v
    return $v
}
proc double_to_fbits {v} {
    if {[catch {set b [binary format R $v]}]} { return 0 }
    binary scan $b Iu bits
    return $bits
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
    set word_fixups {}

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
                            if {![string is integer -strict $v]} {
                                # `.word <symbol>` -- a vtable slot, or any
                                # other pointer the assembler resolves. The
                                # label may not be parsed yet, so record the
                                # address and fill it in below. Writing 0, as
                                # this did, made every vtable a table of null
                                # function pointers.
                                lappend word_fixups [list $daddr $v]
                                set v 0
                            }
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
    # `.word <symbol>` fixups, now that every label is known. A text label
    # resolves to the same value `la` gives it -- the instruction index -- so a
    # function pointer read out of a vtable is callable through jalr.
    foreach fx $word_fixups {
        lassign $fx addr sym
        set v 0
        if {[dict exists $labels $sym]} {
            set v [dict get $labels $sym]
        } elseif {[dict exists $data_syms $sym]} {
            set v [dict get $data_syms $sym]
        }
        for {set i 3} {$i >= 0} {incr i -1} {
            _dbyte data_image $addr [expr {($v >> ($i * 8)) & 0xFF}]
            incr addr
        }
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

# An FP register's raw bits, and its value as a double. Reading an untouched
# register gives zero rather than an error, matching every other register file
# in this simulator.
proc fp {n} {
    upvar 1 F F
    if {[info exists F($n)]} { return $F($n) }
    return 0
}
proc fpv {n} {
    upvar 1 F F
    if {[info exists F($n)]} { return [fbits_to_double $F($n)] }
    return 0.0
}

proc exec_insn {op args} {
    upvar 1 R R  HI HI  LO LO  mb mb  mh mh  mw mw  dsyms dsyms  labels labels  mseq mseq  mseqi mseqi  cart cart  dp_kicks dp_kicks  F F  FCC FCC  C0 C0

    switch -- $op {
        nop - sync { return "" }

        mfc0 {
            # CP0: Status, Cause and friends. Nothing here changes how the
            # simulator runs -- no interrupts, no TLB -- but boot.S reads
            # Status, masks BEV and IE and writes it back, and a no-op mfc0
            # would hand it whatever was already in the destination register.
            set n [lindex $args 0]
            set c [expr {[lindex $args 1]}]
            if {$n} { set R($n) [expr {[dict exists $C0 $c] ? [dict get $C0 $c] : 0}] }
        }
        mtc0 {
            dict set C0 [expr {[lindex $args 1]}] $R([lindex $args 0])
        }
        eret {
            # Return from an exception: clear Status.EXL and jump to EPC
            # (CP0 register 14). Nothing here raises an exception, so EPC only
            # ever holds what something wrote to it -- and an `eret` reached
            # with EPC unset ends the run rather than jumping to zero. The
            # instruction is implemented so that an image containing it is not
            # quietly executed as if the instruction were a nop.
            set st [expr {[dict exists $C0 12] ? [dict get $C0 12] : 0}]
            dict set C0 12 [expr {$st & ~0x2}]
            if {![dict exists $C0 14] || [dict get $C0 14] == 0} { return "done" }
            return "jmp:[dict get $C0 14]"
        }

        mtc1 {
            # FPU, single precision. Registers are addressed by number, so the
            # codegen's habit of writing a GPR name in an FP slot ($a0 meaning
            # $f4, which is what gas makes of it) resolves the same way here as
            # it does in the encoder.
            set F([lindex $args 1]) $R([lindex $args 0])
        }
        mfc1 {
            set n [lindex $args 0]
            if {$n} { set R($n) [fp [lindex $args 1]] }
        }
        mov.s { set F([lindex $args 0]) [fp [lindex $args 1]] }
        neg.s { set F([lindex $args 0]) [double_to_fbits [expr {-[fpv [lindex $args 1]]}]] }
        abs.s { set F([lindex $args 0]) [double_to_fbits [expr {abs([fpv [lindex $args 1]])}]] }
        sqrt.s {
            set v [fpv [lindex $args 1]]
            set F([lindex $args 0]) [double_to_fbits [expr {$v < 0 ? 0.0 : sqrt($v)}]]
        }
        add.s - sub.s - mul.s - div.s {
            set a [fpv [lindex $args 1]]
            set b [fpv [lindex $args 2]]
            switch -- $op {
                add.s { set r [expr {$a + $b}] }
                sub.s { set r [expr {$a - $b}] }
                mul.s { set r [expr {$a * $b}] }
                div.s { if {$b == 0.0} { set r 0.0 } else { set r [expr {$a / $b}] } }
            }
            set F([lindex $args 0]) [double_to_fbits $r]
        }
        cvt.s.w {
            set w [fp [lindex $args 1]]
            if {$w >= 0x80000000} { set w [expr {$w - 0x100000000}] }
            set F([lindex $args 0]) [double_to_fbits [expr {double($w)}]]
        }
        cvt.w.s {
            set v [fpv [lindex $args 1]]
            set F([lindex $args 0]) [expr {int($v) & 0xFFFFFFFF}]
        }
        c.eq.s - c.lt.s - c.le.s {
            set a [fpv [lindex $args 0]]
            set b [fpv [lindex $args 1]]
            switch -- $op {
                c.eq.s { set FCC [expr {$a == $b}] }
                c.lt.s { set FCC [expr {$a <  $b}] }
                c.le.s { set FCC [expr {$a <= $b}] }
            }
        }
        bc1t { if {$FCC}  { return "jmp:[lindex $args 0]" } }
        bc1f { if {!$FCC} { return "jmp:[lindex $args 0]" } }
        lwc1 {
            lassign [lindex $args 1] off base
            set a [expr {($R($base) + $off) & 0xFFFFFFFF}]
            set F([lindex $args 0]) [expr {[dict exists $mw $a] ? [dict get $mw $a] : 0}]
        }
        swc1 {
            lassign [lindex $args 1] off base
            set a [expr {($R($base) + $off) & 0xFFFFFFFF}]
            dict set mw $a [fp [lindex $args 0]]
        }

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
        mult {
            # Signed 64-bit product into HI:LO. Used by fix16.16 multiply.
            set a $R([lindex $args 0]); if {$a >= 0x80000000} { set a [expr {$a - 0x100000000}] }
            set b $R([lindex $args 1]); if {$b >= 0x80000000} { set b [expr {$b - 0x100000000}] }
            set p [expr {$a * $b}]
            set LO [expr {$p & 0xFFFFFFFF}]
            set HI [expr {($p >> 32) & 0xFFFFFFFF}]
        }
        multu {
            set a $R([lindex $args 0])
            set b $R([lindex $args 1])
            set p [expr {$a * $b}]
            set LO [expr {$p & 0xFFFFFFFF}]
            set HI [expr {($p >> 32) & 0xFFFFFFFF}]
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
        sleu - sgtu - sgeu {
            # The unsigned counterparts of sle/sgt/sge. R() already holds the
            # unsigned 32-bit value, so these need no sign fixup.
            set n [lindex $args 0]
            if {$n} {
                set a $R([lindex $args 1]);  set b $R([lindex $args 2])
                switch -- $op {
                    sleu { set R($n) [expr {$a <= $b ? 1 : 0}] }
                    sgtu { set R($n) [expr {$a >  $b ? 1 : 0}] }
                    sgeu { set R($n) [expr {$a >= $b ? 1 : 0}] }
                }
            }
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
            # `div $zero, rs, rt` -- the three-operand spelling that keeps GNU
            # as from expanding its checked macro. The dest is always $zero.
            if {[llength $args] == 3} { set args [lrange $args 1 2] }
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
            if {[llength $args] == 3} { set args [lrange $args 1 2] }
            set a $R([lindex $args 0]);  set b $R([lindex $args 1])
            if {$b} { set LO [expr {$a / $b}];  set HI [expr {$a % $b}] }
        }
        mflo { set n [lindex $args 0]; if {$n} { set R($n) [expr {$LO & 0xFFFFFFFF}] } }
        mfhi { set n [lindex $args 0]; if {$n} { set R($n) [expr {$HI & 0xFFFFFFFF}] } }
        mtlo { set LO $R([lindex $args 0]) }
        mthi { set HI $R([lindex $args 0]) }

        sw {
            lassign [lindex $args 1] off base
            set _a [expr {($R($base) + $off) & 0xFFFFFFFF}]
            dict set mw $_a $R([lindex $args 0])
            # PI_WR_LEN is the register that starts a cart -> RDRAM transfer.
            # Without moving the bytes, a program that streams from the
            # cartridge reads whatever was already in RDRAM -- which for a
            # texture page means it samples zeros and renders black, with every
            # PI register still holding exactly the right value.
            # DPC_END starts the DP on [DPC_START, DPC_END). A program that
            # builds more commands than the display list holds submits several
            # times per frame, each time refilling the buffer from the top, so
            # reading that buffer once at the end sees only the last fragment.
            # Recording each kick's bytes as it happens keeps the whole frame.
            if {$_a == [expr {0xA4100004}]} {
                set _st [expr {0xA4100000}]
                if {[dict exists $mw $_st]} {
                    set _s [dict get $mw $_st]
                    set _e [expr {$R([lindex $args 0]) & 0xFFFFFFFF}]
                    if {$_e > $_s} {
                        set _bytes ""
                        for {set _p $_s} {$_p < $_e} {incr _p 4} {
                            set _va [expr {($_p & 0x1FFFFFFF) | 0xA0000000}]
                            set _wv 0
                            if {[dict exists $mw $_va]} { set _wv [dict get $mw $_va] }
                            append _bytes [binary format I [expr {$_wv & 0xFFFFFFFF}]]
                        }
                        lappend dp_kicks $_bytes
                    }
                }
            }
            if {$_a == 0xA460000C && $cart ne ""} {
                # The dict is keyed by integer addresses, so the hex literal
                # has to be evaluated before it is used as a key.
                set _pd [expr {0xA4600000}]
                set _pc [expr {0xA4600004}]
                pi_dma_read mw $cart \
                    [expr {[dict exists $mw $_pd] ? [dict get $mw $_pd] : 0}] \
                    [expr {[dict exists $mw $_pc] ? [dict get $mw $_pc] : 0}] \
                    [expr {($R([lindex $args 0]) & 0xFFFFFF) + 1}]
            }
        }
        sh {
            # Half store. Like sb: mem_w is the memory, mem_h is only a record
            # of what was stored narrowly, kept so tests can assert a halfword
            # without reconstructing the word around it.
            lassign [lindex $args 1] off base
            set addr [expr {($R($base) + $off) & 0xFFFFFFFF}]
            set val  [expr {$R([lindex $args 0]) & 0xFFFF}]
            dict set mh $addr $val
            set w [expr {$addr & ~3}]
            set shift [expr {(2 - ($addr & 2)) * 8}]
            set cur [expr {[dict exists $mw $w] ? [dict get $mw $w] : 0}]
            dict set mw $w [expr {($cur & ~(0xFFFF << $shift)) | ($val << $shift)}]
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
            } elseif {$addr == [expr {0xA4600010}]} {
                # PI_STATUS is not a latch: a write means "clear interrupt" or
                # "reset controller", a read means "these are the busy bits".
                # Reading back the written word made dma_wait() spin on the
                # IO_BUSY bit of its own PI_STATUS_CLR_INTR store, so every
                # DMA in the simulator hung until the instruction limit. The
                # simulated transfer is instantaneous, so nothing is busy.
                if {$n} { set R($n) 0 }
            } elseif {$n} {
                set R($n) [expr {[dict exists $mw $addr] ? [dict get $mw $addr] : 0}]
            }
        }
        lbu - lb - lhu - lh {
            # mem_w is THE memory: `sb`/`sh` merge their store into the word
            # that contains it, and a .byte or .half in the data image only
            # ever existed as part of a word. So a narrow load reads mem_w and
            # nothing else. Consulting mem_b/mem_h first, as this did, made a
            # byte store permanently shadow the word stores that came after it:
            # zero a pool slot with `sb`, write a field with `sw`, read the
            # field back through `lbu`, and the read still saw the zero.
            set n [lindex $args 0]
            if {$n} {
                lassign [lindex $args 1] off base
                set addr [expr {($R($base) + $off) & 0xFFFFFFFF}]
                set w [expr {$addr & ~3}]
                set word [expr {[dict exists $mw $w] ? [dict get $mw $w] : 0}]
                if {$op eq "lbu" || $op eq "lb"} {
                    set v [expr {($word >> ((3 - ($addr & 3)) * 8)) & 0xFF}]
                    if {$op eq "lb" && $v >= 0x80} { set v [expr {$v - 0x100}] }
                } else {
                    set v [expr {($word >> ((2 - ($addr & 2)) * 8)) & 0xFFFF}]
                    if {$op eq "lh" && $v >= 0x8000} { set v [expr {$v - 0x10000}] }
                }
                set R($n) [expr {$v & 0xFFFFFFFF}]
            }
        }

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
                if {[dict exists $labels $sym]} {
                    set R($n) [dict get $labels $sym]
                } elseif {[dict exists $dsyms $sym]} {
                    set R($n) [dict get $dsyms $sym]
                } else {
                    set R($n) 0
                }
            }
        }

        j    { return "jmp:[lindex $args 0]" }
        jal  { return "call:[lindex $args 0]" }
        jr {
            # The simulator works on an instruction list rather than addresses,
            # so $ra holds the index of the instruction after the call's delay
            # slot. `jr $ra` returns there; $ra starts out invalid, so the
            # outermost return ends the run.
            set n [lindex $args 0]
            if {$n eq "" || $R($n) == 0xFFFFFFFF} { return "done" }
            return "ret:$R($n)"
        }
        jalr {
            # `jalr $rs` or `jalr $rd, $rs` — target is the last register.
            set n [lindex $args end]
            if {$n eq "" || $R($n) == 0xFFFFFFFF} { return "done" }
            return "callidx:$R($n)"
        }
    }
    return ""
}

# What a call leaves in $ra: an instruction index, or the address of that
# instruction when the listing came from a linked image.
proc ret_slot {text_base idx} {
    if {$text_base eq ""} { return $idx }
    return [expr {($text_base + $idx * 4) & 0xFFFFFFFF}]
}

# The instruction index a jump target names. "" when the value is not an
# instruction in this listing, which ends the run rather than jumping wild.
proc to_index {text_base v} {
    if {![string is integer -strict $v]} { return "" }
    if {$text_base eq ""} { return $v }
    set off [expr {($v & 0xFFFFFFFF) - $text_base}]
    if {$off < 0 || ($off & 3)} { return "" }
    return [expr {$off / 4}]
}

# ── public run procedure ──────────────────────────────────────────────────────

# Copy `len` bytes out of the cart image into simulated RDRAM, as the PI does.
# dram is the physical address the program wrote to PI_DRAM_ADDR; the CPU sees
# that memory through KSEG0, which is where the words are stored.
proc pi_dma_read {mwVar cart dram cart_addr len} {
    upvar 1 $mwVar mw
    set src [expr {$cart_addr & 0x0FFFFFFF}]
    set dst [expr {($dram & 0x00FFFFFF) | 0x80000000}]
    set have [string length $cart]
    for {set i 0} {$i < $len} {incr i 4} {
        set w 0
        for {set b 0} {$b < 4} {incr b} {
            set o [expr {$src + $i + $b}]
            set byte 0
            if {$o < $have} { binary scan [string index $cart $o] cu byte }
            set w [expr {($w << 8) | $byte}]
        }
        dict set mw [expr {($dst + $i) & 0xFFFFFFFF}] $w
    }
}

# `text_base`, when given, says the listing is a disassembly of a linked image:
# instruction N lives at text_base + 4*N. With it, $ra holds a real return
# ADDRESS rather than an instruction index, so `jalr` through a pointer loaded
# by `la` lands on the right instruction. Without it the simulator behaves
# exactly as before -- $ra is an index and only direct calls work.
proc run {text {start "main"} {limit 20000000} {preset {}} {cart ""} {text_base ""}} {
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
    array set F {}         ;# FP registers, as 32-bit IEEE-754 bit patterns
    set FCC 0              ;# the FPU condition bit bc1t/bc1f test
    set C0 [dict create]   ;# CP0 registers, by number
    set mh [dict create]   ;# sh stores
    set mb [dict create]   ;# sb stores
    # Seed memory with the data sections so a static's initialiser is readable,
    # then with any caller-supplied values. `preset` is how a test models MMIO
    # the program polls: without it a status register reads 0 forever and a
    # hardware wait loop never exits.
    set mw $dimage
    set mseq  [dict create]
    set mseqi [dict create]
    set dp_kicks {}
    # `cart` is read by the sw handler through upvar, like mw/mh/mb.
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

        if {[string match "jmp:*" $result] || [string match "call:*" $result] \
            || [string match "callidx:*" $result]} {
            # MIPS branch delay slot: instruction at PC+1 always executes
            set ds [lindex $insns [expr {$pc + 1}]]
            if {[llength $ds]} { incr count; exec_insn {*}$ds }
            if {[string match "callidx:*" $result]} {
                set R(31) [ret_slot $text_base [expr {$pc + 2}]]
                set new_pc [string range $result 8 end]
                if {![string is integer -strict $new_pc]} break
                set new_pc [to_index $text_base $new_pc]
                if {$new_pc eq "" || $new_pc < 0 || $new_pc >= $n_insns} break
                if {$new_pc == $pc} break
                set pc $new_pc
                continue
            }
            if {[string match "call:*" $result]} {
                set R(31) [ret_slot $text_base [expr {$pc + 2}]]
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
            set pc [to_index $text_base [string range $result 4 end]]
            if {$pc eq ""} break
        } else {
            incr pc
        }
    }

    # `halted` distinguishes a program that ran to completion from one the
    # instruction limit cut off mid-flight. A test that only reads registers
    # passes either way, which is how a hung DMA went unnoticed.
    # Registers come back too: a test that runs a whole boot sequence has to be
    # able to ask what $sp ended up as, and nothing else in the result says.
    set regs [dict create]
    for {set i 0} {$i < 32} {incr i} { dict set regs $i $R($i) }
    return [dict create mem_b $mb mem_h $mh mem_w $mw insns $count data_syms $dsyms \
                        dp_kicks $dp_kicks halted [expr {$count < $limit}] regs $regs]
}

} ;# namespace eval pak::mipsim

proc pak::mips_sim_run {args} { pak::mipsim::run {*}$args }
