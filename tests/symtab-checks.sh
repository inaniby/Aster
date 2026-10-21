#!/bin/sh
# v0.17.0 structural checks for the source-level symbol table. Nothing here executes a generated
# image; see e2e-symtab.sh for the executed checks and regression-symtab.sh for the proof that the
# symbol table disturbed no pre-existing byte of any product.
set -eu
[ -x ./aster ] || { echo "build ./aster first" >&2; exit 2; }

./aster build-elf examples/symbols_demo.ast  -o tmp-sym-exec
./aster build-pie examples/symbols_demo.ast  -o tmp-sym-pie
./aster build-so  examples/symbols_demo.ast  -o tmp-sym.so
./aster build-elf examples/symbols_init.ast  -o tmp-sym-init
./aster build-so  examples/runtime_init.ast  -o tmp-sym-rt.so
./aster build-pie examples/align_global.ast  -o tmp-sym-align
./aster build-so  examples/so_math.ast       -o tmp-sym-math.so
./aster build-obj examples/symbols_init.ast  -o tmp-sym-init.o

python3 - <<'PY'
import os, struct

FUNC, OBJECT = 2, 1


def load(path):
    b = open(path, 'rb').read()
    etype, machine = struct.unpack_from('<HH', b, 16)
    entry = struct.unpack_from('<Q', b, 24)[0]
    shoff = struct.unpack_from('<Q', b, 40)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', b, 58)
    raw = [struct.unpack_from('<IIQQQQIIQQ', b, shoff + i * shentsize) for i in range(shnum)] if shnum else []
    names = b[raw[shstrndx][4]:raw[shstrndx][4] + raw[shstrndx][5]] if raw else b''
    sec = {}
    for i, s in enumerate(raw):
        if s[0] < len(names):
            sec.setdefault(names[s[0]:names.index(b'\0', s[0])].decode(), (i, s))
    idx2name = {i: n for n, (i, s) in sec.items()}
    idx2name[0] = 'UND'
    idx2name[0xfff1] = 'ABS'

    def symbols(table):
        if table not in sec:
            return []
        s = sec[table][1]
        data = b[s[4]:s[4] + s[5]]
        st = sec['.strtab' if table == '.symtab' else '.dynstr'][1]
        strings = b[st[4]:st[4] + st[5]]
        out = []
        for off in range(0, len(data), 24):
            n, info, other, shndx, val, size = struct.unpack_from('<IBBHQQ', data, off)
            out.append(dict(name=strings[n:strings.index(b'\0', n)].decode(), bind=info >> 4,
                            type=info & 0xf, other=other, shndx=shndx, value=val, size=size))
        return out

    return dict(path=path, bytes=b, etype=etype, machine=machine, entry=entry, sec=sec,
                idx2name=idx2name, symtab=symbols('.symtab'), dynsym=symbols('.dynsym'))


def S(e, name):
    return e['sec'][name][1]


def byname(e, table='symtab'):
    return {s['name']: s for s in e[table] if s['name']}


def sec_of(e, s):
    return e['idx2name'].get(s['shndx'], '?')


EXEC = load('tmp-sym-exec')
PIE = load('tmp-sym-pie')
SO = load('tmp-sym.so')
INIT = load('tmp-sym-init')
RTSO = load('tmp-sym-rt.so')
ALIGN = load('tmp-sym-align')
MATH = load('tmp-sym-math.so')

# --- 1. .symtab/.strtab are well formed wherever they appear --------------------------------------
for e in (EXEC, PIE, SO, INIT, ALIGN):
    assert '.symtab' in e['sec'] and '.strtab' in e['sec'], e['path']
    si, ss = e['sec']['.symtab']
    ti, ts = e['sec']['.strtab']
    assert (ss[1], ss[6], ss[7], ss[8], ss[9]) == (2, ti, 1, 8, 24), (e['path'], 'symtab shdr', ss)
    assert (ts[1], ts[2], ts[8]) == (3, 0, 1), (e['path'], 'strtab shdr', ts)
    assert e['bytes'][ts[4]] == 0, (e['path'], 'a string table must start with a NUL byte')
    assert S(e, '.shstrtab')[1] == 3, e['path']
    for s in e['symtab']:
        assert s['bind'] == 1 or s['name'] == '', (e['path'], 'non-GLOBAL binding', s)
        assert s['other'] == 0, (e['path'], 'st_other must be 0', s)
        assert (s['type'] in (FUNC, OBJECT)) or s['name'] == '', (e['path'], 'unexpected type', s)
        assert s['shndx'] != 0 or s['name'] == '', (e['path'], 'defined symbol with shndx 0', s)
    assert len({s['name'] for s in e['symtab'] if s['name']}) == len([s for s in e['symtab'] if s['name']]), e['path']
print('PASS: .symtab/.strtab well formed in ET_EXEC, static PIE and shared object (GLOBAL, st_other 0, '
      'FUNC/OBJECT only, unique names, NUL-led string table)')

# --- 2. ET_EXEC: every source-level function and global/array, with source names -------------------
t, d, bs = S(EXEC, '.text'), S(EXEC, '.data'), S(EXEC, '.bss')
tab = byname(EXEC)
assert set(tab) == {'_start', 'main', 'bump', 'counter', 'zeroed', 'table', 'spare'}, sorted(tab)
assert (tab['_start']['type'], tab['_start']['value']) == (FUNC, EXEC['entry']), tab['_start']
assert (tab['main']['type'], tab['main']['value']) == (FUNC, EXEC['entry']), tab['main']
assert (tab['bump']['type'], sec_of(EXEC, tab['bump'])) == (FUNC, '.text'), tab['bump']
assert t[3] <= tab['bump']['value'] < t[3] + t[5] and tab['bump']['size'] > 0, tab['bump']
assert (tab['counter']['type'], sec_of(EXEC, tab['counter']), tab['counter']['value'], tab['counter']['size']) \
    == (OBJECT, '.data', d[3], 4), tab['counter']
assert (tab['table']['type'], sec_of(EXEC, tab['table']), tab['table']['value'], tab['table']['size']) \
    == (OBJECT, '.data', d[3] + 4, 16), tab['table']
assert (tab['zeroed']['type'], sec_of(EXEC, tab['zeroed']), tab['zeroed']['value'], tab['zeroed']['size']) \
    == (OBJECT, '.bss', bs[3], 4), tab['zeroed']
assert (tab['spare']['type'], sec_of(EXEC, tab['spare']), tab['spare']['value'], tab['spare']['size']) \
    == (OBJECT, '.bss', bs[3] + 4, 8), tab['spare']
assert (t[3], t[5]) == (0x401000, 0xd8), (t[3], t[5])
assert EXEC['entry'] == 0x401000, hex(EXEC['entry'])
print('PASS: ET_EXEC st_value is the final link address: main/_start at 0x401000, bump in .text, '
      'counter/table in .data, zeroed/spare in .bss, sizes 4/16/4/8')

# --- 3. the .bss symbols really live in a NOBITS section -------------------------------------------
assert (bs[1], bs[2]) == (8, 0x3), bs
assert (d[1], d[2]) == (1, 0x3), d
assert tab['zeroed']['value'] == bs[3] and tab['spare']['value'] == bs[3] + 4, (bs[3], tab)
assert bs[5] == 12 and d[5] == 20, (bs[5], d[5])
print('PASS: .bss is SHT_NOBITS (WA, 12 bytes) and its STT_OBJECT symbols carry the .bss address; '
      '.data is PROGBITS (WA, 20 bytes)')

# --- 4. static PIE: st_value uses the same image-relative base as e_entry --------------------------
t, d, bs = S(PIE, '.text'), S(PIE, '.data'), S(PIE, '.bss')
tab = byname(PIE)
assert PIE['entry'] == 0x1000, hex(PIE['entry'])
assert t[3] == 0x1000 and d[3] == 0x2000, (hex(t[3]), hex(d[3]))
assert (tab['main']['value'], tab['counter']['value'], tab['table']['value']) == (PIE['entry'], d[3], d[3] + 4), tab
assert (tab['zeroed']['value'], tab['spare']['value']) == (bs[3], bs[3] + 4), tab
assert max(s['value'] for s in PIE['symtab']) < 0x10000, 'PIE symbol values must stay image-relative'
print('PASS: static PIE st_value is a plain image offset like e_entry (main=0x1000, globals at their '
      '0x2000-based offsets), never a link-time address')

# --- 5. shared object: .symtab agrees with .dynsym on every exported function ----------------------
dyn = byname(SO, 'dynsym')
tab = byname(SO, 'symtab')
assert set(dyn) == {'main', 'bump'}, sorted(dyn)
assert all(s['type'] == FUNC and s['bind'] == 1 for s in dyn.values()), dyn
for n in dyn:
    assert n in tab and tab[n]['type'] == FUNC and tab[n]['value'] == dyn[n]['value'] \
        and tab[n]['size'] == dyn[n]['size'] and sec_of(SO, tab[n]) == '.text', (n, tab.get(n), dyn[n])
print('PASS: tmp-sym.so: .symtab carries the same value/size/section for every function .dynsym exports')

# --- 6. shared object globals ---------------------------------------------------------------------
d, bs = S(SO, '.data'), S(SO, '.bss')
got = [(n, s) for n, s in tab.items() if s['type'] == OBJECT]
assert {n for n, s in got} == {'counter', 'zeroed', 'table', 'spare'}, sorted(tab)
assert (tab['counter']['value'], tab['counter']['size'], sec_of(SO, tab['counter'])) == (d[3], 4, '.data')
assert (tab['table']['value'], tab['table']['size'], sec_of(SO, tab['table'])) == (d[3] + 4, 16, '.data')
assert (tab['zeroed']['value'], tab['zeroed']['size'], sec_of(SO, tab['zeroed'])) == (bs[3], 4, '.bss')
assert (tab['spare']['value'], tab['spare']['size'], sec_of(SO, tab['spare'])) == (bs[3] + 4, 8, '.bss')
print('PASS: tmp-sym.so: globals are STT_OBJECT with exact sizes (4/16/4/8) in .data and .bss')

# --- 7. run-time initializer: source names kept, synthetic routine not published -------------------
tab = byname(INIT)
assert set(tab) == {'_start', 'main', 'seed', 'started', 'arr'}, sorted(tab)
assert not any(n.startswith('__aster_') for n in tab), sorted(tab)
assert (tab['arr']['size'], sec_of(INIT, tab['arr'])) == (12, '.data')
assert (tab['started']['size'], sec_of(INIT, tab['started'])) == (4, '.bss')
print('PASS: tmp-sym-init: a run-time initializer keeps seed/started/arr/main and publishes no '
      '__aster_init* name')

# --- 8. ...and the object file still shows the routine, so the omission is deliberate --------------
o = load('tmp-sym-init.o')
assert '__aster_init' in byname(o), sorted(byname(o))
assert '__aster_init' not in byname(RTSO, 'symtab'), sorted(byname(RTSO, 'symtab'))
assert '__aster_init' in byname(RTSO, 'dynsym'), sorted(byname(RTSO, 'dynsym'))
print('PASS: __aster_init stays in the ET_REL symbol table and in .dynsym (DT_INIT_ARRAY) but is kept '
      'out of the source-level .symtab')

# --- 9. @align(N) reaches the section headers of a final product -----------------------------------
d, bs = S(ALIGN, '.data'), S(ALIGN, '.bss')
tab = byname(ALIGN)
assert d[8] == 32 and bs[8] == 64, (d, bs)
assert (tab['data_array']['value'], tab['data_array']['size'], sec_of(ALIGN, tab['data_array'])) == (d[3], 12, '.data')
assert (tab['aligned_scalar']['value'], tab['aligned_scalar']['size']) == (d[3] + 32, 4), tab['aligned_scalar']
assert (tab['aligned_array']['value'], tab['aligned_array']['size'], sec_of(ALIGN, tab['aligned_array'])) == (bs[3], 32, '.bss')
print('PASS: tmp-sym-align: @align(32)/@align(64) show up as .data/.bss sh_addralign and as aligned '
      'st_value fields in a final product')

# --- 10. so_math: exports and globals all named -----------------------------------------------------
tab = byname(MATH)
assert {'add', 'mul', 'accumulate', 'current', 'untouched_value'} <= set(tab), sorted(tab)
assert (tab['accumulator']['size'], sec_of(MATH, tab['accumulator'])) == (4, '.data')
assert (tab['untouched']['size'], sec_of(MATH, tab['untouched'])) == (4, '.bss')
print('PASS: tmp-sym-math.so: so_math exports and both globals are named in .symtab')

# --- 11. no debug information ----------------------------------------------------------------------
for e in (EXEC, PIE, SO, INIT, RTSO, ALIGN, MATH):
    assert not any(n.startswith('.debug') for n in e['sec']), (e['path'], sorted(e['sec']))
    assert not any(n == '.line' or n == '.stab' for n in e['sec']), e['path']
print('PASS: no .debug_* / DWARF section in any of the 7 final products')
PY
rm -f tmp-sym-exec tmp-sym-pie tmp-sym.so tmp-sym-init tmp-sym-init.o tmp-sym-rt.so tmp-sym-align tmp-sym-math.so
echo "PASS: all v0.17.0 source-level symbol table checks"
