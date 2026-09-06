#!/usr/bin/env tclsh
# tcl/tools/ares_test.tcl — Pak standalone ROMs run on a real emulator.
#
# Everything else in this repo checks Pak against Pak: the simulator executes
# what the codegen emitted, and the gates that do have an outside oracle
# (binutils) only cover the bytes, not what the machine does with them. This
# runs the finished .z64 on ares and looks at the pixels that come out.
#
# ares specifically:
#   * mupen64plus cannot run libdragon's IPL3 at all -- its RDRAM emulation
#     leaves the size detection at 64 MB. See ipl3_compat.README.md.
#   * ares implements the PIF's five-second boot timeout, which is what caught
#     Pak's crt0 never sending the boot-termination command. An emulator that
#     skips it would have shown a working screen and hidden a ROM that hangs
#     on hardware.
#   * its RDP is paraLLEl-RDP, so the second case checks Pak's command stream
#     against a bit-accurate implementation rather than against
#     tcl/tools/rdp_test.tcl's idea of what the words should be.
#
# Headless: Xvfb plus Mesa's software rasterisers. Build ares with
# tools/build_ares.sh. Skips, loudly, when ares or Xvfb is missing.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl mips_codegen.tcl]
source [file join $REPO tcl optimize.tcl]
source [file join $REPO tcl n64enc.tcl]
source [file join $REPO tcl n64link.tcl]
source [file join $REPO tcl n64rom.tcl]

set ::pass 0
set ::fail 0
proc ok {name got want} {
    if {$got eq $want} { incr ::pass; puts "ok    $name = $got" } \
    else { incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want" }
}
proc ok_true {name cond {detail ""}} {
    if {$cond} { incr ::pass; puts "ok    $name$detail" } \
    else { incr ::fail; puts "FAIL  $name$detail" }
}

proc find_tool {name {extra {}}} {
    foreach dir [concat $extra [list /opt/pak-ares/bin] [split $::env(PATH) :]] {
        set p [file join $dir $name]
        if {[file executable $p]} { return $p }
    }
    return ""
}
set ARES    [find_tool ares]
set XVFB    [find_tool Xvfb]
set IMPORT  [find_tool import]
set CONVERT [find_tool convert]
foreach {n v} [list ares $ARES Xvfb $XVFB import $IMPORT convert $CONVERT] {
    if {$v eq ""} {
        puts "SKIP  $n not found (run tools/build_ares.sh)"
        exit 0
    }
}

# Debian and Ubuntu ship ares with the Nintendo 64 core removed, and it is on
# PATH ahead of anything tools/build_ares.sh installs. It opens a window, loads
# nothing, and shows a black screen -- which is indistinguishable from a ROM
# that does not boot. Ask which systems this binary actually has.
proc ares_has_n64 {ares} {
    set d ""
    catch {set d [glob /tmp/.X*-lock]}
    if {[catch {set out [exec xvfb-run -a $ares --help 2>@1]}]} { return 0 }
    return [string match "*Nintendo 64*" $out]
}
if {![ares_has_n64 $ARES]} {
    puts "SKIP  $ARES has no Nintendo 64 core (the distro package strips it)."
    puts "      Build one with tools/build_ares.sh and put it first on PATH."
    exit 0
}
puts "ares: $ARES"

set TMP /tmp/pak-ares-test
file delete -force $TMP
file mkdir $TMP

# ── build a ROM the way `pak build --backend mips` does ──────────────────────

proc asm_of_pak {path} {
    set fh [open $path r]; fconfigure $fh -encoding utf-8
    set src [read $fh]; close $fh
    set lx [pak::Lexer new $src]
    set ast [pak::parse_tokens [$lx tokenize]]
    return [pak::records_to_asm [pak::optimize_records [pak::mips_generate_records $ast]]]
}

proc build_rom {tag source title} {
    global TMP
    set dir [file join $TMP $tag]
    file mkdir $dir
    set fh [open runtime/standalone/boot.S r]; set boot [read $fh]; close $fh
    set bo [file join $dir boot.pakobj]
    pak::enc::write_object_from_asm $boot $bo
    set ro [file join $dir runtime.pakobj]
    pak::enc::write_object_from_asm [asm_of_pak runtime/standalone/runtime.pk64] $ro
    set go [file join $dir game.pakobj]
    pak::enc::write_object_from_asm [asm_of_pak $source] $go
    set r [pak::link_objects [list $bo $ro $go] _start]
    set rom [pak::n64rom [dict get $r image] $title [pak::n64rom_default_ipl3] \
                 [expr {4 * 1024 * 1024}]]
    set path [file join $dir $tag.z64]
    set fh [open $path wb]; puts -nonewline $fh $rom; close $fh
    return $path
}

# ── a display nothing else is using ──────────────────────────────────────────

proc start_xvfb {} {
    global XVFB TMP
    for {set d 90} {$d < 120} {incr d} {
        if {[file exists /tmp/.X$d-lock]} continue
        # -ac: no auth file to thread through to the screen grab.
        set pid [exec $XVFB :$d -screen 0 1280x960x24 -ac -nolisten tcp \
                     >> [file join $TMP xvfb.log] 2>@1 &]
        after 2000
        if {[file exists /tmp/.X$d-lock]} { return [list $d $pid] }
        catch {exec kill -9 $pid}
    }
    error "ares_test: no free X display"
}

# ── run one ROM and grab the screen ──────────────────────────────────────────

# Returns {shot log}. Polls until the screen stops being black rather than
# sleeping a fixed time: paraLLEl-RDP compiles its shaders on the first frame
# under lavapipe, which takes seconds.
proc run_rom {tag rom display} {
    global ARES IMPORT CONVERT TMP
    set log [file join $TMP $tag.log]
    set shot [file join $TMP $tag.png]
    set env_disp $display
    set pid [exec env DISPLAY=:$display LIBGL_ALWAYS_SOFTWARE=1 $ARES \
                 --system "Nintendo 64" --no-file-prompt --fullscreen \
                 --setting Audio/Driver=None --setting Audio/Mute=true \
                 --setting Input/Driver=None $rom >& $log &]
    set deadline [expr {[clock seconds] + 240}]
    set lit 0
    set stable 0
    set last {}
    while {[clock seconds] < $deadline} {
        after 3000
        if {[catch {exec env DISPLAY=:$env_disp $IMPORT -window root $shot 2>@1}]} continue
        if {[catch {set mean [exec env DISPLAY=:$env_disp $CONVERT $shot -format \
            {%[fx:mean.r*255] %[fx:mean.g*255] %[fx:mean.b*255]} info:]}]} continue
        lassign $mean mr mg mb
        # A whole-screen fill puts one channel's mean up near 100-240. ares
        # also draws a status message over the black window while it loads,
        # and that is bright enough to clear any small threshold -- hence
        # asking for a channel MEAN that only a filled frame can reach.
        set peak [expr {max($mr, max($mg, $mb))}]
        if {$peak <= 40} { set stable 0; set last {}; continue }
        # First light is not the finished frame. paraLLEl-RDP compiles its
        # shaders on the first draw, which under lavapipe can take minutes, and
        # ares fades a status message over the middle of the screen while it
        # does. Wait for the picture to stop changing instead of guessing a
        # sleep: three identical samples in a row, and the last grab is the one
        # that gets probed.
        if {$last ne "" && [same_frame $mean $last]} {
            incr stable
        } else {
            set stable 0
        }
        set last $mean
        if {$stable >= 2} { set lit 1; break }
    }
    catch {exec kill -9 $pid}
    after 500
    if {!$lit} {
        # Say what ares was doing, rather than only that no frame arrived.
        catch {
            set fh [open $log r]; set txt [read $fh]; close $fh
            foreach line [split [string trim $txt] \n] {
                if {[string match "ALSA*" $line]} continue
                puts "        ares: $line"
            }
        }
    }
    return [list $shot $log $lit]
}

# Two whole-screen means are the same picture. The tolerance absorbs the VI's
# dither, which alternates between fields.
proc same_frame {a b} {
    foreach x $a y $b {
        if {abs($x - $y) > 0.5} { return 0 }
    }
    return 1
}

# One pixel, in framebuffer coordinates: the VI scales 320x240 up to the whole
# window, so the mapping is a straight multiply and the test does not have to
# know the screen size.
proc probe {shot display fx fy} {
    global CONVERT IMPORT
    set wh [exec env DISPLAY=:$display $CONVERT $shot -format {%w %h} info:]
    lassign $wh w h
    set x [expr {int($fx * $w / 320.0)}]
    set y [expr {int($fy * $h / 240.0)}]
    set px [exec env DISPLAY=:$display $CONVERT $shot -format \
        "%\[fx:floor(p{$x,$y}.r*255)\] %\[fx:floor(p{$x,$y}.g*255)\] %\[fx:floor(p{$x,$y}.b*255)\]" info:]
    return $px
}

# The VI's anti-alias and dither filters move edge pixels around, so a probe
# names the channel that should dominate rather than an exact triple. Every
# probe below sits well inside a flat region.
proc ok_colour {name got want} {
    lassign $got r g b
    lassign $want wr wg wb
    set good 1
    foreach c [list $r $g $b] w [list $wr $wg $wb] {
        if {$w > 128} { if {$c < 200} { set good 0 } } else { if {$c > 48} { set good 0 } }
    }
    ok_true $name $good "  rgb($r,$g,$b), want [expr {$wr>128?"R":"-"}][expr {$wg>128?"G":"-"}][expr {$wb>128?"B":"-"}]"
}

proc no_boot_timeout {tag log} {
    set fh [open $log r]; set txt [read $fh]; close $fh
    ok_true "$tag: the PIF did not time the boot out" \
        [expr {![string match "*boot timeout*" $txt]}]
    return $txt
}

# ── the cases ────────────────────────────────────────────────────────────────

lassign [start_xvfb] DISPLAY XVFB_PID
puts "using display :$DISPLAY"

set failed 0
if {[catch {

puts ""
puts "== the CPU writes the framebuffer =="
# No RDP, no RSP, no interrupts. VI setup, a fill, a flip. If this comes up
# red then IPL3 handed over, boot.S ran, main ran, and the VI is programmed.
set rom [build_rom redscreen tcl/tests/ares/redscreen.pk64 "PAKRED"]
lassign [run_rom redscreen $rom $DISPLAY] shot log lit
no_boot_timeout redscreen $log
ok_true "redscreen: a frame reached the screen" $lit
if {$lit} {
    foreach {fx fy where} {20 20 top-left 160 120 centre 300 220 bottom-right} {
        ok_colour "redscreen: $where is red" [probe $shot $DISPLAY $fx $fy] {255 0 0}
    }
}

puts ""
puts "== the RDP draws =="
# rdpq.attach_clear to blue, then fill_rectangle(80,60,240,180) in green.
# ares renders this with paraLLEl-RDP, so the corners landing where they
# should is a check on the command words, not just on our own encoder.
set rom [build_rom rdpfill tcl/tests/ares/rdpfill.pk64 "PAKRDP"]
lassign [run_rom rdpfill $rom $DISPLAY] shot log lit
no_boot_timeout rdpfill $log
ok_true "rdpfill: a frame reached the screen" $lit
if {$lit} {
    foreach {fx fy where} {40 40 outside-top-left 300 220 outside-bottom-right
                           20 120 outside-left 160 20 outside-top} {
        ok_colour "rdpfill: $where is the blue clear" \
            [probe $shot $DISPLAY $fx $fy] {0 0 255}
    }
    foreach {fx fy where} {160 120 centre 90 70 inside-top-left 230 170 inside-bottom-right} {
        ok_colour "rdpfill: $where is the green rectangle" \
            [probe $shot $DISPLAY $fx $fy] {0 255 0}
    }
}

} err]} {
    puts "FAIL  ares_test: $err"
    incr ::fail
}

catch {exec kill -9 $XVFB_PID}
catch {file delete /tmp/.X$DISPLAY-lock}

puts ""
puts "screenshots: $TMP"
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
