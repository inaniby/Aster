# tests/ — Aster 回归测试套件索引

本目录是 Aster 编译器的回归测试门禁。所有套件都从仓库根目录运行，
用 `sh` 写成（除特别注明外），断言失败即退出非零。

> 数字以实测为准（v0.23.82-dev，HEAD `449ad2a`）：
> `tests/ci.sh` 的 `DEFAULT_SUITES` 共 **153 个套件**；
> `tests/*.sh` 共 158 个文件，其中 6 个不是套件（见下）；
> 另有 76 个 `.c` 陪测/宿主文件、9 个 `.py` 辅助脚本、`tests/lib/` 下 6 个
> 共享库。`examples/*.ast` 共 132 个（见 `examples/README.md`），
> 当前基线 `tests/baseline/v0.23.82-dev/example-hashes.txt` 共 393 行
> （见 `tests/baseline/README.md`）。

## 运行方式

```sh
sh tests/ci.sh                                            # 全部门禁
CI_SUITES="tls-checks.sh linker-checks.sh" sh tests/ci.sh  # 只跑子集
sh tests/bool-checks.sh                                   # 单跑某套件（仓库根目录）
```

单跑套件时，套件自己负责编译编译器（一般是严格模式
`g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror src/aster.cpp`），
并把临时文件放在 `tmp-<套件名>` 下、退出时清理。`tests/ci.sh` 则只编译
一次，通过 `tests/lib/cxx-cache.sh` 把同一二进制交给各套件。

`tests/ci.sh` 支持的环境变量（以 `tests/ci.sh` 开头的注释为准）：

| 变量 | 含义 |
| --- | --- |
| `CI_SUITES` | 空格分隔的套件子集，覆盖 `DEFAULT_SUITES` |
| `CI_JOBS=N` | N 个套件并行跑，各自隔离在 worktree 里（默认 1） |
| `CI_OUT` | 日志/产物目录（默认 `ci-artifacts`） |
| `CI_SUITE_DIR` | 套件名相对的目录（默认 `tests`） |
| `CI_CRITICAL` | SKIP 即判失败的套件表（默认见 `ci.sh` 内的 `CRITICAL`） |
| `CI_ALLOW_MISSING=1` | 缺工具时不直接 exit 2，改由套件 SKIP（关键套件 SKIP 仍失败） |
| `CI_SKIP_APK_GATE=1` | 跳过三个独立 APK 门（无 `CI_ALLOW_APK_GATE_SKIP=1` 时判失败） |
| `CI_ALLOW_APK_GATE_SKIP=1` | 允许上述跳过，跳过会被记名 |
| `CI_KEEP_ARTIFACTS=1` | 绿了也保留日志 |
| `CI_REBUILD=1` | 无条件重编缓存的编译器 |
| `CXX`、`HOSTCC`、`RUNNER` | 编译器、宿主交叉编译器、qemu 前缀（默认 `tests/run-aarch64.sh`） |

## 断言（verdict）规矩

- 退出码 `0` = PASS，`77` = SKIP，**其它一律 FAIL**。
- SKIP 必须在日志里写一行 `SKIP: <原因>`；关键套件（`CRITICAL`）SKIP
  即整轮失败；没有原因的 `rc=77` 按 FAIL 计。
- 退出 0 但日志里没有任何 `PASS:`/`OK:` 行的套件叫 **NO EVIDENCE**——
  它什么都没断言，绿是假的；关键套件出现 NO EVIDENCE 直接判失败。
  每写一段断言就打印一行 `PASS:`/`OK:`，不要只在结尾报一次绿。
- 门禁另有**覆盖率棘轮**（`tests/ci-protocol-checks.sh` 末节，下限只升不降）：
  套件数 ≥ 121、示例数 ≥ 120、基线行数 ≥ 360、含 `mutant` 的变异套件 ≥ 30、
  无孤儿套件、无缺失套件。

## 套件索引（153 个，按主题分组）

### 1. 前端与语义（22 个）

测词法、语法、语义分析：类型检查、控制流、调用形式、拒绝矩阵。

`bool-checks.sh`、`callback-table-checks.sh`、`comment-checks.sh`、
`condition-checks.sh`、`diagnostics-checks.sh`、`discard-call-checks.sh`、
`enum-checks.sh`、`error-checks.sh`、`eval-order-checks.sh`、
`for-loop-checks.sh`、`front-sema-checks.sh`、`function-return-fn-checks.sh`、
`function-type-checks.sh`、`indirect-call-checks.sh`、
`lang-completion-checks.sh`、`operator-checks.sh`、`precedence-checks.sh`、
`sema-checks.sh`、`static-checks.sh`、`switch-checks.sh`、
`syntax-relief-checks.sh`、`type-strictness-checks.sh`

### 2. 类型、字面量与数值（14 个）

测整数宽度、符号性、常量折叠、浮点字面量、宽整数。

`char-checks.sh`、`const-fold-u64-checks.sh`、`f64-short-circuit-checks.sh`、
`float-literal-checks.sh`、`integer-cast-checks.sh`、
`cast-conversions-checks.sh`、`literals-checks.sh`、`signedness-checks.sh`、
`sizeof-len-checks.sh`、`u64-literal-compare-checks.sh`、`union-checks.sh`、
`void-checks.sh`、`wide-int-checks.sh`、`wide-int-literal-checks.sh`

### 3. 内存、数组、结构与全局量（23 个）

测寻址、越界、帧布局、窄整数的内存表示、线程局部存储。

`address-of-checks.sh`、`array-address-checks.sh`、
`array-bounds-checks.sh`、`array-elem-types-checks.sh`、
`array-param-bounds-checks.sh`、`global-checks.sh`、
`global-deep-checks.sh`、`heap-checks.sh`、`layout-boundary-checks.sh`、
`local-array-checks.sh`、`multi-dim-array-checks.sh`、
`narrow-int-abi-checks.sh`、`narrow-memory-checks.sh`、
`narrow-value-coverage.sh`、`null-ptr-checks.sh`、
`pointer-difference-checks.sh`、`pointer-index-checks.sh`、
`runtime-bounds-checks.sh`、`stack-arg-abi-checks.sh`、
`stride-scale-checks.sh`、`struct-checks.sh`、
`struct-array-field-checks.sh`、`tls-checks.sh`

### 4. 链接器、ELF、符号表与目标文件（20 个）

测产物结构：节表追加、符号表、RELRO、GNU hash、`@embed` 对齐、页大小。

`alias-const-checks.sh`、`elf-metadata-checks.sh`、`embed-checks.sh`、
`embed-align-checks.sh`、`frame-size-checks.sh`、
`frame-slot-contract-checks.sh`、`gnu-hash-checks.sh`、`include-checks.sh`、
`linker-checks.sh`、`link-project-contract-checks.sh`、`object-checks.sh`、
`page-size-checks.sh`、`pie-so-checks.sh`、`relro-checks.sh`、
`resource-table-checks.sh`、`section-align-contract-checks.sh`、
`symtab-checks.sh`、`regression-symtab.sh`、`symbol-versioning-checks.sh`、
`write-output-checks.sh`

其中 `regression-symtab.sh` 是 v0.17.0 回归证明：加符号表不得改变加载器
与运行程序看到的任何东西，对照物是 `tests/baseline/v0.16.0/` 下冻结的
7 个 ELF（见 `tests/baseline/README.md`）。

### 5. 共享对象与动态链接（6 个）

测 `.so` 的参数传递、依赖链、作用域、缺失依赖/符号、生命周期回调。

`so-argument-checks.sh`、`so-dependency-chain-checks.sh`、`so-dyn-checks.sh`、
`so-negative-checks.sh`、`so-scope-checks.sh`、`lifecycle-callbacks.sh`

### 6. 标准库与运行时（10 个）

测内置库（map/str/io 等三批 stdlib）与运行时系统调用。

`float-checks.sh`、`library-core-checks.sh`、`stdlib-checks.sh`、
`stdlib-io-checks.sh`、`stdlib-map-checks.sh`、`stdlib-str-checks.sh`、
`stdlib2-checks.sh`、`stdlib3-checks.sh`、`string-symbol-checks.sh`、
`syscall-io-checks.sh`

### 7. 端到端 qemu 执行（25 个）

在 qemu-user 下把产物真正跑起来，并与宿主 C 编译的对照程序（twin）
比对输出；`e2e-c-*` 覆盖 C ABI 的各个调用形状。

`e2e-c-abi-32-args.sh`、`e2e-c-abi-32-external.sh`、`e2e-c-abi.sh`、
`e2e-c-address-of.sh`、`e2e-c-libc-strings.sh`、`e2e-c-mixed-ptr-stack.sh`、
`e2e-c-multi-object-rodata.sh`、`e2e-c-ptr-arithmetic.sh`、
`e2e-c-ptr-difference.sh`、`e2e-c-ptr-index.sh`、`e2e-c-ptr-memory.sh`、
`e2e-c-ptr-u8.sh`、`e2e-c-ptr.sh`、`e2e-c-string-literals.sh`、
`e2e-c-struct.sh`、`e2e-global-deep.sh`、`e2e-pie-so.sh`、`e2e-relro.sh`、
`e2e-so-dependency-chain.sh`、`e2e-so-dependency-failure.sh`、
`e2e-so-dependency-lifecycle.sh`、`e2e-so-import.sh`、`e2e-so-negative.sh`、
`e2e-so-scope.sh`、`e2e-symtab.sh`

### 8. C ABI 结构化对照（11 个）

不跑 qemu 时的结构对照：与宿主 C 编译器比调用约定、内存布局与字符串
处理；是第 7 组 `e2e-c-*` 的静态搭档。

`c-abi-32-args-structural.sh`、`c-abi-32-external-structural.sh`、
`c-abi-structural.sh`、`c-libc-strings-structural.sh`、
`c-mixed-ptr-stack-structural.sh`、`c-multi-object-rodata-structural.sh`、
`c-ptr-arithmetic-structural.sh`、`c-ptr-memory-structural.sh`、
`c-ptr-structural.sh`、`c-ptr-u8-structural.sh`、
`c-string-literals-structural.sh`

### 9. APK、UI 与设备（7 个）

测 APK 打包、签名、图标、触摸与像素偏移；`ui-checks.sh` 是
`stdlib/asterui` 子模块自带的套件（门禁里唯一的仓外套件）。

`apk-checks.sh`、`icon-checks.sh`、`icon-text-demo-checks.sh`、
`pixel-offset-checks.sh`、`signing-checks.sh`、`touch-checks.sh`、
`../stdlib/asterui/tests/ui-checks.sh`

### 10. 项目、缓存与自举（2 个）

`project-checks.sh` 测 `aster.proj` 工程模式与 `aster build`；
`bootstrap-loop-checks.sh` 测编译器自举闭环（用 Aster 编 Aster）。

### 11. 调试信息与异常帧（3 个）

`debug-info-checks.sh`、`debugline-checks.sh`、`eh-frame-checks.sh`——
DWARF 行号与 `.eh_frame`。

### 12. 门禁、基线与变异（10 个）

测门禁本身：孤儿套件、覆盖率棘轮、差分测试、变异评分、消毒器、版本号。

`ci-protocol-checks.sh`、`compiler-other-faces-audit.sh`、
`coverage-checks.sh`、`difftest-checks.sh`、`fuzz-checks.sh`、
`mutation-score-checks.sh`、`sanitizer-checks.sh`、`version-checks.sh`、
`typedir-mutation.sh`、`codegen-checks.sh`

## 不是套件的 6 个 `.sh` 文件

`tests/ci-protocol-checks.sh` 用显式 allowlist 管理它们，每条都有理由；
新脚本要么注册进 `DEFAULT_SUITES`，要么在这里声明理由，否则判孤儿。

| 文件 | 为什么不是套件 |
| --- | --- |
| `ci.sh` | 门禁 runner 本身 |
| `run-aarch64.sh` | 套件用的 qemu 前缀 |
| `run-on-device.sh` | 只在真机（或完整 qemu sysroot）上跑，CI 没有动态链接器/dlopen 环境 |
| `smoke.sh` | 开发者驱动：编编译器、查 20 个示例的 ELF 头、再调一长串已注册套件；在 CI 里跑等于把套件跑两遍；门禁断言它调的套件全部已注册 |
| `host-toolchain-probe.sh`、`guest-libc-alias.sh` | 被 e2e 套件 source 的库 |

## 新增套件的规矩

1. **注册**：把套件名加进 `tests/ci.sh` 的 `DEFAULT_SUITES`。不注册就是
   孤儿，`ci-protocol-checks.sh` 会让门禁变红。只有“本身不是套件”的脚本
   才能进 allowlist，且须在 `ci-protocol-checks.sh` 里写清理由。
   驱动脚本（像 `smoke.sh`）可以不注册，但它调用的每个套件必须已注册，
   门禁会断言这一点。
2. **断言要留痕**：每段断言打印 `PASS:`/`OK:` 行；只在结尾报一次绿、
   中间零断言的套件会被判 NO EVIDENCE。跑不起来时退出 `77` 并在日志里
   写 `SKIP: <原因>`；不要 exit 0 假装通过。
3. **基线不许写死路径**：需要冻结基线时 source `tests/lib/baseline.sh`，
   用 `aster_baseline_file` 定位当前版本的
   `tests/baseline/v<版本>/example-hashes.txt`。套件里出现字面量的
   `tests/baseline/v[0-9].../example-hashes.txt` 会被门禁判失败。
   基线重录规矩见 `tests/baseline/README.md`。
4. **变异要能被抓住**：凡是断言“编译器必须拒绝/必须保持某结构”的地方，
   配套写一个 mutant 探针——把源码改坏一处，看套件是否变红
   （`mutation-score-checks.sh` 统计含 `mutant` 的套件数，下限 30）。
   只报绿、抓不住变异的套件等于没测。
5. **自包含**：开头 `cd "$(dirname "$0")/.."` 回到仓库根；临时文件放
   `tmp-<套件名>` 并 `trap` 清理；不要依赖别的套件先跑、不要写仓库外。
6. **命名**：套件叫 `<主题>-checks.sh`；纯端到端执行叫 `e2e-<主题>.sh`；
   静态结构对照叫 `<主题>-structural.sh`。名字进 `DEFAULT_SUITES` 后
   就是门禁日志里的名字，保持稳定。

## 配套文件

- `tests/lib/`：共享库——`baseline.sh`（冻结基线定位与校验）、
  `cxx-cache.sh`（门禁内编译器缓存）、`linkmode.sh`、`tmpdir.sh`、
  `tools.sh`、`verdict.sh`。
- `tests/*.py`：辅助脚本——`validate_apk.py`（APK 校验）、`fuzz-gen.py` /
  `fuzz-bin.py`（模糊测试）、`debuginfo-decode.py` / `debugline-decode.py` /
  `ehframe-decode.py`（调试信息解码）、`apk-semantic-mutate.py` /
  `bounds-mutate.py` / `proj-meta-mutate.py`（变异探针）。
- `tests/*.c`：76 个陪测/宿主文件——`*-twin.c` 是与 `.ast` 示例对照的
  C 程序，`*-host.c` 是 e2e 套件用的宿主侧代码。
- `tests/audit-evidence/`：审计证据夹具（按版本分子目录）。
- `tests/baseline/`：冻结基线与历史 ELF 夹具，见 `tests/baseline/README.md`。
