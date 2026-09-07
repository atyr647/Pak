#!/usr/bin/env tclsh
# Compile the C backend's output, instead of only diffing it against a snapshot.
#
#   tclsh tcl/tools/c_compile_test.tcl            # gate
#   tclsh tcl/tools/c_compile_test.tcl --list     # print per-file error counts
#   tclsh tcl/tools/c_compile_test.tcl --regen    # rewrite the known-broken list
#
# Why this exists: every other check on the libdragon path compares generated C
# to checked-in text. Text that matches its snapshot can still be text no
# compiler accepts, and for half the canonical corpus it is. This runs cc over
# the real output so a syntax or scoping bug fails here rather than at a user's
# `make`.
#
# libdragon is not installed in CI, so the headers the codegen includes are
# stubbed. The stubs are not hand-written: every C symbol is declared from
# MODULE_API, the same table the checker and STDLIB index derive from, so the
# HAL contract and this gate cannot drift apart. Only the two `pak_str_*` /
# `pak_arena_*` families are skipped -- the codegen emits its own definitions
# for those in the prelude.
#
# tests/c_compile_known_broken.txt lists the examples whose C does NOT compile
# today. The gate fails in BOTH directions: a file off the list that stops
# compiling is a regression, and a file on the list that starts compiling must
# be removed from it. The list is debt, and it can only shrink.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
source [file join $HERE .. module_api.tcl]
source [file join $HERE gate_corpus.tcl]
cd $REPO

set KNOWN [file join $REPO tests c_compile_known_broken.txt]
set CC [expr {[info exists ::env(CC)] ? $::env(CC) : "cc"}]

proc have_cc {} {
    global CC
    expr {![catch {exec sh -c "command -v $CC"}]}
}

# ── stub tree ───────────────────────────────────────────────────────────────

proc hal_stub_header {} {
    set out {}
    lappend out "#pragma once"
    lappend out "#include <stdint.h>"
    lappend out "#include <stdbool.h>"
    lappend out "#include <stddef.h>"
    lappend out "/* Declared from MODULE_API -- do not hand-edit. */"
    lappend out ""
    lappend out "/* The few libdragon *types* the codegen names in emitted C."
    lappend out " * Symbols come from MODULE_API above; these do not appear there"
    lappend out " * because they are types, not functions. Keep this list minimal:"
    lappend out " * it exists so a missing libdragon header is not mistaken for a"
    lappend out " * codegen bug, not to reimplement libdragon. */"
    lappend out "typedef struct { int _pak_opaque; } sprite_t;"
    lappend out "typedef struct { bool a, b, z, start, l, r, up, down, left, right;"
    lappend out "                 bool c_up, c_down, c_left, c_right; } pak_joypad_buttons_t;"
    lappend out "typedef struct { pak_joypad_buttons_t held, pressed, released;"
    lappend out "                 int stick_x, stick_y; } pak_joypad_status_t;"
    lappend out "/* The standalone HAL's spelling, which is what MODULE_API names."
    lappend out " * Both exist because the two backends genuinely differ here. */"
    lappend out "typedef pak_joypad_buttons_t joypad_buttons_t;"
    lappend out "typedef pak_joypad_status_t  joypad_status_t;"
    lappend out "/* The audio and Tiny3D handle types. Opaque here for the same"
    lappend out " * reason sprite_t is: a program names them to declare a static,"
    lappend out " * and the question this gate asks is whether the generated C"
    lappend out " * parses and scopes, not what is inside them. Their real layouts"
    lappend out " * and signatures are libdragon_api_test.tcl's job. */"
    lappend out "typedef struct { int _pak_opaque; } wav64_t;"
    lappend out "typedef struct { int _pak_opaque; } xm64player_t;"
    lappend out "typedef union { struct { float x, y, z; }; float v\[3\]; } T3DVec3;"
    lappend out "typedef union { struct { float x, y, z, w; }; float v\[4\]; } T3DVec4;"
    lappend out "typedef struct { float m\[4\]\[4\]; } T3DMat4;"
    lappend out "typedef struct { int _pak_opaque; } T3DMat4FP;"
    lappend out "typedef struct { int _pak_opaque; } T3DViewport;"
    lappend out "typedef struct { int _pak_opaque; } T3DModel;"
    lappend out "typedef struct { int _pak_opaque; } T3DSkeleton;"
    lappend out "typedef struct { int _pak_opaque; } T3DAnim;"
    lappend out "typedef struct { int _pak_opaque; } rspq_block_t;"
    lappend out "typedef struct { int _pak_opaque; } surface_t;"
    lappend out ""
    lappend out "/* The runtime/pak_libdragon.h shims. They are not in MODULE_API --"
    lappend out " * MODULE_API names the symbol the STANDALONE HAL defines -- so the"
    lappend out " * C backend's adapter names are declared here. The real"
    lappend out " * signatures are checked by tcl/tools/libdragon_api_test.tcl"
    lappend out " * against libdragon's own headers; these only have to let the"
    lappend out " * generated C parse. */"
    lappend out "void pak_display_init(int, int, int, int, int);"
    lappend out "pak_joypad_status_t pak_joypad_get_status(int);"
    lappend out "short *pak_audio_get_buffer(void);"
    lappend out "void pak_rdpq_set_fill_color(uint32_t);"
    lappend out "void pak_rdpq_set_mode_fill(uint32_t);"
    lappend out ""
    lappend out "/* DragonFS. `main` mounts it when the file declares an asset,"
    lappend out " * so the generated C names these two whether or not the program"
    lappend out " * calls anything from dragonfs.h itself. Neither is in"
    lappend out " * MODULE_API: they are emitted by the entry-block prologue"
    lappend out " * rather than by a Pak call. */"
    lappend out "#define DFS_DEFAULT_LOCATION 0"
    lappend out "int dfs_init(uint32_t);"
    # The generic declaration below is `long sym();`, which is enough for a
    # call but not for `T3DViewport vp = t3d_viewport_create();`. The handful
    # of API entries that return a struct BY VALUE get a real return type here
    # so the stub is self-consistent; everything about their arguments is
    # still libdragon_api_test.tcl's business, against the real headers.
    set ret_override [dict create \
        t3d_viewport_create T3DViewport \
        t3d_skeleton_create T3DSkeleton \
        t3d_anim_create     T3DAnim \
        t3d_model_load      {T3DModel *} \
    ]
    dict for {sym rt} $ret_override { lappend out "$rt ${sym}();" }

    set seen [dict create]
    foreach key [pak::module_api_keys] {
        lassign $key mod fn
        set sym [pak::module_api_symbol $mod $fn]
        if {[dict exists $seen $sym]} continue
        if {[dict exists $ret_override $sym]} continue
        # The codegen defines these itself in the generated prelude.
        if {[string match "pak_str_*" $sym] || [string match "pak_arena_*" $sym]} continue
        dict set seen $sym 1
        if {$sym eq "joypad_get_status"} {
            lappend out "joypad_status_t ${sym}();"
            continue
        }
        if {$sym eq "sprite_load"} {
            lappend out "sprite_t *${sym}();"
            continue
        }
        lappend out "long ${sym}();"
    }
    return [join $out "\n"]
}

# Every `#include <...>` the generated C asks for, so a newly-included header
# stubs itself instead of failing the gate for a reason that is not the code.
proc included_headers {csrc} {
    set hs {}
    foreach line [split $csrc "\n"] {
        if {[regexp {^\s*#include\s*[<"]([^>"]+)[>"]} $line -> h]} {
            # Real C library headers must come from the system, not a stub.
            if {$h in {stdint.h stdbool.h stddef.h stdlib.h string.h math.h stdio.h}} continue
            lappend hs $h
        }
    }
    return [lsort -unique $hs]
}

# Symbols the generated C declares or defines itself. Stubbing those too is how
# a gate invents "conflicting types" errors that say nothing about the codegen.
proc self_declared {csrc} {
    set syms {}
    foreach line [split $csrc "\n"] {
        if {[regexp {([A-Za-z_][A-Za-z0-9_]*)\s*\(} $line -> sym]} {
            if {[regexp {^\s*(extern|static)?\s*[A-Za-z_]} $line] \
                && [regexp {[);]\s*$|\{\s*$} $line]} {
                lappend syms $sym
            }
        }
    }
    return [lsort -unique $syms]
}

# `extern const RDPQ_COMBINER_FLAT: u32` is Pak declaring that a name exists in
# the C headers -- usually as a macro, which is why the codegen emits it as a
# comment rather than a declaration it would have to invent a definition for.
# The gate honours that declaration the same way it honours MODULE_API: the
# source says the name exists, so the stub provides one. Without this an
# accurate passthrough reads as a codegen bug.
proc extern_consts {csrc} {
    set out {}
    foreach line [split $csrc "\n"] {
        if {[regexp {/\* extern const ([A-Za-z_][A-Za-z0-9_ *]*?) ([A-Za-z_][A-Za-z0-9_]*);} $line -> ctype name]} {
            lappend out [list [string trim $ctype] $name]
        }
    }
    return $out
}

proc write_stubs {dir csrc} {
    file mkdir $dir
    set skip [self_declared $csrc]
    set out {}
    foreach line [split [hal_stub_header] "\n"] {
        if {[regexp {^long ([A-Za-z0-9_]+)\(\);$} $line -> sym] && $sym in $skip} continue
        lappend out $line
    }
    foreach ec [extern_consts $csrc] {
        lassign $ec ctype name
        lappend out "static const $ctype $name = 0;"
    }
    set fh [open [file join $dir hal_stubs.h] w]
    puts $fh [join $out "\n"]
    close $fh
    foreach h [included_headers $csrc] {
        set path [file join $dir $h]
        file mkdir [file dirname $path]
        set fh [open $path w]
        puts $fh "#include \"hal_stubs.h\""
        close $fh
    }
}

# ── per-example compile ─────────────────────────────────────────────────────

proc explain_c {pk} {
    global REPO
    set cli [file join $REPO tcl cli.tcl]
    if {[catch {exec tclsh $cli explain $pk} out]} { return "" }
    return $out
}

# Returns {errcount firstlines}. The stub dir is rebuilt per file so a header
# one example includes cannot mask a missing include in another.
proc compile_one {pk workdir} {
    # $pk is repo-relative: two programs both called main.pk64 must not share
    # a scratch directory.
    global CC
    set csrc [explain_c $pk]
    if {$csrc eq ""} { return [list 1 "pak explain produced no output"] }
    set dir [file join $workdir [string map {/ _} [file rootname $pk]]]
    file delete -force $dir
    write_stubs $dir $csrc
    set cfile [file join $dir gen.c]
    set fh [open $cfile w]; puts $fh $csrc; close $fh

    set diag ""
    catch {exec $CC -fsyntax-only -std=gnu99 -I$dir $cfile 2>@1} diag
    set n 0
    set first {}
    foreach line [split $diag "\n"] {
        if {[string match "*error:*" $line]} {
            incr n
            if {[llength $first] < 3} { lappend first [string trim $line] }
        }
    }
    return [list $n [join $first "\n      "]]
}

# ── known-broken list ───────────────────────────────────────────────────────

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
    puts $fh "# Canonical examples whose generated C does NOT compile."
    puts $fh "#"
    puts $fh "# Maintained by tcl/tools/c_compile_test.tcl. This is debt, not"
    puts $fh "# configuration: fix a backend bug, drop the name, and the gate holds"
    puts $fh "# the new floor. Adding a name is how a regression gets waved through,"
    puts $fh "# so add one only with the bug it records written down."
    puts $fh ""
    foreach n [lsort $names] { puts $fh $n }
    close $fh
}

# ── main ────────────────────────────────────────────────────────────────────

set mode gate
if {"--list" in $argv} { set mode list }
if {"--regen" in $argv} { set mode regen }

if {![have_cc]} {
    puts "c compile gate: SKIP (no $CC on PATH)"
    exit 0
}

set workdir [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] pak_c_compile]
file delete -force $workdir
file mkdir $workdir

set examples [pak::gate_corpus $REPO]
set broken {}
set clean {}
set detail [dict create]
foreach name $examples {
    lassign [compile_one $name $workdir] n first
    if {$n > 0} {
        lappend broken $name
        dict set detail $name [list $n $first]
    } else {
        lappend clean $name
    }
}

if {$mode eq "list"} {
    foreach name $broken {
        lassign [dict get $detail $name] n first
        puts [format "%-24s %3d errors" $name $n]
        puts "      $first"
    }
    puts ""
    puts "compiles: [llength $clean]/[llength $examples]"
    exit 0
}

if {$mode eq "regen"} {
    write_known $broken
    puts "wrote [llength $broken] known-broken names to [file tail $KNOWN]"
    exit 0
}

set known [read_known]
set regressed {}   ;# broken but not on the list
set fixed {}       ;# on the list but now compiles
foreach name $broken   { if {$name ni $known}  { lappend regressed $name } }
foreach name $known    { if {$name ni $broken} { lappend fixed $name } }

puts "c compile gate: [llength $clean]/[llength $examples] programs compile"
puts "                [llength $known] known-broken, [llength $regressed] regressed, [llength $fixed] newly fixed"

set rc 0
if {[llength $regressed]} {
    puts ""
    puts "REGRESSION -- generated C no longer compiles:"
    foreach name $regressed {
        lassign [dict get $detail $name] n first
        puts "  $name ($n errors)"
        puts "      $first"
    }
    set rc 1
}
if {[llength $fixed]} {
    puts ""
    puts "FIXED -- these now compile; drop them from tests/c_compile_known_broken.txt:"
    foreach name $fixed { puts "  $name" }
    puts "  (tclsh tcl/tools/c_compile_test.tcl --regen)"
    set rc 1
}
if {$rc == 0} { puts "" ; puts "no regressions." }
exit $rc
