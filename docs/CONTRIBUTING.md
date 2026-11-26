# Contributing to Aster

Aster is a self-hosting compiler for AArch64, written as a single C++17
file (`src/aster.cpp`, zero dependencies) plus a bootstrap compiler written
in Aster itself (`bootstrap/aster.ast`). Contributions are welcome — the
rules below are what keep a one-file compiler reviewable.

## One version, one theme

Work lands one version at a time, one coherent theme per version. A version
moves in three batches, in this order:

1. **impl** — the compiler change, plus the version identity move:
   `ASTER_VERSION_STRING` in `src/aster.cpp` and the CMake project version.
   Every hard version guard in the tests (`grep -qF '#define
   ASTER_VERSION_STRING ...'`) is re-pinned in the same batch.
2. **tests** — a resident suite for the change, registered in
   `tests/ci.sh` (`DEFAULT_SUITES` and, for contract suites, `CRITICAL`).
3. **docs** — the audit/validation notes and any user-facing doc updates.

Do not mix a new feature into a fix version, and do not change the version
string outside an impl batch.

## The 9-layer resident suite

Every resident suite follows the same nine layers (see
`validations/VALIDATION-v0.23.79-dev.md` §4 for a worked example):

1. Strict `-Werror` build and the version guard.
2. Python source guards pinning the exact lines the fix touches.
3. A static oracle — preferably pure Python, not binutils as primary judge.
4. A behavioural matrix: accepted side and every refusal, each with its
   exact diagnostic.
5. A C oracle (gcc / `aarch64-linux-gnu-gcc`) where the answer is
   independently computable.
6. Every ELF writer the change can reach (`build-elf`, `build-pie`,
   `build-obj`, `build-so`, `link-obj`, `link-pie`, `link-so`), plus `-g`
   and `--bounds-check` where relevant.
7. A coverage census with a floor.
8. Mutations: removing the fix must be caught by the suite.
9. The byte baseline: zero drift against `tests/baseline/`, all rows
   reproduced.

A fix without layers 4, 8 and 9 is not done. A suite that exits 0 without
printing a `PASS`/`OK` line fails the gate — the verdict is about evidence,
not just about failures.

## Cross-host discipline

- AArch64 products run through `tests/run-aarch64.sh` (`$RUNNER`): native
  on AArch64, under `qemu-aarch64` elsewhere. Never assume the host CPU.
- C oracles go through `$HOSTCC` (`aarch64-linux-gnu-gcc` when present).
- Scratch space comes from `tests/lib/tmpdir.sh` (`$TMPD`), never a fixed
  `/tmp` path — suites run in parallel in isolated worktrees.

## Building and testing

```sh
# Strict build (the only accepted build)
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster

# Host prerequisites (Ubuntu 24.04)
apt-get update -o Acquire::Languages=none
apt-get install -y --no-install-recommends qemu-user gcc-aarch64-linux-gnu \
  binutils-aarch64-linux-gnu llvm-18 openjdk-21-jre-headless file shellcheck \
  libc6-dev-arm64-cross
# llvm tools are used by their un-suffixed names:
ln -sf /usr/bin/llvm-objdump-18 /usr/local/bin/llvm-objdump
ln -sf /usr/bin/llvm-dwarfdump-18 /usr/local/bin/llvm-dwarfdump
ln -sf /usr/bin/llvm-readelf-18 /usr/local/bin/llvm-readelf
ln -sf /usr/bin/llvm-nm-18 /usr/local/bin/llvm-nm

aster doctor          # expect 13 ok, 0 warnings
sh tests/ci.sh        # the full gate: 152 suites + 3 APK gates
```

Run the full gate before submitting. A focused run is fine while iterating
(`CI_SUITES="frame-size-checks.sh" sh tests/ci.sh`), but the final check
is the whole gate, unskipped (`CI_SKIP_APK_GATE=1` needs
`CI_ALLOW_APK_GATE_SKIP=1`, and the skip is then deliberate and visible).

## Reporting a defect

Open an issue with:

- A minimal `.ast` reproducer (or ELF/APK input) and the exact command.
- Expected vs. actual behaviour, with exit codes.
- A control case: the same program with the suspect feature removed, or
  the gcc C oracle's answer, so the report shows the defect and not just
  a surprise.
- The output of `aster doctor` and `aster --version`.

Security-sensitive reports (silent miscompilation, linker memory safety,
APK verification) follow `SECURITY.md` — do not open a public issue for
those.

## What not to change casually

- `src/aster.cpp` is one file on purpose. Do not split it, and do not add
  a dependency, without a design discussion first.
- The frozen byte baseline (`tests/baseline/`) is a contract: a change
  that moves any row needs the row re-recorded deliberately, with the
  reason written down — never silently.
- The bootstrap (`bootstrap/aster.ast`) and its twin
  (`tests/codegen-twin.c`) must change together; a fix in one without the
  other is how a shared bug stays invisible to the gate.
- Do not pick a license. The project has none yet; that decision belongs
  to the maintainer.

## 发版仪式 (release ritual)

A release bump is mechanical positions plus human narrative — never the
other way round. `tests/bump-version.sh` moves only the mechanical
positions; it writes no prose. Follow the steps in order:

1. 跑全量门禁：`sh tests/ci.sh` 全绿且不跳过 APK 门——发版只给已验证的树升版。
2. 人工写叙事：在 `VERSION_HISTORY.md` 顶部加新版本条目，并写出
   `VALIDATION-v<新版>.md`（本轮改了什么、证据在哪里）；发版脚本不生成
   这些文字，`tests/bump-version.sh` 跑完也会再提醒一次去哪里写。
3. 先 `--dry-run` 核对：`sh tests/bump-version.sh --dry-run <新版> "<一句话摘要>"`，
   逐项对改动清单——4 处版本位置、21 个套件守卫钉、1 份新基线——确认无多余项。
4. 正式跑脚本：`sh tests/bump-version.sh <新版> "<一句话摘要>"`；脚本每处只改
   一处（多改或零改都会报错退出），并从最新基线复制出
   `tests/baseline/v<新版>/example-hashes.txt`，校验行数一致且逐字节相同。
5. 核对 diff：`git status` / `git diff` 逐项对照 a53ca33 的 26 文件清单
   （`src/aster.cpp`、`CMakeLists.txt`、`README.md` 标题、
   `docs/language-reference.md` 的 "Applies to"、21 个套件、新基线），
   确认版本号已是新版、没有其他文件被改动。
6. 严格重编并跑版本检查：`g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp -o aster`，
   再跑 `sh tests/version-checks.sh`——它还要求第 2 步的叙事文件就位
   （`VALIDATION-v<新版>.md` 与 `VERSION_HISTORY.md` 顶部条目），缺了就会失败。
7. 跑发版脚本自检：`sh tests/bump-version.sh selftest`——它把工作树复制到
   `/tmp` 的临时目录，在副本里升到假版本 0.23.99-dev，核对 21 个守卫钉与
   新基线（393 行），工作树本身不被升版。
8. 提交推送：`git commit -m "Bump version to v<新版>"`（正文放第 3 步那句摘要），
   然后 push；不要把自检用的假版本留在任何地方。
