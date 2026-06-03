#!/usr/bin/env tclsh
# examples/baremetal/render_fb.tcl
#
# Execute the bare-metal main.s in a pure-Tcl MIPS simulator, capture every
# `sh` store to the 320×240 framebuffer region (0xA0100000..+153600), and
# write the result as a PPM image.  No emulator, no toolchain.
#
# Usage (from repo root):
#   tclsh examples/baremetal/render_fb.tcl [output.ppm]
#
# If main.s is absent it is regenerated via:
#   pak explain --backend mips examples/baremetal/main.pk64

set here [file join [pwd] [file dirname [info script]]]
set repo [file dirname [file dirname $here]]
source [file join $repo tcl mips_sim.tcl]

proc slurp {p} { set f [open $p r]; set d [read $f]; close $f; return $d }

# ── locate / generate main.s ─────────────────────────────────────────────────

set asm_path [file join $here main.s]
if {![file exists $asm_path]} {
    set pk [file join $here main.pk64]
    puts "main.s not found — generating from [file tail $pk]"
    set asm_text [exec pak explain --backend mips $pk]
    set fw [open $asm_path w]; puts $fw $asm_text; close $fw
    puts "wrote [file tail $asm_path]"
} else {
    set asm_text [slurp $asm_path]
}

# ── simulate ─────────────────────────────────────────────────────────────────

set W 320; set H 240
set FB_BASE 0xA0100000
set FB_END  [expr {$FB_BASE + $W * $H * 2}]

puts "simulating [llength [split $asm_text \n]] lines of MIPS assembly..."
set t0 [clock milliseconds]
set sim [pak::mips_sim_run $asm_text main]
set t1 [clock milliseconds]
set n_insns [dict get $sim insns]
puts "executed $n_insns instructions in [expr {$t1 - $t0}] ms"

# ── extract framebuffer pixels ────────────────────────────────────────────────

set mem_h [dict get $sim mem_h]

# collect {pixel_index -> u16} for addresses in the FB region
set fb [dict create]
dict for {addr val} $mem_h {
    if {$addr >= $FB_BASE && $addr < $FB_END && ($addr & 1) == 0} {
        dict set fb [expr {($addr - $FB_BASE) / 2}] $val
    }
}
set npix [dict size $fb]
puts "captured $npix / [expr {$W * $H}] framebuffer pixels"
if {$npix < [expr {$W * $H / 2}]} {
    puts stderr "WARNING: fewer than half the pixels were written — simulation may be incomplete"
}

# ── RGBA5551 → RGB8 helper ────────────────────────────────────────────────────

proc rgba5551_to_rgb8 {px} {
    set r [expr {(($px >> 11) & 0x1F) * 255 / 31}]
    set g [expr {(($px >>  6) & 0x1F) * 255 / 31}]
    set b [expr {(($px >>  1) & 0x1F) * 255 / 31}]
    list $r $g $b
}

# ── write PPM P6 ──────────────────────────────────────────────────────────────

set out_ppm [expr {$argc >= 1 ? [lindex $argv 0] : [file join $here framebuffer.ppm]}]
set f [open $out_ppm wb]
puts $f "P6\n$W $H\n255"
for {set i 0} {$i < $W * $H} {incr i} {
    if {[dict exists $fb $i]} {
        lassign [rgba5551_to_rgb8 [dict get $fb $i]] r g b
    } else {
        set r 0; set g 0; set b 0
    }
    puts -nonewline $f [binary format ccc $r $g $b]
}
close $f
set sz [file size $out_ppm]
puts "wrote [file tail $out_ppm]  (${W}x${H} PPM, $sz bytes)"
