# editors/rpg_dialogue.tcl — branching dialogue editor.
# Each dialogue is authored as a small readable script; load/save convert it
# to/from the structured node tree in doc.dialogues.
#
#   @n0 Elder Mira: My heirloom is lost in the woods. Will you help?
#   > I'll find it. -> n1 [q_heirloom]
#   > Not now.      -> end
#   @n1 Elder Mira: Bless you, traveller.
#
# A line beginning with @ opens a node "@<id> <Speaker>: <text>". Lines
# beginning with > are that node's choices "<label> -> <goto> [optional switch]".
# Special goto targets: end (close), shop, craft.

namespace eval rpg_dialogue {}

proc rpg_dialogue::create {parent} {
    set f [ttk::frame $parent.dlg]
    pack $f -fill both -expand 1
    ttk::label $f.hint -style Subtitle.TLabel -anchor w -wraplength 760 -justify left \
        -text "@nodeId Speaker: text   opens a node.   > label -> gotoNode \[switchId\]   adds a choice.   Goto end/shop/craft for special actions."
    pack $f.hint -fill x -padx 8 -pady {6 0}
    set body [ttk::frame $f.body]
    pack $body -fill both -expand 1
    rdb::make dlg $body {
        {id     "ID"     str}
        {name   "Name"   str}
        {script "Script" multi}
    } -addlabel "Dialogue" -onchange rpg_dialogue::_dirty
    # Make the script box tall — it's the main content.
    catch { $rdb::w(dlg,fld,script) configure -height 16 }
    return $f
}

proc rpg_dialogue::_dirty {} { catch { project::mark_dirty; app::_update_save_indicator } }

proc rpg_dialogue::_enc {nodes} {
    set lines {}
    foreach n $nodes {
        set id      [dict get $n id]
        set speaker [expr {[dict exists $n speaker] ? [dict get $n speaker] : ""}]
        set text    [expr {[dict exists $n text]    ? [dict get $n text]    : ""}]
        lappend lines "@$id $speaker: $text"
        foreach c [expr {[dict exists $n choices] ? [dict get $n choices] : {}}] {
            set lbl  [dict get $c label]
            set goto [expr {[dict exists $c goto] ? [dict get $c goto] : "end"}]
            set set  [expr {[dict exists $c set]  ? [dict get $c set]  : ""}]
            set line "> $lbl -> $goto"
            if {$set ne ""} { append line " \[$set\]" }
            lappend lines $line
        }
    }
    return [join $lines "\n"]
}

proc rpg_dialogue::_dec {script} {
    set nodes {}
    set cur {}
    foreach raw [split $script "\n"] {
        set line [string trim $raw]
        if {$line eq ""} continue
        if {[string index $line 0] eq "@"} {
            if {[dict size $cur]} { lappend nodes $cur }
            set rest [string range $line 1 end]
            set sp [string first " " $rest]
            if {$sp < 0} { set id $rest; set body "" } \
            else { set id [string range $rest 0 [expr {$sp-1}]]; set body [string range $rest [expr {$sp+1}] end] }
            set colon [string first ": " $body]
            if {$colon >= 0} {
                set speaker [string range $body 0 [expr {$colon-1}]]
                set text    [string range $body [expr {$colon+2}] end]
            } else { set speaker ""; set text $body }
            set cur [dict create id $id speaker $speaker text $text choices {}]
        } elseif {[string index $line 0] eq ">"} {
            if {![dict size $cur]} continue
            set body [string trim [string range $line 1 end]]
            set setid ""
            if {[regexp {\[([^\]]*)\]\s*$} $body -> setid]} {
                set body [string trim [regsub {\[[^\]]*\]\s*$} $body ""]]
            }
            set arrow [string first "->" $body]
            if {$arrow >= 0} {
                set lbl  [string trim [string range $body 0 [expr {$arrow-1}]]]
                set goto [string trim [string range $body [expr {$arrow+2}] end]]
            } else { set lbl $body; set goto end }
            set choices [dict get $cur choices]
            lappend choices [dict create label $lbl goto $goto set $setid]
            dict set cur choices $choices
        }
    }
    if {[dict size $cur]} { lappend nodes $cur }
    return $nodes
}

proc rpg_dialogue::load_doc {doc} {
    if {![rpg::is_rpg $doc]} return
    set recs {}
    foreach d [expr {[dict exists $doc dialogues] ? [dict get $doc dialogues] : {}}] {
        set script [_enc [expr {[dict exists $d nodes] ? [dict get $d nodes] : {}}]]
        lappend recs [dict create id [dict get $d id] \
            name [expr {[dict exists $d name] ? [dict get $d name] : [dict get $d id]}] \
            script $script]
    }
    rdb::set_records dlg $recs
}

proc rpg_dialogue::save_to_doc {} {
    if {![rpg::is_rpg [project::current_doc]]} return
    set recs {}
    foreach d [rdb::get_records dlg] {
        lappend recs [dict create id [dict get $d id] \
            name [expr {[dict exists $d name] ? [dict get $d name] : [dict get $d id]}] \
            nodes [_dec [expr {[dict exists $d script] ? [dict get $d script] : ""}]]]
    }
    project::set_field dialogues $recs
}
