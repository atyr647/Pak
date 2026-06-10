/* Riverdale Saga - top-down RPG showcase at N64 hi-res (640x480, RGBA5551).
 * Direct framebuffer (CPU writes, no rdpq/RSP) so it scans out under the
 * headless capture pipeline. Era-appropriate late-90s JRPG aesthetic: ordered
 * dithering for smooth gradients, textured 32x32 tiles, shaded & outlined
 * sprites, and ornate gradient UI windows. Ten cycling scenes. */
#define _GNU_SOURCE
#include <libdragon.h>
#include <stdint.h>
#include <string.h>
#include "pak_math.h"

#define W 640
#define H 480
static uint16_t *fb;
static int stride_px;

/* RGBA5551 from 5-bit channels */
#define C(r,g,b) ((uint16_t)(((r)<<11)|((g)<<6)|((b)<<1)|1))

static inline void put(int x,int y,uint16_t c){ if((unsigned)x<W&&(unsigned)y<H) fb[y*stride_px+x]=c; }
static void fillr(int x,int y,int w,int h,uint16_t c){
 for(int dy=0;dy<h;dy++){int yy=y+dy; if((unsigned)yy>=H)continue;
   uint16_t*row=&fb[yy*stride_px]; for(int dx=0;dx<w;dx++){int xx=x+dx; if((unsigned)xx<W)row[xx]=c;}}}
static void hbar(int x0,int x1,int y,uint16_t c){ if((unsigned)y>=H)return;
 if(x0<0)x0=0; if(x1>=W)x1=W-1; uint16_t*row=&fb[y*stride_px]; for(int x=x0;x<=x1;x++)row[x]=c; }
static void rect_outline(int x,int y,int w,int h,uint16_t c){
 hbar(x,x+w-1,y,c); hbar(x,x+w-1,y+h-1,c);
 for(int i=0;i<h;i++){put(x,y+i,c);put(x+w-1,y+i,c);}}
static int isqrt(int v){int r=0;while((r+1)*(r+1)<=v)r++;return r;}
static void disc(int cx,int cy,int r,uint16_t c){
 for(int dy=-r;dy<=r;dy++){int hf=isqrt(r*r-dy*dy); hbar(cx-hf,cx+hf,cy+dy,c);}}
static void ring(int cx,int cy,int r,uint16_t c){
 for(int dy=-r;dy<=r;dy++){int hf=isqrt(r*r-dy*dy); put(cx-hf,cy+dy,c); put(cx+hf,cy+dy,c);}
 for(int dx=-r;dx<=r;dx++){int vf=isqrt(r*r-dx*dx); put(cx+dx,cy-vf,c); put(cx+dx,cy+vf,c);}}

/* ── ordered dithering (4x4 Bayer) → smooth N64-style gradients ─────────────── */
static const uint8_t BAYER[4][4]={{0,8,2,10},{12,4,14,6},{3,11,1,9},{15,7,13,5}};
/* channel 0..255 → 5-bit with ordered dither at (x,y). Division-free hot path:
 * top 5 bits give the level, low 3 bits drive the Bayer threshold. */
static inline int dith5(int v,int x,int y){
 int base=v>>3; if(((v&7)<<1) > BAYER[y&3][x&3]) base++; if(base>31)base=31; return base;
}
static inline void put_rgb(int x,int y,int r,int g,int b){
 if((unsigned)x>=W||(unsigned)y>=H)return;
 fb[y*stride_px+x]=C(dith5(r,x,y),dith5(g,x,y),dith5(b,x,y));
}
/* vertical gradient fill (RGB 0..255 endpoints), dithered */
static void vgrad(int x,int y,int w,int h,int r0,int g0,int b0,int r1,int g1,int b1){
 for(int dy=0;dy<h;dy++){int yy=y+dy; if((unsigned)yy>=H)continue;
   int r=r0+(r1-r0)*dy/h, g=g0+(g1-g0)*dy/h, b=b0+(b1-b0)*dy/h;
   for(int dx=0;dx<w;dx++)put_rgb(x+dx,yy,r,g,b);}}

/* ── 5x7 bitmap font (uppercase, digits, punctuation) ───────────────────────── */
static const uint8_t F[][7]={
 {0,0,0,0,0,0,0},                                  /* space */
 {0x0E,0x11,0x11,0x1F,0x11,0x11,0x11},/*A*/{0x1E,0x11,0x1E,0x11,0x11,0x11,0x1E},/*B*/
 {0x0E,0x11,0x10,0x10,0x10,0x11,0x0E},/*C*/{0x1E,0x11,0x11,0x11,0x11,0x11,0x1E},/*D*/
 {0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F},/*E*/{0x1F,0x10,0x10,0x1E,0x10,0x10,0x10},/*F*/
 {0x0E,0x11,0x10,0x17,0x11,0x11,0x0F},/*G*/{0x11,0x11,0x11,0x1F,0x11,0x11,0x11},/*H*/
 {0x0E,0x04,0x04,0x04,0x04,0x04,0x0E},/*I*/{0x07,0x02,0x02,0x02,0x02,0x12,0x0C},/*J*/
 {0x11,0x12,0x14,0x18,0x14,0x12,0x11},/*K*/{0x10,0x10,0x10,0x10,0x10,0x10,0x1F},/*L*/
 {0x11,0x1B,0x15,0x15,0x11,0x11,0x11},/*M*/{0x11,0x19,0x15,0x13,0x11,0x11,0x11},/*N*/
 {0x0E,0x11,0x11,0x11,0x11,0x11,0x0E},/*O*/{0x1E,0x11,0x11,0x1E,0x10,0x10,0x10},/*P*/
 {0x0E,0x11,0x11,0x11,0x15,0x12,0x0D},/*Q*/{0x1E,0x11,0x11,0x1E,0x14,0x12,0x11},/*R*/
 {0x0F,0x10,0x10,0x0E,0x01,0x01,0x1E},/*S*/{0x1F,0x04,0x04,0x04,0x04,0x04,0x04},/*T*/
 {0x11,0x11,0x11,0x11,0x11,0x11,0x0E},/*U*/{0x11,0x11,0x11,0x11,0x11,0x0A,0x04},/*V*/
 {0x11,0x11,0x11,0x15,0x15,0x1B,0x11},/*W*/{0x11,0x11,0x0A,0x04,0x0A,0x11,0x11},/*X*/
 {0x11,0x11,0x0A,0x04,0x04,0x04,0x04},/*Y*/{0x1F,0x01,0x02,0x04,0x08,0x10,0x1F},/*Z*/
 {0x0E,0x11,0x13,0x15,0x19,0x11,0x0E},/*0*/{0x04,0x0C,0x04,0x04,0x04,0x04,0x0E},/*1*/
 {0x0E,0x11,0x01,0x02,0x04,0x08,0x1F},/*2*/{0x1F,0x02,0x04,0x02,0x01,0x11,0x0E},/*3*/
 {0x02,0x06,0x0A,0x12,0x1F,0x02,0x02},/*4*/{0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E},/*5*/
 {0x06,0x08,0x10,0x1E,0x11,0x11,0x0E},/*6*/{0x1F,0x01,0x02,0x04,0x08,0x08,0x08},/*7*/
 {0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E},/*8*/{0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C},/*9*/
 {0x00,0x04,0x00,0x00,0x04,0x00,0x00},/*:  37*/{0x00,0x00,0x00,0x00,0x00,0x0C,0x0C},/*. 38*/
 {0x00,0x00,0x00,0x00,0x0C,0x04,0x08},/*, 39*/{0x04,0x04,0x04,0x04,0x04,0x00,0x04},/*! 40*/
 {0x0E,0x11,0x01,0x02,0x04,0x00,0x04},/*? 41*/{0x08,0x08,0x10,0x00,0x00,0x00,0x00},/*' 42*/
 {0x00,0x00,0x00,0x1F,0x00,0x00,0x00},/*- 43*/{0x01,0x02,0x04,0x04,0x08,0x10,0x10},/*/ 44*/
 {0x00,0x0A,0x1F,0x0E,0x1F,0x0A,0x00},/*heart-ish 45*/
};
static int fidx(char c){
 if(c>='A'&&c<='Z')return 1+(c-'A'); if(c>='a'&&c<='z')return 1+(c-'a');
 if(c>='0'&&c<='9')return 27+(c-'0');
 switch(c){case ':':return 37;case '.':return 38;case ',':return 39;case '!':return 40;
  case '?':return 41;case '\'':return 42;case '-':return 43;case '/':return 44;default:return 0;}}
/* scaled glyph; sc = pixel size */
static void gch(int x,int y,char c,int sc,uint16_t col){
 const uint8_t*g=F[fidx(c)];
 for(int r=0;r<7;r++)for(int k=0;k<5;k++) if(g[r]&(0x10>>k)) fillr(x+k*sc,y+r*sc,sc,sc,col);}
static void gtext(int x,int y,const char*s,int sc,uint16_t col){
 while(*s){ if(*s==' '){x+=6*sc;s++;continue;} gch(x,y,*s++,sc,col); x+=6*sc; }}
/* text with a 1px (scaled) drop shadow — the classic JRPG look */
static void gtext_sh(int x,int y,const char*s,int sc,uint16_t col,uint16_t sh){
 gtext(x+sc,y+sc,s,sc,sh); gtext(x,y,s,sc,col);}
static void gnum(int x,int y,int v,int dg,int sc,uint16_t col){
 for(int i=dg-1;i>=0;i--){gch(x+i*6*sc,y,(char)('0'+v%10),sc,col);v/=10;}}

/* ── ornate JRPG window: blue gradient fill + double bevel border ───────────── */
static void window(int x,int y,int w,int h){
 /* shadow */ fillr(x+4,y+4,w,h,C(0,0,2));
 /* gradient body (deep navy → royal blue) */
 vgrad(x,y,w,h, 6,10,40, 18,30,90);
 /* outer light border */ rect_outline(x,y,w,h,C(24,28,31));
 /* inner shadow border */ rect_outline(x+1,y+1,w-2,h-2,C(4,8,26));
 rect_outline(x+2,y+2,w-4,h-4,C(14,20,52>>1));
 /* corner accents */
 uint16_t ac=C(28,30,31);
 for(int i=0;i<3;i++){put(x+i,y,ac);put(x,y+i,ac);
  put(x+w-1-i,y,ac);put(x+w-1,y+i,ac);
  put(x+i,y+h-1,ac);put(x,y+h-1-i,ac);
  put(x+w-1-i,y+h-1,ac);put(x+w-1,y+h-1-i,ac);}
}
/* title banner: gold gradient bar */
static void banner(int x,int y,int w,int h,const char*t){
 vgrad(x,y,w,h, 90,60,8, 150,110,24);
 rect_outline(x,y,w,h,C(31,28,12)); rect_outline(x+1,y+1,w-2,h-2,C(14,9,2));
 gtext_sh(x+8,y+(h-10)/2,t,2,C(31,30,18),C(8,5,1));
}
static void hpbar(int x,int y,int w,int v,int max,int r,int g,int b){
 fillr(x,y,w,8,C(3,3,8)); rect_outline(x,y,w,8,C(12,14,22));
 int f=max>0?(w-2)*v/max:0; if(f<0)f=0;
 for(int i=0;i<f;i++){ int yy; for(int dy=0;dy<6;dy++){yy=y+1+dy;
   int sh=dy<2?40:(dy>4?-30:0); put_rgb(x+1+i,yy, r+sh,g+sh,b+sh);} }
}

/* ════════════════ TILES (32x32, textured) ════════════════ */
#define TS 32
static int hsh(int v){v^=v<<13;v^=v>>7;v^=v<<5;return v;}

/* ── value noise: smooth organic variation for painterly terrain ──────────── */
static inline int nhash(int x,int y){
 unsigned h=(unsigned)(x*374761393 + y*668265263); h=(h^(h>>13))*1274126177u; return (h>>16)&0xFF; }
/* bilinear value noise at lattice scale 1<<sh, returns 0..255 */
static int vnoise(int x,int y,int sh){
 int m=(1<<sh)-1, x0=x>>sh, y0=y>>sh, fx=x&m, fy=y&m;
 int n00=nhash(x0,y0),n10=nhash(x0+1,y0),n01=nhash(x0,y0+1),n11=nhash(x0+1,y0+1);
 int a=n00+(((n10-n00)*fx)>>sh), b=n01+(((n11-n01)*fx)>>sh);
 return a+(((b-a)*fy)>>sh); }
static inline int clampc(int v){return v<0?0:(v>255?255:v);}

/* a soft, top-left-lit foliage/rock blob with noisy leaf detail */
static void blob(int cx,int cy,int r,int br,int bg,int bb,int rough){
 for(int dy=-r;dy<=r;dy++){int hf=isqrt(r*r-dy*dy);
  for(int dx=-hf;dx<=hf;dx++){
   int lt=-(dx+dy)*44/r;                       /* directional light */
   int edge=(dx*dx+dy*dy)*36/(r*r);            /* darker rim */
   int n=((((hsh((cx+dx)*131+(cy+dy)*977))>>5)&127)-64)*rough/100;
   put_rgb(cx+dx,cy+dy, clampc(br+lt-edge+n), clampc(bg+lt-edge+n), clampc(bb+lt/2-edge+n));}}}

static void t_grass(int sx,int sy,int wx,int wy){
 for(int y=0;y<TS;y++){int gy=wy+y;
  for(int x=0;x<TS;x++){int gx=wx+x;
   int patch=vnoise(gx,gy,5);                           /* soft meadow patches */
   int blade=(hsh(gx*131+gy*977)>>4)&255;               /* fine blades */
   int r=30 + patch*30/255 + (blade>210?16:0);
   int g=58 + patch*78/255 + (blade>210?34:0) - (blade<40?20:0);
   int b=22 + patch*22/255;
   put_rgb(sx+x,sy+y, r,g,b);}}}
static void t_path(int sx,int sy,int wx,int wy){
 for(int y=0;y<TS;y++){int gy=wy+y;
  for(int x=0;x<TS;x++){int gx=wx+x;
   int n=vnoise(gx,gy,4);
   int st=(hsh(gx*71+gy*37)>>3)&255;
   int r=104+n*46/255, g=80+n*34/255, b=48+n*22/255;
   if(st>214){r+=34;g+=28;b+=20;}                       /* pale pebble */
   else if(st<40){r-=34;g-=28;b-=18;}                   /* rut/shadow */
   put_rgb(sx+x,sy+y, clampc(r),clampc(g),clampc(b));}}}
static void t_water(int sx,int sy,int wx,int wy,int f){
 for(int y=0;y<TS;y++){int gy=wy+y;
  for(int x=0;x<TS;x++){int gx=wx+x;
   int wv=vnoise(gx, gy*2 - f*2, 3);                    /* drifting body */
   int sp=(hsh((gx*2+f)*71+(gy*2)*37)>>3)&255;          /* sparkle field */
   int r=16+wv/12, g=58+wv/4, b=128+wv/5;
   if(sp>236){r+=120;g+=120;b+=90;}                     /* sun specular */
   else if(sp>210){r+=40;g+=50;b+=40;}                  /* ripple crest */
   put_rgb(sx+x,sy+y, clampc(r),clampc(g),clampc(b));}}
 (void)wy;}
static void ground_shadow(int cx,int cy,int rw,int rh){
 for(int dy=-rh;dy<=rh;dy++){int hf=rw-(dy<0?-dy:dy)*rw/rh; int y=cy+dy;
  for(int dx=-hf;dx<=hf;dx++){int x=cx+dx; if((unsigned)x<W&&(unsigned)y<H){
   uint16_t*p=&fb[y*stride_px+x]; *p=C(((*p>>11)&31)*3/5,((*p>>6)&31)*3/5,((*p>>1)&31)*3/5);}}}}
static void t_tree(int sx,int sy,int wx,int wy){
 t_grass(sx,sy,wx,wy);
 ground_shadow(sx+18,sy+28,12,5);
 /* trunk with bark shading */
 for(int y=18;y<31;y++)for(int x=13;x<19;x++){
   int sh=(x-13)*8-12; int n=(vnoise((sx+x)*2,(sy+y),1)-128)/8;
   put_rgb(sx+x,sy+y, clampc(78+sh+n),clampc(48+sh+n),clampc(24+sh/2+n));}
 /* layered volumetric canopy (dark base → lit clumps) */
 blob(sx+16,sy+15,15, 26,72,30, 60);
 blob(sx+14,sy+12,11, 40,104,44, 70);
 blob(sx+12,sy+10,7,  64,140,66, 80);
 blob(sx+11,sy+9,4,   96,176,90, 80);
}
static void t_wall(int sx,int sy){
 /* plastered stone with beveled blocks */
 for(int y=0;y<TS;y++)for(int x=0;x<TS;x++){
  int n=vnoise(sx+x,sy+y,3);
  int r=150+n*30/255-15, g=128+n*26/255-13, b=92+n*20/255-10;
  int by=y&15, bx=(x + (y/16)*8)&15;                   /* offset courses */
  if(by==0||by==15){r-=46;g-=40;b-=30;}                /* mortar */
  else if(by==1){r+=26;g+=22;b+=16;}                   /* top bevel light */
  else if(by==14){r-=26;g-=22;b-=16;}                  /* bottom bevel dark */
  if(bx==0){r-=40;g-=34;b-=26;} else if(bx==1){r+=22;g+=18;b+=12;}
  put_rgb(sx+x,sy+y, clampc(r),clampc(g),clampc(b));}}
static void t_roof(int sx,int sy){
 for(int y=0;y<TS;y++)for(int x=0;x<TS;x++){
  int row=y/8, ph=y%8;
  int ofx=(x + row*8)%16;                              /* staggered tiles */
  int n=vnoise(sx+x,sy+y,2);
  int r=150+n*40/255, g=44+n*20/255, b=38+n*16/255;
  if(ph==0){r+=44;g+=24;b+=20;}                        /* tile lip highlight */
  else if(ph>=6){r-=50;g-=22;b-=18;}                   /* shadow under lip */
  if(ofx==0||ofx==15){r-=30;g-=14;b-=12;}              /* tile seam */
  put_rgb(sx+x,sy+y, clampc(r),clampc(g),clampc(b));}}
static void t_door(int sx,int sy){
 t_wall(sx,sy);
 /* stone arch frame */ for(int i=0;i<7;i++){put(sx+6+i,sy+4,C(20,16,11));put(sx+25-i,sy+4,C(20,16,11));}
 for(int y=5;y<32;y++){int x0=sx+6,x1=sx+25; put(x0,y,C(8,6,4));put(x1,y,C(8,6,4));}
 /* planked wood door with grain + iron bands */
 for(int y=6;y<32;y++)for(int x=8;x<24;x++){
   int n=(vnoise((sx+x)*3,(sy+y),1)-128)/6;
   int pl=((x-8)/5); int sh=(pl&1)?-10:6;
   put_rgb(sx+x,sy+y, clampc(86+sh+n),clampc(54+sh+n),clampc(26+sh/2+n));
   if((x-8)%5==4) put(sx+x,sy+y,C(5,3,2)); }
 hbar(sx+8,sx+23,sy+12,C(7,5,3)); hbar(sx+8,sx+23,sy+25,C(7,5,3)); /* iron bands */
 disc(sx+21,sy+19,1,C(28,24,8)); put(sx+21,sy+19,C(31,28,12)); }
static void t_flower(int sx,int sy,int wx,int wy){
 t_grass(sx,sy,wx,wy);
 int n=hsh(wx*5+wy*9);
 for(int i=0;i<4;i++){int cx=sx+6+((n>>(i*3))&18), cy=sy+6+((n>>(i*3+2))&18);
   uint16_t pc=(i&1)?C(31,26,10):((i&2)?C(31,12,18):C(22,14,31));
   put(cx,cy-2,pc);put(cx,cy+2,pc);put(cx-2,cy,pc);put(cx+2,cy,pc);
   put(cx-1,cy-1,pc);put(cx+1,cy+1,pc); put(cx,cy,C(31,29,18));}}
static void t_fence(int sx,int sy,int wx,int wy){
 t_grass(sx,sy,wx,wy);
 for(int y=12;y<17;y++)for(int x=0;x<TS;x++){int n=(vnoise((sx+x)*2,sy+y,1)-128)/8;
   int sh=(y==12)?20:(y>=16?-18:0); put_rgb(sx+x,sy+y,clampc(110+sh+n),clampc(78+sh+n),clampc(42+sh+n));}
 for(int x=6;x<TS;x+=16)for(int y=6;y<26;y++){int n=(vnoise(sx+x,sy+y,1)-128)/8;
   int sh=(y<8)?18:0; put_rgb(sx+x,sy+y,clampc(98+sh+n),clampc(66+sh+n),clampc(34+n));
   put_rgb(sx+x+3,sy+y,clampc(60+n),clampc(40+n),clampc(20+n));}}
static const uint8_t MAP[15][20]={
 {3,3,3,0,0,7,0,0,0,0,0,0,7,0,0,0,3,3,3,3},
 {3,0,0,0,5,5,5,5,0,0,0,0,5,5,5,5,0,0,0,3},
 {3,0,7,0,5,4,4,5,0,1,1,0,5,4,4,5,0,7,0,3},
 {3,0,0,0,4,4,6,4,0,1,1,0,4,4,6,4,0,0,0,0},
 {0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0},
 {0,1,0,0,7,0,0,0,1,0,0,0,7,0,0,0,0,1,0,3},
 {3,1,0,2,2,2,2,0,1,0,0,0,0,0,7,0,0,1,0,3},
 {3,1,0,2,2,2,2,0,1,1,1,1,1,1,1,1,1,1,0,3},
 {3,1,0,2,2,2,2,0,1,0,0,0,0,0,0,0,7,1,0,3},
 {3,1,0,0,0,0,0,0,1,0,5,5,5,5,0,0,0,1,0,0},
 {0,1,1,1,1,1,1,1,1,0,5,4,4,5,0,7,0,1,0,0},
 {3,0,7,0,0,0,0,0,0,0,4,4,6,4,0,0,0,1,0,3},
 {3,0,0,8,8,8,8,8,8,0,0,0,0,0,0,7,0,1,0,3},
 {3,3,0,0,7,0,0,0,0,0,7,0,0,3,0,0,0,0,0,3},
 {3,3,3,3,0,0,0,3,3,3,3,3,0,0,0,3,3,3,3,3},
};
static void draw_tile(int sx,int sy,int wx,int wy,uint8_t t,int f){
 switch(t){
  case 0: t_grass(sx,sy,wx,wy); break;
  case 1: t_path(sx,sy,wx,wy); break;
  case 2: t_water(sx,sy,wx,wy,f); break;
  case 3: t_tree(sx,sy,wx,wy); break;
  case 4: t_wall(sx,sy); break;
  case 5: t_roof(sx,sy); break;
  case 6: t_door(sx,sy); break;
  case 7: t_flower(sx,sy,wx,wy); break;
  case 8: t_fence(sx,sy,wx,wy); break;
 }
}
static void draw_map(int f){
 for(int ty=0;ty<15;ty++)for(int tx=0;tx<20;tx++)
   draw_tile(tx*TS,ty*TS,tx*TS,ty*TS,MAP[ty][tx],f);
}

/* ════════════════ SPRITES (outlined, shaded) ════════════════ */
static void shadow(int cx,int cy,int rw){ for(int dy=-3;dy<=3;dy++){int hf=rw-(dy<0?-dy:dy);
 for(int dx=-hf;dx<=hf;dx++){int x=cx+dx,y=cy+dy; if((unsigned)x<W&&(unsigned)y<H){
   uint16_t*p=&fb[y*stride_px+x]; *p=C(((*p>>11)&31)/2,((*p>>6)&31)/2,((*p>>1)&31)/2);}}}}

/* hero: ~22x36, dir 0=down 1=up 2=left 3=right, step toggles legs */
static void hero(int cx,int cy,int dir,int step){
 uint16_t OL=C(2,2,5), skin=C(30,23,17),skinS=C(24,17,12),hair=C(20,11,4),hairH=C(27,17,7),
  tunic=C(8,15,28),tunicH=C(13,21,31),tunicS=C(5,10,20),belt=C(20,14,5),
  boot=C(12,8,4),blade=C(27,29,31),hilt=C(26,20,6);
 shadow(cx,cy+18,10);
 int lo=step?2:-2;
 /* legs */
 fillr(cx-6,cy+8,5,12,boot); fillr(cx+2,cy+8,5,12,boot);
 rect_outline(cx-6,cy+8,5,12,OL); rect_outline(cx+2,cy+8,5,12,OL);
 fillr(cx-6,cy+18+ (lo>0?0:lo),5,3,boot); fillr(cx+2,cy+18+(lo>0?lo:0),5,3,boot);
 /* body */
 fillr(cx-8,cy-6,17,16,tunic);
 fillr(cx-8,cy-6,5,16,tunicH);            /* lit left */
 fillr(cx+5,cy-6,4,16,tunicS);            /* shaded right */
 fillr(cx-8,cy+5,17,3,belt);
 rect_outline(cx-8,cy-6,17,16,OL);
 /* arms */
 fillr(cx-10,cy-4,3,10,skin); fillr(cx+9,cy-4,3,10,skin);
 rect_outline(cx-10,cy-4,3,10,OL); rect_outline(cx+9,cy-4,3,10,OL);
 /* head */
 disc(cx,cy-13,8,OL); disc(cx,cy-13,7,skin);
 fillr(cx+3,cy-16,4,8,skinS);
 /* hair */
 fillr(cx-7,cy-21,15,6,hair); disc(cx,cy-19,7,hair);
 fillr(cx-7,cy-21,5,4,hairH);
 if(dir==1){ disc(cx,cy-15,7,hair); }                 /* back of head */
 else {
   uint16_t eye=C(2,4,12);
   if(dir==0){put(cx-3,cy-13,eye);put(cx-2,cy-13,eye);put(cx+2,cy-13,eye);put(cx+3,cy-13,eye);
     put(cx-2,cy-9,skinS);put(cx+2,cy-9,skinS);}
   if(dir==2){put(cx-4,cy-13,eye);put(cx-3,cy-13,eye);}
   if(dir==3){put(cx+3,cy-13,eye);put(cx+4,cy-13,eye);}
 }
 /* sword */
 if(dir==3){ fillr(cx+12,cy-12,3,16,blade); rect_outline(cx+12,cy-12,3,16,OL);
   fillr(cx+10,cy+3,7,3,hilt); put(cx+13,cy-13,C(31,31,31)); }
 else if(dir==2){ fillr(cx-14,cy-12,3,16,blade); rect_outline(cx-14,cy-12,3,16,OL);
   fillr(cx-16,cy+3,7,3,hilt); put(cx-13,cy-13,C(31,31,31)); }
}
/* generic NPC */
static void npc(int cx,int cy,uint16_t robe,uint16_t robeH,uint16_t hairc){
 uint16_t OL=C(2,2,5),skin=C(30,23,17);
 shadow(cx,cy+18,10);
 fillr(cx-8,cy-6,17,22,robe); fillr(cx-8,cy-6,5,22,robeH);
 rect_outline(cx-8,cy-6,17,22,OL);
 fillr(cx-10,cy-2,3,9,skin); fillr(cx+9,cy-2,3,9,skin);
 disc(cx,cy-13,8,OL); disc(cx,cy-13,7,skin);
 fillr(cx-7,cy-21,15,6,hairc); disc(cx,cy-19,7,hairc);
 put(cx-3,cy-13,C(2,4,12));put(cx-2,cy-13,C(2,4,12));
 put(cx+2,cy-13,C(2,4,12));put(cx+3,cy-13,C(2,4,12));
}
static void slime(int cx,int cy,int f){
 int sq=isqrt((f*4)&31)-2; uint16_t OL=C(1,5,2);
 shadow(cx,cy+10,11);
 disc(cx,cy+2-sq,13+sq,OL); disc(cx,cy+2-sq,12+sq,C(8,26,12));
 disc(cx,cy-2,8,C(14,31,18));                /* highlight */
 disc(cx-4,cy-5,3,C(22,31,26));
 put(cx-4,cy,C(2,2,4));put(cx-3,cy,C(2,2,4));put(cx+3,cy,C(2,2,4));put(cx+4,cy,C(2,2,4));
 put(cx-4,cy+1,C(31,31,31));put(cx+4,cy+1,C(31,31,31));
}
static void goblin(int cx,int cy){
 uint16_t OL=C(1,4,1),body=C(9,16,6),bodyH=C(13,22,9),skin=C(11,18,7);
 shadow(cx,cy+16,11);
 fillr(cx-9,cy-2,19,18,body); fillr(cx-9,cy-2,5,18,bodyH);
 rect_outline(cx-9,cy-2,19,18,OL);
 disc(cx,cy-11,8,OL); disc(cx,cy-11,7,skin);
 fillr(cx-11,cy-15,3,5,skin); fillr(cx+9,cy-15,3,5,skin); /* ears */
 put(cx-3,cy-11,C(31,6,2));put(cx-2,cy-11,C(31,6,2));put(cx+2,cy-11,C(31,6,2));put(cx+3,cy-11,C(31,6,2));
 fillr(cx-3,cy-7,7,2,C(22,18,4));            /* fang grin */
 fillr(cx+11,cy-8,4,20,C(16,12,6)); rect_outline(cx+11,cy-8,4,20,OL); /* club */
 disc(cx+13,cy-9,4,C(14,10,5));
}
static void warden(int cx,int cy,int f){
 uint16_t OL=C(1,4,1);
 shadow(cx,cy+34,32);
 fillr(cx-30,cy-18,61,56,C(7,12,5));         /* trunk body */
 for(int i=-30;i<31;i+=5) fillr(cx+i,cy-18,3,56,C(4,9,3));
 rect_outline(cx-30,cy-18,61,56,OL);
 /* roots/arms */ fillr(cx-46,cy-6,16,7,C(6,11,4)); fillr(cx+30,cy-6,16,7,C(6,11,4));
 /* canopy crown — volumetric lit foliage */
 disc(cx,cy-30,31,OL);
 blob(cx,cy-30,29, 22,60,28, 55);
 blob(cx-18,cy-24,17, 34,92,40, 70); blob(cx+16,cy-26,15, 30,84,36, 70);
 blob(cx-8,cy-38,13, 56,128,60, 80); blob(cx+12,cy-34,10, 48,116,52, 80);
 /* glowing eyes + maw */
 int gl=18+isqrt((f*3)&63); if(gl>31)gl=31;
 disc(cx-12,cy-2,5,C(31,gl,2)); disc(cx-12,cy-2,2,C(31,31,20));
 disc(cx+12,cy-2,5,C(31,gl,2)); disc(cx+12,cy-2,2,C(31,31,20));
 fillr(cx-14,cy+14,29,4,C(20,4,2));
 for(int x=-14;x<15;x+=4){put(cx+x,cy+14,C(28,10,4));}
}

/* ════════════════ SCENES ════════════════ */
static void scene_title(int f){
 vgrad(0,0,W,300, 8,8,34, 26,20,58);          /* dusk sky */
 for(int i=0;i<90;i++){int n=hsh(i*257); int x=((n&1023)+f/4)%W, y=(n>>10)&255;
   if(y<260) put_rgb(x,y, 180+((n>>4)&60),180+((n>>2)&60),200);}
 /* moon */ disc(540,80,34,C(30,30,26)); disc(528,72,30,C(26,27,22)); disc(548,90,8,C(22,23,20));
 /* hills */
 for(int x=0;x<W;x++){int hh=300+ (isqrt((x*3)&255)) - (x/20%7); for(int y=hh;y<340;y++)put_rgb(x,y,16,40,22);}
 vgrad(0,330,W,40, 14,46,24, 22,70,32);
 /* castle */
 fillr(250,250,140,80,C(7,7,16)); rect_outline(250,250,140,80,C(11,11,22));
 fillr(270,224,18,28,C(9,9,18)); fillr(352,224,18,28,C(9,9,18)); fillr(305,210,30,42,C(9,9,18));
 for(int i=0;i<3;i++){int wx=276+i*40; put_rgb(wx,300,((f>>3)&1)?255:120,((f>>3)&1)?210:90,40);
   fillr(wx-1,298,3,5,((f>>4)&1)?C(31,26,8):C(16,12,4));}
 /* meadow + characters */
 vgrad(0,360,W,120, 22,72,32, 12,52,22);
 for(int i=0;i<60;i++){int n=hsh(i*97); put_rgb((n&1023)%W,360+((n>>10)&119),20,90,36);}
 hero(150,400,3,(f>>3)&1);
 npc(470,402,C(22,6,8),C(28,10,12),C(7,5,3));
 /* logo */
 gtext_sh(120,90,"RIVERDALE",6,C(31,26,8),C(8,4,1));
 gtext_sh(232,160,"SAGA",6,C(31,18,6),C(8,3,1));
 fillr(118,150,232,3,C(20,14,4));
 gtext(196,210,"AN EPIC N64 RPG",2,C(20,24,30));
 if((f/20)%2==0){ window(238,300,164,34); gtext(258,310,"PRESS START",2,C(31,31,22)); }
 gtext(150,452,"BUILT WITH PAKSTUDIO",2,C(16,18,14));
}

static void hud_top(){
 window(8,8,210,64);
 gtext(20,16,"ARIA",2,C(31,30,20));
 gtext(20,36,"HP",1,C(18,28,31)); hpbar(40,34,150,28,32,30,210,60);
 gtext(20,52,"MP",1,C(18,28,31)); hpbar(40,50,150,9,12,40,120,240);
 window(W-180,8,172,30);
 gtext(W-168,16,"GOLD",2,C(31,26,8)); gnum(W-78,16,150,4,2,C(31,31,31));
}
static void scene_overworld(int f){
 draw_map(f);
 npc(4*TS+16,2*TS+16,C(22,8,26),C(28,12,31),C(7,5,3));     /* elder */
 npc(12*TS+16,10*TS+12,C(8,20,12),C(13,27,17),C(20,13,5)); /* shopkeep */
 int hx=2*TS+16+((f/2)%(9*TS));
 hero(hx,4*TS+12,3,(f>>3)&1);
 /* quest marker */
 int by=2*TS-2+ (isqrt((f*3)&31));
 gch(4*TS+12,by-12,'!',3,C(31,28,8)); gch(4*TS+13,by-11,'!',3,C(20,14,2));
 hud_top();
 window(150,446,340,28); gtext(166,453,"WHISPERING WOODS  -  NORTH GATE",2,C(20,24,31));
}

static void scene_dialogue(int f){
 scene_overworld(0);
 for(int y=300;y<H;y++)for(int x=0;x<W;x++) if(((x+y)&1)==0){uint16_t*p=&fb[y*stride_px+x];
   *p=C(((*p>>11)&31)/3,((*p>>6)&31)/3,((*p>>1)&31)/3+1);}
 window(16,300,140,150);                        /* portrait */
 fillr(28,316,116,116,C(14,8,18)); rect_outline(28,316,116,116,C(20,14,26));
 npc(86,400,C(22,8,26),C(28,12,31),C(7,5,3));
 window(170,300,454,150);                       /* text box */
 banner(184,294,170,26,"ELDER MIRA");
 gtext(190,338,"MY FAMILY'S HEIRLOOM IS LOST IN",2,C(28,30,31));
 gtext(190,360,"THE WHISPERING WOODS. WILL YOU",2,C(28,30,31));
 gtext(190,382,"HELP AN OLD WOMAN, BRAVE ONE?",2,C(28,30,31));
 int sel=(f/24)%2;
 gch(196,412,sel==0?'>':' ',2,C(31,28,8)); gtext(214,412,"I WILL FIND IT",2,sel==0?C(31,31,22):C(16,18,24));
 gch(430,412,sel==1?'>':' ',2,C(31,28,8)); gtext(448,412,"NOT NOW",2,sel==1?C(31,31,22):C(16,18,24));
}

static const char*INV[]={"POTION","ETHER","HERB","IRON ORE","BRONZE SWORD","TOWN KEY"};
static const int IQ[]={5,2,8,3,1,1};
static void scene_menu(int f){
 vgrad(0,0,W,H, 3,4,16, 8,8,30);
 window(16,16,300,300);
 gtext_sh(32,28,"PARTY",2,C(31,30,20),C(6,5,1));
 fillr(28,52,276,2,C(16,20,40));
 /* Aria */
 window(28,62,276,100); npc(64,118,C(8,15,28),C(13,21,31),C(20,11,4));
 gtext(98,72,"ARIA",2,C(31,31,31)); gtext(230,72,"LV 4",2,C(20,28,31));
 gtext(98,92,"KNIGHT",1,C(18,20,26));
 gtext(98,108,"HP",1,C(18,28,31)); hpbar(122,106,150,28,32,30,210,60); gnum(280,106,28,2,1,C(20,28,31));
 gtext(98,126,"MP",1,C(18,28,31)); hpbar(122,124,150,9,12,40,120,240); gnum(280,124,9,2,1,C(20,28,31));
 /* Loras */
 window(28,170,276,100); npc(64,226,C(18,8,26),C(26,12,31),C(8,6,3));
 gtext(98,180,"LORAS",2,C(31,31,31)); gtext(230,180,"LV 3",2,C(20,28,31));
 gtext(98,200,"MAGE",1,C(18,20,26));
 gtext(98,216,"HP",1,C(18,28,31)); hpbar(122,214,150,18,24,30,210,60); gnum(280,214,18,2,1,C(20,28,31));
 gtext(98,234,"MP",1,C(18,28,31)); hpbar(122,232,150,22,24,40,120,240); gnum(280,232,22,2,1,C(20,28,31));
 gtext(32,284,"GOLD",2,C(31,26,8)); gnum(110,284,150,4,2,C(31,31,31));
 /* items */
 window(332,16,292,300);
 gtext_sh(348,28,"ITEMS",2,C(31,30,20),C(6,5,1));
 fillr(344,52,268,2,C(16,20,40));
 int sel=(f/18)%6;
 for(int i=0;i<6;i++){int yy=62+i*38;
   if(i==sel){ vgrad(344,yy-4,268,34, 20,30,70, 12,18,46); rect_outline(344,yy-4,268,34,C(24,30,31));
     gch(350,yy+4,'>',2,C(31,28,8)); }
   gtext(372,yy+4,INV[i],2,i==sel?C(31,31,31):C(20,22,28));
   gch(560,yy+4,':',2,C(16,18,24)); gnum(574,yy+4,IQ[i],2,2,C(31,26,8)); }
 (void)f;
}

static void scene_quests(int f){
 vgrad(0,0,W,H, 3,4,16, 8,8,30);
 window(16,16,608,448);
 gtext_sh(36,30,"QUEST LOG",3,C(31,30,20),C(6,5,1));
 fillr(32,72,576,2,C(16,20,40));
 window(32,86,576,150);
 gch(46,98,'!',2,C(31,28,8)); gtext_sh(70,98,"THE MISSING HEIRLOOM",2,C(31,31,31),C(4,4,8));
 gtext(70,122,"ELDER MIRA LOST HER LOCKET.",2,C(18,20,28));
 gtext(60,150,"DONE  SPEAK WITH ELDER MIRA",2,C(20,30,20));
 gch(62,172,'>',2,C(31,28,8)); gtext(86,172,"FIND THE HEIRLOOM IN THE WOODS",2,C(31,30,16));
 gtext(86,194,"RETURN THE HEIRLOOM TO MIRA",2,C(13,15,22));
 banner(432,98,150,24,"REWARD");
 gtext(444,130,"150 GOLD",2,C(31,31,31)); gtext(444,152,"IRON SWORD",2,C(20,28,31));
 window(32,250,576,96);
 gch(46,262,'!',2,C(31,22,8)); gtext_sh(70,262,"SLIME CLEANUP",2,C(31,31,31),C(4,4,8));
 gtext(70,286,"CLEAR THE SLIMES NEAR THE WELL.",2,C(18,20,28));
 gtext(70,312,"DEFEAT SLIMES",2,C(31,30,16)); gtext(330,312,"3 / 5",2,C(31,31,31));
 hpbar(420,314,150,3,5,40,210,80);
 gtext(36,362,"COMPLETED",2,C(16,18,24));
 gtext(60,386,"WELCOME TO RIVERDALE",2,C(16,28,18));
 gtext(60,408,"A GIFT FOR BRAM",2,C(16,28,18));
 (void)f;
}

static const char*SH[]={"POTION","ETHER","HERB","BRONZE SWORD","LEATHER ARMOR"};
static const int SP[]={25,60,5,80,70};
static void scene_shop(int f){
 vgrad(0,0,W,H, 5,7,18, 11,13,32);            /* the windows cover the rest */
 window(16,16,608,280);
 banner(28,10,200,26,"GENERAL STORE");
 gtext(440,22,"GOLD",2,C(31,26,8)); gnum(530,22,150,4,2,C(31,31,31));
 fillr(32,56,576,2,C(16,20,40));
 int sel=(f/20)%5;
 for(int i=0;i<5;i++){int yy=70+i*42;
   if(i==sel){ vgrad(32,yy-6,576,38, 20,30,70, 12,18,46); rect_outline(32,yy-6,576,38,C(24,30,31));
     gch(40,yy+2,'>',2,C(31,28,8)); }
   gtext(64,yy+2,SH[i],2,i==sel?C(31,31,31):C(20,22,28));
   gtext(430,yy+2,"PRICE",2,C(16,18,24)); gnum(520,yy+2,SP[i],4,2,C(31,26,8)); }
 window(16,310,608,154);
 fillr(32,326,116,116,C(14,18,14)); rect_outline(32,326,116,116,C(20,26,20));
 npc(90,408,C(8,20,12),C(13,27,17),C(20,13,5));
 banner(166,320,90,24,"BRAM");
 gtext(166,358,"\"A POTION HEALS 30 HP -",2,C(26,28,31));
 gtext(166,380,"CAN'T ADVENTURE WITHOUT ONE!\"",2,C(26,28,31));
 gtext(166,420,"BUY      SELL      LEAVE",2,C(18,20,26));
 (void)f;
}

static void scene_craft(int f){
 vgrad(0,0,W,H, 16,8,6, 6,3,2);
 window(16,16,608,448);
 gtext_sh(36,30,"FORGE",3,C(31,24,8),C(6,3,1));
 gtext(320,40,"CRAFTING BENCH",2,C(20,18,14));
 fillr(32,72,576,2,C(40,28,16));
 gtext(40,86,"RECIPES",2,C(31,26,8));
 const char*rec[]={"BREW POTION","FORGE IRON SWORD"}; int sel=(f/24)%2;
 for(int i=0;i<2;i++){int yy=112+i*34;
   if(i==sel){ vgrad(36,yy-6,260,30, 60,30,18, 36,18,10); rect_outline(36,yy-6,260,30,C(31,24,12));
     gch(44,yy,'>',2,C(31,28,8)); }
   gtext(68,yy,rec[i],2,i==sel?C(31,31,31):C(22,20,16)); }
 fillr(320,86,2,300,C(40,28,16));
 gtext(344,96,"FORGE IRON SWORD",2,C(31,31,31));
 gtext(344,128,"REQUIRES",2,C(31,26,8));
 gtext(364,154,"IRON ORE",2,C(20,22,28));    gtext(560,154,"3",2,C(20,30,20));
 gtext(364,176,"BRONZE SWORD",2,C(20,22,28)); gtext(560,176,"1",2,C(20,30,20));
 gtext(344,212,"PRODUCES",2,C(31,26,8));
 /* sword icon */
 fillr(360,238,6,40,C(27,29,31)); fillr(356,236,14,4,C(31,31,28)); fillr(350,278,26,6,C(18,13,6));
 gtext(390,246,"IRON SWORD",2,C(31,31,31)); gtext(390,268,"ATK +9",2,C(20,28,31));
 if((f/16)%2==0){ vgrad(360,320,220,40, 16,46,16, 8,30,8); rect_outline(360,320,220,40,C(20,31,20));
   gtext(384,332,"CRAFT  -  READY",2,C(31,31,31)); }
 else { rect_outline(360,320,220,40,C(14,20,14)); gtext(384,332,"CRAFT  -  READY",2,C(18,24,18)); }
 /* anvil */
 fillr(80,360,160,18,C(11,11,15)); fillr(120,378,80,56,C(8,8,12)); fillr(64,356,200,8,C(15,15,20));
 int sp=(f>>2)&3; if(sp<2){disc(160,352,3+sp*2,C(31,26,8)); disc(160,352,1,C(31,31,22));}
}

static void woods(int f){
 /* dappled forest floor */
 for(int y=0;y<H;y++)for(int x=0;x<W;x++){
   int p=vnoise(x,y,5);
   int r=16+p*22/255, g=40+p*52/255, b=18+p*16/255;
   put_rgb(x,y, r,g,b);}
 /* winding river with banks + specular */
 for(int y=0;y<H;y++){int rx=150 + (vnoise(0,y,5)-128)*40/128 - y/14;
  for(int k=0;k<22;k++){int x=rx+k; int sp=(hsh((x*2+f)*71+(y*2)*37)>>3)&255;
   int r=16,g=58,b=132; if(sp>232){r+=120;g+=120;b+=90;} else if(sp>204){r+=36;g+=46;b+=36;}
   put_rgb(x,y,clampc(r),clampc(g),clampc(b));}
  put_rgb(rx-1,y,30,52,28); put_rgb(rx+22,y,30,52,28);}
 /* shaded canopy trees */
 for(int i=0;i<15;i++){int n=hsh(i*151); int tx=(n&1023)%W, ty=40+((n>>10)&400);
   ground_shadow(tx+6,ty+24,20,7);
   for(int y=22;y<34;y++)for(int x=-3;x<3;x++){int sh=x*7; put_rgb(tx+x+1,ty+y,clampc(70+sh),clampc(44+sh),clampc(22+sh/2));}
   blob(tx,ty,21, 22,64,28, 60); blob(tx-3,ty-6,15, 36,98,42, 70); blob(tx-7,ty-11,8, 60,136,64, 80);}
 (void)f;
}
static void scene_action(int f){
 woods(f);
 int hx=300,hy=270;
 int sw=f%40;
 if(sw<12){ for(int a=-12;a<=12;a++){int ax=hx+22+a, ay=hy-12+(a*a)/14;
   put(ax,ay,C(28,30,31)); put(ax,ay+1,C(18,24,31)); put(ax,ay-1,C(31,31,31));}
   disc(hx+30,hy-4,5,C(31,30,18)); disc(hx+30,hy-4,2,C(31,31,31)); }
 hero(hx,hy,3,(f>>3)&1);
 slime(450,180,f);   hpbar(420,150,70,8,14,255,40,40);
 slime(510,300,f+8); hpbar(480,270,70,14,14,255,40,40);
 goblin(500,236);    hpbar(470,200,70,18,26,255,40,40);
 if((f%40)<20) gtext_sh(404,140-(f%40),"12",3,C(31,28,8),C(8,4,1));
 if(sw<10){disc(424,160,4+sw,C(31,24,6)); disc(424,160,2,C(31,31,31));}
 int px=500-((f*4)%160); disc(px,236,4,C(31,12,4)); disc(px,236,2,C(31,28,16));
 window(8,8,250,52); gtext(20,16,"ARIA",2,C(31,30,20));
 gtext(20,38,"HP",1,C(18,28,31)); hpbar(44,36,200,28,32,30,210,60);
 window(W-220,8,212,28); gtext(W-208,16,"WHISPERING WOODS",2,C(18,24,20));
 window(W-150,430,142,42); gtext(W-138,438,"A  ATTACK",2,C(20,24,30));
 gtext(W-138,456,"B  MAGIC",2,C(20,24,30));
}

static void scene_battle(int f){
 vgrad(0,0,W,H, 12,4,22, 3,1,8);
 for(int i=0;i<60;i++){int n=hsh(i*193); int x=((n&1023)+f)%W; put_rgb(x,(n>>10)&300,90,70,140);}
 disc(320,150,160,C(5,2,12)); disc(320,150,90,C(8,3,18)); /* arena glow */
 goblin(220,150);  hpbar(180,108,90,26,30,255,40,40); gtext(180,92,"GOBLIN",1,C(28,18,18));
 goblin(390,170);  hpbar(350,128,90,18,30,255,40,40);
 slime(500,150,f); hpbar(466,110,70,14,14,255,40,40);
 hero(150,320,1,0);
 npc(230,332,C(18,8,26),C(26,12,31),C(8,6,3));
 if((f>>3)&1) gch(132,272,'!',3,C(31,28,8));
 window(8,376,300,96);
 const char*cmd[]={"FIGHT","SKILL","ITEM","RUN"}; int sel=(f/16)%4;
 for(int i=0;i<4;i++){int cx=24+(i%2)*150, cy=392+(i/2)*40;
   if(i==sel){ vgrad(cx-8,cy-6,140,30, 20,30,70, 12,18,46); rect_outline(cx-8,cy-6,140,30,C(24,30,31));
     gch(cx,cy,'>',2,C(31,28,8)); }
   gtext(cx+22,cy,cmd[i],2,i==sel?C(31,31,22):C(20,22,28)); }
 window(320,376,312,96);
 gtext(336,386,"ARIA",2,C(31,31,31));  gtext(540,386,"TURN 3",2,C(31,26,8));
 gtext(336,406,"HP",1,C(18,28,31)); hpbar(360,404,150,26,32,30,210,60); gnum(520,404,26,2,2,C(20,28,31));
 gtext(336,422,"MP",1,C(18,28,31)); hpbar(360,420,150,9,12,40,120,240); gnum(520,420,9,2,2,C(20,28,31));
 gtext(336,442,"LORAS",2,C(31,31,31));
 gtext(336,460,"HP",1,C(18,28,31)); hpbar(360,458,150,18,24,30,210,60); gnum(520,458,18,2,2,C(20,28,31));
 window(8,344,624,28);
 gtext(20,351,"ARIA ATTACKS!  GOBLIN TAKES 14 DAMAGE!",2,C(28,30,31));
}

static void scene_boss(int f){
 woods(f);
 for(int y=0;y<H;y++)for(int x=0;x<W;x++) if(((x*3+y)&7)==0){uint16_t*p=&fb[y*stride_px+x];
   *p=C(((*p>>11)&31)*3/4,((*p>>6)&31)*3/4,((*p>>1)&31)*3/4);}
 warden(320,200,f);
 window(70,16,500,40);
 gtext_sh(82,24,"FOREST WARDEN",2,C(31,8,8),C(8,1,1));
 hpbar(250,26,300,84,120,((f>>3)&1)?255:200,20,20);
 hero(180,410,1,(f>>3)&1);
 npc(300,420,C(18,8,26),C(26,12,31),C(8,6,3));
 int fx=300+((f*5)%160), fy=420-((f*5)%220);
 disc(fx,fy,7,C(31,18,2)); disc(fx,fy,4,C(31,31,20));
 for(int t=1;t<5;t++) disc(fx-t*7,fy+t*9,6-t,C(31,10,2));
 for(int i=0;i<7;i++){int tx=120+i*70,ty=(f*3+i*50)%300+50;
   fillr(tx,ty,3,10,C(14,20,8)); disc(tx+1,ty+11,2,C(20,28,10));}
 if((f%30)<10){disc(300,200,6+(f%30),C(31,24,6)); disc(300,200,2,C(31,31,31));}
 window(150,440,340,30); gtext(166,447,"GIVE IT EVERYTHING YOU HAVE!",2,C(28,22,22));
}

int main(void){
 display_init(1,2,2,0,1);   /* 640x480, 16bpp, double-buffer */
 int f=0;
 for(;;){
   surface_t*d=display_get();
   fb=(uint16_t*)d->buffer; stride_px=(int)(d->stride/2);
#ifdef FORCE_SCENE
   int scene=FORCE_SCENE;
#else
   int scene=(f/110)%10;
#endif
   switch(scene){
     case 0: scene_title(f); break;
     case 1: scene_overworld(f); break;
     case 2: scene_dialogue(f); break;
     case 3: scene_menu(f); break;
     case 4: scene_quests(f); break;
     case 5: scene_shop(f); break;
     case 6: scene_craft(f); break;
     case 7: scene_action(f); break;
     case 8: scene_battle(f); break;
     default: scene_boss(f); break;
   }
   display_show(d);
   f++;
 }
 return 0;
}
