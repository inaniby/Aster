# 验收报告 — v0.23.68-dev（`void` 返回类型）

## 1. 审计诉求

`AUDIT-v0.23.61-dev.md` 第三部分「语言层面的缺口」Top5 按性价比排序为
`typedef`(1)、`const`(2)、`void`(3)、`char`(4)、`union`(5)，要求依次关闭。
v0.23.67-dev 关闭了前两项；本轮关闭第三项 **`void`**，`char` 与 `union` 仍排队。

## 2. 本轮交付

- **`void` 仅作返回类型**：编译器新增 `Ty::Void`；`parseType` 仅在
  `needType` 的 `allowVoid` 门后接受 `void` 关键字（函数声明的 `->` 返回与
  `fn` 类型的 `->` 传 `true`，其余值位置一律 `false`）。因此 `void` 永不能
  出现在参数、局部、字段、别名或数组元素——各自被拒。
- **返回纪律**：`void` 函数可写 `return;`（无表达式）、可自然落空（没有值
  可缺失）；`return e;` 被 Sema 拒绝（`cannot return a value from a void
  function`）。`void` 函数仍走完整 prologue/epilogue、同一套 AAPCS64 ABI。
- **值域拒绝**：`void` 结果不能当值用——`let x: i32 = f()`、`return f()`、
  `g(f())` 因 `tyAssignable(_, Void) == false` 被拒（`got void`）；运算数
  形式 `f() + 1` 先被 `isVoidUsingOp` 以 `a void value cannot be used in an
  expression` 拦下。
- **别名拒绝**：`type V = void` 被拒（`a type alias cannot be void: V`）——
  否则别名会把 void 走私进值位置，架空 `allowVoid` 门。
- **词法器**：新增保留字 `void`，29 → 30；token 总数 80 → 81；
  `gen_lexer_names.py --check` 守门通过。
- **C-ABI 互操作**：Aster 的 `void` 函数参数走 `W0`、不返回任何值，与 C
  完全一致。套件以真实跨语言链接证明：C 的 `main` 链接 Aster 提供的
  `void` 函数，qemu 下退出码 0，两侧无任何垫片。

## 3. 新增文件

| 文件 | 内容 |
| --- | --- |
| `tests/void-checks.sh` | 9 层套件（见 §5），注册进 `ci.sh` 的 `CRITICAL` 与 `DEFAULT_SUITES` |
| `examples/void_return.ast` | 覆盖 `void` 每一种合法拼写位置（文件级 void 函数、落空、显式 `return;`、值函数调用 void 函数、循环+if），qemu 退出码 19 |
| `tests/void-return-twin.c` | C 孪生，qemu 退出码一致 |
| `tests/baseline/v0.23.68-dev/` | 本版本字节快照：369 行（124 例 × 3 模式 − 3 个 `address_of_abi`），123 个既有例子的行与 v0.23.67-dev 逐一相同 |

## 4. 字节基线

全量重生成 369 行基线并与当前最终编译器逐行比对：**完全一致**。
123 个既有例子的输出与 v0.23.67-dev 零差异——`void` 是纯语言特性，
不移动任何既有镜像字节。

## 5. 套件九层

1. 严格构建（`-Wall -Wextra -pedantic -Werror`）。
2. 源码守卫 24 条 + 保留字断言（30 词、`tls` 仍是上下文关键字、
   `void` 在列、`Ty::Void` 在 `Ty` 枚举末尾等）。
3. **C-ABI 互操作见证**：C 的 `main` 链接 Aster 的 `void` 函数
   （`c_calls_aster_void`，qemu 退出 0）+ C-only 孪生对照。
4. gcc 差分 5 例（basic / fallthrough / loop_if / value_fn_calls_void /
   maybe），Aster 与 C 的 qemu 退出码逐一一致。
5. 拒绝矩阵 11 条：void 作参数/局部/字段/别名、从 void 函数返回值、
   void 结果作 let/赋值/return/实参/运算数——其中 5 条 gcc 孪生同样拒绝，
   其余为 Aster 独有。
6. shipped 例子 `void_return.ast` 对 C 孪生（退出码 19 一致）。
7. 覆盖计数：守卫 ≥ 20、拒绝 ≥ 10、gcc 差分 ≥ 5。
8. 六个变异体全部「被察觉」：m1 禁用 void 返回值拒绝 → witness 可编译；
   m2 放开 `allowVoid` 门 → void 可作参数；m3 禁用 `isVoidUsingOp` →
   void 可作运算数；m4 禁用 void 落空豁免 → void 函数必须显式返回；
   m5 让 `tyAssignable` 接受 Void → i32 函数可 `return f()`；
   m6 禁用别名 void 守卫 → `type V = void` 可编译。
9. 字节基线：钉死 3 个 `void_return` 行。

## 6. 本轮修掉的测试侧问题（首跑前排查）

- mutation (a) 原本只禁用 Sema 早返回一处，但 `return 5;` 在 void 函数里
  被**两道**检查拦截（另一道是整数返回路径的 `checkValue`，报
  `expected void, got i32`）——变异后仍被拒，属假阴性。现同时中和两处。
- mutation (e) 原 sed 目标 `if(f.retType==Ty::Void){` 在源码中不存在
  （6228 行是 `if(f.retType==Ty::Void&&!definitelyReturns(f.body))retVoid();`，
  无 `{`），属盲变异。现改为 mutate `tyAssignable` 接受 Void。
- mutation (f) 原本只改写报错文本、未真正关掉拒绝。现用行尾锚定
  `if(t.k==Ty::Void)$` 仅禁用别名守卫（不碰 1268 行的 `allowVoid` 门）。
- `void-checks.sh` [9/9] 的 `for spec in $void_rows` 按**单词**而非**行**
  分割，`val` 取成了 key 本身。改为 `while IFS= read -r`。
- `examples/void_return.ast` 加入后，13 个基线套件的 FILTER 列表需含
  `^void_return\.`——逐一核实全部在位（上轮预备时已加入），
  `alias-const-checks.sh` 的行数断言 366 → 369 已同步。

## 7. 拒绝矩阵实测（15 例）

接受：`v_ok`（带参 void 函数 + early return）、`v_fall`（void 函数落空），
qemu 退出码均为 0。拒绝（带精确消息）：

| 程序 | 消息 |
| --- | --- |
| `return 5;` in void fn | cannot return a value from a void function |
| `let x: i32 = f()` | expected i32, got void |
| `let x = f()`（未标类型） | expected ':' |
| `x = f()` | expected i32, got void |
| `return f();` in i32 fn | expected i32, got void |
| `g(f())` | expected i32, got void |
| `f() + 1` | a void value cannot be used in an expression |
| `fn f(a: void)` | void is only a function return type |
| `let x: void` | void is only a function return type |
| `struct S { v: void; }` | void is only a function return type |
| `type V = void` | a type alias cannot be void: V |
| `fn f(a: void)` 变异 m2 | （变异后接受 → 被察觉） |

无类型 `ptr`（即 C 的 `void*`）不受影响，照常接受。

## 8. 版本与计数

- `src/aster.cpp` `ASTER_VERSION_STRING` = `0.23.68-dev`；
  `CMakeLists.txt` `VERSION 0.23.68`。
- token 总数 81（`enum class TK`，`gen_lexer_names.py --check` 守门）。
- 保留字 30（`type`、`const`、`void` 于 0.23.67/68-dev 加入）。
- `DEFAULT_SUITES` 125 项；`CRITICAL` 16 项（新增 `void-checks.sh`）。

## 9. 全量门禁

`LC_ALL=C CXX=g++ HOSTCC=aarch64-linux-gnu-gcc bash tests/ci.sh`：

- **125 passed, 0 skipped, 0 failed**（124 → 125 套件，新增
  `void-checks.sh`）；APK 门禁 **3 passed, 0 skipped, 0 failed**。

实际运行（2026-11-03，`setsid` 脱离会话启动，RC=0）与上方数字完全一致：
125 套件全绿、APK 3/3。过程中暴露并修复了三处测试侧守卫（非功能缺陷）：
(1) `Ty::Kind` 枚举尾部锚点 `Struct };` → `Void };`（enum/sema/struct/wide-int 四套件）；
(2) 保留字数断言 29 → 30（alias-const）；
(3) `void-checks.sh` 的 bash here-string `<<<` 改为 dash 兼容的临时文件读入。
修复后复跑即全绿。

## 10. 结论

审计第 13 项（语言缺口）前三项 `typedef`/`const`/`void` 全部关闭，
仅剩 `char` 与 `union` 排队。`void` 的加入使 Aster 具备与 C 互操作
「无返回值函数」的能力——这是 C 库里最常见的函数形状之一。
