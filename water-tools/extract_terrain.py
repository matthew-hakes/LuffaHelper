"""Pass 1: read every terrain tile of both continents and record, for each
4.17-yard cell, how deep the liquid above the ground is and what liquid it is.

Output (in OUT_DIR): <map>_depth.bin, <map>_type.bin (8192x8192 bytes each),
liquid_ids.json, wmo_placements.json.
  depth byte: 0 = no liquid above ground, else min(255, 1 + depth_yards * 10)
  type byte : index into liquid_ids.json
"""
import json
import os
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casc

OUT_DIR = sys.argv[1]
MAPS = (("Azeroth", 0, 775971), ("Kalimdor", 1, 782779))
N = 8192  # cells per side: 64 tiles * 16 chunks * 8 cells


def chunks(buf, start=0, end=None):
    end = len(buf) if end is None else end
    pos = start
    while pos + 8 <= end:
        size = struct.unpack_from("<I", buf, pos + 4)[0]
        yield buf[pos:pos + 4][::-1], pos + 8, size
        pos += 8 + size


def main():
    c = casc.open_default()
    liquid_ids = [None]          # index 0 unused
    liquid_index = {}
    liquid_cells = {}
    lvf_seen = {}
    placements = {}              # (map, uniqueId) -> placement
    t0 = time.time()

    for name, map_id, wdt_fdid in MAPS:
        depth = bytearray(N * N)
        ltype = bytearray(N * N)
        wdt = c.read_fdid(wdt_fdid)
        maid = None
        for magic, off, size in chunks(wdt):
            if magic == b"MAID":
                maid = struct.unpack_from("<%dI" % (size // 4), wdt, off)
        done = 0
        for tile in range(4096):
            root_id, obj_id = maid[tile * 8], maid[tile * 8 + 1]
            if not root_id:
                continue
            ty, tx = divmod(tile, 64)
            a = c.read_fdid(root_id)
            mh2o = None
            terrain = {}         # (ix, iy) -> 81 absolute outer-vertex heights
            for magic, off, size in chunks(a):
                if magic == b"MH2O":
                    mh2o = off
                elif magic == b"MCNK":
                    ix, iy = struct.unpack_from("<II", a, off + 4)
                    base = struct.unpack_from("<f", a, off + 0x70)[0]
                    for m2, o2, s2 in chunks(a, off + 128, off + size):
                        if m2 == b"MCVT":
                            v = struct.unpack_from("<145f", a, o2)
                            terrain[(ix, iy)] = [base + v[r * 17 + cc]
                                                 for r in range(9) for cc in range(9)]
                            break
            if mh2o is not None:
                for iy in range(16):
                    for ix in range(16):
                        o_inst, layers, _ = struct.unpack_from(
                            "<III", a, mh2o + (iy * 16 + ix) * 12)
                        if not layers:
                            continue
                        th = terrain.get((ix, iy))
                        if th is None:
                            continue
                        for layer in range(layers):
                            p = mh2o + o_inst + layer * 24
                            (lt, lvf, hmin, hmax, xo, yo, w, h, o_bits,
                             o_verts) = struct.unpack_from("<HHffBBBBII", a, p)
                            lvf_seen[lvf] = lvf_seen.get(lvf, 0) + 1
                            if w == 0 or h == 0 or xo + w > 8 or yo + h > 8:
                                continue
                            heights = None
                            if o_verts and lvf != 2 and hmin != hmax:
                                nv = (w + 1) * (h + 1)
                                hs = struct.unpack_from("<%df" % nv, a, mh2o + o_verts)
                                if all(hmin - 1 <= x <= hmax + 1 for x in hs):
                                    heights = hs
                            flat = 0.0 if (lvf == 2 and hmin == 0 and hmax == 0) else hmin
                            if o_bits:
                                bits = a[mh2o + o_bits:mh2o + o_bits + (w * h + 7) // 8]
                            else:
                                bits = None
                            li = liquid_index.get(lt)
                            if li is None:
                                li = len(liquid_ids)
                                liquid_ids.append(lt)
                                liquid_index[lt] = li
                            row0 = ty * 128 + iy * 8
                            col0 = tx * 128 + ix * 8
                            for r in range(h):
                                for cc in range(w):
                                    k = r * w + cc
                                    if bits is not None and not (bits[k >> 3] >> (k & 7)) & 1:
                                        continue
                                    if heights:
                                        i0 = r * (w + 1) + cc
                                        lh = (heights[i0] + heights[i0 + 1]
                                              + heights[i0 + w + 1] + heights[i0 + w + 2]) / 4
                                    else:
                                        lh = flat
                                    gr, gc = yo + r, xo + cc
                                    t = (th[gr * 9 + gc] + th[gr * 9 + gc + 1]
                                         + th[gr * 9 + gc + 9] + th[gr * 9 + gc + 10]) / 4
                                    d = lh - t
                                    if d <= 0:
                                        continue
                                    b = min(255, 1 + int(d * 10))
                                    g = (row0 + gr) * N + col0 + gc
                                    if b > depth[g]:
                                        depth[g] = b
                                        ltype[g] = li
                                    liquid_cells[lt] = liquid_cells.get(lt, 0) + 1

            # WMO placements for pass 2
            if obj_id:
                try:
                    o = c.read_fdid(obj_id)
                    for magic, off, size in chunks(o):
                        if magic == b"MODF":
                            for i in range(size // 64):
                                e = struct.unpack_from("<II3f3f6fHHHH", o, off + i * 64)
                                placements[(map_id, e[1])] = {
                                    "map": map_id, "id": e[0], "pos": e[2:5],
                                    "rot": e[5:8], "bb": e[8:14],
                                    "flags": e[14], "scale": e[17]}
                except KeyError:
                    pass
            done += 1
            if done % 200 == 0:
                print(name, done, "tiles", "%.0fs" % (time.time() - t0), flush=True)

        with open(os.path.join(OUT_DIR, name + "_depth.bin"), "wb") as f:
            f.write(depth)
        with open(os.path.join(OUT_DIR, name + "_type.bin"), "wb") as f:
            f.write(ltype)
        print(name, "done:", done, "tiles; cells with liquid above ground:",
              N * N - depth.count(0), flush=True)

    with open(os.path.join(OUT_DIR, "liquid_ids.json"), "w") as f:
        json.dump(liquid_ids, f)
    with open(os.path.join(OUT_DIR, "wmo_placements.json"), "w") as f:
        json.dump(list(placements.values()), f)
    print("liquid type id -> cells:", dict(sorted(liquid_cells.items())))
    print("vertex formats seen:", dict(sorted(lvf_seen.items())))
    print("wmo placements:", len(placements))


main()
