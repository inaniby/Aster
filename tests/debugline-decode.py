#!/usr/bin/env python3
"""Stand-alone DWARF v4 .debug_line decoder for Aster's test suite (P4.2).

Why this exists: the suite must prove what aster wrote, not what a tool chooses
to show. This reads the ELF64 section table by hand (no pyelftools, no objdump)
and runs the line-number state machine itself, then prints one row per line:

    <addr-hex> <line> <file>

`--units` prints one line per unit instead:

    <file> <first-addr-hex> <last-addr-hex>

Rows with end_sequence set are dropped from the row listing (they mark the end
of a sequence, not a source statement) but still bound a unit's address range.

Usage:
    debugline-decode.py [--units] <elf-file>
"""
import sys


def die(msg):
    sys.stderr.write("debugline-decode: %s\n" % msg)
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
    """Return (offset, size) of the section named `want`, or None."""
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


def decode_units(blob):
    """Yield one dict per DWARF unit in a .debug_line section."""
    pos = 0
    while pos + 4 <= len(blob):
        unit_start = pos
        length = u32(blob, pos)
        pos += 4
        if length == 0xFFFFFFFF:
            die("DWARF64 line programs are not supported")
        unit_end = pos + length
        if length == 0 or unit_end > len(blob):
            die("unit length %d runs past the end of .debug_line" % length)
        version = u16(blob, pos)
        pos += 2
        if version != 4:
            die("only DWARF version 4 line programs are supported (got %d)" % version)
        header_length = u32(blob, pos)
        pos += 4
        program_start = pos + header_length
        min_inst = blob[pos]
        pos += 1
        if version >= 4:
            pos += 1                        # maximum_operations_per_instruction
        default_is_stmt = blob[pos]
        pos += 1
        line_base = blob[pos] - 256 if blob[pos] > 127 else blob[pos]
        pos += 1
        line_range = blob[pos]
        pos += 1
        opcode_base = blob[pos]
        pos += 1
        pos += opcode_base - 1              # standard_opcode_lengths
        dirs = []
        while blob[pos] != 0:
            end = blob.find(b"\0", pos)
            dirs.append(blob[pos:end].decode("utf-8", "replace"))
            pos = end + 1
        pos += 1
        files = []
        while blob[pos] != 0:
            end = blob.find(b"\0", pos)
            name = blob[pos:end].decode("utf-8", "replace")
            pos = end + 1
            dir_index, pos = read_uleb(blob, pos)
            _mtime, pos = read_uleb(blob, pos)
            _length, pos = read_uleb(blob, pos)
            files.append((name, dir_index))
        pos += 1
        if pos != program_start:
            die("line header is %d bytes but the prologue says %d" % (pos - unit_start - 10, header_length))

        # ---- run the state machine -------------------------------------------------
        rows = []
        address = 0
        line = 1
        file_index = 1
        is_stmt = default_is_stmt
        p = program_start
        while p < unit_end:
            op = blob[p]
            p += 1
            if op >= opcode_base:
                adjusted = op - opcode_base
                op_advance = adjusted // line_range
                address += min_inst * op_advance
                line += line_base + (adjusted % line_range)
                rows.append((address, line, file_index, is_stmt, False))
            elif op == 0:                    # extended
                size, p = read_uleb(blob, p)
                sub_end = p + size
                sub = blob[p]
                p += 1
                if sub == 0x01:              # DW_LNE_end_sequence
                    rows.append((address, line, file_index, is_stmt, True))
                    address = 0
                    line = 1
                    file_index = 1
                elif sub == 0x02:             # DW_LNE_set_address
                    address = 0
                    for i in range(sub_end - p):
                        address |= blob[p + i] << (8 * i)
                p = sub_end
            elif op == 0x01:                 # DW_LNS_copy
                rows.append((address, line, file_index, is_stmt, False))
            elif op == 0x02:                 # DW_LNS_advance_pc
                operand, p = read_uleb(blob, p)
                address += min_inst * operand
            elif op == 0x03:                 # DW_LNS_advance_line
                operand, p = read_sleb(blob, p)
                line += operand
            elif op == 0x04:                 # DW_LNS_set_file
                file_index, p = read_uleb(blob, p)
            elif op == 0x05:                 # DW_LNS_set_column
                _operand, p = read_uleb(blob, p)
            elif op == 0x06:                 # DW_LNS_negate_stmt
                is_stmt = not is_stmt
            elif op == 0x07:                 # DW_LNS_set_basic_block
                pass
            elif op == 0x08:                 # DW_LNS_const_add_pc
                address += min_inst * ((255 - opcode_base) // line_range)
            elif op == 0x09:                 # DW_LNS_fixed_advance_pc
                address += u16(blob, p)
                p += 2
            elif op == 0x0A:                 # DW_LNS_set_prologue_end
                pass
            elif op == 0x0B:                 # DW_LNS_set_epilogue_begin
                pass
            elif op == 0x0C:                 # DW_LNS_set_isa
                _operand, p = read_uleb(blob, p)
            else:
                die("unknown line-number opcode 0x%02x at offset %d" % (op, p - 1))
        if p != unit_end:
            die("line program does not end where the unit says it does")

        def path_of(idx):
            # File indices are 1-based; a file's directory comes from the
            # include_directories list, whose indices are also 1-based here.
            if 1 <= idx <= len(files):
                name, dir_index = files[idx - 1]
                if 1 <= dir_index <= len(dirs) and dirs[dir_index - 1] not in ("", "."):
                    return "%s/%s" % (dirs[dir_index - 1], name)
                return name
            return "<unknown>"

        yield {
            "start": unit_start,
            "dirs": dirs,
            "files": files,
            "rows": [(a, ln, path_of(fi), es) for (a, ln, fi, _st, es) in rows],
        }
        pos = unit_end


def main(argv):
    want_units = "--units" in argv
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1:
        die("usage: debugline-decode.py [--units] <elf-file>")
    blob = find_section(args[0], ".debug_line")
    if blob is None:
        die("%s has no .debug_line section" % args[0])
    for unit in decode_units(blob):
        live = [r for r in unit["rows"] if not r[3]]
        if want_units:
            first = live[0][0] if live else 0
            last = live[-1][0] if live else 0
            print("%s 0x%x 0x%x" % (unit["files"][0][0] if unit["files"] else "?", first, last))
        else:
            for (addr, line, path, _es) in live:
                print("0x%x %d %s" % (addr, line, path))


if __name__ == "__main__":
    main(sys.argv[1:])
