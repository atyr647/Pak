/*
 * libdragon.h — Pak standalone shim
 *
 * When compiled with -I pak/runtime/ this file shadows the real libdragon.h,
 * redirecting all API calls to the Pak N64 HAL.  No libdragon installation
 * required.
 */
#ifndef LIBDRAGON_H
#define LIBDRAGON_H

#include "pak_hal.h"

/* Additional types that libdragon.h provides and generated code may use */
typedef display_t         display_context_t; /* legacy alias */
typedef uint32_t          color_t;           /* RGBA8888 */

/* surface_t: in libdragon this is a richer struct; we alias to display_t */
typedef struct {
    display_t pixels;
    int       width;
    int       height;
} surface_t;

/* RGBA helper macro (matches libdragon's RGBA(r,g,b,a)) */
#define RGBA32(r,g,b,a) (((uint32_t)(r)<<24)|((uint32_t)(g)<<16)|((uint32_t)(b)<<8)|(uint32_t)(a))

#endif /* LIBDRAGON_H */
