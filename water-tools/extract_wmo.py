"""Pass 2: liquid inside world buildings (WMOs): canals, fountains, wells, pools.

Reads wmo_placements.json from pass 1, opens each building model, and writes
wmo_liquid.json: a list of [map, north, west, height, liquid_type_id] for
every liquid tile, in world yards.
"""
import json
import math
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casc

OUT = sys.argv[1]
MID = 32 * 533.33333
UNIT = 533.33333 / 128


def chunks(buf, start=0, end=None):
    end = len(buf) if end is None else end
    pos = start
    while pos + 8 <= end:
        size = struct.unpack_from("<I", buf, pos + 4)[0]
        yield buf[pos:pos + 4][::-1], pos + 8, size
        pos += 8 + size


def rotation(rot):
    """R = Rz(rot.y) * Ry(rot.x) * Rx(rot.z), degrees (the usual vmap convention)."""
    a, b, g = (math.radians(rot[1]), math.radians(rot[0]), math.radians(rot[2]))
    ca, sa, cb, sb, cg, sg = math.cos(a), math.sin(a), math.cos(b), math.sin(b), math.cos(g), math.sin(g)
    return (
        (ca * cb, ca * sb * sg - sa * cg, ca * sb * cg + sa * sg),
        (sa * cb, sa * sb * sg + ca * cg, sa * sb * cg - ca * sg),
        (-sb, cb * sg, cb * cg),
    )


def load_wmo(c, fdid, cache):
    """Returns a list of (x, y, z, liquid_id_or_legacy) tile centres in model space."""
    if fdid in cache:
        return cache[fdid]
    tiles = []
    try:
        root = c.read_fdid(fdid)
    except KeyError:
        cache[fdid] = None
        return None
    use_dbc, groups = False, []
    for magic, off, size in chunks(root):
        if magic == b"MOHD":
            n_groups = struct.unpack_from("<I", root, off + 4)[0]
            flags = struct.unpack_from("<H", root, off + 60)[0]
            use_dbc = bool(flags & 4)
        elif magic == b"GFID":
            groups = struct.unpack_from("<%dI" % (size // 4), root, off)[:n_groups]
    for gid in groups:
        if not gid:
            continue
        try:
            g = c.read_fdid(gid)
        except KeyError:
            continue
        for magic, off, size in chunks(g):
            if magic != b"MOGP":
                continue
            group_liquid = struct.unpack_from("<I", g, off + 52)[0]
            for m2, o2, s2 in chunks(g, off + 68, off + size):
                if m2 != b"MLIQ":
                    continue
                xv, yv, xt, yt, cx, cy, cz, _mat = struct.unpack_from("<iiii3fH", g, o2)
                vbase = o2 + 30
                tbase = vbase + xv * yv * 8
                if xv != xt + 1 or yv != yt + 1 or tbase + xt * yt > o2 + s2:
                    continue
                for j in range(yt):
                    for i in range(xt):
                        tf = g[tbase + j * xt + i]
                        if (tf & 0x0F) == 0x0F:
                            continue
                        h = 0.0
                        for dj, di in ((0, 0), (0, 1), (1, 0), (1, 1)):
                            h += struct.unpack_from("<f", g, vbase + ((j + dj) * xv + i + di) * 8 + 4)[0]
                        if use_dbc or group_liquid > 20:
                            lt = group_liquid
                        else:  # legacy: basic type 0 water, 1 ocean, 2 magma, 3 slime
                            lt = -1 - (group_liquid & 3)
                        tiles.append((cx + (i + 0.5) * UNIT, cy + (j + 0.5) * UNIT, h / 4, lt))
    cache[fdid] = tiles
    return tiles


def main():
    c = casc.open_default()
    placements = json.load(open(os.path.join(OUT, "wmo_placements.json")))
    by_fdid = sum(1 for p in placements if p["flags"] & 8)
    print("placements", len(placements), "with file id", by_fdid)
    cache, out = {}, []
    missing = inside = outside = 0
    t0 = time.time()
    for p in placements:
        if not p["flags"] & 8:
            continue
        tiles = load_wmo(c, p["id"], cache)
        if tiles is None:
            missing += 1
            continue
        if not tiles:
            continue
        R = rotation(p["rot"])
        scale = p["scale"] / 1024.0 if p["flags"] & 4 else 1.0
        px, py, pz = p["pos"]
        ix, iy, iz = pz, px, py           # "fixCoords": internal x, y, z
        for x, y, z, lt in tiles:
            x, y, z = x * scale, y * scale, z * scale
            wx = R[0][0] * x + R[0][1] * y + R[0][2] * z + ix
            wy = R[1][0] * x + R[1][1] * y + R[1][2] * z + iy
            wz = R[2][0] * x + R[2][1] * y + R[2][2] * z + iz
            out.append([p["map"], round(MID - wx, 1), round(MID - wy, 1), round(wz, 1), lt])
            # Self-check: the map file stores a bounding box for each placed
            # building (in raw x, y, z = wy, wz, wx). A correct transform puts
            # every liquid tile inside it.
            bb = p["bb"]
            if (bb[0] - 3 <= wy <= bb[3] + 3 and bb[1] - 3 <= wz <= bb[4] + 3
                    and bb[2] - 3 <= wx <= bb[5] + 3):
                inside += 1
            else:
                outside += 1
    print("transform self-check: tiles inside their building's box", inside, "outside", outside)
    print("models read", len(cache), "missing", missing, "liquid tiles", len(out),
          "%.0fs" % (time.time() - t0))
    types = {}
    for o in out:
        types[o[4]] = types.get(o[4], 0) + 1
    print("liquid ids (negative = legacy water/ocean/magma/slime):", dict(sorted(types.items())))
    json.dump(out, open(os.path.join(OUT, "wmo_liquid.json"), "w"))

    # Transform self-check: a correctly placed tile must fall inside the
    # bounding box the map file itself stores for that building.
    # (re-read boxes from the obj files is costly; use Stormwind as a spot check)
    sw = [o for o in out if o[0] == 0 and -9100 < o[1] < -8300 and 200 < o[2] < 1100]
    if sw:
        print("Stormwind-area tiles:", len(sw),
              "north %.0f..%.0f west %.0f..%.0f height %.0f..%.0f" % (
                  min(o[1] for o in sw), max(o[1] for o in sw),
                  min(o[2] for o in sw), max(o[2] for o in sw),
                  min(o[3] for o in sw), max(o[3] for o in sw)),
              "types", sorted(set(o[4] for o in sw)))


main()
