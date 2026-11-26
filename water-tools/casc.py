"""Minimal read-only reader for a local World of Warcraft CASC install.

Only what the water extractor needs: look a file up by FileDataID and return
its decoded bytes. Nothing is written to the game folder.
"""
import glob
import os
import struct
import zlib


class Casc:
    def __init__(self, wow_root, build_key):
        self.data_dir = os.path.join(wow_root, "Data", "data")
        self.archives = {}
        self.index = {}          # first 9 bytes of ekey -> (archive, offset, size)
        self._load_indices()
        cfg = self._read_config(os.path.join(
            wow_root, "Data", "config", build_key[:2], build_key[2:4], build_key))
        self.config = cfg
        enc_ckey, enc_ekey = cfg["encoding"].split()
        self.ckey_to_ekey = {}
        self._load_encoding(self.read_ekey(bytes.fromhex(enc_ekey)))
        root_ckey = bytes.fromhex(cfg["root"].split()[0])
        self.fdid_to_ckeys = {}
        self._load_root(self.read_ckey(root_ckey))

    # -- config ------------------------------------------------------------
    @staticmethod
    def _read_config(path):
        out = {}
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                if " = " in line and not line.startswith("#"):
                    k, v = line.rstrip("\n").split(" = ", 1)
                    out[k] = v
        return out

    # -- local index -------------------------------------------------------
    def _load_indices(self):
        newest = {}
        for path in glob.glob(os.path.join(self.data_dir, "*.idx")):
            name = os.path.basename(path)
            bucket, version = name[:2], int(name[2:10], 16)
            if bucket not in newest or version > newest[bucket][0]:
                newest[bucket] = (version, path)
        for _, path in newest.values():
            with open(path, "rb") as f:
                buf = f.read()
            hdr_size = struct.unpack_from("<I", buf, 0)[0]
            # header fields start at 8
            _, _, _, size_len, off_len, key_len, off_bits = struct.unpack_from("<HBBBBBB", buf, 8)
            pos = (8 + hdr_size + 0x0F) & ~0x0F
            entries_size = struct.unpack_from("<I", buf, pos)[0]
            pos += 8
            rec = key_len + off_len + size_len
            end = pos + entries_size
            mask = (1 << off_bits) - 1
            while pos + rec <= end:
                key = buf[pos:pos + key_len]
                packed = int.from_bytes(buf[pos + key_len:pos + key_len + off_len], "big")
                size = int.from_bytes(buf[pos + key_len + off_len:pos + rec], "little")
                self.index.setdefault(key, (packed >> off_bits, packed & mask, size))
                pos += rec

    def _archive(self, n):
        fh = self.archives.get(n)
        if fh is None:
            fh = open(os.path.join(self.data_dir, "data.%03d" % n), "rb")
            self.archives[n] = fh
        return fh

    # -- BLTE --------------------------------------------------------------
    @staticmethod
    def _blte(buf):
        if buf[:4] != b"BLTE":
            raise ValueError("not BLTE")
        header_size = struct.unpack_from(">I", buf, 4)[0]
        if header_size == 0:
            return Casc._chunk(buf[8:])
        count = int.from_bytes(buf[9:12], "big")
        pos = 12
        sizes = []
        for _ in range(count):
            comp, _decomp = struct.unpack_from(">II", buf, pos)
            sizes.append(comp)
            pos += 24
        out = []
        pos = header_size
        for comp in sizes:
            out.append(Casc._chunk(buf[pos:pos + comp]))
            pos += comp
        return b"".join(out)

    @staticmethod
    def _chunk(data):
        mode = data[:1]
        if mode == b"N":
            return data[1:]
        if mode == b"Z":
            return zlib.decompress(data[1:])
        if mode == b"F":
            return Casc._blte(data[1:])
        raise ValueError("unsupported BLTE chunk mode %r" % mode)

    # -- reads -------------------------------------------------------------
    def read_ekey(self, ekey):
        entry = self.index.get(ekey[:9])
        if entry is None:
            raise KeyError("ekey not in local storage")
        archive, offset, size = entry
        fh = self._archive(archive)
        fh.seek(offset + 0x1E)
        return self._blte(fh.read(size - 0x1E))

    def read_ckey(self, ckey):
        ekey = self.ckey_to_ekey.get(ckey)
        if ekey is None:
            raise KeyError("ckey not in encoding")
        return self.read_ekey(ekey)

    def read_fdid(self, fdid):
        last = None
        for ckey in self.fdid_to_ckeys.get(fdid, ()):
            try:
                return self.read_ckey(ckey)
            except (KeyError, ValueError) as e:
                last = e
        raise KeyError("fdid %d unavailable (%s)" % (fdid, last))

    def has_fdid(self, fdid):
        return fdid in self.fdid_to_ckeys

    # -- encoding ----------------------------------------------------------
    def _load_encoding(self, buf):
        if buf[:2] != b"EN":
            raise ValueError("bad encoding file")
        (_ver, ck_len, ek_len, ck_page_kb, _ek_page_kb, ck_pages, _ek_pages,
         _unk, espec_size) = struct.unpack_from(">BBBHHIIBI", buf, 2)
        pos = 22 + espec_size + ck_pages * (ck_len + 16)
        page_size = ck_page_kb * 1024
        for p in range(ck_pages):
            q = pos + p * page_size
            end = q + page_size
            while q + 6 + ck_len <= end:
                key_count = buf[q]
                if key_count == 0:
                    break
                ckey = buf[q + 6:q + 6 + ck_len]
                ekey = buf[q + 6 + ck_len:q + 6 + ck_len + ek_len]
                self.ckey_to_ekey[ckey] = ekey
                q += 6 + ck_len + ek_len * key_count

    # -- root --------------------------------------------------------------
    def _load_root(self, buf):
        if buf[:4] != b"TSFM":
            raise ValueError("unexpected root format %r" % buf[:4])
        a, b = struct.unpack_from("<II", buf, 4)
        if a < 100:               # new header: headerSize, version, total, named, pad
            header_size, version = a, b
            total, named = struct.unpack_from("<II", buf, 12)
            pos = header_size
        else:                     # old header: total, named
            version, total, named = 0, a, b
            pos = 12
        self.root_version = version
        all_named = (total == named)
        n = len(buf)
        while pos < n:
            if version >= 2:
                count, _locale, f1, f2, f3 = struct.unpack_from("<IIIIB", buf, pos)
                pos += 17
                content = f1 | f2 | (f3 << 17)
            else:
                count, content, _locale = struct.unpack_from("<III", buf, pos)
                pos += 12
            deltas = struct.unpack_from("<%di" % count, buf, pos)
            pos += 4 * count
            fdid = -1
            for i in range(count):
                fdid += deltas[i] + 1
                ckey = buf[pos + 16 * i:pos + 16 * i + 16]
                self.fdid_to_ckeys.setdefault(fdid, []).append(ckey)
            pos += 16 * count
            if all_named or not (content & 0x10000000):
                pos += 8 * count
        if pos != n:
            raise ValueError("root parse ended at %d of %d" % (pos, n))


def open_default():
    root = r"C:\Program Files (x86)\World of Warcraft"
    with open(os.path.join(root, ".build.info"), "r") as f:
        lines = f.read().splitlines()
    cols = [c.split("!")[0] for c in lines[0].split("|")]
    row = dict(zip(cols, lines[1].split("|")))
    return Casc(root, row["Build Key"])


if __name__ == "__main__":
    import time
    t = time.time()
    c = open_default()
    print("index entries", len(c.index), "encoding", len(c.ckey_to_ekey),
          "root fdids", len(c.fdid_to_ckeys), "root version", c.root_version,
          "%.1fs" % (time.time() - t))
    for name, fdid in (("Azeroth.wdt", 775971), ("Kalimdor.wdt", 782779)):
        try:
            d = c.read_fdid(fdid)
            print(name, fdid, len(d), d[:4])
        except Exception as e:
            print(name, fdid, "FAILED", e)
