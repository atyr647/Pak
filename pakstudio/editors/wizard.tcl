# editors/wizard.tcl — new project wizard dialog (multi-step)

namespace eval wizard {
    variable result {}    ;# set to doc on finish, {} on cancel
}

# Show the wizard dialog on top of $parent.
# Blocks until user finishes or cancels.
# Returns a project doc dict, or {} on cancel.
proc wizard::show {parent} {
    variable result
    set result {}

    set dlg [toplevel $parent.wiz]
    wm title    $dlg "New Project"
    wm resizable $dlg 0 0
    wm transient $dlg $parent
    wm protocol  $dlg WM_DELETE_WINDOW [list wizard::_cancel $dlg]

    # Center over parent
    update idletasks
    set px [winfo rootx $parent]
    set py [winfo rooty $parent]
    set pw [winfo width  $parent]
    set ph [winfo height $parent]
    set w 520
    set h 420
    wm geometry $dlg ${w}x${h}+[expr {$px+($pw-$w)/2}]+[expr {$py+($ph-$h)/2}]

    # State
    set ::wiz_genre    "platformer"
    set ::wiz_name     "My Game"
    set ::wiz_gravity  0.35
    set ::wiz_jump     -7.5
    set ::wiz_speed    2.5

    # Header
    ttk::frame $dlg.hdr
    ttk::label $dlg.hdr.title -text "Create New Project" \
        -font {TkDefaultFont 16 bold} -foreground #88ccff
    ttk::label $dlg.hdr.sub   -text "Set up your game in seconds" \
        -foreground #888888
    pack $dlg.hdr.title -pady {12 2}
    pack $dlg.hdr.sub
    pack $dlg.hdr -fill x

    ttk::separator $dlg.sep1 -orient horizontal
    pack $dlg.sep1 -fill x -pady 8

    # Notebook for steps
    set nb [ttk::notebook $dlg.nb]
    pack $nb -fill both -expand 1 -padx 16 -pady 4

    # ── Page 1: Genre ──────────────────────────────────────────────────────────
    set p1 [ttk::frame $nb.p1]
    $nb add $p1 -text " 1. Genre "

    ttk::label $p1.info -text "What kind of game do you want to make?" \
        -wraplength 440 -justify left
    pack $p1.info -anchor w -padx 12 -pady {12 8}

    set genres {
        platformer  "2D Platformer"  "Run, jump, collect coins, defeat enemies"
        topdown     "Top-Down (soon)" "Birds-eye view RPG / adventure  [coming soon]"
        shmup       "Shoot-em-Up (soon)" "Scrolling shooter  [coming soon]"
        fps         "FPS (soon)"     "First-person shooter  [coming soon]"
        racer       "Racer (soon)"   "3D racing game  [coming soon]"
    }
    foreach {id lbl desc} $genres {
        set state [expr {[string match "*soon*" $lbl] ? "disabled" : "normal"}]
        ttk::radiobutton $p1.r_$id -text $lbl -variable ::wiz_genre -value $id \
            -state $state
        ttk::label $p1.d_$id -text $desc -foreground #888888 \
            -font {TkDefaultFont 8}
        pack $p1.r_$id -anchor w -padx {24 4} -pady {4 0}
        pack $p1.d_$id -anchor w -padx {48 4} -pady {0 2}
    }

    # ── Page 2: Name & Settings ────────────────────────────────────────────────
    set p2 [ttk::frame $nb.p2]
    $nb add $p2 -text " 2. Name "

    ttk::label $p2.info -text "Give your game a name:" \
        -wraplength 440 -justify left
    pack $p2.info -anchor w -padx 12 -pady {12 4}

    ttk::frame $p2.nf
    ttk::label $p2.nf.lbl -text "Game Name:" -width 14
    ttk::entry $p2.nf.ent -textvariable ::wiz_name -width 30
    pack $p2.nf.lbl $p2.nf.ent -side left -padx 4
    pack $p2.nf -anchor w -padx 24 -pady 8

    ttk::label $p2.lmt -text "(max 20 chars — becomes the ROM title card)" \
        -foreground #888888 -font {TkDefaultFont 8}
    pack $p2.lmt -anchor w -padx 24

    ttk::separator $p2.sep -orient horizontal
    pack $p2.sep -fill x -padx 12 -pady 12

    ttk::label $p2.ph -text "Feel & Physics:" -font {TkDefaultFont 9 bold}
    pack $p2.ph -anchor w -padx 12

    set presets {
        "Default"     {0.35 -7.5 2.5}
        "Floaty"      {0.20 -6.0 2.2}
        "Heavy"       {0.55 -9.0 3.0}
        "Slippery"    {0.35 -7.5 4.0}
        "Custom"      {}
    }
    ttk::frame $p2.pf
    ttk::label $p2.pf.lbl -text "Preset:" -width 14
    set pnames [list]
    foreach {n _} $presets { lappend pnames $n }
    ttk::combobox $p2.pf.cmb -values $pnames -state readonly -width 16 \
        -textvariable ::wiz_preset
    set ::wiz_preset "Default"
    bind $p2.pf.cmb <<ComboboxSelected>> [list wizard::_apply_preset $presets]
    pack $p2.pf.lbl $p2.pf.cmb -side left -padx 4
    pack $p2.pf -anchor w -padx 24 -pady 4

    foreach {lbl var from to step} {
        "Gravity:"    ::wiz_gravity  0.1  2.0  0.05
        "Jump Force:" ::wiz_jump    -15.0 -2.0 0.5
        "Move Speed:" ::wiz_speed    0.5   8.0  0.25
    } {
        ttk::frame $p2.ff_$var
        ttk::label $p2.ff_$var.l -text $lbl -width 14
        ttk::scale $p2.ff_$var.s -variable $var -from $from -to $to \
            -orient horizontal -length 200
        ttk::label $p2.ff_$var.v -textvariable $var -width 7
        pack $p2.ff_$var.l $p2.ff_$var.s $p2.ff_$var.v -side left -padx 4
        pack $p2.ff_$var -anchor w -padx 24 -pady 2
    }

    # ── Page 3: Summary ────────────────────────────────────────────────────────
    set p3 [ttk::frame $nb.p3]
    $nb add $p3 -text " 3. Create "

    ttk::label $p3.ready -text "Ready to create!" \
        -font {TkDefaultFont 14 bold} -foreground #66ff88
    pack $p3.ready -pady {24 8}

    ttk::label $p3.msg -text \
        "PakStudio will create your project with the settings\nyou chose. You can change everything later.\n\nClick \"Create\" to open the editor." \
        -justify center -wraplength 400
    pack $p3.msg -pady 8

    # Buttons
    ttk::separator $dlg.sep2 -orient horizontal
    pack $dlg.sep2 -fill x -pady {8 4}

    ttk::frame $dlg.btns
    ttk::button $dlg.btns.cancel -text "Cancel"   -command [list wizard::_cancel $dlg]
    ttk::button $dlg.btns.back   -text "< Back"   -command [list wizard::_nav $nb -1]
    ttk::button $dlg.btns.next   -text "Next >"   -command [list wizard::_nav $nb  1]
    ttk::button $dlg.btns.create -text "Create!"  -style Accent.TButton \
        -command [list wizard::_create $dlg]
    pack $dlg.btns.cancel -side left  -padx 4
    pack $dlg.btns.create -side right -padx 4
    pack $dlg.btns.next   -side right -padx 4
    pack $dlg.btns.back   -side right -padx 4
    pack $dlg.btns -fill x -padx 16 -pady {0 12}

    _update_buttons $dlg $nb

    # Bind tab switch to update buttons
    bind $nb <<NotebookTabChanged>> [list wizard::_update_buttons $dlg $nb]

    grab set $dlg
    tkwait window $dlg
    return $result
}

proc wizard::_nav {nb dir} {
    set cur [$nb index current]
    set total [$nb index end]
    set next [expr {$cur + $dir}]
    if {$next < 0} return
    if {$next >= $total} return
    $nb select $next
}

proc wizard::_update_buttons {dlg nb} {
    set cur   [$nb index current]
    set total [$nb index end]
    set last  [expr {$total - 1}]
    set btns  $dlg.btns
    if {$cur == $last} {
        $btns.next   state disabled
        $btns.create state !disabled
    } else {
        $btns.next   state !disabled
        $btns.create state disabled
    }
    if {$cur == 0} {
        $btns.back state disabled
    } else {
        $btns.back state !disabled
    }
}

proc wizard::_apply_preset {presets} {
    set name $::wiz_preset
    foreach {n vals} $presets {
        if {$n eq $name && $vals ne {}} {
            lassign $vals ::wiz_gravity ::wiz_jump ::wiz_speed
            return
        }
    }
}

proc wizard::_create {dlg} {
    variable result
    set name [string trim $::wiz_name]
    if {$name eq ""} { set name "My Game" }
    set doc [project::new $::wiz_genre $name]
    project::set_field physics gravity    $::wiz_gravity
    project::set_field physics jump_force $::wiz_jump
    project::set_field physics move_speed $::wiz_speed
    set result [project::current_doc]
    grab release $dlg
    destroy $dlg
}

proc wizard::_cancel {dlg} {
    variable result
    set result {}
    grab release $dlg
    destroy $dlg
}
