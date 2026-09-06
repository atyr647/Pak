#!/usr/bin/env tclsh
# Read assets out of the ROM, in the MIPS simulator.
#
# `pak link --fs` appends a PakFS archive to the ROM and patches its offset
# into two runtime statics; runtime/standalone/runtime.pk64 reads the index
# over PI and hands back file bytes. Nothing else exercises that path: the
# link gate proves the symbols resolve, and the ares gate draws what is
# already in RDRAM. Here the simulator plays the cartridge, so a wrong offset,
# a byte swapped for a big-endian one, or an index walked with the wrong
# stride shows up as a wrong answer rather than a black screen.

set HERE [file dirname [file normalize [info script]]]
source [file join $HERE .. parser.tcl]
source [file join $HERE .. mips_codegen.tcl]
source [file join $HERE .. optimize.tcl]
source [file join $HERE .. mips_sim.tcl]
source [file join $HERE .. pakfs.tcl]

set pass 0
set fail 0

# The whole runtime goes in front of each program. Not a slice of it: the
# asset reader calls PI DMA, which writes back the D-cache, which is inline
# asm near the top of the file -- and a `jal` to a name no label defines just
# ends the simulator's run, which reads as "every answer is zero".
proc runtime_src {} {
    set f [open [file join $::HERE .. .. runtime standalone runtime.pk64] r]
    set rt [read $f]
    close $f
    return $rt
}

# An 8x8 RGBA16 sprite in libdragon's uncompressed layout: width, height,
# bitdepth, flags (format in the low 5 bits; 2 is RGBA16), hslices, vslices,
# then the texels. Pixel (x, y) is 0x0800 + y*16 + x so a wrong row stride is
# visible in the value.
proc make_sprite {w h} {
    set s [binary format SScccc $w $h 0 0x02 1 1]
    for {set y 0} {$y < $h} {incr y} {
        for {set x 0} {$x < $w} {incr x} {
            append s [binary format S [expr {0x0800 + $y * 16 + $x}]]
        }
    }
    return $s
}

# A cartridge image with the archive at $off, which is what the simulator
# reads through PI DMA.
proc make_cart {off archive} {
    return "[string repeat "\x00" $off]$archive"
}

set ROM_OFF 0x00101000

proc run_prog {src archive syms} {
    set full "[runtime_src]\n$src"
    set lx [pak::Lexer new $full]
    set ast [pak::parse_tokens [$lx tokenize]]
    set recs [pak::optimize_records [pak::mips_generate_records $ast]]
    set cart [make_cart $::ROM_OFF $archive]
    set run [pak::mips_sim_run [pak::records_to_asm $recs] main 4000000 {} $cart]
    set out [dict create]
    foreach s $syms {
        set a [dict get [dict get $run data_syms] $s]
        set mw [dict get $run mem_w]
        dict set out $s [expr {[dict exists $mw $a] ? [dict get $mw $a] : "<unwritten>"}]
    }
    return $out
}

proc chk {what src archive sym want} {
    if {[catch {set got [dict get [run_prog $src $archive [list $sym]] $sym]} err]} {
        puts "FAIL  $what -- $err"
        incr ::fail
        return
    }
    if {$got eq $want} {
        puts "ok    $what = $got"
        incr ::pass
    } else {
        puts "FAIL  $what = $got (want $want)"
        incr ::fail
    }
}

# Every program mounts the archive by hand, because in a real ROM the linker
# patches these two -- there is no linker here.
set MOUNT "    g_pakfs_rom = 0x10101000\n    g_pakfs_len = ARCHIVE_LEN\n"

proc prog {body archive} {
    set n [string length $archive]
    return "static out: i32 = 0\nentry \{\n    g_pakfs_rom = 0x10101000\n    g_pakfs_len = $n\n$body\n\}"
}

set spr [make_sprite 8 8]
set arch [pak::pakfs_pack [list [list "sprites/hero.sprite" $spr] \
                                [list "sprites/other.sprite" [make_sprite 4 2]]]]

puts "== the archive index =="

chk "a name in the archive is found" [prog {
    let p: u32 = pakfs_find("sprites/hero.sprite")
    if p != 0 { out = 1 }
} $arch] $arch out 1

chk "a name that is not there is not found" [prog {
    out = 5
    let p: u32 = pakfs_find("sprites/nope.sprite")
    if p == 0 { out = 7 }
} $arch] $arch out 7

chk "the size comes back with it" [prog {
    out = pakfs_size("sprites/hero.sprite")
} $arch] $arch out [string length $spr]

chk "the second entry is walked to correctly" [prog {
    out = pakfs_size("sprites/other.sprite")
} $arch] $arch out [string length [make_sprite 4 2]]

# The generated code spells asset paths with libdragon's scheme; the archive
# names do not carry it.
chk "the pak:/ scheme is stripped" [prog {
    out = pakfs_size("pak:/sprites/hero.sprite")
} $arch] $arch out [string length $spr]

puts ""
puts "== the bytes actually arrive =="

chk "sprite_load reads the header" [prog {
    let s: *u8 = sprite_load("sprites/hero.sprite")
    if s != none { out = sprite_width(s) * 100 + sprite_height(s) }
} $arch] $arch out 808

chk "a second sprite has its own size" [prog {
    let s: *u8 = sprite_load("sprites/other.sprite")
    if s != none { out = sprite_width(s) * 100 + sprite_height(s) }
} $arch] $arch out 402

# Texel (3, 5) is 0x0800 + 5*16 + 3 = 0x0853. Reading it proves the whole file
# came across, not just the first block, and that nothing byte-swapped it.
chk "a texel deep in the file is intact" [prog {
    let s: *u8 = sprite_load("sprites/hero.sprite")
    out = 0
    if s != none {
        let px: u32 = (s as u32) + 8 + ((5 * 8 + 3) * 2) as u32
        out = pakfs_be16(px)
    }
} $arch] $arch out [expr {0x0800 + 5 * 16 + 3}]

chk "loading what is not there gives none" [prog {
    out = 3
    let s: *u8 = sprite_load("sprites/nope.sprite")
    if s == none { out = 9 }
} $arch] $arch out 9

puts ""
puts "== a ROM with no archive =="

# g_pakfs_len is zero in a ROM built without --fs. That has to read as "no
# assets", not as a mount failure part-way through a garbage index.
chk "no archive means every lookup misses" {
static out: i32 = 0
entry {
    out = 4
    if pakfs_find("sprites/hero.sprite") == 0 { out = 6 }
}
} $arch out 6

puts ""
puts "PASS=$pass  FAIL=$fail"
exit [expr {$fail > 0 ? 1 : 0}]
