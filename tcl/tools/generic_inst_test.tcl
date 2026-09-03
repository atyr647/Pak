#!/usr/bin/env tclsh
# tcl/tools/generic_inst_test.tcl — week-5: check generic bodies at the
# instantiation, not only at the unspecialized definition.
#
#   E015 — explicit type-arg count does not match the function's type params
#   E016 — after T is concrete, field access on a primitive is an error
# A well-typed instantiation (identity<i32>, max_of on i32, field access on
# a struct) stays clean.

set HERE [file dirname [file normalize [info script]]]
source [file join $HERE .. parser.tcl]
source [file join $HERE .. typechecker.tcl]

set ::pass 0
set ::fail 0

proc ok {name cond {detail ""}} {
    if {$cond} {
        incr ::pass; puts "ok    $name"
    } else {
        incr ::fail; puts "FAIL  $name $detail"
    }
}

proc parse_src {src} {
    set lx [pak::Lexer new $src]
    return [pak::parse_tokens [$lx tokenize]]
}

proc codes {diags} {
    set out {}
    foreach d $diags { lappend out [dict get $d code] }
    return $out
}

proc has_code {diags code} {
    expr {$code in [codes $diags]}
}

proc msgs {diags} {
    set out {}
    foreach d $diags { lappend out [dict get $d message] }
    return [join $out {; }]
}

puts "== well-typed instantiations stay clean =="

set ast [parse_src {
fn identity<T>(x: T) -> T { return x }
entry { let a: i32 = identity(42); let b: i32 = identity<i32>(99) }
}]
set diags [pak::typecheck $ast "t.pk64"]
ok "identity inferred + explicit is clean" [expr {[llength $diags] == 0}] [codes $diags]

set ast [parse_src {
fn max_of<T>(a: T, b: T) -> T {
    if a > b { return a }
    return b
}
entry { let m: i32 = max_of(3, 7) }
}]
set diags [pak::typecheck $ast "t.pk64"]
ok "max_of<i32> is clean" [expr {[llength $diags] == 0}] [codes $diags]

set ast [parse_src {
struct Point { x: i32 y: i32 }
fn get_x<T>(p: T) -> i32 { return p.x }
entry { let n: i32 = get_x(Point { x: 1, y: 2 }) }
}]
set diags [pak::typecheck $ast "t.pk64"]
ok "get_x(Point) is clean" [expr {[llength $diags] == 0}] [msgs $diags]

puts "== E015 type-arg count =="

set ast [parse_src {
fn identity<T>(x: T) -> T { return x }
entry { let a: i32 = identity<i32, i32>(42) }
}]
set diags [pak::typecheck $ast "t.pk64"]
ok "identity<i32, i32> is E015" [has_code $diags E015] [codes $diags]
ok "E015 names the function" [string match "*identity*" [msgs $diags]] [msgs $diags]
ok "E015 says 1 vs 2" [regexp {takes 1 type argument.*got 2} [msgs $diags]] [msgs $diags]

set ast [parse_src {
fn pair<A, B>(a: A, b: B) -> A { return a }
entry { let a: i32 = pair<i32>(1, 2) }
}]
set diags [pak::typecheck $ast "t.pk64"]
ok "pair<i32> (needs 2) is E015" [has_code $diags E015] [codes $diags]

puts "== E016 field access after instantiation =="

set ast [parse_src {
fn get_x<T>(p: T) -> i32 { return p.x }
entry { let n: i32 = get_x(42) }
}]
set diags [pak::typecheck $ast "t.pk64"]
ok "get_x(42) is E016" [has_code $diags E016] [codes $diags]
ok "E016 names i32" [string match "*i32*" [msgs $diags]] [msgs $diags]
ok "E016 names the field" [string match "*x*" [msgs $diags]] [msgs $diags]

set ast [parse_src {
fn get_x<T>(p: T) -> i32 { return p.x }
fn identity<T>(x: T) -> T { return x }
entry { let a: i32 = identity(1) }
}]
set diags [pak::typecheck $ast "t.pk64"]
ok "uninstantiated generic body is not E016" [expr {![has_code $diags E016]}] [codes $diags]

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
