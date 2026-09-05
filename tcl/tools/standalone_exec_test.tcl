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
puts "PASS=$pass  FAIL=$fail"
exit [expr {$fail > 0 ? 1 : 0}]
