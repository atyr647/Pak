# tcl/n64rom.tcl — build a bootable .z64 from a flat program image, with no
# external tools: 64-byte header, IPL3 region, program at ROM 0x1000 (linked
# to run at 0x80000400), CIC-NUS-6102 CRC1/CRC2, padded to a 4/8/16/32/64 MiB
# cart (default 4 MiB). A 2.9 MB image crashes on flashcarts.
#
# pak::n64rom {prog_bytes title ?ipl3? ?rom_size?} -> .z64 bytes
#   prog_bytes : flat image (text+rodata+data) linked to run at 0x80000400
#   title      : up to 20 chars, ROM header name
#   ipl3       : raw IPL3 bytes (up to 0xFC0). Use pak::n64rom_ipl3_from_z64 to
#                lift the IPL3 region out of an existing ROM. "" -> zero IPL3.
#   rom_size   : final cart size in bytes; must be 4/8/16/32/64 MiB. Default 4 MiB.
#                If the image is larger, the next valid size is chosen. CRC1/CRC2
#                are computed over the 1 MB window at ROM 0x1000 *before* the
#                cart-size pad, so extra zeros do not change the checksum.

namespace eval pak {}
if {[info exists ::pak::_n64rom_loaded]} { return }
set ::pak::_n64rom_loaded 1

set ::pak::ROM_HEADER_SIZE 0x40      ;# 64 bytes
set ::pak::ROM_IPL3_SIZE   0xFC0     ;# 4032 bytes (0x40 .. 0xFFF)
set ::pak::ROM_ENTRY       0x80000400
set ::pak::ROM_CRC_WINDOW  0x100000  ;# CRC covers 1 MB starting at ROM 0x1000
# Flash RAM carts EverDrive / SummerCart64 / flashcarts expect a power-of-two
# size. A 2.9 MB image will crash on hardware; pad to 4/8/16/32/64 MiB.
set ::pak::ROM_VALID_SIZES [list 0x400000 0x800000 0x1000000 0x2000000 0x4000000]
set ::pak::ROM_DEFAULT_SIZE 0x400000

# ── CIC-NUS-6102 / 7101 CRC ─────────────────────────────────────────────────

proc pak::rom_ror32 {v b} {
    set b [expr {$b & 31}]
    if {$b == 0} { return [expr {$v & 0xFFFFFFFF}] }
    return [expr {(($v >> $b) | ($v << (32 - $b))) & 0xFFFFFFFF}]
}

# Returns {crc1 crc2} over the 1 MB region starting at ROM offset 0x1000.
proc pak::n64_crc {rom} {
    set SEED 0xF8CA4DDC
    set M 0xFFFFFFFF
    set t1 $SEED; set t2 $SEED; set t3 $SEED
    set t4 $SEED; set t5 $SEED; set t6 $SEED

    # Read the window once into a word list; scanning per-iteration is far too
    # slow for 256K words.
    set window [string range $rom 0x1000 [expr {0x1000 + $::pak::ROM_CRC_WINDOW - 1}]]
    set have [expr {[string length $window] / 4}]
    binary scan $window Iu* words

    set nwords [expr {$::pak::ROM_CRC_WINDOW / 4}]
    for {set i 0} {$i < $nwords} {incr i} {
        if {$i < $have} { set d [lindex $words $i] } else { set d 0 }

        set old_t6 $t6
        set t6 [expr {($t6 + $d) & $M}]
        if {$t6 < $old_t6} { set t4 [expr {($t4 + 1) & $M}] }

        set t3 [expr {($t3 ^ $d) & $M}]
        set r [pak::rom_ror32 $d [expr {$d & 31}]]
        set t5 [expr {($t5 + $r) & $M}]

        if {$t2 > $d} {
            set t2 [expr {($t2 ^ $r) & $M}]
        } else {
            set t2 [expr {($t2 ^ ($t6 ^ $d)) & $M}]
        }

        set t1 [expr {($t1 + (($i & 0xFF) ^ $d)) & $M}]
    }

    return [list [expr {($t6 ^ $t4 ^ $t3) & $M}] [expr {($t5 ^ $t2 ^ $t1) & $M}]]
}

# ── Header ───────────────────────────────────────────────────────────────────

# 64-byte N64 ROM header. CRC fields are left zero; pak::n64rom patches them
# once the full image exists.
proc pak::n64rom_header {title {boot_addr ""}} {
    if {$boot_addr eq ""} { set boot_addr $::pak::ROM_ENTRY }
    set hdr [binary format I 0x80371240]     ;# PI BSD config / .z64 endianness
    append hdr [binary format I 0x000F0000]  ;# clock rate (default)
    append hdr [binary format I $boot_addr]  ;# PC on entry
    append hdr [binary format I 0]           ;# release
    append hdr [binary format I 0]           ;# CRC1 — patched later
    append hdr [binary format I 0]           ;# CRC2 — patched later
    append hdr [binary format II 0 0]        ;# unknown (bytes 24-31)
    # Game name: 20 bytes, space-padded ASCII (0x20..0x33)
    append hdr [binary format a20 [format %-20s [string range $title 0 19]]]
    append hdr [binary format I 0]           ;# 0x34 manufacturer + game code
    # 0x38: media type 0x00, cart 'N', cart id 'P', 'K'
    append hdr [binary format cccc 0x00 0x4E 0x50 0x4B]
    # 0x3C: country 'E' (US/NTSC), mask ROM version, pad
    append hdr [binary format cccc 0x45 0x00 0x00 0x00]
    return $hdr
}

# Lift the IPL3 region (0x40..0xFFF) out of an existing .z64, for real-hardware
# boot. Returns "" if the file is missing or too short.
proc pak::n64rom_ipl3_from_z64 {path} {
    if {$path eq "" || ![file exists $path]} { return "" }
    set f [open $path rb]
    set blob [read $f]
    close $f
    if {[string length $blob] < 0x1000} { return "" }
    return [string range $blob 0x40 0xFFF]
}

# ── ROM assembly ─────────────────────────────────────────────────────────────

# The bootcode shipped with Pak: libdragon's IPL3, compat build, public domain.
# See runtime/standalone/ipl3_compat.README.md. Returns "" if the file is
# missing, which leaves the region zeroed -- a ROM that cannot boot, but a
# `pak link` that still tells you what it produced.
# Where this file lives, captured at load time -- `info script` inside a proc
# names whatever is being sourced when the proc runs, not where it was written.
set ::pak::_n64rom_dir [file dirname [file normalize [info script]]]

proc pak::n64rom_default_ipl3 {} {
    # Located from this file rather than from $::pak::CLI_ROOT: the packer is
    # sourced directly by tests and tools that never set that global, and a
    # missing bootcode is not something to discover as an empty string.
    set root [file dirname $::pak::_n64rom_dir]
    if {[info exists ::pak::CLI_ROOT]} { set root $::pak::CLI_ROOT }
    set f [file join $root runtime standalone ipl3_compat.bin]
    if {![file exists $f]} { return "" }
    set fh [open $f rb]; set d [read $fh]; close $fh
    return $d
}

proc pak::n64rom {prog_bytes title {ipl3 ""} {rom_size ""}} {
    if {[string length $ipl3] > $::pak::ROM_IPL3_SIZE} {
        set ipl3 [string range $ipl3 0 [expr {$::pak::ROM_IPL3_SIZE - 1}]]
    }
    append ipl3 [string repeat "\x00" \
        [expr {$::pak::ROM_IPL3_SIZE - [string length $ipl3]}]]

    set rom [pak::n64rom_header $title]
    append rom $ipl3
    append rom $prog_bytes

    # Pad to a word boundary, then out to a full CRC window so CRC1/CRC2 are
    # computed over deterministic bytes.
    set len [string length $rom]
    if {$len % 4} { append rom [string repeat "\x00" [expr {4 - ($len % 4)}]] }
    set minlen [expr {0x1000 + $::pak::ROM_CRC_WINDOW}]
    set len [string length $rom]
    if {$len < $minlen} { append rom [string repeat "\x00" [expr {$minlen - $len}]] }

    lassign [pak::n64_crc $rom] crc1 crc2
    set rom [string replace $rom 16 23 [binary format II $crc1 $crc2]]

    # libdragon's compat IPL3 reads the payload size from 0x10, the field a
    # conventional ROM uses for CRC1. It does not check the header CRC -- the
    # CIC checks the IPL3, not the header -- and given a zero or out-of-range
    # value it falls back to copying a flat 1 MiB, which truncates any image
    # larger than that. So the size goes in, after the CRC is computed over
    # the real bytes. CRC2 at 0x14 is left alone.
    set payload [expr {[string length $prog_bytes]}]
    set rom [string replace $rom 16 19 [binary format I $payload]]

    # Cart-size pad. Flashcarts (and FZ) crash on a 2.9 MB image; only
    # 4/8/16/32/64 MiB are valid. CRC is already baked and does not cover this.
    if {$rom_size eq ""} { set rom_size $::pak::ROM_DEFAULT_SIZE }
    set rom_size [expr {$rom_size}]
    set ok 0
    foreach s $::pak::ROM_VALID_SIZES {
        if {$rom_size == $s} { set ok 1; break }
    }
    if {!$ok} {
        return -code error "ROM size $rom_size is not 4/8/16/32/64 MiB"
    }
    set len [string length $rom]
    if {$len > $rom_size} {
        set chosen ""
        foreach s $::pak::ROM_VALID_SIZES {
            if {$s >= $len} { set chosen $s; break }
        }
        if {$chosen eq ""} {
            return -code error "ROM image ([expr {$len}] bytes) exceeds 64 MiB"
        }
        set rom_size $chosen
    }
    if {$len < $rom_size} {
        append rom [string repeat "\x00" [expr {$rom_size - $len}]]
    }
    return $rom
}
