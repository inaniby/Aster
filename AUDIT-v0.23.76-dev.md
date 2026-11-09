# Aster 第三轮全量源码审计报告（v0.23.76-dev）

**审计对象**：Aster 编译器 v0.23.75-dev → 合并 `origin/main` 后的 v0.23.76-dev（`src/aster.cpp` 约 14,000 行单文件）
**审计基准**：132 个 `examples/*.ast`、139 个常驻套件、393 行冻结字节基线（`tests/baseline/v0.23.76-dev/`）
**审计方法**：只读源码审阅 → 手写最小复现探针（约 90 个 `.ast`）→ 差分（对 `gcc -O2 -fwrapv` 的退出码）→
ASAN 构建下的畸形输入/变异 APK/变异目标文件模糊 → `llvm-dwarfdump --verify` 作为 DWARF 独立裁判
**状态**：**确认并修复 6 个代码缺陷（A-01、A-06、A-06b、A-08、A-09、A-10）**，另修正 3 处文档不一致
（A-02、A-04、A-07），撤回 1 项误报（A-03），修掉 1 处已导致自身 `-Werror` 门禁失败的排版（A-05）。
新增一个 9 层常驻套件 `tests/u64-literal-compare-checks.sh`（28 个行为用例 + 5 个变异体）。

> **一句话结论**：门禁全绿不等于没有 bug。本轮 6 个缺陷里有 4 个（A-06b、A-08、A-09、A-10）落在
> 「常量折叠」和「调试信息」这两块**几乎不参与运行期断言**的区域——`-g` 的 78 个编译单元此前**全部**
> 被 `llvm-dwarfdump --verify` 判为非法，而仓库里没有一个套件对 `.debug_info` 做过第三方校验。

---

## 1. 发现一览

| 编号 | 领域 | 级别 | 现象 | 状态 |
| --- | --- | --- | --- | --- |
| A-01 | 前端/常量 | P1 | 无后缀字面量 ≥ 2^63 在比较中按**有符号 64 位**读，`18446744073709551615 > 0` 为假 | 已修 |
| A-06 | 前端/常量 | P1 | `u` 后缀字面量被当成宽常量，u32 运算不回绕，`4294967295u * 2u` 得 8589934590 | 已修 |
| A-06b | 前端/常量折叠 | P1 | 常量初始化按 i64 折叠，`let q: u32 = 4294967295u + 1u;` 被拒（运行期其实是 0） | 已修 |
| A-08 | 前端/switch | P2 | `switch` 的 case 标签同样按 i64 折叠，u32 标签被拒 | 已修 |
| A-09 | 调试信息 | P1 | `DW_AT_stmt_list` 用 `DW_FORM_data4`（DWARF4 应为 `DW_FORM_sec_offset`），LLVM 全部拒收 | 已修 |
| A-10 | 调试信息 | P1 | 类型 DIE 被写进另一个 DIE 的属性流，单元解析错位（数组参数必现） | 已修 |
| A-02 | 文档 | P3 | 文档称 u8/u16 "按类型宽度回绕"，实现是提升到 i32（与 C 一致） | 已改文档 |
| A-04 | 文档 | P3 | "literal must fit the target" 有 i32 例外（截断存储） | 已改文档 |
| A-07 | 文档 | P3 | 用户看到的溢出文案是 `is too large`，文档写的 `exceeds u64 range` 分支不可达 | 已改文档 |
| A-03 | CLI | — | 曾疑 `--page-size` 校验不一致；复核三条 CLI 路径均干净报错 | 撤回 |
| A-05 | 宿主构建 | P2 | `parseObject` 里 `push_back` 粘在 `throw` 行末尾，`-Werror` 下**整个 CI 无法构建** | 已修 |

---

## 2. 逐项记录

### A-01 无后缀字面量 ≥ 2^63 没有有符号读法

```aster
fn main() -> i32 { if (18446744073709551615 > 0) { return 1; } return 2; }
// 修复前返回 2，修复后返回 1
```

`primary()` 接受 `2^64-1` 的字面量（v0.23.48-dev），`exprType(Num)` 却一律回 `I32`；
`constExceedsI32` 因数值超界把**运算**抬到 64 位，条件码仍由 `promoteInt(I32,I32)` 决定——有符号。
最高位为 1 的位型于是按负数比较。

修复：`primary()` 把这类字面量定型为 `u64`（正是 C 对"超出 long long 的十进制常量"的定型），
比较条件码、`UDIV`/`LSR`、`initializerFits` 随之全部走无符号路径；带后缀与范围内字面量不变。

### A-06 `u` 后缀必须优先于数值判定

```aster
fn main() -> i32 { if (4294967295u * 2u == 4294967294u) { return 17; } return 0; }
// 修复前返回 0，修复后返回 17
```

`constExceedsI32` 只看数值大小，`u` 字面量（有意义时必然 > 2^31）把所有运算抬到 64 位，
32 位回绕失效。修复：`if(p->suffix==Expr::LSU)return false;`。

### A-06b 常量初始化按自身类型 + 消费者宽度折叠

```aster
let q: u32 = 4294967295u + 1u;   // 修复前：local initializer does not fit in u32: q (4294967296)
                                  // 修复后：通过，q == 0（与发射的 32 位 ADD 一致）
q = 4294967295u + 6u;             // 赋值、局部数组、全局初值同理
```

新增 `foldAtExprType(t, slot, v)`：类型为 U32 且**槽位非 64 位**时按 32 位回绕后再做 fit 检查；
八个落点（全局初值 ×2、Sema 的 let/数组 ×2、Sema 赋值 ×2、codegen 镜像 ×2）统一。
`!tyIs64(slot)` 这一半是必须的：按 `wideOp` 第 3 条，64 位消费者的运算在 64 位下做，
`let q: u64 = 0u - 1u;` 运行期是 `2^64-1`，折叠值必须与之一致。
新增 `constExprType`（前置声明 `promoteInt`）供解析器阶段推导常量表达式类型；
注意 Sema 的 `typeOf(Add)` 恒回 `I32`，因此不能用注解类型。

### A-08 switch 标签也是常量表达式

```aster
let x: u32 = 4294967295u;
switch (x) { case 0u - 1u: return 1; default: return 2; }
// 修复前：case value does not fit the switch subject type；修复后：返回 1
```

codegen 早已在主体宽度上生成标签（运行期正确），只有 Sema 的 fit 检查用了 i64 折叠值（-1）。
修复同上；裸字面量仍按 i64 读，`case 4294967296` 依旧被拒。
副作用：i32 主体上的 `case 0u - 1u` 现在被拒（4294967295 不是 i32 值），与 `caseValueFits` 的文档一致。

### A-09 DWARF4 里的 `DW_AT_stmt_list` 形式错误

```
error: DIE has invalid DW_AT_stmt_list encoding
```

该属性是 section offset，DWARF4/5 要求 `DW_FORM_sec_offset (0x17)`，实现写的是 `DW_FORM_data4`。
LLVM 直接拒收，lldb 读不到行表。只改形式，值仍是 32 位 DWARF 的 4 字节偏移。

### A-10 类型 DIE 必须先于引用它的 DIE 发射

```aster
fn f(a: i32[4]) -> i32 { return a[0]; }
// 修复前：DW_AT_type = 0x5404，而该单元只有 0xd9 字节
```

`typeRef()` 会向同一 buffer 追加 DIE，却被写在 `dbgPut32(w.info, w.typeRef(...))` 的参数表里，
于是"预热阶段没缓存过的类型"（如指向数组的指针）被塞进当前 DIE 的属性流中间，后续全部错位。
四个落点全部改为**先解析引用、再写 DIE 头**：`subroutine_type` 的返回类型与参数、全局变量、
`subprogram` 的返回类型回退与全部局部/参数。

**量化**：修复前 `-g` 的 78 个编译单元 **78/78** 被 `llvm-dwarfdump --verify` 拒绝；修复后 **0/78**。

---

## 3. 测试基础设施：原生 AArch64 宿主不需要交叉工具链

在 Termux（原生 aarch64）上，`cc` 就是目标编译器、二进制直接运行、binutils 没有 `aarch64-linux-gnu-` 前缀。
套件里有六处假定了 x86 CI 机器，本轮逐一修正：

| # | 假设 | 修法 |
| --- | --- | --- |
| 1 | `HOSTCC` 探测要求带额外 flag 才算成功 | 用独立 `hostcc_ok` 标志；空 flag 列表也是成功（`wide-int-literal`、`narrow-int-abi`） |
| 2 | C 孪生一律 `-static` 链接 | `tests/lib/tools.sh:aster_hostcc_link` 先 `-static`、失败退回普通链接（8 个套件） |
| 3 | `OBJCOPY=$(HOSTCC 把 gcc 换成 objcopy)` | 对 `cc`/`clang` 失效，改为回退到任一本机 objcopy |
| 4 | 硬编码 `aarch64-linux-gnu-readelf/-objdump` | `tests/lib/tools.sh` 解析 `AST_READELF/AST_OBJDUMP/AST_OBJCOPY`（6 个套件） |
| 5 | GNU 反汇编写法 `b.cs` / `#16` | LLVM 写 `b.hs` / `#0x10`：归一化或两种都接受 |
| 6 | `dlopen` 层假定宿主能解析 glibc soname | Aster 的 `.so` 带 `DT_NEEDED libc.so.6`，Android bionic 无法解析 → 该层在 Android 上 SKIP |

---

## 4. 未发现缺陷的方向（负结果也记录）

| 方向 | 方法 | 结果 |
| --- | --- | --- |
| 结构体布局 | 60 个随机结构体（u8/u16/i32/i64/char），字段写入回读 + `sizeof` 对 C | 60/60 一致 |
| 算术/比较差分 | 440 例（六种整型、双目运算、比较、移位、`/ %`、嵌套、u64 比较）对 `gcc -O2 -fwrapv` | 除已修正的 A-02 文档类外全部一致 |
| 编译器畸形输入 | ASAN 构建，200 例（词法垃圾/深层嵌套/超大数/截断结构体/无效 `@embed`） | 0 崩溃、0 ASAN 报告 |
| `verify-apk` | ASAN，260 例变异 APK（位翻转/截断/插入/重复/清零/伪造 EOCD/伪造长度字段） | 0 崩溃；合法 APK 仍完整 v1+v2 验签 |
| 目标文件链接 | ASAN，220 例变异 `.o` 喂 `link-so`（含多目标、TLS、`-g` 输入） | 0 崩溃、0 悬挂 |
| `--bounds-check` | 负下标、越界、合法、u8 下标、二维下标 | 越界全部 SIGTRAP(133)，合法无假阳性 |
| 枚举/char/ptr | 负值枚举、`INT32_MAX`、`sizeof(E)`、switch on enum、char 算术、`ptr` vs `ptr<u8>` 跨步 | 全部符合文档 |

---

## 5. 兼容性说明

- **多接受**：u32 槽位与 u32 switch 标签现在接受 u32 常量表达式（A-06b、A-08）。
- **多拒绝**：i32 主体上的 `case 0u - 1u`（值 4294967295 不在 i32 范围），与 `caseValueFits` 文档一致。
- **字节零漂移**：任何在修复前可编译的程序，产物字节不变；393 行冻结基线逐行复现，各套件钉住的 312 行预存在行也未动。
- **`-g` 产物变化**（A-09、A-10）：这是修复本身；非 `-g` 产物不受影响。

---

## 6. 复现与环境

```sh
# 原生 aarch64（Termux）：无需交叉工具链
export HOSTCC=cc CXX=clang++
sh tests/u64-literal-compare-checks.sh          # 新增套件：28 例 + 5 变异体
for s in literals-checks wide-int-literal-checks const-fold-u64-checks \
         front-sema-checks signedness-checks stack-arg-abi-checks \
         debugline-checks debug-info-checks eh-frame-checks; do sh tests/$s.sh; done
```

`-g` 全量校验：

```sh
for f in examples/*.ast; do
    ./aster build-elf -g "$f" -o /tmp/x.elf && llvm-dwarfdump --verify /tmp/x.elf
done
```

ASAN 复核：`clang++ -std=c++17 -O1 -g -fsanitize=address -o build/aster-asan src/aster.cpp`。

---

## 7. A-11（新，P1）：长表达式链导致指数级编译时间

**现象**（本机实测，`build/aster` 优化构建）：

| 表达式 | 编译耗时 |
| --- | --- |
| `return (1+1+…+1) & 255`（10 项） | 21 ms |
| 同上（20 项） | 200 ms |
| 同上（22 项） | 782 ms |
| 同上（30 项） | 逾 60 s 未完成 |
| 同上（3000 项） | ASAN 构建栈耗尽崩溃 |

变量链同样中招（`a+a+…+a` 20 项 416 ms），说明与常量折叠无关，是**类型计算**的问题。

**定位**：给 `exprType` 加计数器后，20 项表达式触发了 **11,010,020 次** `exprType(Num)` 调用
（≈ 2^23）。根因在 `Codegen::exprType` 的“void 操作数”前置检查：

```cpp
if(isVoidUsingOp(e.k)){
    if(e.a&&exprType(*e.a)==Ty::Void) throw ...;   // 第一次递归
    if(e.b&&exprType(*e.b)==Ty::Void) throw ...;
}
switch(e.k){
    case Expr::Add: { const Ty a=exprType(*e.a),b=exprType(*e.b); ... }  // 第二次递归
```

每个节点都把两个操作数各算两遍，于是 T(n)=2·T(n−1)，指数爆炸。仓库自带的
`examples/long_expression.ast` 只有 20 项——正好是“还能忍”的边界，因此此前无人察觉。

**修复**：把 `exprType` 拆成带记忆化的包装 + 纯实现 `exprTypeUncached`，
以 AST 节点指针为键缓存结果（AST 在 codegen 阶段稳定，纯记忆化不改任何决策）。
修复后 20/30/50/100/1000 项分别为瞬时、瞬时……全部通过；3000 项给出干净诊断
`expression is nested too deeply (max 2048)`（递归实现本身的既有上限，不是崩溃）。

**回归**：`tests/u64-literal-compare-checks.sh` 新增第 29 个行为用例（200 项链必须编译并运行）、
两条源码守卫（`exprTypeUncached` 与 `exprTypeCache.find(&e)` 必须存在）、以及变异体 m6
（删掉缓存查找后，该用例必须在 20 s 内超时被抓到）。字节基线仍零漂移。

---

## 8. 编译期复杂度扫描（A-11 修复后）

修复 A-11 后，把「长输入会不会退化成指数/三次」按形状扫了一遍（本机 release 构建，
`build-elf`，含链接；每组取编译耗时）：

| 形状 | size | 耗时 | 结论 |
| --- | --- | --- | --- |
| return 中的常量加法链 | 100 / 300 / 1000 / 2000 项 | 7 / 10 / 42 / 154 ms | ~n²，上限被 2048 递归守卫挡住 |
| 局部 `let` 常量链 | 100 / 300 / 1000 | 6 / 10 / 41 ms | 同上 |
| `if` 条件里的常量链 | 100 / 300 / 1000 | 6 / 12 / 44 ms | 同上 |
| 全局常量初值（`foldConst` 路径） | 500 / 1000 / 1500 / 2000 项 | 7 / 6 / 8 / 8 ms | 线性 |
| 2000 项混合运算符 `+ - * ^ \|` | 2000 项 | 30 ms | 线性 |
| 变量链 `a+a+…`（无折叠） | 100 / 300 / 1000 | 7 / 10 / 53 ms | 线性 |
| 嵌套括号 | 200 / 500 层 | 7 ms / 干净拒绝 | 256 深度守卫 |
| 括号/三元嵌套 | 200 / 500 层 | 15 ms / 干净拒绝 | 256 守卫 |
| 局部声明 | 1000 / 5000 条 | 干净拒绝（500 上限） | 守卫正确 |
| 函数数量 | 200 / 1000 | 19 / 314 ms | 线性（含符号表与重定位） |
| 全局变量 | 1000 / 5000 | 18 / 100 ms | 线性 |
| `switch` 分支 | 100 / 500 | 7 / 8 ms | 线性 |
| 结构体字段 | 200 个 i32 | 6 ms | 线性 |
| 数组动态下标写入 | 500 次 | 8 ms | 线性 |
| 字符串字面量局部量 | 2000 条 | 干净拒绝（500 声明确上限） | 守卫正确 |

**结论**：A-11 是唯一一处指数级路径。其余最慢的是「return 里的常量链」的 ~n² 类型注解，
但被 2048 的递归深度守卫封顶（最坏约 160 ms），不构成可用性问题。

扫描脚本：`~/DSH/complexity_probe.py`、`complexity_probe2.py`、`complexity_probe3.py`。

---

## 9. A-12（P1，已修）：多目标 `-g` 链接后所有编译单元指向同一条行表

**现象**：两个 `-g` 目标文件链接后，`llvm-dwarfdump --verify` 报

```
error: Identical DW_AT_stmt_list section offset occurred 1 time(s).
```

两个 CU 的 `DW_AT_stmt_list` 都是 `0x00000000`，而合并后的 `.debug_line` 里明明有两条行表程序
（`debug_line[0x00000000]`、`debug_line[0x00000071]`）。调试器会把第二个源文件的代码按第一个源文件的
行号解释。

**机理**：每个目标对象的 CU 里 `stmt_list` 都是 0（指向自己行表的开头）；链接器把 `.debug_line`
与 `.debug_info` 顺序拼接，并修正了 `.debug_line` 里的地址（`debugLineFixups`）与 `.debug_info`
里的 `low_pc`（`debugInfoPatches`），却唯独没有把第二个单元（以及之后每个单元）的 `stmt_list`
加上它在合并行表里的偏移。

**修复**：`parseObject` 在读到 `.debug_info`/`.debug_abbrev` 后，用一个小 DWARF 阅读器定位该单元的
`DW_AT_stmt_list` 字段（走 CU 头 → abbrev 表 → 属性表，只接受写者会产出的形式，其它形式直接拒绝，
绝不把修不了的表合并进去），把偏移存进 `ParsedObject`；`linkObjects` 与 `linkSharedObjects`
在拼接时把该字段改写成"本对象行表在合并段里的起点"。

**验证**：

| 场景 | 修前 | 修后 |
| --- | --- | --- |
| `link-pie` 两个 `-g` 对象 | 两个 CU 都是 `0x0`，verify 报错 | `0x0` / `0x71`，**No errors** |
| `link-so` 两个 `-g` PIC 对象 | 同上 | `0x0` / `0x6f`，**No errors** |
| `link-pie` 三个 `-g` 对象 | 同上 | `0x0` / `0x71` / `0xd7`，**No errors** |
| 单对象链接、非 `-g` 链接 | 正常 | 字节不变 |

**回归**：`tests/debuginfo-decode.py --units` 增加两列（本单元的 `DW_AT_stmt_list` 与
`.debug_line` 大小），`tests/debug-info-checks.sh` 在 `link-obj` 与 `link-so` 之后断言：
第一个单元为 0、两单元互不相同、第二个落在 `.debug_line` 范围内。
另外把 `tests/symbol-versioning-checks.sh` 的 `dlopen` 见证层在 bionic 宿主上改为跳过
（它要求 `--needed libc.so.6`，Android 的加载器没有这个名字）——与之前 e2e 层的处理一致。
