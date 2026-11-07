# VALIDATION-v0.23.71-dev — `@embed` alignment and the `ET_REL` blind spot

**Version:** `0.23.71-dev` · **Theme:** close the last two items the audit left
open · **Byte impact:** none on any pre-existing example.

The audit's second part ended with two "still open" items: `.rodata` carried
`addralign 1` where GNU ld uses 8, so `@embed` data could not ask for more than
byte alignment; and `regression-symtab.sh`'s `ET_REL` branch had never run.
This round closes both. The first is a language/ELF change with a default of
1 chosen deliberately so that every program written before it stays
byte-identical. The second is a test-gate fix — no compiler change — and is
the more embarrassing of the two: four products were being built and then
silently never compared.

## 1. Strict build and the generated-table contract

| Check | Result |
| --- | --- |
| `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp` | PASS |
| `python3 bootstrap/gen_lexer_names.py --check` | PASS (83 tokens / 32 keywords, unchanged) |
| `python3 bootstrap/gen_parser_names.py --check` | PASS |
| Quoted version literal `"0.23.71-dev"` in `src/aster.cpp` | exactly 1 |
| `./aster --version` | `Aster bootstrap compiler v0.23.71-dev` |
| `CMakeLists.txt` project version | `0.23.71` |
| `src/aster.cpp` line count | 13778 (ARCHITECTURE.md claims `~13k`, within ±10%) |

No reserved word is added this round: 32 keywords, `tls` still contextual.
`bootstrap/gen_lexer_names.py`, `bootstrap/aster.ast` and
`tests/lexer_names.h` are therefore untouched.

## 2. Implementation, by the code that carries it

The compiler already had **half** the contract: `parseObject` read a
`.rodata` section's `addralign` back into `rodataAlign`, and both linkers
padded the merged blob to it
(`while(obj.rodataAlign>1&&mergedRodata.size()%obj.rodataAlign)`). What was
missing was the producing end and the dynamic section header.

| Piece | Change |
| --- | --- |
| Parser | `@embed("path", N)` parses an optional second argument after `eat(TK::Comma)`; `need(TK::Number, "expected a power-of-two alignment after …")` + `unsignedLiteral()` reject non-literals; power-of-two and `≤ 4096` checks mirror `@align(N)`. `@embed_len` refuses the second argument with `@embed_len takes no alignment argument`. A third argument or a missing comma reaches the existing `expected ')' after the file path`. |
| `embedFile()` | Signature gains `uint64_t align`. On a cache hit it walks `globals` for the `fromEmbed` placeholder and does `if(align>g.align)g.align=align;` — **raise, never lower** — so one path stays one blob. On a miss `g.align = align`. |
| Data model | `Global::align`; `ObjectLayout::rodataAlign = 1`; `SoDynSpec::rodataAlign`. |
| `layoutObject()` | `const uint64_t a=g.isString?(g.fromEmbed?g.align:1):…`; only `@embed` blobs (not ordinary string literals) may ask for a boundary. `if(a>L.rodataAlign)L.rodataAlign=a;` records the maximum, and `L.rodata.resize(alignUp(...))` inserts the zero padding. |
| `writeObject()` | `const uint64_t rodataAlign=L.rodataAlign;`; `rodataOff=alignUp(...,rodataAlign)`; `sh[idxRodata].addralign=rodataAlign;`. With the default 1 both expressions are numerically identical to the old code. |
| `build-so` / `link-so` | `spec.rodataAlign=L.rodataAlign;` / `spec.rodataAlign=maxRodataAlign;`, with `maxRodataAlign` accumulated as `if(obj.rodataAlign>maxRodataAlign)…`. |
| `writeSharedObjectDyn()` | No longer hard-codes `addralign=1`. `if(spec.rodataAlign>1&&rodataVaddr%spec.rodataAlign)` throws `internal error: .rodata address is not aligned to its declared alignment`; `setSh(S_RODATA,…,spec.rodataAlign,0)` declares it. |

The default of `1` is the reason default alignment costs zero bytes:
`alignUp(x,1)==x` and `sh_addralign` was already `1`.

## 3. The nine-layer suite `tests/embed-align-checks.sh` [9/9]

| Layer | Evidence |
| --- | --- |
| [1/9] Strict build | `-Wall -Wextra -pedantic -Werror`, clean; version constant pinned |
| [2/9] Source guards | **26** guards covering every edit: the default, the comma branch, all three diagnostics, `unsignedLiteral`, the call into `embedFile`, its new signature, dedup-max, `g.align = align`, `rodataAlign` in both structs (count assertion = 2), layout recording, the `fromEmbed` ternary, `writeObject`'s aligned offset and header, both dyn forwarding sites, the merge maximum, the congruence check, the dyn `setSh`, and `parseObject` still reading it back. Both linkers' padding line is counted (assertion = 2). |
| [3/9] Refusals | **12** exact messages: `3`, `0`, `6`, `0x18` → power of two; `8192`, `65536` → 4096 ceiling; a variable, an empty argument, `-1` → non-literal; a third argument and a missing comma → `expected ')'`; `@embed_len(...,8)` → its own message. Three positive controls (`default`, `1`, `4096`) must still build. |
| [4/9] `build-obj` structure | Independent Python ELF reader (no `readelf` column parsing): `align=64`, `size=83`, `addr%align=0`, `off%align=0`; byte layout `head@0`, `tail@64`, `third@80`, all 63+14 padding bytes zero. Default and explicit `1` give `align=1, size=1`; `4096` gives `align=4096, size=1`. Both dedup spellings produce exactly **one** `__aster_embed_` symbol and `align=64`. |
| [5/9] Direct writers + qemu + C twin | `build-elf` / `build-pie` / `build-so` all declare `align=64`; `build-elf` and `build-pie` exit **215** under qemu; the gcc `-static` C twin also exits **215**; a 4096 request in an executable keeps its address congruent. |
| [6/9] Linkers | `link-obj` (one `@embed` object + one ordinary-string object, avoiding the pre-existing cross-object duplicate `__aster_embed_0` constraint) declares `align=64`, exits **215** under qemu; `link-so` declares `align=64`; a second link witness carries the merged maximum. |
| [7/9] Coverage | 62 assertions executed (floor 45), plus a **runtime** writer witness: `saw()` records the six writers actually invoked and all six must appear. A deleted layer leaves its string in a comment but cannot leave a `saw()` call. |
| [8/9] Mutations | **6**, each rebuilt under `-w` and caught: `g.align = 1`, layout `g.isString?1`, unaligned object offset, object header `addralign=1`, dyn header `addralign=1`, and dedup lowering the alignment. |
| [9/9] Byte baseline | The three `embed_align` rows reproduce exactly (output basename equals the baseline key, so `build-so`'s `.dynstr` name is stable); the previous release's 375 frozen rows are all present and identical. |

The shipped example is `examples/embed_align.ast` with three one-/two-/three-byte
assets and `tests/embed-align-twin.c` as the gcc oracle.

## 4. The `ET_REL` blind spot, closed

`tests/regression-symtab.sh` declares 11 `CASES`, but only 7 v0.16.0 fixtures
were ever committed. Its Python loop iterated `os.listdir(refdir)`, so
`so_math.so`, `so_rtinit.so`, `obj_globals.o` and `obj_array.o` were built and
then never compared — and both `ET_REL` products were among the missing four.

| Change | Evidence |
| --- | --- |
| `tests/baseline/symtab-frozen/` | Four new fixtures built by the current compiler, **explicitly labelled** as a v0.23.71-dev frozen snapshot. There is no v0.16.0 tag/commit in this repository, so they are not passed off as v0.16.0 images. |
| `frozen_invariants()` | ET_REL and ET_DYN products compared by section set, all section-header fields except `sh_offset` (a legitimate relayout may move bytes within the file), section content bytes, `.symtab`/`.strtab` presence, no `.debug_*`, and (for ET_DYN) the append-only `e_shoff ≥ p_offset+p_filesz` rule. Whole-file equality would be a tautology for a same-version snapshot. |
| Loop | Now iterates all eleven products and asserts `set(os.listdir(refdir)) == EXPECTED_FILES`; asserts every `CASES` product was built; asserts `passed == 11`; asserts `etrel >= 2`. |
| `--write-frozen` | New explicit refresh path, separate from `--write-fixtures`, so the two kinds of reference can never be confused. |

Standalone run: **11 products compared** — 7 against v0.16.0, 4 against the
frozen snapshot, `ET_REL branch executed 2 time(s)`. Two mutation probes:

- remove `obj_array.o` from the snapshot → `M1_EXIT=1`,
  `AssertionError: ('incomplete reference set', ['obj_array.o'], [])`;
- flip one `.text` byte in `obj_array.o` → `M2_EXIT=1`,
  `AssertionError: ('obj_array.o', 'section content changed', '.text')`.

Both guards therefore have teeth, and the historical "only 7 of 11 fixtures"
note in `ROADMAP.md` is now closed rather than merely recorded.

## 5. Zero byte drift

`tests/baseline/v0.23.71-dev/example-hashes.txt` is **378 rows**: the 375 rows
of v0.23.70-dev plus three `embed_align` rows.

| Check | Result |
| --- | --- |
| Independent recomputation of all 125 pre-existing examples × 3 modes, with the historical `address_of_abi` filter | `ROWS=375`, `ZERO_DRIFT_OK` |
| `alias-const-checks.sh` / `elf-metadata-checks.sh` | 378 rows reproduced, 375 pre-existing unchanged |
| 13 filtered suites | `294 → 297` pre-existing rows, FILTERs untouched |
| 2 full-baseline suites | `375 → 378` |

`build-so` hashes are recomputed with the output basename equal to the baseline
key, because that basename lands in `.dynstr` / the VERDEF BASE name.

## 6. Realignment and registration

| Item | Change |
| --- | --- |
| Version guards | 12 suites × 2 lines `0.23.70-dev → 0.23.71-dev`; historical comments in `union-checks.sh:5` and `version-checks.sh` left alone |
| Baseline row counts | 13 suites `294 → 297`, 2 suites `375 → 378`; `embed-align-checks.sh`'s `375` names the *previous* release and is deliberately unchanged |
| `tests/ci.sh` | `embed-align-checks.sh` added to both `CRITICAL` (18 → 19) and `DEFAULT_SUITES` (127 → 128) |
| `CMakeLists.txt` | `0.23.70 → 0.23.71` |
| Docs | `README.md`, `VERSION_HISTORY.md`, `FEATURE_STATUS.md`, `ARCHITECTURE.md`, `ROADMAP.md` (status line, version row, backlog close-out), `AUDIT-v0.23.61-dev.md`, `docs/language-reference.md` (attributes table + the previously truncated `@embed` paragraph completed) |
| `tests/version-checks.sh` | unchanged; its four status-line guards now check `0.23.71-dev` implicitly |
| `tests/embed-checks.sh` | its `no-dedup` mutation pinned the old single-line dedup early return; `embedFile()`'s hit branch grew a body this round, so the anchor now pins just the `embedBlobs.find(full)` lookup. All four mutations still build and are still noticed (standalone re-run PASS). This was the one **real** regression the first gate attempt exposed — the other three failures were OOM-killed `cc1plus` processes under 24-way parallelism, all three green when run alone. |
| `tests/mutation-score-checks.sh` | unchanged. Its `KILL` list enumerates the survivor-assertion wordings used by the independently-grown mutation helpers; the new suite's failing path now says `went unnoticed` so the aggregate census can see it. Census after registration: **32 suites / 200 mutants** (floors 24 / 150), 200/200 caught. |

## 7. Gate

`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc CI_JOBS=3 bash tests/ci.sh`

```
CI SUMMARY: 128 passed, 0 skipped, 0 failed (of 128 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
CI_EXIT=0
```

`CI_JOBS=3` is an isolation setting, not a different gate: `tests/ci.sh`
still runs all 128 suites and all three APK gates, each in its own copy of the
tree. It is used because the container's cgroup memory limit is 8 GiB and one
strict build of `src/aster.cpp` peaks at 610 MiB; the first attempt at 24-way
parallelism overlapped enough `cc1plus` processes to exceed that limit and
three suites failed with `g++: fatal error: Killed signal terminated program
cc1plus`. Each of those three is green both alone and in the 3-way run, so
they were OOM artefacts, not regressions. Peak RSS in the green run stayed at
~3.5 GiB.

That first attempt also exposed one **real** regression, now fixed:
`tests/embed-checks.sh`'s `no-dedup` mutation anchor pinned the old
single-line dedup early return, which this round replaced with a hit-side
body. Its four mutations still build and are still noticed. The second full
run (also 3-way, 128 suites) reported a single failure in
`mutation-score-checks.sh`: the new suite's survivor path said
`was not caught`, a wording the aggregate census did not recognise. The
wording is now `went unnoticed`, matching the census's `KILL` list without
loosening the gate; the census then reads 32 suites / 200 mutants, 200/200
caught. The third full run is the green result above.

`tests/version-checks.sh` (15 checks) and `tests/ci-protocol-checks.sh`
(33 checks, coverage ratchet 128 suites / 127 examples / 378 baseline rows /
42 mutation suites / no orphans) are green, as are the two mutation probes
and the two standalone suite re-runs recorded in §4 and §6.
