"""N64/libdragon API mappings for c2pak (Phase 5).

Provides:
  C_TO_PAK_API: dict mapping C function name → (module, method) for libdragon API
  N64_TYPES:    dict mapping N64 decomp type names to Pak type strings
"""

from __future__ import annotations
from typing import Dict, Optional, Tuple

# ── C → Pak API mapping ───────────────────────────────────────────────────────
# Built from the inverse of pak/codegen.py MODULE_API dict.
# Format: 'c_func_name' → ('pak_module', 'pak_method')
C_TO_PAK_API: Dict[str, Tuple[str, str]] = {
    # display
    'display_init':           ('display', 'init'),
    'display_get':            ('display', 'get'),
    'display_show':           ('display', 'show'),
    'display_close':          ('display', 'close'),

    # rdpq
    'rdpq_init':              ('rdpq', 'init'),
    'rdpq_close':             ('rdpq', 'close'),
    'rdpq_attach':            ('rdpq', 'attach'),
    'rdpq_attach_clear':      ('rdpq', 'attach_clear'),
    'rdpq_detach':            ('rdpq', 'detach'),
    'rdpq_detach_show':       ('rdpq', 'detach_show'),
    'rdpq_set_mode_standard': ('rdpq', 'set_mode_standard'),
    'rdpq_set_mode_copy':     ('rdpq', 'set_mode_copy'),
    'rdpq_set_mode_fill':     ('rdpq', 'set_mode_fill'),
    'rdpq_fill_rectangle':    ('rdpq', 'fill_rectangle'),
    'rdpq_sync_full':         ('rdpq', 'sync_full'),
    'rdpq_sync_pipe':         ('rdpq', 'sync_pipe'),
    'rdpq_sync_tile':         ('rdpq', 'sync_tile'),
    'rdpq_sync_load':         ('rdpq', 'sync_load'),
    'rdpq_set_scissor':       ('rdpq', 'set_scissor'),
    'rdpq_triangle':          ('rdpq', 'triangle'),
    'rdpq_texture_rectangle': ('rdpq', 'texture_rectangle'),
    'rdpq_texture_rectangle_scaled': ('rdpq', 'texture_rectangle_scaled'),
    'rdpq_set_blend_color':   ('rdpq', 'set_blend_color'),
    'rdpq_set_fog_color':     ('rdpq', 'set_fog_color'),
    'rdpq_set_fill_color':    ('rdpq', 'set_fill_color'),
    'rdpq_set_env_color':     ('rdpq', 'set_env_color'),
    'rdpq_set_prim_color':    ('rdpq', 'set_prim_color'),
    'rdpq_set_z_image':       ('rdpq', 'set_z_image'),
    'rdpq_set_color_image':   ('rdpq', 'set_color_image'),
    'rdpq_set_tile':          ('rdpq', 'set_tile'),
    'rdpq_set_tile_size':     ('rdpq', 'set_tile_size'),
    'rdpq_load_tile':         ('rdpq', 'load_tile'),
    'rdpq_load_tlut':         ('rdpq', 'load_tlut'),
    'rdpq_set_combiner_raw':  ('rdpq', 'set_combiner_raw'),
    'rdpq_set_other_modes_raw': ('rdpq', 'set_other_modes_raw'),
    'rspq_flush':             ('rdpq', 'flush'),
    'rdpq_block_begin':       ('rdpq', 'block_begin'),
    'rdpq_block_end':         ('rdpq', 'block_end'),
    'rdpq_block_run':         ('rdpq', 'block_run'),
    'rdpq_block_free':        ('rdpq', 'block_free'),
    'rdpq_call':              ('rdpq', 'call'),

    # joypad
    'joypad_init':            ('joypad', 'init'),
    'joypad_poll':            ('joypad', 'poll'),
    'joypad_get_status':      ('joypad', 'get_status'),
    'joypad_get_buttons':     ('joypad', 'get_buttons'),
    'joypad_get_buttons_pressed':  ('joypad', 'get_buttons_pressed'),
    'joypad_get_buttons_released': ('joypad', 'get_buttons_released'),
    'joypad_get_axis_held':   ('joypad', 'get_axis_held'),
    'joypad_get_axis_pressed': ('joypad', 'get_axis_pressed'),
    'joypad_get_accessory_type': ('joypad', 'get_accessory_type'),
    'joypad_is_connected':    ('joypad', 'is_connected'),

    # surface
    'surface_alloc':          ('surface', 'alloc'),
    'surface_free':           ('surface', 'free'),
    'surface_make_sub':       ('surface', 'make_sub'),
    'display_get_surface':    ('display', 'get'),  # alias

    # audio
    'audio_init':             ('audio', 'init'),
    'audio_close':            ('audio', 'close'),
    'audio_push':             ('audio', 'push'),
    'audio_get_buffer':       ('audio', 'get_buffer'),
    'audio_write':            ('audio', 'write'),
}

# ── N64 decomp type aliases ───────────────────────────────────────────────────
# Maps C type names that appear in decomp code → Pak type representation
N64_TYPES: Dict[str, str] = {
    # Vector types
    'Vec3f':   '[3]f32',
    'Vec3i':   '[3]i16',
    'Vec3s':   '[3]i16',
    'Vec3b':   '[3]i8',

    # Matrix types
    'Mtx':     '[4][4]i16',
    'MtxF':    '[4][4]f32',
    'Matrix':  '[4][4]f32',

    # GFX/RDP
    'Gfx':     'u64',
    'Vtx':     'u64',     # display list vertex
    'Lights':  'u32',
    'OSThread': '*mut u8',  # extern/opaque
    'OSMesgQueue': '*mut u8',
    'OSMesg':  'u64',
    'OSTask':  '*mut u8',
    'SPTask':  '*mut u8',

    # libdragon types
    'surface_t': 'surface_t',
    'display_context_t': '*mut u8',
    'resolution_t': 'i32',
    'bitdepth_t': 'i32',
    'antialias_filter_t': 'i32',
    'gamma_t': 'i32',

    # libdragon graphics / sprites
    'sprite_t': '*mut u8',
    'rdpq_blitparms_t': '*mut u8',
    'color_t': 'u32',
    'rdp_color_t': 'u32',
    'rdpq_tile_t': 'i32',
    'tex_format_t': 'i32',

    # libdragon audio
    'wav64_t': '*mut u8',
    'xm64player_t': '*mut u8',
    'ym64player_t': '*mut u8',
    'mixer_ch_t': '*mut u8',

    # libdragon rspq / rdpq blocks
    'rspq_block_t': '*mut u8',
    'rdpq_block_t': '*mut u8',

    # libdragon filesystem / debug
    'FILE': '*mut u8',
    'dir_t': '*mut u8',

    # libdragon controller / joypad
    'joypad_port_t': 'i32',
    'joypad_style_t': 'i32',
    'joypad_buttons_t': 'u32',
    'joypad_inputs_t': '*mut u8',

    # OS / threading
    'OSTime': 'u64',
    'OSPri': 'i32',
    'OSId': 'i32',

    # Common
    '__builtin_va_list': '*mut u8',
}

# Modules collected from C_TO_PAK_API for use declarations
_MODULE_NAMES = sorted({mod for mod, _ in C_TO_PAK_API.values()})


def get_pak_call(c_func_name: str) -> Optional[Tuple[str, str]]:
    """Return (module, method) for a C libdragon function name, or None."""
    return C_TO_PAK_API.get(c_func_name)


def get_use_statements(used_modules) -> list:
    """Return sorted list of 'use n64.module' lines for used modules."""
    return [f'use n64.{mod}' for mod in sorted(used_modules)]
