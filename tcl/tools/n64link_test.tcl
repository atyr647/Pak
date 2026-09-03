#!/usr/bin/env tclsh
# tcl/tools/n64link_test.tcl — regression tests for the flat N64 linker.
# All object files are synthetic text; no MIPS toolchain is involved.

set HERE [file dirname [file normalize [info script]]]
source [file join $HERE .. n64link.tcl]
source [file join $HERE .. n64rom.tcl]

set ::pass 0
set ::fail 0

proc ok {name got want} {
    if {$got eq $want} {
        incr ::pass; puts "ok    $name"
    } else {
        incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want"
    }
}

proc link_texts {texts} {
    set objs {}
    set i 0
    foreach t $texts { lappend objs [pak::parse_object_text $t "obj$i"]; incr i }
    return [pak::link_parsed_objects $objs]
}

proc word_at {image vaddr} {
    set off [expr {$vaddr - $::pak::LINK_BASE_ADDR}]
    binary scan [string range $image $off [expr {$off + 3}]] Iu w
    return [format %08X $w]
}

proc hexof {s} { binary scan $s H* h; return $h }

# Expect a LINKERROR whose message contains `needle`.
proc expect_error {name script needle} {
    if {[catch {uplevel 1 $script} err]} {
        if {[string match "LINKERROR*" $err] && [string match "*$needle*" $err]} {
            incr ::pass; puts "ok    $name (error mentions '$needle')"
        } else {
            incr ::fail; puts "FAIL  $name: wrong error: $err"
        }
    } else {
        incr ::fail; puts "FAIL  $name: expected an error, got none"
    }
}

puts "== single object, no relocs =="
set r [link_texts [list "# pak object v1
section .text
sym _start 0
data 03e00008 00000000
"]]
ok "image bytes"   [hexof [dict get $r image]] "03e0000800000000"
ok "image length"  [string length [dict get $r image]] 8
ok "_start vaddr"  [format %#010x [dict get $r symbols _start]] 0x80000400
ok "base"          [format %#010x [dict get $r base]] 0x80000400

puts "== R_MIPS_32 in .data pointing at a .text symbol =="
set r [link_texts [list "section .text
sym target 0
data 03e00008
section .data
reloc 0 R_MIPS_32 target
data 00000000
"]]
ok "target vaddr" [format %#010x [dict get $r symbols target]] 0x80000400
ok "patched word" [word_at [dict get $r image] [dict get $r section_bases .data]] 80000400

puts "== R_MIPS_26 (jal) =="
# Pad .text so `callee` lands exactly at 0x80001000, then jal it from offset 0.
set pad_words [expr {(0x1000 - 0x400) / 4 - 1}]
set data_line "0c000000"
for {set i 0} {$i < $pad_words} {incr i} { append data_line " 00000000" }
set r [link_texts [list "section .text
sym caller 0
reloc 0 R_MIPS_26 callee
data $data_line
sym callee [expr {($pad_words + 1) * 4}]
"]]
ok "callee vaddr" [format %#010x [dict get $r symbols callee]] 0x80001000
# (0x80001000 >> 2) & 0x3FFFFFF = 0x400; opcode 0x0C000000.
ok "jal encoding" [word_at [dict get $r image] 0x80000400] 0C000400

puts "== HI16/LO16 pair =="
# lui $a0,%hi(sym) ; addiu $a0,$a0,%lo(sym) with sym at 0x80002004.
set pad_words [expr {(0x2004 - 0x400) / 4 - 2}]
set data_line "3c040000 24840000"
for {set i 0} {$i < $pad_words} {incr i} { append data_line " 00000000" }
set r [link_texts [list "section .text
reloc 0 R_MIPS_HI16 sym
reloc 4 R_MIPS_LO16 sym
data $data_line
sym sym [expr {($pad_words + 2) * 4}]
"]]
ok "sym vaddr" [format %#010x [dict get $r symbols sym]] 0x80002004
# hi = (0x80002004 + 0x8000) >> 16 = 0x8000 (carry correction), lo = 0x2004.
ok "lui hi16"   [word_at [dict get $r image] 0x80000400] 3C048000
ok "addiu lo16" [word_at [dict get $r image] 0x80000404] 24842004

puts "== two objects, cross-object reference =="
set r [link_texts [list "section .text
sym func 0
data 03e00008 00000000 00000000 00000000
" "section .text
sym bcaller 0
reloc 0 R_MIPS_26 func
data 0c000000
"]]
ok "func vaddr"    [format %#010x [dict get $r symbols func]] 0x80000400
ok "bcaller vaddr" [format %#010x [dict get $r symbols bcaller]] 0x80000410
ok "cross jal"     [word_at [dict get $r image] 0x80000410] 0C000100

puts "== section ordering / alignment =="
# .text is 24 bytes (ends 0x80000418); .rodata aligns up to 16 -> 0x80000420.
set r [link_texts [list "section .text
data 00000000 00000000 00000000 00000000 00000000 00000000
section .rodata
sym rosym 0
data 48656c6c 6f000000
"]]
ok ".text base"   [format %#010x [dict get $r section_bases .text]]   0x80000400
ok ".rodata base" [format %#010x [dict get $r section_bases .rodata]] 0x80000420
ok "rosym vaddr"  [format %#010x [dict get $r symbols rosym]]         0x80000420

puts "== local labels are object-local =="
# Assembler temporaries (".L*") are per-function names the codegen reinvents in
# every object. They must not collide across objects, and a reference must
# resolve to the one in the referring object.
set r [link_texts [list "section .text
sym runtime_fn 0
sym .Lif_end_3 4
reloc 0 R_MIPS_26 .Lif_end_3
data 0c000000 03e00008
" "section .text
sym game_fn 0
sym .Lif_end_3 4
reloc 0 R_MIPS_26 .Lif_end_3
data 0c000000 03e00008
"]]
ok "first object kept"  [format %#010x [dict get $r symbols runtime_fn]] 0x80000400
ok "second object kept" [format %#010x [dict get $r symbols game_fn]]    0x80000408
ok "no global .L entry" [dict exists $r symbols .Lif_end_3] 0
# Object 0's jal targets its own .Lif_end_3 at 0x80000404 -> (>>2)&0x3FFFFFF = 0x101.
ok "object 0 reloc" [word_at [dict get $r image] 0x80000400] 0C000101
# Object 1's targets ITS own, at 0x8000040C -> 0x103.
ok "object 1 reloc" [word_at [dict get $r image] 0x80000408] 0C000103
expect_error "duplicate local within one object" {link_texts [list "section .text
sym .Ldup 0
sym .Ldup 4
data 03e00008 03e00008
"]} .Ldup

puts "== error cases =="
expect_error "undefined symbol" {link_texts [list "section .text
reloc 0 R_MIPS_26 nowhere
data 0c000000
"]} nowhere
expect_error "duplicate symbol" {link_texts [list "section .text
sym main 0
data 03e00008
" "section .text
sym main 0
data 03e00008
"]} main
expect_error "reserved linker symbol" {link_texts [list "section .text
sym __bss_start 0
data 03e00008
"]} __bss_start
expect_error "unknown section" {link_texts [list "section .weird
data 03e00008
"]} .weird
expect_error "bad reloc kind" {link_texts [list "section .text
reloc 0 R_MIPS_HI17 x
data 03e00008
"]} R_MIPS_HI17
expect_error "short data word" {link_texts [list "section .text
data 03e0000
"]} {8 hex chars}
expect_error "directive before section" {link_texts [list "sym main 0
"]} "before any 'section'"

puts "== .bss reserves address space but stays out of the image =="
set r [link_texts [list "section .text
sym _start 0
data 03e00008 00000000
section .data
sym dval 0
data deadbeef
section .bss
sym bvar 0
space 64
"]]
# .text ends 0x80000408; .rodata is empty but still aligns the cursor to 16
# (0x80000410), so .data lands there, and .bss at align8(0x80000414)=0x80000418.
ok ".data base"  [format %#010x [dict get $r section_bases .data]] 0x80000410
ok "dval vaddr"  [format %#010x [dict get $r symbols dval]]        0x80000410
ok ".bss base"   [format %#010x [dict get $r section_bases .bss]]  0x80000418
ok "bvar vaddr"  [format %#010x [dict get $r symbols bvar]]        0x80000418
ok "image excludes .bss" [string length [dict get $r image]] [expr {(0x80000410 - 0x80000400) + 4}]

puts "== linker-defined bss bounds =="
ok "__bss_start" [format %#010x [dict get $r symbols __bss_start]] 0x80000418
ok "_fbss"       [format %#010x [dict get $r symbols _fbss]]       0x80000418
ok "__bss_end"   [format %#010x [dict get $r symbols __bss_end]]   [format %#010x [expr {0x80000418 + 64}]]
ok "_end"        [format %#010x [dict get $r symbols _end]]        [format %#010x [expr {0x80000418 + 64}]]

puts "== memory-map symbols =="
ok "__fb0"        [format %#010x [dict get $r symbols __fb0]]        0x80200000
ok "__fb1"        [format %#010x [dict get $r symbols __fb1]]        0x80225800
ok "__fb2"        [format %#010x [dict get $r symbols __fb2]]        0x8024b000
ok "__zb"         [format %#010x [dict get $r symbols __zb]]         0x80271000
ok "__dl_base"    [format %#010x [dict get $r symbols __dl_base]]    0x80297000
ok "__heap_start" [format %#010x [dict get $r symbols __heap_start]] 0x802a0000
ok "__stack_top"  [format %#010x [dict get $r symbols __stack_top]]  0x80400000

puts "== overlap: .data that grows into FB0 is a link error =="
# .text 4 bytes at 0x80000400; .data of 2 MiB starts at 0x80000410 and
# crosses 0x80200000.
expect_error "data overlaps framebuffer" [list link_texts [list "section .text
sym _start 0
data 03e00008
section .data
space 2097152
"]] "memory map overlap"

puts "== ROM packing =="
set r [link_texts [list "section .text
sym _start 0
data 03e00008 00000000
"]]
set rom [pak::n64rom [dict get $r image] "TESTROM"]
ok "rom is word-aligned"  [expr {[string length $rom] % 4}] 0
ok "rom is 4 MiB"          [string length $rom] 4194304
ok "rom covers CRC window" [expr {[string length $rom] >= 0x101000}] 1
ok "header magic"          [hexof [string range $rom 0 3]] 80371240
binary scan [string range $rom 8 11] Iu entry_pc
ok "entry point"           [format %#010x $entry_pc] 0x80000400
ok "title field"           [string trimright [string range $rom 32 51]] TESTROM
ok "code at 0x1000"        [hexof [string range $rom 0x1000 0x1007]] 03e0000800000000
# CRC1/CRC2 must be non-zero and stable for a fixed image (CIC-NUS-6102).
# Golden CIC-NUS-6102 CRC for this exact image; matches the reference packer.
binary scan [string range $rom 16 23] IuIu crc1 crc2
ok "CRC1" [format %08X $crc1] FF4A4DEC
ok "CRC2" [format %08X $crc2] 0EAFCDE4
# Repacking the same image must reproduce the same ROM byte for byte.
ok "packing is deterministic" [expr {[pak::n64rom [dict get $r image] "TESTROM"] eq $rom}] 1
# A different title changes the ROM (title is inside the CRC-free header) but
# not the code region.
set rom2 [pak::n64rom [dict get $r image] "OTHER"]
ok "title is honoured" [string trimright [string range $rom2 32 51]] OTHER
ok "code unchanged"    [hexof [string range $rom2 0x1000 0x1007]] 03e0000800000000

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
