/**
 * pak_libdragon.h — Pak's calling convention on top of libdragon's real API.
 *
 * Pak's HAL contract is one surface with two backends: the same
 * `display.init(0, 2, 3, 0, 1)` has to mean the same thing whether it lowers
 * to libdragon C or to runtime/standalone/runtime.pk64. Where libdragon's own
 * signature cannot express that contract directly, the adapter lives here
 * rather than in the code generator, so it is ordinary C that a person can
 * read, and so a variable argument works exactly like a literal one.
 *
 * Three cases need it today:
 *
 *   display_init  libdragon's resolution_t is a struct ({w, h, interlaced}),
 *                 not an integer, so Pak's documented integer cannot be cast
 *                 to it at all. The table below is the mapping N64_HARDWARE.md
 *                 documents.
 *
 *   joypad        libdragon has no single call returning held/pressed/released
 *                 together; it has four. Pak's `controller.read(port)` is one
 *                 struct, matching the standalone HAL's ControllerState, so
 *                 this composes it.
 *
 *   colours       rdpq takes color_t where Pak passes a packed 0xRRGGBBAA.
 *
 * Requires: libdragon.h
 */
#pragma once
#include <libdragon.h>
#include <stdint.h>
#include <stdbool.h>

/* ── display ──────────────────────────────────────────────────────────────── */

/**
 * Pak's `display.init(resolution, bit_depth, num_buffers, gamma, filters)`.
 * The integers are the ones N64_HARDWARE.md documents; they are Pak's ABI and
 * do not track libdragon's enum values, which have changed before.
 */
static inline void pak_display_init(int res, int bit_depth, int num_buffers,
                                    int gamma, int filters)
{
    resolution_t r;
    switch (res) {
        case 1:  r = RESOLUTION_640x480; break;
        case 2:  r = RESOLUTION_256x240; break;
        case 3:  r = RESOLUTION_512x240; break;
        case 4:  r = RESOLUTION_512x480; break;
        case 5:  r = RESOLUTION_640x240; break;
        default: r = RESOLUTION_320x240; break;
    }
    /* Pak documents 2 = 16bpp and 4 = 32bpp (bytes-per-pixel, which is what
     * libdragon's enum used to be). Accept libdragon's current enum values
     * too, so a program written against either number does the right thing. */
    bitdepth_t d = (bit_depth == 4 || bit_depth == 1) ? DEPTH_32_BPP : DEPTH_16_BPP;

    gamma_t g;
    switch (gamma) {
        case 1:  g = GAMMA_CORRECT; break;
        case 2:
        case 3:  g = GAMMA_CORRECT_DITHER; break;
        default: g = GAMMA_NONE; break;
    }

    filter_options_t f;
    switch (filters) {
        case 1:  f = FILTERS_RESAMPLE; break;
        case 2:  f = FILTERS_DEDITHER; break;
        case 3:  f = FILTERS_RESAMPLE_ANTIALIAS; break;
        case 4:  f = FILTERS_RESAMPLE_ANTIALIAS_DEDITHER; break;
        default: f = FILTERS_DISABLED; break;
    }

    display_init(r, d, (uint32_t)num_buffers, g, f);
}

/* ── controller ───────────────────────────────────────────────────────────── */

/**
 * One button set, with Pak's field names. libdragon spells the d-pad
 * d_up/d_down/d_left/d_right; Pak's surface (and the standalone HAL's
 * ButtonState) spells it up/down/left/right, so the same Pak source has to
 * read on both backends.
 */
typedef struct {
    bool a, b, z, start;
    bool up, down, left, right;
    bool l, r;
    bool c_up, c_down, c_left, c_right;
} pak_joypad_buttons_t;

/**
 * What Pak's `controller.read(port)` returns. Field names match the standalone
 * HAL's ControllerState so the same Pak source reads on both backends.
 */
typedef struct {
    pak_joypad_buttons_t held;
    pak_joypad_buttons_t pressed;
    pak_joypad_buttons_t released;
    int stick_x;
    int stick_y;
} pak_joypad_status_t;

static inline pak_joypad_buttons_t pak_joypad_buttons(joypad_buttons_t b)
{
    pak_joypad_buttons_t o;
    o.a = b.a;   o.b = b.b;   o.z = b.z;   o.start = b.start;
    o.up = b.d_up;      o.down  = b.d_down;
    o.left = b.d_left;  o.right = b.d_right;
    o.l = b.l;   o.r = b.r;
    o.c_up = b.c_up;       o.c_down  = b.c_down;
    o.c_left = b.c_left;   o.c_right = b.c_right;
    return o;
}

static inline pak_joypad_status_t pak_joypad_get_status(int port)
{
    joypad_port_t p = (joypad_port_t)port;
    joypad_inputs_t in = joypad_get_inputs(p);
    pak_joypad_status_t s;
    s.held     = pak_joypad_buttons(joypad_get_buttons_held(p));
    s.pressed  = pak_joypad_buttons(joypad_get_buttons_pressed(p));
    s.released = pak_joypad_buttons(joypad_get_buttons_released(p));
    s.stick_x  = in.stick_x;
    s.stick_y  = in.stick_y;
    return s;
}

/* ── audio ────────────────────────────────────────────────────────────────── */

/**
 * Pak's `audio.get_buffer()`, which N64_HARDWARE.md documents as returning
 * `none` when a buffer is not ready. libdragon has no audio_get_buffer; it has
 * audio_write_begin(), which assumes the caller already checked
 * audio_can_write(). This is that pair, with Pak's documented contract.
 */
static inline short *pak_audio_get_buffer(void) {
    return audio_can_write() ? audio_write_begin() : (short *)0;
}

/* ── colours ──────────────────────────────────────────────────────────────── */
/* Pak passes a packed 0xRRGGBBAA; rdpq takes a color_t. */

static inline void pak_rdpq_set_fill_color(uint32_t c) {
    rdpq_set_fill_color(color_from_packed32(c));
}
static inline void pak_rdpq_set_mode_fill(uint32_t c) {
    rdpq_set_mode_fill(color_from_packed32(c));
}
