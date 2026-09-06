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
    interrupt 1 \
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
    sp 1 \
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
    {rdpq load_tile} {5 5} \
    {rdpq load_block} {5 5} \
    {rdpq load_tlut} {3 3} \
    {rdpq texture_rectangle} {7 7} \
    {rdpq texture_rectangle_flip} {7 7} \
    {rdpq texture_rectangle_scaled} {9 9} \
    {rdpq set_prim_depth} {2 2} \
    {rdpq set_key_r} {3 3} \
    {rdpq set_key_gb} {6 6} \
    {rdpq set_convert} {6 6} \
    {rdpq triangle} {6 6} \
    {rdpq triangle_z} {9 9} \
    {rdpq triangle_shade} {9 9} \
    {rdpq triangle_shade_z} {12 12} \
    {rdpq triangle_tex} {13 13} \
    {rdpq triangle_tex_z} {13 13} \
    {rdpq triangle_shade_tex} {16 16} \
    {rdpq triangle_shade_tex_z} {16 16} \
    {rdpq set_tri_z} {3 3} \
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

# Unprefixed global names libdragon's public headers already define, all of
# them deprecated compatibility shims for a prefixed replacement. A Pak `fn`
# with one of these names generates C that collides with libdragon and fails
# to compile -- with an error pointing into libdragon's headers, not at the
# user's line. W004 says it in Pak terms instead. Sourced from the
# `deprecated(...)` declarations in the libdragon revision that
# tools/fetch_libdragon.sh pins.
set ::pak::LIBDRAGON_RESERVED [dict create \
    audio_write 1  controller_init 1  controller_read 1  controller_read_gc 1 \
    controller_read_gc_origin 1  controller_scan 1  execute_raw_command 1 \
    init_interrupts 1  load_data 1  load_ucode 1  rdp_close 1  rdp_detach 1 \
    rdp_draw_filled_rectangle 1  rdp_enable_primitive_fill 1 \
    rdp_enable_texture_copy 1  rdp_init 1  rdp_set_clipping 1 \
    rdp_set_default_clipping 1  rdp_sync 1  read_data 1  read_ucode 1 \
    register_reset_handler 1  rspq_signal 1  rumble_start 1  rumble_stop 1 \
    run_ucode 1 \
]

# C standard library names newlib declares, which libdragon.h pulls in. A Pak
# `fn` with one of these names generates a C function that collides.
#
# This bites specifically on the TARGET: mips64-elf has a 32-bit long, so
# Pak's `i32` is `long` there and `int` on a 64-bit host. `fn abs(x: i32)`
# therefore matched C's `abs(int)` exactly when compiled for the host and
# conflicted when cross-compiled -- 07_control_flow did exactly this, and only
# the real toolchain saw it.
#
# Computed by compiling a conflicting redeclaration of each candidate against
# newlib + libdragon; see tools/build_n64_toolchain.sh for the toolchain.
set ::pak::LIBC_RESERVED [dict create \
    abort 1  abs 1  atan 1  atan2 1  atexit 1  atof 1  atoi 1  atol 1 \
    bsearch 1  calloc 1  ceil 1  cos 1  div 1  exit 1  exp 1  fabs 1 \
    fclose 1  floor 1  fmod 1  fopen 1  fread 1  free 1  fwrite 1 \
    getchar 1  getenv 1  index 1  ldiv 1  log 1  malloc 1  memcmp 1 \
    memcpy 1  memmove 1  memset 1  pow 1  printf 1  putchar 1  puts 1 \
    qsort 1  rand 1  realloc 1  remove 1  rename 1  round 1  sin 1 \
    snprintf 1  sprintf 1  sqrt 1  srand 1  strcat 1  strchr 1  strcmp 1 \
    strcpy 1  strlen 1  strncmp 1  strncpy 1  strstr 1  system 1  tan 1 \
]
