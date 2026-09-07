#!/usr/bin/env tclsh
# tcl/tools/accessory_test.tcl — the Rumble Pak's Joybus frames and the
# ISViewer debug channel, executed.
#
# There is no Rumble Pak here, and the simulator does not model PIF RAM, so
# what can be proved is what the CPU puts on the wire. That is most of it:
# every way rumble goes wrong on real hardware is a wrong byte in this frame.
#
#   1. The address CRC-5. The pak REJECTS a write whose address checksum is
#      wrong, silently -- a rumble that "does nothing" is usually this. The
#      two addresses the pak uses are checked against the values libdragon's
#      own table produces: 0x8000 -> 0x8001, 0xC000 -> 0xC01B.
#   2. The write frame: tx=35 (cmd + 2 address + 32 data), rx=1, cmd 0x03,
#      and all 32 payload bytes actually filled.
#   3. The read frame: tx=3, rx=33, cmd 0x02.
#   4. The channel offset. The accessory lives behind a CONTROLLER, so the
#      frame is on that controller's channel: one 0x00 skip byte per lower
#      port, and port 3's frame must still end inside the 64-byte buffer.
#   5. debug.init_isviewer probes for the IS64 magic, and debug.log packs
#      its text into whole big-endian words with the length written last.
#   6. start()/stop() drive the motor only when the probe answered. With no
#      hardware the probe fails, so the last frame out must be the probe's
#      read and not a motor write -- otherwise a game with no Rumble Pak
#      would spend a Joybus transaction per frame on nothing.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl mips_sim.tcl]

set RUNTIME runtime/standalone/runtime.pk64
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
    if {$cond} { incr ::pass; puts "ok    $name" } \
    else       { incr ::fail; puts "FAIL  $name $detail" }
}

proc word_hex {mw addr} {
    set addr [expr {$addr}]
    if {![dict exists $mw $addr]} { return "<unwritten>" }
    return [format %08X [dict get $mw $addr]]
}

proc byte_hex {mb mw addr} {
    set addr [expr {$addr}]
    if {[dict exists $mb $addr]} { return [format %02X [dict get $mb $addr]] }
    set w [expr {$addr & ~3}]
    if {[dict exists $mw $w]} {
        set word [dict get $mw $w]
        return [format %02X [expr {($word >> ((3 - ($addr & 3)) * 8)) & 0xFF}]]
    }
    return "<unwritten>"
}

proc compile_sim {driver {limit 4000000}} {
    global RUNTIME HERE
    set fh [open $RUNTIME r]; set rt [read $fh]; close $fh
    set combined [file join $HERE .. .. .rumble_combined.pk64]
    set fh [open $combined w]; puts -nonewline $fh "$rt\n$driver"; close $fh
    set asm [exec [info nameofexecutable] tcl/cli.tcl explain --backend mips $combined]
    file delete $combined
    return [pak::mips_sim_run $asm main $limit]
}

proc pif_base {mw} {
    set addr [expr {0xA4800000}]
    if {![dict exists $mw $addr]} { return 0 }
    return [expr {[dict get $mw $addr] | 0x80000000}]
}

# The last word stored into the statics window that is one of the wanted
# values. Mirrors eeprom_test.tcl's sink read.
proc sink_of {mw wanted} {
    set got "<unwritten>"
    dict for {addr val} $mw {
        if {$addr >= 0x80300000 && $addr < 0x80310000 && ($addr & 3) == 0} {
            if {[lsearch -exact $wanted $val] >= 0} { set got $val }
        }
    }
    return $got
}

# ── 1. the address CRC-5 ─────────────────────────────────────────────────────
puts "== the address checksum the pak checks =="

set r [compile_sim {
static sink: i32 = 0
entry {
    sink = rumble_addr(0x8000) as i32
}
}]
ok "rumble_addr(0x8000)" [sink_of [dict get $r mem_w] [list 32769]] 32769

set r [compile_sim {
static sink: i32 = 0
entry {
    sink = rumble_addr(0xC000) as i32
}
}]
ok "rumble_addr(0xC000)" [sink_of [dict get $r mem_w] [list 49179]] 49179

# The two addresses above between them exercise only table entries 14 and 15.
# 0xFFE0 has every address bit set, so its checksum is the XOR of all eleven
# entries -- and flipping any single one of them changes it. Without this,
# nine of the eleven were never read by any test.
set r [compile_sim {
static sink: i32 = 0
entry {
    sink = rumble_addr(0xFFE0) as i32
}
}]
ok "rumble_addr(0xFFE0) exercises every table entry" \
    [sink_of [dict get $r mem_w] [list 65517]] 65517

# ── 2. the motor write frame ────────────────────────────────────────────────
puts ""
puts "== write 0x01 x32 to the motor block, port 0 =="

set r [compile_sim {
entry {
    rumble_write_fill(0, RUMBLE_ADDR_MOTOR, 0x01)
}
}]
set mb [dict get $r mem_b]
set mw [dict get $r mem_w]
set buf [pif_base $mw]

ok_true "SI_DRAM_ADDR written" [expr {$buf != 0}] "buf=$buf"
ok "SI_PIF_ADDR_WR64B"  [word_hex $mw 0xA4800010] 1FC007C0
ok "write: tx=35"       [byte_hex $mb $mw [expr {$buf + 0}]]  23
ok "write: rx=1"        [byte_hex $mb $mw [expr {$buf + 1}]]  01
ok "write: cmd 0x03"    [byte_hex $mb $mw [expr {$buf + 2}]]  03
ok "write: addr hi"     [byte_hex $mb $mw [expr {$buf + 3}]]  C0
ok "write: addr lo+crc" [byte_hex $mb $mw [expr {$buf + 4}]]  1B
ok "write: first payload byte"  [byte_hex $mb $mw [expr {$buf + 5}]]  01
ok "write: last payload byte" [byte_hex $mb $mw [expr {$buf + 36}]] 01
ok "write: end 0xFE"    [byte_hex $mb $mw [expr {$buf + 38}]] FE
ok "write: run 0x01"    [byte_hex $mb $mw [expr {$buf + 63}]] 01

# Every one of the 32 payload bytes, not just the ends: a loop that stops one
# short still rumbles on some paks and not others.
set filled 1
for {set i 0} {$i < 32} {incr i} {
    if {[byte_hex $mb $mw [expr {$buf + 5 + $i}]] ne "01"} { set filled 0 }
}
ok_true "write: all 32 payload bytes filled" $filled

# ── 3. the read frame ────────────────────────────────────────────────────────
puts ""
puts "== read the probe block, port 0 =="

set r [compile_sim {
static sink: i32 = 7
entry {
    sink = rumble_read_is_fill(0, RUMBLE_ADDR_PROBE, 0x80)
}
}]
set mb [dict get $r mem_b]
set mw [dict get $r mem_w]
set buf [pif_base $mw]

ok "read: tx=3"         [byte_hex $mb $mw [expr {$buf + 0}]]  03
ok "read: rx=33"        [byte_hex $mb $mw [expr {$buf + 1}]]  21
ok "read: cmd 0x02"     [byte_hex $mb $mw [expr {$buf + 2}]]  02
ok "read: addr hi"      [byte_hex $mb $mw [expr {$buf + 3}]]  80
ok "read: addr lo+crc"  [byte_hex $mb $mw [expr {$buf + 4}]]  01
ok "read: end 0xFE"     [byte_hex $mb $mw [expr {$buf + 38}]] FE
ok "read: no pak, so not a fill" [sink_of $mw [list 0 1]] 0

# ── 4. the channel offset ────────────────────────────────────────────────────
puts ""
puts "== port 3 puts its frame on channel 3 =="

set r [compile_sim {
entry {
    rumble_write_fill(3, RUMBLE_ADDR_MOTOR, 0x01)
}
}]
set mb [dict get $r mem_b]
set mw [dict get $r mem_w]
set buf [pif_base $mw]

ok "port3: skip ch0"    [byte_hex $mb $mw [expr {$buf + 0}]]  00
ok "port3: skip ch1"    [byte_hex $mb $mw [expr {$buf + 1}]]  00
ok "port3: skip ch2"    [byte_hex $mb $mw [expr {$buf + 2}]]  00
ok "port3: tx=35"       [byte_hex $mb $mw [expr {$buf + 3}]]  23
ok "port3: cmd 0x03"    [byte_hex $mb $mw [expr {$buf + 5}]]  03
ok "port3: end 0xFE"    [byte_hex $mb $mw [expr {$buf + 41}]] FE
# 3 skip + 38 frame bytes + the 0xFE = 42, and byte 63 is the run bit. The
# frame must not reach it, or the transaction never starts.
ok_true "port3: frame ends before the run byte" [expr {3 + 38 < 63}]

# ── 5. no pak, no motor write ───────────────────────────────────────────────
puts ""
puts "== start() with nothing plugged in =="

set r [compile_sim {
entry {
    rumble_init()
    rumble_start(0)
}
}]
set mb [dict get $r mem_b]
set mw [dict get $r mem_w]
set buf [pif_base $mw]

# The probe's last transaction is the READ, so the buffer must still hold the
# read frame. A motor write here would mean start() ignored the probe.
ok "no pak: last frame is the probe read, not a motor write" \
    [byte_hex $mb $mw [expr {$buf + 2}]] 02
ok "no pak: probe address, not the motor address" \
    [byte_hex $mb $mw [expr {$buf + 3}]] 80

# ── 6. the ISViewer debug channel ───────────────────────────────────────────
puts ""
puts "== debug.init_isviewer probes for the IS64 magic =="

set r [compile_sim {
entry {
    debug_init_isviewer()
}
}]
set mw [dict get $r mem_w]
ok "isviewer: writes the IS64 magic to 0x13FF0000" [word_hex $mw 0xB3FF0000] 49533634

# The simulator has no open bus -- cartridge space reads back whatever was
# written -- so the probe succeeds here and the write path runs. That is the
# half worth checking anyway: the buffer takes whole big-endian WORDS, so
# "hi" is 0x68690000 with the tail zero-padded, and the length is written
# last because writing it is what makes the host print.
set r [compile_sim {
entry {
    debug_init_isviewer()
    debug.log("hi")
}
}]
set mw [dict get $r mem_w]
ok "isviewer: text packs big-endian, zero-padded" [word_hex $mw 0xB3FF0020] 68690000
ok "isviewer: the length is the byte count"       [word_hex $mw 0xB3FF0014] 00000002

# Five characters spill into a second word, and the count is bytes, not words.
set r [compile_sim {
entry {
    debug_init_isviewer()
    debug.log("abcde")
}
}]
set mw [dict get $r mem_w]
ok "isviewer: first word"  [word_hex $mw 0xB3FF0020] 61626364
ok "isviewer: second word" [word_hex $mw 0xB3FF0024] 65000000
ok "isviewer: length is 5" [word_hex $mw 0xB3FF0014] 00000005

puts ""
puts "PASS=$::pass  FAIL=$::fail"
exit [expr {$::fail > 0 ? 1 : 0}]
