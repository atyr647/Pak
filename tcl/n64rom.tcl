# tcl/n64rom.tcl — build a bootable .z64 from a flat program image, with no
# external tools. Embeds an open-source IPL3 (libdragon/Rasky) for real-hardware
# boot; on HLE emulators the program at ROM 0x1000 (linked to 0x80000400) is
# loaded directly. Pure binary assembly via `binary format`, like pakfs.tcl.
#
# pak::n64rom {prog_bytes title ipl3_path} -> .z64 bytes
#   prog_bytes : flat image (text+rodata+data) linked to run at 0x80000400
#   title      : up to 20 chars, ROM header name
#   ipl3_path  : path to an open IPL3 .z64 (first 0x1000 bytes = header+IPL3);
#                we reuse its IPL3 region (0x40..0xFFF). "" -> zero IPL3.

namespace eval pak {}
if {[info exists ::pak::_n64rom_loaded]} { return }
set ::pak::_n64rom_loaded 1

proc pak::n64rom {prog_bytes title {ipl3_path ""}} {
    set ENTRY 0x80000400

    # ── Header (0x40 bytes), big-endian (.z64) ────────────────────────────────
    set hdr [binary format I 0x80371240]          ;# PI/endianness config (.z64)
    append hdr [binary format I 0x0000000F]        ;# clock rate
    append hdr [binary format I $ENTRY]            ;# boot/entry address
    append hdr [binary format I 0x00001444]        ;# libultra/release (arbitrary)
    append hdr [binary format I 0x00000000]        ;# CRC1 (unchecked by HLE emus)
    append hdr [binary format I 0x00000000]        ;# CRC2
    append hdr [binary format II 0 0]              ;# reserved (8 bytes)
    # title: 20 bytes, space-padded (0x20..0x33)
    set t [string range $title 0 19]
    append hdr [binary format a20 [format %-20s $t]]
    # 0x34..0x3F (12 bytes): reserved(7) + media/cart-id/region/version
    append hdr [binary format I 0]                 ;# 0x34 reserved (4)
    append hdr [binary format I 0]                 ;# 0x38 reserved (4)
    append hdr [binary format I 0]                 ;# 0x3C cart id/region/ver (4)
    # hdr is now exactly 0x40 (64) bytes

    # ── IPL3 region (0x40..0xFFF = 0xFC0 bytes) ───────────────────────────────
    set ipl3 [string repeat "\x00" 0xFC0]
    if {$ipl3_path ne "" && [file exists $ipl3_path]} {
        set f [open $ipl3_path rb]; set blob [read $f]; close $f
        if {[string length $blob] >= 0x1000} {
            set ipl3 [string range $blob 0x40 0xFFF]   ;# reuse its IPL3 bytes
        }
    }

    # ── Assemble ROM: header + IPL3 + program @ 0x1000 ────────────────────────
    set rom $hdr
    append rom $ipl3
    append rom $prog_bytes
    # Pad to a 2-byte boundary at least; many emulators want >= a minimum size.
    set len [string length $rom]
    set minlen [expr {1 << 19}]   ;# 512 KiB minimum, generous
    if {$len < $minlen} { append rom [string repeat "\x00" [expr {$minlen - $len}]] }
    return $rom
}
