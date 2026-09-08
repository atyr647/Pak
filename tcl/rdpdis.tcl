# tcl/rdpdis.tcl — RDP display-list disassembler.
#
# The standalone runtime builds a list of 64-bit RDP commands in RDRAM and
# hands the DP a start/end pair. Everything about whether a frame is right
# lives in those words, and until now the only way to read them was to stare
# at hex in a test's EXPECTED block.
#
# This turns the stream back into text: one line per command, with the fields
# the encoders in runtime/standalone/runtime.pk64 pack decoded back out.
#
# Public API:
#   pak::rdpdis::disasm words ?base?  -> list of text lines
#     words — list of 32-bit integers, in display-list order
#     base  — byte offset printed for the first word (default 0)
#
# It decodes what it can prove and prints raw hex for what it cannot. The
# combiner mux (SET_COMBINE) is 16 packed fields whose meaning depends on the
# cycle; naming them wrong would be worse than not naming them, so its two
# words are printed raw.

namespace eval pak::rdpdis {}

# Command length in 32-bit words. Everything is two words except the triangles
# (edge coefficients, plus a block per enabled interpolator) and the texture
# rectangles (the rectangle, then the texture coordinate and its steps).
#
#   base edges        8 words
#   + shade          16 words   (opcodes with bit 2 set)
#   + texture        16 words   (opcodes with bit 1 set)
#   + depth           4 words   (opcodes with bit 0 set)
set ::pak::rdpdis::LEN [dict create \
    0x08 8  0x09 12  0x0A 24  0x0B 28 \
    0x0C 24  0x0D 28  0x0E 40  0x0F 44 \
    0x24 4  0x25 4]

set ::pak::rdpdis::NAME [dict create \
    0x00 NOOP \
    0x08 TRIANGLE                0x09 TRIANGLE_Z \
    0x0A TRIANGLE_TEX            0x0B TRIANGLE_TEX_Z \
    0x0C TRIANGLE_SHADE          0x0D TRIANGLE_SHADE_Z \
    0x0E TRIANGLE_SHADE_TEX      0x0F TRIANGLE_SHADE_TEX_Z \
    0x24 TEXTURE_RECTANGLE       0x25 TEXTURE_RECTANGLE_FLIP \
    0x26 SYNC_LOAD               0x27 SYNC_PIPE \
    0x28 SYNC_TILE               0x29 SYNC_FULL \
    0x2A SET_KEY_GB              0x2B SET_KEY_R \
    0x2C SET_CONVERT             0x2D SET_SCISSOR \
    0x2E SET_PRIM_DEPTH          0x2F SET_OTHER_MODES \
    0x30 LOAD_TLUT               0x32 SET_TILE_SIZE \
    0x33 LOAD_BLOCK              0x34 LOAD_TILE \
    0x35 SET_TILE                0x36 FILL_RECTANGLE \
    0x37 SET_FILL_COLOR          0x38 SET_FOG_COLOR \
    0x39 SET_BLEND_COLOR         0x3A SET_PRIM_COLOR \
    0x3B SET_ENV_COLOR           0x3C SET_COMBINE \
    0x3D SET_TEXTURE_IMAGE       0x3E SET_Z_IMAGE \
    0x3F SET_COLOR_IMAGE]

set ::pak::rdpdis::CYCLE  {1CYCLE 2CYCLE COPY FILL}
set ::pak::rdpdis::FMT    {RGBA YUV CI IA I fmt5 fmt6 fmt7}
set ::pak::rdpdis::SIZE   {4bpp 8bpp 16bpp 32bpp}
# cms/cmt are two bits: bit 1 clamp, bit 0 mirror.
set ::pak::rdpdis::WRAP   {wrap mirror clamp "clamp+mirror"}

# SET_OTHER_MODES names the mode register's single bits. The register is 56
# bits wide: the command word carries bits 55-32 in its low 24, and the second
# word is bits 31-0. Bit numbers below are in that 56-bit space, matching the
# shifts the runtime's rdpq_set_other_modes_raw callers use.
set ::pak::rdpdis::MODE_BITS [dict create \
    55 atomic_prim   51 persp_tex_en   50 detail_tex_en  49 sharpen_tex_en \
    48 tex_lod_en    47 en_tlut        46 tlut_type      45 sample_type \
    44 mid_texel     43 bi_lerp0       42 bi_lerp1       41 convert_one \
    40 key_en \
    14 force_blend   13 alpha_cvg_select 12 cvg_times_alpha \
    7  color_on_cvg  6  image_read_en  5  z_update_en    4  z_compare_en \
    3  antialias_en  2  z_source_sel   1  dither_alpha_en 0 alpha_compare_en]

# ── field helpers ────────────────────────────────────────────────────────────

proc pak::rdpdis::bits {v hi lo} {
    return [expr {($v >> $lo) & ((1 << ($hi - $lo + 1)) - 1)}]
}

# Screen coordinates are 10.2 unsigned; texture coordinates in a rectangle are
# s10.5; the steps are s5.10. Printing the raw integer hides an off-by-a-
# quarter-pixel, so each is shown as the real number it encodes.
# Callers extract the field first (screen X/Y are 12 bits, a triangle's YL/YM/
# YH are 14), so this must not re-mask -- doing so silently dropped the top two
# bits of any Y past 1023.75.
proc pak::rdpdis::fx102 {v} { return [format %.2f [expr {$v / 4.0}]] }

# A triangle's YL/YM/YH is a signed 14-bit field (11.2), not the unsigned
# 12-bit field the scissor and rectangles use -- a vertex above the top or
# left of the screen has a genuine negative coordinate, and the RDP's own
# scissor test clips what falls outside the visible range.
proc pak::rdpdis::fx142 {v} {
    set v [expr {$v & 0x3FFF}]
    if {$v >= 0x2000} { set v [expr {$v - 0x4000}] }
    return [format %.2f [expr {$v / 4.0}]]
}

proc pak::rdpdis::s16 {v} {
    set v [expr {$v & 0xFFFF}]
    if {$v >= 0x8000} { set v [expr {$v - 0x10000}] }
    return $v
}
proc pak::rdpdis::fx105 {v} { return [format %.3f [expr {[s16 $v] / 32.0}]] }
proc pak::rdpdis::fx510 {v} { return [format %.3f [expr {[s16 $v] / 1024.0}]] }

proc pak::rdpdis::s32 {v} {
    set v [expr {$v & 0xFFFFFFFF}]
    if {$v >= 0x80000000} { set v [expr {$v - 0x100000000}] }
    return $v
}
# Edge X positions and slopes are s15.16.
proc pak::rdpdis::fx1516 {v} { return [format %.3f [expr {[s32 $v] / 65536.0}]] }

proc pak::rdpdis::name_of {op} {
    variable NAME
    set k [format 0x%02X $op]
    if {[dict exists $NAME $k]} { return [dict get $NAME $k] }
    return [format "UNKNOWN_%02X" $op]
}

proc pak::rdpdis::len_of {op} {
    variable LEN
    set k [format 0x%02X $op]
    if {[dict exists $LEN $k]} { return [dict get $LEN $k] }
    return 2
}

proc pak::rdpdis::pick {lst i} {
    if {$i < [llength $lst]} { return [lindex $lst $i] }
    return $i
}

# ── per-opcode operand decode ────────────────────────────────────────────────

# `words` is the whole command; w0/w1 are its first two.
proc pak::rdpdis::operands {op words} {
    variable CYCLE
    variable FMT
    variable SIZE
    variable WRAP
    variable MODE_BITS

    set w0 [lindex $words 0]
    set w1 [lindex $words 1]

    switch -- $op {
        0x3D - 0x3F {
            # SET_TEXTURE_IMAGE / SET_COLOR_IMAGE share a layout.
            return [format "%s %s width=%d addr=0x%06X" \
                [pick $FMT [bits $w0 23 21]] [pick $SIZE [bits $w0 20 19]] \
                [expr {[bits $w0 9 0] + 1}] [expr {$w1 & 0xFFFFFF}]]
        }
        0x3E { return [format "addr=0x%06X" [expr {$w1 & 0xFFFFFF}]] }

        0x2D {
            return [format "(%s,%s)-(%s,%s)%s" \
                [fx102 [bits $w0 23 12]] [fx102 [bits $w0 11 0]] \
                [fx102 [bits $w1 23 12]] [fx102 [bits $w1 11 0]] \
                [expr {[bits $w1 25 24] ? " interlace" : ""}]]
        }
        0x36 {
            # FILL_RECTANGLE stores the inclusive lower-right first.
            return [format "(%s,%s)-(%s,%s) inclusive" \
                [fx102 [bits $w1 23 12]] [fx102 [bits $w1 11 0]] \
                [fx102 [bits $w0 23 12]] [fx102 [bits $w0 11 0]]]
        }

        0x2F {
            set out [format "cycle=%s" [pick $CYCLE [bits $w0 21 20]]]
            # Reassemble the 56-bit mode register so the bit numbers below are
            # the ones the hardware reference uses: w0's low 24 bits are 55-32,
            # w1 is 31-0.
            set mode [expr {(($w0 & 0xFFFFFF) << 32) | ($w1 & 0xFFFFFFFF)}]
            foreach bit [lsort -integer -decreasing [dict keys $MODE_BITS]] {
                if {($mode >> $bit) & 1} { append out " " [dict get $MODE_BITS $bit] }
            }
            set zmode [bits $w1 11 10]
            if {$zmode} { append out [format " z_mode=%d" $zmode] }
            append out [format " blender=%08X" [expr {$w1 & 0xFFFF0000}]]
            return $out
        }
        0x3C {
            # Sixteen packed mux selects whose meaning depends on the cycle.
            # Printed raw on purpose -- see the note at the top of this file.
            return [format "hi=%06X lo=%08X (raw mux)" [expr {$w0 & 0xFFFFFF}] $w1]
        }

        0x37 {
            # In 16bpp fill the register holds two adjacent RGBA5551 pixels.
            set hi [expr {($w1 >> 16) & 0xFFFF}]
            set lo [expr {$w1 & 0xFFFF}]
            if {$hi == $lo} { return [format "RGBA5551 0x%04X (both pixels)" $hi] }
            return [format "0x%08X (pixels 0x%04X 0x%04X)" $w1 $hi $lo]
        }
        0x38 - 0x39 - 0x3A - 0x3B { return [format "RGBA8888 0x%08X" $w1] }

        0x2E {
            return [format "z=%d dz=%d" [expr {($w1 >> 16) & 0xFFFF}] [expr {$w1 & 0xFFFF}]]
        }
        0x2C {
            # Six 9-bit two's-complement YUV coefficients, k2 split across the
            # two words: its top four bits end w0, its low five start w1.
            set k0 [bits $w0 21 13]
            set k1 [bits $w0 12 4]
            set k2 [expr {(([bits $w0 3 0]) << 5) | [bits $w1 31 27]}]
            set k3 [bits $w1 26 18]
            set k4 [bits $w1 17 9]
            set k5 [bits $w1 8 0]
            set ks {}
            foreach k [list $k0 $k1 $k2 $k3 $k4 $k5] {
                lappend ks [expr {$k >= 256 ? $k - 512 : $k}]
            }
            return "k0..k5 = [join $ks {, }]"
        }
        0x2B {
            return [format "width=%d center=%d scale=%d" \
                [bits $w1 27 16] [bits $w1 15 8] [bits $w1 7 0]]
        }
        0x2A {
            return [format "width_g=%d width_b=%d center_g=%d scale_g=%d center_b=%d scale_b=%d" \
                [bits $w0 23 12] [bits $w0 11 0] \
                [bits $w1 31 24] [bits $w1 23 16] [bits $w1 15 8] [bits $w1 7 0]]
        }

        0x35 {
            set cms [expr {([bits $w1 9 9] << 1) | [bits $w1 8 8]}]
            set cmt [expr {([bits $w1 19 19] << 1) | [bits $w1 18 18]}]
            return [format "tile=%d %s %s line=%d tmem=0x%03X pal=%d S:%s mask=%d T:%s mask=%d" \
                [bits $w1 26 24] [pick $FMT [bits $w0 23 21]] [pick $SIZE [bits $w0 20 19]] \
                [bits $w0 17 9] [bits $w0 8 0] [bits $w1 23 20] \
                [pick $WRAP $cms] [bits $w1 7 4] [pick $WRAP $cmt] [bits $w1 17 14]]
        }
        0x32 - 0x34 {
            # SET_TILE_SIZE and LOAD_TILE share a layout; both store the
            # inclusive far corner, so the exclusive size is one more.
            set s0 [bits $w0 23 12]; set t0 [bits $w0 11 0]
            set s1 [bits $w1 23 12]; set t1 [bits $w1 11 0]
            return [format "tile=%d S %s..%s T %s..%s (%dx%d texels)" \
                [bits $w1 26 24] [fx102 $s0] [fx102 $s1] [fx102 $t0] [fx102 $t1] \
                [expr {($s1 - $s0) / 4 + 1}] [expr {($t1 - $t0) / 4 + 1}]]
        }
        0x33 {
            return [format "tile=%d s0=%d t0=%d texels=%d dxt=%d" \
                [bits $w1 26 24] [bits $w0 23 12] [bits $w0 11 0] \
                [expr {[bits $w1 23 12] + 1}] [bits $w1 11 0]]
        }
        0x30 {
            return [format "tile=%d first=%d last=%d" \
                [bits $w1 26 24] [expr {[bits $w0 23 12] / 4}] [expr {[bits $w1 23 12] / 4}]]
        }

        0x24 - 0x25 {
            set w2 [lindex $words 2]
            set w3 [lindex $words 3]
            return [format "tile=%d (%s,%s)-(%s,%s) s=%s t=%s dsdx=%s dtdy=%s" \
                [bits $w1 26 24] \
                [fx102 [bits $w1 23 12]] [fx102 [bits $w1 11 0]] \
                [fx102 [bits $w0 23 12]] [fx102 [bits $w0 11 0]] \
                [fx105 [expr {($w2 >> 16) & 0xFFFF}]] [fx105 [expr {$w2 & 0xFFFF}]] \
                [fx510 [expr {($w3 >> 16) & 0xFFFF}]] [fx510 [expr {$w3 & 0xFFFF}]]]
        }

        default {
            if {$op >= 0x08 && $op <= 0x0F} {
                return [format "%s YL=%s YM=%s YH=%s" \
                    [expr {[bits $w0 23 23] ? "left" : "right"}] \
                    [fx142 [bits $w0 13 0]] \
                    [fx142 [expr {($w1 >> 16) & 0x3FFF}]] [fx142 [expr {$w1 & 0x3FFF}]]]
            }
            if {$op >= 0x26 && $op <= 0x29} { return "" }
            return ""
        }
    }
}

# The three edge slope pairs every triangle carries after its header, then
# whichever coefficient blocks the opcode turns on. Named so a wrong shade or
# texture block is visible instead of being 16 words of hex.
proc pak::rdpdis::tri_extra_labels {op} {
    set out {"XL / DxLDy" "XH / DxHDy" "XM / DxMDy"}
    if {$op & 4} {
        lappend out "RGBA           int" "RGBA  DxDx     int" \
                    "RGBA          frac" "RGBA  DxDx    frac" \
                    "RGBA  DxDe     int" "RGBA  DxDy     int" \
                    "RGBA  DxDe    frac" "RGBA  DxDy    frac"
    }
    if {$op & 2} {
        lappend out "STW            int" "STW   DxDx     int" \
                    "STW           frac" "STW   DxDx    frac" \
                    "STW   DxDe     int" "STW   DxDy     int" \
                    "STW   DxDe    frac" "STW   DxDy    frac"
    }
    if {$op & 1} {
        lappend out "Z / DzDx" "DzDe / DzDy"
    }
    return $out
}

# ── the disassembler ─────────────────────────────────────────────────────────

proc pak::rdpdis::disasm {words {base 0}} {
    set out {}
    set n [llength $words]
    set i 0
    while {$i < $n} {
        set w0 [expr {[lindex $words $i] & 0xFFFFFFFF}]
        set op [expr {($w0 >> 24) & 0x3F}]
        set len [len_of $op]

        # A command running past the end of the captured list is not a command;
        # say so rather than decoding whatever follows as operands.
        if {$i + $len > $n} {
            lappend out [format "+%04X  %08X           <truncated: %s needs %d words, %d left>" \
                [expr {$base + $i * 4}] $w0 [name_of $op] $len [expr {$n - $i}]]
            break
        }

        set cmd {}
        for {set k 0} {$k < $len} {incr k} {
            lappend cmd [expr {[lindex $words [expr {$i + $k}]] & 0xFFFFFFFF}]
        }

        lappend out [string trimright [format "+%04X  %08X %08X  %-22s %s" \
            [expr {$base + $i * 4}] [lindex $cmd 0] [lindex $cmd 1] \
            [name_of $op] [operands [format 0x%02X $op] $cmd]]]

        # Trailing doublewords: labelled for triangles, raw for the texture
        # rectangles (their two extra words are already in the operand line).
        if {$op >= 0x08 && $op <= 0x0F} {
            set labels [tri_extra_labels $op]
            set li 0
            for {set k 2} {$k < $len} {incr k 2} {
                set lbl [expr {$li < [llength $labels] ? [lindex $labels $li] : ""}]
                # The three edge pairs are an X position and a slope, both
                # s15.16. Left in hex they say nothing; a wrong slope is the
                # difference between a triangle and a sliver.
                if {$li < 3} {
                    append lbl [format "   X=%s  dX/dY=%s" \
                        [fx1516 [lindex $cmd $k]] \
                        [fx1516 [lindex $cmd [expr {$k + 1}]]]]
                }
                lappend out [string trimright [format "+%04X  %08X %08X  %-22s %s" \
                    [expr {$base + ($i + $k) * 4}] \
                    [lindex $cmd $k] [lindex $cmd [expr {$k + 1}]] "" $lbl]]
                incr li
            }
        } elseif {$len > 2} {
            for {set k 2} {$k < $len} {incr k 2} {
                lappend out [format "+%04X  %08X %08X" \
                    [expr {$base + ($i + $k) * 4}] \
                    [lindex $cmd $k] [lindex $cmd [expr {$k + 1}]]]
            }
        }

        incr i $len
    }
    return $out
}

# Convenience: a binary string of big-endian words, as the simulator captures a
# DP kick, straight to text.
proc pak::rdpdis::disasm_bytes {bytes {base 0}} {
    binary scan $bytes I* words
    if {![info exists words]} { set words {} }
    return [disasm $words $base]
}
