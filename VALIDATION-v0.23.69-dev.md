# 验收报告 — v0.23.69-dev（`char` 无符号 8 位类型）

## 1. 审计诉求

`AUDIT-v0.23.61-dev.md` 第三部分「语言层面的缺口」Top5 按性价比排序为
`typedef`(1)、`const`(2)、`void`(3)、`char`(4)、`union`(5)，要求依次关闭。
v0.23.67-dev 关闭前两项、v0.23.68-dev 关闭第三项、本轮关闭第四项 **`char`**，
仅剩 `union` 排队。

## 2. 本轮交付

- **`char` 作为独立的无符号 8 位类型**：编译器新增 `Ty::Char`（插在
  `Ty::Kind` 枚举 `Void` 之前）；其关键字是 `char`（`TK::CharType`），**刻意与**
  `Char` **字面量 token**（`TK::Char`，`'a'` 自 v0.23.50-dev 折叠为 `i32` 常量）分开。
- **复用 `u8` 全部机**：`tySize`/`tyAlign` 答 1，`tyIsInteger`/`tyIsUnsigned` 纳入它，
  `initializerFits`/`caseValueFits` 把它约束到 0..255，`castConstValue` 经
  `uint8_t` 截断，且所有 `== Ty::U8` 的代码生成宽度点（共 12+ 处：var/global/stack
  的 load-store 对、非缩放偏移守卫、`LDRB W16` 加载、`gen()` 内的 `UXTB`、
  `loadBaseT` ×2、返回处的 `retTy`）也都读 `== Ty::Char`，因此 `char` 与 C 的
  `unsigned char` **字节级 ABI 完全一致**。
- **拓宽与收窄**：`char` 可无损拓宽到任意更宽整数（`let w: i32 = c;` 合法）；
  收窄（`char = 300`、`char = -1`）被拒，消息 `does not fit in char`；
  显式转型 `char(300)` 经 `uint8_t` 截断为 44。
- **首类位置**：`char` 在 `u8` 能出现的每个位置都是首类类型——局部、全局、
  `const`、数组元素、结构体字段、参数、返回类型——`char(x)` 是合法收窄转型。
- **词法器**：新增保留字 `char`，30 → 31；`gen_lexer_names.py --check` 守门通过，
  重新生成 `aster.ast` 与 `lexer_names.h`。
- **C-ABI 互操作**：Aster 的 `char`/`i32` 函数参数走 `W0` 截断到一字节、返回是
  `UXTB W0`、结构体字段是一字节槽位、数组每元素跨一字节——与 C 完全一致。
  套件以真实跨语言链接证明：C 的 `main` 链接 Aster 提供的 `char` 函数，
  qemu 下退出码 0，与纯 C 孪生逐一对齐。

## 3. 新增文件

| 文件 | 内容 |
| --- | --- |
| `tests/char-checks.sh` | 9 层套件（见 §5），注册进 `ci.sh` 的 `CRITICAL` 与 `DEFAULT_SUITES` |
| `examples/char_return.ast` | 覆盖 `char` 每一种合法拼写位置（局部/全局/数组/结构体字段/参数/返回，含拓宽、收窄转型、与 C 孪生逐字节 ABI 一致），qemu 退出码 0 |
| `tests/char-return-twin.c` | C 孪生（`unsigned char`），qemu 退出码一致 |
| `tests/baseline/v0.23.69-dev/` | 本版本字节快照：372 行（125 例 × 3 模式 − 3 个 `address_of_abi`），124 个既有例子的行与 v0.23.68-dev 逐一相同 |

## 4. 字节基线

全量重生成 372 行基线并与当前最终编译器逐行比对：**完全一致**。
124 个既有例子的输出与 v0.23.68-dev 零差异——`char` 是纯语言特性，
不移动任何既有镜像字节（仅新增 `char_return` 的 3 行）。

## 5. 套件九层

1. 严格构建（`-Wall -Wextra -pedantic -Werror`）。
2. 源码守卫 15 条 + 保留字断言（31 词、`tls` 仍是上下文关键字、
   `char` 在列、`Ty::Char` 在 `Ty` 枚举、`u8`/`char` 代码生成点 ≥ 10 处等）。
3. **C-ABI 互操作见证**：C 的 `main` 链接 Aster 的 `char` 函数
   （`c_calls_aster_char`，qemu 退出 0）+ C-only 孪生对照。
4. gcc 差分 6 例（arith / array / struct / widen / narrow / param_ret），
   Aster 与 C 的 qemu 退出码逐一一致。
5. 拒绝矩阵 11 条：char 作局部/全局/`const`/赋值/返回/结构体字段/参数初始值、
   折叠超界（`300 + 1`）、`switch` 超界 case——消息精确
   （`does not fit in char` / `expected char, got i32` /
   `case value does not fit the switch subject type`）。C 仅告警、不拒，故全部为 Aster 独有规则。
6. shipped 例子 `char_return.ast` 对 C 孪生（退出码 0 一致）。
7. 覆盖计数：守卫 ≥ 15、拒绝 ≥ 10、gcc 差分 ≥ 6。
8. 六个变异体全部「被察觉」：m1 禁用 `initializerFits(char)` 两路
   （字面量 + 折叠）→ witness 可编译；m2 放开 `parseType` 的 char 分支 →
   char 不再成类型；m3 撤掉转型守卫 `||cur().k==TK::CharType` → char(x) 不再成转型；
   m4 禁用 `caseValueFits(char)` → switch 超界 case 可编译；m5 撤掉
   `tyIsInteger` 的 char → char 退出整数集；m6 撤掉 `u8`/`char` 共用代码生成 →
   字节哈希改变。
9. 字节基线：钉死 3 个 `char_return` 行（build-so / build-elf / build-obj_--pic）。

## 6. 本轮修掉的测试侧问题（首跑前排查）

- mutation (a) 初版只禁 Sema 一处，但 `initializerFits(char)` 有**两路**——
  字面量早返回（`if(t==Ty::Char)return (uint64_t)e.n<=255u;`，约 873 行）与
  折叠表达式 `switch` 分支（约 894 行）。仅禁一处时 `let c: char = 300;` 仍被
  字面量路拦截，属假阴性。现两路同禁。
- mutation (d) 原 sed 目标是 `caseValueFits(char)` 里的 `switch` 分支
  （约 919 行），而 `return 300;` 走的是 `tyAssignable`→`initializerFits` 字面量路，
  与 919 行无关——假阴性。现 witness 改为 `switch(c){ case 300: }` 超界 case，
  命中 `caseValueFits` 路。
- mutation (c) 初版在 `primary()`（返回 `E`）里写 `return false;`，类型不符编译失败。
  `primary` 返回的是 `unique_ptr<Expr>`，故改为撤掉转型**守卫**
  `||cur().k==TK::CharType`（函数体返回类型不变），`char(x)` 不再被识别为转型。
- `build-so` 把**输出文件名**嵌入 `.dynstr`，故字节基线须以与重生成完全相同的
  输出名 `char_return.build-so` 记录——初版用 `/tmp/cr.so` 导致哈希不匹配，
  已重算为 `4e1f6a41…`。`build-elf`/`build-obj` 不嵌文件名，哈希稳定。
- `char-checks.sh` 全程 dash 兼容（无 `<<<`/bashism），与 `void-checks.sh` 同形。

## 7. 拒绝矩阵实测（11 例，全部 Aster 独有）

接受：`char_arith`/`char_array`/`char_struct`/`char_widen`/`char_narrow`/
`char_param_ret`（gcc 差分 6 例，qemu 退出码均与 C 孪生一致为 0）。拒绝（带精确消息）：

| 程序 | 消息 |
| --- | --- |
| `let c: char = 300;` | does not fit in char |
| `let g: char = 300;` | does not fit in char |
| `const c: char = 300;` | does not fit in char |
| `let c: char = -1;` | does not fit in char |
| `let c: char = 300 + 1;` | does not fit in char |
| `let c: char = 0; c = 300;` | does not fit in char |
| `fn f() -> char { return 300; }` | expected char, got i32 (write an explicit cast to truncate) |
| `struct S { c: char, n: i32 }` + `S { 300, 7 }` | expected char, got i32 |
| `fn f(x: i32) -> char { return x; }` | expected char, got i32 (write an explicit cast to truncate) |
| `let x: i32 = 300; let c: char = x;` | expected char, got i32 (write an explicit cast to truncate) |
| `switch(c: char){ case 300: }` | case value does not fit the switch subject type |

## 8. 版本与计数

- `src/aster.cpp` `ASTER_VERSION_STRING` = `0.23.69-dev`；
  `CMakeLists.txt` `VERSION 0.23.69`。
- token 总数 82（`enum class TK`，`gen_lexer_names.py --check` 守门，`CharType`
  追加在 `Amp` 之后）。
- 保留字 31（`type`、`const`、`void`、`char` 先后加入）。
- `DEFAULT_SUITES` 126 项；`CRITICAL` 17 项（新增 `char-checks.sh`）。

## 9. 全量门禁

`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc bash tests/ci.sh`：

- **126 passed, 0 skipped, 0 failed**（125 → 126 套件，新增 `char-checks.sh`）；
  APK 门禁 **3 passed, 0 skipped, 0 failed**。

`char-checks.sh` 单跑（本环境、`CXX=g++ HOSTCC=aarch64-linux-gnu-gcc`）：9 层全绿，
含 C-ABI 互操作见证、6 例 gcc 差分、11 条拒绝、6 个变异体、3 个字节基线行全部复现。
全量基线重生成 372 行与 `tests/baseline/v0.23.69-dev/` 逐行一致、124 个既有例子的行未移动。

## 10. 结论

审计第 13 项（语言缺口）前四项 `typedef`/`const`/`void`/`char` 全部关闭，
仅剩 `union` 排队。`char` 的加入使 Aster 拥有与 C `unsigned char`
字节级一致的 8 位整数类型——它复用 `u8` 的全部代码生成与 ABI 机，
因此与 C 调用方链接时在 qemu 下退出码逐一对齐，无需任何垫片。
