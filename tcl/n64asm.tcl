# tcl/n64asm.tcl — a self-contained MIPS-I/III assembler for the subset of
# instructions the Pak MIPS backend emits. Turns the backend's .s text into a
# flat machine-code image (no binutils). Pseudo-ops are expanded to match GNU
# as (-march=vr4300); validated byte-for-byte against mips64-elf-as.
#
# pak::n64asm {asm_text base_addr} -> dict {text <bytes> rodata <bytes>
#   data <bytes> bss <int> entry <addr> symbols <dict name->addr>}

namespace eval pak::asm {}
if {[info exists ::pak::_n64asm_loaded]} { return }
set ::pak::_n64asm_loaded 1

# ── Register numbers ──────────────────────────────────────────────────────────
set ::pak::asm::GPR [dict create \
    {$zero} 0 {$at} 1 {$v0} 2 {$v1} 3 {$a0} 4 {$a1} 5 {$a2} 6 {$a3} 7 \
    {$t0} 8 {$t1} 9 {$t2} 10 {$t3} 11 {$t4} 12 {$t5} 13 {$t6} 14 {$t7} 15 \
    {$s0} 16 {$s1} 17 {$s2} 18 {$s3} 19 {$s4} 20 {$s5} 21 {$s6} 22 {$s7} 23 \
    {$t8} 24 {$t9} 25 {$k0} 26 {$k1} 27 {$gp} 28 {$sp} 29 {$fp} 30 {$s8} 30 {$ra} 31]
proc pak::asm::gpr {r} {
    set r [string trim $r ,]
    if {![dict exists $::pak::asm::GPR $r]} { error "n64asm: unknown register '$r'" }
    return [dict get $::pak::asm::GPR $r]
}
proc pak::asm::fpr {r} { set r [string trim $r ,]; return [string range $r 2 end] } ;# $fN -> N

# ── Instruction encoders (return a 32-bit int) ───────────────────────────────
proc pak::asm::R {op rs rt rd shamt funct} {
    return [expr {(($op & 0x3f) << 26) | (($rs & 0x1f) << 21) | (($rt & 0x1f) << 16) \
        | (($rd & 0x1f) << 11) | (($shamt & 0x1f) << 6) | ($funct & 0x3f)}]
}
proc pak::asm::I {op rs rt imm} {
    return [expr {(($op & 0x3f) << 26) | (($rs & 0x1f) << 21) | (($rt & 0x1f) << 16) | ($imm & 0xffff)}]
}
proc pak::asm::J {op target} {
    return [expr {(($op & 0x3f) << 26) | (($target >> 2) & 0x3ffffff)}]
}

# operand splitter: "$t0, $t1, $t2" -> {$t0 $t1 $t2}
proc pak::asm::ops {operands} {
    set out {}
    foreach o [split $operands ,] { set o [string trim $o]; if {$o ne ""} { lappend out $o } }
    return $out
}
# parse "off($base)" -> {off base}
proc pak::asm::mem {operand} {
    if {[regexp {^(-?\w+)?\(([^)]+)\)$} [string trim $operand] -> off base]} {
        if {$off eq ""} { set off 0 }
        return [list $off $base]
    }
    error "n64asm: bad mem operand '$operand'"
}

# R-type funct codes (op=0) and I-type opcodes.
set ::pak::asm::RFUNCT [dict create addu 0x21 subu 0x23 and 0x24 or 0x25 xor 0x26 nor 0x27 \
    slt 0x2a sltu 0x2b sllv 0x04 srlv 0x06 srav 0x07]
set ::pak::asm::SHIFT [dict create sll 0x00 srl 0x02 sra 0x03]
set ::pak::asm::IOPC [dict create addiu 0x09 andi 0x0c ori 0x0d xori 0x0e slti 0x0a sltiu 0x0b]
set ::pak::asm::LOADC [dict create lw 0x23 lh 0x21 lhu 0x25 lb 0x20 lbu 0x24 sw 0x2b sh 0x29 sb 0x28 \
    lwc1 0x31 swc1 0x39 ldc1 0x35 sdc1 0x3d]

# Expand one instruction line into a list of 32-bit words.
# addr = address of this instruction; syms = dict label->addr (0 if unknown in pass1).
proc pak::asm::encode {op operands addr syms} {
    set a [pak::asm::ops $operands]
    set R pak::asm::R; set I pak::asm::I; set J pak::asm::J; set g pak::asm::gpr
    switch -- $op {
        nop  { return [list 0] }
        move { return [list [$R 0 [$g [lindex $a 1]] 0 [$g [lindex $a 0]] 0 0x25]] } ;# or rd,rs,$zero
        not  { return [list [$R 0 [$g [lindex $a 1]] 0 [$g [lindex $a 0]] 0 0x27]] } ;# nor rd,rs,$zero
        addu - subu - and - or - xor - nor - slt - sltu {
            set f [dict get $::pak::asm::RFUNCT $op]
            return [list [$R 0 [$g [lindex $a 1]] [$g [lindex $a 2]] [$g [lindex $a 0]] 0 $f]]
        }
        sllv - srlv - srav {
            set f [dict get $::pak::asm::RFUNCT $op]
            return [list [$R 0 [$g [lindex $a 2]] [$g [lindex $a 1]] [$g [lindex $a 0]] 0 $f]]
        }
        sll - srl - sra {
            set f [dict get $::pak::asm::SHIFT $op]
            return [list [$R 0 0 [$g [lindex $a 1]] [$g [lindex $a 0]] [expr {[lindex $a 2] & 0x1f}] $f]]
        }
        addiu - andi - ori - xori - slti - sltiu {
            set opc [dict get $::pak::asm::IOPC $op]
            return [list [$I $opc [$g [lindex $a 1]] [$g [lindex $a 0]] [pak::asm::imm [lindex $a 2]]]]
        }
        lui { return [list [$I 0x0f 0 [$g [lindex $a 0]] [pak::asm::imm [lindex $a 1]]]] }
        lw - lh - lhu - lb - lbu - sw - sh - sb - lwc1 - swc1 - ldc1 - sdc1 {
            set opc [dict get $::pak::asm::LOADC $op]
            lassign [pak::asm::mem [lindex $a 1]] off base
            set rt [expr {$op in {lwc1 swc1 ldc1 sdc1} ? [pak::asm::fpr [lindex $a 0]] : [$g [lindex $a 0]]}]
            return [list [$I $opc [$g $base] $rt [pak::asm::imm $off]]]
        }
        mult { return [list [$R 0 [$g [lindex $a 0]] [$g [lindex $a 1]] 0 0 0x18]] }
        multu { return [list [$R 0 [$g [lindex $a 0]] [$g [lindex $a 1]] 0 0 0x19]] }
        div  { return [list [$R 0 [$g [lindex $a 0]] [$g [lindex $a 1]] 0 0 0x1a]] }
        divu { return [list [$R 0 [$g [lindex $a 0]] [$g [lindex $a 1]] 0 0 0x1b]] }
        mflo { return [list [$R 0 0 0 [$g [lindex $a 0]] 0 0x12]] }
        mfhi { return [list [$R 0 0 0 [$g [lindex $a 0]] 0 0x10]] }
        mul  { ;# VR4300 has no mul: GNU as expands to multu rs,rt ; mflo rd
            return [list [$R 0 [$g [lindex $a 1]] [$g [lindex $a 2]] 0 0 0x19] \
                         [$R 0 0 0 [$g [lindex $a 0]] 0 0x12]]
        }
        jr   { return [list [$R 0 [$g [lindex $a 0]] 0 0 0 0x08]] }
        jalr { ;# jalr $ra, $reg  (or jalr $reg)
            if {[llength $a] == 2} { set rd [$g [lindex $a 0]]; set rs [$g [lindex $a 1]] } \
            else { set rd 31; set rs [$g [lindex $a 0]] }
            return [list [$R 0 $rs 0 $rd 0 0x09]]
        }
        j - jal {
            set opc [expr {$op eq "j" ? 0x02 : 0x03}]
            set tgt [pak::asm::sym [lindex $a 0] $syms]
            return [list [$J $opc $tgt]]
        }
        beq - bne {
            set opc [expr {$op eq "beq" ? 0x04 : 0x05}]
            set tgt [pak::asm::sym [lindex $a 2] $syms]
            set off [expr {($tgt - ($addr + 4)) >> 2}]
            return [list [$I $opc [$g [lindex $a 0]] [$g [lindex $a 1]] $off]]
        }
        beqz - bnez {
            set opc [expr {$op eq "beqz" ? 0x04 : 0x05}]
            set tgt [pak::asm::sym [lindex $a 1] $syms]
            set off [expr {($tgt - ($addr + 4)) >> 2}]
            return [list [$I $opc [$g [lindex $a 0]] 0 $off]]
        }
        li   { return [pak::asm::expand_li [$g [lindex $a 0]] [pak::asm::imm [lindex $a 1]]] }
        la   {
            set addr32 [pak::asm::sym [lindex $a 1] $syms]
            return [pak::asm::expand_la [$g [lindex $a 0]] $addr32]
        }
        mtc1 { return [list [pak::asm::R 0x11 0x04 [$g [lindex $a 0]] [pak::asm::fpr [lindex $a 1]] 0 0]] }
        mfc1 { return [list [pak::asm::R 0x11 0x00 [$g [lindex $a 0]] [pak::asm::fpr [lindex $a 1]] 0 0]] }
        cvt.s.w { return [list [pak::asm::R 0x11 0x14 0 [pak::asm::fpr [lindex $a 1]] [pak::asm::fpr [lindex $a 0]] 0x20]] }
        cvt.w.s { return [list [pak::asm::R 0x11 0x10 0 [pak::asm::fpr [lindex $a 1]] [pak::asm::fpr [lindex $a 0]] 0x24]] }
        sync { return [list [pak::asm::R 0 0 0 0 0 0x0f]] }
        bge - bgt - ble - blt {
            return [pak::asm::expand_branch_cmp $op $a $addr $syms]
        }
        sge - sgt - sle - seq - sne {
            return [pak::asm::expand_set_cmp $op $a]
        }
        default { error "n64asm: unhandled instruction '$op $operands'" }
    }
}

# li expansion (matches GNU as): fits in [0,0xffff] -> ori; signed16 -> addiu;
# else lui (+ ori if low bits set).
proc pak::asm::expand_li {rd v} {
    set v [expr {$v & 0xffffffff}]
    set sv [expr {$v >= 0x80000000 ? $v - 0x100000000 : $v}]
    if {$sv >= -32768 && $sv <= 32767} {
        return [list [pak::asm::I 0x09 0 $rd [expr {$v & 0xffff}]]] ;# addiu rd,$zero,v
    } elseif {$v <= 0xffff} {
        return [list [pak::asm::I 0x0d 0 $rd $v]]            ;# ori rd,$zero,v
    } else {
        set hi [expr {($v >> 16) & 0xffff}]
        set lo [expr {$v & 0xffff}]
        if {$lo == 0} { return [list [pak::asm::I 0x0f 0 $rd $hi]] }
        return [list [pak::asm::I 0x0f 0 $rd $hi] [pak::asm::I 0x0d $rd $rd $lo]]
    }
}
# la of an absolute address: lui + ori (addresses here are KSEG entries, high bit set)
proc pak::asm::expand_la {rd addr32} {
    # GNU as: lui rd,%hi ; addiu rd,rd,%lo  with the %hi carry adjustment so the
    # sign-extension of the %lo addiu reconstructs the exact 32-bit address.
    set lo [expr {$addr32 & 0xffff}]
    set hi [expr {(($addr32 >> 16) + (($addr32 >> 15) & 1)) & 0xffff}]
    if {$lo == 0} { return [list [pak::asm::I 0x0f 0 $rd $hi]] }
    return [list [pak::asm::I 0x0f 0 $rd $hi] [pak::asm::I 0x09 $rd $rd $lo]]
}
proc pak::asm::expand_branch_cmp {op a addr syms} {
    set g pak::asm::gpr
    set s [$g [lindex $a 0]]; set t [$g [lindex $a 1]]
    set tgt [pak::asm::sym [lindex $a 2] $syms]
    # slt $at, ... ; beq/bne $at,$zero,target  (target offset relative to 2nd instr)
    set off [expr {($tgt - ($addr + 8)) >> 2}]
    switch -- $op {
        bge { set slt [pak::asm::R 0 $s $t 1 0 0x2a]; set br [pak::asm::I 0x04 1 0 $off] } ;# !(s<t)
        blt { set slt [pak::asm::R 0 $s $t 1 0 0x2a]; set br [pak::asm::I 0x05 1 0 $off] } ;# s<t
        bgt { set slt [pak::asm::R 0 $t $s 1 0 0x2a]; set br [pak::asm::I 0x05 1 0 $off] } ;# t<s
        ble { set slt [pak::asm::R 0 $t $s 1 0 0x2a]; set br [pak::asm::I 0x04 1 0 $off] } ;# !(t<s)
    }
    return [list $slt $br]
}
proc pak::asm::expand_set_cmp {op a} {
    set g pak::asm::gpr
    set d [$g [lindex $a 0]]; set s [$g [lindex $a 1]]; set t [$g [lindex $a 2]]
    switch -- $op {
        sgt { return [list [pak::asm::R 0 $t $s $d 0 0x2a]] }                              ;# slt d,t,s
        sge { return [list [pak::asm::R 0 $s $t $d 0 0x2a] [pak::asm::I 0x0e $d $d 1]] }    ;# slt;xori 1
        sle { return [list [pak::asm::R 0 $t $s $d 0 0x2a] [pak::asm::I 0x0e $d $d 1]] }    ;# slt d,t,s;xori 1
        seq { return [list [pak::asm::R 0 $s $t $d 0 0x23] [pak::asm::I 0x0b $d $d 1]] }    ;# subu;sltiu d,d,1
        sne { return [list [pak::asm::R 0 $s $t $d 0 0x23] [pak::asm::R 0 0 $d $d 0 0x2b]] };# subu;sltu d,$zero,d
    }
}

# resolve an immediate (decimal/hex) to an int
proc pak::asm::imm {tok} {
    set tok [string trim $tok ,]
    if {[string match -nocase "0x*" $tok]} { return [expr {$tok}] }
    return [expr {$tok}]
}
# resolve a symbol or numeric to an address
proc pak::asm::sym {tok syms} {
    set tok [string trim $tok ,]
    if {[string is integer -strict $tok] || [string match -nocase "0x*" $tok]} { return [expr {$tok}] }
    if {[dict exists $syms $tok]} { return [dict get $syms $tok] }
    return 0  ;# unknown in pass 1
}

# Number of words an instruction occupies (for pass-1 sizing).
proc pak::asm::isize {op operands} {
    switch -- $op {
        mul - la - bge - bgt - ble - blt - sge - sle - seq - sne { return 2 }
        li {
            set a [pak::asm::ops $operands]
            return [llength [pak::asm::expand_li 1 [pak::asm::imm [lindex $a 1]]]]
        }
        default { return 1 }
    }
}

# ── Two-pass assembler/linker → flat image ────────────────────────────────────
# Lays out .text, then .rodata, then .data contiguously starting at `base`;
# .bss size is returned separately. Returns a dict.
proc pak::n64asm {asm_text base} {
    # Bucket items by section, preserving order.
    set sec text
    set items [dict create text {} rodata {} data {} bss {}]
    foreach raw [split $asm_text "\n"] {
        set line [string trimright $raw]
        if {$line eq ""} continue
        set t [string trim $line]
        if {[string index $t 0] eq "#"} continue
        # strip trailing '# ...' comments (but keep '#' inside .asciiz strings)
        if {![string match {.asciiz*} $t]} { set t [string trim [regsub {\s*#.*$} $t ""]] }
        if {$t eq ""} continue
        # label?
        if {[regexp {^([A-Za-z_.$][\w.$]*):\s*$} $t -> lbl]} {
            dict lappend items $sec [list label $lbl]; continue
        }
        # directive?
        if {[string index $t 0] eq "."} {
            if {[regexp {^\.section\s+\.(\w+)} $t -> s]} {
                if {$s in {text rodata data bss}} { set sec $s } else { set sec text }
                continue
            }
            if {[regexp {^\.align\s+(\d+)} $t -> n]} { dict lappend items $sec [list align $n]; continue }
            if {[regexp {^\.(globl|type|size|extern|set|ent|end)\b} $t]} { continue }
            if {[regexp {^\.word\s+(.+)$} $t -> v]}  { dict lappend items $sec [list word [string trim $v]]; continue }
            if {[regexp {^\.half\s+(.+)$} $t -> v]}  { dict lappend items $sec [list half [string trim $v]]; continue }
            if {[regexp {^\.byte\s+(.+)$} $t -> v]}  { dict lappend items $sec [list byte [string trim $v]]; continue }
            if {[regexp {^\.space\s+(\d+)} $t -> n]} { dict lappend items $sec [list space $n]; continue }
            if {[regexp {^\.asciiz\s+"(.*)"$} $t -> s]} { dict lappend items $sec [list asciiz $s]; continue }
            continue
        }
        # instruction: "op operands"
        if {[regexp {^(\S+)\s*(.*)$} $t -> op rest]} {
            dict lappend items $sec [list ins $op [string trim $rest]]
        }
    }

    # Pass 1: assign addresses (text, rodata, data order), build symbol table.
    set syms [dict create]
    set order {text rodata data}
    set addr $base
    foreach s $order {
        foreach it [dict get $items $s] {
            lassign $it kind a b
            switch -- $kind {
                label { dict set syms $a $addr }
                align { set m [expr {1 << $a}]; set addr [expr {($addr + $m - 1) & ~($m - 1)}] }
                ins   { incr addr [expr {[pak::asm::isize $a $b] * 4}] }
                word  { incr addr 4 }
                half  { incr addr 2 }
                byte  { incr addr 1 }
                space { incr addr $a }
                asciiz { incr addr [expr {[string length [pak::asm::unescape $a]] + 1}] }
            }
        }
    }
    set bss_size 0
    foreach it [dict get $items bss] {
        lassign $it kind a b
        switch -- $kind {
            label { dict set syms $a [expr {$base + 0}] }
            space { incr bss_size $a }
            align { set m [expr {1 << $a}]; set bss_size [expr {($bss_size + $m - 1) & ~($m - 1)}] }
        }
    }

    # Pass 2: encode each section to bytes.
    set blobs [dict create]
    set addr $base
    foreach s $order {
        set bin ""
        foreach it [dict get $items $s] {
            lassign $it kind a b
            switch -- $kind {
                label {}
                align {
                    set m [expr {1 << $a}]; set pad [expr {(($addr + $m - 1) & ~($m - 1)) - $addr}]
                    append bin [string repeat "\x00" $pad]; incr addr $pad
                }
                ins {
                    foreach w [pak::asm::encode $a $b $addr $syms] {
                        append bin [binary format I [expr {$w & 0xffffffff}]]; incr addr 4
                    }
                }
                word { append bin [binary format I [expr {[pak::asm::imm $a] & 0xffffffff}]]; incr addr 4 }
                half { append bin [binary format S [expr {[pak::asm::imm $a] & 0xffff}]]; incr addr 2 }
                byte { append bin [binary format c [expr {[pak::asm::imm $a] & 0xff}]]; incr addr 1 }
                space { append bin [string repeat "\x00" $a]; incr addr $a }
                asciiz { set str [pak::asm::unescape $a]; append bin $str "\x00"; incr addr [expr {[string length $str]+1}] }
            }
        }
        dict set blobs $s $bin
    }
    set entry [expr {[dict exists $syms _start] ? [dict get $syms _start] : ([dict exists $syms main] ? [dict get $syms main] : $base)}]
    return [dict create text [dict get $blobs text] rodata [dict get $blobs rodata] \
        data [dict get $blobs data] bss $bss_size entry $entry symbols $syms base $base]
}

proc pak::asm::unescape {s} {
    return [subst -nocommands -novariables [string map {\\n \n \\t \t \\r \r \\\" \" \\\\ \\} $s]]
}
