# tests/baseline/ — 冻结基线与历史夹具

本目录放两类冻结物：**每版的字节基线**（`v<版本>/example-hashes.txt`）
和**历史 ELF 夹具**（`v0.16.0/`、`symtab-frozen/`）。它们是门禁的
对照物，不是缓存：删了、改了，门禁就按失败算。

规则的权威来源是 `tests/lib/baseline.sh` 开头的注释（第 8 行
“snapshots are immutable; a new release starts by copying the newest one”，
第 17 行示例 `cp tests/baseline/v<previous>/example-hashes.txt
tests/baseline/v<version>/`，第 112 行版本升级须另建快照并有意重录）。
本文只转述，不另立规矩；冲突时以 `tests/lib/baseline.sh` 为准。

## 基线文件格式

每版一个目录，里面一个 `example-hashes.txt`，一行一个产品：

```text
<示例名>.<模式> <sha256 | FAILED>
```

模式三种（键里空格写成下划线）：`build-so`、`build-elf`、
`build-obj_--pic`。`FAILED` 表示该模式编不出这个示例。
当前版（v0.23.82-dev）共 393 行：132 个示例 × 3 个模式，减去
`address_of_abi` 被排除的 3 行（见 `examples/README.md`）。

定位与校验由 `tests/lib/baseline.sh` 负责：

- `aster_baseline_version`——从 `src/aster.cpp` 的
  `ASTER_VERSION_STRING` 读当前版本，版本是编译器的单一事实来源。
- `aster_baseline_file`——打印该版本的基线文件路径；**版本升了但没有
  对应快照，是硬失败**，绝不会悄悄拿上一版的比。
- `aster_baseline_check`——校验文件形状：每行恰好两列、模式合法、
  值是 `FAILED` 或 64 位十六进制摘要、无重复键、每行指的示例仍然存在
  （`examples/<名>.ast`）。

44 个套件 source 这个库并逐行比对；`tests/difftest-checks.sh` 还会
断言总行数（当前 393 行）。

## 铁律：快照不可原地改

- **旧快照是历史，一字节都不许动。** 想改某行的值，说明这一轮有意
  改变了那个产品的字节——改动只能落在**新版本的快照**里，并附上理由。
- **新版本先复制最新一份，再重录。** 不要从空文件起手，不要从旧版
  挑行拼：
  ```sh
  mkdir -p tests/baseline/v<新版本>
  cp tests/baseline/v<上一版本>/example-hashes.txt tests/baseline/v<新版本>/
  ```
- **只改本轮动到的行。** 其它行必须与上一版逐字节相同；门禁里多个套件
  会拿上一版快照逐行比对，动了不该动的行就失败（`build-so` 行除外——
  v0.23.77-dev 的 A-16 修复停掉了本不存在的 `DT_VERNEED` 声明，改了全部
  `.so` 的字节，这是已记录的修复，不是漂移；另有 `embed_align`、
  `icon_text_demo`、`lifecycle` 三个 `.build-obj_--pic` 行在 v0.23.81-dev
  被有意重钉，理由见 `tests/alias-const-checks.sh` 的 `[9/9]` 节注释）。
- 套件里**不许写死带版本号的基线路径**（`tests/ci-protocol-checks.sh`
  会 grep 全体套件并判失败）；一律用 `aster_baseline_file` 定位。

## 重录方法

没有“一键重录全部”的命令——重录就是重新算出本轮动到的行的值，
其余行保持复制来的原值。算一行的方法与各套件的 `[字节基线]` 节相同
（以 `tests/alias-const-checks.sh` 的 `[9/9]` 节为准）：

```sh
# 以 <示例> 的 build-elf 行为例；build-so 与 build-obj --pic 同理，
# 键里的模式空格写成下划线（build-obj_--pic）。
./aster build-elf examples/<示例>.ast -o /tmp/<示例>.build-elf
sha256sum /tmp/<示例>.build-elf | cut -d' ' -f1
# 编不出来时该行记 FAILED，而不是删行。
```

全量复核（改完快照后必跑，确认整文件仍能逐行复现）：

```sh
sh tests/difftest-checks.sh     # 断言总行数（当前 393）与基线复现
sh tests/alias-const-checks.sh  # [9/9] 节：全量复现 + 上一版未动行比对
sh tests/ci-protocol-checks.sh  # 覆盖率棘轮：基线行数下限 360，无孤儿套件
```

以及任何本轮动到的示例所属的套件。提交前 `git diff` 看一眼：
diff 里只能出现本轮有意改动（或新增示例带来）的行。

## 当前快照一览

| 目录 | 内容 |
| --- | --- |
| `v0.16.0/` | 7 个 ELF 夹具（无 `example-hashes.txt`），见下节 |
| `v0.23.61-dev/` – `v0.23.66-dev/` | 各 360 行 |
| `v0.23.67-dev/` | 366 行 |
| `v0.23.68-dev/` | 369 行 |
| `v0.23.69-dev/` | 372 行 |
| `v0.23.70-dev/` | 375 行 |
| `v0.23.71-dev/` – `v0.23.72-dev/` | 各 378 行 |
| `v0.23.73-dev/` | 384 行 |
| `v0.23.74-dev/` | 390 行 |
| `v0.23.75-dev/` – `v0.23.79-dev`、`v0.23.82-dev` | 各 393 行 |
| `symtab-frozen/` | 4 个文件，见下节 |

（行数以 `wc -l` 实测为准；v0.23.80-dev 与 v0.23.81-dev 没有快照目录。）

## `v0.16.0/`：7 个无后缀 ELF 夹具

### 它们是什么

| 文件 | `file(1)` 的识别结果 |
| --- | --- |
| `exec_plain`、`exec_globals`、`exec_align`、`exec_rtinit`、`link_multi` | ELF 64-bit LSB executable, ARM aarch64, 静态链接，**无节头**（`e_shoff = e_shnum = e_shstrndx = 0`） |
| `pie_plain`、`pie_globals` | ELF 64-bit LSB shared object, ARM aarch64, 静态链接，无节头 |

这是 v0.16.0 编译器的真实产物：v0.16.0 写产物时不写节头表，
v0.17.0 才加上 `.symtab`/`.strtab` 与节头表。5 个可执行文件来自
`build-elf`（`link_multi` 来自 `link-obj`），2 个静态 PIE 来自
`build-pie`。

### 谁在用

只有 **`tests/regression-symtab.sh`**（v0.17.0 回归证明）按现名引用它们：
`CASES` 里的 11 个产品中这 7 个取这里的夹具作对照，另 4 个
（`so_math.so`、`so_rtinit.so`、`obj_globals.o`、`obj_array.o`）的
v0.16.0 夹具从未提交，改用 `symtab-frozen/` 里明确标注的
v0.23.71-dev 冻结快照。仓库里没有 v0.16.0 的 tag 或 commit，
这 7 个文件是唯一能证明“v0.16.0 产出过什么”的东西，删不得、改不得。

### 为什么没有 `.elf` 后缀——有意为之，不补

- **文件名就是 v0.16.0 编译器写出时的 `-o` 路径。** 套件的 `build_case`
  以 `"$a" build-elf examples/hello.ast -o "$d/exec_plain"` 这种形式
  调用编译器，夹具名与构建命令一一对应；改名等于改写历史记录。
- **重生成会把它改回来。** 套件支持
  `ASTER_V16_DIR=/path/to/aster-v0.16.0 sh tests/regression-symtab.sh
  --write-fixtures` 从真正的 v0.16.0 编译器重建夹具，
  重建出来的仍是无后缀名——加后缀会在下一次重生成时悄悄失效，
  或在目录里留下一份陈旧的 `.elf` 副本。
- **同目录的另一组夹具证明了命名规矩**：`symtab-frozen/` 里的
  `so_math.so`、`so_rtinit.so`、`obj_globals.o`、`obj_array.o` 带后缀，
  是因为构建它们的命令本来就给了带后缀的 `-o` 路径。规矩是
  “名从构建命令来”，不是“按类型加后缀”。
- **没有工具依赖后缀**：套件按确切文件名读取（`EXPECTED_FILES` 集合）、
  按通配符复制（`cp "$FIXTURE_DIR"/*`），`file(1)` 不靠后缀识别 ELF。
  加后缀除了多改一处外没有任何收益。

所以这 7 个文件保持无后缀；**不要给它们改名，不要改它们的内容**。
需要确认类型时用 `file tests/baseline/v0.16.0/*`。

### `symtab-frozen/` 是什么

v0.23.71-dev 的冻结快照，4 个文件（`so_math.so`、`so_rtinit.so`、
`obj_globals.o`、`obj_array.o`），由当前编译器构建、专供
`tests/regression-symtab.sh` 的 `ET_REL` 分支与 `.so` 形状断言用。
它**不是** v0.16.0 产物，绝不伪装成 v0.16.0 产物；只有当有意的
`ET_REL`/`.so` 形状变更落地时才用
`sh tests/regression-symtab.sh --write-frozen` 刷新。
