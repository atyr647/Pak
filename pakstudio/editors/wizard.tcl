# editors/wizard.tcl — new project wizard dialog (multi-step)

namespace eval wizard {
    variable result {}
}

proc wizard::show {parent} {
    variable result
    set result {}

    # Destroy any stale dialog left from a previous (cancelled or interrupted)
    # invocation so re-opening the wizard never collides on the window name.
    if {[winfo exists $parent.wiz]} { destroy $parent.wiz }

    set dlg [toplevel $parent.wiz]
    wm title     $dlg "New Project"
    wm resizable $dlg 0 0
    wm transient $dlg $parent
    wm protocol  $dlg WM_DELETE_WINDOW [list wizard::_cancel $dlg]

    # Center over parent (or screen if parent not yet mapped)
    update idletasks
    set w 540; set h 580
    set pw [winfo width  $parent]
    set ph [winfo height $parent]
    if {$pw > 1 && $ph > 1} {
        set cx [expr {[winfo rootx $parent] + ($pw - $w) / 2}]
        set cy [expr {[winfo rooty $parent] + ($ph - $h) / 2}]
    } else {
        set cx [expr {([winfo screenwidth  $dlg] - $w) / 2}]
        set cy [expr {([winfo screenheight $dlg] - $h) / 2}]
    }
    wm geometry $dlg ${w}x${h}+${cx}+${cy}

    # State
    set ::wiz_genre   "platformer"
    set ::wiz_orient  "horizontal"
    set ::wiz_name    "My Game"
    set ::wiz_gravity  0.35
    set ::wiz_jump    -7.5
    set ::wiz_speed    2.5

    # ── Header ────────────────────────────────────────────────────────────────
    ttk::frame $dlg.hdr
    ttk::label $dlg.hdr.title -text "Create New Project" \
        -font {TkDefaultFont 16 bold} -foreground #6aadff
    ttk::label $dlg.hdr.sub -text "Set up your game in a few steps" \
        -foreground #7a8a9f
    pack $dlg.hdr.title -pady {14 2}
    pack $dlg.hdr.sub
    pack $dlg.hdr -fill x

    # ── Step indicator ────────────────────────────────────────────────────────
    ttk::frame $dlg.steps
    set steps {"1  Genre" "2  Name" "3  Create"}
    set i 0
    foreach step $steps {
        set lbl [ttk::label $dlg.steps.s$i -text $step \
            -font {TkDefaultFont 9 bold} -width 12 -anchor center]
        if {$i == 0} {
            $lbl configure -foreground #6aadff
        } else {
            $lbl configure -foreground #3d4a5e
        }
        pack $lbl -side left -padx 4
        set ::wiz_step_lbl($i) $lbl
        incr i
    }
    pack $dlg.steps -pady {8 0}

    ttk::separator $dlg.sep1 -orient horizontal
    pack $dlg.sep1 -fill x -pady {6 0}

    # ── Notebook ──────────────────────────────────────────────────────────────
    set nb [ttk::notebook $dlg.nb]
    pack $nb -fill both -padx 16 -pady 4

    # ── Page 1: Genre ─────────────────────────────────────────────────────────
    set p1 [ttk::frame $nb.p1]
    $nb add $p1 -text " 1. Genre "

    ttk::label $p1.info -text "What kind of game do you want to make?" \
        -foreground #7a8a9f -wraplength 460 -justify left
    pack $p1.info -anchor w -padx 14 -pady {12 10}

    set genres {
        platformer  "2D Platformer"       "Run, jump, collect coins, defeat enemies"
        shmup       "Shoot-em-Up"         "Horizontal or vertical scrolling shooter"
        topdown     "Top-Down RPG"        "Birds-eye RPG: events, quests, crafting, battles"
        fps         "FPS (soon)"          "First-person shooter  [coming soon]"
        racer       "Racer (soon)"        "3D racing game  [coming soon]"
    }
    foreach {id lbl desc} $genres {
        set state [expr {[string match "*soon*" $lbl] ? "disabled" : "normal"}]
        set rf [ttk::frame $p1.rf_$id]
        ttk::radiobutton $rf.r -text $lbl -variable ::wiz_genre -value $id \
            -state $state -command wizard::_on_genre
        ttk::label $rf.d -text $desc -foreground #3d4a5e \
            -font {TkDefaultFont 8}
        pack $rf.r -anchor w
        pack $rf.d -anchor w -padx {20 0}
        pack $rf -anchor w -padx 24 -pady 3
    }

    # Shoot-em-Up scroll direction (only meaningful for the shmup genre)
    set of [ttk::frame $p1.orient]
    ttk::label $of.lbl -text "Scroll Direction:" -foreground #7a8a9f
    ttk::radiobutton $of.h -text "Horizontal" -variable ::wiz_orient -value horizontal
    ttk::radiobutton $of.v -text "Vertical"   -variable ::wiz_orient -value vertical
    pack $of.lbl -side left -padx {0 8}
    pack $of.h $of.v -side left -padx 6
    pack $of -anchor w -padx 24 -pady {10 3}
    set ::wiz_orient_frame $of
    wizard::_on_genre

    # ── Page 2: Name & Physics ────────────────────────────────────────────────
    set p2 [ttk::frame $nb.p2]
    $nb add $p2 -text " 2. Name "

    ttk::label $p2.info -text "Give your game a name:" \
        -foreground #7a8a9f -wraplength 460 -justify left
    pack $p2.info -anchor w -padx 14 -pady {12 6}

    ttk::frame $p2.nf
    ttk::label $p2.nf.lbl -text "Game Name:" -width 14
    ttk::entry $p2.nf.ent -textvariable ::wiz_name -width 28
    pack $p2.nf.lbl $p2.nf.ent -side left -padx 4
    pack $p2.nf -anchor w -padx 24 -pady 4

    ttk::label $p2.lmt -text "(max 20 chars — becomes the ROM title card)" \
        -foreground #3d4a5e -font {TkDefaultFont 8}
    pack $p2.lmt -anchor w -padx 24

    ttk::separator $p2.sep -orient horizontal
    pack $p2.sep -fill x -padx 14 -pady 10

    ttk::label $p2.ph -text "Feel & Physics:" \
        -font {TkDefaultFont 9 bold} -foreground #dde4f0
    pack $p2.ph -anchor w -padx 14

    set presets {
        "Default"   {0.35 -7.5 2.5}
        "Floaty"    {0.20 -6.0 2.2}
        "Heavy"     {0.55 -9.0 3.0}
        "Slippery"  {0.35 -7.5 4.0}
        "Custom"    {}
    }
    ttk::frame $p2.pf
    ttk::label $p2.pf.lbl -text "Preset:" -width 14
    set pnames [list]
    foreach {n _} $presets { lappend pnames $n }
    ttk::combobox $p2.pf.cmb -values $pnames -state readonly -width 16 \
        -textvariable ::wiz_preset
    set ::wiz_preset "Default"
    bind $p2.pf.cmb <<ComboboxSelected>> \
        [list wizard::_apply_preset $presets]
    pack $p2.pf.lbl $p2.pf.cmb -side left -padx 4
    pack $p2.pf -anchor w -padx 24 -pady 6

    foreach {lbl var from to} {
        "Gravity:"    ::wiz_gravity  0.1  2.0
        "Jump Force:" ::wiz_jump    -15.0 -2.0
        "Move Speed:" ::wiz_speed    0.5   8.0
    } {
        ttk::frame $p2.ff_$var
        ttk::label $p2.ff_$var.l -text $lbl -width 14
        ttk::scale $p2.ff_$var.s -variable $var -from $from -to $to \
            -orient horizontal -length 190
        ttk::label $p2.ff_$var.v -textvariable $var -width 7
        pack $p2.ff_$var.l $p2.ff_$var.s $p2.ff_$var.v -side left -padx 4
        pack $p2.ff_$var -anchor w -padx 24 -pady 2
    }

    # ── Page 3: Summary ───────────────────────────────────────────────────────
    set p3 [ttk::frame $nb.p3]
    $nb add $p3 -text " 3. Create "

    ttk::label $p3.icon -text "✓" \
        -font {TkDefaultFont 36} -foreground #2da864
    pack $p3.icon -pady {28 4}

    ttk::label $p3.ready -text "Ready to create!" \
        -font {TkDefaultFont 14 bold} -foreground #dde4f0
    pack $p3.ready -pady {0 8}

    ttk::label $p3.msg \
        -text "PakStudio will create your project with the\nsettings you chose. You can change everything later.\n\nClick Create to open the editor." \
        -justify center -foreground #7a8a9f -wraplength 400
    pack $p3.msg -pady 4

    # ── Buttons ───────────────────────────────────────────────────────────────
    ttk::separator $dlg.sep2 -orient horizontal
    pack $dlg.sep2 -fill x -pady {6 4}

    ttk::frame $dlg.btns
    ttk::button $dlg.btns.cancel -text "Cancel" \
        -command [list wizard::_cancel $dlg]
    ttk::button $dlg.btns.back   -text "← Back" \
        -command [list wizard::_nav $nb $dlg -1]
    ttk::button $dlg.btns.next   -text "Next →" \
        -command [list wizard::_nav $nb $dlg  1]
    ttk::button $dlg.btns.create -text "Create Project" -style Accent.TButton \
        -command [list wizard::_create $dlg]

    pack $dlg.btns.cancel -side left  -padx 6
    pack $dlg.btns.create -side right -padx 6
    pack $dlg.btns.next   -side right -padx 4
    pack $dlg.btns.back   -side right -padx 4
    pack $dlg.btns -fill x -padx 12 -pady {0 10}

    _update_buttons $dlg $nb

    bind $nb <<NotebookTabChanged>> \
        [list wizard::_on_tab_changed $dlg $nb]

    grab set $dlg
    tkwait window $dlg
    return $result
}

proc wizard::_nav {nb dlg dir} {
    set cur   [$nb index current]
    set total [$nb index end]
    set next  [expr {$cur + $dir}]
    if {$next < 0 || $next >= $total} return
    $nb select $next
}

proc wizard::_on_tab_changed {dlg nb} {
    _update_buttons $dlg $nb
    # Update step indicators
    set cur [$nb index current]
    for {set i 0} {$i < 3} {incr i} {
        if {[info exists ::wiz_step_lbl($i)]} {
            if {$i == $cur} {
                $::wiz_step_lbl($i) configure -foreground #6aadff
            } elseif {$i < $cur} {
                $::wiz_step_lbl($i) configure -foreground #2da864
            } else {
                $::wiz_step_lbl($i) configure -foreground #3d4a5e
            }
        }
    }
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
    $btns.back state [expr {$cur == 0 ? "disabled" : "!disabled"}]
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
    if {$::wiz_genre eq "shmup"} {
        project::set_field settings orientation $::wiz_orient
    } else {
        project::set_field physics gravity    $::wiz_gravity
        project::set_field physics jump_force $::wiz_jump
        project::set_field physics move_speed $::wiz_speed
    }
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

# Enable the scroll-direction selector only when the shmup genre is chosen.
proc wizard::_on_genre {} {
    if {![info exists ::wiz_orient_frame] || ![winfo exists $::wiz_orient_frame]} return
    set st [expr {$::wiz_genre eq "shmup" ? "normal" : "disabled"}]
    foreach child [winfo children $::wiz_orient_frame] {
        catch { $child configure -state $st }
    }
}
