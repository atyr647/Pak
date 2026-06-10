/* Sky Quest - direct framebuffer platformer demo - bypasses RDPQ entirely */
#define _GNU_SOURCE
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

static const uint8_t fnt[27][5] = {
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
};
static void dc(int x,int y,char c,uint16_t col) {
    int i=0;
    if(c>='A'&&c<='Z') i=1+(c-'A');
    else if(c>='a'&&c<='z') i=1+(c-'a');
    else return;
    for(int r=0;r<5;r++){uint8_t b=fnt[i][r];for(int k=0;k<5;k++) if(b&(0x10>>k)) put(x+k,y+r,col);}
}
static void ds(int x,int y,const char*s,uint16_t col){while(*s){dc(x,y,*s++,col);x+=6;}}

#define TW 20
#define TH 14
static const uint8_t tilemap[TH][TW] = {
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,2,2,2,0,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,2,2,2,2,0,0},
    {0,0,2,2,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {1,1,1,0,0,0,0,1,1,1,1,0,0,0,0,0,1,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {1,1,1,1,1,0,0,0,1,1,1,1,1,1,0,0,0,1,1,1},
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0},
    {1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1},
};
#define TILE_SZ 16
static void draw_tile(int tx, int ty) {
    int px2=tx*TILE_SZ, py2=ty*TILE_SZ;
    uint8_t t=tilemap[ty][tx];
    if(t==1) {
        fillr(px2,py2,TILE_SZ,TILE_SZ,RGB16(12,10,6));
        fillr(px2,py2,TILE_SZ,2,RGB16(8,22,4));
    } else if(t==2) {
        fillr(px2,py2,TILE_SZ,4,RGB16(18,12,6));
        fillr(px2,py2,TILE_SZ,2,RGB16(10,24,6));
    }
}

static void draw_bg(int scroll) {
    for(int y=0;y<H;y++) {
        int r=(y<120)?(5+y/8):15;
        int g=(y<120)?(20+y/6):28;
        int b=(y<120)?(28-y/15):20;
        for(int x=0;x<W;x++) fb[y*stride_px+x]=RGB16(r,g,b);
    }
    for(int x=0;x<W;x++) {
        int mx=(x+scroll/3)%W;
        int mh=60+((mx*17+mx*mx/40)%30);
        for(int y=H-80-mh;y<H-80;y++) if(y>=0) put(x,y,RGB16(15,18,20));
    }
    int cx=(scroll/2)%W;
    for(int off=0;off<3;off++) {
        int cx2=(cx+off*110)%W;
        fillr(cx2,30+off*15,40,10,RGB16(28,30,31));
        fillr(cx2+5,25+off*15,30,8,RGB16(28,30,31));
    }
}

static void draw_player(int px2,int py2,int wf) {
    uint16_t skin=RGB16(28,22,16),hair=RGB16(20,10,4),body=RGB16(8,16,28),leg=RGB16(6,14,24);
    fillr(px2+3,py2,8,8,skin);
    fillr(px2+3,py2,8,3,hair);
    fillr(px2+2,py2+8,10,8,body);
    fillr(px2,py2+8,3,6,skin);
    fillr(px2+11,py2+8,3,6,skin);
    int la=wf<3?2:0, lb=wf<3?0:2;
    fillr(px2+2,py2+16,4,8,leg);
    fillr(px2+7,py2+16,4,8,leg);
    put(px2+2+la,py2+22,skin); put(px2+7+lb,py2+22,skin);
}
static void draw_enemy(int ex,int ey) {
    fillr(ex+2,ey+2,12,6,RGB16(20,10,4));
    fillr(ex,ey+4,16,8,RGB16(20,10,4));
    put(ex+4,ey+5,RGB16(31,31,31)); put(ex+10,ey+5,RGB16(31,31,31));
    put(ex+4,ey+6,RGB16(0,0,0));    put(ex+10,ey+6,RGB16(0,0,0));
    fillr(ex+1,ey+11,5,4,RGB16(4,4,4));
    fillr(ex+9,ey+11,5,4,RGB16(4,4,4));
}
static void draw_coin(int cx2,int cy2,int frame) {
    uint16_t c=(frame/3)%2?RGB16(28,24,0):RGB16(31,28,4);
    fillr(cx2+2,cy2,4,8,c);
    put(cx2+1,cy2+1,c); put(cx2+1,cy2+6,c);
    put(cx2+6,cy2+1,c); put(cx2+6,cy2+6,c);
}
static void draw_hud(int coins, int lives, int score) {
    fillr(0,0,W,14,RGB16(0,0,0));
    ds(2,4,"COINS",RGB16(28,24,0));
    char cb='0'+(char)(coins%10);
    dc(38,4,cb,RGB16(28,56,0));
    ds(80,4,"LIVES",RGB16(28,0,0));
    char lb='0'+(char)(lives%10);
    dc(116,4,lb,RGB16(31,8,8));
    ds(160,4,"SCORE",RGB16(0,24,28));
    int s=score%1000;
    dc(196,4,'0'+s/100,RGB16(8,56,31));
    dc(202,4,'0'+(s/10)%10,RGB16(8,56,31));
    dc(208,4,'0'+s%10,RGB16(8,56,31));
    ds(250,4,"STAGE",RGB16(16,16,0));
    dc(286,4,'1',RGB16(28,28,4));
}

int main(void) {
    display_init(0, 2, 3, 0, 1);
    int f=0;
    for(;;) {
        surface_t *d=display_get();
        fb=(uint16_t*)d->buffer;
        stride_px=(int)(d->stride/2);

        draw_bg(f);
        for(int ty=0;ty<TH;ty++) for(int tx=0;tx<TW;tx++) draw_tile(tx,ty);

        int wf=(f/8)%6;
        int px2=40+(f%2);
        draw_player(px2, 176, wf);
        draw_enemy(120+((f/2)%60), 192);
        draw_enemy(200, 160);
        draw_coin(60,64,f); draw_coin(76,64,f+2); draw_coin(92,64,f+4);
        draw_coin(180,48,f); draw_coin(196,48,f+2);
        draw_hud(3, 5, (f/2)%1000);

        int t=f%300;
        if(t < 90) {
            fillr(50,95,220,50,RGB16(0,0,8));
            ds(60,102,"SKY QUEST",RGB16(10,30,31));
            ds(64,114,"N64 PLATFORMER",RGB16(20,42,28));
            ds(52,126,"BUILT WITH PAKSTUDIO",RGB16(14,14,8));
            if((t/15)%2==0) ds(74,138,"PRESS START",RGB16(28,56,28));
        }

        display_show(d);
        f++;
    }
    return 0;
}
