#!/usr/bin/env tclsh
# tcl/tools/libdragon_link_test.tcl — the generated C cross-compiles for MIPS
# and links into a real ROM.
#
#   tclsh tcl/tools/libdragon_link_test.tcl          # gate
#   tclsh tcl/tools/libdragon_link_test.tcl --list   # per-file errors
#   tclsh tcl/tools/libdragon_link_test.tcl --regen  # rewrite the debt list
#
# tcl/tools/libdragon_api_test.tcl compiles the same C against libdragon's real
# headers, which closes the signature-mismatch class: a missing header, a
# renamed function, the wrong arity, the wrong types. It runs the HOST
# compiler, so there are two things it structurally cannot see:
#
#   * anything the TARGET decides -- a 32-bit long where the host's is 64,
#     struct layout, alignment, endianness. Compiling for mips64-elf does.
#   * whether the symbols the code calls actually EXIST at link time. Only
#     linking does.
#
# It also compiles with libdragon's own N64_CFLAGS, read out of n64.mk rather
# than copied here, which means -Wall -Werror: a warning in Pak's generated C
# fails a real user's build, so it fails here.
#
# Needs a toolchain (tools/build_n64_toolchain.sh) and a built libdragon at
# N64_INST. Skips cleanly without them, the way the pixel gate does without
# angrylion -- a 40-minute toolchain build is not something to fail CI over
# when it is absent.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO

set KNOWN [file join $REPO tests libdragon_link_known_broken.txt]
set N64_INST [expr {[info exists ::env(N64_INST)] ? $::env(N64_INST) : "/opt/pak-n64"}]
set CACHE [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]

set MODE gate
foreach a $argv {
    switch -- $a { --list {set MODE list} --regen {set MODE regen} }
}

set CC [file join $N64_INST bin mips64-elf-gcc]
set LIBDRAGON [file join $N64_INST mips64-elf lib libdragon.a]
set N64MK [file join $N64_INST include n64.mk]

if {![file executable $CC]} {
    puts "libdragon link: SKIP (no mips64-elf-gcc at $N64_INST -- run tools/build_n64_toolchain.sh)"
    exit 0
}
if {![file exists $LIBDRAGON] || ![file exists $N64MK]} {
    puts "libdragon link: SKIP (libdragon not installed at $N64_INST -- see tools/build_libdragon.sh)"
    exit 0
}

# libdragon's own compile flags, asked of n64.mk rather than duplicated here,
# so this keeps matching what a user's build does as libdragon changes.
proc n64_flags {var} {
    global N64_INST CACHE N64MK
    set w [file join $CACHE pak-n64flags]; file mkdir $w
    set f [open [file join $w Makefile] w]
    puts $f "N64_INST := $N64_INST"
    puts $f "include $N64MK"
    puts $f "print:\n\t@echo \$($var)"
    close $f
    if {[catch {exec make -s -C $w print} out]} { return "" }
    return [string trim $out]
}
set CFLAGS [n64_flags N64_CFLAGS]
if {$CFLAGS eq ""} { puts "libdragon link: SKIP (cannot read N64_CFLAGS from n64.mk)"; exit 0 }

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

set WORK [file join $CACHE pak-link-test]
file mkdir $WORK

set results [dict create]
foreach src [lsort [glob -nocomplain [file join $REPO examples canonical *.pk64]]] {
    set name [file rootname [file tail $src]]
    set cfile [file join $WORK "$name.c"]
    if {[catch {exec [info nameofexecutable] [file join $REPO tcl cli.tcl] explain $src} c]} {
        dict set results $name [list 1 "pak explain failed"]
        continue
    }
    set fh [open $cfile w]; puts $fh $c; close $fh
    set rc 0; set err ""
    if {[catch {
        exec $CC {*}$CFLAGS -I[file join $REPO runtime] \
            -c $cfile -o [file join $WORK "$name.o"] 2>@1
    } err]} { set rc 1 }
    dict set results $name [list $rc $err]
}

proc n_errors {t} {
    set n 0
    foreach l [split $t "\n"] { if {[string match "*error:*" $l]} { incr n } }
    return $n
}

if {$MODE eq "list"} {
    foreach n [lsort [dict keys $results]] {
        lassign [dict get $results $n] rc err
        if {$rc} { puts [format "%-24s %d error(s)" $n [n_errors $err]] }
    }
    exit 0
}

set broken {}
foreach n [lsort [dict keys $results]] {
    lassign [dict get $results $n] rc err
    if {$rc} { lappend broken $n }
}

if {$MODE eq "regen"} {
    set fh [open $KNOWN w]
    puts $fh "# Canonical examples whose generated C does NOT cross-compile for"
    puts $fh "# mips64-elf with libdragon's own N64_CFLAGS (which include -Werror)."
    puts $fh "#"
    puts $fh "# Maintained by tcl/tools/libdragon_link_test.tcl. Debt, not"
    puts $fh "# configuration: fix the backend, drop the name."
    puts $fh ""
    foreach n $broken { puts $fh $n }
    close $fh
    puts "libdragon link: wrote [llength $broken] name(s)"
    exit 0
}

set known [known_broken]
set regressed {}; set fixed {}
foreach n $broken { if {$n ni $known} { lappend regressed $n } }
foreach n $known { if {$n ni $broken} { lappend fixed $n } }

puts "libdragon link gate: [expr {[dict size $results] - [llength $broken]}]/[dict size $results]\
 canonical examples cross-compile for mips64-elf"
puts "                     [llength $known] known-broken, [llength $regressed] regressed, [llength $fixed] newly fixed"

if {[llength $regressed] > 0} {
    puts ""
    puts "REGRESSED:"
    foreach n $regressed {
        lassign [dict get $results $n] rc err
        puts "  $n"
        set shown 0
        foreach l [split $err "\n"] {
            if {[string match "*error:*" $l] && $shown < 3} { puts "      $l"; incr shown }
        }
    }
}
if {[llength $fixed] > 0} {
    puts ""
    puts "NEWLY FIXED -- remove from [file tail $KNOWN]:"
    foreach n $fixed { puts "  $n" }
}
if {[llength $regressed] > 0 || [llength $fixed] > 0} { exit 1 }

# ── end to end: a scaffolded project must reach a bootable ROM ──────────────
#
# Cross-compiling every example proves the C is good. It does not prove the
# BUILD is: the generated Makefile reimplemented n64.mk's link rule and passed
# raw linker options (--gc-sections, --wrap) straight to the compiler driver,
# so no generated project had ever linked. Only running `pak init && pak build
# && make` finds that.
puts ""
puts "== pak init -> pak build -> make =="
set proj [file join $CACHE pak-romtest]
file delete -force $proj
file mkdir $proj
set ok 1
set pak "[info nameofexecutable] [file join $REPO tcl cli.tcl]"
set demo [file join $proj demo]
# Each step runs with the project as its working directory, which is how a
# user runs them; `pak build` looks for pak.toml there.
foreach step [list \
        [list "pak init"  "cd [file nativename $proj] && $pak init demo"] \
        [list "pak build" "cd [file nativename $demo] && $pak build"] \
        [list "make"      "cd [file nativename $demo] && make"]] {
    lassign $step label cmd
    if {!$ok} break
    if {[catch {exec sh -c "$cmd 2>&1"} out]} {
        puts "FAIL  $label:"
        foreach l [lrange [split $out "\n"] end-8 end] { puts "      $l" }
        set ok 0
    }
}
set rom [file join $demo demo.z64]
if {$ok && ![file exists $rom]} { puts "FAIL  no demo.z64 produced"; set ok 0 }
if {$ok} {
    set fh [open $rom rb]; fconfigure $fh -translation binary
    set d [read $fh]; close $fh
    binary scan [string range $d 0 3] H8 magic
    set ipl3 0
    binary scan [string range $d 64 4095] cu* bytes
    foreach b $bytes { if {$b != 0} { incr ipl3 } }
    if {$magic ne "80371240"} { puts "FAIL  bad .z64 magic: $magic"; set ok 0 }
    if {$ipl3 == 0} { puts "FAIL  IPL3 region is empty -- the ROM will not boot"; set ok 0 }
    if {$ok} {
        puts [format "ok    demo.z64: %d bytes, magic %s, %d IPL3 bytes" \
            [string length $d] $magic $ipl3]
    }
}
if {!$ok} { exit 1 }
puts ""
puts "no regressions."
