"""Checks the addon's nearest-water search: a line-for-line Python port of
NearestPreloaded (ring search over the Lua data files) must agree with a
brute-force search over every spot, for many random positions."""
import math
import os
import random
import re
import sys

ADDON = sys.argv[1]
TILE = 533.33333
MID = 32 * TILE


def load(map_id):
    data = {}
    for line in open(os.path.join(ADDON, "Water_%d.lua" % map_id)):
        m = re.match(r"\[(\d+)\]=\{([\d,]*)\},", line)
        if m:
            data[int(m.group(1))] = [int(x) for x in m.group(2).split(",")]
    return data


def ring_search(data, north, west):
    a, b = MID - north, MID - west
    tn, tw = math.floor(a / TILE), math.floor(b / TILE)
    best = None
    for ring in range(0, 13):
        for dn in range(-ring, ring + 1):
            step = 1 if (dn == -ring or dn == ring) else 2 * ring
            dw = -ring
            while dw <= ring:
                rn, rw = tn + dn, tw + dw
                lst = data.get(rn * 64 + rw) if (0 <= rn < 64 and 0 <= rw < 64) else None
                if lst:
                    base_a, base_b = rn * TILE + 0.5, rw * TILE + 0.5
                    for v in lst:
                        sa, sb = base_a + v // 600, base_b + v % 600
                        sq = (sa - a) ** 2 + (sb - b) ** 2
                        if best is None or sq < best[0]:
                            best = (sq, MID - sa, MID - sb)
                dw += step
        if best and best[0] <= (ring * TILE) ** 2:
            break
    return best


def brute(data, north, west):
    a, b = MID - north, MID - west
    best = None
    for key, lst in data.items():
        rn, rw = divmod(key, 64)
        for v in lst:
            sa, sb = rn * TILE + 0.5 + v // 600, rw * TILE + 0.5 + v % 600
            sq = (sa - a) ** 2 + (sb - b) ** 2
            if best is None or sq < best[0]:
                best = (sq, MID - sa, MID - sb)
    return best


random.seed(1)
for map_id in (0, 1):
    data = load(map_id)
    total = sum(len(v) for v in data.values())
    biggest = max(len(v) for v in data.values())
    bad_vals = sum(1 for v in data.values() for x in v if x // 600 > 533 or x % 600 > 533)
    keys = list(data)
    mism = 0
    worst_ring_far = 0
    for _ in range(300):
        rn, rw = divmod(random.choice(keys), 64)
        north = MID - (rn + random.uniform(-3, 4)) * TILE
        west = MID - (rw + random.uniform(-3, 4)) * TILE
        r, bf = ring_search(data, north, west), brute(data, north, west)
        if r is None or abs(r[0] - bf[0]) > 1e-6:
            mism += 1
        worst_ring_far = max(worst_ring_far, math.sqrt(bf[0]))
    print("map", map_id, "tiles", len(data), "spots", total, "largest tile", biggest,
          "out-of-range values", bad_vals, "| 300 random positions: mismatches", mism,
          "| farthest nearest-water %.0f yd" % worst_ring_far)

for label, m, north, west in (("Goldshire", 0, -9460, 60), ("Stormwind Trade District", 0, -8830, 630),
                              ("Thunder Bluff", 1, -1250, 100), ("Gadgetzan", 1, -7150, -3800)):
    r = ring_search(load(m), north, west)
    print("  %-26s %5.0f yd -> (%.0f, %.0f)" % (label, math.sqrt(r[0]), r[1], r[2]))
