#!/usr/bin/env tclsh
# tests/test_project.tcl — project model: create, mutate, save, load

set here [file dirname [file normalize [info script]]]
source [file join $here .. app project.tcl]

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
        puts "  FAIL: $desc — got '$got' expected '$expected'"
        incr fail
    }
}

# ── new project structure ────────────────────────────────────────────────────

puts "\n=== project::new structure ==="
set doc [project::new platformer "My Game"]

assert "has schema"      {[dict exists $doc schema]}
assert "has meta"        {[dict exists $doc meta]}
assert "has settings"    {[dict exists $doc settings]}
assert "has physics"     {[dict exists $doc physics]}
assert "has levels"      {[dict exists $doc levels]}
assert "has tilesets"    {[dict exists $doc tilesets]}
assert "has entities"    {[dict exists $doc entities]}
assert "has audio"       {[dict exists $doc audio]}

assert_eq "genre is platformer" [dict get $doc meta genre] "platformer"
assert_eq "name is set"         [dict get $doc meta name]  "My Game"
assert_eq "schema version"      [dict get $doc schema]     1

# ── default level ────────────────────────────────────────────────────────────

puts "\n=== default level ==="
set lvl0 [lindex [dict get $doc levels] 0]
assert_eq "level width"  [dict get $lvl0 width]  32
assert_eq "level height" [dict get $lvl0 height] 15
assert    "tiles list"   {[llength [dict get $lvl0 tiles]] == 480}
assert    "has player_start" {[llength [dict get $lvl0 objects]] >= 1}

# ── default physics ─────────────────────────────────────────────────────────

puts "\n=== default physics ==="
set phys [dict get $doc physics]
assert "has gravity"      {[dict exists $phys gravity]}
assert "has jump_force"   {[dict exists $phys jump_force]}
assert "has move_speed"   {[dict exists $phys move_speed]}
assert "gravity positive" {[dict get $phys gravity] > 0}
assert "jump_force neg"   {[dict get $phys jump_force] < 0}

# ── set_tile ─────────────────────────────────────────────────────────────────

puts "\n=== set_tile ==="
project::set_tile 0 5 5 1
set doc2 [project::current_doc]
set lvl [lindex [dict get $doc2 levels] 0]
set W   [dict get $lvl width]
set t   [lindex [dict get $lvl tiles] [expr {5 * $W + 5}]]
assert_eq "tile set to solid" $t 1

project::set_tile 0 5 5 0
set doc2 [project::current_doc]
set lvl  [lindex [dict get $doc2 levels] 0]
set t    [lindex [dict get $lvl tiles] [expr {5 * $W + 5}]]
assert_eq "tile cleared" $t 0

# ── add/remove objects ────────────────────────────────────────────────────────

puts "\n=== add/remove objects ==="
set before [llength [dict get [lindex [dict get [project::current_doc] levels] 0] objects]]
project::add_object 0 [dict create type coin x 10 y 8]
set after  [llength [dict get [lindex [dict get [project::current_doc] levels] 0] objects]]
assert_eq "object added" $after [expr {$before + 1}]

set idx [expr {$after - 1}]
project::remove_object 0 $idx
set final [llength [dict get [lindex [dict get [project::current_doc] levels] 0] objects]]
assert_eq "object removed" $final $before

# ── add_level ────────────────────────────────────────────────────────────────

puts "\n=== add_level ==="
set n_before [llength [dict get [project::current_doc] levels]]
project::add_level
set n_after  [llength [dict get [project::current_doc] levels]]
assert_eq "level count increased" $n_after [expr {$n_before + 1}]

# ── set_field ────────────────────────────────────────────────────────────────

puts "\n=== set_field ==="
project::set_field physics gravity 0.42
set g [dict get [project::current_doc] physics gravity]
assert_eq "gravity updated" $g 0.42

project::set_field meta name "Renamed"
assert_eq "name updated" [dict get [project::current_doc] meta name] "Renamed"

# ── dirty flag ───────────────────────────────────────────────────────────────

puts "\n=== dirty flag ==="
project::new platformer "Clean"
assert "clean after new" {![project::is_dirty]}
project::set_field physics gravity 0.1
assert "dirty after mutation" {[project::is_dirty]}

# ── save / load round-trip ────────────────────────────────────────────────────

puts "\n=== save/load round-trip ==="
project::new platformer "RoundTrip"
project::set_field physics gravity 0.77
project::set_tile 0 3 3 1
set tmp [file join /tmp "pakstudio_test_[pid].pakstudio"]
project::save_to $tmp
assert "file written" {[file exists $tmp]}
assert "not dirty after save" {![project::is_dirty]}

# Fresh load
project::new platformer "Scratch"
project::load_from $tmp
set loaded [project::current_doc]
assert_eq "name preserved" [dict get $loaded meta name]      "RoundTrip"
assert_eq "gravity preserved" [dict get $loaded physics gravity] 0.77
set lvl_loaded [lindex [dict get $loaded levels] 0]
set W [dict get $lvl_loaded width]
set t [lindex [dict get $lvl_loaded tiles] [expr {3 * $W + 3}]]
assert_eq "tile preserved" $t 1
assert "not dirty after load" {![project::is_dirty]}
file delete $tmp

# ── get accessor ─────────────────────────────────────────────────────────────

puts "\n=== get accessor ==="
project::new platformer "AccessTest"
assert_eq "get meta name" [project::get meta name] "AccessTest"
assert_eq "get schema"    [project::get schema]    1

# ── Summary ──────────────────────────────────────────────────────────────────

puts ""
puts "Results: $pass passed, $fail failed"
if {$fail > 0} { exit 1 }
