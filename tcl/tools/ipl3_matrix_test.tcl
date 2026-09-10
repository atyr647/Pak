#!/usr/bin/env tclsh
# tcl/tools/ipl3_matrix_test.tcl — docs/ipl3-emulator-matrix.md is checkable.
#
# "It boots" is a claim about a pair: which bootcode, which machine. Pak's CI
# runs exactly one of those pairs (compat × ares), and that is also the most
# permissive machine about the thing that breaks elsewhere -- so a green
# ares_test.tcl has never meant "this ROM boots", only "this ROM boots ares".
#
# This gate does two jobs:
#
#   1. Parse the matrix out of the doc and assert it is well-formed: every row
#      names a bootcode this repo knows about, an expectation, and the file
#      that checks it -- and that file has to exist. A row whose checker was
#      deleted is a row nobody is testing.
#   2. Check the rows that need no emulator: the shipped bootcode is the size
#      the PIF expects and is what `pak link` actually embeds; the `none` row
#      really does produce a ROM with a zeroed boot region; the compat loader's
#      payload-size field is written where the loader reads it.
#
# Where mupen64plus is on PATH, its documented row is run for real: that row
# says the ROM does NOT boot, so the gate fails if it suddenly does -- because
# then the doc, the Known Bugs table and reality have come apart, which is the
# only interesting thing that can happen to a row like that.
#
#   tclsh tcl/tools/ipl3_matrix_test.tcl

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl n64rom.tcl]

set ::pass 0
set ::fail 0
proc ok_true {name cond {detail ""}} {
    if {$cond} { incr ::pass; puts "ok    $name$detail" } \
    else { incr ::fail; puts "FAIL  $name$detail" }
}

set DOC docs/ipl3-emulator-matrix.md
if {![file exists $DOC]} {
    puts "FAIL  $DOC is missing -- the matrix is the deliverable, not this gate"
    exit 1
}
set fh [open $DOC r]; set doc [read $fh]; close $fh

# ── 1. the table parses and every row is well-formed ────────────────────────

# Rows look like: | `id` | runner | expected | checked-by |
set rows {}
set in_matrix 0
foreach line [split $doc "\n"] {
    if {[regexp {^##\s+The matrix} $line]} { set in_matrix 1; continue }
    if {$in_matrix && [regexp {^##\s} $line]} { set in_matrix 0 }
    if {!$in_matrix} continue
    if {![string match "|*" [string trim $line]]} continue
    if {[regexp {^\|\s*-+} $line]} continue
    if {[regexp {^\|\s*IPL3\s*\|} $line]} continue
    set cells {}
    foreach c [split [string trim [string trim $line] "|"] "|"] {
        lappend cells [string trim $c]
    }
    if {[llength $cells] < 4} continue
    lappend rows $cells
}

ok_true "the matrix has rows" [expr {[llength $rows] >= 4}] " ([llength $rows])"

set KNOWN_IPL3 {compat 8m none custom}
foreach r $rows {
    lassign $r ipl3 runner expect checker
    regsub -all {`} $ipl3 "" id
    ok_true "row '$id x $runner' names a bootcode this repo knows" \
        [expr {$id in $KNOWN_IPL3}] ""
    ok_true "row '$id x $runner' states an expectation" \
        [expr {[string length $expect] > 0}] ""
    # Every path in backticks in the "checked by" cell has to exist.
    foreach {- path} [regexp -all -inline {`([a-zA-Z0-9_./-]+\.(?:tcl|sh))`} $checker] {
        ok_true "row '$id x $runner' checker $path exists" [file exists $path] ""
    }
}

# ── 2. the rows that need no emulator ───────────────────────────────────────

set ipl3 [pak::n64rom_default_ipl3]
ok_true "the shipped bootcode is present" [expr {$ipl3 ne ""}] ""
ok_true "the shipped bootcode fills the PIF's region exactly" \
    [expr {[string length $ipl3] == $::pak::ROM_IPL3_SIZE}] \
    " ([string length $ipl3] of $::pak::ROM_IPL3_SIZE bytes)"

# A payload the loader has to copy. Its contents do not matter here; its
# length does, because that is what goes in the header field.
set payload [string repeat "\xDE\xAD\xBE\xEF" 64]

set rom_compat [pak::n64rom $payload "PAK IPL3 MATRIX" $ipl3 [expr {4 * 1024 * 1024}]]
set rom_none   [pak::n64rom $payload "PAK IPL3 MATRIX" ""    [expr {4 * 1024 * 1024}]]

proc region {rom} { return [string range $rom 0x40 [expr {0x40 + $::pak::ROM_IPL3_SIZE - 1}]] }

ok_true "compat: the boot region carries the bootcode" \
    [expr {[region $rom_compat] eq $ipl3}] ""
ok_true "none: the boot region is 4032 zero bytes (this ROM does not boot)" \
    [expr {[region $rom_none] eq [string repeat "\x00" $::pak::ROM_IPL3_SIZE]}] ""

# The compat loader reads the payload size from 0x10, where a conventional ROM
# keeps CRC1. Get this wrong and it copies a flat 1 MiB instead -- which boots
# a small ROM anyway, so nothing downstream would notice.
binary scan [string range $rom_compat 16 19] Iu size_field
ok_true "compat: 0x10 carries the payload size the loader copies" \
    [expr {$size_field == [string length $payload]}] \
    " (0x10 = $size_field, payload = [string length $payload])"

binary scan [string range $rom_compat 8 11] Iu entry_field
ok_true "compat: 0x08 carries the link base the loader jumps to" \
    [expr {$entry_field == 0x80000400}] [format " (0x08 = 0x%08X)" $entry_field]

# ── 3. the mupen64plus row, if it can be run ────────────────────────────────

set MUPEN ""
foreach dir [split $::env(PATH) :] {
    set p [file join $dir mupen64plus]
    if {[file executable $p]} { set MUPEN $p; break }
}

# The `8m` bootcode, when it has been built. It exists to make the row above
# flip, so the assertion is the opposite one: this ROM must BOOT mupen64plus,
# which means not producing the RDRAM complaint the compat blob does.
proc mupen_run {mupen path} {
    set out ""
    catch {exec $mupen --nosaveoptions --noosd --emumode 0 --testshots 0 \
               --gfx dummy --audio dummy --input dummy \
               --rsp mupen64plus-rsp-hle $path 2>@1} out
    return $out
}

set ipl3_8m [pak::n64rom_named_ipl3 8m]
if {$ipl3_8m eq ""} {
    puts "note  ipl3_compat_8m.bin not built -- run tools/build_ipl3_8m.sh"
} else {
    ok_true "8m: the built bootcode fills the PIF's region exactly" \
        [expr {[string length $ipl3_8m] == $::pak::ROM_IPL3_SIZE}] \
        " ([string length $ipl3_8m] bytes)"
    # It must differ from compat -- if the build silently produced the stock
    # blob, every assertion below would be testing the wrong thing.
    ok_true "8m: it is not byte-identical to compat" \
        [expr {$ipl3_8m ne $ipl3}] ""
}

if {$MUPEN eq ""} {
    puts "note  mupen64plus not on PATH -- its rows stay documented, not run"
} else {
    set tmp /tmp/pak-ipl3-matrix
    file mkdir $tmp
    set path [file join $tmp compat.z64]
    set f [open $path wb]; puts -nonewline $f $rom_compat; close $f
    # Dummy plugins throughout: this row is about what the BOOTCODE does, and
    # a headless runner has no GL context -- without these mupen64plus fails on
    # "Could not load EGL library" and closes the ROM before IPL3 ever runs,
    # which would make the row report whatever the video stack did instead of
    # whatever the bootcode did.
    set out [mupen_run $MUPEN $path]
    # The documented expectation is a failure with this exact diagnosis. If it
    # ever starts booting, the Known Bugs row and this doc are both stale.
    set detected [string match "*IPL3 detected*RDRAM*" $out]
    ok_true "mupen64plus: the documented IPL3/RDRAM failure still reproduces" \
        $detected ""
    if {!$detected} {
        puts "      mupen64plus said:"
        puts [string trim $out]
        puts "      If this ROM now boots, update docs/ipl3-emulator-matrix.md and"
        puts "      drop `mupen64plus-ipl3` from CURRENTLY_SUPPORTED.md."
    }

    # The row the second bootcode exists to flip. Same payload, same emulator,
    # different 4032 bytes: this one must NOT produce the complaint. That is
    # the whole claim `8m` makes, so it is the one thing worth asserting about
    # it, and asserting it here means the claim cannot rot into a README line.
    if {$ipl3_8m ne ""} {
        set rom8 [pak::n64rom $payload "PAK IPL3 8M" $ipl3_8m [expr {4 * 1024 * 1024}]]
        set p8 [file join $tmp compat8m.z64]
        set f [open $p8 wb]; puts -nonewline $f $rom8; close $f
        set out8 [mupen_run $MUPEN $p8]
        set still [string match "*IPL3 detected*RDRAM*" $out8]
        # Reaching the CPU at all is a precondition: a run that died in the
        # video or capture stack proves nothing about the bootcode, and would
        # otherwise look like a pass because the complaint is absent.
        set ran [string match "*Starting R4300*" $out8]
        ok_true "8m: mupen64plus starts the CPU on this ROM" $ran ""
        ok_true "8m: and does not reject its RDRAM size" \
            [expr {$ran && !$still}] ""
        if {$ran && $still} {
            puts "      the cap did not change what mupen64plus sees:"
            foreach l [split $out8 "\n"] {
                if {[string match "*RDRAM*" $l]} { puts "        [string trim $l]" }
            }
        }
    }
}

puts ""
puts "PASS=$::pass  FAIL=$::fail"
exit [expr {$::fail > 0 ? 1 : 0}]
