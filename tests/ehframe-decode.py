#!/usr/bin/env python3
"""Stand-alone .eh_frame / .eh_frame_hdr decoder for Aster's test suite.

Why this exists: the suite has to prove what aster wrote, not what a tool
chooses to show. This reads .eh_frame and .eh_frame_hdr straight out of the
ELF64 section table by hand (no pyelftools, no objdump), applies Aster's own
relocations when the file is still relocatable, runs each CFI program through a
row machine, and prints the result in a form a shell script can assert on.

Aster's frames are uniform — every function's prologue is exactly
`SUB SP, SP, #8192` and SP never moves again — so a whole function's unwind
table is a handful of bytes:

    CFA        r31 (sp) + 8192, from one instruction past the prologue
    r30 (x30)  at CFA-8, for a body that returns; absent for main, which exits

Modes:

    (default)   the whole table: one CIE line and one FDE line per function,
                each followed by its CFI instructions indented
    --cie       one line: the CIE's fields
    --ciehex    the CIE entry's raw bytes as hex, so two producers can be
                compared byte for byte
    --fdes      one line per FDE: <pc_begin> <pc_end> <cfa> <return-address>
                e.g. 0x401000 0x40102c r31+8192 cfa-8
    --hdr       the .eh_frame_hdr: one line of fields, then one line per row,
                <function-start> <fde-address>, in the order they are stored

A missing section prints nothing and exits 0, so a suite can count lines.

Usage:
    ehframe-decode.py [--cie|--fdes|--hdr] <elf-file>
"""
import sys

# The ELF reader is a deliberate copy of the ones in debugline-decode.py and
# debuginfo-decode.py: each decoder is an independent witness over its own
# section, and none should break because another changed.


def die(msg):
    sys.stderr.write("ehframe-decode: %s\n" % msg)
    sys.exit(1)


def u16(b, o):
    return b[o] | (b[o + 1] << 8)


def u32(b, o):
    return b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)


def u64(b, o):
    v = 0
    for i in range(8):
        v |= b[o + i] << (8 * i)
    return v


def read_uleb(b, o):
    val = 0
    shift = 0
    while True:
        byte = b[o]
        o += 1
        val |= (byte & 0x7F) << shift
        shift += 7
        if not (byte & 0x80):
            return val, o


def read_sleb(b, o):
    val = 0
    shift = 0
    while True:
        byte = b[o]
        o += 1
        val |= (byte & 0x7F) << shift
        shift += 7
        if not (byte & 0x80):
            if byte & 0x40:
                val -= 1 << shift
            return val, o


class Elf(object):
    """Just enough ELF64 little-endian to find a section and its relocations."""

    def __init__(self, path):
        with open(path, "rb") as f:
            self.b = bytearray(f.read())
        b = self.b
        if len(b) < 64 or b[:4] != b"\x7fELF":
            die("%s is not an ELF file" % path)
        if b[4] != 2:
            die("%s is not ELF64" % path)
        if b[5] != 1:
            die("%s is not little-endian" % path)
        self.shoff = u64(b, 0x28)
        self.shentsize = u16(b, 0x3A)
        self.shnum = u16(b, 0x3C)
        self.shstrndx = u16(b, 0x3E)
        self.secs = []
        for i in range(self.shnum):
            o = self.shoff + i * self.shentsize
            self.secs.append({
                "name_off": u32(b, o),
                "addr": u64(b, o + 16),
                "offset": u32(b, o + 24),
                "size": u64(b, o + 32),
                "link": u32(b, o + 40),
                "entsize": u64(b, o + 56),
            })
        strtab = self.raw(self.shstrndx)
        for s in self.secs:
            end = strtab.find(b"\0", s["name_off"])
            s["name"] = strtab[s["name_off"]:end].decode("utf-8", "replace")

    def raw(self, index):
        s = self.secs[index]
        return bytes(self.b[s["offset"]:s["offset"] + s["size"]])

    def section_bytes(self, sec):
        return bytes(self.b[sec["offset"]:sec["offset"] + sec["size"]])

    def find(self, name):
        for s in self.secs:
            if s["name"] == name:
                return s
        return None

    def symbols(self):
        """{index: (name, value, size)} over .symtab."""
        sec = self.find(".symtab")
        out = {}
        if sec is None:
            return out
        strtab = self.raw(sec["link"])
        for i in range(sec["size"] // 24):
            o = sec["offset"] + i * 24
            name_off = u32(self.b, o)
            value = u64(self.b, o + 8)
            size = u64(self.b, o + 16)
            end = strtab.find(b"\0", name_off)
            out[i] = (strtab[name_off:end].decode("utf-8", "replace"), value, size)
        return out

    def apply_relocs(self, sec, data):
        """Apply .rela.<name> to a copy of a section's bytes.

        A relocatable object leaves every FDE address as zero and says how to
        fix it instead; without this the whole table would read as a pile of
        functions sitting at address 0.
        """
        rel = self.find(".rela" + sec["name"])
        if rel is None:
            return data
        syms = self.symbols()
        entsize = rel["entsize"] or 24
        out = bytearray(data)
        for i in range(rel["size"] // entsize):
            o = rel["offset"] + i * entsize
            r_offset = u64(self.b, o)
            r_info = u64(self.b, o + 8)
            r_addend = u64(self.b, o + 16)
            if r_addend >> 63:
                r_addend -= 1 << 64
            rtype = r_info & 0xFFFFFFFF
            name, value, _size = syms.get(r_info >> 32, ("", 0, 0))
            if rtype == 261:            # R_AARCH64_PREL32: S + A - P
                v = (value + r_addend - (sec["addr"] + r_offset)) % (1 << 64)
                for k in range(4):
                    out[r_offset + k] = (v >> (8 * k)) & 0xFF
            elif rtype == 257:          # R_AARCH64_ABS64: S + A
                v = (value + r_addend) % (1 << 64)
                for k in range(8):
                    out[r_offset + k] = (v >> (8 * k)) & 0xFF
            else:
                die("unsupported relocation type %d against %s (symbol %s)"
                    % (rtype, sec["name"], name))
        return bytes(out)


# --- DW_EH_PE pointer encodings ------------------------------------------------
DW_EH_PE_omit = 0xFF

# How many bytes each format field occupies; ULEB/SLEB are variable and skipped.
FIXED_WIDTHS = {0x02: 2, 0x03: 4, 0x04: 8, 0x0A: 2, 0x0B: 4, 0x0C: 8}


def read_encoded(b, o, enc, pc_base, datarel_base):
    """Read one pointer encoded the way the augmentation string asked for."""
    if enc == DW_EH_PE_omit:
        return None, o
    fmt = enc & 0x0F
    app = enc & 0x70
    if fmt == 0x01:                 # uleb128
        v, o = read_uleb(b, o)
    elif fmt == 0x09:               # sleb128
        v, o = read_sleb(b, o)
    else:
        if fmt not in FIXED_WIDTHS:
            die("unsupported pointer encoding 0x%02x" % enc)
        w = FIXED_WIDTHS[fmt]
        v = 0
        for k in range(w):
            v |= b[o + k] << (8 * k)
        o += w
        if fmt in (0x0A, 0x0B, 0x0C) and v & (1 << (8 * w - 1)):
            v -= 1 << (8 * w)       # sdataN: sign extend
    if app == 0x10:                 # pcrel
        v += pc_base
    elif app == 0x30:               # datarel
        v += datarel_base
    elif app == 0x20:
        die("DW_EH_PE_textrel needs a text base this decoder does not take")
    elif app == 0x40:
        die("DW_EH_PE_funcrel needs a function base this decoder does not take")
    elif app == 0x50:
        die("DW_EH_PE_aligned is not used by Aster")
    if enc & 0x80:
        die("DW_EH_PE_indirect is not used by Aster")
    return v, o


# --- CFI -----------------------------------------------------------------------
class Cie(object):
    def __init__(self):
        self.version = 0
        self.augmentation = ""
        self.code_align = 1
        self.data_align = 1
        self.ra_column = 0
        self.aug_data = b""
        self.fde_ptr_enc = 0x00     # from 'R'; absptr when there is no 'R'
        self.body_start = 0
        self.body_end = 0
        self.offset = 0             # where the entry's length field sits
        self.total = 0              # and how many bytes it occupies in all


class Row(object):
    def __init__(self):
        self.loc = 0
        self.cfa_reg = None
        self.cfa_off = 0
        self.rules = {}             # register -> ("offset", n)

    def cfa(self):
        if self.cfa_reg is None:
            return "undefined"
        return "r%d+%d" % (self.cfa_reg, self.cfa_off)

    def rule(self, reg):
        r = self.rules.get(reg)
        if r is None:
            return "-"
        if r[0] == "offset":
            n = r[1]
            return "cfa-%d" % (-n) if n < 0 else "cfa+%d" % n
        return r[0]


def run_cfi(b, start, end, cie, row, trace):
    """Advance a row through one CFI program, in place.

    Only the opcodes Aster emits are understood; anything else is an error
    rather than silence, so a change in the format cannot pass unnoticed.
    A caller passes the row the CIE's own initial instructions left behind,
    which is where an FDE's program starts.
    """
    o = start
    while o < end:
        op = b[o]
        o += 1
        high = op & 0xC0
        low = op & 0x3F
        if high == 0x40:                                # DW_CFA_advance_loc
            row.loc += low * cie.code_align
            trace.append("DW_CFA_advance_loc %d" % (low * cie.code_align))
        elif high == 0x80:                              # DW_CFA_offset
            off, o = read_uleb(b, o)
            row.rules[low] = ("offset", off * cie.data_align)
            trace.append("DW_CFA_offset r%d at %s" % (low, row.rule(low)))
        elif op == 0x00:                                # DW_CFA_nop
            trace.append("DW_CFA_nop")
        elif op == 0x0C:                                # DW_CFA_def_cfa
            reg, o = read_uleb(b, o)
            off, o = read_uleb(b, o)
            row.cfa_reg = reg
            row.cfa_off = off
            trace.append("DW_CFA_def_cfa r%d ofs %d" % (reg, off))
        elif op == 0x0D:                                # DW_CFA_def_cfa_register
            reg, o = read_uleb(b, o)
            row.cfa_reg = reg
            trace.append("DW_CFA_def_cfa_register r%d" % reg)
        elif op == 0x0E:                                # DW_CFA_def_cfa_offset
            off, o = read_uleb(b, o)
            row.cfa_off = off
            trace.append("DW_CFA_def_cfa_offset %d" % off)
        elif op == 0x0A:                                # DW_CFA_remember_state
            trace.append("DW_CFA_remember_state")
        elif op == 0x0B:                                # DW_CFA_restore_state
            trace.append("DW_CFA_restore_state")
        else:
            die("unsupported CFI opcode 0x%02x at offset 0x%x — the format "
                "grew and this decoder has to grow with it" % (op, o - 1))
    return trace


def encoded_width(enc):
    """How many bytes one encoded pointer takes, for walking augmentation data."""
    fmt = enc & 0x0F
    if fmt in (0x01, 0x09):
        die("a variable-length pointer encoding cannot be stepped over here")
    return FIXED_WIDTHS.get(fmt, 8)


def parse_cie(b, body, length):
    """A CIE: a zero where an FDE has a pointer back to one, then its fields."""
    c = Cie()
    o = body + 4                    # past the CIE_id that identifies it
    c.version = b[o]
    o += 1
    end = b.find(b"\0", o)
    c.augmentation = b[o:end].decode("ascii")
    o = end + 1
    aug = c.augmentation
    if aug.startswith("eh"):        # the old GNU marker for a CIE
        aug = aug[2:]
    if c.version >= 4:
        o += 2                      # address_size, segment_selector_size
    c.code_align, o = read_uleb(b, o)
    c.data_align, o = read_sleb(b, o)
    if c.version >= 4:
        c.ra_column, o = read_uleb(b, o)
    else:
        c.ra_column = b[o]
        o += 1
    if aug.startswith("z"):
        aug_len, o = read_uleb(b, o)
        c.aug_data = bytes(b[o:o + aug_len])
        o += aug_len
        aug = aug[1:]
    p = 0
    if p < len(aug) and aug[p] == "L":      # an LSDA encoding byte
        p += 1
    if p < len(aug) and aug[p] == "P":      # a personality: encoding, value
        p += 1
        if p < len(c.aug_data):
            p += encoded_width(c.aug_data[p])
    if p < len(aug) and aug[p] == "R":      # the FDE pointer encoding
        c.fde_ptr_enc = c.aug_data[p]
    c.body_start = o
    c.body_end = body + length
    return c


def parse(elf, sec):
    """Walk [length][id] entries: id 0 is a CIE, anything else an FDE.

    Returns (entries, cie, data): every CIE in the file is the same one, the
    FDE rows are the part the suite asserts on, and the bytes come back so a
    caller can compare one producer's table against another's.
    """
    data = elf.apply_relocs(sec, elf.section_bytes(sec))
    base = sec["addr"]
    entries = []
    cies = {}                       # offset of a CIE -> the parsed Cie
    cie = None
    o = 0
    while o + 4 <= len(data):
        length = u32(data, o)
        if length == 0:
            break                   # a terminator: the table is over
        if length == 0xFFFFFFFF:
            die("64-bit DWARF .eh_frame is not something Aster writes")
        body = o + 4
        end = body + length
        if end > len(data):
            die("an .eh_frame entry runs past the end of the section")
        if u32(data, body) == 0:
            cies[o] = parse_cie(data, body, length)
            cies[o].offset = o
            cies[o].total = 4 + length
            if cie is None:
                cie = cies[o]
        else:
            # The pointer is a distance backwards from its own field, which is
            # the four bytes the entry's length does not count.
            cie_start = body - u32(data, body)
            if cie_start not in cies:
                die("an FDE points at 0x%x, which is not a CIE" % cie_start)
            cie = cies[cie_start]
            p = body + 4
            pc_begin, p = read_encoded(data, p, cie.fde_ptr_enc, base + p, 0)
            # The range reuses the encoding, but a pcrel range would be
            # nonsense: every reader, gcc's included, takes it as a plain size.
            range_enc = cie.fde_ptr_enc & 0x8F
            if range_enc & 0x0F == 0x00:
                range_enc = (range_enc & 0x70) | 0x04
            pc_range, p = read_encoded(data, p, range_enc, 0, 0)
            if "z" in cie.augmentation:
                aug_len, p = read_uleb(data, p)
                p += aug_len
            # An FDE starts from the row the CIE's own instructions leave, so
            # the CFA rule a function never repeats is still in force.
            row = Row()
            row.loc = pc_begin
            run_cfi(data, cie.body_start, cie.body_end, cie, row, [])
            trace = run_cfi(data, p, end, cie, row, [])
            entries.append({"pc_begin": pc_begin, "pc_end": pc_begin + pc_range,
                            "row": row, "trace": trace})
        o = end
    return entries, cie, data


def emit_cie(c):
    return ("version=%d augmentation=%s code_alignment=%d data_alignment=%d "
            "ra_column=%d augmentation_data=%s"
            % (c.version, c.augmentation, c.code_align, c.data_align,
               c.ra_column, c.aug_data.hex()))


def dump_hdr(elf):
    sec = elf.find(".eh_frame_hdr")
    if sec is None:
        return
    d = elf.section_bytes(sec)
    base = sec["addr"]
    enc_ptr, enc_cnt, enc_tbl = d[1], d[2], d[3]
    ptr, o = read_encoded(d, 4, enc_ptr, base + 4, 0)
    cnt, o = read_encoded(d, o, enc_cnt, 0, 0)
    lines = ["version=%d eh_frame_ptr_enc=0x%02x eh_frame_ptr=0x%x "
             "fde_count_enc=0x%02x fde_count=%d table_enc=0x%02x"
             % (d[0], enc_ptr, ptr, enc_cnt, cnt, enc_tbl)]
    if enc_tbl == DW_EH_PE_omit:
        return
    for _ in range(cnt):
        start, o = read_encoded(d, o, enc_tbl, 0, base)
        fde, o = read_encoded(d, o, enc_tbl, 0, base)
        lines.append("0x%x 0x%x" % (start, fde))
    sys.stdout.write("\n".join(lines) + "\n")


def main(argv):
    mode = ""
    path = None
    for a in argv[1:]:
        if a in ("--cie", "--ciehex", "--fdes", "--hdr"):
            mode = a
        elif a in ("-h", "--help"):
            sys.stdout.write(__doc__)
            return 0
        elif a.startswith("-"):
            die("unknown option %s" % a)
        else:
            path = a
    if path is None:
        die("no input file")

    elf = Elf(path)
    if mode == "--hdr":
        dump_hdr(elf)
        return 0

    sec = elf.find(".eh_frame")
    if sec is None:
        return 0
    entries, cie, data = parse(elf, sec)
    if not entries:
        return 0

    if mode == "--cie":
        sys.stdout.write(emit_cie(cie) + "\n")
        return 0
    if mode == "--ciehex":
        sys.stdout.write(data[cie.offset:cie.offset + cie.total].hex() + "\n")
        return 0
    if mode == "--fdes":
        for e in entries:
            sys.stdout.write("0x%x 0x%x %s %s\n"
                             % (e["pc_begin"], e["pc_end"], e["row"].cfa(),
                                e["row"].rule(cie.ra_column)))
        return 0

    sys.stdout.write("CIE " + emit_cie(cie) + "\n")
    cie_row = Row()
    for line in run_cfi(elf.section_bytes(sec), cie.body_start, cie.body_end,
                        cie, cie_row, []):
        sys.stdout.write("    " + line + "\n")
    for e in entries:
        sys.stdout.write("FDE pc=0x%x..0x%x\n" % (e["pc_begin"], e["pc_end"]))
        for line in e["trace"]:
            sys.stdout.write("    " + line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
