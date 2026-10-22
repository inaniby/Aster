# M3d Codegen Specification (frozen)

> **状态**：契约先行冻结（v0.23.46-dev）。本规格对齐 `SELFHOSTING-PLAN.md` M3 流水线
> 「词法→语法→类型检查→**生成 AArch64 字节 → 写出 ELF**」的最后两段，是
> `bootstrap/aster.ast` 代码生成趟与 `tests/codegen-twin.c` 差分孪生的共同契约。
> 上游契约：`bootstrap/LEXER-SPEC.md`（M3a）、`bootstrap/PARSER-SPEC.md`（M3b）、
> `bootstrap/SEMANTIC-SPEC.md`（M3c，符号表与 `ex_ty` 由它填好，本规格直接消费）。
>
> **轮次性质**：无编译器改动轮——宿主 `src/aster.cpp` 只改版本常量
> （`0.23.45-dev` → `0.23.46-dev`），全文字面量仍仅 1 处。宿主 `build-elf`
> 的功能等价参照地位见 §11；孪生字节一致性条款见 §12。
>
> **每条指令编码都经 `aarch64-linux-gnu-as` 实证**（objdump 复核），不是手推。

---

## 1. 状态与范围

**输入**：stdin 上一份 Aster 源（M3a 词法、M3b 语法、M3c 语义已依次通过，
`sema(prog)` 返回 0）。**输出**：stdout 上一个可独立运行的 AArch64 ELF 可执行文件
（ET_EXEC），`qemu-aarch64 <file>` 直接运行；进程退出码/ stdout 即程序语义。

**语言子集**（= M3b 解析器能产出的全集，M3d 不做任何放宽）：

| 维度 | 内容 |
|---|---|
| 类型 | `i32` `i64` `u8` `ptr` `ptr<u8>` `ptr<i32>` `ptr<i64>`（7 个类型标签，§2） |
| 表达式 | 恰 25 种：`Num String Var Call Index`、`Add Sub Mul Div Mod Neg`、`Eq Ne Lt Le Gt Ge`、`And Or Not`、`Shl Shr`、`BitAnd BitOr BitXor` |
| 语句 | 恰 9 种：`Let Assign IndexAssign Return If While Break Continue Expr` |
| 结构 | `Program Function Global Param Block` |
| 内建 | 恰 15 个：`write read openat close fstat mmap brk exit`（syscall 类）+ `load_ptr load_i64 store_i64 load_u8 store_u8 load_u16 store_u16`（内存类），§8 |
| 控制流 | `if`/`else if`/`else`、`while`、`break`、`continue` |

**明确不在子集**（解析器已拒，codegen 永不见到）：`for`、`struct`/字段/`.`、
`bool` 类型与 `true`/`false` 作类型、`u16`/`u32` 类型、`~`（无 `BitNot`）、`?:`
（无 `Cond`）、`*` 解引用（无 `Deref`）、`&` 取地址（无 `AddrOf`）、`sizeof`/`len`、
局部数组、数组参数、多维数组、复合赋值、`++`/`--`、函数指针、`@embed`、`include`。

**三遍生成**（§3–§9 的骨架）：

1. `cg_collect` —— 地址分配：走符号表与 AST，算 `.rodata`/`.data`/`.bss` 尺寸与每个
   字符串、每个全局的绝对虚址；登记 runtime-init 全局清单。
2. `gen_function` —— 线性展开：把每个函数的指令按字追加进 `textw: i32[262144]`，
   分支/调用登 fixup（§7），全局/串地址用四词 `emit_addr64` 物化（绝对址，§4）。
3. `elf_emit` —— 已知全部地址后顺序写 ELF：Ehdr/Phdr/`.text`/`.rodata`/`.data`/
   `.symtab`/`.strtab`/`.shstrtab`/Shdr，并解析全部 fixup 回填（§9）。

---

## 2. 类型词汇与宽度/符号规则

**类型标签**（沿用 M3c，`bootstrap/aster.ast:214-220`）：

| 标签 | 值 | 宽度 | 符号 |
|---|---|---|---|
| `TY_I32` | 1 | 4 | signed |
| `TY_I64` | 2 | 8 | signed |
| `TY_U8` | 3 | 1 | unsigned |
| `TY_PTR` | 4 | 8 | — |
| `TY_PTR_U8` | 5 | 8 | — |
| `TY_PTR_I32` | 6 | 8 | — |
| `TY_PTR_I64` | 7 | 8 | — |

- `tyIs64(t)`：`t ∈ {TY_I64, TY_PTR, TY_PTR_U8, TY_PTR_I32, TY_PTR_I64}`。
- `tyIsUnsigned(t)`：`t == TY_U8`（子集无 u16/u32）。
- `ptrElem(t)`：`ptr<u8>→u8`、`ptr<i32>→i32`、`ptr<i64>→i64`、裸 `ptr→i32`
  （宿主持此兜底，`bootstrap/aster.ast:2484`）。
- M3c 把「bool 值表达式」的 `ex_ty` 置为 **-2**（比较/`&&`/`||`/`!` 的结果）；
  codegen 视 -2 为 i32 宽（0/1 物化，§6）。

**宽度传播**（镜像宿主 `gen(want)`，`src/aster.cpp:3086`）：`gen_expr(h, want)`
按**消费者期望宽度**生成操作数，生成时自行扩展：

- i32 值进 i64 上下文：载入后用 `SXTW`（`0x93407c00|(Rn<<5)|Rd`）——宿主同款
  （`src/aster.cpp:3130`）。u8 载入用 `LDRB`，零扩展天然正确；i64/ptr 载入即全宽。
- `E_Num`：want 为 64 位 → `emit_imm64`（§4.1，**省略形**：高 16 位为 0 的 chunk
  不发 `MOVK`——与宿主 `emitMov64` 逐条同规则，`src/aster.cpp:2887`）；
  否则 `MOVZ Wd,#(v&0xffff)`，`v>>16` 非零再补一条 `MOVK Wd,#(v>>16),lsl#16`
  （宿主 `src/aster.cpp:3098` 同款，两词覆盖全部 32 位 patterns，含负数）。
- 二元运算 `wideOp = tyIs64(want) || tyIs64(ta) || tyIs64(tb)`；`wide` 为真时
  `opWant = TY_I64`，否则 `opWant = want`。**宿主 `constExceedsI32` 在 bootstrap 中
  已由 M3c 蕴含**：`E_Num` 越出 i32 即 `TY_I64`、`E_Neg` 继承操作数类型
  （`bootstrap/aster.ast:2804/2808`），故 `tyIs64(ta)` 已覆盖常量越界。
- 移位只看左操作数：`wide = tyIs64(want) || tyIs64(ta)`（`E_Shl/E_Shr` 的结果类型
  即左操作数类型，M3c `bootstrap/aster.ast:2815`）；右操作数（计数）恒按 i32 生成。
- 比较：`wide = tyIs64(ta) || tyIs64(tb)`；`cmpTy = wide ? TY_I64 : i32`
  （u8 提升 i32；`promoteInt` 在子集里的效果）。两操作数都按 `cmpTy` 生成。
  条件码：有符号 `EQ0 NE1 GE10 LT11 GT12 LE13`；**任一操作数为 u8 时用无符号条件码**
  `LO3 HS2 HI8 LS9`（宿主 `comparisonCond`，`src/aster.cpp:2290`）。
- `&&`/`||`/`!` 与一切比较结果：物化为 i32 的 0/1（§6），与 want 无关。

**符号规则**：`/` `%` 在任一操作数为 u8 时用 `UDIV`（否则 `SDIV`）；
`>>` 在左操作数为 u8 时用 `LSR`（否则 `ASR`）；`E_Neg` 用 `SUB Wd,WZR,Wa`
（或 64 位形）——均镜像宿主（`src/aster.cpp:3550-3600`）。

---

## 3. ABI

- **AAPCS64 子集**：前 8 个标量参数走 `X0–X7`，第 9+ 个走栈；返回值 `X0`。
  子集无结构体，每参数恰占 1 个 8 字节槽（宿主 `layoutArgs` 在标量下的结果，
  `src/aster.cpp:3720`）。
- **栈参位置**：调用方把第 k 个参数（k≥9）写到**自己帧内**的
  `[SP + 8*(k-8)]`（§5 槽 0..31 区）。AArch64 的 `BL` 不压栈，故被调方入口
  `SP` 即调用方 `SP`；被调方 `SUB SP,SP,#8192` 后从 `[SP + 8192 + 8*(k-8)]` 读入
  （宿主 `src/aster.cpp:4979` 同款几何）。
- **临时寄存器**：`X0–X15`（编号 0–15），严格 LIFO 自由表管理（§5）。
  **禁用 `X19–X28`、`X29` 帧指针、`X30` 除显式保存外**。
- **栈对齐**：16 字节。帧恒 8192 字节，入口 `SP` 16 对齐，故帧内一切访问保持对齐。
- **帧**：8192 字节 = 1024 个 8 字节槽（§5 布局图）。
- **`main`**：符号名 `main`，ELF 入口 `_start` 指向它（§9）。`main` 不保存 `X30`
  （无处可返）；`main` 的每条 `return` 路径以 `MOV X8,#93; SVC #0` 收尾——
  即 `exit(返回值)`（93 是 AArch64 `exit` 系统调用号；宿主把 main 的返回同样
  lower 成退出，`src/aster.cpp` main 特判）。
- **返回值宽度**：返回类型为 i32/u8 → `W0`（u8 零扩展）；i64/ptr → `X0`。

---

## 4. 指令集子集与编码

`emit_word(w)` 把 32 位字追加进 `textw`（`textlen` 为字下标）；写 `.text` 时每词
按 4 字节小端输出。下列编码**全部经 `aarch64-linux-gnu-as` + objdump 实证**，
`sf=1` 为 64 位（X），`sf=0` 为 32 位（W）；寄存器号为 0–15。

### 4.1 立即数搬运

| 助记符 | 编码 |
|---|---|
| `MOVZ Xd,#u16,lsl#(16*hw)` | `0xd2800000 \| (hw<<21) \| (u16<<5) \| Rd` |
| `MOVZ Wd,#u16,lsl#(16*hw)` | `0x52800000 \| (hw<<21) \| (u16<<5) \| Rd` |
| `MOVK Xd,#u16,lsl#(16*hw)` | `0xf2800000 \| (hw<<21) \| (u16<<5) \| Rd` |
| `MOVK Wd,#u16,lsl#(16*hw)` | `0x72800000 \| (hw<<21) \| (u16<<5) \| Rd` |
| `MOV Xd,Xm` | `0xaa0003e0 \| (Rm<<16) \| Rd` |
| `MOV Wd,Wm` | `0x2a0003e0 \| (Rm<<16) \| Rd` |
| `MOV Wd,#0` / `MOV Xd,#0` | `0x2a1f03e0\|Rd` / `0xaa1f03e0\|Rd`（WZR/XZR 源） |

**`emit_addr64(rd, v)`**（全局/串地址物化，四词**不省略**）：
`MOVZ Xd,#(v&0xffff)`；`MOVK Xd,#((v>>16)&0xffff),lsl#16`；
`MOVK Xd,#((v>>32)&0xffff),lsl#32`；`MOVK Xd,#((v>>48)&0xffff),lsl#48`。
与常量物化 `emit_imm64`（省略形，宿主同款：高 16 位为 0 的 chunk 不发，
`src/aster.cpp:2887`）是**两个函数**：`E_Num` 走 `emit_imm64`，地址走
`emit_addr64`——地址流恒四词，发射序对孪生逐字可锁。

### 4.2 算术 / 逻辑 / 移位

| 助记符 | 编码（Rd=Rn=操作数组合时的字段） |
|---|---|
| `ADD/SUB Xd,Xn,#imm12` | `0x91000000` / `0xd1000000` + `(imm12<<10)\|(Xn<<5)\|Rd` |
| `ADD/SUB Wd,Wn,#imm12` | `0x11000000` / `0x51000000` + 同上 |
| `ADD/SUB Xd,Xn,Xm` | `0x8b000000` / `0xcb000000` + `(Rm<<16)\|(Rn<<5)\|Rd` |
| `ADD/SUB Wd,Wn,Wm` | `0x0b000000` / `0x4b000000` + 同上 |
| `MUL Xd,Xn,Xm` | `0x9b007c00` + `(Rm<<16)\|(Rn<<5)\|Rd` |
| `MUL Wd,Wn,Wm` | `0x1b007c00` + 同上 |
| `SDIV/UDIV Xd,Xn,Xm` | `0x9ac00000\|0xc00` / `0x9ac00000\|0x800` + 字段 |
| `SDIV/UDIV Wd,Wn,Wm` | `0x1ac00000\|0xc00` / `0x1ac00000\|0x800` + 字段 |
| `MSUB Xd,Xn,Xm,Xa`（`Xn-Xm*Xa`） | `0x9b008000` + `(Rm<<16)\|(Xn<<5)\|(Xa<<10)\|Rd` |
| `MSUB Wd,Wn,Wm,Wa` | `0x1b008000` + 同上 |
| `LSL/LSR/ASR Xd,Xn,Xm` | `0x9ac02000` / `+0x400` / `+0x800` + `(Rm<<16)\|(Rn<<5)\|Rd` |
| `LSL/LSR/ASR Wd,Wn,Wm` | `0x1ac02000` / `+0x400` / `+0x800` + 同上 |
| `AND/ORR/EOR Xd,Xn,Xm` | `0x8a000000`/`0xaa000000`/`0xca000000` + 字段 |
| `AND/ORR/EOR Wd,Wn,Wm` | `0x0a000000`/`0x2a000000`/`0x4a000000` + 字段 |
| `NEG Xd,Xm`（`SUB Xd,XZR,Xm`） | `0xcb0003e0` + `(Rm<<16)\|Rd` |
| `NEG Wd,Wm` | `0x4b0003e0` + 同上 |
| `SXTW Xd,Wn` | `0x93407c00` + `(Rn<<5)\|Rd` |

### 4.3 指针语义（**不对称，必须镜像宿主**）

| 场景 | 指令 | 编码 |
|---|---|---|
| `p ± 整数`（**字节偏移，无缩放**） | `ADD/SUB Xd,Xn,Wm,SXTW` | `0x8b20c000` / `0xcb20c000` + `(Rm<<16)\|(Xn<<5)\|Rd`（option=110） |
| `p[i]` / `a[i]`（**按元素宽缩放**） | `ADD Xd,Xn,Wm,UXTW #sh` | `0x8b204000\|(sh<<10)` + `(Rm<<16)\|(Xn<<5)\|Rd`（option=010），`sh=log2(元素宽)` |

`sh ∈ {0,2,3}`（u8/i32/i64 元素）；裸 `ptr` 索引按 i32 宽（sh=2）。
`i + p`（整数在左）时交换操作数使指针恒为 `Xn`（宿主 `src/aster.cpp:3643`）。
`ptr±ptr`、`ptr*整数` 等一律 §10 的 C5 拒绝。

### 4.4 比较 / 条件 / 分支

| 助记符 | 编码 |
|---|---|
| `CMP Xn,Xm` | `0xeb00001f` + `(Rm<<16)\|(Xn<<5)` |
| `CMP Wn,Wm` | `0x6b00001f` + 同上 |
| `CMP Xn,#imm12` | `0xf100001f` + `(imm12<<10)\|(Xn<<5)` |
| `CMP Wn,#imm12` | `0x7100001f` + 同上 |
| `CSET Wd,cond` | `0x1a9f07e0` + `((cond^1)<<12)\|Rd`（**W 形；计划稿的 X 形值已按汇编器修正**） |
| `B.cond t` | `0x54000000` + `cond\|(imm19<<5)`，`imm19=(t-pos)`（词） |
| `B t` | `0x14000000` + `imm26=(t-pos)` |
| `BL t` | `0x94000000` + `imm26=(t-pos)` |
| `RET` | `0xd65f03c0` |
| `SVC #0` | `0xd4000001` |

### 4.5 访存（imm12 为**缩放后**偏移：X/8、W/4、H/2、B 不缩放）

| 助记符 | 编码 |
|---|---|
| `LDR/STR Xt,[Xn,#off]` | `0xf9400000`/`0xf9000000` + `((off/8)<<10)\|(Xn<<5)\|Xt` |
| `LDR/STR Wt,[Xn,#off]` | `0xb9400000`/`0xb9000000` + `((off/4)<<10)\|(Xn<<5)\|Xt` |
| `LDRB/STRB Wt,[Xn,#off]` | `0x39400000`/`0x39000000` + `(off<<10)\|(Xn<<5)\|Xt` |
| `LDRH/STRH Wt,[Xn,#off]` | `0x79400000`/`0x79000000` + `((off/2)<<10)\|(Xn<<5)\|Xt` |

帧内一切偏移为 8 的倍数且 `< 8192`，故 imm12 恒在范围内（X 形 imm12 上限 32760）。

---

## 5. 寄存器 / 栈槽分配

**临时寄存器池**：`tmp_free[16]` 自由表 + `tmp_top`，`alloc_tmp()` 取栈顶、
`free_tmp(r)` 严格 LIFO 归还（宿主同款，`src/aster.cpp:2429`）。耗尽时报
`expression too complex: temporary register limit exceeded`（§10 C4）。
不变量：任意时刻 `tmp_top ≤ 16`；二元运算后 `free_tmp(右操作数)`。

**帧布局**（1024 槽 × 8B，槽号即字节偏移/8）：

| 槽 | 用途 |
|---|---|
| 0..31 | **出参区**：第 k 个参数（k≥9）在 `[SP+8*(k-8)]`。解析器限 32 参 → 最多 24 个栈参（槽 1..24）；槽 0 留空保对齐 |
| 32..531 | **形参 + 局部**：形参先占 `32..32+nparams-1`，`S_Let` 按声明顺序续占（≤500，与 M3c S21 同限） |
| 532..799 | 备用 |
| 800..899 | **调用暂存网格**：每次调用的实参依次落槽，嵌套调用以当前高水位为基、返回时恢复高水位 |
| 900..949 | **活临时溢出区**：调用/系统调用前 `STR Xr,[SP,#(900+r)*8]`（r<tmp_top），返回后 `LDR` 还原 |
| 950..1021 | 备用 |
| 1022 | **调用结果暂存**：`BL`/`SVC` 后先 `STR X0,[SP,#8184-8]` 再还原活临时，避免被覆盖 |
| 1023 | **X30**（非 main）：`STR X30,[SP,#8184]` |

**槽分配纪律**：`gen_function` 进入时把形参登记进基作用域（槽 32 起），随后线性走
语句；遇 `S_Let` 取下一槽并压入当前作用域（名字→槽）。`if`/`while`/`else` 体
（N_Block）各 push/pop 一个作用域——与 M3c 的 `push_scope/pop_scope` 完全一致
（`bootstrap/aster.ast:2938-2959`）；内层遮蔽取新槽，槽号单调不减（宿主同款）。
因 M3c 已保证 `nlocs ≤ 500`，codegen 的槽检查是防御性镜像（§10 C11）。

---

## 6. 逐节点 lowering

### 6.1 表达式 `gen_expr(h, want) -> reg`

**必须迭代**（显式工作栈，禁深递归）：`dense.ast` 类语料的左结合链可达 3 万+ 节点，
每层 Aster 调用 8 KiB 帧，递归会爆栈（qemu 栈约 8 MiB）。工作栈条目 =
`(节点, 状态, want, 左结果寄存器)`；二元节点用「左完成→求右→发射→释放右」三态；
`E_Call` 用逐参子状态机（每参结果落网格槽即释放，同时至多 1 个参数结果活跃）。
语句递归安全（M3b C2 限深 96）。

| 节点 | lowering |
|---|---|
| `E_Num` | §2 宽度规则：`want` 64 位 → `emit_imm64`（省略形）；否则 `MOVZ Wd`（+条件 `MOVK`） |
| `E_String` | `emit_addr64(rd, 串绝对虚址)`（§9 `.rodata`，NUL 结尾） |
| `E_Var` 局部/形参 | `alloc d; LDR (B/W/X) d,[SP,#槽*8]`（按声明宽度；imm12=槽*2 或 槽）；`want` 64 位且声明为 i32 → `SXTW d,d` |
| `E_Var` 全局标量 | `alloc d; alloc t; emit_addr64(t, 全局虚址); LDR (B/W/X) d,[t]`；i32+want64 → `SXTW`；`free t` |
| `E_Var` 全局数组 | 衰变为首元素地址：`alloc d; emit_addr64(d, 全局虚址)` |
| `E_Call` | §7 |
| `E_Index` | 基址（数组→`emit_addr64`；ptr→`gen_expr(基, i64)`）+ 下标（i32 宽）→ `ADD Xd,Xn,Wm,UXTW #sh` → 按元素宽 `LDR (B/W/X)`；i32 元素 +want64 → `SXTW` |
| `E_Add/Sub`（ptr±int） | 指针侧 `gen_expr(i64)`、整数侧 `gen_expr(i32)` → `ADD/SUB Xd,Xn,Wm,SXTW`（§4.3） |
| `E_Add/Sub/Mul`（整数） | 栈式：`a=gen(左,opWant); b=gen(右,opWant); ADD/SUB/MUL a,a,b; free b` |
| `E_Div` | `SDIV/UDIV`（u8 操作数 → UDIV） |
| `E_Mod` | `SDIV/UDIV q,a,b` 入新临时 → `MSUB a,a,b,q` → `free q; free b`（宿主 `src/aster.cpp:3550`） |
| `E_Neg` | `a=gen(操作数,want)` → `NEG (W/X) a,a`（`tyIs64(want)` 选形） |
| `E_Shl/Shr` | `a=gen(左,opWant); b=gen(右,i32)` → `LSL/LSR/ASR a,a,b`（u8 左操作数 → LSR）→ `free b` |
| `E_BitAnd/Or/Xor` | `AND/ORR/EOR a,a,b`（wideOp 定宽）→ `free b` |
| `E_Eq..Ge` | `a=gen(左,cmpTy); b=gen(右,cmpTy); CMP a,b; free b; free a; alloc d; CSET d,cond`（cond 见 §2 符号规则） |
| `E_And` | `a=gen(左); CMP a,#0; MOV a,#0(默认); B.EQ L_end(占位); b=gen(右); MOV a,b; free b; L_end:`（结果落在**左**寄存器 `a`，不设独立 `t`） |
| `E_Or` | 同上但默认 `MOV a,#1`、条件分支 `B.NE` |
| `E_Not` | `r=gen(操作数)（bool 物化）; CMP r,#0; CSET r,EQ` |

> 注：局部标量无需地址临时（帧内偏移直接编入 imm12）；全局与数组衰变才取地址临时。
> 二元「左结果活着求右」天然维持 LIFO：`gx_push_bin` 先压右子后压左子，左子后出栈拿到**较旧**寄存器 `a`、右子拿到**较新** `b`，故 `free b`（较新）合法。

> **一元节点必须早于二元字段返回**：`gx_dispatch` 顶部的 `l=nfirst`、`r=nnext[l]`、`lt=ex_ty[l]`、`rt=ex_ty[r]` 仅对二元节点成立；`E_Index`/`E_Neg`/`E_Not` 只有单个子（`nnext[l]` 为 0），若在此读取 `r` 再 `ex_ty[r-1]` 即 `ex_ty[-1]` 越界崩溃。故 `E_Index`/`E_Neg`/`E_Not` 在 `gx_dispatch` 顶部 `return`，不得触及 `r`/`rt`。

> **`E_Index` 的 LIFO**：基址临时 `a` 在 `gen_index` 内 `alloc`（较新），下标 `i` 由子表达式先 `alloc`（较旧）。地址结果落 `i`（`ADD Xi,Xa,Wi,UXTW` → `free a`），返回 `i`；若反过来 `free i` 会触发泄漏守卫（上面压着 `a`）。`E_And`/`E_Or` 同理——结果落较旧的左寄存器、释放较新的右寄存器。

> **嵌套 `gen_expr` 的基址约定**（#258 定钉）：入口是 `gen_expr(h, want)`，实现为 `gen_expr_at(h, want, 0)` 的包装；被表达式求值中途调用的路径（唯一一处：`gen_call` 的逐参 staging）必须传**调用方的 `gx_top`** 作 base——`gen_expr_at(参, 参型, gx_top)`。内层表达式（含其中再嵌的调用）的全部工作帧落在外层活帧**之上**，正常退出时 `gx_top == base`，外层帧及其左结果寄存器原样存活。若内层从 0 起压栈，外层帧被覆写，外层循环随后把 `gx_top` 弹到 base 以下、寄存器分配错乱（实测：p5b `n * fact(n-1)` 的 `E_Mul` 右子是 `E_Call`，泄漏守卫误报、调用目标错乱）。语句层的 `gen_index_addr`/`gen_init` 无外层表达式在跑（`gx_top==0`），仍走 `gen_expr`。循环不变量：`while (gx_top > base)`；任何 `return -1` 直接向上返回（错误即终止编译，不尝试恢复工作栈）。

### 6.2 语句 `gen_stmt(s)`（递归，深 ≤96 安全）

| 语句 | lowering |
|---|---|
| `S_Let` | 取新槽（§5）→ `v=gen_expr(初值, 声明型)` → 按声明宽 `STR (B/W/X) v,[SP,#槽]` → `free v` |
| `S_Assign` | 解析目标（局部槽 / 全局地址）：`v=gen_expr(右, 目标型)` → 存储（全局：`alloc t; emit_addr64 t,址; STR`）→ `free` |
| `S_IndexAssign` | 子0 是 `E_Index`（名字+下标）：算元素址入临时 a（同 `E_Index` 寻址）→ `v=gen_expr(右, 元素型)` → `STR v,[a]` → `free v; free a` |
| `S_Return` | `v=gen_expr(表达式, 返回型)` → `v≠0` 时 `MOV (W/X)0,v` → main：`MOV X8,#93; SVC #0`；非 main：`LDR X30,[SP,#8184]; ADD SP,SP,#8192; RET` |
| `S_If` | `r=gen_expr(cond,i32); CMP (W/X)r,#0`（cond 静态宽 64 位用 X 形）→ `B.EQ L_else`（fixup）→ gen then 块 → `B L_end` → `L_else:` → gen else（N_Block 或 else-if 的 S_If）→ `L_end:` |
| `S_While` | `L_cond:` → `r=gen_expr(cond,i32); CMP; B.EQ L_exit` → gen 体（`break`→`B L_exit`，`continue`→`B L_cond`）→ `B L_cond` → `L_exit:` |
| `S_Break/Continue` | 取循环标签栈顶发 `B`；栈空 → §10 C1/C2 |
| `S_Expr` | `v=gen_expr(调用,i32)` → `free v`（丢弃） |

**条件统一规则**：无论条件是 bool 值（-2）还是整数值，都「物化再测试」：
`gen_expr(cond)` 得 0/1 或整数值，`CMP`（静态宽 64 位 → `CMP Xr,#0`，否则
`CMP Wr,#0`）后 `B.EQ` 跳假目标。宿主对比较型条件复用 flags 省一次 `CSET`
（`src/aster.cpp:4477`）；bootstrap 不做此优化（§11），功能等价。

### 6.3 结构 `N_*`

- `N_Program`：`cg_collect` 后按「入口桩（若有）→ `__aster_init`（若有）→ `main`
  → 其余函数（源序）」逐 `N_Function` 进 `gen_function`；`N_Global` 不产指令
  （§9 数据节）。
- `N_Function`：prologue → 形参搬槽 → `gen_block` → epilogue（§3/§6.2 返回路径）。
- `N_Param`：prologue 搬槽：第 i<8 个 `STR (W/X)Xi,[SP,#(32+i)*8]`；
  第 i≥8 个 `LDR X9,[SP,#8192+8*(i-8)]; STR X9,[SP,#(32+i)*8]`。
- `N_Block`：顺序 `gen_stmt`（§5 作用域）。

**prologue**（非 main）：`SUB SP,SP,#8192`（`0xd1400bff`）→ `STR X30,[SP,#8184]`
（`0xf90ffffe`）→ 形参搬槽。**main**：仅 `SUB SP,SP,#8192`（不存 X30）。

---

## 7. 控制流与回填

线性发射时前向目标未知，用**标签表 + fixup 表**（`textw` 字下标为址）：

- `labels[i]`：标签 id → 字偏移；到达标签处 `labels[i] = textlen`。
- `fixups`（并行四数组 `fx_pos/fx_kind/fx_label/fx_cond` + `nfix`）：
  - `fx_kind=0`：`B.cond`（`fx_cond` 存条件码）
  - `fx_kind=1`：`B`
  - `fx_kind=2`：`BL`（`fx_label` = 目标**标签 id**，对调用即 `fn_lab[fsym]`——不是符号行）
- 发射分支/调用时先 `emit_word(占位)` 并 `push_fixup`；`elf_emit` 统一解析：
  `delta = labels[fx_label] - fx_pos`，校验 `|delta| ≤ 2^18`（B.cond）/`2^25`（B/BL）
  后写回。`textw` 上限 262144 词恰为 ±2^18，故 B.cond 恒可达；越界仍断言（§10 C13）。
- 标签 id：单调计数器（每个 `if` 2 个、每个 `while` 2 个），上限 65536（§10 C13）。
- **标签 id 的生命周期跨趟**（#258 定钉）：`cg_collect`（第一趟，零发射）已为每个
  非 extern 函数（及需要时的 `__aster_init`）分配标签 id；第二趟的控制流标签必须
  **接续**该计数器。`cg_init` 只重置 `textlen` 与临时寄存器池，**不得**重置
  `nlabels`/`nfix`——一旦重置，`if`/`while` 的 `lelse`/`lend` 会复用函数标签 id 0/1，
  其 `place_label` 覆盖函数入口偏移，所有 `BL` 错解析到控制流标签处（实测：p5b 递归
  `fact` 的调用目标变成 if 的合并标签，无限递归）。
- **break/continue 标签栈**：`lp_exit[64]`/`lp_cont[64]`/`lp_depth`；嵌套超 64 → §10 C13。
  宿主对应物是 `loops` 向量（`src/aster.cpp:2419`）。

---

## 8. syscall 内建表（15 个）

**AArch64 Linux 编号**。系统调用类统一序列（宿主 `syscallInsn`，`src/aster.cpp:3047`）：
park 活临时（`STR Xr,[SP,#(900+r)*8]`，`tmp_top←0`）→ 逐参 `gen_expr(参i, 参型i)`
落网格槽（`STR (W/X)v,[SP,#(800+基+i)*8]`，宽按参型）→ 搬 `X0–X7`
（`LDR (W/X)Xi,[SP,#(800+基+i)*8]`）→ `MOV X8,#号; SVC #0` →
`STR X0,[SP,#1022*8]` → 还原 `tmp_top` 与活临时 → `alloc d; LDR (W/X)d,[SP+#1022*8]`
（返回型宽）。**exit 的返回类型记 i32**；内核自 `exit` 不返回，其余指令为死代码，
语义无涉（孪生同序列）。

| 内建 | 号 | 签名（→ 返回） | 备注 |
|---|---|---|---|
| `write` | 64 | `(i32, ptr, i32) → i32` | |
| `read` | 63 | `(i32, ptr, i32) → i32` | |
| `openat` | 56 | `(i32, ptr, i32, i32) → i32` | 无 plain open |
| `close` | 57 | `(i32) → i32` | |
| `fstat` | 80 | `(i32, ptr) → i32` | |
| `mmap` | 222 | `(ptr, i64, i32, i32, i32, i64) → ptr` | 第 2/6 参 i64 全宽 |
| `brk` | 214 | `(ptr) → ptr` | |
| `exit` | 93 | `(i32) → i32` | **bootstrap 新增**（宿主持无；宿主 main 的 return 即 exit） |

**内存类**（不走 SVC，直接访存；宿主 `src/aster.cpp:3169-3210`）。store 族
**先求值参后求指针参**（宿主同序），故指针临时较新、被释放的是它：

| 内建 | lowering | 返回 |
|---|---|---|
| `load_ptr` | `a=gen(ptr参,i64); LDR Xa,[Xa]`（`0xf9400000\|(a<<5)\|a`） | ptr |
| `load_i64` | `a=gen(ptr参,i64); LDR Xa,[Xa]`（`0xf9400000\|(a<<5)\|a`） | i64 |
| `load_u8` | `a=gen(ptr参,i64); LDRB Wa,[Xa]`（`0x39400000\|(a<<5)\|a`） | i32（零扩展） |
| `load_u16` | `a=gen(ptr参,i64); LDRH Wa,[Xa]`（`0x79400000\|(a<<5)\|a`） | i32（零扩展） |
| `store_i64` | `v=gen(i64参); a=gen(ptr参,i64); STR Xv,[Xa]`（`0xf9000000\|(a<<5)\|v`） | i64 |
| `store_u8` | `v=gen(i32参); a=gen(ptr参,i64); STRB Wv,[Xa]`（`0x39000000\|(a<<5)\|v`） | i32 |
| `store_u16` | `v=gen(i32参); a=gen(ptr参,i64); STRH Wv,[Xa]`（`0x79000000\|(a<<5)\|v`） | i32 |

load 族的载入形自带全宽零扩展（LDRB/LDRH 写 W 即清零高 32 位），**无 SXTW 尾**；
store 族原样返回值临时（宿主同）。

**内建实参校验**（M3c 对内建跳过签名检查，故由 codegen 补）：个数与类型按上表，
消息镜像宿主（`src/aster.cpp:3170-3210,5980-6043`），如
`write expects (fd: i32, buf: ptr, len: i32)`、`load_u8 expects exactly one ptr argument`。
逐槽规则（镜像宿主 typeOf 比较）：**i32 槽只拒指针**（bool 放行，宿主亦然）；
**i64 槽拒指针或 bool**；**ptr 槽要求四个指针标记之一**。消息形状：load 族
（单参内存类）走 `<名> expects a ptr argument`；其余内建命名位置
（`<名> [第n] argument must be <型>`，单参时省序数）。**exit 的消息为 bootstrap 自有**
（宿主持无 exit 内建，其 main 的 return 即 exit），按 close 的图案拼写：
`exit expects (code: i32)` / `exit argument must be i32`。

系统调用类与普通调用共用同一网格纪律：`基 = cg_grid_hi`，越界同样触发
`nested function-call arguments exceed compiler limit (100 scratch slots)`
（内建最多 6 参，mmap）。系统调用类结果经槽 1022 还原后读回，**返回型 i32 且 want
64 位时同样 `SXTW`**（与普通调用尾一致；内存类无此尾）。

**普通函数调用**（宿主 `emitCallSeq`，`src/aster.cpp:4115`）：
park 活临时（`tmp_top←0`）→ 逐参 `gen_expr_at(参i, 形参型i, gx_top)` 落网格槽（每参 1 槽，
高水位+1；嵌套调用以当前高水位为基、返回时恢复；内层求值从调用方工作栈顶起压栈，§6.1 注）
→ `LDR (W/X)Xi,[SP,#(800+基+i)*8]`
（i<8）→ 栈参：`LDR X9,[SP,#(800+基+i)*8]; STR X9,[SP,#8*(i-8)]` → `BL`（fixup=2）→
`STR X0,[SP+#1022*8]` → 还原 `tmp_top` 与活临时 → `alloc d; LDR (W/X)d,[SP+#1022*8]`
→ 返回型 i32 且 want 64 位 → `SXTW d,d`。

**extern 函数/全局**：独立镜像无动态链接器，引用即拒（§10 C9）。

---

## 9. ELF 布局

固定基址，**无重定位、无 `DT_NEEDED`、无动态节**（所有符号在本镜像内）：

| 量 | 值 |
|---|---|
| 镜像基址 | `0x400000` |
| `.text` 虚址/文件偏移 | `0x401000` / `0x1000` |
| `.rodata` 虚址 | `0x600000`（固定；`.text` 上限 1 MiB → 0x501000 之下不重叠） |
| `.data` 虚址 | `0x800000`（固定；`.rodata` 上限 2 MiB → 0x800000 之下不重叠） |
| `.bss` 虚址 | `alignUp(.data虚址+.data尺寸, 8)` |

**节存在性**：`.text`/`.symtab`/`.strtab`/`.shstrtab` 恒有；`.rodata` 有 ≥1 个
字符串字面量时才有；`.data` 有 ≥1 个非零常量全局时才有；`.bss` 有 ≥1 个全零或
runtime-init 全局时才有。文件内顺序：`Ehdr+Phdr`（页 0）→ `.text` → `.rodata`
（页对齐）→ `.data`（页对齐）→ `.symtab`/`.strtab`/`.shstrtab`（8 对齐）→ Shdr 表。

**段页对齐不变量**（#260 `elf_emit` 必须遵守）：每个 `PT_LOAD` 的
`p_offset ≡ p_vaddr (mod 0x1000)`。qemu-user 的加载器按
`vaddr − (offset mod page)` 反推映射基址，一旦错位即 `Error mapping file:
Invalid argument` 静默拒载（#259 原型 emitter 实测：对齐掩码写成 `0-0xfff`
即 −4095，少 1 个位，`.rodata` 整体偏移 1 字节，所有含字符串字面量的探针
 rc=255）。对齐须用 `(v + 0xfff) / 0x1000 * 0x1000` 或 `& ~0xfff`，
**不得**写成 `& (0 - 0xfff)`。

**`cg_collect` 分配规则**：

- **`.rodata`**：按**转储先序**走全部 `E_String` 节点——镜像 `emit()` 的
  迭代先序走法（显式栈 + 兄弟链，与 M3b 转储同序，定义不依赖句柄分配
  次序，孪生可从同一规格复现节布局），各追加 strpool 字节（`tstart/tlen`）
  + 1 个 NUL；`str_addr[句柄] = 0x600000 + 偏移`。不去重。
- **全局**（`N_Program` 孩子序）：标量尺寸 = 元素宽；数组 = `ncount × 元素宽`
  （单常量初值**填充全部元素**，宿主 `src/aster.cpp:1986`）。
  - **节内对齐**：每个全局按自身宽度在所属节内对齐——u8=1、i32=4、
    i64/ptr=8、数组按元素宽（u8/i32 数组按元素宽而非总尺寸对齐）。
  - `.bss` 两段式：走查中先记节内偏移，`cg_collect` 收尾统一加
    `bss_base = alignUp(0x800000+data_size, 8)` 得绝对虚址。
  - 数组全局：初值必为常量（M3b P27 已拒非常量）；`cg_collect` 重调 `fold()` 得值
    （解析期已成功，不会 die）；值 0 → `.bss`，否则 `.data` 按元素宽重复写值。
  - 标量常量：`fold()` 得值；0 → `.bss`，否则 `.data`。
  - 标量非常量（runtime-init，含字符串初值——`is_const` 不认 `E_String`）：
    落 `.bss`，登记进 runtime-init 清单（声明序）。
  - i32 槽存 `值 & 0xFFFFFFFF`（宿主同款截断，`src/aster.cpp:1989`）。
- **入口**：有 runtime-init 全局时，`.text` 偏移 0 处发两词入口桩
  `BL __aster_init; B main`（`e_entry=0x401000`）；否则 `main` 就在偏移 0
  （`e_entry=0x401000` 同）。**故 `e_entry` 恒为 `0x401000`。**
  `__aster_init`：标准帧（`SUB SP,#8192; STR X30`）+ 对每个 runtime-init 全局
  （声明序）发 `gen_expr(初值, 声明型)` → `emit_addr64(t,全局虚址); STR` + 尾声
  （`LDR X30; ADD SP,#8192; RET`）。宿主对应物：合成 `__aster_init` 函数
  （`src/aster.cpp:6514`）。
- **函数序**：`main` 先，其余按源序（宿主同款，`src/aster.cpp:6503`）；
  入口桩与 `__aster_init`（若有）在最前。

**Ehdr**：`e_ident=7f454c46 02 01 01 00 +8×00`；`e_type=2`(ET_EXEC)；
`e_machine=183`；`e_version=1`；`e_entry=0x401000`；`e_phoff=64`；
`e_shoff=尾部`；`e_ehsize=64`；`e_phentsize=56`；`e_shentsize=64`；
`e_shstrndx=最后一节`。

**Phdr**（`e_phnum = 1 + (有.rodata) + (有.data||.bss)`）：
- 段0：`PT_LOAD`，`flags=5`(R+X)，`p_offset=0, p_vaddr=0x400000,
  p_filesz=p_memsz=0x1000+.text尺寸, p_align=0x1000`（覆盖 Ehdr+Phdr+.text）。
- 段1（若有 rodata）：`PT_LOAD`，`flags=4`(R)，`p_offset/p_vaddr` 按上表，
  `filesz=memsz=rodata尺寸`。
- 段2（若有 data/bss）：`PT_LOAD`，`flags=6`(R+W)，
  `p_filesz=.data尺寸, p_memsz=.data尺寸+.bss尺寸`。

**Shdr**（顺序：0 null、`.text`、`.rodata`?、`.data`?、`.bss`?、`.symtab`、
`.strtab`、`.shstrtab`）：`.text` = `SHT_PROGBITS`/`flags=0x6`/`align=4`；
`.rodata` = PROGBITS/`0x4`/`align=1`；`.data` = PROGBITS/`0x3`/`align=8`；
`.bss` = `SHT_NOBITS`/`0x3`/`align=8`（`sh_offset` = `.data` 文件尾，即
`data_off + data_size`；NOBITS 无文件内容）；`.symtab` = `SHT_SYMTAB`/`link=.strtab`/
`info=1`（sym0 之后首个全局符号）/`entsize=24`；`.strtab`/`.shstrtab` =
`SHT_STRTAB`/`align=1`。`.shstrtab` 只含存在节的名（`\0.text\0...`）。
`e_shstrndx` = `.shstrtab` 的下标（末节），`e_shnum` = 上列节总数。

**Symtab**（sym0 = 全零 null）。**表内顺序钉定**（孪生据此逐字节复现）：
null → `_start` → `__aster_init`（有入口桩时）→ 程序函数（发射序：`main` 先，
其余源序，即 `cg_gen_program` 的走查序；extern 函数无符号）→ 全局（符号行序，
即声明序；`skind==SK_GLOBAL` 的每一行）：
- 每个函数：`STT_FUNC`(info `0x12`)，`shndx=.text`，
  `value=0x401000+词偏移*4`，`size=词数*4`（`fn_words`/`init_words`，
  `cg_gen_program` 逐函数记录）。
- `_start`：`value=0x401000`，`size` = 入口桩尺寸（16 字节）或 main 尺寸（无桩时）。
- `__aster_init`（若有）：同函数符号规则（`value=0x401000+labels[init_lab]*4`）。
- 每个非 extern 全局：`STT_OBJECT`(info `0x11`)，`shndx=.data/.bss`，
  `value=虚址`，`size=字节数`。

**字符串表**：`.strtab` 与 `.shstrtab` 均为「字节 + 一个 NUL」的追加式构造，
**字节 0 恒为 NUL**（空名，null 符号的 `st_name=0` 解析到它）。`.strtab` 在
符号收集时随每个符号追加其名（`st_name` = 落点偏移；函数/全局名取自
`sname` 的 token 字节，`_start`/`__aster_init` 为字面量）；`.shstrtab` 在节图
定死后按**节序**一次性构造（与 Shdr 写出序一致）。

**表偏移**：三张表跟在**最后一段有文件内容的数据之后 8 对齐**（它们不被映射，
故不需要页对齐——段缺失时不留幻影页）：基址 = `.text` 尾 / `.rodata` 尾 /
`.data` 尾（按存在性取最后者），`symtab_off = align8(基址)`，
`strtab_off = symtab_off + elf_nsym*24`，`shstr_off = strtab_off + strtab_len`，
`shoff = align8(shstr_off + shstr_len)`。

**分支距离守卫**：fixup 回填时校验 `delta`（词单位）在 `B.cond` 的 ±2^18 与
`B/BL` 的 ±2^25 内——文本段上限 262144 词（1 MiB）使二者**永不可达**，
是「上限即保证」的腰带式断言，消息 `conditional branch out of range` /
`branch out of range`。

**小端化**：`elf_put16/32/64` 各经若干 `putb(v>>(8*i)&0xff)`（32/64 位取值先
窄化到 i32 局部——Aster 不允许 i64 实参直接进 i32 形参）；Shdr 记录与 symtab
条目各有定长 writer（`elf_shdr` 10 字段 64 字节、条目 24 字节），补白游标
`elf_written` 从「Ehdr+Phdr 已写字节数」（`64 + nseg*56`）起计。ELF 字节仍走
现有 `putb/putn` + `flush_out()`（→ `write(1,…)`），与 M3b 转储同一条输出通道。

---

## 10. 成功输出与错误 / 限制

**成功**：ELF 字节写 stdout，退出码 0。**失败**：一个诊断行到 stderr
（`aster: error: <base> at L:C`，格式同 M3c §10），退出码 1，stdout 不产字节。

**Codegen 错误目录**（新 C 类；带宿主锚的镜像宿主原句）：

| 编号 | 消息 | 锚 |
|---|---|---|
| C1 | `break used outside a loop` | 宿主 `src/aster.cpp` |
| C2 | `continue used outside a loop` | 宿主 |
| C3 | `<fn> may fall through without returning i32; add a return or make both if/else branches return`（ptr 返回型时 "ptr"） | 宿主 `src/aster.cpp:4903` |
| C4 | `expression too complex: temporary register limit exceeded` | 宿主 `:2429` |
| C5 | `invalid pointer arithmetic: expected ptr +/- i32 or i32 + ptr` | 宿主 `:3649` |
| C6 | `only == and != are defined for a ptr` | 宿主 `:4387` |
| C7 | `the arguments of this call need more scratch space than the frame provides` | 宿主 `:4162` |
| C8 | `nested function-call arguments exceed compiler limit (100 scratch slots)` | 宿主 `:4180` 同款句式 |
| C9 | `cannot call external function: <name>` / `cannot reference external global: <name>` | 新（宿主在链接期报 undefined symbol） |
| C10 | `no main function: this backend emits a standalone ELF and needs an entry point` | 新（宿主 `build-elf` 经链接器报 `no input object defines global _start`） |
| C11 | `too many local declarations (limit 500, including parameters)` | 镜像 M3c S21（防御性） |
| C12 | `internal compiler error: temporary register leak` / `...: invalid frame slot` / `...: walk stack overflow` | 宿主同款 |
| C13 | 容量守卫：`.text exceeds the 1 MiB instruction buffer` / `.rodata exceeds its 2 MiB window` / `.strtab exceeds its 1 MiB window` / `too many symbols` / `fixup table overflow` / `too many labels` / `loops nested too deeply (limit 64)` / `global data exceeds the address space` | 新 |
| C14 | `type mismatch initializing global '<name>': expected <T>, got <U>` | 宿主 `src/aster.cpp:6527` 同款 |
| C15 | 内建实参校验（§8 表尾消息集） | 宿主 `:3170-3210,5980-6043` |

**编译期强制的不变量**（写码时断言，失败即 C12）：
- `free_tmp` 严格 LIFO（释放非栈顶 → internal error）；
- 帧槽号 ∈ [0,1023]；
- `gen_expr` 工作栈不溢出不变量（条目上界 65536）；
- 每函数收尾 `tmp_top == 0`（临时泄漏检查，宿主 `:4988` 同款）。

**C1/C2/C3 的 bootstrap 位置钉定**（#258 实证，探针 e1–e4 与宿主逐字对齐）：
C1/C2 锚在 `break`/`continue` 关键字 token（宿主同）；C3 锚在**函数名 token**
（`gen_function` 的名称 token）——宿主持句无位置，bootstrap 补 `at L:C`。
三条均在发射任何指令前判定（C3 在 prologue 之前），故拒绝时 stdout 无字节。

**容量上限**（与上游共享）：源 1 MiB、节点 65536、符号 4096、串池 1 MiB、
指令流 262144 词、fixup/标签 65536、循环嵌套 64、语句嵌套 96（M3b C2）。

---

## 11. 与宿主 `build-elf` 的差异（有意）

| # | 宿主 | bootstrap | 影响 |
|---|---|---|---|
| 1 | 全局/串地址经 `X16 = SP+8192` 相对寻址（`kGlobalBase`） | 四词 `emit_addr64` 绝对址（镜像免 ADRP；ET_EXEC 基址固定） | 编码更长，语义等价 |
| 2 | 比较型条件复用 flags（省一次 `CSET`） | 一律物化再 `CMP` | 多 2 条指令/条件 |
| 3 | 活临时 park 用 `STR W`（`storeLocal`，仅存低 32 位） | `STR X`/`LDR X` 全宽 park | bootstrap 修正了宿主在 i64 活临时上的潜在截断；W 写零扩展保证两种宽都圆整 |
| 4 | 调用结果直接 `MOV d,X0`（d=nextTemp） | 结果经帧槽 1022 中转 | 多 2 条指令/调用 |
| 5 | 字符串全局为 `.data` 常量（rodata 地址编译期填入） | 字符串全局走 runtime-init（`is_const` 不认 `E_String`），`__aster_init` 落值 | 功能等价 |
| 6 | `.eh_frame`/`.debug_line`/`.debug_info`（`-g`）、`--bounds-check` | 均不发 | M3d 最小可运行镜像 |
| 7 | rodata 只收代码生成实际引用的串（发射序） | 收全部 `E_String` 节点（句柄序） | 死代码串也占位 |
| 8 | PIC/`build-so`/多对象链接路径 | 无（单镜像 ET_EXEC） | 自举闭环属 M4 |
| 9 | 无 `exit` 内建 | 新增 `exit=93` | bootstrap 扩展 |
| 10 | 符号表含链接器视图（`_start` 即 main 别名） | `_start`（入口桩/main）+ `main` + `__aster_init` + 函数/全局符号 | 可读性等价 |

功能验收口径：**bootstrap ELF 与宿主 `build-elf` ELF 在 qemu-aarch64 下
运行结果一致**（退出码/stdout），不要求字节一致（§13.3 同款放宽）。

---

## 12. 与孪生的字节级一致性条款

`tests/codegen-twin.c`（独立 C 实现，仿 `tests/parser-twin.c` 纪律：
`gcc -std=c11 -O2 -Wall -Wextra -Werror -fwrapv -fno-builtin`）从本规格**独立**
实现：自有递归下降解析 → 自有 AST → 同一份 lowering 规则（§2–§9 的全部编码、
帧布局、发射序、fixup/标签语义、ELF 布局）→ 同一字节流。

- **一致项**：对任何双方都接受的程序，`cmp -s boot.elf twin.elf` 逐字节相同；
  对任何一方拒绝的程序，退出码与 stderr 基础串相同。
- **纪律**：孪生不得读 bootstrap 源码；两实现共享的唯一知识是本规格与
  `tests/parser-twin.c` 已验证的节点编号/转储事实。
- **裁判规则**：任何发散即一方缺陷——bootstrap 侧缺陷修 bootstrap，
  孪生侧缺陷修孪生；规格本身歧义时先修规格再修两侧。

---

## 13. 自举验证声明

M3d 的达成判据（`tests/codegen-checks.sh` 落地后必须全绿）：

1. **最小链路**：`arithmetic.ast`（纯 i32 算术，退出码即结果）、
   `write_hello.ast`（字符串 rodata + `write` syscall，stdout=`Hello, World!`）、
   综合样例（多函数 `BL` + 全局数组 + 指针遍历 + `while` + `break`/`continue`）
   在 `qemu-aarch64` 下结果正确。
2. **字节级差分**：上述样例 + 全语料接纳用例，bootstrap 与孪生 `cmp -s` 一致。
3. **功能等价**：bootstrap ELF vs 宿主 `build-elf` ELF 运行结果一致。
4. **零依赖**：产物 ELF 无动态节、无 UND 符号（`readelf -d` 无输出）。
5. **变异探针**：对 `bootstrap/aster.ast` 打补丁重建，断言与孪生发散
   （≥3–5 探针覆盖：指令编码、syscall 号、分支回填、符号地址、宽度传播）。
6. **容量/边界**：大函数、深表达式（左结合 3 万+ 项）、>8 参数走栈、长串、
   大数组（≤1 MiB）、32 参上限、嵌套调用网格预算。
7. **内建对拍**（#259 交付，宿主参照 `build-elf`）：15 内建逐一覆盖——
   退出码对拍 q1 `exit(42)`=42、q2 `write`=5、q3a/b/c/d 内存族四宽
   （200/64/7/99）、q4a/b `mmap`/`brk`=77/88、q5a/b/c 嵌套与 park 交互
   （2/3/1）、q6 `openat`+`fstat`+`read`+`close`=100、q7 mmap i64 宽实参
   =225、q8 字符串字面量上的 load 族=9、q9 bool 参 `exit`=1；
   write 探针另比对 stdout 字节。错误探针 e5–e11/e13–e15 的消息与位置
   与宿主逐字一致（bootstrap 单行格式 vs 宿主富格式之差是 M3c 诊断的时代差，
   消息核心与位置即判据）；e15（exit 个数错误）为 bootstrap 自有消息，
   按钉定字符串比对。
8. **ELF 结构**（#260 交付，`readelf` 断言）：节表钉定——null/`.text`/
   `.rodata`?/`.data`?/`.bss`?/`.symtab`/`.strtab`/`.shstrtab` 的存在性与
   类型/flag/对齐（§9），`e_shstrndx` 指末节；符号表钉定——顺序、`_start`
   （有桩 size=16 / 无桩 = main 尺寸）、`__aster_init`、每函数
   `value=0x401000+词偏移*4`/`size=词数*4`、每全局 `value`/`size`/`shndx`；
   段表钉定——`p_offset ≡ p_vaddr (mod 0x1000)` 与三段的 filesz/memsz 分工
   （`.bss` 只进 memsz）；零依赖（无动态节、无 UND——null 符号除外）。
   综合样例 s1（`.data`+`.bss`+`.rodata`+入口桩+3 函数）与极端形态
   （无全局无串：1 段 5 节；仅 `.data`；仅 `.bss`）逐一断言。**实证记录**：
   原型 emitter 曾因补白游标漏计 Ehdr+Phdr 的 120 字节致 `.text` 整体后移、
   入口点落零（qemu SIGILL rc=132）——游标必须从 `64 + nseg*56` 起计；
   另修正「段缺失时三张表对齐到幻影数据页」为「跟在最后一段文件内容后 8 对齐」。

**不在 M3d 范围**（属 M4 闭环自举）：`bootstrap/aster.ast` 自身编译——
它调用 4 个 extern fn（`strlen/utoa/itoa/memcmp`，`bootstrap/aster.ast:33-36`），
独立镜像无法解析（§10 C9）。M4 以多对象链接或内建 lowering 闭合。
