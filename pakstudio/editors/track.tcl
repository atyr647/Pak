# editors/track.tcl — canvas-based waypoint track editor for the racer genre.
#
# The track is stored as doc.levels[0].waypoints: a list of dicts
# {x <f32> z <f32> width <f32>}.  World units map to canvas pixels via
# SCALE = 2.0 px/unit with origin at the canvas centre (200, 200).
#
# Tools: Add (click empty space), Move (drag a waypoint dot), Delete (right-click).
# Track edges are drawn as parallel lines offset by width/2 on each side.

namespace eval track_ed {
    variable SCALE   2.0
    variable CX      200
    variable CY      200
    variable CSIZE   400
    variable DOT_R   6

    variable lvl_idx  0
    variable dragging -1
    variable tool     "add"
}

# ── Create ────────────────────────────────────────────────────────────────────

proc track_ed::create {parent} {
    set f [ttk::frame $parent.trk]
    pack $f -fill both -expand 1

    # ── Toolbar ──────────────────────────────────────────────────────────────
    set tb [ttk::frame $f.tb]
    pack $tb -fill x -padx 8 -pady {6 2}

    ttk::label $tb.lbl -text "Track Editor" -style Header.TLabel
    pack $tb.lbl -side left -padx {0 16}

    foreach {tid txt} {add "Add WP" move "Move WP" del "Delete WP"} {
        set btn [ttk::button $tb.t_$tid -text $txt -style Toolbutton \
            -command [list track_ed::_set_tool $tid]]
        pack $btn -side left -padx 2
        set ::track_tool_btn($tid) $btn
    }

    ttk::separator $tb.s1 -orient vertical
    pack $tb.s1 -side left -fill y -padx 6 -pady 4

    ttk::label  $tb.nlbl   -text "Laps:" -foreground #7a8a9f
    ttk::spinbox $tb.nlaps -textvariable ::track_laps -from 1 -to 9 -width 3 \
        -command track_ed::_on_laps_changed
    bind $tb.nlaps <FocusOut> track_ed::_on_laps_changed
    pack $tb.nlbl $tb.nlaps -side left -padx 2

    ttk::label   $tb.ailbl -text "AI:" -foreground #7a8a9f
    ttk::spinbox $tb.nai   -textvariable ::track_ai -from 0 -to 3 -width 3 \
        -command track_ed::_on_ai_changed
    bind $tb.nai <FocusOut> track_ed::_on_ai_changed
    pack $tb.ailbl $tb.nai -side left -padx 2

    ttk::separator $tb.s2 -orient vertical
    pack $tb.s2 -side left -fill y -padx 6 -pady 4

    ttk::button $tb.reset -text "Reset Oval" -style Toolbutton \
        -command track_ed::_reset_oval
    pack $tb.reset -side left -padx 2

    # ── Canvas ───────────────────────────────────────────────────────────────
    set cf [ttk::frame $f.cf]
    pack $cf -fill both -expand 1 -padx 8 -pady {2 8}

    set c [canvas $cf.c -width 400 -height 400 \
        -background #0d1520 -highlightthickness 0]
    pack $c -side left

    set ::track_canvas $c

    bind $c <Button-1>        {track_ed::_on_click_at %x %y}
    bind $c <B1-Motion>       {track_ed::_on_drag_at  %x %y}
    bind $c <ButtonRelease-1> {track_ed::_on_release}
    bind $c <Button-3>        {track_ed::_on_right_click_at %x %y}

    # ── Info panel ───────────────────────────────────────────────────────────
    set ip [ttk::frame $cf.ip -width 180]
    pack $ip -side left -fill y -padx {8 0}

    ttk::label $ip.h -text "Waypoint" -style Header.TLabel
    pack $ip.h -anchor w -pady {4 8}

    foreach {lbl var} {"Index:" ::track_sel_idx "X:" ::track_sel_x "Z:" ::track_sel_z "Width:" ::track_sel_w} {
        set row [ttk::frame $ip.r_[string map {: "" " " ""} $lbl]]
        ttk::label $row.l -text $lbl -width 8 -anchor w -foreground #7a8a9f
        ttk::entry $row.e -textvariable $var -width 10
        pack $row.l $row.e -side left -padx 2
        pack $row -anchor w -pady 2
    }
    set ::track_sel_idx ""
    set ::track_sel_x   ""
    set ::track_sel_z   ""
    set ::track_sel_w   ""

    ttk::button $ip.apply -text "Apply" -style Accent.TButton \
        -command track_ed::_apply_wp_edit
    pack $ip.apply -anchor w -pady {8 4}

    ttk::separator $ip.sep -orient horizontal
    pack $ip.sep -fill x -pady 8

    ttk::label $ip.hint -text "Left-click to add\nDrag dots to move\nRight-click to delete\n\nConnect last→first\nfor a closed loop." \
        -style Subtitle.TLabel -justify left
    pack $ip.hint -anchor w

    _set_tool "add"
    return $f
}

# ── Tool selection ────────────────────────────────────────────────────────────

proc track_ed::_set_tool {tid} {
    set ::track_tool $tid
    foreach id {add move del} {
        catch {
            if {$id eq $tid} {
                $::track_tool_btn($id) state selected
            } else {
                $::track_tool_btn($id) state !selected
            }
        }
    }
}

# ── Coordinate conversion ─────────────────────────────────────────────────────

proc track_ed::_w2c {wx wz} {
    variable SCALE CX CY
    list [expr {$CX + $wx * $SCALE}] [expr {$CY - $wz * $SCALE}]
}

proc track_ed::_c2w {cx cy} {
    variable SCALE CX CY
    list [expr {($cx - $CX) / $SCALE}] [expr {($CY - $cy) / $SCALE}]
}

# ── Waypoint data helpers ─────────────────────────────────────────────────────

proc track_ed::_get_wps {} {
    variable lvl_idx
    set doc [project::current_doc]
    if {![dict exists $doc levels]} { return {} }
    set lvl [lindex [dict get $doc levels] $lvl_idx]
    if {![dict exists $lvl waypoints]} { return {} }
    return [dict get $lvl waypoints]
}

proc track_ed::_set_wps {wps} {
    variable lvl_idx
    set doc [project::current_doc]
    if {![dict exists $doc levels]} return
    set lvls [dict get $doc levels]
    set lvl  [lindex $lvls $lvl_idx]
    dict set lvl waypoints $wps
    lset lvls $lvl_idx $lvl
    project::set_field levels $lvls
}

proc track_ed::_hit_wp {cx cy} {
    variable DOT_R
    set wps [_get_wps]
    for {set i 0} {$i < [llength $wps]} {incr i} {
        set wp [lindex $wps $i]
        lassign [_w2c [dict get $wp x] [dict get $wp z]] px py
        set dx [expr {$cx - $px}]
        set dy [expr {$cy - $py}]
        if {sqrt($dx*$dx + $dy*$dy) <= $DOT_R + 4} { return $i }
    }
    return -1
}

# ── Canvas draw ───────────────────────────────────────────────────────────────

proc track_ed::_redraw {} {
    variable SCALE CX CY DOT_R CSIZE
    set c $::track_canvas
    if {![winfo exists $c]} return
    $c delete all

    # Grid
    $c create line $CX 0 $CX $CSIZE -fill #1a2540 -dash {2 6}
    $c create line 0 $CY $CSIZE $CY -fill #1a2540 -dash {2 6}

    set wps [_get_wps]
    set n   [llength $wps]
    if {$n == 0} {
        $c create text $CX $CY -text "Click to add waypoints" \
            -fill #3d4a5e -font {TkDefaultFont 11}
        return
    }

    # Track edges: connect each consecutive pair, close the loop
    for {set i 0} {$i < $n} {incr i} {
        set j [expr {($i + 1) % $n}]
        set wp0 [lindex $wps $i]
        set wp1 [lindex $wps $j]
        lassign [_w2c [dict get $wp0 x] [dict get $wp0 z]] x0 y0
        lassign [_w2c [dict get $wp1 x] [dict get $wp1 z]] x1 y1

        set dx [expr {$x1 - $x0}]
        set dy [expr {$y1 - $y0}]
        set len [expr {sqrt($dx*$dx + $dy*$dy)}]
        if {$len < 0.001} continue
        set nx [expr {-$dy / $len}]
        set ny [expr { $dx / $len}]

        set hw0 [expr {[dict get $wp0 width] * $SCALE / 2.0}]
        set hw1 [expr {[dict get $wp1 width] * $SCALE / 2.0}]

        # centre line
        $c create line $x0 $y0 $x1 $y1 -fill #334466 -width 1

        # left edge
        $c create line \
            [expr {$x0 + $nx*$hw0}] [expr {$y0 + $ny*$hw0}] \
            [expr {$x1 + $nx*$hw1}] [expr {$y1 + $ny*$hw1}] \
            -fill #5566aa -width 2

        # right edge
        $c create line \
            [expr {$x0 - $nx*$hw0}] [expr {$y0 - $ny*$hw0}] \
            [expr {$x1 - $nx*$hw1}] [expr {$y1 - $ny*$hw1}] \
            -fill #5566aa -width 2
    }

    # Waypoint dots and indices
    for {set i 0} {$i < $n} {incr i} {
        set wp [lindex $wps $i]
        lassign [_w2c [dict get $wp x] [dict get $wp z]] px py
        set col [expr {$i == 0 ? "#ffdd44" : "#44aaff"}]
        $c create oval \
            [expr {$px - $DOT_R}] [expr {$py - $DOT_R}] \
            [expr {$px + $DOT_R}] [expr {$py + $DOT_R}] \
            -fill $col -outline #ffffff -width 1 -tags "wp_$i"
        $c create text [expr {$px + 10}] [expr {$py - 8}] \
            -text $i -fill #aabbcc -font {TkDefaultFont 8}
    }
}

# ── Mouse handlers ────────────────────────────────────────────────────────────

proc track_ed::_on_click_at {cx cy} {
    variable dragging
    set tool [expr {[info exists ::track_tool] ? $::track_tool : "add"}]
    set hit  [_hit_wp $cx $cy]

    if {$tool eq "del"} {
        if {$hit >= 0} { _delete_wp $hit }
        return
    }
    if {$tool eq "move" || ($tool eq "add" && $hit >= 0)} {
        set dragging $hit
        _show_wp_info $hit
        return
    }
    # add tool, empty space → new waypoint
    lassign [_c2w $cx $cy] wx wz
    set wps [_get_wps]
    lappend wps [dict create x [format %.1f $wx] z [format %.1f $wz] width 12.0]
    _set_wps $wps
    _redraw
    _show_wp_info [expr {[llength $wps] - 1}]
    project::mark_dirty
    catch { app::_update_save_indicator }
}

proc track_ed::_on_drag_at {cx cy} {
    variable dragging
    if {$dragging < 0} return
    lassign [_c2w $cx $cy] wx wz
    set wps [_get_wps]
    if {$dragging >= [llength $wps]} { set dragging -1; return }
    set wp [lindex $wps $dragging]
    dict set wp x [format %.1f $wx]
    dict set wp z [format %.1f $wz]
    lset wps $dragging $wp
    _set_wps $wps
    _redraw
    _show_wp_info $dragging
    project::mark_dirty
    catch { app::_update_save_indicator }
}

proc track_ed::_on_release {} {
    variable dragging
    set dragging -1
}

proc track_ed::_on_right_click_at {cx cy} {
    set hit [_hit_wp $cx $cy]
    if {$hit >= 0} { _delete_wp $hit }
}

proc track_ed::_delete_wp {idx} {
    set wps [_get_wps]
    if {[llength $wps] <= 2} return  ;# keep at least 2 waypoints
    set wps [lreplace $wps $idx $idx]
    _set_wps $wps
    _redraw
    set ::track_sel_idx ""
    set ::track_sel_x   ""
    set ::track_sel_z   ""
    set ::track_sel_w   ""
    project::mark_dirty
    catch { app::_update_save_indicator }
}

# ── Info panel ────────────────────────────────────────────────────────────────

proc track_ed::_show_wp_info {idx} {
    set wps [_get_wps]
    if {$idx < 0 || $idx >= [llength $wps]} return
    set wp [lindex $wps $idx]
    set ::track_sel_idx $idx
    set ::track_sel_x   [dict get $wp x]
    set ::track_sel_z   [dict get $wp z]
    set ::track_sel_w   [dict get $wp width]
}

proc track_ed::_apply_wp_edit {} {
    set idx $::track_sel_idx
    if {$idx eq "" || ![string is integer $idx]} return
    set wps [_get_wps]
    if {$idx < 0 || $idx >= [llength $wps]} return
    set wp [lindex $wps $idx]
    dict set wp x     $::track_sel_x
    dict set wp z     $::track_sel_z
    dict set wp width $::track_sel_w
    lset wps $idx $wp
    _set_wps $wps
    _redraw
    project::mark_dirty
    catch { app::_update_save_indicator }
}

# ── Spinbox change handlers ───────────────────────────────────────────────────

proc track_ed::_on_laps_changed {} {
    set v [expr {[info exists ::track_laps] ? $::track_laps : 3}]
    if {![string is integer $v] || $v < 1} { set v 3 }
    project::set_field physics num_laps $v
    catch { app::_update_save_indicator }
}

proc track_ed::_on_ai_changed {} {
    set v [expr {[info exists ::track_ai] ? $::track_ai : 3}]
    if {![string is integer $v] || $v < 0} { set v 3 }
    project::set_field physics ai_count $v
    catch { app::_update_save_indicator }
}

# ── Reset to default oval ─────────────────────────────────────────────────────

proc track_ed::_reset_oval {} {
    set wps [list \
        [dict create x  0.0  z -60.0 width 12.0] \
        [dict create x 40.0  z -50.0 width 12.0] \
        [dict create x 60.0  z -20.0 width 12.0] \
        [dict create x 60.0  z  20.0 width 12.0] \
        [dict create x 40.0  z  50.0 width 12.0] \
        [dict create x  0.0  z  60.0 width 12.0] \
        [dict create x -40.0 z  50.0 width 12.0] \
        [dict create x -60.0 z  20.0 width 12.0] \
        [dict create x -60.0 z -20.0 width 12.0] \
        [dict create x -40.0 z -50.0 width 12.0] \
    ]
    _set_wps $wps
    _redraw
    project::mark_dirty
    catch { app::_update_save_indicator }
}

# ── Load / Save ───────────────────────────────────────────────────────────────

proc track_ed::load_doc {doc} {
    variable lvl_idx
    set lvl_idx 0
    if {[dict exists $doc physics num_laps]} {
        set ::track_laps [dict get $doc physics num_laps]
    } else {
        set ::track_laps 3
    }
    if {[dict exists $doc physics ai_count]} {
        set ::track_ai [dict get $doc physics ai_count]
    } else {
        set ::track_ai 3
    }
    _redraw
}

proc track_ed::save_to_doc {} {
    # Waypoints are written directly via _set_wps on every edit.
    # Flush laps/ai in case the spinbox was typed into without <Return>.
    _on_laps_changed
    _on_ai_changed
}
