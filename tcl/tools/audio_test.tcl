#!/usr/bin/env tclsh
# tcl/tools/audio_test.tcl — week-6 goldens: AI PCM on the standalone HAL.
#
# There is no DAC here. What we can prove by executing the generated MIPS:
#   1. audio.init(44100, 4) programs AI_DACRATE / AI_BITRATE / AI_CONTROL.
#   2. audio.get_buffer returns the PCM ring at 0x80299000 (or none if FULL).
#   3. audio.write kicks AI_DRAM_ADDR (physical), AI_LEN (8-byte multiple),
#      AI_CONTROL=1, after a cache writeback.
#   4. A second get_buffer without write still kicks (fill-only idiom).
#   5. audio.close stops the clocks.
#
# AI_STATUS defaults to 0 in the simulator (not FULL), matching a ready DAC.
# Return values are stored through a mailbox at 0x80F00000 so they are not
# mixed with the runtime's own .data statics.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl mips_sim.tcl]

set RUNTIME runtime/standalone/runtime.pk64
set AI_DRAM   [expr {0xA4500000}]
set AI_LEN    [expr {0xA4500004}]
set AI_CTRL   [expr {0xA4500008}]
set AI_STATUS [expr {0xA450000C}]
set AI_DAC    [expr {0xA4500010}]
set AI_BIT    [expr {0xA4500014}]
set PCM_BASE  [expr {0x80299000}]
set PCM_PHYS  [expr {0x00299000}]
set MAILBOX   [expr {0x80F00000}]

# NTSC clock 48681818, freq 44100:
#   dacrate = ((2*clock/freq)+1)/2 = 1104; register = 1103
#   bitrate = min(dacrate/66, 16) = 16; register = 15
#   frames  = ceil(44100/60) even = 736; bytes = 2944
set DAC_44100 1103
set BIT_44100 15
set LEN_44100 2944

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

proc word_hex {mem addr} {
    set addr [expr {$addr}]
    if {![dict exists $mem $addr]} { return "<unwritten>" }
    return [format %08X [dict get $mem $addr]]
}

proc compile_sim {driver {preset {}} {limit 20000000}} {
    global RUNTIME HERE
    set fh [open $RUNTIME r]; set rt [read $fh]; close $fh
    set combined [file join $HERE .. .. .au_combined.pk64]
    set fh [open $combined w]; puts -nonewline $fh "$rt\n$driver"; close $fh
    set asm [exec [info nameofexecutable] tcl/cli.tcl explain --backend mips $combined]
    file delete $combined
    return [pak::mips_sim_run $asm main $limit $preset]
}

puts "== audio.init(44100, 4) programs the AI =="

set r [compile_sim {
entry {
    audio.init(44100, 4)
}
}]
set mw [dict get $r mem_w]
ok "AI_DACRATE 44100" [word_hex $mw $AI_DAC]  [format %08X $DAC_44100]
ok "AI_BITRATE 44100" [word_hex $mw $AI_BIT]  [format %08X $BIT_44100]
ok "AI_CONTROL enable" [word_hex $mw $AI_CTRL] 00000001

puts ""
puts "== get_buffer / write kick =="

set r [compile_sim {
entry {
    audio.init(44100, 4)
    let buf: *i16 = audio.get_buffer()
    let m: *volatile u32 = 0x80F00000 as *volatile u32
    *m = buf as u32
    audio.write(buf)
    audio.close()
}
}]
set mw [dict get $r mem_w]
ok "get_buffer is PCM base" [word_hex $mw $MAILBOX] [format %08X $PCM_BASE]
ok "AI_DRAM_ADDR physical"  [word_hex $mw $AI_DRAM] [format %08X $PCM_PHYS]
ok "AI_LEN 8-byte multiple" [word_hex $mw $AI_LEN]  [format %08X $LEN_44100]
ok_true "AI_LEN % 8 == 0" [expr {($LEN_44100 & 7) == 0}]
ok "close DACRATE" [word_hex $mw $AI_DAC]  00000000
ok "close BITRATE" [word_hex $mw $AI_BIT]  00000000
ok "close CONTROL" [word_hex $mw $AI_CTRL] 00000000

puts ""
puts "== get_buffer returns none when AI is FULL =="

set r [compile_sim {
entry {
    audio.init(44100, 4)
    let st: *volatile u32 = 0xA450000C as *volatile u32
    *st = 0x80000000
    let m: *volatile u32 = 0x80F00000 as *volatile u32
    *m = audio.get_buffer() as u32
}
}]
set mw [dict get $r mem_w]
ok "none when FULL" [word_hex $mw $MAILBOX] 00000000

puts ""
puts "== fill-only loop kicks on the second get_buffer =="

set r [compile_sim {
entry {
    audio.init(44100, 4)
    let a: *i16 = audio.get_buffer()
    let b: *i16 = audio.get_buffer()
    let m: *volatile u32 = 0x80F00000 as *volatile u32
    *m = b as u32
}
}]
set mw [dict get $r mem_w]
ok "fill-only DRAM_ADDR" [word_hex $mw $AI_DRAM] [format %08X $PCM_PHYS]
ok "fill-only LEN"       [word_hex $mw $AI_LEN]  [format %08X $LEN_44100]
ok "second buffer"       [word_hex $mw $MAILBOX] [format %08X [expr {$PCM_BASE + $LEN_44100}]]

puts ""
puts "== can_write / frequency / write_silence =="

set r [compile_sim {
entry {
    audio.init(32000, 2)
    let m: *volatile u32 = 0x80F00000 as *volatile u32
    *m = audio.get_frequency() as u32
    let n: *volatile u32 = 0x80F00004 as *volatile u32
    *n = audio.can_write() as u32
    audio.write_silence()
}
}]
set mw [dict get $r mem_w]
ok "get_frequency 32000" [word_hex $mw $MAILBOX] 00007D00
ok "can_write ready"     [word_hex $mw [expr {$MAILBOX + 4}]] 00000001
ok_true "silence kicked LEN" [expr {[word_hex $mw $AI_LEN] ne "<unwritten>"}]

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
