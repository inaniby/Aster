# Aster 第二轮全量源码审计报告

**审计对象**：Aster 编译器 v0.23.72-dev（源码与 v0.23.71-dev 的 `d5f073b9` 字节相同，仅版本号不同）
**审计基准**：`src/aster.cpp` 13,778 行、`bootstrap/aster.ast` 5,475 行、128 个常驻套件、127 个例子、378 行冻结字节基线、3 个 APK gate
**审计方法**：五路并行只读源码审阅 → 30 个候选条目 → 逐个编译探针在 `qemu-aarch64` 上实测 → 每项配对照组 / C oracle / 反汇编 / ELF 节头手术 → 只保留有复现证据的项
**状态**：**确认 13 个真缺陷（2 个 P0、8 个 P1、3 个 P2），另有 7 项门禁有效性元发现。本轮为纯审计轮，不改编译器、不改门禁；缺陷按 §8 的路线留待后续版本修复。**

> **后续状态（v0.23.74-dev）**：F-03/F-04/F-05/F-06 + F-11 五个前端语义缺陷已按 §8 修复并推送，配两个 9 层常驻套件、两个 shipped examples、两个 C 孪生与 12 个全数捕获的变异体；实测 384 行继承基线零漂移，新增 6 行。**本报告保留审计当时的原始结论，不改写**；下面各节对缺陷机理与复现的描述仍是对 v0.23.72-dev 的准确记录。详见 `VERSION_HISTORY.md` 的 v0.23.74-dev 条目与 `VALIDATION-v0.23.74-dev.md`。
>
> **后续状态（v0.23.73-dev）**：F-01 与 F-02 两个 P0 已按 §8 修复并推送；其余 11 个缺陷（8 P1、3 P2）、7 项门禁元发现、6 项静态观察与 K-01 治本项仍开放，继续按 §8 路线排队。修复落在 `layoutArgs`、caller 栈循环与新增的 `emitScaledAdd`，配两个 9 层常驻套件和两个 shipped examples；实测 378 行继承基线零漂移。详见 `VERSION_HISTORY.md` 的 v0.23.73-dev 条目与 `VALIDATION-v0.23.73-dev.md`。**本报告保留审计当时的原始结论，不改写**；下面各节对缺陷机理与复现的描述仍是对 v0.23.72-dev 的准确记录。

> **本轮最重要的一句话**：v0.23.71-dev 的门禁是 `128 passed, 0 failed / APK 3 passed`，字节基线 378 行零漂移。在这样一条全绿的门禁下，一次只读审阅加 60 余个探针挖出了两个 P0 和八个 P1。这不是巧合，而是 §4 里那七个门禁元发现的直接后果——**一个全绿的 CI 不等于没有 bug**，这是 v0.23.61-dev 审计元发现的重演，且这次更严重：本轮两个 P0 都能被「变量下标 + 运行时实参」这种最普通的组合探针捕获，而既有 128 个套件几乎全用常量下标和常量右值。

---

## 1. 范围、方法与纪律

### 1.1 五路划分

| 路 | 主题 | 主要行号区间 |
| --- | --- | --- |
| 一 | 前端与语义层 | 219–488 Lexer；489–808 Ty/布局；810–1149 Expr/Stmt/Global；2369/3040 常量折叠；2506–2627 标签表；7094 编译期越界检查 |
| 二 | 代码生成与调用 ABI | 3229–6339 Codegen；4899–4910 `layoutArgs`；4951/5063 地址缩放；5425/5464 实参写出；5630/5713 比较；4641/4834 除法 |
| 三 | ELF 写出器与链接器 | 6340–6597 `writeElfBytes`；8928–9128 `writeObject`；9129–9500 `parseObject`/重定位；9501–9960 `writeSharedObject`；10573–10923 `link-so`/`linkObjects` |
| 四 | 调试信息、APK 与外围 | 8457–8927 DWARF；11074–13778 SHA256/Big/DER/ZIP/AXML/PNG/签名/CLI；1367–1445 `@embed` 路径解析 |
| 五 | 门禁有效性与自举链 | `tests/ci.sh`、`ci-protocol-checks.sh`、`lib/verdict.sh`、`lib/baseline.sh`、变异层、`bootstrap/aster.ast`、`codegen-twin` |

### 1.2 验证纪律

- **推断不算缺陷**。五路审阅员被要求只读、不编译、不改文件；返回的每个「确认缺陷」都只是源码推断，必须实测。
- **严格编译**。审计对象用 `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror` 重建后使用。
- **每个异常项配对照组**：同类但走正确代码路径的程序（非 2 幂 stride、全标量参数、同符号比较、align=16 节头、被正确拒绝的常量下标等）。
- **第三方 oracle**：C 语义用 `aarch64-linux-gnu-gcc -static -O2` 编译的同源 C 程序在 qemu 上跑；AArch64 编码用 `aarch64-linux-gnu-objdump -d` 读回实际发射的指令；ELF 契约用 `aarch64-linux-gnu-readelf -SW/-lW`。
- **ELF 节头手术**：`parseObject` 接受外部对象节头 `addralign ≤ 65536`，而 Aster 自己写出的对象只声称 16/64。为触达高对齐路径，用 Python 直接改 ELF64 `Shdr+48` 的 `sh_addralign` 字段，再走 `build-obj → link-obj / link-so`。
- **低 8 位陷阱**。进程退出码只保留低 8 位；第一轮探针因此出现两个假阴性（`10852 & 0xff = 100`、`10752 & 0xff = 0`）。凡涉及「读回值是否正确」的判定，一律改用 `if (v == expected) return 0; return 1;` 的条件返回，不直接返回读回值。

### 1.3 分级标准

| 级别 | 判据 |
| --- | --- |
| **P0** | 合法程序崩溃（SIGILL/段错误），或静默产出错误结果且影响常见合法组合 |
| **P1** | 语义/契约错误，影响较窄或需要特定输入，但结果不正确 |
| **P2** | 一致性、互操作性或依赖特定威胁模型的偏差，不构成普遍误编译 |

### 1.4 与上一版审计的关系

v0.23.61-dev 审计发现的 4 个 P0（多维下标赋值求值顺序、结构体数组字段寻址顺序、`*p=v` 右值宽度、bool 转换只比低 32 位）与 5 个 P1 已在 v0.23.62–v0.23.70 分批修复，本轮**不重复报告**。已修的 ELF 节头项（`kRelTlsOff` 8 字节越界、段符号排序/`sh_info`、`.hash entsize`、`.rela.plt sh_info`、`NOBITS sh_offset`、PLT ADRP ±4GB、纯 `.tbss` TLS 对齐、`.rodata addralign=1`）同样不重复。C1/C2/C3 是这些修复之后**仍残留的另一侧**（起点对齐），已在各项里注明区分。

---

## 2. 结论总表

五路共提出 30 个候选条目（20 项标「确认缺陷」、10 项标「待实测」）。第二路第 3、4 项经实测合并为同一根因，故按 29 个独立 verdict 计。

| # | 路 | 条目 | verdict | 级别 |
| --- | --- | --- | --- | --- |
| F-01 | 二 | `layoutArgs` 参数落栈后 `ngrn` 未置 8 → 实参整体丢失 | **确认** | **P0** |
| F-02 | 二 | `sh<<10` 溢出 imm3 / option → 保留编码或缩放丢失 | **确认** | **P0** |
| F-03 | 一 | u64 全局常量表达式被 i64 有符号溢出语义拒绝 | **确认** | P1 |
| F-04 | 一 | 标签命名空间交叉漏检（顺序依赖，alias 被静默遮蔽） | **确认** | P1 |
| F-05 | 一 | `switch(enum)` 的 case 值不做范围检查，静默截断 | **确认** | P1 |
| F-06 | 一 | 溢出常量绕过编译期数组越界检查并回绕到数组起点 | **确认** | P1 |
| F-07 | 二 | 宽比较/除法按「任一操作数无符号」选条件码与 UDIV | **确认** | P1 |
| F-08 | 三 | `.tbss` 起点固定 16 对齐，却声明 `addralign = maxTlsAlign` | **确认** | P1 |
| F-09 | 三 | `.data/.bss` 起点只按 `pageSize` 对齐，却声明大对齐 | **确认** | P1 |
| F-10 | 三 | `link-so` 的 `maxTlsAlign` 是死变量，PT_TLS 恒 16 | **确认** | P1 |
| F-11 | 一 | `DerefAssign` 不做右值类型检查 | **确认** | P2 |
| F-12 | 三 | `parseObject` 误拒 `addralign = 0` 的合法 TLS/数据节 | **确认** | P2 |
| F-13 | 四 | `@embed` 无绝对路径/穿越/symlink 约束 | **确认（威胁模型依赖）** | P2 |
| G-01 | 五 | 零断言套件 `exit 0` 被判 `PASS` | **确认（实测）** | 门禁 |
| G-02 | 五 | APK gate 一键跳过而终判仍绿 | **确认（实测）** | 门禁 |
| G-03 | 五 | 三向差分拒绝路径无 oracle | **静态确认** | 门禁 |
| G-04 | 五 | 覆盖棘轮是静态 grep + 硬编码 floor，可回退 7 个套件 | **静态确认** | 门禁 |
| G-05 | 五 | 字节基线只钉 3 个写出器，并豁免一个 example | **静态确认** | 门禁 |
| G-06 | 五 | 部分套件变异用整文件 hash 差分而非不变量 | **静态确认** | 门禁 |
| G-07 | 五 | 并行分组靠 grep 字面 `/tmp/` | **静态确认** | 门禁 |
| S-01 | 三 | `resolveRelocations` 对 `r.patch` 无边界检查 | 静态确认，未动态复现 | 观察 |
| S-02 | 三 | `writeSharedObject` 传统路径把 kind3 压成 `.bss` | 审阅员自承疑不可达 | 不报 |
| S-03 | 四 | `derChildren` 子节点可越出父 SEQUENCE 边界 | 静态确认，未动态复现 | 观察 |
| S-04 | 四 | `build-apk` 预编译 `.so` 与 `--page-size 16384` 组合无校验 | 静态确认，未动态复现 | 观察 |
| S-05 | 四 | 原子写忽略目录 `fsync` 返回值 | 静态确认，需 LD_PRELOAD | 观察 |
| S-06 | 四 | `rsaPublicKey` 用 `derSlice().size()` 而非 `.len` 验 OID | 静态确认，长格式本非法 | 观察 |
| S-07 | 四 | `divmod` add-back 的 `qhat` 下溢 | 未复现，需 fuzz | 观察 |
| S-08 | 四 | `size2+8` uint64 回绕 | 审阅员自承被 L12861 挡住 | 不报 |
| X-01 | 一 | 数字分隔符 `0x_a` 因 `isalnum` 被接受 | **误判** | — |
| K-01 | — | `typeOf` / `exprType` 语义分歧、TypedIR 豁免名单 | 已知治本项，沿用上一版 | 技术债 |

**统计**：13 个确认缺陷（P0×2、P1×8、P2×3）；7 项门禁元发现；6 项静态确认待动态、2 项不报；1 项误判；1 项已知治本项。

---

## 3. 确认的缺陷

### F-01（P0）AAPCS64 落栈实参整体丢失

**位置**：`layoutArgs` 4899–4900；调用方寄存器循环 5425、栈循环 5464；callee 读取 6287–6319。

**机理**：`layoutArgs` 在 `ngrn + need > 8` 时把参数放到 `stackOff[i]`，但**没有按 AAPCS64 C.12 把 `ngrn` 置为 8**。于是当第 8 个参数（下标 7）是一个 9–16 字节聚合（`need = 2`，`ngrn = 7` 放不下）时：

- 寄存器循环 `for (i < min(8, nargs))` 遇到 `lay.reg[7] < 0` 就 `continue`；
- 栈循环 `for (i = 8; i < nargs; ++i)` 从 8 开始，永远不处理下标 7；
- **该实参从未被拷进 outgoing area**，callee 从 `[SP + 8192 + stackOff[7]]` 读到未初始化字节。

`ngrn` 未置 8 还使后续标量被塞进 x7，与真实 AAPCS64 外部调用不符。

**复现**（`p06_stack_arg_lost.ast`）：

```aster
struct T { a: i32, b: i32, c: i32 }
fn sum(p:i32,q:i32,r:i32,s:i32,t:i32,u:i32,v:i32,w:T)->i32 {
    return w.a + w.b + w.c;
}
fn main()->i32 { return sum(1,2,3,4,5,6,7,T{10,20,30}); }
```

预期 `60`，实测 `EXIT=0`（三个字段全读到 0）。

**对照组（精确界定边界）**：

| 探针 | 布局 | 实测 | 说明 |
| --- | --- | --- | --- |
| `r2_1b` | 8 个标量（1+2+…+7+60） | `88` | 全进 x0–x7，正确 |
| `r2_1c` | 6 标量 + `T` 落 x6/x7 | `60` | 聚合未落栈时正确 |
| `r2_1d` | 9 个标量，第 9 个落栈（`ngrn` 已 = 8） | `9` | 纯栈参正确 |

三条对照证明这**不是**聚合传参整体坏，也不是栈参机制坏，而是「前 8 个参数内出现因放不下而落栈的参数」这一唯一窗口。

**建议修法**：落栈分支里 `ngrn = 8`；栈循环改为遍历全部 `nargs` 并跳过 `lay.reg[i] >= 0` 者，使下标 < 8 的落栈参数同样被写出。

---

### F-02（P0）`sh<<10` 溢出：保留编码触发 SIGILL，大 stride 静默错址

**位置**：`emitElemStride` 5063–5067、`emitElemIndex` 4951、`elemShiftOf` 690–700。

**机理**：两处都发射 `ADD X16, X16, Wm, UXTW #sh`，把 `sh` 放在 `bit 13` 的 option 字段（`0b010 << 13`）与 `bit 10` 的 imm3 字段（`sh << 10`）。AArch64 规定 **UXTW 的 imm3 只允许 0–4**：

| sh | `sh<<10` OR `0b010<<13` | 实际编码 | 后果 |
| --- | --- | --- | --- |
| 0–4 | `0x4000..0x5000` | `UXTW #0..#4` | 正确 |
| 5–7 | `0x5400/0x5800/0x5c00` | `UXTW #5/#6/#7` | **保留编码 → SIGILL** |
| 8 | `0x6000` | option `011` = `LSL #0`（`uxtx`） | 缩放 ×1 而非 ×256 |
| 9 | `0x6400` | `LSL #1` | 缩放 ×2 而非 ×512 |
| 10 | `0x6800` | `LSL #2` | 缩放 ×4 而非 ×1024 |

非 2 幂 stride 走 `UMADDL` 分支，反而是对的——**缺陷只命中 2 幂且 ≥ 2^5 的 stride**。

**复现与证据**：

| 探针 | stride | 实测 | objdump |
| --- | --- | --- | --- |
| `s2`/`s4` | 2^3/2^4 | `EXIT=0`（正确） | `uxtw #3` / `uxtw #4` |
| `s5`/`s6`/`s7` | 2^5/2^6/2^7 | **`EXIT=132` core dump** | `undefined` |
| `s8`/`s9` | 2^8/2^9 | `sc_8`/`sc_9` `EXIT=1`（首元素被覆写） | `uxtx` |
| `s10` | 2^10 | `sc_10` 假阴性 `0`，`sc_10b` `EXIT=1`（`a[0][1]` 被误写） | `uxtx` |
| `c7`/`c63`/`c3`/`c5` | 非 2 幂 | 全 `EXIT=0`（正确） | 仅内层 `uxtw #2` |
| `struct32b` | 32 字节结构体元素 | **`EXIT=132`** | `undefined` |

`r2_4.elf` 反汇编逐条坐实：`8b215610` 即 `ADD X16,X16,W1,UXTW #5`，objdump 标 `undefined`，QEMU 抛 SIGILL。`s8.elf` 里 `8b216210` 是 `add x16,x16,x1,uxtx`，`a[1][0]=42` 因此写到 `sp+1` 而非 `sp+256`，`a[0][0]` 读回 `0x00002A00 = 10752`——正是 v0.23.61-dev 之后本轮报告预测的「10852」同类值，被退出码低 8 位伪装成 100。

**影响面**：不止多维数组的行 stride。`emitElemIndex` 用 `elemShiftOf(Ty)`，任何**元素大小 32/64/128 字节**的数组（如 8 字段 i32 结构体，`struct32b`）都走同一条坏编码。

**建议修法**：`sh > 4` 一律改走 `UMADDL`（乘法）分支；`emitElemIndex` 与 `emitElemStride` 两处都要限。并补一个「每个 2 幂 stride 从 2^0 到 2^12 都跑变量下标写后读」的常驻套件。

---

### F-03（P1）u64 全局常量表达式被 i64 有符号溢出语义拒绝

**位置**：2369（全局初始化器 `__builtin_add_overflow`）、3040（折叠）。

| 探针 | 程序 | 实测 |
| --- | --- | --- |
| `r1_1a` | `let g: u64 = 9223372036854775807 + 1;` | **REJECTED** `addition overflows i64 in global variable initializer` |
| `r1_1b` | `let g: u64 = 9223372036854775808;` | `BUILD_OK`（Num 分支接受） |
| `r1_1c` | 局部 `let c: u64 = a + b;`（a=2^63-1, b=1） | `BUILD_OK`（运行时 64 位回绕） |

同一个值，单字面量合法、局部运行时合法、全局常量表达式却被拒。这是编译期/运行时语义分歧，不是有意的限制（同一文件 955–958 已明确 `U64` 保留每个位模式）。

---

### F-04（P1）标签命名空间交叉漏检，顺序依赖

**位置**：2506–2508、2570–2572、2623–2627、1235–1236。

| 探针 | 程序 | 实测 |
| --- | --- | --- |
| `r1_2a` | `type P = i32;` 后 `struct P { x: i32 }` | `BUILD_OK`（重复标签未被拒） |
| `r1_2b` | 反序 `struct P` 后 `type P = i32` | REJECTED `type alias conflicts with a struct: P` |
| `r1_2c` | `enum E` 后 `struct E` | `BUILD_OK` |
| `r1_2shadow` | `r1_2a` 之后 `let v: P = 5;` | REJECTED `type mismatch initializing 'v': expected P, got i32` |
| `r1_2shadowctl` | 只有 `type P = i32` | `EXIT=5` |

`r1_2shadow` 证明 alias 不是被「并列保留」而是被 struct **静默遮蔽**：`P` 此后恒解析为结构体，alias 无法再拼写。反序会被拒，说明这是漏检而非设计。enum 名义类型同理会变得无法拼写。

---

### F-05（P1）`switch(enum)` 的 case 值静默截断

**位置**：`caseValueFits` 960 的 `default: return true`；`tyIsInteger` 685 把 Enum 计入可 switch 主题；8137 比较处。

| 探针 | 程序 | 实测 |
| --- | --- | --- |
| `r1_3a` | `enum Color{Red=0}`；`switch(c:Color){case 4294967296: return 1; default: return 0;}` | `EXIT=1`（case 截成 0 撞上 Red） |
| `r1_3b` | 同 case 值，主题改 `i32` | REJECTED `case value does not fit the switch subject type` |

主题为 enum 时 case 不做 i32 范围检查，比较时按主题宽度截断——正是 943–949 注释声称要防的事。`let c: Color = 4294967296;` 本身会被 923 拒，说明这不是有意的宽松。

---

### F-06（P1）溢出常量绕过编译期越界检查并回绕到数组起点

**位置**：7094 `if (!constantInteger(index, value)) return;`；3040 折叠失败。

| 探针 | 程序 | 实测 |
| --- | --- | --- |
| `r1_5a` | `a[9223372036854775807 + 1]`（`i32[4]`） | `BUILD_OK`（检查被跳过） |
| `r1_5b` | `a[4]` | REJECTED `array index out of bounds for 'a': index 4, length 4` |
| `r1_5val` | 同上但 `a = {11,22,33,44}` | `EXIT=11`（读到 `a[0]`） |

溢出使 `constantInteger` 返回 false，编译期越界检查整体跳过；运行时索引按 i64 溢出回绕，地址计算恰好落回数组起点并读到 `a[0]=11`。既有程序「静默读到错误的有效元素」比崩溃更难发现。

---

### F-07（P1）宽比较/除法按「任一操作数无符号」选条件码与 UDIV

**位置**：5630、5713（`comparisonCond(..., tyIsUnsigned(ta)||tyIsUnsigned(tb))`）、4641/4643、4834（UDIV/SDIV）；`promoteInt` 3111。

`promoteInt(i64, u32)` 答 `I64`（有符号 64 位），但条件码与除法却取「任一操作数是无符号」——两处口径不一致，把负 i64 当 2^64 大数。

| 探针 | 程序 | 实测 |
| --- | --- | --- |
| `r2_2a` | `a:i64=-5; b:u32=3; return a<b;` | `EXIT=0`（错） |
| `r2_2b` | `b` 改 `i64` | `EXIT=1` |
| C oracle | `int64_t a=-5; uint32_t b=3; return a<b;` | `EXIT=1` |
| `r2_2div` | `a:i64=-84; b:u32=2; q=a/b; q==-42` | `EXIT=0`（UDIV 得巨值） |
| `r2_2divctl` | `b` 改 `i64` | `EXIT=1` |

C oracle 坐实预期（`int64_t` 能表示 `uint32_t` 全值，b 提升为有符号 64 位）。比较、除法、取模三条同源。

---

### F-08 / F-09 / F-10（P1）对象节对齐声明与写出器布局不一致

三者同源：`parseObject`（9137 `validSectionAlign` 允许 ≤ 65536）与 `linkObjects`（10796/10867）按输入对象的 `addralign` 填充并声明，但写出器对**节起点**只按固定常量对齐。为触达该路径，用 `tests/audit-evidence/v0.23.72-dev/bump_align.py` 改 ELF64 `Shdr+48`。

| # | 位置 | 实验 | 实测 | 对照 |
| --- | --- | --- | --- | --- |
| F-08 | 6447 `tbssFileOff = alignUp(tlsFileEnd, kTlsBlockAlign=16)`；6544/6561 声明 `tlsAlign`；10923 `tbssVaddr` 同样硬编码 16 | `.tdata/.tbss` 声明 32，带一个零初始化 TLS 变量后 `link-obj` | `.tbss Addr=0x402050`，**`0x50 % 32 = 16`** 而 `Align=32`；`.tdata=0x402040` 与 `PT_TLS p_align=0x20` 均正确 | bump 到 16 全绿 |
| F-09 | 6435 `dataFileOff = alignUp(afterRodata, pageSize)`；6552/6559 声明 `dataAlign/bssAlign` | 加 4 字节 `.rodata` 令 `.data` 落到 `0x403000`，声明 8192 | `.data Addr=0x403000`，**`%8192 = 4096 ≠ 0`** 而 `Align=8192` | bump 到 4096 全绿 |
| F-10 | 10573 `maxTlsAlign=kTlsBlockAlign`、10671–10672 更新，但 10687–10754 构造的 `SoDynSpec`（10005–10039 无 tlsAlign 字段）从不引用；10217/10466/10506 全用 16 | `build-obj --pic` + bump `.tdata/.tbss=32` + `link-so` | `PT_TLS p_align=0x10` 恒 16，输出节声明被**降级**成 16；与 bump=16 的产物完全相同 | bump 到 16 一致 |

F-08 与 v0.23.66 修的「纯 `.tbss` 对齐」是不同残留：那次让 `tlsVaddr` 按 `maxTlsAlign` 对齐，本项是 `.tbss` 相对起点仍固定 16。三者都使高对齐 TLS/数据变量落错地址，或让节头声明与地址不自洽。

**F-12（P2）**：同一 `validSectionAlign(a)` 要求 `a >= 1`，而 `.rodata`（9236）特赦 `addralign != 0`；`.tdata/.tbss/.data/.bss`（9237–9242）却直接拒 0。ELF64 规范 `sh_addralign = 0` 与 `1` 等价「无对齐要求」。实测 `bump .tdata=0` → `link-obj` 报 `unsupported .tdata section attributes`，而相同手法的 `.rodata=0` 被放行。`tls0` 实验坐实。

---

### F-11（P2）`DerefAssign` 不做右值类型检查

**位置**：8035 只调 `annotateExpr`；而 `IndexAssign`/`FieldAssign`（7999/8020）都调 `checkValue`。

| 探针 | 程序 | 实测 |
| --- | --- | --- |
| `r1_4a` | `p: ptr<i64>; *p = true;` | `BUILD_OK` |
| `r1_4b` | `a: i64; a = true;` | REJECTED `type mismatch assigning variable: a` |
| `r1_4val` | `*p = true;` 后读 `a` | `EXIT=1`（bool 零扩展成 1） |

运行时结果「恰好合理」，故定 P2：这是类型系统的一致性缺口，不是误编译。同一语句形状在赋值目标不同时校验强度不同。

---

### F-13（P2，威胁模型依赖）`@embed` 无路径约束

**位置**：`resolveEmbedPath` 1367–1373（`if (path[0]=='/') return path;` 直接返回绝对路径；相对路径拼接 `..` 无过滤）；`embedFile` 用 `::stat` 跟随 symlink（1402 附近）。

| 探针 | `@embed` 实参 | 实测 |
| --- | --- | --- |
| `embed_abs` | `/etc/hostname` | `RC=0`，产物含 13 字节 rodata |
| `embed_link` | `link.bin`（→ `/etc/hostname` 的 symlink） | `RC=0`，同样 13 字节 |
| `embed_trav` | `../../../etc/hostname` | `RC=0`，同样 13 字节 |

**限定**：读任意路径与 `#include` 的刻意设计同类，且威胁模型是「编译不受信任的 `.ast`」。本项之所以仍算缺陷，是因为同文件里 `zipNameSafe`（12623）、`writeKeyPair` 的 `lstat` 拒 symlink（11961）、`validateApkInputs`（13224）都做了同等防护——同一编译器对同类输入的处理不一致。定 P2、标注为待拍板的设计决策，不建议无讨论直接收紧（会影响 include 组合）。

---

## 4. 门禁有效性元发现（第五路）

这七项解释了「为什么 128 全绿还能藏住两个 P0」。

**G-01（实测）零断言套件被判 `PASS`**。`ci.sh` 的 `classify_suite`（315–321、360–367）：`rc == 0` 且 `pass_marks == 0` 且 `skip_marks == 0` 时落到 `else` 分支直接 `printf 'PASS\n'`。实测在 `tests/` 放一个只有 `exit 0`、无任何输出的 `zz_audit_probe.sh`，`CI_SUITES=zz_audit_probe.sh sh tests/ci.sh` 得到 `zz_audit_probe.sh  PASS` / `CI SUMMARY: 1 passed, 0 skipped, 0 failed`。套件是否真的断言过，门禁完全不看。

**G-02（实测）APK gate 一键跳过而终判仍绿**。`CI_SKIP_APK_GATE=1`（516–517）使三个 gate 全部 `SKIP`，终判只查 `FAIL`/`GATE_FAIL`。实测：`APK GATES : 0 passed, 1 skipped, 0 failed`，`CI SUMMARY: 1 passed, 0 skipped, 0 failed`，退出码 0。

**G-03 三向差分拒绝路径无 oracle**。`codegen-checks.sh` 122–124 明写「both reject → consistent … does not pin rejection text」，141–142 的 `REJ_BOTH++` 还让双误拒增加计数；`bootstrap-loop-checks.sh` 162–163 自承「both sides can emit the same malformed ELF」。两侧共享 `CODEGEN-SPEC.md` 与生成表，字节一致 ≠ 正确。

**G-04 覆盖棘轮是静态 grep + 硬编码 floor**。`ci-protocol-checks.sh` 319 声称「move up with the project」，387 却是固定 `suite_count >= 121 && examples >= 120 && rows >= 360 && mutations >= 30`。当前是 128/127/378，**删掉 7 个套件仍满足 floor**；变异普查（336）只 `grep -l 'mutant'`，不验证断言真的会失败。

**G-05 字节基线只钉 3 个写出器并豁免一个 example**。`lib/baseline.sh` 56–59 只有 `build-so`/`build-elf`/`build-obj_--pic`（378 = 126×3）；`build-pie`、`build-obj`、`link-*`、`-g`、`--bounds-check`、`--page-size` 的字节漂移无基线。`alias-const-checks.sh` 599/611/622 用 `grep -v '^address_of_abi\.'` 过滤掉三行且硬编码 `rows=378`。

**G-06 部分套件变异用整文件 hash 差分**。`union-checks.sh` 506–512 用 `[ "$o_h" != "$m_h" ]`，任何无关字节变化都算 noticed；`embed-align-checks.sh` 357–365 的 `mut_check` 才是真不变量。前者存在假阳性空间。

**G-07 并行分组靠 grep 字面 `/tmp/`**（`ci.sh` 457）。`wait "$p" || true` 由 422 写 `$OUT/$s.rc` 兜底属刻意设计，但拼接出的固定路径若不含 `/tmp/` 会漏判入并行组。

**组合矩阵缺口（缺陷存活的直接原因）**：第五路给出的四个组合，现有用例全部绕开——`array_index_expr.ast` 的下标是常量 `4`；union 例子全用 `U{5}` / 常量 `q`；`embed-align` 只测六个写出器的默认路径；`multi_dim_array.ast` 未与 AAPCS64 X8 路径组合。本轮 F-01、F-02 恰恰只需要「变量下标 + 运行时实参」就能暴露。

---

## 5. 未确认为缺陷的项

- **X-01（误判）** `0x_a` 的分隔符校验用 `isalnum`：审阅推断剥离后成 `0xa` 返回 10。实测 `r1_6a` 被 `hexadecimal literal has no digits` 拒绝，`r1_6b`（`1_a`）被 `digit separator '_' must be between two digits` 拒绝。hex 分支在剥离前就因无数字失败，推断不成立。
- **S-01 / S-03 / S-04 / S-05 / S-06 / S-07（静态确认，未动态复现）**。这些都在「解析不受信任二进制输入」或「需要 LD_PRELOAD / 真机 / 大规模 fuzz」的路径上，源码证据清楚，但本轮没有构造出能稳定复现的完整输入。**按纪律不计入缺陷**，列为观察项与后续 fuzz 目标。其中 S-04、S-06 的审阅员自己也标注了「设计限制/长格式本非法」。
- **S-02 / S-08（不报）**。审阅员自承 S-02 疑不可达（`13508` 使 rodata 非空必走另一条路径）、S-08 被 L12861 的 magic 校验挡住。
- **K-01 已知治本项**：`typeOf` 对算术节点恒答 `i32`、`exprType` 答提升后宽度，TypedIR 断言因此带豁免名单（6941–6950）。上一版判定「改成任一侧都会动已发布例子的字节」，本轮沿用结论，只标注仍开放，不展开。
- **刻意设计（不计入）**：i32 裸字面量低 32 位截断、下标/字段赋值 `refuseNarrow=false`、union 字面量只初始化首成员、switch 用比较链无跳表、8 KiB 固定帧、ADRP 4 KiB 粒度与 `pageSize=16384` 并存、9485 同余检查、`@embed` align ≤ 4096 使 10493 恒真。

---

## 6. 文档一致性观察

| 位置 | 观察 | 判定 |
| --- | --- | --- |
| `ROADMAP.md:184` | 仍写 `Still open from this area: regression-symtab.sh's ET_REL branch has never executed (only 7 of its 11 fixtures were ever committed)`，而同表 111 行已标 v0.23.71-dev **shipped** | **活声明漂移**，本轮文档批次修正 |
| `AUDIT-v0.23.61-dev.md:4` | 「5 个 P1 缺陷与第二、三、四部分发现仍未处理」；357/377 行「第 3 批仍剩第 13 项（typedef/const/void）」 | 实际 v0.23.62–v0.23.71 已分批全部修完。顶部是活摘要会误导；357/377 是当时批次记录，保留原样，仅加一条顶部注记指向本报告 |
| `README.md:204–209` / `VERSION_HISTORY.md:759–762` | 115/115、360 行、24 套件/155 mutants 等 | **历史版本记录**（描述 v0.23.61-dev 当时门禁），不是活状态声明，不改；仅在本报告记录以免误读 |
| `version-checks.sh` 138–155 | 状态行守卫只扫前 8 行 | 抓不到 backlog 表格里的 `Still open` 这类声明，是 G-04 同类的守卫盲区，列为后续加固项 |

---

## 7. 元发现（本轮）

1. **全绿 CI 不等于没有 bug——而且这次的门槛更低**。v0.23.61-dev 的 4 个 P0 需要「多维下标 + 结构体字段 + 非常量右值」的组合才能触发；本轮两个 P0 只需要「变量下标」与「一个 9–16 字节聚合作为第 8 参数」。缺陷在向更普通的代码路径迁移。
2. **门禁对自己的断言强度没有断言**。G-01/G-02 是两个开关就能演示的假阳性：一个 `exit 0` 的空套件被判 PASS，三个 APK gate 被跳过而终判仍绿。覆盖棘轮（G-04）与变异普查（G-06）都是 grep 级别的证据。
3. **差分测试缺第三方 oracle**。G-03 与「codegen twin 共享生成表」是同一个问题：两侧一致只能证明一致，不能证明正确。本轮凡是能配 C oracle 或 objdump 读回编码的项，结论都与纯源码推断不同（F-02 的退出码假阴性、X-01 的误判尤其明显）。
4. **字节基线钉住的是 3 个写出器，不是全部契约**。F-08/F-09/F-10 这类「节头声明与节地址不同余」的缺陷不改变任何既有例子的字节，因此 378 行零漂移对此完全无感。
5. **审计方法本身需要防假阴性**。本轮两处「推断正确但探针无效」：F-02 第一版复现用常量下标（stride 被折叠，写读同路径自洽），F-01/F-02 的退出码被低 8 位截断。**探针必须能区分「正确」与「碰巧看起来正确」**。

---

## 8. 建议修复路线（后续版本，一轮一主题）

| 建议版本 | 主题 | 内容 |
| --- | --- | --- |
| v0.23.73-dev | **修 F-01 + F-02 两个 P0** | `layoutArgs` 置 `ngrn=8` 并重写栈循环；`emitElemIndex`/`emitElemStride` 对 `sh>4` 走 UMADDL。两者都需新建 9 层常驻套件（含 2^0..2^12 全谱 stride、变量下标写后读、AAPCS64 落栈参数矩阵 + C 孪生）。**注意**：可能改变含这些组合的例子的字节，需重录基线并复核 378 行漂移范围。**（已于 v0.23.73-dev 落地：实测 378 行继承基线零漂移，新增 6 行。）** |
| v0.23.74-dev | 前端语义四项 | F-03/F-04/F-05/F-06 + F-11。常量折叠统一到 u64 语义、标签表统一交叉检查、`caseValueFits` 补 Enum、越界检查对折叠失败显式报错。**（已于 v0.23.74-dev 落地：384 行继承基线零漂移，新增 6 行；两个 9 层套件，12/12 变异体捕获。）** |
| v0.23.75-dev | 符号性 | F-07。比较/除法/取模按 `promoteInt` 的结果选条件码，配 i64 × 各窄类型矩阵与 C oracle |
| v0.23.76-dev | ELF 对齐契约 | F-08/F-09/F-10/F-12。节起点一律按声明的 maxAlign 对齐、`SoDynSpec` 增加 tlsAlign、`validSectionAlign` 对 0 归一到 1。配 `readelf` 断言「Addr % Align == 0」的常驻套件 |
| 后续 | 门禁加固（G-01…G-07） | `classify_suite` 要求 `pass_marks > 0`；CRITICAL 纳入元门禁；棘轮 floor 改为随版本生成；基线扩展六个写出器；变异层统一走不变量；F-13 作为设计决策单独拍板 |
| 后续 | 观察项动态化 | S-01/S-03/S-04/S-05/S-06/S-07 用构造输入 / LD_PRELOAD / fuzz 补齐实证；K-01 治本项需先定语义口径 |

---

## 9. 附录：证据与复现

- **探针语料**：`tests/audit-evidence/v0.23.72-dev/`（`EVIDENCE.md` 含逐项命令、实测输出与对照结论；`*.ast` 为可直接编译的最小复现；`bump_align.py` 为 ELF 节头手术工具）。该目录**不注册进 CI**，是只读证据，不是常驻套件。
- **工具链**：`g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror`、`qemu-aarch64`、`aarch64-linux-gnu-gcc -static -O2`、`aarch64-linux-gnu-objdump -d`、`aarch64-linux-gnu-readelf -SW/-lW`。
- **通用运行方式**：

```sh
./aster build-elf <probe>.ast -o /tmp/<probe>.elf
qemu-aarch64 /tmp/<probe>.elf; echo "EXIT=$?"
aarch64-linux-gnu-objdump -d /tmp/<probe>.elf | grep -E 'uxtw|uxtx|undefined'
```

- **本轮门禁**：见 `VALIDATION-v0.23.72-dev.md`。审计轮不改编译器、不加常驻套件，字节基线从 v0.23.71-dev 原样复制（378 行零漂移），全量 `ci.sh` 仍应 128/128 全绿——这本身就是 §7 元发现 1 与 4 的现场证据。
