# editors/level.tcl — visual tile/object level editor

namespace eval level_ed {
    variable canvas    {}
    variable doc       {}
    variable level_idx 0
    variable tile_sz   24     ;# display pixels per tile
    variable cur_tile   1     ;# tile type to paint (1=solid)
    variable cur_tool  "tile" ;# tile | eraser | entity | select
    variable cur_entity "coin"
    variable on_change {}
    variable on_select {}     ;# called with {lvl_idx obj_idx obj} when obj selected
    variable drag_last {}     ;# last painted tile during drag (prevent re-paint)
}

# Tile type → display colour (matches tileset defaults)
proc level_ed::_tile_color {t} {
    switch $t {
        0  { return {} }
        1  { return #AA5533 }
        2  { return #558844 }
        3  { return #FF2200 }
        4  { return #AA8844 }
        default { return #888888 }
    }
}

# Entity type → colour
proc level_ed::_entity_color {type} {
    switch $type {
        coin          { return #FFDD00 }
        enemy_patrol  { return #FF4488 }
        enemy_jumper  { return #FF8844 }
        player_start  { return #00FFAA }
        checkpoint    { return #00DDFF }
        spring        { return #FFCC00 }
        door          { return #8844AA }
        goal          { return #FFFFFF }
        default       { return #FFFFFF }
    }
}

# Create the level editor.
# parent      — Tk frame to pack into
# on_change   — callback when tiles/objects modified
# on_sel      — callback {lvl_idx obj_idx obj} when object selected
proc level_ed::create {parent on_change_cb on_sel_cb} {
    variable canvas
    variable on_change
    variable on_select
    set on_change $on_change_cb
    set on_select $on_sel_cb

    set f [ttk::frame $parent.leved]

    # Toolbar (packed at top)
    set tb [ttk::frame $f.toolbar]
    _make_toolbar $tb
    pack $tb -fill x -padx 4 -pady 2

    ttk::separator $f.tbs -orient horizontal
    pack $f.tbs -fill x

    # Canvas area (inner frame, uses grid for scrollbars)
    set cvf [ttk::frame $f.cvf]
    pack $cvf -fill both -expand 1

    set cv [canvas $cvf.cv -bg #1a1a2e -highlightthickness 1 \
        -highlightcolor #334466 -cursor crosshair]
    set vsb [ttk::scrollbar $cvf.vsb -orient vertical   -command [list $cv yview]]
    set hsb [ttk::scrollbar $cvf.hsb -orient horizontal -command [list $cv xview]]
    $cv configure -yscrollcommand [list $vsb set] -xscrollcommand [list $hsb set]

    grid $cv  $vsb -sticky nsew
    grid $hsb      -sticky ew
    grid columnconfigure $cvf 0 -weight 1
    grid rowconfigure    $cvf 0 -weight 1

    set canvas $cv

    # Mouse bindings
    bind $cv <ButtonPress-1>   [list level_ed::_on_press   %x %y]
    bind $cv <B1-Motion>       [list level_ed::_on_drag    %x %y]
    bind $cv <ButtonRelease-1> [list level_ed::_on_release %x %y]
    bind $cv <ButtonPress-3>   [list level_ed::_on_rclick  %x %y]
    bind $cv <Motion>          [list level_ed::_on_hover   %x %y]
    bind $cv <Leave>           [list level_ed::_on_leave]

    # Scroll
    bind $cv <MouseWheel> [list level_ed::_scroll $cv %D]
    bind $cv <Button-4>   [list $cv yview scroll -3 units]
    bind $cv <Button-5>   [list $cv yview scroll  3 units]

    # Keyboard shortcuts
    bind $cv <Key-q>  [list level_ed::set_tool tile]
    bind $cv <Key-e>  [list level_ed::set_tool eraser]
    bind $cv <Key-r>  [list level_ed::set_tool entity]
    bind $cv <Key-s>  [list level_ed::set_tool select]
    bind $cv <Key-1>  [list level_ed::set_cur_tile 1]
    bind $cv <Key-2>  [list level_ed::set_cur_tile 2]
    bind $cv <Key-3>  [list level_ed::set_cur_tile 3]
    focus $cv

    pack $f -fill both -expand 1
    return $f
}

proc level_ed::_make_toolbar {tb} {
    variable cur_tool
    variable cur_tile
    variable cur_entity

    # Tool buttons
    foreach {id icon tip} {
        tile    "■"  "Paint Tile (Q)"
        eraser  "□"  "Erase (E)"
        entity  "★"  "Place Object (R)"
        select  "↖"  "Select Object (S)"
    } {
        ttk::button $tb.t_$id -text "$icon $tip" \
            -command [list level_ed::set_tool $id] \
            -style Toolbutton
        pack $tb.t_$id -side left -padx 2
    }

    ttk::separator $tb.sep1 -orient vertical
    pack $tb.sep1 -side left -fill y -padx 4

    # Tile type palette
    ttk::label $tb.tlbl -text "Tile:"
    pack $tb.tlbl -side left -padx 2

    foreach {t lbl col} {
        1 "■ Solid"    #AA5533
        2 "▤ Platform" #558844
        3 "✕ Hazard"  #FF2200
    } {
        ttk::button $tb.tile_$t -text $lbl \
            -command [list level_ed::set_cur_tile $t] -style Toolbutton
        pack $tb.tile_$t -side left -padx 1
    }

    ttk::separator $tb.sep2 -orient vertical
    pack $tb.sep2 -side left -fill y -padx 4

    # Entity palette
    ttk::label $tb.elbl -text "Entity:"
    pack $tb.elbl -side left -padx 2

    foreach {id lbl} {
        coin         "Coin"
        enemy_patrol "Patrol"
        enemy_jumper "Jumper"
        spring       "Spring"
        checkpoint   "Checkpoint"
        goal         "Goal"
        door         "Door"
    } {
        ttk::button $tb.ent_$id -text $lbl \
            -command [list level_ed::set_cur_entity $id] -style Toolbutton
        pack $tb.ent_$id -side left -padx 1
    }

    ttk::separator $tb.sep3 -orient vertical
    pack $tb.sep3 -side left -fill y -padx 4

    # Zoom buttons
    ttk::button $tb.zin  -text "+" -command [list level_ed::_zoom  1] -width 2
    ttk::button $tb.zout -text "-" -command [list level_ed::_zoom -1] -width 2
    ttk::button $tb.zrst -text "1:1" -command [list level_ed::_zoom_reset] -width 3
    pack $tb.zout $tb.zin $tb.zrst -side right -padx 1
}

proc level_ed::set_tool {t} {
    variable cur_tool
    variable canvas
    set cur_tool $t
    switch $t {
        tile   { $canvas configure -cursor crosshair }
        eraser { $canvas configure -cursor X_cursor  }
        entity { $canvas configure -cursor plus      }
        select { $canvas configure -cursor arrow     }
    }
}

proc level_ed::set_cur_tile {t} {
    variable cur_tile
    set cur_tile $t
    set_tool tile
}

proc level_ed::set_cur_entity {id} {
    variable cur_entity
    set cur_entity $id
    set_tool entity
}

# Load a project doc into the editor.
proc level_ed::load_doc {d {li 0}} {
    variable doc
    variable level_idx
    set doc       $d
    set level_idx $li
    _redraw
}

# Refresh after external change.
proc level_ed::refresh {} {
    variable doc
    set doc [project::current_doc]
    _redraw
}

# ── Drawing ─────────────────────────────────────────────────────────────────

proc level_ed::_redraw {} {
    variable canvas
    variable doc
    variable level_idx
    variable tile_sz
    if {$canvas eq {} || $doc eq {}} return

    $canvas delete all

    set lvl  [lindex [dict get $doc levels] $level_idx]
    set W    [dict get $lvl width]
    set H    [dict get $lvl height]
    set tiles [dict get $lvl tiles]

    # Background
    $canvas configure -scrollregion [list 0 0 \
        [expr {$W * $tile_sz}] [expr {$H * $tile_sz}]]

    # Tiles
    for {set ty 0} {$ty < $H} {incr ty} {
        for {set tx 0} {$tx < $W} {incr tx} {
            set t [lindex $tiles [expr {$ty * $W + $tx}]]
            set x1 [expr {$tx * $tile_sz}]
            set y1 [expr {$ty * $tile_sz}]
            set x2 [expr {$x1 + $tile_sz}]
            set y2 [expr {$y1 + $tile_sz}]
            set col [_tile_color $t]
            if {$col ne {}} {
                $canvas create rectangle $x1 $y1 $x2 $y2 \
                    -fill $col -outline #000000 -width 0.5 \
                    -tags [list tile tile_${tx}_${ty}]
            } else {
                # Grid dot for empty tiles (every 4th)
                if {($tx % 4 == 0) && ($ty % 4 == 0)} {
                    $canvas create rectangle $x1 $y1 $x2 $y2 \
                        -fill {} -outline #1e2a3a -width 0.5 \
                        -tags [list tile tile_${tx}_${ty}]
                }
            }
        }
    }

    # Objects
    foreach {oi obj} [_indexed_objects $lvl] {
        _draw_object $oi $obj
    }
}

proc level_ed::_indexed_objects {lvl} {
    set result {}
    set objs [dict get $lvl objects]
    set i 0
    foreach obj $objs {
        lappend result $i $obj
        incr i
    }
    return $result
}

proc level_ed::_draw_object {oi obj} {
    variable canvas
    variable tile_sz
    set type [dict get $obj type]
    set col  [_entity_color $type]
    set ox   [dict get $obj x]
    set oy   [dict get $obj y]
    set x1 [expr {$ox * $tile_sz + 2}]
    set y1 [expr {$oy * $tile_sz + 2}]
    set x2 [expr {$x1 + $tile_sz - 4}]
    set y2 [expr {$y1 + $tile_sz - 4}]
    set id [$canvas create oval $x1 $y1 $x2 $y2 \
        -fill $col -outline white -width 1.5 \
        -tags [list obj obj_$oi]]
    # Short label inside
    set abbrev [string index $type 0]
    $canvas create text [expr {($x1+$x2)/2}] [expr {($y1+$y2)/2}] \
        -text [string toupper $abbrev] -fill black \
        -font {TkDefaultFont 8 bold} -tags [list obj obj_$oi]
}

# ── Mouse handlers ─────────────────────────────────────────────────────────

proc level_ed::_canvas_to_tile {cx cy} {
    variable canvas
    variable tile_sz
    set x [$canvas canvasx $cx]
    set y [$canvas canvasy $cy]
    return [list [expr {int($x / $tile_sz)}] [expr {int($y / $tile_sz)}]]
}

proc level_ed::_on_press {cx cy} {
    variable cur_tool
    variable canvas
    focus $canvas
    switch $cur_tool {
        tile   { _paint $cx $cy }
        eraser { _erase $cx $cy }
        entity { _place_entity $cx $cy }
        select { _try_select $cx $cy }
    }
}

proc level_ed::_on_drag {cx cy} {
    variable cur_tool
    variable drag_last
    switch $cur_tool {
        tile   {
            lassign [_canvas_to_tile $cx $cy] tx ty
            if {"$tx,$ty" ne $drag_last} {
                set drag_last "$tx,$ty"
                _paint $cx $cy
            }
        }
        eraser {
            lassign [_canvas_to_tile $cx $cy] tx ty
            if {"$tx,$ty" ne $drag_last} {
                set drag_last "$tx,$ty"
                _erase $cx $cy
            }
        }
    }
}

proc level_ed::_on_release {cx cy} {
    variable drag_last
    set drag_last {}
}

proc level_ed::_on_rclick {cx cy} {
    # Right-click erases
    _erase $cx $cy
}

proc level_ed::_on_hover {cx cy} {
    variable canvas
    variable tile_sz
    lassign [_canvas_to_tile $cx $cy] tx ty
    $canvas delete hover_rect
    set x1 [expr {$tx * $tile_sz}]
    set y1 [expr {$ty * $tile_sz}]
    $canvas create rectangle $x1 $y1 \
        [expr {$x1+$tile_sz}] [expr {$y1+$tile_sz}] \
        -outline #ffffff -fill {} -width 1.5 -tags hover_rect
}

proc level_ed::_on_leave {} {
    variable canvas
    $canvas delete hover_rect
}

proc level_ed::_paint {cx cy} {
    variable level_idx
    variable cur_tile
    lassign [_canvas_to_tile $cx $cy] tx ty
    set lvl [lindex [dict get [project::current_doc] levels] $level_idx]
    if {$tx < 0 || $tx >= [dict get $lvl width]}  return
    if {$ty < 0 || $ty >= [dict get $lvl height]} return
    project::set_tile $level_idx $tx $ty $cur_tile
    _redraw_tile $tx $ty $cur_tile
    {*}$::level_ed::on_change
}

proc level_ed::_erase {cx cy} {
    variable level_idx
    lassign [_canvas_to_tile $cx $cy] tx ty
    set lvl [lindex [dict get [project::current_doc] levels] $level_idx]
    if {$tx < 0 || $tx >= [dict get $lvl width]}  return
    if {$ty < 0 || $ty >= [dict get $lvl height]} return
    project::set_tile $level_idx $tx $ty 0
    _redraw_tile $tx $ty 0
    {*}$::level_ed::on_change
}

proc level_ed::_redraw_tile {tx ty t} {
    variable canvas
    variable tile_sz
    $canvas delete tile_${tx}_${ty}
    set x1 [expr {$tx * $tile_sz}]
    set y1 [expr {$ty * $tile_sz}]
    set x2 [expr {$x1 + $tile_sz}]
    set y2 [expr {$y1 + $tile_sz}]
    set col [_tile_color $t]
    if {$col ne {}} {
        $canvas create rectangle $x1 $y1 $x2 $y2 \
            -fill $col -outline #000000 -width 0.5 \
            -tags [list tile tile_${tx}_${ty}]
    } else {
        if {($tx % 4 == 0) && ($ty % 4 == 0)} {
            $canvas create rectangle $x1 $y1 $x2 $y2 \
                -fill {} -outline #1e2a3a -width 0.5 \
                -tags [list tile tile_${tx}_${ty}]
        }
    }
    $canvas raise hover_rect
}

proc level_ed::_place_entity {cx cy} {
    variable cur_entity
    variable level_idx
    lassign [_canvas_to_tile $cx $cy] tx ty
    project::add_object $level_idx [dict create type $cur_entity x $tx y $ty]
    {*}$::level_ed::on_change
    _redraw
}

proc level_ed::_try_select {cx cy} {
    variable canvas
    variable tile_sz
    variable level_idx
    variable on_select
    set x [$canvas canvasx $cx]
    set y [$canvas canvasy $cy]
    set items [$canvas find overlapping \
        [expr {$x-2}] [expr {$y-2}] [expr {$x+2}] [expr {$y+2}]]
    foreach item $items {
        set tags [$canvas gettags $item]
        foreach tag $tags {
            if {[string match "obj_*" $tag]} {
                set oi [string range $tag 4 end]
                set lvl [lindex [dict get [project::current_doc] levels] $level_idx]
                set obj [lindex [dict get $lvl objects] $oi]
                if {$on_select ne {}} {
                    {*}$on_select $level_idx $oi $obj
                }
                return
            }
        }
    }
    # Clicked empty space — deselect
    if {$on_select ne {}} {
        {*}$on_select {} {} {}
    }
}

proc level_ed::_scroll {cv delta} {
    if {$delta > 0} { $cv yview scroll -3 units } else { $cv yview scroll 3 units }
}

proc level_ed::_zoom {dir} {
    variable tile_sz
    set tile_sz [expr {max(8, min(64, $tile_sz + $dir * 4))}]
    _redraw
}

proc level_ed::_zoom_reset {} {
    variable tile_sz
    set tile_sz 24
    _redraw
}
