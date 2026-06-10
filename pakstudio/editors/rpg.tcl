# editors/rpg.tcl — umbrella for the top-down RPG authoring suite.
# Builds the RPG editor tabs into a notebook and routes load/save across them.
# The Events editor is the sole writer of the `levels` list (it owns map events),
# so no other RPG editor touches levels — avoiding clobbered write-backs.

namespace eval rpg_ed {}

proc rpg_ed::create_tabs {nb} {
    set defs {
        ev    "  Events  "    rpg_ev
        db    "  Database  "  rpg_db
        quest "  Quests  "    rpg_quests
        craft "  Crafting  "  rpg_craft
        dlg   "  Dialogue  "  rpg_dialogue
        world "  World  "     rpg_world
    }
    foreach {key title ns} $defs {
        set p [ttk::frame $nb.rpg_$key]
        $nb add $p -text $title
        ${ns}::create $p
    }
}

proc rpg_ed::load_doc {doc} {
    rpg_ev::load_doc       $doc
    rpg_db::load_doc       $doc
    rpg_quests::load_doc   $doc
    rpg_craft::load_doc    $doc
    rpg_dialogue::load_doc $doc
    rpg_world::load_doc    $doc
}

proc rpg_ed::save_to_doc {} {
    rpg_db::save_to_doc
    rpg_quests::save_to_doc
    rpg_craft::save_to_doc
    rpg_dialogue::save_to_doc
    rpg_world::save_to_doc
    # Events last: it writes the whole `levels` list.
    rpg_ev::save_to_doc
}
