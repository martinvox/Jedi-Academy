#!/usr/bin/env python3
"""Generates a small synthetic Jedi Academy install for automated tests.

Writes <out>/base/assets0.pk3 and assets1.pk3 containing an RBSP v1 map
(maps/test.bsp) with brushes, planar faces, a bezier patch, a triangle soup,
a lightmap page, brush entities and a shader script. No retail assets are
used, so the fixture can live in the repository.

Struct layouts follow the PC definitions in code/qcommon/qfiles.h.
"""
import os
import struct
import sys
import zipfile
import zlib

# contents / surface flags (code/game/surfaceflags.h)
CONTENTS_SOLID = 0x1
CONTENTS_WATER = 0x4
CONTENTS_PLAYERCLIP = 0x10
CONTENTS_TRIGGER = 0x400
SURF_SKY = 0x2000
SURF_NODRAW = 0x200000

MST_PLANAR, MST_PATCH, MST_TRIANGLE_SOUP = 1, 2, 3
LIGHTMAP_BY_VERTEX = -3


class Bsp:
    def __init__(self):
        self.shaders = []    # (name, surf, contents)
        self.planes = []     # (nx, ny, nz, dist)
        self.brushes = []    # (firstSide, numSides, shaderNum)
        self.sides = []      # (planeNum, shaderNum, drawSurfNum)
        self.verts = []      # dict per vertex
        self.indexes = []
        self.surfaces = []   # dicts
        self.models = []     # (mins, maxs, firstSurf, numSurf, firstBrush, numBrush)
        self.lightmaps = []  # bytes, 128*128*3 each
        self.entities = []   # list of dict

    def shader(self, name, surf, contents):
        self.shaders.append((name, surf, contents))
        return len(self.shaders) - 1

    def box_brush(self, mins, maxs, shader):
        first = len(self.sides)
        for axis in range(3):
            for sign in (1, -1):
                n = [0.0, 0.0, 0.0]
                n[axis] = float(sign)
                d = maxs[axis] if sign > 0 else -mins[axis]
                self.planes.append((n[0], n[1], n[2], float(d)))
                self.planes.append((-n[0], -n[1], -n[2], float(-d)))  # x^1 is the opposite plane
                self.sides.append((len(self.planes) - 2, shader, -1))
        self.brushes.append((first, 6, shader))

    def vert(self, xyz, st, lm, normal, color=(255, 255, 255, 255)):
        self.verts.append({"xyz": xyz, "st": st, "lm": lm, "n": normal, "c": color})
        return len(self.verts) - 1

    def quad(self, shader, corners, normal, lm_page=0, lightmapped=True):
        """corners: 4 points; winding is fixed up so that, like q3map2 output,
        triangles are clockwise when seen from the front."""
        a, b, c = corners[0], corners[1], corners[2]
        cross = _cross(_sub(b, a), _sub(c, a))
        if _dot(cross, normal) > 0:
            corners = list(reversed(corners))
        fv = len(self.verts)
        for i, p in enumerate(corners):
            uv = [(0, 0), (0, 1), (1, 1), (1, 0)][i]
            self.vert(p, (p[0] / 128.0, p[1] / 128.0 + p[2] / 128.0), uv, normal)
        fi = len(self.indexes)
        self.indexes += [0, 1, 2, 0, 2, 3]
        self.surfaces.append(dict(shader=shader, type=MST_PLANAR, fv=fv, nv=4, fi=fi, ni=6,
                                  lm=lm_page if lightmapped else LIGHTMAP_BY_VERTEX, pw=0, ph=0))

    def write(self, path):
        lumps = [b""] * 18
        lumps[0] = _entity_string(self.entities)
        lumps[1] = b"".join(struct.pack("<64sii", n.encode(), s, c) for n, s, c in self.shaders)
        lumps[2] = b"".join(struct.pack("<4f", *p) for p in self.planes)
        lumps[7] = b"".join(struct.pack("<6f4i", *m[0], *m[1], *m[2:]) for m in self.models)
        lumps[8] = b"".join(struct.pack("<3i", *b) for b in self.brushes)
        lumps[9] = b"".join(struct.pack("<3i", *s) for s in self.sides)
        vb = bytearray()
        for v in self.verts:
            vb += struct.pack("<3f2f", *v["xyz"], *v["st"])
            vb += struct.pack("<8f", *v["lm"], 0, 0, 0, 0, 0, 0)
            vb += struct.pack("<3f", *v["n"])
            vb += bytes(v["c"]) + bytes(12)
        lumps[10] = bytes(vb)
        lumps[11] = struct.pack("<%di" % len(self.indexes), *self.indexes)
        sb = bytearray()
        for s in self.surfaces:
            sb += struct.pack("<7i", s["shader"], -1, s["type"], s["fv"], s["nv"], s["fi"], s["ni"])
            sb += bytes([0, 255, 255, 255]) + bytes([0, 255, 255, 255])
            sb += struct.pack("<4i", s["lm"], -3, -3, -3)
            sb += struct.pack("<8i", 0, 0, 0, 0, 0, 0, 0, 0)  # lightmapX/Y
            sb += struct.pack("<2i", 128, 128)
            sb += struct.pack("<3f", 0, 0, 0) + struct.pack("<9f", *([0.0] * 9))
            sb += struct.pack("<2i", s["pw"], s["ph"])
        assert len(sb) == 148 * len(self.surfaces)
        lumps[13] = bytes(sb)
        lumps[14] = b"".join(self.lightmaps)

        header_size = 8 + 18 * 8
        out = bytearray(header_size)
        struct.pack_into("<4si", out, 0, b"RBSP", 1)
        for i, data in enumerate(lumps):
            while len(out) % 4:
                out.append(0)
            struct.pack_into("<ii", out, 8 + i * 8, len(out), len(data))
            out += data
        with open(path, "wb") as f:
            f.write(out)


def _sub(a, b):
    return (a[0] - b[0], a[1] - b[1], a[2] - b[2])


def _cross(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def _dot(a, b):
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]


def _entity_string(ents):
    s = ""
    for e in ents:
        s += "{\n" + "".join('"%s" "%s"\n' % kv for kv in e.items()) + "}\n"
    return s.encode() + b"\0"


def tga(w, h, rgb):
    hdr = struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, w, h, 24, 0)
    return hdr + bytes([rgb[2], rgb[1], rgb[0]]) * (w * h)


def png(w, h, rgb):
    raw = b"".join(b"\0" + bytes(rgb) * w for _ in range(h))

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


SHADER_SCRIPT = """// test shaders
textures/test/glass
{
	qer_editorimage textures/test/wall
	surfaceparm trans
	cull none
	{
		map textures/test/wall
		blendFunc GL_SRC_ALPHA GL_ONE_MINUS_SRC_ALPHA
		tcMod scroll 0.5 0
	}
}

/* block comment
textures/test/ignored { }
*/
textures/test/sky
{
	surfaceparm sky
	surfaceparm noimpact
	skyparms env/test 512 -
}

textures/common/trigger
{
	surfaceparm nodraw
	surfaceparm trigger
}
"""


def add_stress(b, count, shader_base):
    """Adds `count` pillars (5 lightmapped quads + 1 brush each) spread over
    `shader_base`..+50 shaders, to approximate retail map sizes for timing."""
    shaders = [b.shader("textures/stress/s%d" % i, 0, CONTENTS_SOLID) for i in range(50)]
    first_surface, first_brush = len(b.surfaces), len(b.brushes)
    side = int(count ** 0.5) + 1
    for k in range(count):
        x0, y0 = (k % side) * 48 - side * 24, (k // side) * 48 - side * 24
        x1, y1, z1 = x0 + 16, y0 + 16, 64 + (k % 7) * 16
        sh = shaders[k % len(shaders)]
        b.quad(sh, [(x0, y0, z1), (x0, y1, z1), (x1, y1, z1), (x1, y0, z1)], (0, 0, 1))
        b.quad(sh, [(x1, y0, 0), (x1, y1, 0), (x1, y1, z1), (x1, y0, z1)], (1, 0, 0))
        b.quad(sh, [(x0, y0, 0), (x0, y1, 0), (x0, y1, z1), (x0, y0, z1)], (-1, 0, 0))
        b.quad(sh, [(x0, y1, 0), (x1, y1, 0), (x1, y1, z1), (x0, y1, z1)], (0, 1, 0))
        b.quad(sh, [(x0, y0, 0), (x1, y0, 0), (x1, y0, z1), (x0, y0, z1)], (0, -1, 0))
        b.box_brush((x0, y0, 0), (x1, y1, z1), sh)
    return len(b.surfaces) - first_surface, len(b.brushes) - first_brush


def build_stress(out_dir, count):
    b = Bsp()
    ns, nb = add_stress(b, count, 0)
    b.models.append(((-4096, -4096, 0), (4096, 4096, 512), 0, ns, 0, nb))
    for i in range(16):
        b.lightmaps.append(bytes([i * 16, 128, 200]) * (128 * 128))
    b.entities = [{"classname": "worldspawn"},
                  {"classname": "info_player_start", "origin": "0 0 600", "angles": "30 45 0"}]
    base = os.path.join(out_dir, "base")
    os.makedirs(base, exist_ok=True)
    bsp_path = os.path.join(out_dir, "stress.bsp")
    b.write(bsp_path)
    with zipfile.ZipFile(os.path.join(base, "stress.pk3"), "w") as z:
        z.write(bsp_path, "maps/stress.bsp")
    os.remove(bsp_path)


def build(out_dir):
    b = Bsp()
    sh_floor = b.shader("textures/test/floor", 0, CONTENTS_SOLID)
    sh_wall = b.shader("textures/test/wall", 0, CONTENTS_SOLID)
    sh_trig = b.shader("textures/common/trigger", SURF_NODRAW, CONTENTS_TRIGGER)
    sh_sky = b.shader("textures/test/sky", SURF_SKY, CONTENTS_SOLID)
    sh_glass = b.shader("textures/test/glass", 0, CONTENTS_SOLID)
    sh_clip = b.shader("textures/common/player_clip", SURF_NODRAW, CONTENTS_PLAYERCLIP)
    sh_water = b.shader("textures/test/water", 0, CONTENTS_WATER)

    # --- model 0: world. Room interior is [-256,256]^2 x [0,256], walls 16 thick.
    R, H, T = 256, 256, 16
    first_surface = len(b.surfaces)
    b.quad(sh_floor, [(-R, -R, 0), (-R, R, 0), (R, R, 0), (R, -R, 0)], (0, 0, 1))
    b.quad(sh_sky, [(-R, -R, H), (-R, R, H), (R, R, H), (R, -R, H)], (0, 0, -1))
    b.quad(sh_wall, [(R, -R, 0), (R, R, 0), (R, R, H), (R, -R, H)], (-1, 0, 0))
    b.quad(sh_wall, [(-R, -R, 0), (-R, R, 0), (-R, R, H), (-R, -R, H)], (1, 0, 0))
    b.quad(sh_wall, [(-R, R, 0), (R, R, 0), (R, R, H), (-R, R, H)], (0, -1, 0))
    b.quad(sh_glass, [(-R, -R, 0), (R, -R, 0), (R, -R, H), (-R, -R, H)], (0, 1, 0), lightmapped=False)

    # bezier patch: a 3x3 hump on the floor, normals up
    fv = len(b.verts)
    for j in range(3):
        for i in range(3):
            x, y = -64 + i * 64, 64 + j * 64
            z = 32 if (i == 1 and j == 1) else (16 if (i == 1 or j == 1) else 0)
            b.vert((x, y, z), (i * 0.5, j * 0.5), (i * 0.5, j * 0.5), (0, 0, 1))
    b.surfaces.append(dict(shader=sh_floor, type=MST_PATCH, fv=fv, nv=9, fi=0, ni=0, lm=0, pw=3, ph=3))

    # triangle soup (a misc_model baked by q3map2), vertex lit
    fv = len(b.verts)
    b.vert((100, -100, 0), (0, 0), (0, 0), (0, 0, 1), (255, 0, 0, 255))
    b.vert((100, -50, 0), (0, 1), (0, 0), (0, 0, 1), (0, 255, 0, 255))
    b.vert((150, -100, 0), (1, 0), (0, 0), (0, 0, 1), (0, 0, 255, 255))
    a, bb, c = b.verts[fv]["xyz"], b.verts[fv + 1]["xyz"], b.verts[fv + 2]["xyz"]
    order = [0, 1, 2] if _dot(_cross(_sub(bb, a), _sub(c, a)), (0, 0, 1)) < 0 else [0, 2, 1]
    fi = len(b.indexes)
    b.indexes += order
    b.surfaces.append(dict(shader=sh_wall, type=MST_TRIANGLE_SOUP, fv=fv, nv=3, fi=fi, ni=3,
                           lm=LIGHTMAP_BY_VERTEX, pw=0, ph=0))
    world_surfs = len(b.surfaces) - first_surface

    first_brush = len(b.brushes)
    b.box_brush((-R - T, -R - T, -T), (R + T, R + T, 0), sh_floor)
    b.box_brush((-R - T, -R - T, H), (R + T, R + T, H + T), sh_sky)
    b.box_brush((R, -R, 0), (R + T, R, H), sh_wall)
    b.box_brush((-R - T, -R, 0), (-R, R, H), sh_wall)
    b.box_brush((-R, R, 0), (R, R + T, H), sh_wall)
    b.box_brush((-R, -R - T, 0), (R, -R, H), sh_glass)
    b.box_brush((-200, -200, 0), (-150, -150, 128), sh_clip)
    b.box_brush((150, 150, 0), (250, 250, 32), sh_water)
    b.box_brush((100, -250, 0), (160, -150, 16), sh_wall)   # step: below STEPSIZE (18)
    b.box_brush((-250, 50, 0), (-150, 150, 32), sh_wall)    # block: too high to step
    b.models.append(((-R - T, -R - T, -T), (R + T, R + T, H + T), first_surface, world_surfs,
                     first_brush, len(b.brushes) - first_brush))

    # --- model 1: func_door
    s0 = len(b.surfaces)
    b.quad(sh_wall, [(0, -8, 0), (0, 8, 0), (0, 8, 96), (0, -8, 96)], (-1, 0, 0))
    b0 = len(b.brushes)
    b.box_brush((0, -8, 0), (8, 8, 96), sh_wall)
    b.models.append(((0, -8, 0), (8, 8, 96), s0, 1, b0, 1))

    # --- model 2: trigger_multiple
    b0 = len(b.brushes)
    b.box_brush((-64, -64, 0), (64, 64, 64), sh_trig)
    b.models.append(((-64, -64, 0), (64, 64, 64), len(b.surfaces), 0, b0, 1))

    # lightmap page: horizontal gradient
    lm = bytearray()
    for y in range(128):
        for x in range(128):
            lm += bytes([x * 2, 128, 255 - x * 2])
    b.lightmaps.append(bytes(lm))

    b.entities = [
        {"classname": "worldspawn", "message": "Test map", "music": "music/test"},
        {"classname": "info_player_start", "origin": "0 -128 24", "angle": "90"},
        {"classname": "func_door", "model": "*1", "angle": "90", "targetname": "door1"},
        {"classname": "trigger_multiple", "model": "*2", "target": "door1"},
        {"classname": "light", "origin": "0 0 200", "light": "300"},
        {"classname": "misc_model_static", "origin": "64 64 0", "angles": "0 45 0",
         "model": "models/map_objects/test/crate.md3"},
    ]

    base = os.path.join(out_dir, "base")
    os.makedirs(base, exist_ok=True)
    bsp_path = os.path.join(out_dir, "test.bsp")
    b.write(bsp_path)
    with zipfile.ZipFile(os.path.join(base, "assets0.pk3"), "w") as z:
        z.write(bsp_path, "maps/test.bsp")
        z.writestr("shaders/test.shader", SHADER_SCRIPT)
        z.writestr("textures/test/floor.tga", tga(8, 8, (255, 0, 0)))
        z.writestr("Textures/Test/Wall.png", png(8, 8, (0, 0, 255)))
        sky = {"rt": (255, 128, 0), "lf": (0, 128, 255), "bk": (128, 255, 128),
               "ft": (255, 255, 0), "up": (200, 200, 255), "dn": (60, 40, 20)}
        for suf, rgb in sky.items():
            z.writestr("env/test_%s.tga" % suf, tga(4, 4, rgb))
    # Later pk3 overrides earlier ones (FS_AddGameDirectory): floor turns green.
    with zipfile.ZipFile(os.path.join(base, "assets1.pk3"), "w") as z:
        z.writestr("textures/test/floor.tga", tga(8, 8, (0, 255, 0)))
    os.remove(bsp_path)


if __name__ == "__main__":
    # make_test_map.py <out_dir> [--stress N]
    out = sys.argv[1] if len(sys.argv) > 1 else "fixtures/gamedata"
    if "--stress" in sys.argv:
        build_stress(out, int(sys.argv[sys.argv.index("--stress") + 1]))
    else:
        build(out)
