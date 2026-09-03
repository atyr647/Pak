#ifndef PAK_HAL_H
#define PAK_HAL_H

/*
 * pak_hal.h — Pak standalone N64 HAL
 *
 * Declares every function that pak-generated C calls, using the same names
 * as libdragon so no changes to codegen output are needed.
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stddef.h>

#include "vi.h"   /* display_t, vi_* */
#include "si.h"   /* joypad_buttons_t, si_* */

/* ── display API ───────────────────────────────────────────────── */

/* display.init(res, bpp, bufs, gamma, filters) — we always do 320×240 16bpp */
void      display_init(int res, int bpp, int bufs, int gamma, int filters);
display_t display_get(void);
void      display_show(display_t fb);
void      display_close(void);

/* ── joypad API ────────────────────────────────────────────────── */

void             joypad_init(void);
void             joypad_poll(void);
/* joypad_get_status returns the button struct for the given port */
joypad_buttons_t joypad_get_status(int port);

/* ── rdpq API (software renderer) ─────────────────────────────── */

/* Current draw colour for fill ops (set by rdpq_set_mode_fill / attach_clear) */
extern uint16_t _pak_fill_color;
extern display_t _pak_current_fb;

void rdpq_init(void);
void rdpq_close(void);

/* Attach a framebuffer as the current render target */
void rdpq_attach(display_t fb);
/* Attach and clear in one call — color is 0xRRGGBBAA */
void rdpq_attach_clear(display_t fb, uint32_t color);
/* Detach current target */
void rdpq_detach(void);
/* Detach and flip (calls vi_show internally) */
void rdpq_detach_show(void);

/* Fill a rectangle with the current fill colour (pixel coords, inclusive) */
void rdpq_fill_rectangle(int x0, int y0, int x1, int y1);

/* Set fill mode with an RGBA8 colour */
void rdpq_set_mode_fill(uint32_t color);

/* No-ops for this runtime — included so generated code links cleanly */
static inline void rdpq_set_mode_standard(void) {}
static inline void rdpq_set_mode_copy(void)     {}
static inline void rdpq_sync_full(void)         {}
static inline void rdpq_sync_pipe(void)         {}
static inline void rdpq_sync_tile(void)         {}
static inline void rdpq_sync_load(void)         {}

/* ── n64sys ─────────────────────────────────────────────────────── */
/* Stub timer helpers so n64.timer-using code links */
static inline uint32_t TICKS_READ(void)           { return 0; }
static inline float    TIMER_MICROS(uint32_t tks) { (void)tks; return 0.0f; }

/* ── math ───────────────────────────────────────────────────────── */
#include <math.h>

/* ── debug ──────────────────────────────────────────────────────── */
static inline void debugf(const char *fmt, ...) { (void)fmt; }

#endif /* PAK_HAL_H */
