# tcl/mips_tables.tcl — lookup tables for the MIPS backend: the runtime
# symbols the generated code may reference, the module API map (Pak call →
# runtime symbol), and primitive type layouts.
# Generated once from a second implementation; now hand-maintained source.
# String/container runtime symbols and the CStr/Str layout follow after memset.
namespace eval pak {}
if {[info exists ::pak::_mips_tables_loaded]} { return }
set ::pak::_mips_tables_loaded 1

set ::pak::MIPS_EXTERNS [list \
    display_init \
    display_get \
    display_show \
    display_close \
    joypad_init \
    joypad_get_status \
    joypad_poll \
    rdpq_init \
    rdpq_close \
    rdpq_attach \
    rdpq_attach_clear \
    rdpq_detach \
    rdpq_detach_show \
    rdpq_set_mode_standard \
    rdpq_set_mode_standard_z \
    rdpq_set_mode_copy \
    rdpq_set_mode_fill \
    rdpq_clear_z \
    rdpq_fill_rectangle \
    rdpq_sync_full \
    rdpq_sync_pipe \
    rdpq_sync_tile \
    rdpq_sync_load \
    rdpq_set_scissor \
    rdpq_set_color_image \
    rdpq_set_z_image \
    rdpq_set_other_modes_raw \
    rdpq_set_combiner_raw \
    rdpq_set_fill_color \
    rdpq_set_blend_color \
    rdpq_set_fog_color \
    rdpq_set_env_color \
    rdpq_set_prim_color \
    rdpq_set_texture_image \
    rdpq_set_tile \
    rdpq_set_tile_mask \
    rdpq_set_tile_size \
    rdpq_load_tile \
    rdpq_load_block \
    rdpq_load_tlut \
    rdpq_texture_rectangle \
    rdpq_texture_rectangle_scaled \
    rdpq_triangle \
    rdpq_triangle_z \
    rdpq_triangle_shade \
    rdpq_triangle_shade_z \
    rdpq_triangle_tex \
    rdpq_triangle_tex_z \
    rdpq_triangle_shade_tex \
    rdpq_triangle_shade_tex_z \
    rdpq_set_tri_z \
    sprite_load \
    rdpq_sprite_blit \
    timer_init \
    _pak_delta_time \
    get_ticks \
    audio_init \
    audio_close \
    audio_get_buffer \
    audio_get_frequency \
    audio_can_write \
    audio_write \
    audio_write_silence \
    audio_set_buffer_num \
    debugf \
    assert \
    dma_read \
    dma_write \
    dma_wait \
    data_cache_hit_writeback \
    data_cache_hit_invalidate \
    data_cache_hit_writeback_invalidate \
    eeprom_present \
    eeprom_type_detect \
    eeprom_read \
    eeprom_write \
    rumble_init \
    rumble_start \
    rumble_stop \
    cpak_init \
    cpak_is_plugged \
    cpak_is_formatted \
    cpak_format \
    cpak_read_sector \
    cpak_write_sector \
    cpak_get_free_space \
    tpak_init \
    tpak_set_value \
    tpak_get_value \
    t3d_init \
    t3d_destroy \
    t3d_frame_start \
    rspq_block_run \
    t3d_screen_projection \
    t3d_viewport_create \
    t3d_viewport_set_projection \
    t3d_model_load \
    t3d_model_free \
    t3d_model_draw \
    t3d_mat4_identity \
    t3d_mat4_rotate \
    t3d_mat4_translate \
    t3d_mat4_scale \
    t3d_mat4_mul \
    t3d_mat4_from_srt \
    t3d_mat4_from_srt_euler \
    t3d_mat4_invert \
    t3d_mat4_transpose \
    t3d_vec3_norm \
    t3d_vec3_cross \
    t3d_vec3_dot \
    t3d_vec3_lerp \
    t3d_quat_identity \
    t3d_quat_from_axis_angle \
    t3d_quat_mul \
    t3d_quat_nlerp \
    t3d_quat_slerp \
    t3d_light_set_ambient \
    t3d_light_set_directional \
    t3d_light_set_count \
    t3d_light_set_point \
    t3d_light_set_spot \
    t3d_light_set_point_params \
    t3d_viewport_attach \
    t3d_viewport_set_fov \
    t3d_set_camera \
    t3d_look_at \
    t3d_fog_set_enabled \
    t3d_fog_set_range \
    t3d_fog_set_color \
    t3d_anim_create \
    t3d_anim_destroy \
    t3d_anim_set_playing \
    t3d_anim_set_looping \
    t3d_anim_set_speed \
    t3d_anim_update \
    t3d_anim_attach \
    t3d_skeleton_create \
    t3d_skeleton_destroy \
    t3d_skeleton_update \
    t3d_skeleton_draw \
    t3d_state_set_vertex_fx \
    t3d_state_set_drawflags \
    t3d_push_draw_flags \
    t3d_pop_draw_flags \
    t3d_model_get_object_by_index \
    t3d_model_get_object_by_name \
    t3d_model_get_material \
    t3d_model_get_vertex_count \
    t3d_model_bake_pos \
    t3d_draw_object \
    t3d_draw_indexed \
    t3d_segment_set \
    t3d_rdpq_draw_object \
    t3d_vert_load \
    t3d_vert_load_srt \
    t3d_tri_draw \
    t3d_tri_sync \
    __pak_fix16_div \
    __pak_alloc \
    __pak_free \
    __pak_panic \
    memcpy \
    memset \
    snprintf \
    strlen \
    strcmp \
    strncmp \
    strstr \
    pak_str_eq \
    pak_map_set \
    pak_map_get \
    pak_map_has \
    pak_map_remove \
    pak_pool_acquire \
    pak_pool_release \
]

set ::pak::MIPS_API [dict create \
    {display init} {display_init} \
    {display get} {display_get} \
    {display show} {display_show} \
    {display close} {display_close} \
    {controller init} {joypad_init} \
    {controller read} {joypad_get_status} \
    {controller poll} {joypad_poll} \
    {rdpq init} {rdpq_init} \
    {rdpq close} {rdpq_close} \
    {rdpq attach} {rdpq_attach} \
    {rdpq attach_clear} {rdpq_attach_clear} \
    {rdpq detach} {rdpq_detach} \
    {rdpq detach_show} {rdpq_detach_show} \
    {rdpq set_mode_standard} {rdpq_set_mode_standard} \
    {rdpq set_mode_standard_z} {rdpq_set_mode_standard_z} \
    {rdpq set_mode_copy} {rdpq_set_mode_copy} \
    {rdpq set_mode_fill} {rdpq_set_mode_fill} \
    {rdpq clear_z} {rdpq_clear_z} \
    {rdpq fill_rectangle} {rdpq_fill_rectangle} \
    {rdpq sync_full} {rdpq_sync_full} \
    {rdpq sync_pipe} {rdpq_sync_pipe} \
    {rdpq sync_tile} {rdpq_sync_tile} \
    {rdpq sync_load} {rdpq_sync_load} \
    {rdpq set_scissor} {rdpq_set_scissor} \
    {rdpq set_color_image} {rdpq_set_color_image} \
    {rdpq set_z_image} {rdpq_set_z_image} \
    {rdpq set_other_modes_raw} {rdpq_set_other_modes_raw} \
    {rdpq set_combiner_raw} {rdpq_set_combiner_raw} \
    {rdpq set_fill_color} {rdpq_set_fill_color} \
    {rdpq set_blend_color} {rdpq_set_blend_color} \
    {rdpq set_fog_color} {rdpq_set_fog_color} \
    {rdpq set_env_color} {rdpq_set_env_color} \
    {rdpq set_prim_color} {rdpq_set_prim_color} \
    {rdpq set_texture_image} {rdpq_set_texture_image} \
    {rdpq set_tile} {rdpq_set_tile} \
    {rdpq set_tile_mask} {rdpq_set_tile_mask} \
    {rdpq set_tile_size} {rdpq_set_tile_size} \
    {rdpq load_tile} {rdpq_load_tile} \
    {rdpq load_block} {rdpq_load_block} \
    {rdpq load_tlut} {rdpq_load_tlut} \
    {rdpq texture_rectangle} {rdpq_texture_rectangle} \
    {rdpq texture_rectangle_scaled} {rdpq_texture_rectangle_scaled} \
    {rdpq triangle} {rdpq_triangle} \
    {rdpq triangle_z} {rdpq_triangle_z} \
    {rdpq triangle_shade} {rdpq_triangle_shade} \
    {rdpq triangle_shade_z} {rdpq_triangle_shade_z} \
    {rdpq triangle_tex} {rdpq_triangle_tex} \
    {rdpq triangle_tex_z} {rdpq_triangle_tex_z} \
    {rdpq triangle_shade_tex} {rdpq_triangle_shade_tex} \
    {rdpq triangle_shade_tex_z} {rdpq_triangle_shade_tex_z} \
    {rdpq set_tri_z} {rdpq_set_tri_z} \
    {sprite load} {sprite_load} \
    {sprite blit} {rdpq_sprite_blit} \
    {timer init} {timer_init} \
    {timer delta} {_pak_delta_time} \
    {timer get_ticks} {get_ticks} \
    {audio init} {audio_init} \
    {audio close} {audio_close} \
    {audio get_buffer} {audio_get_buffer} \
    {audio get_frequency} {audio_get_frequency} \
    {audio can_write} {audio_can_write} \
    {audio write} {audio_write} \
    {audio write_silence} {audio_write_silence} \
    {audio set_buffer_num} {audio_set_buffer_num} \
    {debug log} {debugf} \
    {debug assert} {assert} \
    {debug log_value} {debugf} \
    {dma read} {dma_read} \
    {dma write} {dma_write} \
    {dma wait} {dma_wait} \
    {exception set_handler} {exception_set_handler} \
    {exception get_handler} {exception_get_handler} \
    {cache writeback} {data_cache_hit_writeback} \
    {cache invalidate} {data_cache_hit_invalidate} \
    {cache writeback_inv} {data_cache_hit_writeback_invalidate} \
    {eeprom init} {eeprom_init} \
    {eeprom present} {eeprom_present} \
    {eeprom type_detect} {eeprom_type_detect} \
    {eeprom read} {eeprom_read} \
    {eeprom write} {eeprom_write} \
    {rumble init} {rumble_init} \
    {rumble start} {rumble_start} \
    {rumble stop} {rumble_stop} \
    {cpak init} {cpak_init} \
    {cpak is_plugged} {cpak_is_plugged} \
    {cpak is_formatted} {cpak_is_formatted} \
    {cpak format} {cpak_format} \
    {cpak read_sector} {cpak_read_sector} \
    {cpak write_sector} {cpak_write_sector} \
    {cpak get_free_space} {cpak_get_free_space} \
    {tpak init} {tpak_init} \
    {tpak set_value} {tpak_set_value} \
    {tpak get_value} {tpak_get_value} \
    {t3d init} {t3d_init} \
    {t3d destroy} {t3d_destroy} \
    {t3d frame_start} {t3d_frame_start} \
    {t3d frame_end} {rspq_block_run} \
    {t3d screen_projection} {t3d_screen_projection} \
    {t3d viewport_create} {t3d_viewport_create} \
    {t3d viewport_set_projection} {t3d_viewport_set_projection} \
    {t3d model_load} {t3d_model_load} \
    {t3d model_free} {t3d_model_free} \
    {t3d model_draw} {t3d_model_draw} \
    {t3d mat4_identity} {t3d_mat4_identity} \
    {t3d mat4_rotate_y} {t3d_mat4_rotate} \
    {t3d mat4_rotate_x} {t3d_mat4_rotate} \
    {t3d mat4_rotate_z} {t3d_mat4_rotate} \
    {t3d mat4_translate} {t3d_mat4_translate} \
    {t3d mat4_scale} {t3d_mat4_scale} \
    {t3d mat4_mul} {t3d_mat4_mul} \
    {t3d mat4_from_srt} {t3d_mat4_from_srt} \
    {t3d mat4_from_srt_euler} {t3d_mat4_from_srt_euler} \
    {t3d mat4_invert} {t3d_mat4_invert} \
    {t3d mat4_transpose} {t3d_mat4_transpose} \
    {t3d vec3_norm} {t3d_vec3_norm} \
    {t3d vec3_cross} {t3d_vec3_cross} \
    {t3d vec3_dot} {t3d_vec3_dot} \
    {t3d vec3_lerp} {t3d_vec3_lerp} \
    {t3d quat_identity} {t3d_quat_identity} \
    {t3d quat_from_axis_angle} {t3d_quat_from_axis_angle} \
    {t3d quat_mul} {t3d_quat_mul} \
    {t3d quat_nlerp} {t3d_quat_nlerp} \
    {t3d quat_slerp} {t3d_quat_slerp} \
    {t3d light_set_ambient} {t3d_light_set_ambient} \
    {t3d light_set_directional} {t3d_light_set_directional} \
    {t3d light_set_count} {t3d_light_set_count} \
    {t3d light_set_point} {t3d_light_set_point} \
    {t3d light_set_spot} {t3d_light_set_spot} \
    {t3d light_set_point_params} {t3d_light_set_point_params} \
    {t3d viewport_attach} {t3d_viewport_attach} \
    {t3d viewport_set_fov} {t3d_viewport_set_fov} \
    {t3d set_camera} {t3d_set_camera} \
    {t3d look_at} {t3d_look_at} \
    {t3d fog_set_enabled} {t3d_fog_set_enabled} \
    {t3d fog_set_range} {t3d_fog_set_range} \
    {t3d fog_set_color} {t3d_fog_set_color} \
    {t3d anim_create} {t3d_anim_create} \
    {t3d anim_destroy} {t3d_anim_destroy} \
    {t3d anim_set_playing} {t3d_anim_set_playing} \
    {t3d anim_set_looping} {t3d_anim_set_looping} \
    {t3d anim_set_speed} {t3d_anim_set_speed} \
    {t3d anim_update} {t3d_anim_update} \
    {t3d anim_attach} {t3d_anim_attach} \
    {t3d skeleton_create} {t3d_skeleton_create} \
    {t3d skeleton_destroy} {t3d_skeleton_destroy} \
    {t3d skeleton_update} {t3d_skeleton_update} \
    {t3d skeleton_draw} {t3d_skeleton_draw} \
    {t3d state_set_vertex_fx} {t3d_state_set_vertex_fx} \
    {t3d state_set_drawflags} {t3d_state_set_drawflags} \
    {t3d push_draw_flags} {t3d_push_draw_flags} \
    {t3d pop_draw_flags} {t3d_pop_draw_flags} \
    {t3d model_get_object_by_index} {t3d_model_get_object_by_index} \
    {t3d model_get_object_by_name} {t3d_model_get_object_by_name} \
    {t3d model_get_material} {t3d_model_get_material} \
    {t3d model_get_vertex_count} {t3d_model_get_vertex_count} \
    {t3d model_bake_pos} {t3d_model_bake_pos} \
    {t3d draw_object} {t3d_draw_object} \
    {t3d draw_indexed} {t3d_draw_indexed} \
    {t3d segment_set} {t3d_segment_set} \
    {t3d rdpq_draw_object} {t3d_rdpq_draw_object} \
    {t3d vert_load} {t3d_vert_load} \
    {t3d vert_load_srt} {t3d_vert_load_srt} \
    {t3d tri_draw} {t3d_tri_draw} \
    {t3d tri_sync} {t3d_tri_sync} \
]

# primitive type layouts: name -> {size align is_float is_signed}
set ::pak::MIPS_PRIM [dict create \
    {void} {0 1 0 0} \
    {bool} {1 1 0 0} \
    {byte} {1 1 0 0} \
    {c_char} {1 1 0 1} \
    {i8} {1 1 0 1} \
    {u8} {1 1 0 0} \
    {i16} {2 2 0 1} \
    {u16} {2 2 0 0} \
    {i32} {4 4 0 1} \
    {u32} {4 4 0 0} \
    {i64} {8 8 0 1} \
    {u64} {8 8 0 0} \
    {f32} {4 4 1 1} \
    {f64} {8 8 1 1} \
    {fix16.16} {4 4 0 1} \
    {fix10.5} {2 2 0 1} \
    {fix1.15} {2 2 0 1} \
    {ptr} {4 4 0 0} \
    {*T} {4 4 0 0} \
    {CStr}  {4 4 0 0} \
    {Str}   {8 4 0 0} \
]
