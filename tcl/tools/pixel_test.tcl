#!/usr/bin/env tclsh
# tcl/tools/pixel_test.tcl — check what the RDP actually DRAWS, not what the
# command words say.
#
# rdp_test.tcl asserts the encoding of every command the runtime emits. That is
# necessary and provably insufficient: for as long as those goldens have
# existed, the `lft` bit was inverted on all seven triangle commands, so every
# triangle covered about one pixel on hardware. The goldens matched perfectly,
# because they pinned the wrong value.
#
# So this runs the display list through angrylion's RDP -- the accuracy
# reference -- and compares the resulting pixels against geometry computed
# independently, from the vertices the Pak source asked for. A wrong lft, a
# wrong 10.2 scissor or a bad edge slope changes pixels; none of them change
# whether the encoder agrees with itself.
#
#   tools/build_rdp_harness.sh   builds the reference (pinned revision)
#   tclsh tcl/tools/pixel_test.tcl
#
# Skips cleanly when the harness is unavailable, the same way n64asm_parity.sh
# skips without mips64-elf-as.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl mips_sim.tcl]

set TMP [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set HARNESS_DIR [file join $TMP pak-rdp-harness]
set RDPRUN [file join $HARNESS_DIR rdprun]
set WORK [file join $TMP pak-pixel-test]
file mkdir $WORK

if {![file executable $RDPRUN]} {
    catch {exec bash [file join $REPO tools build_rdp_harness.sh] $HARNESS_DIR} out
    puts $out
}

# Skipping when the reference cannot be built is fine on a laptop with no
# network. Skipping on the machine that is supposed to be the gate is how the
# `lft` bit stayed inverted on every triangle opcode for as long as the
# encoding goldens existed: the harness quietly failed to build, the suite
# reported SKIP, and CI went green. So CI sets PAK_REQUIRE_RDP_HARNESS=1 and
# a missing harness is a failure there, with the build log to say why.
set REQUIRED [expr {[info exists ::env(PAK_REQUIRE_RDP_HARNESS)]
                    && $::env(PAK_REQUIRE_RDP_HARNESS) ni {0 "" no false}}]

if {![file executable $RDPRUN]} {
    if {$REQUIRED} {
        puts "pixel test: FAIL (PAK_REQUIRE_RDP_HARNESS is set and the reference"
        puts "                  RDP harness is not at $RDPRUN)"
        puts "                  tools/build_rdp_harness.sh said:"
        puts [string trim $out]
        exit 1
    }
    puts "pixel test: SKIP (no reference RDP harness; run tools/build_rdp_harness.sh)"
    exit 0
}

set ::pass 0
set ::fail 0

proc ok_true {name cond {detail ""}} {
    if {$cond} { incr ::pass; puts "ok    $name$detail" } \
    else { incr ::fail; puts "FAIL  $name$detail" }
}

# ── run a Pak driver, hand its display list to the reference RDP ─────────────

# The framebuffer, the display list and any texture all live in the simulated
# RDRAM at the physical addresses the program used, so the reference RDP can be
# pointed straight at it. angrylion holds RDRAM as a host-native word array, so
# the image is byte-swapped in 32-bit groups on the way out.
# `cart` is the cartridge image, or "" for a scene that does not stream. The
# simulator honours PI_WR_LEN against it, so a scene whose texels come from the
# cart renders here exactly as it would on hardware -- and, crucially, renders
# BLACK if the transfer does not happen, which is what makes the streaming
# gate below meaningful rather than decorative.
proc render {driver_src {cart ""}} {
    global REPO WORK RDPRUN
    set fh [open runtime/standalone/runtime.pk64 r]; set rt [read $fh]; close $fh
    set combined [file join $REPO .pixel_combined.pk64]
    set f [open $combined w]; puts -nonewline $f "$rt\n$driver_src"; close $f
    set asm [exec [info nameofexecutable] tcl/tools/mips_dump.tcl $combined]
    file delete $combined
    if {[string match "UNPORTED*" $asm] || [string match "ERROR*" $asm]} {
        return [list err [lindex [split $asm "\n"] 0]]
    }
    # DP idle, VI past the active region, PI idle.
    set preset [dict create 0xA410000C 0 0xA4400010 {0x1E0 0x000}]
    set r [pak::mips_sim_run $asm main 20000000 $preset $cart]
    set mw [dict get $r mem_w]

    set SIZE [expr {0x800000}]
    set buf [binary format x$SIZE]
    foreach {kind width} {mem_w 4 mem_h 2 mem_b 1} {
        dict for {addr val} [dict get $r $kind] {
            set p [expr {$addr & 0x1FFFFFFF}]
            if {$p < 0 || $p + $width > $SIZE} continue
            switch -- $width {
                4 { set bytes [binary format I [expr {$val & 0xFFFFFFFF}]] }
                2 { set bytes [binary format S [expr {$val & 0xFFFF}]] }
                1 { set bytes [binary format c [expr {$val & 0xFF}]] }
            }
            set buf [string replace $buf $p [expr {$p + $width - 1}] $bytes]
        }
    }
    binary scan $buf I* words
    set img [file join $WORK rdram.bin]
    set o [open $img wb]; fconfigure $o -translation binary
    puts -nonewline $o [binary format i* $words]; close $o

    proc _rd {mw a} { set a [expr {$a}]; return [expr {[dict exists $mw $a] ? [dict get $mw $a] : 0}] }
    set dl_start [_rd $mw 0xA4100000]
    set dl_end   [_rd $mw 0xA4100004]
    if {$dl_end <= $dl_start} { return [list err "no display list was submitted"] }

    set ppm [file join $WORK out.ppm]
    if {[catch {exec $RDPRUN $img $dl_start [expr {$dl_end - $dl_start}] \
            0x200000 320 240 $ppm 2>@1} e]} {
        return [list err "reference RDP failed: $e"]
    }
    return [list ok $ppm]
}

# Pixels that are not the clear colour, as a dict keyed "x,y".
proc drawn_pixels {ppm} {
    set f [open $ppm rb]; fconfigure $f -translation binary
    set d [read $f]; close $f
    set i [expr {[string first "255\n" $d] + 4}]
    set px [string range $d $i end]
    set out [dict create]
    for {set y 0} {$y < 240} {incr y} {
        for {set x 0} {$x < 320} {incr x} {
            set o [expr {($y * 320 + $x) * 3}]
            binary scan [string range $px $o [expr {$o+2}]] cucucu r g b
            if {$r != 0 || $g != 0 || $b != 0} { dict set out "$x,$y" [list $r $g $b] }
        }
    }
    return $out
}

proc sgn {ax ay bx by cx cy} { return [expr {($ax-$cx)*($by-$cy) - ($bx-$cx)*($ay-$cy)}] }

# Clip a polygon to one axis-aligned half-plane (Sutherland-Hodgman). Used to
# get the correct expected coverage for a triangle with a vertex off-screen --
# its true visible area is smaller than its full geometric area, and checking
# coverage against the unclipped area would fail for a shape that is working
# exactly as intended.
proc clip_half {poly axis cmp bound} {
    set out {}
    set n [llength $poly]
    if {$n == 0} { return $out }
    for {set i 0} {$i < $n} {incr i} {
        lassign [lindex $poly $i] cx cy
        lassign [lindex $poly [expr {($i+1)%$n}]] nx ny
        if {$axis eq "x"} { set cv $cx; set nv $nx } else { set cv $cy; set nv $ny }
        if {$cmp eq "ge"} {
            set cin [expr {$cv >= $bound}]; set nin [expr {$nv >= $bound}]
        } else {
            set cin [expr {$cv <= $bound}]; set nin [expr {$nv <= $bound}]
        }
        if {$cin} { lappend out [list $cx $cy] }
        if {$cin != $nin} {
            set t [expr {double($bound - $cv) / double($nv - $cv)}]
            lappend out [list [expr {$cx + $t*($nx-$cx)}] [expr {$cy + $t*($ny-$cy)}]]
        }
    }
    return $out
}

proc clipped_area {x0 y0 x1 y1 x2 y2 w h} {
    set poly [list [list $x0 $y0] [list $x1 $y1] [list $x2 $y2]]
    set poly [clip_half $poly x ge 0]
    set poly [clip_half $poly x le $w]
    set poly [clip_half $poly y ge 0]
    set poly [clip_half $poly y le $h]
    if {[llength $poly] < 3} { return 0.0 }
    set a 0.0
    set n [llength $poly]
    for {set i 0} {$i < $n} {incr i} {
        lassign [lindex $poly $i] ax ay
        lassign [lindex $poly [expr {($i+1)%$n}]] bx by
        set a [expr {$a + $ax*$by - $bx*$ay}]
    }
    return [expr {abs($a)/2.0}]
}

# ── 1. filled triangles cover the right pixels ───────────────────────────────

puts "== filled triangles cover their geometry =="

proc check_triangle {name x0 y0 x1 y1 x2 y2} {
    set src "
entry {
    rdpq.init()
    rdpq.attach_clear(0xA0200000, 0x0000_0001)
    rdpq.set_mode_fill(0xFFFF_FFFF)
    rdpq.triangle($x0, $y0, $x1, $y1, $x2, $y2)
    rdpq.detach_show()
}"
    lassign [render $src] st res
    if {$st eq "err"} { puts "FAIL  $name: $res"; incr ::fail; return }
    set drawn [drawn_pixels $res]

    # Interior points, computed from the source vertices, not from anything the
    # encoder produced. Every one of them must be covered.
    set inside {}
    for {set y 0} {$y < 240} {incr y} {
        for {set x 0} {$x < 320} {incr x} {
            set px [expr {$x + 0.5}] ; set py [expr {$y + 0.5}]
            set d1 [sgn $px $py $x0 $y0 $x1 $y1]
            set d2 [sgn $px $py $x1 $y1 $x2 $y2]
            set d3 [sgn $px $py $x2 $y2 $x0 $y0]
            set neg [expr {$d1 < 0 || $d2 < 0 || $d3 < 0}]
            set pos [expr {$d1 > 0 || $d2 > 0 || $d3 > 0}]
            if {!($neg && $pos)} { lappend inside [list $x $y] }
        }
    }
    # Erode by one pixel: the points no correct rasterizer may miss, whatever
    # its edge rule.
    set core {}
    set iset [dict create]
    foreach p $inside { dict set iset "[lindex $p 0],[lindex $p 1]" 1 }
    foreach p $inside {
        lassign $p x y
        set solid 1
        foreach dx {-1 0 1} {
            foreach dy {-1 0 1} {
                if {![dict exists $iset "[expr {$x+$dx}],[expr {$y+$dy}]"]} { set solid 0 }
            }
        }
        if {$solid} { lappend core $p }
    }
    set missing 0
    foreach p $core {
        if {![dict exists $drawn "[lindex $p 0],[lindex $p 1]"]} { incr missing }
    }
    # Clipped to the viewport: a vertex off-screen makes the true visible area
    # smaller than the raw shoelace formula, and checking against the
    # unclipped area would fail a triangle that is working exactly as
    # intended. For an all-on-screen triangle clipping is a no-op, so this is
    # the same check as before for every existing case.
    set area [clipped_area $x0 $y0 $x1 $y1 $x2 $y2 320 240]
    set n [dict size $drawn]
    # Coverage may exceed the exact area by up to the perimeter (half a pixel
    # per boundary pixel), but must not fall short of it.
    set per [expr {hypot($x1-$x0,$y1-$y0) + hypot($x2-$x1,$y2-$y1) + hypot($x0-$x2,$y0-$y2)}]
    set ok [expr {$missing == 0 && $n >= $area * 0.95 && $n <= $area + $per}]
    if {$ok} {
        incr ::pass
        puts [format "ok    %-22s drawn=%d area=%.0f missing=0" $name $n $area]
    } else {
        incr ::fail
        puts [format "FAIL  %-22s drawn=%d area=%.0f missing=%d" $name $n $area $missing]
    }
}

# Both windings: the major edge on the left, and on the right. An inverted lft
# collapses one or both to a couple of pixels.
check_triangle "major edge left"  40 40 200 60 80 180
check_triangle "major edge right" 200 40 40 60 160 180
check_triangle "tall thin"        150 20 170 220 130 220
check_triangle "wide flat"        20 100 300 110 160 130
check_triangle "right angle"      50 50 250 50 50 200

# A vertex off-screen. The RDP's YL/YM/YH header field is a signed 14-bit
# value (11.2), not the unsigned 12-bit field the scissor and rectangles use,
# and a vertex above the top or left of the screen has a genuinely negative
# coordinate. Clamping it to 0 (as to_fx102 does, correctly, for scissor and
# rect corners) leaves the X value at the header's Y wrong -- X is the
# unclamped value at the TRUE vertex Y, not at Y=0 -- and the RDP starts
# rasterizing at scanline 0 with an X that belongs to a different Y, shearing
# the whole triangle. Y is unclamped now (to_fx142); the RDP's own scissor
# test clips what falls outside 0..239, same as any other engine.
puts ""
puts "== a vertex off-screen does not shear the triangle =="
check_triangle "vertex above top"      100 -40 250 120  40  150
check_triangle "vertex left of screen"  -60  60 200  40 100  200
check_triangle "vertex below bottom"   100  40 250 300  40  150
check_triangle "vertex right of screen" 350  60 100 200  40   40
check_triangle "two vertices offscreen" -50 -50 400  40 100  260

# ── 2. texture rectangles sample the texels they were given ──────────────────

puts ""
puts "== a texture rectangle shows the texels it was handed =="

# The page is written by the program itself: left half red, right half blue in
# RGBA5551. If TMEM, the tile descriptor or the combiner were wrong the colours
# would not come back.
set tex_src {
@aligned(16)
static page: [2048]u8 = undefined

fn fill_page() {
    let base: u32 = (&page[0] as u32) | 0xA000_0000
    let mut i: i32 = 0
    loop {
        if i >= 1024 { break }
        let s: i32 = i % 32
        let p: *volatile u16 = (base + (i * 2) as u32) as *volatile u16
        if s < 16 { *p = 0xF801 as u16 } else { *p = 0x003F as u16 }
        i = i + 1
    }
}

entry {
    rdpq.init()
    fill_page()
    rdpq.attach_clear(0xA0200000, 0x0000_0001)
    rdpq.set_mode_standard()
    rdpq.set_texture_image((&page[0] as u32) | 0xA000_0000, 0, 2, 32)
    rdpq.set_tile_mask(0, 0, 2, 8, 0, 0, 2, 2, 5, 5)
    rdpq.load_tile(0, 0, 0, 32, 32)
    rdpq.set_tile_size(0, 0, 0, 32, 32)
    rdpq.sync_tile()
    SETMODE
    RECT
    rdpq.detach_show()
}}

set copy_src [string map {SETMODE "rdpq.set_mode_copy()" \
                          RECT "rdpq.texture_rectangle(0, 60, 40, 220, 200, 0, 0)"} $tex_src]
lassign [render $copy_src] st res
if {$st eq "err"} {
    puts "FAIL  texture rectangle: $res"
    incr ::fail
} else {
    set drawn [drawn_pixels $res]
    set red 0 ; set blue 0 ; set other 0
    dict for {k v} $drawn {
        lassign $v r g b
        if {$r > 200 && $b < 60} { incr red } elseif {$b > 200 && $r < 60} { incr blue } else { incr other }
    }
    set total [expr {$red + $blue + $other}]
    if {$total != 25600} {
        incr ::fail
        puts "FAIL  texrect covers 160x160        drawn=$total (want 25600)"
    } else {
        incr ::pass
        puts "ok    texrect covers 160x160        drawn=$total"
    }
    # The page is half red and half blue, so the rect must be too.
    if {$red > 0 && $blue > 0 && $red == $blue && $other == 0} {
        incr ::pass
        puts "ok    texels come back red and blue red=$red blue=$blue"
    } else {
        incr ::fail
        puts "FAIL  texels come back red and blue red=$red blue=$blue other=$other"
    }
}

# A 1:1 blit in 1-cycle mode. The S step is s5.10 texels per pixel, and COPY
# wants it written 4x because the RDP retires four pixels per cycle there.
# Hardcoding the COPY constant made every 1-cycle blit walk S four times too
# fast, consuming a 32-texel page in eight pixels; the COPY test above cannot
# see that, because there the value is right.
puts ""
puts "== a 1-cycle blit steps one texel per pixel =="

set blit1_src [string map {SETMODE "rdpq.set_mode_standard()" \
                           RECT "rdpq.texture_rectangle(0, 100, 100, 132, 132, 0, 0)"} $tex_src]
lassign [render $blit1_src] st res
if {$st eq "err"} {
    puts "FAIL  1-cycle blit: $res"
    incr ::fail
} else {
    set drawn [drawn_pixels $res]
    set red 0 ; set blue 0
    dict for {k v} $drawn {
        lassign $v r g b
        if {$r > 200 && $b < 80} { incr red } elseif {$b > 200 && $r < 80} { incr blue }
    }
    # 32x32 pixels over a 32x32 page at 1:1 is the page exactly: 16 red columns
    # and 16 blue, 32 rows each.
    ok_true "32x32 blit covers 1024 pixels" [expr {[dict size $drawn] == 1024}] \
        " (drawn=[dict size $drawn])"
    ok_true "one texel per pixel, half red half blue" [expr {$red == 512 && $blue == 512}] \
        " (red=$red blue=$blue)"
}

# ── 3. the textured triangle opcodes sample the texture across their surface ──

puts ""
puts "== a textured triangle maps the texture across itself =="

# The same half-red/half-blue page, drawn through the triangle opcodes that
# carry a texture coefficient block, in 1-cycle mode with ST spanning the whole
# page. This is the case the roadmap called the real gate, and it is the one
# that stayed broken longest: with bi_lerp clear the RDP sends every texel
# through the YUV convert path and the triangle comes out untextured, while
# every command word still looks right.
#
# All three of TRI_TEX, TRI_TEX_Z and TRI_SHADE_TXTR carry the same eight ST
# coefficient dwords, and rdp_test.tcl pins all three against the same
# expectations -- so a wrong packing would agree with itself across the set and
# the encoding goldens would stay green. Each one is rendered separately here
# because sharing a coefficient *builder* is not evidence that the three
# commands the RDP receives are each right: TRI_SHADE_TXTR puts the block after
# a shade block, and TRI_TEX_Z in front of a Z block, so a block boundary that
# is off by a doubleword shows up in one and not the others.
set tri_tpl {
@aligned(16)
static page: [2048]u8 = undefined

fn fill_page() {
    let base: u32 = (&page[0] as u32) | 0xA000_0000
    let mut i: i32 = 0
    loop {
        if i >= 1024 { break }
        let s: i32 = i % 32
        let p: *volatile u16 = (base + (i * 2) as u32) as *volatile u16
        if s < 16 { *p = 0xF801 as u16 } else { *p = 0x003F as u16 }
        i = i + 1
    }
}

entry {
    rdpq.init()
    fill_page()
    rdpq.attach_clear(0xA0200000, 0x0000_0001)
    rdpq.set_texture_image((&page[0] as u32) | 0xA000_0000, 0, 2, 32)
    rdpq.set_tile_mask(0, 0, 2, 8, 0, 0, 2, 2, 5, 5)
    rdpq.load_tile(0, 0, 0, 32, 32)
    rdpq.set_tile_size(0, 0, 0, 32, 32)
    rdpq.sync_tile()
    PRE
    DRAW
    rdpq.detach_show()
}}

# Coverage, texturing and the direction of the S axis, for one textured
# triangle drawn over the vertices (40,40) (200,60) (80,180) with S running
# 0..32 from the two left vertices to the right one. Every check is against
# what the Pak source asked for, never against what the encoder produced.
proc check_textured_tri {name pre draw} {
    global tri_tpl
    lassign [render [string map [list PRE $pre DRAW $draw] $tri_tpl]] st res
    if {$st eq "err"} { puts "FAIL  $name: $res"; incr ::fail; return }
    set drawn [drawn_pixels $res]
    set red 0 ; set blue 0 ; set other 0
    set redx 0 ; set bluex 0
    dict for {k v} $drawn {
        lassign $v r g b
        lassign [split $k ,] x y
        if {$r > 200 && $b < 80} { incr red ; incr redx $x } \
        elseif {$b > 200 && $r < 80} { incr blue ; incr bluex $x } \
        else { incr other }
    }
    set n [dict size $drawn]
    # The filled triangle of the same vertices covers 10800 by area; a textured
    # one must cover essentially the same, not a handful of pixels.
    ok_true "$name covers its geometry" [expr {$n > 10000 && $n < 11500}] \
        " (drawn=$n, area=10800)"
    ok_true "$name is textured, not flat" [expr {$red > 1000 && $blue > 1000}] \
        " (red=$red blue=$blue other=$other)"
    # S runs 0..32 left-to-right across the triangle, so the red half (S<16)
    # must sit to the left of the blue half. If ST were ignored or constant
    # this would not hold.
    if {$red > 0 && $blue > 0} {
        set rmean [expr {double($redx) / $red}]
        set bmean [expr {double($bluex) / $blue}]
        ok_true "$name runs S the right way" [expr {$rmean < $bmean}] \
            [format " (mean x: red %.1f < blue %.1f)" $rmean $bmean]
    } else {
        incr ::fail
        puts "FAIL  $name runs S the right way (one colour missing)"
    }
}

check_textured_tri "TRI_TEX" \
    "rdpq.set_mode_standard()" \
    "rdpq.triangle_tex(0, 40, 40, 0, 0, 200, 60, 32, 0, 80, 180, 0, 32)"

# TRI_TEX_Z (0x0B) is TRI_TEX with a Z block appended. Drawn here with the
# depth buffer enabled and all three vertices at the same Z, so the picture
# must be the one TRI_TEX draws -- a Z block written into the wrong place
# would be consumed as ST, or the ST as Z.
check_textured_tri "TRI_TEX_Z" \
    "rdpq.set_mode_standard_z()\n    rdpq.clear_z()\n    rdpq.set_tri_z(100, 100, 100)" \
    "rdpq.triangle_tex_z(0, 40, 40, 0, 0, 200, 60, 32, 0, 80, 180, 0, 32)"

# TRI_SHADE_TXTR (0x0E) puts a shade block between the edges and the ST block.
# The 1-cycle combiner set_mode_standard installs passes TEX0 straight through
# and ignores shade, so the colours below are the texture's, exactly as for
# TRI_TEX; what this case is gating is that the ST block still lands where the
# RDP expects it with 64 bytes of shade in front of it.
check_textured_tri "TRI_SHADE_TXTR" \
    "rdpq.set_mode_standard()" \
    "rdpq.triangle_shade_tex(0, 40, 40, 0xFFFF_FFFF, 0, 0, 200, 60, 0xFFFF_FFFF, 32, 0, 80, 180, 0xFFFF_FFFF, 0, 32)"

# ── 4. the Z block on a textured triangle actually rejects ───────────────────

puts ""
puts "== a textured triangle's Z block is depth-tested =="

# Two TRI_TEX_Z triangles over the same vertices: a near one with S running
# left-to-right (red on the left), then a far one with S reversed (blue on the
# left). With the Z block right the far triangle fails the depth test and the
# picture stays red-on-the-left. With Z ignored -- or read out of the ST
# dwords, which is what a block boundary off by one doubleword produces -- the
# second draw wins and the halves swap. Coverage and texturing alone cannot
# see this: both draws are correctly-textured triangles.
set z_pre "rdpq.set_mode_standard_z()\n    rdpq.clear_z()\n    rdpq.set_tri_z(200, 200, 200)"
set z_draw "rdpq.triangle_tex_z(0, 40, 40, 0, 0, 200, 60, 32, 0, 80, 180, 0, 32)
    rdpq.set_tri_z(30000, 30000, 30000)
    rdpq.triangle_tex_z(0, 40, 40, 32, 0, 200, 60, 0, 0, 80, 180, 32, 32)"

lassign [render [string map [list PRE $z_pre DRAW $z_draw] $tri_tpl]] st res
if {$st eq "err"} {
    puts "FAIL  depth-tested textured triangle: $res"
    incr ::fail
} else {
    set drawn [drawn_pixels $res]
    set red 0 ; set blue 0 ; set redx 0 ; set bluex 0
    dict for {k v} $drawn {
        lassign $v r g b
        lassign [split $k ,] x y
        if {$r > 200 && $b < 80} { incr red ; incr redx $x } \
        elseif {$b > 200 && $r < 80} { incr blue ; incr bluex $x }
    }
    if {$red > 0 && $blue > 0} {
        set rmean [expr {double($redx) / $red}]
        set bmean [expr {double($bluex) / $blue}]
        ok_true "the far triangle is rejected" [expr {$rmean < $bmean}] \
            [format " (mean x: red %.1f, blue %.1f)" $rmean $bmean]
    } else {
        incr ::fail
        puts "FAIL  the far triangle is rejected (one colour missing: red=$red blue=$blue)"
    }
}

# ── 5. a texture streamed from the cart reaches the screen ──────────────────

puts ""
puts "== a page DMA'd from the cart is the page that gets drawn =="

# Everything above hands the RDP texels the program itself wrote into RDRAM.
# The CHROMA nave does not work that way and neither does any scene too big to
# embed its art: the texels live on the cartridge and arrive by PI DMA, one
# page at a time. That path has had no pixel gate at all -- church_test.tcl
# asserts the PI registers and the display list, which is to say it asserts
# that the program ASKED for the right transfer, not that the right texels
# arrived. `pak dlist --cart` had the only cart hook in the tree.
#
# This is the general case, not a church harness: any scene whose texture comes
# from `dma.read` can be rendered this way. The page below is built here, in
# the test, at the cart address the scene reads -- so if the simulator did not
# honour PI_WR_LEN, or the scene got the cart address wrong, or the cache ops
# were in the wrong order, the scratch buffer would still hold zeros and the
# triangle would come back black instead of red-and-blue. Nothing else in the
# suite can tell those apart.

set PAGE_BASE 0x10200000
set PAGE_OFF  0x200000

# 32x32 RGBA5551, left half red, right half blue: the same page the in-RAM
# cases use, so a difference in the picture is a difference in the PATH, not
# in the texture.
set page ""
for {set t 0} {$t < 32} {incr t} {
    for {set sx 0} {$sx < 32} {incr sx} {
        append page [binary format S [expr {$sx < 16 ? 0xF801 : 0x003F}]]
    }
}
# The cart image only has to reach past the page; the loader never reads the
# gap, and a short image would make pi_dma_read pad with zeros silently.
set cart_img [string repeat "\x00" $PAGE_OFF]
append cart_img $page

set stream_src {
@aligned(16)
static page_buf: [2048]u8 = undefined

-- The CHROMA per-page pipeline, verbatim: writeback, read, wait, invalidate.
-- E201 fires without the writeback and E202 without the @aligned(16), so the
-- checker has already refused the two ways to get this wrong at compile time.
-- What it cannot check is whether the bytes actually landed, which is what the
-- picture below is for.
fn fetch_page(page: i32) {
    cache.writeback(&page_buf[0], 2048)
    dma.read(&page_buf[0], 0x1020_0000 + (page * 2048) as u32, 2048)
    dma.wait()
    cache.invalidate(&page_buf[0], 2048)
}

entry {
    rdpq.init()
    fetch_page(0)
    rdpq.attach_clear(0xA0200000, 0x0000_0001)
    -- KSEG1 alias: the DP reads RDRAM, not the d-cache (E203 on a KSEG0 addr).
    rdpq.set_texture_image((&page_buf[0] as u32) | 0xA000_0000, 0, 2, 32)
    rdpq.set_tile_mask(0, 0, 2, 8, 0, 0, 2, 2, 5, 5)
    rdpq.load_tile(0, 0, 0, 32, 32)
    rdpq.set_tile_size(0, 0, 0, 32, 32)
    rdpq.sync_tile()
    rdpq.set_mode_standard()
    rdpq.triangle_tex(0, 40, 40, 0, 0, 200, 60, 32, 0, 80, 180, 0, 32)
    rdpq.detach_show()
}}

lassign [render $stream_src $cart_img] st res
if {$st eq "err"} {
    puts "FAIL  streamed page: $res"
    incr ::fail
} else {
    set drawn [drawn_pixels $res]
    set red 0 ; set blue 0 ; set other 0 ; set redx 0 ; set bluex 0
    dict for {k v} $drawn {
        lassign $v r g b
        lassign [split $k ,] x y
        if {$r > 200 && $b < 80} { incr red ; incr redx $x } \
        elseif {$b > 200 && $r < 80} { incr blue ; incr bluex $x } \
        else { incr other }
    }
    set n [dict size $drawn]
    ok_true "the streamed triangle covers its geometry" \
        [expr {$n > 10000 && $n < 11500}] " (drawn=$n, area=10800)"
    # The whole point: these texels were never written by the program. If the
    # PI transfer did not happen the buffer is zeros and this is all black.
    ok_true "the cart's texels are on screen, not zeros" \
        [expr {$red > 1000 && $blue > 1000}] " (red=$red blue=$blue other=$other)"
    if {$red > 0 && $blue > 0} {
        set rmean [expr {double($redx) / $red}]
        set bmean [expr {double($bluex) / $blue}]
        ok_true "the streamed page is oriented the right way" \
            [expr {$rmean < $bmean}] \
            [format " (mean x: red %.1f < blue %.1f)" $rmean $bmean]
    } else {
        incr ::fail
        puts "FAIL  the streamed page is oriented the right way (one colour missing)"
    }
}

# The negative control. Same scene, same assertions, no cart image: the PI
# transfer moves nothing and the page stays zero. If this DREW a textured
# triangle, the test above would be passing on texels that came from somewhere
# other than the cart, and would be worth nothing.
lassign [render $stream_src ""] st2 res2
if {$st2 eq "err"} {
    puts "FAIL  streamed page (no cart): $res2"
    incr ::fail
} else {
    set drawn2 [drawn_pixels $res2]
    set coloured 0
    dict for {k v} $drawn2 {
        lassign $v r g b
        if {($r > 200 && $b < 80) || ($b > 200 && $r < 80)} { incr coloured }
    }
    ok_true "with no cart image the same scene draws no texels" \
        [expr {$coloured == 0}] " (coloured=$coloured)"
}

puts ""
puts "PASS=$::pass  FAIL=$::fail"
exit [expr {$::fail > 0 ? 1 : 0}]
