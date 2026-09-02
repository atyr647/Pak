# editors/rpg_common.tcl — shared master-detail "record database" widget.
#
# Many RPG editors are the same shape: a list of records on the left, a form
# inspector on the right, and Add / Duplicate / Delete controls. `rdb` builds
# that once. Each editor supplies a field spec; rdb handles selection, live
# write-back into a working copy of the record list, and add/dup/delete.
#
# Field spec: a list of {key label type ?arg?} where type is one of:
#   str    free-text entry
#   int    integer spinbox          (arg = "from to", default "0 999")
#   real   decimal spinbox          (arg = "from to step")
#   multi  multi-line text box
#   combo  read-only dropdown       (arg = list of values)
#   ids    space-separated id list  (arg = hint string)
#
# Records are Tcl dicts; every record must carry an `id`. The display label is
# the record's `name` (falling back to `id`).

namespace eval rdb {
    variable lists   ;# tag -> list of record dicts (working copy)
    variable sel     ;# tag -> selected index (-1 none)
    variable fields  ;# tag -> field spec
    variable w       ;# tag,key -> widget path
    variable onchange ;# tag -> callback when records mutate
    variable labelkey ;# tag -> key used for list label
    array set lists {}
    array set sel {}
    array set fields {}
    array set w {}
    array set onchange {}
    array set labelkey {}
}

# Build the editor. `parent` is an empty frame. Returns the frame.
proc rdb::make {tag parent fieldspec args} {
    variable lists; variable sel; variable fields; variable onchange; variable labelkey; variable w
    set lists($tag)    {}
    set sel($tag)      -1
    set fields($tag)   $fieldspec
    set onchange($tag) [expr {[dict exists $args -onchange] ? [dict get $args -onchange] : ""}]
    set labelkey($tag) [expr {[dict exists $args -label]    ? [dict get $args -label]    : "name"}]
    set addlabel       [expr {[dict exists $args -addlabel] ? [dict get $args -addlabel] : "Record"}]

    set f [ttk::frame $parent.rdb_$tag]
    pack $f -fill both -expand 1

    # ── Left: list + buttons ────────────────────────────────────────────────
    set left [ttk::frame $f.left -width 190]
    pack $left -side left -fill y -padx {6 0} -pady 6
    pack propagate $left 0

    set lb [listbox $left.lb -selectmode single \
        -bg #1a1f2e -fg #dde4f0 -selectbackground #1a3f72 \
        -selectforeground #dde4f0 -borderwidth 0 -highlightthickness 0 \
        -font {TkDefaultFont 9} -activestyle none]
    pack $lb -fill both -expand 1
    bind $lb <<ListboxSelect>> [list rdb::_on_select $tag]
    set w($tag,lb) $lb

    set bf [ttk::frame $left.bf]
    pack $bf -fill x -pady {4 0}
    ttk::button $bf.add -text "+ Add" -style Toolbutton \
        -command [list rdb::_add $tag $addlabel]
    ttk::button $bf.dup -text "Dup" -style Toolbutton \
        -command [list rdb::_dup $tag]
    ttk::button $bf.del -text "Del" -style Toolbutton -width 4 \
        -command [list rdb::_del $tag]
    pack $bf.add $bf.dup $bf.del -side left -padx 1

    # ── Right: detail form (scrollable) ─────────────────────────────────────
    set right [ttk::frame $f.right]
    pack $right -side left -fill both -expand 1 -padx 6 -pady 6
    set inner [prop_panel::create $right]
    set w($tag,form) $inner

    _build_form $tag
    return $f
}

proc rdb::_build_form {tag} {
    variable fields; variable w; variable sel
    set inner $w($tag,form)
    prop_panel::clear $inner
    set row 0
    foreach spec $fields($tag) {
        lassign $spec key label type arg
        set vn ::rdb_${tag}_${key}
        switch $type {
            multi {
                ttk::label $inner.l$row -text $label -anchor nw
                set t [text $inner.t$row -height 3 -width 30 -wrap word \
                    -bg #21273a -fg #dde4f0 -insertbackground #fff \
                    -borderwidth 0 -highlightthickness 1 \
                    -highlightcolor #1a3f72 -highlightbackground #1e2540 \
                    -font {TkDefaultFont 9}]
                grid $inner.l$row -row $row -column 0 -sticky nw -padx {6 2} -pady 2
                grid $t           -row $row -column 1 -sticky ew -padx {2 6} -pady 2
                bind $t <KeyRelease> [list rdb::_writeback $tag]
                set w($tag,fld,$key) $t
            }
            combo {
                ttk::label $inner.l$row -text $label -anchor w
                ttk::combobox $inner.c$row -textvariable $vn -values $arg \
                    -state readonly
                grid $inner.l$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
                grid $inner.c$row -row $row -column 1 -sticky ew -padx {2 6} -pady 2
                bind $inner.c$row <<ComboboxSelected>> [list rdb::_writeback $tag]
                set w($tag,fld,$key) $inner.c$row
            }
            int - real {
                if {$arg eq ""} { set arg {0 9999} }
                lassign $arg from to step
                if {$step eq ""} { set step [expr {$type eq "real" ? 0.1 : 1}] }
                ttk::label $inner.l$row -text $label -anchor w
                ttk::spinbox $inner.s$row -textvariable $vn -from $from -to $to \
                    -increment $step -width 12
                grid $inner.l$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
                grid $inner.s$row -row $row -column 1 -sticky w  -padx {2 6} -pady 2
                bind $inner.s$row <KeyRelease> [list rdb::_writeback $tag]
                bind $inner.s$row <<Increment>> [list after 1 [list rdb::_writeback $tag]]
                bind $inner.s$row <<Decrement>> [list after 1 [list rdb::_writeback $tag]]
                set w($tag,fld,$key) $inner.s$row
            }
            ids {
                ttk::label $inner.l$row -text $label -anchor w
                ttk::entry $inner.e$row -textvariable $vn
                grid $inner.l$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
                grid $inner.e$row -row $row -column 1 -sticky ew -padx {2 6} -pady 2
                bind $inner.e$row <KeyRelease> [list rdb::_writeback $tag]
                set w($tag,fld,$key) $inner.e$row
                if {$arg ne ""} {
                    incr row
                    ttk::label $inner.h$row -text $arg -foreground #5a6b80 \
                        -font {TkDefaultFont 7}
                    grid $inner.h$row -row $row -column 1 -sticky w -padx {2 6}
                }
            }
            default {
                ttk::label $inner.l$row -text $label -anchor w
                ttk::entry $inner.e$row -textvariable $vn
                grid $inner.l$row -row $row -column 0 -sticky w  -padx {6 2} -pady 2
                grid $inner.e$row -row $row -column 1 -sticky ew -padx {2 6} -pady 2
                bind $inner.e$row <KeyRelease> [list rdb::_writeback $tag]
                set w($tag,fld,$key) $inner.e$row
            }
        }
        incr row
    }
    grid columnconfigure $inner 1 -weight 1
    _set_form_state $tag [expr {$sel($tag) >= 0}]
}

proc rdb::_set_form_state {tag enabled} {
    variable fields; variable w
    set st [expr {$enabled ? "normal" : "disabled"}]
    foreach spec $fields($tag) {
        set key [lindex $spec 0]
        if {[info exists w($tag,fld,$key)]} {
            catch { $w($tag,fld,$key) configure -state $st }
        }
    }
}

# Load records into the editor and select the first.
proc rdb::set_records {tag records} {
    variable lists; variable sel
    set lists($tag) $records
    set sel($tag) [expr {[llength $records] > 0 ? 0 : -1}]
    _refresh_list $tag
    _load_form $tag
}

proc rdb::get_records {tag} {
    variable lists
    return $lists($tag)
}

proc rdb::_refresh_list {tag} {
    variable lists; variable w; variable labelkey; variable sel
    set lb $w($tag,lb)
    $lb delete 0 end
    foreach rec $lists($tag) {
        set lbl ""
        if {[dict exists $rec $labelkey($tag)]} { set lbl [dict get $rec $labelkey($tag)] }
        if {$lbl eq "" && [dict exists $rec id]} { set lbl [dict get $rec id] }
        $lb insert end "  $lbl"
    }
    if {$sel($tag) >= 0} {
        $lb selection clear 0 end
        $lb selection set $sel($tag)
    }
}

proc rdb::_on_select {tag} {
    variable w; variable sel
    set s [$w($tag,lb) curselection]
    if {$s eq {}} return
    set sel($tag) [lindex $s 0]
    _load_form $tag
}

proc rdb::_load_form {tag} {
    variable lists; variable sel; variable fields; variable w
    if {$sel($tag) < 0} { _set_form_state $tag 0; return }
    _set_form_state $tag 1
    set rec [lindex $lists($tag) $sel($tag)]
    foreach spec $fields($tag) {
        lassign $spec key label type
        set v [expr {[dict exists $rec $key] ? [dict get $rec $key] : ""}]
        if {$type eq "multi"} {
            set t $w($tag,fld,$key)
            $t delete 1.0 end
            $t insert 1.0 $v
        } else {
            set ::rdb_${tag}_${key} $v
        }
    }
}

proc rdb::_writeback {tag} {
    variable lists; variable sel; variable fields; variable w; variable onchange; variable labelkey
    if {$sel($tag) < 0} return
    set rec [lindex $lists($tag) $sel($tag)]
    foreach spec $fields($tag) {
        lassign $spec key label type
        if {$type eq "multi"} {
            set v [string trimright [$w($tag,fld,$key) get 1.0 end] "\n"]
        } else {
            set v [set ::rdb_${tag}_${key}]
        }
        dict set rec $key $v
    }
    lset lists($tag) $sel($tag) $rec
    # Live-update the list label if the name changed.
    set lbl [expr {[dict exists $rec $labelkey($tag)] ? [dict get $rec $labelkey($tag)] : [dict get $rec id]}]
    catch { $w($tag,lb) delete $sel($tag); $w($tag,lb) insert $sel($tag) "  $lbl"
            $w($tag,lb) selection set $sel($tag) }
    if {$onchange($tag) ne ""} { catch { uplevel #0 $onchange($tag) } }
}

proc rdb::_unique_id {tag base} {
    variable lists
    set ids {}
    foreach r $lists($tag) { lappend ids [dict get $r id] }
    if {[lsearch -exact $ids $base] < 0} { return $base }
    set n 2
    while {[lsearch -exact $ids ${base}$n] >= 0} { incr n }
    return ${base}$n
}

proc rdb::_add {tag addlabel} {
    variable lists; variable sel; variable fields; variable onchange
    set rec [dict create id [_unique_id $tag new]]
    foreach spec $fields($tag) {
        lassign $spec key label type
        if {$key eq "id"} continue
        dict set rec $key [expr {$type in {int real} ? 0 : ($key eq "name" ? "New $addlabel" : "")}]
    }
    lappend lists($tag) $rec
    set sel($tag) [expr {[llength $lists($tag)] - 1}]
    _refresh_list $tag
    _load_form $tag
    if {$onchange($tag) ne ""} { catch { uplevel #0 $onchange($tag) } }
}

proc rdb::_dup {tag} {
    variable lists; variable sel; variable onchange
    if {$sel($tag) < 0} return
    set rec [lindex $lists($tag) $sel($tag)]
    dict set rec id [_unique_id $tag [dict get $rec id]]
    if {[dict exists $rec name]} { dict set rec name "[dict get $rec name] copy" }
    lappend lists($tag) $rec
    set sel($tag) [expr {[llength $lists($tag)] - 1}]
    _refresh_list $tag
    _load_form $tag
    if {$onchange($tag) ne ""} { catch { uplevel #0 $onchange($tag) } }
}

proc rdb::_del {tag} {
    variable lists; variable sel; variable onchange
    if {$sel($tag) < 0} return
    set lists($tag) [lreplace $lists($tag) $sel($tag) $sel($tag)]
    if {$sel($tag) >= [llength $lists($tag)]} { set sel($tag) [expr {[llength $lists($tag)]-1}] }
    _refresh_list $tag
    _load_form $tag
    if {$onchange($tag) ne ""} { catch { uplevel #0 $onchange($tag) } }
}

# Convenience: ids of every record of a given doc database list, for combos.
proc rdb::doc_ids {doc args} {
    if {![dict exists $doc {*}$args]} { return {} }
    set out {}
    foreach r [dict get $doc {*}$args] { lappend out [dict get $r id] }
    return $out
}
