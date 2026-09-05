#!/usr/bin/env tclsh
# tcl/tools/n64enc_test.tcl — golden-encoding tests for the MIPS encoder.
#
# Run:  tclsh tcl/tools/n64enc_test.tcl
# All assertions are hand-verified big-endian 32-bit encodings.

set here [file dirname [file normalize [info script]]]
source [file join $here .. n64enc.tcl]

set ::pass 0
set ::fail 0

# Assert a single-instruction record encodes to the given 32-bit word.
proc check {rec expect} {
    set got [pak::enc::word_of $rec]
    set ge [format 0x%08X $got]
    set ee [format 0x%08X $expect]
    if {$got == ($expect & 0xffffffff)} {
        incr ::pass
        puts "ok    $ee  <- $rec"
    } else {
        incr ::fail
        puts "FAIL  expected $ee got $ge  <- $rec"
    }
}

# Assert two raw values are equal (generic).
proc check_eq {label got expect} {
    if {$got eq $expect} {
        incr ::pass
        puts "ok    $label"
    } else {
        incr ::fail
        puts "FAIL  $label\n        expected: $expect\n        got:      $got"
    }
}

# Pull the Nth 32-bit word (0-based) from a section's byte buffer.
proc word_at {ctx sec n} {
    set bytes [dict get $ctx secdata $sec bytes]
    set base [expr {$n * 4}]
    set w 0
    for {set j 0} {$j < 4} {incr j} {
        set w [expr {($w << 8) | ([lindex $bytes [expr {$base+$j}]] & 0xff)}]
    }
    return $w
}

puts "== single-instruction golden encodings =="

check {i addu {$t1} {$t2} {$t3}}   0x014B4821
check {i addiu {$sp} {$sp} -256}   0x27BDFF00
check {i addiu {$sp} {$sp} 256}    0x27BD0100
check {i lw {$ra} 252($sp)}        0x8FBF00FC
check {i sw {$ra} 252($sp)}        0xAFBF00FC
check {i lui {$t0} 0x8040}         0x3C088040
check {i ori {$t0} {$t0} 0x400}    0x35080400
check {i jr {$ra}}                 0x03E00008
check {i sll {$t0} {$t1} 2}        0x00094080
check {i and {$t0} {$t1} {$t2}}    0x012A4024
check {i or {$t0} {$t1} {$t2}}     0x012A4025
check {i slt {$t0} {$t1} {$t2}}    0x012A402A
check {i nop}                      0x00000000
check {i move {$t0} {$t1}}         0x01204025
check {i mult {$t0} {$t1}}         0x01090018
check {i mflo {$t0}}               0x00004012
check {i li {$t0} 5}               0x24080005
check {i xori {$t0} {$t0} 1}       0x39080001

puts "== branch offset (local label) =="
# Label L at byte offset 0, beq at byte offset 4: offset=(0-(4+4))>>2 = -2.
set ctx [pak::enc::encode {
    {d section .text}
    {label L}
    {i nop}
    {i beq {$t0} {$zero} L}
}]
check_eq "beq \$t0,\$zero,L (woff=4)" \
    [format 0x%08X [word_at $ctx .text 1]] 0x1100FFFE

puts "== li wide (lui+ori) =="
set ctx [pak::enc::encode {
    {d section .text}
    {i li {$t0} 0x12345}
}]
check_eq "li \$t0,0x12345 word0 (lui)" \
    [format 0x%08X [word_at $ctx .text 0]] 0x3C080001
check_eq "li \$t0,0x12345 word1 (ori)" \
    [format 0x%08X [word_at $ctx .text 1]] 0x35082345

puts "== seq pseudo expansion (two words) =="
set ctx [pak::enc::encode {
    {d section .text}
    {i seq {$t0} {$t1} {$t2}}
}]
set bytes [dict get $ctx secdata .text bytes]
check_eq "seq expands to 2 words (8 bytes)" [llength $bytes] 8
check_eq "seq word0 (xor \$t0,\$t1,\$t2)" \
    [format 0x%08X [word_at $ctx .text 0]] 0x012A4026
check_eq "seq word1 (sltiu \$t0,\$t0,1)" \
    [format 0x%08X [word_at $ctx .text 1]] 0x2D080001

puts "== la expansion (HI16/LO16 relocs, zero imm fields) =="
set ctx [pak::enc::encode {
    {d section .text}
    {label start}
    {i la {$a0} .Lmsg}
    {d section .rodata}
    {label .Lmsg}
    {d asciiz hi}
}]
check_eq "la word0 (lui \$a0, imm=0)" \
    [format 0x%08X [word_at $ctx .text 0]] 0x3C040000
check_eq "la word1 (addiu \$a0,\$a0, imm=0)" \
    [format 0x%08X [word_at $ctx .text 1]] 0x24840000
set relocs [dict get $ctx secdata .text relocs]
check_eq "la relocs" $relocs {{0 R_MIPS_HI16 .Lmsg} {4 R_MIPS_LO16 .Lmsg}}
# .rodata: "hi" + NUL = 3 bytes, padded to 4.
check_eq ".rodata asciiz bytes (padded to 4)" \
    [llength [dict get $ctx secdata .rodata bytes]] 4
check_eq ".rodata word0 = 'h''i'0x00 pad" \
    [format 0x%08X [word_at $ctx .rodata 0]] 0x68690000

puts "== COP1 unary / compare / branch =="
# mov.s $f4,$f6 -> 010001 10000 00000 00110 00100 000110
check {i mov.s {$f4} {$f6}}   0x46003106
# neg.s $f0,$f2 -> funct 0x07
check {i neg.s {$f0} {$f2}}   0x46001007
# abs.s $f0,$f2 -> funct 0x05
check {i abs.s {$f0} {$f2}}   0x46001005
# sqrt.s $f0,$f2 -> funct 0x04
check {i sqrt.s {$f0} {$f2}}  0x46001004
# c.eq.s $f4,$f6 -> fmt=16 ft=6 fs=4 funct=0x30|2
check {i c.eq.s {$f4} {$f6}}  0x46062032
# c.lt.s $f4,$f6 -> funct=0x30|12
check {i c.lt.s {$f4} {$f6}}  0x4606203C
# c.le.s $f4,$f6 -> funct=0x30|14
check {i c.le.s {$f4} {$f6}}  0x4606203E

# bc1t/bc1f resolve like any other local-label branch.
set ctx [pak::enc::encode {
    {d section .text}
    {label .Lfp}
    {i nop}
    {i bc1t .Lfp}
    {i bc1f .Lfp}
}]
# bc1t at 4: target 0, offset = (0 - 8) >> 2 = -2 -> 0xFFFE
check_eq "bc1t backward" [format 0x%08X [word_at $ctx .text 1]] 0x4501FFFE
# bc1f at 8: offset = (0 - 12) >> 2 = -3 -> 0xFFFD
check_eq "bc1f backward" [format 0x%08X [word_at $ctx .text 2]] 0x4500FFFD

puts "== CACHE instruction =="
# cache 0x19, 0($a0) -> op=0x2F(47) rs=$a0(4) rt=0x19(25) imm=0
# 0b10_1111_00100_11001_0000000000000000 = 0xBC990000
check {i cache 0x19 0($a0)} 0xBC990000
# cache 0x14, 0($a0) -> rt=0x14(20)
# 0b10_1111_00100_10100_0000000000000000 = 0xBC940000
check {i cache 0x14 0($a0)} 0xBC940000

puts "== BGTZ / BLEZ local-label branches =="
set ctx [pak::enc::encode {
    {d section .text}
    {label .Lloop}
    {i nop}
    {i bgtz {$a1} .Lloop}
}]
# bgtz at byte offset 4: target=0, off=(0-(4+4))>>2 = -2 = 0xFFFE
# op=0x07 rs=$a1(5) rt=0 imm=-2: 0b000_0111_00101_00000_1111111111111110
# = 0x1CA0FFFE
check_eq "bgtz \$a1,.Lloop" \
    [format 0x%08X [word_at $ctx .text 1]] 0x1CA0FFFE

set ctx [pak::enc::encode {
    {d section .text}
    {label .Lloop}
    {i nop}
    {i blez {$a1} .Lloop}
}]
# blez op=0x06: 0b000_0110_00101_00000_1111111111111110 = 0x18A0FFFE
check_eq "blez \$a1,.Lloop" \
    [format 0x%08X [word_at $ctx .text 1]] 0x18A0FFFE

puts "== verbatim label detection =="
set ctx [pak::enc::encode {
    {d section .text}
    {verbatim .Ldcwb_1:}
    {i nop}
    {verbatim {bgtz $a1, .Ldcwb_1}}
}]
check_eq "verbatim label .Ldcwb_1 resolves" \
    [format 0x%08X [word_at $ctx .text 1]] 0x1CA0FFFE

puts "== extra: more real-instruction sanity =="
check {i subu {$t0} {$t1} {$t2}}   0x012A4023
check {i sltiu {$t0} {$t0} 1}      0x2D080001
check {i j main}                   0x08000000
# sgt $t0,$t1,$t2 -> slt $t0,$t2,$t1 (rs=$t2=10, rt=$t1=9, rd=$t0=8)
check {i sgt {$t0} {$t1} {$t2}}    0x0149402A

puts "== object-file format smoke test =="
set tmp [file join [file dirname [info script]] _n64enc_obj.tmp]
pak::enc::write_object {
    {d section .text}
    {d globl main}
    {label main}
    {i jr {$ra}}
    {i nop}
} $tmp
set fh [open $tmp r]; set obj [read $fh]; close $fh
file delete $tmp
puts "---- object output ----"
puts -nonewline $obj
puts "-----------------------"
check_eq "object header line" [lindex [split $obj "\n"] 0] "# pak object v1"

# ── CP0, numeric registers, and constant-expression immediates (boot.S) ──────
# mfc0 $8,$12 -> COP0 op=0x10 rs=0(MF) rt=8 rd=12
check {i mfc0 $8 $12} 0x40086000
# mtc0 $8,$12 -> rs=4(MT)
check {i mtc0 $8 $12} 0x40886000
# numeric GPRs: addu $8,$8,$9
check {i addu $8 $8 $9} 0x01094021
# sw $0, 0($8) — zero register by number
check {i sw $0 0($8)} 0xAD000000
# li with a C-style constant expression ~1 == -2 -> addiu $9,$zero,-2
check {i li $9 ~1} 0x2409FFFE
# li with a shift expression 1<<10 == 1024 (fits unsigned16 path? -> addiu)
check {i li $8 (1<<10)} 0x24080400
# lui with numeric dest
check {i lui $29 0x8040} 0x3C1D8040

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
exit 0
