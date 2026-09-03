#ifndef PAK_N64_REGS_H
#define PAK_N64_REGS_H

#include <stdint.h>

#define IO_READ(addr)        (*(volatile uint32_t *)(uintptr_t)(addr))
#define IO_WRITE(addr, val)  (*(volatile uint32_t *)(uintptr_t)(addr) = (uint32_t)(val))

/* ── MI  (MIPS Interface) ─────────────────────────────── 0xA4300000 */
#define MI_BASE         0xA4300000u
#define MI_MODE         (MI_BASE + 0x00u)
#define MI_VERSION      (MI_BASE + 0x04u)
#define MI_INTR         (MI_BASE + 0x08u)
#define MI_INTR_MASK    (MI_BASE + 0x0Cu)

/* ── VI  (Video Interface) ────────────────────────────── 0xA4400000 */
#define VI_BASE         0xA4400000u
#define VI_CTRL         (VI_BASE + 0x00u)
#define VI_ORIGIN       (VI_BASE + 0x04u)
#define VI_WIDTH        (VI_BASE + 0x08u)
#define VI_V_INTR       (VI_BASE + 0x0Cu)
#define VI_V_CURRENT    (VI_BASE + 0x10u)
#define VI_BURST        (VI_BASE + 0x14u)
#define VI_V_SYNC       (VI_BASE + 0x18u)
#define VI_H_SYNC       (VI_BASE + 0x1Cu)
#define VI_LEAP         (VI_BASE + 0x20u)
#define VI_H_START      (VI_BASE + 0x24u)
#define VI_V_START      (VI_BASE + 0x28u)
#define VI_V_BURST      (VI_BASE + 0x2Cu)
#define VI_X_SCALE      (VI_BASE + 0x30u)
#define VI_Y_SCALE      (VI_BASE + 0x34u)

#define VI_CTRL_BLANK   0x0000u
#define VI_CTRL_16BPP   0x3202u  /* 16bpp RGBA5551, AA off, non-interlaced */
#define VI_CTRL_32BPP   0x3203u  /* 32bpp RGBA8888 */

/* ── AI  (Audio Interface) ────────────────────────────── 0xA4500000 */
#define AI_BASE         0xA4500000u
#define AI_DRAM_ADDR    (AI_BASE + 0x00u)
#define AI_LEN          (AI_BASE + 0x04u)
#define AI_CONTROL      (AI_BASE + 0x08u)
#define AI_STATUS       (AI_BASE + 0x0Cu)
#define AI_DACRATE      (AI_BASE + 0x10u)
#define AI_BITRATE      (AI_BASE + 0x14u)

/* ── PI  (Peripheral Interface) ───────────────────────── 0xA4600000 */
#define PI_BASE         0xA4600000u
#define PI_DRAM_ADDR    (PI_BASE + 0x00u)
#define PI_CART_ADDR    (PI_BASE + 0x04u)
#define PI_RD_LEN       (PI_BASE + 0x08u)
#define PI_WR_LEN       (PI_BASE + 0x0Cu)
#define PI_STATUS       (PI_BASE + 0x10u)
#define PI_BSD_DOM1_LAT (PI_BASE + 0x14u)
#define PI_BSD_DOM1_PWD (PI_BASE + 0x18u)
#define PI_BSD_DOM1_PGS (PI_BASE + 0x1Cu)
#define PI_BSD_DOM1_RLS (PI_BASE + 0x20u)

#define PI_STATUS_DMA_BUSY  0x01u
#define PI_STATUS_IO_BUSY   0x02u
#define PI_STATUS_CLR_INTR  0x02u
#define PI_STATUS_RESET     0x01u

/* ── SI  (Serial Interface) ───────────────────────────── 0xA4800000 */
#define SI_BASE         0xA4800000u
#define SI_DRAM_ADDR    (SI_BASE + 0x00u)
#define SI_PIF_RD64B    (SI_BASE + 0x04u)   /* write to trigger PIF→DRAM read */
#define SI_PIF_WR64B    (SI_BASE + 0x10u)   /* write to trigger DRAM→PIF write */
#define SI_STATUS       (SI_BASE + 0x18u)

#define SI_STATUS_DMA_BUSY  0x0001u
#define SI_STATUS_RD_BUSY   0x0002u
#define SI_STATUS_DMA_ERR   0x0008u
#define SI_STATUS_INTR      0x1000u

/* ── PIF RAM ──────────────────────────────────────────── 0xBFC007C0 */
#define PIF_RAM         0xBFC007C0u

/* ── RDP (DP) command registers ───────────────────────── 0xA4100000 */
#define DP_BASE         0xA4100000u
#define DP_CMD_START    (DP_BASE + 0x00u)
#define DP_CMD_END      (DP_BASE + 0x04u)
#define DP_CMD_CURRENT  (DP_BASE + 0x08u)
#define DP_STATUS       (DP_BASE + 0x0Cu)

#define DP_STATUS_XBUS_DMA    0x001u
#define DP_STATUS_FREEZE      0x002u
#define DP_STATUS_FLUSH       0x004u
#define DP_STATUS_PIPE_BUSY   0x100u
#define DP_STATUS_CMD_BUSY    0x200u
#define DP_STATUS_CBUF_READY  0x400u

/* ── SP  (Signal Processor) ───────────────────────────── 0xA4040000 */
#define SP_BASE         0xA4040000u
#define SP_MEM_ADDR     (SP_BASE + 0x00u)
#define SP_DRAM_ADDR    (SP_BASE + 0x04u)
#define SP_RD_LEN       (SP_BASE + 0x08u)
#define SP_WR_LEN       (SP_BASE + 0x0Cu)
#define SP_STATUS       (SP_BASE + 0x10u)

#define SP_STATUS_HALT  0x01u

/* ── RDRAM ──────────────────────────────────────────────────────── */
#define RDRAM_SIZE      0x00400000u  /* 4 MB */

#endif /* PAK_N64_REGS_H */
