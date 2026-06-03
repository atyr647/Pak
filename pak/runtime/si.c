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
    _pif_buf[63] = 0xFE;  /* end-of-commands marker */
}

void si_poll(void) {
    /*
     * Build the PIF command block:
     *   Port 0: tx=1 (cmd 0x01), rx=4  → bytes 0-5
     *   Ports 1-3: 0xFF (skip)
     *   Byte 63:   0xFE (end)
     *
     * After execution PIF fills in the rx bytes in-place.
     */
    _pif_buf[0]  = 0x01;   /* tx length */
    _pif_buf[1]  = 0x04;   /* rx length */
    _pif_buf[2]  = 0x01;   /* command: read buttons */
    _pif_buf[3]  = 0x00;   /* response byte 0 — filled by PIF */
    _pif_buf[4]  = 0x00;   /* response byte 1 */
    _pif_buf[5]  = 0x00;   /* response byte 2 (stick X) */
    _pif_buf[6]  = 0x00;   /* response byte 3 (stick Y) */
    _pif_buf[7]  = 0xFF;   /* skip port 1 */
    _pif_buf[8]  = 0xFF;   /* skip port 2 */
    _pif_buf[9]  = 0xFF;   /* skip port 3 */
    _pif_buf[63] = 0xFE;   /* end */

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

    /* ── 3. Parse port 0 (bytes 3-6 in the command block) ── */
    uint8_t hi = _pif_buf[3];
    uint8_t lo = _pif_buf[4];
    int8_t  sx = (int8_t)_pif_buf[5];
    int8_t  sy = (int8_t)_pif_buf[6];

    _state[0].a       = (hi >> 7) & 1;
    _state[0].b       = (hi >> 6) & 1;
    _state[0].z       = (hi >> 5) & 1;
    _state[0].start   = (hi >> 4) & 1;
    _state[0].up      = (hi >> 3) & 1;
    _state[0].down    = (hi >> 2) & 1;
    _state[0].left    = (hi >> 1) & 1;
    _state[0].right   = (hi >> 0) & 1;
    /* lo byte: -, -, L, R, CU, CD, CL, CR */
    _state[0].l       = (lo >> 5) & 1;
    _state[0].r       = (lo >> 4) & 1;
    _state[0].c_up    = (lo >> 3) & 1;
    _state[0].c_down  = (lo >> 2) & 1;
    _state[0].c_left  = (lo >> 1) & 1;
    _state[0].c_right = (lo >> 0) & 1;
    _state[0].stick_x = sx;
    _state[0].stick_y = sy;

    /* Ports 1-3 remain zeroed (not polled in this MVP) */
}

joypad_buttons_t si_read(int port) {
    if (port >= 0 && port < 4)
        return _state[port];
    joypad_buttons_t empty;
    memset(&empty, 0, sizeof(empty));
    return empty;
}
