# editors/rpg_craft.tcl — Crafting recipe editor.
# Recipes use a compact "item:qty" token syntax in the form; load/save convert
# to/from the structured schema {inputs[{item qty}] output{item qty}}.

namespace eval rpg_craft {}

proc rpg_craft::create {parent} {
    set f [ttk::frame $parent.craft]
    pack $f -fill both -expand 1
    ttk::label $f.hint -style Subtitle.TLabel -anchor w \
        -text "Recipes turn ingredients into an item. Use item:qty tokens, e.g.  herb:2 iron_ore:1"
    pack $f.hint -fill x -padx 8 -pady {6 0}
    set body [ttk::frame $f.body]
    pack $body -fill both -expand 1
    rdb::make craft $body {
        {id      "ID"          str}
        {name    "Recipe Name" str}
        {station "Station"     combo {alchemy forge cooking tailor any}}
        {inputs  "Ingredients" ids "item:qty tokens, space-separated"}
        {output  "Produces"    ids "single item:qty"}
    } -addlabel "Recipe" -onchange rpg_craft::_dirty
    return $f
}

proc rpg_craft::_dirty {} { catch { project::mark_dirty; app::_update_save_indicator } }

# {inputs[{item h qty 2}...]} -> "herb:2 iron_ore:1"
proc rpg_craft::_enc_inputs {lst} {
    set out {}
    foreach e $lst { lappend out "[dict get $e item]:[dict get $e qty]" }
    return [join $out " "]
}
proc rpg_craft::_dec_inputs {s} {
    set out {}
    foreach tok $s {
        lassign [split $tok ":"] item qty
        if {$item eq ""} continue
        if {$qty eq ""} { set qty 1 }
        lappend out [dict create item $item qty $qty]
    }
    return $out
}
proc rpg_craft::_enc_output {d} {
    if {![dict size $d]} { return "" }
    return "[dict get $d item]:[dict get $d qty]"
}
proc rpg_craft::_dec_output {s} {
    set tok [lindex $s 0]
    if {$tok eq ""} { return {} }
    lassign [split $tok ":"] item qty
    if {$qty eq ""} { set qty 1 }
    return [dict create item $item qty $qty]
}

proc rpg_craft::load_doc {doc} {
    if {![rpg::is_rpg $doc]} return
    set recs {}
    foreach r [expr {[dict exists $doc recipes] ? [dict get $doc recipes] : {}}] {
        dict set r inputs [_enc_inputs [expr {[dict exists $r inputs] ? [dict get $r inputs] : {}}]]
        dict set r output [_enc_output [expr {[dict exists $r output] ? [dict get $r output] : {}}]]
        lappend recs $r
    }
    rdb::set_records craft $recs
}

proc rpg_craft::save_to_doc {} {
    if {![rpg::is_rpg [project::current_doc]]} return
    set recs {}
    foreach r [rdb::get_records craft] {
        dict set r inputs [_dec_inputs [expr {[dict exists $r inputs] ? [dict get $r inputs] : ""}]]
        dict set r output [_dec_output [expr {[dict exists $r output] ? [dict get $r output] : ""}]]
        lappend recs $r
    }
    project::set_field recipes $recs
}
