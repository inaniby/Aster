# Validation — v0.23.16-dev

**The e2e suite runs on the development machine too: 23 checks stop silently
skipping.**

This release changes no code generation. It changes what the test suite is
allowed to claim. On the machine where Aster is actually developed (x86_64),
`ci.sh` used to report `49 passed, 23 skipped, 0 failed` — and the 23 skipped
checks were not a random sample: they were the C-ABI interop suites, the ones
that prove Aster's calling convention against a real C compiler. A codegen
change could break them and CI would still be green, because CI never ran them.
This release makes the host architecture irrelevant to whether a check runs.

---

## 1. The defect: "skip" was hiding the ABI layer

The e2e suites compile a C harness, link it against Aster's output, and run the
result — the only place where Aster's AAPCS64 conformance is checked against an
independent implementation. `ci.sh` chose the C compiler with "what can execute
on this machine":

```
# before
ARCH=$(uname -m)
if [ -n "${HOSTCC:-}" ]; then ...
elif [ "$ARCH" = aarch64 ] || [ "$ARCH" = arm64 ]; then HOSTCC=cc
else HOSTCC=cc   # and then the suites SKIP: not the target architecture
fi
```

On x86 the probe concluded "this host cannot run AArch64 guests" and 22
`e2e-*` suites plus `icon-text-demo-checks.sh` reported SKIP. The skip was
honest reporting, but the conclusion was wrong: the ability to *execute* an
AArch64 binary is not a property of the host, it is a property of the router —
and `tests/run-aarch64.sh` already had it.

| | v0.23.15-dev | v0.23.16-dev |
|---|---|---|
| passed | 49 | **72** |
| skipped | **23** | 0 |
| failed | 0 | 0 |
| host | x86_64 | x86_64 (same machine) |

The middle column is the whole point: 23 checks moved from "did not run" to
"ran and asserted".

## 2. The change: the contract is the target, not the machine

`ci.sh` now selects a cross-compiler whenever one exists, on any host:

```sh
if [ -n "${HOSTCC:-}" ]; then
    : # caller-supplied
elif command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then
    HOSTCC=aarch64-linux-gnu-gcc
else
    HOSTCC=cc
fi
```

A test host is compiled **for the target architecture** and executed through
`tests/run-aarch64.sh`, which already routed correctly (native on AArch64,
`qemu-aarch64 -L /usr/aarch64-linux-gnu` elsewhere). What was missing was
universal use: 11 of the 22 `e2e-*` suites invoked the host binary directly.
Each now carries the convention the other 11 already used:

```sh
RUNNER=${RUNNER:-tests/run-aarch64.sh}
run() { $RUNNER "$@"; }
```

and every host invocation goes through `run`.

**Proof that the router is really executing, not skipping.** A trivial AArch64
binary on this x86_64 machine:

```
$ /tmp/g2.a64                                  # direct
exec format error                              # exit 126
$ tests/run-aarch64.sh /tmp/g2.a64             # via router
guest ran: sizeof(long)=8                      # exit 7 propagated correctly
```

The exit status comes back too, which is what every e2e assertion reads.

## 3. The one real bug it uncovered: `libc.so` is a linker script here

Four suites died immediately once they started running:

```
dlopen: /lib/libc.so: invalid ELF header
```

Aster emits the **Android** spelling `libc.so` in `DT_NEEDED` — correct on a
device, where Bionic provides it. On a glibc host, `/usr/aarch64-linux-gnu/lib/libc.so`
is a **linker script** (`GROUP ( /lib/libc.so.6 … )`), not an ELF image, so the
guest loader rejects it.

**The first fix was wrong, and it is worth recording why.** Rewriting the
spelling to the host's real `libc.so.6` (`-print-file-name=libc.so.6`, passed as
`--needed`) did *not* work: `ndkLibraryFor` adds its own `libc.so` entry for
libc imports regardless, so the object ended up with **two** `DT_NEEDED`
entries and still failed. It also had a deeper problem — it would have tested a
different `.so` than the one that ships, which is exactly what a byte-identity
discipline exists to prevent.

**The fix that works touches neither the compiler nor the emitted bytes.**
`tests/guest-libc-alias.sh` — the symlink farm `touch-checks.sh` already used to
satisfy the same Android spelling for `libm.so` under qemu — is now sourced by
five suites (`e2e-c-abi`, `e2e-c-abi-32-external`, `e2e-c-libc-strings`,
`e2e-c-multi-object-rodata`, `e2e-c-string-literals`):

```sh
. tests/guest-libc-alias.sh
provide_guest_libc_alias "$OUT"
ABS_OUT=$(cd "$OUT" && pwd)
LD_LIBRARY_PATH="$ABS_OUT${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH
```

The guest asks for `libc.so` and the loader finds a real ELF under that name.
On a device the aliased paths do not exist, so the farm is a no-op — the `.so`
stays byte-identical to what ships.

## 4. What the now-running suites actually assert

Not "it linked" — real values, computed by executing the guest:

```
e2e-c-abi.sh
  aster_abs(-42)=42   aster_abs(7)=7
  aster_sum8(1..8)=36
  aster_mix8(80,7,6,5,4,3,2,1)=76
  aster_sum12(1..12)=78
  aster_mix12(100,9,8,7,6,5,4,3,2,1,10,11)=94
  aster_call_sum12()=78
  PASS: C -> Aster i32 exports and Aster -> Aster 12-argument stack call
  PASS: Aster -> Android libc abs(int)

e2e-c-libc-strings.sh
  strlen=16  memcmp_equal=0  memcmp_different=1
  PASS: C -> Aster -> Bionic strlen/memcmp with pointer arguments

icon-text-demo-checks.sh
  androguard resolves 4 resources (drawable/ic_launcher, string/app_name, …)
  PASS: APK validated, v1 + v2 verified, assets packaged, name in manifest + table
```

`e2e-c-abi` alone covers 8-argument and 12-argument calls, stack spill, an
Aster→Aster call through the stack, and an Aster→libc import — all of it now
executed on every host.

## 5. Byte identity: two independent witnesses

The version string reaches stdout and the APK JAR manifest; it is embedded in no
ELF, `.so` or `.o` Aster emits. Nothing else in the source changed.

| witness | result |
|---|---|
| `tests/baseline/v0.23.5-dev/example-hashes.txt` (261 lines, asserted by `struct-checks.sh` [4/8]) | **261/261 reproduced byte for byte** |
| direct A/B, v0.23.15 compiler vs v0.23.16, 3 modes over every example | **212/212 byte-identical** (40/40 `build-elf`, 86/86 `build-obj`, 86/86 `build-so`) |

## 6. Cost

`ci.sh` went from ~8 minutes to **27 minutes** on x86_64. That is the real price
of running 23 suites under qemu-user instead of reporting them as skipped, and
it is the reason this was worth a release of its own rather than a footnote.

## 7. What this is for

The compiler gap analysis (see `Aster编译器缺口分析与完善计划-v0.23.16.md`) ranks
the missing operators first: `%`, `<<`/`>>`, `&`/`|`/`^`/`~`, compound
assignment, `++`/`--`, `?:`. All of them land in the arithmetic codegen path —
`SDIV`+`MSUB`, `LSL`/`LSR`/`ASR`, `AND`/`ORR`/`EOR`/`ORN`, register allocation,
the i64 ABI. Before this release, changing any of that on the development
machine meant editing the C-ABI layer with its regression suite switched off.
Now each operator can ship with the Aster side executed under qemu **and** the C
side as a differential oracle, in the same run.

## 8. Verification log

```
strict build: g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror  ->  clean
ci.sh (run 1, docs not yet synced): 71 passed, 0 skipped, 1 failed
    FAILED: version-checks.sh   <- demanded VALIDATION-v0.23.16-dev.md
ci.sh (run 2, after docs):       72 passed, 0 skipped, 0 failed
APK gate: native_render, icon_text_demo, native_touch  ->  3/3 PASS
A/B: 212/212 byte-identical; 261-line baseline reproduced
```

Run 1's single failure is a gate doing its job: `version-checks.sh` refuses to
let a version ship without its documentation. It is recorded rather than
quietly re-run away.
