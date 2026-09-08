#!/usr/bin/env tclsh
# tcl/tools/dlist_test.tcl — the RDP disassembler agrees with the encoder.
#
# tcl/rdpdis.tcl is the inverse of the command builders in
# runtime/standalone/runtime.pk64, and `pak dlist` is only worth anything if
# that inverse is exact. This runs the same driver tcl/tools/rdp_test.tcl uses
# — which exercises every opcode the runtime can emit — and checks the
# disassembly against what the driver asked for.
#
# Two classes of bug are caught here:
#
#   1. A wrong per-opcode length. The stream is self-delimiting only if every
#      length is right; one wrong count desynchronizes everything after it, so
#      the opcode sequence and the "every word consumed" check below are a
#      strong test of the whole table.
#   2. A wrong field decode. The spot checks name the values the driver passed
#      and demand the disassembler recover them.
#
# It does NOT check that the command words themselves are correct — that is
# tcl/tools/rdp_test.tcl (encodings) and tcl/tools/pixel_test.tcl (pixels).

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl mips_sim.tcl]
source [file join $REPO tcl rdpdis.tcl]

set RUNTIME runtime/standalone/runtime.pk64
set DRIVER  tcl/tests/rdp/commands.pk64
set DL_BASE [expr {0xA0297000}]

set ::pass 0
set ::fail 0

proc ok {name got want} {
    if {$got eq $want} {
        incr ::pass; puts "ok    $name"
    } else {
        incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want"
    }
}
proc ok_true {name cond {detail ""}} {
    if {$cond} { incr ::pass; puts "ok    $name$detail" } \
    else { incr ::fail; puts "FAIL  $name$detail" }
}

# One line whose text contains `needle`, or "" — used so a spot check names the
# command it is about rather than a line number that moves.
proc line_with {lines needle} {
    foreach l $lines {
        if {[string first $needle $l] >= 0} { return $l }
    }
    return ""
}

# ── build the display list the driver produces ───────────────────────────────

set fh [open $RUNTIME r]; set rt [read $fh]; close $fh
set fh [open $DRIVER r];  set dr [read $fh]; close $fh
set combined [file join $REPO .dlist_combined.pk64]
set fh [open $combined w]; puts -nonewline $fh "$rt\n$dr"; close $fh
set asm [exec [info nameofexecutable] tcl/cli.tcl explain --backend mips $combined]
file delete $combined

set preset [dict create 0xA410000C 0 0xA4400010 {0x1E0 0x000}]
set r [pak::mips_sim_run $asm main 20000000 $preset]
set mem [dict get $r mem_w]

set words {}
for {set i 0} {$i < 4096} {incr i} {
    set a [expr {$DL_BASE + $i * 4}]
    if {![dict exists $mem $a]} break
    lappend words [dict get $mem $a]
}

set lines [pak::rdpdis::disasm $words]

puts "== the stream decodes as a whole =="
ok_true "the driver built a display list" [expr {[llength $words] > 0}] \
    " ([llength $words] words)"

# A command line carries a mnemonic in the fourth column; continuation lines do
# not. Everything the disassembler recognised, in order.
set ops {}
foreach l $lines {
    if {[regexp {^\+[0-9A-F]{4}  [0-9A-F]{8} [0-9A-F]{8}  ([A-Z_0-9]+)} $l -> op]} {
        lappend ops $op
    }
}

ok_true "no opcode came back UNKNOWN" [expr {[lsearch -glob $ops UNKNOWN_*] < 0}] \
    " ([llength $ops] commands)"
ok_true "no command ran past the end of the list" \
    [expr {[lsearch -glob $lines "*<truncated*"] < 0}]

# The strongest check on the length table: walking the stream by the lengths
# rdpdis believes must land exactly on the end. One wrong length desynchronizes
# from that point on and this stops matching.
set i 0
while {$i < [llength $words]} {
    set op [expr {([lindex $words $i] >> 24) & 0x3F}]
    incr i [pak::rdpdis::len_of $op]
}
ok "walking by the length table consumes every word" $i [llength $words]

# The driver calls each builder once, in this order. It doubles as the
# disassembler's coverage list: every opcode the runtime can emit is here.
set EXPECTED_OPS {
    SET_COLOR_IMAGE SET_Z_IMAGE SET_SCISSOR
    SYNC_PIPE SET_OTHER_MODES SET_FILL_COLOR FILL_RECTANGLE FILL_RECTANGLE
    SET_SCISSOR
    SYNC_PIPE SET_OTHER_MODES
    SET_TEXTURE_IMAGE SET_TILE LOAD_TILE SET_TILE_SIZE LOAD_BLOCK LOAD_TLUT
    TEXTURE_RECTANGLE TEXTURE_RECTANGLE_FLIP TEXTURE_RECTANGLE
    SYNC_PIPE SET_OTHER_MODES SET_COMBINE
    SET_PRIM_COLOR SET_BLEND_COLOR SET_FOG_COLOR SET_ENV_COLOR
    SET_PRIM_DEPTH SET_KEY_R SET_KEY_GB SET_CONVERT
    TRIANGLE TRIANGLE_Z SET_TILE TRIANGLE_TEX
    SET_COLOR_IMAGE SYNC_PIPE SET_OTHER_MODES SET_FILL_COLOR FILL_RECTANGLE
    SET_COLOR_IMAGE SYNC_PIPE SET_OTHER_MODES SET_COMBINE
    TRIANGLE_SHADE TRIANGLE_SHADE_Z TRIANGLE_SHADE_TEX TRIANGLE_SHADE_TEX_Z
    TRIANGLE_TEX_Z
    SYNC_PIPE SYNC_TILE SYNC_LOAD SYNC_FULL
}
ok "the opcode sequence is the one the driver wrote" [join $ops " "] [join $EXPECTED_OPS " "]

# Every triangle opcode, so a length or label regression on any of the eight
# shows up as a missing command rather than as plausible-looking hex.
foreach t {TRIANGLE TRIANGLE_Z TRIANGLE_TEX TRIANGLE_TEX_Z
           TRIANGLE_SHADE TRIANGLE_SHADE_Z TRIANGLE_SHADE_TEX TRIANGLE_SHADE_TEX_Z} {
    ok_true "$t decoded" [expr {[lsearch -exact $ops $t] >= 0}]
}

puts ""
puts "== fields come back as the driver passed them =="

# rdpq.attach: 320x240 RGBA 16bpp at FB0, Z after the third framebuffer.
ok_true "SET_COLOR_IMAGE names the surface" \
    [string match "*RGBA 16bpp width=320 addr=0x200000*" [line_with $lines SET_COLOR_IMAGE]]
ok_true "SET_Z_IMAGE names the Z buffer" \
    [string match "*addr=0x271000*" [line_with $lines SET_Z_IMAGE]]
ok_true "SET_SCISSOR is the full screen" \
    [string match "*(0.00,0.00)-(320.00,240.00)*" [line_with $lines SET_SCISSOR]]

# fill_rectangle(0,0,320,240) is stored as the inclusive 0..319 / 0..239.
ok_true "FILL_RECTANGLE shows the inclusive corners" \
    [string match "*(0.00,0.00)-(319.00,239.00) inclusive*" [line_with $lines FILL_RECTANGLE]]

# set_mode_copy: COPY cycle with alpha_compare_en. set_mode_standard: 1CYCLE
# with both bi_lerp bits, which is the fix pixel_test.tcl guards.
ok_true "SET_OTHER_MODES names the COPY cycle" \
    [string match "*cycle=COPY*alpha_compare_en*" [line_with $lines "2F200000"]]
ok_true "SET_OTHER_MODES names both bi_lerp bits" \
    [string match "*cycle=1CYCLE bi_lerp0 bi_lerp1*" [line_with $lines "2F000C00"]]
ok_true "SET_OTHER_MODES names the Z bits when they are on" \
    [string match "*z_update_en z_compare_en*" [line_with $lines "00506070"]]

# set_tile_mask(0, 0, 2, 8, 0, 0, 2, 2, 5, 5): clamp both axes, mask 5 = 32.
ok_true "SET_TILE recovers clamp/clamp and mask 5" \
    [string match "*S:clamp mask=5 T:clamp mask=5*" [line_with $lines "00094250"]]
# load_tile(0, 0, 0, 32, 32) covers a 32x32 page.
ok_true "LOAD_TILE recovers the 32x32 page" \
    [string match "*(32x32 texels)*" [line_with $lines LOAD_TILE]]
# load_block(0, 0, 0, 512, 256)
ok_true "LOAD_BLOCK recovers 512 texels" \
    [string match "*texels=512 dxt=256*" [line_with $lines LOAD_BLOCK]]

# texture_rectangle in COPY steps four texels per cycle; the scaled call asks
# for half a texel per pixel. Both are the values the encoder packs.
ok_true "TEXTURE_RECTANGLE in COPY steps dsdx=4" \
    [string match "*dsdx=4.000 dtdy=1.000*" [line_with $lines "2420C144"]]
ok_true "the scaled rectangle steps dsdx=0.5" \
    [string match "*dsdx=0.500 dtdy=1.000*" [line_with $lines "2428C144"]]

# set_prim_depth(0x7FFF, 0), set_key_r(16,128,4), set_convert(NTSC coefficients)
ok_true "SET_PRIM_DEPTH recovers z and dz" \
    [string match "*z=32767 dz=0*" [line_with $lines SET_PRIM_DEPTH]]
ok_true "SET_KEY_R recovers width/center/scale" \
    [string match "*width=16 center=128 scale=4*" [line_with $lines SET_KEY_R]]
ok_true "SET_CONVERT recovers the six signed coefficients" \
    [string match "*175, -43, -89, 222, 114, 42*" [line_with $lines SET_CONVERT]]

# triangle(10,10, 90,20, 100,90) sorted by Y is (10,10) (90,20) (100,90):
# YH=10, YM=20, YL=90, and the major edge runs to the left.
set tri [line_with $lines "08800168"]
ok_true "TRIANGLE recovers YL/YM/YH" \
    [string match "*left YL=90.00 YM=20.00 YH=10.00*" $tri]

# The three edge pairs are s15.16. XM is x at the top vertex, and DxMDy is the
# slope of the short top edge: (90-10)/(20-10) = 9.
ok_true "the edge slopes decode as s15.16" \
    [string match "*XM / DxMDy   X=10.000  dX/dY=9.000*" [line_with $lines "00090000"]]

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
