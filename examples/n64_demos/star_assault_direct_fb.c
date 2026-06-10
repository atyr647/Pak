/* Direct framebuffer demo - bypasses RDPQ entirely */
#define _GNU_SOURCE

/* pak_compat.h (force-included) wraps display_init(int,int,int,int,int).
 * Use integer args to match: res=0 (320x240), bpp=2 (16bpp), buf=3, gamma=0, filt=1 (RESAMPLE) */

#include <libdragon.h>
#include <stdint.h>
#include <string.h>
#include "pak_math.h"

#define RGB16(r,g,b) ((uint16_t)(((r)<<11)|((g)<<6)|(b)))
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

static const uint8_t font[33][5] = {
    {0x00,0x00,0x00,0x00,0x00}, /* ' ' */
    {0x1F,0x11,0x1F,0x11,0x11}, /* A */
    {0x1E,0x11,0x1E,0x11,0x1E}, /* B */
    {0x0E,0x11,0x10,0x11,0x0E}, /* C */
    {0x1E,0x11,0x11,0x11,0x1E}, /* D */
    {0x1F,0x10,0x1E,0x10,0x1F}, /* E */
    {0x1F,0x10,0x1E,0x10,0x10}, /* F */
    {0x0E,0x11,0x17,0x11,0x0E}, /* G */
    {0x11,0x11,0x1F,0x11,0x11}, /* H */
    {0x0E,0x04,0x04,0x04,0x0E}, /* I */
    {0x01,0x01,0x01,0x11,0x0E}, /* J */
    {0x11,0x12,0x1C,0x12,0x11}, /* K */
    {0x10,0x10,0x10,0x10,0x1F}, /* L */
    {0x11,0x1B,0x15,0x11,0x11}, /* M */
    {0x11,0x19,0x15,0x13,0x11}, /* N */
    {0x0E,0x11,0x11,0x11,0x0E}, /* O */
    {0x1E,0x11,0x1E,0x10,0x10}, /* P */
    {0x0E,0x11,0x15,0x12,0x0D}, /* Q */
    {0x1E,0x11,0x1E,0x12,0x11}, /* R */
    {0x0E,0x10,0x0E,0x01,0x1E}, /* S */
    {0x1F,0x04,0x04,0x04,0x04}, /* T */
    {0x11,0x11,0x11,0x11,0x0E}, /* U */
    {0x11,0x11,0x0A,0x0A,0x04}, /* V */
    {0x11,0x11,0x15,0x1B,0x11}, /* W */
    {0x11,0x0A,0x04,0x0A,0x11}, /* X */
    {0x11,0x0A,0x04,0x04,0x04}, /* Y */
    {0x1F,0x02,0x04,0x08,0x1F}, /* Z */
    {0x0E,0x13,0x15,0x19,0x0E}, /* 0 */
    {0x04,0x0C,0x04,0x04,0x0E}, /* 1 */
    {0x1E,0x01,0x0E,0x10,0x1F}, /* 2 */
    {0x1F,0x02,0x06,0x01,0x1E}, /* 3 */
    {0x12,0x12,0x1F,0x02,0x02}, /* 4 */
    {0x1E,0x10,0x1E,0x01,0x1E}, /* 5 */
};

static void draw_chr(int x, int y, char c, uint16_t col) {
    int idx = 0;
    if (c >= 'A' && c <= 'Z') idx = 1 + (c - 'A');
    else if (c >= 'a' && c <= 'z') idx = 1 + (c - 'a');
    else if (c >= '0' && c <= '5') idx = 27 + (c - '0');
    else return;
    for (int row = 0; row < 5; row++) {
        uint8_t b = font[idx][row];
        for (int k = 0; k < 5; k++)
            if (b & (0x10 >> k)) put(x+k, y+row, col);
    }
}
static void draw_str(int x, int y, const char *s, uint16_t col) {
    while (*s) { draw_chr(x, y, *s++, col); x += 6; }
}

static uint32_t rng = 0xDEADBEEF;
static inline uint32_t rng_next(void) {
    return (rng = rng * 1664525 + 1013904223);
}

#define NS 64
static uint16_t sx[NS]; static uint8_t sy[NS], sspd[NS];
static void stars_init(void) {
    for (int i=0;i<NS;i++) {
        sx[i]=(uint16_t)(rng_next()%W);
        sy[i]=(uint8_t)(rng_next()%H);
        sspd[i]=(uint8_t)(1+rng_next()%3);
    }
}
static void stars_tick(void) {
    static const uint16_t sc[3]={RGB16(6,12,6),RGB16(14,28,14),RGB16(28,56,28)};
    for (int i=0;i<NS;i++) {
        sy[i]=(uint8_t)((sy[i]+sspd[i])%H);
        put(sx[i],sy[i],sc[sspd[i]-1]);
    }
}

static void ship(int cx,int cy) {
    uint16_t b=RGB16(10,22,28), cr=RGB16(24,50,31), e=RGB16(31,18,0);
    for (int i=-6;i<=6;i++) put(cx+i,cy+2,b);
    for (int i=-4;i<=4;i++) put(cx+i,cy,b);
    for (int i=-1;i<=1;i++) { put(cx+i,cy-3,cr); put(cx+i,cy-2,cr); }
    put(cx,cy-4,cr); put(cx,cy-1,b); put(cx,cy+1,b);
    put(cx-4,cy+3,e); put(cx-4,cy+4,e);
    put(cx+4,cy+3,e); put(cx+4,cy+4,e);
}
static void enemy(int cx,int cy) {
    fillr(cx-4,cy-3,9,7,RGB16(24,4,4));
    fillr(cx-2,cy-1,5,5,RGB16(31,0,0));
    put(cx,cy,RGB16(31,31,0));
}
static void boss(int cx,int cy) {
    fillr(cx-25,cy-8,51,17,RGB16(12,0,18));
    fillr(cx-12,cy-5,25,11,RGB16(22,0,28));
    fillr(cx-6,cy-2,13,5,RGB16(31,0,16));
    put(cx,cy,RGB16(31,63,31));
}
static void bullet(int x,int y,int friendly) {
    uint16_t c=friendly?RGB16(31,63,0):RGB16(31,0,0);
    put(x,y,c); put(x,y+1,RGB16(31,63,31)); put(x,y+2,c);
}
static void hpbar(int x,int y,int v,int m,uint16_t c) {
    int w=60*v/m;
    fillr(x,y,60,4,RGB16(4,4,4));
    if(w>0) fillr(x,y,w,4,c);
    for(int i=0;i<60;i++){put(x+i,y,RGB16(16,16,16));put(x+i,y+3,RGB16(16,16,16));}
}

int main(void) {
    /* display_init is macro'd to pak_display_init(int,int,int,int,int):
     * 0=320x240, 2=16bpp, 3 bufs, 0=no gamma, 1=RESAMPLE */
    display_init(0, 2, 3, 0, 1);

    stars_init();
    int f = 0;

    for (;;) {
        surface_t *d = display_get();
        fb = (uint16_t*)d->buffer;
        stride_px = (int)(d->stride / 2);

        /* Background gradient */
        for (int y=0;y<H;y++) {
            uint16_t bg=RGB16(0,y/40,y/20);
            for (int x=0;x<W;x++) fb[y*stride_px+x]=bg;
        }

        stars_tick();

        int t = f % 180;
        if (t < 90) {
            /* Title */
            draw_str(46, 55, "STAR ASSAULT", RGB16(20,42,31));
            draw_str(70, 65, "N64 SHMUP", RGB16(0,32,31));
            draw_str(40, 78, "BUILT WITH PAKSTUDIO", RGB16(14,14,8));
            draw_str(52, 90, "PAK COMPILER", RGB16(12,6,0));
            draw_str(52, 102, "LIBDRAGON N64", RGB16(0,14,14));
            ship(160,148);
            enemy(100,160); enemy(160,160); enemy(220,160);
            bullet(160,133,1); bullet(160,124,1);
            if ((t/15)%2==0) draw_str(70,175,"PRESS START",RGB16(28,56,28));
        } else {
            int et = t - 90;
            boss(160, 44 + (et%8) - 4);
            hpbar(100,3,65,100,RGB16(31,0,0));
            draw_str(62,3,"BOSS",RGB16(31,0,0));
            for (int col=0;col<4;col++) {
                enemy(50+col*70, 25+(et%20));
                enemy(50+col*70, 50+(et%20));
            }
            ship(160,198);
            bullet(160,183-et%30,1); bullet(155,165-et%30,1);
            bullet(130,110+et%30,0); bullet(185,95+et%30,0);
            fillr(0,222,320,18,RGB16(2,2,8));
            draw_str(4,226,"SCORE",RGB16(0,28,28));
            draw_str(40,226,"12500",RGB16(24,50,24));
            draw_str(108,226,"STAGE",RGB16(0,28,28));
            draw_str(144,226,"1",RGB16(28,28,0));
            draw_str(172,226,"LIVES",RGB16(0,28,28));
            draw_str(208,226,"3",RGB16(28,28,0));
            hpbar(244,224,75,100,RGB16(0,31,0));
        }

        display_show(d);
        f++;
    }
    return 0;
}
