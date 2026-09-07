#!/usr/bin/env tclsh
# tcl/tools/rsp_codegen_test.tcl — goldens for tcl/rsp_codegen.tcl, the
# restricted codegen for the RSP target (steps 1-3 of docs/rsp-microcode-in-
# pak.md's suggested order, plus the struct/array-of-vec8x16 machinery step
# 4's worked vertex-transform example needs).
#
# Every control-flow test here goes through pak::enc::encode and checks the
# real bytes, not just pak::mips_sim_run on the assembly TEXT. That
# distinction is not paranoia: it is exactly what let a real bug through
# once already. This codegen's `while`/`if`/`loop` used a plain `j` for
# their backward/skip jump; n64enc.tcl's `j` is J-type and encodes an
# ABSOLUTE address via an R_MIPS_26 relocation meant for a *linker* to
# patch (see n64link.tcl) -- but a microcode never runs through a linker,
# so the relocation was never resolved and every such jump silently
# targeted word 0. The text simulator never caught it: its own `j` case
# resolves the label BY NAME directly off the assembly text, which is a
# completely different code path from the byte encoder and was never
# wrong. Only encoding the real program and booting it on ares (see
# tcl/tools/ares_test.tcl's "rsp_task_loop" case) surfaced it -- as a hang,
# not a crash, since the RSP just restarted the whole program on every
# loop iteration. Fixed by using `beq $zero,$zero,label` instead: PC-
# relative, resolved locally by the encoder, no linker required.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl lexer.tcl]
source [file join $REPO tcl ast.tcl]
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl mips_codegen.tcl]
source [file join $REPO tcl rsp_codegen.tcl]
source [file join $REPO tcl n64enc.tcl]
source [file join $REPO tcl optimize.tcl]
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

proc ast_of {src} { return [pak::parse_tokens [[pak::Lexer new $src] tokenize]] }

# Real encoded bytes, as a list of 0xHHHHHHHH words -- the ONLY thing that
# proves the encoder (not just the text simulator) got it right.
proc words_of {src} {
    set recs [pak::rsp_generate_records [ast_of $src]]
    set ctx [pak::enc::encode $recs]
    set bytes [dict get $ctx secdata .text bytes]
    set out {}
    for {set i 0} {$i < [llength $bytes]} {incr i 4} {
        set w 0
        for {set j 0} {$j < 4} {incr j} { set w [expr {($w<<8)|([lindex $bytes [expr {$i+$j}]]&0xFF)}] }
        lappend out [format 0x%08X $w]
    }
    return $out
}

# Pack/unpack 8 lanes as 4 big-endian words at `base`, element 0 first --
# the same convention rsp_vector_test.tcl uses for the vector-unit goldens.
proc pack_lanes {lanes {base 0}} {
    set d [dict create]; set addr $base
    foreach {a b} $lanes { dict set d $addr [expr {(($a & 0xFFFF) << 16) | ($b & 0xFFFF)}]; incr addr 4 }
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

# Run the compiled program in the fast simulator with a preset DMEM image
# (dict addr->word), and return the resulting mem_w dict.
proc run_dmem {src preset {limit 2000}} {
    set recs [pak::rsp_generate_records [ast_of $src]]
    set asm [pak::records_to_asm $recs]
    set r [pak::mips_sim_run $asm entry $limit $preset]
    if {![dict get $r halted]} { error "did not halt (hit the instruction limit -- infinite loop?)" }
    return [dict get $r mem_w]
}

puts "== straight-line arithmetic (golden bytes, real hardware confirmed on ares) =="
set add_src {
static a: u32
static b: u32
static sum: u32

entry {
    sum = a + b
}
}
check_eq "rsp_task_add.pk64's own golden bytes" [words_of $add_src] \
    {0x8C080000 0x8C090004 0x01094021 0xAC080008 0x0000000D 0x00000000}
set m [run_dmem $add_src [dict create 0 0x12340000 4 0x0000ABCD]]
check_eq "sum computed correctly" [dict get $m 8] [expr {0x1234ABCD}]

puts ""
puts "== while loop + variable array index (golden bytes, real hardware confirmed on ares) =="
set loop_src {
static n: u32
static values: [8]u32
static total: u32

entry {
    let mut i: u32 = 0
    let mut acc: u32 = 0
    while i < n {
        acc = acc + values[i]
        i = i + 1
    }
    total = acc
}
}
check_eq "rsp_task_loop.pk64's own golden bytes" [words_of $loop_src] \
    {0x24080000 0x24090000 0x01005025 0x8C0B0000 0x014B502B 0x1140000E 0x00000000 0x01205025 0x01006025 0x000C5880 0x256B0004 0x8D6B0000 0x014B5021 0x01404825 0x01005025 0x240B0001 0x014B5021 0x01404025 0x1000FFEF 0x00000000 0x01205025 0xAC0A0024 0x0000000D 0x00000000}
# The regression test for the bug itself: the backward jump must be a
# PC-relative branch (opcode 0x04, beq) that does NOT sit at target 0 --
# `0x08000000` is exactly the word an unresolved `j`-via-relocation leaves
# behind, and it is also a syntactically well-formed instruction (jump to
# word 0), so nothing about the byte itself screams "broken" without this
# check.
set backward_jump [lindex [words_of $loop_src] 18]
ok "the loop's backward jump is a resolved branch, not an unresolved absolute jump" \
    [expr {$backward_jump ne "0x08000000" && [string range $backward_jump 2 2] eq "1"}] \
    "  (got $backward_jump)"
set preset [dict create 0 5]
set vals {10 20 30 40 50 60 70 80}
set addr 4
foreach v $vals { dict set preset $addr $v; incr addr 4 }
set m [run_dmem $loop_src $preset]
check_eq "loop summed the first 5 of 8 values" [dict get $m 36] 150

puts ""
puts "== if / else =="
set if_src {
static x: u32
static y: u32
static out: u32

entry {
    if x < y {
        out = 1
    } else {
        out = 2
    }
}
}
set m1 [run_dmem $if_src [dict create 0 3 4 5]]
check_eq "if-branch taken (3 < 5)" [dict get $m1 8] 1
set m2 [run_dmem $if_src [dict create 0 9 4 5]]
check_eq "else-branch taken (9 >= 5)" [dict get $m2 8] 2
# The if/else "skip past else" jump is the SAME kind of backward/forward
# unconditional jump the loop's back-edge is -- confirm it too resolved to
# a real branch, not the same relocation bug in a different shape.
set if_words [words_of $if_src]
set has_bad_j 0
foreach w $if_words { if {$w eq "0x08000000"} { set has_bad_j 1 } }
ok "if/else compiles with no unresolved absolute jump" [expr {!$has_bad_j}]

puts ""
puts "== infinite `loop` (compiles; correctness of an unreachable exit is on the caller) =="
set loop_stmt_src {
static hits: u32

entry {
    let mut i: u32 = 0
    loop {
        hits = i
        i = i + 1
        if i == 3 {
            break
        }
    }
}
}
# `break` inside a Pak `loop` is a language-level loop-exit, not the RSP's
# hardware BREAK instruction -- this codegen does not implement loop-exit
# yet (only the hardware instruction, emitted once at the very end of
# `entry`), so this is expected to refuse rather than silently compile an
# infinite spin. Documented here so the boundary is a test, not a surprise.
if {[catch {words_of $loop_stmt_src} err]} {
    ok "loop-exit `break` refuses (not implemented) rather than compiling wrong" \
        [string match "RSPUNPORTED*" $err] "  ($err)"
} else {
    ok "loop-exit `break` refuses (not implemented) rather than compiling wrong" 0 \
        "  (compiled with no error -- but there is no way out of the loop, which is worse)"
}

puts ""
puts "== vec8x16: static-to-static add (golden bytes match rsp_vecadd.S's proven encoding) =="
# Same LQV/VADD/SQV shape hand-verified on ares in rsp_vecadd.S -- this is
# the identical instruction sequence, generated from real Pak source
# (static/entry/vec8x16/+) instead of hand-written .S, with $v0/$v1 in
# place of $v1/$v2/$v3.
set vadd_src {
static a: vec8x16
static b: vec8x16
static c: vec8x16

entry {
    c = a + b
}
}
check_eq "vec8x16 add golden bytes" [words_of $vadd_src] \
    {0xC8002000 0xC8012001 0x4A010010 0xE8002002 0x0000000D 0x00000000}
set pa [pack_lanes {1 2 3 4 5 6 7 8} 0]
set pb [pack_lanes {10 20 30 40 50 60 70 80} 16]
set preset [dict merge $pa $pb]
set m [run_dmem $vadd_src $preset]
check_eq "vec8x16 add computed correctly" [unpack_lanes $m 32 8] {11 22 33 44 55 66 77 88}

puts ""
puts "== vec8x16: broadcast, fused into the next instruction's element-select =="
set fused_src {
static a: vec8x16
static b: vec8x16
static c: vec8x16

entry {
    c = a + b.broadcast(0)
}
}
check_eq "fused broadcast golden bytes (e=8 in the vadd itself, no extra instruction)" \
    [words_of $fused_src] {0xC8002000 0xC8012001 0x4B010010 0xE8002002 0x0000000D 0x00000000}
set pa [pack_lanes {1 2 3 4 5 6 7 8} 0]
set pb [pack_lanes {100 0 0 0 0 0 0 0} 16]
set m [run_dmem $fused_src [dict merge $pa $pb]]
check_eq "fused broadcast computed correctly" [unpack_lanes $m 32 8] {101 102 103 104 105 106 107 108}

puts ""
puts "== vec8x16: broadcast materialized as a standalone value =="
set standalone_bc_src {
static a: vec8x16
static c: vec8x16

entry {
    let bc: vec8x16 = a.broadcast(2)
    c = bc
}
}
set m [run_dmem $standalone_bc_src [pack_lanes {10 20 30 40 50 60 70 80} 0]]
check_eq "standalone broadcast computed correctly" [unpack_lanes $m 16 8] {30 30 30 30 30 30 30 30}

puts ""
puts "== rsp.vacc: mul/mac/mid, matching the design note's own worked example =="
set vacc_src {
use rsp.vacc

static m0: vec8x16
static m1: vec8x16
static v: vec8x16
static result: vec8x16

entry {
    vacc.mul(m0, v.broadcast(0))
    vacc.mac(m1, v.broadcast(1))
    result = vacc.mid()
}
}
check_eq "vacc mul/mac/mid golden bytes" [words_of $vacc_src] \
    {0xC8002000 0xC8022002 0x4B020040 0xC8012001 0xC8022002 0x4B220808 0x4B20001D 0xE8002003 0x0000000D 0x00000000}
# lane0: m0[0]=0.5, v[0]=0.5 -> mul contributes 0.25; m1[0]=0.5, v[1]=0.5 ->
# mac contributes 0.25 more -> 0.5, all in Q1.15 (0x4000 = 16384 = 0.5).
set preset [pack_lanes {16384 0 0 0 0 0 0 0} 0]
dict for {a val} [pack_lanes {16384 0 0 0 0 0 0 0} 16] { dict set preset $a $val }
dict for {a val} [pack_lanes {16384 16384 0 0 0 0 0 0} 32] { dict set preset $a $val }
set m [run_dmem $vacc_src $preset]
check_eq "vacc mul/mac/mid computed correctly (0.5*0.5 + 0.5*0.5 = 0.5)" \
    [unpack_lanes $m 48 8] {16384 0 0 0 0 0 0 0}

puts ""
puts "== struct + array-of-vec8x16: the design note's vertex-transform example =="
# docs/rsp-microcode-in-pak.md's "A whole microcode" worked example, minus
# shrinking 64 vertices to 4 (see tcl/tests/ares/rsp_task_vtx.pk64, which
# this mirrors) -- a struct with vec8x16 array fields, a struct-typed
# static, a `while` bounded by one of the struct's own fields, and
# per-iteration indexing of two different array fields, one by a loop
# variable.
set vtx_src {
use rsp.vacc

@aligned(16)
struct VtxJob {
    mvp: [4]vec8x16,
    count: i32,
    vertices: [4]vec8x16
}

@aligned(16)
static job: VtxJob

entry {
    let mut i: i32 = 0
    while i < job.count {
        let v: vec8x16 = job.vertices[i]

        vacc.mul(job.mvp[0], v.broadcast(0))
        vacc.mac(job.mvp[1], v.broadcast(1))
        vacc.mac(job.mvp[2], v.broadcast(2))
        vacc.mac(job.mvp[3], v.broadcast(3))

        job.vertices[i] = vacc.mid()
        i = i + 1
    }
}
}
check_eq "vertex-transform golden bytes" [words_of $vtx_src] \
    {0x24080000 0x01004825 0x8C0A0040 0x012A482B 0x11200021 0x00000000 0x01005025 0x000A4900 0x25290050 0xC9202000 0x4A00006A 0x24090000 0xC9202000 0x4A0108EA 0x4B030080 0x24090010 0xC9222000 0x4A0108EA 0x4B231008 0x24090020 0xC9202000 0x4A0108EA 0x4B430088 0x24090030 0xC9222000 0x4A0108EA 0x4B631008 0x01005025 0x000A4900 0x25290050 0x4B20001D 0xE9202000 0x01004825 0x240A0001 0x012A4821 0x01204025 0x1000FFDC 0x00000000 0x0000000D 0x00000000}
# DMEM layout, the same bump allocator as every other static: job.mvp[0..3]
# at 0/16/32/48, job.count at 64, job.vertices[0..3] at 80/96/112/128
# (rounded up from 68 to vec8x16's own 16-byte alignment). mvp is a uniform
# 0.25 (0x2000) in every lane of every one of its 4 entries, so the
# transform reduces to output_lane = 0.25 * (v[0]+v[1]+v[2]+v[3]) for every
# lane, independent of which lane -- distinct per-vertex data (only lane 0
# of each vertex varies: 0x1000/0x2000/0x3000/0x4000, the rest held at
# 0x4000) is chosen specifically so a bug that indexed the wrong vertex (a
# fixed one, or always vertex 0) would show up as a wrong or duplicated
# value instead of accidentally reading back correct-looking data.
set preset [dict create]
foreach base {0 16 32 48} {
    dict for {a v} [pack_lanes {0x2000 0x2000 0x2000 0x2000 0x2000 0x2000 0x2000 0x2000} $base] { dict set preset $a $v }
}
dict set preset 64 4
dict for {a v} [pack_lanes {0x1000 0x4000 0x4000 0x4000 0x4000 0x4000 0x4000 0x4000} 80]  { dict set preset $a $v }
dict for {a v} [pack_lanes {0x2000 0x4000 0x4000 0x4000 0x4000 0x4000 0x4000 0x4000} 96]  { dict set preset $a $v }
dict for {a v} [pack_lanes {0x3000 0x4000 0x4000 0x4000 0x4000 0x4000 0x4000 0x4000} 112] { dict set preset $a $v }
dict for {a v} [pack_lanes {0x4000 0x4000 0x4000 0x4000 0x4000 0x4000 0x4000 0x4000} 128] { dict set preset $a $v }
set m [run_dmem $vtx_src $preset]
check_eq "vertex 0 (lane0=0.125, rest 0.5 -> 0.25*1.625=0.40625)" [unpack_lanes $m 80 8] \
    {13312 13312 13312 13312 13312 13312 13312 13312}
check_eq "vertex 1 (lane0=0.25 -> 0.25*1.75=0.4375)" [unpack_lanes $m 96 8] \
    {14336 14336 14336 14336 14336 14336 14336 14336}
check_eq "vertex 2 (lane0=0.375 -> 0.25*1.875=0.46875)" [unpack_lanes $m 112 8] \
    {15360 15360 15360 15360 15360 15360 15360 15360}
check_eq "vertex 3 (lane0=0.5 -> 0.25*2.0=0.5)" [unpack_lanes $m 128 8] \
    {16384 16384 16384 16384 16384 16384 16384 16384}

puts ""
puts "== vec8x16: lane read/write round-trip (MTC2 then MFC2) =="
set lane_src {
static v: vec8x16
static out: u32

entry {
    v[3] = 999 as i16
    let x: i16 = v[3]
    out = x as u32
}
}
set m [run_dmem $lane_src [pack_lanes {1 2 3 4 5 6 7 8} 0]]
check_eq "lane write then read round-trips" [dict get $m 16] 999

puts ""
puts "== refusals: the RSP target says no by name, not by miscompiling =="
proc expect_unported {name src} {
    if {[catch {words_of $src} err]} {
        ok "$name refuses" [string match "RSPUNPORTED*" $err] "  ($err)"
    } else {
        ok "$name refuses" 0 "  (compiled with no error)"
    }
}
expect_unported "multiply" {
static a: u32
static b: u32
static c: u32
entry { c = a * b }
}
expect_unported "divide" {
static a: u32
static b: u32
static c: u32
entry { c = a / b }
}
expect_unported "a static with an initializer" {
static a: u32 = 5
entry { a = a }
}
expect_unported "f32 (no FPU)" {
static a: f32
entry { a = a }
}
expect_unported "a second entry block" {
static a: u32
entry { a = a }
entry { a = a }
}
expect_unported "assigning a whole struct-typed static (not a value -- assign its fields)" {
struct Foo { x: u32 }
static job: Foo
static a: Foo
entry { job = a }
}
expect_unported "a struct declared twice" {
struct Foo { x: u32 }
struct Foo { y: u32 }
static a: u32
entry { a = a }
}
expect_unported "field access more than one level deep" {
struct Inner { x: u32 }
struct Outer { inner: Inner }
static o: Outer
static a: u32
entry { a = o.inner.x }
}
expect_unported "a function call (no modules, no functions yet)" {
static a: u32
entry { a = foo(a) }
}
expect_unported "vec8x16 << (no vector shift on real RSP hardware)" {
static a: vec8x16
static b: vec8x16
entry { a = a << b }
}
expect_unported "a variable vec8x16 lane index (the encoding needs a literal)" {
static v: vec8x16
static i: u32
static out: u32
entry {
    let x: i16 = v[i]
    out = x as u32
}
}
expect_unported "vacc.mac with no vacc.mul before it" {
static m1: vec8x16
static v: vec8x16
entry { vacc.mac(m1, v) }
}
expect_unported "vacc.high() with no vacc.mul or vacc.mac before it" {
static v: vec8x16
entry { let r: vec8x16 = vacc.high() }
}
expect_unported "vacc.mid() with no vacc.mul or vacc.mac before it" {
static v: vec8x16
entry { let r: vec8x16 = vacc.mid() }
}
expect_unported "vacc.low() with no vacc.mul or vacc.mac before it" {
static v: vec8x16
entry { let r: vec8x16 = vacc.low() }
}

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
