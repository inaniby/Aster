#!/usr/bin/env python3
"""Structured (semantic) APK mutants from a seed APK (v0.23.81-dev, fuzz batch).

Each mutant is built by parsing the ZIP/Signing-Block structure, not by
random byte churn, so the mutation has a known meaning. The sanitizer suite
(tests/sanitizer-checks.sh step [5/9]) runs every mutant through the ASan
`verify-apk` and asserts the expected outcome:

  reject (exit 1)  every mutant that breaks integrity or structure: payload
                   and manifest flips, truncation, an extra META-INF or
                   payload entry, local/central extraLen disagreement, the
                   Signing Block size2 disagreement (the counter-proof for
                   the size2 check), a duplicated signer, a duplicated
                   central-directory entry, a wrong EOCD cdStart, a renamed
                   CERT.SF, a flipped CRC.
  accept (exit 0)  v3-pair-added: an unknown Signing Block ID must be
                   ignored, so a v3 pair next to a valid v2 pair still
                   verifies.
  reject (exit 1)  dup-v2-pair: a duplicated v2 pair was a KNOWN GAP in the
                   fuzz batch (the verifier kept the last v2 pair and
                   silently ignored the first); v0.23.81-dev rejects any
                   Signing Block ID that appears twice, so this mutant is
                   now rejected like the other 14.

Writes <outdir>/<name>.apk for each mutant. Deterministic, no randomness.
"""
import os, struct, sys, zlib

MAG = b"APK Sig Block 42"
V2_ID = 0x7109871a
V3_ID = 0x1b93ad61


def u16(b, o): return struct.unpack_from("<H", b, o)[0]
def u32(b, o): return struct.unpack_from("<I", b, o)[0]
def u64(b, o): return struct.unpack_from("<Q", b, o)[0]
def p16(v): return struct.pack("<H", v)
def p32(v): return struct.pack("<I", v)
def p64(v): return struct.pack("<Q", v)


def parse(buf):
    """Return dict with locals, cd entries, eocd offset, sb start/end."""
    eocd = buf.rfind(b"PK\x05\x06")
    assert eocd >= 0
    cd_size = u32(buf, eocd + 12)
    cd_start = u32(buf, eocd + 16)
    count = u16(buf, eocd + 10)
    entries = []
    p = cd_start
    for _ in range(count):
        assert buf[p:p + 4] == b"PK\x01\x02", (p, buf[p:p + 4])
        nl, el, cl = u16(buf, p + 28), u16(buf, p + 30), u16(buf, p + 32)
        name = bytes(buf[p + 46:p + 46 + nl]).decode()
        entries.append({"cd_off": p, "name": name, "crc": u32(buf, p + 16),
                        "comp": u32(buf, p + 20), "local_off": u32(buf, p + 42),
                        "nl": nl, "el": el, "cl": cl})
        p += 46 + nl + el + cl
    assert p == cd_start + cd_size
    i = buf.find(MAG)
    sb_end = i + 16
    size2 = u64(buf, sb_end - 24)
    sb_start = sb_end - (size2 + 8)
    assert u64(buf, sb_start) == size2
    locals_ = []
    for e in entries:
        lo = e["local_off"]
        assert buf[lo:lo + 4] == b"PK\x03\x04"
        lnl, lel = u16(buf, lo + 26), u16(buf, lo + 28)
        data_off = lo + 30 + lnl + lel
        locals_.append({**e, "data_off": data_off, "lnl": lnl, "lel": lel})
    return {"eocd": eocd, "cd_start": cd_start, "cd_size": cd_size,
            "count": count, "entries": entries, "locals": locals_,
            "sb_start": sb_start, "sb_end": sb_end, "size2": size2}


def rebuild_sb(buf, info, new_pairs):
    """new_pairs: list of (id, value bytes). Returns buf with rebuilt block."""
    body = bytearray()
    for pid, val in new_pairs:
        body += p64(4 + len(val)) + p32(pid) + val
    blk_size = len(body) + 24
    sb = p64(blk_size) + bytes(body) + p64(blk_size) + MAG
    out = bytearray(buf[:info["sb_start"]] + sb + buf[info["sb_end"]:])
    delta = len(sb) - (info["sb_end"] - info["sb_start"])
    # EOCD moved by delta; its cdStart field points at the new CD start.
    eocd = info["eocd"] + delta
    struct.pack_into("<I", out, eocd + 16, u32(out, eocd + 16) + delta)
    return bytes(out)


def get_pairs(buf, info):
    pairs = []
    p = info["sb_start"] + 8
    end = info["sb_end"] - 24
    while p < end:
        ln = u64(buf, p)
        pid = u32(buf, p + 8)
        pairs.append((pid, bytes(buf[p + 12:p + 8 + ln])))
        p += 8 + ln
    assert p == end
    return pairs


def lp(data):
    return p32(len(data)) + data


def insert_entry(buf, info, name, data):
    """Insert a new stored entry just before the Signing Block. Returns bytes."""
    crc = zlib.crc32(data) & 0xFFFFFFFF
    nb = name.encode()
    lh = (b"PK\x03\x04" + p16(20) + p16(0) + p16(0) + p16(0) + p16(0)
          + p32(crc) + p32(len(data)) + p32(len(data)) + p16(len(nb)) + p16(0) + nb)
    local = lh + data
    new_local_off = info["sb_start"]
    ch = (b"PK\x01\x02" + p16(20) + p16(20) + p16(0) + p16(0) + p16(0) + p16(0)
          + p32(crc) + p32(len(data)) + p32(len(data)) + p16(len(nb)) + p16(0)
          + p16(0) + p16(0) + p16(0) + p32(0) + p32(new_local_off) + nb)
    out = bytearray(buf[:info["sb_start"]] + local + buf[info["sb_start"]:info["cd_start"]]
                    + buf[info["cd_start"]:info["eocd"]] + ch + buf[info["eocd"]:])
    eocd = info["eocd"] + len(local) + len(ch)
    struct.pack_into("<H", out, eocd + 8, info["count"] + 1)
    struct.pack_into("<H", out, eocd + 10, info["count"] + 1)
    struct.pack_into("<I", out, eocd + 12, info["cd_size"] + len(ch))
    struct.pack_into("<I", out, eocd + 16, info["cd_start"] + len(local))
    return bytes(out)


def main():
    seed_path, outdir = sys.argv[1], sys.argv[2]
    os.makedirs(outdir, exist_ok=True)
    raw = open(seed_path, "rb").read()
    info = parse(raw)
    out = {}

    def entry_local(name):
        for e in info["locals"]:
            if e["name"] == name:
                return e
        raise KeyError(name)

    # 1. flip a byte inside the packaged .so payload
    so = entry_local([e["name"] for e in info["locals"] if e["name"].endswith(".so")][0])
    b = bytearray(raw); b[so["data_off"] + 16] ^= 0xFF
    out["so-byte-flip"] = bytes(b)
    # 2. flip a byte inside AndroidManifest.xml payload
    mf = entry_local("AndroidManifest.xml")
    b = bytearray(raw); b[mf["data_off"] + 8] ^= 0xFF
    out["manifest-byte-flip"] = bytes(b)
    # 3/4. truncation
    out["truncate-100"] = raw[:-100]
    out["truncate-in-signing-block"] = raw[:info["sb_start"] + 10]
    # 5. an extra META-INF entry (v1 skips META-INF, v2 digest must catch it)
    out["extra-metainf-entry"] = insert_entry(raw, info, "META-INF/EXTRA.TXT", b"extra\n")
    # 6. an extra payload entry (v1 manifest coverage must catch it)
    out["extra-payload-entry"] = insert_entry(raw, info, "assets/extra.txt", b"extra\n")
    # 7. central extraLen claims 4 bytes that are not there (CD framing)
    cd = info["entries"][0]
    b = bytearray(raw)
    struct.pack_into("<H", b, cd["cd_off"] + 30, cd["el"] + 4)
    out["cd-extralen-plus4"] = bytes(b)
    # 8. local extraLen claims 4 bytes (data offset shifts -> CRC/digest)
    lo = info["locals"][0]["local_off"]
    b = bytearray(raw)
    struct.pack_into("<H", b, lo + 28, 4)
    out["local-extralen-4"] = bytes(b)
    # 9. Signing Block trailing size disagrees with the leading size
    b = bytearray(raw)
    struct.pack_into("<Q", b, info["cd_start"] - 24, info["size2"] + 1)
    out["size2-mismatch"] = bytes(b)
    # 10. duplicate the single v2 signer inside the v2 value
    pairs = get_pairs(raw, info)
    v2 = [v for pid, v in pairs if pid == V2_ID][0]
    # v2 value = lp(signers-seq); signers-seq = lp(signer) (+ maybe more)
    seq_len = u32(v2, 0)
    seq = v2[4:4 + seq_len]
    assert len(seq) == seq_len and len(v2) == 4 + seq_len
    signer_len = u32(seq, 0)
    signer = seq[4:4 + signer_len]
    assert len(signer) == signer_len and len(seq) == 4 + signer_len
    new_seq = lp(signer) + lp(signer)
    new_v2 = lp(new_seq)
    out["dup-signer"] = rebuild_sb(raw, info,
                                   [(pid, new_v2 if pid == V2_ID else v) for pid, v in pairs])
    # 11. add a v3 pair (unknown ID: must be ignored, APK still verifies)
    out["v3-pair-added"] = rebuild_sb(raw, info, pairs + [(V3_ID, b"v3-placeholder")])
    # 12. duplicate the v2 pair itself
    v2pair = [(pid, v) for pid, v in pairs if pid == V2_ID][0]
    out["dup-v2-pair"] = rebuild_sb(raw, info, pairs + [v2pair])
    # 13. duplicate a central-directory entry (same name twice)
    first = info["entries"][0]
    cd_bytes = bytes(raw[first["cd_off"]:first["cd_off"] + 46 + first["nl"] + first["el"] + first["cl"]])
    b = bytearray(raw[:info["eocd"]] + cd_bytes + raw[info["eocd"]:])
    struct.pack_into("<H", b, info["eocd"] + len(cd_bytes) + 8, info["count"] + 1)
    struct.pack_into("<H", b, info["eocd"] + len(cd_bytes) + 10, info["count"] + 1)
    struct.pack_into("<I", b, info["eocd"] + len(cd_bytes) + 12, info["cd_size"] + len(cd_bytes))
    out["dup-central-entry"] = bytes(b)
    # 14. EOCD cdStart points 8 bytes too far
    b = bytearray(raw)
    struct.pack_into("<I", b, info["eocd"] + 16, info["cd_start"] + 8)
    out["eocd-cdstart-plus8"] = bytes(b)
    # 15. rename CERT.SF -> CERT.SX in local + central headers (same length:
    # "META-INF/CERT.SF" is 16 bytes, so the rename must write exactly 16)
    b = bytearray(raw)
    for e in info["locals"]:
        if e["name"] == "META-INF/CERT.SF":
            b[e["local_off"] + 30:e["local_off"] + 30 + 16] = b"META-INF/CERT.SX"
    for e in info["entries"]:
        if e["name"] == "META-INF/CERT.SF":
            b[e["cd_off"] + 46:e["cd_off"] + 46 + 16] = b"META-INF/CERT.SX"
    out["certsf-renamed"] = bytes(b)
    # 16. flip the .so CRC in the central directory
    b = bytearray(raw)
    struct.pack_into("<I", b, so["cd_off"] + 16, so["crc"] ^ 0xFFFFFFFF)
    out["so-crc-flip"] = bytes(b)

    for name, blob in out.items():
        open(os.path.join(outdir, name + ".apk"), "wb").write(blob)
    print("wrote %d mutants to %s" % (len(out), outdir))


if __name__ == "__main__":
    main()
