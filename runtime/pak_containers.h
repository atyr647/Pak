/**
 * pak_containers.h — Pak runtime helpers for FixedMap and Pool containers.
 *
 * FixedList and RingBuffer are simple enough to be inlined directly in the
 * generated code.  FixedMap and Pool need small generic-style helpers that
 * operate on the generated structs via pointer + capacity args.
 *
 * All helpers are static inline to compile away when unused.
 */
#pragma once
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

/* ── FixedMap helpers ────────────────────────────────────────────────────────
 *
 * A FixedMap(K, V, N) generates:
 *   typedef struct { K keys[N]; V values[N]; bool occupied[N]; int32_t count; } FixedMap_K_V_N;
 *
 * pak_map_set / pak_map_get operate through void pointers + element sizes so
 * they work with any generated map type without requiring C generics.
 */

/**
 * Set key→value in a FixedMap.
 * map_ptr  : pointer to the generated FixedMap struct
 * cap      : maximum number of entries (N)
 * key_ptr  : pointer to the key (size = key_sz bytes)
 * val_ptr  : pointer to the value (size = val_sz bytes)
 * key_sz   : sizeof(K)
 * val_sz   : sizeof(V)
 * Returns true on success, false if map is full and key not already present.
 */
static inline bool pak_map_set_raw(void *map_ptr, int32_t cap,
                                   const void *key_ptr, const void *val_ptr,
                                   int32_t key_sz, int32_t val_sz) {
    /* Layout: keys[cap], values[cap], occupied[cap], count */
    uint8_t *keys     = (uint8_t *)map_ptr;
    uint8_t *values   = keys + (size_t)cap * (size_t)key_sz;
    bool    *occupied = (bool *)(values + (size_t)cap * (size_t)val_sz);
    int32_t *count    = (int32_t *)(occupied + (size_t)cap);

    /* Linear probe: first check for existing key */
    for (int32_t i = 0; i < cap; i++) {
        if (occupied[i] && memcmp(keys + (size_t)i * (size_t)key_sz, key_ptr, (size_t)key_sz) == 0) {
            memcpy(values + (size_t)i * (size_t)val_sz, val_ptr, (size_t)val_sz);
            return true;
        }
    }
    /* Find empty slot */
    for (int32_t i = 0; i < cap; i++) {
        if (!occupied[i]) {
            memcpy(keys + (size_t)i * (size_t)key_sz, key_ptr, (size_t)key_sz);
            memcpy(values + (size_t)i * (size_t)val_sz, val_ptr, (size_t)val_sz);
            occupied[i] = true;
            (*count)++;
            return true;
        }
    }
    return false;  /* full */
}

/**
 * Get a value from a FixedMap by key.
 * Returns pointer to the value slot, or NULL if not found.
 */
static inline void *pak_map_get_raw(void *map_ptr, int32_t cap,
                                    const void *key_ptr,
                                    int32_t key_sz, int32_t val_sz) {
    uint8_t *keys     = (uint8_t *)map_ptr;
    uint8_t *values   = keys + (size_t)cap * (size_t)key_sz;
    bool    *occupied = (bool *)(values + (size_t)cap * (size_t)val_sz);

    for (int32_t i = 0; i < cap; i++) {
        if (occupied[i] && memcmp(keys + (size_t)i * (size_t)key_sz, key_ptr, (size_t)key_sz) == 0) {
            return values + (size_t)i * (size_t)val_sz;
        }
    }
    return NULL;
}

/*
 * Convenience macros for generated code.
 * Generated code calls:  pak_map_set(&map, cap, key, value)
 *                        pak_map_get(&map, cap, key)
 * These macros forward to the raw helpers using typeof to get sizes.
 */
#define pak_map_set(map_ptr, cap, key, val) \
    pak_map_set_raw((map_ptr), (cap), &(key), &(val), \
                    (int32_t)sizeof(key), (int32_t)sizeof(val))

#define pak_map_get(map_ptr, cap, key) \
    pak_map_get_raw((map_ptr), (cap), &(key), \
                    (int32_t)sizeof(key), \
                    (int32_t)sizeof((map_ptr)->values[0]))

#define pak_map_remove(map_ptr, cap, key) \
    pak_map_remove_raw((map_ptr), (cap), &(key), \
                       (int32_t)sizeof(key), (int32_t)sizeof((map_ptr)->values[0]))
#define pak_map_has(map_ptr, cap, key) \
    pak_map_has_raw((map_ptr), (cap), &(key), \
                    (int32_t)sizeof(key), (int32_t)sizeof((map_ptr)->values[0]))

/* String-keyed variants (FixedMap with *c_char keys) */
#define pak_map_set_str(map_ptr, cap, key, val) \
    pak_map_set_str_raw((map_ptr), (cap), &(key), &(val), \
                        (int32_t)sizeof((map_ptr)->keys[0]), (int32_t)sizeof(val))
#define pak_map_get_str(map_ptr, cap, key) \
    pak_map_get_str_raw((map_ptr), (cap), &(key), \
                        (int32_t)sizeof((map_ptr)->keys[0]), (int32_t)sizeof((map_ptr)->values[0]))
#define pak_map_remove_str(map_ptr, cap, key) \
    pak_map_remove_str_raw((map_ptr), (cap), &(key), \
                           (int32_t)sizeof((map_ptr)->keys[0]), (int32_t)sizeof((map_ptr)->values[0]))
#define pak_map_has_str(map_ptr, cap, key) \
    pak_map_has_str_raw((map_ptr), (cap), &(key), \
                        (int32_t)sizeof((map_ptr)->keys[0]), (int32_t)sizeof((map_ptr)->values[0]))

/** Remove a key (memcmp keys). Returns true if a key was removed. */
static inline bool pak_map_remove_raw(void *map_ptr, int32_t cap,
                                      const void *key_ptr,
                                      int32_t key_sz, int32_t val_sz) {
    uint8_t *keys     = (uint8_t *)map_ptr;
    uint8_t *values   = keys + (size_t)cap * (size_t)key_sz;
    bool    *occupied = (bool *)(values + (size_t)cap * (size_t)val_sz);
    int32_t *count    = (int32_t *)(occupied + (size_t)cap);
    for (int32_t i = 0; i < cap; i++) {
        if (occupied[i] && memcmp(keys + (size_t)i * (size_t)key_sz, key_ptr, (size_t)key_sz) == 0) {
            occupied[i] = false;
            (*count)--;
            return true;
        }
    }
    return false;
}

static inline bool pak_map_has_raw(void *map_ptr, int32_t cap,
                                   const void *key_ptr,
                                   int32_t key_sz, int32_t val_sz) {
    return pak_map_get_raw(map_ptr, cap, key_ptr, key_sz, val_sz) != NULL;
}

/* ── String-keyed FixedMap (keys are char*, compared by content) ──────────────
 * For FixedMap(*c_char, V, N): keys[] holds char* and the *content* must be
 * compared (strcmp), not the pointer. key_ptr points to the char* variable.
 */
static inline bool pak_map_set_str_raw(void *map_ptr, int32_t cap,
                                       const void *key_ptr, const void *val_ptr,
                                       int32_t key_sz, int32_t val_sz) {
    char  **keys     = (char **)map_ptr;
    uint8_t *values  = (uint8_t *)map_ptr + (size_t)cap * (size_t)key_sz;
    bool    *occupied = (bool *)(values + (size_t)cap * (size_t)val_sz);
    int32_t *count    = (int32_t *)(occupied + (size_t)cap);
    const char *k = *(const char *const *)key_ptr;
    for (int32_t i = 0; i < cap; i++) {
        if (occupied[i] && keys[i] && k && strcmp(keys[i], k) == 0) {
            memcpy(values + (size_t)i * (size_t)val_sz, val_ptr, (size_t)val_sz);
            return true;
        }
    }
    for (int32_t i = 0; i < cap; i++) {
        if (!occupied[i]) {
            keys[i] = (char *)k;
            memcpy(values + (size_t)i * (size_t)val_sz, val_ptr, (size_t)val_sz);
            occupied[i] = true;
            (*count)++;
            return true;
        }
    }
    return false;
}

static inline void *pak_map_get_str_raw(void *map_ptr, int32_t cap,
                                        const void *key_ptr,
                                        int32_t key_sz, int32_t val_sz) {
    char  **keys     = (char **)map_ptr;
    uint8_t *values  = (uint8_t *)map_ptr + (size_t)cap * (size_t)key_sz;
    bool    *occupied = (bool *)(values + (size_t)cap * (size_t)val_sz);
    const char *k = *(const char *const *)key_ptr;
    for (int32_t i = 0; i < cap; i++) {
        if (occupied[i] && keys[i] && k && strcmp(keys[i], k) == 0) {
            return values + (size_t)i * (size_t)val_sz;
        }
    }
    return NULL;
}

static inline bool pak_map_remove_str_raw(void *map_ptr, int32_t cap,
                                          const void *key_ptr,
                                          int32_t key_sz, int32_t val_sz) {
    char  **keys     = (char **)map_ptr;
    uint8_t *values  = (uint8_t *)map_ptr + (size_t)cap * (size_t)key_sz;
    bool    *occupied = (bool *)(values + (size_t)cap * (size_t)val_sz);
    int32_t *count    = (int32_t *)(occupied + (size_t)cap);
    const char *k = *(const char *const *)key_ptr;
    for (int32_t i = 0; i < cap; i++) {
        if (occupied[i] && keys[i] && k && strcmp(keys[i], k) == 0) {
            occupied[i] = false;
            (*count)--;
            return true;
        }
    }
    return false;
}

static inline bool pak_map_has_str_raw(void *map_ptr, int32_t cap,
                                       const void *key_ptr,
                                       int32_t key_sz, int32_t val_sz) {
    return pak_map_get_str_raw(map_ptr, cap, key_ptr, key_sz, val_sz) != NULL;
}

/* ── Pool helpers ────────────────────────────────────────────────────────────
 *
 * A Pool(T, N) generates:
 *   typedef struct { T data[N]; int32_t len; } Pool_T_N;
 *
 * Acquire returns a pointer to a zeroed slot; release swaps with last.
 */

static inline void *pak_pool_acquire_raw(void *pool_ptr, int32_t cap,
                                         int32_t elem_sz) {
    uint8_t *data  = (uint8_t *)pool_ptr;
    int32_t *count = (int32_t *)(data + (size_t)cap * (size_t)elem_sz);
    if (*count >= cap) return NULL;
    void *slot = data + (size_t)(*count) * (size_t)elem_sz;
    memset(slot, 0, (size_t)elem_sz);
    (*count)++;
    return slot;
}

static inline void pak_pool_release_raw(void *pool_ptr, int32_t cap,
                                        int32_t elem_sz, void *item) {
    uint8_t *data  = (uint8_t *)pool_ptr;
    int32_t *count = (int32_t *)(data + (size_t)cap * (size_t)elem_sz);
    if (*count <= 0) return;
    /* Swap with last active element */
    (*count)--;
    void *last = data + (size_t)(*count) * (size_t)elem_sz;
    if (item != last) {
        uint8_t tmp[64];  /* small stack buffer for swap */
        size_t  remaining = (size_t)elem_sz;
        uint8_t *a = (uint8_t *)item, *b = (uint8_t *)last;
        while (remaining > 0) {
            size_t chunk = remaining < sizeof(tmp) ? remaining : sizeof(tmp);
            memcpy(tmp, a, chunk);
            memcpy(a,   b, chunk);
            memcpy(b, tmp, chunk);
            a += chunk; b += chunk; remaining -= chunk;
        }
    }
}

#define pak_pool_acquire(pool_ptr) \
    pak_pool_acquire_raw((pool_ptr), \
        (int32_t)(sizeof((pool_ptr)->data)/sizeof((pool_ptr)->data[0])), \
        (int32_t)sizeof((pool_ptr)->data[0]))

#define pak_pool_release(pool_ptr, item_ptr) \
    pak_pool_release_raw((pool_ptr), \
        (int32_t)(sizeof((pool_ptr)->data)/sizeof((pool_ptr)->data[0])), \
        (int32_t)sizeof((pool_ptr)->data[0]), \
        (item_ptr))
