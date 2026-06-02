"""
tests/test_api_patterns.py — Verify correct N64 API usage patterns compile.

These tests encode behavioral knowledge from STDLIB.md and N64_HARDWARE.md
as executable checks. Each test:
  1. Verifies the documented CORRECT pattern compiles cleanly.
  2. Verifies the documented WRONG pattern fails (where the compiler can detect it).

This catches documentation drift: if a "correct" example stops compiling,
the doc is wrong. If a "wrong" example starts compiling, the doc is wrong.

Where hardware behavior can't be checked at compile time (wrong flag values,
missing controller.poll(), etc.), the test documents the pattern and verifies
the syntax at least compiles correctly.
"""

import subprocess
import textwrap
import tempfile
from pathlib import Path
import pytest

# Drives the installed `pak` CLI; skipped cleanly if it is not on PATH.
pytestmark = pytest.mark.requires_pak


def _check(source: str) -> tuple[int, str]:
    with tempfile.NamedTemporaryFile(suffix=".pk64", mode="w",
                                     encoding="utf-8", delete=False) as f:
        f.write(textwrap.dedent(source).strip())
        tmp = Path(f.name)
    try:
        r = subprocess.run(["pak", "check", str(tmp)], capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr
    finally:
        tmp.unlink(missing_ok=True)


def assert_passes(source: str, reason: str = ""):
    code, output = _check(source)
    assert code == 0, f"Expected PASS ({reason}):\n{output}"


def assert_fails(source: str, reason: str = ""):
    code, output = _check(source)
    assert code != 0, f"Expected FAIL ({reason}) but compiled."


# ══════════════════════════════════════════════════════════════════════════════
# display module
# ══════════════════════════════════════════════════════════════════════════════

class TestDisplayPatterns:
    def test_correct_display_init_raw_values(self):
        """display.init with raw numeric values (preferred form) compiles."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            entry {
                display.init(0, 2, 3, 0, 1)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.detach_show()
                }
            }
        """, "display.init with raw values")

    def test_correct_display_init_double_buffer(self):
        """2 buffers (double-buffer) also valid."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            entry {
                display.init(0, 2, 2, 0, 0)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.detach_show()
                }
            }
        """, "double-buffer display.init")

    def test_correct_get_attach_detach_show_sequence(self):
        """get → attach_clear → ... → detach_show is the canonical sequence."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            entry {
                display.init(0, 2, 3, 0, 1)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.set_mode_fill(0x000000FF)
                    rdpq.fill_rectangle(0, 0, 320, 240)
                    rdpq.detach_show()
                }
            }
        """, "canonical render loop")


# ══════════════════════════════════════════════════════════════════════════════
# controller module
# ══════════════════════════════════════════════════════════════════════════════

class TestControllerPatterns:
    def test_correct_poll_then_read_sequence(self):
        """controller.poll() before controller.read() — canonical pattern."""
        assert_passes("""
            use n64.controller
            use n64.display
            use n64.rdpq
            static jumped: bool = false
            entry {
                display.init(0, 2, 2, 0, 0)
                rdpq.init()
                controller.init()
                loop {
                    controller.poll()
                    let pad = controller.read(0)
                    if pad.pressed.a { jumped = true }
                    if pad.held.right { jumped = false }
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.detach_show()
                }
            }
        """, "poll → read → use buttons")

    def test_all_button_fields_accessible(self):
        """All documented button fields on held, pressed, released are accessible."""
        assert_passes("""
            use n64.controller
            static sink: bool = false
            entry {
                controller.init()
                loop {
                    controller.poll()
                    let pad = controller.read(0)
                    sink = pad.held.a
                    sink = pad.held.b
                    sink = pad.held.start
                    sink = pad.held.z
                    sink = pad.held.l
                    sink = pad.held.r
                    sink = pad.held.up
                    sink = pad.held.down
                    sink = pad.held.left
                    sink = pad.held.right
                    sink = pad.pressed.a
                    sink = pad.released.b
                }
            }
        """, "all button fields")

    def test_analog_stick_access(self):
        """Analog stick fields are i8 and accessible."""
        assert_passes("""
            use n64.controller
            static dx: i32 = 0
            static dy: i32 = 0
            entry {
                controller.init()
                loop {
                    controller.poll()
                    let pad = controller.read(0)
                    dx = pad.stick_x as i32
                    dy = pad.stick_y as i32
                }
            }
        """, "analog stick access")

    def test_dead_zone_pattern(self):
        """Dead zone pattern: only move if stick exceeds threshold."""
        assert_passes("""
            use n64.controller
            static move_x: i32 = 0
            const DEAD_ZONE: i32 = 10
            entry {
                controller.init()
                loop {
                    controller.poll()
                    let pad = controller.read(0)
                    let raw_x: i32 = pad.stick_x as i32
                    if raw_x > DEAD_ZONE or raw_x < -DEAD_ZONE {
                        move_x = raw_x
                    }
                }
            }
        """, "dead zone pattern")


# ══════════════════════════════════════════════════════════════════════════════
# rdpq module
# ══════════════════════════════════════════════════════════════════════════════

class TestRdpqPatterns:
    def test_fill_mode_rectangle(self):
        """set_mode_fill → fill_rectangle pattern compiles."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            entry {
                display.init(0, 2, 2, 0, 0)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.set_mode_fill(0xFF0000FF)
                    rdpq.fill_rectangle(0, 0, 320, 240)
                    rdpq.detach_show()
                }
            }
        """, "fill mode rectangle")

    def test_mode_switch_with_sync_pipe(self):
        """Switching modes requires rdpq.sync_pipe() between them."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            use n64.sprite
            asset spr: Sprite from "test.png"
            entry {
                display.init(0, 2, 2, 0, 0)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.set_mode_fill(0x000000FF)
                    rdpq.fill_rectangle(0, 0, 320, 240)
                    rdpq.sync_pipe()
                    rdpq.set_mode_copy()
                    sprite.blit(spr, 100, 80, 0)
                    rdpq.detach_show()
                }
            }
        """, "mode switch with sync_pipe")

    def test_standard_mode_compiles(self):
        """rdpq.set_mode_standard() compiles."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            entry {
                display.init(0, 2, 2, 0, 0)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.set_mode_standard()
                    rdpq.detach_show()
                }
            }
        """, "standard mode")

    def test_rgba_color_constants(self):
        """RGBA color values compile correctly as u32 literals."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            const BLACK: u32 = 0x000000FF
            const WHITE: u32 = 0xFFFFFFFF
            const RED:   u32 = 0xFF0000FF
            entry {
                display.init(0, 2, 2, 0, 0)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.set_mode_fill(BLACK)
                    rdpq.fill_rectangle(0, 0, 160, 240)
                    rdpq.set_mode_fill(RED)
                    rdpq.fill_rectangle(160, 0, 320, 240)
                    rdpq.detach_show()
                }
            }
        """, "RGBA color constants")


# ══════════════════════════════════════════════════════════════════════════════
# DMA module
# ══════════════════════════════════════════════════════════════════════════════

class TestDmaPatterns:
    def test_correct_dma_sequence_with_alignment(self):
        """Full correct DMA sequence: aligned buf + writeback + read + wait + invalidate."""
        assert_passes("""
            use n64.dma
            use n64.cache

            @aligned(16)
            static rom_data: [4096]u8 = undefined

            fn load_data_from_rom() {
                cache.writeback(&rom_data[0], 4096)
                dma.read(&rom_data[0], 0x10040000, 4096)
                dma.wait()
                cache.invalidate(&rom_data[0], 4096)
            }

            entry {
                load_data_from_rom()
                loop { }
            }
        """, "correct DMA sequence")

    def test_named_constants_for_address_ok(self):
        """Named constants in DMA address/size args no longer trigger false positives."""
        assert_passes("""
            use n64.dma
            use n64.cache

            const ROM_ADDR: i32 = 0x10040000
            const DATA_LEN: i32 = 512

            @aligned(16)
            static buf: [512]u8 = undefined

            entry {
                cache.writeback(&buf[0], DATA_LEN)
                dma.read(&buf[0], ROM_ADDR, DATA_LEN)
                dma.wait()
                cache.invalidate(&buf[0], DATA_LEN)
                loop { }
            }
        """, "named constants in DMA args")

    def test_missing_alignment_triggers_e202(self):
        """Buffer without @aligned(16) triggers E202."""
        assert_fails("""
            use n64.dma
            use n64.cache
            static buf: [4096]u8 = undefined
            entry {
                cache.writeback(buf, 4096)
                dma.read(buf, 0x10040000, 4096)
                dma.wait()
                cache.invalidate(buf, 4096)
                loop { }
            }
        """, "missing @aligned(16) should fail with E202")

    def test_missing_writeback_triggers_e201(self):
        """Missing cache.writeback triggers E201."""
        assert_fails("""
            use n64.dma
            static buf: [4096]u8 = undefined
            entry {
                dma.read(buf, 0x10040000, 4096)
                dma.wait()
                loop { }
            }
        """, "missing cache.writeback should fail with E201")


# ══════════════════════════════════════════════════════════════════════════════
# audio module
# ══════════════════════════════════════════════════════════════════════════════

class TestAudioPatterns:
    def test_correct_audio_init(self):
        """audio.init with valid frequency and buffer count compiles."""
        assert_passes("""
            use n64.audio
            entry {
                audio.init(44100, 4)
                loop { }
            }
        """, "audio.init correct")

    def test_get_buffer_none_check(self):
        """audio.get_buffer() returns *i16 or none; always check before writing."""
        assert_passes("""
            use n64.audio
            entry {
                audio.init(44100, 4)
                loop {
                    let buf: *i16 = audio.get_buffer()
                    if buf == none { }
                }
            }
        """, "audio get_buffer with none check")

    def test_22050_hz_valid(self):
        """22050 Hz is a valid audio frequency."""
        assert_passes("""
            use n64.audio
            entry {
                audio.init(22050, 2)
                loop { }
            }
        """, "22050 Hz audio")

    def test_32000_hz_valid(self):
        """32000 Hz is a valid audio frequency."""
        assert_passes("""
            use n64.audio
            entry {
                audio.init(32000, 4)
                loop { }
            }
        """, "32000 Hz audio")


# ══════════════════════════════════════════════════════════════════════════════
# EEPROM module
# ══════════════════════════════════════════════════════════════════════════════

class TestEepromPatterns:
    def test_correct_eeprom_present_check_before_use(self):
        """eeprom.present() must be checked before read/write."""
        assert_passes("""
            use n64.eeprom
            @aligned(8)
            static buf: [8]u8 = undefined
            entry {
                if eeprom.present() {
                    eeprom.read(0, &buf[0])
                }
                loop { }
            }
        """, "eeprom.present check before read")

    def test_eeprom_write_with_presence_check(self):
        """Writing to EEPROM with presence check compiles."""
        assert_passes("""
            use n64.eeprom
            @aligned(8)
            static save: [8]u8 = undefined
            entry {
                if eeprom.present() {
                    save[0] = 0xDE
                    save[1] = 0xAD
                    eeprom.write(0, &save[0])
                }
                loop { }
            }
        """, "eeprom.write with presence check")

    def test_eeprom_type_detect(self):
        """eeprom.type_detect() compiles and returns i32."""
        assert_passes("""
            use n64.eeprom
            static etype: i32 = 0
            entry {
                if eeprom.present() {
                    etype = eeprom.type_detect()
                }
                loop { }
            }
        """, "eeprom.type_detect")


# ══════════════════════════════════════════════════════════════════════════════
# sprite module
# ══════════════════════════════════════════════════════════════════════════════

class TestSpritePatterns:
    def test_asset_sprite_blit_in_copy_mode(self):
        """Asset sprite blitted in copy mode — correct pattern."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            use n64.sprite
            asset player: Sprite from "player.png"
            entry {
                display.init(0, 2, 3, 0, 1)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.set_mode_copy()
                    sprite.blit(player, 160, 120, 0)
                    rdpq.detach_show()
                }
            }
        """, "asset sprite blit in copy mode")

    def test_multiple_asset_sprites(self):
        """Multiple asset sprites all compile and are in scope."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            use n64.sprite
            asset bg:     Sprite from "bg.png"
            asset player: Sprite from "player.png"
            asset enemy:  Sprite from "enemy.png"
            entry {
                display.init(0, 2, 3, 0, 1)
                rdpq.init()
                loop {
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.set_mode_copy()
                    sprite.blit(bg,     0,   0,   0)
                    sprite.blit(player, 160, 120, 0)
                    sprite.blit(enemy,  100, 80,  0)
                    rdpq.detach_show()
                }
            }
        """, "multiple asset sprites")


# ══════════════════════════════════════════════════════════════════════════════
# Initialization order patterns
# ══════════════════════════════════════════════════════════════════════════════

class TestInitializationOrder:
    def test_full_game_init_sequence(self):
        """Full recommended init sequence compiles: display → rdpq → controller → timer → audio."""
        assert_passes("""
            use n64.display
            use n64.rdpq
            use n64.controller
            use n64.timer
            use n64.audio
            use n64.rumble
            entry {
                display.init(0, 2, 3, 0, 1)
                rdpq.init()
                controller.init()
                timer.init()
                audio.init(44100, 4)
                rumble.init()
                loop {
                    controller.poll()
                    let pad = controller.read(0)
                    let dt: f32 = timer.delta()
                    let buf: *i16 = audio.get_buffer()
                    let fb = display.get()
                    rdpq.attach_clear(fb)
                    rdpq.set_mode_fill(0x000000FF)
                    rdpq.fill_rectangle(0, 0, 320, 240)
                    rdpq.detach_show()
                }
            }
        """, "full game init sequence")


# ══════════════════════════════════════════════════════════════════════════════
# math module — fixed-point trig/sqrt, float helpers, deterministic RNG
# ══════════════════════════════════════════════════════════════════════════════

class TestMathPatterns:
    def test_math_float_and_fixed_and_rng(self):
        assert_passes("""
            use n64.math
            entry {
                let a: f32 = 2.0
                let s: f32 = math.sqrt_f(a)
                let c: f32 = math.clamp_f(a, 0.0, 1.0)
                let p: f32 = math.pow_f(a, 3.0)
                let fl: f32 = math.floor_f(a)
                let fs: fix16.16 = math.fix_sin(1)
                let fq: fix16.16 = math.fix_sqrt(4)
                math.rand_seed(42)
                let r: i32 = math.rand_range(0, 10)
                let rf: f32 = math.rand_f()
                let n: u32 = math.rand()
            }
        """, "math builtins: fixed/float/rng")

    def test_deref_write_then_free(self):
        # Regression: newline-delimited parsing — `*p = v` then `free(p)`.
        assert_passes("""
            entry {
                let p: *mut i32 = alloc(i32)
                *p = 42
                *p = *p * 2
                free(p)
            }
        """, "deref-write then free no longer triggers spurious E010")
