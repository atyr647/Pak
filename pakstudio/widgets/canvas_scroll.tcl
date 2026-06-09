# widgets/canvas_scroll.tcl — scrollable, zoomable canvas with pan support

namespace eval canvas_scroll {
    variable instances {}
}

# Create a scrollable canvas inside $parent.
# Returns dict: {canvas <w> xsb <w> ysb <w> frame <w>}
proc canvas_scroll::create {parent args} {
    set f   [ttk::frame $parent.cvsframe]
    set cv  [canvas $f.cv -highlightthickness 0 -bg #222222 {*}$args]
    set vsb [ttk::scrollbar $f.vsb -orient vertical   -command [list $cv yview]]
    set hsb [ttk::scrollbar $f.hsb -orient horizontal -command [list $cv xview]]
    $cv configure -yscrollcommand [list $vsb set] -xscrollcommand [list $hsb set]

    grid $cv  $vsb -sticky nsew
    grid $hsb      -sticky ew
    grid columnconfigure $f 0 -weight 1
    grid rowconfigure    $f 0 -weight 1
    pack $f -fill both -expand 1

    # Pan with middle-mouse
    bind $cv <ButtonPress-2>   [list canvas_scroll::_pan_start $cv %x %y]
    bind $cv <B2-Motion>       [list canvas_scroll::_pan_move  $cv %x %y]

    # Zoom with Ctrl+scroll
    bind $cv <Control-MouseWheel> [list canvas_scroll::_zoom $cv %x %y %D]
    bind $cv <Control-Button-4>   [list canvas_scroll::_zoom $cv %x %y  120]
    bind $cv <Control-Button-5>   [list canvas_scroll::_zoom $cv %x %y -120]

    # Plain scroll
    bind $cv <MouseWheel> [list canvas_scroll::_vscroll $cv %D]
    bind $cv <Button-4>   [list $cv yview scroll -3 units]
    bind $cv <Button-5>   [list $cv yview scroll  3 units]

    # Store zoom level per canvas
    set ::canvas_scroll::zoom($cv) 1.0

    return [dict create canvas $cv vsb $vsb hsb $hsb frame $f]
}

proc canvas_scroll::_pan_start {cv x y} {
    $cv scan mark $x $y
}
proc canvas_scroll::_pan_move {cv x y} {
    $cv scan dragto $cv $x $y 1
}
proc canvas_scroll::_vscroll {cv delta} {
    if {$delta > 0} { $cv yview scroll -3 units } else { $cv yview scroll 3 units }
}
proc canvas_scroll::_zoom {cv x y delta} {
    variable zoom
    set factor [expr {$delta > 0 ? 1.25 : 0.8}]
    set new [expr {$zoom($cv) * $factor}]
    if {$new < 0.25 || $new > 8.0} return
    set zoom($cv) $new
    # Scale all items around the mouse point
    set cx [$cv canvasx $x]
    set cy [$cv canvasy $y]
    $cv scale all $cx $cy $factor $factor
    $cv configure -scrollregion [$cv bbox all]
}

# Reset zoom to 1:1
proc canvas_scroll::reset_zoom {cv} {
    variable zoom
    set z $zoom($cv)
    if {$z == 1.0} return
    set cx [expr {[winfo width  $cv] / 2}]
    set cy [expr {[winfo height $cv] / 2}]
    set factor [expr {1.0 / $z}]
    $cv scale all $cx $cy $factor $factor
    set zoom($cv) 1.0
    $cv configure -scrollregion [$cv bbox all]
}
