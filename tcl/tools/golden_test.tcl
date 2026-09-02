#!/usr/bin/env tclsh
# tcl/tools/golden_test.tcl — front-end regression gate for the Tcl compiler.
#
# Replaces the old *_parity.sh scripts, which compared each Tcl stage against a
# live Python oracle. The Python implementation is gone; the goldens in
# tests/golden/ are the frozen output of its last run and are now the oracle.
#
#   tests/golden/lex.sha256    — sha256 of each corpus file's token dump
#   tests/golden/ast.sha256    — sha256 of each corpus file's AST dump
#   tests/golden/cg.sha256     — sha256 of each corpus file's generated C
#   tests/golden/mips.sha256   — sha256 of each corpus file's MIPS assembly
#                                (float literals keep their source spelling, so
#                                 `0.000001` stays `0.000001f` rather than the
#                                 `1e-06f` the Python oracle's float repr gave)
#   tests/golden/check/*.txt   — checker diagnostics, verbatim
#   tests/golden/tc/*.txt      — typechecker diagnostics, verbatim
#   tests/golden/header/*.h    — generated module headers
#   tests/golden/c2pak/*.pk64  — C-to-Pak transpiler output
#   tests/golden/makefile.txt  — generated Makefiles for four project shapes
#   tests/golden/pakfs.txt     — PakFS archive layout for three scenarios
#
# Token and AST dumps run to megabytes across the corpus, so they are gated by
# hash; the corpus file itself is what you diff when one moves. Diagnostics are
# small and worth reading, so those are stored in full.
#
# Usage:
#   tclsh tcl/tools/golden_test.tcl            # check every stage
#   tclsh tcl/tools/golden_test.tcl lex ast    # check only these stages
#   REGEN=1 tclsh tcl/tools/golden_test.tcl    # rewrite the goldens
#
# REGEN rewrites the goldens from the CURRENT Tcl output. Only do that when you
# have decided the new output is correct — it will happily bless a regression.
#
# The mips stage has no external oracle (the Python MIPS backend was removed
# before the port finished), so its goldens are a self-snapshot: they pin the
# current output, including the UNPORTED markers for constructs the backend
# cannot lower yet, so closing one of those gaps shows up as a deliberate
# golden change rather than passing unnoticed.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO

set STAGES {lex ast cg mips check tc header c2pak makefile pakfs}
set want $argv
if {[llength $want] == 0} { set want $STAGES }
foreach s $want {
    if {$s ni $STAGES} {
        puts stderr "golden_test: unknown stage '$s' (have: $STAGES)"
        exit 2
    }
}
set REGEN [expr {[info exists ::env(REGEN)] && $::env(REGEN) eq "1"}]
set VERBOSE [expr {[info exists ::env(VERBOSE)] && $::env(VERBOSE) eq "1"}]

# ── corpus ───────────────────────────────────────────────────────────────────

proc corpus {} {
    set files {}
    foreach root {examples ai tests tcl/tests} {
        if {![file isdirectory $root]} continue
        lappend files {*}[corpus_walk $root]
    }
    return [lsort -unique $files]
}
proc corpus_walk {dir} {
    set out {}
    # tests/golden holds expected outputs, including c2pak's .pk64 results.
    # Those are goldens, not corpus inputs.
    if {[file tail $dir] eq "golden" && [file tail [file dirname $dir]] eq "tests"} {
        return {}
    }
    foreach item [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $item]} {
            lappend out {*}[corpus_walk $item]
        } elseif {[file extension $item] eq ".pk64"} {
            lappend out $item
        }
    }
    return $out
}

proc write_golden {path content} {
    set body [string trimright $content "\n"]
    set fh [open $path w]
    if {$body ne ""} { puts $fh $body }
    close $fh
}

proc golden_name {path} {
    return "[string map {/ __ .pk64 {}} $path].txt"
}

proc run_dump {stage path} {
    if {[catch {exec [info nameofexecutable] \
            [file join $::HERE ${stage}_dump.tcl] $path 2>@1} out]} {
        # A dump that exits non-zero still produced text we want to compare;
        # only a genuine crash (no output) is reported as such.
        if {$out eq ""} { return "DUMPCRASH" }
    }
    return $out
}

# Hash the dump with the trailing newline trimmed and as UTF-8 bytes, so the
# manifest is independent of how a given dump script terminates its output.
proc sha {s} {
    return [::sha2::sha256 -hex [encoding convertto utf-8 [string trimright $s "\n"]]]
}

package require sha256

# ── hash-manifest stages (lex, ast) ──────────────────────────────────────────

proc check_hash_stage {stage files} {
    set manifest tests/golden/${stage}.sha256
    if {$::REGEN} {
        set lines {}
        foreach f $files { lappend lines "[sha [run_dump $stage $f]]  $f" }
        set fh [open $manifest w]
        puts -nonewline $fh [join $lines "\n"]\n
        close $fh
        puts "$stage: regenerated [llength $lines] entries"
        return 0
    }
    if {![file exists $manifest]} {
        puts "$stage: MISSING $manifest (run with REGEN=1)"
        return 1
    }
    set expected [dict create]
    set fh [open $manifest r]
    foreach line [split [string trim [read $fh]] "\n"] {
        set h [lindex $line 0]
        set p [string trim [string range $line 64 end]]
        dict set expected $p $h
    }
    close $fh

    set pass 0; set fail 0; set failed {}
    foreach f $files {
        if {![dict exists $expected $f]} {
            incr fail; lappend failed "$f (no golden — new file, run REGEN=1)"
            continue
        }
        if {[sha [run_dump $stage $f]] eq [dict get $expected $f]} {
            incr pass
        } else {
            incr fail; lappend failed $f
        }
    }
    foreach p [dict keys $expected] {
        if {$p ni $files} { incr fail; lappend failed "$p (golden for a file that no longer exists)" }
    }
    puts "$stage: PASS=$pass FAIL=$fail (of [llength $files])"
    if {$fail} { puts "  MISMATCHED:\n    [join $failed "\n    "]" }
    return $fail
}

# ── full-text stages (check, tc) ─────────────────────────────────────────────

proc check_text_stage {stage files} {
    set dir tests/golden/$stage
    if {$::REGEN} {
        file mkdir $dir
        foreach f $files {
            write_golden [file join $dir [golden_name $f]] [run_dump $stage $f]
        }
        puts "$stage: regenerated [llength $files] goldens"
        return 0
    }
    set pass 0; set fail 0; set failed {}
    foreach f $files {
        set gp [file join $dir [golden_name $f]]
        if {![file exists $gp]} {
            incr fail; lappend failed "$f (no golden — new file, run REGEN=1)"
            continue
        }
        set fh [open $gp r]; set want [read $fh]; close $fh
        set got [run_dump $stage $f]
        # The dumps end with a newline the golden captured verbatim; compare
        # trimmed so a trailing-newline difference is not a false failure.
        if {[string trimright $got "\n"] eq [string trimright $want "\n"]} {
            incr pass
        } else {
            incr fail; lappend failed $f
            if {$::VERBOSE} {
                puts "=== $stage MISMATCH: $f ==="
                puts "--- golden:\n$want"
                puts "--- tcl:\n$got"
            }
        }
    }
    puts "$stage: PASS=$pass FAIL=$fail (of [llength $files])"
    if {$fail} { puts "  MISMATCHED:\n    [join $failed "\n    "]" }
    return $fail
}

# ── per-input stages with a non-corpus input set (header, c2pak) ─────────────

# Each input maps to one golden file; `cmd` builds the dump command line.
proc check_mapped_stage {stage inputs golden_of cmd_of} {
    set dir tests/golden/$stage
    if {$::REGEN} { file mkdir $dir }
    set pass 0; set fail 0; set failed {}
    foreach in $inputs {
        set gp [file join $dir [apply $golden_of $in]]
        if {[catch {exec [info nameofexecutable] {*}[apply $cmd_of $in] 2>@1} got]} {
            if {$got eq ""} { set got "DUMPCRASH" }
        }
        if {$::REGEN} {
            write_golden $gp $got
            continue
        }
        if {![file exists $gp]} {
            incr fail; lappend failed "$in (no golden — run REGEN=1)"
            continue
        }
        set fh [open $gp r]; set want [read $fh]; close $fh
        if {[string trimright $got "\n"] eq [string trimright $want "\n"]} {
            incr pass
        } else {
            incr fail; lappend failed $in
            if {$::VERBOSE} { puts "=== $stage MISMATCH: $in ===\n--- golden:\n$want\n--- tcl:\n$got" }
        }
    }
    if {$::REGEN} { puts "$stage: regenerated [llength $inputs] goldens"; return 0 }
    puts "$stage: PASS=$pass FAIL=$fail (of [llength $inputs])"
    if {$fail} { puts "  MISMATCHED:\n    [join $failed "\n    "]" }
    return $fail
}

# ── whole-output stages (makefile, pakfs) ────────────────────────────────────

proc check_single_stage {stage} {
    set gp tests/golden/${stage}.txt
    if {[catch {exec [info nameofexecutable] [file join $::HERE ${stage}_dump.tcl] 2>@1} got]} {
        if {$got eq ""} { set got "DUMPCRASH" }
    }
    if {$::REGEN} {
        write_golden $gp $got
        puts "$stage: regenerated"
        return 0
    }
    if {![file exists $gp]} { puts "$stage: MISSING $gp (run with REGEN=1)"; return 1 }
    set fh [open $gp r]; set want [read $fh]; close $fh
    if {[string trimright $got "\n"] eq [string trimright $want "\n"]} {
        puts "$stage: PASS"
        return 0
    }
    puts "$stage: FAIL"
    if {$::VERBOSE} { puts "--- golden:\n$want\n--- tcl:\n$got" }
    return 1
}

# ── run ──────────────────────────────────────────────────────────────────────

set files [corpus]
set total_fail 0
foreach stage $want {
    switch -- $stage {
        lex - ast - cg - mips { incr total_fail [check_hash_stage $stage $files] }
        check - tc  { incr total_fail [check_text_stage $stage $files] }
        header {
            # Module headers, one per canonical example, under a synthetic
            # module path so the include guard is deterministic.
            incr total_fail [check_mapped_stage header \
                [lsort [glob -nocomplain examples/canonical/*.pk64]] \
                {{f} {return "[file rootname [file tail $f]].h"}} \
                {{f} {return [list [file join $::HERE header_dump.tcl] $f \
                    "demo.[file rootname [file tail $f]]"]}}]
        }
        c2pak {
            incr total_fail [check_mapped_stage c2pak \
                [lsort [glob -nocomplain tests/c2pak/inputs/*.c]] \
                {{f} {return "[file rootname [file tail $f]].pk64"}} \
                {{f} {return [list [file join $::HERE c2pak_dump.tcl] $f]}}]
        }
        makefile - pakfs { incr total_fail [check_single_stage $stage] }
    }
}
puts ""
if {$total_fail} {
    puts "golden: $total_fail failure(s)"
    exit 1
}
puts "golden: all stages match"
