"""Draws the addon's arrow: a gold, dark-outlined arrow pointing up, in the
style of the game's quest arrows. Writes a 64x64 32-bit TGA for the game and,
optionally, a PNG preview.

Usage: make_arrow.py <out.tga> [preview.png]
"""
import math
import struct
import sys
import zlib

SIZE = 64
SS = 4  # supersampling per axis
# Arrow outline, y down, kept inside a 30 px circle so it survives rotation.
POLY = [(32, 3), (55, 31), (41, 31), (41, 58), (23, 58), (23, 31), (9, 31)]
OUTLINE = 2.6


def inside(x, y):
    hit = False
    n = len(POLY)
    for i in range(n):
        x1, y1 = POLY[i]
        x2, y2 = POLY[(i + 1) % n]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / (y2 - y1) + x1:
            hit = not hit
    return hit


def edge_distance(x, y):
    best = 1e9
    n = len(POLY)
    for i in range(n):
        x1, y1 = POLY[i]
        x2, y2 = POLY[(i + 1) % n]
        dx, dy = x2 - x1, y2 - y1
        t = max(0.0, min(1.0, ((x - x1) * dx + (y - y1) * dy) / (dx * dx + dy * dy)))
        best = min(best, math.hypot(x - (x1 + t * dx), y - (y1 + t * dy)))
    return best


def colour(x, y):
    d = edge_distance(x, y)
    if d < OUTLINE:
        return (0.16, 0.08, 0.0)
    t = min(1.0, (d - OUTLINE) / 6.0)            # bevel: darker gold at the rim
    r, g, b = 0.80 + 0.20 * t, 0.50 + 0.38 * t, 0.04 + 0.22 * t
    light = 0.12 * ((40 - x) / 32 + (30 - y) / 40)   # light from the upper left
    return tuple(max(0.0, min(1.0, c + light)) for c in (r, g, b))


rows = []
for py in range(SIZE):
    row = []
    for px in range(SIZE):
        acc, cover = [0.0, 0.0, 0.0], 0
        for sy in range(SS):
            for sx in range(SS):
                x, y = px + (sx + 0.5) / SS, py + (sy + 0.5) / SS
                if inside(x, y):
                    c = colour(x, y)
                    acc[0] += c[0]; acc[1] += c[1]; acc[2] += c[2]
                    cover += 1
        if cover:
            row.append((int(255 * acc[0] / cover + 0.5), int(255 * acc[1] / cover + 0.5),
                        int(255 * acc[2] / cover + 0.5), int(255 * cover / (SS * SS) + 0.5)))
        else:
            row.append((0, 0, 0, 0))
    rows.append(row)

# TGA: uncompressed true colour, 32 bit, bottom-up rows, BGRA.
with open(sys.argv[1], "wb") as f:
    f.write(struct.pack("<BBBHHBHHHHBB", 0, 0, 2, 0, 0, 0, 0, 0, SIZE, SIZE, 32, 8))
    for row in reversed(rows):
        f.write(b"".join(bytes((b, g, r, a)) for r, g, b, a in row))

if len(sys.argv) > 2:
    # PNG preview, 4x enlarged on a dark green background (like grass in game).
    scale, bg = 4, (40, 70, 40)
    raw = bytearray()
    for row in rows:
        line = bytearray([0])
        for r, g, b, a in row:
            k = a / 255
            px = bytes(int(c * k + bgc * (1 - k)) for c, bgc in zip((r, g, b), bg))
            line += px * scale
        raw += bytes(line) * scale

    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    with open(sys.argv[2], "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", SIZE * scale, SIZE * scale, 8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b""))
