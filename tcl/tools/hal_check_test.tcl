#!/usr/bin/env tclsh
# HAL contract tests: MODULE_API existence (E010) and --backend mips
# rejecting anything not defined in runtime/standalone/runtime.pk64.

set HERE [file dirname [file normalize [info script]]]
set REPO [file normalize [file join $HERE .. ..]]
source [file join $HERE .. parser.tcl]
source [file join $HERE .. checker.tcl]

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

puts "== MODULE_API existence (C backend) =="
set ast [parse_src "use n64.display
entry { display.init(0, 2, 3, 0, 1) }
"]
set diags [pak::semantic_check $ast "t.pk64" c]
ok "known display.init is clean" [expr {[llength $diags] == 0}] $diags

set ast [parse_src "use n64.display
entry { display.not_a_real_api() }
"]
set diags [pak::semantic_check $ast "t.pk64" c]
ok "unknown method is E010" [has_code $diags E010] [codes $diags]
ok "unknown method message names the method" \
    [string match "*not_a_real_api*" [dict get [lindex $diags 0] message]] \
    [dict get [lindex $diags 0] message]

set ast [parse_src "entry { n64.display.not_a_real_api() }
"]
set diags [pak::semantic_check $ast "t.pk64" c]
ok "fully-qualified unknown method is E010" [has_code $diags E010] [codes $diags]

puts "== standalone HAL (mips backend) =="
set ast [parse_src "use n64.display
use n64.rdpq
entry {
    display.init(0, 2, 3, 0, 1)
    rdpq.init()
}
"]
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "display+rdpq accepted on mips" [expr {[llength $diags] == 0}] $diags

set ast [parse_src "use n64.audio
entry { audio.init(22050, 1) }
"]
set diags [pak::semantic_check $ast "t.pk64" c]
ok "audio.init accepted on libdragon" [expr {[llength $diags] == 0}] $diags
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "audio.init is E010 on mips" [has_code $diags E010] [codes $diags]

set ast [parse_src "use n64.eeprom
entry { eeprom.present() }
"]
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "eeprom.present is E010 on mips" [has_code $diags E010] [codes $diags]

set ast [parse_src "use n64.sprite
entry { sprite.load(\"a.sprite\") }
"]
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "sprite.load is E010 on mips" [has_code $diags E010] [codes $diags]

set ast [parse_src "use n64.display as disp
entry { disp.init(0, 2, 3, 0, 1) }
"]
set diags [pak::semantic_check $ast "t.pk64" c]
ok "use-as alias resolves to MODULE_API" [expr {[llength $diags] == 0}] $diags
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "use-as alias accepted on mips for HAL fn" [expr {[llength $diags] == 0}] $diags

puts "== tables =="
ok "MODULE_API is non-empty" [expr {[llength [pak::module_api_keys]] > 50}] \
    [llength [pak::module_api_keys]]
ok "display_init is in the HAL" [pak::mips_hal_symbol display_init]
ok "audio_init is not in the HAL" [expr {![pak::mips_hal_symbol audio_init]}]
ok "sprite_load is not in the HAL" [expr {![pak::mips_hal_symbol sprite_load]}]
ok "rdpq_triangle_tex is in the HAL" [pak::mips_hal_symbol rdpq_triangle_tex]
ok "rdpq_set_tile_mask is in the HAL" [pak::mips_hal_symbol rdpq_set_tile_mask]
ok "rdpq_triangle_shade is in the HAL" [pak::mips_hal_symbol rdpq_triangle_shade]
ok "rdpq_triangle_shade_z is in the HAL" [pak::mips_hal_symbol rdpq_triangle_shade_z]
ok "rdpq_clear_z is in the HAL" [pak::mips_hal_symbol rdpq_clear_z]
ok "exception_paint is in the HAL" [pak::mips_hal_symbol exception_paint]
ok "exception_set_handler is in the HAL" [pak::mips_hal_symbol exception_set_handler]

set ast [parse_src "use n64.exception
entry { exception.set_handler(0 as *u8) }
"]
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "exception.set_handler accepted on mips" [expr {[llength $diags] == 0}] $diags

set ast [parse_src "use n64.rdpq
entry { rdpq.triangle_tex(0, 0, 0, 0, 0, 32, 0, 32, 0, 0, 32, 0, 32) }
"]
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "triangle_tex accepted on mips" [expr {[llength $diags] == 0}] $diags

set ast [parse_src "use n64.rdpq
entry { rdpq.triangle_shade(0, 0, 0xFF0000FF, 32, 0, 0x00FF00FF, 0, 32, 0x0000FFFF) }
"]
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "triangle_shade accepted on mips" [expr {[llength $diags] == 0}] $diags

set ast [parse_src "entry { n64.rdpq.set_texture_image(0x80001000, 0, 2, 32) }
"]
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "KSEG0 texture addr is E203" [has_code $diags E203] [codes $diags]

set ast [parse_src "entry { n64.rdpq.set_texture_image(0xA0300000, 0, 2, 32) }
"]
set diags [pak::semantic_check $ast "t.pk64" mips]
ok "KSEG1 texture addr is clean" [expr {![has_code $diags E203]}] [codes $diags]

puts ""
puts "PASS=$::pass  FAIL=$::fail"
if {$::fail > 0} { exit 1 }
