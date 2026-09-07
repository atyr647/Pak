/**
 * pak_math.h — Pak runtime math helpers for Vec2/Vec3/Mat4
 *
 * Thin wrappers around Tiny3D's vector and matrix types. All functions are
 * static inline so they compile away when unused.
 *
 * EVERY declaration below needs T3DVec3/T3DMat4/T3DMat4FP, so the
 * whole file is conditional on Tiny3D being available. It used to guard only
 * the #include and then use the types unconditionally, which meant the header
 * -- included by every file the C backend emits -- did not compile at all for
 * a project without Tiny3D. Since `tiny3d = false` is the default `pak init`
 * writes, that was every default project.
 *
 * PAK_HAS_TINY3D is defined by the generated Makefile when pak.toml asks for
 * tiny3d. __has_include is the fallback for a hand-rolled build.
 *
 * Requires:  t3d/t3d.h  (for T3DVec3/T3DMat4/T3DMat4FP; T3DVec2 is defined here)
 *            math.h     (sqrtf)
 */
#pragma once
#include <stdint.h>
#include <math.h>

/* ── scalar helpers ───────────────────────────────────────────────────────── */
/* These need nothing but <stdint.h>, so they sit outside the Tiny3D guard.
 * The C backend used to emit MIN()/MAX() for math.min_i32 / math.max_i32 --
 * macros that libdragon does not define and nothing else did either, so the
 * call was an implicit declaration that only a warning flagged. Inline
 * functions also evaluate each argument exactly once, which a macro would
 * not. */

static inline int32_t pak_min_i32(int32_t a, int32_t b) { return a < b ? a : b; }
static inline int32_t pak_max_i32(int32_t a, int32_t b) { return a > b ? a : b; }
static inline float   pak_min_f(float a, float b)       { return a < b ? a : b; }
static inline float   pak_max_f(float a, float b)       { return a > b ? a : b; }

#if !defined(PAK_HAS_TINY3D) && defined(__has_include)
#  if __has_include(<t3d/t3d.h>)
#    define PAK_HAS_TINY3D 1
#  endif
#endif

#ifdef PAK_HAS_TINY3D
#include <t3d/t3d.h>

/* ── Vec3 ─────────────────────────────────────────────────────────────────── */

static inline T3DVec3 pak_vec3_add(T3DVec3 a, T3DVec3 b) {
    return (T3DVec3){{a.v[0]+b.v[0], a.v[1]+b.v[1], a.v[2]+b.v[2]}};
}
static inline T3DVec3 pak_vec3_sub(T3DVec3 a, T3DVec3 b) {
    return (T3DVec3){{a.v[0]-b.v[0], a.v[1]-b.v[1], a.v[2]-b.v[2]}};
}
static inline T3DVec3 pak_vec3_scale(T3DVec3 v, float s) {
    return (T3DVec3){{v.v[0]*s, v.v[1]*s, v.v[2]*s}};
}
static inline float pak_vec3_length(T3DVec3 v) {
    return sqrtf(v.v[0]*v.v[0] + v.v[1]*v.v[1] + v.v[2]*v.v[2]);
}
static inline T3DVec3 pak_vec3_normalize(T3DVec3 v) {
    float len = pak_vec3_length(v);
    if (len < 1e-8f) return (T3DVec3){{0,0,0}};
    return pak_vec3_scale(v, 1.0f / len);
}
static inline float pak_vec3_dot(T3DVec3 a, T3DVec3 b) {
    return a.v[0]*b.v[0] + a.v[1]*b.v[1] + a.v[2]*b.v[2];
}
static inline T3DVec3 pak_vec3_cross(T3DVec3 a, T3DVec3 b) {
    return (T3DVec3){{
        a.v[1]*b.v[2] - a.v[2]*b.v[1],
        a.v[2]*b.v[0] - a.v[0]*b.v[2],
        a.v[0]*b.v[1] - a.v[1]*b.v[0]
    }};
}
static inline float pak_vec3_distance(T3DVec3 a, T3DVec3 b) {
    return pak_vec3_length(pak_vec3_sub(b, a));
}
static inline T3DVec3 pak_vec3_direction(T3DVec3 from, T3DVec3 to) {
    return pak_vec3_normalize(pak_vec3_sub(to, from));
}
static inline T3DVec3 pak_vec3_lerp(T3DVec3 a, T3DVec3 b, float t) {
    return pak_vec3_add(a, pak_vec3_scale(pak_vec3_sub(b, a), t));
}

/* ── Vec2 ─────────────────────────────────────────────────────────────────── */

/* Tiny3D has no 2D vector type -- T3DVec3 and T3DVec4 are typedefs of
 * libdragon's fm_vec3_t / fm_vec4_t, and there is no fm_vec2_t. Everything
 * below named it anyway, so this whole block was six declarations of an
 * unknown type, and any program including this header failed to compile
 * before the compiler reached a line of generated code. It is ours: shaped
 * like the Tiny3D ones so `.v[0]` reads the same way in all three. */
#ifndef PAK_T3DVEC2_DEFINED
#define PAK_T3DVEC2_DEFINED
typedef struct { float v[2]; } T3DVec2;
#endif

static inline T3DVec2 pak_vec2_add(T3DVec2 a, T3DVec2 b) {
    return (T3DVec2){{a.v[0]+b.v[0], a.v[1]+b.v[1]}};
}
static inline T3DVec2 pak_vec2_sub(T3DVec2 a, T3DVec2 b) {
    return (T3DVec2){{a.v[0]-b.v[0], a.v[1]-b.v[1]}};
}
static inline T3DVec2 pak_vec2_scale(T3DVec2 v, float s) {
    return (T3DVec2){{v.v[0]*s, v.v[1]*s}};
}
static inline float pak_vec2_length(T3DVec2 v) {
    return sqrtf(v.v[0]*v.v[0] + v.v[1]*v.v[1]);
}

/* ── Mat4 ─────────────────────────────────────────────────────────────────── */

/** Return an identity T3DMat4. */
static inline T3DMat4 pak_mat4_identity(void) {
    T3DMat4 m = {0};
    t3d_mat4_identity(&m);
    return m;
}

static inline void pak_mat4_rotate_y(T3DMat4 *m, float angle_rad) {
    t3d_mat4_rotate(m, &(T3DVec3){{0,1,0}}, angle_rad);
}
static inline void pak_mat4_rotate_x(T3DMat4 *m, float angle_rad) {
    t3d_mat4_rotate(m, &(T3DVec3){{1,0,0}}, angle_rad);
}
static inline void pak_mat4_rotate_z(T3DMat4 *m, float angle_rad) {
    t3d_mat4_rotate(m, &(T3DVec3){{0,0,1}}, angle_rad);
}

static inline void pak_mat4_set_position(T3DMat4 *m, T3DVec3 pos) {
    m->m[3][0] = pos.v[0];
    m->m[3][1] = pos.v[1];
    m->m[3][2] = pos.v[2];
}
static inline void pak_mat4_translate(T3DMat4 *m, float x, float y, float z) {
    m->m[3][0] += x;
    m->m[3][1] += y;
    m->m[3][2] += z;
}
static inline void pak_mat4_scale_uniform(T3DMat4 *m, float s) {
    t3d_mat4_scale(m, s, s, s);
}

/** Allocate a T3DMat4FP in uncached RDRAM and convert from a T3DMat4. */
static inline T3DMat4FP *pak_mat4_to_fp_alloc(const T3DMat4 *src) {
    T3DMat4FP *fp = malloc_uncached(sizeof(T3DMat4FP));
    t3d_mat4_to_fixed(fp, src);
    return fp;
}

#endif /* PAK_HAS_TINY3D */
