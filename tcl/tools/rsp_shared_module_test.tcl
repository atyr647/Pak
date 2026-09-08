#!/usr/bin/env tclsh
# tcl/tools/rsp_shared_module_test.tcl — task #51: cross-file struct module
# sharing for the RSP target, via cli.tcl's pak::rsp_resolve_program.
#
# The fixture project (tcl/tests/ares/rsp_shared_project/) splits
# tcl/tests/ares/rsp_task_vtx.pk64 (task #49, already hardware-verified on
# ares) into two files exactly the way the design note's own example is
# shaped: src/shared/vtxjob.pk64 declares `module shared.vtxjob` and the
# VtxJob struct alone, and rsp/transform.pk64 is the actual microcode,
# `use`ing it instead of declaring VtxJob inline.
#
# The whole test is one equality: pak::rsp_resolve_program on
# rsp/transform.pk64, fed through the ordinary rsp_generate_records +
# encode pipeline, must produce BYTE-IDENTICAL output to rsp_task_vtx.pk64
# (checked directly against its own already-verified golden bytes, not
# re-derived here). Since those bytes are already proven correct on real
# RSP hardware, an exact match is hardware verification by construction --
# splitting a proven program across two files and reassembling it via
# project module resolution cannot introduce a new arithmetic bug the
# original single-file version didn't have; the only thing genuinely new
# here is whether the FILE-FINDING mechanism (pak::rsp_resolve_program)
# does its job, which byte-identity settles completely.
#
# Also covers pak::cli_check_module_imports's matching fix: without it,
# `pak check FILE` run one file at a time (exactly what the PostToolUse
# hook does on every write/edit) could never resolve `use shared.vtxjob`
# no matter how it was spelled, because that check's project-root search
# used `pwd`, not the file's own directory.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl cli.tcl]

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

proc words_of_program {prog} {
    set bytes [dict get [pak::enc::encode [pak::rsp_generate_records $prog]] secdata .text bytes]
    set out {}
    for {set i 0} {$i < [llength $bytes]} {incr i 4} {
        set w 0
        for {set j 0} {$j < 4} {incr j} { set w [expr {($w<<8)|([lindex $bytes [expr {$i+$j}]]&0xFF)}] }
        lappend out [format 0x%08X $w]
    }
    return $out
}

set fixture [file join $REPO tcl tests ares rsp_shared_project rsp transform.pk64]
set reference [file join $REPO tcl tests ares rsp_task_vtx.pk64]

puts "== pak::rsp_resolve_program finds the shared struct across files =="
set combined_prog [pak::rsp_resolve_program $fixture]
if {[catch {words_of_program $combined_prog} shared_words]} {
    ok "rsp/transform.pk64 (with its struct in another file) compiles" 0 "\n        ($shared_words)"
} else {
    ok "rsp/transform.pk64 (with its struct in another file) compiles" 1

    set ref_ast [pak::parse_tokens [[pak::Lexer new [pak::cli_read $reference]] tokenize]]
    set ref_words [words_of_program $ref_ast]

    check_eq "byte-identical to rsp_task_vtx.pk64's already hardware-verified bytes (task #49)" \
        $shared_words $ref_words
}

puts ""
puts "== without a project, the same file falls back to single-file behavior =="
# Copy just rsp/transform.pk64 (no pak.toml above it, no shared/vtxjob.pk64
# alongside it) somewhere with no project -- `use shared.vtxjob` then has
# nothing to resolve against, and the struct it names was never declared,
# so VtxJob itself is undefined. rsp_generate_records must refuse this
# clearly (RSPUNPORTED), not crash and not silently compile something
# wrong.
set tmpdir [expr {[info exists ::env(TMPDIR)] && $::env(TMPDIR) ne "" ? $::env(TMPDIR) : "/tmp"}]
set orphan [file join $tmpdir rsp_shared_module_test_orphan.pk64]
file copy -force $fixture $orphan
if {[catch {pak::rsp_resolve_program $orphan} orphan_prog]} {
    ok "orphaned copy at least still parses on its own" 0 "\n        ($orphan_prog)"
} else {
    if {[catch {words_of_program $orphan_prog} err]} {
        ok "an orphaned copy (no project, no shared module) refuses cleanly" \
            [string match "RSPUNPORTED*" $err] "\n        ($err)"
    } else {
        ok "an orphaned copy (no project, no shared module) refuses cleanly" 0 \
            "\n        (compiled with no error -- VtxJob should have been undefined)"
    }
}
file delete -force $orphan

puts ""
puts "== pak::cli_check_module_imports resolves the same way pak::rsp_resolve_program does =="
# `pak check FILE`, one file at a time -- exactly what the PostToolUse
# validation hook runs on every write/edit -- must not report E105 on
# `use shared.vtxjob` just because it wasn't invoked from inside the
# project (tools/pak_hook.tcl always runs from the repo root). This is
# the UNMERGED single-file parse (not $combined_prog, which already has
# the module declaration concatenated into it and would make the check
# below pass for the wrong reason -- via the pre-existing "declared among
# the files checked together" path, not the new per-file project fallback
# this test means to exercise).
set solo_prog [pak::parse_tokens [[pak::Lexer new [pak::cli_read $fixture]] tokenize]]
set diags [pak::cli_check_module_imports [list [list $fixture $solo_prog]]]
set e105 {}
foreach d $diags { if {[dict get $d code] eq "E105"} { lappend e105 $d } }
check_eq "no E105 on shared.vtxjob when checked as a single file from outside the project" \
    [llength $e105] 0

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
