#!/usr/bin/env tclsh
# tcl/tools/fuzz_test.tcl — the compiler front end must never crash on garbage.
#
# Every diagnostic the corpus and tests/invalid/ exercise is a mistake someone
# thought to write down. A fuzzer finds the ones nobody did: a `struct` whose
# body ends at EOF, a cast with no type after it, an annotation with an
# unterminated paren, a `match` arm that is half a token.
#
# The contract this enforces is not "reject bad input" — plenty of mutants are
# valid Pak. It is:
#
#   * the lexer either succeeds or raises LEXERROR;
#   * the parser either succeeds or raises PARSEERROR;
#   * the checker and typechecker RETURN diagnostics and never raise at all;
#   * codegen either succeeds or raises CGUNPORTED / MIPSUNPORTED.
#
# Anything else — "can't read", "invalid command name", "list element in
# braces", an AST-schema assertion — is the compiler falling over, and the
# user sees a Tcl stack trace instead of an error message with a line number.
#
# Deterministic: the seed drives everything, so a failure reproduces exactly.
# A failing input is written to /tmp for the report to point at, and the mutant
# currently under the compiler is always on disk at /tmp/pak-fuzz/current.pk64
# — DEADLINE can only be checked between mutants, so if one wedges the compiler
# outright (the parser used to spin forever on `.ok(1)`) that file names it.
#
#   tclsh tcl/tools/fuzz_test.tcl                # the CI budget
#   ITERATIONS=20000 SEED=7 tclsh tcl/tools/fuzz_test.tcl
#   tclsh tcl/tools/fuzz_test.tcl --file bad.pk64   # re-run one input

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl typechecker.tcl]
source [file join $REPO tcl checker.tcl]
source [file join $REPO tcl codegen.tcl]
source [file join $REPO tcl mips_codegen.tcl]
source [file join $REPO tcl optimize.tcl]

set ITERATIONS [expr {[info exists ::env(ITERATIONS)] ? $::env(ITERATIONS) : 3000}]
set SEED       [expr {[info exists ::env(SEED)] ? $::env(SEED) : 20260905}]
# A wall-clock ceiling, so the gate costs a bounded amount of CI time whatever
# the corpus grows into, and a per-mutant ceiling: taking minutes over a few
# kilobytes of source is a defect in its own right, and without this it just
# looks like the suite hanging.
set DEADLINE   [expr {[info exists ::env(DEADLINE)] ? $::env(DEADLINE) : 120}]
set SLOW_MS    [expr {[info exists ::env(SLOW_MS)] ? $::env(SLOW_MS) : 5000}]
set WORK [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] pak-fuzz]
file mkdir $WORK
set CURRENT [file join $WORK current.pk64]

# ── the contract ─────────────────────────────────────────────────────────────

# Error tags the front end is allowed to raise. Everything else is a crash.
set ::EXPECTED_TAGS {LEXERROR PARSEERROR CGUNPORTED MIPSUNPORTED C2PAKUNPORTED}

proc tag_of {err} {
    set t [lindex [split $err "\t"] 0]
    return $t
}

proc is_expected {err} {
    return [expr {[lsearch -exact $::EXPECTED_TAGS [tag_of $err]] >= 0}]
}

# How far mutants get. A fuzzer that only ever trips the lexer proves nothing
# about the parser, so these are reported and floor-checked at the end: if a
# change starts rejecting everything at the first stage, the run stops being a
# test and says so instead of passing quietly.
array set ::reached {lex 0 parse 0 check 0 codegen 0}

# Run every front-end stage over one source string. Returns "" when the source
# behaved (compiled, or failed with a diagnostic), or a description of the
# crash it caused.
proc compile_once {src} {
    # 1. lex
    set toks ""
    if {[catch {
        set lx [pak::Lexer new $src]
        set toks [$lx tokenize]
    } err]} {
        if {[is_expected $err]} { return "" }
        return "lexer: $err"
    }

    incr ::reached(lex)

    # 2. parse
    set ast ""
    if {[catch { set ast [pak::parse_tokens $toks] } err]} {
        if {[is_expected $err]} { return "" }
        return "parser: $err"
    }

    incr ::reached(parse)

    # 3. typecheck — returns diagnostics, must not raise
    set clean 1
    if {[catch {
        set env [pak::TypeEnv new]
        $env collect [pak::items [pak::nfield $ast decls]]
        set tc [pak::TypeChecker new $env fuzz.pk64 0]
        set diags [$tc check [pak::items [pak::nfield $ast decls]]]
        $tc destroy
        $env destroy
        foreach d $diags {
            if {[dict get $d severity] ne "warning"} { set clean 0 }
        }
    } err]} {
        return "typechecker: $err"
    }

    # 4. semantic check — same contract
    if {[catch {
        foreach d [pak::semantic_check $ast fuzz.pk64 c] {
            if {[dict get $d severity] ne "warning"} { set clean 0 }
        }
    } err]} {
        return "checker: $err"
    }

    # 5. codegen, but only on input the checker accepted. Lowering an AST the
    #    checker rejected is not a supported path -- the compiler stops before
    #    it -- so a failure there is not evidence of anything.
    incr ::reached(check)
    if {$clean} {
        incr ::reached(codegen)
        if {[catch { pak::generate $ast fuzz.pk64 } err]} {
            if {![is_expected $err]} { return "codegen(c): $err" }
        }
        if {[catch {
            pak::records_to_asm [pak::optimize_records [pak::mips_generate_records $ast]]
        } err]} {
            if {![is_expected $err]} { return "codegen(mips): $err" }
        }
    }
    return ""
}

# ── mutation ─────────────────────────────────────────────────────────────────

# Characters that carry structure in Pak, so a single insertion is much more
# likely to reach a parser corner than a random byte would be.
set ::SPICE [list "\{" "\}" "(" ")" "\[" "\]" "<" ">" "\"" "'" "@" "#" ":" ";" \
                  "," "." "=" "-" "+" "*" "/" "%" "&" "|" "!" "?" "\\" "_" \
                  "0" "9" "\n" "\t" " "]
set ::WORDS {fn entry struct enum variant impl trait use asset const static let mut
             if elif else loop while for break continue return match defer as
             and or not none true false i32 u32 f32 u8 bool self}

proc rnd {n} {
    if {$n <= 0} { return 0 }
    return [expr {int(rand() * $n)}]
}

proc mutate {src} {
    set n [string length $src]
    if {$n < 2} { return "fn" }
    switch -- [rnd 8] {
        0 {
            # Delete a span. Finds the "body ran out early" family.
            set a [rnd $n]; set b [expr {$a + 1 + [rnd 64]}]
            return [string replace $src $a $b ""]
        }
        1 {
            # Truncate. Every construct, cut off mid-token.
            return [string range $src 0 [rnd $n]]
        }
        2 {
            # Insert a structural character.
            set a [rnd $n]
            return [string replace $src $a [expr {$a - 1}] \
                [lindex $::SPICE [rnd [llength $::SPICE]]]]
        }
        3 {
            # Overwrite one character with a structural one.
            set a [rnd $n]
            return [string replace $src $a $a [lindex $::SPICE [rnd [llength $::SPICE]]]]
        }
        4 {
            # Splice a keyword in where one does not belong.
            set a [rnd $n]
            return [string replace $src $a [expr {$a - 1}] \
                " [lindex $::WORDS [rnd [llength $::WORDS]]] "]
        }
        5 {
            # Duplicate a span: unbalanced braces, doubled declarations.
            set a [rnd $n]; set b [expr {$a + 1 + [rnd 128]}]
            set piece [string range $src $a $b]
            return [string replace $src $a [expr {$a - 1}] $piece]
        }
        6 {
            # Swap two spans.
            set a [rnd $n]; set b [rnd $n]
            set la [string range $src $a [expr {$a + 8}]]
            set lb [string range $src $b [expr {$b + 8}]]
            set out [string replace $src $a [expr {$a + 8}] $lb]
            return [string replace $out $b [expr {$b + 8}] $la]
        }
        default {
            # Replace one keyword with another, keeping the file plausible.
            set w [lindex $::WORDS [rnd [llength $::WORDS]]]
            set v [lindex $::WORDS [rnd [llength $::WORDS]]]
            return [string map [list $w $v] $src]
        }
    }
}

# ── corpus ───────────────────────────────────────────────────────────────────

proc corpus {} {
    set out {}
    foreach dir {examples/canonical tests/invalid} {
        foreach f [lsort [glob -nocomplain [file join $dir *.pk64]]] {
            set fh [open $f r]; lappend out [read $fh]; close $fh
        }
    }
    return $out
}

# ── single-file mode: reproduce one saved crash ──────────────────────────────

if {[lindex $argv 0] eq "--file"} {
    set f [lindex $argv 1]
    set fh [open $f r]; set src [read $fh]; close $fh
    set t0 [clock milliseconds]
    set why [compile_once $src]
    set dt [expr {[clock milliseconds] - $t0}]
    if {$why eq ""} {
        puts "ok    $f compiles or diagnoses cleanly (${dt}ms)"
        exit 0
    }
    puts "FAIL  $f\n        $why"
    exit 1
}

# ── the run ──────────────────────────────────────────────────────────────────

set seeds [corpus]
if {[llength $seeds] == 0} {
    puts "fuzz: SKIP (no corpus found)"
    exit 0
}

expr {srand($SEED)}
puts "== fuzzing the front end =="
puts "seed=$SEED iterations=$ITERATIONS corpus=[llength $seeds] files"

# The unmutated corpus first: if a pristine canonical example crashes the
# compiler, that is the bug to report, not whatever the mutator finds after it.
set fails 0
set i 0
foreach src $seeds {
    incr i
    set why [compile_once $src]
    if {$why ne ""} {
        puts "FAIL  corpus file $i (unmutated)\n        $why"
        incr fails
    }
}
if {$fails > 0} {
    puts "\nPASS=0  FAIL=$fails  (the corpus itself does not compile)"
    exit 1
}
puts "ok    all [llength $seeds] corpus files compile or diagnose cleanly"

# From here the depth counters are about mutants only.
array set ::reached {lex 0 parse 0 check 0 codegen 0}

# Mutants. Each starts from a random corpus file and takes one to three
# mutations, so most stay recognisably Pak and reach deep into the parser.
set crashes {}
set slow {}
set started [clock milliseconds]
set ran 0
for {set n 1} {$n <= $ITERATIONS} {incr n} {
    if {[clock milliseconds] - $started > $DEADLINE * 1000} { break }
    set src [lindex $seeds [rnd [llength $seeds]]]
    set rounds [expr {1 + [rnd 3]}]
    for {set k 0} {$k < $rounds} {incr k} { set src [mutate $src] }

    # The mutant currently under the compiler, on disk before it goes in. The
    # deadline can only be checked between mutants, so if one wedges the
    # compiler outright this file is the reproducer.
    set cur [open $CURRENT w]; puts -nonewline $cur $src; close $cur

    set t0 [clock milliseconds]
    set why [compile_once $src]
    set dt [expr {[clock milliseconds] - $t0}]
    incr ran

    if {$why ne ""} {
        set out [file join $WORK "crash-$SEED-$n.pk64"]
        set fh [open $out w]; puts -nonewline $fh $src; close $fh
        lappend crashes [list $n $why $out]
        # Stop after a handful: past that the report is noise, and one
        # reproducer is enough to fix a crash.
        if {[llength $crashes] >= 5} break
    } elseif {$dt > $SLOW_MS} {
        set out [file join $WORK "slow-$SEED-$n.pk64"]
        set fh [open $out w]; puts -nonewline $fh $src; close $fh
        lappend slow [list $n $dt [string length $src] $out]
        if {[llength $slow] >= 3} break
    }
}

file delete -force $CURRENT
puts ""
puts [format "      %d mutants in %.1fs; reaching: lexed %d, parsed %d, checked %d, lowered %d" \
    $ran [expr {([clock milliseconds] - $started) / 1000.0}] \
    $::reached(lex) $::reached(parse) $::reached(check) $::reached(codegen)]

foreach sl $slow {
    lassign $sl n dt len out
    puts "FAIL  mutant $n took ${dt}ms over $len bytes of source"
    puts "        reproduce: tclsh tcl/tools/fuzz_test.tcl --file $out"
}

if {[llength $crashes] == 0 && [llength $slow] == 0} {
    puts "ok    $ran mutants: no crash, every failure was a diagnostic"

    # A run where nothing survives the parser is not a passing run, it is a
    # run that tested one stage. The floors are deliberately low -- they catch
    # "the mutator broke" and "the lexer started rejecting everything", not a
    # few percent of drift.
    set depth_ok 1
    if {$::reached(parse) < $ran / 20} {
        puts "FAIL  only $::reached(parse) of $ran mutants parsed — the mutator is not reaching the parser"
        set depth_ok 0
    }
    if {$::reached(codegen) < $ran / 100} {
        puts "FAIL  only $::reached(codegen) of $ran mutants reached codegen"
        set depth_ok 0
    }
    if {$depth_ok} {
        puts "ok    mutants reached every stage"
        puts ""
        puts "PASS=3  FAIL=0"
        exit 0
    }
    puts ""
    puts "PASS=2  FAIL=1"
    exit 1
}

foreach c $crashes {
    lassign $c n why out
    puts "FAIL  mutant $n crashed the compiler"
    puts "        $why"
    puts "        reproduce: tclsh tcl/tools/fuzz_test.tcl --file $out"
}
puts ""
puts "PASS=1  FAIL=[expr {[llength $crashes] + [llength $slow]}]"
exit 1
