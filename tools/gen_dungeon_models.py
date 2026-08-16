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


# 3x3 grid of rooms, every neighbour joined by a 2-tile-wide corridor so two
# units can pass each other anywhere in the dungeon.
ROOMS = [
    (2, 2, 8, 6),    (12, 2, 19, 6),    (23, 2, 29, 6),
    (2, 10, 8, 15),  (12, 10, 19, 15),  (23, 10, 29, 15),
    (2, 18, 8, 22),  (12, 18, 19, 22),  (23, 18, 29, 22),
]
BOSS_ROOM = (23, 18, 29, 22)

CORRIDORS = [
    # horizontal links (x0, x1, y0, y1) -- 2 tiles tall
    (8, 12, 3, 4),   (19, 23, 3, 4),
    (8, 12, 12, 13), (19, 23, 12, 13),
    (8, 12, 19, 20), (19, 23, 19, 20),
    # vertical links -- 2 tiles wide
    (4, 5, 6, 10),   (15, 16, 6, 10),   (26, 27, 6, 10),
    (4, 5, 15, 18),  (15, 16, 15, 18),  (26, 27, 15, 18),
]


def build_level():
    lv = [TILE_WALL] * (GRID_W * GRID_H)

    def fill(x0, y0, x1, y1):
        for gy in range(y0, y1 + 1):
            for gx in range(x0, x1 + 1):
                lv[gy * GRID_W + gx] = TILE_FLOOR

    for (x0, y0, x1, y1) in ROOMS:
        fill(x0, y0, x1, y1)
    for (x0, x1, y0, y1) in CORRIDORS:
        fill(x0, y0, x1, y1)
    return lv


LEVEL = build_level()


def tile_at(gx, gy):
    if gx < 0 or gx >= GRID_W or gy < 0 or gy >= GRID_H:
        return TILE_WALL
    return LEVEL[gy * GRID_W + gx]


def is_boss_room(gx, gy):
    x0, y0, x1, y1 = BOSS_ROOM
    return x0 <= gx <= x1 and y0 <= gy <= y1


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
def build_dungeon_mesh(cx=None, cy=None):
    """Level geometry. With (cx, cy) given, emits only that chunk.

    Interior wall faces (those touching another wall) are dropped, and walls
    with no floor neighbour at all are skipped outright -- that removes most
    of the solid rock and keeps each chunk small.
    """
    m = Mesh()

    if cx is None:
        xr, yr = range(GRID_W), range(GRID_H)
    else:
        xr = range(cx * CHUNK_W, min(GRID_W, (cx + 1) * CHUNK_W))
        yr = range(cy * CHUNK_H, min(GRID_H, (cy + 1) * CHUNK_H))

    for gy in yr:
        for gx in xr:
            wx = (gx - (GRID_W - 1) / 2.0) * TILE
            wz = (gy - (GRID_H - 1) / 2.0) * TILE
            h = TILE / 2.0

            if tile_at(gx, gy) == TILE_FLOOR:
                if is_boss_room(gx, gy):
                    col = BOSS_A if (gx + gy) % 2 == 0 else BOSS_B
                else:
                    col = FLOOR_A if (gx + gy) % 2 == 0 else FLOOR_B
                m.quad((wx - h, FLOOR_Y, wz + h), (wx + h, FLOOR_Y, wz + h),
                       (wx + h, FLOOR_Y, wz - h), (wx - h, FLOOR_Y, wz - h),
                       col, (0, 1, 0))
                continue

            nb = [(1, 0), (-1, 0), (0, 1), (0, -1)]
            if not any(tile_at(gx + dx, gy + dy) == TILE_FLOOR for dx, dy in nb):
                # Interior rock: no exposed side faces, but it still needs a cap
                # or the camera sees straight through the level into the void.
                m.quad((wx - h, WALL_H, wz + h), (wx + h, WALL_H, wz + h),
                       (wx + h, WALL_H, wz - h), (wx - h, WALL_H, wz - h),
                       ROCK_TOP, (0, 1, 0))
                continue

            m.quad((wx - h, WALL_H, wz + h), (wx + h, WALL_H, wz + h),
                   (wx + h, WALL_H, wz - h), (wx - h, WALL_H, wz - h),
                   WALL_TOP, (0, 1, 0))

            side_dark = tuple(c * 0.80 for c in WALL_SIDE[:3]) + (1.0,)
            if tile_at(gx, gy + 1) == TILE_FLOOR:
                m.quad((wx - h, 0, wz + h), (wx + h, 0, wz + h),
                       (wx + h, WALL_H, wz + h), (wx - h, WALL_H, wz + h),
                       WALL_SIDE, (0, 0, 1))
            if tile_at(gx, gy - 1) == TILE_FLOOR:
                m.quad((wx + h, 0, wz - h), (wx - h, 0, wz - h),
                       (wx - h, WALL_H, wz - h), (wx + h, WALL_H, wz - h),
                       WALL_SIDE, (0, 0, -1))
            if tile_at(gx + 1, gy) == TILE_FLOOR:
                m.quad((wx + h, 0, wz + h), (wx + h, 0, wz - h),
                       (wx + h, WALL_H, wz - h), (wx + h, WALL_H, wz + h),
                       side_dark, (1, 0, 0))
            if tile_at(gx - 1, gy) == TILE_FLOOR:
                m.quad((wx - h, 0, wz - h), (wx - h, 0, wz + h),
                       (wx - h, WALL_H, wz + h), (wx - h, WALL_H, wz - h),
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
    """Gelatinous blob: a real curved dome, not a stack of boxes."""
    body = rgba(0x46B45AFF)
    lite = rgba(0x93EC9EFF)
    dark = rgba(0x2E8442FF)
    m = Mesh()
    # main body -- squashed dome, slightly deeper than wide
    m.dome(0.0, 0.0, 0.0, 0.33, 0.50, body, lite, segs=10, rings=5,
           squash_z=0.92)
    # a smaller dome offset forward reads as the blob bulging as it moves
    m.dome(0.0, 0.0, -0.10, 0.20, 0.30, body, lite, segs=8, rings=3,
           squash_z=0.9)
    # darker contact ring where it meets the floor
    m.dome(0.0, 0.0, 0.0, 0.345, 0.055, dark, dark, segs=10, rings=1,
           squash_z=0.92)
    # highlight and a drip on the front
    part(m, -0.12, 0.30, 0.40, -0.20, 0.05, 0.03, TRIM_W, TRIM_W)
    part(m, 0.16, 0.04, 0.14, -0.24, 0.042, 0.032, lite, lite)
    eyes(m, 0.27, -0.28, 0.10, BONE_DARK, w=0.05, h=0.042, d=0.02)
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
    """Raised body carried on eight arched legs, with a cluster of eyes."""
    body = rgba(0x3B3547FF)
    lite = rgba(0x5C5270FF)
    m = Mesh()
    base = 0.20                      # body rides above the leg joints
    part(m, 0.0, base, base + 0.20, 0.13, 0.19, 0.17, lite, body)   # abdomen
    part(m, 0.0, base - 0.02, base + 0.14, -0.12, 0.135, 0.115, body, body)
    part(m, 0.0, base + 0.02, base + 0.10, -0.25, 0.085, 0.055, body, body)
    # 8 legs, each rising to a knee then dropping to the floor
    for sx in (-1, 1):
        for lz in (-0.18, -0.05, 0.09, 0.22):
            part(m, sx * 0.17, base + 0.02, base + 0.16, lz,
                 0.075, 0.026, lite, body)          # upper, angled up
            part(m, sx * 0.28, base + 0.10, base + 0.20, lz,
                 0.055, 0.024, lite, body)          # knee
            part(m, sx * 0.34, 0.0, base + 0.14, lz,
                 0.028, 0.022, body, body)          # lower, down to floor
    eyes(m, base + 0.09, -0.31, 0.05, EYE_RED, w=0.026, h=0.020, d=0.014)
    eyes(m, base + 0.045, -0.31, 0.088, EYE_RED, w=0.020, h=0.016, d=0.012)
    for sx in (-1, 1):
        part(m, sx * 0.045, base - 0.04, base + 0.02, -0.30, 0.020, 0.020,
             BONE, BONE)                            # fangs
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


def main():
    out = os.path.normpath(OUT_DIR)
    os.makedirs(out, exist_ok=True)
    print(f"Writing dungeon models -> {out}")
    print(f"  level {GRID_W}x{GRID_H}, {CHUNK_COLS}x{CHUNK_ROWS} chunks "
          f"of {CHUNK_W}x{CHUNK_H} tiles")

    models = []
    for cy in range(CHUNK_ROWS):
        for cx in range(CHUNK_COLS):
            idx = cy * CHUNK_COLS + cx
            models.append((f"dungeon_c{idx}.glb", build_dungeon_mesh(cx, cy)))
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

    total_tris = 0
    for name, mesh in models:
        write_glb(mesh, os.path.join(out, name))
        total_tris += len(mesh.idx) // 3

    print(f"Done -- {len(models)} models, {total_tris} triangles total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
