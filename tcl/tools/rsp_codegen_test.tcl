#!/usr/bin/env tclsh
# tcl/tools/rsp_codegen_test.tcl — goldens for tcl/rsp_codegen.tcl, the
# restricted scalar codegen for the RSP target (step 1 of
# docs/rsp-microcode-in-pak.md's suggested order).
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
expect_unported "a struct at top level (not yet supported)" {
struct Foo { x: u32 }
static a: u32
entry { a = a }
}
expect_unported "a function call (no modules, no functions yet)" {
static a: u32
entry { a = foo(a) }
}

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
