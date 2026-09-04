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

# ── &arr[i], *u8[i], and u8 slices ──────────────────────────────────────────
# emit_slice used to sll the start by 2. Untyped `let s = buf[1..4]` used to
# store the pair address as i32, so s[0] loaded the pointer instead of a byte.

set src6 {
static buf: [8]u8 = undefined
static addr2: u32 = 0
static p_sink: u32 = 0
static sl_sink: u32 = 0
static sl1_sink: u32 = 0
static for_sum: u32 = 0

entry {
    buf[0] = 0xAA
    buf[1] = 0xBB
    buf[2] = 0xCC
    buf[3] = 0xDD
    addr2 = &buf[2] as u32
    let p: *u8 = &buf
    p[2] = 0xEE
    p_sink = buf[2] as u32
    let s = buf[1..4]
    sl_sink = s[0] as u32
    sl1_sink = s[1] as u32
    let mut acc: u32 = 0
    for b in s {
        acc = acc + (b as u32)
    }
    for_sum = acc
}
}
set lx [pak::Lexer new $src6]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set mb [dict get $run mem_b]
set DATA 0x80300000
# .data: addr2, p_sink, sl_sink, sl1_sink, for_sum. .bss: buf.
set buf_addrs [lsort -integer [dict keys $mb]]
set BUF [lindex $buf_addrs 0]
check_eq {&buf[i] is buf+i} [word_hex $mw $DATA] [format %08X [expr {$BUF + 2}]]
check_eq {*u8 p[i] store} [word_hex $mw [expr {$DATA + 4}]] 000000EE
check_eq {u8 slice s[0] is buf[1]} [word_hex $mw [expr {$DATA + 8}]] 000000BB
check_eq {u8 slice s[1] is buf[2] after p[i]} [word_hex $mw [expr {$DATA + 12}]] 000000EE
check_eq {for b in s sums BB+EE+DD} [word_hex $mw [expr {$DATA + 16}]] 00000286

# ── for-in on a fixed array uses [N], not the first two words as a fat pointer
set src7 {
static bytes: [4]u8 = undefined
static words: [4]i32 = undefined
static bsum: u32 = 0
static wsum: i32 = 0

entry {
    bytes[0] = 1
    bytes[1] = 2
    bytes[2] = 3
    bytes[3] = 4
    words[0] = 10
    words[1] = 20
    words[2] = 30
    words[3] = 40
    let mut acc: u32 = 0
    for x in bytes {
        acc = acc + (x as u32)
    }
    bsum = acc
    let mut wacc: i32 = 0
    for y in words {
        wacc = wacc + y
    }
    wsum = wacc
}
}
set lx [pak::Lexer new $src7]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set DATA 0x80300000
check_eq {for x in [4]u8 sums 1+2+3+4} [word_hex $mw $DATA] 0000000A
check_eq {for y in [4]i32 sums 10+20+30+40} [word_hex $mw [expr {$DATA + 4}]] 00000064

# ── struct for-in copies the whole element; [N]T.len is N
set src8 {
struct Point {
    x: i32
    y: i32
}
static pts: [2]Point = undefined
static psum: i32 = 0
static ssum: i32 = 0
static alen: u32 = 0
static slen: u32 = 0

entry {
    pts[0].x = 1
    pts[0].y = 10
    pts[1].x = 2
    pts[1].y = 20
    let mut acc: i32 = 0
    for p in pts {
        acc = acc + p.x + p.y
    }
    psum = acc
    let s = pts[0..2]
    let mut sacc: i32 = 0
    for q in s {
        sacc = sacc + q.x + q.y
    }
    ssum = sacc
    alen = pts.len as u32
    slen = s.len as u32
}
}
set lx [pak::Lexer new $src8]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set DATA 0x80300000
check_eq {for p in [2]Point sums x+y} [word_hex $mw $DATA] 00000021
check_eq {for q in []Point sums x+y} [word_hex $mw [expr {$DATA + 4}]] 00000021
check_eq {[2]Point.len} [word_hex $mw [expr {$DATA + 8}]] 00000002
check_eq {[]Point.len} [word_hex $mw [expr {$DATA + 12}]] 00000002

# ── struct assignment copies fields, not the literal's stack address
set src9 {
struct Point {
    x: i32
    y: i32
}
static pts: [2]Point = undefined
static lit_sum: i32 = 0
static idx_sum: i32 = 0
static sl_sum: i32 = 0
static copy_sum: i32 = 0

entry {
    pts[0] = Point { x: 1, y: 10 }
    pts[1] = Point { x: 2, y: 20 }
    lit_sum = pts[0].x + pts[0].y + pts[1].x + pts[1].y
    pts[0] = pts[1]
    idx_sum = pts[0].x + pts[0].y
    let s: []mut Point = pts[0..2]
    s[1] = Point { x: 3, y: 30 }
    sl_sum = pts[1].x + pts[1].y
    let mut a: Point = Point { x: 4, y: 40 }
    let b: Point = Point { x: 5, y: 50 }
    a = b
    copy_sum = a.x + a.y
}
}
set lx [pak::Lexer new $src9]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set DATA 0x80300000
check_eq {pts[i] = Point{...} copies fields} [word_hex $mw $DATA] 00000021
check_eq {pts[0] = pts[1] copies fields} [word_hex $mw [expr {$DATA + 4}]] 00000016
check_eq {s[1] = Point{...} copies through slice} [word_hex $mw [expr {$DATA + 8}]] 00000021
check_eq {a = b copies local structs} [word_hex $mw [expr {$DATA + 12}]] 00000037

# ── slice / struct / array args and array assign: pass address, memcpy in
set src10 {
struct Point {
    x: i32
    y: i32
}
static nums: [4]i32 = undefined
static pts: [2]Point = undefined
static a: [2]i32 = undefined
static b: [2]i32 = undefined
static slice_sum: i32 = 0
static pt_sum: i32 = 0
static val_sum: i32 = 0
static arr_sum: i32 = 0

fn sum(s: []i32) -> i32 {
    let mut total: i32 = 0
    for item in s {
        total = total + item
    }
    return total
}
fn sum_x(s: []Point) -> i32 {
    let mut total: i32 = 0
    for p in s {
        total = total + p.x
    }
    return total
}
fn add(p: Point) -> i32 {
    return p.x + p.y
}

entry {
    nums[0] = 10
    nums[1] = 20
    nums[2] = 30
    nums[3] = 40
    let s = nums[0..4]
    slice_sum = sum(s)
    pts[0] = Point { x: 1, y: 10 }
    pts[1] = Point { x: 2, y: 20 }
    let ps = pts[0..2]
    pt_sum = sum_x(ps)
    val_sum = add(pts[0])
    b[0] = 10
    b[1] = 20
    a = b
    arr_sum = a[0] + a[1]
}
}
set lx [pak::Lexer new $src10]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set DATA 0x80300000
check_eq {sum([]i32) of 10+20+30+40} [word_hex $mw $DATA] 00000064
check_eq {sum_x([]Point) of 1+2} [word_hex $mw [expr {$DATA + 4}]] 00000003
check_eq {add(Point) of pts[0]} [word_hex $mw [expr {$DATA + 8}]] 0000000B
check_eq {a = b copies [2]i32} [word_hex $mw [expr {$DATA + 12}]] 0000001E

# ── sret: returned structs/slices live in the caller's frame
set src11 {
struct Point {
    x: i32
    y: i32
}
static mk_sum: i32 = 0
static nest_sum: i32 = 0
static meth_sum: i32 = 0
static sl_sum: i32 = 0
static arr_ret: i32 = 0
static nums: [4]i32 = undefined

fn mk(x: i32, y: i32) -> Point {
    return Point { x: x, y: y }
}
fn add(p: Point) -> i32 {
    return p.x + p.y
}
fn rest(s: []i32) -> []i32 {
    return s[1..4]
}
fn pair() -> [2]i32 {
    let mut a: [2]i32 = undefined
    a[0] = 3
    a[1] = 7
    return a
}

impl Point {
    fn doubled(self: Point) -> Point {
        return Point { x: self.x * 2, y: self.y * 2 }
    }
}

entry {
    let p = mk(3, 7)
    mk_sum = p.x + p.y
    nest_sum = add(mk(4, 6))
    let q = Point { x: 5, y: 8 }
    let r = q.doubled()
    meth_sum = r.x + r.y
    nums[0] = 10
    nums[1] = 20
    nums[2] = 30
    nums[3] = 40
    let s = rest(nums[0..4])
    sl_sum = s[0] + s[1] + s[2]
    let arr = pair()
    arr_ret = arr[0] + arr[1]
}
}
set lx [pak::Lexer new $src11]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set DATA 0x80300000
check_eq {let p = mk(3,7) fields} [word_hex $mw $DATA] 0000000A
check_eq {add(mk(4,6)) nested sret} [word_hex $mw [expr {$DATA + 4}]] 0000000A
check_eq {q.doubled() method sret} [word_hex $mw [expr {$DATA + 8}]] 0000001A
check_eq {rest([]i32) returns slice} [word_hex $mw [expr {$DATA + 12}]] 0000005A
check_eq {pair() returns [2]i32} [word_hex $mw [expr {$DATA + 16}]] 0000000A

# ── CStr / Str: inline strlen, no libc jal
set src12 {
static len: i32 = 0
static has: i32 = 0
static pre: i32 = 0
static suf: i32 = 0
static eqv: i32 = 0
static at: i32 = 0
static empty: i32 = 0
static slen: i32 = 0
static slen2: i32 = 0

fn check_pakstr(s: Str) -> i32 {
    return s.len()
}

entry {
    let s: CStr = "hello world"
    len = s.len()
    has = s.contains("world") as i32
    pre = s.starts_with("hello") as i32
    suf = s.ends_with("world") as i32
    eqv = s.eq("hello world") as i32
    at = s.find("world")
    empty = s.is_empty() as i32
    let ps: Str = str.from_cstr("pak")
    slen = check_pakstr(ps)
    slen2 = ps.len
}
}
set lx [pak::Lexer new $src12]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set syms [dict get $run data_syms]
proc static_hex {mw syms name} {
    set addr [dict get $syms $name]
    return [word_hex $mw $addr]
}
check_eq {CStr.len hello world} [static_hex $mw $syms len] 0000000B
check_eq {CStr.contains world} [static_hex $mw $syms has] 00000001
check_eq {CStr.starts_with hello} [static_hex $mw $syms pre] 00000001
check_eq {CStr.ends_with world} [static_hex $mw $syms suf] 00000001
check_eq {CStr.eq hello world} [static_hex $mw $syms eqv] 00000001
check_eq {CStr.find world} [static_hex $mw $syms at] 00000006
check_eq {CStr.is_empty} [static_hex $mw $syms empty] 00000000
check_eq {str.from_cstr pak .len()} [static_hex $mw $syms slen] 00000003
check_eq {Str.len field} [static_hex $mw $syms slen2] 00000003

# ── Str.eq / contains / find / slice (bounded memcmp, not jal pak_str_eq)
set src13 {
static eqv: i32 = 0
static has: i32 = 0
static at: i32 = 0
static pre: i32 = 0
static suf: i32 = 0
static sln: i32 = 0

entry {
    let ps: Str = str.from_cstr("hello world")
    eqv = ps.eq(str.from_cstr("hello world")) as i32
    has = ps.contains(str.from_cstr("world")) as i32
    at = ps.find(str.from_cstr("world"))
    pre = ps.starts_with(str.from_cstr("hello")) as i32
    suf = ps.ends_with(str.from_cstr("world")) as i32
    let part: Str = ps.slice(6, 5)
    sln = part.len()
}
}
set lx [pak::Lexer new $src13]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set syms [dict get $run data_syms]
check_eq {Str.eq hello world} [static_hex $mw $syms eqv] 00000001
check_eq {Str.contains world} [static_hex $mw $syms has] 00000001
check_eq {Str.find world} [static_hex $mw $syms at] 00000006
check_eq {Str.starts_with hello} [static_hex $mw $syms pre] 00000001
check_eq {Str.ends_with world} [static_hex $mw $syms suf] 00000001
check_eq {Str.slice(6,5).len} [static_hex $mw $syms sln] 00000005

# ── array.as_slice / get_unchecked
set src14 {
static a: i32 = 0
static b: i32 = 0
static c: i32 = 0
entry {
    let buf: [4]i32 = [10, 20, 30, 40]
    let s: []i32 = buf.as_slice()
    a = s.len
    b = s[1]
    c = buf.get_unchecked(2)
}
}
set lx [pak::Lexer new $src14]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set syms [dict get $run data_syms]
check_eq {[4]i32.as_slice.len} [static_hex $mw $syms a] 00000004
check_eq {as_slice s[1]} [static_hex $mw $syms b] 00000014
check_eq {get_unchecked(2)} [static_hex $mw $syms c] 0000001E

# ── Result match / Option Some+none / catch
set src15 {
static a: i32 = 0
static b: i32 = 0
static c: i32 = 0
static d: i32 = 0
static e: i32 = 0

fn get_ok() -> Result(i32, i32) { return ok(5) }
fn get_err() -> Result(i32, i32) { return err(3) }

entry {
    let x: Result(i32, i32) = ok(5)
    match x {
        .ok(v) => { a = v }
        .err(e) => { a = e }
    }
    let y: Result(i32, i32) = err(3)
    match y {
        .ok(v) => { b = v }
        .err(e) => { b = e }
    }
    let s: Option(i32) = Some(7)
    match s {
        .Some(v) => { c = v }
        .None => { c = 0 }
    }
    let n: Option(i32) = none
    match n {
        .Some(v) => { d = v }
        .None => { d = 9 }
    }
    e = get_ok() catch { 0 }
}
}
set lx [pak::Lexer new $src15]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set syms [dict get $run data_syms]
check_eq {match ok(5)} [static_hex $mw $syms a] 00000005
check_eq {match err(3)} [static_hex $mw $syms b] 00000003
check_eq {match Some(7)} [static_hex $mw $syms c] 00000007
check_eq {match none} [static_hex $mw $syms d] 00000009
check_eq {get_ok() catch} [static_hex $mw $syms e] 00000005

# ── generic monomorphize is a real function, not spliced into main
set src16 {
static a: i32 = 0
static b: i32 = 0
fn id<T>(x: T) -> T { return x }
fn add<T>(x: T, y: T) -> T { return x + y }
entry {
    a = id(11)
    b = add<i32>(3, 4)
}
}
set lx [pak::Lexer new $src16]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set syms [dict get $run data_syms]
check_eq {id(11) inferred} [static_hex $mw $syms a] 0000000B
check_eq {add<i32>(3,4)} [static_hex $mw $syms b] 00000007

# ── variant match loads the tag at the value's address, not the first word as a pointer
set src17 {
variant Shape { Circle(i32), Pair(i32, i32) }
static a: i32 = 0
static b: i32 = 0
entry {
    let s: Shape = Shape.Circle(4)
    match s {
        .Circle(r) => { a = r }
        .Pair(x, y) => { a = x + y }
    }
    let t: Shape = Shape.Pair(3, 5)
    match t {
        .Circle(r) => { b = r }
        .Pair(x, y) => { b = x + y }
    }
}
}
set lx [pak::Lexer new $src17]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set syms [dict get $run data_syms]
check_eq {match Circle(4)} [static_hex $mw $syms a] 00000004
check_eq {match Pair(3,5)} [static_hex $mw $syms b] 00000008

# ── non-capturing closure via jalr; integer format without snprintf
set src18 {
static a: i32 = 0
static b: i32 = 0
entry {
    let add = fn(x: i32, y: i32) -> i32 { return x + y }
    a = add(3, 4)
    let n: i32 = 3
    let s: CStr = "x={n}"
    b = s.len()
}
}
set lx [pak::Lexer new $src18]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set syms [dict get $run data_syms]
check_eq {fn-closure add(3,4)} [static_hex $mw $syms a] 00000007
check_eq {fmt x={3} len} [static_hex $mw $syms b] 00000003

# ── capturing closure: env word copied from enclosing n
set src19 {
static a: i32 = 0
static b: i32 = 0
entry {
    let n: i32 = 10
    let addn = fn(x: i32) -> i32 { return x + n }
    a = addn(3)
    let m: i32 = 4
    let addm = fn(x: i32) -> i32 { return x + n + m }
    b = addm(1)
}
}
set lx [pak::Lexer new $src19]
set ast [pak::parse_tokens [$lx tokenize]]
set recs [pak::optimize_records [pak::mips_generate_records $ast]]
set asm [pak::records_to_asm $recs]
set run [pak::mips_sim_run $asm main 200000]
set mw [dict get $run mem_w]
set syms [dict get $run data_syms]
check_eq {capture n addn(3)} [static_hex $mw $syms a] 0000000D
check_eq {capture n+m addm(1)} [static_hex $mw $syms b] 0000000F

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }


