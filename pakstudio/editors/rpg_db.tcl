# editors/rpg_db.tcl — RPG Database editor (actors, items, skills, enemies, troops).
# A notebook of master-detail record editors backed by rdb. Reads/writes
# doc.database.{actors,items,skills,enemies,troops}.

namespace eval rpg_db {}

proc rpg_db::create {parent} {
    set f [ttk::frame $parent.rpgdb]
    pack $f -fill both -expand 1

    set nb [ttk::notebook $f.nb]
    pack $nb -fill both -expand 1 -padx 2 -pady 2

    foreach {key title} {actors Actors items Items skills Skills enemies Enemies troops Troops} {
        set p [ttk::frame $nb.$key]
        $nb add $p -text "  $title  "
        rdb::make db_$key $p [_fields $key] -addlabel $title -onchange rpg_db::_dirty
    }
    set ::rpg_db_nb $nb
    return $f
}

proc rpg_db::_dirty {} { catch { project::mark_dirty; app::_update_save_indicator } }

proc rpg_db::_fields {key} {
    switch $key {
        actors {
            return {
                {id    "ID"        str}
                {name  "Name"      str}
                {klass "Class"     str}
                {level "Level"     int {1 99}}
                {hp    "Max HP"    int {1 9999}}
                {mp    "Max MP"    int {0 9999}}
                {atk   "Attack"    int {0 999}}
                {def   "Defense"   int {0 999}}
                {mag   "Magic"     int {0 999}}
                {spd   "Speed"     int {0 999}}
                {weapon "Weapon ID" str}
                {armor  "Armor ID"  str}
                {skills "Skills"   ids "space-separated skill ids"}
                {sprite "Sprite"   str}
                {desc  "Bio"       multi}
            }
        }
        items {
            return {
                {id     "ID"      str}
                {name   "Name"    str}
                {kind   "Kind"    combo {consumable weapon armor material key}}
                {price  "Price"   int {0 99999}}
                {effect "Effect"  combo {none heal_hp heal_mp atk def revive}}
                {power  "Power"   int {0 9999}}
                {target "Target"  combo {none ally all_allies one_enemy}}
                {icon   "Icon"    str}
                {desc   "Description" multi}
            }
        }
        skills {
            return {
                {id      "ID"      str}
                {name    "Name"    str}
                {mp      "MP Cost" int {0 999}}
                {power   "Power"   int {0 9999}}
                {element "Element" combo {none fire ice bolt light dark}}
                {target  "Target"  combo {one_enemy all_enemies one_ally all_allies self}}
                {desc    "Description" multi}
            }
        }
        enemies {
            return {
                {id     "ID"      str}
                {name   "Name"    str}
                {hp     "Max HP"  int {1 99999}}
                {mp     "Max MP"  int {0 9999}}
                {atk    "Attack"  int {0 999}}
                {def    "Defense" int {0 999}}
                {spd    "Speed"   int {0 999}}
                {exp    "EXP"     int {0 99999}}
                {gold   "Gold"    int {0 99999}}
                {ai     "AI"      combo {chase erratic ranged boss static}}
                {touch  "Touch Dmg" int {0 999}}
                {skills "Skills"  ids "space-separated skill ids"}
                {sprite "Sprite"  str}
                {desc   "Notes"   multi}
            }
        }
        troops {
            return {
                {id      "ID"      str}
                {name    "Name"    str}
                {members "Members" ids "space-separated enemy ids (the battle lineup)"}
                {bgm     "Battle BGM" str}
            }
        }
    }
}

proc rpg_db::load_doc {doc} {
    if {![rpg::is_rpg $doc]} return
    foreach key {actors items skills enemies troops} {
        set recs [expr {[dict exists $doc database $key] ? [dict get $doc database $key] : {}}]
        rdb::set_records db_$key $recs
    }
}

proc rpg_db::save_to_doc {} {
    if {![rpg::is_rpg [project::current_doc]]} return
    foreach key {actors items skills enemies troops} {
        project::set_field database $key [rdb::get_records db_$key]
    }
}
