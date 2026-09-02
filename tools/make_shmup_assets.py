#!/usr/bin/env python3
"""
Generate libdragon .sprite binary format files for a retro N64 space shoot-em-up.
"""

import struct
import os
import math

OUTPUT_DIR = "/tmp/shmup_assets/sprites"


def make_sprite(pixels_rgba8888, width, height):
    """pixels_rgba8888: list of (r,g,b,a) tuples, row-major"""
    pixel_bytes = bytearray()
    for r, g, b, a in pixels_rgba8888:
        r5 = (r >> 3) & 0x1F
        g5 = (g >> 3) & 0x1F
        b5 = (b >> 3) & 0x1F
        a1 = 1 if a > 127 else 0
        word = (r5 << 11) | (g5 << 6) | (b5 << 1) | a1
        pixel_bytes += struct.pack('>H', word)  # big-endian
    header = struct.pack('>HH', width, height)
    header += struct.pack('BBBB', 2, 2, 1, 1)  # bitdepth=2, flags=FMT_RGBA16=2, hslices=1, vslices=1
    return header + bytes(pixel_bytes)


TRANSPARENT = (0, 0, 0, 0)


def save_sprite(name, pixels, width, height):
    data = make_sprite(pixels, width, height)
    path = os.path.join(OUTPUT_DIR, name)
    with open(path, 'wb') as f:
        f.write(data)
    print(f"  {name}: {len(data)} bytes ({width}x{height})")
    return path


def grid(width, height, fn):
    """Build pixel list by calling fn(x, y) for each pixel."""
    return [fn(x, y) for y in range(height) for x in range(width)]


# ---------------------------------------------------------------------------
# ship.sprite  16x12  — Player fighter pointing RIGHT
# ---------------------------------------------------------------------------
def make_ship():
    W, H = 16, 12
    # Define the ship shape in a string grid (16 cols, 12 rows)
    # . = transparent
    # b = body (light blue-white)
    # B = bright body highlight
    # w = wing (darker blue-grey)
    # e = engine glow (orange-yellow)
    # c = cockpit (cyan highlight)
    art = [
        "................",  # row 0
        "......B.........",  # row 1
        ".....BBb........",  # row 2
        "....BBbb....eeee",  # row 3  <- nose points right (col 15)
        "wwwwBBBBBBbbeeee",  # row 4
        "wwwwBBBBBBBBeeee",  # row 5  <- center row
        "wwwwBBBBBBbbeeee",  # row 6
        "....BBbb....eeee",  # row 7
        ".....BBb........",  # row 8
        "......B.........",  # row 9
        "................",  # row 10
        "................",  # row 11
    ]

    color_map = {
        '.': TRANSPARENT,
        'B': (230, 240, 255, 255),   # bright body highlight
        'b': (160, 200, 240, 255),   # light blue body
        'w': (80,  110, 160, 255),   # dark wing
        'e': (255, 180,  40, 255),   # engine glow orange
        'c': (120, 230, 255, 255),   # cockpit cyan
    }

    pixels = []
    for y in range(H):
        for x in range(W):
            ch = art[y][x] if x < len(art[y]) else '.'
            pixels.append(color_map.get(ch, TRANSPARENT))

    save_sprite("ship.sprite", pixels, W, H)


# ---------------------------------------------------------------------------
# enemy_straight.sprite  14x12  — Red angular enemy pointing LEFT
# ---------------------------------------------------------------------------
def make_enemy_straight():
    W, H = 14, 12
    art = [
        "..............",  # row 0
        ".........R....",  # row 1
        "........RRr...",  # row 2
        "eeeee...RRRr..",  # row 3   <- nose at col 0 (left)
        "eeeeWWWRRRRRr.",  # row 4
        "eeeeWWWRRRRRRr",  # row 5   center
        "eeeeWWWRRRRRr.",  # row 6
        "eeeee...RRRr..",  # row 7
        "........RRr...",  # row 8
        ".........R....",  # row 9
        "..............",  # row 10
        "..............",  # row 11
    ]
    color_map = {
        '.': TRANSPARENT,
        'R': (220,  40,  40, 255),   # bright red body
        'r': (160,  20,  20, 255),   # dark red
        'W': (80,   80, 100, 255),   # dark wing
        'e': (255, 120,  40, 255),   # engine glow
    }
    pixels = [color_map.get(art[y][x] if x < len(art[y]) else '.', TRANSPARENT)
              for y in range(H) for x in range(W)]
    save_sprite("enemy_straight.sprite", pixels, W, H)


# ---------------------------------------------------------------------------
# enemy_sine.sprite  12x12  — Orange sine enemy, rounder, pointing LEFT
# ---------------------------------------------------------------------------
def make_enemy_sine():
    W, H = 12, 12
    # Rounder design with a bubble-like silhouette
    art = [
        "............",  # 0
        "....OOOO....",  # 1
        "...OOooOO...",  # 2
        "eeOOoooOOO..",  # 3
        "eeOooooooO..",  # 4
        "eeOooooooOO.",  # 5  center
        "eeOooooooO..",  # 6
        "eeOOoooOOO..",  # 7
        "...OOooOO...",  # 8
        "....OOOO....",  # 9
        "............",  # 10
        "............",  # 11
    ]
    color_map = {
        '.': TRANSPARENT,
        'O': (255, 140,  20, 255),   # bright orange outline
        'o': (220, 100,  10, 255),   # darker orange fill
        'e': (255, 220,  80, 255),   # yellow engine glow
    }
    pixels = [color_map.get(art[y][x] if x < len(art[y]) else '.', TRANSPARENT)
              for y in range(H) for x in range(W)]
    save_sprite("enemy_sine.sprite", pixels, W, H)


# ---------------------------------------------------------------------------
# enemy_turret.sprite  16x16  — Purple hexagonal ground turret, cannon up-right
# ---------------------------------------------------------------------------
def make_enemy_turret():
    W, H = 16, 16
    # Hex base rows 6-15, cannon rows 0-8 pointing up-right
    art = [
        "................",  # 0
        "..........PP....",  # 1  cannon barrel tip
        ".........PPP....",  # 2
        "........PPPp....",  # 3
        ".......PPPp.....",  # 4
        "......PPPp......",  # 5
        "......pppp......",  # 6
        "....pppppppp....",  # 7  hex base top
        "...ppppHpppp....",  # 8
        "..ppppHHHpppp...",  # 9
        "..ppppHHHpppp...",  # 10
        "..ppppHHHpppp...",  # 11
        "...ppppHpppp....",  # 12
        "....pppppppp....",  # 13
        "................",  # 14
        "................",  # 15
    ]
    color_map = {
        '.': TRANSPARENT,
        'P': (220, 180, 255, 255),   # bright purple cannon
        'p': (130,  60, 180, 255),   # dark purple base
        'H': (80,   30, 120, 255),   # very dark hub center
    }
    pixels = [color_map.get(art[y][x] if x < len(art[y]) else '.', TRANSPARENT)
              for y in range(H) for x in range(W)]
    save_sprite("enemy_turret.sprite", pixels, W, H)


# ---------------------------------------------------------------------------
# boss.sprite  32x24  — Massive dark boss ship pointing LEFT
# ---------------------------------------------------------------------------
def make_boss():
    W, H = 32, 24
    # 32 cols x 24 rows
    art = [
        "................................",  # 0
        "................................",  # 1
        "................DDDD............",  # 2
        "..............DDDDDDdd..........",  # 3
        "............DDDDDDDDDDdd........",  # 4
        "RRR.........DDDDDDDDDDDDdd......",  # 5  cannon 1
        "RRRR........DDDDDDDDDDDDDDdd....",  # 6
        "RRRRccccccccDDDDDDDDDDDDDDDDDD..",  # 7
        "RRRRccccccccccDDDDDDDDDDDDDDDDDD",  # 8  <- nose (col 0 = left)
        "RRRRccccccccccDDDDDDDDDDDDDDDDDD",  # 9  center
        "RRRRccccccccDDDDDDDDDDDDDDDDDD..",  # 10
        "RRRRccccccccDDDDDDDDDDDDDDDD....",  # 11
        "RRR.........DDDDDDDDDDDDdd......",  # 12  cannon 2
        "............DDDDDDDDDDdd........",  # 13
        "rrrr........DDDDDDDDdd..........",  # 14  cannon 3 (smaller)
        "rrrr........DDDDDDDdd..eeeeeeeee",  # 15
        "rrrr........DDDDDDdd...eeeeeeeee",  # 16  engine glow
        "rrrr........DDDDDdd....eeeeeeeee",  # 17
        "............DDDDdd..............",  # 18
        "..............DDdd..............",  # 19
        "................dd..............",  # 20
        "................................",  # 21
        "................................",  # 22
        "................................",  # 23
    ]
    color_map = {
        '.': TRANSPARENT,
        'D': (50,   40,  70, 255),   # dark purple-grey body
        'd': (30,   25,  50, 255),   # very dark body shadow
        'c': (80,   65, 110, 255),   # mid-body (center mass)
        'R': (220,  30,  30, 255),   # bright red cannon
        'r': (180,  20,  20, 255),   # slightly darker red cannon
        'e': (255, 140,  40, 255),   # orange engine glow
    }
    pixels = [color_map.get(art[y][x] if x < len(art[y]) else '.', TRANSPARENT)
              for y in range(H) for x in range(W)]
    save_sprite("boss.sprite", pixels, W, H)


# ---------------------------------------------------------------------------
# bullet.sprite  6x4  — Bright yellow/white elongated player bullet
# ---------------------------------------------------------------------------
def make_bullet():
    W, H = 6, 4
    # Elongated oval pointing right
    art = [
        "......",  # 0
        ".YYYY.",  # 1
        ".YYYY.",  # 2
        "......",  # 3
    ]
    # Override center pixels as white core
    art = [
        "......",
        ".WYY..",
        ".WYY..",
        "......",
    ]
    color_map = {
        '.': TRANSPARENT,
        'W': (255, 255, 200, 255),   # near-white core
        'Y': (255, 230,  40, 255),   # bright yellow
    }
    pixels = [color_map.get(art[y][x] if x < len(art[y]) else '.', TRANSPARENT)
              for y in range(H) for x in range(W)]
    save_sprite("bullet.sprite", pixels, W, H)


# ---------------------------------------------------------------------------
# ebullet.sprite  4x6  — Red enemy teardrop bullet (tall)
# ---------------------------------------------------------------------------
def make_ebullet():
    W, H = 4, 6
    art = [
        ".RR.",  # 0  tip at top
        "RRRR",  # 1
        "RRRR",  # 2
        "RRRR",  # 3
        ".rr.",  # 4  tail
        ".rr.",  # 5
    ]
    color_map = {
        '.': TRANSPARENT,
        'R': (240,  40,  40, 255),   # bright red
        'r': (160,  10,  10, 255),   # dark red tail
    }
    pixels = [color_map.get(art[y][x] if x < len(art[y]) else '.', TRANSPARENT)
              for y in range(H) for x in range(W)]
    save_sprite("ebullet.sprite", pixels, W, H)


# ---------------------------------------------------------------------------
# powerup.sprite  12x12  — Bright green power-up with "+" symbol
# ---------------------------------------------------------------------------
def make_powerup():
    W, H = 12, 12
    # Green circle with bright + symbol
    art = [
        "............",  # 0
        "....GGGG....",  # 1
        "...GGooGG...",  # 2
        "..GGo+oGG...",  # 3   slightly off-center to keep integer grid
        "..GG+++GG...",  # 4
        ".GGo+++oGG..",  # 5  center rows
        ".GGo+++oGG..",  # 6
        "..GG+++GG...",  # 7
        "..GGo+oGG...",  # 8
        "...GGooGG...",  # 9
        "....GGGG....",  # 10
        "............",  # 11
    ]
    color_map = {
        '.': TRANSPARENT,
        'G': (40,  200,  60, 255),   # bright green ring
        'o': (20,  140,  40, 255),   # darker green interior
        '+': (220, 255, 180, 255),   # bright lime + symbol
    }
    pixels = [color_map.get(art[y][x] if x < len(art[y]) else '.', TRANSPARENT)
              for y in range(H) for x in range(W)]
    save_sprite("powerup.sprite", pixels, W, H)


# ---------------------------------------------------------------------------
# background.sprite  64x64  — Space background with stars and faint nebula
# ---------------------------------------------------------------------------
def make_background():
    W, H = 64, 64

    import random
    rng = random.Random(42)   # deterministic seed for reproducible output

    # Start with near-black deep space
    pixels = [(5, 5, 12, 255)] * (W * H)

    # Faint nebula: a soft blue-purple wash in the upper-right quadrant
    for y in range(H):
        for x in range(W):
            # Radial falloff centered at (48, 16)
            dx = x - 48
            dy = y - 16
            dist = math.sqrt(dx*dx + dy*dy)
            nebula_r = 22.0
            if dist < nebula_r:
                strength = (1.0 - dist / nebula_r) * 0.45
                r, g, b, a = pixels[y * W + x]
                r = min(255, int(r + strength * 60))
                g = min(255, int(g + strength * 20))
                b = min(255, int(b + strength * 100))
                pixels[y * W + x] = (r, g, b, a)

    # Second nebula blob — warm reddish at lower-left
    for y in range(H):
        for x in range(W):
            dx = x - 12
            dy = y - 50
            dist = math.sqrt(dx*dx + dy*dy)
            nebula_r = 18.0
            if dist < nebula_r:
                strength = (1.0 - dist / nebula_r) * 0.30
                r, g, b, a = pixels[y * W + x]
                r = min(255, int(r + strength * 90))
                g = min(255, int(g + strength * 20))
                b = min(255, int(b + strength * 10))
                pixels[y * W + x] = (r, g, b, a)

    # Scatter stars of varying brightness
    # Dim stars (most common)
    for _ in range(80):
        sx = rng.randint(0, W - 1)
        sy = rng.randint(0, H - 1)
        brightness = rng.randint(100, 170)
        tint = rng.choice([
            (brightness, brightness, brightness),          # white
            (brightness - 20, brightness - 20, brightness + 40),  # blue-white
            (brightness, brightness, brightness - 30),     # warm white
        ])
        pixels[sy * W + sx] = (tint[0], tint[1], tint[2], 255)

    # Medium stars
    for _ in range(30):
        sx = rng.randint(0, W - 1)
        sy = rng.randint(0, H - 1)
        brightness = rng.randint(180, 220)
        tint = rng.choice([
            (brightness, brightness, 255),
            (255, brightness, brightness),
            (brightness, 255, brightness),
        ])
        pixels[sy * W + sx] = (tint[0], tint[1], tint[2], 255)

    # Bright stars (few)
    for _ in range(10):
        sx = rng.randint(0, W - 1)
        sy = rng.randint(0, H - 1)
        pixels[sy * W + sx] = (255, 255, 255, 255)
        # Small cross glow for brightest stars
        for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
            nx, ny = sx + dx, sy + dy
            if 0 <= nx < W and 0 <= ny < H:
                cr, cg, cb, ca = pixels[ny * W + nx]
                pixels[ny * W + nx] = (
                    min(255, cr + 60),
                    min(255, cg + 60),
                    min(255, cb + 80),
                    255
                )

    save_sprite("background.sprite", pixels, W, H)


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    print(f"Writing sprites to {OUTPUT_DIR}/")

    make_ship()
    make_enemy_straight()
    make_enemy_sine()
    make_enemy_turret()
    make_boss()
    make_bullet()
    make_ebullet()
    make_powerup()
    make_background()

    print("Done.")


if __name__ == "__main__":
    main()
