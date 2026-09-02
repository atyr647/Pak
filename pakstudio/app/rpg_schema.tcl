# app/rpg_schema.tcl — Top-down RPG data model + sample project.
#
# The "gold standard" RPG-maker schema. Every authoring editor (events,
# database, quests, crafting, dialogue, switches/variables, shops) reads and
# writes the structures defined here. The runtime codegen (codegen/topdown.tcl)
# consumes the same doc. This file owns ONLY data + defaults — no GUI.
#
# Top-level RPG keys layered onto the doc by project::new for the topdown genre:
#
#   rpg        { combat_default, gold_start, start{map x y facing}, party[] }
#   database   { actors[] items[] skills[] enemies[] troops[] classes[] }
#   recipes    [ {id name station inputs[{item qty}] output{item qty}} ]
#   quests     [ {id name desc giver stages[{id desc kind target count}] reward{}} ]
#   dialogues  [ {id name nodes[{id speaker text choices[{label goto set}]}]} ]
#   switches   [ {id name init} ]
#   variables  [ {id name init} ]
#   shops      [ {id name kind items[item_id]} ]
#
# Maps (the genre-shared `levels` list) gain RPG fields:
#   combat_mode (none|action|turn), encounter_rate, troops[], events[]
# where each event = { id name x y trigger graphic pages[{conditions commands}] }
# and each command is a dict { op ... } (see rpg::command_ops for the vocabulary).

namespace eval rpg {}

# ── Event-command vocabulary ────────────────────────────────────────────────
# Ordered list of {op label} pairs the Event editor offers. The runtime
# interpreter in codegen/topdown.tcl switches on `op`.
proc rpg::command_ops {} {
    return {
        text          "Show Text"
        choice        "Show Choices"
        switch        "Set Switch"
        var           "Set Variable"
        if            "Conditional Branch"
        give_item     "Give Item"
        take_item     "Remove Item"
        gold          "Change Gold"
        give_skill    "Teach Skill"
        quest_start   "Start Quest"
        quest_advance "Advance Quest"
        quest_done    "Complete Quest"
        teleport      "Teleport"
        shop          "Open Shop"
        craft         "Open Crafting"
        battle        "Start Battle"
        heal          "Heal Party"
        recruit       "Add Party Member"
        sfx           "Play Sound"
        music         "Play Music"
        wait          "Wait"
        move_npc      "Move This Event"
        set_graphic   "Change Graphic"
        comment       "Comment"
    }
}

proc rpg::command_label {op} {
    foreach {o l} [command_ops] { if {$o eq $op} { return $l } }
    return $op
}

# Event trigger kinds.
proc rpg::trigger_kinds {} {
    return {action "Action Button" touch "Player Touch" auto "Autorun" parallel "Parallel"}
}

# Event movement kinds (NPC wander behaviour).
proc rpg::move_kinds {} {
    return {fixed "Stand Still" random "Random Walk" approach "Approach Player" route "Fixed Route"}
}

# Conditional-branch comparison kinds (for the `if` command and event-page gating).
proc rpg::cond_kinds {} {
    return {
        switch_on  "Switch is ON"
        switch_off "Switch is OFF"
        var_ge     "Variable >="
        var_eq     "Variable =="
        has_item   "Has Item"
        quest_at   "Quest at Stage"
        gold_ge    "Gold >="
    }
}

# ── Database defaults ───────────────────────────────────────────────────────

proc rpg::default_actors {} {
    return [list \
        [dict create id hero name "Aria"  klass "Knight" sprite "" \
            level 1 hp 32 mp 12 atk 9 def 7 mag 4 spd 6 \
            weapon bronze_sword armor leather_armor \
            skills {slash} desc "A young knight from Riverdale."] \
        [dict create id mage name "Loras" klass "Mage" sprite "" \
            level 1 hp 22 mp 24 atk 4 def 4 mag 11 spd 7 \
            weapon "" armor "" \
            skills {fireball heal} desc "A travelling scholar of the arcane."] \
    ]
}

proc rpg::default_items {} {
    return [list \
        [dict create id potion        name "Potion"        kind consumable price 25  effect heal_hp power 30  target ally   desc "Restores 30 HP."          icon ""] \
        [dict create id ether         name "Ether"         kind consumable price 60  effect heal_mp power 20  target ally   desc "Restores 20 MP."          icon ""] \
        [dict create id herb          name "Herb"          kind material   price 5   effect none    power 0   target none   desc "A common healing herb."   icon ""] \
        [dict create id iron_ore      name "Iron Ore"      kind material   price 12  effect none    power 0   target none   desc "Raw ore for the forge."   icon ""] \
        [dict create id bronze_sword  name "Bronze Sword"  kind weapon     price 80  effect atk     power 4   target none   desc "A sturdy starter blade."  icon ""] \
        [dict create id iron_sword    name "Iron Sword"    kind weapon     price 200 effect atk     power 9   target none   desc "Forged from iron ore."    icon ""] \
        [dict create id leather_armor name "Leather Armor" kind armor      price 70  effect def     power 3   target none   desc "Light, flexible guard."   icon ""] \
        [dict create id town_key      name "Town Key"      kind key        price 0   effect none    power 0   target none   desc "Opens the village gate."  icon ""] \
    ]
}

proc rpg::default_skills {} {
    return [list \
        [dict create id slash    name "Slash"     mp 0  power 12 element none  target one_enemy  desc "A basic sword strike."] \
        [dict create id fireball name "Fireball"  mp 6  power 22 element fire  target one_enemy  desc "Hurls a ball of flame."] \
        [dict create id heal     name "Heal"      mp 5  power 28 element light target one_ally   desc "Restores an ally's HP."] \
        [dict create id guard    name "Guard"     mp 0  power 0  element none  target self       desc "Halve damage this turn."] \
    ]
}

proc rpg::default_enemies {} {
    return [list \
        [dict create id slime  name "Slime"  sprite "" hp 14 mp 0  atk 5  def 2 spd 3 exp 6  gold 8  ai chase  touch 3 skills {}        desc "A wobbling blob."] \
        [dict create id goblin name "Goblin" sprite "" hp 26 mp 0  atk 9  def 4 spd 6 exp 14 gold 20 ai chase  touch 5 skills {}        desc "A sneaky woodland raider."] \
        [dict create id bat    name "Bat"    sprite "" hp 10 mp 0  atk 6  def 1 spd 9 exp 5  gold 4  ai erratic touch 2 skills {}        desc "Flits erratically."] \
        [dict create id warden name "Forest Warden" sprite "" hp 120 mp 30 atk 16 def 9 spd 7 exp 200 gold 300 ai boss touch 8 skills {fireball} desc "Guardian of the woods."] \
    ]
}

# Turn-based encounter groups (a "troop" = enemies arranged for one battle).
proc rpg::default_troops {} {
    return [list \
        [dict create id slimes  name "Slime Pair"     members {slime slime}        bgm "battle"] \
        [dict create id ambush  name "Goblin Ambush"  members {goblin goblin bat}  bgm "battle"] \
        [dict create id boss    name "Forest Warden"  members {warden}             bgm "boss"] \
    ]
}

# ── Crafting recipes ────────────────────────────────────────────────────────
proc rpg::default_recipes {} {
    return [list \
        [dict create id r_potion name "Brew Potion" station alchemy \
            inputs {{item herb qty 2}} output {item potion qty 1}] \
        [dict create id r_iron   name "Forge Iron Sword" station forge \
            inputs {{item iron_ore qty 3} {item bronze_sword qty 1}} \
            output {item iron_sword qty 1}] \
    ]
}

# ── Quests ──────────────────────────────────────────────────────────────────
proc rpg::default_quests {} {
    return [list \
        [dict create id q_heirloom name "The Missing Heirloom" giver elder \
            desc "Elder Mira lost her family heirloom in the Whispering Woods." \
            stages [list \
                [dict create id s1 desc "Speak with Elder Mira"        kind talk    target elder      count 1] \
                [dict create id s2 desc "Find the heirloom in the woods" kind collect target heirloom count 1] \
                [dict create id s3 desc "Return the heirloom to Mira"   kind talk    target elder      count 1] \
            ] \
            reward [dict create gold 150 item iron_sword exp 50]] \
        [dict create id q_slimes name "Slime Cleanup" giver shopkeep \
            desc "The shopkeeper wants the slimes near the well cleared out." \
            stages [list \
                [dict create id s1 desc "Defeat 5 slimes" kind defeat target slime count 5] \
            ] \
            reward [dict create gold 60 item potion exp 30]] \
    ]
}

# ── Dialogue trees ──────────────────────────────────────────────────────────
proc rpg::default_dialogues {} {
    return [list \
        [dict create id d_elder name "Elder Mira" nodes [list \
            [dict create id n0 speaker "Elder Mira" \
                text "Oh, traveller! My family's heirloom is lost in the woods. Will you help?" \
                choices [list \
                    [dict create label "I'll find it." goto n1 set q_heirloom] \
                    [dict create label "Not now."      goto end set ""] \
                ]] \
            [dict create id n1 speaker "Elder Mira" \
                text "Bless you. It fell near the old oak, beyond the river." \
                choices {}] \
        ]] \
        [dict create id d_shop name "Shopkeeper" nodes [list \
            [dict create id n0 speaker "Bram" \
                text "Welcome to the General Store! Care to browse?" \
                choices [list \
                    [dict create label "Show me your wares." goto shop set ""] \
                    [dict create label "Just looking."       goto end  set ""] \
                ]] \
        ]] \
    ]
}

# ── Switches & variables ────────────────────────────────────────────────────
proc rpg::default_switches {} {
    return [list \
        [dict create id intro_done     name "Intro Complete"   init 0] \
        [dict create id met_elder      name "Met the Elder"    init 0] \
        [dict create id heirloom_found name "Heirloom Found"   init 0] \
        [dict create id woods_open     name "Woods Unlocked"   init 0] \
    ]
}

proc rpg::default_variables {} {
    return [list \
        [dict create id slimes_slain name "Slimes Slain"  init 0] \
        [dict create id reputation   name "Reputation"    init 0] \
    ]
}

# ── Shops ───────────────────────────────────────────────────────────────────
proc rpg::default_shops {} {
    return [list \
        [dict create id general name "General Store" kind buy_sell \
            items {potion ether herb bronze_sword leather_armor}] \
    ]
}

# ── rpg root block ──────────────────────────────────────────────────────────
proc rpg::default_root {} {
    return [dict create \
        combat_default action \
        gold_start 50 \
        party {hero} \
        start [dict create map 0 x 8 y 9 facing down] \
    ]
}

# Assemble every RPG-specific top-level fragment (merged into the doc).
proc rpg::default_db {} {
    return [dict create \
        actors  [default_actors] \
        items   [default_items] \
        skills  [default_skills] \
        enemies [default_enemies] \
        troops  [default_troops] \
        classes {} \
    ]
}

# ── Sample maps ─────────────────────────────────────────────────────────────
# A map is the genre-shared level dict + RPG fields. Two starter maps: a
# peaceful village (no combat) and the woods (action combat), wired together
# with a teleport event and populated with quest-giver / shop / chest / craft
# bench / sign events so a new project is a complete, playable loop.

proc rpg::_blank_layer {w h fill} { return [lrepeat [expr {$w*$h}] $fill] }

proc rpg::sample_maps {} {
    set vw 20; set vh 15
    set ground [_blank_layer $vw $vh 1]   ;# grass
    # carve a dirt plaza + a pond
    for {set y 6} {$y < 10} {incr y} {
        for {set x 7} {$x < 13} {incr x} { lset ground [expr {$y*$vw+$x}] 2 }
    }
    lset ground [expr {3*$vw+15}] 5
    lset ground [expr {3*$vw+16}] 5
    set village [dict create \
        id 0 name "Riverdale Village" width $vw height $vh tileset 0 \
        bg_color "0x1B3A24FF" music "town" \
        combat_mode none encounter_rate 0 troops {} \
        layer_ground $ground \
        layer_deco   [_blank_layer $vw $vh 0] \
        layer_coll   [_blank_layer $vw $vh 0] \
        tiles        $ground \
        objects {} \
        events [list \
            [dict create id ev_elder name "Elder Mira" x 5 y 5 trigger action \
                graphic npc_elder move fixed pages [list \
                    [dict create conditions {} commands [list \
                        [dict create op text speaker "Elder Mira" text "The woods grow restless, traveller."] \
                        [dict create op quest_start quest q_heirloom] \
                        [dict create op switch id met_elder value 1] \
                    ]] \
                ]] \
            [dict create id ev_shop name "Shopkeeper Bram" x 14 y 7 trigger action \
                graphic npc_shop move fixed pages [list \
                    [dict create conditions {} commands [list \
                        [dict create op text speaker "Bram" text "Welcome! Take a look."] \
                        [dict create op shop shop general] \
                    ]] \
                ]] \
            [dict create id ev_bench name "Crafting Bench" x 10 y 11 trigger action \
                graphic prop_bench move fixed pages [list \
                    [dict create conditions {} commands [list \
                        [dict create op craft station forge] \
                    ]] \
                ]] \
            [dict create id ev_chest name "Chest" x 3 y 12 trigger action \
                graphic prop_chest move fixed pages [list \
                    [dict create conditions {{kind switch_off target intro_done}} commands [list \
                        [dict create op text speaker "" text "You found 30 gold and a Potion!"] \
                        [dict create op gold amount 30] \
                        [dict create op give_item item potion qty 1] \
                        [dict create op switch id intro_done value 1] \
                    ]] \
                    [dict create conditions {{kind switch_on target intro_done}} commands [list \
                        [dict create op text speaker "" text "The chest is empty."] \
                    ]] \
                ]] \
            [dict create id ev_gate name "Woods Gate" x 18 y 8 trigger touch \
                graphic none move fixed pages [list \
                    [dict create conditions {} commands [list \
                        [dict create op teleport map 1 x 2 y 8 facing right] \
                    ]] \
                ]] \
        ] \
    ]

    set ww 24; set wh 16
    set wground [_blank_layer $ww $wh 1]
    for {set y 0} {$y < $wh} {incr y} {
        lset wground [expr {$y*$ww+11}] 6   ;# a river running down
        lset wground [expr {$y*$ww+12}] 6
    }
    set woods [dict create \
        id 1 name "Whispering Woods" width $ww height $wh tileset 0 \
        bg_color "0x0C2416FF" music "field" \
        combat_mode action encounter_rate 30 troops {slimes ambush} \
        layer_ground $wground \
        layer_deco   [_blank_layer $ww $wh 0] \
        layer_coll   [_blank_layer $ww $wh 0] \
        tiles        $wground \
        objects {} \
        events [list \
            [dict create id ev_back name "Village Path" x 1 y 8 trigger touch \
                graphic none move fixed pages [list \
                    [dict create conditions {} commands [list \
                        [dict create op teleport map 0 x 17 y 8 facing left] \
                    ]] \
                ]] \
            [dict create id ev_slime1 name "Slime" x 7 y 5 trigger touch \
                graphic enemy_slime move random pages [list \
                    [dict create conditions {} commands [list \
                        [dict create op battle troop slimes] \
                    ]] \
                ]] \
            [dict create id ev_goblin name "Goblin Camp" x 16 y 11 trigger touch \
                graphic enemy_goblin move approach pages [list \
                    [dict create conditions {} commands [list \
                        [dict create op battle troop ambush] \
                    ]] \
                ]] \
            [dict create id ev_heirloom name "Glinting Object" x 20 y 3 trigger action \
                graphic prop_sparkle move fixed pages [list \
                    [dict create conditions {{kind switch_off target heirloom_found}} commands [list \
                        [dict create op text speaker "" text "A silver locket — the elder's heirloom!"] \
                        [dict create op give_item item town_key qty 1] \
                        [dict create op quest_advance quest q_heirloom stage s2] \
                        [dict create op switch id heirloom_found value 1] \
                    ]] \
                ]] \
            [dict create id ev_warden name "Forest Warden" x 21 y 13 trigger action \
                graphic enemy_warden move fixed pages [list \
                    [dict create conditions {{kind switch_on target heirloom_found}} commands [list \
                        [dict create op text speaker "Forest Warden" text "You dare take what is ours?"] \
                        [dict create op battle troop boss] \
                    ]] \
                ]] \
        ] \
    ]
    return [list $village $woods]
}

# ── RPG tileset (terrain palette for top-down maps) ──────────────────────────
proc rpg::default_tileset {} {
    return [dict create \
        id 0 file "" tile_size 16 \
        types [dict create 0 empty 1 grass 2 dirt 3 wall 4 floor 5 water 6 river 7 tree 8 bridge] \
        colors [dict create \
            1 "#3C7A3C" 2 "#9A7B4F" 3 "#5A5A66" 4 "#C8BCA0" \
            5 "#2E6FA8" 6 "#2E6FA8" 7 "#1E5A2A" 8 "#A07845"] \
    ]
}

# True when the doc is an RPG project carrying the RPG schema.
proc rpg::is_rpg {doc} {
    return [expr {[dict exists $doc meta genre] && [dict get $doc meta genre] eq "topdown"}]
}

# Layer the full RPG schema onto a freshly-created topdown doc.
proc rpg::install {docVar} {
    upvar 1 $docVar doc
    dict set doc rpg       [default_root]
    dict set doc database  [default_db]
    dict set doc recipes   [default_recipes]
    dict set doc quests    [default_quests]
    dict set doc dialogues [default_dialogues]
    dict set doc switches  [default_switches]
    dict set doc variables [default_variables]
    dict set doc shops     [default_shops]
    dict set doc tilesets  [list [default_tileset]]
    dict set doc levels    [sample_maps]
}

# Forward-migrate an older topdown doc that predates a schema field.
proc rpg::migrate {docVar} {
    upvar 1 $docVar doc
    if {![rpg::is_rpg $doc]} return
    if {![dict exists $doc rpg]}       { dict set doc rpg       [default_root] }
    if {![dict exists $doc database]}  { dict set doc database  [default_db] }
    if {![dict exists $doc recipes]}   { dict set doc recipes   [default_recipes] }
    if {![dict exists $doc dialogues]} { dict set doc dialogues [default_dialogues] }
    if {![dict exists $doc switches]}  { dict set doc switches  [default_switches] }
    if {![dict exists $doc variables]} { dict set doc variables [default_variables] }
    if {![dict exists $doc shops]}     { dict set doc shops     [default_shops] }
}
