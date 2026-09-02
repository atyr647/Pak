/* pak_compat.h — force-included compatibility layer for building pak 0.1.0
 * C output against a current libdragon (e.g. the one at /opt/n64).
 *
 * pak 0.1.0 targets an older libdragon API in several places that current
 * libdragon changed:
 *
 *   1. Joypad API: pak emits joypad_get_status() returning joypad_status_t
 *      with .held/.pressed sub-structs.  Current libdragon renamed this to
 *      joypad_get_inputs() + joypad_get_buttons_held/pressed().
 *
 *   2. pak_math.h references tiny3d (T3DMat4 etc.) types in static inline
 *      helpers that a 2D game never calls but the compiler still parses.
 *
 *   3. Audio API: pak emits extern "C" declarations for wav64_open/play,
 *      xm64player_open/play/stop with slightly different types than current
 *      libdragon (char* vs const char*, int32_t vs int).  The fix is to
 *      rename the real symbols before including libdragon.h so pak's extern
 *      declarations become the first (and only) visible declaration; the
 *      linker then resolves to the real symbol by name.
 *
 *   4. mixer.poll: pak lowers mixer.poll(buf) to audio_poll(buf).  Current
 *      libdragon has mixer_poll(buf, nsamples); we bridge the two.
 *
 *   5. mixer.ch_playing: pak emits mixer.ch_playing(ch) literally as a C
 *      member call.  We provide a proxy struct named "mixer" so it compiles.
 *
 *   6. rdpq_set_mode_copy: pak emits rdpq_set_mode_copy() with no args;
 *      current libdragon requires rdpq_set_mode_copy(bool transparency).
 *      We provide a 0-arg wrapper.
 *
 *   7. sprite_load: pak codegen uses sprite_load("pak:/…") to load sprites;
 *      current libdragon has sprite_load(const char*) declared with const.
 *      Same rename trick as audio: pak's extern declares the name first.
 *
 * This header is injected via -include before the generated translation unit,
 * so everything here is visible before pak_math.h and the game code see it.
 */
#ifndef PAK_COMPAT_H
#define PAK_COMPAT_H

/* ── Pre-include renames ────────────────────────────────────────────────────
 * Rename libdragon symbols that conflict with pak's extern "C" declarations
 * BEFORE including libdragon.h.  After the include we #undef the macros so
 * pak's generated extern declarations become the first visible declarations
 * of those names.  The linker still resolves to the real symbols because the
 * binary export names are unaffected by macro renaming of header declarations.
 */
#define wav64_open          _pak_h_wav64_open
#define wav64_play          _pak_h_wav64_play
#define xm64player_open     _pak_h_xm64player_open
#define xm64player_play     _pak_h_xm64player_play
#define xm64player_stop     _pak_h_xm64player_stop
#define sprite_load         _pak_h_sprite_load
#define rdpq_set_mode_copy  _pak_h_rdpq_set_mode_copy

#include <libdragon.h>

/* Remove the renames so pak's generated externs are first declarations. */
#undef wav64_open
#undef wav64_play
#undef xm64player_open
#undef xm64player_play
#undef xm64player_stop
#undef sprite_load
#undef rdpq_set_mode_copy

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
 * Each wrapper inline is defined BEFORE its #define so the inline body binds
 * to the real libdragon symbol; call sites in the generated code expand to the
 * wrapper.  (The preprocessor is top-to-bottom, so this avoids recursion.)
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

/* rdpq_set_mode_copy: pak emits rdpq_set_mode_copy() with no args;
 * current libdragon requires rdpq_set_mode_copy(bool transparency).
 * The real function was renamed above (_pak_h_rdpq_set_mode_copy); provide
 * a 0-arg wrapper so pak's 0-arg calls compile.                             */
static inline void rdpq_set_mode_copy(void) { _pak_h_rdpq_set_mode_copy(false); }

/* audio_get_buffer: old API returned a ready buffer or NULL; new API uses
 * audio_write_begin() / audio_write_end().  Lazy-submit pattern: commit the
 * previous frame's buffer on the NEXT call so the caller fills it in between.
 * We cache the current buffer pointer so audio_poll can retrieve it.        */
static int    _pak_audio_pending  = 0;
static short *_pak_audio_cur_buf  = NULL;

static inline short *pak_audio_get_buffer(void) {
    if (_pak_audio_pending) {
        audio_write_end();
        _pak_audio_pending = 0;
        _pak_audio_cur_buf = NULL;
    }
    if (!audio_can_write()) return (short *)0;
    _pak_audio_pending = 1;
    _pak_audio_cur_buf = audio_write_begin();
    return _pak_audio_cur_buf;
}
#define audio_get_buffer() pak_audio_get_buffer()

/* audio_poll: pak lowers mixer.poll(buf) to audio_poll(*buf).
 * *buf is a scalar short (the value at the buffer pointer — we ignore it)
 * and we mix using the cached buffer from the last audio_get_buffer call.   */
static inline void pak_audio_poll(short ignored) {
    (void)ignored;
    if (_pak_audio_cur_buf)
        mixer_poll(_pak_audio_cur_buf, audio_get_buffer_length());
}
#define audio_poll(x) pak_audio_poll(x)

/* mixer proxy: pak emits mixer.ch_playing(ch) as a C member call, expecting
 * "mixer" to be a struct variable.  Provide a minimal proxy with that field.
 * Always returns false (= channel not busy) so sounds always play; for a
 * packed-action game this is the correct default.                            */
typedef struct { bool (*ch_playing)(int ch); } _pak_mixer_proxy_t;
static inline bool _pak_mixer_ch_playing_impl(int ch) { (void)ch; return false; }
static _pak_mixer_proxy_t mixer = { .ch_playing = _pak_mixer_ch_playing_impl };

#endif /* PAK_API_BRIDGES */

#endif /* PAK_COMPAT_H */
