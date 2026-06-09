# widgets/log_panel.tcl — scrollable streaming build-log text widget

namespace eval log_panel {}

# Create the log panel as a child of $parent.
# Returns the widget path of the text area (useful for direct access).
proc log_panel::create {parent} {
    set f [ttk::frame $parent.logframe]

    set hdr [ttk::frame $f.hdr]
    ttk::label $hdr.lbl -text "Build Log" -font {TkDefaultFont 9 bold}
    ttk::button $hdr.clr -text "Clear" -style Toolbutton \
        -command [list log_panel::clear $f.txt]
    pack $hdr.lbl -side left
    pack $hdr.clr -side right
    pack $hdr -fill x -padx 4 -pady {4 0}

    set txt [text $f.txt -height 8 -wrap none -state disabled \
        -font {TkFixedFont 9} -bg #1a1a1a -fg #e0e0e0 \
        -insertbackground white -relief flat -borderwidth 0]
    set vsb [ttk::scrollbar $f.vsb -orient vertical   -command [list $txt yview]]
    set hsb [ttk::scrollbar $f.hsb -orient horizontal -command [list $txt xview]]
    $txt configure -yscrollcommand [list $vsb set] -xscrollcommand [list $hsb set]

    # Colour tags
    $txt tag configure tag_err  -foreground #ff6060
    $txt tag configure tag_warn -foreground #ffcc44
    $txt tag configure tag_ok   -foreground #66ff88
    $txt tag configure tag_hdr  -foreground #88ccff -font {TkFixedFont 9 bold}

    grid $txt $vsb -sticky nsew
    grid $hsb      -sticky ew
    grid columnconfigure $f 0 -weight 1
    grid rowconfigure    $f 0 -weight 1

    pack $f -fill both -expand 1
    return $f.txt
}

# Append one line to the log widget with auto-colour coding.
proc log_panel::append {txt line} {
    set tag {}
    if {[string match "ERROR:*" $line] || [string match "*error*" [string tolower $line]]} {
        set tag tag_err
    } elseif {[string match "---*" $line]} {
        set tag tag_hdr
    } elseif {[string match "  PASS:*" $line]} {
        set tag tag_ok
    } elseif {[string match "*warning*" [string tolower $line]]} {
        set tag tag_warn
    }

    $txt configure -state normal
    if {$tag ne {}} {
        $txt insert end "$line\n" $tag
    } else {
        $txt insert end "$line\n"
    }
    $txt configure -state disabled
    $txt see end
    update idletasks
}

proc log_panel::clear {txt} {
    $txt configure -state normal
    $txt delete 1.0 end
    $txt configure -state disabled
}
