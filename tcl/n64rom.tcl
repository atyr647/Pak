# tcl/n64rom.tcl — build a bootable .z64 from a flat program image, with no
# external tools. Tcl port of pak/tools/rompack.py: 64-byte header, IPL3
# region, program at ROM 0x1000 (linked to run at 0x80000400), padded to a
# full 1 MB CRC window, with CIC-NUS-6102 CRC1/CRC2 patched into the header.
# Pure binary assembly via `binary format`, like pakfs.tcl.
#
# pak::n64rom {prog_bytes title ?ipl3?} -> .z64 bytes
#   prog_bytes : flat image (text+rodata+data) linked to run at 0x80000400
#   title      : up to 20 chars, ROM header name
#   ipl3       : raw IPL3 bytes (up to 0xFC0). Use pak::n64rom_ipl3_from_z64 to
#                lift the IPL3 region out of an existing ROM. "" -> zero IPL3.

namespace eval pak {}
if {[info exists ::pak::_n64rom_loaded]} { return }
set ::pak::_n64rom_loaded 1

set ::pak::ROM_HEADER_SIZE 0x40      ;# 64 bytes
set ::pak::ROM_IPL3_SIZE   0xFC0     ;# 4032 bytes (0x40 .. 0xFFF)
set ::pak::ROM_ENTRY       0x80000400
set ::pak::ROM_CRC_WINDOW  0x100000  ;# CRC covers 1 MB starting at ROM 0x1000

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

proc pak::n64rom {prog_bytes title {ipl3 ""}} {
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
    return $rom
}
