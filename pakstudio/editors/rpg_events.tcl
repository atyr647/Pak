# editors/rpg_events.tcl — the Event editor (the heart of the RPG maker).
#
# Model (authentic RPG-Maker style):
#   map -> events[] -> pages[] -> commands[]
# A page has gating `conditions` and a flat, indented command list. Control-flow
# commands (if/else/end_if, choice/when/end_choice) nest visually via depth; the
# runtime interpreter walks the flat list with a branch stack. Everything else is
# a linear command (text, give_item, teleport, battle, …).

namespace eval rpg_ev {
    variable maps    {}   ;# working copy of doc levels
    variable mi      -1   ;# selected map index
    variable ei      -1   ;# selected event index
    variable pi      0    ;# selected page index
    variable ci      -1   ;# selected command index
    variable W
    array set W {}
}

# ── Command vocabulary for the Add menu (includes control-flow markers) ──────
proc rpg_ev::ops_menu {} {
    return {
        text          "Show Text"
        choice        "Show Choices >"
        when          "   When (choice branch)"
        end_choice    "   End Choices"
        if            "Condition >"
        else          "   Else"
        end_if        "   End Condition"
        switch        "Set Switch"
        var           "Set Variable"
        give_item     "Give Item"
        take_item     "Remove Item"
        gold          "Change Gold"
        give_skill    "Teach Skill"
        recruit       "Add Party Member"
        quest_start   "Start Quest"
        quest_advance "Advance Quest"
        quest_done    "Complete Quest"
        teleport      "Teleport"
        shop          "Open Shop"
        craft         "Open Crafting"
        battle        "Start Battle"
        heal          "Heal Party"
        sfx           "Play Sound"
        music         "Play Music"
        wait          "Wait"
        move_npc      "Move This Event"
        set_graphic   "Change Graphic"
        comment       "Comment"
    }
}

# Per-op argument field specs: {key label type ?choices-token?}.
# choices-token names a doc list whose ids fill a combobox: items skills quests
# switches variables shops troops maps dialogues actors music sfx.
proc rpg_ev::op_fields {op} {
    switch $op {
        text          { return {{speaker "Speaker" str} {text "Text" multi}} }
        choice        { return {{prompt "Prompt" str}} }
        when          { return {{label "Choice Label" str}} }
        if            { return {{kind "Condition" combo:cond} {target "Target id" str} {value "Value" str}} }
        switch        { return {{id "Switch" combo:switches} {value "Value" combo:onoff}} }
        var           { return {{id "Variable" combo:variables} {vop "Operation" combo:varop} {value "Value" int}} }
        give_item     { return {{item "Item" combo:items} {qty "Qty" int {1 99}}} }
        take_item     { return {{item "Item" combo:items} {qty "Qty" int {1 99}}} }
        gold          { return {{amount "Amount (+/-)" int {-99999 99999}}} }
        give_skill    { return {{skill "Skill" combo:skills}} }
        recruit       { return {{actor "Actor" combo:actors}} }
        quest_start   { return {{quest "Quest" combo:quests}} }
        quest_advance { return {{quest "Quest" combo:quests} {stage "Stage id" str}} }
        quest_done    { return {{quest "Quest" combo:quests}} }
        teleport      { return {{map "Map" combo:maps} {x "Tile X" int} {y "Tile Y" int} {facing "Facing" combo:facing}} }
        shop          { return {{shop "Shop" combo:shops}} }
        craft         { return {{station "Station" combo:station}} }
        battle        { return {{troop "Troop" combo:troops}} }
        sfx           { return {{id "Sound" str}} }
        music         { return {{id "Music" str}} }
        wait          { return {{frames "Frames" int {1 600}}} }
        move_npc      { return {{dir "Direction" combo:facing} {steps "Steps" int {1 20}}} }
        set_graphic   { return {{graphic "Graphic" str}} }
        comment       { return {{text "Comment" multi}} }
        default       { return {} }
    }
}

proc rpg_ev::_combo_values {token doc} {
    switch -glob $token {
        combo:cond      { set out {}; foreach {k l} [rpg::cond_kinds] { lappend out $k }; return $out }
        combo:onoff     { return {1 0} }
        combo:varop     { return {set add sub} }
        combo:facing    { return {down up left right} }
        combo:station   { return {alchemy forge cooking tailor any} }
        combo:items     { return [rdb::doc_ids $doc database items] }
        combo:skills    { return [rdb::doc_ids $doc database skills] }
        combo:actors    { return [rdb::doc_ids $doc database actors] }
        combo:troops    { return [rdb::doc_ids $doc database troops] }
        combo:quests    { return [rdb::doc_ids $doc quests] }
        combo:switches  { return [rdb::doc_ids $doc switches] }
        combo:variables { return [rdb::doc_ids $doc variables] }
        combo:shops     { return [rdb::doc_ids $doc shops] }
        combo:maps      {
            set out {}; set i 0
            foreach m [dict get $doc levels] { lappend out $i; incr i }
            return $out
        }
        default { return {} }
    }
}

# ── UI ───────────────────────────────────────────────────────────────────────
proc rpg_ev::create {parent} {
    variable W
    set f [ttk::frame $parent.ev]
    pack $f -fill both -expand 1

    # Map selector
    set top [ttk::frame $f.top]
    pack $top -fill x -padx 6 -pady {6 2}
    ttk::label $top.l -text "Map:"
    ttk::combobox $top.cmb -textvariable ::rpg_ev_map -state readonly -width 28
    bind $top.cmb <<ComboboxSelected>> rpg_ev::_on_map
    pack $top.l $top.cmb -side left -padx {0 6}
    set W(mapcmb) $top.cmb

    set pw [ttk::panedwindow $f.pw -orient horizontal]
    pack $pw -fill both -expand 1 -padx 4 -pady 4

    # ── Events list ─────────────────────────────────────────────────────────
    set evcol [ttk::frame $pw.evs -width 170]
    $pw add $evcol -weight 0
    pack propagate $evcol 0
    ttk::label $evcol.h -text "EVENTS" -style Section.TLabel
    pack $evcol.h -anchor w -padx 6 -pady {2 2}
    set lb [listbox $evcol.lb -bg #1a1f2e -fg #dde4f0 -selectbackground #1a3f72 \
        -selectforeground #dde4f0 -borderwidth 0 -highlightthickness 0 \
        -activestyle none -font {TkDefaultFont 9}]
    pack $lb -fill both -expand 1
    bind $lb <<ListboxSelect>> rpg_ev::_on_event
    set W(evlb) $lb
    set bf [ttk::frame $evcol.bf]; pack $bf -fill x -pady {4 0}
    ttk::button $bf.add -text "+ Event" -style Toolbutton -command rpg_ev::_add_event
    ttk::button $bf.del -text "Del" -style Toolbutton -width 4 -command rpg_ev::_del_event
    pack $bf.add $bf.del -side left -padx 1

    # ── Event properties + page ──────────────────────────────────────────────
    set mid [ttk::frame $pw.mid -width 230]
    $pw add $mid -weight 0
    pack propagate $mid 0
    set inner [prop_panel::create $mid]
    set W(props) $inner

    # ── Command list ──────────────────────────────────────────────────────────
    set cmdcol [ttk::frame $pw.cmds]
    $pw add $cmdcol -weight 1
    ttk::label $cmdcol.h -text "EVENT COMMANDS" -style Section.TLabel
    pack $cmdcol.h -anchor w -padx 6 -pady {2 2}
    set clb [listbox $cmdcol.lb -bg #161b28 -fg #cfe0f5 \
        -selectbackground #244066 -selectforeground #ffffff \
        -borderwidth 0 -highlightthickness 0 -activestyle none \
        -font {TkFixedFont 9}]
    pack $clb -fill both -expand 1
    bind $clb <<ListboxSelect>> rpg_ev::_on_cmd
    bind $clb <Double-1> rpg_ev::_edit_cmd
    set W(cmdlb) $clb
    set cbf [ttk::frame $cmdcol.bf]; pack $cbf -fill x -pady {4 0}
    ttk::menubutton $cbf.add -text "+ Add Command" -style Toolbutton -menu $cbf.add.m
    menu $cbf.add.m -tearoff 0
    foreach {op lbl} [ops_menu] {
        $cbf.add.m add command -label $lbl -command [list rpg_ev::_add_cmd $op]
    }
    ttk::button $cbf.edit -text "Edit"  -style Toolbutton -command rpg_ev::_edit_cmd
    ttk::button $cbf.up   -text "Up"    -style Toolbutton -width 4 -command [list rpg_ev::_move_cmd -1]
    ttk::button $cbf.dn   -text "Dn"    -style Toolbutton -width 4 -command [list rpg_ev::_move_cmd 1]
    ttk::button $cbf.del  -text "Del"   -style Toolbutton -width 4 -command rpg_ev::_del_cmd
    pack $cbf.add $cbf.edit $cbf.up $cbf.dn $cbf.del -side left -padx 1
    return $f
}

# ── Data plumbing ─────────────────────────────────────────────────────────────
proc rpg_ev::_dirty {} { catch { project::mark_dirty; app::_update_save_indicator } }

proc rpg_ev::_cur_event {} {
    variable maps; variable mi; variable ei
    if {$mi < 0 || $ei < 0} { return {} }
    set evs [_map_events [lindex $maps $mi]]
    return [lindex $evs $ei]
}
proc rpg_ev::_map_events {m} {
    return [expr {[dict exists $m events] ? [dict get $m events] : {}}]
}
proc rpg_ev::_set_cur_event {ev} {
    variable maps; variable mi; variable ei
    set m [lindex $maps $mi]
    set evs [_map_events $m]
    lset evs $ei $ev
    dict set m events $evs
    lset maps $mi $m
    _dirty
}
proc rpg_ev::_cur_commands {} {
    variable pi
    set ev [_cur_event]
    if {$ev eq {}} { return {} }
    set pages [dict get $ev pages]
    set page [lindex $pages $pi]
    return [expr {[dict exists $page commands] ? [dict get $page commands] : {}}]
}
proc rpg_ev::_set_cur_commands {cmds} {
    variable pi
    set ev [_cur_event]
    set pages [dict get $ev pages]
    set page [lindex $pages $pi]
    dict set page commands $cmds
    lset pages $pi $page
    dict set ev pages $pages
    _set_cur_event $ev
}

proc rpg_ev::load_doc {doc} {
    variable maps; variable mi
    if {![rpg::is_rpg $doc]} return
    set maps [dict get $doc levels]
    set names {}
    set i 0
    foreach m $maps { lappend names "$i  [dict get $m name]"; incr i }
    $rpg_ev::W(mapcmb) configure -values $names
    set mi [expr {[llength $maps] > 0 ? 0 : -1}]
    if {$mi >= 0} { set ::rpg_ev_map [lindex $names 0] }
    _refresh_events
}

proc rpg_ev::save_to_doc {} {
    variable maps
    if {![rpg::is_rpg [project::current_doc]]} return
    project::set_field levels $maps
}

proc rpg_ev::_on_map {} {
    variable mi
    set mi [$rpg_ev::W(mapcmb) current]
    set rpg_ev::ei -1
    set rpg_ev::pi 0
    _refresh_events
}

# Programmatically switch to map $idx — called by the left panel list.
proc rpg_ev::goto_map {idx} {
    variable maps; variable mi; variable W
    if {$idx < 0 || $idx >= [llength $maps]} return
    set mi $idx
    set rpg_ev::ei -1
    set rpg_ev::pi 0
    if {[info exists W(mapcmb)] && [winfo exists $W(mapcmb)]} {
        $W(mapcmb) current $idx
    }
    _refresh_events
}

# Add a blank map and reload — called by left panel "+ Add Map".
proc rpg_ev::add_map {} {
    variable maps
    set ref [expr {[llength $maps] > 0 ? [lindex $maps 0] : {}}]
    set w [expr {[dict exists $ref width]  ? [dict get $ref width]  : 20}]
    set h [expr {[dict exists $ref height] ? [dict get $ref height] : 15}]
    set id [llength $maps]
    set tiles [lrepeat [expr {$w * $h}] 1]
    set newmap [dict create \
        id $id name "Map [expr {$id + 1}]" \
        width $w height $h tileset 0 \
        bg_color "0x1B3A24FF" music "" \
        combat_mode none encounter_rate 0 troops {} \
        layer_ground $tiles layer_deco [lrepeat [expr {$w*$h}] 0] \
        layer_coll   [lrepeat [expr {$w*$h}] 0] \
        tiles $tiles objects {} events {}]
    lappend maps $newmap
    save_to_doc
    load_doc [project::current_doc]
    goto_map $id
    catch { app::_refresh_level_list }
}

# Delete map at $idx — called by left panel "− Remove".
proc rpg_ev::del_map {idx} {
    variable maps
    if {[llength $maps] <= 1} {
        tk_messageBox -title "Cannot Delete" \
            -message "An RPG project must have at least one map." -icon warning
        return
    }
    set maps [lreplace $maps $idx $idx]
    save_to_doc
    load_doc [project::current_doc]
    goto_map [expr {min($idx, [llength $maps]-1)}]
    catch { app::_refresh_level_list }
}

proc rpg_ev::_refresh_events {} {
    variable W; variable maps; variable mi; variable ei
    set lb $W(evlb)
    $lb delete 0 end
    if {$mi < 0} { _refresh_props; _refresh_cmds; return }
    foreach ev [_map_events [lindex $maps $mi]] {
        $lb insert end "  [dict get $ev name]  ([dict get $ev x],[dict get $ev y])"
    }
    if {$ei >= 0} { $lb selection set $ei }
    _refresh_props
    _refresh_cmds
}

proc rpg_ev::_on_event {} {
    variable W; variable ei; variable pi
    set s [$W(evlb) curselection]
    if {$s eq {}} return
    set ei [lindex $s 0]
    set pi 0
    _refresh_props
    _refresh_cmds
}

proc rpg_ev::_add_event {} {
    variable maps; variable mi; variable ei
    if {$mi < 0} return
    set m [lindex $maps $mi]
    set evs [_map_events $m]
    set ev [dict create id ev[llength $evs] name "New Event" x 1 y 1 \
        trigger action graphic none move fixed \
        pages [list [dict create conditions {} commands {}]]]
    lappend evs $ev
    dict set m events $evs
    lset maps $mi $m
    set ei [expr {[llength $evs]-1}]
    _dirty
    _refresh_events
}

proc rpg_ev::_del_event {} {
    variable maps; variable mi; variable ei
    if {$mi < 0 || $ei < 0} return
    set m [lindex $maps $mi]
    set evs [_map_events $m]
    set evs [lreplace $evs $ei $ei]
    dict set m events $evs
    lset maps $mi $m
    set ei [expr {$ei >= [llength $evs] ? [llength $evs]-1 : $ei}]
    _dirty
    _refresh_events
}

# ── Event property form ───────────────────────────────────────────────────────
proc rpg_ev::_refresh_props {} {
    variable W; variable ei; variable pi
    set inner $W(props)
    prop_panel::clear $inner
    set ev [_cur_event]
    if {$ev eq {}} {
        ttk::label $inner.none -text "Select or add an event." -style Subtitle.TLabel
        grid $inner.none -row 0 -column 0 -padx 8 -pady 8 -sticky w
        return
    }
    prop_panel::add_section $inner "Event"
    set ::rpg_evp_name    [dict get $ev name]
    set ::rpg_evp_x       [dict get $ev x]
    set ::rpg_evp_y       [dict get $ev y]
    set ::rpg_evp_trigger [dict get $ev trigger]
    set ::rpg_evp_graphic [dict get $ev graphic]
    set ::rpg_evp_move    [dict get $ev move]
    prop_panel::add_entry $inner "Name" ::rpg_evp_name
    prop_panel::add_spin  $inner "Tile X" ::rpg_evp_x 0 999 1
    prop_panel::add_spin  $inner "Tile Y" ::rpg_evp_y 0 999 1
    set tk {}; foreach {k l} [rpg::trigger_kinds] { lappend tk $k }
    prop_panel::add_combo $inner "Trigger" ::rpg_evp_trigger $tk
    set mk {}; foreach {k l} [rpg::move_kinds] { lappend mk $k }
    prop_panel::add_combo $inner "Movement" ::rpg_evp_move $mk
    prop_panel::add_entry $inner "Graphic" ::rpg_evp_graphic
    foreach v {::rpg_evp_name ::rpg_evp_x ::rpg_evp_y ::rpg_evp_trigger ::rpg_evp_graphic ::rpg_evp_move} {
        trace remove variable $v write rpg_ev::_prop_write
        trace add    variable $v write rpg_ev::_prop_write
    }

    prop_panel::add_section $inner "Pages"
    set npages [llength [dict get $ev pages]]
    set pglist {}; for {set i 0} {$i < $npages} {incr i} { lappend pglist [expr {$i+1}] }
    set ::rpg_evp_page [expr {$pi+1}]
    prop_panel::add_combo $inner "Active Page" ::rpg_evp_page $pglist
    trace remove variable ::rpg_evp_page write rpg_ev::_page_write
    trace add    variable ::rpg_evp_page write rpg_ev::_page_write

    set row [llength [winfo children $inner]]
    set pf [ttk::frame $inner.pf]
    ttk::button $pf.add -text "+ Page" -style Toolbutton -command rpg_ev::_add_page
    ttk::button $pf.del -text "− Page" -style Toolbutton -command rpg_ev::_del_page
    pack $pf.add $pf.del -side left -padx 1
    grid $pf -row $row -column 0 -columnspan 2 -sticky w -padx 6 -pady 4

    # Page conditions (compact: kind:target lines)
    set page [lindex [dict get $ev pages] $pi]
    set conds [expr {[dict exists $page conditions] ? [dict get $page conditions] : {}}]
    set txt {}
    foreach c $conds {
        lappend txt "[dict get $c kind]:[expr {[dict exists $c target]?[dict get $c target]:{}}]"
    }
    prop_panel::add_section $inner "Page Conditions"
    set crow [llength [winfo children $inner]]
    set ce [text $inner.cond -height 3 -width 24 -wrap word -bg #21273a -fg #dde4f0 \
        -insertbackground #fff -borderwidth 0 -highlightthickness 1 \
        -highlightcolor #1a3f72 -highlightbackground #1e2540 -font {TkDefaultFont 8}]
    $ce insert 1.0 [join $txt "\n"]
    grid $ce -row $crow -column 0 -columnspan 2 -sticky ew -padx 6 -pady 2
    bind $ce <KeyRelease> rpg_ev::_cond_write
    set W(condbox) $ce
    ttk::label $inner.condhint -text "one per line: kind:target  (switch_on, has_item, …)" \
        -foreground #5a6b80 -font {TkDefaultFont 7}
    grid $inner.condhint -row [expr {$crow+1}] -column 0 -columnspan 2 -sticky w -padx 6
}

proc rpg_ev::_prop_write {args} {
    set ev [_cur_event]
    if {$ev eq {}} return
    dict set ev name    $::rpg_evp_name
    dict set ev x       $::rpg_evp_x
    dict set ev y       $::rpg_evp_y
    dict set ev trigger $::rpg_evp_trigger
    dict set ev graphic $::rpg_evp_graphic
    dict set ev move    $::rpg_evp_move
    _set_cur_event $ev
    catch {
        set lb $rpg_ev::W(evlb)
        $lb delete $rpg_ev::ei
        $lb insert $rpg_ev::ei "  $::rpg_evp_name  ($::rpg_evp_x,$::rpg_evp_y)"
        $lb selection set $rpg_ev::ei
    }
}

proc rpg_ev::_page_write {args} {
    variable pi
    set np [expr {$::rpg_evp_page - 1}]
    if {$np eq $pi} return
    set pi $np
    _refresh_cmds
    after 1 rpg_ev::_refresh_props
}

proc rpg_ev::_cond_write {args} {
    variable W; variable pi
    set ev [_cur_event]
    if {$ev eq {}} return
    set conds {}
    foreach line [split [$W(condbox) get 1.0 end] "\n"] {
        set line [string trim $line]
        if {$line eq ""} continue
        lassign [split $line ":"] kind target
        lappend conds [dict create kind $kind target $target]
    }
    set pages [dict get $ev pages]
    set page [lindex $pages $pi]
    dict set page conditions $conds
    lset pages $pi $page
    dict set ev pages $pages
    _set_cur_event $ev
}

proc rpg_ev::_add_page {} {
    variable pi
    set ev [_cur_event]
    if {$ev eq {}} return
    set pages [dict get $ev pages]
    lappend pages [dict create conditions {} commands {}]
    dict set ev pages $pages
    set pi [expr {[llength $pages]-1}]
    _set_cur_event $ev
    _refresh_props
    _refresh_cmds
}

proc rpg_ev::_del_page {} {
    variable pi
    set ev [_cur_event]
    if {$ev eq {}} return
    set pages [dict get $ev pages]
    if {[llength $pages] <= 1} return
    set pages [lreplace $pages $pi $pi]
    dict set ev pages $pages
    set pi 0
    _set_cur_event $ev
    _refresh_props
    _refresh_cmds
}

# ── Command list rendering (indented flat list) ──────────────────────────────
proc rpg_ev::_refresh_cmds {} {
    variable W; variable ci
    set lb $W(cmdlb)
    $lb delete 0 end
    set depth 0
    foreach cmd [_cur_commands] {
        set op [dict get $cmd op]
        if {$op in {end_if end_choice else when}} { set depth [expr {max(0,$depth-1)}] }
        set indent [string repeat "    " $depth]
        $lb insert end "$indent[_summary $cmd]"
        if {$op in {if choice when else}} { incr depth }
    }
    if {$ci >= 0 && $ci < [$lb size]} { $lb selection set $ci }
}

proc rpg_ev::_on_cmd {} {
    variable W; variable ci
    set s [$W(cmdlb) curselection]
    if {$s eq {}} return
    set ci [lindex $s 0]
}

proc rpg_ev::_summary {cmd} {
    set op [dict get $cmd op]
    set g [list]
    foreach {k v} $cmd { if {$k ne "op"} { dict set g $k $v } }
    switch $op {
        text     { return "Text - [dict get $g speaker]: \"[string range [dict get $g text] 0 28]\"" }
        choice   { return "Choices: \"[dict get $g prompt]\"" }
        when     { return "When [\"[dict get $g label]\"]" }
        end_choice { return "End Choices" }
        if       { return "If [dict get $g kind] [dict get $g target] [expr {[dict exists $g value]?[dict get $g value]:{}}]" }
        else     { return "Else" }
        end_if   { return "End Condition" }
        switch   { return "Switch [dict get $g id] = [expr {[dict get $g value] ? "ON" : "OFF"}]" }
        var      { return "Var [dict get $g id] [dict get $g vop] [dict get $g value]" }
        give_item { return "Give [dict get $g item] x[dict get $g qty]" }
        take_item { return "Remove [dict get $g item] x[dict get $g qty]" }
        gold     { return "Gold [dict get $g amount]" }
        give_skill { return "Teach skill [dict get $g skill]" }
        recruit  { return "Add party member [dict get $g actor]" }
        quest_start   { return "Start quest [dict get $g quest]" }
        quest_advance { return "Advance quest [dict get $g quest] -> [dict get $g stage]" }
        quest_done    { return "Complete quest [dict get $g quest]" }
        teleport { return "Teleport -> map [dict get $g map] ([dict get $g x],[dict get $g y])" }
        shop     { return "Open shop [dict get $g shop]" }
        craft    { return "Open crafting ([dict get $g station])" }
        battle   { return "Battle: troop [dict get $g troop]" }
        heal     { return "Heal party" }
        sfx      { return "Sound: [dict get $g id]" }
        music    { return "Music: [dict get $g id]" }
        wait     { return "Wait [dict get $g frames]f" }
        move_npc { return "Move [dict get $g dir] x[dict get $g steps]" }
        set_graphic { return "Set graphic [dict get $g graphic]" }
        comment  { return "// [dict get $g text]" }
        default  { return $op }
    }
}

proc rpg_ev::_add_cmd {op} {
    variable ci
    if {[_cur_event] eq {}} {
        tk_messageBox -title "No Event" -message "Select or add an event first." -icon info
        return
    }
    set cmd [dict create op $op]
    foreach spec [op_fields $op] {
        lassign $spec key label type
        dict set cmd $key [expr {[string match int* $type] ? 0 : ""}]
    }
    set cmds [_cur_commands]
    set at [expr {$ci < 0 ? [llength $cmds] : $ci+1}]
    set cmds [linsert $cmds $at $cmd]
    _set_cur_commands $cmds
    set ci $at
    _refresh_cmds
    if {[llength [op_fields $op]] > 0} { _edit_cmd }
}

proc rpg_ev::_del_cmd {} {
    variable ci
    set cmds [_cur_commands]
    if {$ci < 0 || $ci >= [llength $cmds]} return
    set cmds [lreplace $cmds $ci $ci]
    _set_cur_commands $cmds
    if {$ci >= [llength $cmds]} { set ci [expr {[llength $cmds]-1}] }
    _refresh_cmds
}

proc rpg_ev::_move_cmd {dir} {
    variable ci
    set cmds [_cur_commands]
    set j [expr {$ci+$dir}]
    if {$ci < 0 || $j < 0 || $j >= [llength $cmds]} return
    set a [lindex $cmds $ci]; set b [lindex $cmds $j]
    lset cmds $ci $b; lset cmds $j $a
    _set_cur_commands $cmds
    set ci $j
    _refresh_cmds
}

# ── Per-command argument dialog ───────────────────────────────────────────────
proc rpg_ev::_edit_cmd {} {
    variable ci; variable W
    set cmds [_cur_commands]
    if {$ci < 0 || $ci >= [llength $cmds]} return
    set cmd [lindex $cmds $ci]
    set op [dict get $cmd op]
    set fields [op_fields $op]
    if {[llength $fields] == 0} return

    set doc [project::current_doc]
    set dlg .cmdedit
    if {[winfo exists $dlg]} { destroy $dlg }
    toplevel $dlg
    wm title $dlg [rpg::command_label $op]
    wm transient $dlg .
    wm resizable $dlg 0 0
    set inner [ttk::frame $dlg.f]
    pack $inner -fill both -expand 1 -padx 12 -pady 10
    ttk::label $inner.h -text [rpg::command_label $op] -style Header.TLabel
    grid $inner.h -row 0 -column 0 -columnspan 2 -sticky w -pady {0 8}

    set row 1
    set boxes {}
    foreach spec $fields {
        lassign $spec key label type arg
        set cur [expr {[dict exists $cmd $key] ? [dict get $cmd $key] : ""}]
        ttk::label $inner.l$row -text $label -anchor w
        grid $inner.l$row -row $row -column 0 -sticky nw -padx {0 6} -pady 3
        if {[string match combo:* $type]} {
            set vals [_combo_values $type $doc]
            set ::rpg_ce_$key $cur
            ttk::combobox $inner.w$row -textvariable ::rpg_ce_$key -values $vals -width 22
            grid $inner.w$row -row $row -column 1 -sticky ew -pady 3
            lappend boxes [list $key var]
        } elseif {$type eq "multi"} {
            set t [text $inner.w$row -height 3 -width 30 -wrap word -bg #21273a -fg #dde4f0 \
                -insertbackground #fff -borderwidth 0 -highlightthickness 1 \
                -highlightcolor #1a3f72 -font {TkDefaultFont 9}]
            $t insert 1.0 $cur
            grid $inner.w$row -row $row -column 1 -sticky ew -pady 3
            lappend boxes [list $key text $t]
        } elseif {[string match int* $type]} {
            lassign $arg from to
            if {$from eq ""} { set from -99999 }; if {$to eq ""} { set to 99999 }
            set ::rpg_ce_$key $cur
            ttk::spinbox $inner.w$row -textvariable ::rpg_ce_$key -from $from -to $to -width 22
            grid $inner.w$row -row $row -column 1 -sticky ew -pady 3
            lappend boxes [list $key var]
        } else {
            set ::rpg_ce_$key $cur
            ttk::entry $inner.w$row -textvariable ::rpg_ce_$key -width 24
            grid $inner.w$row -row $row -column 1 -sticky ew -pady 3
            lappend boxes [list $key var]
        }
        incr row
    }
    grid columnconfigure $inner 1 -weight 1
    set bf [ttk::frame $inner.bf]
    grid $bf -row $row -column 0 -columnspan 2 -sticky e -pady {10 0}
    ttk::button $bf.cancel -text "Cancel" -command [list destroy $dlg]
    ttk::button $bf.ok -text "OK" -style Accent.TButton \
        -command [list rpg_ev::_apply_cmd $dlg $op $boxes]
    pack $bf.cancel $bf.ok -side left -padx 4
    grab set $dlg
}

proc rpg_ev::_apply_cmd {dlg op boxes} {
    variable ci
    set cmd [dict create op $op]
    foreach b $boxes {
        lassign $b key kind w
        if {$kind eq "text"} {
            dict set cmd $key [string trimright [$w get 1.0 end] "\n"]
        } else {
            dict set cmd $key [set ::rpg_ce_$key]
        }
    }
    set cmds [_cur_commands]
    lset cmds $ci $cmd
    _set_cur_commands $cmds
    destroy $dlg
    _refresh_cmds
}
