#!/usr/bin/env tclsh
# tcl/tools/array_addr_test.tcl — &array is the label, u8 index is a byte.
#
# Taking `&g_buf` used to load the first word (la + lw). Indexing `[N]u8`
# used to scale the index by 4 and `sw`. Both made PIF/EEPROM and shade+tex
# vertex arrays go through helpers. This file executes the generated MIPS
# and checks the stores.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl mips_codegen.tcl]
source [file join $REPO tcl mips_sim.tcl]
source [file join $REPO tcl optimize.tcl]

set ::pass 0
set ::fail 0

proc check_eq {name got want} {
    if {$got eq $want} {
        incr ::pass
        puts "ok    $name = $got"
    } else {
        incr ::fail
        puts "FAIL  $name\n        got:  $got\n        want: $want"
    }
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

proc word_hex {mw addr} {
    set addr [expr {$addr}]
    if {![dict exists $mw $addr]} { return "<unwritten>" }
    return [format %08X [dict get $mw $addr]]
}

set src {
static buf: [8]u8 = undefined
static words: [4]i32 = undefined
static addr_sink: u32 = 0
static b1_sink: u32 = 0
static w1_sink: i32 = 0

entry {
    buf[0] = 0xAA
    buf[1] = 0xBB
    buf[2] = 0xCC
    buf[3] = 0xDD
    words[0] = 0x11111111
    words[1] = 0x22222222
    addr_sink = &buf as u32
    b1_sink = buf[1] as u32
    w1_sink = words[1]
}
}

set lx [pak::Lexer new $src]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]

# The lowering we actually want to see in the instruction stream.
set has_sb 0
set has_la_buf 0
set scaled_u8 0
foreach r $recs {
    if {[lindex $r 0] ne "i"} continue
    set m [lindex $r 1]
    if {$m eq "sb"} { set has_sb 1 }
    if {$m eq "la" && [string match {*buf*} [lindex $r 3]]} { set has_la_buf 1 }
    # A u8 index of 1 must not become sll by 2 before the store.
    if {$m eq "sll" && [lindex $r 4] eq "2"} { incr scaled_u8 }
}
check_eq "u8 store emits sb" $has_sb 1
check_eq "address-of static array is la, not la+lw" $has_la_buf 1

set run [pak::mips_sim_run $asm main 200000]
set mb [dict get $run mem_b]
set mw [dict get $run mem_w]

# .data first (addr_sink, b1_sink, w1_sink), then .bss (buf, words).
set buf_addrs [lsort -integer [dict keys $mb]]
check_eq "four sb stores" [llength $buf_addrs] 4
set BUF [lindex $buf_addrs 0]
check_eq "buf0 byte" [byte_hex $mb $mw $BUF] AA
check_eq "buf1 byte" [byte_hex $mb $mw [expr {$BUF + 1}]] BB
check_eq "buf2 byte" [byte_hex $mb $mw [expr {$BUF + 2}]] CC
check_eq "buf3 byte" [byte_hex $mb $mw [expr {$BUF + 3}]] DD
set WORDS [expr {$BUF + 8}]
check_eq "words0" [word_hex $mw $WORDS] 11111111
check_eq "words1" [word_hex $mw [expr {$WORDS + 4}]] 22222222
set DATA 0x80300000
check_eq "address of buf" [word_hex $mw $DATA] [format %08X $BUF]
check_eq "loaded buf1" [word_hex $mw [expr {$DATA + 4}]] 000000BB
check_eq "loaded words1" [word_hex $mw [expr {$DATA + 8}]] 22222222

# Local array: same lowering, address is $sp-relative.
set src2 {
static sink: u32 = 0
entry {
    let mut local: [4]u8 = undefined
    local[0] = 0x11
    local[1] = 0x22
    local[2] = 0x33
    local[3] = 0x44
    sink = local[2] as u32
}
}
set lx [pak::Lexer new $src2]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set sink "<unwritten>"
dict for {addr val} $mw {
    if {$addr >= 0x80300000 && $addr < 0x80400000} {
        set sink [format %08X $val]
        break
    }
}
check_eq "local u8 index 2 loaded" $sink 00000033

# ── struct field address and value-struct stores ────────────────────────────
# `&p.y` used to evaluate y, spill it, and return the stack slot. Value
# `p.x =` used the first word of p as a pointer. Both must hit the object.

set src3 {
struct Point {
    x: i32
    y: i32
}
struct Pack {
    buf: [4]u8
}
static p: Point = undefined
static pack: Pack = undefined
static addr_p: u32 = 0
static addr_y: u32 = 0
static y_sink: i32 = 0

entry {
    p.x = 0x11111111
    p.y = 0x22222222
    addr_p = &p as u32
    addr_y = &p.y as u32
    y_sink = p.y
    pack.buf[0] = 0xAA
    pack.buf[1] = 0xBB
    pack.buf[2] = 0xCC
    pack.buf[3] = 0xDD
}
}
set lx [pak::Lexer new $src3]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set mb [dict get $run mem_b]
set DATA 0x80300000
# .data: addr_p, addr_y, y_sink (12 bytes). .bss: p (8), pack (4).
set P [expr {$DATA + 12}]
check_eq "value struct p.x store" [word_hex $mw $P] 11111111
check_eq "value struct p.y store" [word_hex $mw [expr {$P + 4}]] 22222222
check_eq "address of p" [word_hex $mw $DATA] [format %08X $P]
check_eq "address of p.y" [word_hex $mw [expr {$DATA + 4}]] [format %08X [expr {$P + 4}]]
check_eq "loaded p.y" [word_hex $mw [expr {$DATA + 8}]] 22222222

set pack_addrs [lsort -integer [dict keys $mb]]
check_eq "pack.buf four sb" [llength $pack_addrs] 4
set PACK [lindex $pack_addrs 0]
check_eq "pack.buf0" [byte_hex $mb $mw $PACK] AA
check_eq "pack.buf1" [byte_hex $mb $mw [expr {$PACK + 1}]] BB
check_eq "pack.buf2" [byte_hex $mb $mw [expr {$PACK + 2}]] CC
check_eq "pack.buf3" [byte_hex $mb $mw [expr {$PACK + 3}]] DD

# Pointer receiver + nested field: g.player.x must hit player, not a copy.
set src4 {
struct Point {
    x: i32
    y: i32
}
struct Game {
    player: Point
}
static g: Game = undefined
static sink: i32 = 0

fn bump(gs: *Game) {
    gs.player.x = 0x7E57
    gs.player.y = 0xABCD
}

entry {
    bump(&g)
    sink = g.player.x
}
}
set lx [pak::Lexer new $src4]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set DATA 0x80300000
check_eq "nested ptr field x" [word_hex $mw [expr {$DATA + 4}]] 00007E57
check_eq "nested ptr field y" [word_hex $mw [expr {$DATA + 8}]] 0000ABCD
check_eq "loaded nested x" [word_hex $mw $DATA] 00007E57

# ── method self: value, pointer, nested field ───────────────────────────────
# ptr.init() used to pass &ptr (address of the pointer slot). g.player.init()
# used to spill a copy of player's first word.

set src5 {
struct Point {
    x: i32
    y: i32
}
impl Point {
    fn init(self: *Point, x: i32, y: i32) {
        self.x = x
        self.y = y
    }
}
struct Game {
    player: Point
}
static p: Point = undefined
static q: Point = undefined
static g: Game = undefined
static sum_p: i32 = 0
static sum_q: i32 = 0
static sum_g: i32 = 0

entry {
    p.init(3, 7)
    let ptr: *Point = &q
    ptr.init(4, 6)
    g.player.init(1, 2)
    sum_p = p.x + p.y
    sum_q = q.x + q.y
    sum_g = g.player.x + g.player.y
}
}
set lx [pak::Lexer new $src5]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set DATA 0x80300000
# .data: sum_p, sum_q, sum_g. .bss: p, q, g.
check_eq "value receiver p.init sum" [word_hex $mw $DATA] 0000000A
check_eq "pointer receiver ptr.init sum" [word_hex $mw [expr {$DATA + 4}]] 0000000A
check_eq "nested field g.player.init sum" [word_hex $mw [expr {$DATA + 8}]] 00000003

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }


