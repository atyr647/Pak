# editors/rpg_world.tcl — Switches, Variables, Shops, and Party/Start settings.
# Switches/Variables/Shops are record lists (rdb); Party & Start is a small form.

namespace eval rpg_world {
    variable W
    array set W {}
}

proc rpg_world::create {parent} {
    variable W
    set f [ttk::frame $parent.world]
    pack $f -fill both -expand 1
    set nb [ttk::notebook $f.nb]
    pack $nb -fill both -expand 1 -padx 2 -pady 2

    set sw [ttk::frame $nb.sw]; $nb add $sw -text "  Switches  "
    rdb::make sw $sw {
        {id   "ID"        str}
        {name "Name"      str}
        {init "Starts ON" combo {0 1}}
    } -addlabel "Switch" -onchange rpg_world::_dirty

    set vr [ttk::frame $nb.vr]; $nb add $vr -text "  Variables  "
    rdb::make vr $vr {
        {id   "ID"      str}
        {name "Name"    str}
        {init "Initial" int {-99999 99999}}
    } -addlabel "Variable" -onchange rpg_world::_dirty

    set sh [ttk::frame $nb.sh]; $nb add $sh -text "  Shops  "
    rdb::make sh $sh {
        {id    "ID"    str}
        {name  "Name"  str}
        {kind  "Kind"  combo {buy_sell buy_only sell_only}}
        {items "Stock" ids "space-separated item ids"}
    } -addlabel "Shop" -onchange rpg_world::_dirty

    set st [ttk::frame $nb.st]; $nb add $st -text "  Party / Start  "
    _build_start $st
    return $f
}

proc rpg_world::_build_start {parent} {
    variable W
    set inner [prop_panel::create $parent]
    set W(inner) $inner
    prop_panel::add_section $inner "Starting Party"
    set W(party) [prop_panel::add_entry $inner "Party (actor ids)" ::rw_party]
    prop_panel::add_section $inner "Start Position"
    set W(map)    [prop_panel::add_spin  $inner "Map Index"  ::rw_map    0 99   1]
    set W(x)      [prop_panel::add_spin  $inner "Tile X"     ::rw_x      0 999  1]
    set W(y)      [prop_panel::add_spin  $inner "Tile Y"     ::rw_y      0 999  1]
    set W(facing) [prop_panel::add_combo $inner "Facing"     ::rw_facing {down up left right}]
    prop_panel::add_section $inner "Economy & Combat"
    set W(gold)   [prop_panel::add_spin  $inner "Starting Gold" ::rw_gold 0 999999 10]
    set W(combat) [prop_panel::add_combo $inner "Default Combat" ::rw_combat {action turn none}]
    foreach v {::rw_party ::rw_map ::rw_x ::rw_y ::rw_facing ::rw_gold ::rw_combat} {
        trace add variable $v write rpg_world::_dirty_trace
    }
}

proc rpg_world::_dirty {} { catch { project::mark_dirty; app::_update_save_indicator } }
proc rpg_world::_dirty_trace {args} { _dirty }

proc rpg_world::load_doc {doc} {
    if {![rpg::is_rpg $doc]} return
    rdb::set_records sw [expr {[dict exists $doc switches]  ? [dict get $doc switches]  : {}}]
    rdb::set_records vr [expr {[dict exists $doc variables] ? [dict get $doc variables] : {}}]
    rdb::set_records sh [expr {[dict exists $doc shops]     ? [dict get $doc shops]     : {}}]
    set rpg [expr {[dict exists $doc rpg] ? [dict get $doc rpg] : {}}]
    set ::rw_party  [expr {[dict exists $rpg party] ? [dict get $rpg party] : ""}]
    set ::rw_gold   [expr {[dict exists $rpg gold_start] ? [dict get $rpg gold_start] : 0}]
    set ::rw_combat [expr {[dict exists $rpg combat_default] ? [dict get $rpg combat_default] : "action"}]
    set start [expr {[dict exists $rpg start] ? [dict get $rpg start] : {}}]
    set ::rw_map    [expr {[dict exists $start map]    ? [dict get $start map]    : 0}]
    set ::rw_x      [expr {[dict exists $start x]      ? [dict get $start x]      : 0}]
    set ::rw_y      [expr {[dict exists $start y]      ? [dict get $start y]      : 0}]
    set ::rw_facing [expr {[dict exists $start facing] ? [dict get $start facing] : "down"}]
}

proc rpg_world::save_to_doc {} {
    if {![rpg::is_rpg [project::current_doc]]} return
    project::set_field switches  [rdb::get_records sw]
    project::set_field variables [rdb::get_records vr]
    project::set_field shops     [rdb::get_records sh]
    project::set_field rpg party          [string trim $::rw_party]
    project::set_field rpg gold_start     $::rw_gold
    project::set_field rpg combat_default $::rw_combat
    project::set_field rpg start [dict create map $::rw_map x $::rw_x y $::rw_y facing $::rw_facing]
}
