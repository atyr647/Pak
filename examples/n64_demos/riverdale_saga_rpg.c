/* riverdale_saga_rpg.c — N64 top-down RPG demo, direct framebuffer 640×480
 * Build:
 *   mips64-elf-gcc -O2 -march=vr4300 -mfix4300 -G0 -DN64 \
 *     [-DFORCE_SCENE=N] \
 *     -I/opt/n64/mips64-elf/include \
 *     -L/opt/n64/mips64-elf/lib \
 *     -T/opt/n64/mips64-elf/lib/n64.ld \
 *     riverdale_saga_rpg.c \
 *     -ldragon -lc -lm -ldragonsys \
 *     -o riverdale.elf
 *   n64elfcompress -o . -c 1 riverdale.elf
 *   n64tool --title "RIVERDALE SAGA" --toc --output riverdale.z64 \
 *           --align 256 riverdale.elf
 */
#include <libdragon.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define W 640
#define H 480
#define TS 24  /* tile size */

/* ── Key-light positions for the battle/boss scenes ──
 * The disc art (moon/sun) and the god-rays and the cast shadows all read
 * from these so the light source, its rays, and every shadow stay in sync. */
#define MOON_CX 96
#define MOON_CY 56
#define MOON_R  28
#define SUN_CX  (W-96)
#define SUN_CY  48
#define SUN_R   22

/* RGBA5551 color — R,G,B each 0-31 */
#define C(r,g,b) ((uint16_t)(((r)<<11)|((g)<<6)|((b)<<1)|1))

/* ── Global framebuffer ── */
static uint16_t *fb;
static uint32_t fb_stride;

/* ── Palette ── */
static uint16_t pal(char c) {
    switch(c) {
    /* Grass / nature */
    case 'g': return C(5,17,4);    /* grass mid */
    case 'G': return C(8,22,6);    /* grass bright */
    case 'e': return C(3,12,2);    /* dark grass */
    case 'E': return C(2,8,1);     /* deep shadow grass */
    case 't': return C(4,15,3);    /* tree foliage dark */
    case 'T': return C(3,18,3);    /* tree foliage mid */
    case 'u': return C(10,7,3);    /* tree trunk brown */
    case 'U': return C(7,5,2);     /* tree trunk dark */
    /* Path / dirt */
    case 'd': return C(18,12,6);   /* dirt/path light */
    case 'D': return C(13,9,4);    /* dirt dark */
    case 'q': return C(22,16,8);   /* dry grass/sand */
    /* Water */
    case 'w': return C(6,14,26);   /* water mid */
    case 'W': return C(10,18,30);  /* water highlight */
    case 'v': return C(4,10,20);   /* water dark */
    /* Stone / building */
    case 'k': return C(15,15,15);  /* stone mid */
    case 'K': return C(10,10,10);  /* stone dark */
    case 'l': return C(21,21,21);  /* stone light */
    case 'L': return C(24,22,18);  /* warm stone/stucco */
    case 'm': return C(18,17,16);  /* mortar gray */
    /* Roof */
    case 'r': return C(22,8,4);    /* red roof */
    case 'R': return C(16,5,2);    /* dark red */
    /* Color accents */
    case 'y': return C(28,24,4);   /* yellow */
    case 'Y': return C(22,18,3);   /* gold */
    case 'o': return C(26,14,3);   /* orange */
    case 'c': return C(10,20,28);  /* pale blue */
    case 'p': return C(18,8,24);   /* purple */
    case 'P': return C(12,4,16);   /* dark purple */
    /* Skin / characters */
    case 'f': return C(26,18,12);  /* flesh */
    case 'F': return C(20,13,8);   /* tan/shadow flesh */
    case 'h': return C(12,8,4);    /* hair brown */
    case 'H': return C(20,14,6);   /* hair light */
    case 'Z': return C(28,26,22);  /* white cloth */
    case 'z': return C(20,18,14);  /* off-white cloth */
    /* Enemy colors */
    case 'a': return C(6,20,8);    /* slime green */
    case 'A': return C(4,14,5);    /* slime dark */
    case 'b': return C(20,8,6);    /* goblin skin */
    case 'B': return C(14,5,4);    /* goblin dark */
    case 'n': return C(3,4,16);    /* bat body */
    case 'N': return C(2,3,10);    /* bat dark */
    /* Sky / night */
    case 's': return C(5,8,20);    /* night sky */
    case 'S': return C(3,5,14);    /* deep night */
    case 'x': return C(0,0,0);     /* black */
    case ' ': return C(0,0,0);     /* transparent/black */
    case '.': return C(2,3,5);     /* near black */
    case ',': return C(4,5,8);     /* dark gray-blue */
    case 'i': return C(28,28,28);  /* white/bright */
    case 'I': return C(22,22,24);  /* pale white-blue */
    case 'M': return C(20,22,28);  /* moonlit bright */
    case 'j': return C(14,16,22);  /* moonlit mid */
    /* Day sky */
    case 'O': return C(7,15,28);   /* day sky blue */
    case 'Q': return C(12,20,30);  /* day sky bright */
    case 'X': return C(28,24,10);  /* sun yellow */
    default:  return C(20,20,20);
    }
}

/* ── Drawing primitives ── */
static inline void put(int x, int y, uint16_t col) {
    if ((unsigned)x < W && (unsigned)y < H)
        fb[y * (fb_stride >> 1) + x] = col;
}

static inline uint16_t get(int x, int y) {
    if ((unsigned)x < W && (unsigned)y < H)
        return fb[y * (fb_stride >> 1) + x];
    return 0;
}

static void hline(int x0, int x1, int y, uint16_t col) {
    if ((unsigned)y >= H) return;
    int s = fb_stride >> 1;
    if (x0 > x1) { int t = x0; x0 = x1; x1 = t; }
    if (x0 < 0) x0 = 0;
    if (x1 >= W) x1 = W-1;
    for (int x = x0; x <= x1; x++) fb[y*s+x] = col;
}

static void rect(int x0, int y0, int x1, int y1, uint16_t col) {
    for (int y = y0; y <= y1; y++) hline(x0, x1, y, col);
}

static void disc(int cx, int cy, int r, uint16_t col) {
    for (int dy = -r; dy <= r; dy++) {
        int hw = (int)__builtin_sqrt((double)(r*r - dy*dy));
        hline(cx-hw, cx+hw, cy+dy, col);
    }
}

/* Vertical gradient from color (r0,g0,b0) to (r1,g1,b1) in y range [y0,y1] */
static void vgrad(int x0, int y0, int x1, int y1,
                  int r0, int g0, int b0, int r1, int g1, int b1) {
    for (int y = y0; y <= y1 && y < H; y++) {
        int t = (y1 > y0) ? (y - y0) * 255 / (y1 - y0) : 0;
        int r = r0 + (r1-r0)*t/255;
        int g = g0 + (g1-g0)*t/255;
        int b = b0 + (b1-b0)*t/255;
        hline(x0, x1, y, C(r,g,b));
    }
}

/* ── Math helpers ── */
static int isqrt(int n) {
    if (n <= 0) return 0;
    int x = (int)__builtin_sqrt((double)n);
    while (x*x > n) x--;
    while ((x+1)*(x+1) <= n) x++;
    return x;
}

static const int8_t SIN64[64] = {
     0,  3,  6,  9, 12, 15, 17, 20, 22, 24, 26, 28, 29, 30, 31, 31,
    31, 31, 30, 29, 28, 26, 24, 22, 20, 17, 15, 12,  9,  6,  3,  0,
    -3, -6, -9,-12,-15,-17,-20,-22,-24,-26,-28,-29,-30,-31,-31,-31,
   -31,-31,-30,-29,-28,-26,-24,-22,-20,-17,-15,-12, -9, -6, -3,  0
};
static inline int isin(int a) { return SIN64[a&63]; }
static inline int icos(int a) { return SIN64[(a+16)&63]; }

/* 4×4 Bayer ordered dither matrix (0-15) */
static const uint8_t BAYER4[4][4] = {
    { 0,  8,  2, 10},
    {12,  4, 14,  6},
    { 3, 11,  1,  9},
    {15,  7, 13,  5}
};

/* 8×8 Bayer matrix (0-63) — fine dithering for smooth volumetric glows */
static const uint8_t BAYER8[8][8] = {
    { 0,32, 8,40, 2,34,10,42},
    {48,16,56,24,50,18,58,26},
    {12,44, 4,36,14,46, 6,38},
    {60,28,52,20,62,30,54,22},
    { 3,35,11,43, 1,33, 9,41},
    {51,19,59,27,49,17,57,25},
    {15,47, 7,39,13,45, 5,37},
    {63,31,55,23,61,29,53,21}
};

/* ── Blitter ── */
static void blit(int dx, int dy, const char *const *art, int w, int h, int sc) {
    for (int row = 0; row < h; row++) {
        const char *line = art[row];
        for (int col = 0; col < w; col++) {
            char ch = line[col];
            if (ch == ' ' || ch == '\0') continue;
            uint16_t col16 = pal(ch);
            for (int sy = 0; sy < sc; sy++)
                for (int sx = 0; sx < sc; sx++)
                    put(dx + col*sc + sx, dy + row*sc + sy, col16);
        }
    }
}

static void blitf(int dx, int dy, const char *const *art, int w, int h, int sc) {
    for (int row = 0; row < h; row++) {
        const char *line = art[row];
        for (int col = 0; col < w; col++) {
            char ch = line[w-1-col];
            if (ch == ' ' || ch == '\0') continue;
            uint16_t col16 = pal(ch);
            for (int sy = 0; sy < sc; sy++)
                for (int sx = 0; sx < sc; sx++)
                    put(dx + col*sc + sx, dy + row*sc + sy, col16);
        }
    }
}

/* Robe recolor: swap 'Z'/'z' for custom robe/accent colors */
static void blit_robe(int dx, int dy, const char *const *art, int w, int h, int sc,
                      uint16_t robe, uint16_t robeH) {
    for (int row = 0; row < h; row++) {
        const char *line = art[row];
        for (int col = 0; col < w; col++) {
            char ch = line[col];
            if (ch == ' ' || ch == '\0') continue;
            uint16_t c16;
            if      (ch == 'Z') c16 = robe;
            else if (ch == 'z') c16 = robeH;
            else                c16 = pal(ch);
            for (int sy = 0; sy < sc; sy++)
                for (int sx = 0; sx < sc; sx++)
                    put(dx + col*sc + sx, dy + row*sc + sy, c16);
        }
    }
}

/* Rim lighting pass: brighten edge pixels of a sprite */
static void blit_rim(int dx, int dy, const char *const *art, int w, int h, int sc,
                     uint16_t rim) {
    for (int row = 0; row < h; row++) {
        const char *line = art[row];
        int prevfill = 0;
        for (int col = 0; col < w; col++) {
            char ch = line[col];
            int fill = (ch != ' ' && ch != '\0');
            int nextfill = (col+1 < w) ? (line[col+1] != ' ' && line[col+1] != '\0') : 0;
            if (fill && (!prevfill || !nextfill)) {
                /* edge pixel — apply rim light */
                for (int sy = 0; sy < sc; sy++)
                    for (int sx = 0; sx < sc; sx++)
                        put(dx + col*sc + sx, dy + row*sc + sy, rim);
            }
            prevfill = fill;
        }
    }
}

/* ── Tile art — 8×8 characters, blitted at scale 3 = 24×24 pixels ── */

static const char *A_grass[8] = {
    "gGgGeGgG",
    "GgGgGgGg",
    "gGgGgGgE",
    "EgGgGeGg",
    "gGgGgGgG",
    "GgEgGgGg",
    "gGgGgGgG",
    "GgGgGgGg",
};

static const char *A_flower[8] = {
    "gGgGgGgG",
    "GgGgGgGg",
    "gGgYgGgG",
    "GgGgGgGg",
    "gGgGgGgG",
    "GgGGygGg",
    "gGgGgGgG",
    "GgGgGgGg",
};

static const char *A_path[8] = {
    "dDdDdDdD",
    "DdDdqdDd",
    "dDdDdDdD",
    "qDdDdDdq",
    "dDdqdDdD",
    "DdDdDdDd",
    "dDdDdDqD",
    "DqdDdDdD",
};

static const char *A_water[8] = {
    "wWwvwWwv",
    "WwwWwwWw",
    "wwWwvwWw",
    "vwwwWwwv",
    "wWwwwWwW",
    "WwvwWwww",
    "wwWwwwWw",
    "vwwWwvwW",
};

static const char *A_tree[8] = {
    " .tTt. .",
    ".tTTtT..",
    "tTTTTTt.",
    "TTtTtTTt",
    "tTTTTtTt",
    ".tTTTt..",
    " .uUu. .",
    " .uUu. .",
};

static const char *A_wall[8] = {
    "LlLlLlLl",
    "lLlLlLlL",
    "LlLlLlLl",
    "mmmmmmmm",
    "lLlLlLlL",
    "LlLlLlLl",
    "lLlLlLlL",
    "mmmmmmmm",
};

static const char *A_roof[8] = {
    "rRrRrRrR",
    "RrRrRrRr",
    "rRrRrRrR",
    "RrRrRrRr",
    "rRrRrRrR",
    "RrRrRrRr",
    "rRrRrRrR",
    "RrRrRrRr",
};

static const char *A_door[8] = {
    "LlLlLlLl",
    "LlhhhhlL",
    "Lhyyyyyy",
    "lhyyyyYy",
    "Lhyyyyhy",
    "lhyyyyhy",
    "LhyYyYhy",
    "lDDDDDDl",
};

static const char *A_fence[8] = {
    "u u u u ",
    "u u u u ",
    "uuuuuuuu",
    "u u u u ",
    "u u u u ",
    "uuuuuuuu",
    "u u u u ",
    "        ",
};

/* ── Character sprites — 8×12, blitted at scale 2 = 16×24 ── */

static const char *A_hero_dn[12] = {
    "  hHHh  ",
    " hfffffh",
    " hf..fFh",
    " hff.ffh",
    "  hfffh ",
    " ZZZzZZ ",
    "ZZZZZZZz",
    "ZzZZZZZ ",
    " ZzZZzZ ",
    " zZZZZz ",
    " zkkzkk ",
    " zkzzkk ",
};

static const char *A_hero_up[12] = {
    "  hhHH  ",
    " hHHHhHh",
    " hHhHHHh",
    " hHHHHHh",
    "  hHHhh ",
    " ZZZzZZ ",
    "ZZZZZZZz",
    "ZzZZZZZ ",
    " ZZZZZz ",
    " zZZZzz ",
    " zkkzkk ",
    " zkzzkk ",
};

static const char *A_hero_sd[12] = {
    "   hHhh ",
    "  hffffh",
    "  hf.ffH",
    "  hffffh",
    "  hffhh ",
    "  ZZZzZ ",
    " ZZZZZZz",
    " ZZZZZZz",
    "  ZZZzZ ",
    "  zZZzz ",
    "  zkkzk ",
    "  zkkzk ",
};

static const char *A_villager[12] = {
    "  HhHh  ",
    " HfffffH",
    " Hf..ffh",
    " Hff.fFh",
    "  hfffh ",
    " ZZZzZZ ",
    "ZZZZZZZz",
    "ZzZZZZZ ",
    " ZzZZzZ ",
    " zZZZZz ",
    " zdDzDD ",
    " zdDzdD ",
};

static const char *A_elder[12] = {
    "  iiih  ",
    " iifFFFh",
    " if..FFh",
    " iff.fFh",
    "  hfffh ",
    " pPPpPP ",
    "PPPPPPPp",
    "PpPPPPP ",
    " PpPPpP ",
    " pPPPPp ",
    " pdDpDD ",
    " pdDpdD ",
};

static const char *A_knight[12] = {
    "  kKkk  ",
    " kKKKkk ",
    " kK..Kk ",
    " kKK.KK ",
    "  kKKkk ",
    " lllkll ",
    "lllllllk",
    "lkllllll",
    " llllkll",
    " kllllkl",
    " kllkll ",
    " klklll ",
};

/* Battle sprites — side-view, 10×14, scale 2 = 20×28 */
static const char *A_aria_b[14] = {
    "  .hHHH.",
    " .hffffh",
    ".Hf....h",
    "Hfff..fH",
    ".Hfffffh",
    " Hffffh ",
    ".ZZZZZZ.",
    "ZZZZZZZz",
    "ZZZZZZzZ",
    ".ZZZZzz.",
    " ZZZZzZ ",
    " ZZZZzZ ",
    " zDDDzz ",
    " zDDzDz ",
};

static const char *A_loras_b[14] = {
    "  .hHH. ",
    " .hffffh",
    ".hf....h",
    "hfff..fh",
    ".hfffffh",
    " hffffh ",
    ".zZZZZz.",
    "zZZZZZZZ",
    "zZZZZZZZ",
    ".zZZZZz.",
    " ZzZZZz ",
    " ZzZZZz ",
    " zDDDDz ",
    " zDzDDz ",
};

/* Enemy sprites */
static const char *A_slime[8] = {
    "  .aaa. ",
    " .aAAAA.",
    ".aAA..Aa",
    "aAA..AAA",
    ".aAAAAa.",
    " .aAAA. ",
    "  .aaa. ",
    "        ",
};

static const char *A_goblin[10] = {
    "  .bb.  ",
    " .bBBb. ",
    ".bB..Bb.",
    "bBB..BBb",
    ".bBbbBb.",
    " .bBb.  ",
    ".rbbbrr.",
    ".rbbbr..",
    " .rrrr. ",
    "        ",
};

static const char *A_bat[8] = {
    ".n. . .n.",
    "nn.nnn.nn",
    "n.nnnnn.n",
    " .nNNn. ",
    " .n..n. ",
    " .nnnn. ",
    "  .nn.  ",
    "        ",
};

/* Boss warden — 12×14, scale 2 = 24×28 */
static const char *A_warden[14] = {
    "  .pPPp.  .",
    " .pPPPPp. .",
    ".pP....Pp..",
    "pP..PP..Pp.",
    ".pPPPPPPp..",
    " .pPPPPp.. ",
    " .LlLlLl.. ",
    ".LlLlLlLl..",
    "LlLlLlLlLl.",
    ".lLlLlLlL..",
    " lLLLLLLl. ",
    " .lLLLLl.  ",
    " .lllll.   ",
    "           ",
};

/* ── Sprite wrappers (cy = feet y) ── */
static void draw_hero(int cx, int cy, int dir, int step) {
    const char *const *art = (dir==0)?A_hero_dn:(dir==1)?A_hero_up:A_hero_sd;
    int dx = cx - 8, dy = cy - 24;
    if (dir==2 && (step/8)&1) blitf(dx, dy, art, 8, 12, 2);
    else                       blit (dx, dy, art, 8, 12, 2);
}

static void draw_villager(int cx, int cy, uint16_t robe, uint16_t robeH) {
    int dx = cx - 8, dy = cy - 24;
    blit_robe(dx, dy, A_villager, 8, 12, 2, robe, robeH);
}

static void draw_elder(int cx, int cy) {
    blit(cx-8, cy-24, A_elder, 8, 12, 2);
}

static void draw_knight(int cx, int cy) {
    blit(cx-8, cy-24, A_knight, 8, 12, 2);
}

static void draw_slime(int cx, int cy, int f) {
    int bounce = (isin(f*4) * 2) >> 5;
    blit(cx-8, cy-16+bounce, A_slime, 8, 8, 2);
}

static void draw_goblin(int cx, int cy) {
    blit(cx-8, cy-20, A_goblin, 8, 10, 2);
}

static void draw_bat(int cx, int cy, int f) {
    int flap = (isin(f*6) * 3) >> 5;
    blit(cx-8, cy-16+flap, A_bat, 9, 8, 2);
}

/* ── Shadow ── */
static void gshadow(int cx, int cy, int rw, int rh) {
    for (int dy = -rh; dy <= rh; dy++) {
        int hf = rw * isqrt(rh*rh - dy*dy) / (rh > 0 ? rh : 1);
        int y = cy + dy;
        if ((unsigned)y >= H) continue;
        uint16_t base = get(cx, y);
        /* Darken the base color slightly */
        uint16_t sh = C(
            ((base >> 11) & 0x1F) * 10 / 16,
            ((base >>  6) & 0x1F) * 10 / 16,
            ((base >>  1) & 0x1F) * 10 / 16
        );
        for (int x = cx-hf; x <= cx+hf; x++) {
            if ((unsigned)x < W) {
                uint16_t px = get(x, y);
                int r = ((px >> 11) & 0x1F) * 10 / 16;
                int g = ((px >>  6) & 0x1F) * 10 / 16;
                int b = ((px >>  1) & 0x1F) * 10 / 16;
                put(x, y, C(r, g, b));
            }
        }
    }
}

/* Directional cast shadow: throws a figure's blob shadow onto the ground in
 * the direction *opposite* a key light at (lx,ly). The shadow is anchored at
 * the feet (cx,cy) and stretched/offset away from the light; its length grows
 * as the light gets lower/further to the side (fig_h = figure pixel height).
 * The far end fades into a soft penumbra. */
static void cast_shadow(int cx, int cy, int rw, int rh, int lx, int ly, int fig_h) {
    int hdx = cx - lx;                          /* + : light is to the left  */
    int vdy = cy - ly; if (vdy < 8) vdy = 8;    /* light sits above the figure */
    int tip = hdx * fig_h / vdy;                /* horizontal throw of the tip */
    int maxtip = rw * 5;
    if (tip >  maxtip) tip =  maxtip;
    if (tip < -maxtip) tip = -maxtip;
    int s    = (tip >= 0) ? 1 : -1;
    int atip = tip * s;
    int ecx  = cx + tip / 2;                    /* ellipse centre (mid-throw) */
    int erw  = rw + atip / 2;                   /* elongated along the throw  */
    int reach = atip + rw; if (reach < 1) reach = 1;
    for (int dy = -rh; dy <= rh; dy++) {
        int y = cy + dy;
        if ((unsigned)y >= H) continue;
        int hw = erw * isqrt(rh*rh - dy*dy) / (rh > 0 ? rh : 1);
        for (int x = ecx - hw; x <= ecx + hw; x++) {
            if ((unsigned)x >= W) continue;
            int along = (x - cx) * s;           /* 0 at feet → reach at tip   */
            if (along < 0) along = 0;
            int m = 9 + along * 6 / reach;      /* 9 (dark) → 15 (faded out)  */
            if (m > 15) m = 15;
            uint16_t px = get(x, y);
            int r = ((px >> 11) & 0x1F) * m / 16;
            int g = ((px >>  6) & 0x1F) * m / 16;
            int b = ((px >>  1) & 0x1F) * m / 16;
            put(x, y, C(r, g, b));
        }
    }
}

/* ── Lighting ── */
static void lighten(int x, int y, int dr, int dg, int db) {
    if ((unsigned)x >= W || (unsigned)y >= H) return;
    uint16_t px = get(x, y);
    int r = (px >> 11) & 0x1F;
    int g = (px >>  6) & 0x1F;
    int b = (px >>  1) & 0x1F;
    r += dr; if (r > 31) r = 31;
    g += dg; if (g > 31) g = 31;
    b += db; if (b > 31) b = 31;
    put(x, y, C(r, g, b));
}

/* Moon: single disc with terminator shading and small craters */
static void moon(int cx, int cy, int r) {
    uint16_t rim = C(28, 28, 24);
    for (int dy = -r; dy <= r; dy++) {
        int hw = isqrt(r*r - dy*dy);
        for (int dx = -hw; dx <= hw; dx++) {
            /* Terminator shading: right side brighter */
            int lx = dx + r/3;
            int br = 22 + lx * 9 / (r > 0 ? r : 1);
            if (br < 14) br = 14;
            if (br > 30) br = 30;
            int bg = br - 1;
            int bb = br - 4;
            if (bg < 0) bg = 0;
            if (bb < 0) bb = 0;
            put(cx+dx, cy+dy, C(br, bg, bb));
        }
    }
    /* Craters */
    disc(cx+r/4, cy-r/5, r/5, C(20,20,17));
    disc(cx-r/5, cy+r/4, r/6, C(19,19,16));
    disc(cx+r/3, cy+r/4, r/7, C(21,21,18));
    /* Rim highlight */
    for (int dy = -r; dy <= r; dy++) {
        int hw = isqrt(r*r - dy*dy);
        put(cx - hw, cy+dy, rim);
        put(cx + hw, cy+dy, rim);
    }
}

/* Halo: large soft dithered glow around the moon (smooth radial falloff). */
static void moon_halo(int cx, int cy, int r0, int r1) {
    for (int dy = -(r1+2); dy <= r1+2; dy++) {
        int yy = cy + dy;
        if ((unsigned)yy >= H) continue;
        for (int dx = -(r1+2); dx <= r1+2; dx++) {
            int dist2 = dx*dx + dy*dy;
            if (dist2 < r0*r0 || dist2 > r1*r1) continue;
            int dist = isqrt(dist2);
            /* intensity 255 at inner edge → 0 at outer edge */
            int inten = 255 - (dist - r0) * 255 / ((r1 - r0) > 0 ? r1-r0 : 1);
            inten = inten * inten >> 8;                 /* gentle quadratic */
            int q = inten * 5;
            int add = q >> 8;
            if ((q & 255) > (BAYER8[yy & 7][(cx+dx) & 7] << 2)) add++;
            if (add > 0) lighten(cx+dx, yy, (add*3)>>2, (add*3)>>2, add);
        }
    }
}

/* ── Volumetric god-ray system ──────────────────────────────────────────────
 * One soft light shaft from source (sx,sy) to far point (ex,ey).
 *   w_end  : half-width in px at the far end (the shaft widens with distance)
 *   peak   : peak intensity, 0..255
 *   tint   : 0 = cool moonlight (blue-white), 1 = warm sunlight (gold)
 *   phase  : per-beam phase so the gentle sway differs between shafts
 * The cross-section is a smooth parabola (soft feathered edges); along the
 * beam the light ramps in at the source then fades to zero at the far end
 * (true crepuscular falloff). Intensity is 8×8-dithered into a small additive
 * lighten so the gradient stays smooth on the 5-bit framebuffer. */
static void godray(int sx, int sy, int ex, int ey, int w_end, int peak,
                   int tint, int phase, int frame) {
    int span = ey - sy;
    if (span <= 0) return;
    for (int y = sy + 4; y < ey && y < H; y++) {
        if (y < 0) continue;
        int t = (y - sy) * 256 / span;                 /* 0..256 along shaft */
        int sway = (isin((frame + phase + (y >> 2)) & 63) * 3) >> 5; /* ±3px */
        int cx = sx + ((ex - sx) * t >> 8) + sway;
        int hw = 3 + (w_end * t >> 8);                 /* widen with distance */
        int hw2 = hw * hw;
        int along;
        if (t < 24) along = peak * t / 24;             /* fade in at the gap */
        else        along = peak * (256 - t) / 232;    /* fade to 0 at the end */
        if (along <= 0) continue;
        for (int dx = -hw; dx <= hw; dx++) {
            int adx = dx < 0 ? -dx : dx;
            int cross = (hw2 - adx*adx) * 256 / hw2;    /* 0..256 soft parabola */
            int inten = (along * cross) >> 8;           /* 0..peak */
            if (inten <= 0) continue;
            int x = cx + dx;
            if ((unsigned)x >= W || (unsigned)y >= H) continue;
            int q = inten * 7;                          /* up to ~1785 */
            int add = q >> 8;                           /* 0..6 */
            if ((q & 255) > (BAYER8[y & 7][x & 7] << 2)) add++;
            if (add <= 0) continue;
            if (tint == 0) lighten(x, y, (add*3)>>2, (add*3)>>2, add);   /* cool */
            else           lighten(x, y, add, (add*4)/5, add>>1);        /* warm */
        }
    }
}

/* Moonlight: a fan of soft shafts pouring from the moon over the battlefield,
 * plus two thin bright accent cores. */
static void moon_rays(int mx, int my, int ground_y, int frame) {
    godray(mx, my, mx+ 70, ground_y-40, 16, 110, 0, 31, frame);
    godray(mx, my, mx+120, ground_y-20, 22, 150, 0,  0, frame);
    godray(mx, my, mx+180, ground_y,    26, 180, 0, 11, frame);
    godray(mx, my, mx+240, ground_y-10, 20, 145, 0, 23, frame);
    godray(mx, my, mx+300, ground_y-30, 18, 120, 0, 41, frame);
    /* thin bright accent cores */
    godray(mx, my, mx+170, ground_y,     6, 205, 0,  7, frame);
    godray(mx, my, mx+215, ground_y-15,  5, 185, 0, 17, frame);
}

/* Sunlight: warm shafts fanning down-left from a high sun. */
static void sun_rays(int sx, int sy, int ground_y, int frame) {
    godray(sx, sy, sx-120, ground_y-30, 18, 100, 1, 37, frame);
    godray(sx, sy, sx-200, ground_y,    24, 135, 1,  0, frame);
    godray(sx, sy, sx-300, ground_y-10, 26, 150, 1, 13, frame);
    godray(sx, sy, sx-400, ground_y,    22, 120, 1, 27, frame);
    godray(sx, sy, sx-480, ground_y-20, 20, 110, 1, 45, frame);
    /* thin bright accent core */
    godray(sx, sy, sx-320, ground_y,     6, 175, 1,  9, frame);
}

/* Soft light pool on the ground (additive glow ellipse) */
static void lightpool(int cx, int cy, int rw, int rh) {
    for (int dy = -rh; dy <= rh; dy++) {
        int hw = rw * isqrt(rh*rh - dy*dy) / (rh > 0 ? rh : 1);
        int y = cy + dy;
        for (int x = cx-hw; x <= cx+hw; x++) {
            int ax = x-cx; if (ax<0) ax=-ax;
            int ay = dy;   if (ay<0) ay=-ay;
            int bayer = BAYER4[y&3][x&3];
            /* radial fade */
            int r2 = ax*ax*(rh*rh) + ay*ay*(rw*rw);
            int rf = rw*rh; rf = rf*rf;
            int fade = (int)((long)r2 * 14 / (rf > 0 ? rf : 1));
            if (bayer > fade + 4) {
                lighten(x, y, 2, 2, 3);
            }
        }
    }
}

/* ── Battle backgrounds ── */

/* Far treeline silhouette using sinusoidal peaks */
static void treeline_far(int base_y, uint16_t col, int amp, int freq) {
    for (int x = 0; x < W; x++) {
        int height = base_y - amp/2 - (isin(x * freq / W * 64) * amp >> 5);
        for (int y = height; y < base_y+4; y++)
            put(x, y, col);
    }
}

/* Near treeline with individual tree shapes */
static void treeline_near(int base_y, uint16_t dark, uint16_t mid) {
    for (int x = 0; x < W; x++) {
        /* layered sine for natural treeline */
        int h1 = (isin((x * 3) & 63) * 16) >> 5;
        int h2 = (isin((x * 7 + 20) & 63) * 8) >> 5;
        int h3 = (isin((x * 11 + 40) & 63) * 5) >> 5;
        int top = base_y - 40 - h1 - h2 - h3;
        int mid_y = base_y - 20;
        for (int y = top; y <= base_y + 6; y++) {
            uint16_t c = (y < mid_y) ? mid : dark;
            put(x, y, c);
        }
    }
}

/* NIGHT battle background */
static void battle_bg_night(int f) {
    /* Sky gradient: deep night */
    vgrad(0, 0, W-1, 200, 4,5,18, 8,10,26);

    /* Stars */
    for (int i = 0; i < 80; i++) {
        int sx = (i * 173 + 41) % W;
        int sy = (i * 97  + 13) % 160;
        int br = (i & 3) + 1;
        int twinkle = ((f + i*7) >> 3) & 3;
        if (twinkle < 3)
            put(sx, sy, C(br*7, br*7, br*8));
    }

    /* Moon */
    moon(MOON_CX, MOON_CY, MOON_R);
    moon_halo(MOON_CX, MOON_CY, MOON_R+2, MOON_R+16);

    /* Far treeline */
    treeline_far(168, C(2,5,2), 24, 3);

    /* Ground: mossy night */
    vgrad(0, 170, W-1, H-1, 3,8,4, 2,5,2);

    /* Near treeline */
    treeline_near(178, C(1,3,1), C(2,6,2));

    /* Ground texture: subtle moss highlights */
    for (int y = 185; y < H; y++) {
        for (int x = 0; x < W; x += 4) {
            int v = BAYER4[y&3][x&3];
            if (v > 11) lighten(x+(v&3), y, 1, 1, 0);
        }
    }
}

/* DAY battle background */
static void battle_bg_day(int f) {
    /* Sky: warm afternoon blue */
    vgrad(0, 0, W-1, 160, 7,16,30, 12,22,30);

    /* Sun */
    disc(SUN_CX, SUN_CY, SUN_R,   C(30,28,12));
    disc(SUN_CX, SUN_CY, SUN_R-4, C(31,30,18));
    /* Sun glow */
    for (int dy = -40; dy <= 40; dy++) {
        for (int dx = -40; dx <= 40; dx++) {
            int d2 = dx*dx + dy*dy;
            if (d2 < SUN_R*SUN_R || d2 > 40*40) continue;
            int bayer = BAYER4[(SUN_CY+dy)&3][(SUN_CX+dx)&3];
            int dist = isqrt(d2);
            int fade = (dist - SUN_R) * 14 / 18;
            if (bayer > fade + 4)
                lighten(SUN_CX+dx, SUN_CY+dy, 3, 2, 0);
        }
    }

    /* Birds (V shapes) */
    for (int b = 0; b < 5; b++) {
        int bx = ((f*2 + b*120) % (W+40)) - 20;
        int by = 30 + b*12;
        if (bx > 0 && bx < W-8) {
            put(bx,   by,   C(2,3,6));
            put(bx-2, by+2, C(2,3,6));
            put(bx+2, by+2, C(2,3,6));
        }
    }

    /* Clouds */
    for (int cl = 0; cl < 4; cl++) {
        int cx = ((f + cl*180) % (W+120)) - 60;
        int cy = 40 + cl * 20;
        int cw = 60 + cl*15;
        for (int dy = -10; dy <= 10; dy++) {
            int hw = isqrt(cw*cw/16 - dy*dy*cw/16);
            hline(cx - hw, cx + hw, cy+dy, C(28,28,30));
        }
        /* Cloud shadow bottom */
        for (int dy = 6; dy <= 12; dy++) {
            int hw = isqrt(cw*cw/16 - dy*dy*cw/16) - 2;
            if (hw > 0) hline(cx - hw, cx + hw, cy+dy, C(22,22,26));
        }
    }

    /* Far treeline — bright green */
    treeline_far(162, C(4,14,3), 20, 3);

    /* Ground: bright grass */
    vgrad(0, 162, W-1, H-1, 6,18,5, 4,14,3);

    /* Near treeline — vivid daytime green */
    treeline_near(172, C(3,12,2), C(6,18,4));

    /* Ground highlights */
    for (int y = 178; y < H; y++) {
        for (int x = 0; x < W; x += 3) {
            int v = BAYER4[y&3][x&3];
            if (v > 10) lighten(x+(v&2), y, 1, 2, 0);
        }
    }

    /* Scattered flowers */
    for (int fl = 0; fl < 20; fl++) {
        int fx = (fl * 173 + 29) % W;
        int fy = 185 + (fl * 67) % (H - 195);
        put(fx, fy, C(28,24,4));
    }
}

/* ── Text rendering (simple 4×5 bitmap font) ── */
static const uint8_t FONT55[26][5] = {
    {0x6,0x9,0xF,0x9,0x9}, /* A */
    {0xE,0x9,0xE,0x9,0xE}, /* B */
    {0x6,0x9,0x8,0x9,0x6}, /* C */
    {0xE,0x9,0x9,0x9,0xE}, /* D */
    {0xF,0x8,0xE,0x8,0xF}, /* E */
    {0xF,0x8,0xE,0x8,0x8}, /* F */
    {0x6,0x8,0xB,0x9,0x7}, /* G */
    {0x9,0x9,0xF,0x9,0x9}, /* H */
    {0xE,0x4,0x4,0x4,0xE}, /* I */
    {0x2,0x2,0x2,0xA,0x4}, /* J */
    {0x9,0xA,0xC,0xA,0x9}, /* K */
    {0x8,0x8,0x8,0x8,0xF}, /* L */
    {0x9,0xF,0xF,0x9,0x9}, /* M */
    {0x9,0xD,0xB,0x9,0x9}, /* N */
    {0x6,0x9,0x9,0x9,0x6}, /* O */
    {0xE,0x9,0xE,0x8,0x8}, /* P */
    {0x6,0x9,0xB,0xA,0x5}, /* Q */
    {0xE,0x9,0xE,0xA,0x9}, /* R */
    {0x7,0x8,0x6,0x1,0xE}, /* S */
    {0xE,0x4,0x4,0x4,0x4}, /* T */
    {0x9,0x9,0x9,0x9,0x6}, /* U */
    {0x9,0x9,0xA,0xA,0x4}, /* V */
    {0x9,0x9,0xF,0xF,0x9}, /* W */
    {0x9,0xA,0x4,0xA,0x9}, /* X */
    {0x9,0xA,0x4,0x4,0x4}, /* Y */
    {0xF,0x2,0x4,0x8,0xF}, /* Z */
};

/* Digits 0-9 (4×5) */
static const uint8_t DIGIT55[10][5] = {
    {0x6,0x9,0x9,0x9,0x6}, /* 0 */
    {0x2,0x6,0x2,0x2,0x7}, /* 1 */
    {0xE,0x1,0x6,0x8,0xF}, /* 2 */
    {0xE,0x1,0x6,0x1,0xE}, /* 3 */
    {0x9,0x9,0xF,0x1,0x1}, /* 4 */
    {0xF,0x8,0xE,0x1,0xE}, /* 5 */
    {0x6,0x8,0xE,0x9,0x6}, /* 6 */
    {0xF,0x1,0x2,0x4,0x4}, /* 7 */
    {0x6,0x9,0x6,0x9,0x6}, /* 8 */
    {0x6,0x9,0x7,0x1,0x6}, /* 9 */
};

/* Punctuation: bitmasks for a few useful glyphs */
static void draw_char(int x, int y, char c, int sc, uint16_t col) {
    const uint8_t *g = 0;
    if (c >= 'A' && c <= 'Z')      g = FONT55[c - 'A'];
    else if (c >= 'a' && c <= 'z') g = FONT55[c - 'a'];
    else if (c >= '0' && c <= '9') g = DIGIT55[c - '0'];
    else if (c == '%') { static const uint8_t pc[5]={0x9,0x2,0x4,0x4,0x9}; g = pc; }
    else if (c == '!') { static const uint8_t pc[5]={0x4,0x4,0x4,0x0,0x4}; g = pc; }
    else if (c == '/') { static const uint8_t pc[5]={0x1,0x2,0x4,0x8,0x8}; g = pc; }
    else if (c == '-') { static const uint8_t pc[5]={0x0,0x0,0xF,0x0,0x0}; g = pc; }
    else return;  /* space / unknown → blank */
    for (int row = 0; row < 5; row++) {
        for (int bit = 0; bit < 4; bit++) {
            if (g[row] & (0x8 >> bit)) {
                for (int sy = 0; sy < sc; sy++)
                    for (int sx = 0; sx < sc; sx++)
                        put(x + bit*sc + sx, y + row*sc + sy, col);
            }
        }
    }
}

static void draw_str(int x, int y, const char *s, int sc, uint16_t col) {
    for (; *s; s++, x += (4+1)*sc)
        draw_char(x, y, *s, sc, col);
}

/* Draw string centered */
static void draw_strc(int cx, int y, const char *s, int sc, uint16_t col) {
    int len = 0;
    for (const char *p = s; *p; p++) if (*p != ' ') len++;
    /* each char is 4 bits wide + 1 spacing, × sc */
    int total = 0;
    for (const char *p = s; *p; p++) total += (*p == ' ') ? sc*2 : (4+1)*sc;
    draw_str(cx - total/2, y, s, sc, col);
}

/* ── UI panels ── */
static void panel(int x0, int y0, int x1, int y1, uint16_t bg, uint16_t border) {
    rect(x0, y0, x1, y1, bg);
    hline(x0, x1, y0, border); hline(x0, x1, y1, border);
    for (int y = y0; y <= y1; y++) { put(x0, y, border); put(x1, y, border); }
}

/* Labeled HP/MP bar row. The name is drawn at (x,y); the bar always begins at
 * bar_x (chosen by the caller to clear the longest name) so the fill never
 * overlaps the text. cur/max give the fill fraction. */
static void stat_bar(int x, int y, const char *name, int bar_x, int bar_w,
                     int cur, int max, uint16_t fillc) {
    draw_str(x, y, name, 2, C(22,22,28));
    int by0 = y, by1 = y + 9;
    /* track */
    rect(bar_x, by0, bar_x + bar_w, by1, C(5,4,4));
    /* border */
    hline(bar_x, bar_x + bar_w, by0, C(12,12,18));
    hline(bar_x, bar_x + bar_w, by1, C(12,12,18));
    for (int yy = by0; yy <= by1; yy++) { put(bar_x, yy, C(12,12,18)); put(bar_x+bar_w, yy, C(12,12,18)); }
    /* fill */
    int fw = (max > 0) ? bar_w * cur / max : 0;
    if (fw < 0) fw = 0; if (fw > bar_w) fw = bar_w;
    if (fw > 1) {
        rect(bar_x+1, by0+1, bar_x + fw, by1-1, fillc);
        /* glossy top line */
        hline(bar_x+1, bar_x + fw, by0+1, C(
            ((fillc>>11)&0x1F)*5/4 > 31 ? 31 : ((fillc>>11)&0x1F)*5/4,
            ((fillc>> 6)&0x1F)*5/4 > 31 ? 31 : ((fillc>> 6)&0x1F)*5/4,
            ((fillc>> 1)&0x1F)*5/4 > 31 ? 31 : ((fillc>> 1)&0x1F)*5/4));
    }
}

/* ── Scene: Title ── */
static void scene_title(int f) {
    /* Night sky */
    vgrad(0, 0, W-1, H-1, 4,5,18, 2,3,12);

    /* Stars */
    for (int i = 0; i < 120; i++) {
        int sx = (i * 173 + 7)  % W;
        int sy = (i * 97  + 31) % (H/2);
        int br = (i & 3) + 1;
        int tw = ((f + i*5) >> 4) & 3;
        if (tw < 3) put(sx, sy, C(br*6, br*6, br*7));
    }

    /* Moon */
    moon(W-120, 60, 32);
    moon_halo(W-120, 60, 34, 52);

    /* Castle silhouette */
    /* Main tower */
    rect(260, 240, 380, 380, C(3,3,6));
    /* Battlements */
    for (int b = 0; b < 5; b++) {
        int bx = 260 + b*26;
        rect(bx, 228, bx+16, 245, C(3,3,6));
    }
    /* Side towers */
    rect(200, 280, 260, 380, C(3,3,6));
    rect(380, 280, 440, 380, C(3,3,6));
    /* Tower battlements */
    for (int b = 0; b < 3; b++) {
        rect(200+b*22, 268, 215+b*22, 282, C(3,3,6));
        rect(380+b*22, 268, 395+b*22, 282, C(3,3,6));
    }
    /* Windows */
    rect(298, 290, 318, 320, C(28,24,4));
    rect(340, 290, 360, 320, C(28,24,4));
    /* Gate */
    rect(300, 340, 340, 380, C(8,6,12));
    /* Drawbridge stones */
    for (int s = 0; s < 3; s++)
        hline(300, 340, 350+s*8, C(4,4,8));

    /* Ground fog */
    vgrad(0, 350, W-1, 380, 8,10,24, 3,4,14);
    for (int i = 0; i < 40; i++) {
        int fx = (i * 173 + f * 2 + i * 11) % W;
        int fy = 360 + (i & 3);
        int fw = 30 + (i & 15) * 4;
        for (int dx = -fw; dx <= fw; dx++) {
            int bayer = BAYER4[fy&3][(fx+dx)&3];
            if (bayer > 6) lighten(fx+dx, fy, 3, 3, 5);
        }
    }

    /* Title */
    draw_strc(W/2, 100, "RIVERDALE SAGA", 4, C(28,26,14));
    /* Shadow */
    draw_strc(W/2+2, 102, "RIVERDALE SAGA", 4, C(8,6,2));
    draw_strc(W/2, 100, "RIVERDALE SAGA", 4, C(30,28,16));

    /* Subtitle */
    draw_strc(W/2, 165, "PRESS START", 2, C(20,20,28));

    /* Animated sparkle on title */
    int spark = (f/4) & 63;
    put(W/2 + (isin(spark)*60 >> 5), 108 + (icos(spark)*10 >> 5), C(30,30,28));
}

/* ── Scene: Overworld ── */
#define MAP_W 20
#define MAP_H 16
static const char *MAP[MAP_H] = {
    "wwwwwwwwwwwwwwwwwwww",
    "wggGgggGggggGgggggGw",
    "wgWWWWWgggGgGgggggGw",
    "wgWRRRWgggggggfggggw",
    "wgWRRRWgggGgggggggfw",
    "wgWWWWWgggggggggggfw",
    "wgggggggggGgggggggGw",
    "wgGggggggggggGgggggw",
    "wgggDDDDDDDDDDgggggw",
    "wggggggggggggggggggw",
    "wgggggGgggggggggGggw",
    "wgggWWWWWggggggggggw",
    "wgggWRRRWggggGgggggw",
    "wgggWRRRWgggggggggfw",
    "wgggWWWWWggggggggggw",
    "wwwwwwwwwwwwwwwwwwww",
};

static const char *MAPTILE_ART[8] = {0};

static void draw_tile(int tx, int ty, char tile) {
    int dx = tx * TS, dy = ty * TS;
    const char **art = A_grass;
    switch (tile) {
    case 'w': art = A_water;  break;
    case 'g': case 'G': art = ((tx^ty)&1) ? A_flower : A_grass; break;
    case 'W': art = A_wall;   break;
    case 'R': art = A_roof;   break;
    case 'D': art = A_path;   break;
    case 'f': art = A_fence;  break;
    default:  art = A_grass;  break;
    }
    blit(dx, dy, art, 8, 8, 3);
}

static void scene_overworld(int f) {
    /* Draw visible tiles */
    for (int ty = 0; ty < MAP_H && ty*TS < H; ty++) {
        for (int tx = 0; tx < MAP_W && tx*TS < W; tx++) {
            char tile = MAP[ty][tx];
            draw_tile(tx, ty, tile);
        }
    }

    /* Water shimmer */
    for (int ty = 0; ty < MAP_H; ty++) {
        for (int tx = 0; tx < MAP_W; tx++) {
            if (MAP[ty][tx] == 'w') {
                int phase = (f + tx*3 + ty*7) & 7;
                if (phase < 2) {
                    int wx = tx*TS + 4 + phase*6;
                    int wy = ty*TS + 4 + (phase&1)*4;
                    hline(wx, wx+6, wy, C(20,26,30));
                }
            }
        }
    }

    /* Shadows under trees */
    for (int ty = 0; ty < MAP_H; ty++) {
        for (int tx = 0; tx < MAP_W; tx++) {
            if (MAP[ty][tx] == 'T' || MAP[ty][tx] == 't') {
                gshadow(tx*TS+12, ty*TS+18, 10, 4);
            }
        }
    }

    /* Door markers on wall tiles */
    int houses[2][2] = {{2,2},{11,11}};
    for (int h = 0; h < 2; h++) {
        blit(houses[h][0]*TS+8, houses[h][1]*TS-8, A_door, 8, 8, 3);
    }

    /* Characters with shadows */
    int hero_x = 8*TS + 12, hero_y = 9*TS - 4;
    gshadow(hero_x, hero_y+2, 10, 3);
    draw_hero(hero_x, hero_y, 0, f);

    /* NPCs */
    int npc1x = 2*TS+12, npc1y = 5*TS+16;
    gshadow(npc1x, npc1y+2, 9, 3);
    draw_villager(npc1x, npc1y, C(20,10,6), C(26,14,8));

    int npc2x = 15*TS+12, npc2y = 12*TS+16;
    gshadow(npc2x, npc2y+2, 9, 3);
    draw_villager(npc2x, npc2y, C(10,8,22), C(16,12,28));

    /* Elder */
    int ex = 3*TS+12, ey = 6*TS+16;
    gshadow(ex, ey+2, 9, 3);
    draw_elder(ex, ey);

    /* HUD */
    panel(4, 4, 214, 42, C(0,0,8), C(14,16,24));
    stat_bar(12, 12, "ARIA", 80, 124, 80, 100, C(20,4,4));   /* HP */
    stat_bar(12, 28, "MP",   80, 124, 60, 100, C(4,8,20));   /* MP */
}

/* ── Scene: Dialogue ── */
static void scene_dialogue(int f) {
    /* Background: outside wall of house */
    rect(0, 0, W-1, H-1, C(6,14,6));
    blit(0, 0, A_wall, 8, 8, 3);
    for (int tx = 0; tx < MAP_W; tx++)
        blit(tx*TS, 0, A_wall, 8, 8, 3);
    for (int ty = 0; ty < 12; ty++) {
        blit(0, ty*TS, A_grass, 8, 8, 3);
        blit(W-TS, ty*TS, A_grass, 8, 8, 3);
        for (int tx = 1; tx < MAP_W-1; tx++)
            blit(tx*TS, ty*TS, A_grass, 8, 8, 3);
    }

    /* Tree in background */
    blit(W/2-36, 40, A_tree, 8, 8, 3);
    blit(W/2+12, 40, A_tree, 8, 8, 3);

    /* Elder NPC on left */
    gshadow(W/4, H/2+2, 10, 3);
    draw_elder(W/4, H/2);

    /* Hero on right */
    gshadow(3*W/4, H/2+2, 10, 3);
    draw_hero(3*W/4, H/2, 2, f);

    /* Dialogue panel */
    panel(30, H-145, W-30, H-20, C(1,2,8), C(14,18,28));
    /* Portrait box */
    panel(38, H-138, 108, H-30, C(3,5,14), C(12,14,24));
    /* Elder portrait */
    blit(44, H-130, A_elder, 8, 12, 2);

    /* Nametag */
    rect(38, H-148, 150, H-140, C(8,10,24));
    draw_str(46, H-146, "ELDER MARON", 1, C(28,28,28));

    /* Dialogue text */
    draw_str(120, H-132, "YOUNG ARIA THE ANCIENT", 2, C(20,22,28));
    draw_str(120, H-112, "DARKNESS STIRS IN THE", 2, C(20,22,28));
    draw_str(120, H-92,  "FOREST TO THE EAST", 2, C(20,22,28));
    draw_str(120, H-72,  "YOU MUST FIND THE", 2, C(20,22,28));
    draw_str(120, H-52,  "CRYSTAL OF DAWN", 2, C(20,22,28));

    /* Blinking continue indicator */
    if ((f >> 3) & 1) draw_str(W-80, H-32, "NEXT", 2, C(28,26,14));
}

/* ── Scene: Main Menu ── */
static void scene_menu(int f) {
    /* Dark BG */
    vgrad(0, 0, W-1, H-1, 5,6,18, 2,3,10);
    moon(W/2, 80, 20);

    /* Decorative castle silhouette */
    rect(W/2-60, 300, W/2+60, H, C(2,2,5));
    rect(W/2-80, 320, W/2-60, H, C(2,2,5));
    rect(W/2+60, 320, W/2+80, H, C(2,2,5));

    /* Title */
    draw_strc(W/2, 60, "RIVERDALE SAGA", 3, C(28,26,14));

    /* Menu items */
    const char *items[] = {"NEW GAME", "CONTINUE", "OPTIONS", "QUIT"};
    int sel = (f/80) & 3;
    for (int i = 0; i < 4; i++) {
        int mx = W/2, my = 180 + i*50;
        if (i == sel) {
            /* Selected item highlight */
            rect(mx-120, my-8, mx+120, my+24, C(8,10,22));
            hline(mx-120, mx+120, my-8, C(14,18,28));
            hline(mx-120, mx+120, my+24, C(14,18,28));
        }
        uint16_t tc = (i == sel) ? C(30,28,14) : C(18,20,26);
        draw_strc(mx, my, items[i], 2, tc);
    }

    /* Animated cursor */
    int cx = W/2 - 130;
    int cy = 180 + sel*50;
    if ((f>>2)&1) draw_char(cx, cy, 'Z', 2, C(28,26,14));
}

/* ── Scene: Quests ── */
static void scene_quests(int f) {
    panel(0, 0, W-1, H-1, C(1,2,8), C(12,14,24));
    draw_strc(W/2, 16, "QUEST JOURNAL", 2, C(28,26,14));
    hline(20, W-20, 36, C(10,12,24));

    const char *quests[] = {
        "FIND THE CRYSTAL OF DAWN",
        "DEFEAT THE FOREST WARDEN",
        "SPEAK WITH ELDER MARON",
        "EXPLORE THE EASTERN RUINS",
        "CRAFT A MOONSTONE AMULET",
    };
    int active[] = {1,0,1,0,0};

    for (int i = 0; i < 5; i++) {
        int qy = 55 + i*52;
        uint16_t qcol = active[i] ? C(20,24,30) : C(12,12,18);
        uint16_t scol  = active[i] ? C(18,22,8)  : C(16,10,4);

        /* Quest entry box */
        rect(20, qy, W-20, qy+44, C(2,3,10));
        hline(20, W-20, qy, C(8,10,22));
        hline(20, W-20, qy+44, C(8,10,22));

        /* Status dot */
        disc(36, qy+22, 6, active[i] ? C(16,22,8) : C(14,10,4));

        draw_str(50, qy+6, quests[i], 2, qcol);

        /* Subtext */
        draw_str(50, qy+26, active[i] ? "IN PROGRESS" : "COMPLETED", 1, scol);
    }

    /* Page indicator */
    draw_strc(W/2, H-20, "PAGE ONE OF THREE", 1, C(14,16,24));
}

/* ── Scene: Shop ── */
static void scene_shop(int f) {
    /* Shop interior */
    rect(0, 0, W-1, H-1, C(14,10,6));
    /* Floor boards */
    for (int y = 0; y < H; y += 20) {
        hline(0, W-1, y, C(10,7,4));
        hline(0, W-1, y+1, C(18,13,8));
    }
    /* Walls */
    rect(0, 0, W-1, 120, C(20,16,10));
    for (int y = 0; y < 120; y += 30) {
        hline(0, W-1, y, C(12,9,5));
    }
    /* Shelves */
    rect(40, 60, W-40, 90, C(16,12,7));
    hline(40, W-40, 60, C(10,7,4));
    /* Potion items on shelf */
    for (int i = 0; i < 8; i++) {
        int px = 60 + i*70;
        disc(px, 52, 10, C(16,4,4+i*2));
        rect(px-4, 44, px+4, 50, C(8,6,3));
    }

    /* Counter */
    rect(40, H-130, W-40, H-80, C(16,12,7));
    hline(40, W-40, H-130, C(10,7,4));
    hline(40, W-40, H-80, C(10,7,4));

    /* Shopkeeper */
    gshadow(W/2, H-130+2, 10, 3);
    draw_villager(W/2, H-130, C(14,12,4), C(20,18,8));

    /* Shop panel */
    panel(20, H-76, W/2-10, H-10, C(1,2,8), C(12,14,22));
    draw_str(30, H-68, "ITEMS FOR SALE", 2, C(24,22,14));
    const char *sitems[] = {"POTION     50G", "HI POTION 200G", "ETHER     100G", "ELIXIR    999G"};
    for (int i = 0; i < 4; i++)
        draw_str(30, H-48+i*12, sitems[i], 1, C(18,20,26));

    /* Gold display */
    panel(W/2+10, H-76, W-20, H-10, C(1,2,8), C(12,14,22));
    draw_str(W/2+20, H-68, "YOUR GOLD", 2, C(28,24,8));
    draw_str(W/2+20, H-44, "1248 G", 3, C(28,26,10));
}

/* ── Scene: Crafting ── */
static void scene_craft(int f) {
    panel(0, 0, W-1, H-1, C(2,3,10), C(10,12,22));
    draw_strc(W/2, 12, "CRAFTING FORGE", 2, C(28,22,8));
    hline(20, W-20, 34, C(10,12,22));

    /* Forge visual */
    rect(W/2-50, 60, W/2+50, 140, C(12,8,4));
    disc(W/2, 100, 30, C(8,5,2));
    /* Fire glow */
    int flame = (isin(f*6) >> 3) + 2;
    disc(W/2, 108, 20+flame, C(28,12,2));
    disc(W/2, 108, 15+flame, C(30,18,4));
    disc(W/2, 112, 10+flame, C(30,26,8));
    /* Anvil */
    rect(W/2-35, 142, W/2+35, 162, C(10,10,10));
    rect(W/2-25, 135, W/2+25, 142, C(14,14,14));

    /* Recipe panel */
    panel(20, 170, W/2-10, H-10, C(1,2,8), C(10,12,22));
    draw_str(30, 178, "MOONSTONE AMULET", 2, C(22,20,28));
    draw_str(30, 200, "REQUIRES", 1, C(16,16,22));
    const char *mats[] = {"MOONSTONE X1", "SILVER WIRE X2", "DARK CRYSTAL X1"};
    int have[]  = {1,1,0};
    for (int i = 0; i < 3; i++) {
        uint16_t mc = have[i] ? C(16,22,8) : C(22,8,4);
        draw_str(30, 216+i*14, mats[i], 1, mc);
    }

    /* Result */
    panel(W/2+10, 170, W-20, H-10, C(1,2,8), C(10,12,22));
    draw_str(W/2+20, 178, "RESULT", 2, C(22,20,28));
    /* Amulet icon */
    disc(W*3/4, 250, 22, C(14,14,20));
    disc(W*3/4, 250, 16, C(20,16,28));
    disc(W*3/4, 250, 8,  C(24,22,30));
    for (int i = 0; i < 8; i++) {
        int ax = W*3/4 + (icos(i*8) * 24 >> 5);
        int ay = 250      + (isin(i*8) * 24 >> 5);
        put(ax, ay, C(28,24,30));
    }
    draw_str(W/2+20, 295, "MOONSTONE AMULET", 1, C(20,18,28));
    draw_str(W/2+20, 312, "ATK PLUS TWO", 1, C(16,20,14));
    draw_str(W/2+20, 326, "MAGIC PLUS FIVE", 1, C(14,16,24));

    /* Craft button */
    rect(W/2+20, H-48, W-30, H-16, C(4,3,12));
    hline(W/2+20, W-30, H-48, C(12,14,24));
    hline(W/2+20, W-30, H-16, C(12,14,24));
    draw_strc((W/2+20 + W-30)/2, H-42, "CRAFT", 2, C(28,26,16));
}

/* ── Scene: Action ── */
static void scene_action(int f) {
    /* Dungeon corridor */
    vgrad(0, 0, W-1, H-1, 4,3,8, 2,2,4);
    /* Floor tiles */
    for (int ty = 8; ty < 16; ty++)
        for (int tx = 0; tx < MAP_W; tx++)
            blit(tx*TS, ty*TS, A_wall, 8, 8, 3);
    /* Ceiling */
    for (int tx = 0; tx < MAP_W; tx++)
        blit(tx*TS, 0, A_wall, 8, 8, 3);
    /* Open path */
    for (int ty = 3; ty < 8; ty++)
        for (int tx = 0; tx < MAP_W; tx++)
            blit(tx*TS, ty*TS, A_path, 8, 8, 3);

    /* Torches on wall */
    for (int t = 0; t < 4; t++) {
        int tx = 80 + t*160;
        int ty = 52;
        rect(tx-4, ty, tx+4, ty+16, C(14,10,4));
        /* Flame animation */
        int flicker = (isin((f+t*16)*8) >> 3) + 3;
        disc(tx, ty-flicker, 6, C(28,14,2));
        disc(tx, ty-flicker, 4, C(30,22,6));
        disc(tx, ty-flicker, 2, C(30,28,12));
        /* Light halo on wall */
        for (int dy = -20; dy <= 20; dy++) {
            for (int dx = -20; dx <= 20; dx++) {
                int d2 = dx*dx + dy*dy;
                if (d2 > 400) continue;
                int bayer = BAYER4[(ty+dy)&3][(tx+dx)&3];
                if (bayer > d2*14/400)
                    lighten(tx+dx, ty+dy, 2, 1, 0);
            }
        }
    }

    /* Hero running */
    int hx = 100 + (f*3) % (W-200);
    int hy = 6*TS - 4;
    gshadow(hx, hy+2, 10, 3);
    draw_hero(hx, hy, 2, f);

    /* Goblins */
    for (int g = 0; g < 3; g++) {
        int gx = 300 + g*120 - (f&1)*2;
        int gy = 6*TS - 4;
        gshadow(gx, gy+2, 9, 3);
        draw_goblin(gx, gy);
    }

    /* Action: hero slash FX */
    if ((f/20)%3 == 0) {
        int fx = hx + 30;
        int fy = hy - 12;
        for (int a = 0; a < 5; a++) {
            int bx2 = fx + (icos(a*12)*20 >> 5);
            int by2 = fy + (isin(a*12)*20 >> 5);
            hline(fx, bx2, by2, C(28,28,30));
        }
    }

    /* HUD */
    panel(4, 4, 214, 30, C(0,0,8), C(14,16,24));
    stat_bar(12, 10, "ARIA", 80, 124, 50, 100, C(20,4,4));
}

/* ── Scene: Battle ──
 * Layout (640×480):
 *   sky / treeline      y 0..184
 *   battlefield ground  y 185..330  (enemies back row ~230, party front ~310)
 *   UI panels           y 332..476
 */
static void scene_battle(int f) {
    /* Cycle day/night every 55 frames */
    int is_night = ((f / 55) & 1);

    if (is_night) battle_bg_night(f);
    else          battle_bg_day(f);

    uint16_t rim = is_night ? C(18,22,30) : C(28,26,14);

    /* Key-light position — all shadows are thrown away from this point. */
    int lcx = is_night ? MOON_CX : SUN_CX;
    int lcy = is_night ? MOON_CY : SUN_CY;

    /* God-rays are cast over the whole field BEFORE the actors so the actors
     * read as lit objects sitting in the light rather than being washed out. */
    if (is_night) moon_rays(MOON_CX, MOON_CY, 320, f);
    else          sun_rays (SUN_CX,  SUN_CY,  320, f);

    /* ── Enemies: back row, standing on the ground (feet y ≈ 222..236) ── */
    /* Bat hovers mid-field, well clear of the treeline (base ~178) */
    int bat_y = 205 + (isin(f*3) * 12 >> 5);
    draw_bat(360, bat_y, f);

    /* Goblin A */
    cast_shadow(180, 224, 14, 5, lcx, lcy, 20);
    draw_goblin(180, 222);
    if (is_night) blit_rim(180-8, 222-20, A_goblin, 8, 10, 2, rim);

    /* Goblin B */
    cast_shadow(268, 230, 14, 5, lcx, lcy, 20);
    draw_goblin(268, 228);
    if (is_night) blit_rim(268-8, 228-20, A_goblin, 8, 10, 2, rim);

    /* Warden (boss-lite), larger and further back-right */
    cast_shadow(430, 236, 22, 6, lcx, lcy, 24);
    blit(430-24, 236-28, A_warden, 12, 14, 2);
    if (is_night) blit_rim(430-24, 236-28, A_warden, 12, 14, 2, rim);

    /* ── Party battlers: front row, lower and larger (feet y ≈ 308..320) ── */
    if (is_night) lightpool(210, 322, 130, 16);

    /* Aria */
    cast_shadow(150, 312, 16, 5, lcx, lcy, 28);
    blit(150-10, 312-28, A_aria_b, 10, 14, 2);
    if (is_night) blit_rim(150-10, 312-28, A_aria_b, 10, 14, 2, rim);

    /* Loras */
    cast_shadow(240, 320, 16, 5, lcx, lcy, 28);
    blit(240-10, 320-28, A_loras_b, 10, 14, 2);
    if (is_night) blit_rim(240-10, 320-28, A_loras_b, 10, 14, 2, rim);

    /* Knight */
    cast_shadow(330, 316, 16, 5, lcx, lcy, 24);
    draw_knight(330, 316);
    if (is_night) blit_rim(330-8, 316-24, A_knight, 8, 12, 2, rim);

    /* Fireflies (night only) — confined to the lower field so they read */
    if (is_night) {
        for (int i = 0; i < 12; i++) {
            int bx = 40 + (i * 173 + f * (i+1)/3) % (W-80);
            int by = 250 + (isin((f+i*11)*4) * 28 >> 5);
            put(bx, by, C(26,28,8));
            if ((f>>2)&1) put(bx+1, by, C(20,24,6));
        }
    }

    /* ── UI ── */
    int ui_y = H - 144;          /* 336 */

    /* Enemy info (left) */
    panel(4, ui_y, W/2-6, ui_y+62, C(0,1,6), C(10,12,22));
    draw_str(14, ui_y+6, "ENEMIES", 1, C(14,16,24));
    stat_bar(14, ui_y+18, "GOBLIN", 110, 220, 62, 100, C(22,6,6));
    stat_bar(14, ui_y+34, "WARDEN", 110, 220, 84, 100, C(22,10,6));

    /* Party info (right) */
    panel(W/2+6, ui_y, W-4, ui_y+62, C(0,1,6), C(10,12,22));
    draw_str(W/2+16, ui_y+6, "PARTY", 1, C(14,16,24));
    stat_bar(W/2+16, ui_y+16, "ARIA",   W/2+96, 200, 70, 100, C(18,6,6));
    stat_bar(W/2+16, ui_y+30, "LORAS",  W/2+96, 200, 88, 100, C(18,6,6));
    stat_bar(W/2+16, ui_y+44, "KNIGHT", W/2+96, 200, 60, 100, C(18,6,6));

    /* Command panel (left) */
    panel(4, ui_y+66, W/2-6, H-4, C(0,1,6), C(10,12,22));
    const char *cmds[] = {"ATTACK", "SKILL", "ITEM", "RUN"};
    int cmd_sel = (f/30) & 3;
    for (int i = 0; i < 4; i++) {
        int cx = 84 + (i & 1) * 150;
        int cy = ui_y + 80 + (i >> 1) * 30;
        if (i == cmd_sel) {
            rect(cx-58, cy-5, cx+58, cy+18, C(6,8,20));
            hline(cx-58, cx+58, cy-5,  C(14,18,30));
            hline(cx-58, cx+58, cy+18, C(14,18,30));
            /* cursor */
            draw_char(cx-54, cy, 'Z', 1, C(28,26,14));
        }
        draw_strc(cx, cy, cmds[i], 2, (i==cmd_sel) ? C(30,28,14) : C(18,20,26));
    }

    /* Battle log (right) */
    panel(W/2+6, ui_y+66, W-4, H-4, C(0,1,6), C(10,12,22));
    draw_str(W/2+16, ui_y+76, "ARIA ATTACKS GOBLIN", 1, C(20,22,28));
    draw_str(W/2+16, ui_y+90, "GOBLIN TAKES 42 DAMAGE!", 1, C(22,14,8));
    draw_str(W/2+16, ui_y+108,"GOBLIN USES SLASH", 1, C(20,22,28));
    draw_str(W/2+16, ui_y+122,"ARIA TAKES 18 DAMAGE", 1, C(22,14,8));

    /* Day/night indicator */
    draw_str(W-72, 6, is_night ? "NIGHT" : "DAY", 1, C(16,18,26));
}

/* ── Scene: Boss ── */
static void scene_boss(int f) {
    /* Night battle bg for boss */
    battle_bg_night(f);
    moon_rays(MOON_CX, MOON_CY, 300, f);

    /* Boss warden — large, centered, standing on the ground.
     * A_warden has a blank trailing row, so its visible feet are ~4px above by;
     * the shadow + light pool are anchored to the visible feet, not the cell. */
    int bx = W/2, by = 230;
    lightpool(bx, by-6, 110, 16);
    cast_shadow(bx, by-4, 40, 8, MOON_CX, MOON_CY, 52);
    blit(bx-48, by-56, A_warden, 12, 14, 4);

    uint16_t boss_rim = C(20,24,30);
    blit_rim(bx-48, by-56, A_warden, 12, 14, 4, boss_rim);

    /* Boss name + health bar (top banner) */
    panel(70, 12, W-70, 40, C(2,0,4), C(16,8,20));
    draw_str(80, 18, "FOREST WARDEN", 2, C(26,20,28));
    {
        int barx = 250, barw = (W-78) - barx;
        rect(barx, 20, barx+barw, 34, C(8,4,8));
        hline(barx, barx+barw, 20, C(20,10,24));
        hline(barx, barx+barw, 34, C(20,10,24));
        int hpbar = barw * (100 - (f % 100)) / 100;
        if (hpbar > 1) rect(barx+1, 21, barx+hpbar, 33, C(20,4,20));
    }

    /* Boss attack VFX — purple shockwave radiating from the warden */
    if ((f/15)%4 < 2) {
        int wave_r = ((f*4) % 200);
        for (int dy = -wave_r; dy <= wave_r; dy += 2) {
            int hw = isqrt(wave_r*wave_r - dy*dy);
            int bayer = BAYER4[dy&3][hw&3];
            if (bayer > 6) {
                put(bx-hw, by+dy, C(18,6,22));
                put(bx+hw, by+dy, C(18,6,22));
            }
        }
    }

    /* Party — front row, on the ground (feet y ≈ 312..320) */
    lightpool(210, 322, 130, 16);
    cast_shadow(150, 312, 16, 5, MOON_CX, MOON_CY, 28);
    blit(150-10, 312-28, A_aria_b, 10, 14, 2);
    blit_rim(150-10, 312-28, A_aria_b, 10, 14, 2, boss_rim);

    cast_shadow(240, 320, 16, 5, MOON_CX, MOON_CY, 28);
    blit(240-10, 320-28, A_loras_b, 10, 14, 2);
    blit_rim(240-10, 320-28, A_loras_b, 10, 14, 2, boss_rim);

    cast_shadow(330, 316, 16, 5, MOON_CX, MOON_CY, 24);
    draw_knight(330, 316);
    blit_rim(330-8, 316-24, A_knight, 8, 12, 2, boss_rim);

    /* Fireflies — confined to mid-field */
    for (int i = 0; i < 14; i++) {
        int fix = 40 + (i * 173 + f*(i+1)/2) % (W-80);
        int fiy = 250 + (isin((f+i*11)*4) * 30 >> 5);
        put(fix, fiy, C(24,28,8));
        if ((f>>2)&1) put(fix+1, fiy, C(20,22,6));
    }

    /* ── UI ── */
    int ui_y = H - 90;

    /* Party HP (left) */
    panel(4, ui_y, W/2-6, H-4, C(0,1,6), C(10,12,22));
    draw_str(14, ui_y+6, "PARTY", 1, C(14,16,24));
    stat_bar(14, ui_y+18, "ARIA",   96, W/2-120, 78, 100, C(18,6,6));
    stat_bar(14, ui_y+38, "LORAS",  96, W/2-120, 64, 100, C(18,6,6));
    stat_bar(14, ui_y+58, "KNIGHT", 96, W/2-120, 56, 100, C(18,6,6));

    /* Battle log (right) */
    panel(W/2+6, ui_y, W-4, H-4, C(0,1,6), C(10,12,22));
    draw_str(W/2+16, ui_y+8,  "WARDEN CASTS DARK VEIL", 1, C(22,10,28));
    draw_str(W/2+16, ui_y+26, "ARIA COUNTERS WITH HOLY", 1, C(24,24,10));
    draw_str(W/2+16, ui_y+44, "WARDEN TAKES 180 DAMAGE!", 1, C(28,14,6));
    draw_str(W/2+16, ui_y+62, "THE WARDEN STAGGERS", 1, C(20,22,28));
}

/* ── Main ── */
int main(void) {
    display_init(RESOLUTION_640x480, DEPTH_16_BPP, 2, GAMMA_NONE, FILTERS_RESAMPLE);

    int frame = 0;

    while (1) {
        surface_t *surf = display_get();
        fb        = (uint16_t *)surf->buffer;
        fb_stride = surf->stride;

        /* Clear */
        memset(fb, 0, (size_t)H * fb_stride);

#ifdef FORCE_SCENE
        int scene = FORCE_SCENE;
#else
        int scene = (frame / 110) % 10;
#endif
        int f = frame % 110;

        switch (scene) {
        case 0: scene_title    (frame); break;
        case 1: scene_overworld(frame); break;
        case 2: scene_dialogue (frame); break;
        case 3: scene_menu     (frame); break;
        case 4: scene_quests   (frame); break;
        case 5: scene_shop     (frame); break;
        case 6: scene_craft    (frame); break;
        case 7: scene_action   (frame); break;
        case 8: scene_battle   (frame); break;
        case 9: scene_boss     (frame); break;
        }

        display_show(surf);
        frame++;
    }

    return 0;
}
