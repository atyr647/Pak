/**
 * pak_rand.h — Pak runtime PRNG (xorshift32) + helpers.
 *
 * Dependency-free, deterministic, fast. Seedable for reproducible gameplay.
 * All functions are static inline so they compile away when unused.
 */
#pragma once
#include <stdint.h>

/* Global PRNG state. Nonzero default seed (xorshift must never be 0). */
static uint32_t __pak_rng_state = 0x2545F491u;

static inline void __pak_srand(uint32_t seed) {
    __pak_rng_state = seed ? seed : 0x2545F491u;
}

/** Next 32-bit pseudo-random value (xorshift32). */
static inline uint32_t __pak_rand(void) {
    uint32_t x = __pak_rng_state;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    __pak_rng_state = x;
    return x;
}

/** Uniform integer in [lo, hi). Returns lo if hi <= lo. */
static inline int32_t __pak_rand_range(int32_t lo, int32_t hi) {
    if (hi <= lo) return lo;
    return lo + (int32_t)(__pak_rand() % (uint32_t)(hi - lo));
}

/** Uniform float in [0, 1). */
static inline float __pak_rand_f(void) {
    return (float)(__pak_rand() >> 8) / 16777216.0f;  /* 24-bit mantissa */
}
