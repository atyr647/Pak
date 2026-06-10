#!/usr/bin/env tclsh
# tests/test_codegen.tcl — generate gold-standard .pk64 from projects, pak check them.

set here [file dirname [file normalize [info script]]]
source [file join $here .. app project.tcl]
source [file join $here .. codegen platformer.tcl]
source [file join $here .. app codegen.tcl]
source [file join $here .. app validate.tcl]

set pass 0
set fail 0

proc assert {desc cond} {
    global pass fail
    if {[uplevel 1 [list expr $cond]]} {
        puts "  PASS: $desc"; incr pass
    } else {
        puts "  FAIL: $desc"; incr fail
    }
}

proc check_doc_passes {label doc} {
    global pass fail
    set result [validate::check_doc $doc]
    if {[dict get $result ok]} {
        puts "  PASS: $label — pak check clean"; incr pass
    } else {
        puts "  FAIL: $label — pak check errors:"
        foreach line [split [dict get $result errors] "\n"] {
            if {$line ne ""} { puts "        $line" }
        }
        incr fail
    }
}

# ── Structure: default project emits all gold-standard subsystems ─────────────

puts "\n=== generate: default platformer project ==="
set doc [project::new platformer "Test Game"]
set files [codegen::generate $doc]

assert "generates pak.toml"   {[dict exists $files "pak.toml"]}
assert "generates main.pk64"  {[dict exists $files "src/main.pk64"]}

set toml [dict get $files "pak.toml"]
assert "toml has project section"  {[string match "*\[project\]*" $toml]}
assert "toml has display section"  {[string match "*\[display\]*" $toml]}

set pak [dict get $files "src/main.pk64"]

# Engine subsystems
assert "uses display"        {[string match "*use n64.display*" $pak]}
assert "uses audio"          {[string match "*use n64.audio*" $pak]}
assert "uses eeprom"         {[string match "*use n64.eeprom*" $pak]}
assert "has entry block"     {[string match "*\nentry \{*" $pak]}

# Text engine (bitmap font)
assert "has bitmap font init"   {[string match "*fn init_font*" $pak]}
assert "has draw_text"          {[string match "*fn draw_text(*" $pak]}
assert "has draw_number"        {[string match "*fn draw_number(*" $pak]}

# Audio engine
assert "has procedural audio"   {[string match "*fn fill_audio*" $pak]}
assert "has sfx triggers"       {[string match "*fn sfx_jump*" $pak]}
assert "has music table"        {[string match "*fn init_music_table*" $pak]}

# Player / enemies / world
assert "has player_update"      {[string match "*fn player_update*" $pak]}
assert "has enemies_update"     {[string match "*fn enemies_update*" $pak]}
assert "has tile_at dispatch"   {[string match "*fn tile_at(*" $pak]}
assert "has one-way handling"   {[string match "*oneway_land*" $pak]}
assert "has ladder handling"    {[string match "*on_ladder*" $pak]}
assert "has spring handling"    {[string match "*SPRING_FORCE*" $pak]}
assert "has checkpoint respawn" {[string match "*spawn_x*" $pak]}
assert "has invuln frames"      {[string match "*INVULN_F*" $pak]}

# Menus & flow
assert "has 6-phase enum"       {[string match "*enum Phase: u8 \{ title, playing, paused, levelclear, gameover, win \}*" $pak]}
assert "has title render"       {[string match "*fn render_title*" $pak]}
assert "has pause menu"         {[string match "*fn render_pause*" $pak]}
assert "has level clear"        {[string match "*fn render_levelclear*" $pak]}
assert "has win screen"         {[string match "*fn render_win*" $pak]}
assert "has menu selection"     {[string match "*menu_sel*" $pak]}

# Save
assert "has save/load"          {[string match "*fn save_hi*" $pak] && [string match "*fn load_hi*" $pak]}

# Hygiene — Pak forbids these
assert "no &&"          {![string match "*&&*" $pak]}
assert "no ||"          {![string match "*||*" $pak]}
assert "no null"        {![string match "* null *" $pak]}
assert "no semicolons"  {![regexp {\w;\s*$} $pak]}

# Title is sanitised to font charset (uppercase, no symbol leakage)
assert "title is uppercase glyphs" {[string match "*draw_text_centered(\"TEST GAME\"*" $pak]}

# ── pak check across multiple configurations ─────────────────────────────────

puts "\n=== pak check: real compiler across configs ==="

check_doc_passes "default project" [project::new platformer "Test Game"]

set d2 [project::new platformer "Kitchen Sink"]
project::add_object 0 [dict create type coin x 5 y 12]
project::add_object 0 [dict create type coin x 8 y 12]
project::add_object 0 [dict create type enemy_patrol x 12 y 12]
project::add_object 0 [dict create type enemy_jumper x 18 y 12]
project::add_object 0 [dict create type spring x 22 y 13]
project::add_object 0 [dict create type checkpoint x 24 y 12]
project::add_object 0 [dict create type goal x 30 y 12]
check_doc_passes "all entity types" [project::current_doc]

set d3 [project::new platformer "Multi"]
project::add_level
project::add_level
project::add_object 1 [dict create type coin x 4 y 12]
project::add_object 2 [dict create type goal x 28 y 12]
check_doc_passes "three levels" [project::current_doc]

set d4 [project::new platformer "Empty"]
set lvls [dict get $d4 levels]
set l0 [lindex $lvls 0]
dict set l0 objects [list]
lset lvls 0 $l0
dict set d4 levels $lvls
check_doc_passes "level with no objects" $d4

check_doc_passes "weird name" [project::new platformer "Bob's Quest 2! @#"]

# ── Physics injection ─────────────────────────────────────────────────────────

puts "\n=== codegen: physics values injected ==="
set d5 [project::new platformer "Physics"]
project::set_field physics gravity 0.5
project::set_field physics jump_force -9.0
set d5 [project::current_doc]
set pak5 [dict get [codegen::generate $d5] "src/main.pk64"]
assert "gravity 0.5 injected"      {[string match "*const GRAVITY*= 0.5*" $pak5]}
assert "jump_force -9.0 injected"  {[string match "*const JUMP_FORCE*= -9.0*" $pak5]}

# ── Summary ───────────────────────────────────────────────────────────────────

puts ""
puts "Results: $pass passed, $fail failed"
if {$fail > 0} { exit 1 }
