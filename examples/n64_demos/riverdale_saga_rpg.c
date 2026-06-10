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

/* Halo: dithered glow ring around moon */
static void moon_halo(int cx, int cy, int r0, int r1) {
    for (int dy = -(r1+2); dy <= r1+2; dy++) {
        for (int dx = -(r1+2); dx <= r1+2; dx++) {
            int dist2 = dx*dx + dy*dy;
            if (dist2 < r0*r0 || dist2 > r1*r1) continue;
            int bayer = BAYER4[((cy+dy)&3)][((cx+dx)&3)];
            int dist = isqrt(dist2);
            int fade = (dist - r0) * 15 / ((r1 - r0) > 0 ? r1-r0 : 1);
            if (bayer > fade + 6) {
                lighten(cx+dx, cy+dy, 2, 2, 3);
            }
        }
    }
}

/* Atmospheric moonbeam shafts — moonlight filtered through forest canopy gaps.
 * Multiple thin roughly-parallel beams, NOT a spotlight cone.
 * mx,my = moon center; ground_y = y level of ground/party feet area. */
static void moon_rays(int mx, int my, int ground_y) {
    /* 7 beams: [x_offset_top, x_offset_bottom, brightness(1-4), start_pct, end_pct]
     * Offsets are perpendicular to the main (moon->ground) axis.
     * Together they simulate moonlight filtering through separated canopy gaps. */
    static const int8_t B[7][5] = {
        { 46, 54, 4, 18, 98},  /* main shaft — strongest, full length */
        { 26, 32, 3, 15, 90},  /* left of main */
        { 68, 78, 3, 20, 94},  /* right of main */
        {  8, 12, 2, 28, 82},  /* far left — shorter, dimmer */
        { 88, 98, 2, 12, 85},  /* far right — shorter */
        { 36, 43, 1, 32, 72},  /* near-left — faint, stops early */
        { 58, 67, 1, 22, 68},  /* near-right — faint, stops early */
    };
    int span = ground_y - my;
    if (span <= 0) return;

    for (int i = 0; i < 7; i++) {
        int ox_t = B[i][0], ox_b = B[i][1];
        int brt  = B[i][2];
        int ys   = my + span * B[i][3] / 100;
        int ye   = my + span * B[i][4] / 100;

        for (int y = ys; y < ye && y < H; y++) {
            /* position along beam, 0..255 */
            int t = (y - ys) * 255 / ((ye - ys) > 0 ? (ye - ys) : 1);
            /* interpolate x offset along beam */
            int ox = ox_t + ((ox_b - ox_t) * t >> 8);
            int bx = mx + ox;  /* beam center x */

            /* 3-pixel wide shaft with edge falloff */
            for (int dxx = -1; dxx <= 1; dxx++) {
                int adxx = dxx < 0 ? -dxx : dxx;
                int eff = brt - adxx;
                if (eff <= 0) continue;
                int x = bx + dxx;
                /* Ordered dithering: higher brt = denser, lower brt = wispy */
                int bayer = BAYER4[y & 3][x & 3];
                int thresh = 14 - eff * 3;  /* brt4→thresh2, brt1→thresh11 */
                if (thresh < 0) thresh = 0;
                if (bayer >= thresh) {
                    /* Slight blue-white moonlight tint */
                    lighten(x, y, eff, eff, eff < 4 ? eff+1 : eff);
                }
            }
        }
    }
}

/* Sunbeams for daytime battle — warm diffuse light from upper right */
static void sun_rays(int sx, int sy, int ground_y) {
    /* 5 sunbeam shafts, warmer color, coming from upper-right */
    static const int8_t S[5][5] = {
        {-50,-58, 4, 15, 100},
        {-30,-36, 3, 10,  90},
        {-70,-80, 3, 20,  95},
        {-15,-18, 2, 25,  80},
        {-85,-96, 1, 12,  75},
    };
    int span = ground_y - sy;
    if (span <= 0) return;
    for (int i = 0; i < 5; i++) {
        int ox_t = S[i][0], ox_b = S[i][1];
        int brt  = S[i][2];
        int ys   = sy + span * S[i][3] / 100;
        int ye   = sy + span * S[i][4] / 100;
        for (int y = ys; y < ye && y < H; y++) {
            int t = (y - ys) * 255 / ((ye - ys) > 0 ? (ye - ys) : 1);
            int ox = ox_t + ((ox_b - ox_t) * t >> 8);
            int bx = sx + ox;
            for (int dxx = -1; dxx <= 1; dxx++) {
                int adxx = dxx < 0 ? -dxx : dxx;
                int eff = brt - adxx;
                if (eff <= 0) continue;
                int x = bx + dxx;
                int bayer = BAYER4[y & 3][x & 3];
                int thresh = 14 - eff * 3;
                if (thresh < 0) thresh = 0;
                if (bayer >= thresh)
                    lighten(x, y, eff+1, eff, eff-1 < 0 ? 0 : eff-1);
            }
        }
    }
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
    moon(96, 56, 28);
    moon_halo(96, 56, 30, 44);

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
    disc(W-96, 48, 22, C(30,28,12));
    disc(W-96, 48, 18, C(31,30,18));
    /* Sun glow */
    for (int dy = -40; dy <= 40; dy++) {
        for (int dx = -40; dx <= 40; dx++) {
            int d2 = dx*dx + dy*dy;
            if (d2 < 22*22 || d2 > 40*40) continue;
            int bayer = BAYER4[(48+dy)&3][(W-96+dx)&3];
            int dist = isqrt(d2);
            int fade = (dist - 22) * 14 / 18;
            if (bayer > fade + 4)
                lighten(W-96+dx, 48+dy, 3, 2, 0);
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

static void draw_char(int x, int y, char c, int sc, uint16_t col) {
    if (c < 'A' || c > 'Z') {
        if (c == ' ') return;
        if (c >= 'a' && c <= 'z') c -= 32;
        else return;
    }
    const uint8_t *g = FONT55[c - 'A'];
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
    panel(4, 4, 200, 36, C(0,0,8), C(14,16,24));
    draw_str(12, 12, "ARIA  HP", 2, C(22,22,28));
    rect(90, 14, 190, 24, C(6,4,4));
    rect(90, 14, 90 + 80, 24, C(20,4,4));  /* HP bar */
    draw_str(12, 26, "  MP", 2, C(16,18,28));
    rect(90, 26, 190, 34, C(4,4,6));
    rect(90, 26, 90 + 60, 34, C(4,8,20));  /* MP bar */
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
    panel(4, 4, 200, 28, C(0,0,8), C(14,16,24));
    draw_str(12, 10, "ARIA  HP", 2, C(22,22,28));
    rect(90, 12, 190, 22, C(6,4,4));
    rect(90, 12, 140, 22, C(20,4,4));
}

/* ── Scene: Battle ── */
static void scene_battle(int f) {
    /* Cycle day/night every 55 frames */
    int is_night = ((f / 55) & 1);

    if (is_night) {
        battle_bg_night(f);
    } else {
        battle_bg_day(f);
    }

    /* ── Enemies ── */
    uint16_t rim = is_night ? C(18,22,30) : C(28,26,14);

    /* Goblin 1 */
    gshadow(180, 132, 20, 5);
    draw_goblin(180, 128);
    if (is_night) blit_rim(180-8, 128-20, A_goblin, 8, 10, 2, rim);

    /* Goblin 2 */
    gshadow(280, 128, 20, 5);
    draw_goblin(280, 124);
    if (is_night) blit_rim(280-8, 124-20, A_goblin, 8, 10, 2, rim);

    /* Warden (boss-lite) */
    gshadow(440, 140, 28, 6);
    blit(440-24, 140-28, A_warden, 12, 14, 2);
    if (is_night) blit_rim(440-24, 140-28, A_warden, 12, 14, 2, rim);

    /* Bat */
    int bat_y = 100 + (isin(f*3) * 12 >> 5);
    draw_bat(350, bat_y, f);

    /* ── Moonbeams / Sunbeams ── */
    if (is_night) {
        moon_rays(96, 56, 310);
        lightpool(200, 315, 90, 14);
    } else {
        sun_rays(W-80, 50, 310);
    }

    /* ── Party battlers (side-view) ── */
    /* Aria */
    gshadow(130, 260, 20, 5);
    blit(130-10, 260-28, A_aria_b, 10, 14, 2);
    if (is_night) blit_rim(130-10, 260-28, A_aria_b, 10, 14, 2, rim);

    /* Loras */
    gshadow(200, 275, 20, 5);
    blit(200-10, 275-28, A_loras_b, 10, 14, 2);
    if (is_night) blit_rim(200-10, 275-28, A_loras_b, 10, 14, 2, rim);

    /* Knight */
    gshadow(270, 268, 20, 5);
    draw_knight(270, 268);
    if (is_night) blit_rim(270-8, 268-24, A_knight, 8, 12, 2, rim);

    /* Fireflies (night only) */
    if (is_night) {
        for (int i = 0; i < 12; i++) {
            int bx = 40 + (i * 173 + f * (i+1)/3) % (W-80);
            int by = 180 + (isin((f+i*11)*4) * 30 >> 5);
            put(bx, by, C(26,28,8));
            if ((f>>2)&1) put(bx+1, by, C(20,24,6));
        }
    }

    /* ── UI panels ── */
    int ui_y = H - 148;

    /* Enemy info */
    panel(4, ui_y, W/2-4, ui_y+64, C(0,1,6), C(10,12,22));
    draw_str(12, ui_y+6,  "GOBLIN A", 2, C(22,22,28));
    draw_str(12, ui_y+24, "HP", 2, C(22,8,8));
    rect(40, ui_y+26, 160, ui_y+36, C(6,4,4));
    rect(40, ui_y+26, 110, ui_y+36, C(22,4,4));
    draw_str(12, ui_y+40, "WARDEN  HP", 2, C(22,22,28));
    rect(96, ui_y+42, 290, ui_y+52, C(6,4,4));
    rect(96, ui_y+42, 200, ui_y+52, C(22,8,4));

    /* Party info */
    panel(W/2+4, ui_y, W-4, ui_y+64, C(0,1,6), C(10,12,22));
    draw_str(W/2+12, ui_y+6,  "ARIA  HP", 2, C(22,22,28));
    rect(W/2+72, ui_y+8,  W/2+190, ui_y+18, C(6,4,4));
    rect(W/2+72, ui_y+8,  W/2+140, ui_y+18, C(20,4,4));
    draw_str(W/2+12, ui_y+24, "LORAS HP", 2, C(22,22,28));
    rect(W/2+72, ui_y+26, W/2+190, ui_y+36, C(6,4,4));
    rect(W/2+72, ui_y+26, W/2+160, ui_y+36, C(20,4,4));
    draw_str(W/2+12, ui_y+42, "KNIGHT HP", 2, C(22,22,28));
    rect(W/2+80, ui_y+44, W/2+190, ui_y+54, C(6,4,4));
    rect(W/2+80, ui_y+44, W/2+120, ui_y+54, C(20,4,4));

    /* Command panel */
    panel(4, ui_y+68, W/2-4, H-4, C(0,1,6), C(10,12,22));
    const char *cmds[] = {"ATTACK", "SKILL", "ITEM", "RUN"};
    int cmd_sel = (f/30) & 3;
    for (int i = 0; i < 4; i++) {
        int cx = W/4 + (i%2)*(W/4) - W/8;
        int cy = ui_y + 78 + (i/2)*36;
        if (i == cmd_sel) {
            rect(cx-42, cy-4, cx+42, cy+20, C(6,8,20));
            hline(cx-42, cx+42, cy-4, C(12,16,28));
        }
        draw_strc(cx, cy, cmds[i], 2, (i==cmd_sel) ? C(30,28,14) : C(18,20,26));
    }

    /* Battle log */
    panel(W/2+4, ui_y+68, W-4, H-4, C(0,1,6), C(10,12,22));
    draw_str(W/2+12, ui_y+76, "ARIA ATTACKS", 2, C(22,22,28));
    draw_str(W/2+12, ui_y+98, "GOBLIN A TAKES 42 DMG", 1, C(20,12,8));
    draw_str(W/2+12, ui_y+114,"GOBLIN A USES SLASH", 2, C(22,22,28));
    draw_str(W/2+12, ui_y+136,"ARIA TAKES 18 DMG", 1, C(20,12,8));

    /* Day/night indicator */
    draw_str(W-80, 4, is_night ? "NIGHT" : "DAY  ", 1, C(16,18,26));
}

/* ── Scene: Boss ── */
static void scene_boss(int f) {
    /* Night battle bg for boss */
    battle_bg_night(f);
    moon_rays(96, 56, 310);

    /* Boss warden — large, centered */
    int bx = W/2, by = 190;
    gshadow(bx, by+4, 40, 8);
    blit(bx-48, by-56, A_warden, 12, 14, 4);

    uint16_t boss_rim = C(20,24,30);
    blit_rim(bx-48, by-56, A_warden, 12, 14, 4, boss_rim);

    /* Boss health bar */
    panel(80, 14, W-80, 38, C(2,0,4), C(16,8,20));
    draw_str(88, 18, "FOREST WARDEN", 2, C(26,20,28));
    rect(240, 20, W-88, 34, C(8,4,8));
    int hpbar = (W-88-240) * (100 - (f % 100)) / 100;
    rect(240, 20, 240+hpbar, 34, C(20,4,20));
    lightpool(bx, by+10, 100, 16);

    /* Party */
    gshadow(130, 260, 20, 5);
    blit(130-10, 260-28, A_aria_b, 10, 14, 2);

    gshadow(200, 275, 20, 5);
    blit(200-10, 275-28, A_loras_b, 10, 14, 2);

    gshadow(270, 268, 20, 5);
    draw_knight(270, 268);

    /* Boss attack VFX */
    if ((f/15)%4 < 2) {
        /* Purple shockwave */
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

    /* Fireflies */
    for (int i = 0; i < 16; i++) {
        int fix = 40 + (i * 173 + f*(i+1)/2) % (W-80);
        int fiy = 160 + (isin((f+i*11)*4) * 40 >> 5);
        put(fix, fiy, C(24,28,8));
        if ((f>>2)&1) put(fix+1, fiy, C(20,22,6));
    }

    /* UI */
    int ui_y = H - 88;
    panel(4, ui_y, W-4, H-4, C(0,1,6), C(10,12,22));
    draw_str(12, ui_y+6,  "ARIA  HP", 2, C(22,22,28));
    rect(72, ui_y+8, 220, ui_y+18, C(6,4,4));
    rect(72, ui_y+8, 180, ui_y+18, C(20,4,4));
    draw_str(12, ui_y+24, "LORAS HP", 2, C(22,22,28));
    rect(72, ui_y+26, 220, ui_y+36, C(6,4,4));
    rect(72, ui_y+26, 150, ui_y+36, C(20,4,4));
    draw_str(12, ui_y+42, "KNIGHT HP", 2, C(22,22,28));
    rect(80, ui_y+44, 220, ui_y+54, C(6,4,4));
    rect(80, ui_y+44, 130, ui_y+54, C(20,4,4));

    panel(W/2-50, ui_y, W-4, H-4, C(0,1,6), C(10,12,22));
    draw_str(W/2-40, ui_y+8,  "WARDEN CASTS DARK VEIL", 2, C(22,8,28));
    draw_str(W/2-40, ui_y+30, "ARIA COUNTERS WITH HOLY", 2, C(22,22,8));
    draw_str(W/2-40, ui_y+52, "WARDEN TAKES 180 DMG", 2, C(28,12,4));
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
