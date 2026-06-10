/* Riverdale Saga - top-down RPG demo (direct framebuffer, no rdpq/RSP).
 * The visual reference for PakStudio's top-down RPG maker: overworld with a
 * tile map, animated 4-direction hero, NPCs, dialogue boxes, a party/inventory
 * menu, quest log, shop, crafting, action combat, and a turn-based battle.
 * Scenes cycle so a single ROM showcases the whole genre. */
#define _GNU_SOURCE
#include <libdragon.h>
#include <stdint.h>
#include <string.h>
#include "pak_math.h"

/* N64 RGBA5551: R=[15:11] G=[10:6] B=[5:1] A=[0]=1. All channels 0-31. */
#define C(r,g,b) ((uint16_t)(((r)<<11)|((g)<<6)|((b)<<1)|1))
#define W 320
#define H 240

static uint16_t *fb;
static int stride_px;

static inline void put(int x, int y, uint16_t c) {
    if ((unsigned)x < W && (unsigned)y < H) fb[y*stride_px+x] = c;
}
static void fillr(int x,int y,int w,int h,uint16_t c) {
    for(int dy=0;dy<h;dy++){int yy=y+dy; if((unsigned)yy>=H)continue;
        for(int dx=0;dx<w;dx++){int xx=x+dx; if((unsigned)xx<W) fb[yy*stride_px+xx]=c;}}
}
static void frame_rect(int x,int y,int w,int h,uint16_t c){
    for(int i=0;i<w;i++){put(x+i,y,c);put(x+i,y+h-1,c);}
    for(int i=0;i<h;i++){put(x,y+i,c);put(x+w-1,y+i,c);}
}
static int isqrt(int v){int r=0;while((r+1)*(r+1)<=v)r++;return r;}
static void disc(int cx,int cy,int r,uint16_t c){
    for(int dy=-r;dy<=r;dy++){int hf=isqrt(r*r-dy*dy);
        for(int dx=-hf;dx<=hf;dx++) put(cx+dx,cy+dy,c);}
}

/* sin*31 over 64 steps */
static const int8_t SIN64[64]={0,3,6,9,12,15,17,20,22,24,26,27,29,30,30,31,
 31,31,30,30,29,27,26,24,22,20,17,15,12,9,6,3,0,-3,-6,-9,-12,-15,-17,-20,-22,
 -24,-26,-27,-29,-30,-30,-31,-31,-31,-30,-30,-29,-27,-26,-24,-22,-20,-17,-15,-12,-9,-6,-3};
static inline int isin(int a){return SIN64[a&63];}

/* ── 5x5 font: space, A-Z, 0-9, and a few punctuation ──────────────────────── */
static const uint8_t font[42][5]={
 {0,0,0,0,0},
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
 {0x00,0x04,0x00,0x04,0x00}, /* : (37) */
 {0x00,0x00,0x00,0x04,0x08}, /* , (38) */
 {0x00,0x00,0x00,0x00,0x04}, /* . (39) */
 {0x04,0x04,0x04,0x00,0x04}, /* ! (40) */
 {0x0E,0x02,0x04,0x00,0x04}, /* ? (41) */
};
static int fidx(char c){
 if(c>='A'&&c<='Z')return 1+(c-'A');
 if(c>='a'&&c<='z')return 1+(c-'a');
 if(c>='0'&&c<='9')return 27+(c-'0');
 if(c==':')return 37; if(c==',')return 38; if(c=='.')return 39;
 if(c=='!')return 40; if(c=='?')return 41; return 0;
}
static void dch(int x,int y,char c,uint16_t col){const uint8_t*g=font[fidx(c)];
 for(int r=0;r<5;r++)for(int k=0;k<5;k++)if(g[r]&(0x10>>k))put(x+k,y+r,col);}
static void dstr(int x,int y,const char*s,uint16_t col){while(*s){dch(x,y,*s++,col);x+=6;}}
static void dch2(int x,int y,char c,uint16_t col){const uint8_t*g=font[fidx(c)];
 for(int r=0;r<5;r++)for(int k=0;k<5;k++)if(g[r]&(0x10>>k))fillr(x+k*2,y+r*2,2,2,col);}
static void dstr2(int x,int y,const char*s,uint16_t col){while(*s){dch2(x,y,*s++,col);x+=12;}}
static void dnum(int x,int y,int v,int digits,uint16_t col){
 for(int i=digits-1;i>=0;i--){dch(x+i*6,y,(char)('0'+v%10),col);v/=10;}}

/* ── shared chrome ─────────────────────────────────────────────────────────── */
static void panel(int x,int y,int w,int h){
 fillr(x,y,w,h,C(2,3,9));
 frame_rect(x,y,w,h,C(20,24,31));
 frame_rect(x+1,y+1,w-2,h-2,C(8,11,20));
}
static void bar(int x,int y,int w,int v,int max,uint16_t c){
 fillr(x,y,w,4,C(4,4,7));
 int f=max>0?w*v/max:0; if(f>0)fillr(x,y,f,4,c);
 frame_rect(x,y,w,4,C(12,12,18));
}

/* ── overworld tiles ───────────────────────────────────────────────────────── */
/* 0 grass 1 path 2 water 3 tree 4 house wall 5 roof 6 door 7 flower 8 fence */
#define MW 20
#define MH 15
static const uint8_t village[MH][MW]={
 {3,3,3,0,0,0,7,0,0,0,0,7,0,0,0,3,3,3,3,3},
 {3,0,0,0,5,5,5,5,0,0,0,0,0,5,5,5,0,0,0,3},
 {3,0,0,0,5,4,4,5,0,1,1,0,0,5,4,5,0,7,0,3},
 {3,0,7,0,4,4,6,4,0,1,1,0,0,4,6,4,0,0,0,0},
 {0,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,0,0},
 {0,1,0,0,0,0,7,0,1,0,0,7,0,0,0,0,0,1,0,3},
 {3,1,0,2,2,2,0,0,1,0,0,0,0,7,0,0,0,1,0,3},
 {3,1,0,2,2,2,0,0,1,1,1,1,1,1,1,1,1,1,0,3},
 {3,1,0,2,2,2,0,0,1,0,0,0,0,0,0,0,7,1,0,3},
 {3,1,0,0,0,0,0,0,1,0,5,5,5,5,0,0,0,1,0,3},
 {0,1,1,1,1,1,1,1,1,0,5,4,4,5,0,7,0,1,0,0},
 {3,0,7,0,0,0,0,0,0,0,4,6,4,4,0,0,0,1,0,3},
 {3,0,0,0,8,8,8,8,8,0,0,0,0,0,0,0,0,1,0,3},
 {3,3,0,0,0,7,0,0,0,0,7,0,0,3,0,0,0,0,0,3},
 {3,3,3,3,0,0,0,3,3,3,3,3,0,0,0,3,3,3,3,3},
};
#define TS 16
static void draw_tile(int sx,int sy,uint8_t t,int f){
 switch(t){
 case 0: fillr(sx,sy,TS,TS,C(6,16,7)); /* grass speckle */
         if(((sx>>2)+(sy>>3))&1) put(sx+4,sy+9,C(4,12,5)); put(sx+11,sy+3,C(8,20,9)); break;
 case 1: fillr(sx,sy,TS,TS,C(18,15,9)); /* path */
         for(int i=0;i<TS;i+=4){put(sx+i,sy+5,C(14,11,6));put(sx+i+2,sy+11,C(14,11,6));} break;
 case 2: { uint16_t w=((f>>3)&1)?C(5,12,28):C(4,10,25); fillr(sx,sy,TS,TS,w);
         for(int i=0;i<TS;i+=6)put(sx+((i+f/4)%TS),sy+4+(i%6),C(12,20,31)); } break;
 case 3: fillr(sx,sy,TS,TS,C(6,16,7)); disc(sx+8,sy+7,7,C(3,12,4));
         disc(sx+8,sy+5,5,C(5,18,6)); fillr(sx+7,sy+12,2,4,C(12,7,2)); break;
 case 4: fillr(sx,sy,TS,TS,C(20,17,12)); frame_rect(sx,sy,TS,TS,C(12,10,7)); break;
 case 5: fillr(sx,sy,TS,TS,C(24,6,5)); for(int i=0;i<TS;i+=3)put(sx+i,sy+8,C(16,3,3)); break;
 case 6: fillr(sx,sy,TS,TS,C(20,17,12)); fillr(sx+4,sy+3,8,13,C(8,5,3));
         put(sx+10,sy+9,C(28,24,6)); break;
 case 7: fillr(sx,sy,TS,TS,C(6,16,7)); disc(sx+8,sy+8,2,C(31,28,6));
         put(sx+8,sy+8,C(31,12,16)); break;
 case 8: fillr(sx,sy,TS,TS,C(6,16,7)); fillr(sx,sy+6,TS,2,C(16,12,7));
         put(sx+4,sy+3,C(16,12,7)); put(sx+12,sy+3,C(16,12,7)); break;
 }
}

/* ── hero sprite (4-dir, 2-frame walk) ─────────────────────────────────────── */
/* dir: 0 down 1 up 2 left 3 right */
static void hero(int cx,int cy,int dir,int step){
 uint16_t skin=C(28,21,15),hair=C(18,10,4),tunic=C(8,16,28),tunic2=C(6,12,22),
          boot=C(12,8,4),blade=C(26,28,31);
 int legoff=step?1:-1;
 /* shadow */ disc(cx,cy+9,6,C(2,5,3));
 /* body */ fillr(cx-4,cy-2,9,9,tunic); fillr(cx-4,cy-2,9,2,tunic2);
 /* legs */ fillr(cx-3,cy+7,3,3,boot); fillr(cx+1,cy+7,3,3,boot);
 put(cx-3,cy+9+ (legoff>0?0:1),boot); put(cx+3,cy+9+(legoff>0?1:0),boot);
 /* head */ disc(cx,cy-6,4,skin);
 if(dir==1){ disc(cx,cy-7,4,hair); }                 /* facing up: hair */
 else { fillr(cx-4,cy-9,9,3,hair);
   if(dir==0){put(cx-2,cy-6,C(2,2,4));put(cx+2,cy-6,C(2,2,4));}/* eyes */
   if(dir==2){put(cx-3,cy-6,C(2,2,4));}
   if(dir==3){put(cx+3,cy-6,C(2,2,4));}
 }
 /* arms / sword depending on dir */
 if(dir==3){ fillr(cx+5,cy,2,5,skin); fillr(cx+7,cy-4,2,7,blade); }
 else if(dir==2){ fillr(cx-6,cy,2,5,skin); fillr(cx-8,cy-4,2,7,blade); }
 else { fillr(cx-6,cy,2,5,skin); fillr(cx+5,cy,2,5,skin); }
}

/* a generic villager NPC */
static void npc(int cx,int cy,uint16_t robe,uint16_t hairc){
 disc(cx,cy+9,6,C(2,5,3));
 fillr(cx-4,cy-2,9,10,robe);
 fillr(cx-4,cy-2,9,2,C((robe>>11)&0x1f,((robe>>6)&0x1f)/2,((robe>>1)&0x1f)/2));
 disc(cx,cy-6,4,C(28,21,15));
 fillr(cx-4,cy-9,9,3,hairc);
 put(cx-2,cy-6,C(2,2,4)); put(cx+2,cy-6,C(2,2,4));
}
static void slime(int cx,int cy,int f){
 int sq=isin(f*4)/12;
 disc(cx,cy+6,6,C(2,5,3));
 disc(cx,cy+2-sq,7+sq,C(8,26,12));
 disc(cx,cy-sq,5,C(14,31,18));
 put(cx-2,cy,C(2,2,4)); put(cx+2,cy,C(2,2,4));
 put(cx-2,cy+1,C(31,31,31)); put(cx+2,cy+1,C(31,31,31));
}
static void goblin(int cx,int cy){
 disc(cx,cy+8,6,C(2,5,3));
 fillr(cx-4,cy-1,9,9,C(9,16,6)); disc(cx,cy-6,4,C(11,18,7));
 put(cx-5,cy-8,C(11,18,7)); put(cx+5,cy-8,C(11,18,7)); /* ears */
 put(cx-2,cy-6,C(31,6,2)); put(cx+2,cy-6,C(31,6,2));
 fillr(cx-2,cy-2,5,1,C(20,18,4));
 fillr(cx+5,cy-4,2,9,C(16,12,6)); /* club */
}
static void warden(int cx,int cy,int f){
 disc(cx,cy+18,18,C(2,5,3));
 /* trunk body */ fillr(cx-16,cy-10,33,30,C(7,12,5));
 for(int i=-16;i<17;i+=4) fillr(cx+i,cy-10,2,30,C(4,9,3));
 /* canopy crown */ disc(cx,cy-16,18,C(4,14,5)); disc(cx-10,cy-10,11,C(5,17,6));
 disc(cx+10,cy-10,11,C(5,17,6));
 /* glowing eyes */ int g=(isin(f*5)+31)/3;
 disc(cx-7,cy-2,3,C(31,g,2)); disc(cx+7,cy-2,3,C(31,g,2));
 fillr(cx-8,cy+8,17,2,C(20,4,2)); /* maw */
 /* arms */ fillr(cx-24,cy-4,8,4,C(6,11,4)); fillr(cx+16,cy-4,8,4,C(6,11,4));
}

/* ════════════════ SCENES ════════════════ */

/* 1. Title */
static void scene_title(int f){
 for(int y=0;y<H;y++){uint16_t c=C(1+y/30,2+y/22,6+y/14);
   for(int x=0;x<W;x++)fb[y*stride_px+x]=c;}
 for(int i=0;i<40;i++){int x=(i*97+f/3)%W,y=(i*53)%120;put(x,y,C(20,20,28));}
 /* distant hills + castle */
 for(int x=0;x<W;x++){int hh=150+isin(x/4)*6/31;for(int y=hh;y<170;y++)put(x,y,C(3,10,5));}
 fillr(120,120,80,40,C(6,6,12)); fillr(132,108,10,14,C(8,8,16));
 fillr(178,108,10,14,C(8,8,16)); fillr(150,100,20,22,C(8,8,16));
 for(int i=0;i<3;i++)put(136+i*22,112,((f>>3)&1)?C(31,28,6):C(20,16,4));
 /* meadow */ fillr(0,170,W,70,C(6,16,7));
 hero(70,196,3,(f>>3)&1);
 npc(250,196,C(22,6,8),C(6,4,2));
 /* logo */
 dstr2(60,44,"RIVERDALE",C(2,3,9));
 dstr2(58,42,"RIVERDALE",C(31,26,8));
 dstr2(116,66,"SAGA",C(2,3,9));
 dstr2(114,64,"SAGA",C(28,18,6));
 fillr(58,84,204,1,C(20,14,4));
 dstr(96,90,"AN EPIC N64 RPG",C(18,22,28));
 if((f/20)%2==0) dstr(110,150,"PRESS START",C(28,31,20));
 dstr(70,222,"BUILT WITH PAKSTUDIO",C(11,13,9));
}

/* 2. Overworld */
static void draw_world(int camx,int camy){
 for(int ty=0;ty<MH;ty++)for(int tx=0;tx<MW;tx++)
   draw_tile(tx*TS-camx,ty*TS-camy,village[ty][tx],0);
}
static void hud_overworld(int f){
 panel(4,4,96,30);
 dstr(10,9,"ARIA",C(28,31,20));
 dstr(10,18,"HP",C(20,28,31)); bar(28,18,60,28,32,C(8,28,10));
 dstr(10,25,"MP",C(20,28,31)); bar(28,26,60,9,12,C(10,18,31));
 panel(W-86,4,82,16);
 dstr(W-80,9,"GOLD",C(28,24,6)); dnum(W-44,9,150,4,C(31,31,31));
 (void)f;
}
static void scene_overworld(int f){
 int camx=8, camy=20;
 draw_world(camx,camy);
 /* NPCs */
 npc(5*TS-camx+8, 5*TS-camy+8, C(22,8,26), C(6,4,2));   /* elder */
 npc(13*TS-camx+8,11*TS-camy+4, C(8,20,12), C(18,12,4)); /* shopkeep */
 /* hero walking the path */
 int hx=2*TS+8+((f/2)%(10*TS));
 hero(hx-camx, 4*TS-camy+6, 3, (f>>3)&1);
 /* floating quest marker over elder */
 int by=5*TS-camy-8+isin(f*3)*2/31;
 dch(5*TS-camx+6,by,'!',C(31,28,6));
 hud_overworld(f);
 dstr(96,224,"WHISPERING WOODS  -  NORTH GATE",C(14,16,22));
}

/* 3. Dialogue */
static void scene_dialogue(int f){
 scene_overworld(0);
 /* dim */
 for(int y=150;y<H;y++)for(int x=0;x<W;x++) if(((x+y)&1)==0) put(x,y,C(0,0,2));
 /* portrait */
 panel(8,150,52,52);
 fillr(12,154,44,44,C(10,6,14));
 npc(34,184,C(22,8,26),C(6,4,2));
 /* name + text box */
 panel(64,150,248,52);
 fillr(70,150,60,11,C(20,14,4)); dstr(76,153,"ELDER MIRA",C(4,3,1));
 dstr(72,168,"My family heirloom is lost in the",C(26,28,31));
 dstr(72,177,"Whispering Woods. Will you help",C(26,28,31));
 dstr(72,186,"an old woman, brave one?",C(26,28,31));
 /* choices */
 int sel=(f/24)%2;
 dch(74,194,sel==0?'>':' ',C(31,28,6));
 dstr(82,194,"I WILL FIND IT",sel==0?C(31,31,20):C(16,18,22));
 dch(200,194,sel==1?'>':' ',C(31,28,6));
 dstr(208,194,"NOT NOW",sel==1?C(31,31,20):C(16,18,22));
}

/* 4. Party / inventory menu */
static const char*items[]={"POTION","ETHER","HERB","IRON ORE","BRONZE SWORD","TOWN KEY"};
static const int   iqty[]={5,2,8,3,1,1};
static void scene_menu(int f){
 for(int y=0;y<H;y++){uint16_t c=C(2,2,7+y/40);for(int x=0;x<W;x++)fb[y*stride_px+x]=c;}
 /* left: party */
 panel(6,6,150,150);
 dstr(14,12,"PARTY",C(28,31,20));
 fillr(12,22,138,1,C(16,18,28));
 /* Aria card */
 fillr(12,28,138,40,C(5,7,16));
 npc(28,52,C(8,16,28),C(18,10,4));
 dstr(46,30,"ARIA",C(31,31,31)); dstr(100,30,"LV 4",C(20,28,31));
 dstr(46,40,"KNIGHT",C(16,18,24));
 dstr(46,50,"HP",C(20,28,31)); bar(62,50,80,28,32,C(8,28,10));
 dstr(46,58,"MP",C(20,28,31)); bar(62,58,80,9,12,C(10,18,31));
 /* Loras card */
 fillr(12,72,138,40,C(5,7,16));
 npc(28,96,C(18,8,26),C(8,6,3));
 dstr(46,74,"LORAS",C(31,31,31)); dstr(100,74,"LV 3",C(20,28,31));
 dstr(46,84,"MAGE",C(16,18,24));
 dstr(46,94,"HP",C(20,28,31)); bar(62,94,80,18,24,C(8,28,10));
 dstr(46,102,"MP",C(20,28,31)); bar(62,102,80,22,24,C(10,18,31));
 dstr(14,120,"GOLD",C(28,24,6)); dnum(50,120,150,4,C(31,31,31));
 dstr(14,132,"PLAYTIME 00:42",C(16,18,24));
 /* right: inventory */
 panel(162,6,152,150);
 dstr(170,12,"ITEMS",C(28,31,20));
 fillr(168,22,138,1,C(16,18,28));
 int sel=(f/18)%6;
 for(int i=0;i<6;i++){
   int yy=28+i*18;
   if(i==sel){fillr(168,yy-2,140,16,C(10,16,30)); dch(170,yy+2,'>',C(31,28,6));}
   dstr(180,yy+2,items[i],i==sel?C(31,31,31):C(20,22,28));
   dch(286,yy+2,':',C(16,18,24)); dnum(292,yy+2,iqty[i],2,C(28,24,6));
 }
 dstr(168,140,"USE   DROP   SORT",C(16,18,24));
 (void)f;
}

/* 5. Quest log */
static void scene_quests(int f){
 for(int y=0;y<H;y++){uint16_t c=C(2,2,7+y/40);for(int x=0;x<W;x++)fb[y*stride_px+x]=c;}
 panel(8,8,304,224);
 dstr2(20,16,"QUEST LOG",C(28,31,20));
 fillr(16,36,290,1,C(16,18,28));
 /* active quest */
 fillr(16,44,290,64,C(5,8,18));
 dch(22,50,'!',C(31,28,6)); dstr(32,50,"THE MISSING HEIRLOOM",C(31,31,31));
 dstr(32,62,"Elder Mira lost her locket.",C(18,20,26));
 dstr(28,76,"DONE  SPEAK WITH ELDER MIRA",C(10,26,12));
 dch(30,86,'>',C(31,28,6));
 dstr(40,86,"FIND THE HEIRLOOM IN THE WOODS",C(28,28,12));
 dstr(40,96,"RETURN THE HEIRLOOM TO MIRA",C(12,14,20));
 dstr(220,50,"REWARD",C(28,24,6));
 dstr(220,62,"150 G",C(31,31,31));
 dstr(220,72,"IRON SWORD",C(20,28,31));
 /* second quest */
 fillr(16,116,290,40,C(5,8,18));
 dch(22,122,'!',C(28,18,6)); dstr(32,122,"SLIME CLEANUP",C(31,31,31));
 dstr(32,134,"Clear the slimes near the well.",C(18,20,26));
 dstr(28,144,"DEFEAT SLIMES",C(28,28,12));
 dstr(160,144,"3 / 5",C(31,31,31));
 bar(196,145,100,3,5,C(8,28,10));
 dstr(16,170,"COMPLETED",C(16,18,24));
 dstr(28,182,"WELCOME TO RIVERDALE",C(10,20,12));
 dstr(28,192,"A GIFT FOR BRAM",C(10,20,12));
 (void)f;
}

/* 6. Shop */
static const char*shop_items[]={"POTION","ETHER","HERB","BRONZE SWORD","LEATHER ARMOR"};
static const int   shop_price[]={25,60,5,80,70};
static void scene_shop(int f){
 scene_overworld(0);
 for(int y=0;y<H;y++)for(int x=0;x<W;x++) if(((x+y)&1)==0) put(x,y,C(0,0,2));
 panel(8,8,304,150);
 fillr(14,12,120,11,C(20,14,4)); dstr(20,15,"GENERAL STORE",C(4,3,1));
 dstr(220,15,"GOLD",C(28,24,6)); dnum(256,15,150,4,C(31,31,31));
 fillr(14,28,296,1,C(16,18,28));
 int sel=(f/20)%5;
 for(int i=0;i<5;i++){int yy=36+i*20;
   if(i==sel){fillr(14,yy-2,296,18,C(10,16,30)); dch(18,yy+2,'>',C(31,28,6));}
   dstr(28,yy+2,shop_items[i],i==sel?C(31,31,31):C(20,22,28));
   dstr(220,yy+2,"PRICE",C(16,18,24)); dnum(258,yy+2,shop_price[i],4,C(28,24,6));
 }
 /* shopkeeper + description box */
 panel(8,162,304,70);
 npc(34,200,C(8,20,12),C(18,12,4));
 dstr(60,170,"BRAM",C(28,31,20));
 dstr(60,184,"\"A potion heals 30 HP -",C(24,26,31));
 dstr(60,194,"can't adventure without one!\"",C(24,26,31));
 dstr(60,212,"BUY      SELL      LEAVE",C(16,18,24));
 (void)f;
}

/* 7. Crafting */
static void scene_craft(int f){
 for(int y=0;y<H;y++){uint16_t c=C(7+y/40,4,3);for(int x=0;x<W;x++)fb[y*stride_px+x]=c;}
 panel(8,8,304,224);
 dstr2(20,16,"FORGE",C(31,24,8));
 dstr(150,20,"CRAFTING BENCH",C(20,18,14));
 fillr(16,36,290,1,C(20,14,8));
 /* recipe list */
 dstr(20,44,"RECIPES",C(28,24,6));
 int sel=(f/24)%2;
 const char*rec[]={"BREW POTION","FORGE IRON SWORD"};
 for(int i=0;i<2;i++){int yy=56+i*16;
   if(i==sel){fillr(16,yy-2,140,14,C(20,12,8)); dch(20,yy+1,'>',C(31,28,6));}
   dstr(30,yy+1,rec[i],i==sel?C(31,31,31):C(22,20,16));
 }
 fillr(160,44,1,150,C(20,14,8));
 /* selected recipe detail: forge iron sword */
 dstr(174,44,"FORGE IRON SWORD",C(31,31,31));
 dstr(174,60,"REQUIRES",C(28,24,6));
 dstr(184,74,"IRON ORE",C(20,22,28));  dstr(280,74,"3",C(10,26,12));
 dstr(184,84,"BRONZE SWORD",C(20,22,28)); dstr(280,84,"1",C(10,26,12));
 dstr(174,104,"PRODUCES",C(28,24,6));
 /* sword icon */
 fillr(184,118,3,18,C(26,28,31)); fillr(180,134,11,3,C(16,12,6));
 fillr(184,116,3,3,C(31,31,28));
 dstr(200,122,"IRON SWORD",C(31,31,31));
 dstr(200,132,"ATK +9",C(20,28,31));
 if((f/16)%2==0){fillr(180,160,120,18,C(8,22,8)); frame_rect(180,160,120,18,C(16,31,16));
   dstr(196,166,"CRAFT  -  READY",C(31,31,31));}
 else { frame_rect(180,160,120,18,C(12,18,12)); dstr(196,166,"CRAFT  -  READY",C(18,24,18)); }
 /* anvil at bottom */
 fillr(40,150,80,10,C(10,10,14)); fillr(60,160,40,30,C(8,8,12));
 fillr(30,148,100,4,C(14,14,18));
 int sp=(f>>2)&3; if(sp<2){disc(80,146,2+sp,C(31,28,6)); put(78,144,C(31,16,4));}
}

/* 8. Action combat (woods) */
static void woods_bg(int f){
 for(int y=0;y<H;y++){uint16_t c=C(3,9+y/40,4);for(int x=0;x<W;x++)fb[y*stride_px+x]=c;}
 /* scattered trees + river */
 for(int i=0;i<7;i++){int tx=(i*47+13)%W,ty=20+(i*53)%180;
   disc(tx,ty,10,C(2,9,3)); disc(tx,ty-4,7,C(4,13,5)); fillr(tx-1,ty+8,3,8,C(10,6,2));}
 for(int y=0;y<H;y++){int rx=70+isin(y/6+f/8)*8/31;fillr(rx,y,10,1,((y+f/4)&7)<4?C(5,12,28):C(4,10,24));}
}
static void scene_action(int f){
 woods_bg(f);
 int hx=150,hy=130;
 /* sword swing arc */
 int sw=(f%40); if(sw<10){ for(int a=-6;a<=6;a++){int ax=hx+12+a, ay=hy-6+(a*a)/8;
   put(ax,ay,C(28,30,31)); put(ax,ay+1,C(18,24,31)); } disc(hx+16,hy-2,3,C(31,31,28)); }
 hero(hx,hy,3,(f>>3)&1);
 /* enemies */
 slime(220,90,f); bar(208,76,24,8,14,C(31,6,6));
 slime(250,150,f+8); bar(238,136,24,14,14,C(31,6,6));
 goblin(245,118); bar(233,102,24,18,26,C(31,6,6));
 /* damage number popping */
 if((f%40)<18){ dstr(196,64-(f%40),"12",C(31,28,8)); }
 /* hit spark */
 if(sw<8){disc(206,84,3+sw,C(31,24,6)); disc(206,84,1,C(31,31,31));}
 /* projectile from goblin */
 int px=245-((f*3)%90); disc(px,118,2,C(31,12,4));
 /* hud */
 panel(4,4,120,26);
 dstr(10,8,"ARIA",C(28,31,20)); dstr(10,17,"HP",C(20,28,31)); bar(28,17,84,26,32,C(8,28,10));
 dstr(W-92,8,"WHISPERING WOODS",C(18,22,18));
 dstr(W-70,200,"A   ATTACK",C(20,24,28));
 dstr(W-70,210,"B   MAGIC",C(20,24,28));
}

/* 9. Turn-based battle */
static void scene_battle(int f){
 /* dramatic backdrop */
 for(int y=0;y<H;y++){uint16_t c=C(4+y/30,2,8+y/24);for(int x=0;x<W;x++)fb[y*stride_px+x]=c;}
 for(int i=0;i<30;i++){int x=(i*101+f)%W;put(x,(i*37)%150,C(16,12,24));}
 /* enemy party up top */
 goblin(120,70); bar(104,50,40,26,30,C(31,6,6)); dstr(104,42,"GOBLIN",C(28,18,18));
 goblin(200,84); bar(184,64,40,18,30,C(31,6,6));
 slime(255,72,f); bar(240,52,30,14,14,C(31,6,6));
 /* hero party (backs) lower-left */
 hero(70,150,1,0);
 npc(110,160,C(18,8,26),C(8,6,3));
 /* active turn marker */
 if((f>>3)&1) dch(64,128,'!',C(31,28,6));
 /* command window */
 panel(6,176,150,58);
 int sel=(f/16)%4;
 const char*cmd[]={"FIGHT","SKILL","ITEM","RUN"};
 for(int i=0;i<4;i++){int cx=14+(i%2)*72, cy=184+(i/2)*22;
   if(i==sel){fillr(cx-4,cy-2,70,16,C(10,16,30)); dch(cx-2,cy+2,'>',C(31,28,6));}
   dstr(cx+8,cy+2,cmd[i],i==sel?C(31,31,20):C(20,22,28));
 }
 /* party status window */
 panel(160,176,154,58);
 dstr(168,182,"ARIA",C(31,31,31));
 dstr(168,192,"HP",C(20,28,31)); bar(184,192,60,26,32,C(8,28,10)); dnum(248,191,26,2,C(20,28,31));
 dstr(168,200,"MP",C(20,28,31)); bar(184,200,60,9,12,C(10,18,31)); dnum(248,199,9,2,C(20,28,31));
 dstr(168,210,"LORAS",C(31,31,31));
 dstr(168,220,"HP",C(20,28,31)); bar(184,220,60,18,24,C(8,28,10)); dnum(248,219,18,2,C(20,28,31));
 dstr(254,182,"TURN 3",C(28,24,6));
 /* message line */
 panel(6,158,308,16);
 dstr(12,162,"ARIA ATTACKS!  GOBLIN TAKES 14 DAMAGE!",C(28,30,31));
}

/* 10. Boss */
static void scene_boss(int f){
 woods_bg(f);
 for(int y=0;y<H;y++)for(int x=0;x<W;x++) if(((x*3+y)&7)==0) put(x,y,C(0,2,0));
 warden(160,96,f);
 /* boss hp */
 panel(40,12,240,18);
 dstr(46,16,"FOREST WARDEN",C(31,8,8));
 bar(120,17,150,84,120,((f>>3)&1)?C(31,4,4):C(24,0,0));
 /* hero + mage casting */
 hero(90,200,1,(f>>3)&1);
 npc(140,205,C(18,8,26),C(8,6,3));
 /* fireball from mage toward boss */
 int fx=140+((f*4)%80), fy=205-((f*4)%110);
 disc(fx,fy,4,C(31,18,2)); disc(fx,fy,2,C(31,31,20));
 for(int t=1;t<4;t++) disc(fx-t*4,fy+t*5,3-t/2,C(31,10,2));
 /* boss attack: falling thorns */
 for(int i=0;i<5;i++){int tx=70+i*45,ty=(f*3+i*40)%150+40;
   fillr(tx,ty,2,6,C(14,20,8)); put(tx,ty+6,C(20,28,10));}
 /* impact spark on boss */
 if((f%30)<8){disc(150,96,4+(f%30),C(31,24,6));}
 dstr(96,224,"A HUGE BATTLE  -  GIVE IT EVERYTHING!",C(28,20,20));
}

int main(void){
 display_init(0,2,3,0,1);
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
