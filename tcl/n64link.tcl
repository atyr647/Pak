# tcl/n64link.tcl — minimal static linker for Pak ".pakobj" object files.
#
# There is NO MIPS toolchain and NO ELF
# involved: this combines relocatable object files (the text format the
# encoder emits) into a flat N64 RDRAM image laid out exactly like
# runtime/standalone/n64.ld, which tcl/n64rom.tcl then packs into a .z64.
#
# Object file format (line oriented text)
#     # pak object v1            -- comments and blank lines ignored
#     section .text              -- start/continue a section
#     sym main 0                 -- symbol NAME at BYTEOFFSET within this
#                                   object's contribution to the section
#     reloc 16 R_MIPS_26 printf  -- fixup at BYTEOFFSET, KIND, target SYMBOL
#     data 27bdff00 afbf00fc     -- raw big-endian 32-bit words (8 hex chars)
#     space 64                   -- reserve N zero bytes (.bss style)
#
# Sections concatenate in a fixed order: .text, .rodata, .data, .bss. Within a
# section, objects concatenate in argument order (the boot object first, so
# _start lands at the base address).
#
# Public API:
#   pak::link_objects paths ?entry?  -> dict {image symbols base
#                                             section_bases section_sizes}
#     image          — flat binary string [.text | pad16 | .rodata | pad8 | .data]
#     symbols        — dict {name -> final virtual address}
#     section_bases  — dict {section -> virtual base address}
#     section_sizes  — dict {section -> size in bytes}
# Errors are raised with a "LINKERROR\t<message>" payload.

namespace eval pak {}
if {[info exists ::pak::_n64link_loaded]} { return }
set ::pak::_n64link_loaded 1

set ::pak::LINK_BASE_ADDR 0x80000400

# Standalone RDRAM map (cached KSEG0). Uncached KSEG1 is these | 0xA0000000.
# Layout, low to high:
#   0x80000000 vectors (boot.S copies a trampoline here at runtime)
#   .text / .rodata / .data / .bss | 64-byte gap | FB0 FB1 FB2 | Z | DL | PCM | heap | stack
# Framebuffers, Z, the RDP display list, heap and stack are NOT relocatable: the
# runtime hard-codes the same numbers. The linker refuses to place a section
# that would collide with them.
set ::pak::MEM_GAP           64
set ::pak::MEM_FB0           0x80200000
set ::pak::MEM_FB_SIZE       0x25800          ;# 320 * 240 * 2
set ::pak::MEM_FB_COUNT      3
set ::pak::MEM_ZB            0x80271000
set ::pak::MEM_ZB_SIZE       0x25800
set ::pak::MEM_DL_BASE       0x80297000
set ::pak::MEM_DL_SIZE       8192
set ::pak::MEM_AB_BASE       0x80299000
set ::pak::MEM_AB_SIZE       0x7000          ;# PCM ring, up to 8 buffers
set ::pak::MEM_HEAP_BASE     0x802A0000
set ::pak::MEM_HEAP_LIMIT    0x803C0000
set ::pak::MEM_STACK_TOP     0x80400000
# FB2 ends at 0x80270800; 64-byte gap then Z at 0x80271000 (matches runtime).
# Z is 320×240×16-bit (0x25800), then DL at 0x80297000, PCM at 0x80299000.

# Fixed section order, and the alignment applied BEFORE each section is placed
# (matching n64.ld's ALIGN directives). .text starts at the already-16-aligned
# base, so it needs no extra alignment of its own.
set ::pak::LINK_SECTION_ORDER {.text .rodata .data .bss}
set ::pak::LINK_SECTION_ALIGN [dict create .text 1 .rodata 16 .data 8 .bss 8]
set ::pak::LINK_RELOC_KINDS {R_MIPS_26 R_MIPS_HI16 R_MIPS_LO16 R_MIPS_32}

proc pak::link_error {msg} { return -code error "LINKERROR\t$msg" }

proc pak::link_align_up {value alignment} {
    if {$alignment <= 1} { return $value }
    return [expr {($value + $alignment - 1) & ~($alignment - 1)}]
}

# ── Parsing ──────────────────────────────────────────────────────────────────

# Returns dict {path P sections {SEC -> {data D symbols {N->off} relocs {{off kind sym}}}}}
proc pak::parse_object_text {text {path <string>}} {
    set sections [dict create]
    set cur ""
    set lineno 0

    foreach raw [split $text "\n"] {
        incr lineno
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} continue
        set parts [regexp -all -inline {\S+} $line]
        set kw [lindex $parts 0]

        if {$kw eq "section"} {
            if {[llength $parts] != 2} {
                pak::link_error "$path:$lineno: 'section' needs exactly one name"
            }
            set name [lindex $parts 1]
            if {$name ni $::pak::LINK_SECTION_ORDER} {
                pak::link_error "$path:$lineno: unknown section '$name'"
            }
            if {![dict exists $sections $name]} {
                dict set sections $name [dict create data "" symbols {} relocs {}]
            }
            set cur $name
            continue
        }

        if {$cur eq ""} {
            pak::link_error "$path:$lineno: directive '$kw' before any 'section'"
        }

        switch -- $kw {
            sym {
                if {[llength $parts] != 3} {
                    pak::link_error "$path:$lineno: 'sym' needs NAME OFFSET"
                }
                set name [lindex $parts 1]
                set off [lindex $parts 2]
                if {![string is integer -strict $off]} {
                    pak::link_error "$path:$lineno: bad sym offset '$off'"
                }
                if {[dict exists $sections $cur symbols $name]} {
                    pak::link_error "$path:$lineno: duplicate local symbol '$name' in section $cur"
                }
                dict set sections $cur symbols $name [expr {$off}]
            }
            reloc {
                if {[llength $parts] != 4} {
                    pak::link_error "$path:$lineno: 'reloc' needs OFFSET KIND SYMBOL"
                }
                lassign [lrange $parts 1 3] off kind symbol
                if {![string is integer -strict $off]} {
                    pak::link_error "$path:$lineno: bad reloc offset '$off'"
                }
                if {$kind ni $::pak::LINK_RELOC_KINDS} {
                    pak::link_error "$path:$lineno: unknown reloc kind '$kind'"
                }
                set rl [dict get $sections $cur relocs]
                lappend rl [list [expr {$off}] $kind $symbol]
                dict set sections $cur relocs $rl
            }
            data {
                set blob ""
                foreach tok [lrange $parts 1 end] {
                    if {[string length $tok] != 8} {
                        pak::link_error "$path:$lineno: data word '$tok' must be 8 hex chars"
                    }
                    if {![regexp {^[0-9a-fA-F]{8}$} $tok]} {
                        pak::link_error "$path:$lineno: bad data word '$tok'"
                    }
                    append blob [binary format H8 $tok]
                }
                dict set sections $cur data [string cat [dict get $sections $cur data] $blob]
            }
            space {
                if {[llength $parts] != 2} {
                    pak::link_error "$path:$lineno: 'space' needs a byte count"
                }
                set n [lindex $parts 1]
                if {![string is integer -strict $n]} {
                    pak::link_error "$path:$lineno: bad space count '$n'"
                }
                dict set sections $cur data [string cat [dict get $sections $cur data] \
                    [string repeat "\x00" [expr {$n}]]]
            }
            default {
                pak::link_error "$path:$lineno: unknown directive '$kw'"
            }
        }
    }
    return [dict create path $path sections $sections]
}

proc pak::parse_object {path} {
    set f [open $path rb]
    set text [read $f]
    close $f
    return [pak::parse_object_text $text $path]
}

# ── Relocation application ───────────────────────────────────────────────────

proc pak::link_read_word {bufvar off} {
    upvar 1 $bufvar buf
    binary scan [string range $buf $off [expr {$off + 3}]] Iu w
    return $w
}

proc pak::link_write_word {bufvar off word} {
    upvar 1 $bufvar buf
    set w [expr {$word & 0xFFFFFFFF}]
    set buf [string replace $buf $off [expr {$off + 3}] [binary format I $w]]
}

proc pak::link_apply_reloc {bufvar off kind S where} {
    upvar 1 $bufvar buf
    if {$off + 4 > [string length $buf]} {
        pak::link_error "$where: reloc offset $off out of range"
    }
    switch -- $kind {
        R_MIPS_32 {
            pak::link_write_word buf $off $S
        }
        R_MIPS_26 {
            set word [pak::link_read_word buf $off]
            set target [expr {($S >> 2) & 0x03FFFFFF}]
            pak::link_write_word buf $off [expr {($word & 0xFC000000) | $target}]
        }
        R_MIPS_HI16 {
            set word [pak::link_read_word buf $off]
            set hi [expr {(($S + 0x8000) >> 16) & 0xFFFF}]
            pak::link_write_word buf $off [expr {($word & 0xFFFF0000) | $hi}]
        }
        R_MIPS_LO16 {
            set word [pak::link_read_word buf $off]
            set lo [expr {$S & 0xFFFF}]
            pak::link_write_word buf $off [expr {($word & 0xFFFF0000) | $lo}]
        }
        default {
            pak::link_error "$where: unknown reloc kind '$kind'"
        }
    }
}

# ── Linker core ──────────────────────────────────────────────────────────────

proc pak::link_parsed_objects {objects {entry _start}} {
    # 1. Concatenate each section's bytes across objects, recording where each
    #    object's contribution starts so symbols and relocs resolve.
    set section_bytes [dict create]
    set contributions [dict create]
    foreach sec $::pak::LINK_SECTION_ORDER {
        dict set section_bytes $sec ""
        dict set contributions $sec {}
    }
    foreach obj $objects {
        foreach sec $::pak::LINK_SECTION_ORDER {
            if {![dict exists $obj sections $sec]} continue
            set start [string length [dict get $section_bytes $sec]]
            dict lappend contributions $sec [list $obj $start]
            dict set section_bytes $sec [string cat [dict get $section_bytes $sec] \
                [dict get $obj sections $sec data]]
        }
    }

    # 2. Assign final virtual addresses to each section.
    set section_bases [dict create]
    set section_sizes [dict create]
    set cursor $::pak::LINK_BASE_ADDR
    foreach sec $::pak::LINK_SECTION_ORDER {
        set size [string length [dict get $section_bytes $sec]]
        dict set section_sizes $sec $size
        set cursor [pak::link_align_up $cursor [dict get $::pak::LINK_SECTION_ALIGN $sec]]
        dict set section_bases $sec $cursor
        incr cursor $size
    }

    # 3. Build the symbol table. Names beginning with ".L" are assembler
    #    temporaries -- branch targets and block labels the codegen invents per
    #    function -- so they are local to the object that defines them, exactly
    #    as a real linker treats them. Only the rest go in the global table,
    #    where a duplicate is an error.
    set symbols [dict create]
    set sym_origin [dict create]
    set locals [dict create]
    foreach sec $::pak::LINK_SECTION_ORDER {
        set sec_base [dict get $section_bases $sec]
        foreach c [dict get $contributions $sec] {
            lassign $c obj contrib_off
            set opath [dict get $obj path]
            dict for {name byte_off} [dict get $obj sections $sec symbols] {
                set vaddr [expr {$sec_base + $contrib_off + $byte_off}]
                if {[string match ".L*" $name]} {
                    if {[dict exists $locals $opath $name]} {
                        pak::link_error "duplicate local symbol '$name' in $opath"
                    }
                    dict set locals $opath $name $vaddr
                    continue
                }
                if {[dict exists $symbols $name]} {
                    pak::link_error "duplicate symbol '$name': defined in\
                        [dict get $sym_origin $name] and $opath (section $sec)"
                }
                dict set symbols $name $vaddr
                dict set sym_origin $name "$opath (section $sec)"
            }
        }
    }

    # 3b. Linker-defined symbols. boot.S zero-fills .bss between these; the
    #     classic GNU-ld names are provided so the hand-written crt0 links.
    #     A user object defining them is an error (they are reserved).
    set bss_start [dict get $section_bases .bss]
    set bss_end [expr {$bss_start + [dict get $section_sizes .bss]}]
    foreach {name value} [list __bss_start $bss_start _fbss $bss_start \
                               __bss_end $bss_end _end $bss_end] {
        if {[dict exists $symbols $name]} {
            pak::link_error "reserved linker symbol '$name' is also defined in\
                [dict get $sym_origin $name]"
        }
        dict set symbols $name $value
    }

    # 3c. Memory map: program sections must leave a 64-byte gap before FB0.
    #     Anything interesting (18×256² sheets in .data) used to land in the
    #     framebuffers; this is the check that stops it.
    set code_end $bss_end
    set fb0 $::pak::MEM_FB0
    if {$code_end + $::pak::MEM_GAP > $fb0} {
        pak::link_error [format \
            "memory map overlap: .text/.rodata/.data/.bss ends at %#010x; framebuffer 0 starts at %#010x (need a %d-byte gap). Layout: .text/.rodata/.data | 64-byte gap | FB | Z | DL | PCM | heap | stack. Shrink .data (stream textures via PI DMA) or drop a framebuffer." \
            $code_end $fb0 $::pak::MEM_GAP]
    }

    # Linker-defined hardware-region symbols. Same addresses the runtime uses,
    # so a program that wants to *read* the map (rather than hard-code it) can.
    set fb1 [expr {$fb0 + $::pak::MEM_FB_SIZE}]
    set fb2 [expr {$fb1 + $::pak::MEM_FB_SIZE}]
    foreach {name value} [list \
            __fb0 $fb0 __fb1 $fb1 __fb2 $fb2 \
            __zb $::pak::MEM_ZB \
            __zb_end [expr {$::pak::MEM_ZB + $::pak::MEM_ZB_SIZE}] \
            __dl_base $::pak::MEM_DL_BASE \
            __dl_end  [expr {$::pak::MEM_DL_BASE + $::pak::MEM_DL_SIZE}] \
            __ab $::pak::MEM_AB_BASE \
            __ab_end [expr {$::pak::MEM_AB_BASE + $::pak::MEM_AB_SIZE}] \
            __heap_start $::pak::MEM_HEAP_BASE \
            __heap_end   $::pak::MEM_HEAP_LIMIT \
            __stack_top  $::pak::MEM_STACK_TOP] {
        if {[dict exists $symbols $name]} {
            pak::link_error "reserved linker symbol '$name' is also defined in\
                [dict get $sym_origin $name]"
        }
        dict set symbols $name $value
    }

    # 4. Apply relocations, collecting every undefined symbol for one report.
    set undefined {}
    foreach sec $::pak::LINK_SECTION_ORDER {
        if {$sec eq ".bss"} {
            # .bss is not stored in the image, so there is nothing to patch.
            foreach c [dict get $contributions $sec] {
                lassign $c obj _off
                if {[llength [dict get $obj sections $sec relocs]] > 0} {
                    pak::link_error "[dict get $obj path]: relocations in .bss are not supported"
                }
            }
            continue
        }
        set buf [dict get $section_bytes $sec]
        foreach c [dict get $contributions $sec] {
            lassign $c obj contrib_off
            set opath [dict get $obj path]
            foreach rel [dict get $obj sections $sec relocs] {
                lassign $rel off kind symbol
                if {[dict exists $locals $opath $symbol]} {
                    set S [dict get $locals $opath $symbol]
                } elseif {[dict exists $symbols $symbol]} {
                    set S [dict get $symbols $symbol]
                } else {
                    lappend undefined "$symbol (referenced from $opath\
                        section $sec offset $off)"
                    continue
                }
                pak::link_apply_reloc buf [expr {$contrib_off + $off}] $kind $S \
                    "$opath $sec+[format %#x $off]"
            }
        }
        dict set section_bytes $sec $buf
    }
    if {[llength $undefined] > 0} {
        pak::link_error "undefined symbol(s):\n  [join $undefined "\n  "]"
    }

    # 5. Build the flat ROM image: [.text | pad16 | .rodata | pad8 | .data].
    #    .bss is NOT stored (boot.S zeroes it). Inter-section padding is only
    #    emitted between sections that actually carry bytes; trailing alignment
    #    for an empty later section would just bloat the image.
    set image ""
    set prev_end ""
    foreach sec {.text .rodata .data} {
        set data [dict get $section_bytes $sec]
        if {$data eq ""} continue
        if {$prev_end ne ""} {
            append image [string repeat "\x00" \
                [expr {[dict get $section_bases $sec] - $prev_end}]]
        }
        append image $data
        set prev_end [expr {[dict get $section_bases $sec] + [string length $data]}]
    }

    return [dict create image $image symbols $symbols base $::pak::LINK_BASE_ADDR \
        section_bases $section_bases section_sizes $section_sizes]
}

proc pak::link_objects {object_paths {entry _start}} {
    set objects {}
    foreach p $object_paths { lappend objects [pak::parse_object $p] }
    return [pak::link_parsed_objects $objects $entry]
}
