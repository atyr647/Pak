"""Pak → C code generator."""

from typing import Optional, List, Any, Callable
from . import ast


# ── Module → C API mapping ────────────────────────────────────────────────────
# Maps "module.function" → C function name (or callable that takes args list
# and returns a full C call string).

def _passthrough(fn: str):
    """Map directly to a C function name."""
    return fn

def _method_call(c_fn: str, first_arg_addr: bool = False):
    """Generate a C function call, optionally taking address of first arg."""
    def _gen(args):
        if first_arg_addr and args:
            return f'{c_fn}(&{args[0]}, {", ".join(args[1:])})'
        return f'{c_fn}({", ".join(args)})'
    return _gen

# (module, function) → C function name string OR callable(args) → str
MODULE_API: dict = {
    # n64.display
    ('display', 'init'):           'display_init',
    ('display', 'get'):            'display_get',
    ('display', 'show'):           'display_show',
    ('display', 'close'):          'display_close',

    # n64.controller / joypad
    ('controller', 'init'):        'joypad_init',
    ('controller', 'read'):        lambda args: f'joypad_get_status({args[0]})' if args else 'joypad_get_status(0)',
    ('controller', 'poll'):        'joypad_poll',

    # n64.rdpq
    ('rdpq', 'init'):              'rdpq_init',
    ('rdpq', 'close'):             'rdpq_close',
    ('rdpq', 'attach'):            'rdpq_attach',
    ('rdpq', 'attach_clear'):      'rdpq_attach_clear',
    ('rdpq', 'detach'):            'rdpq_detach',
    ('rdpq', 'detach_show'):       'rdpq_detach_show',
    ('rdpq', 'set_mode_standard'): 'rdpq_set_mode_standard',
    ('rdpq', 'set_mode_copy'):     'rdpq_set_mode_copy',
    ('rdpq', 'set_mode_fill'):     'rdpq_set_mode_fill',
    ('rdpq', 'fill_rectangle'):    'rdpq_fill_rectangle',
    ('rdpq', 'sync_full'):         'rdpq_sync_full',
    ('rdpq', 'sync_pipe'):         'rdpq_sync_pipe',
    ('rdpq', 'sync_tile'):         'rdpq_sync_tile',
    ('rdpq', 'sync_load'):         'rdpq_sync_load',
    ('rdpq', 'set_scissor'):       'rdpq_set_scissor',

    # n64.sprite
    ('sprite', 'load'):            'sprite_load',
    ('sprite', 'blit'):            lambda args: (
        f'rdpq_sprite_blit({args[0]}, {args[1]}, {args[2]}, NULL)'
        if len(args) >= 3 else f'rdpq_sprite_blit({", ".join(args)}, NULL)'
    ),

    # n64.timer
    ('timer', 'init'):             'timer_init',
    ('timer', 'delta'):            lambda args: '_pak_delta_time()',
    ('timer', 'get_ticks'):        'get_ticks',

    # n64.audio
    ('audio', 'init'):             'audio_init',
    ('audio', 'close'):            'audio_close',
    ('audio', 'get_buffer'):       'audio_get_buffer',

    # n64.debug
    ('debug', 'log'):              'debugf',
    ('debug', 'assert'):           'assert',

    # n64.dma
    ('dma', 'read'):               'dma_read',
    ('dma', 'write'):              'dma_write',
    ('dma', 'wait'):               'dma_wait',

    # n64.cache
    ('cache', 'writeback'):        'data_cache_hit_writeback',
    ('cache', 'invalidate'):       'data_cache_hit_invalidate',
    ('cache', 'writeback_inv'):    'data_cache_hit_writeback_invalidate',

    # t3d.core
    ('t3d', 'init'):               't3d_init',
    ('t3d', 'destroy'):            't3d_destroy',
    ('t3d', 'frame_start'):        't3d_frame_start',
    ('t3d', 'frame_end'):          'rspq_block_run',
    ('t3d', 'screen_projection'):  't3d_screen_projection',
    ('t3d', 'viewport_create'):    't3d_viewport_create',
    ('t3d', 'viewport_set_projection'): 't3d_viewport_set_projection',

    # t3d.model
    ('t3d', 'model_load'):         't3d_model_load',
    ('t3d', 'model_free'):         't3d_model_free',
    ('t3d', 'model_draw'):         't3d_model_draw',

    # t3d.math
    ('t3d', 'mat4_identity'):      lambda args: f't3d_mat4_identity({_addr(args, 0)})',
    ('t3d', 'mat4_rotate_y'):      lambda args: f't3d_mat4_rotate({_addr(args, 0)}, &(T3DVec3){{{{0,1,0}}}}, {args[1]})',
    ('t3d', 'mat4_rotate_x'):      lambda args: f't3d_mat4_rotate({_addr(args, 0)}, &(T3DVec3){{{{1,0,0}}}}, {args[1]})',
    ('t3d', 'mat4_rotate_z'):      lambda args: f't3d_mat4_rotate({_addr(args, 0)}, &(T3DVec3){{{{0,0,1}}}}, {args[1]})',
    ('t3d', 'mat4_translate'):     lambda args: f't3d_mat4_translate({_addr(args, 0)}, {args[1]}, {args[2]}, {args[3]})',
    ('t3d', 'mat4_scale'):         lambda args: f't3d_mat4_scale({_addr(args, 0)}, {args[1]}, {args[2]}, {args[3]})',

    # t3d.light
    ('t3d', 'light_set_ambient'):  't3d_light_set_ambient',
    ('t3d', 'light_set_directional'): 't3d_light_set_directional',

    # t3d.viewport
    ('t3d', 'viewport_attach'):    't3d_viewport_attach',
    ('t3d', 'viewport_set_fov'):   't3d_viewport_set_fov',
    ('t3d', 'set_camera'):         't3d_set_camera',
    ('t3d', 'look_at'):            't3d_look_at',

    # t3d.anim — skeletal animation
    ('t3d', 'anim_create'):        't3d_anim_create',
    ('t3d', 'anim_destroy'):       't3d_anim_destroy',
    ('t3d', 'anim_set_playing'):   't3d_anim_set_playing',
    ('t3d', 'anim_set_looping'):   't3d_anim_set_looping',
    ('t3d', 'anim_set_speed'):     't3d_anim_set_speed',
    ('t3d', 'anim_update'):        't3d_anim_update',
    ('t3d', 'anim_attach'):        't3d_anim_attach',

    # t3d.skeleton
    ('t3d', 'skeleton_create'):    't3d_skeleton_create',
    ('t3d', 'skeleton_destroy'):   't3d_skeleton_destroy',
    ('t3d', 'skeleton_update'):    't3d_skeleton_update',
    ('t3d', 'skeleton_draw'):      't3d_skeleton_draw',

    # t3d.math — full matrix/vector/quaternion API
    ('t3d', 'mat4_mul'):           lambda args: f't3d_mat4_mul({_addr(args,0)}, {_addr(args,1)}, {_addr(args,2)})',
    ('t3d', 'mat4_from_srt'):      lambda args: f't3d_mat4_from_srt({_addr(args,0)}, {_addr(args,1)}, {_addr(args,2)}, {_addr(args,3)})',
    ('t3d', 'mat4_from_srt_euler'):lambda args: f't3d_mat4_from_srt_euler({_addr(args,0)}, {_addr(args,1)}, {_addr(args,2)}, {_addr(args,3)})',
    ('t3d', 'mat4_invert'):        lambda args: f't3d_mat4_invert({_addr(args,0)}, {_addr(args,1)})',
    ('t3d', 'mat4_transpose'):     lambda args: f't3d_mat4_transpose({_addr(args,0)}, {_addr(args,1)})',
    ('t3d', 'vec3_norm'):          lambda args: f't3d_vec3_norm({_addr(args,0)})',
    ('t3d', 'vec3_cross'):         lambda args: f't3d_vec3_cross({_addr(args,0)}, {_addr(args,1)}, {_addr(args,2)})',
    ('t3d', 'vec3_dot'):           lambda args: f't3d_vec3_dot({_addr(args,0)}, {_addr(args,1)})',
    ('t3d', 'vec3_lerp'):          lambda args: f't3d_vec3_lerp({_addr(args,0)}, {_addr(args,1)}, {_addr(args,2)}, {args[3]})',
    ('t3d', 'quat_identity'):      lambda args: f't3d_quat_identity({_addr(args,0)})',
    ('t3d', 'quat_from_axis_angle'):lambda args: f't3d_quat_from_axis_angle({_addr(args,0)}, {_addr(args,1)}, {args[2]})',
    ('t3d', 'quat_mul'):           lambda args: f't3d_quat_mul({_addr(args,0)}, {_addr(args,1)}, {_addr(args,2)})',
    ('t3d', 'quat_nlerp'):         lambda args: f't3d_quat_nlerp({_addr(args,0)}, {_addr(args,1)}, {_addr(args,2)}, {args[3]})',
    ('t3d', 'quat_slerp'):         lambda args: f't3d_quat_slerp({_addr(args,0)}, {_addr(args,1)}, {_addr(args,2)}, {args[3]})',

    # t3d.light — full lighting API
    ('t3d', 'light_set_count'):    't3d_light_set_count',
    ('t3d', 'light_set_point'):    't3d_light_set_point',
    ('t3d', 'light_set_spot'):     't3d_light_set_spot',
    ('t3d', 'light_set_point_params'): 't3d_light_set_point_params',

    # t3d.fog
    ('t3d', 'fog_set_enabled'):    lambda args: f't3d_fog_set_enabled({args[0] if args else "true"})',
    ('t3d', 'fog_set_range'):      't3d_fog_set_range',
    ('t3d', 'fog_set_color'):      't3d_fog_set_color',

    # t3d.state
    ('t3d', 'state_set_vertex_fx'): 't3d_state_set_vertex_fx',
    ('t3d', 'state_set_drawflags'): 't3d_state_set_drawflags',
    ('t3d', 'push_draw_flags'):    't3d_push_draw_flags',
    ('t3d', 'pop_draw_flags'):     't3d_pop_draw_flags',

    # t3d.model — extended
    ('t3d', 'model_get_object_by_index'): 't3d_model_get_object_by_index',
    ('t3d', 'model_get_object_by_name'):  't3d_model_get_object_by_name',
    ('t3d', 'model_get_material'):        't3d_model_get_material',
    ('t3d', 'model_get_vertex_count'):    't3d_model_get_vertex_count',
    ('t3d', 'model_bake_pos'):            't3d_model_bake_pos',
    ('t3d', 'draw_object'):               't3d_draw_object',
    ('t3d', 'draw_indexed'):              't3d_draw_indexed',

    # t3d.segment — RSP segment registers
    ('t3d', 'segment_set'):        't3d_segment_set',

    # t3d.rdpq — Tiny3D RDP mode helpers
    ('t3d', 'rdpq_draw_object'):   't3d_rdpq_draw_object',

    # t3d.particles — basic billboard particle support via raw draws
    ('t3d', 'vert_load'):          't3d_vert_load',
    ('t3d', 'vert_load_srt'):      't3d_vert_load_srt',
    ('t3d', 'tri_draw'):           't3d_tri_draw',
    ('t3d', 'tri_sync'):           't3d_tri_sync',

    # n64.rumble — Rumble Pak
    ('rumble', 'init'):            'rumble_init',
    ('rumble', 'start'):           'rumble_start',
    ('rumble', 'stop'):            'rumble_stop',
    ('rumble', 'is_plugged'):      lambda args: f'(joypad_get_accessory_type({args[0] if args else "0"}) == JOYPAD_ACCESSORY_TYPE_RUMBLE_PAK)',

    # n64.cpak — Controller Pak (memory card)
    ('cpak', 'init'):              'cpak_init',
    ('cpak', 'is_plugged'):        'cpak_is_plugged',
    ('cpak', 'is_formatted'):      'cpak_is_formatted',
    ('cpak', 'format'):            'cpak_format',
    ('cpak', 'read_sector'):       'cpak_read_sector',
    ('cpak', 'write_sector'):      'cpak_write_sector',
    ('cpak', 'get_free_space'):    'cpak_get_free_space',

    # n64.tpak — Transfer Pak (GB/GBC cartridge adapter)
    ('tpak', 'init'):              'tpak_init',
    ('tpak', 'set_power'):         'tpak_set_power',
    ('tpak', 'get_status'):        'tpak_get_status',
    ('tpak', 'read'):              'tpak_read',
    ('tpak', 'write'):             'tpak_write',

    # n64.backup — Save memory (EEPROM / SRAM / FlashRAM unified API)
    ('backup', 'type'):            'backup_type',
    ('backup', 'read'):            'backup_read',
    ('backup', 'write'):           'backup_write',
    ('backup', 'size'):            'backup_size',

    # n64.eeprom — Direct EEPROM access
    ('eeprom', 'init'):            'eeprom_init',
    ('eeprom', 'read'):            'eeprom_read',
    ('eeprom', 'write'):           'eeprom_write',

    # n64.sram — SRAM save memory
    ('sram', 'read'):              'sram_read',
    ('sram', 'write'):             'sram_write',

    # n64.flashram — FlashRAM save memory
    ('flashram', 'read'):          'flashram_read',
    ('flashram', 'write'):         'flashram_write',
    ('flashram', 'erase_sector'):  'flashram_erase_sector',

    # n64.rtc — Real-Time Clock (cartridge RTC, e.g. Pokémon Stadium)
    ('rtc', 'init'):               'rtc_init',
    ('rtc', 'get'):                'rtc_get',
    ('rtc', 'set'):                'rtc_set',
    ('rtc', 'is_stopped'):         'rtc_is_stopped',
    ('rtc', 'is_running'):         lambda args: '!rtc_is_stopped()',

    # n64.mouse — N64 Mouse accessory
    ('mouse', 'init'):             'joypad_init',
    ('mouse', 'poll'):             'joypad_poll',
    ('mouse', 'get_delta_x'):      lambda args: f'joypad_get_axis_pressed({args[0] if args else "0"}, JOYPAD_AXIS_STICK_X)',
    ('mouse', 'get_delta_y'):      lambda args: f'joypad_get_axis_pressed({args[0] if args else "0"}, JOYPAD_AXIS_STICK_Y)',
    ('mouse', 'get_buttons'):      lambda args: f'joypad_get_buttons_pressed({args[0] if args else "0"})',

    # n64.vru — Voice Recognition Unit
    ('vru', 'init'):               'vru_init',
    ('vru', 'close'):              'vru_close',
    ('vru', 'read_word'):          'vru_read_word',
    ('vru', 'write_word_list'):    'vru_write_word_list',
    ('vru', 'is_ready'):           'vru_is_ready',

    # n64.system — Expansion Pak, memory, CPU timing
    ('system', 'memory_size'):     'get_memory_size',
    ('system', 'has_expansion'):   lambda args: '(get_memory_size() > 0x400000)',
    ('system', 'ticks'):           lambda args: 'TICKS_READ()',
    ('system', 'ticks_to_ms'):     lambda args: f'TICKS_TO_MS({args[0]})',
    ('system', 'reset'):           lambda args: 'n64sys_reset()',
    ('system', 'tv_type'):         lambda args: 'sys_tv_type()',

    # n64.disk — 64DD disk drive
    ('disk', 'init'):              'disk_init',
    ('disk', 'close'):             'disk_close',
    ('disk', 'read_sector'):       'disk_read_sector',
    ('disk', 'write_sector'):      'disk_write_sector',
    ('disk', 'get_disk_type'):     'disk_get_disk_type',
    ('disk', 'is_present'):        'disk_is_present',

    # n64.rsp — RSP microcode / RSPQ command queue
    ('rsp', 'init'):               'rspq_init',
    ('rsp', 'close'):              'rspq_close',
    ('rsp', 'wait'):               'rspq_wait',
    ('rsp', 'syncpoint_new'):      'rspq_syncpoint_new',
    ('rsp', 'syncpoint_check'):    'rspq_syncpoint_check',
    ('rsp', 'block_begin'):        'rspq_block_begin',
    ('rsp', 'block_end'):          'rspq_block_end',
    ('rsp', 'block_run'):          'rspq_block_run',
    ('rsp', 'block_free'):         'rspq_block_free',

    # n64.rdpq.tex — Texture loading helpers
    ('rdpq_tex', 'upload'):        'rdpq_tex_upload',
    ('rdpq_tex', 'upload_sub'):    'rdpq_tex_upload_sub',
    ('rdpq_tex', 'multi_begin'):   'rdpq_tex_multi_begin',
    ('rdpq_tex', 'multi_end'):     'rdpq_tex_multi_end',

    # n64.rdpq.font — Font / text rendering
    ('rdpq_font', 'load'):         'rdpq_font_load',
    ('rdpq_font', 'free'):         'rdpq_font_free',
    ('rdpq_font', 'draw_text'):    'rdpq_text_print',
    ('rdpq_font', 'measure'):      'rdpq_text_measure',
    ('rdpq_font', 'register'):     'rdpq_font_register',

    # n64.rdpq.mode — Blending / combine modes
    ('rdpq_mode', 'push'):         'rdpq_mode_push',
    ('rdpq_mode', 'pop'):          'rdpq_mode_pop',
    ('rdpq_mode', 'standard'):     'rdpq_set_mode_standard',
    ('rdpq_mode', 'copy'):         'rdpq_set_mode_copy',
    ('rdpq_mode', 'zbuf'):         lambda args: f'rdpq_mode_zbuf(true, {args[0] if args else "true"})',
    ('rdpq_mode', 'blending'):     lambda args: f'rdpq_mode_blending({args[0] if args else "RDPQ_BLENDING_MULTIPLY"})',
    ('rdpq_mode', 'antialias'):    lambda args: f'rdpq_mode_antialias({args[0] if args else "AA_STANDARD"})',

    # n64.audio.mixer — Software mixer
    ('mixer', 'init'):             'mixer_init',
    ('mixer', 'close'):            'mixer_close',
    ('mixer', 'ch_play'):          'mixer_ch_play',
    ('mixer', 'ch_stop'):          'mixer_ch_stop',
    ('mixer', 'ch_set_vol'):       'mixer_ch_set_vol',
    ('mixer', 'ch_set_freq'):      'mixer_ch_set_freq',
    ('mixer', 'poll'):             'audio_poll',

    # n64.audio.xm — XM tracker music
    ('xm64', 'open'):              'xm64player_open',
    ('xm64', 'close'):             'xm64player_close',
    ('xm64', 'play'):              'xm64player_play',
    ('xm64', 'stop'):              'xm64player_stop',
    ('xm64', 'set_vol'):           'xm64player_set_vol',

    # n64.audio.wav — WAV sample playback
    ('wav64', 'open'):             'wav64_open',
    ('wav64', 'close'):            'wav64_close',
    ('wav64', 'play'):             'wav64_play',
    ('wav64', 'set_loop'):         'wav64_set_loop',

    # n64.surface — Off-screen surfaces / render targets
    ('surface', 'alloc'):          'surface_alloc',
    ('surface', 'free'):           'surface_free',
    ('surface', 'make_sub'):       'surface_make_sub',

    # n64.math — Fixed-point / vector math helpers
    ('math', 'abs_i32'):           lambda args: f'abs({args[0]})',
    ('math', 'min_i32'):           lambda args: f'MIN({args[0]}, {args[1]})',
    ('math', 'max_i32'):           lambda args: f'MAX({args[0]}, {args[1]})',
    ('math', 'clamp_i32'):         lambda args: f'CLAMP({args[0]}, {args[1]}, {args[2]})',
    ('math', 'sin_f'):             lambda args: f'sinf({args[0]})',
    ('math', 'cos_f'):             lambda args: f'cosf({args[0]})',
    ('math', 'sqrt_f'):            lambda args: f'sqrtf({args[0]})',
    ('math', 'atan2_f'):           lambda args: f'atan2f({args[0]}, {args[1]})',
    ('math', 'lerp_f'):            lambda args: f'({args[0]} + ({args[1]} - {args[0]}) * {args[2]})',
    ('math', 'fix_to_f'):          lambda args: f'((float)({args[0]}) / 65536.0f)',
    ('math', 'f_to_fix'):          lambda args: f'((int32_t)(({args[0]}) * 65536.0f))',
    # float scalar helpers
    ('math', 'abs_f'):             lambda args: f'fabsf({args[0]})',
    ('math', 'min_f'):             lambda args: f'fminf({args[0]}, {args[1]})',
    ('math', 'max_f'):             lambda args: f'fmaxf({args[0]}, {args[1]})',
    ('math', 'clamp_f'):           lambda args: f'fminf(fmaxf({args[0]}, {args[1]}), {args[2]})',
    ('math', 'floor_f'):           lambda args: f'floorf({args[0]})',
    ('math', 'ceil_f'):            lambda args: f'ceilf({args[0]})',
    ('math', 'pow_f'):             lambda args: f'powf({args[0]}, {args[1]})',
    ('math', 'tan_f'):             lambda args: f'tanf({args[0]})',
    # fixed-point (fix16.16) trig / sqrt — routed through libm, fix<->float at the edges
    ('math', 'fix_sin'):           lambda args: f'((int32_t)(sinf((float)({args[0]}) / 65536.0f) * 65536.0f))',
    ('math', 'fix_cos'):           lambda args: f'((int32_t)(cosf((float)({args[0]}) / 65536.0f) * 65536.0f))',
    ('math', 'fix_sqrt'):          lambda args: f'((int32_t)(sqrtf((float)({args[0]}) / 65536.0f) * 65536.0f))',
    # deterministic PRNG (xorshift32, see runtime/pak_rand.h)
    ('math', 'rand'):              lambda args: f'__pak_rand()',
    ('math', 'rand_seed'):         lambda args: f'__pak_srand({args[0]})',
    ('math', 'rand_range'):        lambda args: f'__pak_rand_range({args[0]}, {args[1]})',
    ('math', 'rand_f'):            lambda args: f'__pak_rand_f()',

    # n64.rdpq — full RDP command queue API
    ('rdpq', 'triangle'):            'rdpq_triangle',
    ('rdpq', 'texture_rectangle'):   'rdpq_texture_rectangle',
    ('rdpq', 'texture_rectangle_scaled'): 'rdpq_texture_rectangle_scaled',
    ('rdpq', 'set_blend_color'):     'rdpq_set_blend_color',
    ('rdpq', 'set_fog_color'):       'rdpq_set_fog_color',
    ('rdpq', 'set_fill_color'):      'rdpq_set_fill_color',
    ('rdpq', 'set_env_color'):       'rdpq_set_env_color',
    ('rdpq', 'set_prim_color'):      'rdpq_set_prim_color',
    ('rdpq', 'set_z_image'):         'rdpq_set_z_image',
    ('rdpq', 'set_color_image'):     'rdpq_set_color_image',
    ('rdpq', 'set_tile'):            'rdpq_set_tile',
    ('rdpq', 'set_tile_size'):       'rdpq_set_tile_size',
    ('rdpq', 'load_tile'):           'rdpq_load_tile',
    ('rdpq', 'load_tlut'):           'rdpq_load_tlut',
    ('rdpq', 'set_combiner_raw'):    'rdpq_set_combiner_raw',
    ('rdpq', 'set_other_modes_raw'): 'rdpq_set_other_modes_raw',
    ('rdpq', 'flush'):               'rspq_flush',
    ('rdpq', 'block_begin'):         'rdpq_block_begin',
    ('rdpq', 'block_end'):           'rdpq_block_end',
    ('rdpq', 'block_run'):           'rdpq_block_run',
    ('rdpq', 'block_free'):          'rdpq_block_free',
    ('rdpq', 'call'):                'rdpq_call',

    # n64.rdpq.mode — full mode API
    ('rdpq_mode', 'filter'):         lambda args: f'rdpq_mode_filter({args[0] if args else "FILTER_BILINEAR"})',
    ('rdpq_mode', 'dithering'):      lambda args: f'rdpq_mode_dithering({args[0] if args else "DITHER_SQUARE_SQUARE"})',
    ('rdpq_mode', 'persp_norm'):     lambda args: f'rdpq_mode_persp_norm({args[0] if args else "true"})',
    ('rdpq_mode', 'combiner'):       'rdpq_mode_combiner',
    ('rdpq_mode', 'tlut'):           lambda args: f'rdpq_mode_tlut({args[0] if args else "TLUT_RGBA16"})',

    # n64.joypad — granular joypad API
    ('joypad', 'init'):              'joypad_init',
    ('joypad', 'poll'):              'joypad_poll',
    ('joypad', 'get_status'):        'joypad_get_status',
    ('joypad', 'get_buttons'):       'joypad_get_buttons',
    ('joypad', 'get_buttons_pressed'):'joypad_get_buttons_pressed',
    ('joypad', 'get_buttons_released'):'joypad_get_buttons_released',
    ('joypad', 'get_axis_held'):     'joypad_get_axis_held',
    ('joypad', 'get_axis_pressed'):  'joypad_get_axis_pressed',
    ('joypad', 'get_accessory_type'):'joypad_get_accessory_type',
    ('joypad', 'is_connected'):      lambda args: f'(joypad_get_status({args[0] if args else "0"}).style != JOYPAD_STYLE_NONE)',

    # n64.vi — Video Interface registers and control
    ('vi', 'set_aa_mode'):           'vi_set_aa_mode',
    ('vi', 'set_dedither'):          'vi_set_dedither',
    ('vi', 'set_gamma'):             'vi_set_gamma',
    ('vi', 'set_divot'):             'vi_set_divot',
    ('vi', 'get_width'):             lambda args: 'display_get_width()',
    ('vi', 'get_height'):            lambda args: 'display_get_height()',
    ('vi', 'wait_vblank'):           lambda args: 'vi_wait_vblank()',

    # n64.mem — heap allocator
    ('mem', 'alloc'):                lambda args: f'malloc({args[0]})',
    ('mem', 'alloc_aligned'):        lambda args: f'memalign({args[1]}, {args[0]})',
    ('mem', 'free'):                 lambda args: f'free({args[0]})',
    ('mem', 'realloc'):              lambda args: f'realloc({args[0]}, {args[1]})',
    ('mem', 'zero'):                 lambda args: f'memset({args[0]}, 0, {args[1]})',
    ('mem', 'copy'):                 lambda args: f'memcpy({args[0]}, {args[1]}, {args[2]})',
    ('mem', 'move'):                 lambda args: f'memmove({args[0]}, {args[1]}, {args[2]})',

    # str module — PakStr helpers
    ('str', 'from_cstr'):            lambda args: f'pak_str_from_cstr({args[0]})',
    ('str', 'eq'):                   lambda args: f'pak_str_eq({args[0]}, {args[1]})',
    ('str', 'len'):                  lambda args: f'({args[0]}).len',
    ('str', 'data'):                 lambda args: f'({args[0]}).data',
    ('str', 'print'):                lambda args: f'debugf("%.*s", ({args[0]}).len, ({args[0]}).data)',
    # str.concat(a, b, buf, buf_size) → snprintf(buf, buf_size, "%.*s%.*s", ...)
    ('str', 'concat'):               lambda args: (
        f'(snprintf({args[2]}, (size_t)({args[3]}), "%.*s%.*s", '
        f'(int)({args[0]}).len, ({args[0]}).data, '
        f'(int)({args[1]}).len, ({args[1]}).data), '
        f'(PakStr){{.data={args[2]}, .len=(int32_t)strlen({args[2]})}})'
        if len(args) >= 4 else f'pak_str_from_cstr(({args[0]}).data)'),

    # arena module — PakArena helpers
    ('arena', 'alloc'):              lambda args: f'pak_arena_alloc({_addr(args,0)}, {args[1] if len(args)>1 else "0"})',
    ('arena', 'reset'):              lambda args: f'pak_arena_reset({_addr(args,0)})',

    # n64.audio — full audio API
    ('audio', 'get_frequency'):      'audio_get_frequency',
    ('audio', 'can_write'):          'audio_can_write',
    ('audio', 'write'):              'audio_write',
    ('audio', 'write_silence'):      'audio_write_silence',
    ('audio', 'set_buffer_num'):     'audio_set_buffer_num',

    # n64.debug — extended debug
    ('debug', 'print'):              'debugf',
    ('debug', 'init'):               'debug_init_isviewer',
    ('debug', 'init_usbfs'):         'debug_init_usbfs',
    ('debug', 'flush'):              'flush',

    # n64.exception — exception/fault handling
    ('exception', 'set_handler'):    'exception_set_handler',
    ('exception', 'get_handler'):    'exception_get_handler',

    # Aliases for nested module keys — allow `mixer.ch_play(...)` etc.
    ('mixer', 'init'):             'mixer_init',
    ('mixer', 'close'):            'mixer_close',
    ('mixer', 'ch_play'):          'mixer_ch_play',
    ('mixer', 'ch_stop'):          'mixer_ch_stop',
    ('mixer', 'ch_set_vol'):       'mixer_ch_set_vol',
    ('mixer', 'ch_set_freq'):      'mixer_ch_set_freq',
    ('mixer', 'poll'):             'audio_poll',

    ('xm64', 'open'):              'xm64player_open',
    ('xm64', 'close'):             'xm64player_close',
    ('xm64', 'play'):              'xm64player_play',
    ('xm64', 'stop'):              'xm64player_stop',
    ('xm64', 'set_vol'):           'xm64player_set_vol',

    ('wav64', 'open'):             'wav64_open',
    ('wav64', 'close'):            'wav64_close',
    ('wav64', 'play'):             'wav64_play',
    ('wav64', 'set_loop'):         'wav64_set_loop',

    ('rdpq_tex', 'upload'):        'rdpq_tex_upload',
    ('rdpq_tex', 'upload_sub'):    'rdpq_tex_upload_sub',
    ('rdpq_tex', 'multi_begin'):   'rdpq_tex_multi_begin',
    ('rdpq_tex', 'multi_end'):     'rdpq_tex_multi_end',

    ('rdpq_font', 'load'):         'rdpq_font_load',
    ('rdpq_font', 'free'):         'rdpq_font_free',
    ('rdpq_font', 'draw_text'):    'rdpq_text_print',
    ('rdpq_font', 'measure'):      'rdpq_text_measure',
    ('rdpq_font', 'register'):     'rdpq_font_register',

    ('rdpq_mode', 'push'):         'rdpq_mode_push',
    ('rdpq_mode', 'pop'):          'rdpq_mode_pop',
    ('rdpq_mode', 'standard'):     'rdpq_set_mode_standard',
    ('rdpq_mode', 'copy'):         'rdpq_set_mode_copy',
    ('rdpq_mode', 'zbuf'):         lambda args: f'rdpq_mode_zbuf(true, {args[0] if args else "true"})',
    ('rdpq_mode', 'blending'):     lambda args: f'rdpq_mode_blending({args[0] if args else "RDPQ_BLENDING_MULTIPLY"})',
    ('rdpq_mode', 'antialias'):    lambda args: f'rdpq_mode_antialias({args[0] if args else "AA_STANDARD"})',

    ('sram', 'read'):              'sram_read',
    ('sram', 'write'):             'sram_write',

    ('flashram', 'read'):          'flashram_read',
    ('flashram', 'write'):         'flashram_write',
    ('flashram', 'erase_sector'):  'flashram_erase_sector',

    ('eeprom', 'init'):            'eeprom_init',
    ('eeprom', 'read'):            'eeprom_read',
    ('eeprom', 'write'):           'eeprom_write',

    ('surface', 'alloc'):          'surface_alloc',
    ('surface', 'free'):           'surface_free',
    ('surface', 'make_sub'):       'surface_make_sub',

    ('rsp', 'init'):               'rspq_init',
    ('rsp', 'close'):              'rspq_close',
    ('rsp', 'wait'):               'rspq_wait',
    ('rsp', 'syncpoint_new'):      'rspq_syncpoint_new',
    ('rsp', 'syncpoint_check'):    'rspq_syncpoint_check',
    ('rsp', 'block_begin'):        'rspq_block_begin',
    ('rsp', 'block_end'):          'rspq_block_end',
    ('rsp', 'block_run'):          'rspq_block_run',
    ('rsp', 'block_free'):         'rspq_block_free',

    ('disk', 'init'):              'disk_init',
    ('disk', 'close'):             'disk_close',
    ('disk', 'read_sector'):       'disk_read_sector',
    ('disk', 'write_sector'):      'disk_write_sector',
    ('disk', 'get_disk_type'):     'disk_get_disk_type',
    ('disk', 'is_present'):        'disk_is_present',
}


# Canonical set of module namespaces that codegen can lower. This is the single
# source of truth for "which modules exist"; the checker and typechecker derive
# their module sets from this so the three can never drift apart.
MODULE_NAMES = {mod for (mod, _fn) in MODULE_API}


def _addr(args, i):
    """Return &args[i] if not already a pointer expression."""
    if i < len(args):
        a = args[i]
        if a.startswith('&') or a.startswith('*'):
            return a
        return f'&{a}'
    return 'NULL'


_FIXPOINT_SHIFTS = {'fix16.16': 16, 'fix10.5': 5, 'fix1.15': 15}

def _fixpoint_shift(typ) -> int:
    """Return the fractional bit count for a fixed-point type, or 0."""
    if isinstance(typ, ast.TypeName):
        return _FIXPOINT_SHIFTS.get(typ.name, 0)
    return 0


def _strip_parens(s: str) -> str:
    """Remove one layer of matching outer parentheses, if present.

    Used to avoid double-wrapping in if/while conditions:
    gen_expr for BinOp already returns '(a == b)'; the caller adds
    its own 'if (%s)' wrapper, which would produce 'if ((a == b))'.
    """
    if len(s) >= 2 and s[0] == '(' and s[-1] == ')':
        depth = 0
        for i, ch in enumerate(s):
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
            if depth == 0 and i < len(s) - 1:
                return s   # outer parens close before the end — don't strip
        return s[1:-1]
    return s


# ── Type mappings ─────────────────────────────────────────────────────────────

PRIMITIVE_TYPES = {
    'i8': 'int8_t',
    'i16': 'int16_t',
    'i32': 'int32_t',
    'i64': 'int64_t',
    'u8': 'uint8_t',
    'u16': 'uint16_t',
    'u32': 'uint32_t',
    'u64': 'uint64_t',
    'f32': 'float',
    'f64': 'double',
    'bool': 'bool',
    'byte': 'uint8_t',
    'fix16.16': 'int32_t',
    'fix10.5': 'int16_t',
    'fix1.15': 'int16_t',
    'Vec2': 'T3DVec2',
    'Vec3': 'T3DVec3',
    'Vec4': 'T3DVec4',
    'Mat4': 'T3DMat4',
    'Str': 'PakStr',
    'CStr': 'const char *',
    'c_char': 'char',
    'Arena': 'PakArena',
    'Allocator': 'Allocator',  # built-in allocator trait object
    'void': 'void',
}

USE_INCLUDES = {
    # Core display / rendering
    'n64.display':      '#include <display.h>',
    'n64.controller':   '#include <joypad.h>',
    'n64.rdpq':         '#include <rdpq.h>\n#include <rdpq_gfx.h>',
    'n64.sprite':       '#include <rdpq_sprite.h>',
    'n64.surface':      '#include <surface.h>',

    # Audio
    'n64.audio':        '#include <audio.h>\n#include <xm64.h>\n#include <wav64.h>',
    'n64.mixer':        '#include <audio.h>\n#include <mixer.h>',
    'n64.xm64':         '#include <xm64.h>',
    'n64.wav64':        '#include <wav64.h>',

    # System
    'n64.timer':        '#include <n64sys.h>',
    'n64.system':       '#include <n64sys.h>',
    'n64.dma':          '#include <dma.h>',
    'n64.cache':        '#include <n64sys.h>',
    'n64.debug':        '#include <debug.h>',
    'n64.math':         '#include <n64sys.h>\n#include <math.h>\n#include "pak_rand.h"',
    'n64.mem':          '#include <malloc.h>',
    'n64.rsp':          '#include <rspq.h>',

    # Save memory
    'n64.eeprom':       '#include <eeprom.h>',
    'n64.backup':       '#include <backup.h>',
    'n64.sram':         '#include <backup.h>',
    'n64.flashram':     '#include <backup.h>',

    # RDP texture / font / mode helpers
    'n64.rdpq_tex':     '#include <rdpq_tex.h>',
    'n64.rdpq_font':    '#include <rdpq_font.h>\n#include <rdpq_text.h>',
    'n64.rdpq_mode':    '#include <rdpq_mode.h>',

    # Accessories
    'n64.rumble':       '#include <joypad.h>\n#include <rumble.h>',
    'n64.cpak':         '#include <cpak.h>',
    'n64.tpak':         '#include <tpak.h>',
    'n64.mouse':        '#include <joypad.h>',
    'n64.vru':          '#include <vru.h>',
    'n64.rtc':          '#include <rtc.h>',

    # 64DD disk drive
    'n64.disk':         '#include <disk.h>',

    # Joypad (explicit)
    'n64.joypad':       '#include <joypad.h>',

    # VI control
    'n64.vi':           '#include <display.h>',

    # Memory / heap
    'n64.mem':          '#include <malloc.h>\n#include <string.h>',

    # String helpers (Pak runtime — no extra header, built into output)
    'pak.str':          '',
    'pak.arena':        '',

    # Exception handling
    'n64.exception':    '#include <exception.h>',

    # Tiny3D
    't3d.core':         '#include <t3d/t3d.h>',
    't3d.model':        '#include <t3d/t3dmodel.h>',
    't3d.math':         '#include <t3d/t3dmath.h>',
    't3d.anim':         '#include <t3d/t3danim.h>',
    't3d.light':        '#include <t3d/t3dlight.h>',
    't3d.viewport':     '#include <t3d/t3d.h>',
    't3d.skeleton':     '#include <t3d/t3dskeleton.h>',
    't3d.fog':          '#include <t3d/t3d.h>',
    't3d.state':        '#include <t3d/t3d.h>',
    't3d.particles':    '#include <t3d/t3d.h>',
}


class CodegenError(Exception):
    pass


class Codegen:
    def __init__(self, filename: str = '<unknown>', module_headers: dict = None):
        self.filename = filename
        self.indent = 0
        self.lines: List[str] = []
        self.includes: List[str] = []
        self.forward_decls: List[str] = []
        self.uses: List[str] = []
        self.assets: List[ast.AssetDecl] = []
        self.module_name: str = ''
        self.fn_names: List[str] = []
        self.enum_variants: dict = {}  # case_name → enum_or_variant_type_name
        self.variant_types: set = set()  # names of variant (tagged-union) types
        # struct_name → {field_name: type_node} — populated in gen_program pass 1
        self.struct_fields: dict = {}
        # Ordered list of (typedef_name, inner_c_type) for fat slices — deduped
        self._slice_typedefs: List[tuple] = []
        self._slice_typedef_names: set = set()
        # Container typedefs: (typedef_name, container_kind, elem_c_type, capacity_int)
        self._container_typedefs: List[tuple] = []
        self._container_typedef_names: set = set()
        # fmt string counter for unique buffer names
        self._fmt_counter: int = 0
        # Map of user module path → generated header filename (for cross-module includes)
        self.module_headers: dict = module_headers or {}
        # Scope stack: {name: type_node}
        self.scopes: List[dict] = [{}]
        # Defer stack: each entry is a list of DeferStmt nodes for the current block
        # Outer list = stack of scopes; inner list = defers in that scope (LIFO)
        self._defer_stack: List[List[ast.DeferStmt]] = [[]]
        # Method registry: type_name → {method_name: FnDecl}
        self.method_registry: dict = {}
        # Current function return type (for ok/err construction)
        self._current_ret_type = None
        # Result type typedefs: deduped list of (typedef_name, c_ok, c_err)
        self._result_typedefs: List[tuple] = []
        self._result_typedef_names: set = set()
        # Generic functions/structs registered for monomorphization
        self._generic_fns: dict = {}   # name → FnDecl
        self._generic_structs: dict = {}  # name → StructDecl
        # Monomorphization cache: (fn_name, tuple(type_args)) → specialized C name
        self._mono_cache: dict = {}
        # Closure registry: list of (c_name, Closure) — emitted as static fns
        self._closures: List[tuple] = []
        # Capturing closures hoisted as GCC nested functions inside the current
        # statement's enclosing block: list of (c_name, Closure). Flushed (and
        # emitted just before the using statement) by the gen_stmt wrapper.
        self._pending_nested: List[tuple] = []
        self._in_stmt: bool = False
        # Const values visible to all scopes (name → expr string)
        self.const_values: dict = {}
        # Trait declarations: name → TraitDecl
        self.trait_decls: dict = {}
        # Tuple typedefs: deduped list of (typedef_name, c_types_list)
        self._tuple_typedefs: List[tuple] = []
        self._tuple_typedef_names: set = set()
        # Vec typedefs (dynamic vector backed by malloc)
        self._vec_typedefs: List[tuple] = []
        self._vec_typedef_names: set = set()
        self._vec_used: bool = False
        self._allocator_used: bool = False

    # ── Scope helpers ─────────────────────────────────────────────────────────

    def scope_push(self):
        self.scopes.append({})
        self._defer_stack.append([])

    def scope_pop(self):
        self.scopes.pop()
        self._defer_stack.pop()

    def _defer_push(self, stmt: ast.DeferStmt):
        """Register a defer in the current scope."""
        self._defer_stack[-1].append(stmt)

    def _emit_defers_for_scope(self, scope_idx: int, pad: str, indent: int) -> List[str]:
        """Emit all defers for a given scope level in LIFO order."""
        lines = []
        for d in reversed(self._defer_stack[scope_idx]):
            if isinstance(d.body, ast.Block):
                for stmt in d.body.stmts:
                    s = self.gen_stmt(stmt, indent)
                    if s:
                        lines.append(s)
        return lines

    def _emit_all_defers(self, pad: str, indent: int) -> List[str]:
        """Emit ALL active defers (all scopes, innermost first). Used before return."""
        lines = []
        for scope_idx in range(len(self._defer_stack) - 1, -1, -1):
            lines.extend(self._emit_defers_for_scope(scope_idx, pad, indent))
        return lines

    def scope_set(self, name: str, typ):
        self.scopes[-1][name] = typ

    def scope_get(self, name: str):
        for s in reversed(self.scopes):
            if name in s:
                return s[name]
        return None

    def is_pointer(self, name: str) -> bool:
        t = self.scope_get(name)
        return isinstance(t, ast.TypePointer)

    def _expr_type(self, e):
        """Best-effort: return the type node for an expression."""
        if isinstance(e, ast.Ident):
            return self.scope_get(e.name)
        if isinstance(e, ast.DotAccess) and isinstance(e.obj, ast.Ident):
            obj_type = self.scope_get(e.obj.name)
            # Unwrap pointer to get the struct name
            struct_name = None
            if isinstance(obj_type, ast.TypeName):
                struct_name = obj_type.name
            elif isinstance(obj_type, ast.TypePointer) and isinstance(obj_type.inner, ast.TypeName):
                struct_name = obj_type.inner.name
            if struct_name and struct_name in self.struct_fields:
                return self.struct_fields[struct_name].get(e.field)
        return None

    def _container_kind(self, t):
        """Return the container kind name (Vec/FixedList/RingBuffer/FixedMap/Pool)
        if t is one of the built-in generic containers, else None."""
        if isinstance(t, ast.TypeGeneric) and t.name in (
                'Vec', 'FixedList', 'RingBuffer', 'FixedMap', 'Pool'):
            return t.name
        return None

    def _is_cstr_type(self, t) -> bool:
        """True if t is a C-string type (*c_char / *mut c_char)."""
        return (isinstance(t, ast.TypePointer)
                and isinstance(t.inner, ast.TypeName)
                and t.inner.name == 'c_char')

    def _match_type_name(self, expr) -> str:
        """Return the base type name of a match expression (for variant/enum detection)."""
        t = self._expr_type(expr)
        if isinstance(t, ast.TypeName):
            return t.name
        if isinstance(t, ast.TypePointer) and isinstance(t.inner, ast.TypeName):
            return t.inner.name
        return ''

    def emit(self, line: str = ''):
        if line:
            self.lines.append('    ' * self.indent + line)
        else:
            self.lines.append('')

    def emit_raw(self, line: str):
        self.lines.append(line)

    def inc(self):
        self.indent += 1

    def dec(self):
        self.indent -= 1

    def _slice_typedef(self, inner_type) -> str:
        """Return the C typedef name for a fat slice of inner_type.
        Registers the typedef for emission before the code body.
        """
        c_inner = self.gen_type(inner_type)
        # Sanitize inner type name for use in a C identifier
        safe = (c_inner.replace(' ', '_').replace('*', 'p')
                       .replace(',', '').replace('(', '').replace(')', ''))
        typedef_name = f'PakSlice_{safe}'
        if typedef_name not in self._slice_typedef_names:
            self._slice_typedef_names.add(typedef_name)
            self._slice_typedefs.append((typedef_name, c_inner))
        return typedef_name

    def _tuple_typedef(self, c_types: List[str]) -> str:
        """Register and return a C typedef name for a tuple type."""
        safe = '_'.join(
            ct.replace(' ', '_').replace('*', 'p').replace(',', '').replace('(', '').replace(')', '')
            for ct in c_types
        )
        typedef_name = f'PakTuple{len(c_types)}_{safe}'
        if typedef_name not in self._tuple_typedef_names:
            self._tuple_typedef_names.add(typedef_name)
            self._tuple_typedefs.append((typedef_name, list(c_types)))
        return typedef_name

    def _vec_typedef(self, elem_c_type: str) -> str:
        """Register and return a C typedef name for Vec(T)."""
        safe = elem_c_type.replace(' ', '_').replace('*', 'p').replace(',', '')
        typedef_name = f'_PakVec_{safe}'
        if typedef_name not in self._vec_typedef_names:
            self._vec_typedef_names.add(typedef_name)
            self._vec_typedefs.append((typedef_name, elem_c_type))
            self._vec_used = True
        return typedef_name

    def _emit_tuple_typedefs(self) -> List[str]:
        lines = []
        for typedef_name, c_types in self._tuple_typedefs:
            lines.append(f'typedef struct {{')
            for i, ct in enumerate(c_types):
                lines.append(f'    {ct} f{i};')
            lines.append(f'}} {typedef_name};')
        return lines

    def _emit_vec_typedefs(self) -> List[str]:
        lines = []
        for typedef_name, elem_c_type in self._vec_typedefs:
            lines.append(f'typedef struct {{')
            lines.append(f'    {elem_c_type} *data;')
            lines.append(f'    int32_t len;')
            lines.append(f'    int32_t cap;')
            lines.append(f'}} {typedef_name};')
        return lines

    def gen_type(self, t) -> str:
        if t is None:
            return 'void'
        if isinstance(t, ast.TypeTuple):
            c_types = [self.gen_type(elem) for elem in t.elements]
            return self._tuple_typedef(c_types)
        if isinstance(t, ast.TypeDynTrait):
            # Trait object struct is named after the trait
            return t.name
        if isinstance(t, ast.TypeVolatile):
            inner = self.gen_type(t.inner)
            # volatile T* vs volatile T — if inner ends with * it's a volatile pointer
            if inner.endswith(' *') or inner.endswith('*'):
                return f'volatile {inner}'
            return f'volatile {inner}'
        if isinstance(t, ast.TypeName):
            # User-defined structs/enums/variants shadow the primitive type table
            if t.name in self.struct_fields or t.name in self.variant_types or t.name in self.enum_variants.values():
                return t.name
            return PRIMITIVE_TYPES.get(t.name, t.name)
        if isinstance(t, ast.TypePointer):
            # *dyn Trait → just the trait-object struct (already a fat pointer)
            if isinstance(t.inner, ast.TypeDynTrait):
                return t.inner.name
            inner = self.gen_type(t.inner)
            return f'{inner} *'
        if isinstance(t, ast.TypeSlice):
            # Fat slice: struct { T *data; int32_t len; }
            return self._slice_typedef(t.inner)
        if isinstance(t, ast.TypeArray):
            inner = self.gen_type(t.inner)
            size = self.gen_expr(t.size)
            return f'{inner}[{size}]'
        if isinstance(t, ast.TypeResult):
            return self._result_typedef(t.ok, t.err)
        if isinstance(t, ast.TypeOption):
            return self.gen_type(t.inner) + ' *'
        if isinstance(t, ast.TypeFn):
            ret = self.gen_type(t.ret) if t.ret else 'void'
            params = ', '.join(self.gen_type(p) for p in t.params)
            return f'{ret} (*)({params})'
        if isinstance(t, ast.TypeGeneric):
            # Parameterized type: map List<T> → PakSlice_T, or Name_T for generics
            if t.name in ('List', 'Slice', 'Array') and len(t.args) == 1:
                return self._slice_typedef(t.args[0])
            # Built-in containers: FixedList(T, N), RingBuffer(T, N), FixedMap(K, V, N)
            if t.name in ('FixedList', 'RingBuffer', 'FixedMap', 'Pool'):
                return self._container_typedef(t)
            # Dynamic vector: Vec(T)
            if t.name == 'Vec' and t.args:
                elem_type = self.gen_type(t.args[0])
                return self._vec_typedef(elem_type)
            # Generic struct: Foo<i32, Str> → Foo_i32_Str
            c_args = '_'.join(
                (self.gen_expr(a) if isinstance(a, ast.IntLit) else
                 self.gen_type(a).replace(' ', '_').replace('*', 'p').replace(',', ''))
                for a in t.args
            )
            return f'{t.name}_{c_args}'
        if isinstance(t, ast.TypeParam):
            # Unresolved type parameter — treat as void * during unspecialized codegen
            return 'void *'
        return 'void *'

    def _result_typedef(self, ok_type, err_type) -> str:
        """Return (and register) the C typedef name for Result(ok, err)."""
        c_ok = self.gen_type(ok_type) if ok_type else 'void *'
        c_err = self.gen_type(err_type) if err_type else 'int32_t'
        safe_ok = c_ok.replace(' ', '_').replace('*', 'p')
        safe_err = c_err.replace(' ', '_').replace('*', 'p')
        typedef_name = f'PakResult_{safe_ok}_{safe_err}'
        if typedef_name not in self._result_typedef_names:
            self._result_typedef_names.add(typedef_name)
            self._result_typedefs.append((typedef_name, c_ok, c_err))
        return typedef_name

    def _container_typedef(self, t: ast.TypeGeneric) -> str:
        """Register and return a C typedef name for a FixedList/RingBuffer/FixedMap/Pool."""
        kind = t.name
        if kind == 'FixedMap':
            # FixedMap(K, V, N)
            k_type = self.gen_type(t.args[0]) if len(t.args) > 0 else 'int32_t'
            v_type = self.gen_type(t.args[1]) if len(t.args) > 1 else 'int32_t'
            cap = t.args[2].value if len(t.args) > 2 and isinstance(t.args[2], ast.IntLit) else 16
            safe_k = k_type.replace(' ', '_').replace('*', 'p')
            safe_v = v_type.replace(' ', '_').replace('*', 'p')
            tname = f'_PakMap_{safe_k}_{safe_v}_{cap}'
            if tname not in self._container_typedef_names:
                self._container_typedef_names.add(tname)
                self._container_typedefs.append((tname, 'FixedMap', k_type, v_type, cap))
        else:
            # FixedList(T, N) / RingBuffer(T, N) / Pool(T, N)
            elem_type = self.gen_type(t.args[0]) if t.args else 'int32_t'
            cap = t.args[1].value if len(t.args) > 1 and isinstance(t.args[1], ast.IntLit) else 16
            safe = elem_type.replace(' ', '_').replace('*', 'p')
            prefix = {'FixedList': '_PakList', 'RingBuffer': '_PakRBuf', 'Pool': '_PakPool'}.get(kind, '_PakList')
            tname = f'{prefix}_{safe}_{cap}'
            if tname not in self._container_typedef_names:
                self._container_typedef_names.add(tname)
                self._container_typedefs.append((tname, kind, elem_type, None, cap))
        return tname

    def _emit_container_typedefs(self) -> List[str]:
        """Emit C struct typedefs for all registered containers."""
        lines = []
        for entry in self._container_typedefs:
            tname = entry[0]
            kind = entry[1]
            if kind == 'FixedMap':
                _, _, k_type, v_type, cap = entry
                lines += [
                    f'typedef struct {{',
                    f'    {k_type} keys[{cap}];',
                    f'    {v_type} values[{cap}];',
                    f'    bool occupied[{cap}];',
                    f'    int32_t count;',
                    f'}} {tname};',
                ]
            elif kind == 'RingBuffer':
                _, _, elem_type, _, cap = entry
                lines += [
                    f'typedef struct {{',
                    f'    {elem_type} data[{cap}];',
                    f'    int32_t head, tail, count;',
                    f'}} {tname};',
                ]
            else:  # FixedList / Pool
                _, _, elem_type, _, cap = entry
                lines += [
                    f'typedef struct {{',
                    f'    {elem_type} data[{cap}];',
                    f'    int32_t len;',
                    f'}} {tname};',
                ]
            lines.append('')
        return lines

    def gen_array_decl(self, name: str, t) -> str:
        """Generate 'type name[size]' for array types."""
        if isinstance(t, ast.TypeArray):
            inner = self.gen_type(t.inner)
            size = self.gen_expr(t.size)
            return f'{inner} {name}[{size}]'
        return f'{self.gen_type(t)} {name}'

    def gen_expr(self, e) -> str:
        if e is None:
            return ''
        if isinstance(e, ast.IntLit):
            if e.raw:
                return e.raw
            return str(e.value)
        if isinstance(e, ast.FloatLit):
            return f'{e.value}f'
        if isinstance(e, ast.BoolLit):
            return 'true' if e.value else 'false'
        if isinstance(e, ast.StringLit):
            escaped = e.value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
            return f'"{escaped}"'
        if isinstance(e, ast.NoneLit):
            return 'NULL'
        if isinstance(e, ast.UndefinedLit):
            return '/* undefined */'
        if isinstance(e, ast.Ident):
            return e.name
        if isinstance(e, ast.DotAccess):
            obj_str = self.gen_expr(e.obj)
            if isinstance(e.obj, ast.Ident):
                n = e.obj.name
                # Enum type name access: Direction.up → Direction_up
                if n in self.enum_variants.values():
                    return f'{obj_str}_{e.field}'
                # Enum variant shortcut (field is a known variant)
                if e.field in self.enum_variants:
                    return f'{obj_str}_{e.field}'
                # Module namespace — not a variable, keep as-is (resolved in Call)
                if (n, e.field) in MODULE_API:
                    return f'{obj_str}.{e.field}'  # placeholder; Call handles it
                # Pointer variable: p.field → p->field
                if self.is_pointer(n):
                    return f'{obj_str}->{e.field}'
            # Chained access on a non-ident expression
            return f'{obj_str}.{e.field}'
        if isinstance(e, ast.IndexAccess):
            obj_str = self.gen_expr(e.obj)
            obj_type = self._expr_type(e.obj)
            idx_str = self.gen_expr(e.index)
            if isinstance(obj_type, ast.TypeSlice):
                return f'({obj_str}).data[{idx_str}]'
            # Container index: Vec/FixedList/Pool hold a `.data` array.
            if self._container_kind(obj_type) in ('Vec', 'FixedList', 'Pool'):
                return f'({obj_str}).data[{idx_str}]'
            return f'{obj_str}[{idx_str}]'
        if isinstance(e, ast.SliceExpr):
            obj_str = self.gen_expr(e.obj)
            start = self.gen_expr(e.start) if e.start else '0'
            obj_type = self._expr_type(e.obj)
            if e.end:
                end_str = self.gen_expr(e.end)
                length = f'({end_str}) - ({start})'
            elif isinstance(obj_type, ast.TypeArray) and isinstance(obj_type.size, ast.IntLit):
                # arr[start..] — use full array size minus start
                length = f'(int)(sizeof({obj_str})/sizeof(({obj_str})[0])) - ({start})'
            else:
                length = f'/* slice length unknown */ 0'
            # Determine inner type for the PakSlice typedef
            if isinstance(obj_type, ast.TypeArray):
                inner_type = obj_type.inner
            elif isinstance(obj_type, ast.TypeSlice):
                inner_type = obj_type.inner
            else:
                inner_type = ast.TypeName(name='auto')
            typedef_name = self._slice_typedef(inner_type)
            return f'({typedef_name}){{ .data = &({obj_str})[{start}], .len = {length} }}'
        if isinstance(e, ast.NamedArg):
            return self.gen_expr(e.value)
        if isinstance(e, ast.FmtStr):
            return self._gen_fmtstr(e)
        if isinstance(e, ast.AlignOf):
            op = e.operand
            if isinstance(op, (ast.TypeName, ast.TypePointer, ast.TypeArray,
                                ast.TypeSlice, ast.TypeResult, ast.TypeGeneric,
                                ast.TypeVolatile)):
                return f'__alignof__({self.gen_type(op)})'
            return f'__alignof__({self.gen_expr(op)})'
        if isinstance(e, ast.Call):
            args_strs = [self.gen_expr(a) for a in e.args]
            # comptime_assert(cond, msg) → _Static_assert(cond, msg)
            if isinstance(e.func, ast.Ident) and e.func.name == 'comptime_assert':
                cond = args_strs[0] if args_strs else 'true'
                msg = args_strs[1] if len(args_strs) > 1 else '"assertion"'
                return f'_Static_assert({cond}, {msg})'
            # heap_allocator() → pak_heap_allocator()
            if isinstance(e.func, ast.Ident) and e.func.name == 'heap_allocator':
                self._allocator_used = True
                return 'pak_heap_allocator()'
            # arena_allocator(arena_ptr) → Allocator_from_Arena(arena_ptr)
            if isinstance(e.func, ast.Ident) and e.func.name == 'arena_allocator':
                self._allocator_used = True
                arg = args_strs[0] if args_strs else '0'
                return f'Allocator_from_Arena({arg})'
            # Static type-method calls: Vec3.zero(), Mat4.identity(), Vec3.from(...) etc.
            if isinstance(e.func, ast.DotAccess) and isinstance(e.func.obj, ast.Ident):
                type_name = e.func.obj.name
                method = e.func.field
                result = self._gen_static_type_method(type_name, method, args_strs)
                if result is not None:
                    return result
            # Method call: obj.method(args) → TypeName_method(&obj, args)
            if isinstance(e.func, ast.DotAccess) and isinstance(e.func.obj, ast.Ident):
                obj_name = e.func.obj.name
                method_name = e.func.field
                obj_type = self.scope_get(obj_name)
                type_name = None
                if isinstance(obj_type, ast.TypeName):
                    type_name = obj_type.name
                elif isinstance(obj_type, ast.TypePointer) and isinstance(obj_type.inner, ast.TypeName):
                    type_name = obj_type.inner.name
                if type_name and type_name in self.method_registry:
                    if method_name in self.method_registry[type_name]:
                        fn_decl = self.method_registry[type_name][method_name]
                        # Determine how to pass self: pointer vs value
                        c_fn = f'{type_name}_{method_name}'
                        if fn_decl.params:
                            sp = fn_decl.params[0]
                            if isinstance(sp.type, ast.TypePointer):
                                # self: *T → pass &obj (or obj if already pointer)
                                if isinstance(obj_type, ast.TypePointer):
                                    self_arg = obj_name
                                else:
                                    self_arg = f'&{obj_name}'
                            else:
                                self_arg = obj_name
                        else:
                            self_arg = f'&{obj_name}'
                        all_args = [self_arg] + args_strs
                        return f'{c_fn}({", ".join(all_args)})'
            # Trait-object method dispatch: d.method(args) → d.vtable->method(d.self, args)
            if isinstance(e.func, ast.DotAccess) and isinstance(e.func.obj, ast.Ident):
                obj_name = e.func.obj.name
                method_name = e.func.field
                obj_type = self.scope_get(obj_name)
                trait_type_name = None
                if isinstance(obj_type, ast.TypeName) and obj_type.name in self.trait_decls:
                    trait_type_name = obj_type.name
                elif isinstance(obj_type, ast.TypeDynTrait):
                    trait_type_name = obj_type.name
                if trait_type_name:
                    vtable_args = [f'{obj_name}.self'] + args_strs
                    return f'({obj_name}.vtable->{method_name})({", ".join(vtable_args)})'

            # Built-in instance method dispatch (Vec3/Mat4/numeric/slice/container)
            if isinstance(e.func, ast.DotAccess):
                obj_expr = e.func.obj
                method = e.func.field
                obj_str = self.gen_expr(obj_expr)
                obj_type = self._expr_type(obj_expr)
                c_type = self.gen_type(obj_type) if obj_type else ''
                result = self._gen_builtin_method(obj_str, c_type, method, args_strs, obj_type)
                if result is not None:
                    return result
            # Module API call: module.function(args) → C API
            if isinstance(e.func, ast.DotAccess) and isinstance(e.func.obj, ast.Ident):
                mod = e.func.obj.name
                fn = e.func.field
                key = (mod, fn)
                if key in MODULE_API:
                    mapping = MODULE_API[key]
                    if callable(mapping):
                        return mapping(args_strs)
                    return f'{mapping}({", ".join(args_strs)})'
            # Generic call: foo::<T>(args) or inferred-generic foo(args)
            func_expr = e.func
            if isinstance(func_expr, ast.Ident):
                fn_name = func_expr.name
                if fn_name in self._generic_fns:
                    type_args = e.type_args
                    if not type_args:
                        # Infer type args from argument expressions
                        type_args = self._infer_type_args(self._generic_fns[fn_name], e.args)
                    if type_args:
                        specialized = self._monomorphize_fn(fn_name, type_args)
                        args = ', '.join(args_strs)
                        return f'{specialized}({args})'
            func = self.gen_expr(e.func)
            args = ', '.join(args_strs)
            return f'{func}({args})'
        if isinstance(e, ast.StructLit):
            fields = ', '.join(f'.{name} = {self.gen_expr(val)}' for name, val in e.fields)
            return f'({e.type_name}){{{fields}}}'
        if isinstance(e, ast.ArrayLit):
            if e.repeat is not None:
                val_expr = e.elements[0] if e.elements else ast.IntLit(value=0)
                val = self.gen_expr(val_expr)
                # If value is 0/false/NULL, use {0} (valid C zero-init)
                if val in ('0', 'false', 'NULL', '0.0f', '0.0'):
                    return '{0}'
                # For small constant repeat counts, expand inline
                if isinstance(e.repeat, ast.IntLit) and e.repeat.value <= 64:
                    elems = ', '.join([val] * e.repeat.value)
                    return f'{{{elems}}}'
                # Large or dynamic N: zero-init with a runtime fill note
                # The let/static statement handler emits the memset fill
                return '{0}'
            elements = ', '.join(self.gen_expr(el) for el in e.elements)
            return f'{{{elements}}}'
        if isinstance(e, ast.UnaryOp):
            if e.op == '!':
                return f'!{self.gen_expr(e.operand)}'
            return f'{e.op}{self.gen_expr(e.operand)}'
        if isinstance(e, ast.BinaryOp):
            left = self.gen_expr(e.left)
            right = self.gen_expr(e.right)
            # Fixed-point arithmetic: detect operand types from scope
            ltype = self._expr_type(e.left)
            rtype = self._expr_type(e.right)
            shift = _fixpoint_shift(ltype) or _fixpoint_shift(rtype)
            if shift and e.op == '*':
                # fix * fix → (int32_t)(((int64_t)(a) * (b)) >> shift)
                return f'(int32_t)(((int64_t)({left}) * ({right})) >> {shift})'
            if shift and e.op == '/':
                # fix / fix → (int32_t)(((int64_t)(a) << shift) / (b))
                return f'(int32_t)(((int64_t)({left}) << {shift}) / ({right}))'
            return f'({left} {e.op} {right})'
        if isinstance(e, ast.Assign):
            return f'{self.gen_expr(e.target)} {e.op} {self.gen_expr(e.value)}'
        if isinstance(e, ast.AddrOf):
            return f'&{self.gen_expr(e.expr)}'
        if isinstance(e, ast.Deref):
            return f'*{self.gen_expr(e.expr)}'
        if isinstance(e, ast.Cast):
            return f'({self.gen_type(e.type)}){self.gen_expr(e.expr)}'
        if isinstance(e, ast.RangeExpr):
            # Used in for loops - handled specially
            start = self.gen_expr(e.start)
            end = self.gen_expr(e.end) if e.end else ''
            return f'{start}..{end}'
        if isinstance(e, ast.EnumVariantAccess):
            # .variant → EnumName_variant if we know the enum
            if e.name in self.enum_variants:
                return f'{self.enum_variants[e.name]}_{e.name}'
            return e.name
        if isinstance(e, ast.CatchExpr):
            # CatchExpr requires multi-statement emit; only called inline as fallback.
            return self.gen_expr(e.expr)
        if isinstance(e, ast.NullCheck):
            return self.gen_expr(e.expr)
        if isinstance(e, ast.OkExpr):
            val = self.gen_expr(e.value)
            if self._current_ret_type is not None:
                rt = self.gen_type(self._current_ret_type)
            else:
                rt = 'PakResult'
            return f'({rt}){{ .is_ok = true, .data.value = {val} }}'
        if isinstance(e, ast.ErrExpr):
            val = self.gen_expr(e.value)
            if self._current_ret_type is not None:
                rt = self.gen_type(self._current_ret_type)
            else:
                rt = 'PakResult'
            return f'({rt}){{ .is_ok = false, .data.error = {val} }}'
        if isinstance(e, ast.SizeOf):
            operand = e.operand
            if isinstance(operand, (ast.TypeName, ast.TypePointer, ast.TypeArray,
                                    ast.TypeSlice, ast.TypeResult, ast.TypeGeneric,
                                    ast.TypeVolatile)):
                return f'sizeof({self.gen_type(operand)})'
            return f'sizeof({self.gen_expr(operand)})'
        if isinstance(e, ast.OffsetOf):
            return f'offsetof({e.type_name}, {e.field})'
        if isinstance(e, ast.AsmExpr):
            return self._gen_asm_expr(e)
        if isinstance(e, ast.Closure):
            return self._gen_closure(e)
        if isinstance(e, ast.TupleLit):
            return self._gen_tuple_lit(e)
        if isinstance(e, ast.TupleAccess):
            obj = self.gen_expr(e.obj)
            return f'({obj}).f{e.index}'
        if isinstance(e, ast.AllocExpr):
            c_type = self.gen_type(e.type_node)
            if e.allocator is not None:
                self._allocator_used = True
                alloc_c = self.gen_expr(e.allocator)
                if e.count is not None:
                    count = self.gen_expr(e.count)
                    return (f'({c_type} *)({alloc_c}).vtable->alloc_bytes('
                            f'({alloc_c}).self, sizeof({c_type}) * (size_t)({count}))')
                return (f'({c_type} *)({alloc_c}).vtable->alloc_bytes('
                        f'({alloc_c}).self, sizeof({c_type}))')
            if e.count is not None:
                count = self.gen_expr(e.count)
                return f'({c_type} *)malloc(sizeof({c_type}) * (size_t)({count}))'
            return f'({c_type} *)malloc(sizeof({c_type}))'
        if isinstance(e, ast.FreeExpr):
            ptr = self.gen_expr(e.ptr)
            if e.allocator is not None:
                self._allocator_used = True
                alloc_c = self.gen_expr(e.allocator)
                return f'({alloc_c}).vtable->dealloc_bytes(({alloc_c}).self, {ptr})'
            return f'free({ptr})'
        return '/* unknown expr */'

    def _gen_asm_expr(self, e: ast.AsmExpr) -> str:
        parts = [f'__asm__ {"__volatile__" if e.volatile else ""}("{e.template}"']
        if e.outputs or e.inputs or e.clobbers:
            outs = ', '.join(f'"{c}"({self.gen_expr(x)})' for c, x in e.outputs)
            ins  = ', '.join(f'"{c}"({self.gen_expr(x)})' for c, x in e.inputs)
            clob = ', '.join(f'"{c}"' for c in e.clobbers)
            parts.append(f' : {outs} : {ins}')
            if clob:
                parts.append(f' : {clob}')
        parts.append(')')
        return ''.join(parts)

    def _infer_c_type_for_tuple_elem(self, e) -> str:
        """Best-effort: return C type string for a tuple element expression."""
        t = self._expr_type(e)
        if t is not None:
            return self.gen_type(t)
        if isinstance(e, ast.IntLit):
            return 'int32_t'
        if isinstance(e, ast.FloatLit):
            return 'float'
        if isinstance(e, ast.BoolLit):
            return 'bool'
        if isinstance(e, ast.StringLit):
            return 'const char *'
        if isinstance(e, ast.TupleLit):
            inner = [self._infer_c_type_for_tuple_elem(el) for el in e.elements]
            return self._tuple_typedef(inner)
        return 'void *'

    def _gen_tuple_lit(self, e: ast.TupleLit) -> str:
        c_types = [self._infer_c_type_for_tuple_elem(el) for el in e.elements]
        typedef_name = self._tuple_typedef(c_types)
        fields = ', '.join(f'.f{i} = {self.gen_expr(el)}' for i, el in enumerate(e.elements))
        return f'({typedef_name}){{{fields}}}'

    def _gen_closure(self, e: ast.Closure) -> str:
        """Emit a closure as a function pointer.

        Inside a statement (function body), emit it as a GCC nested function in
        the enclosing block: it lexically captures any outer locals it uses and
        decays to a plain function pointer (trampoline), so no ABI change is
        needed. At top level (global/static initializers, no enclosing frame),
        fall back to a top-level static function (non-capturing).
        """
        if self._in_stmt:
            name = f'_pak_clo_{len(self._closures) + len(self._pending_nested)}'
            self._pending_nested.append((name, e))
            return name
        name = f'_pak_closure_{len(self._closures)}'
        self._closures.append((name, e))
        return name  # use function pointer directly (decays to fn ptr)

    def _emit_nested_closure(self, name: str, e: ast.Closure, indent: int) -> List[str]:
        """Emit a capturing closure as a GCC nested function at the given indent."""
        pad = '    ' * indent
        inner = '    ' * (indent + 1)
        ret = self.gen_type(e.ret_type) if e.ret_type else 'void'
        params = ', '.join(f'{self.gen_type(p.type)} {p.name}' for p in e.params)
        lines = [f'{pad}{ret} {name}({params or "void"}) {{']
        self.scope_push()
        for p in e.params:
            self.scope_set(p.name, p.type)
        for stmt in e.body.stmts:
            s = self.gen_stmt(stmt, indent + 1)
            if s:
                lines.append(s)
        self.scope_pop()
        lines.append(f'{pad}}}')
        return lines

    def _emit_closures(self) -> List[str]:
        """Emit all registered closures as static functions."""
        lines = []
        for name, e in self._closures:
            ret = self.gen_type(e.ret_type) if e.ret_type else 'void'
            params = ', '.join(f'{self.gen_type(p.type)} {p.name}' for p in e.params)
            lines.append(f'static {ret} {name}({params or "void"}) {{')
            self.scope_push()
            for p in e.params:
                self.scope_set(p.name, p.type)
            for stmt in e.body.stmts:
                s = self.gen_stmt(stmt, indent=1)
                if s:
                    lines.append(s)
            self.scope_pop()
            lines.append('}')
            lines.append('')
        return lines

    # ── Format string helper ──────────────────────────────────────────────────

    _FMT_SPEC = {
        'int8_t': '%d', 'int16_t': '%d', 'int32_t': '%ld', 'int64_t': '%lld',
        'uint8_t': '%u', 'uint16_t': '%u', 'uint32_t': '%lu', 'uint64_t': '%llu',
        'float': '%f', 'double': '%lf', 'bool': '%d',
        'PakStr': '%.*s',
    }

    def _fmt_spec_for_expr(self, expr) -> str:
        """Pick a printf format specifier for an interpolated expression."""
        t = self._expr_type(expr)
        if t:
            c = self.gen_type(t)
            spec = self._FMT_SPEC.get(c)
            if spec:
                return spec
            if c.endswith('*') or c == 'const char *':
                return '%s'
        # Fallback: treat as int
        return '%ld'

    def _fmt_arg_for_expr(self, expr, spec: str) -> str:
        """Wrap expression for printf (e.g., (long) cast for %ld)."""
        c = self.gen_expr(expr)
        if spec == '%ld':
            return f'(long)({c})'
        if spec == '%lld':
            return f'(long long)({c})'
        if spec in ('%lu', '%llu'):
            return f'(unsigned long)({c})'
        if spec == '%.*s':
            # PakStr: pass len then data
            return f'({c}).len, ({c}).data'
        return c

    def _gen_fmtstr(self, e: ast.FmtStr) -> str:
        """Emit a GCC statement expression that snprintf's into a static buffer."""
        fmt_parts = []
        arg_parts = []
        for part in e.parts:
            if isinstance(part, str):
                # Escape the literal part for C string
                escaped = part.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n')
                fmt_parts.append(escaped)
            else:
                spec = self._fmt_spec_for_expr(part)
                fmt_parts.append(spec)
                arg_parts.append(self._fmt_arg_for_expr(part, spec))
        fmt_str = ''.join(fmt_parts)
        n = self._fmt_counter
        self._fmt_counter += 1
        buf = f'_pak_fmt_{n}'
        args = (', ' + ', '.join(arg_parts)) if arg_parts else ''
        return (f'({{ static char {buf}[256];'
                f' snprintf({buf}, 256, "{fmt_str}"{args});'
                f' (const char*){buf}; }})')

    # ── Static type-method dispatch ───────────────────────────────────────────

    _VEC3_ZERO = '(T3DVec3){{0.0f, 0.0f, 0.0f}}'
    _VEC2_ZERO = '(T3DVec2){{0.0f, 0.0f}}'
    _VEC4_ZERO = '(T3DVec4){{0.0f, 0.0f, 0.0f, 0.0f}}'

    def _gen_static_type_method(self, type_name: str, method: str,
                                 args: List[str]) -> Optional[str]:
        """Handle Type.static_method() calls. Returns None if not handled."""
        # Vec3 / Vec2 / Vec4 statics
        if type_name in ('Vec3', 'T3DVec3'):
            if method == 'zero':    return self._VEC3_ZERO
            if method == 'up':      return '(T3DVec3){{0.0f, 1.0f, 0.0f}}'
            if method == 'right':   return '(T3DVec3){{1.0f, 0.0f, 0.0f}}'
            if method == 'forward': return '(T3DVec3){{0.0f, 0.0f, -1.0f}}'
            if method == 'one':     return '(T3DVec3){{1.0f, 1.0f, 1.0f}}'
            if method == 'from' and len(args) == 3:
                return f'(T3DVec3){{{{{args[0]}, {args[1]}, {args[2]}}}}}'
        if type_name in ('Vec2', 'T3DVec2'):
            if method == 'zero':  return self._VEC2_ZERO
            if method == 'one':   return '(T3DVec2){{1.0f, 1.0f}}'
        if type_name in ('Vec4', 'T3DVec4'):
            if method == 'zero':  return self._VEC4_ZERO
        # Mat4 statics
        if type_name in ('Mat4', 'T3DMat4'):
            if method == 'identity':
                return 'pak_mat4_identity()'
        # T3DMat4FP allocation (t3d.math.Mat4Fp.create())
        if type_name in ('Mat4Fp', 'T3DMat4FP'):
            if method == 'create':
                return 'malloc_uncached(sizeof(T3DMat4FP))'
        # FixedList / RingBuffer / FixedMap static init
        if type_name in ('FixedList', 'RingBuffer', 'FixedMap', 'Pool'):
            if method == 'init':
                return '{0}'
        return None

    # ── Built-in instance method dispatch ────────────────────────────────────

    _NUMERIC_CAST_METHODS = {
        'as_i8': 'int8_t', 'as_i16': 'int16_t', 'as_i32': 'int32_t', 'as_i64': 'int64_t',
        'as_u8': 'uint8_t', 'as_u16': 'uint16_t', 'as_u32': 'uint32_t', 'as_u64': 'uint64_t',
        'as_f32': 'float', 'as_f64': 'double', 'as_bool': 'bool',
        'as_byte': 'uint8_t',
    }
    _FIXPOINT_CAST = {
        'as_fix16_16': '(int32_t)(({val}) * 65536.0f)',
        'as_fix10_5':  '(int16_t)(({val}) * 32.0f)',
        'as_fix1_15':  '(int16_t)(({val}) * 32768.0f)',
    }
    _VEC3_INSTANCE = {
        'add':        'pak_vec3_add({obj}, {a0})',
        'sub':        'pak_vec3_sub({obj}, {a0})',
        'scale':      'pak_vec3_scale({obj}, {a0})',
        'normalize':  'pak_vec3_normalize({obj})',
        'length':     'pak_vec3_length({obj})',
        'dot':        'pak_vec3_dot({obj}, {a0})',
        'cross':      'pak_vec3_cross({obj}, {a0})',
        'distance_to':'pak_vec3_distance({obj}, {a0})',
        'direction_to':'pak_vec3_direction({obj}, {a0})',
        'negate':     'pak_vec3_scale({obj}, -1.0f)',
    }
    _VEC2_INSTANCE = {
        'add':      'pak_vec2_add({obj}, {a0})',
        'sub':      'pak_vec2_sub({obj}, {a0})',
        'scale':    'pak_vec2_scale({obj}, {a0})',
        'length':   'pak_vec2_length({obj})',
    }
    _MAT4_INSTANCE = {
        'rotate_y':     'pak_mat4_rotate_y(&({obj}), {a0})',
        'rotate_x':     'pak_mat4_rotate_x(&({obj}), {a0})',
        'rotate_z':     'pak_mat4_rotate_z(&({obj}), {a0})',
        'set_position': 'pak_mat4_set_position(&({obj}), {a0})',
        'translate':    'pak_mat4_translate(&({obj}), {a0}, {a1}, {a2})',
        'scale':        'pak_mat4_scale_uniform(&({obj}), {a0})',
        'to_fixed':     't3d_mat4_to_fixed({a0}, &({obj}))',
        'as_t3d':       'pak_mat4_to_fp_alloc(&({obj}))',
        'identity':     't3d_mat4_identity(&({obj}))',
    }

    # Vec3/Mat4 C type aliases that count as Vec3/Mat4
    _VEC3_CTYPES = {'T3DVec3', 'T3DVec3 *'}
    _VEC2_CTYPES = {'T3DVec2', 'T3DVec2 *'}
    _MAT4_CTYPES = {'T3DMat4', 'T3DMat4 *'}

    # Known Vec3 method names: if receiver type is unknown but method is a known
    # Vec3 method, still dispatch (handles chained calls like pos.add(v).normalize())
    _KNOWN_VEC3_METHODS = set(_VEC3_INSTANCE.keys())

    def _gen_builtin_method(self, obj: str, c_type: str, method: str,
                             args: List[str], obj_type) -> Optional[str]:
        """Dispatch built-in method calls. Returns None if not handled."""
        a = args  # shorthand

        # ── Numeric cast methods ──────────────────────────────────────────────
        if method in self._NUMERIC_CAST_METHODS:
            ct = self._NUMERIC_CAST_METHODS[method]
            return f'({ct})({obj})'
        if method in self._FIXPOINT_CAST:
            tmpl = self._FIXPOINT_CAST[method]
            return tmpl.replace('{val}', obj)

        # ── Fixed-point integer/fraction extraction ───────────────────────────
        if method == 'integer':
            return f'(int32_t)(({obj}) >> 16)'   # assumes fix16.16
        if method == 'fraction':
            return f'((float)(({obj}) & 0xFFFF) / 65536.0f)'

        # ── .clamp(min, max) on any numeric ──────────────────────────────────
        if method == 'clamp' and len(a) == 2:
            return f'(({obj}) < ({a[0]}) ? ({a[0]}) : ({obj}) > ({a[1]}) ? ({a[1]}) : ({obj}))'

        # ── Slice / array methods ─────────────────────────────────────────────
        if method in ('as_slice', 'as_slice_mut'):
            # Works for arrays: arr.as_slice()
            if isinstance(obj_type, ast.TypeArray):
                inner_t = obj_type.inner
                td = self._slice_typedef(inner_t)
                size = self.gen_expr(obj_type.size)
                return f'({td}){{.data = ({obj}), .len = (int32_t)({size})}}'
            # Fallback for any array-like
            return f'({{ __auto_type _arr = &({obj})[0]; (void*)_arr; }})'
        if method == 'get_unchecked' and len(a) == 1:
            if isinstance(obj_type, ast.TypeSlice):
                return f'({obj}).data[{a[0]}]'
            return f'({obj})[{a[0]}]'
        # .len as field is handled by dot-access; .len() as method:
        if method == 'len' and not a:
            if isinstance(obj_type, ast.TypeSlice):
                return f'({obj}).len'
            if isinstance(obj_type, ast.TypeArray):
                return f'(int32_t)(sizeof({obj})/sizeof(({obj})[0]))'
            return f'({obj}).len'

        # ── Free on T3DMat4FP* (mat_fp.free()) ───────────────────────────────
        if method == 'free' and not a:
            if c_type in ('T3DMat4FP *', 'T3DMat4FP*'):
                return f'free_uncached({obj})'
            if c_type in ('T3DModel *', 'T3DModel*'):
                return f't3d_model_free({obj})'

        # ── Vec3 instance methods ─────────────────────────────────────────────
        if c_type in self._VEC3_CTYPES or method in self._KNOWN_VEC3_METHODS:
            if method in self._VEC3_INSTANCE:
                tmpl = self._VEC3_INSTANCE[method]
                a0 = a[0] if a else '0'
                a1 = a[1] if len(a) > 1 else '0'
                a2 = a[2] if len(a) > 2 else '0'
                return tmpl.format(obj=obj, a0=a0, a1=a1, a2=a2)

        # ── Vec2 instance methods ─────────────────────────────────────────────
        if c_type in self._VEC2_CTYPES:
            if method in self._VEC2_INSTANCE:
                tmpl = self._VEC2_INSTANCE[method]
                a0 = a[0] if a else '0'
                return tmpl.format(obj=obj, a0=a0)

        # ── Mat4 instance methods ─────────────────────────────────────────────
        if c_type in self._MAT4_CTYPES:
            if method in self._MAT4_INSTANCE:
                tmpl = self._MAT4_INSTANCE[method]
                a0 = a[0] if a else '0'
                a1 = a[1] if len(a) > 1 else '0'
                a2 = a[2] if len(a) > 2 else '0'
                return tmpl.format(obj=obj, a0=a0, a1=a1, a2=a2)

        # ── FixedList / Pool instance methods ─────────────────────────────────
        if isinstance(obj_type, ast.TypeGeneric) and obj_type.name in ('FixedList', 'Pool'):
            cap = obj_type.args[1].value if len(obj_type.args) > 1 else 0
            if method == 'init':
                return f'memset(&({obj}), 0, sizeof({obj}))'
            if method == 'push' and a:
                return (f'(({obj}).len < {cap} ? '
                        f'(({obj}).data[({obj}).len++] = ({a[0]}), 1) : 0)')
            if method == 'pop':
                return f'({obj}).data[--({obj}).len]'
            if method == 'remove' and a:
                idx = a[0]
                return (f'({{ int32_t _ri = ({idx}); '
                        f'({obj}).data[_ri] = ({obj}).data[--({obj}).len]; }})')
            if method in ('items', 'slice'):
                elem_t = obj_type.args[0] if obj_type.args else ast.TypeName(name='auto')
                td = self._slice_typedef(elem_t)
                return f'({td}){{.data = ({obj}).data, .len = ({obj}).len}}'
            if method == 'len' and not a:
                return f'({obj}).len'
            if method in ('acquire',):    # Pool-specific
                return f'pak_pool_acquire(&({obj}))'
            if method in ('release',) and a:
                return f'pak_pool_release(&({obj}), {a[0]})'

        # ── RingBuffer instance methods ───────────────────────────────────────
        if isinstance(obj_type, ast.TypeGeneric) and obj_type.name == 'RingBuffer':
            cap = obj_type.args[1].value if len(obj_type.args) > 1 else 0
            if method == 'init':
                return f'memset(&({obj}), 0, sizeof({obj}))'
            if method == 'push' and a:
                return (f'({{ ({obj}).data[({obj}).tail] = ({a[0]}); '
                        f'({obj}).tail = (({obj}).tail + 1) % {cap}; '
                        f'if (({obj}).count < {cap}) ({obj}).count++; }})')
            if method == 'peek_back' and a:
                return (f'({obj}).data[(({obj}).tail - ({a[0]}) - 1 + {cap}) % {cap}]')
            if method == 'pop':
                return (f'({{ __auto_type _v = ({obj}).data[({obj}).head]; '
                        f'({obj}).head = (({obj}).head + 1) % {cap}; '
                        f'if (({obj}).count > 0) ({obj}).count--; _v; }})')
            if method == 'len' and not a:
                return f'({obj}).count'

        # ── FixedMap instance methods ─────────────────────────────────────────
        if isinstance(obj_type, ast.TypeGeneric) and obj_type.name == 'FixedMap':
            cap = obj_type.args[2].value if len(obj_type.args) > 2 else 0
            # String keys (*c_char) compare by content (strcmp); others memcmp.
            ksuf = '_str' if (len(obj_type.args) > 0 and self._is_cstr_type(obj_type.args[0])) else ''
            if method == 'init':
                return f'memset(&({obj}), 0, sizeof({obj}))'
            if method == 'set' and len(a) == 2:
                return (f'pak_map_set{ksuf}(&({obj}), {cap}, {a[0]}, {a[1]})')
            if method == 'get' and a:
                return f'pak_map_get{ksuf}(&({obj}), {cap}, {a[0]})'
            if method in ('has', 'contains') and a:
                return f'pak_map_has{ksuf}(&({obj}), {cap}, {a[0]})'
            if method == 'remove' and a:
                return f'pak_map_remove{ksuf}(&({obj}), {cap}, {a[0]})'
            if method in ('len', 'count') and not a:
                return f'({obj}).count'

        # ── Vec(T) dynamic vector methods ─────────────────────────────────────
        if isinstance(obj_type, ast.TypeGeneric) and obj_type.name == 'Vec':
            self._vec_used = True
            if method == 'init':
                return f'memset(&({obj}), 0, sizeof({obj}))'
            if method == 'push' and a:
                return (f'_PAK_VEC_PUSH(&({obj}), ({a[0]}))')
            if method == 'pop':
                return (f'(({obj}).len > 0 ? ({obj}).data[--({obj}).len] : ({obj}).data[0])')
            if method == 'get' and a:
                return f'({obj}).data[{a[0]}]'
            if method == 'len' and not a:
                return f'({obj}).len'
            if method == 'is_empty' and not a:
                return f'(({obj}).len == 0)'
            if method == 'clear' and not a:
                return f'(({obj}).len = 0)'
            if method == 'reserve' and a:
                elem_type = self.gen_type(obj_type.args[0]) if obj_type.args else 'void *'
                return (f'(({obj}).cap < ({a[0]}) ? '
                        f'(({obj}).data = ({elem_type} *)realloc(({obj}).data, '
                        f'(size_t)({a[0]}) * sizeof(*({obj}).data)), '
                        f'({obj}).cap = ({a[0]}), (void)0) : (void)0)')
            if method == 'free' and not a:
                return (f'({{ free(({obj}).data); ({obj}).data = NULL; '
                        f'({obj}).len = ({obj}).cap = 0; }})')

        # ── CStr / Str / PakStr string methods ───────────────────────────────
        is_cstr = c_type in ('const char *', 'char *') or (
            isinstance(obj_type, ast.TypeName) and obj_type.name in ('CStr', 'c_char'))
        is_pakstr = c_type == 'PakStr' or (
            isinstance(obj_type, ast.TypeName) and obj_type.name in ('Str', 'PakStr'))

        if is_cstr:
            if method == 'len' and not a:
                return f'(int32_t)strlen({obj})'
            if method == 'contains' and len(a) == 1:
                return f'(strstr({obj}, {a[0]}) != NULL)'
            if method == 'starts_with' and len(a) == 1:
                return f'(strncmp({obj}, {a[0]}, strlen({a[0]})) == 0)'
            if method == 'ends_with' and len(a) == 1:
                return (f'(strlen({obj}) >= strlen({a[0]}) && '
                        f'strcmp(({obj}) + strlen({obj}) - strlen({a[0]}), {a[0]}) == 0)')
            if method == 'eq' and len(a) == 1:
                return f'(strcmp({obj}, {a[0]}) == 0)'
            if method == 'cmp' and len(a) == 1:
                return f'strcmp({obj}, {a[0]})'
            if method == 'is_empty' and not a:
                return f'(({obj})[0] == \'\\0\')'
            if method == 'as_bytes' and not a:
                return f'(const uint8_t *)({obj})'
            if method == 'to_pakstr' and not a:
                return f'pak_str_from_cstr({obj})'
            # find(needle) → byte offset of first occurrence, or -1
            if method == 'find' and len(a) == 1:
                return (f'({{ const char *_h = strstr({obj}, {a[0]}); '
                        f'_h ? (int32_t)(_h - ({obj})) : -1; }})')
            # slice(start) → pointer into string at offset
            if method == 'slice' and len(a) == 1:
                return f'(({obj}) + ({a[0]}))'
            # slice(start, len) → PakStr fat-slice
            if method == 'slice' and len(a) == 2:
                return f'(PakStr){{.data = ({obj}) + ({a[0]}), .len = ({a[1]})}}'
            # copy_to(buf, buf_size) → strncpy null-terminated into buf
            if method == 'copy_to' and len(a) == 2:
                return f'(snprintf({a[0]}, (size_t)({a[1]}), "%s", {obj}), {a[0]})'
            # concat_into(buf, buf_size, other) → append other to buf
            if method == 'concat_into' and len(a) == 3:
                return (f'(snprintf({a[0]}, (size_t)({a[1]}), "%s%s", {obj}, {a[2]}), {a[0]})')
            # format_into(buf, buf_size, fmt, ...) → snprintf
            if method == 'format_into' and len(a) >= 2:
                rest = ', '.join(a[2:])
                fmt_arg = f', {rest}' if rest else ''
                return f'snprintf({a[0]}, (size_t)({a[1]}), {obj}{fmt_arg})'

        if is_pakstr:
            if method == 'len' and not a:
                return f'({obj}).len'
            if method == 'data' and not a:
                return f'({obj}).data'
            if method == 'eq' and len(a) == 1:
                return f'pak_str_eq({obj}, {a[0]})'
            if method == 'is_empty' and not a:
                return f'(({obj}).len == 0)'
            if method == 'as_cstr' and not a:
                return f'({obj}).data'
            if method == 'contains' and len(a) == 1:
                return (f'(memmem(({obj}).data, (size_t)({obj}).len, '
                        f'({a[0]}).data, (size_t)({a[0]}).len) != NULL)')
            # find(needle: PakStr) → byte offset or -1
            if method == 'find' and len(a) == 1:
                return (f'({{ const void *_h = memmem(({obj}).data, (size_t)({obj}).len, '
                        f'({a[0]}).data, (size_t)({a[0]}).len); '
                        f'_h ? (int32_t)((const char *)_h - ({obj}).data) : -1; }})')
            # slice(start, len) → PakStr sub-slice
            if method == 'slice' and len(a) == 2:
                return f'(PakStr){{.data = ({obj}).data + ({a[0]}), .len = ({a[1]})}}'
            # starts_with(prefix: PakStr)
            if method == 'starts_with' and len(a) == 1:
                return (f'(({obj}).len >= ({a[0]}).len && '
                        f'memcmp(({obj}).data, ({a[0]}).data, (size_t)({a[0]}).len) == 0)')
            # ends_with(suffix: PakStr)
            if method == 'ends_with' and len(a) == 1:
                return (f'(({obj}).len >= ({a[0]}).len && '
                        f'memcmp(({obj}).data + ({obj}).len - ({a[0]}).len, '
                        f'({a[0]}).data, (size_t)({a[0]}).len) == 0)')
            # copy_to(buf, buf_size) → copy data into a mutable buffer, null-terminated
            if method == 'copy_to' and len(a) == 2:
                return (f'(snprintf({a[0]}, (size_t)({a[1]}), "%.*s", '
                        f'(int)({obj}).len, ({obj}).data), {a[0]})')

        return None

    def gen_program(self, program: ast.Program) -> str:
        # First pass: collect uses, assets, fn names, enum/variant info, methods
        for decl in program.decls:
            if isinstance(decl, ast.UseDecl):
                self.uses.append(decl.path)
            elif isinstance(decl, ast.AssetDecl):
                self.assets.append(decl)
            elif isinstance(decl, ast.ModuleDecl):
                self.module_name = decl.path
            elif isinstance(decl, ast.FnDecl):
                self.fn_names.append(decl.name)
                if decl.type_params:
                    self._generic_fns[decl.name] = decl
                if decl.is_method and decl.self_type:
                    tname = decl.self_type
                    if tname not in self.method_registry:
                        self.method_registry[tname] = {}
                    self.method_registry[tname][decl.name] = decl
            elif isinstance(decl, (ast.StructDecl, ast.UnionDecl)):
                self.struct_fields[decl.name] = {f.name: f.type for f in decl.fields}
                if isinstance(decl, ast.StructDecl) and decl.type_params:
                    self._generic_structs[decl.name] = decl
            elif isinstance(decl, ast.EnumDecl):
                for v in decl.variants:
                    self.enum_variants[v.name] = decl.name
            elif isinstance(decl, ast.VariantDecl):
                self.variant_types.add(decl.name)
                for c in decl.cases:
                    self.enum_variants[c.name] = decl.name
            elif isinstance(decl, ast.ImplBlock):
                tname = decl.type_name
                if tname not in self.method_registry:
                    self.method_registry[tname] = {}
                for m in decl.methods:
                    self.method_registry[tname][m.name] = m
            elif isinstance(decl, ast.TraitDecl):
                self.trait_decls[decl.name] = decl
            elif isinstance(decl, ast.ImplTraitBlock):
                tname = decl.type_name
                if tname not in self.method_registry:
                    self.method_registry[tname] = {}
                for m in decl.methods:
                    self.method_registry[tname][m.name] = m
            elif isinstance(decl, ast.CfgBlock):
                # Collect info from the wrapped declaration too
                inner = decl.decl
                if isinstance(inner, ast.StructDecl):
                    self.struct_fields[inner.name] = {f.name: f.type for f in inner.fields}
                elif isinstance(inner, ast.EnumDecl):
                    for v in inner.variants:
                        self.enum_variants[v.name] = inner.name
                elif isinstance(inner, ast.VariantDecl):
                    self.variant_types.add(inner.name)
                    for c in inner.cases:
                        self.enum_variants[c.name] = inner.name
                elif isinstance(inner, ast.FnDecl):
                    self.fn_names.append(inner.name)
            elif isinstance(decl, ast.ConstDecl):
                # Pre-evaluate constant value string for use in type expressions
                self.const_values[decl.name] = self.gen_expr(decl.value)

        # Build output
        out_lines = []
        out_lines.append(f'/* Generated by Pak Compiler - {self.filename} */')
        out_lines.append('')

        # Standard includes
        out_lines.append('#include <libdragon.h>')
        out_lines.append('#include <stdint.h>')
        out_lines.append('#include <stdbool.h>')
        out_lines.append('#include <string.h>')
        out_lines.append('#include <math.h>')
        out_lines.append('#include "pak_math.h"')
        out_lines.append('#include "pak_containers.h"')

        # Module-based includes
        seen_includes = set()
        for use_path in self.uses:
            inc = USE_INCLUDES.get(use_path)
            if inc and inc not in seen_includes:
                out_lines.append(inc)
                seen_includes.add(inc)
            elif not inc and use_path in self.module_headers:
                # User-defined module — include its generated header
                header_line = f'#include "{self.module_headers[use_path]}"'
                if header_line not in seen_includes:
                    out_lines.append(header_line)
                    seen_includes.add(header_line)

        # PakFS header if assets are present
        if self.assets:
            out_lines.append('#include <pakfs.h>')

        # Timer helper if n64.timer is used
        if 'n64.timer' in self.uses:
            out_lines.append('')
            out_lines.append('static uint32_t _pak_last_tick = 0;')
            out_lines.append('static inline float _pak_delta_time(void) {')
            out_lines.append('    uint32_t now = TICKS_READ();')
            out_lines.append('    float dt = (float)TIMER_MICROS(now - _pak_last_tick) / 1000000.0f;')
            out_lines.append('    _pak_last_tick = now;')
            out_lines.append('    return dt;')
            out_lines.append('}')

        out_lines.append('')

        # Asset declarations
        for asset in self.assets:
            out_lines.append(f'/* asset: {asset.name} from "{asset.path}" */')
            out_lines.append(f'static const char *{asset.name}_path = "pak:/{asset.path}";')
        if self.assets:
            out_lines.append('')

        # Generate declarations — this populates _slice_typedefs as a side effect
        body_lines = []
        has_entry = False
        for decl in program.decls:
            if isinstance(decl, (ast.UseDecl, ast.AssetDecl, ast.ModuleDecl)):
                continue
            result = self.gen_decl(decl)
            if result:
                body_lines.append(result)
                body_lines.append('')
            if isinstance(decl, ast.EntryBlock):
                has_entry = True

        # Core Pak runtime types — always emitted
        out_lines.append('')
        out_lines.append('/* -- Pak runtime types -- */')
        out_lines.append('typedef struct { const char *data; int32_t len; } PakStr;')
        out_lines.append('typedef struct { uint8_t *base; uint8_t *ptr; size_t capacity; } PakArena;')
        out_lines.append('static inline PakStr pak_str_from_cstr(const char *s) {')
        out_lines.append('    return (PakStr){ .data = s, .len = (int32_t)strlen(s) }; }')
        out_lines.append('static inline bool pak_str_eq(PakStr a, PakStr b) {')
        out_lines.append('    return a.len == b.len && memcmp(a.data, b.data, (size_t)a.len) == 0; }')
        out_lines.append('static inline void *pak_arena_alloc(PakArena *a, size_t sz) {')
        out_lines.append('    sz = (sz + 7) & ~(size_t)7;  /* 8-byte align */')
        out_lines.append('    if (a->ptr + sz > a->base + a->capacity) return NULL;')
        out_lines.append('    void *p = a->ptr; a->ptr += sz; return p; }')
        out_lines.append('static inline void pak_arena_reset(PakArena *a) { a->ptr = a->base; }')
        if self._allocator_used:
            out_lines.append('')
            out_lines.append('/* -- Allocator trait (vtable-based custom allocator interface) -- */')
            out_lines.append('typedef struct { void *(*alloc_bytes)(void *, size_t); void (*dealloc_bytes)(void *, void *); } Allocator_vtable;')
            out_lines.append('typedef struct { void *self; const Allocator_vtable *vtable; } Allocator;')
            out_lines.append('/* PakArena as Allocator */')
            out_lines.append('static void *_pak_alloc_bytes_Arena(void *_s, size_t sz) { return pak_arena_alloc((PakArena *)_s, sz); }')
            out_lines.append('static void _pak_dealloc_bytes_Arena(void *_s, void *p) { (void)_s; (void)p; }')
            out_lines.append('static const Allocator_vtable _pak_vtable_Arena = { _pak_alloc_bytes_Arena, _pak_dealloc_bytes_Arena };')
            out_lines.append('static inline Allocator Allocator_from_Arena(PakArena *p) { return (Allocator){ .self=(void *)p, .vtable=&_pak_vtable_Arena }; }')
            out_lines.append('/* Heap (malloc/free) as Allocator */')
            out_lines.append('static void *_pak_alloc_bytes_Heap(void *_s, size_t sz) { (void)_s; return malloc(sz); }')
            out_lines.append('static void _pak_dealloc_bytes_Heap(void *_s, void *p) { (void)_s; free(p); }')
            out_lines.append('static const Allocator_vtable _pak_vtable_Heap = { _pak_alloc_bytes_Heap, _pak_dealloc_bytes_Heap };')
            out_lines.append('static inline Allocator pak_heap_allocator(void) { return (Allocator){ .self=NULL, .vtable=&_pak_vtable_Heap }; }')

        # Fat-slice typedefs (emitted after includes so inner types are visible,
        # and after body generation so all slices have been encountered)
        if self._slice_typedefs:
            out_lines.append('')
            for typedef_name, c_inner in self._slice_typedefs:
                out_lines.append(f'typedef struct {{ {c_inner} *data; int32_t len; }} {typedef_name};')

        # Tuple typedefs
        if self._tuple_typedefs:
            out_lines.append('')
            out_lines.append('/* -- Tuple types -- */')
            out_lines.extend(self._emit_tuple_typedefs())

        # Vec(T) dynamic vector typedefs + PAK_VEC_PUSH macro
        if self._vec_used:
            out_lines.append('')
            out_lines.append('/* -- Vec(T) dynamic vector -- */')
            out_lines.append('#include <stdlib.h>')
            out_lines.append('#define _PAK_VEC_PUSH(v, item) do { \\')
            out_lines.append('    if ((v)->len >= (v)->cap) { \\')
            out_lines.append('        (v)->cap = (v)->cap ? (v)->cap * 2 : 8; \\')
            out_lines.append('        (v)->data = realloc((v)->data, (size_t)(v)->cap * sizeof(*(v)->data)); \\')
            out_lines.append('    } \\')
            out_lines.append('    (v)->data[(v)->len++] = (item); \\')
            out_lines.append('} while(0)')
            out_lines.extend(self._emit_vec_typedefs())

        # Result typedefs
        if self._result_typedefs:
            out_lines.append('')
            for typedef_name, c_ok, c_err in self._result_typedefs:
                out_lines.append(f'typedef struct {{ bool is_ok; union {{ {c_ok} value; {c_err} error; }} data; }} {typedef_name};')

        # Container typedefs (FixedList, RingBuffer, FixedMap, Pool)
        container_td_lines = self._emit_container_typedefs()
        if container_td_lines:
            out_lines.append('')
            out_lines.append('/* -- Container types -- */')
            out_lines.extend(container_td_lines)

        # Emit closures (non-capturing fn literals) as static functions
        if self._closures:
            closure_lines = self._emit_closures()
            self._closures.clear()
            out_lines.append('')
            out_lines.append('/* -- Closures -- */')
            out_lines.extend(closure_lines)

        out_lines.extend(body_lines)

        # Emit any monomorphized generic specializations generated during body codegen
        if hasattr(self, '_pending_mono') and self._pending_mono:
            out_lines.append('')
            out_lines.append('/* -- Generic specializations -- */')
            for decl in self._pending_mono:
                if isinstance(decl, ast.FnDecl):
                    out_lines.append(self.gen_fn(decl))
                elif isinstance(decl, ast.StructDecl):
                    out_lines.append(self.gen_struct(decl))
                out_lines.append('')
            self._pending_mono.clear()

        return '\n'.join(out_lines)

    def gen_decl(self, decl) -> str:
        if isinstance(decl, ast.StructDecl):
            return self.gen_struct(decl)
        if isinstance(decl, ast.EnumDecl):
            return self.gen_enum(decl)
        if isinstance(decl, ast.VariantDecl):
            return self.gen_variant(decl)
        if isinstance(decl, ast.FnDecl):
            # Skip generic function bodies — they are emitted only when specialized
            if decl.type_params:
                return None
            return self.gen_fn(decl)
        if isinstance(decl, ast.EntryBlock):
            return self.gen_entry(decl)
        if isinstance(decl, ast.ExternBlock):
            return self.gen_extern(decl)
        if isinstance(decl, ast.StaticDecl):
            return self.gen_static_decl(decl)
        if isinstance(decl, ast.LetDecl):
            return self.gen_let_decl_global(decl)
        if isinstance(decl, ast.ImplBlock):
            return self.gen_impl(decl)
        if isinstance(decl, ast.ConstDecl):
            return self.gen_const(decl)
        if isinstance(decl, ast.ExternConst):
            return self.gen_extern_const(decl)
        if isinstance(decl, ast.TraitDecl):
            return self.gen_trait(decl)
        if isinstance(decl, ast.ImplTraitBlock):
            return self.gen_impl_trait(decl)
        if isinstance(decl, ast.CfgBlock):
            return self.gen_cfg_block(decl)
        if isinstance(decl, ast.UnionDecl):
            return self.gen_union(decl)
        if isinstance(decl, ast.ComptimeIf):
            cond = self.gen_expr(decl.condition)
            then_lines = []
            for s in decl.then.stmts:
                r = self.gen_decl(s)
                if r:
                    then_lines.append(r)
            then_body = '\n'.join(then_lines)
            result = f'#if {cond}\n{then_body}'
            if decl.else_branch:
                else_lines = []
                for s in decl.else_branch.stmts:
                    r = self.gen_decl(s)
                    if r:
                        else_lines.append(r)
                result += f'\n#else\n' + '\n'.join(else_lines)
            result += f'\n#endif'
            return result
        return f'/* unhandled decl: {type(decl).__name__} */'

    def gen_impl(self, impl: ast.ImplBlock) -> str:
        parts = []
        for method in impl.methods:
            parts.append(self.gen_fn(method, prefix=impl.type_name))
        return '\n\n'.join(parts)

    def gen_trait(self, t: ast.TraitDecl) -> str:
        """Emit vtable struct + trait-object struct for a trait declaration."""
        self.trait_decls[t.name] = t
        lines = [f'/* trait {t.name} */']

        # Vtable: one function-pointer slot per method
        lines.append(f'typedef struct {{')
        for m in t.methods:
            ret = self.gen_type(m.ret_type)
            # All vtable slots take 'void *self' as the first arg
            param_types = ['void *']
            for p in m.params:
                if p.name == 'self':
                    continue
                param_types.append(self.gen_type(p.type))
            params_str = ', '.join(param_types)
            lines.append(f'    {ret} (*{m.name})({params_str});')
        lines.append(f'}} {t.name}_vtable;')
        lines.append('')

        # Trait-object struct (fat pointer: self + vtable)
        lines.append(f'typedef struct {{')
        lines.append(f'    void *self;')
        lines.append(f'    const {t.name}_vtable *vtable;')
        lines.append(f'}} {t.name};')

        return '\n'.join(lines)

    def _trait_default_method(self, tm: ast.FnDecl, type_name: str) -> ast.FnDecl:
        """Specialize a trait default method for a concrete impl type: copy the
        FnDecl and retype its `self` parameter to *type_name so the body's
        self.field / self.other() resolve against the implementing type."""
        import copy as _copy
        new_params = []
        for p in tm.params:
            if p.name == 'self':
                p = ast.Param(name='self',
                              type=ast.TypePointer(inner=ast.TypeName(name=type_name),
                                                   nullable=False, mutable=True),
                              mutable=getattr(p, 'mutable', False))
            new_params.append(p)
        return ast.FnDecl(name=tm.name, params=new_params, ret_type=tm.ret_type,
                          body=_copy.deepcopy(tm.body), type_params=[], annotations=[],
                          is_method=True, self_type=type_name)

    def gen_impl_trait(self, impl: ast.ImplTraitBlock) -> str:
        """Emit the real method bodies, thunk wrappers, vtable instance, and
        constructor for an `impl Type for Trait` block. Trait methods the impl
        omits but the trait provides a default body for are synthesized here."""
        lines = [f'/* impl {impl.type_name} for {impl.trait_name} */']
        trait = self.trait_decls.get(impl.trait_name)

        # Full method set = impl methods + non-overridden trait defaults.
        impl_names = {m.name for m in impl.methods}
        methods = list(impl.methods)
        if trait:
            for tm in trait.methods:
                if tm.name not in impl_names and tm.body is not None:
                    methods.append(self._trait_default_method(tm, impl.type_name))

        # Register methods so obj.method() direct dispatch works
        if impl.type_name not in self.method_registry:
            self.method_registry[impl.type_name] = {}
        for m in methods:
            self.method_registry[impl.type_name][m.name] = m

        # Emit the concrete method bodies: TypeName_method(...)
        for m in methods:
            lines.append(self.gen_fn(m, prefix=impl.type_name))
            lines.append('')

        for m in methods:
            ret = self.gen_type(m.ret_type)
            thunk = f'_pak_{impl.trait_name}_{m.name}_{impl.type_name}'
            # Thunk params: void *_self, then other params
            thunk_params = ['void *_self']
            call_params = [f'({impl.type_name} *)_self']
            for p in m.params:
                if p.name == 'self':
                    continue
                thunk_params.append(f'{self.gen_type(p.type)} {p.name}')
                call_params.append(p.name)
            params_str = ', '.join(thunk_params)
            real_fn = f'{impl.type_name}_{m.name}'
            lines.append(f'static {ret} {thunk}({params_str}) {{')
            call_str = f'{real_fn}({", ".join(call_params)})'
            if ret == 'void':
                lines.append(f'    {call_str};')
            else:
                lines.append(f'    return {call_str};')
            lines.append('}')
            lines.append('')

        # Vtable instance
        vtable_var = f'_pak_{impl.trait_name}_vtable_{impl.type_name}'
        lines.append(f'static const {impl.trait_name}_vtable {vtable_var} = {{')
        for m in methods:
            thunk = f'_pak_{impl.trait_name}_{m.name}_{impl.type_name}'
            lines.append(f'    .{m.name} = {thunk},')
        lines.append('};')
        lines.append('')

        # Constructor helper: TraitName_from_TypeName(TypeName *p)
        ctor = f'{impl.trait_name}_from_{impl.type_name}'
        lines.append(f'static inline {impl.trait_name} {ctor}({impl.type_name} *p) {{')
        lines.append(f'    return ({impl.trait_name}){{ .self = (void *)p, .vtable = &{vtable_var} }};')
        lines.append('}')

        return '\n'.join(lines)

    def gen_cfg_block(self, cfg: ast.CfgBlock) -> str:
        """Emit #ifdef/#ifndef ... #endif around a declaration."""
        inner = self.gen_decl(cfg.decl)
        if inner is None:
            return None
        directive = '#ifndef' if cfg.negated else '#ifdef'
        return f'{directive} {cfg.feature}\n{inner}\n#endif  /* {cfg.feature} */'

    def gen_const(self, c: ast.ConstDecl) -> str:
        val = self.gen_expr(c.value)
        if c.type:
            # static const T NAME = val;  — usable in array sizes via enum trick
            c_type = self.gen_type(c.type)
            # Use enum for integer constants so they're usable as array sizes in C89/C99
            if c_type in ('int32_t', 'uint32_t', 'int', 'uint32_t', 'int16_t', 'uint16_t',
                          'int8_t', 'uint8_t', 'int64_t', 'uint64_t'):
                return f'enum {{ {c.name} = {val} }};'
            return f'static const {c_type} {c.name} = {val};'
        return f'enum {{ {c.name} = {val} }};'

    def gen_extern_const(self, e: ast.ExternConst) -> str:
        # Declare as extern for type-checking purposes; the actual value
        # comes from a C header macro.  We emit a static const that re-uses
        # the macro value so we get the type.
        c_type = self.gen_type(e.type)
        return f'/* extern const {c_type} {e.name}; (C macro passthrough) */'

    def _infer_type_args(self, fn_decl: ast.FnDecl, call_args: list) -> list:
        """Infer concrete types for a generic function's type params from call site args."""
        if not fn_decl.type_params:
            return []
        inferred = {}
        for param, arg_expr in zip(fn_decl.params, call_args):
            # Find which type params appear in the param type
            self._collect_type_param_inferences(param.type, arg_expr, fn_decl.type_params, inferred)
        # Return concrete types in type_param declaration order
        result = []
        for tp in fn_decl.type_params:
            if tp in inferred:
                result.append(inferred[tp])
            else:
                return []  # can't fully infer — caller should pass explicit args
        return result

    def _collect_type_param_inferences(self, param_type, arg_expr, type_params: list, inferred: dict):
        """Walk param_type looking for type params, infer concrete types from arg_expr."""
        if isinstance(param_type, ast.TypeName) and param_type.name in type_params:
            # This param position maps to a type param — infer from argument
            t = self._expr_type(arg_expr)
            if t is None:
                # Guess from literal type
                if isinstance(arg_expr, ast.IntLit):
                    t = ast.TypeName(name='i32')
                elif isinstance(arg_expr, ast.FloatLit):
                    t = ast.TypeName(name='f32')
                elif isinstance(arg_expr, ast.BoolLit):
                    t = ast.TypeName(name='bool')
                elif isinstance(arg_expr, ast.StringLit):
                    t = ast.TypeName(name='Str')
            if t is not None and param_type.name not in inferred:
                inferred[param_type.name] = t
        elif isinstance(param_type, ast.TypePointer):
            self._collect_type_param_inferences(param_type.inner, arg_expr, type_params, inferred)
        elif isinstance(param_type, ast.TypeGeneric):
            for sub in param_type.args:
                self._collect_type_param_inferences(sub, arg_expr, type_params, inferred)

    def _monomorphize_fn(self, fn_name: str, type_args: list) -> str:
        """Return the C name for a specialized generic function, emitting it if first use."""
        import copy
        fn_decl = self._generic_fns[fn_name]
        c_type_args = tuple(self.gen_type(t) for t in type_args)
        cache_key = (fn_name, c_type_args)
        if cache_key in self._mono_cache:
            return self._mono_cache[cache_key]
        # Build specialized name: foo_i32, foo_i32_f32, etc.
        safe = '_'.join(t.replace(' ', '_').replace('*', 'p') for t in c_type_args)
        specialized_name = f'{fn_name}_{safe}'
        self._mono_cache[cache_key] = specialized_name
        # Create a substitution map: type_param_name → concrete type
        subst = {}
        for i, tp in enumerate(fn_decl.type_params):
            if i < len(type_args):
                subst[tp] = type_args[i]
        # Deep-copy the decl and substitute type params
        spec_decl = copy.deepcopy(fn_decl)
        spec_decl.name = specialized_name
        spec_decl.type_params = []
        _subst_types_in_fn(spec_decl, subst)
        # Emit at file scope (append to body_lines via _pending_mono)
        if not hasattr(self, '_pending_mono'):
            self._pending_mono = []
        self._pending_mono.append(spec_decl)
        return specialized_name

    def _monomorphize_struct(self, struct_name: str, type_args: list) -> str:
        """Return the C name for a specialized generic struct, emitting if first use."""
        import copy
        struct_decl = self._generic_structs[struct_name]
        c_type_args = tuple(self.gen_type(t) for t in type_args)
        cache_key = (struct_name, c_type_args)
        if cache_key in self._mono_cache:
            return self._mono_cache[cache_key]
        safe = '_'.join(t.replace(' ', '_').replace('*', 'p') for t in c_type_args)
        specialized_name = f'{struct_name}_{safe}'
        self._mono_cache[cache_key] = specialized_name
        subst = {}
        for i, tp in enumerate(struct_decl.type_params):
            if i < len(type_args):
                subst[tp] = type_args[i]
        spec_decl = copy.deepcopy(struct_decl)
        spec_decl.name = specialized_name
        spec_decl.type_params = []
        _subst_types_in_struct(spec_decl, subst)
        if not hasattr(self, '_pending_mono'):
            self._pending_mono = []
        self._pending_mono.append(spec_decl)
        return specialized_name

    def gen_struct(self, s: ast.StructDecl) -> str:
        attrs = []
        for ann in s.annotations:
            if '@packed' in ann or '@c_layout' in ann:
                # @c_layout enforces C ABI layout (no reordering); closest C
                # equivalent is __attribute__((packed)) if also packed, otherwise
                # it's a no-op annotation (C structs already have C layout by default).
                # Emit packed only when @packed is explicit; @c_layout alone is a marker.
                if '@packed' in ann:
                    attrs.append('__attribute__((packed))')
            elif '@aligned' in ann:
                n = ann[ann.index('(')+1:ann.index(')')]
                attrs.append(f'__attribute__((aligned({n})))')
        attr_str = ' '.join(attrs)
        lines = [f'typedef struct {{']
        for field in s.fields:
            if field.bit_width is not None:
                c_type = self.gen_type(field.type)
                lines.append(f'    {c_type} {field.name} : {field.bit_width};')
            else:
                decl = self.gen_array_decl(field.name, field.type)
                lines.append(f'    {decl};')
        suffix = f' {attr_str}' if attr_str else ''
        lines.append(f'}} {s.name}{suffix};')
        return '\n'.join(lines)

    def gen_union(self, u: ast.UnionDecl) -> str:
        """Emit an untagged C union for type-punning."""
        lines = [f'typedef union {{']
        for field in u.fields:
            decl = self.gen_array_decl(field.name, field.type)
            lines.append(f'    {decl};')
        lines.append(f'}} {u.name};')
        return '\n'.join(lines)

    def gen_enum(self, e: ast.EnumDecl) -> str:
        base = PRIMITIVE_TYPES.get(e.base_type, 'int') if e.base_type else 'int'
        lines = [f'typedef enum {{']
        for v in e.variants:
            if v.value is not None:
                lines.append(f'    {e.name}_{v.name} = {self.gen_expr(v.value)},')
            else:
                lines.append(f'    {e.name}_{v.name},')
        lines.append(f'}} {e.name};')
        return '\n'.join(lines)

    def gen_variant(self, v: ast.VariantDecl) -> str:
        lines = []
        # Generate inner structs for each case
        for case in v.cases:
            if case.fields:
                lines.append(f'typedef struct {{')
                for i, f in enumerate(case.fields):
                    if isinstance(f, tuple):
                        name, typ = f
                        lines.append(f'    {self.gen_array_decl(name, typ)};')
                    else:
                        lines.append(f'    {self.gen_type(f)} field{i};')
                lines.append(f'}} {v.name}_{case.name};')
                lines.append('')

        # Tag enum
        lines.append(f'typedef enum {{')
        for case in v.cases:
            lines.append(f'    {v.name}_tag_{case.name},')
        lines.append(f'}} {v.name}_tag;')
        lines.append('')

        # Tagged union struct
        lines.append(f'typedef struct {{')
        lines.append(f'    {v.name}_tag tag;')
        lines.append(f'    union {{')
        for case in v.cases:
            if case.fields:
                lines.append(f'        {v.name}_{case.name} {case.name};')
        lines.append(f'    }} data;')
        lines.append(f'}} {v.name};')
        return '\n'.join(lines)

    def gen_fn(self, fn: ast.FnDecl, prefix: str = '') -> str:
        lines = []
        annotations = fn.annotations or []

        ret = self.gen_type(fn.ret_type)

        # Build param list
        params = []
        for p in fn.params:
            if isinstance(p.type, ast.TypeArray):
                params.append(self.gen_array_decl(p.name, p.type))
            else:
                params.append(f'{self.gen_type(p.type)} {p.name}')
        if getattr(fn, 'variadic', False):
            params.append('...')
            param_str = ', '.join(params)
        else:
            param_str = ', '.join(params) if params else 'void'

        # Annotations → C attributes
        attrs = []
        for ann in annotations:
            if ann == '@hot':
                attrs.append('__attribute__((hot))')
            elif ann == '@inline':
                attrs.append('static inline')
            elif ann == '@no_alloc':
                pass  # compile-time check only
            elif ann.startswith('@export'):
                # @export("symbol_name") — rename the function to the given C symbol
                import re as _re
                m = _re.search(r'@export\s*\(\s*"([^"]+)"\s*\)', ann)
                if m:
                    fn = fn  # closure capture; update name after attrs loop
                    _export_name = m.group(1)
                else:
                    _export_name = None

        name = fn.name
        if prefix:
            name = f'{prefix}_{name}'
        # Apply @export rename if present
        try:
            if _export_name:
                name = _export_name
        except NameError:
            pass

        attr_str = ' '.join(attrs)
        if attr_str:
            lines.append(f'{attr_str}')

        if fn.body is None:
            lines.append(f'{ret} {name}({param_str});')
            return '\n'.join(lines)

        lines.append(f'{ret} {name}({param_str}) {{')
        prev_ret = self._current_ret_type
        self._current_ret_type = fn.ret_type
        self.scope_push()
        for p in fn.params:
            self.scope_set(p.name, p.type)
        for stmt in fn.body.stmts:
            stmt_str = self.gen_stmt(stmt, indent=1)
            if stmt_str:
                lines.append(stmt_str)
        # Emit defers at natural function exit (LIFO, current scope only)
        for d_line in self._emit_defers_for_scope(-1, '    ', 1):
            lines.append(d_line)
        self.scope_pop()
        self._current_ret_type = prev_ret
        lines.append('}')
        return '\n'.join(lines)

    def gen_entry(self, entry: ast.EntryBlock) -> str:
        lines = ['int main(void) {']
        self.scope_push()
        for stmt in entry.body.stmts:
            s = self.gen_stmt(stmt, indent=1)
            if s:
                lines.append(s)
        for d_line in self._emit_defers_for_scope(-1, '    ', 1):
            lines.append(d_line)
        self.scope_pop()
        lines.append('    return 0;')
        lines.append('}')
        return '\n'.join(lines)

    def gen_extern(self, ext: ast.ExternBlock) -> str:
        lines = [f'/* extern "{ext.abi}" */']
        for decl in ext.decls:
            lines.append(self.gen_fn(decl))
        return '\n'.join(lines)

    def gen_static_decl(self, s: ast.StaticDecl) -> str:
        is_uncached = '@uncached' in (s.annotations or [])

        if is_uncached:
            # @uncached static: declare a cached backing array, then expose a
            # pointer to its KSEG1 (uncached) alias via UncachedAddr().
            # This makes every read/write through `name` bypass the CPU cache,
            # so the RDP / DMA sees the data immediately without a writeback.
            raw_name = f'_pak_raw_{s.name}'
            align_attr = '__attribute__((aligned(16)))'
            for ann in (s.annotations or []):
                if '@aligned' in ann:
                    n = ann[ann.index('(')+1:ann.index(')')]
                    align_attr = f'__attribute__((aligned({n})))'
            if s.type:
                raw_decl = self.gen_array_decl(raw_name, s.type)
                c_type   = self.gen_type(s.type)
                # Determine element type for the pointer alias
                if isinstance(s.type, ast.TypeArray):
                    ptr_type = self.gen_type(s.type.inner)
                else:
                    ptr_type = c_type
            else:
                raw_decl = f'uint8_t {raw_name}[0]'
                ptr_type = 'uint8_t'
                c_type   = 'uint8_t'
            lines = [
                f'static {align_attr} {raw_decl};',
                f'static {ptr_type} * const {s.name} = ({ptr_type} *)UncachedAddr({raw_name});',
            ]
            return '\n'.join(lines)

        decl = self.gen_array_decl(s.name, s.type) if s.type else f'__auto_type {s.name}'
        if '@aligned' in ' '.join(s.annotations or []):
            for ann in (s.annotations or []):
                if '@aligned' in ann:
                    n = ann[ann.index('(')+1:ann.index(')')]
                    decl = f'__attribute__((aligned({n}))) ' + decl
        if s.value and not isinstance(s.value, ast.UndefinedLit):
            return f'static {decl} = {self.gen_expr(s.value)};'
        return f'static {decl};'

    def gen_let_decl_global(self, s: ast.LetDecl) -> str:
        decl = self.gen_array_decl(s.name, s.type) if s.type else f'__auto_type {s.name}'
        if s.value and not isinstance(s.value, ast.UndefinedLit):
            return f'{decl} = {self.gen_expr(s.value)};'
        return f'{decl};'

    def gen_stmt(self, stmt, indent: int = 0) -> str:
        # Wrapper: emit any capturing closures used by this statement as GCC
        # nested-function definitions in the enclosing block, just before the
        # statement that references them (so lexical capture is in scope).
        saved_pending, saved_in = self._pending_nested, self._in_stmt
        self._pending_nested, self._in_stmt = [], True
        body = self._gen_stmt_body(stmt, indent)
        hoisted = self._pending_nested
        self._pending_nested, self._in_stmt = saved_pending, saved_in
        if hoisted:
            pad = '    ' * indent
            defs = []
            for name, e in hoisted:
                defs.extend(self._emit_nested_closure(name, e, indent))
            return '\n'.join(defs) + '\n' + (body if body else f'{pad};')
        return body

    def _gen_stmt_body(self, stmt, indent: int = 0) -> str:
        pad = '    ' * indent

        if isinstance(stmt, ast.LetDecl):
            return self.gen_let_stmt(stmt, pad)
        if isinstance(stmt, ast.StaticDecl):
            return self.gen_static_stmt(stmt, pad)
        if isinstance(stmt, ast.Return):
            # Emit all active defers before returning (LIFO across scopes)
            defers = self._emit_all_defers(pad, indent)
            val = f' {self.gen_expr(stmt.value)}' if stmt.value is not None else ''
            lines = defers + [f'{pad}return{val};']
            return '\n'.join(lines)
        if isinstance(stmt, ast.Break):
            return f'{pad}break;'
        if isinstance(stmt, ast.Continue):
            return f'{pad}continue;'
        if isinstance(stmt, ast.GotoStmt):
            return f'{pad}goto {stmt.label};'
        if isinstance(stmt, ast.LabelStmt):
            # Labels are dedented one level so they're visible at block scope
            label_pad = pad[4:] if len(pad) >= 4 else ''
            return f'{label_pad}{stmt.name}:'
        if isinstance(stmt, ast.ExprStmt):
            # CatchExpr as a bare statement: call the function and run the error
            # handler if the call fails, discarding the ok value.
            if isinstance(stmt.expr, ast.CatchExpr):
                return self._gen_catch_stmt(stmt.expr, pad, indent)
            return f'{pad}{self.gen_expr(stmt.expr)};'
        if isinstance(stmt, ast.IfStmt):
            return self.gen_if(stmt, pad, indent)
        if isinstance(stmt, ast.NullCheckStmt):
            return self.gen_null_check(stmt, pad, indent)
        if isinstance(stmt, ast.LoopStmt):
            return self.gen_loop(stmt, pad, indent)
        if isinstance(stmt, ast.WhileStmt):
            return self.gen_while(stmt, pad, indent)
        if isinstance(stmt, ast.ForStmt):
            return self.gen_for(stmt, pad, indent)
        if isinstance(stmt, ast.MatchStmt):
            return self.gen_match(stmt, pad, indent)
        if isinstance(stmt, ast.DeferStmt):
            # Register the defer — don't emit it yet
            self._defer_push(stmt)
            return None
        if isinstance(stmt, ast.StructDecl):
            return self.gen_struct(stmt)
        if isinstance(stmt, ast.EnumDecl):
            return self.gen_enum(stmt)
        if isinstance(stmt, ast.VariantDecl):
            return self.gen_variant(stmt)
        if isinstance(stmt, ast.Block):
            return self.gen_block_inline(stmt, pad, indent)
        if isinstance(stmt, ast.AsmStmt):
            asm_lines = ' '.join(f'"{ln}\\n\\t"' for ln in stmt.lines)
            vol = '__volatile__' if stmt.volatile else ''
            return f'{pad}__asm__ {vol}({asm_lines});'
        if isinstance(stmt, ast.ConstDecl):
            return self.gen_const(stmt)
        if isinstance(stmt, ast.DoWhileStmt):
            body_lines = []
            for s in stmt.body.stmts:
                r = self.gen_stmt(s, indent + 1)
                if r:
                    body_lines.append(r)
            cond = self.gen_expr(stmt.condition)
            inner = '\n'.join(body_lines)
            return f'{pad}do {{\n{inner}\n{pad}}} while ({cond});'
        if isinstance(stmt, ast.ComptimeIf):
            cond = self.gen_expr(stmt.condition)
            then_lines = []
            for s in stmt.then.stmts:
                r = self.gen_stmt(s, indent)
                if r:
                    then_lines.append(r)
            then_body = '\n'.join(then_lines)
            result = f'#if {cond}\n{then_body}'
            if stmt.else_branch:
                else_lines = []
                for s in stmt.else_branch.stmts:
                    r = self.gen_stmt(s, indent)
                    if r:
                        else_lines.append(r)
                result += f'\n#else\n' + '\n'.join(else_lines)
            result += f'\n#endif'
            return result
        if isinstance(stmt, ast.UnionDecl):
            return self.gen_union(stmt)
        return f'{pad}/* unhandled stmt: {type(stmt).__name__} */'

    def gen_let_stmt(self, s: ast.LetDecl, pad: str) -> str:
        annotations = s.annotations or []
        prefix = ''
        if '@aligned' in ' '.join(annotations):
            for ann in annotations:
                if '@aligned' in ann:
                    n = ann[ann.index('(')+1:ann.index(')')]
                    prefix = f'__attribute__((aligned({n}))) '
        if '@dma_safe' in annotations:
            prefix = '__attribute__((aligned(16))) ' + prefix
        if '@uncached' in annotations:
            # For local @uncached arrays: allocate from heap via malloc_uncached
            # so the memory lives in the RDRAM uncached segment (KSEG1).
            if s.type and isinstance(s.type, ast.TypeArray):
                elem_t  = self.gen_type(s.type.inner)
                n_elems = self.gen_expr(s.type.size)
                self.scope_set(s.name, ast.TypePointer(inner=s.type.inner))
                return (f'{pad}{elem_t} * const {s.name} = '
                        f'({elem_t} *)malloc_uncached({n_elems} * sizeof({elem_t}));')
            # For pointer types, defer to value expression (user uses malloc_uncached)
            prefix = '/* @uncached */ ' + prefix

        if s.type:
            decl = self.gen_array_decl(s.name, s.type)
            self.scope_set(s.name, s.type)
        else:
            decl = f'__auto_type {s.name}'
            # Infer pointer type from value if possible
            if isinstance(s.value, ast.AddrOf):
                self.scope_set(s.name, ast.TypePointer(inner=ast.TypeName(name='auto')))

        if s.value is not None and not isinstance(s.value, ast.UndefinedLit):
            # CatchExpr: multi-statement emit
            if isinstance(s.value, ast.CatchExpr):
                return self._gen_catch_let(s, s.value, pad, prefix, decl)
            # ArrayLit repeat with large/dynamic N: declare then loop fill
            if isinstance(s.value, ast.ArrayLit) and s.value.repeat is not None:
                val_expr = s.value.elements[0] if s.value.elements else ast.IntLit(value=0)
                val = self.gen_expr(val_expr)
                zero_val = val in ('0', 'false', 'NULL', '0.0f', '0.0')
                is_small_const = isinstance(s.value.repeat, ast.IntLit) and s.value.repeat.value <= 64
                # Small constant or zero: let gen_expr handle inline expansion
                if zero_val or is_small_const:
                    expanded = self.gen_expr(s.value)
                    return f'{pad}{prefix}{decl} = {expanded};'
                # Large/dynamic: zero-init then fill loop
                count = self.gen_expr(s.value.repeat)
                lines = [f'{pad}{prefix}{decl} = {{0}};']
                lines.append(f'{pad}for (int _fi = 0; _fi < (int)({count}); _fi++) {s.name}[_fi] = {val};')
                return '\n'.join(lines)
            val = self.gen_expr(s.value)
            # OkExpr/ErrExpr: use actual result type name from the declared type
            if isinstance(s.value, (ast.OkExpr, ast.ErrExpr)) and s.type:
                result_c = self.gen_type(s.type)
                if isinstance(s.value, ast.OkExpr):
                    inner = self.gen_expr(s.value.value)
                    val = f'({result_c}){{ .is_ok = true, .data.value = {inner} }}'
                else:
                    inner = self.gen_expr(s.value.value)
                    val = f'({result_c}){{ .is_ok = false, .data.error = {inner} }}'
            return f'{pad}{prefix}{decl} = {val};'
        elif isinstance(s.value, ast.UndefinedLit):
            return f'{pad}{prefix}{decl}; /* undefined */'
        else:
            return f'{pad}{prefix}{decl};'

    def _gen_catch_let(self, s: ast.LetDecl, catch: ast.CatchExpr,
                       pad: str, prefix: str, decl: str) -> str:
        """Emit a let binding whose value is a CatchExpr:

        Fallback form — handler is a single expression (no return/break):
            let x = try_call() catch { default_val }
        Expands to:
            Type x = try_call().is_ok ? try_call().data.value : default_val;
        (but uses a temp to avoid double-evaluation)

        Propagation form — handler contains return / break / explicit control flow:
            let x = try_call() catch e { return err(e) }
        Expands to the if/else expansion.
        """
        inner_c = self.gen_expr(catch.expr)
        tmp = f'_catch_{s.name}'
        lines = []
        inner_pad = pad + '    '

        # Detect fallback form: handler is a single ExprStmt (not Return/Break)
        is_fallback = False
        fallback_expr = None
        if isinstance(catch.handler, ast.Block):
            stmts = [st for st in catch.handler.stmts if st is not None]
            if len(stmts) == 1 and isinstance(stmts[0], ast.ExprStmt):
                is_fallback = True
                fallback_expr = self.gen_expr(stmts[0].expr)
        elif isinstance(catch.handler, ast.ExprStmt):
            is_fallback = True
            fallback_expr = self.gen_expr(catch.handler.expr)
        elif not isinstance(catch.handler, (ast.Block, ast.Return, ast.Break)):
            # Raw expression node
            is_fallback = True
            fallback_expr = self.gen_expr(catch.handler)

        if is_fallback and fallback_expr is not None:
            lines.append(f'{pad}__auto_type {tmp} = {inner_c};')
            lines.append(f'{pad}{prefix}{decl} = {tmp}.is_ok ? {tmp}.data.value : ({fallback_expr});')
            return '\n'.join(lines)

        # Propagation form
        lines.append(f'{pad}__auto_type {tmp} = {inner_c};')
        lines.append(f'{pad}if (!{tmp}.is_ok) {{')
        if catch.binding:
            lines.append(f'{inner_pad}__auto_type {catch.binding} = {tmp}.data.error;')
        if isinstance(catch.handler, ast.Block):
            for stmt in catch.handler.stmts:
                r = self.gen_stmt(stmt, len(inner_pad) // 4)
                if r:
                    lines.append(r)
        else:
            lines.append(f'{inner_pad}{self.gen_expr(catch.handler)};')
        lines.append(f'{pad}}}')
        # success: extract value
        lines.append(f'{pad}{prefix}{decl} = {tmp}.data.value;')
        return '\n'.join(lines)

    def _gen_catch_stmt(self, catch: ast.CatchExpr, pad: str, indent: int) -> str:
        """Emit a CatchExpr used as a bare statement (not a let binding).
        The ok value is discarded; the error handler runs only on failure.

            some_fn() catch |e| { handle(e); }

        expands to:
            { PakResult _tmp = some_fn(); if (!_tmp.is_ok) { int e = _tmp.data.error; handle(e); } }
        """
        self._tmp_counter = getattr(self, '_tmp_counter', 0) + 1
        tmp = f'_catch_tmp_{self._tmp_counter}'
        inner_pad = pad + '    '
        lines = [f'{pad}{{']
        lines.append(f'{inner_pad}__auto_type {tmp} = {self.gen_expr(catch.expr)};')
        lines.append(f'{inner_pad}if (!{tmp}.is_ok) {{')
        handler_pad = inner_pad + '    '
        if catch.binding:
            lines.append(f'{handler_pad}__auto_type {catch.binding} = {tmp}.data.error;')
        if isinstance(catch.handler, ast.Block):
            for s in catch.handler.stmts:
                r = self.gen_stmt(s, indent + 2)
                if r:
                    lines.append(r)
        else:
            lines.append(f'{handler_pad}{self.gen_expr(catch.handler)};')
        lines.append(f'{inner_pad}}}')
        lines.append(f'{pad}}}')
        return '\n'.join(lines)

    def gen_static_stmt(self, s: ast.StaticDecl, pad: str) -> str:
        annotations = s.annotations or []
        prefix = 'static '
        if '@aligned' in ' '.join(annotations):
            for ann in annotations:
                if '@aligned' in ann:
                    n = ann[ann.index('(')+1:ann.index(')')]
                    prefix += f'__attribute__((aligned({n}))) '
        if s.type:
            decl = self.gen_array_decl(s.name, s.type)
        else:
            decl = f'__auto_type {s.name}'

        if s.value is not None and not isinstance(s.value, ast.UndefinedLit):
            val = self.gen_expr(s.value)
            return f'{pad}{prefix}{decl} = {val};'
        return f'{pad}{prefix}{decl};'

    def gen_if(self, s: ast.IfStmt, pad: str, indent: int) -> str:
        cond = _strip_parens(self.gen_expr(s.condition))
        lines = [f'{pad}if ({cond}) {{']
        self.scope_push()
        for stmt in s.then.stmts:
            lines.append(self.gen_stmt(stmt, indent + 1))
        for d in self._emit_defers_for_scope(-1, pad, indent + 1):
            lines.append(d)
        self.scope_pop()
        lines.append(f'{pad}}}')
        for ec, eb in s.elif_branches:
            lines.append(f'{pad}else if ({_strip_parens(self.gen_expr(ec))}) {{')
            self.scope_push()
            for stmt in eb.stmts:
                lines.append(self.gen_stmt(stmt, indent + 1))
            for d in self._emit_defers_for_scope(-1, pad, indent + 1):
                lines.append(d)
            self.scope_pop()
            lines.append(f'{pad}}}')
        if s.else_branch:
            lines.append(f'{pad}else {{')
            self.scope_push()
            for stmt in s.else_branch.stmts:
                lines.append(self.gen_stmt(stmt, indent + 1))
            for d in self._emit_defers_for_scope(-1, pad, indent + 1):
                lines.append(d)
            self.scope_pop()
            lines.append(f'{pad}}}')
        return '\n'.join(l for l in lines if l is not None)

    def gen_null_check(self, s: ast.NullCheckStmt, pad: str, indent: int) -> str:
        expr = self.gen_expr(s.expr)
        inner_pad = '    ' * (indent + 1)
        lines = [f'{pad}if ({expr} != NULL) {{']
        self.scope_push()
        self.scope_set(s.binding, ast.TypePointer(inner=ast.TypeName(name='auto')))
        lines.append(f'{inner_pad}__typeof__({expr}) {s.binding} = {expr};')
        for stmt in s.then.stmts:
            lines.append(self.gen_stmt(stmt, indent + 1))
        for d in self._emit_defers_for_scope(-1, pad, indent + 1):
            lines.append(d)
        self.scope_pop()
        lines.append(f'{pad}}}')
        if s.else_branch:
            lines.append(f'{pad}else {{')
            self.scope_push()
            for stmt in s.else_branch.stmts:
                lines.append(self.gen_stmt(stmt, indent + 1))
            for d in self._emit_defers_for_scope(-1, pad, indent + 1):
                lines.append(d)
            self.scope_pop()
            lines.append(f'{pad}}}')
        return '\n'.join(l for l in lines if l is not None)

    def gen_loop(self, s: ast.LoopStmt, pad: str, indent: int) -> str:
        lines = [f'{pad}while (true) {{']
        self.scope_push()
        for stmt in s.body.stmts:
            lines.append(self.gen_stmt(stmt, indent + 1))
        for d in self._emit_defers_for_scope(-1, pad, indent + 1):
            lines.append(d)
        self.scope_pop()
        lines.append(f'{pad}}}')
        return '\n'.join(l for l in lines if l is not None)

    def gen_while(self, s: ast.WhileStmt, pad: str, indent: int) -> str:
        cond = _strip_parens(self.gen_expr(s.condition))
        lines = [f'{pad}while ({cond}) {{']
        self.scope_push()
        for stmt in s.body.stmts:
            lines.append(self.gen_stmt(stmt, indent + 1))
        for d in self._emit_defers_for_scope(-1, pad, indent + 1):
            lines.append(d)
        self.scope_pop()
        lines.append(f'{pad}}}')
        return '\n'.join(l for l in lines if l is not None)

    def gen_for(self, s: ast.ForStmt, pad: str, indent: int) -> str:
        iterable = s.iterable
        inner_pad = '    ' * (indent + 1)
        lines = []

        if isinstance(iterable, ast.RangeExpr):
            # for i in start..end  →  for (int i = start; i < end; i++)
            start = self.gen_expr(iterable.start)
            end = self.gen_expr(iterable.end) if iterable.end else '0'
            if s.index:
                lines.append(f'{pad}for (int {s.index} = {start}; {s.index} < {end}; {s.index}++) {{')
                lines.append(f'{inner_pad}int {s.binding} = {s.index};')
            else:
                lines.append(f'{pad}for (int {s.binding} = {start}; {s.binding} < {end}; {s.binding}++) {{')
        else:
            coll = self.gen_expr(iterable)
            coll_type = self._expr_type(iterable)
            self.scope_set(s.binding, ast.TypeName(name='auto'))

            if isinstance(coll_type, ast.TypeSlice) or \
                    self._container_kind(coll_type) in ('Vec', 'FixedList', 'Pool'):
                # Fat slice or .data/.len container: iterate via .data up to .len
                idx = s.index if s.index else f'_i_{s.binding}'
                lines.append(f'{pad}for (int {idx} = 0; {idx} < ({coll}).len; {idx}++) {{')
                lines.append(f'{inner_pad}__typeof__(({coll}).data[0]) {s.binding} = ({coll}).data[{idx}];')
            else:
                # Fixed-size C array ([N]T): iterate using sizeof/sizeof
                idx = s.index if s.index else f'_i_{s.binding}'
                lines.append(f'{pad}for (int {idx} = 0; {idx} < (int)(sizeof({coll})/sizeof(({coll})[0])); {idx}++) {{')
                lines.append(f'{inner_pad}__typeof__(({coll})[0]) {s.binding} = ({coll})[{idx}];')

        self.scope_push()
        for stmt in s.body.stmts:
            lines.append(self.gen_stmt(stmt, indent + 1))
        # Emit defers before closing the loop body
        for d_line in self._emit_defers_for_scope(-1, inner_pad, indent + 1):
            lines.append(d_line)
        self.scope_pop()
        lines.append(f'{pad}}}')
        return '\n'.join(l for l in lines if l is not None)

    def gen_match(self, s: ast.MatchStmt, pad: str, indent: int) -> str:
        expr = self.gen_expr(s.expr)
        inner_pad = '    ' * (indent + 1)
        inner2_pad = '    ' * (indent + 2)

        # Determine if the matched expression is a variant (tagged union).
        # Variants need switch(expr.tag); enums switch(expr) directly.
        match_type = self._match_type_name(s.expr)
        is_variant = match_type in self.variant_types
        switch_expr = f'{expr}.tag' if is_variant else expr
        lines = [f'{pad}switch ({switch_expr}) {{']

        for arm in s.arms:
            pat = arm.pattern
            if isinstance(pat, ast.Ident) and pat.name == '_':
                lines.append(f'{inner_pad}default:')
            elif isinstance(pat, ast.EnumVariantAccess):
                type_name = self.enum_variants.get(pat.name, '')
                if type_name in self.variant_types:
                    # Tagged union: case uses _tag_ infix
                    lines.append(f'{inner_pad}case {type_name}_tag_{pat.name}:')
                elif type_name:
                    lines.append(f'{inner_pad}case {type_name}_{pat.name}:')
                else:
                    lines.append(f'{inner_pad}case {pat.name}:')
            elif isinstance(pat, ast.DotAccess):
                # EnumName.variant or VariantName.Case explicit form
                variant = pat.field
                obj_name = self.gen_expr(pat.obj)
                if obj_name in self.variant_types:
                    lines.append(f'{inner_pad}case {obj_name}_tag_{variant}:')
                else:
                    lines.append(f'{inner_pad}case {obj_name}_{variant}:')
            elif isinstance(pat, ast.IntLit):
                lines.append(f'{inner_pad}case {pat.value}:')
            elif isinstance(pat, ast.BoolLit):
                lines.append(f'{inner_pad}case {"1" if pat.value else "0"}:')
            else:
                lines.append(f'{inner_pad}case /* {self.gen_expr(pat)} */:')

            # Wrap body in {} so variable declarations are always valid in C
            lines.append(f'{inner_pad}{{')
            self.scope_push()
            # Emit variant binding if pattern has one: Type.Case(binding)
            if isinstance(pat, ast.DotAccess) and pat.binding:
                obj_name = self.gen_expr(pat.obj)
                if obj_name in self.variant_types:
                    field_name = pat.field.lower()
                    lines.append(f'{inner2_pad}__auto_type {pat.binding} = {expr}.data.{field_name};')
                    self.scope_set(pat.binding, ast.TypeName(name='auto'))
            if isinstance(arm.body, ast.Block):
                for stmt in arm.body.stmts:
                    lines.append(self.gen_stmt(stmt, indent + 2))
            else:
                lines.append(f'{inner2_pad}{self.gen_expr(arm.body)};')
            for d_line in self._emit_defers_for_scope(-1, inner2_pad, indent + 2):
                lines.append(d_line)
            self.scope_pop()
            lines.append(f'{inner2_pad}break;')
            lines.append(f'{inner_pad}}}')

        lines.append(f'{pad}}}')
        return '\n'.join(l for l in lines if l is not None)

    def gen_defer(self, s: ast.DeferStmt, pad: str, indent: int) -> str:
        lines = [f'{pad}/* defer: */']
        if isinstance(s.body, ast.Block):
            for stmt in s.body.stmts:
                lines.append(self.gen_stmt(stmt, indent))
        return '\n'.join(lines)

    def gen_block_inline(self, block: ast.Block, pad: str, indent: int) -> str:
        lines = [f'{pad}{{']
        for stmt in block.stmts:
            lines.append(self.gen_stmt(stmt, indent + 1))
        lines.append(f'{pad}}}')
        return '\n'.join(l for l in lines if l is not None)


def _subst_type(t, subst: dict):
    """Substitute TypeParam names in a type tree."""
    if t is None:
        return t
    if isinstance(t, ast.TypeParam):
        return subst.get(t.name, t)
    if isinstance(t, ast.TypeName):
        if t.name in subst:
            return subst[t.name]
        return t
    if isinstance(t, ast.TypePointer):
        t.inner = _subst_type(t.inner, subst)
    elif isinstance(t, ast.TypeSlice):
        t.inner = _subst_type(t.inner, subst)
    elif isinstance(t, ast.TypeArray):
        t.inner = _subst_type(t.inner, subst)
    elif isinstance(t, ast.TypeResult):
        t.ok = _subst_type(t.ok, subst)
        t.err = _subst_type(t.err, subst)
    elif isinstance(t, ast.TypeOption):
        t.inner = _subst_type(t.inner, subst)
    elif isinstance(t, ast.TypeGeneric):
        t.args = [_subst_type(a, subst) for a in t.args]
    elif isinstance(t, ast.TypeFn):
        t.params = [_subst_type(p, subst) for p in t.params]
        t.ret = _subst_type(t.ret, subst)
    return t

def _subst_types_in_fn(fn: ast.FnDecl, subst: dict):
    for p in fn.params:
        p.type = _subst_type(p.type, subst)
    fn.ret_type = _subst_type(fn.ret_type, subst)

def _subst_types_in_struct(s: ast.StructDecl, subst: dict):
    for f in s.fields:
        f.type = _subst_type(f.type, subst)


def generate(program: ast.Program, filename: str = '<unknown>', module_headers: dict = None) -> str:
    cg = Codegen(filename, module_headers=module_headers)
    return cg.gen_program(program)
