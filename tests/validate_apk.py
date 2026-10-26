#!/usr/bin/env python3
"""Self-contained validator for Aster's self-built NativeActivity APKs.

Checks performed (hermetic: the Python stdlib only. `openssl`, when it happens to
be on PATH, is used as an independent second opinion and never as the only
verifier -- a machine without it still gets every check, and says so):
  [1] ZIP container integrity (every entry's stored CRC-32 matches its bytes)
  [2] APK layout: AndroidManifest.xml, lib/<abi>/lib<name>.so, META-INF/{MANIFEST.MF,CERT.SF,CERT.RSA}
  [3] the .so is 4 KiB-aligned inside the ZIP (required by the Android loader for mmap)
  [4] binary AXML parse of AndroidManifest.xml (custom parser, no aapt/androguard):
      package, versionCode, versionName, minSdk, targetSdk, activities,
      launcher category, android.app.lib_name meta-data, android:icon reference
  [4b] binary resources.arsc parse (custom parser, no aapt):
      package id/name, type + key string pools, drawable entry, and the
      Res_value must be TYPE_STRING pointing at res/drawable-nodpi/<name>.png
  [4d] android:label, in either of its two legal spellings: a TYPE_REFERENCE
      that resolves through the same table to string/app_name (what aapt
      writes, and what `--label-as-reference` asks for), or a TYPE_STRING
      spelled out in the manifest (Aster's default, readable by a viewer that
      never opens the table). Either way string/app_name must be present in the
      table and must agree with the manifest. `--label-literal` /
      `--label-reference` pin the check to one spelling.
  [4c] the launcher icon PNG: signature, per-chunk CRC-32, IHDR, PLTE/tRNS,
      IDAT inflates to exactly h*(row+1) bytes, and the decoded pixels show a
      transparent rounded corner plus the glyph colour
  [5] APK v1 (JAR) signing:
      [5a] MANIFEST.MF per-entry SHA-256-Digest == SHA-256(file bytes)
      [5b] CERT.SF SHA-256-Digest-Manifest + per-entry digests
      [5c] CERT.RSA PKCS#7 signature over CERT.SF, verified in-process
           (RSASSA-PKCS1-v1_5, SHA-256, the public key lifted out of the
           embedded certificate) and then by openssl if openssl is present
      [5d] embedded certificate subject == the Aster dev signing cert (read out
           of the DER, not asked from openssl)
      [5e] the embedded RSA signature is exactly modulus-wide (v0.22.48-dev regression)
  [6] APK v2 (APK Signing Block) signing, v1 retained for dual-signing:
      [6a] "APK Sig Block 42" sits directly before the Central Directory, and both
           uint64 size fields agree and match the real span
      [6b] the 0x7109871a (v2) ID-value pair parses into exactly one signer
      [6c] the signer's public key == the SubjectPublicKeyInfo lifted out of the
           embedded certificate (a mismatch is what apksig reports as
           V2_SIG_PUBLIC_KEY_MISMATCH_BETWEEN_CERTIFICATE_AND_SIGNATURES_RECORD)
      [6d] the RSASSA-PKCS1-v1_5 (0x0103) signature over signed-data verifies
      [6e] the CHUNKED_SHA256 content digest is recomputed over the ZIP entry
           region, the Central Directory and the EOCD -- with the EOCD's
           "offset of start of central directory" rewritten to the Signing Block
           start, which is the one subtle field of the v2 spec -- and matches
      [6f] no v3 / v3.1 block is present (deliberate: v3 only adds key rotation)
      [6g] CERT.SF declares "X-Android-APK-Signed: 2" so the v2 block cannot be
           stripped and downgraded to v1
      [6h] the certificate inside the v2 block is byte-identical to the one in
           CERT.RSA, i.e. v1 and v2 were made with the same key

Usage:
  validate_apk.py <app.apk> [--package PKG] [--libname NAME] [--abi ABI]
"""
import sys, os, re, zipfile, struct, hashlib, subprocess, tempfile, zlib

def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True)

def fail(msg):
    print("    FAIL: " + msg)
    return False

def ok(msg):
    print("    OK:   " + msg)
    return True

def skip(msg):
    """An external witness is missing. That is not a broken APK, and it must
    not be reported as one -- it is reported, and it does not fail the run."""
    print("    SKIP: " + msg)
    return True

# ---------------------------------------------------------------- binary AXML parser
def _varint(b, p):
    v = b[p]; p += 1
    if v & 0x80:
        v = ((v & 0x7f) << 8) | b[p]; p += 1
    return v, p

def _decode_utf8_str(b, base, off):
    p = base + off
    n_units, p = _varint(b, p)
    n_bytes, p = _varint(b, p)
    s = b[p:p + n_bytes].decode('utf-8', 'replace')
    return s

def _u16(b, p): return struct.unpack_from('<H', b, p)[0]
def _u32(b, p): return struct.unpack_from('<I', b, p)[0]

def parse_axml(b):
    """Return dict of manifest facts, or raise on malformed input."""
    # ResXMLTree_header is the first chunk (offset 0 of the manifest file content)
    assert _u16(b, 0) == 0x0003, "not a ResXMLTree (type=0x0003)"
    strings = []          # combined attribute-name + value/element-name pool
    resmap = []           # resource IDs, one per attribute-name pool entry
    pos = 8               # skip the 8-byte ResXMLTree_header; real chunks follow
    end = len(b)
    # walk chunks
    elem_stack = []       # each: dict(name, attrs=[])
    facts = {"activities": [], "launcher": False, "lib_name": None,
             "package": None, "versionCode": None, "versionName": None,
             "minSdk": None, "targetSdk": None, "bad_str_attrs": [],
             "icon": None, "icon_type": None,
             "label": None, "label_type": None}
    while pos + 8 <= end:
        ctype = _u16(b, pos)
        hsize = _u16(b, pos + 2)
        csize = _u32(b, pos + 4)
        if csize <= 0:
            break
        if ctype == 0x0001:  # ResStringPool_header
            cnt = _u32(b, pos + 8)
            flags = _u32(b, pos + 16)
            sstart = _u32(b, pos + 20)
            base = pos + sstart
            for i in range(cnt):
                off = _u32(b, pos + 28 + 4 * i)
                strings.append(_decode_utf8_str(b, base, off) if (flags & 0x100) else "")
        elif ctype == 0x0180:  # ResXMLResourceMap
            n = (csize - 8) // 4
            for i in range(n):
                resmap.append(_u32(b, pos + 8 + 4 * i))
        elif ctype in (0x0100, 0x0101):  # START/END_NAMESPACE (24 bytes)
            pass
        elif ctype == 0x0102:  # START_ELEMENT
            line = _u32(b, pos + 8); comment = _u32(b, pos + 12)
            ns = _u32(b, pos + 16); name = _u32(b, pos + 20)
            astart = _u16(b, pos + 24); asize = _u16(b, pos + 26)
            acount = _u16(b, pos + 28)
            ename = strings[name] if name < len(strings) else "?"
            attrs = []
            ap = pos + _u16(b, pos + 2) + astart
            for k in range(acount):
                an = _u32(b, ap); aname = _u32(b, ap + 4); araw = _u32(b, ap + 8)
                asz = _u16(b, ap + 12); res0 = b[ap + 14]; atype = b[ap + 15]; adata = _u32(b, ap + 16)
                nm = strings[aname] if aname < len(strings) else "?"
                resid = resmap[aname] if aname < len(resmap) else 0
                if atype == 0x03:      # string — Android loader reads typedValue.data here
                    if adata == 0:
                        # data==0 means the loader reads string-pool index 0 (wrong value)
                        facts["bad_str_attrs"].append(nm)
                    val = strings[adata] if (adata and adata < len(strings)) else (
                          strings[araw] if araw < len(strings) else "")
                elif atype == 0x01:    # TYPE_REFERENCE — a resource id, resolved through
                    val = "0x%08x" % adata     # resources.arsc and not by numeric value
                elif atype == 0x10:    # int (signed)
                    val = adata - (1 << 32) if adata & 0x80000000 else adata
                elif atype == 0x11:    # hex/reference
                    val = "0x%08x" % adata
                elif atype == 0x12:    # boolean
                    val = (adata != 0)
                else:
                    val = adata
                attrs.append((nm, resid, val, atype))
                ap += asize
            elem_stack.append({"name": ename, "attrs": attrs})
        elif ctype == 0x0103:  # END_ELEMENT
            if elem_stack:
                el = elem_stack.pop()
                ad = {nm: v for (nm, resid, v, t) in el["attrs"]}
                adt = {nm: t for (nm, resid, v, t) in el["attrs"]}
                if el["name"] == "manifest":
                    facts["package"] = ad.get("package")
                    facts["versionCode"] = ad.get("versionCode")
                    facts["versionName"] = ad.get("versionName")
                elif el["name"] == "uses-sdk":
                    facts["minSdk"] = ad.get("minSdkVersion")
                    facts["targetSdk"] = ad.get("targetSdkVersion")
                elif el["name"] == "activity":
                    nm = ad.get("name")
                    if nm: facts["activities"].append(nm)
                elif el["name"] == "application":
                    # android:icon must be TYPE_REFERENCE (0x01). If it were written as
                    # TYPE_INT_HEX (0x11) the id would look identical in a hex dump but
                    # the framework would never resolve it to a drawable.
                    facts["icon"] = ad.get("icon")
                    facts["icon_type"] = adt.get("icon")
                    # v0.23.7-dev: the label is a resource reference too, for the
                    # same reason the icon is — and for one more: the string it
                    # resolves to lives in the table, so it is written once.
                    facts["label"] = ad.get("label")
                    facts["label_type"] = adt.get("label")
                elif el["name"] == "meta-data" and ad.get("name") == "android.app.lib_name":
                    facts["lib_name"] = ad.get("value")
                elif el["name"] == "category" and ad.get("name") == "android.intent.category.LAUNCHER":
                    facts["launcher"] = True
        # advance to next chunk
        nxt = pos + csize
        if nxt <= pos:
            break
        pos = nxt
    return facts

# ---------------------------------------------------------------- binary resources.arsc parser
def _read_strpool(b, pos):
    """Decode a ResStringPool chunk at `pos`. Returns (strings, chunk_size)."""
    ctype = _u16(b, pos)
    if ctype != 0x0001:
        raise ValueError("expected ResStringPool (0x0001) at %d, got 0x%04x" % (pos, ctype))
    hsize = _u16(b, pos + 2)
    csize = _u32(b, pos + 4)
    cnt = _u32(b, pos + 8)
    flags = _u32(b, pos + 16)
    sstart = _u32(b, pos + 20)
    base = pos + sstart
    out = []
    for i in range(cnt):
        off = _u32(b, pos + hsize + 4 * i)
        out.append(_decode_utf8_str(b, base, off) if (flags & 0x100) else "<utf16>")
    return out, csize

def parse_arsc(b):
    """Parse resources.arsc into a plain dict.

    Returns {"global": [...], "packages": [{"id", "name", "types", "keys", "entries"}]}
    where each entry is (resid, type_name, key_name, dataType, data).
    """
    if _u16(b, 0) != 0x0002:
        raise ValueError("not a ResTable (type=0x0002)")
    hsize = _u16(b, 2)
    total = _u32(b, 4)
    npkg = _u32(b, 8)
    pos = hsize
    gstrs, cs = _read_strpool(b, pos)
    pos += cs
    pkgs = []
    while pos + 8 <= len(b):
        ctype = _u16(b, pos)
        phsize = _u16(b, pos + 2)
        csize = _u32(b, pos + 4)
        if csize <= 0:
            break
        if ctype != 0x0200:
            pos += csize
            continue
        pid = _u32(b, pos + 8)
        raw_name = b[pos + 12: pos + 12 + 256]
        name = raw_name.decode('utf-16-le').split('\0')[0]
        tsoff = _u32(b, pos + 268)      # typeStrings
        ksoff = _u32(b, pos + 276)      # keyStrings
        types, _ = _read_strpool(b, pos + tsoff)
        keys, _ = _read_strpool(b, pos + ksoff)
        entries = []
        p = pos + phsize
        pend = pos + csize
        while p + 8 <= pend:
            ct = _u16(b, p)
            chs = _u16(b, p + 2)
            csz = _u32(b, p + 4)
            if csz <= 0:
                break
            if ct == 0x0201:            # ResTable_type
                tid = b[p + 8]
                ecount = _u32(b, p + 12)
                estart = _u32(b, p + 16)
                for i in range(ecount):
                    eo = _u32(b, p + chs + 4 * i)
                    if eo == 0xFFFFFFFF:
                        continue
                    ep = p + estart + eo
                    esize = _u16(b, ep)
                    eflags = _u16(b, ep + 2)
                    keyidx = _u32(b, ep + 4)
                    if eflags & 0x0001:
                        continue      # ResTable_map_entry — not expected here
                    vp = ep + esize   # simple entry: Res_value follows the entry header
                    # Res_value: size(2) res0(1) dataType(1) data(4) -- data is at +4
                    dtype = b[vp + 3]
                    ddata = _u32(b, vp + 4)
                    resid = (pid << 24) | (tid << 16) | i
                    entries.append((resid,
                                    types[tid - 1] if 0 < tid <= len(types) else "?",
                                    keys[keyidx] if keyidx < len(keys) else "?",
                                    dtype, ddata))
            p += csz
        pkgs.append({"id": pid, "name": name, "types": types, "keys": keys,
                     "entries": entries})
        pos += csize
    return {"count": npkg, "size": total, "global": gstrs, "packages": pkgs}

# ---------------------------------------------------------------- minimal PNG decoder
def decode_png(b):
    """Decode an 8-bit-or-less palette PNG with zlib (stdlib). Returns a dict.

    This is an independent witness: Aster writes the PNG itself, so the check
    must not reuse any Aster code. Python's zlib decompresses the IDAT stream
    and the scanlines are un-filtered by hand.
    """
    if b[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("bad PNG signature")
    p = 8
    w = h = depth = ctype = None
    plte = None
    trns = None
    idat = b""
    crc_bad = []
    seen = []
    while p + 8 <= len(b):
        ln = struct.unpack_from('>I', b, p)[0]
        typ = b[p + 4:p + 8]
        data = b[p + 8:p + 8 + ln]
        got = struct.unpack_from('>I', b, p + 8 + ln)[0]
        want = zlib.crc32(typ + data) & 0xFFFFFFFF
        if got != want:
            crc_bad.append(typ.decode('latin1'))
        seen.append(typ.decode('latin1'))
        if typ == b"IHDR":
            w, h, depth, ctype, comp, filt, inter = struct.unpack_from('>IIBBBBB', data)
            if inter != 0:
                raise ValueError("interlaced PNG not supported by this checker")
        elif typ == b"PLTE":
            plte = data
        elif typ == b"tRNS":
            trns = data
        elif typ == b"IDAT":
            idat += data
        elif typ == b"IEND":
            break
        p += 12 + ln
    if ctype != 3:
        raise ValueError("expected colour type 3 (palette), got %r" % ctype)
    raw = zlib.decompress(idat)                       # verifies the adler32 too
    bpp_bits = depth
    row_bytes = (w * bpp_bits + 7) // 8
    if len(raw) != h * (row_bytes + 1):
        raise ValueError("IDAT decompressed to %d bytes, expected %d"
                         % (len(raw), h * (row_bytes + 1)))
    # un-filter: Aster emits filter type 0 (None) on every scanline
    pixels = []
    prev = bytearray(row_bytes)
    for y in range(h):
        off = y * (row_bytes + 1)
        ft = raw[off]
        if ft != 0:
            raise ValueError("scanline %d uses filter type %d (unsupported here)" % (y, ft))
        cur = bytearray(raw[off + 1: off + 1 + row_bytes])
        pixels.append(cur)
        prev = cur
    def idx_at(x, y):
        row = pixels[y]
        if depth == 8:
            return row[x]
        if depth == 2:
            return (row[x >> 2] >> (6 - 2 * (x & 3))) & 0x03
        if depth == 4:
            return (row[x >> 1] >> (4 - 4 * (x & 1))) & 0x0F
        if depth == 1:
            return (row[x >> 3] >> (7 - (x & 7))) & 0x01
        raise ValueError("bit depth %d unsupported" % depth)
    def rgba(i):
        if plte is None or 3 * i + 2 >= len(plte):
            return None
        a = trns[i] if (trns is not None and i < len(trns)) else 0xFF
        return (plte[3 * i], plte[3 * i + 1], plte[3 * i + 2], a)
    return {"w": w, "h": h, "depth": depth, "ctype": ctype, "chunks": seen,
            "crc_bad": crc_bad, "palette": plte, "trns": trns,
            "idx_at": idx_at, "rgba": rgba, "idat_len": len(idat),
            "raw_len": len(raw)}

# ---------------------------------------------------------------- main validation
def validate(path, want_pkg=None, want_lib=None, want_abi="arm64-v8a", want_label=None,
             want_label_literal=False, want_label_reference=False, want_page_size=4096):
    allok = True
    print("[1] ZIP integrity / CRC-32")
    with zipfile.ZipFile(path) as z:
        bad = z.testzip()
        if bad is not None:
            allok = fail("CRC mismatch in entry %r" % bad); 
        else:
            ok("all entries CRC-32 OK")
        names = z.namelist()
        # unpack contents for later checks
        data = {n: z.read(n) for n in names}
    print("[2] APK layout")
    so_name = "lib/%s/lib%s.so" % (want_abi, want_lib) if want_lib else None
    if "AndroidManifest.xml" not in names: allok = fail("missing AndroidManifest.xml"); 
    else: ok("AndroidManifest.xml present")
    sos = [n for n in names if n.startswith("lib/") and n.endswith(".so")]
    if not sos: allok = fail("no lib/*.so found"); 
    else: ok("shared object(s): %s" % sos)
    for m in ("META-INF/MANIFEST.MF", "META-INF/CERT.SF", "META-INF/CERT.RSA"):
        if m not in names: allok = fail("missing %s" % m)
        else: ok("%s present" % m)

    print("[3] .so %d-byte alignment" % want_page_size)
    # need raw zip to read local-header offsets
    raw = open(path, "rb").read()
    so_align_ok = True
    for n in sos:
        # find the local file header signature 0x04034b50 then parse
        idx = raw.find(b"PK\x03\x04")
        off = None
        while idx != -1:
            name_len = struct.unpack_from('<H', raw, idx + 26)[0]
            extra_len = struct.unpack_from('<H', raw, idx + 28)[0]
            fname = raw[idx + 30: idx + 30 + name_len].decode('utf-8', 'replace')
            if fname == n:
                off = idx + 30 + name_len + extra_len
                break
            idx = raw.find(b"PK\x03\x04", idx + 4)
        if off is None:
            allok = fail("cannot locate local header for %s" % n); so_align_ok = False; break
        # Android's loader mmaps the .so straight out of the APK, so the entry's
        # data offset must be congruent to the device page size. 4096 is the
        # historical floor; 16384 is required on 16 KB-page devices.
        if off % want_page_size != 0:
            allok = fail("%s data starts at %d (not %d-aligned)" % (n, off, want_page_size)); so_align_ok = False
    if so_align_ok: ok("all .so entries %d-byte aligned" % want_page_size)

    print("[3b] NativeActivity .so DT_NEEDED / external imports")
    # Guard against the classic launch crash: a NativeActivity .so that calls
    # extern NDK functions (__android_log_print, ANativeActivity_finish, ...) but
    # is missing the matching DT_NEEDED. Android's RTLD_NOW linker fails the
    # dlopen with "cannot locate symbol" and the app closes immediately.
    def _expect_lib(name):
        if name.startswith("__android_log"): return "liblog.so"
        if name.startswith("__android"): return "libandroid.so"
        _an = ("ANativeActivity_","AConfiguration_","ALooper_","AInputQueue_",
               "AInputEvent_","ASensorManager","ASensor","AChoreographer_",
               "ANativeWindow_","ASurface","AImageReader_","AMedia",
               "AHardwareBuffer_","AStorageManager","ARect_","ADataSpace_")
        if name.startswith(_an): return "libandroid.so"
        if name in ("dlopen","dlsym","dlclose","dlerror","dladdr","dl_iterate_phdr"): return "libdl.so"
        return "libc.so"

    def _parse_needed_and_undef(dso):
        if dso[:4] != b"\x7fELF": return (None, None)
        def u(p,n): return int.from_bytes(dso[p:p+n],'little')
        shoff=u(0x28,8); shent=u(0x3a,2); shnum=u(0x3c,2)
        secs=[]
        for i in range(shnum):
            b=shoff+i*shent
            secs.append((u(b+4,4), u(b+24,8), u(b+32,8), u(b+56,8), u(b+0x28,4)))
        dynsym=dynamic=None
        for typ,off,size,ent,link in secs:
            if typ==11: dynsym=(off,size,ent,secs[link][1])
            elif typ==6: dynamic=(off,size)
        if dynsym is None or dynamic is None: return (set(), set())
        doff,dsize=dynamic
        needed=set(); i=0
        while i<dsize:
            tag=u(doff+i,8); val=u(doff+i+8,8); i+=16
            if tag==1:
                sbase=dynsym[3]; n=dso[sbase+val:]
                needed.add(n[:n.index(0)].decode('latin1'))
        soff,sz,ent,sbase=dynsym
        undef=set()
        for k in range(sz//ent):
            e=soff+k*ent
            name_off=u(e,4); info=dso[e+4]; shndx=u(e+6,2)
            if (info&0xf)==2 and shndx==0:  # STT_FUNC and SHN_UNDEF
                nm=dso[sbase+name_off:]
                undef.add(nm[:nm.index(0)].decode('latin1'))
        return (needed, undef)

    needed_all=set(); undef_all=set()
    for n in sos:
        need,uu=_parse_needed_and_undef(data[n])
        if need is None:
            allok=fail("cannot parse ELF for %s" % n); continue
        needed_all|=need; undef_all|=uu
    if not needed_all:
        ok("no DT_NEEDED (pure self-contained .so)")
    else:
        ok("DT_NEEDED: %s" % sorted(needed_all))
    strict=("liblog.so","libandroid.so","libdl.so","libm.so")
    missing=[(u,_expect_lib(u)) for u in sorted(undef_all)
             if _expect_lib(u) in strict and _expect_lib(u) not in needed_all]
    if missing:
        allok=fail("UND imports lack DT_NEEDED (crash at dlopen): %s" % missing)
    else:
        ok("all strict NDK imports resolve via DT_NEEDED")

    print("[4] AXML binary manifest parse")
    facts = parse_axml(data["AndroidManifest.xml"])
    print("    package=%r verCode=%r verName=%r minSdk=%r targetSdk=%r"
          % (facts["package"], facts["versionCode"], facts["versionName"], facts["minSdk"], facts["targetSdk"]))
    print("    activities=%r launcher=%s lib_name=%r" % (facts["activities"], facts["launcher"], facts["lib_name"]))
    if facts.get("bad_str_attrs"):
        allok = fail("string attribute(s) have zero typedValue.data (framework would read wrong value): %s"
                     % facts["bad_str_attrs"])
    elif not facts["package"]:
        allok = fail("empty package (AXML attribute encoding problem)")
    elif want_pkg and facts["package"] != want_pkg:
        allok = fail("package mismatch: got %r want %r" % (facts["package"], want_pkg))
    elif not facts["activities"]:
        allok = fail("no <activity> parsed from manifest")
    elif "android.app.NativeActivity" not in facts["activities"]:
        allok = fail("expected android.app.NativeActivity, got %r" % facts["activities"])
    elif not facts["lib_name"]:
        allok = fail("android.app.lib_name meta-data missing or empty")
    elif want_lib and facts["lib_name"] != want_lib:
        allok = fail("lib_name mismatch: got %r want %r" % (facts["lib_name"], want_lib))
    else:
        ok("AXML fields consistent (package/activity/lib_name all correct)")

    print("[4a] android:icon reference")
    # The value must be TYPE_REFERENCE (0x01). Written as TYPE_INT_HEX (0x11) the
    # id is byte-identical in a hex dump but the framework's TypedValue never
    # resolves it, and the launcher silently shows the default icon — the worst
    # possible failure mode: installs fine, no error, wrong icon.
    icon_resid = None
    if facts["icon_type"] is None:
        allok = fail("<application> declares no android:icon")
    elif facts["icon_type"] != 0x01:
        allok = fail("android:icon has dataType 0x%02x, expected TYPE_REFERENCE (0x01)"
                     % facts["icon_type"])
    else:
        ok("android:icon = %s encoded as TYPE_REFERENCE (0x01)" % facts["icon"])
        try:
            icon_resid = int(facts["icon"], 16)
        except ValueError:
            allok = fail("android:icon %r is not a hex resource id" % facts["icon"])

    print("[4b] resources.arsc — binary resource table")
    tab = None
    # android:icon is an id (0xpptteeee), not a path. The id -> path mapping lives
    # only in resources.arsc; without it AssetManager#getIdentifier returns 0 and
    # the app falls back to the system default icon with no diagnostic anywhere.
    icon_path = None
    if "resources.arsc" not in names:
        allok = fail("missing resources.arsc — android:icon cannot resolve to a file")
    else:
        try:
            tab = parse_arsc(data["resources.arsc"])
        except Exception as e:
            tab = None
            allok = fail("resources.arsc does not parse: %r" % e)
        if tab is not None:
            print("    table size=%d packageCount=%d globalStrings=%r"
                  % (tab["size"], tab["count"], tab["global"]))
            if not tab["packages"]:
                allok = fail("resources.arsc declares no package")
            else:
                pk = tab["packages"][0]
                print("    package id=0x%02x name=%r types=%r keys=%r"
                      % (pk["id"], pk["name"], pk["types"], pk["keys"]))
                print("    entries=%r" % (pk["entries"],))
                if want_pkg and pk["name"] != want_pkg:
                    allok = fail("arsc package %r != manifest package %r" % (pk["name"], want_pkg))
                elif pk["id"] != 0x7F:
                    allok = fail("arsc package id is 0x%02x, expected 0x7f" % pk["id"])
                elif not pk["entries"]:
                    allok = fail("resources.arsc contains no resource entries")
                elif icon_resid is None:
                    allok = fail("no icon id to resolve")
                else:
                    hit = [e for e in pk["entries"] if e[0] == icon_resid]
                    if not hit:
                        allok = fail("icon id 0x%08x is not defined in resources.arsc" % icon_resid)
                    else:
                        resid, tname, kname, dtype, ddata = hit[0]
                        if (tname, kname) != ("drawable", "ic_launcher"):
                            allok = fail("icon resolves to %s/%s, expected drawable/ic_launcher"
                                         % (tname, kname))
                        elif dtype != 0x03:
                            allok = fail("icon Res_value dataType is 0x%02x, expected TYPE_STRING (0x03)"
                                         % dtype)
                        elif ddata >= len(tab["global"]):
                            allok = fail("icon Res_value data %d out of range for a %d-entry global pool"
                                         % (ddata, len(tab["global"])))
                        else:
                            icon_path = tab["global"][ddata]
                            ok("0x%08x -> %s/%s -> TYPE_STRING -> %r"
                               % (resid, tname, kname, icon_path))
                            if icon_path not in names:
                                allok = fail("arsc points at %r, which is not in the APK" % icon_path)
                                icon_path = None
                            else:
                                ok("%r present in the APK (%d bytes)"
                                   % (icon_path, len(data[icon_path])))

    print("[4d] android:label — the app name, spelled one of two ways")
    # Two spellings are legal, and on a device both resolve to the same name:
    #
    #   TYPE_REFERENCE (0x01)  what aapt writes. The name lives once, in
    #                          resources.arsc, and the framework looks it up.
    #   TYPE_STRING    (0x03)  the name spelled out in the manifest. Every
    #                          consumer can read it, including a third-party APK
    #                          viewer that parses the binary manifest and never
    #                          opens the table -- which is why this is Aster's
    #                          default; `--label-as-reference` asks for the
    #                          aapt spelling back.
    #
    # The invariant is not which byte the manifest uses, it is that the app has
    # a name and that the name is unambiguous. So this section accepts either
    # spelling, resolves it, and then insists that string/app_name is still in
    # the table and still says the same thing -- the two spellings cannot drift
    # apart without a check failing here.
    #
    # `--label-literal` / `--label-reference` pin the section to one spelling.
    # That is how a test proves a flag really changed the bytes: without pinning,
    # a flag that silently did nothing would still pass.
    label_text = None
    if facts["label_type"] is None:
        allok = fail("<application> declares no android:label")
    elif facts["label_type"] == 0x03:
        if want_label_reference:
            allok = fail("android:label is a TYPE_STRING literal, but --label-reference "
                         "expected TYPE_REFERENCE (0x01)")
        label_text = facts["label"]
        ok("android:label is the literal %r (TYPE_STRING)" % label_text)
        if not label_text:
            allok = fail("android:label is an empty literal")
    elif facts["label_type"] != 0x01:
        allok = fail("android:label has dataType 0x%02x; expected TYPE_STRING (0x03) "
                     "or TYPE_REFERENCE (0x01)" % facts["label_type"])
    else:
        if want_label_literal:
            allok = fail("android:label is a TYPE_REFERENCE, but --label-literal "
                         "expected TYPE_STRING (0x03)")
        if tab is None:
            pass                  # a missing table was already reported in [4b]
        else:
            pk = tab["packages"][0]
            # Structure before resolution: a table holding one type was built for
            # one resource, and a label id pointing nowhere is only the second
            # thing wrong with it.
            if len(pk["types"]) < 2:
                allok = fail("resources.arsc declares %d type(s); a drawable and a "
                             "string resource need two" % len(pk["types"]))
            else:
                ok("resource table holds %d types: %r" % (len(pk["types"]), pk["types"]))
            try:
                label_resid = int(facts["label"], 16)
            except ValueError:
                label_resid = None
                allok = fail("android:label %r is not a hex resource id" % facts["label"])
            hit = [] if label_resid is None else [e for e in pk["entries"] if e[0] == label_resid]
            if label_resid is not None and not hit:
                allok = fail("label id 0x%08x is not defined in resources.arsc" % label_resid)
            elif hit:
                resid, tname, kname, dtype, ddata = hit[0]
                if (tname, kname) != ("string", "app_name"):
                    allok = fail("label resolves to %s/%s, expected string/app_name"
                                 % (tname, kname))
                elif dtype != 0x03:
                    allok = fail("label Res_value dataType is 0x%02x, expected TYPE_STRING (0x03)"
                                 % dtype)
                elif ddata >= len(tab["global"]):
                    allok = fail("label Res_value data %d out of range for a %d-entry global pool"
                                 % (ddata, len(tab["global"])))
                else:
                    label_text = tab["global"][ddata]
                    ok("0x%08x -> string/app_name -> TYPE_STRING -> %r" % (resid, label_text))
                    if not label_text:
                        allok = fail("string/app_name is empty")

    # The table is not excused by either spelling: string/app_name has to be
    # there, and it has to agree with whatever the manifest said.
    if tab is not None:
        pk = tab["packages"][0]
        hit = [e for e in pk["entries"] if (e[1], e[2]) == ("string", "app_name")
               and e[3] == 0x03 and e[4] < len(tab["global"])]
        if not hit:
            allok = fail("string/app_name is missing from resources.arsc")
        else:
            txt = tab["global"][hit[0][4]]
            ok("the table still holds string/app_name -> %r" % txt)
            if want_label is not None and txt != want_label:
                allok = fail("string/app_name is %r, expected %r" % (txt, want_label))
            if label_text is not None and txt != label_text:
                allok = fail("the manifest says %r but resources.arsc says %r"
                             % (label_text, txt))
    if want_label is not None and label_text is not None and label_text != want_label:
        allok = fail("android:label is %r, expected %r" % (label_text, want_label))

    print("[4c] launcher icon PNG (independent zlib decode)")
    if icon_path is None:
        print("    SKIP: no icon resolved from the resource table")
    else:
        try:
            img = decode_png(data[icon_path])
        except Exception as e:
            img = None
            allok = fail("icon PNG does not decode: %r" % e)
        if img is not None:
            for need in ("IHDR", "PLTE", "IDAT", "IEND"):
                if need not in img["chunks"]:
                    allok = fail("icon PNG is missing the %s chunk" % need)
            if img["crc_bad"]:
                allok = fail("icon PNG chunk(s) with bad CRC-32: %s" % img["crc_bad"])
            else:
                ok("all %d chunks have matching CRC-32 (%s)"
                   % (len(img["chunks"]), " ".join(img["chunks"])))
            print("    %dx%d bitDepth=%d colourType=%d palette=%d entries idat=%dB raw=%dB"
                  % (img["w"], img["h"], img["depth"], img["ctype"],
                     len(img["palette"]) // 3 if img["palette"] else 0,
                     img["idat_len"], img["raw_len"]))
            if img["w"] != img["h"] or img["w"] < 48:
                allok = fail("icon is %dx%d; a launcher icon should be square and >= 48px"
                             % (img["w"], img["h"]))
            else:
                ok("square %dx%d icon (>= 48px)" % (img["w"], img["h"]))
            corner = img["rgba"](img["idx_at"](0, 0))
            centre = img["rgba"](img["idx_at"](img["w"] // 2, img["h"] // 2))
            colours = {}
            for y in range(img["h"]):
                for x in range(img["w"]):
                    c = img["rgba"](img["idx_at"](x, y))
                    colours[c] = colours.get(c, 0) + 1
            print("    corner=%r centre=%r distinct=%d" % (corner, centre, len(colours)))
            if corner is None or corner[3] != 0:
                allok = fail("icon corner pixel is not transparent: %r" % (corner,))
            else:
                ok("corner pixel transparent (rounded plate, alpha=%d)" % corner[3])
            if centre is None or centre[3] != 255:
                allok = fail("icon centre pixel is not opaque: %r" % (centre,))
            else:
                ok("centre pixel opaque %r" % (centre,))
            opaque = [c for c in colours if c[3] == 255]
            if len(colours) < 3:
                allok = fail("icon has only %d distinct colours; expected plate + glyph + transparent"
                             % len(colours))
            elif len(opaque) < 2:
                allok = fail("icon has %d opaque colour(s); the glyph is invisible against the plate"
                             % len(opaque))
            else:
                ok("%d distinct colours, %d opaque (plate + glyph), %d transparent"
                   % (len(colours), len(opaque), len(colours) - len(opaque)))

    print("[5] APK v1 (JAR) signature")
    # [5a] MANIFEST.MF per-entry digests
    mf = data["META-INF/MANIFEST.MF"].decode('utf-8', 'replace')
    mf_ok = True
    for line in mf.splitlines():
        if line.startswith("Name: "):
            ename = line[6:].strip()
            # find its SHA-256-Digest line
            pass
    # robust: parse Name:/SHA-256-Digest: pairs
    import re
    entries = re.findall(r"Name: ([^\r\n]+)\r?\nSHA-256-Digest: ([^\r\n]+)", mf)
    for ename, digb64 in entries:
        ename = ename.strip()
        if ename not in data:
            allok = fail("MANIFEST lists %r but it is not in the APK" % ename); mf_ok = False; continue
        want = hashlib.sha256(data[ename]).digest()
        got = base64_b64d(digb64.strip())
        if want != got:
            allok = fail("MANIFEST digest mismatch for %r" % ename); mf_ok = False
    if mf_ok: ok("MANIFEST.MF per-entry SHA-256-Digest OK (%d entries)" % len(entries))

    # [5b] CERT.SF
    sf = data["META-INF/CERT.SF"].decode('utf-8', 'replace')
    sf_ok = True
    m = re.search(r"SHA-256-Digest-Manifest: ([^\r\n]+)", sf)
    if not m:
        allok = fail("CERT.SF missing SHA-256-Digest-Manifest"); sf_ok = False
    else:
        want = hashlib.sha256(data["META-INF/MANIFEST.MF"]).digest()
        got = base64_b64d(m.group(1).strip())
        if want != got:
            allok = fail("CERT.SF manifest digest mismatch"); sf_ok = False
    # per-entry digests in CERT.SF over the matching MANIFEST section
    sf_entries = re.findall(r"Name: ([^\r\n]+)\r?\nSHA-256-Digest: ([^\r\n]+)", sf)
    for ename, digb64 in sf_entries:
        ename = ename.strip()
        sect = _manifest_section(mf, ename)
        if sect is None:
            allok = fail("CERT.SF lists %r not present in MANIFEST" % ename); sf_ok = False; continue
        want = hashlib.sha256(sect.encode('utf-8')).digest()
        got = base64_b64d(digb64.strip())
        if want != got:
            allok = fail("CERT.SF per-entry digest mismatch for %r" % ename); sf_ok = False
    if sf_ok: ok("CERT.SF manifest + per-entry digests OK")

    # [5c] CERT.RSA PKCS#7 signature over CERT.SF.
    #
    # This is verified in-process first: the certificate's RSA public key is
    # lifted out of the PKCS#7 blob and the RSASSA-PKCS1-v1_5 signature is
    # checked with pow(), which needs nothing but the stdlib. openssl is then a
    # *second* opinion, not the only one -- when it is absent (a bare Termux
    # install, say) the signature is still verified and the missing tool is
    # reported as a skip instead of as a failure of the APK.
    try:
        vres = _pkcs7_verify(data["META-INF/CERT.RSA"], data["META-INF/CERT.SF"])
        if not vres[0]:
            allok = fail("CERT.RSA PKCS#7 signature did not verify: %s" % vres[1])
        else:
            ok("CERT.RSA PKCS#7 signature over CERT.SF verified in-process "
               "(RSASSA-PKCS1-v1_5, SHA-256, stdlib only)%s" % vres[2])
    except Exception as e:
        allok = fail("CERT.RSA could not be verified in-process: %r" % e)

    # [5d] cert subject -- read out of the certificate itself, then confirmed
    # by openssl when openssl is there.
    try:
        cn = _pkcs7_cert_cn(data["META-INF/CERT.RSA"])
        if cn == "Aster Dev Signing Key":
            ok("embedded cert subject CN=%s" % cn)
        else:
            allok = fail("unexpected cert subject CN: %r" % cn)
    except Exception as e:
        allok = fail("could not read the embedded certificate subject: %r" % e)

    have_openssl = sh("command -v openssl >/dev/null 2>&1").returncode == 0
    if not have_openssl:
        skip("openssl is not on PATH -- the v1 signature above was verified "
             "in-process; install openssl (`pkg install openssl`) for a second opinion")
    else:
        with tempfile.TemporaryDirectory() as td:
            rsa_p = os.path.join(td, "CERT.RSA")
            sf_p = os.path.join(td, "CERT.SF")
            open(rsa_p, "wb").write(data["META-INF/CERT.RSA"])
            open(sf_p, "wb").write(data["META-INF/CERT.SF"])
            r = sh("openssl smime -verify -noverify -inform DER -in '%s' -content '%s'" % (rsa_p, sf_p))
            if r.returncode != 0:
                allok = fail("openssl smime -verify failed:\n" + r.stderr)
            else:
                ok("CERT.RSA PKCS#7 signature over CERT.SF verified (openssl smime -verify)")
            subj = sh("openssl pkcs7 -inform DER -in '%s' -print_certs 2>/dev/null | openssl x509 -noout -subject 2>/dev/null" % rsa_p)
            if "Aster Dev Signing Key" in subj.stdout:
                ok("openssl agrees on the cert subject: %s" % subj.stdout.strip())
            else:
                allok = fail("openssl reports an unexpected cert subject: %r" % subj.stdout.strip())

        # [5e] the embedded RSA signature must be exactly the modulus width.
        # v0.22.48-dev bug: rsaSign() returned a bare big-endian integer, which
        # strips leading zero bytes; for ~1/256 of all signatures the result is
        # shorter than the modulus and every PKCS#7 verifier (openssl here,
        # Android's package verifier on device) rejects the APK with
        # "wrong signature length". openssl -verify only catches this when the
        # digest happens to produce such a signature, so assert the width
        # structurally on every run.
        def der_node(b, off):
            # -> (tag, node_start, content_start, content_len)
            tag = b[off]; p = off + 1
            l = b[p]; p += 1
            if l & 0x80:
                n = l & 0x7f
                l = int.from_bytes(b[p:p + n], 'big'); p += n
            return tag, off, p, l
        def kids(b, node):
            out = []; p = node[2]; end = p + node[3]
            while p < end:
                n = der_node(b, p)
                out.append(n); p = n[2] + n[3]
            return out
        rsa = data["META-INF/CERT.RSA"]
        try:
            ci = der_node(rsa, 0)                                   # ContentInfo SEQ
            ctx = [n for n in kids(rsa, ci) if n[0] == 0xA0][0]     # [0] { SignedData }
            sd = der_node(rsa, ctx[2])                              # SignedData SEQ
            sd_kids = kids(rsa, sd)                                 # INT, SET, SEQ, [0], SET
            z = [n for n in sd_kids if n[0] == 0xA0][0]             # [0] { certificate }
            cert_node = kids(rsa, z)[0]                             # the X.509 certificate
            si_set = [n for n in sd_kids if n[0] == 0x31][-1]       # SignerInfos SET (last child)
            si = der_node(rsa, si_set[2])                           # SignerInfo SEQ (single signer)
            sig_oct = [n for n in kids(rsa, si) if n[0] == 0x04][-1]  # encryptedDigest OCTET STRING
            # modulus width from the certificate's subjectPublicKey BIT STRING
            def find_bitstring(node):
                if node[0] == 0x03: return node
                if node[0] in (0x30, 0x31):
                    for c in kids(rsa, node):
                        r = find_bitstring(c)
                        if r: return r
                return None
            tbs = kids(rsa, cert_node)[0]                           # tbsCertificate SEQ
            bs = find_bitstring(tbs)                                # subjectPublicKey BIT STRING
            rsa_pk = der_node(rsa, bs[2] + 1)                       # skip unused-bits byte -> RSAPublicKey SEQ
            mod_int = kids(rsa, rsa_pk)[0]                          # modulus INTEGER
            mod = rsa[mod_int[2]:mod_int[2] + mod_int[3]]
            if mod and mod[0] == 0x00: mod = mod[1:]                # DER positive-integer pad byte
            if sig_oct[3] == len(mod):
                ok("embedded RSA signature is fixed-width: %d bytes == modulus size" % sig_oct[3])
            else:
                allok = fail("embedded RSA signature is %d bytes but the modulus is %d bytes "
                             "(leading zero bytes were stripped)" % (sig_oct[3], len(mod)))
        except Exception as e:
            allok = fail("could not structurally verify signature width: %r" % e)

    # ------------------------------------------------------------ [6] APK v2
    print("[6] APK v2 (APK Signing Block) signature")
    try:
        allok = validate_v2(raw, data, allok)
    except Exception as e:
        allok = fail("v2 signature block could not be parsed: %r" % e)

    return allok

# ---------------------------------------------------------------- APK v2 helpers
V2_MAGIC = b"APK Sig Block 42"
V2_BLOCK_ID = 0x7109871a
V3_BLOCK_ID = 0xf05368c0
V31_BLOCK_ID = 0x1b93ad61
ALG_RSA_PKCS1_SHA256 = 0x0103
DIGEST_INFO_SHA256 = bytes([0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48,
                            0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20])


def _der_at(b, p):
    """-> (tag, node_start, content_start, content_len) or None."""
    if p + 2 > len(b):
        return None
    tag = b[p]
    q = p + 1
    if b[q] & 0x80:
        n = b[q] & 0x7F
        if n == 0 or n > 4 or q + 1 + n > len(b):
            return None
        ln = int.from_bytes(b[q + 1:q + 1 + n], "big")
        q += 1 + n
    else:
        ln = b[q]
        q += 1
    if q + ln > len(b):
        return None
    return (tag, p, q, ln)


def _der_kids(b, node):
    out = []
    p, end = node[2], node[2] + node[3]
    while p + 2 <= end:
        k = _der_at(b, p)
        if k is None:
            break
        out.append(k)
        p = k[2] + k[3]
    return out


def _cert_spki(cert):
    """SubjectPublicKeyInfo: the only tbsCertificate child that is a SEQUENCE
    whose first child is a SEQUENCE (AlgorithmIdentifier) and whose second is a
    BIT STRING."""
    top = _der_at(cert, 0)
    tbs = _der_at(cert, top[2])
    for k in _der_kids(cert, tbs):
        if k[0] != 0x30:
            continue
        kids = _der_kids(cert, k)
        if len(kids) >= 2 and kids[0][0] == 0x30 and kids[1][0] == 0x03:
            return cert[k[1]:k[2] + k[3]]
    return None


def _rsa_pubkey(spki):
    seq = _der_at(spki, 0)
    kids = _der_kids(spki, seq)
    pk = _der_at(spki, kids[1][2] + 1)          # skip the BIT STRING unused-bits byte
    mk = _der_kids(spki, pk)
    n = int.from_bytes(spki[mk[0][2]:mk[0][2] + mk[0][3]], "big")
    e = int.from_bytes(spki[mk[1][2]:mk[1][2] + mk[1][3]], "big")
    return n, e


def _pkcs1_v15_verify(n, e, signed_data, sig):
    """True iff sig is a RSASSA-PKCS1-v1_5 SHA-256 signature over signed_data."""
    k = (n.bit_length() + 7) // 8
    if len(sig) != k:
        return False, "signature is %d bytes but the modulus is %d bytes" % (len(sig), k)
    em = pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big")
    t = DIGEST_INFO_SHA256 + hashlib.sha256(signed_data).digest()
    want = b"\x00\x01" + b"\xff" * (k - 3 - len(t)) + b"\x00" + t
    if em != want:
        return False, "PKCS#1 v1.5 padding / DigestInfo mismatch"
    return True, "ok"


# ---------------------------------------------------------------- PKCS#7 (v1 JAR)
# The v1 signature is a PKCS#7 SignedData in META-INF/CERT.RSA. Verifying it
# needs no external tool: the signer's certificate rides inside the blob, so its
# RSA public key is right there, and pow(sig, e, n) is the whole of RSA. openssl
# is kept as a second opinion -- which is the only honest reason to shell out,
# and the reason a missing openssl is a skip rather than a failure.
_OID_SHA256 = bytes([0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01])      # 2.16.840.1.101.3.4.2.1
_OID_MSG_DIGEST = bytes([0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04])   # 1.2.840.113549.1.9.4
_OID_CN = bytes([0x55, 0x04, 0x03])                                              # 2.5.4.3


def _pkcs7_signed_data(b):
    """ContentInfo SEQ -> the SignedData SEQ node inside it."""
    ci = _der_at(b, 0)
    if ci is None or ci[0] != 0x30:
        raise ValueError("not a PKCS#7 ContentInfo")
    wrap = [k for k in _der_kids(b, ci) if k[0] == 0xA0][0]
    return _der_at(b, wrap[2])


def _pkcs7_cert(b):
    """The first certificate of the SignedData, as its own bytes."""
    sd = _pkcs7_signed_data(b)
    certs = [k for k in _der_kids(b, sd) if k[0] == 0xA0][0]
    c = _der_kids(b, certs)[0]
    return b[c[1]:c[2] + c[3]]


def _pkcs7_cert_cn(b):
    """The CN of the signer's certificate subject, read out of the DER."""
    cert = _pkcs7_cert(b)
    tbs = _der_at(cert, _der_at(cert, 0)[2])
    seqs = [k for k in _der_kids(cert, tbs) if k[0] == 0x30]
    spki_i = None
    for i, k in enumerate(seqs):
        ks = _der_kids(cert, k)
        if len(ks) >= 2 and ks[0][0] == 0x30 and ks[1][0] == 0x03:
            spki_i = i                      # SubjectPublicKeyInfo
            break
    if not spki_i:
        return ''
    for rdn in _der_kids(cert, seqs[spki_i - 1]):     # Subject: RDNSequence
        for atv in _der_kids(cert, rdn):              # AttributeTypeAndValue
            ks = _der_kids(cert, atv)
            if len(ks) != 2:
                continue
            if cert[ks[0][2]:ks[0][2] + ks[0][3]] == _OID_CN:
                # AttributeTypeAndValue ::= SEQUENCE { type, value } and the
                # value is an ANY -- normally a bare UTF8String/PrintableString,
                # not a SET (the SET is the RDN one level up). Accept a wrapper
                # anyway, since "ANY" means an encoder is free to add one.
                val = ks[1]
                if val[0] == 0x31:
                    inner = _der_kids(cert, val)
                    if inner:
                        val = inner[0]
                return cert[val[2]:val[2] + val[3]].decode('utf-8', 'replace')
    return ''


def _pkcs7_verify(b, content):
    """Verify the single SignerInfo of a PKCS#7 SignedData over `content`.
    -> (True, note, extra) or (False, why, '')."""
    sd = _pkcs7_signed_data(b)
    sd_kids = _der_kids(b, sd)
    n, e = _rsa_pubkey(_cert_spki(_pkcs7_cert(b)))
    si = _der_at(b, [k for k in sd_kids if k[0] == 0x31][-1][2])   # SignerInfos: the last SET
    si_kids = _der_kids(b, si)
    # digestAlgorithm must be SHA-256. A PKCS#7 blob names the digest algorithm
    # twice, and only one of the two is inside what the signature covers.
    da_kids = _der_kids(b, si_kids[2])
    da_oid = b[da_kids[0][2]:da_kids[0][2] + da_kids[0][3]]
    if not da_oid.endswith(_OID_SHA256):
        return False, "digestAlgorithm is not SHA-256", ""
    sig_node = [k for k in si_kids if k[0] == 0x04][-1]            # encryptedDigest
    sig = b[sig_node[2]:sig_node[2] + sig_node[3]]
    attrs = [k for k in si_kids if k[0] == 0xA0]
    extra = ""
    if attrs:
        # signedAttrs are signed, not the content: the signature covers their
        # DER with the implicit [0] tag replaced by the SET (0x31) it stands
        # for, and the content is covered indirectly by the messageDigest attr.
        node = attrs[0]
        signed = b"\x31" + b[node[1] + 1:node[2] + node[3]]
        md = None
        for atv in _der_kids(b, node):
            ks = _der_kids(b, atv)
            if len(ks) != 2:
                continue
            if b[ks[0][2]:ks[0][2] + ks[0][3]] == _OID_MSG_DIGEST:
                vals = _der_kids(b, ks[1])
                v = vals[0] if vals else ks[1]
                md = b[v[2]:v[2] + v[3]]
        if md is None:
            return False, "signedAttrs has no messageDigest attribute", ""
        if md != hashlib.sha256(content).digest():
            return False, "signedAttrs messageDigest != SHA-256(CERT.SF)", ""
        extra = "; signedAttrs messageDigest == SHA-256(CERT.SF)"
    else:
        signed = content
    good, why = _pkcs1_v15_verify(n, e, signed, sig)
    return (True, "ok", extra) if good else (False, why, "")


def _chunked_sha256(segs):
    """The v2 CHUNKED_SHA256 digest: hash each 1 MiB chunk as 0xa5 || uint32 len
    || chunk, then hash 0x5a || uint32 chunkCount || the chunk digests."""
    chunk_digests = []
    for s in segs:
        off = 0
        while off < len(s):
            c = s[off:off + (1 << 20)]
            chunk_digests.append(hashlib.sha256(b"\xa5" + struct.pack("<I", len(c)) + c).digest())
            off += len(c)
    return hashlib.sha256(b"\x5a" + struct.pack("<I", len(chunk_digests)) + b"".join(chunk_digests)).digest()


def _v2_slice(b, p):
    """uint32 length-prefixed slice -> (bytes, next_offset)."""
    n = struct.unpack_from("<I", b, p)[0]
    return b[p + 4:p + 4 + n], p + 4 + n


def validate_v2(raw, data, allok):
    """Verify the APK Signature Scheme v2 block sitting in `raw` (the whole APK).
    `data` maps entry name -> bytes for entries already read out of the ZIP."""
    # [6a] locate the block: it must end (magic included) exactly where the
    # Central Directory begins, and both uint64 size fields must agree.
    mi = raw.rfind(V2_MAGIC)
    if mi < 0:
        return fail("no APK Signing Block (magic 'APK Sig Block 42' not found)")
    sb_end = mi + len(V2_MAGIC)
    if raw[sb_end:sb_end + 4] != b"PK\x01\x02":
        return fail("APK Signing Block is not immediately followed by the Central Directory")
    size_tail = struct.unpack_from("<Q", raw, sb_end - 24)[0]
    sb_start = sb_end - (size_tail + 8)
    if sb_start < 0:
        return fail("nonsensical APK Signing Block size: %d" % size_tail)
    size_head = struct.unpack_from("<Q", raw, sb_start)[0]
    if size_head != size_tail:
        return fail("APK Signing Block size fields disagree: %d vs %d" % (size_head, size_tail))
    if sb_start + size_tail + 8 != sb_end:
        return fail("APK Signing Block span does not reach the Central Directory")
    ok("Signing Block at [%d, %d): %d bytes, size fields agree, CD follows immediately"
       % (sb_start, sb_end, size_tail + 8))

    # [6b] walk the ID-value pairs
    pairs_end = sb_end - 24
    p = sb_start + 8
    v2 = None
    seen = []
    while p + 8 <= pairs_end:
        plen = struct.unpack_from("<Q", raw, p)[0]
        pid = struct.unpack_from("<I", raw, p + 8)[0]
        if plen < 4 or p + 8 + plen > pairs_end:
            return fail("malformed ID-value pair (id=0x%08x len=%d)" % (pid, plen))
        seen.append(pid)
        if pid == V2_BLOCK_ID:
            v2 = raw[p + 12:p + 8 + plen]
        p += 8 + plen
    if p != pairs_end:
        return fail("ID-value pairs do not fill the Signing Block exactly")
    if V3_BLOCK_ID in seen or V31_BLOCK_ID in seen:
        return fail("unexpected v3 / v3.1 block present (Aster deliberately signs v1+v2 only)")
    if v2 is None:
        return fail("no APK Signature Scheme v2 block (ID 0x7109871a) in the Signing Block")
    ok("ID-value pairs: %s -- v2 present, no v3 (Aster signs v1+v2 by design)"
       % ", ".join("0x%08x" % i for i in seen))

    signers, q = _v2_slice(v2, 0)
    if q != len(v2):
        return fail("trailing bytes after the v2 signers sequence")
    signer, q = _v2_slice(signers, 0)
    signer_count = 1
    rest = signers[q:]
    while rest:
        _, q2 = _v2_slice(rest, 0)
        signer_count += 1
        rest = rest[q2:]
    signed_data, q = _v2_slice(signer, 0)
    signatures, q = _v2_slice(signer, q)
    public_key, q = _v2_slice(signer, q)
    if q != len(signer):
        return fail("trailing bytes inside the v2 signer")
    ok("v2 block parses: %d signer; signed-data %d B, signatures %d B, public key %d B"
       % (signer_count, len(signed_data), len(signatures), len(public_key)))

    digests, q = _v2_slice(signed_data, 0)
    certs, q = _v2_slice(signed_data, q)
    attributes, q = _v2_slice(signed_data, q)
    trailing, q = _v2_slice(signed_data, q)

    # digests / signatures: each element is uint32 length + uint32 algID + lp bytes
    def parse_pairs(blob):
        out = []
        p = 0
        while p < len(blob):
            el, p = _v2_slice(blob, p)
            alg = struct.unpack_from("<I", el, 0)[0]
            val, off = _v2_slice(el, 4)
            if off != len(el):
                raise ValueError("trailing bytes in a (uint32, bytes) pair")
            out.append((alg, val))
        return out

    dig_list = parse_pairs(digests)
    sig_list = parse_pairs(signatures)
    cert_list = []
    p = 0
    while p < len(certs):
        c, p = _v2_slice(certs, p)
        cert_list.append(c)
    if [a for a, _ in dig_list] != [a for a, _ in sig_list]:
        return fail("v2 signature algorithm IDs differ between the digests and signatures records: %r vs %r"
                    % ([hex(a) for a, _ in dig_list], [hex(a) for a, _ in sig_list]))
    ok("signed-data: %d digest(s) alg %s, %d signature(s) alg %s, %d certificate(s), "
       "%d attribute(s), %d-B reserved field"
       % (len(dig_list), [hex(a) for a, _ in dig_list], len(sig_list),
          [hex(a) for a, _ in sig_list], len(cert_list), len(attributes), len(trailing)))
    if not cert_list:
        return fail("v2 signer carries no certificate")

    # [6c] the signer's public key must be the certificate's SPKI
    spki = _cert_spki(cert_list[0])
    if spki is None:
        return fail("cannot extract SubjectPublicKeyInfo from the v2 certificate")
    if spki != public_key:
        return fail("v2 public key does not match the certificate's SubjectPublicKeyInfo "
                    "(%d vs %d bytes)" % (len(public_key), len(spki)))
    n, e = _rsa_pubkey(spki)
    ok("v2 public key == the certificate's SubjectPublicKeyInfo (RSA-%d, e=%d)" % (n.bit_length(), e))

    # [6d] verify the signature over signed data
    if len(sig_list) != 1 or sig_list[0][0] != ALG_RSA_PKCS1_SHA256:
        return fail("expected a single 0x0103 (RSASSA-PKCS1-v1_5 / SHA-256) signature, got %r"
                    % [hex(a) for a, _ in sig_list])
    good, why = _pkcs1_v15_verify(n, e, signed_data, sig_list[0][1])
    if not good:
        return fail("v2 signature over signed-data did not verify: %s" % why)
    ok("v2 signature verified: RSASSA-PKCS1-v1_5 over SHA-256(signed-data), %d-bit modulus" % n.bit_length())

    # [6e] recompute the content digest
    eocd_off = raw.rfind(b"PK\x05\x06")
    cd_offset_field = struct.unpack_from("<I", raw, eocd_off + 16)[0]
    if cd_offset_field != sb_end:
        return fail("EOCD central-directory offset is %d but the Central Directory really starts at %d"
                    % (cd_offset_field, sb_end))
    cd = raw[sb_end:eocd_off]
    eocd = raw[eocd_off:]
    # The v2 rule: when digesting, the EOCD's CD-offset field is treated as
    # pointing at the start of the APK Signing Block, not at the CD.
    eocd_for_digest = bytearray(eocd)
    eocd_for_digest[16:20] = struct.pack("<I", sb_start)
    want = _chunked_sha256([raw[:sb_start], cd, bytes(eocd_for_digest)])
    got = dict((a, v) for a, v in dig_list).get(ALG_RSA_PKCS1_SHA256)
    if got is None:
        return fail("no 0x0103 content digest in the v2 signed-data")
    if got != want:
        return fail("v2 CHUNKED_SHA256 content digest mismatch: block has %s, recomputed %s"
                    % (got.hex(), want.hex()))
    ok("v2 content digest recomputed over entries[0:%d] + CD[%d:%d] + EOCD (CD offset "
       "rewritten to the Signing Block start %d) -- matches" % (sb_start, sb_end, eocd_off, sb_start))

    # [6g] anti-stripping: the v1 signature file must declare the v2 scheme
    sf_txt = data["META-INF/CERT.SF"].decode("utf-8", "replace")
    main_section = sf_txt.split("\r\n\r\n", 1)[0]
    m = re.search(r"^X-Android-APK-Signed:[ \t]*([^\r\n]+)", main_section, re.M)
    if not m:
        return fail("CERT.SF main section lacks 'X-Android-APK-Signed': the v2 block could be "
                    "stripped and the APK downgraded to v1 without detection")
    schemes = [t.strip() for t in m.group(1).split(",") if t.strip()]
    if schemes != ["2"]:
        return fail("CERT.SF declares X-Android-APK-Signed: %r, expected ['2']" % schemes)
    ok("CERT.SF declares X-Android-APK-Signed: 2 -- stripping the v2 block is detectable")

    # [6h] v1 and v2 must have been made with the same certificate
    rsa = data["META-INF/CERT.RSA"]
    ci = _der_at(rsa, 0)
    ctx = [k for k in _der_kids(rsa, ci) if k[0] == 0xA0][0]
    sd = _der_at(rsa, ctx[2])
    sd_kids = _der_kids(rsa, sd)
    z = [k for k in sd_kids if k[0] == 0xA0][0]
    v1_cert = rsa[_der_kids(rsa, z)[0][1]:_der_kids(rsa, z)[0][2] + _der_kids(rsa, z)[0][3]]
    if v1_cert != cert_list[0]:
        return fail("the v1 (CERT.RSA) and v2 certificates differ: v1 and v2 were signed with different keys")
    ok("v1 (CERT.RSA) and v2 certificates are byte-identical (%d bytes) -- one key, dual-signed"
       % len(v1_cert))
    return allok

def base64_b64d(s):
    import base64
    return base64.b64decode(s)

def _manifest_section(mf, name):
    """Return the raw 'Name: <name>\\r\\n...\\r\\n\\r\\n' section from MANIFEST.MF."""
    key = "Name: " + name + "\r\n"
    i = mf.find(key)
    if i < 0:
        return None
    j = mf.find("\r\n\r\n", i)
    if j < 0:
        return mf[i:]
    return mf[i:j + 2]   # up to and including the trailing CRLF (before the blank line)

def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("apk")
    ap.add_argument("--package", default=None)
    ap.add_argument("--libname", default=None)
    ap.add_argument("--abi", default="arm64-v8a")
    ap.add_argument("--label", default=None)
    ap.add_argument("--label-literal", action="store_true",
                    help="require android:label to be a TYPE_STRING in the manifest "
                         "(Aster's default)")
    ap.add_argument("--label-reference", action="store_true",
                    help="require android:label to be a TYPE_REFERENCE into "
                         "resources.arsc (what build-apk --label-as-reference produces)")
    ap.add_argument("--page-size", type=int, default=4096, choices=(4096, 16384),
                    help="require every lib/*.so entry to be aligned to this page "
                         "size inside the ZIP (4096 default; 16384 for 16 KB-page devices)")
    args = ap.parse_args()
    if not os.path.exists(args.apk):
        print("error: %s not found" % args.apk); sys.exit(2)
    ok = validate(args.apk, args.package, args.libname, args.abi, args.label,
                  args.label_literal, args.label_reference, args.page_size)
    print("\n=== RESULT: %s ===" % ("ALL CHECKS PASSED" if ok else "SOME CHECKS FAILED"))
    sys.exit(0 if ok else 1)

if __name__ == "__main__":
    main()
