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

/* Pak's rdpq.attach_clear(surface, color) attaches and clears to that colour,
 * which is what the standalone HAL does. libdragon's rdpq_attach_clear takes
 * a Z SURFACE as its second argument and clears the colour buffer to black,
 * so the two names meant different things and the colour Pak passed was being
 * handed over as a pointer. Attaching and filling here keeps one meaning. */
static inline void pak_rdpq_attach_clear(surface_t *fb, uint32_t color) {
    rdpq_attach(fb, NULL);
    rdpq_set_mode_fill(color_from_packed32(color));
    rdpq_fill_rectangle(0, 0, fb->width, fb->height);
}

/* ── the raw RDP surface ──────────────────────────────────────────────────── */
/* Pak's rdpq.set_tile_mask / set_texture_image / set_tri_z / triangle_tex_z
 * name the RDP's own command fields, in screen-space integers, because that is
 * what the standalone HAL emits: it writes the command words itself. libdragon
 * reaches the same commands through its own shapes -- a tileparms struct, and
 * rdpq_triangle over float vertex arrays that the RSP turns into the edge and
 * coefficient blocks -- so these adapt one to the other. Without them the raw
 * surface was standalone-only and examples/chroma/church.pk64 could not be
 * built for libdragon at all. */

/* SET_TILE. libdragon takes tmem address and pitch in BYTES; the RDP field
 * (and so Pak's argument) counts 64-bit words, hence the x8. cms/cmt are the
 * GBI clamp/mirror bit pair: bit 1 clamp, bit 0 mirror. */
static inline void pak_rdpq_set_tile_mask(uint32_t tile, uint32_t fmt, uint32_t size,
                                          uint32_t line, uint32_t tmem_addr,
                                          uint32_t palette, uint32_t cms, uint32_t cmt,
                                          uint32_t mask_s, uint32_t mask_t)
{
    rdpq_tileparms_t parms = {0};
    parms.palette  = (uint8_t)palette;
    parms.s.clamp  = (cms >> 1) & 1;
    parms.s.mirror = cms & 1;
    parms.s.mask   = (uint8_t)mask_s;
    parms.t.clamp  = (cmt >> 1) & 1;
    parms.t.mirror = cmt & 1;
    parms.t.mask   = (uint8_t)mask_t;
    rdpq_set_tile((rdpq_tile_t)tile, (tex_format_t)((fmt << 2) | size),
                  (int32_t)(tmem_addr * 8), (uint16_t)(line * 8), &parms);
}

/* SET_TEXTURE_IMAGE. libdragon also encodes a height, which the RDP ignores --
 * it is there for libdragon's own command validator. Pak's surface carries no
 * height (neither does the RDP command), so this passes the width; the only
 * consequence is that the validator's bounds hint is wrong for a non-square
 * source image. */
static inline void pak_rdpq_set_texture_image(uint32_t addr, uint32_t fmt,
                                              uint32_t size, uint32_t width)
{
    rdpq_set_texture_image_raw(0, PhysicalAddr((void *)addr),
                               (tex_format_t)((fmt << 2) | size),
                               (uint16_t)width, (uint16_t)width);
}

/* Pak's set_tri_z sets the three vertex depths for the NEXT triangle, matching
 * the standalone HAL, which holds them in statics because the RDP takes them
 * inside the triangle command rather than as a command of their own. */
static int32_t _pak_tri_z[3];

static inline void pak_rdpq_set_tri_z(int32_t z0, int32_t z1, int32_t z2) {
    _pak_tri_z[0] = z0; _pak_tri_z[1] = z1; _pak_tri_z[2] = z2;
}

/* Vertex layout {X, Y, S, T, W, Z}: pos at 0, tex (S,T,W) at 2, Z at 5.
 * W is 1 because Pak's surface takes screen-space S/T, already divided.
 * rdpq_triangle scales Z by 0x7FFF, so a 15-bit depth goes in as z/32767. */
static inline void pak_rdpq_triangle_tex_z(uint32_t tile,
    int32_t x0, int32_t y0, int32_t s0, int32_t t0,
    int32_t x1, int32_t y1, int32_t s1, int32_t t1,
    int32_t x2, int32_t y2, int32_t s2, int32_t t2)
{
    rdpq_trifmt_t fmt = {0};
    fmt.pos_offset   = 0;
    fmt.shade_offset = -1;
    fmt.tex_offset   = 2;
    fmt.tex_tile     = (rdpq_tile_t)tile;
    fmt.tex_mipmaps  = 0;
    fmt.z_offset     = 5;
    float v0[6] = { (float)x0, (float)y0, (float)s0, (float)t0, 1.0f, _pak_tri_z[0] / 32767.0f };
    float v1[6] = { (float)x1, (float)y1, (float)s1, (float)t1, 1.0f, _pak_tri_z[1] / 32767.0f };
    float v2[6] = { (float)x2, (float)y2, (float)s2, (float)t2, 1.0f, _pak_tri_z[2] / 32767.0f };
    rdpq_triangle(&fmt, v0, v1, v2);
}

/* Standard 1-cycle mode with the Z buffer on, which is one call on the
 * standalone HAL and two here. */
static inline void pak_rdpq_set_mode_standard_z(void) {
    rdpq_set_mode_standard();
    rdpq_mode_zbuf(true, true);
}

/* Pak's clear_z() takes no argument: it fills with the farthest depth, which
 * is what a depth buffer is cleared to. libdragon spells that value out. */
static inline void pak_rdpq_clear_z(void) {
    rdpq_clear_z(0xFFFC);
}
