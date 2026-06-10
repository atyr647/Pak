/* pak_compat.h — force-included compatibility layer for building pak 0.1.0
 * C output against a current libdragon (e.g. the one at /opt/n64).
 *
 * pak 0.1.0 targets an older libdragon API in two places that current
 * libdragon changed:
 *   1. The joypad API: pak emits `joypad_get_status()` returning a
 *      `joypad_status_t` with `.held` / `.pressed` sub-structs and analog
 *      `stick_x/stick_y`. Current libdragon renamed this to
 *      `joypad_get_inputs()` + `joypad_get_buttons_held/pressed()`.
 *   2. pak's runtime `pak_math.h` references tiny3d (T3DMat4 etc.) types in
 *      `static inline` helpers that a 2D game never calls but the compiler
 *      still parses, so they must at least be declared.
 *
 * This header is injected via `-include` before the generated translation
 * unit, so the definitions exist before pak_math.h and the game code use
 * them. It is a no-op of redefinition risk: current libdragon defines
 * neither `joypad_status_t` nor the T3D* types.
 */
#ifndef PAK_COMPAT_H
#define PAK_COMPAT_H

#include <libdragon.h>

/* ── tiny3d type stubs (only needed so pak_math.h's unused 3D inlines parse) ── */
#ifndef PAK_T3D_STUB
#define PAK_T3D_STUB
typedef struct { float v[2]; } T3DVec2;
typedef struct { float v[3]; } T3DVec3;
typedef struct { float m[4][4]; } T3DMat4;
typedef struct { uint16_t i[4][4]; uint16_t f[4][4]; } T3DMat4FP;
static inline void t3d_mat4_identity(T3DMat4 *m) { (void)m; }
static inline void t3d_mat4_rotate(T3DMat4 *m, const T3DVec3 *a, float r) { (void)m; (void)a; (void)r; }
static inline void t3d_mat4_to_fixed(T3DMat4FP *fp, const T3DMat4 *s) { (void)fp; (void)s; }
static inline void t3d_mat4_scale(T3DMat4 *m, float x, float y, float z) { (void)m; (void)x; (void)y; (void)z; }
#endif

/* ── joypad_status_t / joypad_get_status over the modern joypad API ── */
#ifndef PAK_JOYPAD_STATUS_T
#define PAK_JOYPAD_STATUS_T
typedef struct {
    struct {
        unsigned a:1, b:1, z:1, start:1;
        unsigned up:1, down:1, left:1, right:1;
        unsigned l:1, r:1;
        unsigned c_up:1, c_down:1, c_left:1, c_right:1;
    } held, pressed;
    int stick_x;
    int stick_y;
} joypad_status_t;

static inline joypad_status_t joypad_get_status(joypad_port_t port) {
    joypad_status_t s;
    joypad_buttons_t h  = joypad_get_buttons_held(port);
    joypad_buttons_t p  = joypad_get_buttons_pressed(port);
    joypad_inputs_t  in = joypad_get_inputs(port);

    s.held.a = h.a;         s.held.b = h.b;
    s.held.z = h.z;         s.held.start = h.start;
    s.held.up = h.d_up;     s.held.down = h.d_down;
    s.held.left = h.d_left; s.held.right = h.d_right;
    s.held.l = h.l;         s.held.r = h.r;
    s.held.c_up = h.c_up;       s.held.c_down = h.c_down;
    s.held.c_left = h.c_left;   s.held.c_right = h.c_right;

    s.pressed.a = p.a;         s.pressed.b = p.b;
    s.pressed.z = p.z;         s.pressed.start = p.start;
    s.pressed.up = p.d_up;     s.pressed.down = p.d_down;
    s.pressed.left = p.d_left; s.pressed.right = p.d_right;
    s.pressed.l = p.l;         s.pressed.r = p.r;
    s.pressed.c_up = p.c_up;       s.pressed.c_down = p.c_down;
    s.pressed.c_left = p.c_left;   s.pressed.c_right = p.c_right;

    s.stick_x = in.stick_x;
    s.stick_y = in.stick_y;
    return s;
}
#endif

/* ── API signature bridges (old pak API → current libdragon) ──────────────────
 * Each wrapper inline is defined BEFORE its #define, so the inline body binds to
 * the real libdragon symbol; later call sites in the generated code expand to
 * the wrapper. (The preprocessor is top-to-bottom, so this avoids recursion.)
 */
#ifndef PAK_API_BRIDGES
#define PAK_API_BRIDGES

/* display_init: pak passes int enums; current libdragon takes resolution_t etc. */
static inline void pak_display_init(int res, int bpp, int nbuf, int gamma, int filt) {
    resolution_t r = RESOLUTION_320x240;
    if (res == 1) { resolution_t hi = {640, 480, false}; r = hi; }
    display_init(r,
                 (bitdepth_t)(bpp >= 3 ? DEPTH_32_BPP : DEPTH_16_BPP),
                 (uint32_t)nbuf, (gamma_t)gamma, (filter_options_t)filt);
}
#define display_init(a,b,c,d,e) pak_display_init((a),(b),(c),(d),(e))

/* rdpq colours: pak passes packed 0xRRGGBBAA; current libdragon takes color_t. */
static inline void pak_rdpq_set_fill_color(uint32_t c) {
    rdpq_set_fill_color(color_from_packed32(c));
}
#define rdpq_set_fill_color(c) pak_rdpq_set_fill_color((uint32_t)(c))

static inline void pak_rdpq_set_mode_fill(uint32_t c) {
    rdpq_set_mode_fill(color_from_packed32(c));
}
#define rdpq_set_mode_fill(c) pak_rdpq_set_mode_fill((uint32_t)(c))

/* rdpq_attach_clear: current libdragon needs an explicit (NULL) z-buffer. */
static inline void pak_rdpq_attach_clear(surface_t *s) { rdpq_attach_clear(s, NULL); }
#define rdpq_attach_clear(s) pak_rdpq_attach_clear(s)

/* eeprom_init: current libdragon has no init step. */
#define eeprom_init() ((void)0)

/* audio_get_buffer: old API returned a ready buffer or NULL; new API uses
 * audio_write_begin() / audio_write_end().  Lazy-submit pattern: commit the
 * previous frame's buffer on the NEXT call, so the caller fills it in between. */
static int _pak_audio_pending = 0;
static inline short *pak_audio_get_buffer(void) {
    if (_pak_audio_pending) { audio_write_end(); _pak_audio_pending = 0; }
    if (!audio_can_write()) return (short *)0;
    _pak_audio_pending = 1;
    return audio_write_begin();
}
#define audio_get_buffer() pak_audio_get_buffer()

#endif /* PAK_API_BRIDGES */

#endif /* PAK_COMPAT_H */
