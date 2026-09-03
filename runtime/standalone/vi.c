#include "vi.h"
#include "n64_regs.h"
#include <stdint.h>
#include <string.h>

/*
 * Triple framebuffer pool.
 * Each buffer is 320×240 × 2 bytes = 150 KB.
 * Aligned to 64 bytes so cache-writeback works without partial-line straddles.
 */
static uint16_t _fb[PAK_NUM_BUFS][PAK_SCREEN_W * PAK_SCREEN_H]
    __attribute__((aligned(64)));

static int _shown = 0;   /* index currently displayed by VI */
static int _draw  = 1;   /* index we're drawing into */

/*
 * NTSC 320×240 16bpp timing.
 * These values are standard for CIC-NUS-6102 homebrews; same as libdragon.
 */
void vi_init(void) {
    IO_WRITE(VI_CTRL,    VI_CTRL_BLANK);   /* blank while configuring */
    IO_WRITE(VI_ORIGIN,  (uint32_t)(uintptr_t)_fb[0] & 0x00FFFFFFu);
    IO_WRITE(VI_WIDTH,   PAK_SCREEN_W);
    IO_WRITE(VI_V_INTR,  0x00000200u);
    IO_WRITE(VI_V_CURRENT, 0x00000000u);
    IO_WRITE(VI_BURST,   0x03E52239u);
    IO_WRITE(VI_V_SYNC,  0x0000020Du);
    IO_WRITE(VI_H_SYNC,  0x00000C15u);
    IO_WRITE(VI_LEAP,    0x0C150C15u);
    IO_WRITE(VI_H_START, 0x006C02ECu);
    IO_WRITE(VI_V_START, 0x002501FFu);
    IO_WRITE(VI_V_BURST, 0x000E0204u);
    IO_WRITE(VI_X_SCALE, 0x00000200u);
    IO_WRITE(VI_Y_SCALE, 0x00000400u);
    IO_WRITE(VI_CTRL,    VI_CTRL_16BPP);   /* enable display */

    /* Clear all buffers to black */
    memset(_fb, 0, sizeof(_fb));
}

display_t vi_next_buf(void) {
    return _fb[_draw];
}

void vi_wait_vblank(void) {
    /* NTSC: 525 half-lines per frame; active video ends around half-line 480.
     * Wait until we are safely past the active region, then for the wrap. */
    uint32_t line;
    do { line = IO_READ(VI_V_CURRENT) & 0x3FFu; } while (line < 0x1E0u); /* past 480 */
    do { line = IO_READ(VI_V_CURRENT) & 0x3FFu; } while (line >= 0x1E0u); /* new frame */
}

void vi_show(display_t fb) {
    vi_wait_vblank();
    /* Physical address: strip the cached-segment top bits */
    IO_WRITE(VI_ORIGIN, (uint32_t)(uintptr_t)fb & 0x00FFFFFFu);
    /* Advance draw index: skip the buffer that is now on screen */
    _shown = (int)(fb - _fb[0]) / (PAK_SCREEN_W * PAK_SCREEN_H);
    _draw  = (_shown + 1) % PAK_NUM_BUFS;
}
