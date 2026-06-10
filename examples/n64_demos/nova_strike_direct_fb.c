/* Nova Strike - vertical shmup demo (Raiden / DoDonPachi style).
 * Direct framebuffer rendering - bypasses RDPQ entirely.
 * Four looping scenes: title, ground assault with bomb blast,
 * danmaku midboss, battleship boss with WARNING splash. */
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

/* ── scrolling ground terrain ───────────────────────────────────────────── */
static void draw_terrain(int f) {
    int scroll = f*2;
    for (int y=0;y<H;y++) {
        int wy  = y + scroll;
        int row = wy>>4, ly = wy&15;
        int rcx = 160 + (isin(wy>>3)*50)/31;     /* meandering river centre */
        int road = ((wy & 511) < 8);
        uint16_t *line = &fb[y*stride_px];
        for (int col=0;col<20;col++) {
            uint32_t hs = h32((uint32_t)(row*131+col));
            uint16_t base = ((row+col)&1) ? C(2,9,3) : C(3,8,3);
            if ((hs%5)==0) base = C(2,7,2);
            int feat = (int)(hs%23u);
            for (int lx=0;lx<16;lx++) {
                int x = col*16+lx;
                if (x >= W) break;
                uint16_t c = base;
                if (feat == 3) {                  /* tree */
                    int ddx=lx-8, ddy=ly-8, q=ddx*ddx+ddy*ddy;
                    if (q < 26) c = (ddx+ddy < -3) ? C(3,12,3) : C(1,6,2);
                } else if (feat == 7) {           /* building */
                    if (lx>=2 && lx<14 && ly>=2 && ly<14) {
                        c = C(12,12,13);
                        if (ly==2 || lx==2)  c = C(16,16,17);
                        if (lx==13 || ly==13) c = C(7,7,8);
                        if (lx==11 && ly==4) c = ((f>>3)&1) ? C(31,4,4) : C(10,2,2);
                    } else if ((lx==14 || ly==14) && lx>2 && ly>2) c = C(1,4,1);
                } else if (feat == 11) {          /* crater */
                    int ddx=lx-8, ddy=ly-8, q=ddx*ddx+ddy*ddy;
                    if (q<=12) c = C(1,3,1);
                    else if (q<30) c = C(4,5,3);
                }
                int dxr = x - rcx;                /* river overrides */
                if (dxr > -17 && dxr < 17) {
                    if (dxr > -14 && dxr < 14) {
                        c = C(3,7,17);
                        if (((x*7+wy*3)&63) < 2) c = C(9,16,27);
                        if (dxr < -10 || dxr > 10) c = C(4,9,20);
                    } else c = C(7,8,4);          /* sandy bank */
                }
                if (road) {                       /* road bridges the river */
                    c = C(9,9,9);
                    int rly = wy & 511;
                    if (rly==0 || rly==7) c = C(13,13,13);
                    if (((x>>3)&1) && (rly==3 || rly==4)) c = C(20,20,8);
                }
                line[x] = c;
            }
        }
    }
}
static void draw_clouds_low(int f) {
    for (int i=0;i<5;i++) {
        uint32_t hs = h32(i*517u+99u);
        int span = H+120;
        int cy = (((int)(hs%(unsigned)span)) + f*3) % span - 60;
        int cx = (int)((hs>>10)%W);
        int r  = 18 + (int)((hs>>20)%14u);
        disc_dith(cx, cy, r, C(22,23,26));
        disc_dith(cx+8, cy+4, r-6, C(26,27,30));
    }
}
static void draw_clouds_high(int f) {
    for (int i=0;i<3;i++) {
        uint32_t hs = h32(i*733u+7u);
        int span = H+160;
        int cy = (((int)(hs%(unsigned)span)) + f*5) % span - 80;
        int cx = (int)((hs>>8)%W);
        int r  = 24 + (int)((hs>>20)%16u);
        for (int dy=-r;dy<=r;dy++) {
            int hf = isqrt(r*r-dy*dy), yy = cy+dy;
            if ((unsigned)yy >= H) continue;
            for (int x=cx-hf;x<=cx+hf;x++)
                if (((x+yy*3)&3) == 0) put(x, yy, C(28,29,31));
        }
    }
}

/* ── player ─────────────────────────────────────────────────────────────── */
static void draw_player(int px,int py,int f) {
    uint16_t hull = C(18,22,28), hull2 = C(10,14,22);
    uint16_t wing = C(6,12,26),  wingE = C(12,22,31);
    uint16_t can  = C(10,31,31);
    /* wings, widest at the back */
    for (int i=0;i<4;i++) hline(px-3-i*3, px+3+i*3, py+i, wing);
    hline(px-12, px-9, py+4, wingE); hline(px+9, px+12, py+4, wingE);
    /* tail fins */
    hline(px-5, px-3, py+6, wing); hline(px+3, px+5, py+6, wing);
    /* fuselage */
    fillr(px-1, py-8, 3, 14, hull);
    fillr(px-2, py-4, 1, 8, hull2); fillr(px+2, py-4, 1, 8, hull2);
    put(px, py-9, C(31,8,4)); put(px, py-10, C(28,28,30));
    fillr(px-1, py-5, 3, 4, can);
    /* twin exhausts */
    int len = 4 + ((f>>1)&3);
    for (int j=0;j<len;j++) {
        uint16_t c = (j<1) ? C(31,31,28) : (j<3) ? C(31,24,4) : C(31,11,0);
        put(px-1, py+7+j, c); put(px+1, py+7+j, c);
        if (j < 2) put(px, py+7+j, C(31,31,31));
    }
}
static void draw_opt(int x,int y,int f) {
    fillr(x-1, y-3, 3, 7, C(20,20,26));
    put(x, y, ((f>>2)&1) ? C(10,31,31) : C(31,31,31));
    put(x, y-4, C(12,22,31));
    put(x, y+4, C(31,14,0));
}

/* ── projectiles / fx ───────────────────────────────────────────────────── */
static void draw_vshot(int x,int y) {
    fillr(x, y, 1, 7, C(31,28,8));
    put(x, y-1, C(31,31,31));
    put(x-1, y+1, C(31,20,2)); put(x+1, y+1, C(31,20,2));
}
static void draw_oshot(int x,int y) {
    fillr(x, y, 1, 5, C(10,31,31));
    put(x, y-1, C(31,31,31));
}
static void draw_orb(int x,int y,int f) {
    uint16_t p = ((f>>1)&1) ? C(31,8,24) : C(28,4,20);
    put(x,y,C(31,27,29));
    put(x-1,y,p); put(x+1,y,p); put(x,y-1,p); put(x,y+1,p);
    put(x-1,y-1,C(18,2,12)); put(x+1,y-1,C(18,2,12));
    put(x-1,y+1,C(18,2,12)); put(x+1,y+1,C(18,2,12));
}
static void draw_dot(int x,int y) {
    put(x,y,C(31,27,29));
    put(x-1,y,C(28,4,20)); put(x+1,y,C(28,4,20));
    put(x,y-1,C(28,4,20)); put(x,y+1,C(28,4,20));
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
        int sx = x + (icos(a)*age*2)/40;
        int sy = y + (isin(a)*age*2)/40;
        put(sx, sy, C(31,24,6));
        put(sx, sy+1, C(31,12,0));
    }
}

/* ── enemies ────────────────────────────────────────────────────────────── */
static void draw_popcorn(int x,int y,int f) {
    uint16_t b = C(17,7,19), t = C(24,10,26);
    hline(x-1, x+1, y-4, t);
    fillr(x-1, y-3, 3, 7, b);
    hline(x-5, x+5, y-2, b);
    hline(x-4, x+4, y-1, t);
    put(x, y+4, C(31,28,8));                       /* cockpit faces down */
    put(x, y-5, ((f>>1)&1) ? C(31,12,0) : C(31,22,4));
}
static void draw_tank(int x,int y,int px,int py,int f) {
    fillr(x-6, y-4, 13, 9, C(5,6,4));
    fillr(x-6, y-4, 2, 9, C(3,3,3)); fillr(x+5, y-4, 2, 9, C(3,3,3));
    fillr(x-4, y-3, 9, 7, C(7,10,6));
    hline(x-4, x+4, y-3, C(10,14,9));
    disc(x, y, 3, C(9,12,8)); circ(x, y, 3, C(12,16,11));
    /* barrel tracks the player */
    int dx = px-x, dy = py-y;
    int adx = dx<0?-dx:dx, ady = dy<0?-dy:dy;
    int m = adx>ady ? adx : ady; if (m == 0) m = 1;
    for (int s=2;s<=6;s++) put(x+(dx*s)/m, y+(dy*s)/m, C(13,16,12));
    if (((f>>2)&3) == 0) put(x+(dx*6)/m, y+(dy*6)/m, C(31,31,31));
}
static void draw_midboss(int cx,int cy,int f) {
    /* spinning rotor blades, dithered */
    for (int j=0;j<4;j++) {
        int a = f*6 + j*16;
        for (int s=5;s<26;s++) {
            int bx = cx+(icos(a)*s)/31, by = cy+(isin(a)*s)/31;
            if (((bx+by)&1) == 0) put(bx, by, C(14,14,16));
        }
    }
    circ(cx, cy, 26, C(10,10,12));
    disc(cx, cy, 14, C(12,9,16)); circ(cx, cy, 14, C(18,14,24));
    disc(cx, cy, 8, C(8,5,12));
    int pul = (isin(f*6)+31)/2;
    disc(cx, cy, 4, C(31, pul/2, pul/3));
    /* side gun pods */
    for (int j=0;j<2;j++) {
        int gx = j ? cx+20 : cx-20;
        disc(gx, cy+6, 5, C(12,9,16)); circ(gx, cy+6, 5, C(18,14,24));
        put(gx, cy+6, (((f>>2)+j)&1) ? C(31,31,31) : C(31,6,6));
    }
}
static void draw_vboss(int f) {
    uint16_t arm = C(9,7,14), arm2 = C(14,11,20), edge = C(20,16,27);
    /* hull, tapering to the bow at the bottom */
    for (int y=14;y<88;y++) {
        int hw = 78 - (y>58 ? (y-58)*2 : 0);
        if (hw < 10) hw = 10;
        hline(160-hw, 160+hw, y, arm);
    }
    hline(82, 238, 14, edge);
    /* centre spine */
    fillr(150, 16, 21, 68, arm2);
    for (int y=18;y<82;y+=3) put(160, y, edge);
    /* wing pods */
    fillr(78, 28, 18, 30, arm2); hline(78, 95, 28, edge); put(86, 60, C(31,8,4));
    fillr(225, 28, 18, 30, arm2); hline(225, 242, 28, edge); put(233, 60, C(31,8,4));
    /* turrets with barrels aimed down */
    for (int j=0;j<2;j++) {
        int tx = j ? 196 : 124;
        disc(tx, 40, 8, arm2); circ(tx, 40, 8, edge);
        fillr(tx-1, 48, 3, 6, C(18,18,22));
        put(tx, 40, ((f>>2)&1) ? C(31,31,31) : C(31,6,6));
    }
    /* pulsing core */
    disc(160, 64, 12, C(4,3,8)); circ(160, 64, 13, edge);
    int pul = (isin(f*6)+31)/2;
    disc(160, 64, 7, C(31, pul/2, pul/3));
    disc(160, 64, 3, C(31,28,20));
    /* engine glow along the stern */
    for (int i=0;i<5;i++) {
        uint16_t g = ((f+i)&3)<2 ? C(10,24,31) : C(6,14,26);
        fillr(122+i*18, 12, 6, 2, g);
    }
}

/* ── vertical charge laser ──────────────────────────────────────────────── */
static void draw_vlaser(int x,int y0,int y1,int f) {     /* beam from y0 up to y1 */
    for (int y=y1;y<y0;y++) {
        int hh = 3 + (isin(y*4+f*10)+31)/21;
        for (int dx=-hh;dx<=hh;dx++) {
            int ad = dx<0?-dx:dx;
            uint16_t c = (ad<=1) ? C(31,31,31)
                       : (ad<=hh-2) ? C(12,31,31)
                       : C(3,15,31);
            put(x+dx, y, c);
        }
    }
    disc(x, y0, 6+((f>>1)&3), C(31,31,31));
    circ(x, y0, 9+((f>>1)&3), C(12,31,31));
    for (int k=0;k<3;k++) {
        int ry = y0 - ((f*6 + k*40) % (y0-y1));
        circ(x, ry, 7, C(10,28,31));
    }
}

/* ── HUD ────────────────────────────────────────────────────────────────── */
static void draw_hud(int f) {
    fillr(0, 0, W, 11, C(1,1,3));
    hline(0, W-1, 11, C(8,8,13));
    draw_str(4, 3, "SCORE", C(0,24,28));
    draw_num(38, 3, 100000u + (unsigned)(f/2)*50u, 7, C(31,31,31));
    draw_str(124, 3, "HI", C(24,18,0));
    draw_num(140, 3, 9999999u, 7, C(31,28,8));
    draw_str(226, 3, "ST 2", C(0,24,28));
    draw_str(262, 3, "CREDIT 01", C(16,16,18));

    fillr(0, 229, W, 11, C(1,1,3));
    hline(0, W-1, 229, C(8,8,13));
    /* lives: mini vertical ships */
    for (int i=0;i<3;i++) {
        int lx = 8+i*12;
        put(lx, 231, C(31,8,4));
        fillr(lx-1, 232, 3, 4, C(18,22,28));
        hline(lx-3, lx+3, 235, C(6,12,26));
    }
    /* bombs */
    draw_str(50, 232, "B", C(31,18,0));
    disc(64, 234, 3, C(31,14,0)); circ(64, 234, 3, C(31,24,6));
    disc(74, 234, 3, C(31,14,0)); circ(74, 234, 3, C(31,24,6));
    /* power meter */
    draw_str(110, 232, "PW", C(10,31,31));
    fillr(126, 232, 102, 5, C(3,3,6));
    int chg = (f*2)%160; if (chg > 100) chg = 100;
    for (int i=0;i<chg;i++) {
        uint16_t c = (i<50) ? C(2,10+i/4,31) : (i<85) ? C(8,28,31) : C(31,31,31);
        put(127+i, 233, c); put(127+i, 234, c); put(127+i, 235, c);
    }
    hline(126, 227, 231, C(10,10,16));
    hline(126, 227, 237, C(10,10,16));
}

/* ════════════════ scenes (period 480) ════════════════ */

static void scene_title(int f,int t) {
    draw_str2(96, 44, "NOVA STRIKE", C(2,4,12));
    draw_str2(94, 42, "NOVA STRIKE", C(31,24,8));
    hline(94, 94+131, 64, C(24,16,4));
    draw_str(97, 70, "VERTICAL BARRAGE TYPE", C(28,12,2));
    int px = 160 + (isin(t)*6)/31;
    int py = 150 + (isin(t*2)*6)/31;
    draw_player(px, py, f);
    draw_opt(px-14, py+2, f); draw_opt(px+14, py+2, f);
    for (int i=0;i<3;i++)
        draw_popcorn(120+i*40, 96+(isin(t*2+i*12)*5)/31, f);
    if ((t/16)%2 == 0) draw_str(127, 188, "PRESS START", C(20,31,20));
    draw_str(100, 210, "BUILT WITH PAKSTUDIO", C(11,11,8));
    draw_str(136, 222, "N64 DEMO", C(8,8,12));
}

static void scene_wave(int f,int t) {
    int px = 160 + (isin(t*2)*40)/31, py = 190;

    /* tanks rolling with the terrain, barrels tracking the player */
    for (int i=0;i<3;i++) {
        int sy = ((f*2 + i*200) % (H+260)) - 40;
        int sx = 60 + (int)(h32(i*89u+5u) % (unsigned)(W-120));
        if (sy > -20 && sy < H+20) {
            draw_tank(sx, sy, px, py, f);
            for (int b=0;b<2;b++) {
                int ba = (t*3 + i*31 + b*55) % 110;
                draw_orb(sx + ((px-sx)*ba)/110, sy + ((py-sy)*ba)/110, f+b);
            }
        }
    }
    /* two V-formations of popcorn diving down */
    for (int i=0;i<6;i++) {
        int age = t*3 - i*9;
        if (age < 0 || age > H+30) continue;
        int x = 92 + (2*i-5)*9 + (isin(age+i*8)*10)/31;
        draw_popcorn(x, -12+age, f);
    }
    for (int i=0;i<6;i++) {
        int age = t*3 - i*9 - 40;
        if (age < 0 || age > H+30) continue;
        int x = 230 - (2*i-5)*9 + (isin(age+i*8)*10)/31;
        draw_popcorn(x, -12+age, f);
    }
    /* player + options firing */
    draw_player(px, py, f);
    draw_opt(px-14, py+2, f); draw_opt(px+14, py+2, f);
    for (int k=0;k<4;k++) {
        int age = (f*9 + k*43) % 170;
        draw_vshot(px-2, py-12-age);
        draw_vshot(px+2, py-16-((f*9+k*43+85)%170));
    }
    for (int k=0;k<3;k++) {                       /* spread shots */
        int age = (f*8 + k*55) % 180;
        draw_vshot(px-12 - age/8, py-12-age);
        draw_vshot(px+12 + age/8, py-12-age);
    }
    for (int k=0;k<2;k++) {
        int age = (f*9 + k*70) % 150;
        draw_oshot(px-14, py-6-age);
        draw_oshot(px+14, py-6-age);
    }
    /* rolling explosions + score popups */
    for (int i=0;i<4;i++) {
        int ex = 60 + (int)((h32(i+31u)>>6)%200u);
        int ey = 50 + (int)((h32(i+77u)>>9)%120u);
        int ea = (t + i*12) % 48;
        draw_expl(ex, ey, ea, h32(i));
        if (ea >= 6 && ea < 26)
            draw_num(ex-8, ey-12-ea/4, (i+1)*300u, 4, C(31,28,8));
    }
    /* bomb blast near the end of the wave */
    if (t >= 84 && t < 116) {
        int hage = t-84;
        int r = 8 + hage*7;
        circ(160, 120, r,   C(31,31,31));
        circ(160, 120, r-2, C(12,31,31));
        circ(160, 120, r-4, C(3,15,31));
        if (hage < 6)
            for (int y=0;y<H;y++)
                for (int x=(y&1);x<W;x+=2) put(x, y, C(31,31,31));
    }
}

static void scene_mid(int f,int t) {
    int px = 160 + (isin(t*3)*52)/31, py = 192;
    int cx = 160 + (isin(t)*8)/31, cy = 64;
    draw_midboss(cx, cy, f);
    /* expanding danmaku rings */
    for (int g=0;g<3;g++) {
        int age = (t*2 + g*30) % 96;
        int rad = 6 + age*2;
        for (int j=0;j<16;j++) {
            int a = j*4 + g*2 + t/2;
            draw_dot(cx+(icos(a)*rad)/31, cy+(isin(a)*rad)/31);
        }
    }
    /* twin spirals */
    for (int j=0;j<8;j++) {
        int a = j*8 + t*4;
        int rad = (t*3 + j*36) % 170;
        draw_orb(cx+(icos(a)*rad)/31, cy+(isin(a)*rad)/31, f+j);
        draw_orb(cx-(icos(a)*rad)/31, cy-(isin(a)*rad)/31, f+j+1);
    }
    /* player return fire */
    draw_player(px, py, f);
    draw_opt(px-14, py+2, f); draw_opt(px+14, py+2, f);
    for (int k=0;k<4;k++) {
        int age = (f*9 + k*43) % 170;
        draw_vshot(px-2, py-12-age);
        draw_vshot(px+2, py-16-((f*9+k*43+85)%170));
    }
    /* hits sparking on the hull */
    draw_expl(cx-10, cy-6, (t+6)%30, 5u);
    draw_expl(cx+12, cy+8, (t+19)%30, 9u);
    /* mini hp bar */
    fillr(110, 15, 102, 5, C(3,3,6));
    int hp = 90 - t/2; if (hp < 25) hp = 25;
    fillr(111, 16, hp, 3, C(28,2,2));
    hline(110, 211, 14, C(20,16,27));
    hline(110, 211, 20, C(20,16,27));
}

static void scene_boss(int f,int t) {
    int px = 160 + (isin(t*2)*34)/31, py = 196;
    draw_vboss(f);
    /* bullet spirals from the core */
    for (int j=0;j<12;j++) {
        int a = j*5 + t*4;
        int rad = (t*4 + j*30) % 170;
        int bx = 160+(icos(a)*rad)/31, by = 64+(isin(a)*rad)/31;
        if (by > 12) draw_orb(bx, by, f+j);
    }
    /* aimed 5-way fans from the turrets */
    for (int j2=0;j2<2;j2++) {
        int tx = j2 ? 196 : 124;
        for (int k=-2;k<=2;k++) {
            int ba = (t*3 + j2*20) % 130;
            int bx = tx + ((px-tx)*ba)/130 + (k*ba)/7;
            int by = 50 + ((py-50)*ba)/130;
            draw_orb(bx, by, f+k);
        }
    }
    /* player with charge laser */
    if (t >= 28) draw_vlaser(px, py-10, 90, f);
    draw_player(px, py, f);
    draw_opt(px-14, py+2, f); draw_opt(px+14, py+2, f);
    for (int k=0;k<2;k++) {
        int age = (f*9 + k*70) % 150;
        draw_oshot(px-14, py-6-age);
        draw_oshot(px+14, py-6-age);
    }
    /* damage on the hull */
    draw_expl(132, 70, (t+4)%34, 11u);
    draw_expl(192, 52, (t+19)%34, 23u);
    draw_expl(160, 86, (t+11)%30, 17u);
    /* boss hp bar */
    fillr(80, 15, 162, 7, C(3,3,6));
    hline(80, 241, 14, C(20,16,27));
    hline(80, 241, 22, C(20,16,27));
    int hp = 96 - t/2; if (hp < 30) hp = 30;
    fillr(81, 16, (160*hp)/100, 5, ((f>>3)&1) ? C(28,2,2) : C(24,0,0));
    draw_str(48, 16, "BOSS", C(31,6,6));
    /* WARNING splash */
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
}

int main(void) {
    /* 0=320x240, 2=16bpp, 3 bufs, 0=no gamma, 1=RESAMPLE */
    display_init(0, 2, 3, 0, 1);

    int f = 0;
    for (;;) {
        surface_t *d = display_get();
        fb = (uint16_t*)d->buffer;
        stride_px = (int)(d->stride / 2);

        draw_terrain(f);
        draw_clouds_low(f);

        int t = f % 480;
        if      (t < 120) scene_title(f, t);
        else if (t < 240) scene_wave(f, t-120);
        else if (t < 360) scene_mid(f, t-240);
        else              scene_boss(f, t-360);

        draw_clouds_high(f);
        if (t >= 120) draw_hud(f);

        display_show(d);
        f++;
    }
    return 0;
}
