#!/usr/bin/env tclsh
# tcl/tools/libdragon_api_test.tcl — the generated C matches libdragon's REAL API.
#
#   tclsh tcl/tools/libdragon_api_test.tcl           # gate
#   tclsh tcl/tools/libdragon_api_test.tcl --list    # per-file error counts
#   tclsh tcl/tools/libdragon_api_test.tcl --regen   # rewrite the known-broken list
#
# Why this exists, separately from tcl/tools/c_compile_test.tcl: that gate
# stubs libdragon, declaring every symbol from MODULE_API as `long sym();`.
# An unprototyped declaration accepts any argument count and any argument
# types, so all of these compile clean there and fail at a user's `make`:
#
#   * an #include of a header libdragon does not have
#   * a call to a function libdragon does not have
#   * the wrong number of arguments
#   * the wrong argument types
#
# All four were live in this repo when this gate was written: the rdpq module
# included <rdpq_gfx.h>, which does not exist; rdpq_attach_clear was called
# with one argument where libdragon takes two; display_init was passed raw
# integers where libdragon takes a resolution_t struct. Not one of them was
# visible.
#
# This compiles the same generated C against the real headers, pinned by
# tools/fetch_libdragon.sh. It compiles rather than links, so no MIPS
# toolchain and no built libdragon are needed -- and compiling is where the
# whole signature-mismatch class lives.
#
# The host compiler is not a cross-compiler, so this cannot speak to ABI, type
# sizes or alignment. It is not trying to: it is checking that the CALLS match
# the DECLARATIONS. -w is on because libdragon's own headers warn under a
# 64-bit `long` (%ld against int32_t), which is an artefact of compiling for
# the host and says nothing about Pak.
#
# tests/libdragon_api_known_broken.txt is the debt. The gate fails in BOTH
# directions: a file off the list that stops compiling is a regression, and a
# file on the list that starts compiling must be removed from it.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO

set KNOWN [file join $REPO tests libdragon_api_known_broken.txt]
set CC    [expr {[info exists ::env(CC)] ? $::env(CC) : "cc"}]
set CACHE [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set LDINC [file join $CACHE pak-libdragon libdragon include]

set MODE gate
foreach a $argv {
    switch -- $a {
        --list  { set MODE list }
        --regen { set MODE regen }
    }
}

# ── preconditions: skip cleanly, the way the pixel gate does ─────────────────

if {[catch {exec sh -c "command -v $CC"}]} {
    puts "libdragon api: SKIP (no $CC)"
    exit 0
}
if {![file isdirectory $LDINC]} {
    catch {exec bash [file join $REPO tools fetch_libdragon.sh] [file join $CACHE pak-libdragon]} out
    puts $out
}
if {![file isdirectory $LDINC]} {
    puts "libdragon api: SKIP (no libdragon headers; run tools/fetch_libdragon.sh)"
    exit 0
}

# ── the corpus ───────────────────────────────────────────────────────────────

proc known_broken {} {
    global KNOWN
    set out {}
    if {![file exists $KNOWN]} { return $out }
    set fh [open $KNOWN r]; set t [read $fh]; close $fh
    foreach line [split $t "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        lappend out $line
    }
    return $out
}

set WORK [file join $CACHE pak-libdragon-api]
file mkdir $WORK

set results [dict create]
foreach src [lsort [glob -nocomplain [file join $REPO examples canonical *.pk64]]] {
    set name [file rootname [file tail $src]]
    set cfile [file join $WORK "$name.c"]
    if {[catch {exec [info nameofexecutable] [file join $REPO tcl cli.tcl] explain $src} c]} {
        dict set results $name [list 1 "pak explain failed: [lindex [split $c "\n"] 0]"]
        continue
    }
    set fh [open $cfile w]; puts $fh $c; close $fh
    set rc 0
    set err ""
    if {[catch {
        exec $CC -fsyntax-only -w -I$LDINC -I[file join $REPO runtime] $cfile 2>@1
    } err]} { set rc 1 }
    dict set results $name [list $rc $err]
}

# ── report ───────────────────────────────────────────────────────────────────

proc n_errors {text} {
    set n 0
    foreach line [split $text "\n"] { if {[string match "*error:*" $line]} { incr n } }
    return $n
}

if {$MODE eq "list"} {
    foreach name [lsort [dict keys $results]] {
        lassign [dict get $results $name] rc err
        if {$rc} { puts [format "%-24s %d error(s)" $name [n_errors $err]] }
    }
    exit 0
}

set broken {}
foreach name [lsort [dict keys $results]] {
    lassign [dict get $results $name] rc err
    if {$rc} { lappend broken $name }
}

if {$MODE eq "regen"} {
    set fh [open $KNOWN w]
    puts $fh "# Canonical examples whose generated C does NOT compile against the real"
    puts $fh "# libdragon headers, pinned by tools/fetch_libdragon.sh."
    puts $fh "#"
    puts $fh "# Maintained by tcl/tools/libdragon_api_test.tcl. This is debt, not"
    puts $fh "# configuration: fix the binding, drop the name, and the gate holds the"
    puts $fh "# new floor. Adding a name is how a regression gets waved through, so add"
    puts $fh "# one only with the reason written down."
    puts $fh ""
    foreach n $broken { puts $fh $n }
    close $fh
    puts "libdragon api: wrote [llength $broken] name(s) to [file tail $KNOWN]"
    exit 0
}

set known [known_broken]
set total [dict size $results]
set regressed {}
set fixed {}
foreach name $broken {
    if {$name ni $known} { lappend regressed $name }
}
foreach name $known {
    if {$name ni $broken} { lappend fixed $name }
}

puts "libdragon api gate: [expr {$total - [llength $broken]}]/$total canonical examples"
puts "                    compile against libdragon [string range [exec sh -c "cd $CACHE/pak-libdragon/libdragon && git rev-parse --short HEAD 2>/dev/null || echo unknown"] 0 11]"
puts "                    [llength $known] known-broken, [llength $regressed] regressed, [llength $fixed] newly fixed"

if {[llength $regressed] > 0} {
    puts ""
    puts "REGRESSED -- these compiled before and do not now:"
    foreach n $regressed {
        lassign [dict get $results $n] rc err
        puts "  $n"
        set shown 0
        foreach line [split $err "\n"] {
            if {[string match "*error:*" $line] && $shown < 3} { puts "      $line"; incr shown }
        }
    }
}
if {[llength $fixed] > 0} {
    puts ""
    puts "NEWLY FIXED -- remove from [file tail $KNOWN]:"
    foreach n $fixed { puts "  $n" }
}
if {[llength $regressed] > 0 || [llength $fixed] > 0} { exit 1 }
puts ""
puts "no regressions."
