"""Read LiquidType.db2 (WDC5) from the local client: ID -> name, flags, sound bank.
SoundBank: 0 water, 1 ocean, 2 magma, 3 slime."""
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import casc


def parse(b):
    assert b[:4] == b"WDC5", b[:4]
    p = 8 + 128
    (rec_count, field_count, rec_size, str_size, _th, _lh, min_id, max_id, _loc,
     flags, id_index, total_fields, _bp_off, _lookup, fsi_size, common_size,
     pallet_size, section_count) = struct.unpack_from("<IIIIIIIIIHHIIIIIII", b, p)
    p += struct.calcsize("<IIIIIIIIIHHIIIIIII")
    sections = []
    for _ in range(section_count):
        sections.append(struct.unpack_from("<QIIIIIIII", b, p))
        p += 40
    p += total_fields * 4
    fsi = [struct.unpack_from("<HHIIIII", b, p + i * 24) for i in range(fsi_size // 24)]
    p += fsi_size
    pallet_start = p
    p += pallet_size
    common_start = p
    p += common_size

    def pallet_offset(field):
        off = pallet_start
        for i in range(field):
            if fsi[i][3] in (3, 4):
                off += fsi[i][2]
        return off

    def common_offset(field):
        off = common_start
        for i in range(field):
            if fsi[i][3] == 2:
                off += fsi[i][2]
        return off

    def field_value(rec_pos, rec_id, field):
        bit_off, bit_size, extra, stype, a, bw, c = fsi[field]
        if stype == 0:
            n = bit_size // 8
            return int.from_bytes(b[rec_pos + bit_off // 8:rec_pos + bit_off // 8 + n], "little")
        if stype == 2:
            co = common_offset(field)
            for i in range(extra // 8):
                rid, val = struct.unpack_from("<II", b, co + i * 8)
                if rid == rec_id:
                    return val
            return a  # default
        raw = int.from_bytes(b[rec_pos + bit_off // 8:rec_pos + bit_off // 8 + 8], "little")
        val = (raw >> (bit_off % 8)) & ((1 << bw) - 1) if stype != 1 or True else 0
        if stype in (1, 5):
            return val
        if stype in (3, 4):
            return struct.unpack_from("<I", b, pallet_offset(field) + val * 4)[0]
        return val

    out = {}
    for sec in sections:
        _key, file_off, n, s_size, _end, id_list_size, _rel, _omap, _copy = sec
        ids = struct.unpack_from("<%dI" % (id_list_size // 4), b, file_off + n * rec_size + s_size)
        for i in range(n):
            rp = file_off + i * rec_size
            rid = ids[i]
            name_off = struct.unpack_from("<I", b, rp)[0]
            sp = rp + name_off
            name = b[sp:b.index(b"\0", sp)].decode("utf-8", "replace") if name_off else ""
            out[rid] = {"name": name, "flags": field_value(rp, rid, 2),
                        "sound": field_value(rp, rid, 3)}
    return out, fsi


if __name__ == "__main__":
    c = casc.open_default()
    table, fsi = parse(c.read_fdid(1371380))
    print("field storage (first 5):", fsi[:5])
    for rid in sorted(table):
        print(rid, table[rid])
    if len(sys.argv) > 1:
        json.dump(table, open(os.path.join(sys.argv[1], "liquid_types.json"), "w"))
