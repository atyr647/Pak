#!/usr/bin/env python3
"""
gen_dungeon_models.py -- generate the .glb models for the Dungeon Quartet demo.

The dungeon crawler keeps its geometry in source rather than in binary art
files: this script emits every model the demo loads, so the art is
reproducible and reviewable as code.

Output (written to demos/dungeon_quartet/assets/models/):
    dungeon.glb          the whole static level baked as one mesh
    hero_tank.glb        \
    hero_melee.glb        |  4 player characters
    hero_healer.glb       |
    hero_ranged.glb      /
    enemy_slime.glb      \
    enemy_goblin.glb      |
    enemy_skeleton.glb    |
    enemy_bat.glb         |  9 enemy types
    enemy_spider.glb      |
    enemy_zombie.glb      |
    enemy_orc.glb         |
    enemy_wraith.glb      |
    enemy_boss.glb       /

Emitted glTF matches the structure the Tiny3D converter expects:
flat-shaded triangles with POSITION / NORMAL / COLOR_0 and ushort indices,
against a single "vertex_color" material.

Usage:  python3 tools/gen_dungeon_models.py
"""
import json
import os
import struct
import sys

# ── Grid + level layout (must stay in sync with src/main.pk64) ──────────────
GRID_W, GRID_H = 32, 24

# The level is emitted as a 3x3 grid of chunk models so the game can draw only
# the chunks near the camera instead of the whole dungeon every frame.
CHUNK_COLS, CHUNK_ROWS = 3, 3
CHUNK_W = (GRID_W + CHUNK_COLS - 1) // CHUNK_COLS
CHUNK_H = (GRID_H + CHUNK_ROWS - 1) // CHUNK_ROWS
TILE_WALL, TILE_FLOOR = 0, 1

TILE = 1.0          # world units per grid tile
WALL_H = 1.05       # wall block height
FLOOR_Y = 0.0

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "demos", "dungeon_quartet", "assets", "models")


# ── Procedural level generation ─────────────────────────────────────────────
# Levels are generated here, at build time, rather than in the game. Tiny3D
# draws models, and Pak exposes no documented way to build a mesh at runtime,
# so the geometry has to be baked. What ships is several independently
# generated levels; the game picks one at random and loads its chunks, and
# places the party and enemies procedurally on top of that.
#
# The generator lays a room in each cell of a 3x3 grid, then connects the
# cells with a random spanning tree (which guarantees the level is always
# fully traversable) plus a few extra links so the map has loops rather than
# being a pure tree.

BIOME_DUNGEON = 0
BIOME_FOREST = 1
BIOME_NAMES = {BIOME_DUNGEON: "dungeon", BIOME_FOREST: "forest"}

CELL_W, CELL_H = CHUNK_W, CHUNK_H          # one room cell per chunk


class Level:
    def __init__(self, index, biome, seed):
        self.index = index
        self.biome = biome
        self.seed = seed
        self.tiles = [TILE_WALL] * (GRID_W * GRID_H)
        self.rooms = []            # (x0, y0, x1, y1) per cell, or None
        self.boss_room = None
        self.start_room = None
        self.hero_start = []       # 4x (gx, gy)
        self.enemy_spawns = []     # (gx, gy, kind_id)

    def at(self, gx, gy):
        if gx < 0 or gx >= GRID_W or gy < 0 or gy >= GRID_H:
            return TILE_WALL
        return self.tiles[gy * GRID_W + gx]

    def fill(self, x0, y0, x1, y1):
        for gy in range(max(0, y0), min(GRID_H, y1 + 1)):
            for gx in range(max(0, x0), min(GRID_W, x1 + 1)):
                self.tiles[gy * GRID_W + gx] = TILE_FLOOR

    def in_room(self, ri, gx, gy):
        r = self.rooms[ri]
        return r is not None and r[0] <= gx <= r[2] and r[1] <= gy <= r[3]


def _cell_bounds(cx, cy):
    """Usable tile range inside a cell, leaving a 1-tile wall margin."""
    x0 = cx * CELL_W + 1
    y0 = cy * CELL_H + 1
    x1 = min(GRID_W - 2, (cx + 1) * CELL_W - 2)
    y1 = min(GRID_H - 2, (cy + 1) * CELL_H - 2)
    return x0, y0, x1, y1


def generate_level(index, biome, seed):
    import random as _r
    rng = _r.Random(seed)
    lv = Level(index, biome, seed)

    # --- carve one room per cell, with varied size and shape -----------------
    for cy in range(CHUNK_ROWS):
        for cx in range(CHUNK_COLS):
            bx0, by0, bx1, by1 = _cell_bounds(cx, cy)
            maxw, maxh = bx1 - bx0 + 1, by1 - by0 + 1
            w = rng.randint(max(4, maxw - 3), maxw)
            h = rng.randint(max(4, maxh - 2), maxh)
            x0 = bx0 + rng.randint(0, maxw - w)
            y0 = by0 + rng.randint(0, maxh - h)
            x1, y1 = x0 + w - 1, y0 + h - 1
            lv.fill(x0, y0, x1, y1)
            lv.rooms.append((x0, y0, x1, y1))

            shape = rng.random()
            if shape < 0.22 and w >= 6 and h >= 5:
                # bite a corner out, so the room is not a plain rectangle
                cwid, chgt = rng.randint(2, 3), rng.randint(2, 2)
                corner = rng.randint(0, 3)
                for dy in range(chgt):
                    for dx in range(cwid):
                        gx = x0 + dx if corner in (0, 2) else x1 - dx
                        gy = y0 + dy if corner in (0, 1) else y1 - dy
                        lv.tiles[gy * GRID_W + gx] = TILE_WALL
            elif shape < 0.42 and w >= 7 and h >= 5:
                # interior pillars
                for py in range(y0 + 1, y1, 2):
                    for px in range(x0 + 2, x1 - 1, 3):
                        lv.tiles[py * GRID_W + px] = TILE_WALL

    # --- connect the cells: spanning tree first, then a few extra loops ------
    cells = [(cx, cy) for cy in range(CHUNK_ROWS) for cx in range(CHUNK_COLS)]
    reached = {cells[rng.randrange(len(cells))]}
    edges = []
    while len(reached) < len(cells):
        frontier = []
        for (cx, cy) in reached:
            for (dx, dy) in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nb = (cx + dx, cy + dy)
                if nb in cells and nb not in reached:
                    frontier.append(((cx, cy), nb))
        a_, b_ = frontier[rng.randrange(len(frontier))]
        edges.append((a_, b_))
        reached.add(b_)

    extra = [((cx, cy), (cx + dx, cy + dy))
             for (cx, cy) in cells for (dx, dy) in ((1, 0), (0, 1))
             if (cx + dx, cy + dy) in cells]
    rng.shuffle(extra)
    for e in extra[:rng.randint(2, 4)]:
        if e not in edges and (e[1], e[0]) not in edges:
            edges.append(e)

    # --- carve 2-wide corridors along each edge -----------------------------
    for (ca, cb) in edges:
        ra = lv.rooms[ca[1] * CHUNK_COLS + ca[0]]
        rb = lv.rooms[cb[1] * CHUNK_COLS + cb[0]]
        if ca[1] == cb[1]:                       # horizontal neighbours
            lo, hi = (ra, rb) if ra[0] < rb[0] else (rb, ra)
            ylo = max(lo[1], hi[1])
            yhi = min(lo[3], hi[3])
            if yhi - ylo < 1:
                y = max(0, min(GRID_H - 2, (ylo + yhi) // 2))
            else:
                y = rng.randint(ylo, yhi - 1)
            lv.fill(lo[2], y, hi[0], y + 1)
        else:                                    # vertical neighbours
            lo, hi = (ra, rb) if ra[1] < rb[1] else (rb, ra)
            xlo = max(lo[0], hi[0])
            xhi = min(lo[2], hi[2])
            if xhi - xlo < 1:
                x = max(0, min(GRID_W - 2, (xlo + xhi) // 2))
            else:
                x = rng.randint(xlo, xhi - 1)
            lv.fill(x, lo[3], x + 1, hi[1])

    # Start and boss go in diagonally opposite corners of the cell grid.
    # (Comparing *linear* cell indices here picks an adjacent corner in some
    # cases, not the true diagonal opposite -- e.g. from top-right (index 2
    # in a 3x3 grid) the largest |index difference| is bottom-right (8), not
    # the actually-opposite bottom-left (6). Compare 2D coordinates instead.)
    corner_xy = [(0, 0), (CHUNK_COLS - 1, 0),
                 (0, CHUNK_ROWS - 1), (CHUNK_COLS - 1, CHUNK_ROWS - 1)]
    start_xy = rng.choice(corner_xy)
    boss_xy = max(corner_xy, key=lambda c: (c[0] - start_xy[0]) ** 2 +
                                            (c[1] - start_xy[1]) ** 2)
    lv.start_room = start_xy[1] * CHUNK_COLS + start_xy[0]
    lv.boss_room = boss_xy[1] * CHUNK_COLS + boss_xy[0]

    _place_spawns(lv, rng)
    return lv


# Enemy kind ids, matching enemy_index() in src/main.pk64 exactly.
KIND_ID = {"slime": 0, "goblin": 1, "skeleton": 2, "bat": 3, "spider": 4,
           "zombie": 5, "orc": 6, "wraith": 7, "boss": 8}

TIER_WEAK = ["slime", "goblin", "bat"]
TIER_MID = ["skeleton", "spider", "goblin"]
TIER_STRONG = ["zombie", "orc", "wraith"]


def _room_floor_tiles(lv, ri):
    x0, y0, x1, y1 = lv.rooms[ri]
    return [(gx, gy) for gy in range(y0, y1 + 1) for gx in range(x0, x1 + 1)
            if lv.tiles[gy * GRID_W + gx] == TILE_FLOOR]


def _cell_xy(ci):
    return ci % CHUNK_COLS, ci // CHUNK_COLS


def _cell_dist(a, b):
    ax, ay = _cell_xy(a)
    bx, by = _cell_xy(b)
    return abs(ax - bx) + abs(ay - by)


def _place_spawns(lv, rng):
    """Bake hero start positions and enemy spawns for this level.

    Doing this here, once, at generation time -- rather than searching for
    valid floor tiles at runtime -- guarantees every spawn lands on a real
    floor tile that matches the exact baked geometry. It also means the
    encounter layout is reviewable the same way the geometry is: read the
    generator, not the compiled ROM.

    Encounters escalate with cell-grid distance from the start room: weak
    vermin nearby, mid-tier deeper in, brutes and undead approaching the
    boss wing, which itself gets the boss plus a small guard.
    """
    start_tiles = _room_floor_tiles(lv, lv.start_room)
    scx = sum(t[0] for t in start_tiles) / len(start_tiles)
    scy = sum(t[1] for t in start_tiles) / len(start_tiles)
    start_tiles.sort(key=lambda t: (t[0] - scx) ** 2 + (t[1] - scy) ** 2)
    lv.hero_start = start_tiles[:4]
    while len(lv.hero_start) < 4:          # pathological tiny room fallback
        lv.hero_start.append(lv.hero_start[-1])

    max_d = max(1, _cell_dist(lv.start_room, lv.boss_room))
    reserved = set(lv.hero_start)

    for ci in range(CHUNK_COLS * CHUNK_ROWS):
        if ci == lv.start_room:
            continue
        tiles = [t for t in _room_floor_tiles(lv, ci) if t not in reserved]
        if not tiles:
            continue
        rng.shuffle(tiles)

        if ci == lv.boss_room:
            bx, by = tiles.pop(0)
            lv.enemy_spawns.append((bx, by, KIND_ID["boss"]))
            reserved.add((bx, by))
            count = rng.randint(1, 2)
            pool = TIER_STRONG
        else:
            d = _cell_dist(lv.start_room, ci)
            frac = d / max_d
            pool = TIER_WEAK if frac < 0.4 else (
                TIER_MID if frac < 0.75 else TIER_STRONG)
            count = rng.randint(2, 3)

        placed = 0
        for t in tiles:
            if placed >= count or len(lv.enemy_spawns) >= 24:
                break
            if t in reserved:
                continue
            reserved.add(t)
            kind = pool[rng.randrange(len(pool))]
            lv.enemy_spawns.append((t[0], t[1], KIND_ID[kind]))
            placed += 1


def tile_at(gx, gy):

    return CURRENT.at(gx, gy)


def is_boss_room(gx, gy):
    return CURRENT.in_room(CURRENT.boss_room, gx, gy)


CURRENT = None


# ── Mesh builder ────────────────────────────────────────────────────────────
class Mesh:
    """Accumulates flat-shaded triangles with per-vertex color."""

    def __init__(self):
        self.pos = []
        self.nrm = []
        self.col = []
        self.idx = []

    def tri(self, a, b, c, color, normal=None):
        if normal is None:
            ux, uy, uz = b[0] - a[0], b[1] - a[1], b[2] - a[2]
            vx, vy, vz = c[0] - a[0], c[1] - a[1], c[2] - a[2]
            nx = uy * vz - uz * vy
            ny = uz * vx - ux * vz
            nz = ux * vy - uy * vx
            ln = (nx * nx + ny * ny + nz * nz) ** 0.5
            normal = (nx / ln, ny / ln, nz / ln) if ln > 1e-9 else (0.0, 1.0, 0.0)
        base = len(self.pos)
        for v in (a, b, c):
            self.pos.append(v)
            self.nrm.append(normal)
            self.col.append(color)
        self.idx += [base, base + 1, base + 2]

    def quad(self, a, b, c, d, color, normal=None):
        self.tri(a, b, c, color, normal)
        self.tri(a, c, d, color, normal)

    def box(self, cx, cy, cz, hx, hy, hz, top, side, bottom=None, faces="tsn"):
        """Axis-aligned box. `faces` selects t=top, s=sides, n=bottom."""
        x0, x1 = cx - hx, cx + hx
        y0, y1 = cy - hy, cy + hy
        z0, z1 = cz - hz, cz + hz
        if bottom is None:
            bottom = tuple(c * 0.5 for c in side[:3]) + (side[3],)
        if "t" in faces:
            self.quad((x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0),
                      top, (0, 1, 0))
        if "n" in faces:
            self.quad((x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1),
                      bottom, (0, -1, 0))
        if "s" in faces:
            dark = tuple(c * 0.82 for c in side[:3]) + (side[3],)
            self.quad((x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1),
                      side, (0, 0, 1))
            self.quad((x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0),
                      side, (0, 0, -1))
            self.quad((x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1),
                      dark, (1, 0, 0))
            self.quad((x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0),
                      dark, (-1, 0, 0))

    def dome(self, cx, cy, cz, radius, height, col, col_top=None,
             segs=8, rings=4, squash_z=1.0):
        """Low-poly dome. Stacked boxes cannot make a curved surface -- this
        emits real sloped quads, which is what makes a blob read as a blob."""
        import math as _m
        if col_top is None:
            col_top = col
        def ring(t):
            a = t * _m.pi * 0.5
            return radius * _m.cos(a), height * _m.sin(a)
        for i in range(rings):
            r0, y0 = ring(i / rings)
            r1, y1 = ring((i + 1) / rings)
            f0, f1 = i / rings, (i + 1) / rings
            c0 = tuple(col[k] * (1 - f0) + col_top[k] * f0 for k in range(4))
            c1 = tuple(col[k] * (1 - f1) + col_top[k] * f1 for k in range(4))
            for sgi in range(segs):
                a0 = 2 * _m.pi * sgi / segs
                a1 = 2 * _m.pi * (sgi + 1) / segs
                p00 = (cx + r0 * _m.cos(a0), cy + y0, cz + r0 * _m.sin(a0) * squash_z)
                p01 = (cx + r0 * _m.cos(a1), cy + y0, cz + r0 * _m.sin(a1) * squash_z)
                p10 = (cx + r1 * _m.cos(a0), cy + y1, cz + r1 * _m.sin(a0) * squash_z)
                p11 = (cx + r1 * _m.cos(a1), cy + y1, cz + r1 * _m.sin(a1) * squash_z)
                if r1 < 1e-6:
                    self.tri(p00, p01, (cx, cy + y1, cz), c1)
                else:
                    self.quad(p00, p01, p11, p10, c1)
        return self

    def revolve(self, cx, cy, cz, profile, col_lo, col_hi=None,
                segs=10, squash_z=1.0):
        """Surface of revolution from a bottom-to-top (radius, y) profile.

        Boxes cannot make a curved silhouette; this is what lets blobs and
        canopies read as round instead of as stacked slabs.
        """
        import math as _m
        if col_hi is None:
            col_hi = col_lo
        n = len(profile)
        for i in range(n - 1):
            r0, y0 = profile[i]
            r1, y1 = profile[i + 1]
            f1 = (i + 1) / (n - 1)
            c1 = tuple(col_lo[k] * (1 - f1) + col_hi[k] * f1 for k in range(4))
            for sgi in range(segs):
                a0 = 2 * _m.pi * sgi / segs
                a1 = 2 * _m.pi * (sgi + 1) / segs
                p00 = (cx + r0 * _m.cos(a0), cy + y0, cz + r0 * _m.sin(a0) * squash_z)
                p01 = (cx + r0 * _m.cos(a1), cy + y0, cz + r0 * _m.sin(a1) * squash_z)
                p10 = (cx + r1 * _m.cos(a0), cy + y1, cz + r1 * _m.sin(a0) * squash_z)
                p11 = (cx + r1 * _m.cos(a1), cy + y1, cz + r1 * _m.sin(a1) * squash_z)
                if r1 < 1e-6:
                    self.tri(p00, p01, (cx, cy + y1, cz), c1)
                elif r0 < 1e-6:
                    self.tri((cx, cy + y0, cz), p11, p10, c1)
                else:
                    self.quad(p00, p01, p11, p10, c1)
        return self

    def ellipsoid(self, cx, cy, cz, rx, ry, rz, col_lo, col_hi=None,
                  segs=10, rings=6):
        """Full ellipsoid centred on (cx, cy, cz)."""
        import math as _m
        prof = []
        for i in range(rings + 1):
            a = -_m.pi * 0.5 + _m.pi * i / rings
            prof.append((rx * _m.cos(a), ry * _m.sin(a)))
        return self.revolve(cx, cy, cz, prof, col_lo, col_hi,
                            segs=segs, squash_z=rz / rx if rx > 1e-9 else 1.0)

    def vert_count(self):
        return len(self.pos)


def write_glb(mesh, path):
    if mesh.vert_count() > 65535:
        raise ValueError(f"{path}: {mesh.vert_count()} verts exceeds ushort indices")

    pos_b = b"".join(struct.pack("<3f", *v) for v in mesh.pos)
    nrm_b = b"".join(struct.pack("<3f", *v) for v in mesh.nrm)
    col_b = b"".join(struct.pack("<4f", *v) for v in mesh.col)
    idx_b = b"".join(struct.pack("<H", i) for i in mesh.idx)
    if len(idx_b) % 4:
        idx_b += b"\x00" * (4 - len(idx_b) % 4)

    bin_chunk = pos_b + nrm_b + col_b + idx_b
    o_pos, o_nrm = 0, len(pos_b)
    o_col = o_nrm + len(nrm_b)
    o_idx = o_col + len(col_b)

    mn = [min(v[i] for v in mesh.pos) for i in range(3)]
    mx = [max(v[i] for v in mesh.pos) for i in range(3)]
    n = mesh.vert_count()

    gltf = {
        "asset": {"version": "2.0", "generator": "pak-dungeon-tools"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes": [{"mesh": 0, "name": "mesh0"}],
        "materials": [{"name": "vertex_color", "pbrMetallicRoughness": {}}],
        "meshes": [{
            "name": "mesh0",
            "primitives": [{
                "attributes": {"POSITION": 0, "NORMAL": 1, "COLOR_0": 2},
                "indices": 3, "mode": 4, "material": 0,
            }],
        }],
        "accessors": [
            {"bufferView": 0, "byteOffset": 0, "componentType": 5126,
             "count": n, "type": "VEC3", "min": mn, "max": mx},
            {"bufferView": 1, "byteOffset": 0, "componentType": 5126,
             "count": n, "type": "VEC3"},
            {"bufferView": 2, "byteOffset": 0, "componentType": 5126,
             "count": n, "type": "VEC4"},
            {"bufferView": 3, "byteOffset": 0, "componentType": 5123,
             "count": len(mesh.idx), "type": "SCALAR"},
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": o_pos, "byteLength": len(pos_b), "target": 34962},
            {"buffer": 0, "byteOffset": o_nrm, "byteLength": len(nrm_b), "target": 34962},
            {"buffer": 0, "byteOffset": o_col, "byteLength": len(col_b), "target": 34962},
            {"buffer": 0, "byteOffset": o_idx, "byteLength": len(idx_b), "target": 34963},
        ],
        "buffers": [{"byteLength": len(bin_chunk)}],
    }

    json_b = json.dumps(gltf, separators=(",", ":")).encode("utf-8")
    if len(json_b) % 4:
        json_b += b" " * (4 - len(json_b) % 4)

    total = 12 + 8 + len(json_b) + 8 + len(bin_chunk)
    with open(path, "wb") as f:
        f.write(struct.pack("<III", 0x46546C67, 2, total))
        f.write(struct.pack("<II", len(json_b), 0x4E4F534A))
        f.write(json_b)
        f.write(struct.pack("<II", len(bin_chunk), 0x004E4942))
        f.write(bin_chunk)

    print(f"  {os.path.basename(path):22s} {n:5d} verts  "
          f"{len(mesh.idx)//3:5d} tris  {total:7d} bytes")


# ── Palette (mirrors the 2D HUD colors so the two read as one game) ─────────
def rgba(h):
    return (((h >> 24) & 0xFF) / 255.0, ((h >> 16) & 0xFF) / 255.0,
            ((h >> 8) & 0xFF) / 255.0, 1.0)


FLOOR_A = rgba(0x8A7A5CFF)
FLOOR_B = rgba(0x766A50FF)
BOSS_A = rgba(0x805F8AFF)
BOSS_B = rgba(0x6E5176FF)
WALL_TOP = rgba(0x6E6982FF)
WALL_SIDE = rgba(0x54506AFF)
ROCK_TOP = rgba(0x413E52FF)   # unexposed interior rock cap

TRIM = rgba(0xF2ECDCFF)
TRIM_W = rgba(0xF2ECDCFF)
STEEL = rgba(0xC8CCD8FF)

ROLE = {
    "tank":   (rgba(0x4C7CE0FF), rgba(0x86AEF4FF)),
    "melee":  (rgba(0xE04C4CFF), rgba(0xF48E8EFF)),
    "healer": (rgba(0x3ED27AFF), rgba(0x84E8AEFF)),
    "ranged": (rgba(0xE0BC38FF), rgba(0xF4DC8AFF)),
}


# ── Level mesh ──────────────────────────────────────────────────────────────
# ── Biome palettes ──────────────────────────────────────────────────────────
BIOME_PAL = {
    BIOME_DUNGEON: dict(
        floor_a=rgba(0x8A7A5CFF), floor_b=rgba(0x766A50FF),
        boss_a=rgba(0x805F8AFF), boss_b=rgba(0x6E5176FF),
        wall_top=rgba(0x6E6982FF), wall_side=rgba(0x54506AFF),
        rock_top=rgba(0x413E52FF), wall_h=1.05,
    ),
    BIOME_FOREST: dict(
        floor_a=rgba(0x4E7A3AFF), floor_b=rgba(0x446E33FF),
        boss_a=rgba(0x6A5E3AFF), boss_b=rgba(0x5C5232FF),
        wall_top=rgba(0x2E5C2AFF), wall_side=rgba(0x3E3020FF),
        rock_top=rgba(0x27401FFF), wall_h=1.05,
    ),
}

TRUNK      = rgba(0x4A3620FF)
TRUNK_LT   = rgba(0x5E4529FF)
LEAF_LO    = rgba(0x2C5E28FF)
LEAF_HI    = rgba(0x63A84AFF)
BUSH       = rgba(0x3C7A34FF)
ROCK       = rgba(0x6E6A72FF)
DIRT       = rgba(0x6E5A3EFF)


def tile_hash(gx, gy, salt=0):
    """Deterministic per-tile pseudo-random, so geometry and gameplay agree."""
    h = (gx * 73856093) ^ (gy * 19349663) ^ (salt * 83492791)
    h &= 0x7FFFFFFF
    h = (h ^ (h >> 13)) * 1274126177
    return (h ^ (h >> 16)) & 0x7FFFFFFF


def _forest_tree(m, wx, wz, gx, gy):
    """A tree standing in place of a wall block. Height and canopy vary so a
    treeline never looks like a row of identical stamps.

    Budget: trunk (8 tris, sides only) + one low-poly canopy (20 tris) =
    28 tris/tree. Trees line every perimeter wall tile, so this has to stay
    cheap -- a 7x4-segment canopy (56 tris) made forest chunks 10x the
    triangle cost of dungeon ones.
    """
    r = tile_hash(gx, gy, 1)
    th = 0.52 + ((r >> 3) % 5) * 0.055          # trunk height
    cr = 0.38 + ((r >> 7) % 4) * 0.030          # canopy radius
    lean_x = (((r >> 11) % 5) - 2) * 0.012
    lean_z = (((r >> 15) % 5) - 2) * 0.012
    part(m, wx, 0.0, th, wz, 0.085, 0.085, TRUNK_LT, TRUNK, faces="s")
    cy = th + cr * 0.55
    m.ellipsoid(wx + lean_x, cy, wz + lean_z, cr, cr * 0.82, cr * 0.95,
                LEAF_LO, LEAF_HI, segs=5, rings=2)


def _floor_prop(m, wx, wz, gx, gy, biome):
    """Scatter: rubble underground, bushes and rocks outdoors. Cheap boxes,
    not ellipsoids -- these appear on a double-digit percentage of floor
    tiles, so per-prop cost matters more than per-tree cost."""
    r = tile_hash(gx, gy, 2)
    roll = r % 100
    if biome == BIOME_FOREST:
        if roll < 5:
            cr = 0.16 + ((r >> 5) % 3) * 0.03
            part(m, wx, 0.0, cr * 1.1, wz, cr, cr * 0.9, BUSH, LEAF_LO)
        elif roll < 8:
            rr = 0.11 + ((r >> 5) % 3) * 0.025
            part(m, wx, 0.0, rr * 0.9, wz, rr, rr * 0.85, ROCK, ROCK)
        elif roll < 13:
            part(m, wx, 0.0, 0.012, wz, 0.30, 0.30, DIRT, DIRT, faces="t")
    else:
        if roll < 4:
            rr = 0.10 + ((r >> 5) % 3) * 0.022
            part(m, wx, 0.0, rr * 0.9, wz, rr, rr * 0.8, ROCK, ROCK)
        elif roll < 8:
            part(m, wx + 0.12, 0.0, 0.05, wz - 0.1, 0.07, 0.07,
                 ROCK, ROCK)
        elif roll < 14:
            part(m, wx, 0.0, 0.012, wz, 0.28, 0.28, DIRT, DIRT, faces="t")


def build_level_mesh(lv, cx, cy):
    """Geometry for one chunk of one level, in that level's biome."""
    pal = BIOME_PAL[lv.biome]
    wall_h = pal["wall_h"]
    m = Mesh()

    xr = range(cx * CHUNK_W, min(GRID_W, (cx + 1) * CHUNK_W))
    yr = range(cy * CHUNK_H, min(GRID_H, (cy + 1) * CHUNK_H))

    for gy in yr:
        for gx in xr:
            wx = (gx - (GRID_W - 1) / 2.0) * TILE
            wz = (gy - (GRID_H - 1) / 2.0) * TILE
            h = TILE / 2.0

            if lv.at(gx, gy) == TILE_FLOOR:
                if is_boss_room(gx, gy):
                    col = pal["boss_a"] if (gx + gy) % 2 == 0 else pal["boss_b"]
                else:
                    col = pal["floor_a"] if (gx + gy) % 2 == 0 else pal["floor_b"]
                m.quad((wx - h, FLOOR_Y, wz + h), (wx + h, FLOOR_Y, wz + h),
                       (wx + h, FLOOR_Y, wz - h), (wx - h, FLOOR_Y, wz - h),
                       col, (0, 1, 0))
                _floor_prop(m, wx, wz, gx, gy, lv.biome)
                continue

            nb = [(1, 0), (-1, 0), (0, 1), (0, -1)]
            exposed = [d for d in nb if lv.at(gx + d[0], gy + d[1]) == TILE_FLOOR]
            if not exposed:
                # interior rock still needs a cap or the camera sees the void
                m.quad((wx - h, wall_h, wz + h), (wx + h, wall_h, wz + h),
                       (wx + h, wall_h, wz - h), (wx - h, wall_h, wz - h),
                       pal["rock_top"], (0, 1, 0))
                continue

            if lv.biome == BIOME_FOREST:
                # forest "walls" are trees over a low mound of undergrowth
                m.quad((wx - h, 0.14, wz + h), (wx + h, 0.14, wz + h),
                       (wx + h, 0.14, wz - h), (wx - h, 0.14, wz - h),
                       pal["wall_top"], (0, 1, 0))
                side = pal["wall_side"]
                if lv.at(gx, gy + 1) == TILE_FLOOR:
                    m.quad((wx - h, 0, wz + h), (wx + h, 0, wz + h),
                           (wx + h, 0.14, wz + h), (wx - h, 0.14, wz + h),
                           side, (0, 0, 1))
                if lv.at(gx, gy - 1) == TILE_FLOOR:
                    m.quad((wx + h, 0, wz - h), (wx - h, 0, wz - h),
                           (wx - h, 0.14, wz - h), (wx + h, 0.14, wz - h),
                           side, (0, 0, -1))
                if lv.at(gx + 1, gy) == TILE_FLOOR:
                    m.quad((wx + h, 0, wz + h), (wx + h, 0, wz - h),
                           (wx + h, 0.14, wz - h), (wx + h, 0.14, wz + h),
                           side, (1, 0, 0))
                if lv.at(gx - 1, gy) == TILE_FLOOR:
                    m.quad((wx - h, 0, wz - h), (wx - h, 0, wz + h),
                           (wx - h, 0.14, wz + h), (wx - h, 0.14, wz - h),
                           side, (-1, 0, 0))
                # Skip the tree itself (not the undergrowth mound, which
                # stays as the impassable barrier) on ~1 in 4 tiles. A solid
                # tree on every perimeter tile is also the single biggest
                # triangle cost in the level -- gaps are both cheaper and
                # read as a more natural treeline than an unbroken wall.
                if tile_hash(gx, gy, 3) % 4 != 0:
                    _forest_tree(m, wx, wz, gx, gy)
                continue

            # dungeon: stone block
            m.quad((wx - h, wall_h, wz + h), (wx + h, wall_h, wz + h),
                   (wx + h, wall_h, wz - h), (wx - h, wall_h, wz - h),
                   pal["wall_top"], (0, 1, 0))
            side = pal["wall_side"]
            side_dark = tuple(c * 0.80 for c in side[:3]) + (1.0,)
            if lv.at(gx, gy + 1) == TILE_FLOOR:
                m.quad((wx - h, 0, wz + h), (wx + h, 0, wz + h),
                       (wx + h, wall_h, wz + h), (wx - h, wall_h, wz + h),
                       side, (0, 0, 1))
            if lv.at(gx, gy - 1) == TILE_FLOOR:
                m.quad((wx + h, 0, wz - h), (wx - h, 0, wz - h),
                       (wx - h, wall_h, wz - h), (wx + h, wall_h, wz - h),
                       side, (0, 0, -1))
            if lv.at(gx + 1, gy) == TILE_FLOOR:
                m.quad((wx + h, 0, wz + h), (wx + h, 0, wz - h),
                       (wx + h, wall_h, wz - h), (wx + h, wall_h, wz + h),
                       side_dark, (1, 0, 0))
            if lv.at(gx - 1, gy) == TILE_FLOOR:
                m.quad((wx - h, 0, wz - h), (wx - h, 0, wz + h),
                       (wx - h, wall_h, wz + h), (wx - h, wall_h, wz - h),
                       side_dark, (-1, 0, 0))
    return m


# ── Character construction ──────────────────────────────────────────────────
# Units stand on the floor plane (y = 0) and face -Z (the camera side), so the
# front of a model is its -Z face. Characters are built from articulated parts
# -- legs, torso, arms, head, gear -- rather than a single block, which is what
# makes the silhouettes read at N64 resolution.
#
# Bottom faces are omitted on parts that rest on the floor or sit inside the
# body; nothing can see them and they are a third of a box's triangles.

SKIN_HUMAN  = rgba(0xE0A882FF)
SKIN_GOBLIN = rgba(0x7FA84AFF)
SKIN_ORC    = rgba(0x4E7A3CFF)
SKIN_ZOMBIE = rgba(0x8FA07AFF)
BONE        = rgba(0xE2E0D2FF)
BONE_DARK   = rgba(0x2A2430FF)
LEATHER     = rgba(0x6B4A2FFF)
LEATHER_DK  = rgba(0x4A3320FF)
STEEL       = rgba(0xC2C8D6FF)
STEEL_DK    = rgba(0x8890A2FF)
GOLD        = rgba(0xD8A93AFF)
CLOTH_DK    = rgba(0x3A3346FF)
HOOD_G      = rgba(0x2E8A54FF)   # healer hood, darker than the robe
EYE_RED     = rgba(0xFF4030FF)
EYE_GREEN   = rgba(0x9CFF6AFF)


def part(m, x, y0, y1, z, hw, hd, top, side, faces="ts"):
    """Box spanning y0..y1, centred on (x, z). Reads better than raw box()."""
    m.box(x, (y0 + y1) * 0.5, z, hw, (y1 - y0) * 0.5, hd, top, side, faces=faces)


def humanoid(m, cfg):
    """Shared humanoid frame: legs, torso, arms, head.

    cfg keys let each class/mob vary proportions without repeating geometry.
    """
    leg_top   = cfg["leg_top"]
    torso_top = cfg["torso_top"]
    head_top  = cfg["head_top"]
    tw_       = cfg["torso_hw"]
    td        = cfg["torso_hd"]
    skin      = cfg["skin"]
    cloth     = cfg["cloth"]
    cloth_lt  = cfg.get("cloth_lt", cloth)
    boot      = cfg.get("boot", LEATHER_DK)
    arm_fwd   = cfg.get("arm_fwd", 0.0)      # +Z back, -Z forward
    leg_gap   = cfg.get("leg_gap", 0.5)
    hunch     = cfg.get("hunch", 0.0)        # shifts head/torso forward

    lw = tw_ * 0.40
    lx = tw_ * leg_gap
    # legs
    for sx in (-1, 1):
        part(m, sx * lx, 0.0, leg_top * 0.55, 0.0, lw, td * 0.62, boot, boot)
        part(m, sx * lx, leg_top * 0.55, leg_top, 0.0, lw * 0.92, td * 0.55,
             cloth, cloth)
    # torso
    part(m, 0.0, leg_top, torso_top, -hunch, tw_, td, cloth_lt, cloth)
    # arms
    aw = tw_ * 0.30
    for sx in (-1, 1):
        part(m, sx * (tw_ + aw), leg_top + (torso_top - leg_top) * 0.10,
             torso_top - (torso_top - leg_top) * 0.08, arm_fwd,
             aw, td * 0.62, cloth_lt, cloth)
    # head
    hw = tw_ * 0.62
    part(m, 0.0, torso_top, head_top, -hunch, hw, hw * 0.92, skin, skin)
    return hw


def eyes(m, y, z_front, spread, col, w=0.030, h=0.026, d=0.016):
    for sx in (-1, 1):
        part(m, sx * spread, y - h, y + h, z_front, w, d, col, col, faces="ts")


# ── Player characters ───────────────────────────────────────────────────────
def build_hero_mesh(role):
    body, light = ROLE[role]
    m = Mesh()

    if role == "tank":
        # heavy plate, tower shield, crested helm -- widest silhouette
        hw = humanoid(m, dict(leg_top=0.30, torso_top=0.66, head_top=0.86,
                              torso_hw=0.20, torso_hd=0.13, skin=SKIN_HUMAN,
                              cloth=body, cloth_lt=light, boot=STEEL_DK,
                              leg_gap=0.48))
        # pauldrons
        for sx in (-1, 1):
            part(m, sx * 0.24, 0.58, 0.68, 0.0, 0.09, 0.14, STEEL, STEEL_DK)
        # breastplate + belt
        part(m, 0.0, 0.42, 0.60, -0.14, 0.15, 0.02, STEEL, STEEL)
        part(m, 0.0, 0.36, 0.42, -0.14, 0.18, 0.02, GOLD, GOLD)
        # helm: visor band + crest
        part(m, 0.0, 0.70, 0.78, -0.13, 0.115, 0.02, BONE_DARK, BONE_DARK)
        part(m, 0.0, 0.84, 0.94, 0.0, 0.035, 0.11, GOLD, GOLD)
        part(m, 0.0, 0.80, 0.86, 0.0, hw + 0.02, hw * 0.95, STEEL, STEEL_DK)
        # tower shield on the left arm
        part(m, -0.34, 0.28, 0.72, -0.06, 0.05, 0.17, STEEL, STEEL_DK)
        part(m, -0.38, 0.40, 0.60, -0.06, 0.02, 0.08, GOLD, GOLD)
        # mace in the right hand
        part(m, 0.32, 0.18, 0.56, 0.0, 0.030, 0.030, LEATHER, LEATHER)
        part(m, 0.32, 0.56, 0.68, 0.0, 0.070, 0.070, STEEL, STEEL_DK)

    elif role == "melee":
        # light armour, greatsword raised, shoulder guards
        humanoid(m, dict(leg_top=0.32, torso_top=0.66, head_top=0.86,
                         torso_hw=0.175, torso_hd=0.115, skin=SKIN_HUMAN,
                         cloth=body, cloth_lt=light, boot=LEATHER_DK,
                         arm_fwd=-0.03))
        for sx in (-1, 1):
            part(m, sx * 0.21, 0.60, 0.68, 0.0, 0.075, 0.12, STEEL, STEEL_DK)
        part(m, 0.0, 0.38, 0.44, -0.125, 0.16, 0.02, LEATHER, LEATHER)
        # headband
        part(m, 0.0, 0.78, 0.83, -0.12, 0.115, 0.02, body, body)
        # greatsword: grip, guard, long blade
        part(m, 0.30, 0.34, 0.52, -0.02, 0.028, 0.028, LEATHER_DK, LEATHER_DK)
        part(m, 0.30, 0.52, 0.57, -0.02, 0.10, 0.035, GOLD, GOLD)
        part(m, 0.30, 0.57, 1.06, -0.02, 0.045, 0.018, STEEL, STEEL_DK)
        part(m, 0.30, 1.06, 1.14, -0.02, 0.022, 0.014, STEEL, STEEL)

    elif role == "healer":
        # robed, hooded, staff held clear of the body so it reads in silhouette
        humanoid(m, dict(leg_top=0.26, torso_top=0.64, head_top=0.84,
                         torso_hw=0.16, torso_hd=0.105, skin=SKIN_HUMAN,
                         cloth=body, cloth_lt=light, boot=CLOTH_DK))
        # robe skirt: narrower than the arms so the sleeves still show
        part(m, 0.0, 0.02, 0.20, 0.0, 0.205, 0.145, body, body)
        part(m, 0.0, 0.20, 0.40, 0.0, 0.180, 0.125, light, body)
        # hem trim breaks up the flat robe
        part(m, 0.0, 0.02, 0.06, 0.0, 0.215, 0.152, TRIM_W, TRIM_W)
        # hood, darker than the robe so the head separates
        part(m, 0.0, 0.62, 0.90, 0.01, 0.145, 0.125, HOOD_G, HOOD_G)
        part(m, 0.0, 0.66, 0.80, -0.125, 0.105, 0.02, BONE_DARK, BONE_DARK)
        # large chest sigil
        part(m, 0.0, 0.44, 0.60, -0.11, 0.032, 0.02, TRIM_W, TRIM_W)
        part(m, 0.0, 0.50, 0.555, -0.11, 0.095, 0.02, TRIM_W, TRIM_W)
        # staff held well clear of the robe, orb above head height
        part(m, -0.30, 0.0, 0.92, -0.04, 0.028, 0.028, LEATHER, LEATHER)
        part(m, -0.30, 0.92, 1.06, -0.04, 0.070, 0.070, light, light)
        part(m, -0.30, 1.06, 1.11, -0.04, 0.034, 0.034, TRIM_W, TRIM_W)
        part(m, -0.30, 0.86, 0.90, -0.04, 0.055, 0.055, GOLD, GOLD)

    elif role == "ranged":
        # hooded scout, longbow, quiver on the back -- slimmest silhouette
        humanoid(m, dict(leg_top=0.33, torso_top=0.65, head_top=0.85,
                         torso_hw=0.15, torso_hd=0.10, skin=SKIN_HUMAN,
                         cloth=body, cloth_lt=light, boot=LEATHER_DK,
                         arm_fwd=-0.04, leg_gap=0.55))
        # hood + short cape
        part(m, 0.0, 0.63, 0.88, 0.01, 0.125, 0.11, body, body)
        part(m, 0.0, 0.66, 0.79, -0.105, 0.09, 0.02, BONE_DARK, BONE_DARK)
        part(m, 0.0, 0.40, 0.66, 0.11, 0.16, 0.025, LEATHER, LEATHER_DK)
        # quiver with arrow fletchings
        part(m, 0.13, 0.44, 0.74, 0.13, 0.05, 0.05, LEATHER_DK, LEATHER_DK)
        for ax in (-0.03, 0.0, 0.03):
            part(m, 0.13 + ax, 0.74, 0.84, 0.13, 0.012, 0.012, TRIM_W, TRIM_W)
        # longbow: limbs angled, string down the front
        part(m, -0.26, 0.22, 0.42, -0.02, 0.020, 0.030, LEATHER, LEATHER)
        part(m, -0.29, 0.42, 0.70, -0.02, 0.020, 0.030, LEATHER, LEATHER)
        part(m, -0.26, 0.70, 0.90, -0.02, 0.020, 0.030, LEATHER, LEATHER)
        part(m, -0.24, 0.24, 0.88, -0.02, 0.008, 0.008, TRIM_W, TRIM_W)

    return m


# ── Enemies ─────────────────────────────────────────────────────────────────
def build_slime_mesh():
    """Classic slime: a single smooth onion dome, wide-bottomed and rounded."""
    body = rgba(0x46B45AFF)
    lite = rgba(0x9FEFAAFF)
    dark = rgba(0x2E8442FF)
    m = Mesh()
    # bottom-to-top (radius, y): bulges just above the floor, rounds over
    profile = [
        (0.00, 0.000), (0.300, 0.030), (0.352, 0.100), (0.336, 0.215),
        (0.268, 0.330), (0.170, 0.425), (0.062, 0.487), (0.000, 0.505),
    ]
    m.revolve(0.0, 0.0, 0.0, profile, body, lite, segs=8, squash_z=0.95)
    # darker contact ring
    m.revolve(0.0, 0.0, 0.0, [(0.00, 0.0), (0.305, 0.026)],
              dark, dark, segs=8, squash_z=0.95)
    # highlight and a drip on the front
    m.ellipsoid(-0.115, 0.315, -0.205, 0.055, 0.038, 0.030, TRIM_W, TRIM_W,
                segs=5, rings=3)
    m.ellipsoid(0.150, 0.075, -0.250, 0.048, 0.062, 0.038, lite, lite,
                segs=5, rings=3)
    eyes(m, 0.265, -0.290, 0.098, BONE_DARK, w=0.048, h=0.040, d=0.022)
    return m


def build_goblin_mesh():
    """Small, hunched, oversized ears, crude dagger -- reads as 'weak swarm'."""
    m = Mesh()
    hw = humanoid(m, dict(leg_top=0.20, torso_top=0.44, head_top=0.64,
                          torso_hw=0.135, torso_hd=0.095, skin=SKIN_GOBLIN,
                          cloth=LEATHER, cloth_lt=LEATHER, boot=LEATHER_DK,
                          hunch=0.03, arm_fwd=-0.03, leg_gap=0.55))
    # big pointed ears
    for sx in (-1, 1):
        part(m, sx * (hw + 0.055), 0.50, 0.60, -0.03, 0.055, 0.022,
             SKIN_GOBLIN, SKIN_GOBLIN)
        part(m, sx * (hw + 0.095), 0.56, 0.64, -0.03, 0.030, 0.016,
             SKIN_GOBLIN, SKIN_GOBLIN)
    # loincloth + dagger
    part(m, 0.0, 0.16, 0.26, 0.0, 0.15, 0.11, LEATHER_DK, LEATHER_DK)
    part(m, 0.20, 0.22, 0.32, -0.04, 0.020, 0.020, LEATHER_DK, LEATHER_DK)
    part(m, 0.20, 0.32, 0.52, -0.04, 0.028, 0.012, STEEL, STEEL_DK)
    eyes(m, 0.55, -0.10, 0.055, EYE_RED, w=0.028, h=0.020, d=0.014)
    return m


def build_skeleton_mesh():
    """Bare bones: gapped ribcage, skull with sockets, notched sword."""
    m = Mesh()
    # legs (thin, no cloth)
    for sx in (-1, 1):
        part(m, sx * 0.075, 0.0, 0.34, 0.0, 0.038, 0.038, BONE, BONE)
    # pelvis + spine
    part(m, 0.0, 0.34, 0.40, 0.0, 0.105, 0.075, BONE, BONE)
    part(m, 0.0, 0.40, 0.62, 0.0, 0.040, 0.045, BONE, BONE)
    # ribs -- separate bars so the gaps read as a ribcage
    for i, ry in enumerate((0.44, 0.50, 0.56)):
        w = 0.135 - i * 0.012
        part(m, 0.0, ry, ry + 0.032, -0.03, w, 0.055, BONE, BONE)
    # shoulders + arms
    part(m, 0.0, 0.62, 0.68, 0.0, 0.145, 0.05, BONE, BONE)
    for sx in (-1, 1):
        part(m, sx * 0.155, 0.38, 0.64, 0.0, 0.034, 0.034, BONE, BONE)
    # skull
    part(m, 0.0, 0.68, 0.86, 0.0, 0.105, 0.095, BONE, BONE)
    part(m, 0.0, 0.68, 0.73, -0.06, 0.075, 0.035, BONE, BONE)   # jaw
    eyes(m, 0.79, -0.10, 0.048, BONE_DARK, w=0.032, h=0.026, d=0.016)
    # sword
    part(m, 0.24, 0.30, 0.42, 0.0, 0.024, 0.024, LEATHER_DK, LEATHER_DK)
    part(m, 0.24, 0.42, 0.46, 0.0, 0.075, 0.028, STEEL_DK, STEEL_DK)
    part(m, 0.24, 0.46, 0.84, 0.0, 0.036, 0.014, STEEL, STEEL_DK)
    return m


def build_bat_mesh():
    """Flyer: hovers off the floor, wings swept out, ears up."""
    body = rgba(0x6A4A7AFF)
    wing = rgba(0x4A3357FF)
    m = Mesh()
    base = 0.34                      # hovers above the ground
    part(m, 0.0, base, base + 0.24, 0.0, 0.125, 0.135, body, body)
    part(m, 0.0, base + 0.24, base + 0.40, -0.02, 0.105, 0.10, body, body)
    for sx in (-1, 1):
        part(m, sx * 0.11, base + 0.40, base + 0.52, -0.02, 0.032, 0.018,
             body, body)                                    # ears
        part(m, sx * 0.20, base + 0.12, base + 0.26, 0.0, 0.10, 0.055,
             wing, wing)                                    # inner wing
        part(m, sx * 0.36, base + 0.16, base + 0.30, 0.0, 0.09, 0.045,
             wing, wing)                                    # outer wing
        part(m, sx * 0.50, base + 0.20, base + 0.30, 0.0, 0.06, 0.035,
             wing, wing)                                    # wingtip
    eyes(m, base + 0.31, -0.13, 0.05, EYE_RED, w=0.028, h=0.022, d=0.014)
    return m


def build_spider_mesh():
    """Rounded abdomen and head carried on eight arched legs."""
    body = rgba(0x3B3547FF)
    lite = rgba(0x5C5270FF)
    m = Mesh()
    base = 0.22
    # abdomen: ellipsoid, longer in Z than it is wide
    m.ellipsoid(0.0, base + 0.09, 0.15, 0.185, 0.135, 0.215, body, lite,
                segs=8, rings=4)
    # cephalothorax
    m.ellipsoid(0.0, base + 0.05, -0.11, 0.135, 0.105, 0.135, body, lite,
                segs=8, rings=4)
    # head / mouthparts
    m.ellipsoid(0.0, base + 0.02, -0.245, 0.085, 0.070, 0.075, body, body,
                segs=6, rings=3)
    # 8 legs: up to a knee, then down to the floor
    for sx in (-1, 1):
        for lz in (-0.16, -0.03, 0.11, 0.24):
            part(m, sx * 0.17, base + 0.02, base + 0.16, lz,
                 0.072, 0.024, lite, body)
            part(m, sx * 0.28, base + 0.11, base + 0.21, lz,
                 0.052, 0.022, lite, body)
            part(m, sx * 0.335, 0.0, base + 0.15, lz,
                 0.026, 0.020, body, body)
    eyes(m, base + 0.075, -0.310, 0.048, EYE_RED, w=0.026, h=0.020, d=0.014)
    eyes(m, base + 0.030, -0.305, 0.084, EYE_RED, w=0.020, h=0.016, d=0.012)
    for sx in (-1, 1):
        part(m, sx * 0.042, base - 0.055, base + 0.005, -0.290,
             0.020, 0.020, BONE, BONE)
    return m


def build_zombie_mesh():
    """Shambler: asymmetric pose, one arm out, tattered clothing."""
    m = Mesh()
    humanoid(m, dict(leg_top=0.28, torso_top=0.60, head_top=0.80,
                     torso_hw=0.165, torso_hd=0.11, skin=SKIN_ZOMBIE,
                     cloth=rgba(0x4E5540FF), cloth_lt=rgba(0x626A52FF),
                     boot=LEATHER_DK, hunch=0.04, leg_gap=0.45))
    # right arm thrust forward, left hanging low -- breaks the symmetry
    part(m, 0.24, 0.50, 0.58, -0.20, 0.055, 0.12, SKIN_ZOMBIE, SKIN_ZOMBIE)
    part(m, -0.23, 0.26, 0.50, 0.02, 0.050, 0.050, SKIN_ZOMBIE, SKIN_ZOMBIE)
    # torn shirt hem and exposed ribs
    part(m, 0.0, 0.30, 0.36, -0.115, 0.15, 0.02, rgba(0x3A4030FF),
         rgba(0x3A4030FF))
    part(m, -0.06, 0.44, 0.50, -0.115, 0.05, 0.02, SKIN_ZOMBIE, SKIN_ZOMBIE)
    eyes(m, 0.72, -0.11, 0.052, EYE_GREEN, w=0.028, h=0.022, d=0.014)
    part(m, 0.0, 0.64, 0.68, -0.10, 0.06, 0.02, BONE_DARK, BONE_DARK)  # mouth
    return m


def build_orc_mesh():
    """Brute: broadest humanoid, tusks, heavy club, hunched shoulders."""
    m = Mesh()
    hw = humanoid(m, dict(leg_top=0.30, torso_top=0.70, head_top=0.88,
                          torso_hw=0.245, torso_hd=0.16, skin=SKIN_ORC,
                          cloth=SKIN_ORC, cloth_lt=rgba(0x5E8C48FF),
                          boot=LEATHER_DK, hunch=0.05, leg_gap=0.5))
    # hulking shoulders
    for sx in (-1, 1):
        part(m, sx * 0.29, 0.60, 0.74, -0.02, 0.09, 0.15, rgba(0x5E8C48FF),
             SKIN_ORC)
    # harness + belt
    part(m, 0.0, 0.44, 0.52, -0.17, 0.20, 0.02, LEATHER, LEATHER)
    part(m, 0.0, 0.34, 0.42, -0.17, 0.24, 0.02, LEATHER_DK, LEATHER_DK)
    # tusks + brow
    for sx in (-1, 1):
        part(m, sx * 0.06, 0.72, 0.79, -0.16, 0.022, 0.02, BONE, BONE)
    part(m, 0.0, 0.82, 0.86, -0.15, 0.14, 0.02, rgba(0x3E6230FF),
         rgba(0x3E6230FF))
    eyes(m, 0.79, -0.155, 0.07, EYE_RED, w=0.030, h=0.022, d=0.014)
    # spiked club
    part(m, 0.38, 0.18, 0.62, -0.02, 0.036, 0.036, LEATHER_DK, LEATHER_DK)
    part(m, 0.38, 0.62, 0.84, -0.02, 0.085, 0.085, LEATHER, LEATHER_DK)
    for sx in (-1, 1):
        part(m, 0.38 + sx * 0.10, 0.70, 0.76, -0.02, 0.028, 0.028, BONE, BONE)
    return m


def build_wraith_mesh():
    """Undead spirit: floats, tapers to nothing, hollow hood, no legs."""
    robe = rgba(0x2E2A44FF)
    robe_lt = rgba(0x453F63FF)
    m = Mesh()
    # tapering tail instead of legs -- narrowest at the bottom
    part(m, 0.0, 0.06, 0.16, 0.0, 0.055, 0.05, robe, robe)
    part(m, 0.0, 0.16, 0.30, 0.0, 0.115, 0.10, robe, robe)
    part(m, 0.0, 0.30, 0.50, 0.0, 0.175, 0.14, robe, robe)
    part(m, 0.0, 0.50, 0.70, 0.0, 0.20, 0.15, robe_lt, robe)
    # outspread sleeves
    for sx in (-1, 1):
        part(m, sx * 0.26, 0.50, 0.62, -0.04, 0.09, 0.10, robe_lt, robe)
        part(m, sx * 0.36, 0.44, 0.54, -0.06, 0.05, 0.06, robe, robe)
    # hood with a hollow, glowing interior
    part(m, 0.0, 0.70, 0.94, 0.01, 0.155, 0.135, robe_lt, robe)
    part(m, 0.0, 0.74, 0.88, -0.13, 0.105, 0.02, rgba(0x0A0812FF),
         rgba(0x0A0812FF))
    eyes(m, 0.81, -0.145, 0.052, EYE_GREEN, w=0.030, h=0.024, d=0.014)
    return m


def build_boss_mesh():
    """Demon lord: the largest silhouette -- horns, wings, glowing eyes."""
    body = rgba(0x7E2F96FF)
    lite = rgba(0xAA57C4FF)
    horn = rgba(0xE8D8F0FF)
    wing = rgba(0x4A1B5AFF)
    m = Mesh()
    # legs + hooves
    for sx in (-1, 1):
        part(m, sx * 0.16, 0.0, 0.10, 0.0, 0.10, 0.11, BONE_DARK, BONE_DARK)
        part(m, sx * 0.16, 0.10, 0.44, 0.0, 0.095, 0.095, body, body)
    # torso + chest plate
    part(m, 0.0, 0.44, 0.92, -0.02, 0.30, 0.19, lite, body)
    part(m, 0.0, 0.56, 0.78, -0.20, 0.20, 0.02, rgba(0x561F66FF),
         rgba(0x561F66FF))
    # shoulders + arms
    for sx in (-1, 1):
        part(m, sx * 0.36, 0.80, 0.96, 0.0, 0.11, 0.16, lite, body)
        part(m, sx * 0.40, 0.46, 0.82, 0.0, 0.075, 0.075, body, body)
        part(m, sx * 0.40, 0.36, 0.46, -0.04, 0.09, 0.09, BONE_DARK, BONE_DARK)
    # head, brow, jaw
    part(m, 0.0, 0.92, 1.20, -0.02, 0.185, 0.16, lite, lite)
    part(m, 0.0, 1.06, 1.11, -0.17, 0.15, 0.02, rgba(0x561F66FF),
         rgba(0x561F66FF))
    part(m, 0.0, 0.94, 1.00, -0.15, 0.10, 0.03, BONE_DARK, BONE_DARK)
    eyes(m, 1.03, -0.175, 0.085, EYE_RED, w=0.045, h=0.032, d=0.018)
    # swept horns
    for sx in (-1, 1):
        part(m, sx * 0.17, 1.20, 1.34, -0.02, 0.055, 0.055, horn, horn)
        part(m, sx * 0.25, 1.30, 1.44, -0.02, 0.045, 0.045, horn, horn)
        part(m, sx * 0.33, 1.40, 1.50, -0.02, 0.030, 0.030, horn, horn)
    # folded wings behind the shoulders
    for sx in (-1, 1):
        part(m, sx * 0.40, 0.62, 1.10, 0.20, 0.055, 0.10, wing, wing)
        part(m, sx * 0.50, 0.74, 1.22, 0.22, 0.05, 0.09, wing, wing)
        part(m, sx * 0.58, 0.88, 1.16, 0.22, 0.04, 0.07, wing, wing)
    return m


# ── Level set ───────────────────────────────────────────────────────────────
# Three levels per biome. The game picks one at random each run.
LEVEL_SPECS = [
    (BIOME_DUNGEON, 1101), (BIOME_DUNGEON, 2027), (BIOME_DUNGEON, 3313),
    (BIOME_FOREST,  4409), (BIOME_FOREST,  5501), (BIOME_FOREST,  6607),
]


def emit_level_data(levels, path):
    """Write the tile masks as a Pak module so gameplay matches the geometry.

    Tiles are packed one bit each (set = floor), which keeps the whole level
    set to well under a kilobyte of ROM.
    """
    per_level = (GRID_W * GRID_H + 7) // 8
    words = []
    for lv in levels:
        for byte_i in range(per_level):
            v = 0
            for bit in range(8):
                t = byte_i * 8 + bit
                if t < GRID_W * GRID_H and lv.tiles[t] == TILE_FLOOR:
                    v |= (1 << bit)
            words.append(v)

    def fmt(vals, per_row=16):
        out = []
        for i in range(0, len(vals), per_row):
            out.append("    " + ", ".join(str(v) for v in vals[i:i + per_row]))
        return ",\n".join(out)

    biomes = [lv.biome for lv in levels]
    starts = [lv.start_room for lv in levels]
    bosses = [lv.boss_room for lv in levels]

    # Hero start positions: 4x (gx, gy) per level, flattened.
    hero_xy = []
    for lv in levels:
        for (gx, gy) in lv.hero_start:
            hero_xy += [gx, gy]

    # Enemy spawns: fixed-width MAX_ENEMIES_PER_LEVEL slots of (gx, gy, kind),
    # padded with (0, 0, 255) so the game can tell a slot is unused by
    # checking kind == 255 rather than needing a separate count table.
    max_spawns = max((len(lv.enemy_spawns) for lv in levels), default=0)
    enemy_xyz = []
    for lv in levels:
        for i in range(max_spawns):
            if i < len(lv.enemy_spawns):
                gx, gy, k = lv.enemy_spawns[i]
            else:
                gx, gy, k = 0, 0, 255
            enemy_xyz += [gx, gy, k]

    src = f"""-- src/levels.pk64 -- GENERATED by tools/gen_dungeon_models.py. DO NOT EDIT.
--
-- Tile masks, spawn tables and biome tags for every baked level. Regenerate
-- with:  python3 tools/gen_dungeon_models.py
--
-- Every value is reached through an accessor function, not the bare consts
-- and statics below. Pak's multi-file support is [PARTIAL] (see
-- LANGUAGE.md / examples/canonical/20_multifile.pk64): functions cross a
-- `use module.path` boundary, but top-level `const`/`static` do not --
-- confirmed by hand with a 2-file repro before writing this generator to
-- rely on it. Accessor functions are the working path.
module dungeon.levels

const LEVEL_COUNT:      i32 = {len(levels)}
const LEVEL_TILE_BYTES: i32 = {per_level}
const LEVEL_MAX_SPAWNS: i32 = {max_spawns}
const SPAWN_EMPTY:      u8  = 255

const BIOME_DUNGEON: u8 = 0
const BIOME_FOREST:  u8 = 1

-- packed floor bitmap, LEVEL_COUNT * LEVEL_TILE_BYTES bytes (1 = floor)
static level_bits: [{len(words)}]u8 = [
{fmt(words)}
]

static level_biome: [{len(biomes)}]u8 = [{", ".join(str(b) for b in biomes)}]

-- cell index (0..8) of the room the party starts in / the boss occupies
static level_start_cell: [{len(starts)}]u8 = [{", ".join(str(v) for v in starts)}]
static level_boss_cell:  [{len(bosses)}]u8 = [{", ".join(str(v) for v in bosses)}]

-- hero start tiles: LEVEL_COUNT * 4 * (gx, gy)
static level_hero_xy: [{len(hero_xy)}]u8 = [
{fmt(hero_xy)}
]

-- enemy spawns: LEVEL_COUNT * LEVEL_MAX_SPAWNS * (gx, gy, kind_id).
-- kind_id == SPAWN_EMPTY marks an unused slot.
static level_enemy_xyz: [{len(enemy_xyz)}]u8 = [
{fmt(enemy_xyz)}
]

-- ── Accessors (the actual cross-module API) ─────────────────────────────────
fn level_count() -> i32 {{ return LEVEL_COUNT }}
fn level_tile_bytes() -> i32 {{ return LEVEL_TILE_BYTES }}
fn level_max_spawns() -> i32 {{ return LEVEL_MAX_SPAWNS }}
fn spawn_empty_id() -> u8 {{ return SPAWN_EMPTY }}
fn biome_dungeon_id() -> u8 {{ return BIOME_DUNGEON }}
fn biome_forest_id() -> u8 {{ return BIOME_FOREST }}

fn level_floor_byte(lvl: i32, byte_i: i32) -> u8 {{
    return level_bits[lvl * LEVEL_TILE_BYTES + byte_i]
}}

fn level_biome_of(lvl: i32) -> u8 {{
    return level_biome[lvl]
}}

fn level_hero_x(lvl: i32, slot: i32) -> u8 {{
    return level_hero_xy[lvl * 8 + slot * 2]
}}

fn level_hero_y(lvl: i32, slot: i32) -> u8 {{
    return level_hero_xy[lvl * 8 + slot * 2 + 1]
}}

fn level_spawn_x(lvl: i32, slot: i32) -> u8 {{
    return level_enemy_xyz[(lvl * LEVEL_MAX_SPAWNS + slot) * 3]
}}

fn level_spawn_y(lvl: i32, slot: i32) -> u8 {{
    return level_enemy_xyz[(lvl * LEVEL_MAX_SPAWNS + slot) * 3 + 1]
}}

fn level_spawn_kind(lvl: i32, slot: i32) -> u8 {{
    return level_enemy_xyz[(lvl * LEVEL_MAX_SPAWNS + slot) * 3 + 2]
}}
"""
    with open(path, "w") as f:
        f.write(src)
    total_spawns = sum(len(lv.enemy_spawns) for lv in levels)
    print(f"  {os.path.basename(path):22s} {len(words)}B tiles, "
          f"{len(hero_xy)}B hero starts, {len(enemy_xyz)}B spawns "
          f"({total_spawns} enemies across {len(levels)} levels)")


def main():
    global CURRENT
    out = os.path.normpath(OUT_DIR)
    os.makedirs(out, exist_ok=True)
    print(f"Writing dungeon models -> {out}")
    print(f"  level {GRID_W}x{GRID_H}, {CHUNK_COLS}x{CHUNK_ROWS} chunks "
          f"of {CHUNK_W}x{CHUNK_H} tiles")

    # clear stale chunk models from previous runs
    for old in os.listdir(out):
        if old.startswith(("dungeon_c", "lv")) and old.endswith(".glb"):
            os.remove(os.path.join(out, old))

    levels = []
    total_tris = 0
    for idx, (biome, seed) in enumerate(LEVEL_SPECS):
        lv = generate_level(idx, biome, seed)
        CURRENT = lv
        levels.append(lv)
        lt = 0
        for cy in range(CHUNK_ROWS):
            for cx in range(CHUNK_COLS):
                ci = cy * CHUNK_COLS + cx
                mesh = build_level_mesh(lv, cx, cy)
                write_glb(mesh, os.path.join(out, f"lv{idx}_c{ci}.glb"))
                lt += len(mesh.idx) // 3
        floors = sum(1 for t in lv.tiles if t == TILE_FLOOR)
        print(f"  -- level {idx} ({BIOME_NAMES[biome]}, seed {seed}): "
              f"{floors} floor tiles, {lt} tris")
        total_tris += lt

    models = []
    for role in ("tank", "melee", "healer", "ranged"):
        models.append((f"hero_{role}.glb", build_hero_mesh(role)))
    for name, fn in (("slime", build_slime_mesh),
                     ("goblin", build_goblin_mesh),
                     ("skeleton", build_skeleton_mesh),
                     ("bat", build_bat_mesh),
                     ("spider", build_spider_mesh),
                     ("zombie", build_zombie_mesh),
                     ("orc", build_orc_mesh),
                     ("wraith", build_wraith_mesh),
                     ("boss", build_boss_mesh)):
        models.append((f"enemy_{name}.glb", fn()))

    for name, mesh in models:
        write_glb(mesh, os.path.join(out, name))
        total_tris += len(mesh.idx) // 3

    emit_level_data(levels, os.path.join(
        os.path.dirname(out), "..", "src", "levels.pk64"))

    print(f"Done -- {len(levels)} levels + {len(models)} character models, "
          f"{total_tris} triangles total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
