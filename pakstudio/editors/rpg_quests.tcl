# editors/rpg_quests.tcl — Quest editor.
# Master-detail over doc.quests. Stages and reward use compact line/token
# encodings in the form, converted to/from the structured schema on load/save.
#
#   Stages box (one per line):  kind:target:count | human-readable description
#       kind ∈ talk collect defeat reach custom
#   Reward tokens:              gold:150 item:iron_sword exp:50

namespace eval rpg_quests {}

proc rpg_quests::create {parent} {
    set f [ttk::frame $parent.quests]
    pack $f -fill both -expand 1
    ttk::label $f.hint -style Subtitle.TLabel -anchor w -wraplength 760 -justify left \
        -text "Each stage line: kind:target:count | description   (kind = talk, collect, defeat, reach, custom).   Reward tokens: gold:N item:id exp:N"
    pack $f.hint -fill x -padx 8 -pady {6 0}
    set body [ttk::frame $f.body]
    pack $body -fill both -expand 1
    rdb::make quests $body {
        {id     "ID"          str}
        {name   "Quest Name"  str}
        {giver  "Giver (id)"  str}
        {desc   "Summary"     multi}
        {stages "Stages"      multi}
        {reward "Reward"      ids "gold:N item:id exp:N"}
    } -addlabel "Quest" -onchange rpg_quests::_dirty
    return $f
}

proc rpg_quests::_dirty {} { catch { project::mark_dirty; app::_update_save_indicator } }

proc rpg_quests::_enc_stages {lst} {
    set lines {}
    foreach s $lst {
        set kind   [expr {[dict exists $s kind]   ? [dict get $s kind]   : "custom"}]
        set target [expr {[dict exists $s target] ? [dict get $s target] : ""}]
        set count  [expr {[dict exists $s count]  ? [dict get $s count]  : 1}]
        set desc   [expr {[dict exists $s desc]   ? [dict get $s desc]   : ""}]
        lappend lines "${kind}:${target}:${count} | $desc"
    }
    return [join $lines "\n"]
}
proc rpg_quests::_dec_stages {s} {
    set out {}; set n 1
    foreach line [split $s "\n"] {
        set line [string trim $line]
        if {$line eq ""} continue
        set parts [split $line "|"]
        set spec  [string trim [lindex $parts 0]]
        set desc  [string trim [join [lrange $parts 1 end] "|"]]
        lassign [split $spec ":"] kind target count
        if {$kind eq ""}  { set kind custom }
        if {$count eq ""} { set count 1 }
        lappend out [dict create id s$n kind $kind target $target count $count desc $desc]
        incr n
    }
    return $out
}
proc rpg_quests::_enc_reward {d} {
    set out {}
    foreach k {gold item exp} { if {[dict exists $d $k] && [dict get $d $k] ne ""} { lappend out "$k:[dict get $d $k]" } }
    return [join $out " "]
}
proc rpg_quests::_dec_reward {s} {
    set d [dict create]
    foreach tok $s {
        lassign [split $tok ":"] k v
        if {$k ne "" && $v ne ""} { dict set d $k $v }
    }
    return $d
}

proc rpg_quests::load_doc {doc} {
    if {![rpg::is_rpg $doc]} return
    set recs {}
    foreach q [expr {[dict exists $doc quests] ? [dict get $doc quests] : {}}] {
        dict set q stages [_enc_stages [expr {[dict exists $q stages] ? [dict get $q stages] : {}}]]
        dict set q reward [_enc_reward [expr {[dict exists $q reward] ? [dict get $q reward] : {}}]]
        lappend recs $q
    }
    rdb::set_records quests $recs
}

proc rpg_quests::save_to_doc {} {
    if {![rpg::is_rpg [project::current_doc]]} return
    set recs {}
    foreach q [rdb::get_records quests] {
        dict set q stages [_dec_stages [expr {[dict exists $q stages] ? [dict get $q stages] : ""}]]
        dict set q reward [_dec_reward [expr {[dict exists $q reward] ? [dict get $q reward] : ""}]]
        lappend recs $q
    }
    project::set_field quests $recs
}
