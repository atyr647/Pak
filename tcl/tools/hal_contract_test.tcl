#!/usr/bin/env tclsh
# The HAL contract, over the whole corpus.
#
# `pak check --backend mips` decides whether a program is a valid standalone
# program. Its answer is a promise: if it accepts, the MIPS backend has to be
# able to lower it. When the two disagree the failure surfaces as an UNPORTED
# from the codegen, or later as an undefined symbol at link -- long after the
# checker said the program was fine.
#
# tcl/tools/link_test.tcl enforces the same promise, but only over
# examples/canonical: 32 files. Five of the other 570 broke it, and had been
# broken for as long as the tables disagreed. The causes were all of a kind --
# the checker and the codegen answering "is this a module call?" differently:
#
#   * `use n64.display as disp` -- the C backend resolved the alias and the
#     MIPS backend never recorded it, so `disp.init(...)` looked like a method
#     call on a receiver with no type.
#   * the codegen tested MIPS_API membership where the checker tests the union
#     of the API tables plus the HAL, so `joypad.poll()` fell in the gap.
#   * a module called with no `use` was not recognised as a module call by the
#     checker at all, so `arena.alloc(a, 4)` skipped the HAL check entirely.
#
# Everything the corpus has, in one process, because 600 files x two forked
# interpreters is minutes and this has to be cheap enough to run every time.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl checker.tcl]
source [file join $REPO tcl typechecker.tcl]
source [file join $REPO tcl mips_codegen.tcl]

proc corpus {} {
    set files {}
    foreach root {examples ai tests tcl/tests} {
        if {[file isdirectory $root]} { lappend files {*}[walk $root] }
    }
    return [lsort -unique $files]
}
proc walk {dir} {
    set out {}
    # tests/golden holds expected outputs, not corpus inputs.
    if {[file tail $dir] eq "golden" && [file tail [file dirname $dir]] eq "tests"} {
        return {}
    }
    foreach item [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $item]} {
            lappend out {*}[walk $item]
        } elseif {[file extension $item] eq ".pk64"} {
            lappend out $item
        }
    }
    return $out
}

set accepted 0
set broken {}
set unparsable 0

foreach f [corpus] {
    set fh [open $f r]; fconfigure $fh -encoding utf-8
    set src [read $fh]; close $fh

    # A file that does not parse is an error fixture, not a contract question.
    if {[catch {
        set lx [pak::Lexer new $src]
        set ast [pak::parse_tokens [$lx tokenize]]
    }]} {
        incr unparsable
        continue
    }

    # Both passes, because `pak check` runs both and its verdict is the one
    # that makes the promise. Running only the checker made this gate report
    # E602 fixtures as contract breaks -- the typechecker had already rejected
    # them.
    set rejected 0
    if {[catch {
        # Not `env`: that is Tcl's environment array, and assigning to it
        # throws -- which the catch below turned into "skip this file",
        # silently, for all 600 of them.
        set tenv [pak::TypeEnv new]
        $tenv collect [pak::items [pak::nfield $ast decls]]
        set tc [pak::TypeChecker new $tenv $f 1]
        set tds [$tc check [pak::items [pak::nfield $ast decls]]]
        $tc destroy
        $tenv destroy
        foreach d $tds {
            if {[dict get $d severity] ne "warning"} { set rejected 1; break }
        }
    }]} { continue }
    if {!$rejected} {
        if {[catch {set diags [pak::semantic_check $ast $f mips]}]} { continue }
        foreach d $diags {
            if {[dict exists $d severity] && [dict get $d severity] eq "error"} {
                set rejected 1; break
            }
        }
    }
    if {$rejected} { continue }

    # The checker accepted it, so the backend has to lower it.
    incr accepted
    if {[catch {pak::mips_generate $ast} err]} {
        if {[string match "MIPSUNPORTED*" $err]} {
            lappend broken [list $f [lindex [split $err \t] 1]]
        } else {
            lappend broken [list $f $err]
        }
    }
}

puts "HAL contract: $accepted files accepted by `pak check --backend mips`"
puts "              ([format %d $unparsable] unparsable, not a contract question)"

# The invariant holds vacuously if the checker starts refusing everything, so
# the count is part of the gate: it only ever goes up.
set FLOOR 420
if {$accepted < $FLOOR} {
    puts ""
    puts "FAIL  only $accepted files are accepted for the standalone backend,"
    puts "      below the floor of $FLOOR. Either the corpus shrank or the"
    puts "      checker started refusing things it used to accept -- which"
    puts "      would make the rest of this gate pass for the wrong reason."
    exit 1
}

if {[llength $broken] == 0} {
    puts ""
    puts "ok    every one of them lowers"
    exit 0
}

puts ""
puts "FAIL  [llength $broken] accepted by the checker and refused by the codegen:"
foreach b $broken {
    lassign $b path why
    puts "        $path"
    puts "            $why"
}
exit 1
