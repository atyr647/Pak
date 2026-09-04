#!/usr/bin/env tclsh
# Link the canonical examples into real ROMs, instead of stopping at objgen.
#
#   tclsh tcl/tools/link_test.tcl           # gate
#   tclsh tcl/tools/link_test.tcl --list    # per-example result
#   tclsh tcl/tools/link_test.tcl --regen   # rewrite the known-broken list
#
# Why this exists: CI ran `pak objgen` over the corpus and stopped. objgen
# succeeds on a program that references symbols nothing defines -- the failure
# only appears at `pak link`, which nothing ran. A fix16.16 const shipped for
# months as `la $t8, GRAVITY` against a symbol no section declared.
#
# Only programs `pak check --backend mips` accepts are linked: an example that
# calls libdragon-only APIs is not a standalone program and its objects are
# not expected to resolve. That check is the HAL contract, so this gate and
# the contract cannot disagree about which examples count.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
set PAK  [file join $REPO tcl cli.tcl]
set KNOWN [file join $REPO tests link_known_broken.txt]

proc run {args} {
    if {[catch {exec tclsh {*}$args 2>@1} out]} { return [list 1 $out] }
    return [list 0 $out]
}

proc read_known {} {
    global KNOWN
    set names {}
    if {![file exists $KNOWN]} { return $names }
    foreach line [split [read [open $KNOWN r]] "\n"] {
        set line [string trim $line]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        lappend names $line
    }
    return $names
}

proc write_known {names} {
    global KNOWN
    set fh [open $KNOWN w]
    puts $fh "# Canonical examples that pass `pak check --backend mips` but do NOT link."
    puts $fh "#"
    puts $fh "# Every name here is a hole in the HAL contract: the checker said the"
    puts $fh "# program is a valid standalone program, and then the linker could not"
    puts $fh "# resolve a symbol the codegen emitted. Maintained by"
    puts $fh "# tcl/tools/link_test.tcl. This is debt and can only shrink."
    puts $fh ""
    foreach n [lsort $names] { puts $fh $n }
    close $fh
}

set mode gate
if {"--list"  in $argv} { set mode list }
if {"--regen" in $argv} { set mode regen }

set tmp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] pak_link_test]
file delete -force $tmp
file mkdir $tmp

# The runtime halves every ROM needs.
set boot [file join $tmp boot.pakobj]
set rt   [file join $tmp runtime.pakobj]
lassign [run $PAK asmobj [file join $REPO runtime standalone boot.S] -o $boot] rc out
if {$rc} { puts "link gate: cannot assemble boot.S\n$out"; exit 1 }
lassign [run $PAK objgen [file join $REPO runtime standalone runtime.pk64] -o $rt] rc out
if {$rc} { puts "link gate: cannot objgen runtime.pk64\n$out"; exit 1 }

set linked {}
set broken {}
set skipped {}
set detail [dict create]
foreach pk [lsort [glob -nocomplain [file join $REPO examples canonical *.pk64]]] {
    set name [file tail $pk]
    lassign [run $PAK check $pk --backend mips] rc _
    if {$rc} { lappend skipped $name; continue }
    set obj [file join $tmp [file rootname $name].pakobj]
    lassign [run $PAK objgen $pk -o $obj] rc out
    if {$rc} {
        lappend broken $name
        dict set detail $name "objgen failed: [lindex [split $out \n] 0]"
        continue
    }
    lassign [run $PAK link $boot $rt $obj -o [file join $tmp out.z64] --name PAKCI] rc out
    if {$rc} {
        lappend broken $name
        set first ""
        foreach l [split $out \n] {
            if {[string trim $l] ne "" && ![string match "link error:*" $l]} { set first [string trim $l]; break }
        }
        dict set detail $name $first
    } else {
        lappend linked $name
    }
}

if {$mode eq "list"} {
    foreach n $broken { puts [format "%-24s %s" $n [dict get $detail $n]] }
    puts ""
    puts "links: [llength $linked]  broken: [llength $broken]  not standalone: [llength $skipped]"
    exit 0
}
if {$mode eq "regen"} {
    write_known $broken
    puts "wrote [llength $broken] known-broken names to [file tail $KNOWN]"
    exit 0
}

set known [read_known]
set regressed {}
set fixed {}
foreach n $broken { if {$n ni $known}  { lappend regressed $n } }
foreach n $known  { if {$n ni $broken} { lappend fixed $n } }

puts "link gate: [llength $linked] linked, [llength $broken] broken, [llength $skipped] not standalone"
puts "           [llength $known] known-broken, [llength $regressed] regressed, [llength $fixed] newly fixed"

set rc 0
if {[llength $regressed]} {
    puts ""
    puts "REGRESSION -- these no longer link:"
    foreach n $regressed { puts "  $n -- [dict get $detail $n]" }
    set rc 1
}
if {[llength $fixed]} {
    puts ""
    puts "FIXED -- these now link; drop them from tests/link_known_broken.txt:"
    foreach n $fixed { puts "  $n" }
    puts "  (tclsh tcl/tools/link_test.tcl --regen)"
    set rc 1
}
if {$rc == 0} { puts ""; puts "no regressions." }
exit $rc
