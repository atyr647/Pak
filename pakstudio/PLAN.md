# PakStudio — Implementation Roadmap

## Vision
Tcl/Tk IDE: non-programmer clicks through visual editors → PakStudio generates `.pk64`
+ `pak.toml` → `pak build` → `.z64`. No code ever shown to the user.

## Source of truth: `.pakstudio` file
Plain Tcl dict, versioned, all project data. Never expose `.pk64` to the user.

## Phase status
- [x] Phase 0 — Foundation (data model, codegen, build pipeline, tests)
- [ ] Phase 1 — 2D Platformer (wizard, tile/level editor, entity inspector, physics, audio, save)
- [ ] Phase 2 — Genre library (top-down RPG, shmup, puzzle, top-down racer, beat-em-up)
- [ ] Phase 3 — Advanced (dialogue graph, quest DAG, cutscene sequencer, boss designer)
- [ ] Phase 4 — 3D (after T3D installed: terrain sculpt, model placement, 3D wizards)

## File layout

```
pakstudio/
  main.tcl              entry point, window, menu, toolbar
  PLAN.md               this file
  app/
    project.tcl         .pakstudio load/save/new/dirty state
    codegen.tcl         genre dispatcher → .pk64 + pak.toml
    build.tcl           shell-out: pak build, make, pak run
    validate.tcl        in-process pak check on generated code
  codegen/
    platformer.tcl      platformer-specific template generator
    topdown.tcl         (Phase 2)
    shmup.tcl           (Phase 2)
  editors/
    wizard.tcl          new project multi-step dialog
    level.tcl           scrollable tile canvas + object placement
    entity.tcl          entity inspector (properties per object type)
    physics.tcl         physics/feel sliders panel
    audio.tcl           audio event assignment panel
    save_editor.tcl     save config + EEPROM layout panel
  widgets/
    canvas_scroll.tcl   scrollable/zoomable canvas with grid
    prop_panel.tcl      label+widget property inspector rows
    log_panel.tcl       streaming build log, ANSI-stripped
  tests/
    test_project.tcl    round-trip save/load, schema validation
    test_codegen.tcl    dict-in → pak check passes
```

## Generated file structure (platformer)
```
<project>/
  pak.toml
  src/
    main.pk64           entry, game loop, phase dispatch, rendering
  assets/
    sprites/            tilesets, player sprite sheet
    audio/              music and sfx clips
```

## Codegen contract
`codegen::generate doc` → dict mapping relative path → file content string.
No side effects. All file writes done by caller.

## Key constraints
- T3D not installed → no 3D genres in Phase 1/2
- Pak: no &&/||/!, use and/or/not. All casts explicit. No if-expressions. entry{} not main.
- RDP: set_mode_fill once per frame to enter fill mode; set_fill_color to change color
- Generated code auto-validated with pak check after every significant edit
