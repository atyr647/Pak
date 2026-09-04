#!/usr/bin/env tclsh
# tcl/tools/exception_test.tcl — CPU exception paint + crt0 vector install.
#
# There is no N64 and no emulator here. What we can prove:
#   1. exception_paint fills every framebuffer with RGBA5551 0xF801 and
#      programs the VI, by executing the generated MIPS in mips_sim.
#   2. boot.S encodes a trampoline copied to the four VR4300 vectors and
#      jal's exception_paint (or jalr's g_exc_handler).
#   3. A linked 4 MiB .z64 has a valid header and the paint/handler symbols.
#
# FrozenZ / Parallel / Angrylion smoke is that 4 MiB padded ROM: those
# emulators (and flashcarts) crash on a 2.9 MB image. CI cannot launch them.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl mips_sim.tcl]
source [file join $REPO tcl n64enc.tcl]
source [file join $REPO tcl n64link.tcl]
source [file join $REPO tcl n64rom.tcl]

set RUNTIME runtime/standalone/runtime.pk64
set BOOT    runtime/standalone/boot.S
set CRASH_RED 0xF801
set FB0 0xA0200000
set FB1 0xA0225800
set FB2 0xA024B000
set FB_BYTES [expr {320 * 240 * 2}]

set ::pass 0
set ::fail 0

proc ok {name got want} {
    if {$got eq $want} {
        incr ::pass; puts "ok    $name = $got"
    } else {
        incr ::fail; puts "FAIL  $name\n        got:  $got\n        want: $want"
    }
}

proc ok_true {name cond {detail ""}} {
    if {$cond} {
        incr ::pass; puts "ok    $name"
    } else {
        incr ::fail; puts "FAIL  $name $detail"
    }
}

proc half_hex {mem addr} {
    set addr [expr {$addr}]
    if {![dict exists $mem $addr]} { return "<unwritten>" }
    return [format %04X [dict get $mem $addr]]
}

proc word_hex {mem addr} {
    set addr [expr {$addr}]
    if {![dict exists $mem $addr]} { return "<unwritten>" }
    return [format %08X [dict get $mem $addr]]
}

proc obj_has {txt needle} {
    expr {[string first $needle $txt] >= 0}
}

# ── 1. exception_paint executed in the MIPS simulator ────────────────────────
puts "== exception_paint (simulated) =="

set fh [open $RUNTIME r]; set rt [read $fh]; close $fh
set driver {
entry {
    exception_paint()
}
}
set combined [file join $HERE .. .. .exc_combined.pk64]
set fh [open $combined w]; puts -nonewline $fh "$rt\n$driver"; close $fh
set asm [exec [info nameofexecutable] tcl/cli.tcl explain --backend mips $combined]
file delete $combined

set r [pak::mips_sim_run $asm main 20000000]
set mh [dict get $r mem_h]
set mw [dict get $r mem_w]
set want [format %04X $CRASH_RED]

ok "FB0 first pixel crash red"  [half_hex $mh $FB0] $want
ok "FB0 second pixel crash red" [half_hex $mh [expr {$FB0 + 2}]] $want
ok "FB0 last pixel crash red"   [half_hex $mh [expr {$FB0 + $FB_BYTES - 2}]] $want
ok "FB1 first pixel crash red"  [half_hex $mh $FB1] $want
ok "FB2 first pixel crash red"  [half_hex $mh $FB2] $want
ok "VI_CTRL 16bpp"        [word_hex $mw 0xA4400000] 00003202
ok "VI_ORIGIN FB0 phys"   [word_hex $mw 0xA4400004] 00200000
ok "VI_WIDTH 320"         [word_hex $mw 0xA4400008] 00000140

# ── 2. boot.S object: vector copy + jal exception_paint ──────────────────────
puts ""
puts "== boot.S vector trampoline =="

set boot_obj [file join $HERE .. .. .boot.pakobj]
exec [info nameofexecutable] tcl/cli.tcl asmobj $BOOT -o $boot_obj
set fh [open $boot_obj r]; set boot_txt [read $fh]; close $fh
file delete $boot_obj

ok_true "reloc jal exception_paint" [obj_has $boot_txt "R_MIPS_26 exception_paint"]
ok_true "reloc la g_exc_handler"    [regexp {R_MIPS_(HI16|LO16) g_exc_handler} $boot_txt]
ok_true "sym exception_stub"        [regexp {sym exception_stub } $boot_txt]
ok_true "sym exception_entry"       [regexp {sym exception_entry } $boot_txt]
ok_true "Hit_Invalidate_I (cache 0x10)" [regexp {bd100000} [string tolower $boot_txt]]
ok_true "KSEG1 vector base 0xA000"  [regexp {3c0.a000} [string tolower $boot_txt]]

# ── 3. Linked 4 MiB ROM: header + symbols (FZ/flashcart size) ────────────────
puts ""
puts "== linked ROM smoke (4 MiB, header, symbols) =="

set rt_obj  [file join $HERE .. .. .rt.pakobj]
set game_obj [file join $HERE .. .. .game.pakobj]
set boot2   [file join $HERE .. .. .boot2.pakobj]
set game_pk [file join $HERE .. .. .exc_game.pk64]
set fh [open $game_pk w]
puts -nonewline $fh "entry { display.init(0, 2, 3, 0, 1) }\n"
close $fh
exec [info nameofexecutable] tcl/cli.tcl asmobj $BOOT -o $boot2
exec [info nameofexecutable] tcl/cli.tcl objgen $RUNTIME -o $rt_obj
exec [info nameofexecutable] tcl/cli.tcl objgen $game_pk -o $game_obj

set fh [open $boot2 r]; set btxt [read $fh]; close $fh
set fh [open $rt_obj r]; set rtxt [read $fh]; close $fh
set fh [open $game_obj r]; set gtxt [read $fh]; close $fh
set objs [list \
    [pak::parse_object_text $btxt boot.S] \
    [pak::parse_object_text $rtxt runtime.pk64] \
    [pak::parse_object_text $gtxt game.pk64]]
set linked [pak::link_parsed_objects $objs]
set syms [dict get $linked symbols]
ok_true "symbol _start"            [dict exists $syms _start]
ok_true "symbol exception_paint"   [dict exists $syms exception_paint]
ok_true "symbol exception_entry"   [dict exists $syms exception_entry]
ok_true "symbol exception_stub"    [dict exists $syms exception_stub]
ok_true "symbol g_exc_handler"     [dict exists $syms g_exc_handler]
ok "_start at 0x80000400" [format %#010x [dict get $syms _start]] 0x80000400

# exception_stub in the image is a J to exception_entry.
set stub_va [dict get $syms exception_stub]
set entry_va [dict get $syms exception_entry]
set image [dict get $linked image]
set off [expr {$stub_va - $::pak::LINK_BASE_ADDR}]
binary scan [string range $image $off [expr {$off + 3}]] Iu jword
set jop [expr {($jword >> 26) & 0x3F}]
set jtgt [expr {(($jword & 0x3FFFFFF) << 2) | ($stub_va & 0xF0000000)}]
ok "stub is J-type" $jop 2
ok "stub jumps to exception_entry" [format %#010x $jtgt] [format %#010x $entry_va]

set rom [pak::n64rom $image "PAK EXC"]
ok "ROM is 4 MiB" [string length $rom] 4194304
ok "header magic" [binary scan [string range $rom 0 3] H8 m; set m] 80371240
binary scan [string range $rom 8 11] Iu pc
ok "ROM entry PC" [format %#010x $pc] 0x80000400
binary scan [string range $rom 16 23] IuIu crc1 crc2
ok_true "CRC1 non-zero" [expr {$crc1 != 0}]
ok_true "CRC2 non-zero" [expr {$crc2 != 0}]

file delete $boot2 $rt_obj $game_obj $game_pk

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
