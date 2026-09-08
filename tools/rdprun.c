/* rdprun — run a display list through angrylion's RDP and dump the framebuffer.
 *
 *   rdprun <rdram.bin> <dl_phys> <dl_len> <fb_phys> <w> <h> <out.ppm>
 *
 * rdram.bin is a flat RDRAM image (the display list, textures and the
 * framebuffer all live inside it, at the physical addresses the program used).
 * The RDP is pointed at [dl_phys, dl_phys+dl_len) and run; the framebuffer is
 * then read back out of the same RDRAM and written as a binary PPM.
 */
#include "n64video.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RDRAM_SIZE 0x800000

static uint8_t rdram[RDRAM_SIZE];
static uint8_t dmem[0x1000];
static uint32_t vi_regs[VI_NUM_REG];
static uint32_t dp_regs[DP_NUM_REG];
static uint32_t *vi_reg_ptr[VI_NUM_REG];
static uint32_t *dp_reg_ptr[DP_NUM_REG];
static uint32_t mi_intr;

static void intr_cb(void) {}

int main(int argc, char **argv)
{
    if (argc != 8) {
        fprintf(stderr, "usage: %s rdram.bin dl_phys dl_len fb_phys w h out.ppm\n", argv[0]);
        return 1;
    }
    const char *rdram_path = argv[1];
    uint32_t dl_phys = (uint32_t)strtoul(argv[2], NULL, 0);
    uint32_t dl_len  = (uint32_t)strtoul(argv[3], NULL, 0);
    uint32_t fb_phys = (uint32_t)strtoul(argv[4], NULL, 0);
    int w = atoi(argv[5]);
    int h = atoi(argv[6]);
    const char *out_path = argv[7];

    FILE *f = fopen(rdram_path, "rb");
    if (!f) { perror("rdram"); return 1; }
    size_t n = fread(rdram, 1, RDRAM_SIZE, f);
    fclose(f);
    fprintf(stderr, "rdram: %zu bytes loaded\n", n);

    for (int i = 0; i < VI_NUM_REG; i++) vi_reg_ptr[i] = &vi_regs[i];
    for (int i = 0; i < DP_NUM_REG; i++) dp_reg_ptr[i] = &dp_regs[i];

    struct n64video_config cfg;
    n64video_config_init(&cfg);
    cfg.gfx.rdram       = rdram;
    cfg.gfx.rdram_size  = RDRAM_SIZE;
    cfg.gfx.dmem        = dmem;
    cfg.gfx.vi_reg      = vi_reg_ptr;
    cfg.gfx.dp_reg      = dp_reg_ptr;
    cfg.gfx.mi_intr_reg = &mi_intr;
    cfg.gfx.mi_intr_cb  = intr_cb;
    cfg.parallel        = false;   /* deterministic, single-threaded */
    cfg.num_workers     = 1;
    cfg.dp.compat       = DP_COMPAT_HIGH;

    n64video_init(&cfg);

    /* Point the DP at the list. Bit 0 of STATUS selects XBUS (RSP DMEM); we
     * want RDRAM, so leave it clear -- exactly what the Pak runtime does when
     * it writes DPC_STATUS with the xbus/freeze/flush clear bits. */
    dp_regs[DP_STATUS]  = 0;
    dp_regs[DP_START]   = dl_phys;
    dp_regs[DP_CURRENT] = dl_phys;
    dp_regs[DP_END]     = dl_phys + dl_len;

    n64video_process_list();

    /* Read the colour image back out of RDRAM: RGBA5551, big-endian halfwords. */
    FILE *o = fopen(out_path, "wb");
    if (!o) { perror("out"); return 1; }
    fprintf(o, "P6\n%d %d\n255\n", w, h);
    long nonzero = 0;
    for (int y = 0; y < h; y++) {
        for (int x = 0; x < w; x++) {
            /* RDRAM is a native-endian word array here, so a byte at N64
             * physical address a lives at a ^ BYTE_ADDR_XOR. */
            uint32_t off = fb_phys + (uint32_t)((y * w + x) * 2);
            uint16_t p = (uint16_t)((rdram[off ^ 3] << 8) | rdram[(off + 1) ^ 3]);
            if (p) nonzero++;
            unsigned r = (p >> 11) & 0x1F, g = (p >> 6) & 0x1F, b = (p >> 1) & 0x1F;
            unsigned char rgb[3] = {
                (unsigned char)((r * 255) / 31),
                (unsigned char)((g * 255) / 31),
                (unsigned char)((b * 255) / 31)
            };
            fwrite(rgb, 1, 3, o);
        }
    }
    fclose(o);
    fprintf(stderr, "wrote %s (%d x %d), %ld non-zero pixels\n", out_path, w, h, nonzero);
    n64video_close();
    return 0;
}
