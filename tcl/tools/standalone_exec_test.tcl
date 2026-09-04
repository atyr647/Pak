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
puts "PASS=$pass  FAIL=$fail"
exit [expr {$fail > 0 ? 1 : 0}]
