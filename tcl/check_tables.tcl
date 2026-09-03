# tcl/check_tables.tcl — lookup tables for the semantic checker: known
# modules and their functions, builtin arities, and recognized @cfg features.
# Module *existence* is MODULE_API in tcl/module_api.tcl (CG_API ∪ CG_API_LAMBDA).
# API_ARITY is the subset with a checked argument count (E105). Unknown methods
# are E010, never silently lowered.
namespace eval pak {}
# Include guard (reachable via multiple consumers; see ast.tcl).
if {[info exists ::pak::_check_tables_loaded]} { return }
set ::pak::_check_tables_loaded 1

set ::pak::KNOWN_MODULES [dict create \
    arena 1 \
    audio 1 \
    backup 1 \
    cache 1 \
    controller 1 \
    cpak 1 \
    debug 1 \
    disk 1 \
    display 1 \
    dma 1 \
    eeprom 1 \
    exception 1 \
    flashram 1 \
    joypad 1 \
    math 1 \
    mem 1 \
    mixer 1 \
    mouse 1 \
    rdpq 1 \
    rdpq_font 1 \
    rdpq_mode 1 \
    rdpq_tex 1 \
    rsp 1 \
    rtc 1 \
    rumble 1 \
    sprite 1 \
    sram 1 \
    std 1 \
    str 1 \
    surface 1 \
    system 1 \
    t3d 1 \
    timer 1 \
    tpak 1 \
    vi 1 \
    vru 1 \
    wav64 1 \
    xm64 1 \
]

set ::pak::API_ARITY [dict create \
    {audio can_write} {0 0} \
    {audio close} {0 0} \
    {audio get_buffer} {0 0} \
    {audio get_frequency} {0 0} \
    {audio init} {2 2} \
    {audio set_buffer_num} {1 1} \
    {audio write} {1 1} \
    {audio write_silence} {0 0} \
    {cache invalidate} {2 2} \
    {cache writeback} {2 2} \
    {cache writeback_inv} {2 2} \
    {controller init} {0 0} \
    {controller poll} {0 0} \
    {controller read} {1 1} \
    {debug assert} {1 2} \
    {debug log} {1 } \
    {debug log_value} {2 2} \
    {display close} {0 0} \
    {display get} {0 0} \
    {display init} {5 5} \
    {display show} {1 1} \
    {dma read} {3 3} \
    {dma wait} {0 0} \
    {dma write} {3 3} \
    {exception get_handler} {0 0} \
    {exception set_handler} {1 1} \
    {rdpq attach} {2 2} \
    {rdpq attach_clear} {2 2} \
    {rdpq close} {0 0} \
    {rdpq detach} {0 0} \
    {rdpq detach_show} {0 0} \
    {rdpq fill_rectangle} {4 4} \
    {rdpq init} {0 0} \
    {rdpq clear_z} {0 0} \
    {rdpq set_mode_standard_z} {0 0} \
    {rdpq set_scissor} {4 4} \
    {rdpq set_tile} {6 6} \
    {rdpq set_tile_mask} {10 10} \
    {rdpq set_texture_image} {4 4} \
    {rdpq triangle} {6 6} \
    {rdpq triangle_shade} {9 9} \
    {rdpq triangle_shade_z} {12 12} \
    {rdpq triangle_tex} {13 13} \
    {rdpq sync_full} {0 0} \
    {rdpq sync_pipe} {0 0} \
    {sprite blit} {3 3} \
    {sprite load} {1 1} \
    {t3d destroy} {0 0} \
    {t3d frame_end} {1 1} \
    {t3d frame_start} {0 0} \
    {t3d init} {0 0} \
    {t3d mat4_identity} {1 1} \
    {t3d model_draw} {1 1} \
    {t3d model_free} {1 1} \
    {t3d model_load} {1 1} \
    {timer delta} {0 0} \
    {timer get_ticks} {0 0} \
    {timer init} {0 0} \
]

set ::pak::KNOWN_CFG [dict create \
    c_backend 1 \
    debug 1 \
    mips 1 \
    mips_backend 1 \
    n64 1 \
    release 1 \
    tiny3d 1 \
]
