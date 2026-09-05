#!/usr/bin/env tclsh
# tcl/tools/rdp_test.tcl — assert the standalone runtime emits correct RDP
# commands, by running its own generated MIPS code.
#
# There is no N64 and no emulator here, so the check is done the only way that
# proves anything: compile runtime/standalone/runtime.pk64 together with a
# driver, execute the result in tcl/mips_sim.tcl, and read the display list the
# runtime built out of simulated RDRAM. Every word is compared against the
# encoding in the RDP command reference.
#
# This runs the whole path — codegen, register allocation, the optimizer — so a
# miscompile shows up as a wrong command word, not as a plausible-looking
# instruction stream.
#
# It cannot tell you the command words are RIGHT. Every triangle word below
# once had bit 23 (lft) clear, which matched the encoder exactly and drew about
# one pixel on hardware. tcl/tools/pixel_test.tcl settles that question: it
# renders the list on angrylion and compares pixels against the source
# geometry. Do not "correct" a triangle word here without checking there.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl mips_sim.tcl]

set RUNTIME  runtime/standalone/runtime.pk64
set DRIVER   tcl/tests/rdp/commands.pk64
set DL_BASE  [expr {0xA0297000}]

set ::pass 0
set ::fail 0

# A register the program wrote, as hex; "<unwritten>" if it never was.
proc reg_hex {mem addr} {
    if {![dict exists $mem $addr]} { return "<unwritten>" }
    return [format %08X [dict get $mem $addr]]
}

proc ok {name got want} {
    if {$got eq $want} {
        incr ::pass; puts "ok    $name = $got"
    } else {
        incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want"
    }
}

# Build one source out of the runtime and the driver, lower it to MIPS, run it,
# and return the words the run left in memory.
proc run_driver {optimize} {
    global RUNTIME DRIVER
    set fh [open $RUNTIME r]; set rt [read $fh]; close $fh
    set fh [open $DRIVER r];  set dr [read $fh]; close $fh
    set combined [file join [file dirname [info script]] .. .. .rdp_combined.pk64]
    set fh [open $combined w]; puts -nonewline $fh "$rt\n$dr"; close $fh

    if {$optimize} {
        set asm [exec [info nameofexecutable] tcl/cli.tcl explain --backend mips $combined]
    } else {
        set asm [exec [info nameofexecutable] tcl/tools/mips_dump.tcl $combined]
    }
    file delete $combined
    # Model the two registers the runtime spins on: the DP reports idle, and
    # the VI reports a line past the active region, so vi_wait_vblank returns.
    set preset [dict create 0xA410000C 0 0xA4400010 {0x1E0 0x000}]
    set r [pak::mips_sim_run $asm main 20000000 $preset]
    return [dict get $r mem_w]
}

# The display list as a flat list of words, in the order the runtime wrote them.
proc dl_words {mem} {
    global DL_BASE
    set out {}
    for {set i 0} {$i < 512} {incr i} {
        set a [expr {$DL_BASE + $i * 4}]
        if {![dict exists $mem $a]} break
        lappend out [format %08X [dict get $mem $a]]
    }
    return $out
}

# ── expected command stream ──────────────────────────────────────────────────
# Derived by hand from the RDP command encodings; see the comments for the
# field breakdown of each. Unoptimized and optimized codegen must agree.
set EXPECTED {
    3F10013F 00200000
    3E000000 00271000
    2D000000 005003C0
    27000000 00000000
    2F300000 00000000
    37000000 F801F801
    364FC3BC 00000000
    360BC0FC 00040080
    2D020020 004E03A0
    27000000 00000000
    2F200000 00000001
    3D10001F 00300000
    35101000 00000000
    34000000 0007C07C
    32000000 0007C07C
    33000000 001FF100
    30000000 0003C000
    2420C144 001900C8
    00000000 10000400
    2520C144 001900C8
    00000000 10000400
    2428C144 001900C8
    00000000 02000400
    27000000 00000000
    2F000000 00506040
    3C887F10 88FCF279
    3A000000 112233FF
    39000000 445566FF
    38000000 778899AA
    3B000000 BBCCDDFF
    2E000000 7FFF0000
    2B000000 00108004
    2A010010 80048004
    2C15FD5D 3B78E42A
    08800168 00500028
    00640000 FFFF2493
    000A0000 00006000
    000A0000 00090000
    09800168 00500028
    00640000 FFFF2493
    000A0000 00006000
    000A0000 00090000
    00000000 00000000
    00640064 00000000
    35101000 00094250
    0A8000C0 00400040
    00300000 FFFF0000
    00100000 00000000
    00100000 00000000
    00000000 7FFF0000
    00200000 00000000
    00000000 00000000
    00000000 00000000
    00000020 00000000
    00000020 00000000
    00000000 00000000
    00000000 00000000
    3F10013F 00271000
    27000000 00000000
    2F300000 00000000
    37000000 FFFCFFFC
    364FC3BC 00000000
    3F10013F 00200000
    27000000 00000000
    2F000000 00506070
    3C887F10 88FCF279
    0C800168 00500028
    00640000 FFFF2493
    000A0000 00006000
    000A0000 00090000
    00FF0000 000000FF
    69BDF4DE A1640000
    00000000 00000000
    37A79BD3 2C860000
    F000E000 30000000
    C859E42C 537A0000
    00000001 00000000
    0B228591 6F4D0000
    0D800168 00500028
    00640000 FFFF2493
    000A0000 00006000
    000A0000 00090000
    00FF00FF 00FF00FF
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00640064 00000000
    0E8000C0 00400040
    00300000 FFFF0000
    00100000 00000000
    00100000 00000000
    00FF0000 000000FF
    0800F800 00000000
    00000000 00000000
    00000000 00000000
    08000000 F8000000
    08000000 F8000000
    00000000 00000000
    00000000 00000000
    00000000 7FFF0000
    00200000 00000000
    00000000 00000000
    00000000 00000000
    00000020 00000000
    00000020 00000000
    00000000 00000000
    00000000 00000000
    0F8000C0 00400040
    00300000 FFFF0000
    00100000 00000000
    00100000 00000000
    00FF00FF 00FF00FF
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 00000000
    00000000 7FFF0000
    00200000 00000000
    00000000 00000000
    00000000 00000000
    00000020 00000000
    00000020 00000000
    00000000 00000000
    00000000 00000000
    0000001F 00004000
    00FA00FA 00000000
    0B8000C0 00400040
    00300000 FFFF0000
    00100000 00000000
    00100000 00000000
    00000000 7FFF0000
    00200000 00000000
    00000000 00000000
    00000000 00000000
    00000020 00000000
    00000020 00000000
    00000000 00000000
    00000000 00000000
    0000001F 00004000
    00FA00FA 00000000
    27000000 00000000
    28000000 00000000
    26000000 00000000
    29000000 00000000
}

set NOTES {
    "SET_COLOR_IMAGE   RGBA/16bpp, width 320, fb at 0x00200000"
    "SET_Z_IMAGE       320x240 16-bit Z at 0x00271000"
    "SET_SCISSOR       (0,0)-(320,240) in 10.2"
    "SYNC_PIPE         before the mode change"
    "SET_OTHER_MODES   cycle_type = FILL (3)"
    "SET_FILL_COLOR    0xFF0000FF -> RGBA5551 0xF801, twice"
    "FILL_RECTANGLE    (0,0)-(320,240), inclusive corner 319/239"
    "FILL_RECTANGLE    (16,32)-(48,64)"
    "SET_SCISSOR       (8,8)-(312,232)"
    "SYNC_PIPE         before the mode change"
    "SET_OTHER_MODES   cycle_type = COPY (2), alpha_compare_en"
    "SET_TEXTURE_IMAGE RGBA/16bpp, width 32, at 0x00300000"
    "SET_TILE          tile 0, RGBA/16bpp, line 8, tmem 0"
    "LOAD_TILE         tile 0, (0,0)-(32,32)"
    "SET_TILE_SIZE     tile 0, (0,0)-(32,32)"
    "LOAD_BLOCK        0x33 tile 0, 512 texels, dxt 0x100"
    "LOAD_TLUT         0x30 tile 0, colours 0..15 (10.2 * 4)"
    "TEXTURE_RECTANGLE tile 0, (100,50)-(132,82)"
    "                  s/t = 0, dsdx = 4 texels/cycle, dtdy = 1"
    "TEXTURE_RECT_FLIP 0x25, same rect as TEXTURE_RECTANGLE"
    "                  s/t = 0, dsdx = 4 texels/cycle, dtdy = 1"
    "TEXTURE_RECTANGLE 0x24 scaled (100,50)-(164,82)"
    "                  s/t = 0, dsdx = 0.5 texel/pixel, dtdy = 1"
    "SYNC_PIPE         before the mode change"
    "SET_OTHER_MODES   cycle_type = 1CYCLE, alpha blending"
    "SET_COMBINE       texel passthrough"
    "SET_PRIM_COLOR    0x112233FF"
    "SET_BLEND_COLOR   0x445566FF"
    "SET_FOG_COLOR     0x778899AA"
    "SET_ENV_COLOR     0xBBCCDDFF"
    "SET_PRIM_DEPTH    z=0x7FFF, dz=0"
    "SET_KEY_R         0x2B width=16 center=128 scale=4"
    "SET_KEY_GB        0x2A width 16/16, center 128, scale 4"
    "SET_CONVERT       0x2C NTSC k0..k5 (175,-43,-89,222,114,42)"
    "TRIANGLE          sorted (10,10) (100,20) (40,90); YL/YM/YH"
    "                  XL / DxLDy   (lower minor edge)"
    "                  XH / DxHDy   (major edge)"
    "                  XM / DxMDy   (upper minor edge)"
    "TRIANGLE_Z        0x09 fill+Z, same edges as TRIANGLE"
    "                  XL / DxLDy"
    "                  XH / DxHDy"
    "                  XM / DxMDy"
    "                  Z / dZdx integer then fractional"
    "                  dZde / dZdy integer then fractional"
    "SET_TILE          clamp+mask (cms/cmt=2, mask 5/5)"
    "TRI_TEX           0x0A affine ST, tile 0, Y=16/16/48"
    "                  XL / DxLDy"
    "                  XH / DxHDy"
    "                  XM / DxMDy"
    "                  S/T/W integer halves (W=0x7FFF)"
    "                  dSdx / dTdx / dWdx integer"
    "                  S/T/W fractional halves"
    "                  dSdx / dTdx / dWdx fractional"
    "                  dSde / dTde integer"
    "                  dSdy / dTdy integer"
    "                  dSde / dTde fractional"
    "                  dSdy / dTdy fractional"
    "SET_COLOR_IMAGE   clear_z: point at Z buffer 0x00271000"
    "SYNC_PIPE         before FILL for Z clear"
    "SET_OTHER_MODES   cycle_type = FILL"
    "SET_FILL_COLOR    0xFFFC (max 16-bit Z), twice"
    "FILL_RECTANGLE    full screen into Z"
    "SET_COLOR_IMAGE   restore colour target 0x00200000"
    "SYNC_PIPE         before 1-cycle + Z"
    "SET_OTHER_MODES   1CYCLE + z_compare_en + z_update_en (0x30)"
    "SET_COMBINE       texel passthrough"
    "TRI_SHADE         0x0C Gouraud, same edges as TRIANGLE"
    "                  XL / DxLDy"
    "                  XH / DxHDy"
    "                  XM / DxMDy"
    "                  RGBA integer halves"
    "                  dRdx.. integer"
    "                  RGBA fractional halves"
    "                  dRdx.. fractional"
    "                  dRde.. integer"
    "                  dRdy.. integer"
    "                  dRde.. fractional"
    "                  dRdy.. fractional"
    "TRI_SHADE_Z       0x0D Gouraud + Z, same edges"
    "                  XL / DxLDy"
    "                  XH / DxHDy"
    "                  XM / DxMDy"
    "                  RGBA integer (white)"
    "                  dRdx.. integer"
    "                  RGBA fractional"
    "                  dRdx.. fractional"
    "                  dRde.. integer"
    "                  dRdy.. integer"
    "                  dRde.. fractional"
    "                  dRdy.. fractional"
    "                  Z / dZdx integer then fractional"
    "                  dZde / dZdy integer then fractional"
    "TRI_SHADE_TXTR    0x0E Gouraud + affine ST, tile 0, Y=16/16/48"
    "                  XL / DxLDy"
    "                  XH / DxHDy"
    "                  XM / DxMDy"
    "                  RGBA integer halves"
    "                  dRdx.. integer"
    "                  RGBA fractional halves"
    "                  dRdx.. fractional"
    "                  dRde.. integer"
    "                  dRdy.. integer"
    "                  dRde.. fractional"
    "                  dRdy.. fractional"
    "                  S/T/W integer halves (W=0x7FFF)"
    "                  dSdx / dTdx integer"
    "                  S/T/W fractional halves"
    "                  dSdx / dTdx fractional"
    "                  dSde / dTde integer"
    "                  dSdy / dTdy integer"
    "                  dSde / dTde fractional"
    "                  dSdy / dTdy fractional"
    "TRI_SHADE_TXTR_Z  0x0F Gouraud + tex + Z, same edges"
    "                  XL / DxLDy"
    "                  XH / DxHDy"
    "                  XM / DxMDy"
    "                  RGBA integer (white)"
    "                  dRdx.. integer"
    "                  RGBA fractional"
    "                  dRdx.. fractional"
    "                  dRde.. integer"
    "                  dRdy.. integer"
    "                  dRde.. fractional"
    "                  dRdy.. fractional"
    "                  S/T/W integer halves"
    "                  dSdx / dTdx integer"
    "                  S/T/W fractional"
    "                  dSdx / dTdx fractional"
    "                  dSde / dTde integer"
    "                  dSdy / dTdy integer"
    "                  dSde / dTde fractional"
    "                  dSdy / dTdy fractional"
    "                  Z / dZdx integer then fractional"
    "                  dZde / dZdy integer then fractional"
    "TRI_TEX_Z         0x0B affine ST + Z, tile 0, Y=16/16/48"
    "                  XL / DxLDy"
    "                  XH / DxHDy"
    "                  XM / DxMDy"
    "                  S/T/W integer halves (W=0x7FFF)"
    "                  dSdx / dTdx / dWdx integer"
    "                  S/T/W fractional halves"
    "                  dSdx / dTdx / dWdx fractional"
    "                  dSde / dTde integer"
    "                  dSdy / dTdy integer"
    "                  dSde / dTde fractional"
    "                  dSdy / dTdy fractional"
    "                  Z / dZdx integer then fractional"
    "                  dZde / dZdy integer then fractional"
    "SYNC_PIPE"
    "SYNC_TILE"
    "SYNC_LOAD"
    "SYNC_FULL         emitted by detach_show"
}

proc check_stream {label mem} {
    global EXPECTED NOTES DL_BASE
    set got [dl_words $mem]
    set want {}
    foreach w $EXPECTED { lappend want $w }
    if {[llength $got] != [llength $want]} {
        incr ::fail
        puts "FAIL  $label: display list has [llength $got] words, expected [llength $want]"
        puts "        got:  $got"
        return
    }
    set bad 0
    for {set i 0} {$i < [llength $want]} {incr i} {
        if {[lindex $got $i] ne [lindex $want $i]} {
            incr bad
            set note [lindex $NOTES [expr {$i / 2}]]
            puts "FAIL  $label +[format %03d [expr {$i*4}]] ($note)"
            puts "        got:  [lindex $got $i]"
            puts "        want: [lindex $want $i]"
        }
    }
    if {$bad == 0} {
        incr ::pass
        puts "ok    $label: all [llength $want] command words match"
    } else {
        incr ::fail
    }
}

puts "== RDP command stream (unoptimized) =="
set mem_plain [run_driver 0]
check_stream "unoptimized" $mem_plain

puts ""
puts "== RDP command stream (optimized) =="
# The optimizer reorders instructions and fills delay slots. It must not change
# what the RDP sees; a divergence here is a miscompile.
set mem_opt [run_driver 1]
check_stream "optimized" $mem_opt

puts ""
puts "== DP kick =="
# detach_show hands the list to the DP: physical start/end addresses, and the
# XBUS/freeze/flush clear bits so it reads RDRAM rather than RSP DMEM.
set dpc_start  [expr {0xA4100000}]
set dpc_end    [expr {0xA4100004}]
set dpc_status [expr {0xA410000C}]
set dl_len [expr {4 * [llength $EXPECTED]}]
ok "DPC_START" [reg_hex $mem_plain $dpc_start] [format %08X 0x00297000]
ok "DPC_END"   [reg_hex $mem_plain $dpc_end]   [format %08X [expr {0x00297000 + $dl_len}]]
ok "DPC_STATUS clears xbus/freeze/flush" [reg_hex $mem_plain $dpc_status] 00000015

puts ""
puts "== VI flip =="
# detach_show points the Video Interface at the buffer that was just drawn.
ok "VI_ORIGIN" [reg_hex $mem_plain [expr {0xA4400004}]] 00200000

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
