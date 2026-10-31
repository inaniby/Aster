#!/usr/bin/env python3
"""Aster hostile-input corpus generator (sanitizer campaign).

Writes `--count` deterministic mutations of one seed file into `--outdir`.
The seed decides the recipe:

  elf   the ELF header and section/program header fields (e_shoff,
        sh_offset/sh_size/sh_addralign, p_offset/p_filesz/p_memsz/p_align)
        are overwritten with boundary values, plus generic byte churn.
  zip   the central-directory, local-header and EOCD length/offset fields
        are overwritten (nameLen, extraLen, commentLen, localOff, cdSize,
        cdStart, entry counts), plus the APK Signing Block size fields and
        generic byte churn.  These are the fields whose bounds checks the
        reader relies on.
  der   ASN.1 length octets are turned into long-form / oversized values,
        plus generic byte churn.
  pem   base64 body characters, line breaks and the BEGIN/END lines are
        corrupted, plus generic byte churn.
  auto  detect by the first bytes (ELF magic, ZIP/APK structure, DER SEQUENCE,
        PEM armour); anything else gets generic mutations.

Half the corpus uses the targeted recipe and half uses generic mutations, so
the suite exercises both "a structurally plausible file with one field wrong"
and "arbitrary corruption".  Every output is reproducible from the seed:
the same seed file, --seed and --count produce byte-identical files.

This tool never interprets the input; it only needs it to be readable.
"""

import argparse
import os
import random

INTERESTING = [
    0, 1, 2, 3, 4, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF,
    0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF,
    0x7FFFFFFFFFFFFFFF, 0x8000000000000000, 0xFFFFFFFFFFFFFFFF,
]


def put_int(buf, offset, size, value):
    """Store the low `size` bytes of `value` little-endian, if in bounds."""
    if offset < 0 or size <= 0 or offset + size > len(buf):
        return
    mask = (1 << (8 * size)) - 1
    buf[offset:offset + size] = (value & mask).to_bytes(size, "little")


def generic(data, rnd):
    """One to four random edits: truncate, flip, overwrite, insert, delete."""
    buf = bytearray(data)
    for _ in range(rnd.randint(1, 4)):
        if not buf:
            buf = bytearray(b"A")
        op = rnd.randint(0, 7)
        if op == 0 and len(buf) > 2:                       # truncate
            buf = buf[:rnd.randrange(1, len(buf))]
        elif op == 1:                                      # flip one byte
            buf[rnd.randrange(len(buf))] = rnd.randrange(256)
        elif op == 2:                                      # overwrite a span
            i = rnd.randrange(len(buf))
            n = min(len(buf) - i, rnd.randint(1, 32))
            buf[i:i + n] = bytes(rnd.randrange(256) for _ in range(n))
        elif op == 3:                                      # insert junk
            i = rnd.randrange(len(buf) + 1)
            buf[i:i] = bytes(rnd.randrange(256) for _ in range(rnd.randint(1, 16)))
        elif op == 4 and len(buf) > 8:                     # delete a span
            i = rnd.randrange(len(buf))
            del buf[i:i + min(len(buf) - i, rnd.randint(1, 8))]
        elif op == 5:                                      # duplicate a span
            i = rnd.randrange(len(buf))
            n = min(len(buf) - i, rnd.randint(1, 16))
            j = rnd.randrange(len(buf) + 1)
            buf[j:j] = buf[i:i + n]
        elif op == 6:                                      # boundary integer
            i = rnd.randrange(len(buf))
            put_int(buf, i, rnd.choice([2, 4, 8]), rnd.choice(INTERESTING))
        else:                                              # bit flips
            i = rnd.randrange(len(buf))
            n = min(len(buf) - i, rnd.randint(1, 64))
            for k in range(i, i + n):
                buf[k] ^= 1 << rnd.randrange(8)
    return bytes(buf)


def find_all(buf, pattern):
    out, i = [], 0
    while True:
        i = buf.find(pattern, i)
        if i < 0:
            return out
        out.append(i)
        i += 1


def targeted_elf(data, rnd):
    buf = bytearray(data)
    if len(buf) < 64:
        return generic(data, rnd)
    # e_phoff, e_shoff, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx
    put_int(buf, rnd.choice([0x20, 0x28]), 8, rnd.choice(INTERESTING))
    put_int(buf, rnd.choice([0x36, 0x38, 0x3A, 0x3C, 0x3E]), 2,
            rnd.choice(INTERESTING))
    shoff = int.from_bytes(data[0x28:0x30], "little")
    shentsize = int.from_bytes(data[0x3A:0x3C], "little")
    shnum = int.from_bytes(data[0x3C:0x3E], "little")
    phoff = int.from_bytes(data[0x20:0x28], "little")
    if 64 <= shoff < len(data) and 40 <= shentsize <= 256:
        for _ in range(rnd.randint(1, 4)):
            s = shoff + rnd.randrange(max(1, shnum)) * shentsize
            # sh_type, sh_offset, sh_size, sh_link, sh_info, sh_addralign
            field = rnd.choice([(4, 4), (24, 8), (32, 8), (40, 4), (44, 4), (48, 8)])
            put_int(buf, s + field[0], field[1], rnd.choice(INTERESTING))
    if 64 <= phoff < len(data):
        # p_offset, p_filesz, p_memsz, p_align
        field = rnd.choice([(8, 8), (32, 8), (40, 8), (48, 8)])
        put_int(buf, phoff + field[0], field[1], rnd.choice(INTERESTING))
    return bytes(buf)


ZIP_CD = b"PK\x01\x02"
ZIP_LOCAL = b"PK\x03\x04"
ZIP_EOCD = b"PK\x05\x06"
APK_SIG = b"APK Sig Block 42"


def targeted_zip(data, rnd):
    buf = bytearray(data)
    hits = []
    for pattern in (ZIP_CD, ZIP_LOCAL, ZIP_EOCD, APK_SIG):
        for i in find_all(data, pattern):
            hits.append((pattern, i))
    if not hits:
        return generic(data, rnd)
    pattern, i = rnd.choice(hits)
    if pattern == ZIP_CD:
        # flags, method, crc, compSize, uncompSize, nameLen, extraLen,
        # commentLen, localOff
        field = rnd.choice([(8, 2), (10, 2), (16, 4), (20, 4), (24, 4),
                           (28, 2), (30, 2), (32, 2), (42, 4)])
    elif pattern == ZIP_LOCAL:
        # flags, method, crc, compSize, uncompSize, nameLen, extraLen
        field = rnd.choice([(6, 2), (8, 2), (14, 4), (18, 4), (22, 4),
                           (26, 2), (28, 2)])
    elif pattern == ZIP_EOCD:
        # entry counts, cdSize, cdStart, commentLen
        field = rnd.choice([(8, 2), (10, 2), (12, 4), (16, 4), (20, 2)])
    else:
        # size of block, size of first pair, block id length
        field = rnd.choice([(4, 8), (12, 8), (20, 8)])
    put_int(buf, i + field[0], field[1], rnd.choice(INTERESTING))
    if rnd.random() < 0.5:
        buf[rnd.randrange(len(buf))] ^= 1 << rnd.randrange(8)
    return bytes(buf)


def targeted_der(data, rnd):
    buf = bytearray(data)
    # Turn short-form ASN.1 lengths into long/oversized forms, or extend the
    # length past the end of the buffer.  A length octet is any byte < 0x80
    # that follows a tag byte; trying a random selection is enough here.
    tags = [i for i, b in enumerate(data)
            if b in (0x30, 0x31, 0x02, 0x03, 0x04, 0x05, 0x06, 0x0A, 0x0C)]
    if not tags:
        return generic(data, rnd)
    for _ in range(rnd.randint(1, 3)):
        i = rnd.choice(tags)
        j = i + 1
        if j < len(buf) and buf[j] < 0x80:
            buf[j] = rnd.choice([0x7F, 0x80, 0x81, 0x82, 0x84, 0xFF])
        elif j < len(buf):
            buf[j] = rnd.choice([0x00, 0x7F, 0x80, 0xFF])
    if rnd.random() < 0.5:
        i = rnd.randrange(len(buf))
        buf[i:i + 1] = bytes([rnd.randrange(256)])
    return bytes(buf)


def targeted_pem(data, rnd):
    buf = bytearray(data)
    body = [i for i, b in enumerate(data)
            if chr(b).isalnum() or b in (ord("+"), ord("/"), ord("="))]
    if body:
        for _ in range(rnd.randint(1, 6)):
            i = rnd.choice(body)
            buf[i] = rnd.choice(
                b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
    if rnd.random() < 0.4 and len(buf) > 40:
        # remove or duplicate a line break, which changes base64 framing
        breaks = [i for i, b in enumerate(data) if b == ord("\n")]
        if breaks:
            i = rnd.choice(breaks)
            if rnd.random() < 0.5:
                del buf[i]
            else:
                buf[i:i + 1] = b"\n\n"
    if rnd.random() < 0.3:
        i = rnd.choice([0, max(0, len(buf) - 5)])
        buf[i:i + 5] = rnd.choice([b"DEr--", b"-----", b"\x00\x01\x02\x03\x04"])
    return bytes(buf)


def detect(data):
    if data.startswith(b"\x7fELF"):
        return "elf"
    if data.startswith(b"-----BEGIN"):
        return "pem"
    if data.startswith(b"\x30"):
        return "der"
    if ZIP_EOCD in data and ZIP_CD in data:
        return "zip"
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--seed-file", required=True)
    ap.add_argument("--outdir", required=True)
    ap.add_argument("--count", type=int, required=True)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--format", choices=["auto", "elf", "zip", "der", "pem"],
                    default="auto")
    args = ap.parse_args()

    data = open(args.seed_file, "rb").read()
    fmt = detect(data) if args.format == "auto" else args.format
    rnd = random.Random(args.seed)
    os.makedirs(args.outdir, exist_ok=True)

    target = {
        "elf": targeted_elf,
        "zip": targeted_zip,
        "der": targeted_der,
        "pem": targeted_pem,
    }.get(fmt)

    for i in range(args.count):
        if target is not None and i < args.count // 2:
            blob = target(data, rnd)
        else:
            blob = generic(data, rnd)
        with open(os.path.join(args.outdir, f"{i:04d}.bin"), "wb") as fh:
            fh.write(blob)


if __name__ == "__main__":
    main()
