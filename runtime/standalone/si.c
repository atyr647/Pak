#include "si.h"
#include "n64_regs.h"
#include <stdint.h>
#include <string.h>

/*
 * PIF-RAM command buffer — must be 8-byte aligned for SI DMA.
 *
 * Layout for reading all four controller ports:
 *
 *   [chan_cmd_len, resp_len, cmd, resp0..respN]  per channel
 *   0xFF = skip channel
 *   0xFE = end-of-commands (byte 63)
 *
 * For a single "read buttons" transaction on port N:
 *   tx=1 byte (cmd 0x01), rx=4 bytes (hi_btns, lo_btns, sx, sy)
 */
static uint8_t _pif_buf[64] __attribute__((aligned(8)));

static joypad_buttons_t _state[4];

/* ── Helpers ──────────────────────────────────────────────────── */

static void si_dma_wait(void) {
    while (IO_READ(SI_STATUS) & (SI_STATUS_DMA_BUSY | SI_STATUS_RD_BUSY)) {}
}

static void si_clear_intr(void) {
    IO_WRITE(SI_STATUS, 0);  /* writing any value clears the interrupt flag */
}

/* ── Public API ───────────────────────────────────────────────── */

void si_init(void) {
    memset(_pif_buf, 0, sizeof(_pif_buf));
}

void si_poll(void) {
    /*
     * Build the PIF command block. One "read buttons" command per port,
     * back to back:
     *
     *   [tx=1][rx=4][cmd=0x01][r0][r1][r2][r3]   = 7 bytes, advances one channel
     *
     * so ports 0-3 occupy bytes 0-27. Byte 28 is 0xFE (end of commands) and
     * byte 63 is the run bit. 0xFF is a padding byte that does NOT advance
     * the channel, and 0x00 is "skip this channel" -- using 0xFF to skip
     * ports 1-3 (as this did) left them unpolled and their state zeroed,
     * and putting 0xFE in byte 63 meant the run bit was never set at all.
     *
     * After execution PIF fills in the rx bytes in place and ORs an error
     * code into the rx byte: 0x80 = no device, 0x40 = timeout.
     */
    for (int p = 0; p < 4; p++) {
        uint8_t *c = &_pif_buf[p * 7];
        c[0] = 0x01;   /* tx length */
        c[1] = 0x04;   /* rx length */
        c[2] = 0x01;   /* command: read buttons */
        c[3] = 0xFF;   /* response bytes — filled by PIF */
        c[4] = 0xFF;
        c[5] = 0xFF;
        c[6] = 0xFF;
    }
    _pif_buf[28] = 0xFE;   /* end of commands */
    _pif_buf[63] = 0x01;   /* run */

    /* ── 1. Write command block: RDRAM → PIF RAM ── */
    si_dma_wait();
    IO_WRITE(SI_DRAM_ADDR, (uint32_t)(uintptr_t)_pif_buf & 0x00FFFFFFu);
    IO_WRITE(SI_PIF_WR64B, PIF_RAM & 0x1FFFFFFFu);
    si_dma_wait();
    si_clear_intr();

    /* ── 2. Read response:  PIF RAM → RDRAM ── */
    IO_WRITE(SI_DRAM_ADDR, (uint32_t)(uintptr_t)_pif_buf & 0x00FFFFFFu);
    IO_WRITE(SI_PIF_RD64B, PIF_RAM & 0x1FFFFFFFu);
    si_dma_wait();
    si_clear_intr();

    /* ── 3. Parse every port ── */
    for (int p = 0; p < 4; p++) {
        const uint8_t *c = &_pif_buf[p * 7];

        if (c[1] & 0xC0) {          /* no device, or the transfer timed out */
            memset(&_state[p], 0, sizeof(_state[p]));
            continue;
        }

        uint8_t hi = c[3];
        uint8_t lo = c[4];
        int8_t  sx = (int8_t)c[5];
        int8_t  sy = (int8_t)c[6];

        _state[p].a       = (hi >> 7) & 1;
        _state[p].b       = (hi >> 6) & 1;
        _state[p].z       = (hi >> 5) & 1;
        _state[p].start   = (hi >> 4) & 1;
        _state[p].up      = (hi >> 3) & 1;
        _state[p].down    = (hi >> 2) & 1;
        _state[p].left    = (hi >> 1) & 1;
        _state[p].right   = (hi >> 0) & 1;
        /* lo byte: -, -, L, R, CU, CD, CL, CR */
        _state[p].l       = (lo >> 5) & 1;
        _state[p].r       = (lo >> 4) & 1;
        _state[p].c_up    = (lo >> 3) & 1;
        _state[p].c_down  = (lo >> 2) & 1;
        _state[p].c_left  = (lo >> 1) & 1;
        _state[p].c_right = (lo >> 0) & 1;
        _state[p].stick_x = sx;
        _state[p].stick_y = sy;
    }
}

joypad_buttons_t si_read(int port) {
    if (port >= 0 && port < 4)
        return _state[port];
    joypad_buttons_t empty;
    memset(&empty, 0, sizeof(empty));
    return empty;
}
