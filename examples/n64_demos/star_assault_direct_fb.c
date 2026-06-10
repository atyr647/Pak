/* Star Assault - horizontal shmup demo (Gleylancer / Blazing Star style).
 * Direct framebuffer rendering - bypasses RDPQ entirely.
 * Four looping scenes: title flyby, swarm wave, charge beam vs destroyer,
 * boss fight with WARNING splash. */
#define _GNU_SOURCE

/* pak_compat.h (force-included) wraps display_init(int,int,int,int,int).
 * Use integer args to match: res=0 (320x240), bpp=2 (16bpp), buf=3, gamma=0, filt=1 */

#include <libdragon.h>
#include <stdint.h>
#include <string.h>
#include "pak_math.h"

/* N64 RGBA5551: R=[15:11], G=[10:6], B=[5:1], A=[0]=1(opaque). All values 0-31. */
#define C(r,g,b) ((uint16_t)(((r)<<11)|((g)<<6)|((b)<<1)|1))
#define W 320
#define H 240

static uint16_t *fb;
static int stride_px;

static inline void put(int x, int y, uint16_t c) {
    if ((unsigned)x < W && (unsigned)y < H) fb[y*stride_px+x] = c;
}
static void fillr(int x,int y,int w,int h,uint16_t c) {
    for(int dy=0;dy<h;dy++) for(int dx=0;dx<w;dx++) put(x+dx,y+dy,c);
}
static void hline(int x0,int x1,int y,uint16_t c) {
    if ((unsigned)y >= H) return;
    if (x0 < 0) x0 = 0;
    if (x1 >= W) x1 = W-1;
    for (int x=x0;x<=x1;x++) fb[y*stride_px+x] = c;
}

static int isqrt(int v) { int r=0; while((r+1)*(r+1)<=v) r++; return r; }

static void disc(int cx,int cy,int r,uint16_t c) {
    for (int dy=-r;dy<=r;dy++) { int hf=isqrt(r*r-dy*dy); hline(cx-hf,cx+hf,cy+dy,c); }
}
static void disc_dith(int cx,int cy,int r,uint16_t c) {
    for (int dy=-r;dy<=r;dy++) {
        int hf=isqrt(r*r-dy*dy), y=cy+dy;
        if ((unsigned)y >= H) continue;
        for (int x=cx-hf;x<=cx+hf;x++) if (((x+y)&1)==0) put(x,y,c);
    }
}
static void circ(int cx,int cy,int r,uint16_t c) {
    for (int dy=-r;dy<=r;dy++) {
        int hf=isqrt(r*r-dy*dy);
        put(cx-hf,cy+dy,c); put(cx+hf,cy+dy,c);
    }
    for (int dx=-r;dx<=r;dx++) {
        int vf=isqrt(r*r-dx*dx);
        put(cx+dx,cy-vf,c); put(cx+dx,cy+vf,c);
    }
}

/* sin(i*2pi/64)*31 */
static const int8_t SIN64[64] = {
      0,  3,  6,  9, 12, 15, 17, 20, 22, 24, 26, 27, 29, 30, 30, 31,
     31, 31, 30, 30, 29, 27, 26, 24, 22, 20, 17, 15, 12,  9,  6,  3,
      0, -3, -6, -9,-12,-15,-17,-20,-22,-24,-26,-27,-29,-30,-30,-31,
    -31,-31,-30,-30,-29,-27,-26,-24,-22,-20,-17,-15,-12, -9, -6, -3,
};
static inline int isin(int a) { return SIN64[a&63]; }
static inline int icos(int a) { return SIN64[(a+16)&63]; }

static inline uint32_t h32(uint32_t x) {
    x ^= x>>16; x *= 0x7feb352du; x ^= x>>15; x *= 0x846ca68bu; x ^= x>>16;
    return x;
}

/* ── 5x5 font: space, A-Z, 0-9 ─────────────────────────────────────────── */
static const uint8_t font[37][5] = {
    {0x00,0x00,0x00,0x00,0x00},
    {0x1F,0x11,0x1F,0x11,0x11},{0x1E,0x11,0x1E,0x11,0x1E},{0x0E,0x11,0x10,0x11,0x0E},
    {0x1E,0x11,0x11,0x11,0x1E},{0x1F,0x10,0x1E,0x10,0x1F},{0x1F,0x10,0x1E,0x10,0x10},
    {0x0E,0x11,0x17,0x11,0x0E},{0x11,0x11,0x1F,0x11,0x11},{0x0E,0x04,0x04,0x04,0x0E},
    {0x01,0x01,0x01,0x11,0x0E},{0x11,0x12,0x1C,0x12,0x11},{0x10,0x10,0x10,0x10,0x1F},
    {0x11,0x1B,0x15,0x11,0x11},{0x11,0x19,0x15,0x13,0x11},{0x0E,0x11,0x11,0x11,0x0E},
    {0x1E,0x11,0x1E,0x10,0x10},{0x0E,0x11,0x15,0x12,0x0D},{0x1E,0x11,0x1E,0x12,0x11},
    {0x0E,0x10,0x0E,0x01,0x1E},{0x1F,0x04,0x04,0x04,0x04},{0x11,0x11,0x11,0x11,0x0E},
    {0x11,0x11,0x0A,0x0A,0x04},{0x11,0x11,0x15,0x1B,0x11},{0x11,0x0A,0x04,0x0A,0x11},
    {0x11,0x0A,0x04,0x04,0x04},{0x1F,0x02,0x04,0x08,0x1F},
    {0x0E,0x13,0x15,0x19,0x0E},{0x04,0x0C,0x04,0x04,0x0E},{0x1E,0x01,0x0E,0x10,0x1F},
    {0x1F,0x02,0x06,0x01,0x1E},{0x12,0x12,0x1F,0x02,0x02},{0x1E,0x10,0x1E,0x01,0x1E},
    {0x0E,0x10,0x1E,0x11,0x0E},{0x1F,0x01,0x02,0x04,0x08},{0x0E,0x11,0x0E,0x11,0x0E},
    {0x0E,0x11,0x0F,0x01,0x0E},
};
static int font_idx(char c) {
    if (c >= 'A' && c <= 'Z') return 1 + (c - 'A');
    if (c >= 'a' && c <= 'z') return 1 + (c - 'a');
    if (c >= '0' && c <= '9') return 27 + (c - '0');
    return 0;
}
static void draw_chr(int x, int y, char c, uint16_t col) {
    const uint8_t *g = font[font_idx(c)];
    for (int row=0;row<5;row++)
        for (int k=0;k<5;k++)
            if (g[row] & (0x10>>k)) put(x+k, y+row, col);
}
static void draw_str(int x, int y, const char *s, uint16_t col) {
    while (*s) { draw_chr(x, y, *s++, col); x += 6; }
}
static void draw_chr2(int x, int y, char c, uint16_t col) {
    const uint8_t *g = font[font_idx(c)];
    for (int row=0;row<5;row++)
        for (int k=0;k<5;k++)
            if (g[row] & (0x10>>k)) fillr(x+k*2, y+row*2, 2, 2, col);
}
static void draw_str2(int x, int y, const char *s, uint16_t col) {
    while (*s) { draw_chr2(x, y, *s++, col); x += 12; }
}
static void draw_num(int x, int y, unsigned v, int digits, uint16_t col) {
    for (int i=digits-1;i>=0;i--) { draw_chr(x+i*6, y, (char)('0'+v%10), col); v/=10; }
}

/* ── background layers ──────────────────────────────────────────────────── */
static void draw_bg(void) {
    for (int y=0;y<H;y++) {
        uint16_t c = C(1+y/60, y/48, 5+y/22);
        for (int x=0;x<W;x++) fb[y*stride_px+x] = c;
    }
}
static void draw_nebula(int f) {
    for (int i=0;i<4;i++) {
        uint32_t hs = h32(i*977u+13u);
        int span = W+160;
        int nx = (int)(hs%(unsigned)span) - ((f/10)%span);
        if (nx < -80) nx += span;
        int ny = 30 + (int)((hs>>12)%160u);
        int nr = 26 + (int)((hs>>20)%22u);
        disc_dith(nx, ny, nr, (i&1) ? C(5,2,14) : C(2,5,13));
        disc_dith(nx+6, ny-4, nr/2, C(7,4,17));
    }
}
static void draw_stars(int f) {
    static const uint16_t sc[3] = {C(9,9,13), C(15,15,19), C(24,24,29)};
    for (int i=0;i<96;i++) {
        uint32_t hs = h32(i*2654435761u);
        int sp = 1 + (i%3);
        int x = ((int)(hs%W) - f*sp) % W; if (x<0) x += W;
        int y = (int)((hs>>16)%H);
        put(x, y, sc[sp-1]);
        if (sp == 3) {
            put(x+1, y, sc[2]);
            if (((f+i)&31) < 3) {            /* twinkle cross */
                uint16_t w = C(31,31,31);
                put(x-1,y,w); put(x+2,y,w); put(x,y-1,w); put(x,y+1,w);
            }
        }
    }
}
static void draw_planet(int cx,int cy,int r) {
    for (int dy=-r;dy<=r;dy++) {
        int yy = cy+dy;
        if ((unsigned)yy >= H) continue;
        int hf = isqrt(r*r-dy*dy);
        int band = ((dy+r)/7) % 3;
        uint16_t bc = (band==0) ? C(6,8,24) : (band==1) ? C(4,5,18) : C(8,11,27);
        hline(cx-hf, cx+hf, yy, bc);
        /* right-side terminator shadow */
        int sh = (hf*2)/3;
        for (int x=cx+sh;x<=cx+hf;x++) if (((x+yy)&1)==0) put(x,yy,C(2,2,9));
        /* left rim light */
        put(cx-hf, yy, C(16,22,31)); put(cx-hf+1, yy, C(12,16,29));
    }
    circ(cx, cy, r+2, C(6,14,24));
}

/* ── player ship + options ──────────────────────────────────────────────── */
static void draw_exhaust(int x,int y,int f) {
    int len = 6 + ((f>>1)&3)*2;
    for (int j=0;j<len;j++) {
        uint16_t c = (j<2) ? C(31,31,28) : (j<5) ? C(31,24,4) : C(31,11,0);
        put(x-j, y, c);
        if (j < len/2) {
            int wob = ((f+j)&1) ? 1 : -1;
            put(x-j, y+wob, C(31,17,2));
        }
    }
}
static void draw_ship(int sx,int sy,int f) {
    uint16_t hull = C(18,22,28), hull2 = C(10,14,22);
    uint16_t wing = C(6,12,26),  wingE = C(12,22,31);
    uint16_t can  = C(10,31,31);
    /* swept delta wings */
    for (int i=0;i<4;i++) {
        int x0 = sx-12+i*2, x1 = sx-3-i;
        hline(x0, x1, sy-2-i, wing);
        hline(x0, x1, sy+2+i, wing);
        put(x1, sy-2-i, wingE); put(x1, sy+2+i, wingE);
    }
    /* tail fin */
    fillr(sx-12, sy-6, 2, 4, wing); put(sx-12, sy-7, wingE);
    /* fuselage */
    fillr(sx-12, sy-1, 22, 3, hull);
    hline(sx-12, sx+4, sy-2, hull2);
    hline(sx-12, sx+4, sy+2, hull2);
    /* nose cone */
    hline(sx+10, sx+12, sy-1, C(28,28,30));
    hline(sx+10, sx+13, sy,   C(31,8,4));
    hline(sx+10, sx+12, sy+1, C(28,28,30));
    put(sx+14, sy, C(31,16,4));
    /* canopy */
    fillr(sx+1, sy-2, 5, 2, can); put(sx+6, sy-1, can);
    draw_exhaust(sx-13, sy, f);
}
static void draw_option(int x,int y,int f) {
    fillr(x-3, y-1, 7, 3, C(20,20,26));
    hline(x-2, x+2, y-2, C(13,13,20));
    hline(x-2, x+2, y+2, C(13,13,20));
    put(x, y, ((f>>2)&1) ? C(10,31,31) : C(31,31,31));
    put(x+4, y, C(12,22,31));
    put(x-4, y, C(31,14,0));
}
/* options trail behind+above/below ship, swinging (Gleylancer movers) */
static void option_pos(int sx,int sy,int f,int which,int *ox,int *oy) {
    int sw = (isin(f*3)*8)/31;
    *ox = sx - 10;
    *oy = sy + (which ? (16+sw) : -(16-sw));
}

/* ── projectiles / fx ───────────────────────────────────────────────────── */
static void draw_pshot(int x,int y) {
    hline(x, x+7, y, C(31,28,8));
    hline(x+2, x+7, y-1, C(31,20,2));
    hline(x+2, x+7, y+1, C(31,20,2));
    put(x+8, y, C(31,31,31));
}
static void draw_oshot(int x,int y) {
    hline(x, x+5, y, C(10,31,31));
    put(x+6, y, C(31,31,31));
}
static void draw_orb(int x,int y,int f) {
    uint16_t p = ((f>>1)&1) ? C(31,8,24) : C(28,4,20);
    put(x,y,C(31,27,29));
    put(x-1,y,p); put(x+1,y,p); put(x,y-1,p); put(x,y+1,p);
    put(x-1,y-1,C(18,2,12)); put(x+1,y-1,C(18,2,12));
    put(x-1,y+1,C(18,2,12)); put(x+1,y+1,C(18,2,12));
    put(x-2,y,C(14,1,9)); put(x+2,y,C(14,1,9));
}
static void draw_missile(int x,int y,int dir) {
    fillr(x, y, 5, 2, C(19,19,22));
    put(x+5, y, C(31,14,2)); put(x+5, y+1, C(31,14,2));
    put(x-1, y, C(31,24,4)); put(x-1, y+1, C(31,24,4));
    (void)dir;
}
static void draw_smoke(int x,int y,int r) {
    disc_dith(x, y, r, C(9,9,11));
}
static void draw_expl(int x,int y,int age,uint32_t seed) {
    if (age < 0 || age >= 34) return;
    if (age < 6) {
        disc(x, y, 2+age, C(31,31,27));
    } else if (age < 14) {
        disc(x, y, age, C(31,21,2));
        disc(x, y, age-4, C(31,29,10));
        disc(x, y, 2, C(31,31,31));
    } else {
        int r = age-2;
        circ(x, y, r,   C(31,14,0));
        circ(x, y, r-2, C(27,7,0));
        if (age > 18) disc_dith(x, y, age-12, C(8,7,8));
    }
    for (int j=0;j<8;j++) {
        int a = j*8 + (int)(seed&7);
        int px = x + (icos(a)*age*2)/40;
        int py = y + (isin(a)*age*2)/40;
        put(px, py, C(31,24,6));
        put(px+1, py, C(31,12,0));
    }
}

/* ── enemies ────────────────────────────────────────────────────────────── */
static void draw_swooper(int x,int y,int f) {
    uint16_t body = C(18,6,20), top = C(25,10,27);
    hline(x-2, x+2, y-2, top);
    hline(x-4, x+4, y-1, body);
    hline(x-5, x+5, y,   body);
    hline(x-4, x+4, y+1, body);
    hline(x-2, x+2, y+2, top);
    put(x-4, y, C(31,28,8));                       /* cockpit, faces left */
    put(x+5, y, ((f>>1)&1) ? C(31,12,0) : C(31,22,4));  /* engine */
}
static void draw_pod(int x,int y,int f) {
    disc(x, y, 5, C(15,2,4));
    disc(x, y, 3, C(23,5,6));
    put(x-6,y,C(26,8,8)); put(x+6,y,C(26,8,8));
    put(x,y-6,C(26,8,8)); put(x,y+6,C(26,8,8));
    hline(x-8, x-6, y, C(18,18,22));               /* barrel aims left */
    put(x, y, ((f>>2)&1) ? C(31,31,31) : C(31,4,4));
}
static void draw_destroyer(int x,int y,int f,int hurt) {
    /* x,y = nose (left edge, centre line); hull extends right ~84px */
    uint16_t d = C(8,9,12), m = C(13,14,18), hl = C(18,20,24);
    /* nose wedge */
    for (int i=0;i<8;i++) { hline(x+i, x+8, y-i/2-1, m); hline(x+i, x+8, y+i/2+1, m); }
    hline(x, x+8, y, hl);
    /* main hull */
    fillr(x+8,  y-9, 76, 19, m);
    hline(x+8, x+83, y-9, hl);
    fillr(x+8,  y+6, 76, 4, d);
    /* red stripe */
    hline(x+8, x+83, y-3, C(26,4,4));
    hline(x+8, x+83, y-2, C(20,2,2));
    /* bridge tower */
    fillr(x+50, y-16, 18, 8, m);
    hline(x+50, x+67, y-16, hl);
    fillr(x+54, y-14, 4, 3, C(10,28,31));
    /* portholes */
    for (int i=0;i<9;i++) put(x+14+i*8, y+2, ((f>>3)&1)^(i&1) ? C(10,28,31) : C(6,16,22));
    /* deck turrets */
    for (int i=0;i<3;i++) {
        int tx = x+20+i*22;
        fillr(tx, y-12, 7, 3, d);
        hline(tx-4, tx, y-11, C(18,18,22));
    }
    /* engine glow at rear */
    for (int i=0;i<3;i++) {
        uint16_t g = ((f+i)&3)<2 ? C(10,24,31) : C(6,14,26);
        fillr(x+84, y-7+i*5, 3, 3, g);
    }
    /* damage flashes near nose when beam is hitting */
    if (hurt && ((f>>1)&1)) {
        hline(x, x+18, y-1, C(31,31,31));
        hline(x, x+14, y+1, C(31,31,31));
        hline(x+2, x+22, y-5, C(31,31,20));
    }
}
static void draw_boss(int f) {
    uint16_t arm = C(9,7,14), arm2 = C(14,11,20), edge = C(20,16,27);
    /* spine along right edge */
    fillr(296, 28, 24, 184, arm);
    for (int y=28;y<212;y+=2) put(296, y, edge);
    /* ribs protruding left */
    for (int i=0;i<6;i++) {
        int ry = 38 + i*30;
        fillr(272, ry, 24, 10, arm2);
        hline(272, 295, ry, edge);
        put(270, ry+4, C(31,8,4)); put(270, ry+5, C(31,8,4));
    }
    /* core housing */
    disc(268, 120, 24, arm2);
    circ(268, 120, 24, edge);
    disc(268, 120, 15, C(4,3,8));
    /* pulsing core */
    int pul = (isin(f*6)+31)/2;                    /* 0..31 */
    disc(268, 120, 9, C(31, pul/2, pul/3));
    disc(268, 120, 4+(pul>>4), C(31, 24+pul/5, 18));
    /* orbiting energy pods */
    for (int j=0;j<4;j++) {
        int a = f*2 + j*16;
        int px = 268 + (icos(a)*19)/31;
        int py = 120 + (isin(a)*19)/31;
        put(px,py,C(10,31,31)); put(px-1,py,C(6,22,28));
        put(px+1,py,C(6,22,28)); put(px,py-1,C(6,22,28)); put(px,py+1,C(6,22,28));
    }
    /* turrets top & bottom */
    for (int j=0;j<2;j++) {
        int ty = j ? 184 : 56;
        disc(284, ty, 7, arm2); circ(284, ty, 7, edge);
        hline(272, 277, ty, C(18,18,22));
        put(284, ty, ((f>>2)&1) ? C(31,31,31) : C(31,6,6));
    }
}

/* ── HUD ────────────────────────────────────────────────────────────────── */
static void draw_hud(int f) {
    fillr(0, 0, W, 11, C(1,1,3));
    hline(0, W-1, 11, C(8,8,13));
    draw_str(4, 3, "SCORE", C(0,24,28));
    draw_num(38, 3, 152300u + (unsigned)(f/2)*50u, 7, C(31,31,31));
    draw_str(124, 3, "HI", C(24,18,0));
    draw_num(140, 3, 9999999u, 7, C(31,28,8));
    draw_str(226, 3, "ST 1", C(0,24,28));
    draw_str(262, 3, "CREDIT 01", C(16,16,18));

    fillr(0, 229, W, 11, C(1,1,3));
    hline(0, W-1, 229, C(8,8,13));
    /* lives: mini ships */
    for (int i=0;i<3;i++) {
        int lx = 6+i*14;
        hline(lx, lx+6, 234, C(18,22,28));
        put(lx+7, 234, C(31,8,4));
        hline(lx, lx+2, 233, C(6,12,26));
        hline(lx, lx+2, 235, C(6,12,26));
    }
    /* charge meter */
    draw_str(110, 232, "PW", C(10,31,31));
    fillr(126, 232, 102, 5, C(3,3,6));
    circ(126+51, 234, 0, C(0,0,0)); /* no-op keeps shape symmetric */
    int chg = (f*2)%160; if (chg > 100) chg = 100;
    for (int i=0;i<chg;i++) {
        uint16_t c = (i<50) ? C(2,10+i/4,31) : (i<85) ? C(8,28,31) : C(31,31,31);
        put(127+i, 233, c); put(127+i, 234, c); put(127+i, 235, c);
    }
    hline(126, 227, 231, C(10,10,16));
    hline(126, 227, 237, C(10,10,16));
}

/* ── beam (Blazing Star charge shot) ────────────────────────────────────── */
static void draw_beam(int x0,int y,int x1,int f) {
    for (int x=x0;x<x1;x++) {
        int hh = 4 + (isin(x*4+f*10)+31)/21;       /* 4..6 */
        for (int dy=-hh;dy<=hh;dy++) {
            int ad = dy<0 ? -dy : dy;
            uint16_t c = (ad<=1) ? C(31,31,31)
                       : (ad<=hh-2) ? C(12,31,31)
                       : C(3,15,31);
            put(x, y+dy, c);
        }
        if (((x+f*4)&15) < 2) {                    /* energy pulses */
            put(x, y-hh-1, C(8,22,31)); put(x, y+hh+1, C(8,22,31));
        }
    }
    /* muzzle flare */
    disc(x0+2, y, 7+((f>>1)&3), C(31,31,31));
    circ(x0+2, y, 10+((f>>1)&3), C(12,31,31));
    hline(x0-6, x0+14, y, C(31,31,31));
    for (int j=0;j<4;j++) {
        int a = f*4 + j*16;
        put(x0+2+(icos(a)*12)/31, y+(isin(a)*12)/31, C(10,31,31));
    }
    /* travelling rings */
    for (int k=0;k<3;k++) {
        int rx = x0 + ((f*6 + k*40) % (x1-x0));
        circ(rx, y, 8, C(10,28,31));
    }
}

/* ════════════════ scenes (period 480) ════════════════ */

static void scene_title(int f,int t) {
    draw_planet(70, 192, 50);
    /* logo with drop shadow */
    draw_str2(90, 46, "STAR ASSAULT", C(2,4,12));
    draw_str2(88, 44, "STAR ASSAULT", C(20,28,31));
    hline(88, 88+143, 66, C(10,18,28));
    draw_str(94, 72, "HORIZONTAL ASSAULT TYPE", C(0,18,26));
    /* ship cruising with options */
    int sx = 70 + (isin(t)*5)/31;
    int sy = 140 + (isin(t*2)*8)/31;
    int ox, oy;
    draw_ship(sx, sy, f);
    option_pos(sx, sy, f, 0, &ox, &oy); draw_option(ox, oy, f);
    option_pos(sx, sy, f, 1, &ox, &oy); draw_option(ox, oy, f);
    /* distant escort squadron */
    for (int i=0;i<3;i++) draw_swooper(250-i*18, 110+i*16+(isin(t*2+i*10)*4)/31, f);
    if ((t/16)%2 == 0) draw_str(127, 188, "PRESS START", C(20,31,20));
    draw_str(100, 210, "BUILT WITH PAKSTUDIO", C(11,11,8));
    draw_str(136, 222, "N64 DEMO", C(8,8,12));
}

static void scene_wave(int f,int t) {
    draw_planet(268, 204, 36);
    int sx = 56, sy = 118 + (isin(t*2)*22)/31;
    int ox, oy;

    /* two sine snake squads of swoopers */
    for (int i=0;i<8;i++) {
        int age = t*2 + i*13;
        int x = W+12 - age;
        if (x < -8 || x > W+8) continue;
        draw_swooper(x, 64 + (isin(age*2+i*4)*30)/31, f);
    }
    for (int i=0;i<8;i++) {
        int age = t*2 + i*13 + 40;
        int x = W+12 - age;
        if (x < -8 || x > W+8) continue;
        draw_swooper(x, 172 - (isin(age*2+i*4)*30)/31, f);
    }
    /* turret pods drifting in */
    for (int i=0;i<3;i++) {
        int px = 262 - i*44 - t/4;
        int py = 96 + i*34;
        draw_pod(px, py, f+i*3);
        /* aimed orb spread from each pod */
        for (int j=-1;j<=1;j++) {
            int ba = (t*3 + i*23) % 120;
            draw_orb(px-8-ba, py + (j*ba)/5, f);
        }
    }
    /* player + options firing */
    draw_ship(sx, sy, f);
    for (int w2=0;w2<2;w2++) {
        option_pos(sx, sy, f, w2, &ox, &oy);
        draw_option(ox, oy, f);
        draw_oshot(ox+6 + ((f*7)%160), oy);
        draw_oshot(ox+6 + ((f*7+80)%160), oy);
    }
    for (int k=0;k<4;k++) {
        int bx = sx+15 + ((f*8 + k*46) % 230);
        draw_pshot(bx, sy-2);
        draw_pshot(bx-10, sy+2);
    }
    /* homing missiles with smoke trails */
    for (int i=0;i<2;i++) {
        int age = (f*3 + i*70) % 200;
        int mx = sx+8+age;
        int my = sy + (i ? 1 : -1)*(10 + (isin(age*2)*16)/31);
        if (mx < W) {
            draw_missile(mx, my, 0);
            for (int s2=1;s2<=3;s2++) draw_smoke(mx-7*s2, my + (isin(age*2-s2*6)*4)/31, 2);
        }
    }
    /* battle chaos: rolling explosions + score popups */
    for (int i=0;i<4;i++) {
        int ex = 132 + i*46;
        int ey = 70 + (int)((h32(i+9)>>8)%96u);
        int ea = (t + i*12) % 48;
        draw_expl(ex, ey, ea, h32(i));
        if (ea >= 6 && ea < 26) {
            draw_num(ex-8, ey-12-ea/4, (i+1)*300u, 4, C(31,28,8));
        }
    }
    draw_hud(f);
}

static void scene_beam(int f,int t) {
    int sx = 52, sy = 120;
    int ox, oy;
    draw_destroyer(196, 120, f, 1);
    draw_beam(sx+15, sy, 196, f);
    draw_ship(sx, sy, f);
    for (int w2=0;w2<2;w2++) {
        option_pos(sx, sy, f, w2, &ox, &oy);
        draw_option(ox, oy, f);
        draw_oshot(ox+6 + ((f*7)%130), oy);
    }
    /* impact explosions on the nose */
    draw_expl(198, 114, (t)%30, 7u);
    draw_expl(204, 126, (t+11)%30, 19u);
    draw_expl(194, 120, (t+21)%26, 3u);
    /* debris chunks blown off */
    for (int i=0;i<6;i++) {
        int age = (t*2 + i*17) % 60;
        int dx2 = 198 - age*(1+(i%3));
        int dy2 = 120 + ((int)(h32(i*7u)%48u)-24)*age/40;
        fillr(dx2, dy2, 2, 2, C(20,12,6));
        put(dx2+2, dy2, C(31,14,0));
    }
    /* counterfire from the destroyer turrets */
    for (int i=0;i<3;i++) {
        int ba = (t*3 + i*31) % 130;
        draw_orb(216+i*22-ba, 104 + (((i*29)%30)-15)*ba/100, f);
    }
    draw_str(120, 26, "FULL CHARGE", ((f>>2)&1) ? C(10,31,31) : C(31,31,31));
    draw_hud(f);
}

static void scene_boss(int f,int t) {
    draw_planet(56, 56, 26);
    draw_boss(f);
    int sx = 52, sy = 120 + (isin(t*3)*36)/31;
    int ox, oy;
    draw_ship(sx, sy, f);
    for (int w2=0;w2<2;w2++) {
        option_pos(sx, sy, f, w2, &ox, &oy);
        draw_option(ox, oy, f);
        draw_oshot(ox+6 + ((f*7)%180), oy);
    }
    for (int k=0;k<3;k++) {
        int bx = sx+15 + ((f*8 + k*60) % 190);
        draw_pshot(bx, sy-2);
        draw_pshot(bx-10, sy+2);
    }
    /* radial orb fans from the core */
    for (int j=-3;j<=3;j++) {
        int ba = (t*3) % 120;
        draw_orb(244 - ba, 120 + (j*ba)/4, f);
        int ba2 = (t*3 + 60) % 120;
        draw_orb(244 - ba2, 120 + (j*ba2)/4, f+1);
    }
    /* aimed streams from turrets */
    for (int j2=0;j2<2;j2++) {
        int ty = j2 ? 184 : 56;
        for (int k=0;k<3;k++) {
            int ba = (t*4 + k*40) % 200;
            int bx = 276 - ba;
            int by = ty + ((sy-ty)*ba)/200;
            draw_orb(bx, by, f+k);
        }
    }
    /* hits sparking on the armour */
    draw_expl(266, 84, (t+4)%34, 11u);
    draw_expl(262, 158, (t+19)%34, 23u);
    /* boss hp bar */
    fillr(80, 15, 162, 7, C(3,3,6));
    hline(80, 241, 14, C(20,16,27));
    hline(80, 241, 22, C(20,16,27));
    int hp = 96 - t/2; if (hp < 30) hp = 30;
    fillr(81, 16, (160*hp)/100, 5, ((f>>3)&1) ? C(28,2,2) : C(24,0,0));
    draw_str(48, 16, "BOSS", C(31,6,6));
    /* WARNING splash for the first moments */
    if (t < 28) {
        for (int y=92;y<148;y++)
            for (int x=0;x<W;x++)
                if (((x+y)&1)==0) put(x, y, C(14,0,0));
        hline(0, W-1, 92,  C(31,4,4));
        hline(0, W-1, 147, C(31,4,4));
        draw_str2(118, 108, "WARNING", ((t>>2)&1) ? C(31,28,4) : C(31,8,4));
        draw_str(96, 130, "A HUGE BATTLESHIP", C(28,18,18));
        draw_str(96, 138, "IS APPROACHING FAST", C(28,18,18));
    }
    draw_hud(f);
}

int main(void) {
    /* 0=320x240, 2=16bpp, 3 bufs, 0=no gamma, 1=RESAMPLE */
    display_init(0, 2, 3, 0, 1);

    int f = 0;
    for (;;) {
        surface_t *d = display_get();
        fb = (uint16_t*)d->buffer;
        stride_px = (int)(d->stride / 2);

        draw_bg();
        draw_nebula(f);
        draw_stars(f);

        int t = f % 480;
        if      (t < 120) scene_title(f, t);
        else if (t < 240) scene_wave(f, t-120);
        else if (t < 360) scene_beam(f, t-240);
        else              scene_boss(f, t-360);

        display_show(d);
        f++;
    }
    return 0;
}
