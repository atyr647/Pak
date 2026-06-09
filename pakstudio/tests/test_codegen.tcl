#!/usr/bin/env tclsh
# tests/test_codegen.tcl — generate .pk64 from a default project, pak check it

set here [file dirname [file normalize [info script]]]
source [file join $here .. app project.tcl]
source [file join $here .. codegen platformer.tcl]
source [file join $here .. app codegen.tcl]
source [file join $here .. app validate.tcl]

# ── helpers ──────────────────────────────────────────────────────────────────

set pass 0
set fail 0

proc assert {desc cond} {
    global pass fail
    if {[uplevel 1 [list expr $cond]]} {
        puts "  PASS: $desc"
        incr pass
    } else {
        puts "  FAIL: $desc"
        incr fail
    }
}

proc assert_eq {desc got expected} {
    global pass fail
    if {$got eq $expected} {
        puts "  PASS: $desc"
        incr pass
    } else {
        puts "  FAIL: $desc"
        puts "        expected: $expected"
        puts "        got:      $got"
        incr fail
    }
}

# ── Test: default project generates without error ─────────────────────────────

puts "\n=== generate: default platformer project ==="
set doc [project::new platformer "Test Game"]
set files [codegen::generate $doc]

assert "generates pak.toml"    {[dict exists $files "pak.toml"]}
assert "generates main.pk64"   {[dict exists $files "src/main.pk64"]}

set toml [dict get $files "pak.toml"]
assert "toml has project section"  {[string match "*\[project\]*" $toml]}
assert "toml has display section"  {[string match "*\[display\]*" $toml]}

set pak [dict get $files "src/main.pk64"]
assert "pak has use n64.display"   {[string match "*use n64.display*" $pak]}
assert "pak has entry block"       {[string match "*\nentry \{*" $pak]}
assert "pak has player_update"     {[string match "*fn player_update*" $pak]}
assert "pak has render_level"      {[string match "*fn render_level*" $pak]}
assert "pak has Phase enum"        {[string match "*enum Phase*" $pak]}
assert "pak has GameState struct"  {[string match "*struct GameState*" $pak]}
assert "pak has no &&"             {![string match "*&&*" $pak]}
assert "pak has no ||"             {![string match "*||*" $pak]}
assert "pak has no null"           {![string match "* null *" $pak]}
assert "pak has no semicolons"     {![regexp {\w;\s*$} $pak]}

# ── Test: pak check passes ────────────────────────────────────────────────────

puts "\n=== pak check: default project ==="
set result [validate::check_doc $doc]
if {[dict get $result ok]} {
    puts "  PASS: pak check clean"
    incr pass
} else {
    puts "  FAIL: pak check reported errors:"
    foreach line [split [dict get $result errors] "\n"] {
        if {$line ne ""} { puts "    $line" }
    }
    incr fail
}

# ── Test: project with coins passes pak check ─────────────────────────────────

puts "\n=== pak check: project with coins and enemies ==="
set doc2 [project::new platformer "Coin Game"]
project::add_object 0 [dict create type coin x 5 y 12]
project::add_object 0 [dict create type coin x 8 y 12]
project::add_object 0 [dict create type enemy_patrol x 12 y 12]

# The project module modifies doc in place; grab it
set doc2 [project::current_doc]

set result2 [validate::check_doc $doc2]
if {[dict get $result2 ok]} {
    puts "  PASS: pak check clean with entities"
    incr pass
} else {
    puts "  FAIL: pak check errors with entities:"
    foreach line [split [dict get $result2 errors] "\n"] {
        if {$line ne ""} { puts "    $line" }
    }
    incr fail
}

# ── Test: physics constants injected correctly ────────────────────────────────

puts "\n=== codegen: physics values ==="
set doc3 [project::new platformer "Physics Test"]
project::set_field physics gravity 0.5
project::set_field physics jump_force -9.0
set doc3 [project::current_doc]
set files3 [codegen::generate $doc3]
set pak3   [dict get $files3 "src/main.pk64"]
assert "gravity=0.5 in generated code"   {[string match "*const GRAVITY*= 0.5*" $pak3]}
assert "jump_force=-9.0 in generated code" {[string match "*const JUMP_FORCE*= -9.0*" $pak3]}

# ── Summary ───────────────────────────────────────────────────────────────────

puts ""
puts "Results: $pass passed, $fail failed"
if {$fail > 0} { exit 1 }
