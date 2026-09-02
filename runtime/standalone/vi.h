#ifndef PAK_VI_H
#define PAK_VI_H

#include <stdint.h>

#define PAK_SCREEN_W   320
#define PAK_SCREEN_H   240
#define PAK_NUM_BUFS   3

/* A framebuffer handle is just a pointer to the 16bpp pixel array. */
typedef uint16_t *display_t;

void   vi_init(void);
display_t vi_next_buf(void);
void   vi_show(display_t fb);
void   vi_wait_vblank(void);

/* Pack RGBA (0–255 each) into RGB5551 (N64 16bpp pixel) */
static inline uint16_t rgba_to_16(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    return (uint16_t)(((r >> 3) << 11) | ((g >> 3) << 6) | ((b >> 3) << 1) | (a >> 7));
}

/* Unpack a 0xRRGGBBAA uint32 into RGB5551 */
static inline uint16_t color32_to_16(uint32_t c) {
    return rgba_to_16((c >> 24) & 0xFF, (c >> 16) & 0xFF,
                      (c >>  8) & 0xFF,  c        & 0xFF);
}

#endif /* PAK_VI_H */
