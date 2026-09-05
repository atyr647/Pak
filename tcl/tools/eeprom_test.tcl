#!/usr/bin/env tclsh
# tcl/tools/eeprom_test.tcl — week-5 goldens: EEPROM via SI/PIF + PI DMA stores.
#
# There is no cartridge EEPROM here. What we can prove by executing the
# generated MIPS:
#   1. eeprom.present / type_detect emit a Joybus identify on channel 4
#      (skip 0–3, tx=1 rx=3 cmd=0x00, 0xFE, run-bit) and DMA it through SI.
#   2. eeprom.read / eeprom.write emit cmd 0x04 / 0x05 with the block index.
#   3. present() is 0 when PIF does not reply (no hardware).
#   4. dma.read stores PI_DRAM_ADDR, PI_CART_ADDR, PI_WR_LEN (len-1) in order,
#      and returns rather than spinning on PI_STATUS.
#   5. @aligned(16) on a *local* survives into the address the PI is handed.
#
# sb capture (mem_b) is how the PIF command bytes become visible; the
# simulator does not model PIF RAM.

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

proc byte_hex {mb mw addr} {
    set addr [expr {$addr}]
    if {[dict exists $mb $addr]} {
        return [format %02X [dict get $mb $addr]]
    }
    set w [expr {$addr & ~3}]
    if {[dict exists $mw $w]} {
        set word [dict get $mw $w]
        return [format %02X [expr {($word >> ((3 - ($addr & 3)) * 8)) & 0xFF}]]
    }
    return "<unwritten>"
}

proc compile_sim {driver {limit 2000000}} {
    global RUNTIME HERE
    set fh [open $RUNTIME r]; set rt [read $fh]; close $fh
    set combined [file join $HERE .. .. .ee_combined.pk64]
    set fh [open $combined w]; puts -nonewline $fh "$rt\n$driver"; close $fh
    set asm [exec [info nameofexecutable] tcl/cli.tcl explain --backend mips $combined]
    file delete $combined
    return [pak::mips_sim_run $asm main $limit]
}

proc pif_base {mw} {
    set addr [expr {0xA4800000}]
    if {![dict exists $mw $addr]} { return 0 }
    # SI_DRAM_ADDR is the physical address of g_pif_buf.
    return [expr {[dict get $mw $addr] | 0x80000000}]
}

# ── 1. eeprom.present → identify command + SI DMA, result 0 ─────────────────
puts "== eeprom.present (identify, no cartridge) =="

set driver {
static sink: i32 = 99
entry {
    sink = eeprom_present()
}
}
set r [compile_sim $driver]
set mb [dict get $r mem_b]
set mw [dict get $r mem_w]
set buf [pif_base $mw]

ok_true "SI_DRAM_ADDR written" [expr {$buf != 0}] "buf=$buf"
ok "SI_PIF_ADDR_WR64B" [word_hex $mw 0xA4800010] 1FC007C0
ok "SI_PIF_ADDR_RD64B" [word_hex $mw 0xA4800004] 1FC007C0

# skip ch0–3, identify on ch4, end, run
ok "pif skip ch0"     [byte_hex $mb $mw [expr {$buf + 0}]]  00
ok "pif skip ch1"     [byte_hex $mb $mw [expr {$buf + 1}]]  00
ok "pif skip ch2"     [byte_hex $mb $mw [expr {$buf + 2}]]  00
ok "pif skip ch3"     [byte_hex $mb $mw [expr {$buf + 3}]]  00
ok "pif tx_len=1"     [byte_hex $mb $mw [expr {$buf + 4}]]  01
ok "pif rx_len=3"     [byte_hex $mb $mw [expr {$buf + 5}]]  03
ok "pif cmd identify" [byte_hex $mb $mw [expr {$buf + 6}]]  00
ok "pif end 0xFE"     [byte_hex $mb $mw [expr {$buf + 10}]] FE
ok "pif run 0x01"     [byte_hex $mb $mw [expr {$buf + 63}]] 01

set sink_got "<unwritten>"
dict for {addr val} $mw {
    if {$addr >= 0x80300000 && $addr < 0x80310000 && ($addr & 3) == 0} {
        # sink is a word static; last store of 0 or 1 into the data window
        # after present() is the return. Prefer a store of 0 (not-present).
        if {$val == 0 || $val == 1} { set sink_got $val }
    }
}
ok "present() is 0 without EEPROM" $sink_got 0

# ── 2. eeprom.read(3, dst) → cmd 0x04, block 3 ──────────────────────────────
puts ""
puts "== eeprom.read block 3 =="

set driver {
@aligned(16)
static dst: [8]u8 = undefined
entry {
    eeprom_read(3, &dst[0])
}
}
set r [compile_sim $driver]
set mb [dict get $r mem_b]
set mw [dict get $r mem_w]
set buf [pif_base $mw]

ok_true "read: SI_DRAM_ADDR written" [expr {$buf != 0}] "buf=$buf"
ok "read: SI WR64B" [word_hex $mw 0xA4800010] 1FC007C0
ok "read: SI RD64B" [word_hex $mw 0xA4800004] 1FC007C0
ok "read: skip ch0"    [byte_hex $mb $mw [expr {$buf + 0}]] 00
ok "read: tx_len=2"    [byte_hex $mb $mw [expr {$buf + 4}]] 02
ok "read: rx_len=8"    [byte_hex $mb $mw [expr {$buf + 5}]] 08
ok "read: cmd 0x04"    [byte_hex $mb $mw [expr {$buf + 6}]] 04
ok "read: block 3"     [byte_hex $mb $mw [expr {$buf + 7}]] 03
ok "read: end 0xFE"    [byte_hex $mb $mw [expr {$buf + 16}]] FE
ok "read: run 0x01"    [byte_hex $mb $mw [expr {$buf + 63}]] 01

# ── 3. eeprom.write(7, src) → cmd 0x05, block 7, 8 payload bytes ─────────────
puts ""
puts "== eeprom.write block 7 =="

set driver {
@aligned(16)
static src: [8]u8 = undefined
entry {
    src[0] = 0xAA as u8
    src[1] = 0xBB as u8
    src[7] = 0xCC as u8
    eeprom_write(7, &src[0])
}
}
set r [compile_sim $driver]
set mb [dict get $r mem_b]
set mw [dict get $r mem_w]
set buf [pif_base $mw]

ok_true "write: SI_DRAM_ADDR written" [expr {$buf != 0}] "buf=$buf"
ok "write: tx_len=10"  [byte_hex $mb $mw [expr {$buf + 4}]] 0A
ok "write: rx_len=1"   [byte_hex $mb $mw [expr {$buf + 5}]] 01
ok "write: cmd 0x05"   [byte_hex $mb $mw [expr {$buf + 6}]] 05
ok "write: block 7"    [byte_hex $mb $mw [expr {$buf + 7}]] 07
ok "write: end 0xFE"   [byte_hex $mb $mw [expr {$buf + 17}]] FE
ok "write: run 0x01"   [byte_hex $mb $mw [expr {$buf + 63}]] 01

# ── 4. dma.read: PI_DRAM_ADDR, PI_CART_ADDR, PI_WR_LEN = len-1 ───────────────
puts ""
puts "== dma.read PI MMIO (stores, len-1) =="

set driver {
entry {
    dma_read(0x80300100 as *u8, 0x10040000, 64)
}
}
set r [compile_sim $driver]
set mw [dict get $r mem_w]

ok "PI_CART_ADDR cart" [word_hex $mw 0xA4600004] 10040000
ok "PI_WR_LEN len-1"   [word_hex $mw 0xA460000C] 0000003F
ok "PI_STATUS clr"     [word_hex $mw 0xA4600010] 00000002
ok "PI_DRAM_ADDR phys" [word_hex $mw 0xA4600000] 00300100

# The four assertions above are all stores, and every one of them happens
# before dma_wait's poll loop. They passed for as long as the simulator read
# PI_STATUS back as the 0x02 dma_read had just written it, which left
# dma_wait spinning until the instruction limit. This is the assertion that
# notices: dma_read has to return.
ok_true "dma_read returns (PI_STATUS reads as idle)" [dict get $r halted] \
    " (ran the full [dict get $r insns]-instruction budget)"

# A stack DMA buffer. E202 accepts @aligned(16) on a local, so the codegen has
# to actually give it a 16-aligned slot -- it used to hand it the element
# type's alignment (1 for a byte array), and the address that reached
# PI_DRAM_ADDR was whatever offset the frame happened to have free.
puts ""
puts "== @aligned(16) on a local reaches the PI aligned =="

set driver {
static sink: i32 = 0
entry {
    let pad: i32 = 1
    @aligned(16)
    let buf: [64]u8 = undefined
    data_cache_hit_writeback(&buf[0], 64)
    dma_read(&buf[0], 0x10040000, 64)
    data_cache_hit_invalidate(&buf[0], 64)
    sink = pad + buf[0] as i32
}
}
set r [compile_sim $driver]
set mw [dict get $r mem_w]
set dram [word_hex $mw 0xA4600000]
ok_true "PI_DRAM_ADDR is 16-byte aligned" \
    [expr {$dram ne "<unwritten>" && ("0x$dram" & 15) == 0}] " ($dram)"

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
