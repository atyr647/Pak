# editors/preview.tcl — live visual game preview panel

namespace eval preview_ed {
    variable canvas    ""
    variable scale     2
    variable level_idx 0
    variable show_grid 1
    variable show_cam  1
}

proc preview_ed::create {parent} {
    variable canvas

    set f [ttk::frame $parent.prevf]

    # ── Controls bar ──────────────────────────────────────────────────────────
    set bar [ttk::frame $f.bar]

    ttk::label  $bar.lbl  -text "LIVE PREVIEW" -style Section.TLabel
    ttk::frame  $bar.s1   -width 1 -style Sep.TFrame
    ttk::label  $bar.zlbl -text "Zoom:" -style Subtitle.TLabel
    ttk::button $bar.zm   -text "−" -width 2 -style Toolbutton \
        -command preview_ed::zoom_out
    ttk::label  $bar.zval -textvariable ::preview_ed::scale -width 3 \
        -foreground #6aadff -anchor center -font {TkDefaultFont 9 bold}
    ttk::button $bar.zp   -text "+" -width 2 -style Toolbutton \
        -command preview_ed::zoom_in
    ttk::frame  $bar.s2   -width 1 -style Sep.TFrame
    ttk::checkbutton $bar.grid -text "Grid" \
        -variable ::preview_ed::show_grid \
        -command  preview_ed::refresh \
        -style Toolbutton
    ttk::checkbutton $bar.cam -text "Camera" \
        -variable ::preview_ed::show_cam \
        -command  preview_ed::refresh \
        -style Toolbutton
    ttk::label $bar.hint -text "Updates as you paint" \
        -style Subtitle.TLabel

    pack $bar.lbl  -side left -padx {12 8}
    pack $bar.s1   -side left -fill y  -pady 6 -padx 4
    pack $bar.zlbl -side left -padx {0 4}
    pack $bar.zm   -side left -padx 1
    pack $bar.zval -side left -padx 2
    pack $bar.zp   -side left -padx 1
    pack $bar.s2   -side left -fill y  -pady 6 -padx 4
    pack $bar.grid -side left -padx 2
    pack $bar.cam  -side left -padx 2
    pack $bar.hint -side right -padx 12

    pack $bar -fill x -pady {6 0}

    ttk::separator $f.sep -orient horizontal
    pack $f.sep -fill x -pady {4 0}

    # ── Canvas + scrollbars ───────────────────────────────────────────────────
    set cf [ttk::frame $f.cf]
    pack $cf -fill both -expand 1

    set canvas [canvas $cf.cv \
        -bg #0d1520 -highlightthickness 0 -cursor crosshair \
        -relief flat -borderwidth 0]
    set vsb [ttk::scrollbar $cf.vsb -orient vertical   -command [list $canvas yview]]
    set hsb [ttk::scrollbar $cf.hsb -orient horizontal -command [list $canvas xview]]
    $canvas configure \
        -yscrollcommand [list $vsb set] \
        -xscrollcommand [list $hsb set]

    grid $canvas $vsb -sticky nsew
    grid $hsb         -sticky ew
    grid columnconfigure $cf 0 -weight 1
    grid rowconfigure    $cf 0 -weight 1

    bind $canvas <Motion> [list preview_ed::_show_coords %x %y]

    pack $f -fill both -expand 1
    return $f
}

proc preview_ed::load_doc {doc idx} {
    variable level_idx
    set level_idx $idx
    refresh
}

proc preview_ed::refresh {} {
    variable canvas
    variable scale
    variable show_grid
    variable show_cam
    variable level_idx

    if {$canvas eq "" || ![winfo exists $canvas]} return

    set doc [project::current_doc]
    if {![dict exists $doc meta]} return

    $canvas delete all

    set lvls [dict get $doc levels]
    if {[llength $lvls] == 0} return
    if {$level_idx >= [llength $lvls]} { set level_idx 0 }
    set lvl [lindex $lvls $level_idx]

    set ts [expr {16 * $scale}]
    set lw [dict get $lvl width]
    set lh [dict get $lvl height]
    set pw [expr {$lw * $ts}]
    set ph [expr {$lh * $ts}]

    $canvas configure -scrollregion [list 0 0 $pw $ph]

    # Sky gradient (two rects: upper dark, lower slightly lighter)
    set hm [expr {$ph / 2}]
    $canvas create rectangle 0 0   $pw $hm -fill #0d1828 -outline {}
    $canvas create rectangle 0 $hm $pw $ph -fill #0d1520 -outline {}

    # Tiles — stored as flat integer list indexed by ty*W+tx
    set tiles [dict get $lvl tiles]
    for {set ty 0} {$ty < $lh} {incr ty} {
        for {set tx 0} {$tx < $lw} {incr tx} {
            set t [lindex $tiles [expr {$ty * $lw + $tx}]]
            if {$t != 0} {
                _draw_tile $tx $ty $t $ts
            }
        }
    }

    # Grid overlay
    if {$show_grid} {
        for {set x 0} {$x <= $lw} {incr x} {
            $canvas create line [expr {$x*$ts}] 0 [expr {$x*$ts}] $ph \
                -fill #182030 -width 1
        }
        for {set y 0} {$y <= $lh} {incr y} {
            $canvas create line 0 [expr {$y*$ts}] $pw [expr {$y*$ts}] \
                -fill #182030 -width 1
        }
    }

    # Objects
    foreach obj [dict get $lvl objects] {
        _draw_object \
            [dict get $obj x] \
            [dict get $obj y] \
            [dict get $obj type] $ts
    }

    # Camera viewport (N64 = 320×240 = 20×15 tiles at 16 px/tile)
    if {$show_cam} {
        set camw [expr {20 * $ts}]
        set camh [expr {15 * $ts}]
        set px 0; set py 0
        foreach obj [dict get $lvl objects] {
            if {[dict get $obj type] eq "player_start"} {
                set px [dict get $obj x]
                set py [dict get $obj y]
                break
            }
        }
        set cx [expr {max(0, min($pw - $camw, $px * $ts - $camw/2))}]
        set cy [expr {max(0, min($ph - $camh, $py * $ts - $camh/2))}]
        $canvas create rectangle $cx $cy \
            [expr {$cx+$camw}] [expr {$cy+$camh}] \
            -outline #2e5a99 -width 2 -dash {6 3}
        $canvas create text [expr {$cx+6}] [expr {$cy+5}] \
            -text "320×240 viewport" -fill #3a70cc \
            -anchor nw -font {TkDefaultFont 7}
    }
}

proc preview_ed::_draw_tile {tx ty type ts} {
    # type: 1=solid, 2=one_way, 3=hazard, 4=ladder
    variable canvas
    set x1 [expr {$tx * $ts}]
    set y1 [expr {$ty * $ts}]
    set x2 [expr {$x1 + $ts}]
    set y2 [expr {$y1 + $ts}]

    switch $type {
        1 {
            # Solid — dark blue-grey block with top highlight
            $canvas create rectangle $x1 $y1 $x2 $y2 \
                -fill #3a5070 -outline #4a6080 -width 1
            $canvas create line $x1 [expr {$y1+1}] $x2 [expr {$y1+1}] \
                -fill #5a7090 -width 1
        }
        2 {
            # One-way platform — thin green ledge
            $canvas create rectangle $x1 [expr {$y2-4}] $x2 $y2 \
                -fill #3a6030 -outline {} -width 0
            $canvas create line $x1 [expr {$y2-4}] $x2 [expr {$y2-4}] \
                -fill #55aa44 -width 2
        }
        3 {
            # Hazard — red spike triangle
            set mx [expr {($x1+$x2)/2}]
            $canvas create polygon $x1 $y2 $mx $y1 $x2 $y2 \
                -fill #6a1818 -outline #cc2222 -width 1
        }
        4 {
            # Ladder — brown vertical rungs
            $canvas create rectangle $x1 $y1 $x2 $y2 \
                -fill #5a3a18 -outline {} -width 0
            for {set ry $y1} {$ry < $y2} {incr ry [expr {max(4,$ts/4)}]} {
                $canvas create line $x1 $ry $x2 $ry -fill #8a6030 -width 1
            }
        }
    }
}

proc preview_ed::_draw_object {tx ty type ts} {
    variable canvas
    set x1 [expr {$tx * $ts + 2}]
    set y1 [expr {$ty * $ts + 2}]
    set x2 [expr {$x1 + $ts - 4}]
    set y2 [expr {$y1 + $ts - 4}]
    set mx [expr {($x1+$x2)/2}]
    set my [expr {($y1+$y2)/2}]
    set r  [expr {max(4, $ts/3)}]
    set fs [expr {max(7, $ts/3)}]

    switch $type {
        player_start {
            $canvas create oval $x1 $y1 $x2 $y2 \
                -fill #1d5c38 -outline #33cc66 -width 2
            $canvas create text $mx $my -text "P" \
                -fill #aaffcc -font "TkDefaultFont $fs bold"
        }
        coin {
            $canvas create oval \
                [expr {$mx-$r}] [expr {$my-$r}] \
                [expr {$mx+$r}] [expr {$my+$r}] \
                -fill #886600 -outline #ffcc00 -width 1
            $canvas create text $mx $my \
                -text "◆" -fill #ffee44 -font "TkDefaultFont $fs"
        }
        enemy_patrol {
            $canvas create rectangle $x1 $y1 $x2 $y2 \
                -fill #6e1818 -outline #ff3333 -width 1
            $canvas create text $mx $my -text "E" \
                -fill #ffaaaa -font "TkDefaultFont $fs bold"
        }
        enemy_jumper {
            $canvas create rectangle $x1 $y1 $x2 $y2 \
                -fill #6e3818 -outline #ff8844 -width 1
            $canvas create text $mx $my -text "J" \
                -fill #ffccaa -font "TkDefaultFont $fs bold"
        }
        spring {
            $canvas create rectangle $x1 [expr {$y2-5}] $x2 $y2 \
                -fill #1d5c38 -outline #44cc88
            $canvas create text $mx [expr {$my-2}] -text "▲" \
                -fill #44ff88 -font "TkDefaultFont $fs"
        }
        checkpoint {
            $canvas create rectangle [expr {$mx-1}] $y1 [expr {$mx+1}] $y2 \
                -fill #00ddff -outline {}
            $canvas create rectangle $mx $y1 [expr {$mx+$r}] [expr {$y1+$r}] \
                -fill #00aacc -outline {}
            $canvas create text $mx $y2 -text "C" \
                -fill #aaffff -anchor s -font "TkDefaultFont $fs bold"
        }
        goal {
            $canvas create rectangle [expr {$mx-1}] [expr {$y1-$ts}] [expr {$mx+1}] $y2 \
                -fill #ffffff -outline {}
            $canvas create polygon \
                [expr {$mx+1}] [expr {$y1-$ts}] \
                $x2 [expr {$y1-$ts/2}] \
                [expr {$mx+1}] $y1 \
                -fill #ffcc00 -outline {}
            $canvas create text $mx $my -text "G" \
                -fill #ffee88 -font "TkDefaultFont $fs bold"
        }
        door {
            $canvas create rectangle $x1 $y1 $x2 $y2 \
                -fill #223366 -outline #5577cc -width 2
            $canvas create text $mx $my -text "D" \
                -fill #aaccff -font "TkDefaultFont $fs bold"
        }
    }
}

proc preview_ed::zoom_in {} {
    variable scale
    if {$scale >= 4} return
    incr scale
    refresh
}

proc preview_ed::zoom_out {} {
    variable scale
    if {$scale <= 1} return
    incr scale -1
    refresh
}

proc preview_ed::_show_coords {x y} {
    variable canvas
    variable scale
    if {$canvas eq "" || ![winfo exists $canvas]} return
    set tx [expr {int([$canvas canvasx $x] / (16 * $scale))}]
    set ty [expr {int([$canvas canvasy $y] / (16 * $scale))}]
    catch { $::app_status_pos configure -text "Tile: $tx, $ty" }
}
