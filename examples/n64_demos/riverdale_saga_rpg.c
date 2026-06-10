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
static const int8_t SIN64[64]={0,3,6,9,12,15,17,20,22,24,26,27,29,30,30,31,
 31,31,30,30,29,27,26,24,22,20,17,15,12,9,6,3,0,-3,-6,-9,-12,-15,-17,-20,-22,
 -24,-26,-27,-29,-30,-30,-31,-31,-31,-30,-30,-29,-27,-26,-24,-22,-20,-17,-15,-12,-9,-6,-3};
static inline int isin(int a){return SIN64[a&63];}
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

/* ── handcrafted pixel-art system: indexed palette + blitter ────────────────
 * Tiles and sprites are authored as rows of characters; each char maps to a
 * colour via pal(). ' ' and '.' are transparent. Art is 16-wide and blitted at
 * 2x so 16x16 tiles fill the 32px grid and sprites read as chunky pixel art. */
static uint16_t pal(char c){
 switch(c){
  case ' ': case '.': return 0;                 /* transparent */
  case 'X': return C(2,2,5);    case 'W': return C(30,30,31); case '*': return C(31,31,31);
  case 'g': return C(13,23,11); case 'G': return C(8,18,8);   case 'h': return C(5,12,5);
  case 'd': return C(22,16,10); case 'D': return C(16,11,6);  case 'e': return C(10,7,3);
  case 's': return C(22,21,19); case 'S': return C(16,15,14); case 't': return C(9,9,10);
  case 'b': return C(13,23,31); case 'B': return C(6,13,27);  case 'c': return C(3,7,17);
  case 'w': return C(26,29,31);
  case 'r': return C(26,10,8);  case 'R': return C(18,6,5);   case 'q': return C(11,3,3);
  case 'o': return C(20,14,7);  case 'O': return C(14,9,4);   case 'n': return C(8,5,2);
  case 'l': return C(14,25,13); case 'L': return C(7,16,7);   case 'k': return C(3,9,4);
  case 'i': return C(31,24,18); case 'I': return C(24,17,12); case 'p': return C(17,11,8);
  case 'j': return C(14,8,3);   case 'J': return C(21,13,5);
  case 'u': return C(14,21,31); case 'U': return C(8,14,25);  case 'v': return C(4,8,15);
  case 'm': return C(24,13,30); case 'M': return C(15,7,20);  case 'N': return C(9,3,13);
  case 'f': return C(12,22,9);  case 'F': return C(7,15,5);
  case 'y': return C(31,28,8);  case 'Y': return C(27,19,4);  case 'z': return C(30,6,6);
  case 'a': return C(18,31,21); case 'A': return C(10,26,13); case '+': return C(4,16,7);
  case '=': return C(20,21,25); case '/': return C(28,30,31); case '%': return C(11,12,17);
  case '@': return C(2,3,10);   case '#': return C(17,11,5);  case '!': return C(28,24,20);
  default:  return 0;
 }
}
static void blit(int dx,int dy,const char*const*a,int w,int h,int sc){
 for(int y=0;y<h;y++){const char*row=a[y]; int len=0; while(row[len])len++;
  for(int x=0;x<w;x++){uint16_t c=pal(x<len?row[x]:' '); if(!c)continue;
   if(sc==1)put(dx+x,dy+y,c); else fillr(dx+x*sc,dy+y*sc,sc,sc,c);}}}
/* horizontally-flipped blit (for facing) */
static void blitf(int dx,int dy,const char*const*a,int w,int h,int sc){
 for(int y=0;y<h;y++){const char*row=a[y]; int len=0; while(row[len])len++;
  for(int x=0;x<w;x++){int sx=w-1-x; uint16_t c=pal(sx<len?row[sx]:' '); if(!c)continue;
   if(sc==1)put(dx+x,dy+y,c); else fillr(dx+x*sc,dy+y*sc,sc,sc,c);}}}
/* soft elliptical ground shadow (smooth edge, not a diamond) */
static void gshadow(int cx,int cy,int rw,int rh){
 if(rh<1)rh=1;
 for(int dy=-rh;dy<=rh;dy++){int hf=rw*isqrt(rh*rh-dy*dy)/rh; int y=cy+dy;
  for(int dx=-hf;dx<=hf;dx++){int x=cx+dx; if((unsigned)x<W&&(unsigned)y<H){
   uint16_t*p=&fb[y*stride_px+x]; *p=C(((*p>>11)&31)*5/8,((*p>>6)&31)*5/8,((*p>>1)&31)*5/8);}}}}

/* additive light: raise a pixel's 5-bit channels with clamp */
static void lighten(int x,int y,int dr,int dg,int db){
 if((unsigned)x>=W||(unsigned)y>=H)return;
 uint16_t*p=&fb[y*stride_px+x];
 int r=((*p>>11)&31)+dr,g=((*p>>6)&31)+dg,b=((*p>>1)&31)+db;
 if(r>31)r=31; if(g>31)g=31; if(b>31)b=31;
 *p=C(r,g,b);}

/* a single moon: lit upper-left, terminator shading, craters — all clipped
 * inside one disc so it can never read as two overlapping moons */
static void moon(int cx,int cy,int r){
 for(int dy=-r;dy<=r;dy++){int hf=isqrt(r*r-dy*dy);
  for(int dx=-hf;dx<=hf;dx++){
   int v=27-((dx+dy)*6)/r;          /* light from upper-left */
   if(v>31)v=31; if(v<19)v=19;
   put(cx+dx,cy+dy,C(v,v,v-3));}}
 disc(cx-r/3,cy+r/4,r/5,C(22,23,19));   /* craters (inside the disc) */
 disc(cx+r/4,cy-r/6,r/7,C(23,24,20));
 disc(cx+r/3,cy+r/3,r/8,C(22,23,19));
}
/* dithered glow halo ring around the moon */
static void moon_halo(int cx,int cy,int r0,int r1){
 for(int dy=-r1;dy<=r1;dy++)for(int dx=-r1;dx<=r1;dx++){
  int d2=dx*dx+dy*dy; if(d2>r1*r1||d2<r0*r0)continue;
  if(((dx+dy)&1)==0) lighten(cx+dx,cy+dy,1,1,2);}}
/* volumetric moonbeam: widening dithered shaft from the moon to a target */
static void moonbeam(int mx,int my,int tx,int ty){
 for(int y=my+28;y<ty+28&&y<H;y++){
  int t=(y-my)*256/(ty-my);
  int cxl=mx+((tx-mx)*t>>8);
  int hw=10+(t*46>>8);
  for(int x=cxl-hw;x<=cxl+hw;x++){
   if((x+y)&1)continue;
   int ax=x-cxl; if(ax<0)ax=-ax;
   if(ax<hw/3) lighten(x,y,2,2,3); else lighten(x,y,1,1,2);}}}
/* pool of moonlight where the beam lands */
static void lightpool(int cx,int cy,int rw,int rh){
 if(rh<1)rh=1;
 for(int dy=-rh;dy<=rh;dy++){int hf=rw*isqrt(rh*rh-dy*dy)/rh;
  for(int dx=-hf;dx<=hf;dx++){
   if(((dx+dy)&1)==0) lighten(cx+dx,cy+dy,1,2,3); else lighten(cx+dx,cy+dy,0,1,1);}}}

/* ── handcrafted 16x16 terrain tiles ──────────────────────────────────────── */
static const char* A_grass[16]={
 "GGgGGGGGGhGGGGgG","GhGGGgGGGGGGGGGG","GGGGGGGGGgGGGhGG","gGGhGGGGGGGGGGgG",
 "GGGGGGgGGGhGGGGG","GGgGGGGGGGGGgGGG","GGGGGhGGgGGGGGGG","GGGGGGGGGGGGGGgG",
 "GhGGGgGGGGGGhGGG","GGGGGGGGGgGGGGGG","GGgGGhGGGGGGGGgG","GGGGGGGgGGGGGGGG",
 "gGGGGGGGGGhGGGGG","GGGGhGGgGGGGGgGG","GGGGGGGGGGGGGGGG","GhGGGgGGGhGGGGgG"};
static const char* A_flower[16]={
 "GGgGGGGGGhGGGGgG","GhGGGyGGGGGGzGGG","GGGGgygGGGgGGhGG","gGGhGGGGGGGmGGgG",
 "GGGGGGgGGmhmGGGG","GGgGGGGGGGmGgGGG","GGGGGhGGgGGGGGGG","GGGGGGGGGGGzGGgG",
 "GhGGGgGyGGzmzGGG","GGGGGGyyyGGmGGGG","GGgGGhGyGGGGGGgG","GGGGGGGgGGGGGGGG",
 "gGGGmGGGGGhGGGGG","GGGGhmhGgGGGGGgG","GGGGGmGGGGGGGGGG","GhGGGgGGGhGGGGgG"};
static const char* A_path[16]={
 "DDdDDDDDeDDDDdDD","DdDDDsSDDDDDDDDD","DDDDDStDDDeDDsSD","DDsSDDdDDDDDDDtD",
 "dDDtDDDDDsSDDDeD","DDDDeDDDDStDDdDD","DDdDDDDDsSDDDDDD","DDDDDDDDtDDdDDDD",
 "DsSDDdDDDDDDeDDD","DDtDDDDDdDDsSDDD","DDdDDeDDDDDDtDdD","DDDDDDDsSDDDDDDD",
 "dDDDDDDDtDeDDDDD","DDDeDDdDDDDDsSDD","DDDDDDDDDDDDDtDD","DdDDsSDDeDDDDDDD"};
static const char* A_water[16]={
 "BBBBBBBBBBBBBBBB","BbBBBBBwBBBBBbBB","BBBBBBBBBBBBBBBB","BBBcBBBBBBbBBBBB",
 "wBBBBBBBBBBBBBwB","BBBBBBBbBBBBBBBB","BBbBBBBBBBcBBBBB","BBBBBBBBBBBBBBBB",
 "BBBBwBBBBBBBBbBB","BbBBBBBBBwBBBBBB","BBBBBBcBBBBBBBBB","BBBBBBBBBbBBBBBB",
 "wBBBBBBBBBBBBBBw","BBBbBBBwBBBBBBBB","BBBBBBBBBBBcBBBB","BBBBBbBBBBBBBBBB"};
static const char* A_tree[16]={
 "GGGGGkkkkkGGGGGG","GGGGkLLLLLkGGGGG","GGGkLLllLLLkGGGG","GGkLLlllllLLkGGG",
 "GGkLllllllLLkGGG","GkLLlllllllLLkGG","GkLLllllllLLLkGG","GGkLLllllLLLkGGG",
 "GGkLLLllLLLkGGGG","GGGkLLLLLLkGGGGG","GGGGGkOOkGGGGGGG","GGGGGnOOnGGGGGGG",
 "GGGGGnOOnGGGGGGG","GGGGhnOOnhGGGGGG","GGGhhnnnnhhGGGGG","GGGGhhhhhhGGGGGG"};
static const char* A_wall[16]={
 "ssSSSSSStSSSSSSS","SSSSSSSStSSSSSSS","SSSStSSStSSSStSS","tttttttttttttttt",
 "SSSSSSSSSSSSSStS","SSStSSSSSSStSSSS","sSSSSSSStSSSSSSS","tttttttttttttttt",
 "SSSStSSSSSSSStSS","SStSSSSStSSSSSSS","SSSSSSSSSSStSSSs","tttttttttttttttt",
 "SsSSStSSSSSSSStS","SSSSSSSStSSSSSSS","SSStSSSSSSStSSSS","tttttttttttttttt"};
static const char* A_roof[16]={
 "rRrRrRrRrRrRrRrR","RRRRRRRRRRRRRRRR","qqqqqqqqqqqqqqqq","RrRrRrRrRrRrRrRr",
 "RRRRRRRRRRRRRRRR","qqqqqqqqqqqqqqqq","rRrRrRrRrRrRrRrR","RRRRRRRRRRRRRRRR",
 "qqqqqqqqqqqqqqqq","RrRrRrRrRrRrRrRr","RRRRRRRRRRRRRRRR","qqqqqqqqqqqqqqqq",
 "rRrRrRrRrRrRrRrR","RRRRRRRRRRRRRRRR","qqqqqqqqqqqqqqqq","rRrRrRrRrRrRrRrR"};
static const char* A_door[16]={
 "SSSSSSSSSSSSSSSS","SSSnnnnnnnnnSSSS","SSnoOOOOOOOonSSS","SnoOnOOnOOOOonSS",
 "SnOOnOOnOOnOOnSS","SnOOnOOnOOnOOnSS","SnOOnOOnOOnOOnSS","SnOOnOOnOOnyOnSS",
 "SnOOnOOnOOnOOnSS","SnOOnOOnOOnOOnSS","SnOOnOOnOOnOOnSS","SnOOnOOnOOnOOnSS",
 "SnoOOOOOOOOonSSS","SSnnnnnnnnnnSSSS","SSSSSSSSSSSSSSSS","SSSSSSSSSSSSSSSS"};
static const char* A_fence[16]={
 "GGGGGGGGGGGGGGGG","GGGGGGGGGGGGGGGG","GoGGGGGGoGGGGGGo","GoGGGGGGoGGGGGGo",
 "oooooooooooooooo","nnnnnnnnnnnnnnnn","GoGGGGGGoGGGGGGo","GoGGGGGGoGGGGGGo",
 "oooooooooooooooo","nnnnnnnnnnnnnnnn","GoGGGGGGoGGGGGGo","GGGGGGGGGGGGGGGG",
 "GGGGGGGGGGGGGGGG","GhGGGgGGGhGGGGGG","GGGGGGGGGGGGGGGG","GGGGGgGGGGGhGGGG"};

static void t_grass(int sx,int sy,int wx,int wy){ (void)wx;(void)wy; blit(sx,sy,A_grass,16,16,2); }
static void t_path (int sx,int sy,int wx,int wy){ (void)wx;(void)wy; blit(sx,sy,A_path,16,16,2); }
static void t_water(int sx,int sy,int wx,int wy,int f){ (void)wx;(void)wy;(void)f; blit(sx,sy,A_water,16,16,2); }
static void t_tree (int sx,int sy,int wx,int wy){ (void)wx;(void)wy; blit(sx,sy,A_grass,16,16,2); gshadow(sx+16,sy+28,11,4); blit(sx,sy,A_tree,16,16,2); }
static void t_wall (int sx,int sy){ blit(sx,sy,A_wall,16,16,2); }
static void t_roof (int sx,int sy){ blit(sx,sy,A_roof,16,16,2); }
static void t_door (int sx,int sy){ blit(sx,sy,A_door,16,16,2); }
static void t_flower(int sx,int sy,int wx,int wy){ (void)wx;(void)wy; blit(sx,sy,A_flower,16,16,2); }
static void t_fence(int sx,int sy,int wx,int wy){ (void)wx;(void)wy; blit(sx,sy,A_fence,16,16,2); }
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

/* ════════════════ SPRITES (handcrafted pixel art) ════════════════ */
/* robe-recolour blit: maps 'M'/'m' to a chosen mid/light colour for NPC variety */
static void blit_robe(int dx,int dy,const char*const*a,int w,int h,int sc,uint16_t M,uint16_t m){
 for(int y=0;y<h;y++){const char*row=a[y]; int len=0; while(row[len])len++;
  for(int x=0;x<w;x++){char ch=x<len?row[x]:' '; uint16_t c=(ch=='M')?M:((ch=='m')?m:pal(ch));
   if(!c)continue; if(sc==1)put(dx+x,dy+y,c); else fillr(dx+x*sc,dy+y*sc,sc,sc,c);}}}

/* moonlit rim light: pale edge on every sprite pixel whose top/left neighbour
 * is transparent — reads as light falling on the unit from above-left */
static void blit_rim(int dx,int dy,const char*const*a,int w,int h,int sc,uint16_t rim){
 for(int y=0;y<h;y++){const char*row=a[y]; int len=0; while(row[len])len++;
  const char*up=(y>0)?a[y-1]:0; int ulen=0; if(up){while(up[ulen])ulen++;}
  for(int x=0;x<w;x++){char ch=(x<len)?row[x]:' '; if(!pal(ch))continue;
   char cu=(up&&x<ulen)?up[x]:' ';
   if(!pal(cu)) fillr(dx+x*sc,dy+y*sc,sc,1,rim);
   char cl=(x>0&&x-1<len)?row[x-1]:' ';
   if(!pal(cl)) fillr(dx+x*sc,dy+y*sc,1,sc,rim);}}}

/* hero — 16x22, three facings (side flipped for left) */
static const char* A_hero_dn[22]={
 ".....XXXXXX.....","....XjjjjjjX....","...XjJJJJJJjX...","...XjiiiiiijX...",
 "...XjiiiiiijX...","...Xi@iiii@iX...","...XiiiiiiiiX...","....XipppiiX....",
 "....XIiiiiX.....","...X==uuuu==X...","..X=uUUUUUu=X...","..XiuUUUUUuiX..",
 "..XiuUUUUUuiX..","...XU####UX.....","...XUUvvUUX.....","...XUvvvvUX.....",
 "...XvvX.XvvX....","...XOOX.XOOX....","...XOOX.XOOX....","..XXOOX.XOOXX...",
 "...XX.....XX....",".....X...X....."};
static const char* A_hero_up[22]={
 ".....XXXXXX.....","....XjjjjjjX....","...XjjjjjjjjX...","...XjjjjjjjjX...",
 "...XjjjjjjjjX...","...XjjjjjjjjX...","...XjjjjjjjjX...","....XjjjjjX.....",
 "....XjjjjjX.....","...X==UUUU==X...","..X=UUUUUUU=X...","..XiUUUUUUUiX..",
 "..XiUUUUUUUiX..","...XU####UX.....","...XUUvvUUX.....","...XUvvvvUX.....",
 "...XvvX.XvvX....","...XOOX.XOOX....","...XOOX.XOOX....","..XXOOX.XOOXX...",
 "...XX.....XX....",".....X...X....."};
static const char* A_hero_sd[22]={
 "....XXXXX.......","...XjjjjjX......","..XjJJJJjX......","..XjiiiijX......",
 "..Xji@iiX.......","..XjiiiiX.......","...Xippi X......","...XIiiX.......",
 "..X==uuu===.....",".X=uUUUu=//.....","XiuUUUUu=/X.....","XiuUUUUUuX/.....",
 ".XiUUUUUuX/.....","..XU###UX.//....","..XUUvvUX..//...","..XUvvvUX.......",
 "..XvvXvvX.......","..XOOXOOX.......","..XOOXOOX.......",".XXOOXOOXX......",
 "..XX..XX.......","................"};

/* cy = FEET position; shadow sits exactly under the feet (art feet row 20) */
static void hero(int cx,int cy,int dir,int step){
 gshadow(cx,cy+1,11,4);
 int dy=cy-40+(step?2:0);
 if(dir==1) blit(cx-16,dy,A_hero_up,16,22,2);
 else if(dir==2) blitf(cx-22,dy,A_hero_sd,16,22,2);   /* side art is left-packed */
 else if(dir==3) blit(cx-10,dy,A_hero_sd,16,22,2);
 else blit(cx-16,dy,A_hero_dn,16,22,2);
}

/* generic villager (robe via M/m recolour) — elder, shopkeeper, party portraits */
static const char* A_villager[22]={
 ".....XXXXX......","....XjjjjjX.....","...XjiiiiijX....","...Xi@ii@iiX....",
 "...XiiiiiiiX....","....XippiX......","....XIiiiX......","...XMMMMMMX....",
 "..XMmmmmmmMX...","..XMmMMMMMmMX..","..XMmMMMMMmMX..","..XMmMMMMMmMX..",
 "..XMmMMMMMmMX..","...XMMMMMMX....","...XMMMMMMX....","...XMMMMMMX....",
 "...XMMMMMMX....","...XMmmmmMX....","...XMMMMMMX....","....XMMMMX.....",
 "....XO..OX.....","....XX..XX....."};
/* cy = FEET position (art feet row 21) */
static void npc(int cx,int cy,uint16_t robe,uint16_t robeH,uint16_t hairc){
 (void)hairc; gshadow(cx,cy+1,11,4);
 blit_robe(cx-16,cy-42,A_villager,16,22,2,robe,robeH);
}

/* enemies */
static const char* A_slime[16]={
 "................","......++++......",".....+AAAA+.....","....+AaaaaA+....",
 "...+AaaaaaaA+...","..+Aaa**aaaaA+..","..+Aa****aaaA+..","..+AaaaaaaaaA+..",
 ".+Aaaaaaaaaaa A.","+Aaa@aaaa@aaaA+","+Aaa@@aaa@@aaA+","+AaaaaWaaWaaaA+",
 "+Aaaaaaaaaaaa A+",".+AAaaaaaaaaA+..","..++AAAAAAAA++..","....++++++++...."};
static const char* A_goblin[20]={
 "...k.......k....","..kFk.....kFk...","..kFFk...kFFk...","...kFFkkkFFk....",
 "....kFFFFFFk....","...kFiiiiiiFk...","..kFiz@ii@ziFk..","..kFiiiiiiiiFk..",
 "...kFipppppiFk..","...kFiiiiiiFk...","....kFFFFFk.....","...kfFFFFFfk..o.",
 "..kfFFFFFFFfk.O.","..kfFFFFFFFfk.O.","..kfFffffFFfk.O.","...kfFFFFFfk.O..",
 "...kFFkkFFk..O..","...kFk..kFk.....","..kFk....kFk....","..kk......kk...."};
static const char* A_bat[12]={
 "................","k...........k...","kk.kkkkkkk.kk...","kKkkLLLLLkkKk...",
 "kLLLk@@@kLLLk...","kLLLLLLLLLLLk...",".kLLz@LLL@zLLk..","..kLLLLLLLLk....",
 "...kkLLLLkk.....",".....kLLk.......","......kk........","................"};
/* cy = FEET position for all ground units */
static void slime(int cx,int cy,int f){ int b=(f>>3)&1; gshadow(cx,cy+1,12,4);
 blit(cx-16,cy-30+b*2,A_slime,16,16,2); }
static void goblin(int cx,int cy){ gshadow(cx,cy+1,12,4); blit(cx-16,cy-38,A_goblin,16,20,2); }
static void bat(int cx,int cy,int f){ int b=(f>>2)&1; blit(cx-16,cy-12+b*2,A_bat,16,12,2); }

/* Forest Warden boss — 24x28, ancient treant */
static const char* A_warden[28]={
 ".........kkkkkk.........",".......kkLLLLLLkk.......","......kLLlllllLLk.......",
 ".....kLLlllllllLLk......","....kLLlllllllllLLk.....","...kLLllllllllllLLLk....",
 "...kLlllllllllllllLk....","..kLLlllllllllllllLLk...","..kLllllllllllllllLk...",
 "..kLLlllllllllllllLLk...","...kLLlllllllllllLLk....","....kLLLlllllllLLLk.....",
 ".....kkLLLLLLLLLkk......","......kkkkkkkkkkk.......","........nnOOnn.........",
 ".......nOOOOOOn........",".......nOyyyyOn........",".......nOy@@yOn........",
 "......nOOy@@yOOn.......","......nOzzzzzzOn......",".....nOOzzzzzzOOn......",
 ".....nOOOWWWWOOOn......","....nnOOOOOOOOOOnn.....","...nnOOOnnnnOOOnn n....",
 "..nnOOnn....nnOOnn.....",".nOOnn........nnOOn....","nOOn............nOOn...",
 "nn................nn..."};
/* cy = FEET position (art feet row 27) */
static void warden(int cx,int cy,int f){
 gshadow(cx,cy+2,30,8);
 blit(cx-36,cy-81,A_warden,24,28,3);   /* 72x84 — towering treant */
 /* glowing eyes flicker */
 int gl=(f>>3)&1; if(gl){ disc(cx-7,cy-29,4,C(31,28,6)); disc(cx+7,cy-29,4,C(31,28,6)); }
}

/* ════════════════ SCENES ════════════════ */
static void scene_title(int f){
 vgrad(0,0,W,300, 8,8,34, 26,20,58);          /* dusk sky */
 for(int i=0;i<90;i++){int n=hsh(i*257); int x=((n&1023)+f/4)%W, y=(n>>10)&255;
   if(y<260) put_rgb(x,y, 180+((n>>4)&60),180+((n>>2)&60),200);}
 moon(540,80,30); moon_halo(540,80,32,44);
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
 hero(150,414,3,(f>>3)&1);
 npc(470,418,C(22,6,8),C(28,10,12),C(7,5,3));
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
 /* NPCs stand on grass beside their houses (feet-anchored, not on rooftops) */
 npc(2*TS+16,5*TS+30,C(22,8,26),C(28,12,31),C(7,5,3));     /* elder, left of left house */
 npc(15*TS+16,12*TS+30,C(8,20,12),C(13,27,17),C(20,13,5)); /* shopkeep, right of shop */
 /* hero patrols the open main path (row 4 — all walkable), feet on the path */
 int hx=3*TS+16+((f/2)%(8*TS));
 hero(hx,4*TS+28,3,(f>>3)&1);
 /* quest marker bobbing over the elder's head */
 int by=5*TS-26+ (isin(f*3)*3/31);
 gch(2*TS+12,by,'!',3,C(31,28,8)); gch(2*TS+13,by+1,'!',3,C(20,14,2));
 hud_top();
 window(150,446,340,28); gtext(166,453,"WHISPERING WOODS  -  NORTH GATE",2,C(20,24,31));
}

static void scene_dialogue(int f){
 scene_overworld(0);
 for(int y=300;y<H;y++)for(int x=0;x<W;x++) if(((x+y)&1)==0){uint16_t*p=&fb[y*stride_px+x];
   *p=C(((*p>>11)&31)/3,((*p>>6)&31)/3,((*p>>1)&31)/3+1);}
 window(16,300,140,150);                        /* portrait */
 fillr(28,316,116,116,C(14,8,18)); rect_outline(28,316,116,116,C(20,14,26));
 npc(86,418,C(22,8,26),C(28,12,31),C(7,5,3));
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
 window(28,62,276,100); npc(64,136,C(8,15,28),C(13,21,31),C(20,11,4));
 gtext(98,72,"ARIA",2,C(31,31,31)); gtext(230,72,"LV 4",2,C(20,28,31));
 gtext(98,92,"KNIGHT",1,C(18,20,26));
 gtext(98,108,"HP",1,C(18,28,31)); hpbar(122,106,150,28,32,30,210,60); gnum(280,106,28,2,1,C(20,28,31));
 gtext(98,126,"MP",1,C(18,28,31)); hpbar(122,124,150,9,12,40,120,240); gnum(280,124,9,2,1,C(20,28,31));
 /* Loras */
 window(28,170,276,100); npc(64,244,C(18,8,26),C(26,12,31),C(8,6,3));
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
 npc(90,426,C(8,20,12),C(13,27,17),C(20,13,5));
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
 /* grassy clearing from handcrafted tiles */
 for(int ty=0;ty<15;ty++)for(int tx=0;tx<20;tx++) blit(tx*32,ty*32,A_grass,16,16,2);
 /* winding brook (handcrafted water tiles, offset per row band) */
 for(int by=0;by<15;by++){int rx=150+isin(by*3+f/16)*40/31; rx&=~1;
   blit(rx,by*32,A_water,16,16,2); blit(rx+16,by*32,A_water,16,16,2);
   for(int y=0;y<32;y++){put(rx-1,by*32+y,C(8,16,8));put(rx+32,by*32+y,C(8,16,8));}}
 /* scattered trees */
 for(int i=0;i<16;i++){int n=hsh(i*151); int tx=((n&511)%(W-48))&~1, ty=(16+((n>>9)&13)*30);
   gshadow(tx+16,ty+30,12,4); blit(tx,ty,A_tree,16,16,2);}
 (void)f;
}
static void scene_action(int f){
 woods(f);
 int hx=300,hy=284;                        /* hy = feet */
 int sw=f%40;
 if(sw<12){ for(int a=-12;a<=12;a++){int ax=hx+22+a, ay=hy-26+(a*a)/14;
   put(ax,ay,C(28,30,31)); put(ax,ay+1,C(18,24,31)); put(ax,ay-1,C(31,31,31));}
   disc(hx+30,hy-18,5,C(31,30,18)); disc(hx+30,hy-18,2,C(31,31,31)); }
 hero(hx,hy,3,(f>>3)&1);
 slime(450,196,f);   hpbar(420,150,70,8,14,255,40,40);
 slime(510,316,f+8); hpbar(480,270,70,14,14,255,40,40);
 goblin(500,254);    hpbar(470,200,70,18,26,255,40,40);
 if((f%40)<20) gtext_sh(404,140-(f%40),"12",3,C(31,28,8),C(8,4,1));
 if(sw<10){disc(424,160,4+sw,C(31,24,6)); disc(424,160,2,C(31,31,31));}
 int px=500-((f*4)%160); disc(px,236,4,C(31,12,4)); disc(px,236,2,C(31,28,16));
 window(8,8,250,52); gtext(20,16,"ARIA",2,C(31,30,20));
 gtext(20,38,"HP",1,C(18,28,31)); hpbar(44,36,200,28,32,30,210,60);
 window(W-220,8,212,28); gtext(W-208,16,"WHISPERING WOODS",2,C(18,24,20));
 window(W-150,430,142,42); gtext(W-138,438,"A  ATTACK",2,C(20,24,30));
 gtext(W-138,456,"B  MAGIC",2,C(20,24,30));
}

/* side-view battlers (facing right, toward the enemy line) */
static const char* A_aria_b[22]={
 ".....XXXX.......","....XjjjjX......","...XjJJJjX......","...Xji@ijX...//.",
 "...XjiiijX../X..","...XippiX..//...","...XIiiX..//....","..X==uu=//......",
 ".X=uUUUu/.......",".XiuUUUUX.......",".XiuUUUUuX......","..XU####UX......",
 "..XUUvvUUX......","..XUvvvvUX......","..XvvX.XvvX.....","..XOOX.XOOX.....",
 "..XOOX.XOOX.....",".XXOOX.XOOXX....","..XX....XX......","................",
 "................","................"};
static const char* A_loras_b[22]={
 "....XNNNN.......","...XNMMMMNX.....","..XNMMMMMMNX....","...XjiiiijX.....",
 "...Xi@iiijX..o..","...XiiiiiX...o..","...XippiX...o...","...XMMMMMX.WWW..",
 "..XMmmmmMX..o...","..XMmMMMmX..o...","..XMmMMMmX..o...","..XMMMMMMX..o...",
 "...XMMMMMX..o...","...XMMMMMX......","...XMmmmMX......","...XMMMMMX......",
 "....XMMMX.......","....XMMMX.......","....XO.OX.......","....XX.XX.......",
 "................","................"};

/* layered forest battle backdrop — rolling treeline silhouette, no UI overlap */
static void battle_bg(int f){
 vgrad(0,0,W,205, 9,6,22, 17,12,34);                 /* dusk sky */
 for(int i=0;i<46;i++){int n=hsh(i*193); int x=(n&1023)%W,y=(n>>10)&150;
   int tw=(((f>>3)+i)&7)<2;                          /* twinkle */
   put_rgb(x,y, tw?180:110, tw?170:95, tw?220:160);}
 moon(96,56,26); moon_halo(96,56,28,38);             /* ONE moon, glowing */
 /* far treeline (bumpy crowns), then a nearer darker band for depth */
 for(int x=0;x<W;x++){
   int top=150 + isin(x/22)*10/31 - ((isin(x*2)+31)*10/62);
   for(int y=top;y<206;y++) put_rgb(x,y, 8+((x>>3)&3), 26+((x+y)&3), 11);}
 for(int x=0;x<W;x++){
   int top=176 + isin(x/16+18)*12/31 - ((isin(x*3+5)+31)*8/62);
   for(int y=top;y<206;y++) put_rgb(x,y, 4, 16+((x+y)&2), 6);}
 /* battle ground (mossy clearing) the units stand on */
 vgrad(0,205,W,125, 16,40,16, 9,24,11);
 hbar(0,W-1,205,C(20,46,20)); hbar(0,W-1,206,C(6,16,8));
 for(int i=0;i<120;i++){int n=hsh(i*37+1); put_rgb((n&1023)%W,206+((n>>10)&120),10,30,12);}
}
static void scene_battle(int f){
 battle_bg(f);
 uint16_t rim=C(20,24,31);                            /* cool moonlit rim */
 int act=(f/44)%2;
 int alx=(act==0)?16:0, llx=(act==1)?16:0;            /* active battler lunges */
 /* ── enemy party (right), feet-anchored on the clearing ── */
 gshadow(470,297,15,5); blit(446,239,A_goblin,16,20,3); blit_rim(446,239,A_goblin,16,20,3,rim);
 gtext(446,216,"GOBLIN",1,C(30,20,20)); hpbar(446,226,72,26,30,30,210,60);
 gshadow(565,257,14,4); blit(541,211,A_slime,16,16,3);  blit_rim(541,211,A_slime,16,16,3,rim);
 hpbar(541,198,60,14,14,30,210,60);
 int bb=(f>>2)&1;
 gshadow(412,296,8,3);                                /* faint, far below the bat */
 blit(388,202+bb*3,A_bat,16,12,3); blit_rim(388,202+bb*3,A_bat,16,12,3,rim);
 hpbar(388,190,56,10,12,30,210,60);
 if((f%44)<10) disc(470,266,6+(f%44),C(31,28,10));    /* hit flash */
 if((f%44)<22) gtext_sh(500,200-(f%44)/2,"14",3,C(31,28,8),C(8,4,1));
 /* ── hero party (left): Loras back row, Aria front; shadows track the lunge ── */
 gshadow(124+llx,251,13,4);
 blit(100+llx,195,A_loras_b,16,22,3); blit_rim(100+llx,195,A_loras_b,16,22,3,rim);
 gshadow(157+alx,301,14,5);
 blit(133+alx,246,A_aria_b,16,22,3);  blit_rim(133+alx,246,A_aria_b,16,22,3,rim);
 if(act==0) gch(111+alx,252,'>',3,C(31,28,8));
 else       gch(78+llx,201,'>',3,C(31,28,8));
 /* ── moonlight: beam from the moon onto the party + pool at their feet ── */
 moonbeam(96,56,150,298);
 lightpool(152,302,82,13);
 /* fireflies drifting between the lines */
 for(int i=0;i<6;i++){
   int fx2=246+i*26+(isin(f+i*11)*10)/31;
   int fy2=232+((i&1)*34)+(isin(f*2+i*9)*12)/31;
   put(fx2,fy2,C(28,31,12));
   put(fx2-1,fy2,C(14,20,6));put(fx2+1,fy2,C(14,20,6));
   put(fx2,fy2-1,C(14,20,6));put(fx2,fy2+1,C(14,20,6));}
 /* ── UI: message + command + status (occupy the bottom, clear of sprites) ── */
 window(8,332,624,26);
 gtext(20,339,"ARIA ATTACKS!  GOBLIN TAKES 14 DAMAGE!",2,C(28,30,31));
 window(8,364,300,108);
 banner(20,358,118,22,"COMMAND");
 const char*cmd[]={"FIGHT","SKILL","ITEM","RUN"}; int sel=(f/16)%4;
 for(int i=0;i<4;i++){int cx=24+(i%2)*150, cy=394+(i/2)*38;
   if(i==sel){ vgrad(cx-8,cy-6,140,28, 22,32,74, 12,18,46); rect_outline(cx-8,cy-6,140,28,C(26,31,31));
     gch(cx,cy,'>',2,C(31,28,8)); }
   gtext(cx+22,cy,cmd[i],2,i==sel?C(31,31,22):C(20,22,28)); }
 window(320,364,312,108);
 gtext(336,376,"ARIA",2,C(31,31,31));  gtext(548,376,"TURN 3",2,C(31,26,8));
 gtext(336,396,"HP",1,C(18,28,31)); hpbar(360,394,150,26,32,30,210,60); gnum(520,394,26,2,2,C(20,28,31));
 gtext(336,412,"MP",1,C(18,28,31)); hpbar(360,410,150,9,12,40,120,240); gnum(520,410,9,2,2,C(20,28,31));
 gtext(336,434,"LORAS",2,C(31,31,31));
 gtext(336,454,"HP",1,C(18,28,31)); hpbar(360,452,150,18,24,30,210,60); gnum(520,452,18,2,2,C(20,28,31));
}

static void scene_boss(int f){
 woods(f);
 for(int y=0;y<H;y++)for(int x=0;x<W;x++) if(((x*3+y)&7)==0){uint16_t*p=&fb[y*stride_px+x];
   *p=C(((*p>>11)&31)*3/4,((*p>>6)&31)*3/4,((*p>>1)&31)*3/4);}
 warden(320,207,f);
 window(70,16,500,40);
 gtext_sh(82,24,"FOREST WARDEN",2,C(31,8,8),C(8,1,1));
 hpbar(250,26,300,84,120,((f>>3)&1)?255:200,20,20);
 hero(180,424,1,(f>>3)&1);
 npc(300,432,C(18,8,26),C(26,12,31),C(8,6,3));
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
