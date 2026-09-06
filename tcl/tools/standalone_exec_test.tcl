#!/usr/bin/env tclsh
# Execute the constructs that used to fail at link, in the MIPS simulator.
#
# link_test.tcl proves these programs resolve every symbol. That is necessary
# and not sufficient: a monomorph can be emitted under the right name and still
# compute the wrong thing, and a const can resolve to the wrong number. Each
# case here writes its result to a static and asserts the word the simulator
# left at that address.

set HERE [file dirname [file normalize [info script]]]
source [file join $HERE .. parser.tcl]
source [file join $HERE .. mips_codegen.tcl]
source [file join $HERE .. optimize.tcl]
source [file join $HERE .. mips_sim.tcl]

set pass 0
set fail 0

proc word_hex {mw addr} {
    if {![dict exists $mw $addr]} { return "<unwritten>" }
    return [format %08X [dict get $mw $addr]]
}

proc run_src {src} {
    set lx [pak::Lexer new $src]
    set ast [pak::parse_tokens [$lx tokenize]]
    set recs [pak::optimize_records [pak::mips_generate_records $ast]]
    return [pak::mips_sim_run [pak::records_to_asm $recs] main 200000]
}

# FixedMap and Pool lower to calls on pak_map_* / pak_pool_* in the standalone
# runtime, so a case exercising them has to be linked against that runtime. The
# helper block is self-contained -- no asm, no hardware registers -- so splicing
# it in front of the program runs the real code rather than a copy that drifts.
proc runtime_helpers {} {
    set f [open [file join $::HERE .. .. runtime standalone runtime.pk64] r]
    set rt [read $f]
    close $f
    # From the heap onwards: the Vec helpers allocate, so __pak_alloc has to
    # come along. Everything between is plain Pak with no hardware in it.
    set i [string first "Heap (bump allocator)" $rt]
    if {$i < 0} { error "runtime.pk64: heap block not found" }
    set i [string last "\n" [string range $rt 0 $i]]
    return [string range $rt $i end]
}

proc chk_rt {what src sym want} {
    chk $what "[runtime_helpers]\n$src" $sym $want
}

proc chk {what src sym want} {
    if {[catch {set run [run_src $src]} err]} {
        puts "FAIL  $what -- $err"
        incr ::fail
        return
    }
    set got [word_hex [dict get $run mem_w] [dict get [dict get $run data_syms] $sym]]
    if {$got eq $want} {
        puts "ok    $what = $got"
        incr ::pass
    } else {
        puts "FAIL  $what = $got (want $want)"
        incr ::fail
    }
}

puts "== consts that used to be undefined symbols =="

# eval_const_expr had no FloatLit case, so a fixed-point const never entered
# the const table and every use was `la $t8, GRAVITY`. 0.4 * 65536 = 26214.
chk "fix16.16 const scales to 26214" {
const GRAVITY: fix16.16 = 0.4
static out: i32 = 0
entry { out = GRAVITY }
} out 00006666

chk "fix16.16 const in arithmetic" {
const GRAVITY: fix16.16 = 0.4
static out: i32 = 0
entry {
    let v: fix16.16 = 0
    out = v + GRAVITY + GRAVITY
}
} out 0000CCCC

puts ""
puts "== defer =="

# The deferred body was emitted after pop_scope, so the local it reads was
# already gone and became a reference to a global that does not exist.
chk "defer reads an enclosing local" {
static out: i32 = 0
fn work() {
    let n: i32 = 7
    defer { out = n }
}
entry { work() }
} out 00000007

# Defers run innermost-last-registered first; the second write must win.
chk "defer order is LIFO" {
static out: i32 = 0
fn work() {
    defer { out = 1 }
    defer { out = 2 }
}
entry { work() }
} out 00000001

puts ""
puts "== generic impl monomorphs =="

# `impl Pair<T>` emitted one Pair_sum_i32 while call sites named
# Pair__i32_sum_i32. Both instantiations must exist and compute separately.
chk "Pair<i32>.sum_i32()" {
struct Pair<T> { first: T, second: T }
impl Pair<T> {
    fn sum_i32(self: *Pair<T>) -> T { return self.first + self.second }
    fn get_first(self: *Pair<T>) -> T { return self.first }
}
static out: i32 = 0
entry {
    let p: Pair<i32> = Pair<i32> { first: 10, second: 32 }
    out = p.sum_i32()
}
} out 0000002A

chk "two instantiations stay distinct" {
struct Pair<T> { first: T, second: T }
impl Pair<T> {
    fn get_first(self: *Pair<T>) -> T { return self.first }
}
static out: i32 = 0
entry {
    let a: Pair<i32> = Pair<i32> { first: 3, second: 4 }
    let b: Pair<i32> = Pair<i32> { first: 8, second: 9 }
    out = a.get_first() + b.get_first()
}
} out 0000000B

puts ""
puts "== FixedList =="

# FixedList.init() is a static call on a type: there is no FixedList value and
# no FixedList_init symbol. It means an empty container.
chk "init / push / len" {
static out: i32 = 0
entry {
    let mut xs: FixedList(i32, 8) = FixedList.init()
    xs.push(5)
    xs.push(9)
    out = xs.len()
}
} out 00000002

chk "init leaves an empty list" {
static out: i32 = 0
entry {
    let mut xs: FixedList(i32, 8) = FixedList.init()
    out = xs.len()
}
} out 00000000

chk "get returns what push stored" {
static out: i32 = 0
entry {
    let mut xs: FixedList(i32, 8) = FixedList.init()
    xs.push(5)
    xs.push(9)
    out = xs.get(1)
}
} out 00000009

chk "clear empties the list" {
static out: i32 = 0
entry {
    let mut xs: FixedList(i32, 8) = FixedList.init()
    xs.push(5)
    xs.clear()
    out = xs.len()
}
} out 00000000

chk "set overwrites in place" {
static out: i32 = 0
entry {
    let mut xs: FixedList(i32, 8) = FixedList.init()
    xs.push(5)
    xs.set(0, 12)
    out = xs.get(0)
}
} out 0000000C

# remove is swap-remove: the tail moves into the hole and len drops.
chk "remove shortens the list" {
static out: i32 = 0
entry {
    let mut xs: FixedList(i32, 8) = FixedList.init()
    xs.push(1)
    xs.push(2)
    xs.push(3)
    xs.remove(0)
    out = xs.len()
}
} out 00000002

puts ""
puts "== unsigned arithmetic uses the unsigned instructions =="

# emit_binop was type-blind. Every one of these produced the signed
# instruction -- srav, div, slt -- and every one of them is a shape that
# actually turns up on an N64: a cached address, a packed colour, a size
# compared against a hardware limit. The constants below all have bit 31 set,
# which is exactly where the signed and unsigned answers part company.

chk "u32 >> is a logical shift" {
static out: u32 = 0
entry {
    let a: u32 = 0xA0100000
    let s: u32 = 4
    out = a >> s
}
} out 0A010000

chk "u32 / is an unsigned divide" {
static out: u32 = 0
entry {
    let a: u32 = 0xA0000000
    let b: u32 = 2
    out = a / b
}
} out 50000000

chk "u32 % is an unsigned remainder" {
static out: u32 = 0
entry {
    let a: u32 = 0xA0000001
    let b: u32 = 16
    out = a % b
}
} out 00000001

chk "u32 < compares unsigned" {
static out: u32 = 0
entry {
    let a: u32 = 0xA0000000
    let b: u32 = 1
    if a < b { out = 1 } else { out = 0 }
}
} out 00000000

chk "u32 > compares unsigned" {
static out: u32 = 0
entry {
    let a: u32 = 0xA0000000
    let b: u32 = 1
    if a > b { out = 1 } else { out = 0 }
}
} out 00000001

chk "u32 >= compares unsigned" {
static out: u32 = 0
entry {
    let a: u32 = 0x80000000
    let b: u32 = 0x7FFFFFFF
    if a >= b { out = 1 } else { out = 0 }
}
} out 00000001

chk "u32 <= compares unsigned" {
static out: u32 = 0
entry {
    let a: u32 = 0x80000000
    let b: u32 = 0x7FFFFFFF
    if a <= b { out = 1 } else { out = 0 }
}
} out 00000000

# The signed operators must keep working: i32 >> stays arithmetic.
chk "i32 >> stays an arithmetic shift" {
static out: i32 = 0
entry {
    let a: i32 = -256
    let s: i32 = 4
    out = a >> s
}
} out FFFFFFF0

chk "i32 / stays a signed divide" {
static out: i32 = 0
entry {
    let a: i32 = -100
    let b: i32 = 8
    out = a / b
}
} out FFFFFFF4

chk "i32 < stays a signed compare" {
static out: i32 = 0
entry {
    let a: i32 = -1
    let b: i32 = 1
    if a < b { out = 1 } else { out = 0 }
}
} out 00000001

puts ""
puts "== a static's initializer survives to the target =="

# emit_static only knew how to lay out a scalar. An array or struct literal
# fell through to `.space`, so the initializer was discarded and every read of
# the table returned zero -- a level map, a palette, a lookup table, RSP
# microcode. The C backend had it right the whole time, which is why nothing
# noticed.

chk "an i32 table keeps its values" {
static xs: [4]i32 = [11, 22, 33, 44]
static out: i32 = 0
entry { out = xs[0] + xs[1] + xs[2] + xs[3] }
} out 0000006E

chk "a u32 table keeps a value with bit 31 set" {
static xs: [2]u32 = [0x8C080000, 0x0000000D]
static out: u32 = 0
entry { out = xs[0] }
} out 8C080000

chk "the last element is not clipped" {
static xs: [4]u32 = [1, 2, 3, 0xDEADBEEF]
static out: u32 = 0
entry { out = xs[3] }
} out DEADBEEF

chk "a u8 table packs without shifting" {
static bs: [4]u8 = [1, 2, 3, 4]
static out: i32 = 0
entry { out = (bs[0] as i32) * 1000 + (bs[3] as i32) }
} out 000003EC

chk "a struct literal keeps its fields" {
struct P { x: i32, y: i32 }
static p: P = P { x: 7, y: 9 }
static out: i32 = 0
entry { out = p.x * 10 + p.y }
} out 0000004F

chk "a repeat initializer fills every slot" {
static xs: [4]i32 = [5; 4]
static out: i32 = 0
entry { out = xs[0] + xs[3] }
} out 0000000A

chk "a scalar f32 static keeps its value" {
static g: f32 = 0.4
static out: f32 = 0.0
entry { out = g }
} out 3ECCCCCD

# A global went through a plain `lw` whatever its type, so a byte-wide static
# came back with three of its neighbours in the high bits.
chk "a u8 static reads back as one byte" {
static a: u8 = 200
static b: u8 = 7
static out: i32 = 0
entry { out = a as i32 }
} out 000000C8

chk "an i16 static reads back sign-extended" {
static h: i16 = -2
static pad: i16 = 0x1234
static out: i32 = 0
entry { out = h as i32 }
} out FFFFFFFE

chk "`undefined` still means uninitialized" {
static xs: [4]i32 = undefined
static out: i32 = 0
entry { out = 1 }
} out 00000001

puts ""
puts "== floating point actually computes =="

# The simulator had no FPU at all: mtc1, cvt.s.w, add.s and the rest fell
# through its switch and became no-ops, so a float program "ran" and left its
# destination register holding whatever was there before. Every one of these
# passed trivially before there was an FPU to run them.

chk "f32 add" {
static out: f32 = 0.0
entry {
    let a: f32 = 1.5
    let b: f32 = 2.25
    out = a + b
}
} out 40700000

chk "f32 multiply" {
static out: f32 = 0.0
entry {
    let a: f32 = 3.0
    let b: f32 = 0.5
    out = a * b
}
} out 3FC00000

chk "f32 divide" {
static out: f32 = 0.0
entry {
    let a: f32 = 7.0
    let b: f32 = 2.0
    out = a / b
}
} out 40600000

chk "f32 subtract crosses zero" {
static out: f32 = 0.0
entry {
    let a: f32 = 1.0
    let b: f32 = 4.0
    out = a - b
}
} out C0400000

chk "i32 to f32 conversion" {
static out: f32 = 0.0
entry {
    let n: i32 = -5
    out = n as f32
}
} out C0A00000

chk "f32 to i32 truncates toward zero" {
static out: i32 = 0
entry {
    let f: f32 = 3.75
    out = f as i32
}
} out 00000003

chk "f32 comparison picks the branch" {
static out: i32 = 0
entry {
    let a: f32 = 1.5
    let b: f32 = 2.5
    if a < b { out = 7 } else { out = 9 }
}
} out 00000007

puts ""
puts "== FixedMap and Pool (standalone container helpers) =="

# The MIPS backend used to call pak_map_set(map, cap, key, val), passing the key
# and the value BY VALUE. One helper serves every K and V, so it cannot know how
# wide either is: the call has to pass addresses and sizes. These cases run the
# real runtime helpers, so a signature that drifts shows up as a wrong answer.

chk_rt "FixedMap.set then len" {
static out: i32 = 0
entry {
    let mut m: FixedMap(i32, i32, 16) = FixedMap.init()
    m.set(1, 100)
    m.set(2, 200)
    m.set(3, 300)
    out = m.len()
}
} out 00000003

chk_rt "FixedMap.get returns the value slot" {
static out: i32 = 0
entry {
    let mut m: FixedMap(i32, i32, 16) = FixedMap.init()
    m.set(1, 100)
    m.set(2, 200)
    let p = m.get(2)
    if p != none { out = *p }
}
} out 000000C8

chk_rt "FixedMap.get of an absent key is none" {
static out: i32 = 0
entry {
    let mut m: FixedMap(i32, i32, 16) = FixedMap.init()
    m.set(1, 100)
    out = 5
    let p = m.get(9)
    if p == none { out = 7 }
}
} out 00000007

chk_rt "FixedMap.set over an existing key replaces it" {
static out: i32 = 0
entry {
    let mut m: FixedMap(i32, i32, 16) = FixedMap.init()
    m.set(4, 100)
    m.set(4, 250)
    let p = m.get(4)
    if p != none { out = *p + m.len() }
}
} out 000000FB

chk_rt "FixedMap.has" {
static out: i32 = 0
entry {
    let mut m: FixedMap(i32, i32, 16) = FixedMap.init()
    m.set(3, 300)
    out = (m.has(3) as i32) * 10 + (m.has(4) as i32)
}
} out 0000000A

chk_rt "FixedMap.remove drops the key and the count" {
static out: i32 = 0
entry {
    let mut m: FixedMap(i32, i32, 16) = FixedMap.init()
    m.set(1, 100)
    m.set(2, 200)
    m.remove(1)
    out = m.len() * 10 + (m.has(1) as i32)
}
} out 0000000A

# A u8 key is one byte wide: a helper that compares four bytes, or that indexes
# keys[] by 4, finds the wrong slot. keys[] is also padded up to the value's
# alignment here, which is why the call carries the offset of values[] instead
# of recomputing it from cap * key_sz.
chk_rt "FixedMap with a u8 key and an i32 value" {
static out: i32 = 0
entry {
    let mut m: FixedMap(u8, i32, 6) = FixedMap.init()
    m.set(1, 111)
    m.set(2, 222)
    m.set(3, 333)
    let p = m.get(2)
    if p != none { out = *p }
}
} out 000000DE

chk_rt "FixedMap fills up and refuses the extra key" {
static out: i32 = 0
entry {
    let mut m: FixedMap(i32, i32, 2) = FixedMap.init()
    m.set(1, 10)
    m.set(2, 20)
    m.set(3, 30)
    out = m.len() * 10 + (m.has(3) as i32)
}
} out 00000014

chk_rt "Pool.acquire hands out a zeroed slot" {
struct Bullet { x: f32, y: f32, active: i32 }
static out: i32 = 0
entry {
    let mut pool: Pool(Bullet, 16) = Pool.init()
    let s: *Bullet = pool.acquire()
    if s != none { out = s.active + 1 }
}
} out 00000001

chk_rt "Pool.len counts what is live" {
struct Bullet { x: f32, y: f32, active: i32 }
static out: i32 = 0
entry {
    let mut pool: Pool(Bullet, 16) = Pool.init()
    let a: *Bullet = pool.acquire()
    let b: *Bullet = pool.acquire()
    let c: *Bullet = pool.acquire()
    out = pool.len()
}
} out 00000003

# release swaps the freed slot with the last live one, so the slot the caller
# handed back now holds what the last one did: 2 live, a.active 9, c.active 7.
chk_rt "Pool.release swaps the last live slot down" {
struct Bullet { x: f32, y: f32, active: i32 }
static out: i32 = 0
entry {
    let mut pool: Pool(Bullet, 16) = Pool.init()
    let a: *Bullet = pool.acquire()
    let b: *Bullet = pool.acquire()
    let c: *Bullet = pool.acquire()
    a.active = 7
    c.active = 9
    pool.release(a)
    out = pool.len() * 100 + a.active * 10 + c.active
}
} out 00000129

chk_rt "Pool.acquire refuses when full" {
struct Bullet { x: f32, y: f32, active: i32 }
static out: i32 = 0
entry {
    let mut pool: Pool(Bullet, 2) = Pool.init()
    let a: *Bullet = pool.acquire()
    let b: *Bullet = pool.acquire()
    let c: *Bullet = pool.acquire()
    out = 5
    if c == none { out = pool.len() }
}
} out 00000002

puts ""
puts "== narrow stores and the word underneath them =="

# The simulator kept byte stores in a side table that a narrow load consulted
# first, so a byte store shadowed every word store that came after it: zero a
# struct byte-wise, assign a field, read the field back, and it still read
# zero. Pool.acquire zeroes its slot exactly that way.
chk_rt "a word store wins over the byte store under it" {
static out: i32 = 0
entry {
    let mut buf: [i32; 4] = [1, 2, 3, 4]
    pak_bytes_zero(&buf as u32, 16)
    buf[1] = 0x2A
    let p: *u8 = ((&buf as u32) + 7) as *u8
    out = (*p) as i32
}
} out 0000002A

puts ""
puts "== dyn Trait (vtable dispatch) =="

# A `dyn Trait` is the pair {self, vtable}; the vtable is a .word table of the
# concrete methods in TRAIT DECLARATION order, so one index means the same
# method in every impl. The MIPS backend used to refuse the whole construct.

chk "dispatch picks the receiver's own method" {
trait Shape {
    fn area(self: *Self) -> i32
    fn sides(self: *Self) -> i32
}
struct Sq { w: i32 }
struct Tri { b: i32, h: i32 }
impl Sq for Shape {
    fn area(self: *Sq) -> i32 { return self.w * self.w }
    fn sides(self: *Sq) -> i32 { return 4 }
}
impl Tri for Shape {
    fn area(self: *Tri) -> i32 { return (self.b * self.h) / 2 }
    fn sides(self: *Tri) -> i32 { return 3 }
}
static out: i32 = 0
entry {
    let mut a = Sq { w: 5 }
    let mut b = Tri { b: 6, h: 4 }
    let sa: dyn Shape = Shape_from_Sq(&a)
    let sb: dyn Shape = Shape_from_Tri(&b)
    out = sa.area() * 100 + sb.area()
}
} out 000009D0

# The second slot: an index computed from the trait declaration, not from the
# order the impl happens to list its methods.
chk "the second vtable slot is the second trait method" {
trait Shape {
    fn area(self: *Self) -> i32
    fn sides(self: *Self) -> i32
}
struct Sq { w: i32 }
struct Tri { b: i32, h: i32 }
impl Sq for Shape {
    fn sides(self: *Sq) -> i32 { return 4 }
    fn area(self: *Sq) -> i32 { return self.w * self.w }
}
impl Tri for Shape {
    fn area(self: *Tri) -> i32 { return (self.b * self.h) / 2 }
    fn sides(self: *Tri) -> i32 { return 3 }
}
static out: i32 = 0
entry {
    let mut a = Sq { w: 5 }
    let mut b = Tri { b: 6, h: 4 }
    let sa: dyn Shape = Shape_from_Sq(&a)
    let sb: dyn Shape = Shape_from_Tri(&b)
    out = sa.sides() * 10 + sb.sides()
}
} out 0000002B

# A dyn Trait is 8 bytes, so it travels by address and is copied into the
# callee's frame like any other aggregate.
chk "a dyn Trait passed to a function still dispatches" {
trait Shape {
    fn area(self: *Self) -> i32
}
struct Sq { w: i32 }
impl Sq for Shape {
    fn area(self: *Sq) -> i32 { return self.w * self.w }
}
fn area_of(s: dyn Shape) -> i32 { return s.area() + 1 }
static out: i32 = 0
entry {
    let mut a = Sq { w: 6 }
    let s: dyn Shape = Shape_from_Sq(&a)
    out = area_of(s)
}
} out 00000025

# A trait method with a default body the impl does not override still needs a
# concrete symbol for its vtable slot.
chk "a trait default fills its own vtable slot" {
trait Greet {
    fn base(self: *Self) -> i32
    fn twice(self: *Self) -> i32 { return self.base() * 2 }
}
struct N { v: i32 }
impl N for Greet {
    fn base(self: *N) -> i32 { return self.v }
}
static out: i32 = 0
entry {
    let mut n = N { v: 21 }
    let g: dyn Greet = Greet_from_N(&n)
    out = g.twice()
}
} out 0000002A

chk "dispatch through a float-returning method" {
trait Shape {
    fn area(self: *Self) -> f32
}
struct Rect { w: f32, h: f32 }
impl Rect for Shape {
    fn area(self: *Rect) -> f32 { return self.w * self.h }
}
static out: f32 = 0.0
entry {
    let mut r = Rect { w: 3.0, h: 4.0 }
    let s: dyn Shape = Shape_from_Rect(&r)
    out = s.area()
}
} out 41400000

puts ""
puts "== a data word can name a symbol =="

# `.word <symbol>` had no meaning in the simulator's data image (it stored 0)
# or in tcl/n64asm.tcl (it raised a Tcl error). A vtable is nothing but such
# words, so both had to learn it.
chk "a .word naming a static reads back as its address" {
static target: i32 = 0x5A5A
static out: i32 = 0
entry {
    let p: *i32 = &target
    out = *p
}
} out 00005A5A

puts ""
puts "== Vec (heap-backed, growing) =="

# Vec used to lower to _pak_vec_push / _pak_vec_get / ... -- a family of symbols
# no source on this backend defines, so every program using one linked to
# nothing. Only the three operations that can move the storage call the
# runtime now; the rest read the {data, len, cap} header inline. These run
# against the real helpers, so they also exercise the bump allocator.

chk_rt "Vec.push then len and get" {
static out: i32 = 0
entry {
    let mut v: Vec(i32) = Vec.init()
    v.push(10)
    v.push(20)
    v.push(30)
    out = v.len() * 1000 + v.get(1)
}
} out 00000BCC

chk_rt "Vec grows past its first block" {
static out: i32 = 0
entry {
    let mut v: Vec(i32) = Vec.init()
    let mut i: i32 = 0
    while i < 20 {
        v.push(i * 3)
        i = i + 1
    }
    out = v.len() * 1000 + v.get(19)
}
} out 00004E59

chk_rt "Vec.clear keeps the storage but empties it" {
static out: i32 = 0
entry {
    let mut v: Vec(i32) = Vec.init()
    v.push(1)
    v.push(2)
    v.clear()
    out = (v.is_empty() as i32) * 100 + v.len() * 10 + v.cap()
}
} out 0000006C

chk_rt "Vec.reserve raises cap without touching len" {
static out: i32 = 0
entry {
    let mut v: Vec(i32) = Vec.init()
    v.push(7)
    v.reserve(64)
    out = v.cap() * 100 + v.len() * 10 + v.get(0)
}
} out 00001911

chk_rt "Vec.pop takes the last element" {
static out: i32 = 0
entry {
    let mut v: Vec(i32) = Vec.init()
    v.push(4)
    v.push(9)
    let top = v.pop()
    out = top * 10 + v.len()
}
} out 0000005B

chk_rt "Vec.free empties the header" {
static out: i32 = 0
entry {
    let mut v: Vec(i32) = Vec.init()
    v.push(1)
    v.free()
    out = v.len() * 100 + v.cap() * 10 + (v.is_empty() as i32)
}
} out 00000001

puts ""
puts "== named-field variant arms =="

# `.rect { w: ww, h: hh }` lowers correctly on both backends, but the checker
# declared only positional bindings, so every use of `ww` was E010 and no
# program using the form could reach a backend at all.
chk "a named-field arm binds its fields" {
variant Shape { circle(i32), rect { w: i32, h: i32 } }
static out: i32 = 0
entry {
    let a: Shape = Shape.rect { w: 3, h: 4 }
    match a {
        .circle(r)             => { out = r }
        .rect { w: ww, h: hh } => { out = ww * 100 + hh }
    }
}
} out 00000130

chk "the positional arm of the same variant still works" {
variant Shape { circle(i32), rect { w: i32, h: i32 } }
static out: i32 = 0
entry {
    let b: Shape = Shape.circle(9)
    match b {
        .circle(r)             => { out = r }
        .rect { w: ww, h: hh } => { out = 0 }
    }
}
} out 00000009

puts ""
puts "== a container's backing array =="

# The C backend lowers p.data\[i\] straight through, so it has always worked
# there. Here the layout handed back the ELEMENT type for `data` rather than
# an array of it, so the index scaled by 4 and the field offset was resolved
# against the wrong layout: silently the wrong element, no diagnostic.
chk_rt "FixedList.data indexes by the element's stride" {
static out: i32 = 0
entry {
    let mut l: FixedList(i32, 8) = FixedList.init()
    l.push(10)
    l.push(20)
    l.push(30)
    out = l.data[1]
}
} out 00000014

chk_rt "Pool.data on a struct element reads the right field" {
struct B { x: i32, y: i32, z: i32 }
static out: i32 = 0
entry {
    let mut p: Pool(B, 8) = Pool.init()
    let a: *B = p.acquire()
    let b: *B = p.acquire()
    let c: *B = p.acquire()
    a.z = 1
    b.z = 2
    c.z = 3
    out = p.data[0].z * 100 + p.data[1].z * 10 + p.data[2].z
}
} out 0000007B

chk_rt "FixedMap.keys and .values are their own arrays" {
static out: i32 = 0
entry {
    let mut m: FixedMap(i32, i32, 8) = FixedMap.init()
    m.set(5, 500)
    out = m.keys[0] * 1000 + m.values[0]
}
} out 0000157C

chk_rt "RingBuffer.data indexes from the head slot" {
static out: i32 = 0
entry {
    let mut r: RingBuffer(i32, 8) = RingBuffer.init()
    r.push(77)
    out = r.data[0]
}
} out 0000004D

puts ""
puts "PASS=$pass  FAIL=$fail"
exit [expr {$fail > 0 ? 1 : 0}]
