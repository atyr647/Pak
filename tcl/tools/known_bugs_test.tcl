#!/usr/bin/env tclsh
# tcl/tools/known_bugs_test.tcl — the Known Bugs table has to be true.
#
# CURRENTLY_SUPPORTED.md carries one table of what is broken right now. It is
# the first thing anyone reads to decide whether Pak can be trusted with a
# project, and it is worth exactly as much as its worst row. The failure mode
# it invites is not a wrong row -- it is prose elsewhere in the repo saying "X
# cannot run Y" while the table says "None outstanding", because the table is
# edited when a bug is fixed and the prose is not.
#
# So: any line in any Markdown file that states a blocker has to say which it
# is. Two markers, both inline:
#
#   known-bug: <id>       this line describes bug <id>, which must have a row
#                         in the Known Bugs table
#   known-bug: n/a        this line is not describing a live blocker (history,
#                         a fixed bug, a quoted error message, this file's own
#                         explanation) -- give a reason after the marker
#
# A row in the table declares its id the same way. An id with no row fails; a
# row whose id nothing references fails too, because a bug nobody can reach
# from the docs is a bug nobody will fix.
#
#   tclsh tcl/tools/known_bugs_test.tcl

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO

set pass 0
set fail 0
proc ok   {msg} { incr ::pass; puts "ok    $msg" }
proc bad  {msg} { incr ::fail; puts "FAIL  $msg" }

# Phrases that assert something is broken *now*. Deliberately short: a longer
# list catches more prose and teaches people to write around the gate.
#
# The second group was added after examples/chroma/README.md sat for a release
# saying `triangle_tex` "does not draw correctly yet" and calling it "the
# blocker for the nave" -- both false since the TRI_TEX pixel gate went green,
# and neither matched anything in the first group. A scanner that only knows
# how the last stale claim was phrased will always be one phrasing behind, so
# these are the ways a doc says "this feature does not produce output", not the
# ways this one did.
set BLOCKERS {
    {known bug}
    {cannot run}
    {does not boot}
    {will not boot}
    {is broken}
    {currently broken}
    {wrong on hardware}
    {not supported yet}
    {does not draw}
    {does not render}
    {blocker}
    {stubbed}
    {until this is fixed}
}

proc markers {line} {
    set out {}
    foreach {- id} [regexp -all -inline {known-bug:\s*([A-Za-z0-9._/-]+)} $line] {
        lappend out $id
    }
    return $out
}

# ── the table ────────────────────────────────────────────────────────────────

set src CURRENTLY_SUPPORTED.md
set f [open $src r]; set text [read $f]; close $f

set lines [split $text "\n"]
set in_table 0
set declared [dict create]
set body_seen 0
foreach line $lines {
    if {[regexp {^##\s+Known Bugs} $line]} { set in_table 1; continue }
    if {$in_table && [regexp {^##\s} $line]} { set in_table 0; continue }
    if {!$in_table} continue
    if {[string trim $line] eq ""} continue
    if {[regexp {^\|\s*-+} $line]} continue
    if {[regexp {^\|\s*Bug\s*\|} $line]} continue
    if {[string index [string trim $line] 0] eq "|"} {
        set body_seen 1
        set ids [markers $line]
        if {[llength $ids] == 0} {
            bad "Known Bugs row declares no id (add `known-bug: <id>`): [string range [string trim $line] 0 70]"
        }
        foreach id $ids {
            if {$id eq "n/a"} {
                bad "Known Bugs row uses the `n/a` marker, which is for prose, not rows"
            } else {
                dict set declared $id 1
            }
        }
    }
}

if {$body_seen} {
    ok "Known Bugs table has [dict size $declared] row(s): [lsort [dict keys $declared]]"
} else {
    ok "Known Bugs table is empty (no live blockers declared)"
}

# ── the prose ────────────────────────────────────────────────────────────────

proc find_md {dir} {
    set out {}
    foreach e [glob -nocomplain -directory $dir *] {
        if {[file isdirectory $e]} {
            if {[file tail $e] in {.git node_modules build}} continue
            foreach p [find_md $e] { lappend out $p }
        } elseif {[file extension $e] eq ".md"} {
            lappend out [file normalize $e]
        }
    }
    return $out
}
set mds [lsort -unique [find_md .]]

set referenced [dict create]
set unmarked 0
set dangling 0
set TABLE [file normalize CURRENTLY_SUPPORTED.md]
foreach p $mds {
    set fh [open $p r]; set body [read $fh]; close $fh
    set rel [string range $p [expr {[string length [file normalize .]] + 1}] end]
    set n 0
    # A row in the Known Bugs table declares its id; it does not *reference*
    # one, or every row would satisfy its own reachability check and the gate
    # would prove nothing. So the table's own lines are skipped here.
    set in_table 0
    foreach line [split $body "\n"] {
        incr n
        if {$p eq $TABLE} {
            if {[regexp {^##\s+Known Bugs} $line]} { set in_table 1; continue }
            if {$in_table && [regexp {^##\s} $line]} { set in_table 0 }
            if {$in_table} continue
        }
        set ids [markers $line]

        # Any marker anywhere counts as a reference: the place a bug bites is
        # usually the API doc for the thing that has it, and that sentence
        # does not have to be phrased as a complaint to be the right place to
        # point a reader at.
        foreach id $ids {
            if {$id eq "n/a"} continue
            if {![dict exists $declared $id]} {
                bad "$rel:$n references `known-bug: $id`, which has no row in the Known Bugs table"
                incr dangling
                continue
            }
            dict set referenced $id 1
        }

        set low [string tolower $line]
        set hit ""
        foreach b $::BLOCKERS {
            if {[string first $b $low] >= 0} { set hit $b; break }
        }
        if {$hit eq ""} continue
        if {[llength $ids] == 0} {
            bad "$rel:$n states a blocker (\"$hit\") with no `known-bug:` marker"
            incr unmarked
        }
    }
}

if {$unmarked == 0} { ok "every blocker claim in the docs names a known-bug id (or n/a)" }
if {$dangling == 0} { ok "every known-bug id referenced in the docs has a table row" }

# ── a row nobody references ──────────────────────────────────────────────────

set orphans {}
dict for {id -} $declared {
    if {![dict exists $referenced $id]} { lappend orphans $id }
}
if {[llength $orphans] == 0} {
    ok "every Known Bugs row is reachable from the docs that hit it"
} else {
    foreach id $orphans {
        bad "Known Bugs row `$id` is referenced by no doc -- say where it bites, or drop the row"
    }
}

puts ""
puts "PASS=$pass  FAIL=$fail"
exit [expr {$fail > 0 ? 1 : 0}]
