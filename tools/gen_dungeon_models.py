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
    enemy_skeleton.glb   \
    enemy_slime.glb       |  3 enemy types
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
GRID_W, GRID_H = 16, 12
TILE_WALL, TILE_FLOOR = 0, 1

TILE = 1.0          # world units per grid tile
WALL_H = 1.05       # wall block height
FLOOR_Y = 0.0

OUT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "demos", "dungeon_quartet", "assets", "models")


def build_level():
    lv = [TILE_WALL] * (GRID_W * GRID_H)

    def room(x0, y0, x1, y1):
        for gy in range(y0, y1 + 1):
            for gx in range(x0, x1 + 1):
                lv[gy * GRID_W + gx] = TILE_FLOOR

    def hc(x0, x1, gy):
        for gx in range(x0, x1 + 1):
            lv[gy * GRID_W + gx] = TILE_FLOOR

    def vc(y0, y1, gx):
        for gy in range(y0, y1 + 1):
            lv[gy * GRID_W + gx] = TILE_FLOOR

    room(1, 1, 4, 4)        # A  start room
    room(7, 1, 10, 3)       # B
    room(6, 5, 9, 8)        # C  central hub
    room(1, 6, 4, 9)        # D
    room(11, 5, 14, 8)      # E
    room(10, 9, 14, 11)     # F  boss room
    hc(4, 7, 2)
    vc(4, 6, 2)
    vc(3, 5, 8)
    hc(4, 6, 7)
    hc(9, 11, 6)
    vc(8, 9, 12)
    return lv


LEVEL = build_level()


def tile_at(gx, gy):
    if gx < 0 or gx >= GRID_W or gy < 0 or gy >= GRID_H:
        return TILE_WALL
    return LEVEL[gy * GRID_W + gx]


def is_boss_room(gx, gy):
    return 10 <= gx <= 14 and 9 <= gy <= 11


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

TRIM = rgba(0xF2ECDCFF)
STEEL = rgba(0xC8CCD8FF)

ROLE = {
    "tank":   (rgba(0x4C7CE0FF), rgba(0x86AEF4FF)),
    "melee":  (rgba(0xE04C4CFF), rgba(0xF48E8EFF)),
    "healer": (rgba(0x3ED27AFF), rgba(0x84E8AEFF)),
    "ranged": (rgba(0xE0BC38FF), rgba(0xF4DC8AFF)),
}


# ── Level mesh ──────────────────────────────────────────────────────────────
def build_dungeon_mesh():
    """Whole static level as one mesh.

    Interior wall faces (those touching another wall) are dropped, and walls
    with no floor neighbour at all are skipped outright -- that removes most
    of the solid rock and keeps the model small.
    """
    m = Mesh()

    for gy in range(GRID_H):
        for gx in range(GRID_W):
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

            # wall tile: only keep it if it borders walkable floor
            nb = [(1, 0), (-1, 0), (0, 1), (0, -1)]
            if not any(tile_at(gx + dx, gy + dy) == TILE_FLOOR for dx, dy in nb):
                continue

            cy = WALL_H / 2.0
            m.quad((wx - h, WALL_H, wz + h), (wx + h, WALL_H, wz + h),
                   (wx + h, WALL_H, wz - h), (wx - h, WALL_H, wz - h),
                   WALL_TOP, (0, 1, 0))

            side_dark = tuple(c * 0.80 for c in WALL_SIDE[:3]) + (1.0,)
            # +Z face
            if tile_at(gx, gy + 1) == TILE_FLOOR:
                m.quad((wx - h, 0, wz + h), (wx + h, 0, wz + h),
                       (wx + h, WALL_H, wz + h), (wx - h, WALL_H, wz + h),
                       WALL_SIDE, (0, 0, 1))
            # -Z face
            if tile_at(gx, gy - 1) == TILE_FLOOR:
                m.quad((wx + h, 0, wz - h), (wx - h, 0, wz - h),
                       (wx - h, WALL_H, wz - h), (wx + h, WALL_H, wz - h),
                       WALL_SIDE, (0, 0, -1))
            # +X face
            if tile_at(gx + 1, gy) == TILE_FLOOR:
                m.quad((wx + h, 0, wz + h), (wx + h, 0, wz - h),
                       (wx + h, WALL_H, wz - h), (wx + h, WALL_H, wz + h),
                       side_dark, (1, 0, 0))
            # -X face
            if tile_at(gx - 1, gy) == TILE_FLOOR:
                m.quad((wx - h, 0, wz - h), (wx - h, 0, wz + h),
                       (wx - h, WALL_H, wz + h), (wx - h, WALL_H, wz - h),
                       side_dark, (-1, 0, 0))
    return m


# ── Character meshes ────────────────────────────────────────────────────────
# Units stand on the floor plane (y = 0) and face +Z. Kept blocky and low-poly
# on purpose -- these read at N64 resolution and match the 2D silhouettes.
def build_hero_mesh(role):
    body, light = ROLE[role]
    m = Mesh()

    bw = 0.17
    if role == "tank":
        bw = 0.21
    if role == "ranged":
        bw = 0.15

    m.box(0, 0.05, 0, bw + 0.03, 0.05, 0.13, body, body)          # boots
    m.box(0, 0.30, 0, bw, 0.20, 0.12, light, body)                # torso
    m.box(0, 0.585, 0, 0.115, 0.085, 0.105, light, light)         # head
    m.box(0, 0.60, -0.055, 0.085, 0.055, 0.06, TRIM, TRIM)        # face plate

    if role == "tank":
        m.box(bw + 0.10, 0.32, 0, 0.045, 0.20, 0.16, STEEL, STEEL)   # shield
        m.box(0, 0.70, 0, 0.075, 0.045, 0.075, STEEL, STEEL)         # helm crest
    elif role == "melee":
        m.box(bw + 0.10, 0.45, 0, 0.035, 0.30, 0.035, STEEL, STEEL)  # blade
        m.box(bw + 0.10, 0.20, 0, 0.06, 0.05, 0.06, TRIM, TRIM)      # hilt
    elif role == "healer":
        m.box(0, 0.34, -0.13, 0.045, 0.115, 0.02, TRIM, TRIM)        # cross
        m.box(0, 0.365, -0.13, 0.105, 0.04, 0.02, TRIM, TRIM)
        m.box(-bw - 0.09, 0.42, 0, 0.03, 0.28, 0.03, TRIM, TRIM)     # staff
    elif role == "ranged":
        m.box(-bw - 0.09, 0.40, 0, 0.03, 0.26, 0.03, TRIM, TRIM)     # bow stave
        m.box(-bw - 0.09, 0.40, 0.055, 0.012, 0.24, 0.012, STEEL, STEEL)
    return m


def build_skeleton_mesh():
    bone = rgba(0xD8D8CCFF)
    dark = rgba(0x241E24FF)
    m = Mesh()
    m.box(0, 0.05, 0, 0.13, 0.05, 0.10, bone, bone)
    m.box(0, 0.28, 0, 0.115, 0.18, 0.085, bone, bone)
    # rib gaps
    m.box(0, 0.30, -0.09, 0.09, 0.02, 0.012, dark, dark)
    m.box(0, 0.23, -0.09, 0.09, 0.02, 0.012, dark, dark)
    m.box(0, 0.535, 0, 0.115, 0.085, 0.10, bone, bone)
    m.box(-0.055, 0.55, -0.10, 0.028, 0.028, 0.015, dark, dark)
    m.box(0.055, 0.55, -0.10, 0.028, 0.028, 0.015, dark, dark)
    m.box(0.17, 0.34, 0, 0.028, 0.20, 0.028, bone, bone)
    return m


def build_slime_mesh():
    body = rgba(0x54B268FF)
    lite = rgba(0x9AE8A8FF)
    m = Mesh()
    m.box(0, 0.10, 0, 0.30, 0.10, 0.30, body, body)
    m.box(0, 0.245, 0, 0.22, 0.06, 0.22, body, body)
    m.box(0, 0.325, 0, 0.12, 0.03, 0.12, lite, lite)
    m.box(-0.10, 0.20, -0.22, 0.05, 0.05, 0.04, lite, lite)   # highlight
    m.box(0.07, 0.16, -0.26, 0.035, 0.035, 0.03, rgba(0x1C3A22FF),
          rgba(0x1C3A22FF))
    return m


def build_boss_mesh():
    body = rgba(0x8A3AA0FF)
    lite = rgba(0xB864CCFF)
    horn = rgba(0xE8D8F0FF)
    eye = rgba(0xFF4030FF)
    m = Mesh()
    m.box(0, 0.08, 0, 0.34, 0.08, 0.24, body, body)
    m.box(0, 0.42, 0, 0.30, 0.28, 0.20, lite, body)
    m.box(0, 0.55, -0.21, 0.20, 0.13, 0.02, rgba(0x50205CFF),
          rgba(0x50205CFF))
    m.box(0, 0.80, 0, 0.19, 0.13, 0.16, lite, lite)
    m.box(-0.24, 1.00, 0, 0.055, 0.16, 0.055, horn, horn)
    m.box(0.24, 1.00, 0, 0.055, 0.16, 0.055, horn, horn)
    m.box(-0.20, 0.86, 0, 0.05, 0.05, 0.05, horn, horn)
    m.box(0.20, 0.86, 0, 0.05, 0.05, 0.05, horn, horn)
    m.box(-0.085, 0.84, -0.17, 0.045, 0.030, 0.02, eye, eye)
    m.box(0.085, 0.84, -0.17, 0.045, 0.030, 0.02, eye, eye)
    m.box(-0.38, 0.44, 0, 0.06, 0.24, 0.06, body, body)
    m.box(0.38, 0.44, 0, 0.06, 0.24, 0.06, body, body)
    return m


def main():
    out = os.path.normpath(OUT_DIR)
    os.makedirs(out, exist_ok=True)
    print(f"Writing dungeon models -> {out}")

    models = [("dungeon.glb", build_dungeon_mesh())]
    for role in ("tank", "melee", "healer", "ranged"):
        models.append((f"hero_{role}.glb", build_hero_mesh(role)))
    models.append(("enemy_skeleton.glb", build_skeleton_mesh()))
    models.append(("enemy_slime.glb", build_slime_mesh()))
    models.append(("enemy_boss.glb", build_boss_mesh()))

    total_tris = 0
    for name, mesh in models:
        write_glb(mesh, os.path.join(out, name))
        total_tris += len(mesh.idx) // 3

    print(f"Done -- {len(models)} models, {total_tris} triangles total")
    return 0


if __name__ == "__main__":
    sys.exit(main())
