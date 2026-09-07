#!/usr/bin/env tclsh
# tcl/tools/rsp_vector_test.tcl — RSP vector-unit (COP2) execution goldens.
#
# tcl/mips_sim.tcl's vector semantics are transcribed from ares' RSP
# interpreter (ares/n64/rsp/interpreter-vpu.cpp), a silicon-accurate
# reference -- not reconstructed from documentation or memory, and the
# element-broadcast table and the whole COP2 field layout in tcl/n64enc.tcl
# were separately cross-checked against armips (github.com/Kingcom/armips),
# the assembler real N64 homebrew microcode is written with. This file
# exercises the simulator's side: real microcode text, executed, checked
# against hand-computed expected values.
#
# Run: tclsh tcl/tools/rsp_vector_test.tcl

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl mips_sim.tcl]

set ::pass 0
set ::fail 0
proc ok {name cond {detail ""}} {
    if {$cond} { incr ::pass; puts "ok    $name" } \
    else { incr ::fail; puts "FAIL  $name$detail" }
}
proc check_eq {name got want} {
    if {$got eq $want} { incr ::pass; puts "ok    $name" } \
    else { incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want" }
}

# ── helpers: pack/unpack 8 lanes as 4 big-endian words, element0 first ───────
proc pack_lanes {lanes {base 0}} {
    set d [dict create]
    set addr $base
    foreach {a b} $lanes {
        dict set d $addr [expr {(($a & 0xFFFF) << 16) | ($b & 0xFFFF)}]
        incr addr 4
    }
    return $d
}
proc unpack_lanes {mw addr n} {
    set out {}
    for {set i 0} {$i < $n} {incr i 2} {
        set a [expr {$addr + $i*2}]
        set w [expr {[dict exists $mw $a] ? [dict get $mw $a] : 0}]
        foreach v [list [expr {($w>>16)&0xFFFF}] [expr {$w&0xFFFF}]] {
            if {$v >= 0x8000} { set v [expr {$v - 0x10000}] }
            lappend out $v
        }
    }
    return $out
}
proc run_with_operands {asm v1 v2} {
    set preset [pack_lanes $v1 0]
    dict for {a v} [pack_lanes $v2 16] { dict set preset $a $v }
    set r [pak::mips_sim_run $asm main 1000 $preset]
    return [unpack_lanes [dict get $r mem_w] 32 8]
}

set LOADSTORE {
.text
main:
    lqv $v1[0], 0($a0)
    lqv $v2[0], 16($a0)
%OP%
    sqv $v3[0], 32($a0)
    break
}
proc vecop {mnem v1 v2} {
    global LOADSTORE
    set asm [string map [list %OP% "    $mnem \$v3, \$v1, \$v2"] $LOADSTORE]
    return [run_with_operands $asm $v1 $v2]
}

puts "== arithmetic (vadd/vsub, clamp, carry chaining) =="
check_eq "vadd, no clamp"       [vecop vadd {1 2 3 4 5 6 7 8} {10 20 30 40 50 60 70 80}] \
    {11 22 33 44 55 66 77 88}
check_eq "vsub, no clamp"       [vecop vsub {10 20 30 40 50 60 70 80} {1 2 3 4 5 6 7 8}] \
    {9 18 27 36 45 54 63 72}
check_eq "vadd clamps to 32767" [vecop vadd {32000 0 0 0 0 0 0 0} {32000 0 0 0 0 0 0 0}] \
    {32767 0 0 0 0 0 0 0}
check_eq "vsub clamps to -32768" [vecop vsub {-32000 0 0 0 0 0 0 0} {32000 0 0 0 0 0 0 0}] \
    {-32768 0 0 0 0 0 0 0}

# vaddc sets VCO carry-out; a following vadd (same lanes, e defaulted) reads
# it back as a carry-IN. Real microcode chains a 32-bit add across two lanes
# this way, so the two instructions must not be independent. lane0:
# 0xFFFF+1 carries out (ACCL wraps to 0). The lone vadd's own sum of the same
# two operands would clamp to 0; with the carry folded in it is 1 instead --
# so seeing 1 here is proof the carry crossed the instruction boundary.
set asm {
.text
main:
    lqv $v1[0], 0($a0)
    lqv $v2[0], 16($a0)
    vaddc $v3, $v1, $v2
    vadd $v4, $v1, $v2
    sqv $v4[0], 32($a0)
    break
}
check_eq "vadd carry-in changes the sum by exactly 1" \
    [run_with_operands $asm {0xFFFF 0 0 0 0 0 0 0} {1 0 0 0 0 0 0 0}] \
    {1 0 0 0 0 0 0 0}

puts ""
puts "== logic ops =="
# check_eq compares element-address, so both sides need to be spelled the
# same way -- decimal, since unpack_lanes never produces a hex string. Every
# lane past the interesting one is 0&0 (AND), 0|0 (OR/XOR), or ~(0 op 0) for
# the N-variants, and NAND/NOR/NXOR of two zero lanes is -1 (all bits set),
# not 0 -- worth spelling out since it looks like a typo otherwise.
check_eq "vand"  [vecop vand  {0x0F0F 0 0 0 0 0 0 0} {0x00FF 0 0 0 0 0 0 0}] {15 0 0 0 0 0 0 0}
check_eq "vor"   [vecop vor   {0x0F00 0 0 0 0 0 0 0} {0x00F0 0 0 0 0 0 0 0}] {4080 0 0 0 0 0 0 0}
check_eq "vxor"  [vecop vxor  {0x0FF0 0 0 0 0 0 0 0} {0x0F0F 0 0 0 0 0 0 0}] {255 0 0 0 0 0 0 0}
check_eq "vnand" [vecop vnand {0xFFFF 0 0 0 0 0 0 0} {0xFFFF 0 0 0 0 0 0 0}] {0 -1 -1 -1 -1 -1 -1 -1}
check_eq "vnor"  [vecop vnor  {0 0 0 0 0 0 0 0} {0 0 0 0 0 0 0 0}] {-1 -1 -1 -1 -1 -1 -1 -1}
check_eq "vnxor" [vecop vnxor {0x0FF0 0 0 0 0 0 0 0} {0x0F0F 0 0 0 0 0 0 0}] {-256 -1 -1 -1 -1 -1 -1 -1}

puts ""
puts "== vabs (including the -32768 edge case) =="
check_eq "vabs positive*x"      [vecop vabs {5 0 0 0 0 0 0 0}  {7 0 0 0 0 0 0 0}]  {7 0 0 0 0 0 0 0}
check_eq "vabs negative*x"      [vecop vabs {-5 0 0 0 0 0 0 0} {7 0 0 0 0 0 0 0}]  {-7 0 0 0 0 0 0 0}
check_eq "vabs zero*x"          [vecop vabs {0 0 0 0 0 0 0 0}  {7 0 0 0 0 0 0 0}]  {0 0 0 0 0 0 0 0}
check_eq "vabs(-32768) saturates to 32767" \
    [vecop vabs {-5 0 0 0 0 0 0 0} {-32768 0 0 0 0 0 0 0}] {32767 0 0 0 0 0 0 0}

puts ""
puts "== multiply/multiply-accumulate family (accumulator readback via vsar) =="
proc mulop {mnem v1 v2} {
    set asm {
.text
main:
    lqv $v1[0], 0($a0)
    lqv $v2[0], 16($a0)
    %OP%
    vsar $v9, $v9, $v9[8]
    sqv $v9[0], 32($a0)
    vsar $v9, $v9, $v9[9]
    sqv $v9[0], 64($a0)
    vsar $v9, $v9, $v9[10]
    sqv $v9[0], 96($a0)
    break
}
    set asm [string map [list %OP% "$mnem \$v3, \$v1, \$v2"] $asm]
    set preset [pack_lanes $v1 0]
    dict for {a v} [pack_lanes $v2 16] { dict set preset $a $v }
    set r [pak::mips_sim_run $asm main 1000 $preset]
    return [list [unpack_lanes [dict get $r mem_w] 32 8] \
                 [unpack_lanes [dict get $r mem_w] 64 8] \
                 [unpack_lanes [dict get $r mem_w] 96 8]]
}
# vmudn: acc = s32(u16(v1)*s16(v2)), fresh set (ACCL touched too).
lassign [mulop vmudn {2 3 4 5 6 7 8 9} {-1 -1 -1 -1 -1 -1 -1 -1}] hi mid lo
check_eq "vmudn ACCH (sign-extended)" $hi  {-1 -1 -1 -1 -1 -1 -1 -1}
check_eq "vmudn ACCM"                 $mid {-1 -1 -1 -1 -1 -1 -1 -1}
check_eq "vmudn ACCL (low 16 of product)" $lo {-2 -3 -4 -5 -6 -7 -8 -9}

# vmudh: acc = s64(v1*v2)<<16 -- ACCL is always 0, ACCM holds the product.
lassign [mulop vmudh {3 0 0 0 0 0 0 0} {4 0 0 0 0 0 0 0}] hi mid lo
check_eq "vmudh ACCM = product" $mid {12 0 0 0 0 0 0 0}
check_eq "vmudh ACCL always 0"  $lo  {0 0 0 0 0 0 0 0}

# vmadh must NOT clear ACCL -- only the top 32 bits change. Seed ACCL via a
# vmudn on the same registers first (product's low 16 bits), then vmadh, then
# confirm ACCL survived.
set asm {
.text
main:
    lqv $v1[0], 0($a0)
    lqv $v2[0], 16($a0)
    vmudn $v3, $v1, $v2
    vmadh $v3, $v1, $v2
    vsar $v9, $v9, $v9[10]
    sqv $v9[0], 32($a0)
    break
}
check_eq "vmadh leaves ACCL untouched" \
    [run_with_operands $asm {2 0 0 0 0 0 0 0} {3 0 0 0 0 0 0 0}] {6 0 0 0 0 0 0 0}

puts ""
puts "== compare/merge (veq/vne/vlt/vge/vmrg) =="
# veq selects vs where equal, vt where not -- lanes 1 and 3 are unequal
# (1 vs 5), so both read back vt's 5, not vs's 1.
check_eq "veq selects vs where equal, vt elsewhere" \
    [vecop veq {5 1 5 1 0 0 0 0} {5 5 5 5 0 0 0 0}] {5 5 5 5 0 0 0 0}
check_eq "vlt selects the lesser operand" \
    [vecop vlt {3 9 0 0 0 0 0 0} {5 2 0 0 0 0 0 0}] {3 2 0 0 0 0 0 0}
check_eq "vge selects the greater-or-equal operand" \
    [vecop vge {3 9 5 0 0 0 0 0} {5 2 5 0 0 0 0 0}] {5 9 5 0 0 0 0 0}
# vmrg re-plays VCC from the immediately preceding compare.
set asm {
.text
main:
    lqv $v1[0], 0($a0)
    lqv $v2[0], 16($a0)
    vlt $v3, $v1, $v2
    vmrg $v4, $v1, $v2
    sqv $v4[0], 32($a0)
    break
}
check_eq "vmrg replays the last compare's VCC" \
    [run_with_operands $asm {3 9 0 0 0 0 0 0} {5 2 0 0 0 0 0 0}] {3 2 0 0 0 0 0 0}

puts ""
puts "== element broadcast =="
check_eq "e=8: broadcast lane 0"    [vecop vadd {0 0 0 0 0 0 0 0} {100 0 0 0 0 0 0 0}] {100 0 0 0 0 0 0 0}
set asm {
.text
main:
    lqv $v1[0], 0($a0)
    lqv $v2[0], 16($a0)
    vadd $v3, $v1, $v2[8]
    sqv $v3[0], 32($a0)
    break
}
check_eq "e=8 broadcasts vt lane 0 to every output lane" \
    [run_with_operands $asm {1 2 3 4 5 6 7 8} {100 0 0 0 0 0 0 0}] \
    {101 102 103 104 105 106 107 108}
set asm2 {
.text
main:
    lqv $v1[0], 0($a0)
    lqv $v2[0], 16($a0)
    vadd $v3, $v1, $v2[2]
    sqv $v3[0], 32($a0)
    break
}
check_eq "e=2 pairs even lanes (0,0,2,2,4,4,6,6)" \
    [run_with_operands $asm2 {0 0 0 0 0 0 0 0} {10 20 30 40 50 60 70 80}] \
    {10 10 30 30 50 50 70 70}

puts ""
puts "== load/store: quadword clip-on-load vs wrap-on-store =="
# LQV clips at the 16-byte destination boundary; SQV does not (its tail wraps
# back around into vt's own low bytes). Same element (12), same nominal
# 8-lane vector -- loads only 2 lanes worth, stores wrap the remaining ones.
set asm {
.text
main:
    lqv $v1[0], 0($a0)
    lqv $v5[12], 16($a0)
    sqv $v5[12], 32($a0)
    break
}
set preset [pack_lanes {1 2 3 4 5 6 7 8} 0]
dict for {a v} [pack_lanes {10 20 30 40 50 60 70 80} 16] { dict set preset $a $v }
set r [pak::mips_sim_run $asm main 1000 $preset]
# v5 before the loads is all zero; LQV at elem 12 into v5 loads only bytes
# 12..15 (2 lanes: elements 6,7) from address 16 -- lanes 10,20 land there
# (v5 = {0,0,0,0,0,0,10,20}). SQV at elem 12 then writes 16-(addr&15)=16
# bytes to SEQUENTIAL destination addresses (32,33,...,47), reading its
# SOURCE bytes from v5 starting at byte 12 and wrapping through v5's bytes
# 0..11 (still zero): source byte order 12,13,14,15,0,1,...,11 -- i.e. v5's
# bytes 12-15 (the loaded 10,20) land at the FRONT of the output, not where
# they sit in v5. Output lanes 0,1 = 10,20; the rest are the wrapped zeros.
check_eq {lqv/sqv at a non-zero element: load clips, store wraps} \
    [unpack_lanes [dict get $r mem_w] 32 8] {10 20 0 0 0 0 0 0}

puts ""
puts "== ldv/sdv, llv/slv, lsv/ssv, lbv/sbv (byte-precise transfers) =="
set asm {
.text
main:
    ldv $v1[0], 0($a0)
    sdv $v1[0], 16($a0)
    break
}
set r [pak::mips_sim_run $asm main 1000 [pack_lanes {11 22 0 0 0 0 0 0} 0]]
check_eq "ldv/sdv round-trip, direct" [unpack_lanes [dict get $r mem_w] 16 4] {11 22 0 0}

puts ""
puts "== mfc2/mtc2 (including the odd-element byte-straddle quirk) =="
set asm {
.text
main:
    li $t0, 4660
    mtc2 $t0, $v5[0]
    mfc2 $t1, $v5[0]
    sw $t1, 0($a0)
    break
}
set r [pak::mips_sim_run $asm main 1000]
check_eq "mtc2/mfc2 round-trip on an even element" \
    [dict get [dict get $r mem_w] 0] 4660

# Odd element: MFC2 reads byte(e) and byte(e+1), which straddles two lanes
# when e is odd. Seed two adjacent lanes and confirm the straddled read.
set asm2 {
.text
main:
    lqv $v6[0], 0($a0)
    mfc2 $t0, $v6[1]
    sw $t0, 32($a0)
    break
}
# lane0 = 0x1234, lane1 = 0x5678: byte1(low byte of lane0)=0x34,
# byte2(high byte of lane1)=0x56 -> straddled read = 0x3456.
set preset [dict create 0 [expr {(0x1234<<16)|0x5678}]]
set r2 [pak::mips_sim_run $asm2 main 1000 $preset]
check_eq "mfc2 with an odd element straddles two lanes" \
    [dict get [dict get $r2 mem_w] 32] 13398

puts ""
puts "== cfc2/ctc2 (vco round-trip) =="
set asm {
.text
main:
    li $t0, 0x0103
    ctc2 $t0, vco
    cfc2 $t1, vco
    sw $t1, 0($a0)
    break
}
set r [pak::mips_sim_run $asm main 1000]
check_eq "ctc2/cfc2 round-trips vco (lo=0x03, hi=0x01)" \
    [dict get [dict get $r mem_w] 0] 259

puts ""
puts "== break halts the run =="
set r [pak::mips_sim_run {
.text
main:
    li $t0, 1
    break
    li $t0, 2
} main 1000]
check_eq "break stops before the instruction after it" [dict get [dict get $r regs] 8] 1

puts ""
puts "== deferred opcodes refuse rather than silently no-op =="
foreach mnem {vrcp vch vcl vcr vmov ltv lwv} {
    set asm "
.text
main:
    $mnem \$v1, \$v1
    break
"
    if {[catch {pak::mips_sim_run $asm main 100} err]} {
        incr ::pass; puts "ok    '$mnem' refuses to run ($err)"
    } else {
        incr ::fail; puts "FAIL  '$mnem' should have refused to run (not simulated)"
    }
}

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
