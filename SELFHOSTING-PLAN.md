# Aster 自举完善计划（Self-Hosting Plan）

**约束：全程零依赖。** 单文件 C++ 引导编译器不引入任何外部库；bootstrap 编译器（用 Aster 自身写）产出静态 ELF，纯 `SVC #0` 系统调用，不链 libc、不使用外部 `malloc`。所有新增能力必须在 `src/aster.cpp` 内用裸 AArch64 指令实现。

**判定基准（来自 v0.23.39-dev 现状盘点；① ② 已由 M0/M1 关闭，③ 按既定策略规避）：**
- 已具备：i32/i64/u8/u16/u32/ptr/bool、struct（含 `ptr<自身>` 自引用）、全局数组（上限 1,048,576）、指针与字节内存原语（load_u8/store_u8/store_i64…）、递归（两遍收集，无前向声明限制）、i64（ELF 64 位字段）、`write` syscall、`main`→`exit`、`sizeof`/`len`、字符串字面量。
- 硬缺口：① ~~无法读输入（仅 `write`/`exit` 两个 syscall）~~ → **M0 已关闭**（read/openat/close/fstat，v0.23.40-dev）；② ~~无堆/分配器~~ → **M1 已关闭**（mmap/brk 可增长堆，v0.23.41-dev；分配器在 Aster 侧，如 `examples/arena.ast`）；③ `main` 被钉死 `() -> i32` 且无 argc/argv（自举改用 stdin 进 / stdout 出 规避）。
- 实际风险：每函数 8KB 固定帧 + 无尾调用优化 → 深递归逼近栈上限。

---

## M0 — 进料与 I/O（编译器增强，纯 syscall）【已交付 v0.23.40-dev】

bootstrap 必须能拿到源码字节。新增原始 Linux syscalls 作内建，与 `write` 完全同构：

| 内建 | 签名 | x8 | 说明 |
| --- | --- | --- | --- |
| `read(fd, buf, len)` | `(i32, ptr, i32) -> i32` | 63 | 返回读入字节数，0=EOF，负=-errno |
| `openat(dirfd, path, flags, mode)` | `(i32, ptr, i32, i32) -> i32` | 56 | aarch64 无 plain `open`；dirfd 传 -100（`AT_FDCWD`）按路径打开 |
| `close(fd)` | `(i32) -> i32` | 57 | 成功 0，失败负 -errno（如 -9 坏 fd）|
| `fstat(fd, buf)` | `(i32, ptr) -> i32` | 80 | aarch64 `struct stat` 的 `st_size` 在偏移 48 |

- 最小自举通道：`read(0, …)` 从 stdin 读源码，`write(1, …)` 写 ELF；shell 重定向接文件名。
- 若要按文件名读（对齐 C++ 版 `readFile(path)`）：用 `openat(-100, path, 0, 0)`+`read`+`close`（或 `fstat` 取大小）。
- 全部 SVC，零依赖。交付：源码 + 示例 + C 孪生 + 测试套件 + ci + 文档六件套 + VALIDATION + 全量 CI + 打包。

## M1 — 内存（不依赖 libc）【已交付 v0.23.41-dev】

- **首选（零编译器改动）**：全局 `u8[1<<20]` 竞技场 ×N + 全局 `ptr`/游标，在 Aster 内实现 bump 分配器。对"有界输入"的 bootstrap 足够。
- **已采用（v0.23.41-dev）**：加 `mmap`(222)/`brk`(214) 内建，使 bootstrap 用可增长堆；仍零依赖。交付细节：`mmap` 六参（两个 `i64`）是最宽内建；64 位结果 `MOV Xd, X0`、`i64` 参数全宽暂存两条宽度规则；`callType` 登记 `mmap`/`brk` 答 `Ty::Ptr`；`examples/arena.ast` + `tests/arena-twin.c` 差分一致；`tests/heap-checks.sh` [6/6] 五差分 + 十拒绝 + 两遮蔽 + 五变异探针。
- 目标：token 表 / AST / 符号表 / 输出字节缓冲都从竞技场分配，程序结束随进程退出释放。

## M2 — Aster 标准库雏形（纯 Aster 写，无需编译器改动）【已交付 v0.23.42-dev】

- 字节原语：`memcpy` / `memset` / `memcmp`（基于 `load_u8`/`store_u8`）。
- 文本：`strlen` / `strcmp` / `strncpy`（标识符/关键字匹配）。
- 数值：整数→十进制/十六进制字符串（ELF 字段、诊断输出）。
- 容器：开放寻址哈希表（符号表、标签表），基于全局数组。
- **交付形态（本轮的实质发现）**：`include` 只跨声明（v0.23.13-dev），库不能是 include——交付为 `build-obj` 产出的对象，消费方 `extern fn` 声明，`link-obj`（主对象在前）链接，即 `global_shared_main.ast` 的两对象模式。所有字节缓冲区参数为 `ptr<u8>`：实测唯一能同时收字符串字面量与 `&u8[N]` 的拼写（裸 `ptr` 拒 `&arr`，`ptr[N]` 元素也拒）。`std.o` 定义其使用的每个符号——唯一 UND 是 ELF null symbol，零依赖由套件机械断言。交付：`stdlib/aster_std.ast`（13 函数 + 2 全局，664 指令）、`examples/stdlib_demo.ast`（示例兼差分驱动）、`tests/aster-std-twin.c`（C 孪生，num 族先与 snprintf 交叉自证）、`tests/stdlib-checks.sh` [8/8]（交付链 + 3 拒绝 + 自包含 + 重复符号拒绝 + 8 个针对库源码的变异探针——本仓首次变异 Aster 源码而非编译器）。差分抓到两件事：FNV offset basis 补码两次算错（itoa 把错误常量逐位打回，证明编译器无辜；正确值 -3750763034362895579），以及 `strncpy` 返回值两边同错（差分抓不到「共识错误」，只有文档约定能抓）。

## M3 — bootstrap 编译器本体（aster.ast）【进行中：M3a、M3b、M3c 已交付，M3d 契约冻结、实现待起】

- **流水线**：词法 → 语法（显式工作栈替代深递归，控栈于 8KB 帧纪律内）→ 类型检查 → 生成 AArch64 字节 → 写出 ELF。
- **AST 表示**：每类节点一个独立全局数组 + 整数句柄（竞技场下标当指针），`kind: i32` 区分；规避 `kMaxStructSize=1024` 与无 `union` 的限制。
- **ELF 字段**：i64 + 字节内存原语手工小端化；无位域 → 移位/掩码。
- **输入/输出**：`read` 从 stdin（或 `openat(-100, path, 0, 0)` 按文件名）→ 解析 → `write` 到 stdout。
- **增量**：先覆盖 Aster 自身所用的语言子集，逐步扩张到全语言。
- **M3a（v0.23.43-dev，已交付）：词法阶段**。`bootstrap/aster.ast` 从 stdin 读入一份 Aster 源、向 stdout 转储令牌流（一行一枚令牌），无解析、无名字解析。契约先行冻结于 `bootstrap/LEXER-SPEC.md`（13 节）：72 个令牌类（编号与 `enum class TK` 一致）、C locale 字符类、位置语义（1 基、tab 记 1 列、令牌位置取首字节前）、注释/标识符/数字（含 `0x` 十六进制）/字符串（六转义，解码值入 strpool）/运算符（含 `<<=`/`>>=`/`->` 三字节前瞻）规则、转储格式、九条错误消息逐字冻结。名字表是数据不是代码：`bootstrap/gen_lexer_names.py` 单一事实源同时生成 Aster 侧（`K_*` 常量 + 864 字节打包名表 + `ident_is`/`keyword_kind`）与 C 孪生头 `tests/lexer_names.h`，并与 `src/aster.cpp` 交叉校验。差分孪生 `tests/lexer-twin.c` 按规格独立实现（结构数组对五并行数组、ctype 对字节区间、switch 对 if 链、snprintf 对库 `utoa`、stdio 对 read/write）。三条语言上限塑形设计并已入档：数组不得超 1 MiB → 源缓冲无哨兵字节，`peek()` 以光标比长度判结尾（内嵌 NUL 自然成为词法终点，与宿主一致）；同上限迫使 65536 令牌上限（E9，End 不计入）；`len` 是内建不可作参数名。常驻套件 `tests/lexer-checks.sh` 已于 **v0.23.44-dev 退役**（183 项检查、10 个变异探针），其覆盖被并入 M3b 的 `tests/parser-checks.sh`，复用同一词法孪生。链接产物唯一 UND 是 ELF null symbol。无新示例，基线 330 行字节不变。
- **M3b（v0.23.44-dev，已交付）：语法解析 + AST 转储**。`bootstrap/aster.ast` 在 M3a 词法之上追加显式工作栈的递归下降解析器与 AST 转储器，stdin→AST 三步流水线（词法 → 解析 → 转储）成型：一份 Aster 源进，紧凑 **AST 转储** 出（每节点一行 `Kind line:col` 加操作数），程序被解析为 40 类节点的树（`N_*` 语句、`S_*` 结构、`E_*` 表达式）。契约先行冻结于 `bootstrap/PARSER-SPEC.md`（13 节）：§6.1 优先级链 `logical(1)→logicalAnd(2)→bitor(3)→bitxor(4)→bitand(5)→equality(6)→relational(7)→shift(8)→sum(9)→product(10)`；错误目录 E1–E9 / P1–P62 / B1–B22；位置语义（Return 置于其表达式处、If 置于其条件处、调用语句的 `Expr` 置于被调用者处、二元节点继承左操作数令牌、组不新增节点）；以及限额闸门 C1=96 表达式嵌套、C2=96 语句嵌套、E8=1 MiB、E9=65536 令牌、C3=65536 节点（防御性——E9 在前拦截，最大节点/令牌比率为 1，故不可达）。名字表是数据不是代码：`bootstrap/gen_parser_names.py` 单一事实源生成 Aster 侧（`N_*`/`S_*`/`E_*` 常量 + 打包名表）并与 `src/aster.cpp` 的 `enum class NK` 交叉校验。差分孪生 `tests/parser-twin.c` 按规格独立实现（C 递归下降、结构数组 AST），在五个冻结 §9 示例、95 条钉死诊断、59 例边界语料、限额边缘与全仓库上逐字节一致——含解析器自读自身源码（7961 行转储）与标准库（555 行）。套件发现并修复两个真实 bootstrap bug：P50 诊断位置（曾把节点 id 喂给令牌查找，报 1:11 而非被调用者的 1:20）、P37/P40 的 `expected '='` 误带被赋值名（`…assignmenta`）。常驻套件 `tests/parser-checks.sh` [11/11] 共 **312 项检查**，含 **13 个针对 Aster 源码的变异探针**，并吸收了退役的 `tests/lexer-checks.sh`（183 项、10 探针）使整条流水线在一套中覆盖，复用同一词法孪生。链接产物唯一 UND 是 ELF null symbol。无新示例，基线 330 行字节不变。
- **M3c（v0.23.45-dev，已交付）：语义（类型检查）趟**。`bootstrap/aster.ast` 在 M3b 解析之上追加一次 AST 遍历：stdin 进一份 Aster 源，成功时**原样重发 M3b 的 AST 转储**（字节一致）、失败时打印单条 `aster: error: <Sxx> at L:C` 到 stderr 且 stdout 为空、退出码 1——纯校验门，无代码生成、无 ELF 写出。契约先行冻结于 `bootstrap/SEMANTIC-SPEC.md`（13 节，387 行）：五类型词汇（`i32`/`i64`/`u8`/`ptr`/`ptr<u8>`，`ptr<i32>`/`ptr<i64>` 结构性接受）、符号表模型（七并行 `i32` 数组，句柄索引，作用域链，帧控于 8KB）、遍历次序（顶层收集 → 声明检查 → 每函数作用域 → 表达式/语句类型检查 → 常量校验 → 容量上限）、§5 成功输出规则（转储与 M3b 字节一致）、`S1`–`S25` 错误目录、§7/§8 表达式/语句类型规则、§10 两阶段纪律（遍历完成前不写 stdout）。与宿主 `Sema` 的刻意差异记录在 §12（无 struct/union/用户类型、无 `bool`/`u16`/`u32`/`u64` 可存储类型、成功重发无类型转储而非 IR、实参上限 32 而非 500、无重载/泛型/模块）。差分孪生 `tests/parser-twin.c` 追加语义趟（C 结构数组 + 数组索引符号表），在接纳（转储逐字节一致）与拒绝（同一 `S` 诊断）上均与 bootstrap 锁步——含自读自身 10956 行源码与标准库 555 行源码（§15 自语义：转储与 M3b 字节一致）。常驻套件 `tests/parser-checks.sh` [12/11] 共 **333 项检查**，含 **20 例语义语料**（14 拒绝带精确 `S` 诊断、6 接纳与 M3b 字节一致）与 **13 个针对 Aster 源码的变异探针**（每个均断言能与孪生发散）。链接产物唯一 UND 是 ELF null symbol。无新示例，基线 330 行字节不变。
- **M3d（进行中，契约已冻结）：代码生成 + ELF 写出**。`bootstrap/aster.ast` 在 M3c 语义之上把 AST lower 成 AArch64 机器码并写出可独立运行的 ET_EXEC ELF（`qemu-aarch64` 直接运行；进程退出码/stdout 即程序语义）——stdin 进一份 Aster 源、stdout 出一个 ELF，失败时单条 `aster: error: <Cxx> at L:C` 到 stderr 且 stdout 无字节。契约先行冻结于 `bootstrap/CODEGEN-SPEC.md`（13 节，526 行，**每条指令编码均经 `aarch64-linux-gnu-as` + objdump 实证**）：三遍生成（`cg_collect` 地址分配 → `gen_function` 线性展开进 `textw: i32[262144]` → `elf_emit` 已知全部地址后写节并回填 fixup）；7 类型标签与宽度/符号规则（镜像宿主 `gen(want)` 的消费者期望宽度传播，`SXTW` 扩展、u8 无符号条件码）；AAPCS64 子集（`X0–X7` 传参、栈参 `[SP+8*(k-8)]`、`main`=`_start` 且每条 return 路径 lower 成 `MOV X8,#93; SVC #0`）；1024 槽 × 8B 帧布局（0..31 出参区、32..531 形参+局部、800..899 调用暂存网格、900..949 活临时溢出区、1022 调用结果中转、1023 X30）；迭代式 `gen_expr`（显式工作栈——`dense.ast` 类语料 3 万+ 节点左结合链会爆 Aster 调用栈）；25 种表达式与 9 种语句的逐节点 lowering（指针语义不对称：`p±整数` 为字节偏移 `SXTW`，`p[i]` 按元素宽缩放 `UXTW #sh`）；15 内建（8 syscall + 7 内存类，`exit=93` 为 bootstrap 新增）；固定节基址 ELF 布局（`.text@0x401000`/`.rodata@0x600000`/`.data@0x800000`，免地址 fixup；runtime-init 全局经入口桩 `BL __aster_init; B main` 在 `__aster_init` 中按声明序赋值）；错误目录 `C1`–`C15`（带宿主锚的镜像消息 + C9/C10/C13 新增长容量守卫）；与宿主 `build-elf` 的 10 项有意差异（§11）与孪生字节级一致条款（§12）；自举判据 6 项（§13：最小链路三样例、孪生 `cmp -s`、宿主运行等价、零依赖、≥3 变异探针、容量边界）。`bootstrap/aster.ast` 自身编译（4 个 extern fn）不在 M3d，属 M4。宿主 `src/aster.cpp` 本轮只改版本常量（无编译器改动轮）。
  - **M3d 实现进度（均落在 `bootstrap/aster.ast` 内部，宿主零改动）**：
    - **#255（已交付）：机器接口**。`emit_word` + 完整指令集（`emit_movz/movk/mov_rr/mov_zero/imm64/addr64/addsub_rr/addsub_ext/mul/div/msub/shift/logic/neg/sxtw/cmp_rr/cmp_imm/cset/bcond/bl/mem/frame_addr`），全部基于 i64 算术常数，宽度参数 `i64` 存 `i32` 数组时截断——指令编码全部经 `aarch64-linux-gnu-as` + objdump 实证，与 CODEGEN-SPEC §每指令逐字节一致。
    - **#256（已交付）：地址分配 `cg_collect`**。字符串/全局地址分配（`.rodata`/`.data` 线性布局）、函数标签 `fn_lab[]`、runtime-init 全局列表——三遍生成第一遍，产出第二遍 `gen_function` 所需的全部静态地址与标签。
    - **#257（已交付）：表达式 lower `gen_expr`**。迭代式表达式 lowering（显式工作栈 `(node,state,want)`，`gx_val[node]=结果寄存器`，LIFO 临时寄存器池 `X0–X15` 严格后进先出、释放非栈顶触发泄漏守卫 C12）；全 25 种 `E_*` 节点（`gen_combine`/`gen_leaf`/`gen_var`/`gen_index`/`gen_call`）+ 调用网格（park 活临时→`800+base+i` 网格槽→`X0–X7`/栈参→`BL fn_lab[fsym]`→结果存 1022 槽→恢复 park→读回）。已用临时 selftest 在 qemu 下对 38 条覆盖全运算符/数组/指针/整数提升/短路的探针语句逐条对拍十六进制编码，与手算期望一致后移除临时代码；`parser-checks.sh` 334 全绿。修复四类陷阱：main 经符号表 `main_sym→sfn[]` 定位（非 `N_Function.ntok`）、一元节点须早于二元字段在 `gx_dispatch` 顶部返回（否则 `ex_ty[-1]` 越界）、`E_Index` 结果落较旧下标寄存器并释放较新基址、`E_And`/`E_Or` 结果复用较旧左寄存器并释放较新右寄存器（独立 `t` 会压在 `b` 之上触发 LIFO 守卫）。intrinsics 当前暂标 `internal compiler error: intrinsic lowering not yet wired`，留待 #263。

## M4 — 闭环自举验证

- 用 `aster.ast` 自举编译自身（或最小子集）→ 产出 ELF。
- 与 C++ 版 `aster` 对同输入的产出做字节级对比 + qemu 差分孪生，对齐项目既有验证纪律（负例 / 结构检查 / 运行验收）。

---

## 里程碑顺序与主题（遵循"每版本单一主题"原则）

| 里程碑 | 版本 | 主题 | 编译器改动 |
| --- | --- | --- | --- |
| M0 | v0.23.40-dev | syscall I/O | 加 read/openat/close/fstat 内建 |
| M1 | v0.23.41-dev | 可增长堆（已采用 mmap/brk 路线） | 加 mmap/brk 内建（竞技场模式仅作文档化备选）|
| M2 | v0.23.42-dev | Aster stdlib | 无编译器改动，纯库 |
| M3 | v0.23.43-dev+ | bootstrap 编译器（M3a 词法、M3b 解析、M3c 语义已交付，M3d 生成 #255 机器接口/#256 cg_collect/#257 gen_expr 已交付、余下 #258 语句 #260 ELF 写出进行中） | 无编译器改动，纯库 |
| M4 | v0.23.43-dev+ | 闭环验证 | 无编译器改动 |

**当前进度：M0（v0.23.40-dev）、M1（v0.23.41-dev）、M2（v0.23.42-dev）、M3a（v0.23.43-dev）、M3b（v0.23.44-dev）、M3c（v0.23.45-dev）、M3d-#255/#256/#257（v0.23.46-dev）均已交付——M0 是 read/openat/close/fstat 原始 syscall 内建（CI 98/98），M1 是 mmap/brk 可增长堆内建（零依赖、无分配器），M2 是 Aster 标准库雏形（13 函数、单对象、零依赖，stdlib-checks.sh [8/8] 差分 + 8 个库源码变异探针），M3a 是 bootstrap 编译器本体的词法阶段（bootstrap/aster.ast，stdin→令牌流，LEXER-SPEC.md 冻结契约 + C 孪生差分，lexer-checks.sh 已于 v0.23.44-dev 退役并入 parser 套件），M3b 是 bootstrap 编译器本体的语法解析阶段（bootstrap/aster.ast，stdin→AST 转储，PARSER-SPEC.md 冻结契约 + C 孪生差分 + parser-checks.sh [11/11] 312 项检查含 13 个变异探针，链接产物零依赖），M3c 是 bootstrap 编译器本体的语义（类型检查）阶段（bootstrap/aster.ast，stdin→AST，成功原样重发 M3b 的 AST 转储、失败报 S 诊断且 stdout 为空，SEMANTIC-SPEC.md 冻结契约 + C 孪生语义趟差分 + parser-checks.sh [12/11] 333 项检查含 20 例语义语料与 13 个变异探针，链接产物零依赖）。M3d（v0.23.46-dev）契约已冻结（CODEGEN-SPEC.md，13 节 526 行，指令编码全部经 as 实证），实现推进中：**#255 机器接口**（emit_word + 全指令集，编码经 as 实证）、**#256 cg_collect**（字符串/全局地址分配、函数标签、runtime-init 列表，三遍第一遍）、**#257 gen_expr**（迭代式表达式 lower，全 25 种 E_* + 调用网格，qemu 下 38/38 探针语句编码逐条与手算对拍一致、临时代码已移除、parser-checks.sh 334 全绿）已交付；余下 **#258 语句/结构 lower（gen_stmt + gen_function + break/continue 标签栈 + __aster_init）**、**#259 调用与 syscall 序列 (#263)**、**#260 ELF 写出器（elf_emit）**、**#261 测试（codegen-twin + codegen-checks.sh + 退役 parser-checks.sh）**、**#262 文档与版本（0.23.46-dev）+ VALIDATION** 进行中——三遍生成落地于 bootstrap/aster.ast 内部，宿主零改动（仅版本常量）。两个真实 bootstrap bug 经套件发现并修复（P50 诊断位置、P37/P40 误带名）。三个硬阻塞（输入、内存、工具）已消除，M3d 按「先覆盖 Aster 自身子集」的增量路线推进，全程无需编译器改动。**
