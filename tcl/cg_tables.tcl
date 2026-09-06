# tcl/cg_tables.tcl — lookup tables for the C backend: the module API map
# (Pak call → C symbol), the calls needing a lambda, module includes, primitive
# type spellings and printf format specifiers.
# Generated once from a second implementation; now hand-maintained source.
namespace eval pak {}
# Include guard (reachable via multiple consumers; see ast.tcl).
if {[info exists ::pak::_cg_tables_loaded]} { return }
set ::pak::_cg_tables_loaded 1

set ::pak::CG_API [dict create \
    {audio can_write} {audio_can_write} \
    {audio close} {audio_close} \
    {audio get_frequency} {audio_get_frequency} \
    {audio init} {audio_init} \
    {audio set_buffer_num} {audio_set_buffer_num} \
    {audio write} {audio_write} \
    {audio write_silence} {audio_write_silence} \
    {backup read} {backup_read} \
    {backup size} {backup_size} \
    {backup type} {backup_type} \
    {backup write} {backup_write} \
    {cache invalidate} {data_cache_hit_invalidate} \
    {cache writeback} {data_cache_hit_writeback} \
    {cache writeback_inv} {data_cache_hit_writeback_invalidate} \
    {controller init} {joypad_init} \
    {controller poll} {joypad_poll} \
    {cpak format} {cpak_format} \
    {cpak get_free_space} {cpak_get_free_space} \
    {cpak init} {cpak_init} \
    {cpak is_formatted} {cpak_is_formatted} \
    {cpak is_plugged} {cpak_is_plugged} \
    {cpak read_sector} {cpak_read_sector} \
    {cpak write_sector} {cpak_write_sector} \
    {debug assert} {assert} \
    {debug flush} {flush} \
    {debug init} {debug_init_isviewer} \
    {debug init_isviewer} {debug_init_isviewer} \
    {debug init_usbfs} {debug_init_usbfs} \
    {debug log} {debugf} \
    {debug print} {debugf} \
    {disk close} {disk_close} \
    {disk get_disk_type} {disk_get_disk_type} \
    {disk init} {disk_init} \
    {disk is_present} {disk_is_present} \
    {disk read_sector} {disk_read_sector} \
    {disk write_sector} {disk_write_sector} \
    {display close} {display_close} \
    {display get} {display_get} \
    {display show} {display_show} \
    {dma read} {dma_read} \
    {dma wait} {dma_wait} \
    {dma write} {dma_write} \
    {eeprom present} {eeprom_present} \
    {eeprom read} {eeprom_read} \
    {eeprom write} {eeprom_write} \
    {exception get_handler} {exception_get_handler} \
    {exception set_handler} {exception_set_handler} \
    {interrupt init} {interrupt_init} \
    {interrupt disable} {interrupt_disable} \
    {interrupt restore} {interrupt_restore} \
    {interrupt vi_count} {interrupt_vi_count} \
    {interrupt pending} {interrupt_pending} \
    {interrupt enabled} {interrupt_enabled} \
    {flashram erase_sector} {flashram_erase_sector} \
    {flashram read} {flashram_read} \
    {flashram write} {flashram_write} \
    {joypad get_accessory_type} {joypad_get_accessory_type} \
    {joypad get_axis_held} {joypad_get_axis_held} \
    {joypad get_axis_pressed} {joypad_get_axis_pressed} \
    {joypad get_buttons} {joypad_get_buttons} \
    {joypad get_buttons_pressed} {joypad_get_buttons_pressed} \
    {joypad get_buttons_released} {joypad_get_buttons_released} \
    {joypad get_status} {joypad_get_status} \
    {joypad init} {joypad_init} \
    {joypad poll} {joypad_poll} \
    {mixer ch_play} {mixer_ch_play} \
    {mixer ch_playing} {mixer_ch_playing} \
    {mixer ch_set_freq} {mixer_ch_set_freq} \
    {mixer ch_set_vol} {mixer_ch_set_vol} \
    {mixer ch_stop} {mixer_ch_stop} \
    {mixer close} {mixer_close} \
    {mixer init} {mixer_init} \
    {mixer poll} {audio_poll} \
    {mouse init} {joypad_init} \
    {mouse poll} {joypad_poll} \
    {rdpq attach} {rdpq_attach} \
    {rdpq block_begin} {rdpq_block_begin} \
    {rdpq block_end} {rdpq_block_end} \
    {rdpq block_free} {rdpq_block_free} \
    {rdpq block_run} {rdpq_block_run} \
    {rdpq call} {rdpq_call} \
    {rdpq clear_z} {rdpq_clear_z} \
    {rdpq close} {rdpq_close} \
    {rdpq detach} {rdpq_detach} \
    {rdpq detach_show} {rdpq_detach_show} \
    {rdpq fill_rectangle} {rdpq_fill_rectangle} \
    {rdpq flush} {rspq_flush} \
    {rdpq init} {rdpq_init} \
    {rdpq load_tile} {rdpq_load_tile} \
    {rdpq load_tlut} {rdpq_load_tlut_raw} \
    {rdpq set_blend_color} {rdpq_set_blend_color} \
    {rdpq set_color_image} {rdpq_set_color_image} \
    {rdpq set_combiner_raw} {rdpq_set_combiner_raw} \
    {rdpq set_env_color} {rdpq_set_env_color} \
    {rdpq set_fog_color} {rdpq_set_fog_color} \
    {rdpq set_mode_standard} {rdpq_set_mode_standard} \
    {rdpq set_mode_standard_z} {rdpq_set_mode_standard_z} \
    {rdpq set_other_modes_raw} {rdpq_set_other_modes_raw} \
    {rdpq set_prim_color} {rdpq_set_prim_color} \
    {rdpq set_prim_depth} {rdpq_set_prim_depth_raw} \
    {rdpq set_key_r} {rdpq_set_key_r} \
    {rdpq set_key_gb} {rdpq_set_key_gb} \
    {rdpq set_convert} {rdpq_set_yuv_parms} \
    {rdpq set_scissor} {rdpq_set_scissor} \
    {rdpq set_tile} {rdpq_set_tile} \
    {rdpq set_tile_mask} {rdpq_set_tile_mask} \
    {rdpq set_tile_size} {rdpq_set_tile_size} \
    {rdpq set_z_image} {rdpq_set_z_image} \
    {rdpq sync_full} {rdpq_sync_full} \
    {rdpq sync_load} {rdpq_sync_load} \
    {rdpq sync_pipe} {rdpq_sync_pipe} \
    {rdpq sync_tile} {rdpq_sync_tile} \
    {rdpq load_block} {rdpq_load_block} \
    {rdpq set_texture_image} {rdpq_set_texture_image} \
    {rdpq texture_rectangle} {rdpq_texture_rectangle} \
    {rdpq texture_rectangle_scaled} {rdpq_texture_rectangle_scaled} \
    {rdpq texture_rectangle_flip} {rdpq_texture_rectangle_flip} \
    {rdpq triangle} {rdpq_triangle} \
    {rdpq triangle_z} {rdpq_triangle_z} \
    {rdpq triangle_shade} {rdpq_triangle_shade} \
    {rdpq triangle_shade_z} {rdpq_triangle_shade_z} \
    {rdpq triangle_tex} {rdpq_triangle_tex} \
    {rdpq triangle_tex_z} {rdpq_triangle_tex_z} \
    {rdpq triangle_shade_tex} {rdpq_triangle_shade_tex} \
    {rdpq triangle_shade_tex_z} {rdpq_triangle_shade_tex_z} \
    {rdpq set_tri_z} {rdpq_set_tri_z} \
    {rdpq_font draw_text} {rdpq_text_print} \
    {rdpq_font free} {rdpq_font_free} \
    {rdpq_font load} {rdpq_font_load} \
    {rdpq_font measure} {rdpq_text_measure} \
    {rdpq_font register} {rdpq_font_register} \
    {rdpq_mode combiner} {rdpq_mode_combiner} \
    {rdpq_mode copy} {rdpq_set_mode_copy} \
    {rdpq_mode pop} {rdpq_mode_pop} \
    {rdpq_mode push} {rdpq_mode_push} \
    {rdpq_mode standard} {rdpq_set_mode_standard} \
    {rdpq_tex multi_begin} {rdpq_tex_multi_begin} \
    {rdpq_tex multi_end} {rdpq_tex_multi_end} \
    {rdpq_tex upload} {rdpq_tex_upload} \
    {rdpq_tex upload_sub} {rdpq_tex_upload_sub} \
    {sp init} {pak_sp_init} \
    {sp load_ucode} {pak_sp_load_ucode} \
    {sp load_data} {pak_sp_load_data} \
    {sp read_data} {pak_sp_read_data} \
    {sp run} {pak_sp_run} \
    {sp wait} {pak_sp_wait} \
    {sp done} {pak_sp_done} \
    {sp status} {pak_sp_status} \
    {rsp block_begin} {rspq_block_begin} \
    {rsp block_end} {rspq_block_end} \
    {rsp block_free} {rspq_block_free} \
    {rsp block_run} {rspq_block_run} \
    {rsp close} {rspq_close} \
    {rsp init} {rspq_init} \
    {rsp syncpoint_check} {rspq_syncpoint_check} \
    {rsp syncpoint_new} {rspq_syncpoint_new} \
    {rsp wait} {rspq_wait} \
    {rtc get} {rtc_get} \
    {rtc init} {rtc_init} \
    {rtc is_stopped} {rtc_is_stopped} \
    {rtc set} {rtc_set} \
    {sprite load} {sprite_load} \
    {sram read} {sram_read} \
    {sram write} {sram_write} \
    {surface alloc} {surface_alloc} \
    {surface free} {surface_free} \
    {surface make_sub} {surface_make_sub} \
    {system memory_size} {get_memory_size} \
    {t3d anim_attach} {t3d_anim_attach} \
    {t3d anim_create} {t3d_anim_create} \
    {t3d anim_destroy} {t3d_anim_destroy} \
    {t3d anim_set_looping} {t3d_anim_set_looping} \
    {t3d anim_set_playing} {t3d_anim_set_playing} \
    {t3d anim_set_speed} {t3d_anim_set_speed} \
    {t3d anim_update} {t3d_anim_update} \
    {t3d destroy} {t3d_destroy} \
    {t3d draw_indexed} {t3d_draw_indexed} \
    {t3d draw_object} {t3d_draw_object} \
    {t3d fog_set_color} {t3d_fog_set_color} \
    {t3d fog_set_range} {t3d_fog_set_range} \
    {t3d frame_end} {rspq_block_run} \
    {t3d frame_start} {t3d_frame_start} \
    {t3d init} {t3d_init} \
    {t3d light_set_ambient} {t3d_light_set_ambient} \
    {t3d light_set_count} {t3d_light_set_count} \
    {t3d light_set_directional} {t3d_light_set_directional} \
    {t3d light_set_point} {t3d_light_set_point} \
    {t3d light_set_point_params} {t3d_light_set_point_params} \
    {t3d light_set_spot} {t3d_light_set_spot} \
    {t3d look_at} {t3d_look_at} \
    {t3d model_bake_pos} {t3d_model_bake_pos} \
    {t3d model_draw} {t3d_model_draw} \
    {t3d model_free} {t3d_model_free} \
    {t3d model_get_material} {t3d_model_get_material} \
    {t3d model_get_object_by_index} {t3d_model_get_object_by_index} \
    {t3d model_get_object_by_name} {t3d_model_get_object_by_name} \
    {t3d model_get_vertex_count} {t3d_model_get_vertex_count} \
    {t3d model_load} {t3d_model_load} \
    {t3d pop_draw_flags} {t3d_pop_draw_flags} \
    {t3d push_draw_flags} {t3d_push_draw_flags} \
    {t3d rdpq_draw_object} {t3d_rdpq_draw_object} \
    {t3d screen_projection} {t3d_screen_projection} \
    {t3d segment_set} {t3d_segment_set} \
    {t3d set_camera} {t3d_set_camera} \
    {t3d skeleton_create} {t3d_skeleton_create} \
    {t3d skeleton_destroy} {t3d_skeleton_destroy} \
    {t3d skeleton_draw} {t3d_skeleton_draw} \
    {t3d skeleton_update} {t3d_skeleton_update} \
    {t3d state_set_drawflags} {t3d_state_set_drawflags} \
    {t3d state_set_vertex_fx} {t3d_state_set_vertex_fx} \
    {t3d tri_draw} {t3d_tri_draw} \
    {t3d tri_sync} {t3d_tri_sync} \
    {t3d vert_load} {t3d_vert_load} \
    {t3d vert_load_srt} {t3d_vert_load_srt} \
    {t3d viewport_attach} {t3d_viewport_attach} \
    {t3d viewport_create} {t3d_viewport_create} \
    {t3d viewport_set_fov} {t3d_viewport_set_fov} \
    {t3d viewport_set_projection} {t3d_viewport_set_projection} \
    {timer get_ticks} {get_ticks} \
    {timer init} {timer_init} \
    {timer ticks} {get_ticks} \
    {tpak get_status} {tpak_get_status} \
    {tpak get_value} {tpak_get_value} \
    {tpak init} {tpak_init} \
    {tpak read} {tpak_read} \
    {tpak set_value} {tpak_set_value} \
    {tpak set_power} {tpak_set_power} \
    {tpak write} {tpak_write} \
    {vi set_aa_mode} {vi_set_aa_mode} \
    {vi set_dedither} {vi_set_dedither} \
    {vi set_divot} {vi_set_divot} \
    {vi set_gamma} {vi_set_gamma} \
    {vru close} {vru_close} \
    {vru init} {vru_init} \
    {vru is_ready} {vru_is_ready} \
    {vru read_word} {vru_read_word} \
    {vru write_word_list} {vru_write_word_list} \
    {wav64 close} {wav64_close} \
    {wav64 open} {wav64_open} \
    {wav64 play} {wav64_play} \
    {wav64 set_loop} {wav64_set_loop} \
    {xm64 close} {xm64player_close} \
    {xm64 open} {xm64player_open} \
    {xm64 play} {xm64player_play} \
    {xm64 set_vol} {xm64player_set_vol} \
    {xm64 stop} {xm64player_stop} \
]

set ::pak::CG_API_LAMBDA [dict create \
    {arena alloc} {1} \
    {arena reset} {1} \
    {audio get_buffer} {1} \
    {controller read} {1} \
    {debug log_value} {1} \
    {display init} {1} \
    {eeprom init} {1} \
    {eeprom type_detect} {1} \
    {rdpq attach_clear} {1} \
    {rdpq set_fill_color} {1} \
    {rdpq set_mode_copy} {1} \
    {rdpq set_mode_fill} {1} \
    {joypad is_connected} {1} \
    {math abs_f} {1} \
    {math abs_i32} {1} \
    {math atan2_f} {1} \
    {math ceil_f} {1} \
    {math clamp_f} {1} \
    {math clamp_i32} {1} \
    {math cos_f} {1} \
    {math f_to_fix} {1} \
    {math fix_cos} {1} \
    {math fix_sin} {1} \
    {math fix_sqrt} {1} \
    {math fix_to_f} {1} \
    {math floor_f} {1} \
    {math lerp_f} {1} \
    {math max_f} {1} \
    {math max_i32} {1} \
    {math min_f} {1} \
    {math min_i32} {1} \
    {math pow_f} {1} \
    {math rand} {1} \
    {math rand_f} {1} \
    {math rand_range} {1} \
    {math rand_seed} {1} \
    {math sin_f} {1} \
    {math sqrt_f} {1} \
    {math tan_f} {1} \
    {mem alloc} {1} \
    {mem alloc_aligned} {1} \
    {mem copy} {1} \
    {mem free} {1} \
    {mem move} {1} \
    {mem realloc} {1} \
    {mem zero} {1} \
    {mouse get_buttons} {1} \
    {mouse get_delta_x} {1} \
    {mouse get_delta_y} {1} \
    {rdpq_mode antialias} {1} \
    {rdpq_mode blending} {1} \
    {rdpq_mode dithering} {1} \
    {rdpq_mode filter} {1} \
    {rdpq_mode persp_norm} {1} \
    {rdpq_mode tlut} {1} \
    {rdpq_mode zbuf} {1} \
    {rtc is_running} {1} \
    {rumble init} {1} \
    {rumble is_plugged} {1} \
    {rumble start} {1} \
    {rumble stop} {1} \
    {sprite blit} {1} \
    {str concat} {1} \
    {str data} {1} \
    {str eq} {1} \
    {str from_cstr} {1} \
    {str len} {1} \
    {str print} {1} \
    {system has_expansion} {1} \
    {system reset} {1} \
    {system ticks} {1} \
    {system ticks_to_ms} {1} \
    {system tv_type} {1} \
    {t3d fog_set_enabled} {1} \
    {t3d mat4_from_srt} {1} \
    {t3d mat4_from_srt_euler} {1} \
    {t3d mat4_identity} {1} \
    {t3d mat4_invert} {1} \
    {t3d mat4_mul} {1} \
    {t3d mat4_rotate_x} {1} \
    {t3d mat4_rotate_y} {1} \
    {t3d mat4_rotate_z} {1} \
    {t3d mat4_scale} {1} \
    {t3d mat4_translate} {1} \
    {t3d mat4_transpose} {1} \
    {t3d quat_from_axis_angle} {1} \
    {t3d quat_identity} {1} \
    {t3d quat_mul} {1} \
    {t3d quat_nlerp} {1} \
    {t3d quat_slerp} {1} \
    {t3d vec3_cross} {1} \
    {t3d vec3_dot} {1} \
    {t3d vec3_lerp} {1} \
    {t3d vec3_norm} {1} \
    {timer delta} {1} \
    {vi get_height} {1} \
    {vi get_width} {1} \
    {vi wait_vblank} {1} \
]

set ::pak::CG_USE_INCLUDES [dict create \
    {n64.audio} {#include <audio.h>
#include <xm64.h>
#include <wav64.h>} \
    {n64.backup} {#include <backup.h>} \
    {n64.cache} {#include <n64sys.h>} \
    {n64.controller} {#include <joypad.h>} \
    {n64.cpak} {#include <cpak.h>} \
    {n64.debug} {#include <debug.h>} \
    {n64.disk} {#include <disk.h>} \
    {n64.display} {#include <display.h>} \
    {n64.dma} {#include <dma.h>} \
    {n64.eeprom} {#include <eeprom.h>} \
    {n64.exception} {#include <exception.h>} \
    {n64.interrupt} {#include <interrupt.h>} \
    {n64.sp} {#include <rsp.h>} \
    {n64.flashram} {#include <backup.h>} \
    {n64.joypad} {#include <joypad.h>} \
    {n64.math} {#include <n64sys.h>
#include <math.h>
#include "pak_rand.h"} \
    {n64.mem} {#include <malloc.h>
#include <string.h>} \
    {n64.mixer} {#include <audio.h>
#include <mixer.h>} \
    {n64.mouse} {#include <joypad.h>} \
    {n64.rdpq} {#include <rdpq.h>
#include <rdpq_attach.h>
#include <rdpq_mode.h>
#include <rdpq_rect.h>
#include <rdpq_tri.h>} \
    {n64.rdpq_font} {#include <rdpq_font.h>
#include <rdpq_text.h>} \
    {n64.rdpq_mode} {#include <rdpq_mode.h>} \
    {n64.rdpq_tex} {#include <rdpq_tex.h>} \
    {n64.rsp} {#include <rspq.h>} \
    {n64.rtc} {#include <rtc.h>} \
    {n64.rumble} {#include <joypad.h>} \
    {n64.sprite} {#include <rdpq_sprite.h>} \
    {n64.sram} {#include <backup.h>} \
    {n64.surface} {#include <surface.h>} \
    {n64.system} {#include <n64sys.h>} \
    {n64.timer} {#include <n64sys.h>} \
    {n64.tpak} {#include <tpak.h>} \
    {n64.vi} {#include <display.h>} \
    {n64.vru} {#include <vru.h>} \
    {n64.wav64} {#include <wav64.h>} \
    {n64.xm64} {#include <xm64.h>} \
    {pak.arena} {} \
    {pak.str} {} \
    {t3d.anim} {#include <t3d/t3danim.h>} \
    {t3d.core} {#include <t3d/t3d.h>} \
    {t3d.fog} {#include <t3d/t3d.h>} \
    {t3d.light} {#include <t3d/t3dlight.h>} \
    {t3d.math} {#include <t3d/t3dmath.h>} \
    {t3d.model} {#include <t3d/t3dmodel.h>} \
    {t3d.particles} {#include <t3d/t3d.h>} \
    {t3d.skeleton} {#include <t3d/t3dskeleton.h>} \
    {t3d.state} {#include <t3d/t3d.h>} \
    {t3d.viewport} {#include <t3d/t3d.h>} \
]

set ::pak::CG_PRIM [dict create \
    {Allocator} {Allocator} \
    {Arena} {PakArena} \
    {CStr} {const char *} \
    {Mat4} {T3DMat4} \
    {Str} {PakStr} \
    {Vec2} {T3DVec2} \
    {Vec3} {T3DVec3} \
    {Vec4} {T3DVec4} \
    {bool} {bool} \
    {byte} {uint8_t} \
    {c_char} {char} \
    {f32} {float} \
    {f64} {double} \
    {fix1.15} {int16_t} \
    {fix10.5} {int16_t} \
    {fix16.16} {int32_t} \
    {i16} {int16_t} \
    {i32} {int32_t} \
    {i64} {int64_t} \
    {i8} {int8_t} \
    {joypad_buttons_t} {pak_joypad_buttons_t} \
    {joypad_status_t} {pak_joypad_status_t} \
    {u16} {uint16_t} \
    {u32} {uint32_t} \
    {u64} {uint64_t} \
    {u8} {uint8_t} \
    {void} {void} \
]

set ::pak::CG_FMT_SPEC [dict create \
    {PakStr} {%.*s} \
    {bool} {%d} \
    {double} {%lf} \
    {float} {%f} \
    {int16_t} {%d} \
    {int32_t} {%d} \
    {int64_t} {%lld} \
    {int8_t} {%d} \
    {uint16_t} {%u} \
    {uint32_t} {%u} \
    {uint64_t} {%llu} \
    {uint8_t} {%u} \
]
