"""N64 libdragon FFI — maps PAK module API calls to MIPS jal instructions.

Reuses the MODULE_API mapping table from codegen.py to stay in sync with the
C backend's understanding of the N64 SDK.  For the MIPS path every call
becomes a ``jal <libdragon_symbol>`` with arguments marshalled per o32 ABI.

Special handling:
  - Some libdragon functions take a pointer to the first argument
    (e.g. t3d_mat4_identity takes *T3DMat4).  These are flagged with
    ``first_arg_addr=True`` and we emit ``addiu $t, $sp, offset`` or
    reuse the value already in an address register.
  - Variadic functions (e.g. debugf/printf) work because o32's arg-passing
    is stack-compatible; we just push extras after $a0-$a3.

Usage::

    rt = N64Runtime()
    # Call n64.display.init(0, 2, 2, 0, 1)  -- 320x240, 16bpp, double-buffer, no gamma, resample
    rt.emit_call(em, ra, 'display', 'init',
                 arg_regs=['$a0', '$a1', '$a2', '$a3', '$t0'],
                 arg_locs=classify_args(['u32','u32','i32','u32','u32']))
"""

from __future__ import annotations
from typing import List, Optional, Callable, Any

from .emit import Emitter
from .registers import RegAlloc, A0, A1, A2, A3, SP
from .abi import ArgLoc


# ── Symbol table (module, fn_name) → libdragon symbol ────────────────────────

# Each entry maps to:
#   str           → direct jal to that symbol
#   callable      → called with (arg_registers: list[str]) → symbol_str
#   dict          → extra metadata: {'sym': str, 'first_arg_addr': bool}

def _sym(s: str):
    return {'sym': s, 'first_arg_addr': False}

def _sym_addr(s: str):
    return {'sym': s, 'first_arg_addr': True}

def _sym_fn(fn: Callable):
    return {'sym': fn, 'first_arg_addr': False}


N64_RUNTIME_API: dict = {
    # n64.display
    ('display', 'init'):           _sym('display_init'),
    ('display', 'get'):            _sym('display_get'),
    ('display', 'show'):           _sym('display_show'),
    ('display', 'close'):          _sym('display_close'),

    # n64.controller / joypad
    ('controller', 'init'):        _sym('joypad_init'),
    ('controller', 'read'):        _sym('joypad_get_status'),
    ('controller', 'poll'):        _sym('joypad_poll'),

    # n64.rdpq
    ('rdpq', 'init'):              _sym('rdpq_init'),
    ('rdpq', 'close'):             _sym('rdpq_close'),
    ('rdpq', 'attach'):            _sym('rdpq_attach'),
    ('rdpq', 'attach_clear'):      _sym('rdpq_attach_clear'),
    ('rdpq', 'detach'):            _sym('rdpq_detach'),
    ('rdpq', 'detach_show'):       _sym('rdpq_detach_show'),
    ('rdpq', 'set_mode_standard'): _sym('rdpq_set_mode_standard'),
    ('rdpq', 'set_mode_copy'):     _sym('rdpq_set_mode_copy'),
    ('rdpq', 'set_mode_fill'):     _sym('rdpq_set_mode_fill'),
    ('rdpq', 'fill_rectangle'):    _sym('rdpq_fill_rectangle'),
    ('rdpq', 'sync_full'):         _sym('rdpq_sync_full'),
    ('rdpq', 'sync_pipe'):         _sym('rdpq_sync_pipe'),
    ('rdpq', 'sync_tile'):         _sym('rdpq_sync_tile'),
    ('rdpq', 'sync_load'):         _sym('rdpq_sync_load'),
    ('rdpq', 'set_scissor'):       _sym('rdpq_set_scissor'),

    # n64.sprite
    ('sprite', 'load'):            _sym('sprite_load'),
    ('sprite', 'blit'):            _sym('rdpq_sprite_blit'),

    # n64.timer
    ('timer', 'init'):             _sym('timer_init'),
    ('timer', 'delta'):            _sym('_pak_delta_time'),
    ('timer', 'get_ticks'):        _sym('get_ticks'),

    # n64.audio
    ('audio', 'init'):             _sym('audio_init'),
    ('audio', 'close'):            _sym('audio_close'),
    ('audio', 'get_buffer'):       _sym('audio_get_buffer'),

    # n64.debug
    ('debug', 'log'):              _sym('debugf'),
    ('debug', 'assert'):           _sym('assert'),
    ('debug', 'log_value'):        _sym('debugf'),

    # n64.dma
    ('dma', 'read'):               _sym('dma_read'),
    ('dma', 'write'):              _sym('dma_write'),
    ('dma', 'wait'):               _sym('dma_wait'),

    # n64.cache
    ('cache', 'writeback'):        _sym('data_cache_hit_writeback'),
    ('cache', 'invalidate'):       _sym('data_cache_hit_invalidate'),
    ('cache', 'writeback_inv'):    _sym('data_cache_hit_writeback_invalidate'),

    # n64.eeprom
    ('eeprom', 'present'):         _sym('eeprom_present'),
    ('eeprom', 'type_detect'):     _sym('eeprom_type_detect'),
    ('eeprom', 'read'):            _sym('eeprom_read'),
    ('eeprom', 'write'):           _sym('eeprom_write'),

    # n64.rumble
    ('rumble', 'init'):            _sym('rumble_init'),
    ('rumble', 'start'):           _sym('rumble_start'),
    ('rumble', 'stop'):            _sym('rumble_stop'),

    # n64.cpak
    ('cpak', 'init'):              _sym('cpak_init'),
    ('cpak', 'is_plugged'):        _sym('cpak_is_plugged'),
    ('cpak', 'is_formatted'):      _sym('cpak_is_formatted'),
    ('cpak', 'format'):            _sym('cpak_format'),
    ('cpak', 'read_sector'):       _sym('cpak_read_sector'),
    ('cpak', 'write_sector'):      _sym('cpak_write_sector'),
    ('cpak', 'get_free_space'):    _sym('cpak_get_free_space'),

    # n64.tpak
    ('tpak', 'init'):              _sym('tpak_init'),
    ('tpak', 'set_value'):         _sym('tpak_set_value'),
    ('tpak', 'get_value'):         _sym('tpak_get_value'),

    # t3d.core
    ('t3d', 'init'):               _sym('t3d_init'),
    ('t3d', 'destroy'):            _sym('t3d_destroy'),
    ('t3d', 'frame_start'):        _sym('t3d_frame_start'),
    ('t3d', 'frame_end'):          _sym('rspq_block_run'),
    ('t3d', 'screen_projection'):  _sym('t3d_screen_projection'),
    ('t3d', 'viewport_create'):    _sym('t3d_viewport_create'),
    ('t3d', 'viewport_set_projection'): _sym('t3d_viewport_set_projection'),

    # t3d.model
    ('t3d', 'model_load'):         _sym('t3d_model_load'),
    ('t3d', 'model_free'):         _sym('t3d_model_free'),
    ('t3d', 'model_draw'):         _sym('t3d_model_draw'),

    # t3d.math (first arg is pointer to output struct)
    ('t3d', 'mat4_identity'):      _sym_addr('t3d_mat4_identity'),
    ('t3d', 'mat4_rotate_y'):      _sym_addr('t3d_mat4_rotate'),
    ('t3d', 'mat4_rotate_x'):      _sym_addr('t3d_mat4_rotate'),
    ('t3d', 'mat4_rotate_z'):      _sym_addr('t3d_mat4_rotate'),
    ('t3d', 'mat4_translate'):     _sym_addr('t3d_mat4_translate'),
    ('t3d', 'mat4_scale'):         _sym_addr('t3d_mat4_scale'),
    ('t3d', 'mat4_mul'):           _sym_addr('t3d_mat4_mul'),
    ('t3d', 'mat4_from_srt'):      _sym_addr('t3d_mat4_from_srt'),
    ('t3d', 'mat4_from_srt_euler'):_sym_addr('t3d_mat4_from_srt_euler'),
    ('t3d', 'mat4_invert'):        _sym_addr('t3d_mat4_invert'),
    ('t3d', 'mat4_transpose'):     _sym_addr('t3d_mat4_transpose'),
    ('t3d', 'vec3_norm'):          _sym_addr('t3d_vec3_norm'),
    ('t3d', 'vec3_cross'):         _sym_addr('t3d_vec3_cross'),
    ('t3d', 'vec3_dot'):           _sym_addr('t3d_vec3_dot'),
    ('t3d', 'vec3_lerp'):          _sym_addr('t3d_vec3_lerp'),
    ('t3d', 'quat_identity'):      _sym_addr('t3d_quat_identity'),
    ('t3d', 'quat_from_axis_angle'):_sym_addr('t3d_quat_from_axis_angle'),
    ('t3d', 'quat_mul'):           _sym_addr('t3d_quat_mul'),
    ('t3d', 'quat_nlerp'):         _sym_addr('t3d_quat_nlerp'),
    ('t3d', 'quat_slerp'):         _sym_addr('t3d_quat_slerp'),

    # t3d.light
    ('t3d', 'light_set_ambient'):  _sym('t3d_light_set_ambient'),
    ('t3d', 'light_set_directional'): _sym('t3d_light_set_directional'),
    ('t3d', 'light_set_count'):    _sym('t3d_light_set_count'),
    ('t3d', 'light_set_point'):    _sym('t3d_light_set_point'),
    ('t3d', 'light_set_spot'):     _sym('t3d_light_set_spot'),
    ('t3d', 'light_set_point_params'): _sym('t3d_light_set_point_params'),

    # t3d.viewport
    ('t3d', 'viewport_attach'):    _sym('t3d_viewport_attach'),
    ('t3d', 'viewport_set_fov'):   _sym('t3d_viewport_set_fov'),
    ('t3d', 'set_camera'):         _sym('t3d_set_camera'),
    ('t3d', 'look_at'):            _sym('t3d_look_at'),

    # t3d.fog
    ('t3d', 'fog_set_enabled'):    _sym('t3d_fog_set_enabled'),
    ('t3d', 'fog_set_range'):      _sym('t3d_fog_set_range'),
    ('t3d', 'fog_set_color'):      _sym('t3d_fog_set_color'),

    # t3d.anim
    ('t3d', 'anim_create'):        _sym('t3d_anim_create'),
    ('t3d', 'anim_destroy'):       _sym('t3d_anim_destroy'),
    ('t3d', 'anim_set_playing'):   _sym('t3d_anim_set_playing'),
    ('t3d', 'anim_set_looping'):   _sym('t3d_anim_set_looping'),
    ('t3d', 'anim_set_speed'):     _sym('t3d_anim_set_speed'),
    ('t3d', 'anim_update'):        _sym('t3d_anim_update'),
    ('t3d', 'anim_attach'):        _sym('t3d_anim_attach'),

    # t3d.skeleton
    ('t3d', 'skeleton_create'):    _sym('t3d_skeleton_create'),
    ('t3d', 'skeleton_destroy'):   _sym('t3d_skeleton_destroy'),
    ('t3d', 'skeleton_update'):    _sym('t3d_skeleton_update'),
    ('t3d', 'skeleton_draw'):      _sym('t3d_skeleton_draw'),

    # t3d.state
    ('t3d', 'state_set_vertex_fx'): _sym('t3d_state_set_vertex_fx'),
    ('t3d', 'state_set_drawflags'): _sym('t3d_state_set_drawflags'),
    ('t3d', 'push_draw_flags'):    _sym('t3d_push_draw_flags'),
    ('t3d', 'pop_draw_flags'):     _sym('t3d_pop_draw_flags'),

    # t3d.model extended
    ('t3d', 'model_get_object_by_index'): _sym('t3d_model_get_object_by_index'),
    ('t3d', 'model_get_object_by_name'):  _sym('t3d_model_get_object_by_name'),
    ('t3d', 'model_get_material'):        _sym('t3d_model_get_material'),
    ('t3d', 'model_get_vertex_count'):    _sym('t3d_model_get_vertex_count'),
    ('t3d', 'model_bake_pos'):            _sym('t3d_model_bake_pos'),
    ('t3d', 'draw_object'):               _sym('t3d_draw_object'),
    ('t3d', 'draw_indexed'):              _sym('t3d_draw_indexed'),

    # t3d.segment
    ('t3d', 'segment_set'):        _sym('t3d_segment_set'),

    # t3d.rdpq
    ('t3d', 'rdpq_draw_object'):   _sym('t3d_rdpq_draw_object'),

    # t3d.particles
    ('t3d', 'vert_load'):          _sym('t3d_vert_load'),
    ('t3d', 'vert_load_srt'):      _sym('t3d_vert_load_srt'),
    ('t3d', 'tri_draw'):           _sym('t3d_tri_draw'),
    ('t3d', 'tri_sync'):           _sym('t3d_tri_sync'),
}


class N64Runtime:
    """Translates PAK module API calls into libdragon jal sequences."""

    def lookup(self, module: str, fn: str) -> Optional[dict]:
        """Return the API entry for (module, fn), or None if unknown."""
        return N64_RUNTIME_API.get((module, fn))

    def symbol_for(self, module: str, fn: str) -> Optional[str]:
        """Return the libdragon symbol name for (module, fn)."""
        entry = self.lookup(module, fn)
        if entry is None:
            return None
        sym = entry['sym']
        if callable(sym):
            return None  # dynamic; use emit_call
        return sym

    def emit_call(
        self,
        em: Emitter,
        module: str,
        fn: str,
        arg_regs: List[str],
        arg_locs: List[ArgLoc],
    ) -> None:
        """Emit argument marshalling + jal for a module API call.

        arg_regs: list of GPR/FPR names holding each argument value (in order).
        arg_locs: list of ArgLoc objects from abi.classify_args().
        """
        entry = self.lookup(module, fn)
        if entry is None:
            raise KeyError(f"Unknown N64 API: {module}.{fn}")

        sym = entry['sym']
        first_arg_addr = entry.get('first_arg_addr', False)

        # Marshal arguments into their o32 locations
        for i, (reg, loc) in enumerate(zip(arg_regs, arg_locs)):
            if i == 0 and first_arg_addr:
                # The first argument should already be an address in a GPR;
                # no special handling needed if reg is already a pointer.
                # If it's a struct value, the caller must have taken its address first.
                pass
            if loc.kind == 'gpr' and reg != loc.reg:
                em.move(loc.reg, reg)
            elif loc.kind == 'fpr' and reg != loc.reg:
                from .emit import Emitter as _E
                em.raw(f'    mov.s {loc.reg}, {reg}')
            elif loc.kind == 'stack':
                em.sw(reg, loc.stack_offset, SP)

        # Emit the call
        if callable(sym):
            # Dynamic symbol: ask the callable for the symbol name
            sym_name = sym(arg_regs)
            em.jal(sym_name)
        else:
            em.jal(sym)
        em.nop()  # branch delay slot
