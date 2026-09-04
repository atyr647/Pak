# tcl/module_api.tcl — one HAL contract, two backends.
#
# MODULE_API is the union of CG_API (direct C lowering) and CG_API_LAMBDA
# (inline/lambda lowering). That dict is the source of truth for "does this
# function exist?": the checker, STDLIB generator, and both codegens derive
# from it. A name not in MODULE_API is E010, never silently lowered.
#
# MIPS_HAL_SYMBOLS is the set of C symbols actually defined as `fn` in
# runtime/standalone/runtime.pk64. `pak check --backend mips` rejects any
# MODULE_API call whose symbol is not in that set — those are externs that
# used to fail at link (or not at all).
#
# Do not hand-edit STDLIB.md's generated index; run
#   tclsh tcl/tools/gen_stdlib.tcl
# and keep the rest of the document (builtins, idioms) as prose.

set _modapi_here [file dirname [file normalize [info script]]]
source [file join $_modapi_here cg_tables.tcl]
source [file join $_modapi_here check_tables.tcl]
source [file join $_modapi_here mips_tables.tcl]

namespace eval pak {}
if {[info exists ::pak::_module_api_loaded]} { return }
set ::pak::_module_api_loaded 1

# ── MODULE_API: {mod fn} -> {symbol backends...} ─────────────────────────────

proc pak::module_api_has {mod fn} {
    set key [list $mod $fn]
    expr {[dict exists $::pak::CG_API $key] \
        || [dict exists $::pak::CG_API_LAMBDA $key] \
        || [dict exists $::pak::API_ARITY $key] \
        || [dict exists $::pak::MIPS_API $key]}
}

proc pak::module_api_symbol {mod fn} {
    set key [list $mod $fn]
    if {[dict exists $::pak::CG_API $key]} {
        return [dict get $::pak::CG_API $key]
    }
    if {[dict exists $::pak::MIPS_API $key]} {
        return [dict get $::pak::MIPS_API $key]
    }
    return "${mod}_${fn}"
}

# Every {mod fn} the compiler considers real, sorted for stable docs.
proc pak::module_api_keys {} {
    set keys [dict create]
    dict for {k _} $::pak::CG_API { dict set keys $k 1 }
    dict for {k _} $::pak::CG_API_LAMBDA { dict set keys $k 1 }
    dict for {k _} $::pak::API_ARITY { dict set keys $k 1 }
    dict for {k _} $::pak::MIPS_API { dict set keys $k 1 }
    return [lsort [dict keys $keys]]
}

# ── Standalone HAL: symbols `fn name` in runtime/standalone/runtime.pk64 ─────
# Internal helpers (vi_write, dl_cmd, fb_fill, ...) are intentionally omitted:
# games call the n64.* surface, not the HAL's guts.

set ::pak::MIPS_HAL_SYMBOLS [dict create \
    display_init 1 \
    display_get 1 \
    display_show 1 \
    display_close 1 \
    joypad_init 1 \
    joypad_poll 1 \
    joypad_get_status 1 \
    data_cache_hit_writeback 1 \
    data_cache_hit_invalidate 1 \
    data_cache_hit_writeback_invalidate 1 \
    rdpq_init 1 \
    rdpq_close 1 \
    rdpq_set_color_image 1 \
    rdpq_set_z_image 1 \
    rdpq_set_scissor 1 \
    rdpq_set_other_modes_raw 1 \
    rdpq_set_combiner_raw 1 \
    rdpq_attach 1 \
    rdpq_attach_clear 1 \
    rdpq_detach 1 \
    rdpq_detach_show 1 \
    rdpq_set_mode_fill 1 \
    rdpq_set_mode_copy 1 \
    rdpq_set_mode_standard 1 \
    rdpq_set_mode_standard_z 1 \
    rdpq_clear_z 1 \
    rdpq_set_fill_color 1 \
    rdpq_set_blend_color 1 \
    rdpq_set_fog_color 1 \
    rdpq_set_env_color 1 \
    rdpq_set_prim_color 1 \
    rdpq_set_prim_depth 1 \
    rdpq_fill_rectangle 1 \
    rdpq_set_texture_image 1 \
    rdpq_set_tile 1 \
    rdpq_set_tile_mask 1 \
    rdpq_set_tile_size 1 \
    rdpq_load_tile 1 \
    rdpq_load_block 1 \
    rdpq_load_tlut 1 \
    rdpq_texture_rectangle 1 \
    rdpq_texture_rectangle_scaled 1 \
    rdpq_texture_rectangle_flip 1 \
    rdpq_triangle 1 \
    rdpq_triangle_z 1 \
    rdpq_triangle_shade 1 \
    rdpq_triangle_shade_z 1 \
    rdpq_triangle_tex 1 \
    rdpq_triangle_tex_z 1 \
    rdpq_triangle_shade_tex 1 \
    rdpq_triangle_shade_tex_z 1 \
    rdpq_set_tri_z 1 \
    rdpq_sync_full 1 \
    rdpq_sync_pipe 1 \
    rdpq_sync_tile 1 \
    rdpq_sync_load 1 \
    timer_init 1 \
    get_ticks 1 \
    _pak_delta_time 1 \
    dma_wait 1 \
    dma_read 1 \
    dma_write 1 \
    eeprom_init 1 \
    eeprom_present 1 \
    eeprom_type_detect 1 \
    eeprom_read 1 \
    eeprom_write 1 \
    audio_init 1 \
    audio_close 1 \
    audio_get_buffer 1 \
    audio_get_frequency 1 \
    audio_can_write 1 \
    audio_write 1 \
    audio_write_silence 1 \
    audio_set_buffer_num 1 \
    memset 1 \
    memcpy 1 \
    memcmp 1 \
    strlen 1 \
    strcmp 1 \
    strncmp 1 \
    strstr 1 \
    assert 1 \
    debugf 1 \
    __pak_alloc 1 \
    __pak_free 1 \
    __pak_fix16_div 1 \
    __pak_panic 1 \
    exception_set_handler 1 \
    exception_get_handler 1 \
    exception_paint 1 \
]

proc pak::mips_hal_has {mod fn} {
    set sym [pak::module_api_symbol $mod $fn]
    return [dict exists $::pak::MIPS_HAL_SYMBOLS $sym]
}

proc pak::mips_hal_symbol {sym} {
    return [dict exists $::pak::MIPS_HAL_SYMBOLS $sym]
}
