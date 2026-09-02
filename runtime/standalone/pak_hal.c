#include "pak_hal.h"
#include "vi.h"
#include "si.h"
#include <string.h>

/* ── Global render state ──────────────────────────────────────── */
uint16_t  _pak_fill_color  = 0xFFFF;   /* white by default */
display_t _pak_current_fb  = 0;

/* ── display ──────────────────────────────────────────────────── */

void display_init(int res, int bpp, int bufs, int gamma, int filters) {
    (void)res; (void)bpp; (void)bufs; (void)gamma; (void)filters;
    vi_init();
}

display_t display_get(void) {
    return vi_next_buf();
}

void display_show(display_t fb) {
    vi_show(fb);
}

void display_close(void) {
    /* Blank VI */
    /* IO_WRITE(VI_CTRL, VI_CTRL_BLANK); — let the caller decide */
}

/* ── joypad ───────────────────────────────────────────────────── */

void joypad_init(void) {
    si_init();
}

void joypad_poll(void) {
    si_poll();
}

joypad_buttons_t joypad_get_status(int port) {
    return si_read(port);
}

/* ── rdpq (software renderer) ─────────────────────────────────── */

void rdpq_init(void)  { /* nothing extra needed */ }
void rdpq_close(void) { /* nothing extra needed */ }

void rdpq_attach(display_t fb) {
    _pak_current_fb = fb;
}

void rdpq_attach_clear(display_t fb, uint32_t color) {
    _pak_current_fb = fb;
    uint16_t px = color32_to_16(color);
    int n = PAK_SCREEN_W * PAK_SCREEN_H;
    uint16_t *p = fb;
    for (int i = 0; i < n; i++) p[i] = px;
}

void rdpq_detach(void) {
    _pak_current_fb = 0;
}

void rdpq_detach_show(void) {
    display_t fb = _pak_current_fb;
    _pak_current_fb = 0;
    if (fb) vi_show(fb);
}

void rdpq_set_mode_fill(uint32_t color) {
    _pak_fill_color = color32_to_16(color);
}

void rdpq_fill_rectangle(int x0, int y0, int x1, int y1) {
    if (!_pak_current_fb) return;

    /* Clamp to screen */
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > PAK_SCREEN_W) x1 = PAK_SCREEN_W;
    if (y1 > PAK_SCREEN_H) y1 = PAK_SCREEN_H;
    if (x0 >= x1 || y0 >= y1) return;

    uint16_t *fb = _pak_current_fb;
    for (int y = y0; y < y1; y++) {
        uint16_t *row = fb + y * PAK_SCREEN_W + x0;
        int w = x1 - x0;
        for (int x = 0; x < w; x++) row[x] = _pak_fill_color;
    }
}
