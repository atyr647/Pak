#!/usr/bin/env wish
# PakStudio — zero-code N64 game development suite

package require Tk

# ── Source modules ─────────────────────────────────────────────────────────────

set here [file dirname [file normalize [info script]]]

foreach f {
    app/rpg_schema.tcl
    app/project.tcl
    codegen/platformer.tcl
    codegen/shmup.tcl
    codegen/topdown.tcl
    app/codegen.tcl
    app/validate.tcl
    app/build.tcl
    widgets/log_panel.tcl
    widgets/prop_panel.tcl
    widgets/canvas_scroll.tcl
    editors/wizard.tcl
    editors/physics.tcl
    editors/controls.tcl
    editors/entity.tcl
    editors/level.tcl
    editors/audio.tcl
    editors/save_editor.tcl
    editors/preview.tcl
    editors/assets.tcl
    editors/rpg_common.tcl
    editors/rpg_db.tcl
    editors/rpg_events.tcl
    editors/rpg_quests.tcl
    editors/rpg_craft.tcl
    editors/rpg_dialogue.tcl
    editors/rpg_world.tcl
    editors/rpg.tcl
} {
    source [file join $here $f]
}

# ── Application state ─────────────────────────────────────────────────────────

namespace eval app {
    variable outdir       ""
    variable log_widget   ""
    variable build_running false
}

# ── Premium dark theme ─────────────────────────────────────────────────────────

proc app::setup_theme {} {
    # Palette — define as Tcl variables for substitution
    set bg0  #0a0d14
    set bg1  #131720
    set bg2  #1a1f2e
    set bg3  #21273a
    set bgIn #272e42
    set bgHv #2e3650
    set bgSl #1a3f72
    set fg0  #dde4f0
    set fg1  #7a8a9f
    set fg2  #3d4a5e
    set acc2 #6aadff
    set bdr  #1e2540

    ttk::style theme use clam

    ttk::style configure . \
        -background $bg1 -foreground $fg0 \
        -fieldbackground $bgIn -selectbackground $bgSl \
        -selectforeground $fg0 \
        -troughcolor $bg0 -bordercolor $bdr \
        -font {TkDefaultFont 9}

    ttk::style configure TFrame       -background $bg1
    ttk::style configure TLabel       -background $bg1 -foreground $fg0
    ttk::style configure TLabelframe  -background $bg1 -foreground $acc2
    ttk::style configure TLabelframe.Label -background $bg1 -foreground $acc2

    ttk::style configure TButton \
        -background $bg3 -foreground $fg0 \
        -relief flat -padding {8 4} -borderwidth 0
    ttk::style map TButton \
        -background [list active $bgHv pressed $bg2 disabled $bg2] \
        -foreground [list disabled $fg2]

    ttk::style configure Toolbar.TButton \
        -background $bg2 -foreground $fg1 \
        -relief flat -padding {10 5} -borderwidth 0
    ttk::style map Toolbar.TButton \
        -background [list active $bgHv pressed $bg1 selected $bgSl] \
        -foreground [list active $fg0 selected $acc2]

    ttk::style configure Toolbutton \
        -background $bg2 -foreground $fg1 -relief flat -padding {4 3}
    ttk::style map Toolbutton \
        -background [list active $bgHv selected $bgSl] \
        -foreground [list active $fg0 selected $acc2]

    ttk::style configure Accent.TButton \
        -background #1d5c38 -foreground #ffffff -padding {12 5}
    ttk::style map Accent.TButton \
        -background {active #247a4a pressed #164830}

    ttk::style configure Danger.TButton \
        -background #5c1c1c -foreground #ffffff -padding {8 4}
    ttk::style map Danger.TButton \
        -background {active #7a2424 pressed #3e1010}

    ttk::style configure TEntry \
        -fieldbackground $bgIn -foreground $fg0 \
        -insertcolor #ffffff -relief flat -borderwidth 1

    ttk::style configure TSpinbox \
        -fieldbackground $bgIn -foreground $fg0 \
        -arrowcolor $fg1 -relief flat -borderwidth 1

    ttk::style configure TCombobox \
        -fieldbackground $bgIn -foreground $fg0 \
        -arrowcolor $fg1 -relief flat -borderwidth 1
    ttk::style map TCombobox \
        -fieldbackground [list readonly $bg3]

    ttk::style configure TNotebook -background $bg0 -borderwidth 0
    ttk::style configure TNotebook.Tab \
        -background $bg2 -foreground $fg2 \
        -padding {14 6} -borderwidth 0
    ttk::style map TNotebook.Tab \
        -background [list selected $bg1 active $bg3] \
        -foreground [list selected $fg0 active $fg1]

    ttk::style configure TSeparator   -background $bdr
    ttk::style configure TPanedwindow -background $bg0
    ttk::style configure Sash -sashthickness 4 -sashpad 0

    ttk::style configure TScrollbar \
        -background $bg2 -troughcolor $bg0 \
        -arrowcolor $fg2 -borderwidth 0 -relief flat
    ttk::style map TScrollbar \
        -background [list active $bgHv]

    ttk::style configure TScale \
        -background $bg1 -troughcolor $bgIn
    ttk::style map TScale \
        -background [list active $bg1]

    ttk::style configure TCheckbutton -background $bg1 -foreground $fg0
    ttk::style map TCheckbutton \
        -background [list active $bg1] \
        -foreground [list active $fg0]

    ttk::style configure TRadiobutton -background $bg1 -foreground $fg0
    ttk::style map TRadiobutton \
        -background [list active $bg1] \
        -foreground [list active $fg0]

    # Named label / frame styles
    ttk::style configure Header.TLabel \
        -font {TkDefaultFont 10 bold} -foreground $acc2
    ttk::style configure Subtitle.TLabel \
        -foreground $fg1 -font {TkDefaultFont 8}
    ttk::style configure Section.TLabel \
        -foreground $fg2 -font {TkDefaultFont 8 bold}
    ttk::style configure Sep.TFrame -background $bdr

    . configure -background $bg0
}

# ── Main window ────────────────────────────────────────────────────────────────

proc app::create_main_window {} {
    variable log_widget

    wm title    . "PakStudio — N64 Game Dev Suite"
    wm geometry . "1280x800"
    wm minsize  . 960 640
    catch { wm iconname . "PakStudio" }

    setup_theme
    _create_menu

    # Toolbar sits at the top
    _create_toolbar

    ttk::separator .sep_tb -orient horizontal
    pack .sep_tb -fill x -side top

    # Status bar and log anchored to the bottom (must pack before the expand widget)
    _create_status_bar

    ttk::separator .sep_bot -orient horizontal
    pack .sep_bot -fill x -side bottom

    set bot [ttk::frame .bot]
    pack $bot -fill x -side bottom
    set log_widget [log_panel::create $bot]

    # Main three-panel layout
    set pw [ttk::panedwindow .pw -orient horizontal]
    pack $pw -fill both -expand 1

    set left [ttk::frame $pw.left -width 200]
    $pw add $left -weight 0
    _create_left_panel $left

    set centre [ttk::frame $pw.centre]
    $pw add $centre -weight 3
    _create_centre_panel $centre

    set right [ttk::frame $pw.right -width 220]
    $pw add $right -weight 0
    _create_right_panel $right
}

# ── Toolbar ───────────────────────────────────────────────────────────────────

proc app::_create_toolbar {} {
    set tb [ttk::frame .toolbar]
    pack .toolbar -fill x -side top

    set n 0
    foreach {id lbl cmd} {
        new    "New"       app::cmd_new
        open   "Open"      app::cmd_open
        save   "Save"      app::cmd_save
        -      -           -
        build  "Build"     app::cmd_build
        run    "Run"       app::cmd_run
        -      -           -
        check  "Check"     app::cmd_validate
    } {
        if {$id eq "-"} {
            incr n
            set s [ttk::frame $tb.s$n -width 1 -style Sep.TFrame]
            pack $s -side left -fill y -pady 4 -padx 4
        } else {
            ttk::button $tb.b$id -text $lbl -command $cmd \
                -style Toolbar.TButton -takefocus 0
            pack $tb.b$id -side left -padx 1 -pady 3
        }
    }

    # Right-side: project indicator (shows "● Saved" or "● Unsaved")
    set ::app_proj_indicator [ttk::label $tb.proj \
        -text "No project" -style Subtitle.TLabel -anchor e]
    pack $tb.proj -side right -padx 12
}

# ── Left panel ────────────────────────────────────────────────────────────────

proc app::_create_left_panel {f} {
    # ── Level/Map list ────────────────────────────────────────────────────────
    set ::app_level_hdr [ttk::label $f.lhdr -text "LEVELS" -style Section.TLabel]
    pack $f.lhdr -anchor w -padx 10 -pady {10 4}

    set lb [listbox $f.lb -selectmode single \
        -bg #1a1f2e -fg #dde4f0 \
        -selectbackground #1a3f72 -selectforeground #dde4f0 \
        -borderwidth 0 -highlightthickness 0 \
        -height 8 -font {TkDefaultFont 9} \
        -activestyle none]
    pack $lb -fill x -padx 8
    bind $lb <<ListboxSelect>> [list app::_on_level_select $lb]
    set ::app_level_lb $lb

    set btnf [ttk::frame $f.btnf]
    set ::app_level_add_btn [ttk::button $btnf.add -text "+ Add Level" \
        -command app::_add_level -style Toolbutton]
    set ::app_level_del_btn [ttk::button $btnf.del -text "− Remove" \
        -command app::_del_level -style Toolbutton]
    pack $btnf.add $btnf.del -side left -padx 2
    pack $btnf -anchor w -padx 8 -pady 4

    # ── Platformer info (tile legend + shortcuts) ─────────────────────────────
    set pif [ttk::frame $f.plat_info]
    set ::app_plat_info $pif
    pack $pif -fill x

    ttk::separator $pif.sep1 -orient horizontal
    pack $pif.sep1 -fill x -padx 8 -pady {8 4}
    ttk::label $pif.thdr -text "TILE TYPES" -style Section.TLabel
    pack $pif.thdr -anchor w -padx 10 -pady {0 4}

    set ti 0
    foreach {col lbl} {
        #4a6080  "Solid (key: 1)"
        #55aa44  "One-Way (key: 2)"
        #cc2222  "Hazard (key: 3)"
    } {
        set rf [ttk::frame $pif.pt$ti]; incr ti
        canvas $rf.dot -width 14 -height 14 -highlightthickness 0 -bg #1a1f2e
        $rf.dot create rectangle 2 2 12 12 -fill $col -outline {}
        ttk::label $rf.lbl -text $lbl -style Subtitle.TLabel -anchor w
        pack $rf.dot $rf.lbl -side left -padx {0 4}
        pack $rf -anchor w -padx {24 8} -pady 1
    }

    ttk::separator $pif.sep2 -orient horizontal
    pack $pif.sep2 -fill x -padx 8 -pady {8 4}
    ttk::label $pif.shdr -text "SHORTCUTS" -style Section.TLabel
    pack $pif.shdr -anchor w -padx 10 -pady {0 4}

    set si 0
    foreach {key lbl} {
        "Q"     "Paint tile"
        "E"     "Erase"
        "R"     "Place object"
        "S"     "Select object"
        "1/2/3" "Tile type"
        "+/−"   "Zoom"
        "Drag"  "Pan"
    } {
        set sf [ttk::frame $pif.ps$si]; incr si
        ttk::label $sf.k -text $key -foreground #6aadff \
            -font {TkDefaultFont 8 bold} -width 6 -anchor e
        ttk::label $sf.l -text $lbl -style Subtitle.TLabel
        pack $sf.k $sf.l -side left -padx {0 6}
        pack $sf -anchor w -padx {12 8} -pady 1
    }

    # ── RPG info (map tile palette + editor guide) ────────────────────────────
    set rif [ttk::frame $f.rpg_info]
    set ::app_rpg_info $rif
    # hidden until an RPG project loads

    ttk::separator $rif.sep1 -orient horizontal
    pack $rif.sep1 -fill x -padx 8 -pady {8 4}
    ttk::label $rif.thdr -text "MAP TILES" -style Section.TLabel
    pack $rif.thdr -anchor w -padx 10 -pady {0 4}

    set ri 0
    foreach {col lbl} {
        #3C7A3C "Grass  (1)"
        #9A7B4F "Dirt   (2)"
        #5A5A66 "Wall   (3)"
        #C8BCA0 "Floor  (4)"
        #2E6FA8 "Water  (5)"
        #1E5A2A "Tree   (7)"
        #A07845 "Bridge (8)"
    } {
        set rf [ttk::frame $rif.rt$ri]; incr ri
        canvas $rf.dot -width 14 -height 14 -highlightthickness 0 -bg #1a1f2e
        $rf.dot create rectangle 2 2 12 12 -fill $col -outline {}
        ttk::label $rf.lbl -text $lbl -style Subtitle.TLabel -anchor w
        pack $rf.dot $rf.lbl -side left -padx {0 4}
        pack $rf -anchor w -padx {24 8} -pady 1
    }

    ttk::separator $rif.sep2 -orient horizontal
    pack $rif.sep2 -fill x -padx 8 -pady {8 4}
    ttk::label $rif.shdr -text "RPG EDITORS" -style Section.TLabel
    pack $rif.shdr -anchor w -padx 10 -pady {0 4}

    set hi 0
    foreach {key lbl} {
        "Events"   "Map events & scripts"
        "Database" "Actors, enemies, skills"
        "Quests"   "Quest objectives"
        "Crafting" "Recipes & stations"
        "Dialogue" "NPC conversation trees"
        "World"    "Switches, shops, start"
    } {
        set sf [ttk::frame $rif.rh$hi]; incr hi
        ttk::label $sf.k -text $key -foreground #6aadff \
            -font {TkDefaultFont 8 bold} -width 10 -anchor e
        ttk::label $sf.l -text $lbl -style Subtitle.TLabel
        pack $sf.k $sf.l -side left -padx {0 6}
        pack $sf -anchor w -padx {12 8} -pady 1
    }
}

proc app::_on_level_select {lb} {
    set sel [$lb curselection]
    if {$sel eq {}} return
    set idx [lindex $sel 0]
    if {$::app_genre eq "topdown"} {
        catch { rpg_ev::goto_map $idx }
        return
    }
    level_ed::load_doc [project::current_doc] $idx
    preview_ed::load_doc [project::current_doc] $idx
}

proc app::_add_level {} {
    set idx [project::add_level]
    _refresh_level_list
    $::app_level_lb selection clear 0 end
    $::app_level_lb selection set $idx
    level_ed::load_doc [project::current_doc] $idx
    preview_ed::load_doc [project::current_doc] $idx
}

proc app::_del_level {} {
    set sel [$::app_level_lb curselection]
    if {$sel eq {}} return
    set idx [lindex $sel 0]
    set doc [project::current_doc]
    set lvls [dict get $doc levels]
    if {[llength $lvls] <= 1} {
        tk_messageBox -title "Cannot Delete" \
            -message "A project must have at least one level." -icon warning
        return
    }
    set lvls [lreplace $lvls $idx $idx]
    project::set_field levels $lvls
    _refresh_level_list
    $::app_level_lb selection set 0
    level_ed::load_doc [project::current_doc] 0
    preview_ed::load_doc [project::current_doc] 0
}

proc app::_update_left_panel_for_genre {genre} {
    if {$genre eq "topdown"} {
        $::app_level_hdr configure -text "MAPS"
        $::app_level_add_btn configure -text "+ Add Map" -command app::_add_rpg_map
        $::app_level_del_btn configure -text "− Remove"  -command app::_del_rpg_map
        catch { pack forget $::app_plat_info }
        catch { pack $::app_rpg_info -fill x }
    } else {
        $::app_level_hdr configure -text "LEVELS"
        $::app_level_add_btn configure -text "+ Add Level" -command app::_add_level
        $::app_level_del_btn configure -text "− Remove"   -command app::_del_level
        catch { pack forget $::app_rpg_info }
        catch { pack $::app_plat_info -fill x }
    }
}

proc app::_add_rpg_map {} { catch { rpg_ev::add_map } }

proc app::_del_rpg_map {} {
    set sel [$::app_level_lb curselection]
    if {$sel eq {}} return
    catch { rpg_ev::del_map [lindex $sel 0] }
}

proc app::_refresh_level_list {} {
    set lb $::app_level_lb
    $lb delete 0 end
    set doc [project::current_doc]
    set i 0
    foreach lvl [dict get $doc levels] {
        $lb insert end "  [expr {$i+1}]. [dict get $lvl name]"
        incr i
    }
}

# ── Centre panel ──────────────────────────────────────────────────────────────

# The centre notebook is populated lazily per-genre by _populate_centre, which
# runs when a project loads. ::app_genre tracks which tab set is currently live.
set ::app_genre ""

proc app::_create_centre_panel {f} {
    set nb [ttk::notebook $f.nb]
    pack $nb -fill both -expand 1
    bind $nb <<NotebookTabChanged>> app::_on_tab_changed
    set ::app_centre_nb $nb
}

# Build the tab set appropriate to $genre, replacing whatever was there.
proc app::_populate_centre {genre} {
    set nb $::app_centre_nb
    if {$::app_genre eq $genre && [llength [$nb tabs]] > 0} return
    foreach t [$nb tabs] { destroy $t }
    set ::app_genre $genre
    if {$genre eq "topdown"} {
        rpg_ed::create_tabs $nb
        set ast [ttk::frame $nb.rpg_ast]
        $nb add $ast -text "  Assets  "
        assets_ed::create $ast
        set rom [ttk::frame $nb.rpg_rom]
        $nb add $rom -text "  ROM Settings  "
        save_ed::create $rom
    } else {
        set led [ttk::frame $nb.led]
        $nb add $led -text "  Level Editor  "
        level_ed::create $led app::_on_level_changed app::_on_object_selected

        set prv [ttk::frame $nb.prv]
        $nb add $prv -text "  Preview  "
        preview_ed::create $prv

        set phy [ttk::frame $nb.phy]
        $nb add $phy -text "  Physics  "
        physics_ed::create $phy app::_on_physics_changed

        set ctl [ttk::frame $nb.ctl]
        $nb add $ctl -text "  Controls  "
        controls_ed::create $ctl

        set aud [ttk::frame $nb.aud]
        $nb add $aud -text "  Audio  "
        audio_ed::create $aud

        set ast [ttk::frame $nb.ast]
        $nb add $ast -text "  Assets  "
        assets_ed::create $ast

        set rom [ttk::frame $nb.rom]
        $nb add $rom -text "  ROM Settings  "
        save_ed::create $rom
    }
}

proc app::_on_tab_changed {} {
    set nb  $::app_centre_nb
    if {[llength [$nb tabs]] == 0} return
    set tab [$nb tab current -text]
    # Don't flush panel state into the doc until a project is actually loaded —
    # tab changes fire while the notebook is first being populated.
    if {![dict exists [project::current_doc] meta name]} {
        if {[string match "*Preview*" $tab]} { catch { preview_ed::refresh } }
        return
    }
    if {$::app_genre eq "topdown"} {
        catch {
            switch -glob $tab {
                "*Assets*"       { assets_ed::save_to_doc }
                "*ROM Settings*" { save_ed::save_to_doc   }
            }
        }
        return
    }
    catch {
        switch -glob $tab {
            "*Audio*"    { audio_ed::save_to_doc    }
            "*ROM*"      { save_ed::save_to_doc     }
            "*Physics*"  { physics_ed::save_to_doc  }
            "*Controls*" { controls_ed::save_to_doc }
            "*Preview*"  { preview_ed::refresh      }
        }
    }
    catch { _update_title }
}

proc app::_on_level_changed {} {
    preview_ed::refresh
    _update_title
}

proc app::_on_physics_changed {} {
    physics_ed::save_to_doc
    _update_title
}

proc app::_on_object_selected {lvl_idx obj_idx obj} {
    if {$obj eq {}} {
        entity_ed::deselect
    } else {
        entity_ed::select $lvl_idx $obj_idx $obj
    }
}

# ── Right panel (entity inspector) ────────────────────────────────────────────

proc app::_create_right_panel {f} {
    entity_ed::create $f app::_on_entity_changed
}

proc app::_on_entity_changed {} {
    level_ed::refresh
    preview_ed::refresh
    _update_title
}

# ── Status bar ────────────────────────────────────────────────────────────────

proc app::_create_status_bar {} {
    set sb [ttk::frame .statusbar]
    pack $sb -fill x -side bottom

    ttk::separator .sep_sb -orient horizontal
    pack .sep_sb -fill x -side bottom

    set ::app_status_lbl [ttk::label $sb.msg \
        -text "Ready" -style Subtitle.TLabel -anchor w]
    set ::app_status_pos [ttk::label $sb.pos \
        -text "" -style Subtitle.TLabel -width 22 -anchor e]
    set ::app_save_ind [ttk::label $sb.ind \
        -text "●" -foreground #3d4a5e -width 3 -anchor e]

    pack $sb.msg -side left  -padx {10 4} -pady 2
    pack $sb.ind -side right -padx {0 4}  -pady 2
    pack $sb.pos -side right -padx 4      -pady 2
}

proc app::status {msg} {
    catch { $::app_status_lbl configure -text $msg }
    update idletasks
}

proc app::_update_save_indicator {} {
    set dirty [project::is_dirty]
    catch {
        if {$dirty} {
            $::app_save_ind configure -foreground #d4a017 -text "●"
            $::app_proj_indicator configure -text "Unsaved changes"
        } else {
            $::app_save_ind configure -foreground #2da864 -text "●"
            $::app_proj_indicator configure -text "All saved"
        }
    }
}

# ── Menu bar ──────────────────────────────────────────────────────────────────

proc app::_create_menu {} {
    menu .mb
    . configure -menu .mb

    menu .mb.file -tearoff 0
    .mb add cascade -label "File" -menu .mb.file -underline 0
    .mb.file add command -label "New Project..."  -accelerator "Ctrl+N" \
        -command app::cmd_new
    .mb.file add command -label "Open Project..."  -accelerator "Ctrl+O" \
        -command app::cmd_open
    .mb.file add command -label "Save"             -accelerator "Ctrl+S" \
        -command app::cmd_save
    .mb.file add command -label "Save As..."       -accelerator "Ctrl+Shift+S" \
        -command app::cmd_save_as
    .mb.file add separator
    .mb.file add command -label "Exit"             -command app::cmd_exit

    menu .mb.build -tearoff 0
    .mb add cascade -label "Build" -menu .mb.build -underline 0
    .mb.build add command -label "Build ROM"          -accelerator "F5" \
        -command app::cmd_build
    .mb.build add command -label "Run in Emulator"    -accelerator "F6" \
        -command app::cmd_run
    .mb.build add separator
    .mb.build add command -label "Validate (pak check)" \
        -command app::cmd_validate

    menu .mb.help -tearoff 0
    .mb add cascade -label "Help" -menu .mb.help -underline 0
    .mb.help add command -label "Keyboard Shortcuts" \
        -command app::_show_shortcuts
    .mb.help add command -label "About PakStudio" \
        -command app::_show_about

    bind . <Control-n> app::cmd_new
    bind . <Control-o> app::cmd_open
    bind . <Control-s> app::cmd_save
    bind . <Control-S> app::cmd_save_as
    bind . <F5>        app::cmd_build
    bind . <F6>        app::cmd_run
}

# ── Commands ──────────────────────────────────────────────────────────────────

proc app::cmd_new {} {
    if {[project::is_dirty]} {
        set r [tk_messageBox -title "Unsaved Changes" \
            -message "Save current project before creating a new one?" \
            -type yesnocancel -icon question]
        if {$r eq "cancel"} return
        if {$r eq "yes"}    { cmd_save }
    }
    set doc [wizard::show .]
    if {$doc eq {}} return
    _load_doc $doc
}

proc app::cmd_open {} {
    if {[project::is_dirty]} {
        set r [tk_messageBox -title "Unsaved Changes" \
            -message "Save before opening?" -type yesnocancel -icon question]
        if {$r eq "cancel"} return
        if {$r eq "yes"}    { cmd_save }
    }
    set path [tk_getOpenFile -title "Open Project" \
        -filetypes {{"PakStudio Projects" .pakstudio} {"All Files" *}}]
    if {$path eq ""} return
    set doc [project::load_from $path]
    _load_doc $doc
}

proc app::cmd_save {} {
    set path [project::current_path]
    if {$path eq ""} { cmd_save_as; return }
    app::_flush_editors
    project::save_to $path
    status "Saved: $path"
    _update_title
}

proc app::cmd_save_as {} {
    set path [tk_getSaveFile -title "Save Project As" \
        -filetypes {{"PakStudio Projects" .pakstudio} {"All Files" *}} \
        -defaultextension .pakstudio]
    if {$path eq ""} return
    app::_flush_editors
    project::save_to $path
    status "Saved: $path"
    _update_title
}

proc app::cmd_exit {} {
    if {[project::is_dirty]} {
        set r [tk_messageBox -title "Unsaved Changes" \
            -message "Save before exiting?" -type yesnocancel -icon question]
        if {$r eq "cancel"} return
        if {$r eq "yes"}    { cmd_save }
    }
    exit 0
}

proc app::cmd_validate {} {
    variable log_widget
    log_panel::clear $log_widget
    log_panel::append $log_widget "--- Running pak check ---"
    app::_flush_editors
    set doc    [project::current_doc]
    set result [validate::check_doc $doc]
    if {[dict get $result ok]} {
        log_panel::append $log_widget "  PASS: pak check clean"
        status "Validation passed"
    } else {
        log_panel::append $log_widget "ERROR: pak check failed"
        foreach line [split [dict get $result errors] "\n"] {
            if {$line ne ""} { log_panel::append $log_widget "  $line" }
        }
        status "Validation failed — see log"
    }
}

proc app::cmd_build {} {
    variable log_widget
    variable build_running
    variable outdir
    if {$build_running} return

    app::_flush_editors

    if {$outdir eq "" || ![file isdirectory $outdir]} {
        set outdir [tk_chooseDirectory \
            -title "Choose Build Output Directory" -mustexist 0]
        if {$outdir eq ""} return
        file mkdir $outdir
    }

    log_panel::clear $log_widget
    set build_running true
    status "Building..."
    coroutine build_coro app::_run_build [project::current_doc] $outdir \
        [list log_panel::append $log_widget]
}

proc app::_run_build {doc outdir cb} {
    variable build_running
    set result [build::run $doc $outdir $cb]
    set build_running false
    if {[dict get $result ok]} {
        status "Build succeeded"
        if {[dict exists $result rom]} {
            set rom [dict get $result rom]
            log_panel::append $::app::log_widget "ROM: $rom"
            set r [tk_messageBox -title "Build Complete" \
                -message "ROM built: $rom\n\nRun in emulator?" \
                -type yesno -icon info]
            if {$r eq "yes"} { cmd_run }
        }
    } else {
        status "Build FAILED — see log"
    }
}

proc app::cmd_run {} {
    variable outdir
    variable log_widget
    if {$outdir eq "" || ![file isdirectory $outdir]} {
        status "Build first before running"
        return
    }
    log_panel::append $log_widget "--- Launching emulator ---"
    after 0 [list build::run_rom $outdir [list log_panel::append $log_widget]]
}

# ── Internal helpers ──────────────────────────────────────────────────────────

# Flush in-memory editor panel state into the doc before save/build/validate.
proc app::_flush_editors {} {
    if {$::app_genre eq "topdown"} {
        catch { rpg_ed::save_to_doc    }
        catch { assets_ed::save_to_doc }
        catch { save_ed::save_to_doc   }
    } else {
        catch { audio_ed::save_to_doc }
        catch { save_ed::save_to_doc }
        catch { physics_ed::save_to_doc }
        catch { controls_ed::save_to_doc }
    }
}

proc app::_load_doc {doc} {
    set genre [expr {[dict exists $doc meta genre] ? [dict get $doc meta genre] : "platformer"}]
    _populate_centre $genre
    _refresh_level_list
    if {$genre eq "topdown"} {
        rpg_ed::load_doc    $doc
        assets_ed::load_doc $doc
        save_ed::load_doc   $doc
        catch { $::app_level_lb selection clear 0 end }
        _update_left_panel_for_genre $genre
        _update_title
        status "RPG project loaded"
        return
    }
    _update_left_panel_for_genre $genre
    physics_ed::load_doc  $doc
    controls_ed::load_doc $doc
    audio_ed::load_doc    $doc
    save_ed::load_doc     $doc
    assets_ed::load_doc   $doc
    $::app_level_lb selection clear 0 end
    $::app_level_lb selection set 0
    level_ed::load_doc $doc 0
    preview_ed::load_doc $doc 0
    entity_ed::deselect
    _update_title
    status "Project loaded"
}

proc app::_update_title {} {
    set doc [project::current_doc]
    if {![dict exists $doc meta name]} return
    set name  [dict get $doc meta name]
    set path  [project::current_path]
    set dirty [project::is_dirty]
    set mark  [expr {$dirty ? " *" : ""}]
    if {$path ne ""} {
        wm title . "PakStudio — $name$mark  ($path)"
    } else {
        wm title . "PakStudio — $name$mark  \[unsaved\]"
    }
    _update_save_indicator
}

proc app::_show_shortcuts {} {
    set w [toplevel .shortcuts]
    wm title $w "Keyboard Shortcuts"
    wm transient $w .
    wm resizable $w 0 0

    ttk::frame $w.f
    pack $w.f -padx 20 -pady 16

    ttk::label $w.f.t -text "Keyboard Shortcuts" -style Header.TLabel
    pack $w.f.t -pady {0 12}

    set rows {
        "Ctrl+N"  "New project"
        "Ctrl+O"  "Open project"
        "Ctrl+S"  "Save"
        "F5"      "Build ROM"
        "F6"      "Run in emulator"
        ""        ""
        "Q"       "Paint tile"
        "E"       "Eraser"
        "R"       "Place object"
        "S"       "Select object"
        "1"       "Solid tile"
        "2"       "One-way platform"
        "3"       "Hazard tile"
        "+/−"     "Zoom in / out"
        "Drag"    "Pan canvas"
    }
    foreach {k l} $rows {
        if {$k eq ""} {
            ttk::separator $w.f.s[incr ::_sc_n] -orient horizontal
            pack $w.f.s$::_sc_n -fill x -pady 4
        } else {
            set rf [ttk::frame $w.f.r$k]
            ttk::label $rf.k -text $k -foreground #6aadff \
                -font {TkDefaultFont 9 bold} -width 10 -anchor e
            ttk::label $rf.l -text $l -style Subtitle.TLabel -anchor w
            pack $rf.k $rf.l -side left -padx {0 8}
            pack $rf -fill x -pady 1
        }
    }
    ttk::button $w.f.ok -text "Close" -command [list destroy $w] -style Accent.TButton
    pack $w.f.ok -pady {12 0}
}

proc app::_show_about {} {
    set w [toplevel .about]
    wm title $w "About PakStudio"
    wm transient $w .
    wm resizable $w 0 0

    ttk::frame $w.f
    pack $w.f -padx 32 -pady 24

    ttk::label $w.f.logo -text "PakStudio" \
        -font {TkDefaultFont 20 bold} -foreground #6aadff
    ttk::label $w.f.sub  -text "Zero-Code N64 Game Development Suite" \
        -style Subtitle.TLabel
    ttk::separator $w.f.sep -orient horizontal
    ttk::label $w.f.body -text \
        "Built on the Pak language and libdragon.\n\n2D Platformers: fully functional\nTop-Down / FPS / Racer: coming soon" \
        -justify center -style Subtitle.TLabel
    ttk::button $w.f.ok -text "Close" -command [list destroy $w] -style Accent.TButton

    foreach widget {logo sub sep body ok} {
        pack $w.f.$widget -pady {0 8}
    }
}

# ── Launch ────────────────────────────────────────────────────────────────────

app::create_main_window

if {$argc == 0} {
    after 200 {
        set doc [wizard::show .]
        if {$doc ne {}} {
            app::_load_doc $doc
        } else {
            project::new platformer "My Platformer"
            app::_load_doc [project::current_doc]
        }
    }
} else {
    set fpath [lindex $argv 0]
    if {[file exists $fpath]} {
        set doc [project::load_from $fpath]
        app::_load_doc $doc
    }
}
