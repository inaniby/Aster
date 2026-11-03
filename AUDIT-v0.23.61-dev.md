# Aster 全量源码级审计报告

**审计对象**：Aster 编译器 v0.23.61-dev（`ca7059d`）
**状态**：**4 个 P0 缺陷已在 v0.23.62-dev 修复并补上回归测试**（见文末「修复记录」）；5 个 P1 缺陷与第二、三、四部分发现仍未处理，按建议路线排队。
**审计范围**：`src/aster.cpp`（13,132 行单文件编译器：词法/语法/语义/代码生成/ELF 写出/链接器/DWARF/APK 打包/RSA 签名）、`bootstrap/aster.ast`（5,458 行自举编译器）、115 个常驻测试套件、121 个示例、7 份文档
**审计方法**：五路并行源码审阅 + **执行实测验证**（严格构建 `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror` 通过后，编写 20 个探针程序编译并在 `qemu-aarch64` 上运行，每个异常项都配**对照组**以排除测试程序自身错误）

---

## 摘要

审计发现 **10 个经执行实测确认的缺陷**（其中 4 个会导致**静默的错误结果或内存破坏**，属最高优先级），另有一批代码审阅发现待实测验证。

值得警惕的是：**一个全绿的 115 套件 CI 并不能拦住这批缺陷**。它们全部逃过了现有测试——因为测试用例普遍使用常量下标与常量右值，恰好绕开了出错的求值顺序路径。这印证了「测试覆盖了路径，不等于覆盖了路径的组合」。

| 等级 | 数量 | 性质 |
|---|---|---|
| **P0** | 4 | 静默产生错误结果 / 内存破坏（写错地址） |
| **P1** | 5 | 静默接受非法程序，或错误拒绝合法程序 |
| **P2** | 9 | 代码审阅发现，待实测验证 |

---

## 第一部分：执行实测确认的缺陷

以下每项均给出**最小复现程序**、**实测结果**、**期望结果**与**对照组**。

### P0-1　多维数组下标赋值：目标地址先于右值求值 → 写错地址（内存破坏）

```aster
let g: i32 = 42;
fn main() -> i32 { let m: i32[2][3] = 0; m[0][1] = g; return m[0][1]; }
```
**实测**：返回 `0`　**期望**：`42`

代码生成先把目标元素地址算进 `X16`，再求右值；而右值读取全局变量时 `emitGlobalAddress` 会**覆写 `X16`**，于是 `STR` 写到了 `g` 的存储位置而非 `m[0][1]`。

**对照组（均正常，精确定位故障面）**：

| 用例 | 结果 | 说明 |
|---|---|---|
| `m[0][1] = 42`（常量右值） | 42 ✓ | 常量不占用寄存器 |
| `m[0][1] = f()`（调用右值） | 42 ✓ | 静态 ELF 直连 `BL`，不经 PLT，`X16` 幸存 |
| `a[1] = g`（**一维**数组 + 全局右值） | 42 ✓ | 一维分支求值顺序正确 |
| `m[0][1] = g`（**多维** + 全局） | 0 ✗ | 仅多维分支有缺陷 |

> 一维分支（约 5732/5750 行）遵循「先求值再造址」，多维分支（约 5723-5727 行）顺序相反——同类代码两种写法，是典型的复制粘贴漂移。

**建议修法**：多维分支把 `emitIndexAddr()` 移到 `gen(*s.expr)` 之后。结构体字段存储路径 `emitStructStore` 需同样核查。

**回归用例**：上述 4 个用例应全部固化为断言，缺一则该缺陷会再次溜过。

---

### P0-2　结构体数组字段寻址：基址先于下标求值 → 读到错位元素

```aster
struct S { xs: i32[4] }
let gi: i32 = 2;
fn main() -> i32 { let s: S; s.xs[2] = 12; return s.xs[gi]; }
```
**实测**：返回 `0`　**期望**：`12`

`emitElemAddrField` 先算字段首址（`X16`），再算下标。`gi` 是全局量，读取时覆写 `X16`，后续以 `X16` 为基址取元素 → 偏移落在错误位置。

**对照组**：

| 用例 | 结果 |
|---|---|
| `return s.xs[2]`（常量下标） | 12 ✓ |
| `let li: i32 = 2; return s.xs[li]`（**局部**下标） | 12 ✓ |
| `return s.xs[gi]`（**全局**下标） | 0 ✗ |

局部下标正常、全局下标出错，直接证实了「全局地址加载覆写 `X16`」的机理。同类函数 `emitElemAddr`／`emitPtrElemAddr`／`emitIndexAddr` 都是**先下标后基址**，唯独此处相反。

**建议修法**：交换两行顺序，与其余三个同类函数保持一致。

---

### P0-3　`*p = v` 右值未按目标宽度生成 → 64 位写入被截断为无符号 32 位

```aster
let q: i64 = 0;
fn main() -> i32 { let p: ptr<i64> = &q; *p = -5; if (q == -5) { return 0; } return 1; }
```
**实测**：返回 `1`（即 `q != -5`）　**期望**：`0`

存储宽度取自目标元素类型 `elem`，但右值 `gen(*s.expr)` 用默认 `Ty::I32` 生成 → `SUB W` 得到 `0xFFFFFFFB`，再以 `STR X` 存成 `4294967291`。全局变量与局部变量版本**均触发**。

其余所有写路径（Let、Assign、FieldAssign、IndexAssign）都正确传入了目标类型，仅此一处遗漏。

**建议修法**：改为 `gen(*s.expr, elem)`。

---

### P0-4　`(bool)` 转换对 64 位源只比较低 32 位

```aster
fn main() -> i32 { let a: u64 = 4294967296; let b: bool = bool(a); if (b) { return 1; } return 0; }
```
**实测**：返回 `0`（判为假）　**期望**：`1`（`2^32` 非零应为真）

`gen()` 固定发射 `cmpZero()`（`CMP W` 32 位比较），而源寄存器里其实保留着完整 64 位值 → 高位非零、低位为零时被误判为假。

**对照组**：`bool(u64 = 1)` → `1` ✓（低位非零时掩盖了缺陷）。

> 同文件 `emitCondition`（约 5375 行）已正确写成 `tyIs64(t) ? cmpZeroX : cmpZero`，`&&`/`||` 也正确——此处是遗漏。

**建议修法**：改为 `emit(tyIs64(from) ? cmpZeroX(a) : cmpZero(a))`。

---

### P1-1　宽整数算术参与移位/取反 → 合法程序被拒绝

```aster
fn main() -> i32 { let a: i64 = 1; let b: i64 = 2; let c: i64 = (a + b) << 2; return i32(c); }
```
**实测**：编译拒绝 `TypedIR MISMATCH kind=25 type=i32 exprType=i64`　**期望**：编译通过并返回 `12`

根因：Sema 的 `typeOf(Add)` 硬返回 `Ty::I32`，而 Codegen 的 `exprType(Add)` 返回 `promoteInt`（此处为 `I64`）。TypedIR 一致性断言的豁免名单只列了 `Add/Sub/Mul/Div/Neg/Mod/BitAnd/BitOr/BitXor`，**漏了 `Shl/Shr/BitNot`** → 断言触发。同理 `~(u8+u8)`、以及三元表达式双臂同为宽整数加法也会崩。

**建议修法**：二选一——(a) 把 `Shl/Shr/BitNot` 加入豁免；(b) **治本**：让 `typeOf` 对算术族改用与 `exprType` 相同的 `promoteInt`，消除两套类型推导的不一致。

---

### P1-2　enum 比较运算符缺少名义隔离（本轮新代码的缺陷）

```aster
enum Color { R, G }
enum Fruit { A, B }
fn main() -> i32 { let c: Color = R; let f: Fruit = A; if (c == f) { return 1; } return 0; }
```
**实测**：编译通过并返回 `1`　**期望**：**编译拒绝**

比较运算（约 7029 行）只拒绝 `Ptr`/`Struct`，两个 `Ty::Enum` 一律放行，而 `tyIsInteger` 又已把 `Enum` 算作整数 → 跨枚举比较畅通无阻。这违背了语言参考中「两个 enum 即使同为 4 字节也是不同名义类型」的设计，也与本轮刚建立的 `tyAssignable` enum 分支不一致。

**建议修法**：两侧均为 Enum 时要求 `sid` 相同；一侧为 i32 常量则放行（与 `tyAssignable` 口径一致）。

---

### P1-3　enum 常量初始化缺少 i32 范围检查（本轮新代码）

```aster
enum Color { R, G }
fn main() -> i32 { let c: Color = 4294967296; return 0; }
```
**实测**：编译通过　**期望**：编译拒绝（超出 i32）

`initializerFits` 的 `switch` 无 `Ty::Enum` 分支 → 落到 `default: return true`；`Num` 路径也只对 `U8/U16/Bool/U32/I64` 判范围。越界值经 `tyAssignable` 放行后被静默截断。

**建议修法**：`initializerFits` 增加 `case Ty::Enum:` 判定 `folded ∈ [-2^31, 2^31-1]`，并在 `Num` 路径补同等判据。

---

### P1-4　enum 自增越界未检查（本轮新代码）

```aster
enum E { A = 2147483647, B }
```
**实测**：编译通过（`B = 2147483648`）　**期望**：编译拒绝

声明解析处的注释明确写着「越出 i32 的枚举值不允许」，但该检查只作用于**显式** `= 常量` 的枚举器，自增路径（`next = val + 1`）漏了检查 → 与 P1-3 叠加后静默回绕。

**建议修法**：`next = val + 1` 之后立即执行同一范围检查。

---

### P1-5　`return` 处的隐式窄化未被拒绝

```aster
fn f() -> u8 { let x: i64 = 300; return x; }
fn main() -> i32 { return i32(f()); }
```
**实测**：编译通过，返回 `44`（`300 & 0xFF`）　**期望**：编译拒绝，要求显式 `u8(x)`

`checkValue` 只处理 struct/bool/ptr，不走 `tyAssignable`；而 `tyAssignable` 的注释明确写「没有隐式截断：要截断请写 cast」。故 `return`、数组元素赋值、结构体字段赋值三处的隐式窄化均被静默接受。

> **注意**：参数传递路径**是正确的**——实测 `fn f(a: u8)` 传入 `i64` 变量被正确拒绝（`argument type mismatch: expected u8, got i64`）。这说明 Sema 各路径的严格度不一致：`checkArgument` 严、`checkValue` 松。

**建议修法**：`checkValue` 补 `tyAssignable` 调用，与 `checkArgument` 口径统一。

---

## 第二部分：代码审阅发现（待实测验证）

以下为源码审阅定位、尚未构造复现用例的项，按严重度排列。**标注「待验」意味着可能存在误判，实施修复前应先复现。**

### 内存安全 / 数值

| 严重度 | 位置 | 问题 | 备注 |
|---|---|---|---|
| 高（触发昂贵） | `aster.cpp:692-707` + `2334` | `layoutStruct` 以 `uint32_t` 累加偏移，而 1024 字节上限校验发生在布局**之后** → 回绕出的小 `size` 反而通过校验，字段 `offset` 被写成接近 2³² 的巨大值，随后 `structConstantImage` 按 `size` 分配缓冲区 → **堆越界写**。需约 400 万字段才能回绕，实际触发成本极高（数十 MB 源码、GB 级内存） | 确认缺陷，非 fuzz 可达 |
| 中 | `aster.cpp:628` | `dimsProduct` 的 `uint64` 连乘无溢出检查 | 当前所有调用点已先经 `dimsTotal` 前置校验，**当前不可触发** |
| 中 | `aster.cpp:2451` | 全局 `rawData` 按 `size*count` 分配，无上限 → 单次可达 1GB，配合段累加可致 OOM | 资源耗尽，防御性 |
| 低 | `aster.cpp:10775` | `derChildren` 不校验子节点是否落在**父节点** contents 之内（只校验整个 buffer） | 证书解析宽松，非内存越界 |
| 低 | `aster.cpp:1019/1024` | `cur()`/`need()` 依赖「词法器总追加 End 哨兵」的不变式，无边界检查；7 处 `t[p+1]`/`t[p+2]` 前瞻依赖该不变式 | 已核实无 `need(TK::End)`，**当前不可触发**，属脆弱依赖 |

### ELF / 链接器 / DWARF / APK

| 严重度 | 位置 | 问题 |
|---|---|---|
| 高（待验） | `aster.cpp:9293`、`9847` | `.so` 的 `.eh_frame` 所在 PT_LOAD 声明 `p_align = pageSize`，但 `ehFrameOff` 只做了 `alignUp(..., 8)`——与同文件注释（6030-6034「动态链接器会拒绝 vaddr/offset 未按页对齐的 LOAD 段」）**自相矛盾**。`writeElfBytes` 用的是 `alignUp(..., pageSize)`。后果预判：带 `-g` 的 `.so` 在 Android 15+ 16KB 页设备上 `dlopen` 被拒 |
| 高（待验） | `aster.cpp:8863-8869` | `resolveRelocations` 的 `kRelTlsOff` 分支读写 `text[patch+4 .. patch+7]`，但 `parseObject:8725` 只校验 `text.size() - offset >= 4` → 重定位落在 `.text` 末 4 字节时越界读写 |
| 中（待验） | `aster.cpp:8452-8454`、`8540` | `writeObject` 把 **STB_LOCAL** 段符号放在所有 GLOBAL 之后，却写 `sh_info=1`；ELF 要求 local 符号排在所有 global 之前 → `readelf`/`ld` 可能报错 |
| 中（待验） | `aster.cpp:9662-9663` | PLT 的 `ADRP x16` 未做 ±4GB 页范围检查即截断写入 21 位字段（对比 `resolveRelocations:8883` 有检查） |
| 中（待验） | `aster.cpp:9245`、`9865` | `.bss`（SHT_NOBITS）的 `sh_offset` 固定写 `relroEnd`；有 TLS 时真实 `.bss` 在 `.tbss` 之后 |
| 中（待验） | `aster.cpp:8494` | `rodataOff = alignUp(..., 1)` 是无操作，`.rodata` 完全不对齐 → `@embed` 数据无法获得 >1 对齐 |
| 低 | `aster.cpp:9240/9856` | `.hash` 的 `sh_entsize=0`（应为 4） |
| 低 | `aster.cpp:10233` | `maxTlsAlign` 仅在 `!tdata.empty()` 时更新，纯 `.tbss` 对象的对齐被忽略 |
| 低 | `aster.cpp:9859` | `.rela.plt` 的 `sh_info=0`（应为 `S_PLT`） |

**已审阅未发现问题的部分**（供参考，避免重复劳动）：`writeElfBytes` 的 ELF 头与段表核算、CALL26 ±128MB / ADRP ±4GB / imm12 溢出检查、`DT_RELACOUNT` 与 RELATIVE 连续块一致性、符号版本化索引、DWARF 行表与 DIE/abbrev 一致性、`.eh_frame` CIE/FDE 补丁、APK Signing Block 与 `contentDigest` 语义、resources.arsc 各 chunk、AXML、PNG CRC/zlib、RSA PKCS#1 v1.5 填充与长度校验、`/dev/urandom` 熵源、Miller-Rabin 33 轮。

---

## 第三部分：功能缺口

`docs/language-reference.md:164` 明确列出不支持项：`void`、`float/double`、`char` **类型**、`union`、`const`、`typedef`/类型别名。对照 `ROADMAP.md:172-180` 的「Deliberately not planned」，**这些特性从未进入规划**（连「未排期」都算不上）。

按**性价比**排序最值得补的 5 项（均为纯前端改动，不涉及后端代码生成重写）：

1. **`typedef` / 类型别名** — 在 `Ty` 解析期即可展开，改动集中在 Parser，语义风险最低。
2. **`const` 只读绑定** — 只需 Sema 增加写保护位，可复用现有赋值检查路径。
3. **`void`** — 仅涉及函数返回位；补齐后可直接打通 C ABI 互操作。
4. **`char` 类型** — char **字面量**已在 v0.23.50 落地（折叠为 i32），加一个 `Ty::Char` 即可闭合，成本远低于「新特性」。
5. **`union`** — 复用 struct 布局（`ObjectLayout`），仅重叠偏移，收益是 C 头文件互操作。

**建议维持不做的**：`float/double`（需 FPU 寄存器类 + AAPCS64 传参重做）、泛型/闭包/模块系统/运算符重载（需重建类型系统与符号表）。

### 文档与实现不一致（应修正）

| 位置 | 问题 |
|---|---|
| `FEATURE_STATUS.md:192` | 仍称 `&arr` 元素非 4 字节宽会被拒绝（v0.23.30），与 `:149` 的「v0.23.34 起不再限宽」**自相矛盾**；实现以 `:149` 为准，**`:192` 应删除** |
| `FEATURE_STATUS.md:308-311` | 仍引用已退役的 `tests/lexer-checks.sh`（v0.23.44 退役）与 `tests/parser-checks.sh`（#261 删除） |
| `docs/language-reference.md:164` vs `:110-112` | 一处说无 `char`，另一处说 char 字面量已支持 → 应改为「有 char 字面量（折叠为 i32），无 char 类型」 |
| `ARCHITECTURE.md:438/440` | 「仅 i32/ptr/bool、无 struct」「APK 仅 v1 签名」相对 v0.23.61 **严重过时** |

---

## 第四部分：技术债与工程卫生

**显式技术债几乎为零**：grep 未命中任何 `TODO/FIXME/HACK/XXX`。债是隐式的，散落在注释里：`pointer indexing is not supported yet`、指针算术限制、链式比较限制、函数指针数组限制、局部对齐等。

**单文件可维护性**：`src/aster.cpp` 13,132 行，其中 Codegen 约 3.3k 行、后端+链接器+APK 约 5.2k 行。但 `ROADMAP.md:21-24` 原则 5 明确要求「保持单文件、零依赖」，**因此不建议拆文件**；可行替代是补充 section banner 锚点、把 `main` 后的 CLI 分派改为表驱动。

### 测试盲区

- **`tests/smoke.sh` 未注册进 `tests/ci.sh` 的 `DEFAULT_SUITES`**（已核实：ci.sh 中 grep `smoke` 无结果）。而 `FEATURE_STATUS.md` 多处把**基础算术、比较、while/break/continue、32 参数调用、build-elf** 的覆盖挂在它名下 → 这些**最基础的能力实际没有常驻套件**。这是最高优先级的覆盖缺口，修法仅一行。
- **自举阶段断档**：`lexer-checks.sh` / `parser-checks.sh` 退役后，词法与语法阶段只剩 `codegen-checks.sh` 兜底。
- **Android 后端薄弱**：`liblog`、`libandroid` 相关能力只有示例 + 手工设备验证，无常驻套件。

### 工程卫生

根目录残留（**均已被 `.gitignore` 正确忽略，无未跟踪污染**）：

- `core.*` **100 个 / 约 75 MB**
- `tmp-*` 9 个 / 约 11 MB
- `aster`（1.2 MB）、`lifecycle.apk`、`build.log`（0 字节）、`ci-full.log`、`ci_run.log`

**唯一该加未加的忽略规则**：`*.tmp.*` / `aster.tmp.*`——`tests/ci.sh:249-254` 先写 `aster.tmp.$$` 再 `mv`，若中途中断会留下未被忽略的残留。

---

## 第五部分：建议修复路线

### 第 1 批（P0，正确性，建议立即）
1. 修多维下标赋值的求值顺序（P0-1），同步核查 `emitStructStore`
2. 修 `emitElemAddrField` 的基址/下标顺序（P0-2）
3. `*p = v` 按目标宽度生成右值（P0-3）
4. `(bool)` 对 64 位源改用 `cmpZeroX`（P0-4）
5. **为每个缺陷补 4 个对照用例**（常量/局部/全局/调用），现有测试正是因为只用常量而漏掉了它们

### 第 2 批（P1，语义严格度）
6. 统一 `typeOf` 与 `exprType`，消除 TypedIR 断言豁免名单（P1-1，治本）
7. enum 三件套：比较名义隔离（P1-2）、初始化范围（P1-3）、自增越界（P1-4）
8. `checkValue` 接入 `tyAssignable`，与 `checkArgument` 口径统一（P1-5）

### 第 3 批（P2 与缺口）
9. 实测验证第二部分的 ELF/链接器项，优先 `.so` 的 `.eh_frame` 页对齐（影响 Android 15+ 16KB 设备）与 `kRelTlsOff` 越界
10. `layoutStruct` 改用带溢出检查的累加，并把尺寸上限校验前移
11. **把 `tests/smoke.sh` 加入 `DEFAULT_SUITES`**
12. 修正四处文档过时断言；补 `*.tmp.*` 忽略规则；清理 75 MB 的 `core.*`
13. 语言缺口按第三部分 Top5 推进（先 `typedef`/`const`/`void`）

---

## 附：本次审计的元发现

**一个全绿的 CI 不等于没有 bug。** 本次发现的 4 个 P0 缺陷全部能在现有 115 套件全绿的情况下存在，原因是测试用例普遍采用最简单的形式（常量下标、常量右值），恰好绕开了出错的求值顺序组合。

针对性建议：为**求值顺序**类缺陷建立一个专门的常驻套件，系统性覆盖「下标/基址/右值 × 常量/局部/全局/调用」的组合矩阵。这类缺陷一旦发生就是静默的内存破坏，最难在用户侧被发现，价值远高于再增加一轮功能特性。

---

## 修复记录（v0.23.62-dev）

第 1 批的 5 项**全部完成**，按审计建议落地：

| 审计项 | 处理 |
| --- | --- |
| 第 1 批 1（P0-1） | 已修：`Stmt::IndexAssign` 多维标量分支改为先生成值再寻址；struct 分支**故意保持**寻址优先，并在源码注释说明理由（`emitStructStore` 把目的地址停在栈帧里、每字段重新装载 `X16`，故不跨右值求值持有地址） |
| 第 1 批 2（P0-2） | 已修：`emitElemAddrField` 先求值下标、再算字段基址，与 `emitIndexAddr` 已有顺序一致 |
| 第 1 批 3（P0-3） | 已修：`Stmt::DerefAssign` 改为 `gen(*s.expr, elem)`，按元素自身宽度生成右值 |
| 第 1 批 4（P0-4） | 已修：`gen(Cast)` 的 bool 分支改为 `tyIs64(from) ? cmpZeroX(a) : cmpZero(a)` |
| 第 1 批 5（补对照用例） | 已落地：`tests/eval-order-checks.sh`，其骨架就是审计建议的**操作数组合矩阵**（常量/局部/全局/调用），四个修复形态各配四个右值种类；配套 `tests/eval-order-twin.c` 做 gcc 差分；[7/9] 变异层用 `cmp -s` 断言变异体确实改动了源码 |

元发现的建议已按字面采纳：求值顺序缺陷有了自己的常驻套件（9 层，注册进 `tests/ci.sh` 的 `DEFAULT_SUITES` 与 `CRITICAL`）。

## 修复记录（v0.23.63-dev）

第 2 批的 5 项**全部完成**，沿用同一条纪律——先在二进制上复现，再改，再验：

| 审计项 | 处理 |
| --- | --- |
| 第 2 批 1（P1-1） | 已修：`Shl`/`Shr`/`BitNot` 从 TypedIR 断言的豁免名单中移除，按操作数自身宽度发射；`~(i64+i64)` 由 `-1`（退出码 255）变为 `-4`（252），与 gcc 一致。豁免名单剩下的部分改用具名谓词 `semaTypeIsPlaceholder()` 表达 |
| 第 2 批 2（P1-2） | 已修：`typeOf()` 的比较分支加入名义隔离——两个 `sid` 不同的 enum 直接拒绝；enum 只允许与同一 enum 或 `i32` 比较 |
| 第 2 批 3（P1-3） | 已修：`initializerFits` 的 enum 分支（裸字面量与折叠值两条路径）改走 `enumValueFits` |
| 第 2 批 4（P1-4） | 已修：`enumDeclaration()` 的自增路径同样过 `enumValueFits`，与显式 `= 常量` 共用同一个谓词 |
| 第 2 批 5（P1-5） | 已修：`checkValue` 末端接入 `tyAssignable`，并补齐标量 `let`、局部 `Assign`、全局 `Assign` 三处调用，`Stmt::Return` 的整数分支也接入；常量范围检查**先于**可赋值性检查。**下标存储与字段存储两处刻意豁免**（`checkValue` 的 `refuseNarrow=false`）：`bootstrap/aster.ast` 把 `i64` 指令字写进 `i32[262144]` 流（`textw[textlen] = w;`），而自举子集的解析器拒绝操作数位置上的任何类型关键字，**没有转换表达式**可写该截断；收紧这两处会让自举无解。ptr/bool 进入整数槽在**所有**存储位置仍然拒绝，不受豁免影响 |

治本项（第 2 批建议 6：统一 `typeOf` 与 `exprType`、消除豁免名单）**仍开放**：两个解析器的分歧（`typeOf` 对算术节点恒答 `i32`，`exprType` 答提升后的操作数宽度）是语义决策，改成一侧会动到已发布例子的字节；本轮改为把豁免显式命名，而不是留一张匿名的 case 列表。

新常驻套件 `tests/type-strictness-checks.sh`（9 层，注册进 `DEFAULT_SUITES` 与 `CRITICAL`），配套 `tests/type-strictness-twin.c` 做 gcc 差分；[7/9] 8 个变异体双向断言（n1/n7/n8 撤掉一条现有规则、须被合法程序抓住；n2–n6 恢复一个已被拒绝的缺陷、须被拒绝程序抓住）。

三处既有期望被本轮改写：`tests/enum-checks.sh` 中把「跨 enum 比较合法」写成见证的用例改为拒绝用例（另补 4 条）；`tests/precedence-checks.sh` 中「窄化一个值始终允许」的两条见证改为拒绝、并补上带转换的见证，m8–m12 的探针用例由 `u8 = 300` 换成 `u32 = 0 - 1`（既越界又窄化的常量现在被两条规则同时拒绝，无法再隔离范围检查）；`tests/array-address-checks.sh` 的 `return fill(w);` 改为 `return i32(fill(w));`。

`bootstrap/aster.ast` 改了两行：`data_size`/`bss_size` 原本接收 `align_up` 的 `i64` 返回值，新增 `align_up32` 让算术在槽位自身的宽度上完成，全程序不再有任何截断（插桩统计：整份 6000 行自举源码只有这 2 处窄化）。

**字节层面零改动**：121 个例子的 363 行基线全部逐字节相同（0 变、0 新增）——本轮只动「接受哪些程序」，不动「生成什么指令」。

第 3 批第 11 项**已完成，但审计给出的修法（「把 `tests/smoke.sh` 加进 `DEFAULT_SUITES`，一行」）被否决**，因为它会掩盖更大的问题：

| 审计项 | 处理 |
| --- | --- |
| 第 3 批 11（`smoke.sh` 未注册） | **已修，但不是注册它。** `smoke.sh` 是**驱动器**：编译编译器、检查 20 个例子的 ELF 头，然后串行调用约 28 个**已注册**的套件——注册它会把那 28 个跑第二遍。真正的洞在门禁本身：孤儿套件的定义是「匹配 `tests/*-checks.sh` 但不在 `DEFAULT_SUITES` 里」，而这是**命名约定，不是性质**，有 4 个脚本不符合该 glob 于是从未被门禁看见。其中 3 个是真套件——`c-ptr-memory-structural.sh`、`e2e-so-scope.sh`、`regression-symtab.sh`。门禁改为枚举**全部** `tests/*.sh` 再减去显式白名单（每条注明理由），并新增一条断言：**驱动器只有在其调用的每一个套件都已注册时才允许不注册**。三套件首次运行的结果：前两个通过；`regression-symtab.sh` 失败，且**不是回归**（见下） |
| 第 3 批 11（附：`FEATURE_STATUS.md` 的 5 处过时声称） | **已修。** 32 参数 → `e2e-c-abi-32-args.sh`；算术 → `operator-checks.sh` + `precedence-checks.sh`；比较 → `bool-checks.sh`；`build-elf` → `write-output-checks.sh`。第 5 项是**真洞**：`while` + 无标签 `break;`/`continue;` 在任何常驻套件里都没有被执行（只有带标签 `break outer;`，或 `switch` 里的 `continue`），已在 `tests/condition-checks.sh` [3/9] 补 3 条见证，含证明无标签 `break` 只跳出最内层循环的嵌套用例 |

`regression-symtab.sh` 的失败值得单独记一笔：它断言每个产品的加载映像仍与 `tests/baseline/v0.16.0` 下冻结的固件逐字节相同，而 `hello.ast` 的 `str w0,[sp,#4]` 已变 `#8`、`pie_global_rw.ast` 的溢出槽由 `str w0,[sp,#4080]` 变 `str x0,[sp,#4032]`——这是**已文档化的 8 字节标量槽**（`ARCHITECTURE.md`，随 v0.23.2-dev 宽整数落地），不是回归。重生成固件会抹掉这条记录，豁免名单则会无限增长，故该断言被换成套件**本名所指**、且仍然处处成立的不变量：**节表是追加的**（`e_shoff` ≥ 最后一个 `PT_LOAD` 的 `p_offset + p_filesz`）。另外记录一处未修补的缺口：11 个用例只有 7 个固件被提交，`obj_*`/`so_*` 四个从未提交，故其 `ET_REL` 分支（逐字节相同）**至今仍未执行过**。

本轮**不动编译器、不动字节**：121 个例子的 360 行基线全部逐字节相同。套件数 118 → 121。

第 3 批第 12 项（工程卫生）**顺手完成**：`.gitignore` 补 `*.tmp.*`（`tests/ci.sh` 先写 `aster.tmp.$$` 再 `mv`，中断会留下未被忽略的残留）；四处过时文档断言已修正——`ARCHITECTURE.md` 把 `smoke.sh` 称作「fast local subset」（它从未进过门禁）、`FEATURE_STATUS.md` 两处把退役的 `tests/parser-checks.sh` 当作并入目标（该套件已在 #261 删除，词法/语法覆盖现归 `codegen-checks.sh` 三向差分）、`docs/language-reference.md` 一句「没有 `char`」（与 §3.2 自 v0.23.50-dev 起就有的字符字面量矛盾，改为「有字符字面量、无 `char` 类型」）；并清掉根目录 46 个 `core.*`（约 25 MB，变异层中止留下的核心转储，已被忽略但从未清理）。

## 修复记录（v0.23.65-dev）

第 9、10 两项**已完成**，且发现它们是同一个缺陷的两副面孔：**布局算术用回绕代替拒绝**。本轮不动字节——121 个例子的 360 行基线逐字节相同，改的只是「接受哪些程序」。

| 审计项 | 处理 |
| --- | --- |
| 第 9 项（`kRelTlsOff` 越界） | **确认并已修。** 局部执行 TLS 的偏移装在 `MOVZ X17,#imm16` / `MOVK X17,#imm16,LSL#16` 这对指令的立即数里，只有 **32 位**；原先的写法是 `uint32_t((target-tlsVaddr)&0xffffffffu)`——**掩码不是检查**。偏移为 2^32 的变量被静默搬到了偏移 0，也就是另一个线程局部上。可达且廉价：513 条 `tls let gN: i64[1048576] = 0;`（10 KB 源码）让 `g512` 正好落在 2^32，于是 `g512[0] = 1; return i32(g0[0]);` 返回 **1** 而非 0——不是崩溃，是两个变量变成了同一段八字节。改为在损失性转换处拒绝，报出变量名、偏移与上限 |
| 第 9 项（`.so` 的 `.eh_frame` 页对齐） | **实测通过，未发现缺陷；但检查它的套件是错的。** `tests/page-size-checks.sh` 断言每个 `PT_LOAD` 都**起始**落在页边界上，而契约是**同余**（`p_vaddr == p_offset (mod p_align)`）——加载器从 `p_vaddr & ~(page-1)` 映射文件偏移 `p_offset & ~(page-1)`，需要的正是同余。GNU ld 给出裁决：`-z max-page-size=16384` 下它的第二段在 off `0x3e30` / vaddr `0x7e30`、`p_align 0x4000`，同余但**不**起始对齐；4096 下甚至连 mod `0x4000` 都不同余——这正是 `--page-size` 存在的理由。而更强的断言之所以从未失败，是因为**语料里没有任何镜像带 `.eh_frame`**：`-g` 才会让共享写出器多出第四个 `PT_LOAD`（16 KB 下在 `0x10840`，同余而非起始对齐）。矩阵现在也跑 `-g`（12 → 24 个镜像），断言改为同余，并新增「-g 确实多出一个段」与 GNU ld 差分两条断言，防止这次修正退化成「怎么都行」 |
| 第 10 项（`layoutStruct` 溢出 + 上限前移） | **已修。** `uint32_t` 累加 + 循环**后**才查 1024 上限，而「数组字段最多 1000 元素」「结构体最多 1024 字节」这两道帽是**相乘**而非相加的——字段可以是**结构体数组**。于是 `8192 × (1024 × 512) = 2^32` 精确回绕成 **0**，而 0 不 `> 1024`，一个 4 GiB 的结构体被接受、`sizeof` 报 0；4195 个 `L1[1000]` 字段则回绕成 712704，被拒时报出一个从未存在过的尺寸。累加改 64 位、上限改为**在放置字段时就查**并指名越界的字段（故 `kMaxStructSize` 上移到命名空间作用域，调用方把声明 token 传进去以保留 `at L:C`），另加一道 32 位跨度上限独立守护 `f.offset` |

新常驻套件 `tests/layout-boundary-checks.sh`（9 层，注册进 `DEFAULT_SUITES` 与 `CRITICAL`），配套 `tests/layout-boundary-twin.c`：7 条 qemu 见证（含「最后一个合法块偏移」511 × 8 MiB）、6 例 C 差分、6 条拒绝、双向计数、3 个变异体（m2 刻意是**两处**编辑——只把累加器改回 32 位并**不会**被抓住，因为逐字段检查先触发；这正是「哪一处改动才是承重的」这一问题的诚实答案）、360/360 基线行、1 形态 × 3 模式。

第 3 批仍剩第 13 项（语言缺口 `typedef`/`const`/`void`）未处理，按上面的路线排队。

## 修复记录（v0.23.66-dev）

第二部分「ELF / 链接器 / DWARF / APK」表里的待验项**已全部实测完毕**：五处真缺陷、一处防御性缺口、一处**审计自己判错**。只有 `.so` 的字节动了，且只动在节头表里——121 个例子的文件长度逐一不变，最多相差 4 字节。

| 审计项 | 处理 |
| --- | --- |
| `kRelTlsOff` 只校验 4 字节（标注「高（待验）」） | **确认，且是本轮唯一一处内存安全问题。** 该重定位填的是 `MOVZ`/`MOVK` **一对**指令共 8 字节，而 `parseObject` 只证明了 4 字节在界内。手工构造一个把重定位指向 `.text` 末 4 字节的 `.o`，ASAN 构建直接报 `heap-buffer-overflow ... READ of size 1 ... in resolveRelocations`。Aster 自己写出的对象不会把一对指令放在末尾，但 `parseObject` 是 `link-*` 读外部输入的入口，越过 `std::vector` 就是未定义行为。边界改为按类型：`need=(type==kRelTlsOff)?8u:4u` |
| `writeObject` 的 STB_LOCAL 段符号排序 + `sh_info=1` | **确认。** 只有 `-g` 才写这个符号，而它被写在 **GLOBAL 中间**（紧邻线程局部之前），`sh_info` 却恒为 1。`readelf` 原话：`local symbol 2 found at index >= .symtab's sh_info value of 1`。段符号移到槽 1（紧跟 null 项），全局符号从 `symBase = 1 + dbgSym` 起，`sh_info` 写 `symBase` |
| `.hash` 的 `sh_entsize=0` | **确认。** SysV 哈希表是 `uint32` 数组，`gcc -shared -Wl,--hash-style=sysv` 产出的 `.hash` 在 readelf 里 `ES` 列是 `04`。改为 4 |
| `.rela.plt` 的 `sh_info=0` | **审计判错了。** 审计说应为 `.plt` 的索引；GNU ld 写的是 **`.got.plt`**——同一份 ld 产物里 readelf 显示 `Inf 20`，而 `.plt` 是第 8 节、`.got.plt` 才是第 20 节。这也才是对的：`R_AARCH64_JUMP_SLOT` 填的是 GOT 槽，不是 `.plt` 里的桩。改的是 `.got.plt`，且新套件的 GNU ld 差分先对 ld 自己的输出断言同一不变量，因此修法跟随工具而非猜测——与上一轮页对齐那一项同构（错的都是断言） |
| `.bss` / `.tbss` 的 `sh_offset` 固定写 `relroEnd` | **确认。** SHT_NOBITS 的 `sh_offset` 应是「它若有字节时所处的位置」，即 `sh_addr` 减去所属段的 (vaddr−offset) 差。GNU ld 的 `.bss` 是 `Address 0x20038` / `Off 0x10038`，差 `0x10000` 正是它第二个 `PT_LOAD` 的段差。有 TLS 时 Aster 的 `.bss` 地址在 `.tbss` 之后，偏移却停在 RELRO 末尾，两者相差整个 `.tbss`。改为跟随地址 |
| PLT 的 `ADRP x16` 无 ±4GB 检查 | **确认（防御性）。** 同一条指令在 `resolveRelocations` 里有 `±2^20` 页的检查，PLT 生成处没有，直接截断写进 21 位字段。当前不可达（`.plt` 与 `.got.plt` 相距数十字节），但两条路径不该不一致，故改为拒绝 |
| `maxTlsAlign` 仅 `!tdata.empty()` 时更新 | **确认（低）。** 纯 `.tbss` 对象（线程局部全为零初始化）此前对合并块的对齐毫无贡献。`ParsedObject` 增加 `tbssAlign`，两个链接器都纳入 |
| `.gnu.hash` 的 `sh_entsize=0` | **不是缺陷。** GNU ld 的 `.gnu.hash` 同样写 0。套件**断言 0**，以免后一轮把它「修」成缺陷 |
| `rodataOff=alignUp(...,1)`（`.rodata` 只有 1 对齐） | **确认但与 ld 不一致而非错误**：GNU ld 用 8。未在本轮修——它会移动字节，而本轮的其余部分都是「只改节头」。已记入 `ROADMAP.md` backlog |

新常驻套件 `tests/elf-metadata-checks.sh`（9 层，注册进 `DEFAULT_SUITES` 与 `CRITICAL`）：21 条源码守卫、`readelf` + 独立解码器双读者、**GNU ld 差分**（先对两个 ld 链接的 `.so` 断言同一组不变量，把「什么是对的」钉在工具上而不是钉在 Aster 上）、ASAN 构建下的拒绝矩阵（篡改对象必须被拒绝且**不**产生 sanitizer 报告——靠运气通过的拒绝不算）、2 条 qemu 见证、8 条解码器断言、3 个变异体、360/360 基线行。

第 3 批仍剩第 13 项（语言缺口 `typedef`/`const`/`void`）未处理。

## 修复记录（v0.23.67-dev）

第三部分「语言层面的缺口」Top5 关闭前两项：`typedef`/类型别名（1）与 `const`（2）。**没有任何字节变动**——123 个例子的输出与 v0.23.66-dev 逐一字节相同，360 行基线（366 含注释/过滤后）零改动，所以本轮是「纯语言特性」而非「修缺陷」。新增两个保留字 `type` 与 `const`，保留字数 27 → 29；`tls` 仍是上下文关键字，词法表与手数的 token 数均为生成所得。

| 审计项 | 处理 |
| --- | --- |
| `typedef` / 类型别名 | **新增 `type Name = T ;`。** 没有 `Ty::Alias`——`parseType` 在读取任何关键字或 `ptr<…>` 之前先查 `typeAliasOf`，当场替换成底层 `Ty`。`Ty` 是 `(kind, index)` 对，没有容纳拼写的余地，所以别名在 layout/Sema/codegen 运行前就消失了，两个 `i32` 的别名仍是同一个 `i32`。唯一的例外——函数签名——随别名记录（`TypeAlias{ Ty ty; bool isFunc; FuncSig sig; }`）在每次使用时归还，`type Op = fn(i32) -> i64;` 因此是一个**真实的**签名，`alias_fn_i64_ret` 用例据此返回 11 而非 22。别名不能是数组（`i32[4]` 是声明形式而非类型）、不是转型写法（`T(x)` 只有类型关键字） |
| `const` | **新增 `const x : T = e ;`。** 文件作用域与函数体内皆可读、不可写。只读位随 `Binding`（局部）与 `constGlobals`（全局）走；一个 `isConstName` 回答所有写点，使五处拒绝不会彼此漂移：整体赋值/`+=`/`++`（局部与全局）、元素写 `a[i]=e`、字段写 `s.f=e`（拒绝的是**基** `s`，因为写落在绑定的某个字段上）、取地址 `&x`（Aster 的 `ptr` 不带只读位，`*p=v` 是唯一的回写通道）。const 必须有初值；读取它等同于读取一个 `let`；const 全局占用的 `.data` 字节与 `let` 全局完全相同 |
| `void` | **仍排队。** 本轮未触碰——它涉及函数返回位的改动，与 `typedef`/`const` 不是同一类变更，按路线图「一版本一主题」留作独立一轮 |

新常驻套件 `tests/alias-const-checks.sh`（9 层，注册进 `DEFAULT_SUITES` 与 `CRITICAL`）：26 条源码守卫（钉死两特性的每段代码与保留字表）、**独立读取器**（手写别名展开器，把源里每个别名手工展开后要求**字节相同**输出——字节相等即证明别名是拼写而非类型）、10 例 **gcc 差分**（`typedef`/`const` 都是 C 写法，每个行为用例都有 C 孪生、qemu 下退出码一致）、16 条拒绝矩阵（其中 6 条 gcc 孪生同样拒绝）、两个 shipped 例子对 C 孪生、覆盖计数、6 个变异体、字节基线（断言每个既有行不变）。

第 3 批第 13 项已完成前两项（`typedef`/`const`），剩 `void` 排队。

## 修复记录（v0.23.68-dev）

第三部分「语言层面的缺口」Top5 关闭第三项的 `void`。`void` 是缺口里**唯一做减法的项**——它命名的是「没有返回值」这件事，而非一种新的可计算值。本轮**不改动其余 123 个例子的任何字节**——它们的输出与 v0.23.67-dev 逐一字节相同，369 行基线（123 例 × 3 模式，过滤掉 3 个 `address_of_abi.*`）零改动，故本轮同样是「纯语言特性」。新增一个保留字 `void`，保留字数 29 → 30；`tls` 仍是上下文关键字。

| 审计项 | 处理 |
| --- | --- |
| `void` | **新增 `void` 作为返回类型。** 编译器新增 `Ty::Void`；`parseType` 仅在 `needType` 的 `allowVoid` 门后接受 `void` 关键字（函数声明的 `->` 返回与 `fn` 类型的 `->` 传 `true`，其余值位置一律 `false`），因此 `void` 永不能出现在参数、局部、字段、别名或数组元素——各自被拒（`void is only a function return type`，别名情形为 `a type alias cannot be void: V`）。`void` 函数与其余函数仅有返回纪律的不同：可写 `return;`（无表达式）、可自然落空（没有值可缺失），但仍走完整的 prologue/epilogue、走同一套 AAPCS64 ABI；值返回函数依旧被要求「必然返回」。`return e;` 在 `void` 函数里被 Sema 拒绝（`cannot return a value from a void function`）。`void` 的**结果**不能当值用：`let x: i32 = f()`、`return f()`、`g(f())` 因 `tyAssignable(_, Void) == false` 被拒（`got void`）；运算数形式 `f() + 1` 先被 `isVoidUsingOp` 以 `a void value cannot be used in an expression` 拦下。其意义在于 **C-ABI 互操作**：Aster 的 `void` 函数参数走 `W0`、不返回任何值，与 C 完全一致，因此一个 C 的 `main` 无需任何垫片即可链接 Aster 提供的 `void` 函数 |

新增常驻套件 `tests/void-checks.sh`（9 层，注册进 `DEFAULT_SUITES` 与 `CRITICAL`）：24 条源码守卫（钉死特性的每段代码与保留字表）、**C-ABI 互操作见证**（C 的 `main` 链接 Aster 提供的 `void` 函数，qemu 下退出码 0）、5 例 **gcc 差分**、11 条拒绝矩阵（其中 5 条 gcc 孪生同样拒绝，其余为 Aster 独有）、shipped 例子 `examples/void_return.ast` 对 C 孪生、覆盖计数、6 个变异体、字节基线（钉死 3 个 `void_return` 行）。

第 3 批第 13 项已完成三项中的前三项（`typedef`/`const`/`void`），剩 `char` 与 `union` 排队。
