#!/usr/bin/env python3
"""
make_assets.py — Generate libdragon .sprite binary files for a retro N64 platformer.

Libdragon sprite format:
  - 8-byte header: width (>H), height (>H), bitdepth (B), flags (B), hslices (B), vslices (B)
  - Raw pixel data in RGBA5551 big-endian (2 bytes per pixel)

flags = 2  → FMT_RGBA16 (RGBA5551)
bitdepth = 2 (bytes per pixel)
"""

import struct
import os

OUT_DIR = "/tmp/platformer_assets/sprites"
os.makedirs(OUT_DIR, exist_ok=True)
os.makedirs("/tmp/platformer_assets/audio", exist_ok=True)

# ---------------------------------------------------------------------------
# Core helper
# ---------------------------------------------------------------------------

TRANSPARENT = (0, 0, 0, 0)

def make_sprite(pixels_rgba8888, width, height):
    """Convert a flat list of (r,g,b,a) tuples → libdragon .sprite bytes."""
    assert len(pixels_rgba8888) == width * height, (
        f"Expected {width*height} pixels, got {len(pixels_rgba8888)}"
    )
    pixel_bytes = bytearray()
    for r, g, b, a in pixels_rgba8888:
        r5 = (r >> 3) & 0x1F
        g5 = (g >> 3) & 0x1F
        b5 = (b >> 3) & 0x1F
        a1 = 1 if a > 127 else 0
        word = (r5 << 11) | (g5 << 6) | (b5 << 1) | a1
        pixel_bytes += struct.pack('>H', word)
    header  = struct.pack('>HH', width, height)
    header += struct.pack('BBBB', 2, 2, 1, 1)   # bitdepth=2, flags=FMT_RGBA16, hslices=1, vslices=1
    return header + bytes(pixel_bytes)

def save_sprite(name, pixels, width, height):
    path = os.path.join(OUT_DIR, name)
    data = make_sprite(pixels, width, height)
    with open(path, 'wb') as f:
        f.write(data)
    print(f"  {name:30s}  {len(data):5d} bytes  ({width}x{height})")
    return path

def grid(rows):
    """Flatten a list-of-rows (each row = list of colour tuples) into a flat pixel list."""
    pixels = []
    for row in rows:
        pixels.extend(row)
    return pixels

# ---------------------------------------------------------------------------
# Colour palette helpers
# ---------------------------------------------------------------------------

T  = TRANSPARENT

# Basic palette
W  = (255, 255, 255, 255)   # white
K  = (0,   0,   0,   255)   # black
R  = (200, 40,  40,  255)   # red
G  = (50,  180, 50,  255)   # green
B  = (50,  80,  220, 255)   # blue
LB = (120, 160, 255, 255)   # light blue
Y  = (255, 210, 0,   255)   # yellow
O  = (240, 120, 20,  255)   # orange
C  = (0,   220, 220, 255)   # cyan
P  = (130, 50,  200, 255)   # purple
Br = (140, 90,  40,  255)   # brown
Tn = (200, 165, 100, 255)   # tan
Dk = (30,  30,  30,  255)   # very dark (mortar)
Gy = (150, 150, 150, 255)   # grey
DGn= (20,  100, 20,  255)   # dark green
DR = (140, 20,  20,  255)   # dark red
Gd = (255, 195, 0,   255)   # gold
DGd= (180, 130, 0,   255)   # dark gold
Pk = (240, 200, 160, 255)   # skin/peach
LGn= (100, 220, 100, 255)   # light green
Sn = (255, 220, 170, 255)   # sand highlight
Nv = (10,  10,  80,  255)   # navy / dark sky
St = (240, 240, 255, 255)   # star white

# ---------------------------------------------------------------------------
# player.sprite  16x24 — blue hero, standing pose
# ---------------------------------------------------------------------------

def make_player():
    # 16 columns, 24 rows
    # Row 0-3  : head (flesh + hair)
    # Row 4    : neck
    # Row 5-9  : torso (blue shirt)
    # Row 10-12: belt area
    # Row 13-17: legs
    # Row 18-23: feet/shoes
    _ = T
    h = Pk           # skin
    H = (190, 140, 70,255)  # hair (darker brown)
    S = B            # shirt blue
    Bl= (30, 50, 150,255)   # dark blue (pants)
    sh= (60, 60, 60, 255)   # shoe dark
    e = K            # eye
    m = R            # mouth

    rows = [
        # 0  1  2  3  4  5  6  7  8  9 10 11 12 13 14 15
        [_,_,_,_,_,_,H,H,H,H,_,_,_,_,_,_],   # 0
        [_,_,_,_,_,H,H,H,H,H,H,_,_,_,_,_],   # 1
        [_,_,_,_,_,H,h,h,h,h,H,_,_,_,_,_],   # 2
        [_,_,_,_,_,h,h,e,h,h,h,h,_,_,_,_],   # 3  eyes offset
        [_,_,_,_,_,h,h,h,h,h,h,h,_,_,_,_],   # 4  nose row
        [_,_,_,_,_,h,h,m,m,h,h,h,_,_,_,_],   # 5  mouth
        [_,_,_,_,_,h,h,h,h,h,h,h,_,_,_,_],   # 6  chin
        [_,_,_,_,S,S,S,S,S,S,S,S,S,_,_,_],   # 7  shoulders
        [_,_,_,S,S,S,S,S,S,S,S,S,S,S,_,_],   # 8  chest
        [_,_,_,S,S,S,S,S,S,S,S,S,S,S,_,_],   # 9
        [_,_,_,S,S,S,S,S,S,S,S,S,S,S,_,_],   # 10
        [_,_,_,S,S,S,S,S,S,S,S,S,S,S,_,_],   # 11
        [_,_,_,S,h,h,S,S,S,S,h,h,S,S,_,_],   # 12 arms visible
        [_,_,_,S,h,h,S,S,S,S,h,h,S,S,_,_],   # 13
        [_,_,_,_,_,Bl,Bl,Bl,Bl,Bl,_,_,_,_,_,_],  # 14 belt
        [_,_,_,_,Bl,Bl,_,_,Bl,Bl,_,_,_,_,_,_],   # 15
        [_,_,_,_,Bl,Bl,_,_,Bl,Bl,_,_,_,_,_,_],   # 16
        [_,_,_,_,Bl,Bl,_,_,Bl,Bl,_,_,_,_,_,_],   # 17
        [_,_,_,_,Bl,Bl,_,_,Bl,Bl,_,_,_,_,_,_],   # 18
        [_,_,_,_,Bl,Bl,_,_,Bl,Bl,_,_,_,_,_,_],   # 19
        [_,_,_,_,sh,sh,_,_,sh,sh,_,_,_,_,_,_],   # 20 shoes
        [_,_,_,sh,sh,sh,_,_,sh,sh,sh,_,_,_,_,_], # 21
        [_,_,_,sh,sh,sh,_,_,sh,sh,sh,_,_,_,_,_], # 22
        [_,_,sh,sh,sh,sh,_,_,sh,sh,sh,sh,_,_,_,_],# 23
    ]
    assert all(len(r) == 16 for r in rows), "player row length mismatch"
    return grid(rows), 16, 24

# ---------------------------------------------------------------------------
# enemy_patrol.sprite  16x16 — red goblin with horns
# ---------------------------------------------------------------------------

def make_enemy_patrol():
    _ = T
    r = R
    d = DR
    e = Y            # angry yellow eyes
    k = K
    hn= (180, 80, 20,255)   # horn colour (dark orange)

    rows = [
        [_,_,_,hn,_,_,_,_,_,_,hn,_,_,_,_,_],  # 0 horn tips
        [_,_,hn,hn,_,_,_,_,_,hn,hn,_,_,_,_,_],  # 1
        [_,_,hn,_,d,d,d,d,d,d,_,hn,_,_,_,_],  # 2
        [_,_,_,d,d,d,d,d,d,d,d,_,_,_,_,_],    # 3 head top
        [_,_,d,r,r,r,r,r,r,r,r,d,_,_,_,_],    # 4
        [_,_,r,r,e,e,r,r,e,e,r,r,_,_,_,_],    # 5 eyes
        [_,_,r,r,k,k,r,r,k,k,r,r,_,_,_,_],    # 6 pupils
        [_,_,r,r,r,k,k,k,k,r,r,r,_,_,_,_],    # 7 angry brow
        [_,_,r,r,r,r,r,r,r,r,r,r,_,_,_,_],    # 8
        [_,_,r,r,k,r,r,r,r,k,r,r,_,_,_,_],    # 9 nostrils
        [_,_,r,k,k,k,r,r,k,k,k,r,_,_,_,_],    # 10 teeth
        [_,_,d,r,r,r,d,d,r,r,r,d,_,_,_,_],    # 11 chin
        [_,_,_,d,r,r,r,r,r,r,d,_,_,_,_,_],    # 12 neck
        [_,_,d,d,d,d,d,d,d,d,d,d,_,_,_,_],    # 13 body
        [_,_,d,d,_,_,_,_,_,_,d,d,_,_,_,_],    # 14 legs
        [_,_,d,d,_,_,_,_,_,_,d,d,_,_,_,_],    # 15
    ]
    assert all(len(r) == 16 for r in rows)
    return grid(rows), 16, 16

# ---------------------------------------------------------------------------
# enemy_jumper.sprite  16x16 — orange bouncy blob with big feet
# ---------------------------------------------------------------------------

def make_enemy_jumper():
    _ = T
    o = O
    do= (180, 80, 10, 255)  # dark orange
    e = W
    k = K
    ft= (220, 100, 10, 255) # foot orange

    rows = [
        [_,_,_,_,do,do,do,do,do,do,_,_,_,_,_,_],  # 0
        [_,_,_,do,o,o,o,o,o,o,do,_,_,_,_,_],       # 1
        [_,_,do,o,o,o,o,o,o,o,o,do,_,_,_,_],       # 2
        [_,_,o,o,e,e,o,o,e,e,o,o,_,_,_,_],         # 3 eyes
        [_,_,o,o,k,k,o,o,k,k,o,o,_,_,_,_],         # 4 pupils
        [_,_,o,o,o,o,o,o,o,o,o,o,_,_,_,_],         # 5
        [_,_,o,o,o,k,k,k,k,o,o,o,_,_,_,_],         # 6 smile
        [_,_,o,o,k,o,o,o,o,k,o,o,_,_,_,_],         # 7 smile corners
        [_,_,do,o,o,o,o,o,o,o,o,do,_,_,_,_],       # 8
        [_,_,_,do,do,o,o,o,o,do,do,_,_,_,_,_],     # 9
        [_,_,_,_,do,do,do,do,do,do,_,_,_,_,_,_],   # 10 body bottom
        [_,_,_,do,do,_,do,do,do,_,do,do,_,_,_,_],  # 11 feet start
        [_,_,do,ft,do,_,_,_,_,_,do,ft,do,_,_,_],   # 12
        [_,do,ft,ft,ft,_,_,_,_,ft,ft,ft,do,_,_,_], # 13 big feet
        [_,do,ft,ft,ft,_,_,_,_,ft,ft,ft,do,_,_,_], # 14
        [_,do,do,do,do,_,_,_,_,do,do,do,do,_,_,_], # 15
    ]
    assert all(len(r) == 16 for r in rows)
    return grid(rows), 16, 16

# ---------------------------------------------------------------------------
# coin.sprite  8x8 — gold spinning coin
# ---------------------------------------------------------------------------

def make_coin():
    _ = T
    g = Gd
    d = DGd
    w = (255, 240, 180, 255)  # highlight

    rows = [
        [_,_,d,g,g,d,_,_],
        [_,d,g,w,g,g,d,_],
        [d,g,w,g,g,g,g,d],
        [d,g,w,g,g,g,g,d],
        [d,g,g,g,g,g,g,d],
        [d,g,g,g,g,g,g,d],
        [_,d,g,g,g,g,d,_],
        [_,_,d,d,d,d,_,_],
    ]
    assert all(len(r) == 8 for r in rows)
    return grid(rows), 8, 8

# ---------------------------------------------------------------------------
# spring.sprite  12x8 — green coil spring
# ---------------------------------------------------------------------------

def make_spring():
    _ = T
    g = G
    d = DGn
    y = Y

    rows = [
        [_,y,y,y,y,y,y,y,y,y,y,_],  # 0 top plate (yellow)
        [_,d,d,d,d,d,d,d,d,d,d,_],  # 1
        [d,g,g,_,_,g,g,_,_,g,g,d],  # 2 coil row A
        [d,g,_,_,g,g,_,_,g,g,_,d],  # 3 coil row B
        [d,g,g,_,_,g,g,_,_,g,g,d],  # 4 coil row C
        [d,g,_,_,g,g,_,_,g,g,_,d],  # 5 coil row D
        [_,d,d,d,d,d,d,d,d,d,d,_],  # 6 base top
        [_,d,d,d,d,d,d,d,d,d,d,_],  # 7 base bottom
    ]
    assert all(len(r) == 12 for r in rows)
    return grid(rows), 12, 8

# ---------------------------------------------------------------------------
# checkpoint.sprite  8x16 — cyan flag on a post
# ---------------------------------------------------------------------------

def make_checkpoint():
    _ = T
    p = Gy           # post grey
    c = C            # flag cyan
    dc= (0, 160, 160, 255)   # dark cyan

    rows = [
        [_,_,p,c,c,c,c,_],  # 0 flag top
        [_,_,p,c,dc,c,c,_],  # 1
        [_,_,p,c,c,c,_,_],  # 2
        [_,_,p,c,dc,_,_,_],  # 3
        [_,_,p,_,_,_,_,_],  # 4
        [_,_,p,_,_,_,_,_],  # 5
        [_,_,p,_,_,_,_,_],  # 6
        [_,_,p,_,_,_,_,_],  # 7
        [_,_,p,_,_,_,_,_],  # 8
        [_,_,p,_,_,_,_,_],  # 9
        [_,_,p,_,_,_,_,_],  # 10
        [_,_,p,_,_,_,_,_],  # 11
        [_,_,p,_,_,_,_,_],  # 12
        [_,p,p,p,_,_,_,_],  # 13 base
        [p,p,p,p,p,_,_,_],  # 14
        [p,p,p,p,p,_,_,_],  # 15
    ]
    assert all(len(r) == 8 for r in rows)
    return grid(rows), 8, 16

# ---------------------------------------------------------------------------
# goal.sprite  16x16 — white glowing star
# ---------------------------------------------------------------------------

def make_goal():
    _ = T
    s = W
    y = Y
    g = (220, 220, 255, 255)  # slight blue-white glow
    c = C

    rows = [
        [_,_,_,_,_,_,_,y,y,_,_,_,_,_,_,_],  # 0 top tip
        [_,_,_,_,_,_,_,s,s,_,_,_,_,_,_,_],  # 1
        [_,_,_,_,_,g,g,s,s,g,g,_,_,_,_,_],  # 2
        [_,y,_,_,g,g,s,s,s,s,g,g,_,_,y,_],  # 3 side tips
        [_,s,s,g,g,s,s,s,s,s,s,g,g,s,s,_],  # 4
        [_,_,s,s,s,s,s,s,s,s,s,s,s,s,_,_],  # 5
        [_,_,_,g,s,s,s,s,s,s,s,s,g,_,_,_],  # 6
        [_,_,_,_,s,s,c,s,s,c,s,s,_,_,_,_],  # 7 sparkle
        [_,_,_,_,s,s,s,c,c,s,s,s,_,_,_,_],  # 8
        [_,_,_,g,s,s,s,s,s,s,s,s,g,_,_,_],  # 9
        [_,_,s,s,s,s,s,s,s,s,s,s,s,s,_,_],  # 10
        [_,y,s,g,g,s,s,s,s,s,s,g,g,s,y,_],  # 11 side tips
        [_,_,_,_,g,g,s,s,s,s,g,g,_,_,_,_],  # 12
        [_,_,_,_,_,_,s,s,s,s,_,_,_,_,_,_],  # 13 bottom v-notch
        [_,_,_,_,_,_,y,_,_,y,_,_,_,_,_,_],  # 14
        [_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_],  # 15
    ]
    assert all(len(r) == 16 for r in rows)
    return grid(rows), 16, 16

# ---------------------------------------------------------------------------
# tile_solid.sprite  16x16 — brown brick with mortar lines
# ---------------------------------------------------------------------------

def make_tile_solid():
    _ = T
    b = Br
    t = Tn
    m = Dk
    h = (210, 175, 110, 255)  # highlight tan

    # horizontal mortar at rows 0, 7, 8, 15
    # vertical mortar: offset by 8 in alternate rows
    def brick_row(y, offset):
        row = []
        for x in range(16):
            if y == 0 or y == 15:
                row.append(m)
            elif y == 7 or y == 8:
                row.append(m)
            else:
                # vertical mortar
                col_in_brick = (x - offset) % 8
                if col_in_brick == 0:
                    row.append(m)
                elif col_in_brick == 1 or (y == 1 and col_in_brick < 3):
                    row.append(h if col_in_brick <= 1 else t)
                else:
                    row.append(t if col_in_brick < 5 else b)
        return row

    rows = []
    for y in range(16):
        if y <= 7:
            off = 0
        else:
            off = 4   # stagger second course
        rows.append(brick_row(y, off))
    return grid(rows), 16, 16

# ---------------------------------------------------------------------------
# tile_oneway.sprite  16x8 — green one-way platform
# ---------------------------------------------------------------------------

def make_tile_oneway():
    _ = T
    g  = G
    dg = DGn
    lg = LGn
    k  = K

    rows = [
        [k,k,k,k,k,k,k,k,k,k,k,k,k,k,k,k],  # 0 dark top edge
        [lg,lg,lg,lg,lg,lg,lg,lg,lg,lg,lg,lg,lg,lg,lg,lg],  # 1 highlight
        [g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g],   # 2
        [g,g,g,g,g,g,g,g,g,g,g,g,g,g,g,g],   # 3
        [dg,dg,g,dg,dg,g,dg,dg,g,dg,dg,g,dg,dg,g,dg],  # 4 grass tufts pattern
        [_,dg,_,_,dg,_,_,dg,_,_,dg,_,_,dg,_,_],        # 5
        [_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_],  # 6 transparent
        [_,_,_,_,_,_,_,_,_,_,_,_,_,_,_,_],  # 7 transparent
    ]
    assert all(len(r) == 16 for r in rows)
    return grid(rows), 16, 8

# ---------------------------------------------------------------------------
# tile_hazard.sprite  16x16 — red spike tile
# ---------------------------------------------------------------------------

def make_tile_hazard():
    _ = T
    r  = R
    dr = DR
    y  = Y
    k  = K

    # Base is dark red, spikes pointing up in bright red/yellow
    def spike_row(y_idx):
        row = []
        # 4 spikes of width 4 each
        for x in range(16):
            spike_pos = x % 4          # 0..3 within each spike
            spike_num = x // 4         # which spike 0..3
            tip_row   = 2 + spike_num  # each spike tip row slightly staggered
            if y_idx < tip_row:
                row.append(_)
            elif y_idx == tip_row:
                row.append(y if spike_pos == 1 or spike_pos == 2 else _)
            elif y_idx < tip_row + 3:
                depth = y_idx - tip_row
                margin = depth
                if margin <= spike_pos <= 3 - margin:
                    row.append(r if spike_pos != 0 else dr)
                else:
                    row.append(_)
            else:
                row.append(dr)
        return row

    rows = [spike_row(i) for i in range(8)]
    # bottom half: flat red base
    for i in range(8):
        row = [dr if i == 0 else r] * 16
        rows.append(row)
    assert all(len(r) == 16 for r in rows)
    return grid(rows), 16, 16

# ---------------------------------------------------------------------------
# tile_ladder.sprite  16x16 — yellow ladder
# ---------------------------------------------------------------------------

def make_tile_ladder():
    _ = T
    y  = Y
    dy = (180, 140, 0, 255)  # dark yellow
    bg = (20, 10, 60, 120)   # semi-transparent dark bg

    rows = []
    for row_idx in range(16):
        row = []
        for col_idx in range(16):
            # Two vertical rails at x=2,3 and x=12,13
            if col_idx in (2, 3, 12, 13):
                row.append(dy if col_idx in (3, 13) else y)
            # Rungs every 4 rows
            elif row_idx % 4 in (0, 1):
                if 3 <= col_idx <= 12:
                    row.append(dy if col_idx == 3 or col_idx == 12 else y)
                else:
                    row.append(_)
            else:
                row.append(_)
        rows.append(row)
    assert all(len(r) == 16 for r in rows)
    return grid(rows), 16, 16

# ---------------------------------------------------------------------------
# background.sprite  64x64 — dark night sky with stars and a moon
# ---------------------------------------------------------------------------

def make_background():
    import random
    random.seed(42)

    sky_top    = (8,  6,  48, 255)
    sky_bot    = (18, 12, 72, 255)
    star_c     = (240, 240, 255, 255)
    star_dim   = (150, 150, 200, 255)
    moon_c     = (240, 230, 180, 255)
    moon_shd   = (200, 190, 130, 255)
    moon_dark  = (30,  25,  60, 255)  # "shadow" on moon
    cloud_c    = (50,  40,  100, 200) # translucent wisp

    pixels = []
    for y in range(64):
        for x in range(64):
            # gradient sky
            t = y / 63.0
            sr = int(sky_top[0] * (1-t) + sky_bot[0] * t)
            sg = int(sky_top[1] * (1-t) + sky_bot[1] * t)
            sb = int(sky_top[2] * (1-t) + sky_bot[2] * t)
            px = (sr, sg, sb, 255)

            # Moon: centred at (48, 12), radius 7
            mx, my = 48, 12
            dist_moon = ((x - mx)**2 + (y - my)**2) ** 0.5
            if dist_moon <= 7:
                # Crescent shadow (offset circle)
                shadow_cx, shadow_cy = mx + 3, my - 2
                in_shadow = ((x - shadow_cx)**2 + (y - shadow_cy)**2) ** 0.5 <= 6
                px = moon_dark if in_shadow else (moon_c if dist_moon <= 6 else moon_shd)

            # Stars — deterministic scatter
            cell_x = x // 4
            cell_y = y // 4
            cell_hash = (cell_x * 31 + cell_y * 97 + cell_x * cell_y * 7) % 100
            star_ox = (cell_x * 31 + cell_y * 17) % 4
            star_oy = (cell_x * 13 + cell_y * 41) % 4
            if cell_hash < 18 and x % 4 == star_ox and y % 4 == star_oy:
                if dist_moon > 9:  # don't paint stars over moon
                    px = star_c if cell_hash < 6 else star_dim

            # Tiny extra sparkle stars at pixel level
            pix_hash = (x * 73 + y * 137 + x * y) % 512
            if pix_hash == 0 and dist_moon > 9:
                px = star_c

            # Wispy clouds in lower band (y 40-56)
            if 40 <= y <= 56:
                cloud_val = (x * 3 + y * 7) % 20
                if cloud_val < 3:
                    r2, g2, b2, a2 = cloud_c
                    # Blend over sky
                    alpha = a2 / 255.0
                    pr = int(px[0] * (1 - alpha) + r2 * alpha)
                    pg = int(px[1] * (1 - alpha) + g2 * alpha)
                    pb = int(px[2] * (1 - alpha) + b2 * alpha)
                    px = (pr, pg, pb, 255)

            pixels.append(px)
    return pixels, 64, 64

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

print("Generating platformer sprites...")
print(f"Output directory: {OUT_DIR}")
print()

sprites = [
    ("player.sprite",        make_player),
    ("enemy_patrol.sprite",  make_enemy_patrol),
    ("enemy_jumper.sprite",  make_enemy_jumper),
    ("coin.sprite",          make_coin),
    ("spring.sprite",        make_spring),
    ("checkpoint.sprite",    make_checkpoint),
    ("goal.sprite",          make_goal),
    ("tile_solid.sprite",    make_tile_solid),
    ("tile_oneway.sprite",   make_tile_oneway),
    ("tile_hazard.sprite",   make_tile_hazard),
    ("tile_ladder.sprite",   make_tile_ladder),
    ("background.sprite",    make_background),
]

total_bytes = 0
created = []
for name, fn in sprites:
    pixels, w, h = fn()
    path = save_sprite(name, pixels, w, h)
    sz = os.path.getsize(path)
    total_bytes += sz
    created.append((path, sz))

print()
print(f"Total sprites: {len(created)}")
print(f"Total bytes:   {total_bytes:,}")
print()
print("Audio directory: /tmp/platformer_assets/audio/ (reserved for future use)")
