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
if {![file executable $RDPRUN]} {
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
proc render {driver_src} {
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
    set r [pak::mips_sim_run $asm main 20000000 $preset]
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
    set area [expr {abs([sgn $x0 $y0 $x1 $y1 $x2 $y2]) / 2.0}]
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

# ── 3. a textured triangle samples the texture across its surface ────────────

puts ""
puts "== a textured triangle maps the texture across itself =="

# The same half-red/half-blue page, drawn through TRI_TEX in 1-cycle mode with
# ST spanning the whole page. This is the case the roadmap called the real
# gate, and it is the one that stayed broken longest: with bi_lerp clear the
# RDP sends every texel through the YUV convert path and the triangle comes
# out untextured, while every command word still looks right.
set tri_src {
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
    rdpq.set_mode_standard()
    rdpq.triangle_tex(0, 40, 40, 0, 0, 200, 60, 32, 0, 80, 180, 0, 32)
    rdpq.detach_show()
}}

lassign [render $tri_src] st res
if {$st eq "err"} {
    puts "FAIL  textured triangle: $res"
    incr ::fail
} else {
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
    ok_true "textured triangle covers its geometry" [expr {$n > 10000 && $n < 11500}] \
        " (drawn=$n, area=10800)"
    ok_true "it is textured, not flat" [expr {$red > 1000 && $blue > 1000}] \
        " (red=$red blue=$blue other=$other)"
    # S runs 0..32 left-to-right across the triangle, so the red half (S<16)
    # must sit to the left of the blue half. If ST were ignored or constant
    # this would not hold.
    if {$red > 0 && $blue > 0} {
        set rmean [expr {double($redx) / $red}]
        set bmean [expr {double($bluex) / $blue}]
        ok_true "the S axis runs the right way" [expr {$rmean < $bmean}] \
            [format " (mean x: red %.1f < blue %.1f)" $rmean $bmean]
    } else {
        incr ::fail
        puts "FAIL  the S axis runs the right way (one colour missing)"
    }
}

puts ""
puts "PASS=$::pass  FAIL=$::fail"
exit [expr {$::fail > 0 ? 1 : 0}]
