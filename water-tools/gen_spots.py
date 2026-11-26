"""Pass 3: turn the water grids into a compact list of reachable water spots
and write them as Lua data files for the addon.

Usage: gen_spots.py <scan dir> <addon dir>

A cell counts as water when the liquid is a water/ocean type (not lava, slime,
tar or fel) and stands at least MIN_DEPTH yards above the ground. Spots are
taken from the band of water next to dry land (the place you would walk to),
one per BLOCK x BLOCK cells, choosing the deepest cell in that block.
"""
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casc

SCAN, ADDON = sys.argv[1], sys.argv[2]
N = 8192
TILE = 533.33333
MID = 32 * TILE
UNIT = TILE / 128
MIN_DEPTH = 0.3
BAND = 2          # cells from dry land that still count as "shore"
BLOCK = 6         # one spot per 6x6 cells (25 yards)
MIN_BODY_CELLS = 24   # smallest body kept: about 420 square yards (a small pond)
MAPS = (("Azeroth", 0, 775971), ("Kalimdor", 1, 782779))

ids = json.load(open(os.path.join(SCAN, "liquid_ids.json")))
types = {int(k): v for k, v in json.load(open(os.path.join(SCAN, "liquid_types.json"))).items()}
wmo = json.load(open(os.path.join(SCAN, "wmo_liquid.json")))


def is_water(liquid_id):
    if liquid_id < 0:                      # legacy: -1 water, -2 ocean, -3 magma, -4 slime
        return liquid_id in (-1, -2)
    t = types.get(liquid_id)
    return bool(t) and t["sound"] in (0, 1)


def name_of(liquid_id):
    if liquid_id < 0:
        return ("legacy water", "legacy ocean", "legacy magma", "legacy slime")[-liquid_id - 1]
    return types.get(liquid_id, {}).get("name", "unknown %d" % liquid_id)


def row_int(row_bytes):
    return int(row_bytes.decode("ascii"), 2)


def main():
    c = casc.open_default()
    min_byte = 1 + int(MIN_DEPTH * 10)
    depth_tab = bytes(b"1"[0] if i >= min_byte else b"0"[0] for i in range(256))
    type_tab = bytes(
        b"1"[0] if (0 < i < len(ids) and is_water(ids[i])) else b"0"[0] for i in range(256))
    all_spots = {}
    summary = {}

    for name, map_id, wdt_fdid in MAPS:
        depth = open(os.path.join(SCAN, name + "_depth.bin"), "rb").read()
        ltype = open(os.path.join(SCAN, name + "_type.bin"), "rb").read()

        # which tiles exist (cells outside them are "no data", not dry land)
        wdt = c.read_fdid(wdt_fdid)
        pos = 0
        maid = None
        while pos + 8 <= len(wdt):
            size = struct.unpack_from("<I", wdt, pos + 4)[0]
            if wdt[pos:pos + 4] == b"DIAM":
                maid = struct.unpack_from("<%dI" % (size // 4), wdt, pos + 8)
            pos += 8 + size
        tile_rows = []
        for ty in range(64):
            s = "".join(("1" * 128) if maid[(ty * 64 + tx) * 8] else ("0" * 128) for tx in range(64))
            tile_rows.append(int(s, 2))

        full = (1 << N) - 1
        wet, dry = [], []
        for r in range(N):
            d = row_int(depth[r * N:(r + 1) * N].translate(depth_tab))
            t = row_int(ltype[r * N:(r + 1) * N].translate(type_tab))
            w = d & t
            wet.append(w)
            dry.append(~w & full & tile_rows[r // 128])

        # building water (canals, fountains, wells) as extra cells
        wmo_cells = {}
        for m, north, west, height, lt in wmo:
            # Building water is kept only for the big open city waterways
            # (1344 Stormwind canals, 1350 Orgrimmar). Wells, fountains,
            # moonwells, interiors and cave pools are left out.
            if m != map_id or lt not in (1344, 1350):
                continue
            r, col = int((MID - north) / UNIT), int((MID - west) / UNIT)
            if 0 <= r < N and 0 <= col < N:
                wmo_cells[(r, col)] = (north, west, lt)

        # Size of each body of water, so wells, fountains, moonwells and puddles
        # can be dropped. Bodies are joined at block level (touching blocks).
        area = {}          # (block row, block col) -> wet cells in that block
        for r in range(N):
            if not wet[r]:
                continue
            s = bin(wet[r])[2:].zfill(N)
            col = s.find("1")
            while col != -1:
                bc = col // BLOCK
                key = (r // BLOCK, bc)
                area[key] = area.get(key, 0) + s.count("1", bc * BLOCK, bc * BLOCK + BLOCK)
                col = s.find("1", bc * BLOCK + BLOCK)
        for (r, col) in wmo_cells:
            if not (wet[r] >> (N - 1 - col)) & 1:
                key = (r // BLOCK, col // BLOCK)
                area[key] = area.get(key, 0) + 1
        body_size = {}     # block -> total wet cells of the body it belongs to
        for start in area:
            if start in body_size:
                continue
            members, stack, total = [start], [start], area[start]
            body_size[start] = 0
            while stack:
                br, bc = stack.pop()
                for nr in (br - 1, br, br + 1):
                    for nc in (bc - 1, bc, bc + 1):
                        k = (nr, nc)
                        if k in area and k not in body_size:
                            body_size[k] = 0
                            total += area[k]
                            members.append(k)
                            stack.append(k)
            for k in members:
                body_size[k] = total

        # shore band = wet cells within BAND cells of dry land
        spread = []
        for r in range(N):
            x = dry[r]
            y = x
            for k in range(1, BAND + 1):
                y |= (x << k) | (x >> k)
            spread.append(y & full)
        blocks = {}        # (block row, block col) -> (depth byte, north, west, liquid id)
        for r in range(N):
            near = 0
            for k in range(max(0, r - BAND), min(N, r + BAND + 1)):
                near |= spread[k]
            shore = wet[r] & near
            if not shore:
                continue
            s = bin(shore)[2:].zfill(N)
            col = s.find("1")
            while col != -1:
                g = r * N + col
                key = (r // BLOCK, col // BLOCK)
                cur = blocks.get(key)
                if cur is None or depth[g] > cur[0]:
                    blocks[key] = (depth[g], MID - (r + 0.5) * UNIT, MID - (col + 0.5) * UNIT,
                                   ids[ltype[g]])
                col = s.find("1", col + 1)
        terrain_spots = len(blocks)
        for (r, col), (north, west, lt) in wmo_cells.items():
            key = (r // BLOCK, col // BLOCK)
            if key not in blocks:
                blocks[key] = (0, north, west, lt)

        before = len(blocks)
        small = {}
        for key in list(blocks):
            if body_size.get(key, 0) < MIN_BODY_CELLS:
                v = blocks.pop(key)
                k = ("building: " if v[0] == 0 else "") + name_of(v[3])
                small[k] = small.get(k, 0) + 1
        print(name, "dropped", before - len(blocks), "spots in bodies smaller than",
              MIN_BODY_CELLS, "cells:", dict(sorted(small.items(), key=lambda kv: -kv[1])))
        spots = [(v[1], v[2], v[3], v[0] == 0) for v in blocks.values()]
        all_spots[map_id] = spots
        for _, _, lt, is_wmo in spots:
            k = ("building: " if is_wmo else "") + name_of(lt)
            summary[k] = summary.get(k, 0) + 1
        print(name, "spots:", len(spots), "(terrain %d, building-only %d)" % (
            terrain_spots, len(spots) - terrain_spots), flush=True)

        # Lua data file
        tiles = {}
        for north, west, _, _ in spots:
            a, b = MID - north, MID - west
            tn, tw = int(a // TILE), int(b // TILE)
            tiles.setdefault(tn * 64 + tw, []).append(
                int(a - tn * TILE) * 600 + int(b - tw * TILE))
        path = os.path.join(ADDON, "Water_%d.lua" % map_id)
        with open(path, "w", newline="\n") as f:
            f.write("-- Generated from the game's own map data (%s). Do not edit by hand.\n" % name)
            f.write("-- [tile] = { offsetNorth * 600 + offsetWest, ... } in yards within a 533.33 yd tile.\n")
            f.write("LuffaHelperWater = LuffaHelperWater or {}\n")
            f.write("LuffaHelperWater[%d] = {\n" % map_id)
            for key in sorted(tiles):
                vals = sorted(set(tiles[key]))
                f.write("[%d]={%s},\n" % (key, ",".join(map(str, vals))))
            f.write("}\n")
        print(" wrote", path, os.path.getsize(path) // 1024, "KB", flush=True)

    print("\nspots by water kind:")
    for k, v in sorted(summary.items(), key=lambda kv: -kv[1]):
        print("  %6d  %s" % (v, k))

    def nearest(map_id, north, west):
        best = None
        for s in all_spots[map_id]:
            d = (s[0] - north) ** 2 + (s[1] - west) ** 2
            if best is None or d < best[0]:
                best = (d, s)
        return math.sqrt(best[0]), best[1]

    print("\nnearest water from well-known places:")
    for label, m, north, west in (
        ("Goldshire", 0, -9460, 60), ("Stormwind Trade District", 0, -8830, 630),
        ("Ironforge centre", 0, -4920, -950), ("Undercity (above ground)", 0, 1600, 240),
        ("Lakeshire", 0, -9240, -2200), ("Booty Bay", 0, -14400, 450),
        ("Light's Hope Chapel", 0, 2280, -5300), ("Searing Gorge (Thorium Point)", 0, -6500, -1100),
        ("Orgrimmar (Valley of Strength)", 1, 1600, -4400), ("Thunder Bluff", 1, -1250, 100),
        ("Darnassus", 1, 9950, 2280), ("Crossroads", 1, -450, -2650),
        ("Gadgetzan", 1, -7150, -3800), ("Everlook", 1, 6720, -4670),
        ("Cenarion Hold", 1, -6820, 750), ("Ratchet", 1, -950, -3700),
    ):
        d, s = nearest(m, north, west)
        print("  %-32s %5.0f yd  -> (%.0f, %.0f) %s%s" % (
            label, d, s[0], s[1], "building: " if s[3] else "", name_of(s[2])))


main()
