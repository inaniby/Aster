#!/usr/bin/env python3
"""Stand-alone DWARF v4 .debug_info decoder for Aster's test suite (P4.3).

Why this exists: the suite must prove what aster wrote, not what a tool chooses
to show. This reads .debug_info and .debug_abbrev straight out of the ELF64
section table by hand (no pyelftools, no objdump), rebuilds the DIE tree from
the abbreviation codes, and prints it in a form a shell script can assert on:

    <indent><TAG> attr=value ...

Attributes are printed in the order they appear in the DIE, with these
renderings (a raw byte dump would be unreadable and unassertable):

    DW_AT_low_pc / high_pc / addr   hexadecimal, e.g. 0x1000
    DW_AT_type / sibling            the referenced DIE's type, e.g. i32[2][3]
    DW_AT_location / frame_base     DW_OP_ names, e.g. fbreg+8, breg31+0
    DW_AT_language                  the DW_LANG_ name

Modes:

    (default)   the whole DIE tree, one line per DIE, indented by depth
    --units     one line per compilation unit: <name> <low_pc> <high_pc>
    --functions one line per DW_TAG_subprogram: <name> <low_pc> <size> <decl_line>
    --vars      one line per variable, parameter or global:
                <scope> <name> <kind> <type> <location> <line>

Usage:
    debuginfo-decode.py [--units|--functions|--vars] <elf-file>
"""
import sys

# The ELF reader is a deliberate copy of the one in debugline-decode.py: each
# decoder is an independent witness over its own section, and neither should
# break because the other changed.


def die(msg):
    sys.stderr.write("debuginfo-decode: %s\n" % msg)
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
    shift = 0
    val = 0
    while True:
        byte = b[o]
        o += 1
        val |= (byte & 0x7F) << shift
        shift += 7
        if not (byte & 0x80):
            return val, o


def read_sleb(b, o):
    shift = 0
    val = 0
    while True:
        byte = b[o]
        o += 1
        val |= (byte & 0x7F) << shift
        shift += 7
        if not (byte & 0x80):
            if byte & 0x40:
                val -= 1 << shift          # sign extend
            return val, o


def find_section(path, want):
    """Return the bytes of the section named `want`, or None."""
    with open(path, "rb") as f:
        blob = f.read()
    if len(blob) < 64 or blob[:4] != b"\x7fELF":
        die("%s is not an ELF file" % path)
    if blob[4] != 2:
        die("%s is not ELF64" % path)
    shoff = u64(blob, 0x28)
    shentsize = u16(blob, 0x3A)
    shnum = u16(blob, 0x3C)
    shstrndx = u16(blob, 0x3E)
    if shstrndx >= shnum:
        die("%s has no section-name table" % path)
    shstr = blob[u64(blob, shoff + shstrndx * shentsize + 24):][:u64(blob, shoff + shstrndx * shentsize + 32)]

    def name_of(i):
        base = shoff + i * shentsize
        off = u32(blob, base)
        end = shstr.find(b"\0", off)
        return shstr[off:end].decode("utf-8", "replace")

    for i in range(shnum):
        base = shoff + i * shentsize
        if name_of(i) == want:
            off = u64(blob, base + 24)
            size = u64(blob, base + 32)
            return blob[off:off + size]
    return None


# --- DWARF constants -----------------------------------------------------------
TAGS = {
    0x01: "ARRAY_TYPE", 0x05: "FORMAL_PARAMETER", 0x0d: "MEMBER",
    0x0f: "POINTER_TYPE", 0x11: "COMPILE_UNIT", 0x13: "STRUCTURE_TYPE",
    0x21: "SUBRANGE_TYPE", 0x24: "BASE_TYPE", 0x2e: "SUBPROGRAM",
    0x34: "VARIABLE", 0x3b: "UNSPECIFIED_TYPE",
}
ATTRS = {
    0x01: "sibling", 0x02: "location", 0x03: "name", 0x0b: "byte_size",
    0x10: "stmt_list", 0x11: "low_pc", 0x12: "high_pc", 0x13: "language",
    0x1b: "comp_dir", 0x25: "producer", 0x2f: "upper_bound", 0x38: "data_member_location",
    0x3b: "decl_line", 0x3e: "encoding", 0x3f: "external", 0x40: "frame_base",
    0x49: "type",
}
# Forms that carry a fixed number of bytes; anything else is handled below.
FIXED = {0x01: 8, 0x05: 2, 0x06: 4, 0x07: 8, 0x0b: 1, 0x0d: 2, 0x0e: 4, 0x0f: 8}
LANGUAGES = {0x01: "DW_LANG_C89", 0x02: "DW_LANG_C", 0x0c: "DW_LANG_C99"}


def parse_abbrev(blob):
    """Map abbreviation code -> (tag, has_children, [(attr, form), ...])."""
    table = {}
    pos = 0
    while pos < len(blob):
        code, pos = read_uleb(blob, pos)
        if code == 0:
            break
        tag, pos = read_uleb(blob, pos)
        kids = blob[pos]
        pos += 1
        attrs = []
        while True:
            at, pos = read_uleb(blob, pos)
            form, pos = read_uleb(blob, pos)
            if at == 0 and form == 0:
                break
            attrs.append((at, form))
        table[code] = (tag, kids, attrs)
    return table


def read_expr(blob, o):
    """Read a DWARF expression block and return (ops, end-offset)."""
    length, o = read_uleb(blob, o)
    return blob[o:o + length], o + length


def render_expr(ops):
    """Render the few operators Aster emits; anything else is a hex dump."""
    out = []
    i = 0
    while i < len(ops):
        op = ops[i]
        i += 1
        if op == 0x03 and i + 8 <= len(ops):            # DW_OP_addr
            out.append("addr(0x%x)" % u64(ops, i))
            i += 8
        elif op == 0x91:                                # DW_OP_fbreg
            val, i = read_sleb(ops, i)
            out.append("fbreg%+d" % val)
        elif 0x70 <= op <= 0x8f:                        # DW_OP_breg0..31
            val, i = read_sleb(ops, i)
            out.append("breg%d%+d" % (op - 0x70, val))
        elif op == 0x9f:                                # DW_OP_stack_value
            out.append("stack_value")
        else:
            out.append("op%02x" % op)
    return " ".join(out) if out else "<empty>"


class Unit(object):
    def __init__(self, blob, abbrev):
        self.blob = blob
        self.abbrev = abbrev
        self.start = 0            # the unit header's offset in .debug_info
        self.dies = {}          # offset -> die dict
        self.order = []         # offsets in emission order
        self.roots = []
        self.attrs = {}

    def parse(self, start):
        blob = self.blob
        length = u32(blob, start)
        version = u16(blob, start + 4)
        abbrev_off = u32(blob, start + 6)
        addr_size = blob[start + 10]
        if version != 4:
            die("only DWARF version 4 is supported (got %d)" % version)
        if addr_size != 8:
            die("only 8-byte addresses are supported (got %d)" % addr_size)
        self.version = version
        self.addr_size = addr_size
        self.start = start            # a DW_FORM_ref4 counts from here, not from .debug_info
        end = start + 4 + length
        # The abbreviations live in their own section; the unit header says
        # where in it this unit starts, which for aster is always the beginning.
        if abbrev_off >= len(self.abbrev):
            die("debug_abbrev_offset %d is outside .debug_abbrev" % abbrev_off)
        table = parse_abbrev(self.abbrev[abbrev_off:])
        if not table:
            die(".debug_abbrev declares no abbreviations")
        pos = start + 11
        stack = []
        while pos < end:
            off = pos
            code, pos = read_uleb(blob, pos)
            if code == 0:
                if stack:
                    stack.pop()
                    continue
                break                               # end of the root's children
            if code not in table:
                die("abbreviation code %d at offset %d is not in .debug_abbrev" % (code, off))
            tag, kids, attrs_def = table[code]
            die_obj = {"offset": off, "tag": tag, "attrs": [], "children": [], "depth": len(stack)}
            for (at, form) in attrs_def:
                value, pos = self.read_form(blob, pos, form)
                die_obj["attrs"].append((at, value))
            self.dies[off] = die_obj
            self.order.append(off)
            if stack:
                stack[-1]["children"].append(die_obj)
            else:
                self.roots.append(die_obj)
            if kids:
                stack.append(die_obj)
        if pos != end:
            die("unit does not end where its length says it does (%d vs %d)" % (pos, end))
        self.attrs = self.attrs_of(self.roots[0]) if self.roots else {}
        return end

    def read_form(self, blob, o, form):
        if form == 0x08:                            # DW_FORM_string
            end = blob.find(b"\0", o)
            if end < 0:
                die("unterminated DW_FORM_string at offset %d" % o)
            return ("str", blob[o:end].decode("utf-8", "replace")), end + 1
        if form == 0x18:                            # DW_FORM_exprloc
            ops, end = read_expr(blob, o)
            return ("expr", ops), end
        if form == 0x19:                            # DW_FORM_flag_present
            return ("flag", True), o
        if form == 0x13:                            # DW_FORM_ref4
            return ("ref", u32(blob, o)), o + 4
        if form in FIXED:
            n = FIXED[form]
            v = 0
            for i in range(n):
                v |= blob[o + i] << (8 * i)
            return ("num", v), o + n
        die("unsupported DWARF form 0x%02x" % form)

    @staticmethod
    def attrs_of(d):
        return dict((a, v) for (a, v) in d["attrs"])

    def get(self, d, at):
        for (a, v) in d["attrs"]:
            if a == at:
                return v
        return None

    def tag_name(self, d):
        return TAGS.get(d["tag"], "TAG_%02x" % d["tag"])

    # -- type rendering ---------------------------------------------------------
    def type_dims(self, off):
        """Return (base name, [dimensions outermost first]) for a type DIE."""
        # A ref4 is an offset from the start of the unit that holds it, which is
        # only the start of .debug_info for the first unit in the section.
        d = self.dies.get(self.start + off)
        if d is None:
            return ("<bad-ref:%d>" % (self.start + off), [])
        if d["tag"] == 0x01:                        # array_type
            elem = self.get(d, 0x49)
            n = 0
            for c in d["children"]:
                if c["tag"] == 0x21:                # subrange_type
                    ub = self.get(c, 0x2f)
                    if ub is not None:
                        n = ub[1] + 1
            base, dims = self.type_dims(elem[1]) if elem else ("?", [])
            return (base, [n] + dims)
        if d["tag"] == 0x0f:                        # pointer_type
            tgt = self.get(d, 0x49)
            inner = self.type_name(tgt[1]) if tgt else "?"
            return ("ptr<%s>" % inner, [])
        if d["tag"] == 0x3b:
            return ("void", [])
        nm = self.get(d, 0x03)
        return (nm[1] if nm else "?", [])

    def type_name(self, off):
        base, dims = self.type_dims(off)
        return base + "".join("[%d]" % n for n in dims)

    def render(self, at, v):
        kind = v[0]
        raw = v[1]
        if at == 0x49 or at == 0x01:                # type / sibling
            return self.type_name(raw)
        if at == 0x02 or at == 0x40:                # location / frame_base
            return render_expr(raw)
        if at == 0x13:                              # language
            return LANGUAGES.get(raw, "DW_LANG_%d" % raw)
        if kind == "flag":
            return "true"
        if kind == "num":
            if at in (0x11, 0x12):                  # low_pc / high_pc
                return "0x%x" % raw
            return str(raw)
        return str(raw)

    def line_of(self, d):
        parts = ["  " * d["depth"] + self.tag_name(d)]
        for (at, v) in d["attrs"]:
            parts.append("%s=%s" % (ATTRS.get(at, "attr_%02x" % at), self.render(at, v)))
        return " ".join(parts)


def decode(path):
    info = find_section(path, ".debug_info")
    if info is None:
        die("%s has no .debug_info section" % path)
    abbrev = find_section(path, ".debug_abbrev")
    if abbrev is None:
        die("%s has no .debug_abbrev section" % path)
    units = []
    pos = 0
    while pos + 4 <= len(info):
        u = Unit(info, abbrev)
        pos = u.parse(pos)
        units.append(u)
    return units


def main(argv):
    flags = [a for a in argv if a.startswith("--")]
    args = [a for a in argv if not a.startswith("--")]
    if len(flags) > 1 or len(args) != 1:
        die("usage: debuginfo-decode.py [--units|--functions|--vars] <elf-file>")
    mode = flags[0] if flags else "--tree"
    units = decode(args[0])

    def num(d, at, default=0):
        v = None
        for (a, val) in d["attrs"]:
            if a == at:
                v = val
        return v[1] if v else default

    if mode == "--units":
        for u in units:
            cu = u.roots[0] if u.roots else None
            if cu is None:
                continue
            print("%s 0x%x 0x%x" % (num(cu, 0x03, "?"), num(cu, 0x11), num(cu, 0x12)))
        return
    if mode == "--functions":
        for u in units:
            for d in u.order:
                d = u.dies[d]
                if d["tag"] == 0x2e:
                    print("%s 0x%x 0x%x %d" % (
                        num(d, 0x03, "?"), num(d, 0x11), num(d, 0x12), num(d, 0x3b)))
        return
    if mode == "--vars":
        for u in units:
            scope = "-"

            def walk(d):
                nonlocal scope
                if d["tag"] == 0x2e:
                    scope = num(d, 0x03, "?")
                elif d["tag"] == 0x15:
                    # DW_TAG_subroutine_type (v0.23.51-dev): its
                    # formal_parameter children describe a function's
                    # *signature* — a debugger reads them through the type,
                    # not as slots in any frame. They carry no location, so
                    # printing them here would invent phantom parameters.
                    return
                elif d["tag"] in (0x34, 0x05):
                    kind = "param" if d["tag"] == 0x05 else ("global" if d["depth"] == 1 else "local")
                    loc = u.get(d, 0x02)
                    typ = u.get(d, 0x49)
                    print("%s %s %s %s %s %d" % (
                        scope, num(d, 0x03, "?"), kind,
                        u.type_name(typ[1]) if typ else "?",
                        render_expr(loc[1]) if loc else "?",
                        num(d, 0x3b)))
                for c in d["children"]:
                    walk(c)
                if d["tag"] == 0x2e:
                    scope = "-"
            for r in u.roots:
                walk(r)
        return
    if mode == "--tree":
        for u in units:
            for off in u.order:
                print(u.line_of(u.dies[off]))
        return
    die("unknown mode %s" % mode)


if __name__ == "__main__":
    main(sys.argv[1:])
