#!/usr/bin/env tclsh
# tcl/tools/math_test.tcl — the standalone HAL's math, executed.
#
# n64.math lowers to <math.h> on the libdragon backend. There is no libm in a
# standalone ROM, so runtime/standalone/runtime.pk64 is the implementation:
# sin/cos by Taylor on a quadrant-reduced argument, sqrt by Newton from a
# scaled seed, ln and exp by the power-of-two split, atan2 by a minimax fit.
# None of that is checkable by reading it, so every function is run here and
# compared against the value it is supposed to produce.
#
# The first half of the file is the arithmetic underneath. This backend has
# two FP registers and no allocator over them -- $f12 for a value, $f14 for
# the left side of an operation -- and nothing used to keep a float alive
# across the evaluation of another one. `0.5 * (y + m / y)` compiled to
# `m * (m + m/y)`, and a call in an operand overwrote the other operand. Those
# cases come first because every function below them depends on getting them
# right.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
cd $REPO
source [file join $REPO tcl parser.tcl]
source [file join $REPO tcl mips_codegen.tcl]
source [file join $REPO tcl optimize.tcl]
source [file join $REPO tcl mips_sim.tcl]

set ::pass 0
set ::fail 0

set fh [open runtime/standalone/runtime.pk64 r]; fconfigure $fh -encoding utf-8
set ::RT [read $fh]; close $fh

# Run a program and read a float static back out of simulated RDRAM.
proc run_float {src {name __out}} {
    set lx [pak::Lexer new $src]
    set ast [pak::parse_tokens [$lx tokenize]]
    set recs [pak::optimize_records [pak::mips_generate_records $ast]]
    set r [pak::mips_sim_run [pak::records_to_asm $recs] main 80000000]
    set addr [dict get [dict get $r data_syms] $name]
    set mw [dict get $r mem_w]
    set bits [expr {[dict exists $mw $addr] ? [dict get $mw $addr] : 0}]
    binary scan [binary format Iu $bits] R v
    return $v
}

# `body` is Pak statements that assign to __out. Compiled against the whole
# standalone runtime, so it is the shipped implementation being measured.
proc chk {name body want tol} {
    set src "$::RT\nstatic __out: f32 = 0.0\nentry {\n$body\n}\n"
    if {[catch {set got [run_float $src]} err]} {
        incr ::fail
        puts "FAIL  $name -- [lindex [split $err \n] 0]"
        return
    }
    if {abs($got - $want) <= $tol} {
        incr ::pass
        puts [format "ok    %-38s %.8g" $name $got]
    } else {
        incr ::fail
        puts [format "FAIL  %-38s got %.8g  want %.8g (tol %g)" $name $got $want $tol]
    }
}

proc chk_expr {name expr_src want tol} {
    chk $name "    __out = $expr_src" $want $tol
}

puts "== float expressions survive nesting and calls =="

# Every one of these was wrong: the left operand lived in $f14 and whatever
# came next was free to overwrite it.
chk_expr "two levels: 0.5 * (2.0 + 1.0)"  {0.5 * (2.0 + 1.0)}                1.5      1e-7
chk_expr "three levels"                   {2.0 * (1.0 + (3.0 * (4.0 - 2.0)))} 14.0    1e-6
chk_expr "division on the right"          {0.5 * (1.5 + 2.0 / 1.5)}          1.4166667 1e-6
chk_expr "both sides nested"              {(1.0 + 2.0) * (10.0 - 4.0)}       18.0     1e-6
chk_expr "a call on the right"            {2.0 * math_abs_f(0.0 - 3.0)}      6.0      1e-6
chk_expr "a call on the left"             {math_abs_f(0.0 - 3.0) * 2.0}      6.0      1e-6
chk_expr "calls on both sides"            {math_abs_f(0.0 - 3.0) / math_abs_f(0.0 - 2.0)} 1.5 1e-6
chk_expr "a nested call as an argument"   {math_abs_f(0.0 - math_abs_f(0.0 - 7.0))}     7.0 1e-6
chk_expr "three float arguments"          {math_lerp_f(2.0, 6.0, 0.25)}      3.0      1e-6
chk_expr "three arguments, each a call"   {math_clamp_f(math_abs_f(0.0 - 9.0), 1.0, 5.0)} 5.0 1e-6
chk_expr "second argument is nested"      {math_max_f(1.0, 2.0 * 3.0)}       6.0      1e-6

chk "float compound assignment" {
    let mut a: f32 = 10.0
    a -= 2.0 * 1.5
    __out = a
} 7.0 1e-6

chk "a float local survives a call" {
    let a: f32 = 3.0
    let b: f32 = math_abs_f(0.0 - 4.0)
    __out = a * b
} 12.0 1e-6

puts ""
puts "== the functions themselves =="

chk_expr "sin(0)"            {math_sin_f(0.0)}                    0.0         1e-7
chk_expr "sin(pi/6)"         {math_sin_f(0.5235988)}              0.5         1e-6
chk_expr "sin(pi/2)"         {math_sin_f(1.5707963)}              1.0         1e-6
chk_expr "sin(2)"            {math_sin_f(2.0)}                    0.9092974   1e-6
chk_expr "sin(-1)"           {math_sin_f(0.0 - 1.0)}             -0.8414710   1e-6
chk_expr "sin(10) wraps"     {math_sin_f(10.0)}                  -0.5440211   1e-5
chk_expr "sin(-10) wraps"    {math_sin_f(0.0 - 10.0)}             0.5440211   1e-5
chk_expr "cos(0)"            {math_cos_f(0.0)}                    1.0         1e-6
chk_expr "cos(1)"            {math_cos_f(1.0)}                    0.5403023   1e-6
chk_expr "cos(3)"            {math_cos_f(3.0)}                   -0.9899925   1e-6
chk_expr "tan(0.5)"          {math_tan_f(0.5)}                    0.5463025   1e-5

chk_expr "sqrt(2)"           {math_sqrt_f(2.0)}                   1.4142136   1e-6
chk_expr "sqrt(100)"         {math_sqrt_f(100.0)}                10.0         1e-5
chk_expr "sqrt below one"    {math_sqrt_f(0.0625)}                0.25        1e-7
chk_expr "sqrt(1e6)"         {math_sqrt_f(1000000.0)}          1000.0         1e-3
chk_expr "sqrt(0)"           {math_sqrt_f(0.0)}                   0.0         0.0

chk_expr "atan2 first octant"  {math_atan2_f(1.0, 1.0)}           0.7853982   1e-4
chk_expr "atan2 straight up"   {math_atan2_f(1.0, 0.0)}           1.5707963   1e-4
chk_expr "atan2 straight left" {math_atan2_f(0.0, 0.0 - 1.0)}     3.1415927   1e-4
chk_expr "atan2 third quadrant" {math_atan2_f(0.0 - 1.0, 0.0 - 1.0)} -2.3561945 1e-4
chk_expr "atan2 shallow"       {math_atan2_f(0.1, 1.0)}           0.0996687   1e-4
chk_expr "atan2 at the origin" {math_atan2_f(0.0, 0.0)}           0.0         0.0

chk_expr "pow(2,10)"         {math_pow_f(2.0, 10.0)}           1024.0         1e-1
chk_expr "pow(9,0.5)"        {math_pow_f(9.0, 0.5)}               3.0         1e-4
chk_expr "pow(x,0)"          {math_pow_f(7.0, 0.0)}               1.0         0.0
chk_expr "pow negative base" {math_pow_f(0.0 - 2.0, 3.0)}        -8.0         1e-3
chk_expr "pow(e,1)"          {math_pow_f(2.7182818, 1.0)}         2.7182818   1e-4

chk_expr "floor(-1.5)"       {math_floor_f(0.0 - 1.5)}           -2.0         0.0
chk_expr "floor(1.5)"        {math_floor_f(1.5)}                  1.0         0.0
chk_expr "floor of an exact" {math_floor_f(0.0 - 2.0)}           -2.0         0.0
chk_expr "ceil(1.2)"         {math_ceil_f(1.2)}                   2.0         0.0
chk_expr "ceil(-1.2)"        {math_ceil_f(0.0 - 1.2)}            -1.0         0.0
chk_expr "abs(-3.5)"         {math_abs_f(0.0 - 3.5)}              3.5         0.0
chk_expr "min_f"             {math_min_f(2.0, 1.0)}               1.0         0.0
chk_expr "max_f"             {math_max_f(2.0, 1.0)}               2.0         0.0
chk_expr "clamp_f low"       {math_clamp_f(0.0, 1.0, 5.0)}        1.0         0.0
chk_expr "clamp_f high"      {math_clamp_f(9.0, 1.0, 5.0)}        5.0         0.0

chk_expr "fix_to_f(65536)"   {math_fix_to_f(65536)}               1.0         0.0
chk_expr "f_to_fix round trip" {math_fix_to_f(math_f_to_fix(1.25))} 1.25      1e-5
chk_expr "fix_sin(pi/2)"     {math_fix_to_f(math_fix_sin(102944))} 1.0        1e-4
chk_expr "fix_sqrt(4)"       {math_fix_to_f(math_fix_sqrt(262144))} 2.0       1e-4

puts ""
puts "== integer helpers =="

chk "min_i32 / max_i32 / clamp_i32 / abs_i32" {
    let a: i32 = math_min_i32(3, 7)
    let b: i32 = math_max_i32(3, 7)
    let c: i32 = math_clamp_i32(99, 0, 10)
    let d: i32 = math_abs_i32(0 - 5)
    __out = ((a * 1000 + b * 100 + c * 10 + d) as f32)
} 3805.0 0.0

puts ""
puts "== the PRNG matches runtime/pak_rand.h =="

# xorshift32 from the same default seed. The first three values are what the
# C runtime's __pak_rand() produces, so a program seeded identically sees the
# same stream on either backend.
proc xorshift {x n} {
    for {set i 0} {$i < $n} {incr i} {
        set x [expr {($x ^ ($x << 13)) & 0xFFFFFFFF}]
        set x [expr {$x ^ ($x >> 17)}]
        set x [expr {($x ^ ($x << 5)) & 0xFFFFFFFF}]
    }
    return $x
}
foreach n {1 2 3} {
    set want [xorshift 0x2545F491 $n]
    set calls ""
    for {set i 0} {$i < $n} {incr i} { append calls "    let v$i: u32 = math_rand()\n" }
    chk "rand() #$n" "$calls    __out = ((v[expr {$n-1}] >> 8) as f32)" \
        [expr {double($want >> 8)}] 0.0
}

chk "rand_seed makes it repeat" {
    math_rand_seed(12345)
    let a: u32 = math_rand()
    math_rand_seed(12345)
    let b: u32 = math_rand()
    if a == b { __out = 1.0 } else { __out = 0.0 }
} 1.0 0.0

chk "rand_range stays inside its bounds" {
    math_rand_seed(1)
    let mut good: i32 = 1
    let mut i: i32 = 0
    while i < 200 {
        let v: i32 = math_rand_range(10, 20)
        if v < 10 or v >= 20 { good = 0 }
        i = i + 1
    }
    __out = (good as f32)
} 1.0 0.0

chk {rand_f stays in [0,1)} {
    math_rand_seed(7)
    let mut good: i32 = 1
    let mut i: i32 = 0
    while i < 200 {
        let v: f32 = math_rand_f()
        if v < 0.0 or v >= 1.0 { good = 0 }
        i = i + 1
    }
    __out = (good as f32)
} 1.0 0.0

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
