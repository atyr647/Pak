#!/usr/bin/env python3
"""
make_rally_models.py — Generate low-poly N64 rally car + track .glb models.

Outputs: demos/assets/models/
  car_red.glb, car_blue.glb, car_yellow.glb, car_white.glb, track.glb

Run:
  python3 tools/make_rally_models.py
  # Then convert via the gltf_to_t3d tool:
  for f in demos/assets/models/*.glb; do
      /tmp/tiny3d/tools/gltf_importer/gltf_to_t3d "$f" "${f%.glb}.t3dm" --base-scale=1
  done
"""

import struct
import math
import os
import sys
import json
import base64

OUT_DIR = os.path.join(os.path.dirname(__file__), "..", "demos", "assets", "models")

# ─────────────────────────────────────────────────────────────────────────────
# Colour helpers (sRGB → linear for glTF vertex colours)
# gltf_to_t3d applies x^0.4545 (linear→gamma), so supply linear values.
# ─────────────────────────────────────────────────────────────────────────────

def srgb_to_linear(r8, g8, b8, a8=255):
    """Convert 0-255 sRGB to linear [0,1] tuple for glTF COLOR_0."""
    def c(v): return (v / 255.0) ** 2.2
    return (c(r8), c(g8), c(b8), a8 / 255.0)


# ─────────────────────────────────────────────────────────────────────────────
# Low-level geometry: coloured box with per-face normals
# ─────────────────────────────────────────────────────────────────────────────

def box_faces(mn, mx, face_colors):
    """
    Return (verts, norms, colors, indices) for a box from mn=(x0,y0,z0)
    to mx=(x1,y1,z1). face_colors is a list of 6 RGBA tuples [top, bot, +X, -X, +Z, -Z].
    Uses 4 verts per face for independent per-face normals/colors.
    """
    x0, y0, z0 = mn
    x1, y1, z1 = mx

    corners = {
        "tfl": (x0, y1, z0), "tfr": (x1, y1, z0),  # top-front
        "tbl": (x0, y1, z1), "tbr": (x1, y1, z1),  # top-back
        "bfl": (x0, y0, z0), "bfr": (x1, y0, z0),  # bot-front
        "bbl": (x0, y0, z1), "bbr": (x1, y0, z1),  # bot-back
    }

    # (face positions, normal, colour-index)
    face_defs = [
        # top
        ("tfl", "tfr", "tbr", "tbl"), (0, 1, 0), face_colors[0],
        # bottom
        ("bfl", "bbl", "bbr", "bfr"), (0, -1, 0), face_colors[1],
        # +X right
        ("bfr", "bbr", "tbr", "tfr"), (1, 0, 0), face_colors[2],
        # -X left
        ("bfl", "bfl", "tfl", "tbl"), (-1, 0, 0), face_colors[3],
        # +Z back / rear
        ("bbl", "bbl", "tbl", "tbr"), (0, 0, 1), face_colors[4],
        # -Z front
        ("bfr", "bfl", "tfl", "tfr"), (0, 0, -1), face_colors[5],
    ]

    # Pack differently: list of (v0,v1,v2,v3, norm, color) tuples
    faces = [
        [("tfl","tfr","tbr","tbl"), ( 0, 1, 0), face_colors[0]],  # top
        [("bfl","bbl","bbr","bfr"), ( 0,-1, 0), face_colors[1]],  # bottom
        [("bfr","bbr","tbr","tfr"), ( 1, 0, 0), face_colors[2]],  # right +X
        [("bbl","bfl","tfl","tbl"), (-1, 0, 0), face_colors[3]],  # left  -X
        [("bbl","bbr","tbr","tbl"), ( 0, 0, 1), face_colors[4]],  # back  +Z
        [("bfl","bfr","tfr","tfl"), ( 0, 0,-1), face_colors[5]],  # front -Z
    ]

    verts, norms, cols, idxs = [], [], [], []
    for (v0k, v1k, v2k, v3k), n, c in faces:
        base = len(verts)
        for vk in (v0k, v1k, v2k, v3k):
            verts.append(corners[vk])
            norms.append(n)
            cols.append(c)
        # two triangles: (0,1,2) and (0,2,3)
        idxs += [base, base+1, base+2, base, base+2, base+3]

    return verts, norms, cols, idxs


def shade(c, factor):
    """Return a colour tuple scaled by factor (for ambient occlusion / shadow)."""
    return tuple(min(1.0, v * factor) for v in c)


def merge_meshes(meshes):
    """Merge multiple (verts, norms, cols, idxs) tuples into one."""
    all_v, all_n, all_c, all_i = [], [], [], []
    for v, n, c, i in meshes:
        base = len(all_v)
        all_v.extend(v)
        all_n.extend(n)
        all_c.extend(c)
        all_i.extend(idx + base for idx in i)
    return all_v, all_n, all_c, all_i


# ─────────────────────────────────────────────────────────────────────────────
# Car model builder
# ─────────────────────────────────────────────────────────────────────────────

def make_car(body_col, cab_col, detail_col, under_col):
    """
    Build a low-poly rally car mesh centred at (0,0,0).
    Car faces -Z (front).  Dimensions in N64 world units (base-scale=1).
    Layout:
       body    4.0 × 1.8 × 0.9   (belly to window-sill)
       cab     1.9 × 1.6 × 0.75  (window-sill to roof)
       bumper  front box
       spoiler rear wing
       wheels  4 flat boxes at corners
    """
    L, W, H1 = 4.0, 1.8, 0.9   # body
    CL, CW, CH = 2.0, 1.55, 0.72  # cab
    cab_offset_z = 0.2           # cab shifted rearward

    # body colours: top slightly lighter, bottom darkest
    bT = shade(body_col, 1.10)   # top catch
    bB = shade(body_col, 0.55)   # belly in shadow
    bR = shade(body_col, 0.90)
    bL = shade(body_col, 0.80)
    bK = shade(body_col, 0.70)   # back
    bF = shade(body_col, 0.95)   # front nose

    # cab: lighter roof, dark pillars
    cT = shade(cab_col, 1.0)
    cB = shade(cab_col, 0.60)
    cS = shade(cab_col, 0.80)
    cF = shade(cab_col, 0.85)

    meshes = []

    # ── main body ──
    meshes.append(box_faces(
        (-W/2,  0.0, -L/2),
        ( W/2,  H1,   L/2),
        [bT, bB, bR, bL, bK, bF]
    ))

    # ── cab ──
    cz0 = -CL/2 + cab_offset_z
    cz1 = CL/2 + cab_offset_z
    meshes.append(box_faces(
        (-CW/2, H1, cz0),
        ( CW/2, H1+CH, cz1),
        [cT, cB, cS, cS, cF, cF]
    ))

    # ── front bumper ──
    bmp = shade(detail_col, 0.8)
    meshes.append(box_faces(
        (-W/2*0.75, 0.1, L/2),
        ( W/2*0.75, 0.38, L/2 + 0.2),
        [bmp]*6
    ))

    # ── rear spoiler mounts (two thin posts) ──
    post = shade(detail_col, 0.6)
    for sx in (-W/2*0.55, W/2*0.55):
        meshes.append(box_faces(
            (sx - 0.06, H1+CH*0.5, -L/2-0.05),
            (sx + 0.06, H1+CH+0.05, -L/2+0.05),
            [post]*6
        ))

    # ── rear wing blade ──
    wing = shade(detail_col, 0.85)
    meshes.append(box_faces(
        (-W/2*0.65, H1+CH+0.03, -L/2 - 0.22),
        ( W/2*0.65, H1+CH+0.12, -L/2 + 0.05),
        [wing]*6
    ))

    # ── wheel (flat box) helper ──
    wr = 0.58   # wheel radius
    wt = 0.24   # wheel thickness
    wh = 0.0    # wheel centre height

    wheel_col_outer = srgb_to_linear(25, 25, 25)    # dark tyre
    wheel_col_face  = srgb_to_linear(60, 60, 65)    # alloy face
    wheel_colors    = [wheel_col_face, wheel_col_face,
                       wheel_col_outer, wheel_col_outer,
                       wheel_col_outer, wheel_col_outer]

    for wx, wz in [(-W/2-wt/2+0.04,  L/2*0.55),
                   ( W/2-wt/2+0.04,  L/2*0.55),
                   (-W/2-wt/2+0.04, -L/2*0.55),
                   ( W/2-wt/2+0.04, -L/2*0.55)]:
        wc = [wheel_col_face, wheel_col_face,
              wheel_col_outer if wx > 0 else wheel_col_outer,
              wheel_col_outer if wx > 0 else wheel_col_outer,
              wheel_col_outer, wheel_col_outer]
        meshes.append(box_faces(
            (wx,          wh - wr, wz - wr),
            (wx + wt,     wh + wr, wz + wr),
            wc
        ))

    return merge_meshes(meshes)


# ─────────────────────────────────────────────────────────────────────────────
# Track model builder
# ─────────────────────────────────────────────────────────────────────────────

WAYPOINTS = [
    ( 0.0, -78.0, 14.0),
    (40.0, -55.0, 11.0),
    (68.0, -10.0, 10.0),
    (72.0,  28.0,  9.0),
    (52.0,  60.0,  8.0),
    (15.0,  72.0, 10.0),
    (-28.0, 62.0, 11.0),
    (-65.0, 28.0, 10.0),
    (-72.0,-12.0,  9.0),
    (-58.0,-50.0, 10.0),
    (-25.0,-72.0, 12.0),
    ( -2.0,-80.0, 13.0),
]


def make_track():
    """Build road surface + surrounding terrain mesh."""
    verts, norms, cols, idxs = [], [], [], []

    road_col   = srgb_to_linear( 52,  52,  56)  # dark asphalt
    line_col   = srgb_to_linear(220, 220, 180)  # faded centre line
    shoulder   = srgb_to_linear( 68,  55,  38)  # dirt shoulder
    grass_col  = srgb_to_linear( 28,  68,  22)  # dark grass
    up = (0.0, 1.0, 0.0)

    def add_quad(v0, v1, v2, v3, color, y=0.0):
        base = len(verts)
        for vx, vz in (v0, v1, v2, v3):
            verts.append((vx, y, vz))
            norms.append(up)
            cols.append(color)
        idxs.extend([base, base+1, base+2, base, base+2, base+3])

    # ── Large ground plane (grass) ──
    add_quad((-110, -110), (110, -110), (110, 110), (-110, 110),
             grass_col, y=-0.04)

    # ── Road segments between waypoints ──
    n = len(WAYPOINTS)
    for i in range(n):
        wx1, wz1, w1 = WAYPOINTS[i]
        wx2, wz2, w2 = WAYPOINTS[(i+1) % n]

        dx = wx2 - wx1
        dz = wz2 - wz1
        dist = math.sqrt(dx*dx + dz*dz)
        if dist < 0.001:
            continue
        px = -dz / dist   # perpendicular left
        pz =  dx / dist

        hw1 = w1 * 0.5
        hw2 = w2 * 0.5
        sh = 1.2  # shoulder width

        # dirt shoulder (outside road)
        add_quad(
            (wx1 + px*(hw1+sh),     wz1 + pz*(hw1+sh)),
            (wx1 - px*(hw1+sh),     wz1 - pz*(hw1+sh)),
            (wx2 - px*(hw2+sh),     wz2 - pz*(hw2+sh)),
            (wx2 + px*(hw2+sh),     wz2 + pz*(hw2+sh)),
            shoulder, y=-0.02
        )

        # road surface
        add_quad(
            (wx1 + px*hw1,  wz1 + pz*hw1),
            (wx1 - px*hw1,  wz1 - pz*hw1),
            (wx2 - px*hw2,  wz2 - pz*hw2),
            (wx2 + px*hw2,  wz2 + pz*hw2),
            road_col, y=0.0
        )

        # centre line strip (narrow quad along mid)
        lw = 0.15
        add_quad(
            (wx1 + px*lw,  wz1 + pz*lw),
            (wx1 - px*lw,  wz1 - pz*lw),
            (wx2 - px*lw,  wz2 - pz*lw),
            (wx2 + px*lw,  wz2 + pz*lw),
            line_col, y=0.01
        )

    return verts, norms, cols, idxs


# ─────────────────────────────────────────────────────────────────────────────
# glTF / GLB writer
# ─────────────────────────────────────────────────────────────────────────────

def _pack_buffer(verts, norms, cols, idxs):
    """Pack geometry into a single binary buffer and return (data, meta)."""

    def pack_vec3(lst):
        return b''.join(struct.pack('<fff', *v) for v in lst)

    def pack_vec4(lst):
        return b''.join(struct.pack('<ffff', *v) for v in lst)

    def pack_u16(lst):
        return b''.join(struct.pack('<H', i) for i in lst)

    # Align to 4 bytes
    def pad4(data):
        rem = len(data) % 4
        return data + b'\x00' * ((4 - rem) % 4)

    pos_data   = pad4(pack_vec3(verts))
    norm_data  = pad4(pack_vec3(norms))
    col_data   = pad4(pack_vec4(cols))
    idx_data   = pad4(pack_u16(idxs))

    offsets = {
        'pos_off':  0,
        'pos_len':  len(pos_data),
        'norm_off': len(pos_data),
        'norm_len': len(norm_data),
        'col_off':  len(pos_data) + len(norm_data),
        'col_len':  len(col_data),
        'idx_off':  len(pos_data) + len(norm_data) + len(col_data),
        'idx_len':  len(idx_data),
    }
    buffer = pos_data + norm_data + col_data + idx_data

    # Bounding box for positions
    xs = [v[0] for v in verts]
    ys = [v[1] for v in verts]
    zs = [v[2] for v in verts]

    return buffer, offsets, (min(xs), min(ys), min(zs)), (max(xs), max(ys), max(zs))


def build_glb(verts, norms, cols, idxs):
    """Build a .glb binary blob from mesh data."""
    buf, off, bmin, bmax = _pack_buffer(verts, norms, cols, idxs)
    n_verts = len(verts)
    n_idxs  = len(idxs)

    gltf = {
        "asset": {"version": "2.0", "generator": "pak-rally-tools"},
        "scene": 0,
        "scenes": [{"nodes": [0]}],
        "nodes":  [{"mesh": 0, "name": "mesh0"}],
        "materials": [{"name": "vertex_color", "pbrMetallicRoughness": {}}],
        "meshes": [{
            "name": "mesh0",
            "primitives": [{
                "attributes": {
                    "POSITION":  0,
                    "NORMAL":    1,
                    "COLOR_0":   2,
                },
                "indices": 3,
                "mode": 4,  # TRIANGLES
                "material": 0,
            }]
        }],
        "accessors": [
            # 0 POSITION
            {"bufferView": 0, "byteOffset": 0, "componentType": 5126,
             "count": n_verts, "type": "VEC3",
             "min": list(bmin), "max": list(bmax)},
            # 1 NORMAL
            {"bufferView": 1, "byteOffset": 0, "componentType": 5126,
             "count": n_verts, "type": "VEC3"},
            # 2 COLOR_0
            {"bufferView": 2, "byteOffset": 0, "componentType": 5126,
             "count": n_verts, "type": "VEC4"},
            # 3 indices
            {"bufferView": 3, "byteOffset": 0, "componentType": 5123,
             "count": n_idxs, "type": "SCALAR"},
        ],
        "bufferViews": [
            {"buffer": 0, "byteOffset": off["pos_off"],  "byteLength": off["pos_len"],  "target": 34962},
            {"buffer": 0, "byteOffset": off["norm_off"], "byteLength": off["norm_len"], "target": 34962},
            {"buffer": 0, "byteOffset": off["col_off"],  "byteLength": off["col_len"],  "target": 34962},
            {"buffer": 0, "byteOffset": off["idx_off"],  "byteLength": off["idx_len"],  "target": 34963},
        ],
        "buffers": [{"byteLength": len(buf)}],
    }

    json_bytes = json.dumps(gltf, separators=(',', ':')).encode('utf-8')
    # Pad JSON chunk to 4-byte boundary with spaces
    pad = (4 - len(json_bytes) % 4) % 4
    json_bytes += b' ' * pad

    # GLB header: magic, version, total length
    json_chunk = struct.pack('<II', len(json_bytes), 0x4E4F534A) + json_bytes
    bin_chunk  = struct.pack('<II', len(buf), 0x004E4942) + buf

    total = 12 + len(json_chunk) + len(bin_chunk)
    header = struct.pack('<III', 0x46546C67, 2, total)

    return header + json_chunk + bin_chunk


def save_glb(path, verts, norms, cols, idxs):
    data = build_glb(verts, norms, cols, idxs)
    with open(path, 'wb') as f:
        f.write(data)
    print(f"  wrote {path}  ({len(data)//1024}KB, {len(verts)} verts, {len(idxs)//3} tris)")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

CARS = [
    # name,  body sRGB,       cab sRGB,           detail/trim,        underside
    ("car_red",    (215, 28, 28),  (235, 190, 190), (20, 20, 20),  (90, 15, 15)),
    ("car_blue",   (28, 65, 215),  (170, 190, 235), (18, 18, 18),  (14, 35, 110)),
    ("car_yellow", (235, 195, 18), (22, 22, 22),    (180, 140, 8), (120, 100, 5)),
    ("car_white",  (228, 228, 228),(155, 155, 155), (30, 30, 30),  (100, 100, 100)),
]


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    gltf_to_t3d = "/tmp/tiny3d/tools/gltf_importer/gltf_to_t3d"

    print("Generating GLB models...")

    # ── Cars ──
    for name, body, cab, detail, under in CARS:
        v, n, c, i = make_car(
            srgb_to_linear(*body),
            srgb_to_linear(*cab),
            srgb_to_linear(*detail),
            srgb_to_linear(*under),
        )
        glb_path = os.path.join(OUT_DIR, f"{name}.glb")
        save_glb(glb_path, v, n, c, i)

    # ── Track ──
    v, n, c, i = make_track()
    track_glb = os.path.join(OUT_DIR, "track.glb")
    save_glb(track_glb, v, n, c, i)

    # ── Convert GLB → T3DM ──
    if not os.path.exists(gltf_to_t3d):
        print(f"\nConverter not found at {gltf_to_t3d}")
        print("Build it: cd /tmp/tiny3d/tools/gltf_importer && make")
        return

    print("\nConverting GLB → T3DM...")
    import subprocess
    targets = [f"{n}.glb" for n, *_ in CARS] + ["track.glb"]
    ok = True
    for fname in targets:
        glb  = os.path.join(OUT_DIR, fname)
        t3dm = os.path.join(OUT_DIR, fname.replace(".glb", ".t3dm"))
        r = subprocess.run(
            [gltf_to_t3d, glb, t3dm, "--base-scale=1", "--ignore-materials"],
            capture_output=True, text=True
        )
        if r.returncode == 0:
            sz = os.path.getsize(t3dm)
            print(f"  {fname.replace('.glb','')} → {t3dm.split('/')[-1]}  ({sz} bytes)")
        else:
            print(f"  ERROR converting {fname}:\n{r.stderr[:400]}")
            ok = False

    if ok:
        print("\nAll models ready in demos/assets/models/")
        print("Place them in your project's assets/models/ to build the ROM.")
    else:
        print("\nSome conversions failed — check output above.")


if __name__ == "__main__":
    main()
