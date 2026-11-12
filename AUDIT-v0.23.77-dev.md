# Aster 第四轮全量源码审计报告

**审计对象**：Aster 编译器 v0.23.77-dev，`HEAD = 6e7a148369ee88aa447463dff550ac38927151d1`
**审计基准**：`src/aster.cpp` 16,094 行、`bootstrap/aster.ast` 7,445 行、156 个 `tests/*.sh`（CI 注册 150 个套件）、132 个 `examples/*.ast`、393 行冻结字节基线、3 个 APK gate
**基线门禁**：`CI SUMMARY: 150 passed, 0 skipped, 0 failed (of 150 suites)` / `APK GATES: 3 passed, 0 skipped, 0 failed` / `CI_EXIT=0`；工作树干净、`HEAD == origin/main`
**审计方法**：五路并行只读源码审阅 → 候选条目 → 严格编译探针在 `qemu-aarch64` 上实测 → 每项配对照组 / C oracle / `aarch64-linux-gnu-objdump` 反汇编 / `readelf` ELF 读回 → 只保留有复现证据的项
**状态**：**确认 6 个真缺陷（2 个 P0、2 个 P1、2 个 P2），另有 3 项 P2/观察级实证、8 项门禁有效性元发现（含 1 项新增）、6 项静态确认待动态。本轮为纯审计轮，不改编译器、不改门禁、不重录字节基线；只读证据固化在 `tests/audit-evidence/v0.23.77-dev/`，缺陷按 §7 留待后续版本修复。**

> **本轮最重要的一句话**：这又是一次「全绿门禁下的全量审计」。150 个套件全过、393 行字节基线零漂移、3 个 APK gate 全过，一次只读审阅加 60 余个探针仍挖出两个 P0——而且**两个都落在 v0.23.77-dev 刚引入的新代码面**（`--compact-frames` 与 `f64`），两个都只需要最普通的合法组合（「大帧 + 第 9 个参数」「一个 double 变量 + 若干局部变量」）。`examples/*.ast` 中使用 `f64`/`f32` 的数量是 **0**，所以 393 行字节基线对这两个缺陷没有任何钉子。§6 给出了覆盖盲区的精确形状。


> **后续状态（v0.23.79-dev）**：D-03、D-04、D-05 已在 v0.23.79-dev 修复（详见 `VALIDATION-v0.23.79-dev.md`）。D-03 通过让 `initRefs` 跳过函数符号（`STT_FUNC`）与 `CALL26`/`JUMP26` 重定位，消除了跨对象 `extern fn` 调用被误判为「初始化必须按链接顺序」的假阳性；真正的跨对象数据读取（A-21）仍被拒绝。D-04 让 `aster.proj` 的 `page-size` 真正生效，落入 `filePage` 并抵达四个写出器的 `PT_LOAD` 对齐。D-05 让 SysV `.so` writer 的 `.tbss` 满足 `sh_offset == sh_addr` 且 `PT_TLS p_align` 贯通 TLS 块对齐，静态 / `build-so` / `link-so` 三条路径的节头一致。三个缺陷的字节基线零漂移（没有 example 使用 `page-size` 或严格 TLS 对齐）。G-01…G-08 门禁元发现仍开放。

> **后续状态（v0.23.78-dev）**：D-01、D-02、D-09 已在 `v0.23.77-dev` 线的三个后续提交（`e9bb50d` / `f6dc30a` / `a235ed2`）中修复；本报告的审计结论与分级保持原样、不改写。D-01 采用「帧大于 4095 即回退默认 8192 帧」的策略，未引入两段式 `ADD` 分裂；D-02 的 `imm12` 改为 `slot`，并由此消除了高 slot `f64` 越出帧写进调用者栈的后果（调用者哨兵 20 → 0，现已做成常驻断言）。v0.23.78-dev **不改编译器行为**，只把这三个修复收编为带版本号的发布，并补上它们缺失的门禁：9 层常驻套件 `frame-slot-contract-checks.sh`（注册进 `DEFAULT_SUITES` 与 `CRITICAL`）、19 个版本守卫重钉、393 行字节基线零漂移、`VALIDATION-v0.23.78-dev.md`。其余三个确认缺陷（D-03 / D-04 / D-05）与 G-01…G-08 仍按 §7 排队。

---

## 1. 范围、方法与纪律

### 1.1 五路划分

| 路 | 主题 | 当前源码的主要行号区间 |
| --- | --- | --- |
| 一 | 前端与语义层 | 219–3535（Lexer / Ty / 布局 / Parser / Sema）；1090–1390（`initializerFits` / `foldAtExprType` / `constExprType`）；3535–3742（常量折叠 / `promoteInt`）；276–330、737–800（最近名提示）；7660–8000（`exprYieldsPtr` / `semaTypeIsPlaceholder`） |
| 二 | 代码生成与调用 ABI | 3742–7382（Codegen 主体）；9355–9620（`compileProgram`）；7383–7422（发射助手）；新增的 f64/f32、`--compact-frames`、static locals、do-while、`main(argc,argv,envp)` |
| 三 | ELF 写出器与链接器 | 7382–7672（`writeElfBytes`）；9620–10138（DWARF / `.eh_frame`）；10138–10339（`writeObject`）；10339–11282（`parseObject` / `resolveRelocations` / `writeSharedObject`）；11282–12531（`writeSharedObjectDyn` / `checkInitOrder` / `linkSharedObjects` / `linkObjects`） |
| 四 | CLI 外围子系统 | 12531–14714（APK 打包 / 签名 / DER / PNG / AXML / ZIP / v2）；14109–14714（验签）；14715–15042（`buildApk` / `buildSoFromSource`）；15042–15222（项目基础设施）；15222–16094（`main()` 与全部子命令）；134–168（`execAarch64Image`） |
| 五 | 门禁有效性与自举链 | `tests/ci.sh`、`lib/{verdict,baseline,tools,linkmode}.sh`、`run-aarch64.sh`、`coverage-checks.sh`、`mutation-score-checks.sh`、`difftest-checks.sh`、`bootstrap/aster.ast`、`codegen-twin.c`、17 个 v0.23.77-dev 新套件 |

**本轮五路的实际执行**（如实记录，避免把「审阅过」等同于「有缺陷」）：第三、四、五路由并行只读审阅员返回带行号的候选表，主审计员逐条实证后只保留了 §2 中标记「确认（实测）」的项；第一、二路的审阅结论由主审计员直接承担——第二路产出 D-01/D-02（并额外实测了递归、深调用、`main(argc,argv,envp)`、static locals、f32/FP 调用约定等未发现问题），第一路产出 D-09（并复核了 `promoteInt`/`opIsUnsigned`、`constExprType`/`foldAtExprType`、`layoutStruct`、最近名提示等既有修复仍成立）。所有「确认」条目都有编译探针、对照组与读回证据；推断项一律降为 §5 的「静态确认」。

### 1.2 验证纪律

- **推断不算缺陷**。五路审阅员只读、不编译、不改文件；返回的每个「确认缺陷」都只是源码推断，必须由主审计员实测。
- **严格编译**。审计对象用 `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror` 重建到 `/tmp/aster_audit` 后使用，原工作树中的 `./aster` 不动。
- **每个异常项配对照组**。同类但走正确代码路径的程序：帧 <4096 的栈参数、无栈参数的大帧、不带 `--compact-frames` 的同一程序、f32 同形状、f64 在 slot 0、九个 `i32` 参数同形状、初始化器反序链接、B 无初始化器、CLI `--page-size 16384` 等。
- **第三方 oracle**。C 语义用 `aarch64-linux-gnu-gcc -O2 -fwrapv -static` 编译同源 C 程序在 qemu 上跑（`D02_oracle.c`）；AArch64 编码用 `aarch64-linux-gnu-objdump -d` 读回实际发射的指令；ELF 契约用 `aarch64-linux-gnu-readelf -SW/-lW/-rW/-sW`。
- **低 8 位陷阱**。进程退出码只保留低 8 位；本轮第一轮 f64 探针就因此漏报——`p7=99` 的 32 位写只扰动了 double 2.5 的尾数末位，`fcvtzs` 仍得 2。改用 `if (x == 2.5) { return 0; } return 1;` 的逐位相等条件返回后才捕获。凡涉及「读回值是否正确」的判定一律如此。
- **不污染工作树**。所有探针、项目、假套件都在 `/tmp`；交付物只新增 `AUDIT-v0.23.77-dev.md` 与 `tests/audit-evidence/v0.23.77-dev/`。

### 1.3 分级标准

沿用 `AUDIT-v0.23.72-dev.md` §1.3：

| 级别 | 判据 |
| --- | --- |
| **P0** | 合法程序崩溃（SIGILL/SIGSEGV），或静默产出错误结果且影响常见合法组合 |
| **P1** | 语义/契约错误，影响较窄或需特定输入，但结果不正确（含拒绝合法程序） |
| **P2** | 一致性、互操作性或依赖特定威胁模型的偏差，不构成普遍误编译 |
| **门禁** | 不直接误编译，但回归能溜过门禁或套件能被伪造 PASS |
| **观察** | 静态确认、未动态复现，或需 ELF 节头手术 / 特殊威胁模型 |

### 1.4 与前几轮审计的关系

- v0.23.61-dev 第一轮审计的 4 个 P0 + 5 个 P1 已在 v0.23.62–v0.23.70 修复，**不重复报告**。
- v0.23.72-dev 第二轮审计的 F-01…F-12 已在 v0.23.73–v0.23.76 全部修复；F-13 属威胁模型依赖。**不重复报告**。
- v0.23.76-dev 第三轮审计（A-01…A-26，远端 DSH 审计线）的代码缺陷均已修复，A-03 撤回、A-02/A-04/A-07 为文档项。**不重复报告**。
- 第二轮的两类开放项本轮**逐条复核当前状态**：S-01…S-08、G-01…G-07、K-01。结论见 §4、§5——G-01…G-07 在当前代码里**全部仍成立**；S-05 看起来已修；S-01 仍未修；K-01 仍是技术债。
- v0.23.77-dev 本 checkout 的跨宿主 CI 适配（`.dynamic` DT_NULL padding、`execAarch64Image`、`$RUNNER`/`$HOSTCC`）是上一轮交付，本轮把它当作**审计对象**而非新修复：§3 的 D-01/D-02 与 §5 的观察项都建立在它之上。

---

## 2. 结论总表

| # | 路 | 条目 | verdict | 级别 |
| --- | --- | --- | --- | --- |
| **D-01** | 二 | `--compact-frames` 下帧 >4095 且有栈上传入参数时，`ADD X16,SP,#frameBytes` 的 imm12 溢出到 shift 位 | **确认（实测）** | **P0** |
| **D-02** | 二 | `loadVarT`/`storeVarT` 的 F64 分支把 imm12 写成 `slot*8`，字节偏移被放大 8 倍 | **确认（实测）** | **P0** |
| **D-03** | 三 | `checkInitOrder` 把初始化器里的 `CALL26` 函数调用误判成「读取后面对象的全局」，误拒合法链接 | **确认（实测）** | **P1** |
| **D-04** | 四 | `aster.proj` 的 `page-size` 被解析、被校验、被静默丢弃 | **确认（实测）** | **P1** |
| **D-05** | 三 | SysV `.so` writer 的 `.tbss` `sh_offset ≠ sh_addr`，PT_TLS `p_align` 硬编码 16 | **确认（实测）** | **P2** |
| D-06 | 四 | `aster.proj` 重复源行 → 缓存伪装成「复用」，链接报晦涩的重复符号 | **确认（实测）** | P2 |
| D-07 | 四 | 含空格路径的缓存 meta 按首个空格切分，该对象永不命中缓存 | **确认（实测）** | 观察 |
| D-08 | 四 | `execAarch64Image` 把 `execvp` 的 ENOENT 覆盖回 ENOEXEC，掩盖 qemu 缺失 | **确认（实测）** | 观察 |
| **D-09** | 一 | 词法器把 gcc 拒绝的 `1e2e3` / `1.5.2` 静默截断成合法 token | **确认（实测）** | **P2** |
| G-01 | 五 | 零断言 `exit 0` 被判 `PASS` | **确认（实测）** | 门禁 |
| G-02 | 五 | `CI_SKIP_APK_GATE=1` 三 gate 全跳而终判仍绿 | **确认（实测）** | 门禁 |
| G-03 | 五 | 8 个套件的「no compiler change」层只数 393 行，无字节 oracle | 静态确认 | 门禁 |
| G-04 | 五 | 覆盖/变异棘轮是静态 grep + 硬编码 floor，`\|\| :` 吞错误 | 静态确认 | 门禁 |
| G-05 | 五 | 字节基线只钉 3 个写出器、豁免 1 个 example、58 行 `FAILED` 占位 | 静态确认 | 门禁 |
| G-06 | 五 | 部分套件变异用整文件 sha256 差分而非不变量 | 静态确认 | 门禁 |
| G-07 | 五 | `CI_JOBS` 分组靠字面 `/tmp/`，`grep -qv TMPD` 恒真退化 | 静态确认 | 门禁 |
| **G-08** | 五 | 17 个 v0.23.77-dev 新套件全部不在 `CRITICAL`；C 差分 / coverage 层可静默跳过 | **确认（实测）** | 门禁 |
| S-01 | 三 | `resolveRelocations` 对 `r.patch` 仍无边界检查 | 静态确认，未动态复现 | 观察 |
| S-09 | 三 | `initRefs` 未做 `remapPrivateStringSymbol`，A-25 私有字符串依赖漏检 | 静态确认，中置信 | 观察 |
| S-10 | 三 | `dwarfCuStmtListOffset` 命中 `DW_AT_stmt_list` 时缺 `p+4` 边界检查 | 静态确认，中置信 | 观察 |
| S-11 | 三 | `writeSharedObjectDyn` 的 `.rodata` 仅按 `pageSize` 对齐却校验 `spec.rodataAlign` | 静态确认，低置信 | 观察 |
| S-12 | 四 | APK v1 覆盖检查跳过整个 `META-INF/`，非签名文件可无摘要搭车 | 静态确认，低置信 | 观察 |
| S-04 | 四 | `build-apk` 预编译 `.so` 与 `--page-size` 组合仍无 ELF `p_align` 校验 | 静态确认 | 观察 |
| K-01 | — | `typeOf` / `exprType` 语义分歧、TypedIR 豁免名单 | 已知治本项 | 技术债 |

**统计**：6 个确认缺陷（P0×2、P1×2、P2×2）；3 项 P2/观察级实证（D-06/07/08）；8 项门禁元发现（含 1 项新增）；6 项静态确认待动态 + 1 项技术债。全部证据见 `tests/audit-evidence/v0.23.77-dev/EVIDENCE.md`。

### 2.1 审阅候选 → 最终 verdict 对照

推断不算缺陷。下表把三、四、五路审阅员返回的带行号候选逐条对应到实测结论，「观察」表示静态确认但未动态复现，「撤回」表示复核后认为不成立。

| 候选 | 主题 | verdict |
| --- | --- | --- |
| R3-01 | `checkInitOrder` 以「对象有无初始化器」代替「写集」 | **D-03（P1，实测确认）** |
| R3-04 | SysV writer 的 `.tbss` off/addr 与硬编码 `kTlsBlockAlign` | **D-05（P2，实测确认）** |
| R3-02 | `initRefs` 未 `remapPrivateStringSymbol` | S-09（观察） |
| R3-03 | `dwarfCuStmtListOffset` 缺 `p+4` 边界 | S-10（观察） |
| R3-05 | `resolveRelocations` 对 `r.patch` 无边界检查 | S-01（沿用第二轮，观察） |
| R3-06 | Dyn writer 的 `.rodata` 起点未按 `rodataAlign` 抬升 | S-11（观察） |
| R4-01 | `aster.proj` 的 `page-size` 解析后丢弃 | **D-04（P1，实测确认）** |
| R4-03 | 源列表不去重 → 缓存复用出重复对象 | **D-06（P2，实测确认）** |
| R4-04 | meta `src` 行按首个空格切分 | **D-07（观察，实测确认）** |
| R4-02 | `execAarch64Image` 把 ENOENT 覆盖回 ENOEXEC | **D-08（观察，实测确认）** |
| R4-05 | v1 覆盖检查跳过整个 `META-INF/` | S-12（观察，威胁模型依赖） |
| R5-01 / R5-02 | 零断言 PASS / APK gate 一键跳过 | **G-01 / G-02（受控实验确认）** |
| R5-03 / R5-04 / R5-05 / R5-06 / R5-07 | 无字节 oracle / 基线豁免 / 整文件 hash 变异 / 静态棘轮 / 并行分组 | G-03 / G-05 / G-06 / G-04 / G-07（静态确认，当前行号见 §4） |
| R5-08 | 17 个新套件不在 `CRITICAL`、C 差分可静默跳过 | **G-08（新增，受控实验确认）** |
| — | A-22（不含 `_start` 的对象初始化链断开） | **撤回**：`codegen :7293` 只在 main 注入 `BL __aster_init`，跨对象确实会断，`:12355` 拒绝成立 |
| — | A-14 / A-13 / A-16 后续 / A-03 / S-05 | **复核无误或已修**，见 §5 |
| — | 第五路孤儿复核 | 6 个未注册脚本均在 allowlist，无 `*-checks.sh` 孤儿 |

---

## 3. 确认的缺陷

### D-01（P0）`--compact-frames` 的栈参数基址立即数溢出

**位置**：`src/aster.cpp:7358-7359`（对照正确实现 `:7340-7346` 的 `framePair()`）

```cpp
if(compact&&frameBytes!=8192u)
    for(size_t at:incomingBaseWords)code[at]=0x910003f0u|(frameBytes<<10);
```

**机理**：`0x910003f0` 是 `ADD X16, SP, #0`，imm12 占 bit[21:10]，上限 4095。`frameBytes > 4095` 时 `frameBytes<<10` 会连带置起 bit 22——AArch64 ADD immediate 的 `shift` 位——指令变成 `ADD X16, SP, #imm12, LSL #12`，实际加的是 `(frameBytes & 0xfff) << 12`。序言 `framePair()` 明确处理了 >4095（拆成两条 SUB/ADD），此处没有。`incomingBaseWords` 由第 9+ 个整数/浮点参数、栈上传入的结构体参数触发（`:7252`、`:7274`、`:7278`、`:7286`）。

`frameBytes == 8192` 时条件不成立，保留原始的 `ADD X16, SP, #0x2, LSL #12`（8192），所以只有 `[4096, 8191]` 区间受害。

**复现**：`D01_compact_stack_arg.ast`（9 个整数参数 + `i64[467]` 局部数组 + 一次嵌套调用使紧凑帧恰为 4096）：

| 变体 | frameBytes | 发射的 `ADD X16, SP` | 期望 | 实测 |
| --- | --- | --- | --- | --- |
| pad=100（对照） | 0x480 | `#0x480` | 8 | 8 |
| pad=465（对照） | 4080 | `#0xff0` | 8 | 8 |
| **pad=467** | **4096** | **`#0x0, lsl #12`（= SP+0）** | **8** | **0** |
| pad=469 | 4112 | `#0x10, lsl #12`（= 65536） | 8 | **SIGSEGV** |
| pad=480 | 4192 | `#0x60, lsl #12`（= 393216） | 8 | **SIGSEGV** |
| 同一探针不带 `--compact-frames` | 8192 | `#0x2, lsl #12` | 8 | 8 |
| `D01_ctl_no_stack_arg.ast`（大帧、无栈参数） | 8192 | 无 `incomingBaseWords` | 7 | 7 |

`frameBytes == 4096` 时 X16 指向本帧开头，`LDR W16,[X16]` 读到第一个参数 `a=1` 而不是第 9 个栈参数 `j=9`，`j-a` 变成 `1-1=0`：**不崩溃，静默产出错误结果**。这正是 P0 里最危险的一类。

反汇编（pad=480，compact，`f()` 序言）：

```
4010b8: d14007ff  sub  sp, sp, #0x1, lsl #12     ; 4096
4010bc: d10183ff  sub  sp, sp, #0x60             ;   96  => frame 4192
4010c0: f9082ffe  str  x30, [sp, #4184]          ; raOff = 4192-8，正确
4010e4: 914183f0  add  x16, sp, #0x60, lsl #12   ; 应为 #4192，实为 393216
4010e8: b9400210  ldr  w16, [x16]                ; -> SIGSEGV (rc 139)
```

### D-02（P0）f64 帧槽的立即数被放大 8 倍

**位置**：`src/aster.cpp:4005-4021`

```cpp
if(t==Ty::F32)return 0xbd4003e0u|(uint32_t(slot*2)<<10)|uint32_t(reg);  // 正确：STR S 缩放 4，slot*2 -> byte slot*8
if(t==Ty::F64)return 0xfd4003e0u|(uint32_t(slot*8)<<10)|uint32_t(reg);  // 错误：STR D 缩放 8，slot*8 -> byte slot*64
```

**机理**：`loadVarT`/`storeVarT` 的 F64 分支把「字节偏移」当成了 imm12，而 LDR/STR D 本身按 8 缩放；正确值应为 `slot`（对比 `loadVar64` 用 `slot`）。同一文件里 `loadStackT`/`storeStackT`（`:4572`/`:4580`）、`loadAtT`/`storeAtT`（`:5705`/`:5713`）、`loadGlobalT`（`:4554`）、栈上传入 FP 参数（`:7256`）都用 `off/8`——**这是唯一一处写错**，F32 分支 `off/4` 的等价形式 `slot*2` 是对的。后果是 slot `s` 的 f64 落在字节 `s*64`，与按 `slot*8` 推进的其它局部变量区重叠：只要函数里有 ≥ `8s` 个后续 slot，两边就互相覆写。

**复现与对照**（`D02_*.ast`、`D02_oracle.c`）：

| 探针 | 期望 | Aster | C oracle | 判定 |
| --- | --- | --- | --- | --- |
| `D02_f64_slot1.ast`（x 在 slot 1，p7 在 slot 8） | 0 | **1** | 0 | 误编译 |
| 同形状但 7 个 `i64` 变量（8 字节覆写） | 0 | **1** | 0 | 误编译 |
| `D02_ctl_slot0.ast`（x 在 slot 0，`0*64 == 0`） | 0 | 0 | — | 正确 |
| `D02_ctl_f32_slot1.ast`（同形状，f32） | 0 | 0 | 0 | 正确 |
| `D02_nine_f64_params.ast`（9 个 f64 参数 + 局部数组） | 8 | **255**（=-1） | 8 | 误编译 |
| 同形状但 9 个 `i32` 参数 + 局部数组 | 8 | 8 | — | 正确 |

反汇编（`D02_f64_slot1.ast`，x 本应在 `[sp,#8]`）：

```
401020: fd0023e0  str  d0, [sp, #64]      ; x = 2.5 -> slot 1 被写成 byte 64
401058: b90043e0  str  w0, [sp, #64]      ; p7 = 0  -> slot 8，覆写 x 的低 32 位
401060: b90043e0  str  w0, [sp, #64]      ; p7 = 99 -> 再次覆写
401064: fd4023e0  ldr  d0, [sp, #64]      ; x 读回被污染的位型
```

九个 f64 参数的例子更直接：参数按 slot 0,8,16,…,64 存到 `[sp,#0]…[sp,#512]`，而 `let pad: i64[480] = 0;` 从 `[sp,#72]` 起逐 8 字节清零，把 c..j 全部抹成 0.0；`j-a` 于是 `0.0-1.0=-1.0`，`i32()` 返回 -1 → 退出码 255。

**为什么门禁没抓到**：`tests/float-checks.sh:119` 的 `a_nine` 是同样的九个 f64 参数但**没有局部变量**，参数区自洽；`s_local`/`s_field`/`s_array` 的 f64 都在 slot 0 附近，没有足够的后续 slot 触发重叠。132 个 shipped examples 中 `f64`/`f32` 出现次数为 0。

### D-03（P1）`checkInitOrder` 把函数调用误判成跨对象全局读取

**位置**：`src/aster.cpp:11909-11928`、`11968-11976`（`linkObjects` 的镜像在 `:12214`/`:12218`/`:12331`）

```cpp
11921  if(!initNameByInput.count(j))continue;
11922  if(j>i) throw Error(... "initializers run in link order" ...);
```

**机理**：`initRefs[i]` 收集 `__aster_init` 范围内**所有**重定位符号（含 `R_AARCH64_CALL26` 到别的函数、函数地址、静态初始化常量），`ownerOf`（`:11968`）含**所有**定义符号（含 `STT_FUNC`），`initNameByInput` 只记「对象带初始化器」。判据是「引用了 j 定义的任意符号且 j 也有初始化器」，缺「写集」信息。A-21 的本意是拒绝「后面的对象给前面的初始化器提供初值」，但这里的 `helper` 是一个**函数**，与初始化顺序无关。

**复现与对照**（`D03_*.ast`）：

| 命令 | 期望 | 实测 |
| --- | --- | --- |
| `link-so a.o b.o -o ab.so` | 成功 | `error: a.o: its run-time global initializer reads 'helper', which b.o sets in its own initializer; ... must be listed before a.o` |
| `link-so b.o a.o -o ba.so`（反序） | 成功 | 成功 |
| `link-so a.o b2.o -o ab2.so`（B 无运行期初始化器） | 成功 | 成功 |

`readelf -rW a.o`：`R_AARCH64_CALL26 helper + 0`，落在 `__aster_init`（size 48）内；`readelf -sW a.o` 显示 `helper` 是 `UND FUNC`。A 只调用一个函数，不读 B 的任何全局状态，两种链接顺序语义等价，却被顺序依赖地拒绝。**注意**：A-22（不含 `_start` 的对象初始化链根本不进）经复核**不是**误拒——`codegen :7293` 只在含 `main` 的对象注入 `BL __aster_init`，跨对象时链确实会断，`:12355` 的拒绝成立；`link-so` 走 `.init_array`（`:12103`）故不做该检查，是合理路径差异。

### D-04（P1）`aster.proj` 的 `page-size` 是死设置

**位置**：`spec.pageSize` 全文件只有两处命中——`:15140`（解析赋值）、`:15709`（范围校验）；`:15710` 无条件 `const uint64_t filePage = ps;`（`ps` 是 CLI 值，默认 4096）

**机理**：项目文件里的 `page-size` 被解析、被校验（非 4096/16384 会报错），给用户「已生效」的错觉，但随后从未参与构建。`filePage` 决定 ELF 段对齐（`linkSharedObjects`/`linkObjects`，`:15789`/`:15820`）、ZIP 对齐（`buildApk`，`:15815`）和缓存键（`:15716`）。注释 `:15095`「0 = use the command line / default」暗示非 0 应生效。

**复现**（`D04_project_page_size.sh`）：

```
aster new --apk p16 ; printf 'page-size 16384\n' >> p16/aster.proj ; cd p16 ; aster build
  -> rc=0，无任何告警
  -> build/.cache/*.meta:  flags --p|4096
  -> readelf -lW build/.cache/p16.so:  LOAD ... Align 0x1000
对照：同一项目 aster build --no-cache --page-size 16384
  -> LOAD ... Align 0x4000
```

在要求 16 KB 页对齐的 Android 15+ 设备上，前者产物无法加载且**构建过程不给任何提示**。与历史已撤回的 A-03（`--page-size` 校验不一致）机理不同：这是「配置解析后丢弃」。

### D-05（P2）SysV `.so` writer 的 `.tbss` 契约分叉

**位置**：`src/aster.cpp:11198`（`setSh(kTbssIdx, ..., tbssVaddr, tdataVaddr+tdataSize, ...)`）、`:11220`（`ptls.align=kTlsBlockAlign`）

用 `D05_sysv_tbss.ast`（.tdata 4 字节 + .tbss 16 字节）：

| 命令 | .tbss Address | .tbss Off | PT_TLS Align |
| --- | --- | --- | --- |
| `build-so tls.ast -o sysv.so`（无 soname/needed → SysV writer） | `0x3010` | **`0x3004`** | `0x10` |
| `build-so --soname libdyn.so tls.ast -o dyn.so`（Dyn writer） | `0x3010` | `0x3010` | `0x10` |

在 addr==file-offset 的 identity map 下，NOBITS 节的 `sh_offset` 应与 `sh_addr` 一致；Dyn writer（`:11842`）如此，SysV writer 用了未对齐的 `tdataVaddr+tdataSize`。此外 SysV writer 全程硬编码 `kTlsBlockAlign=16`（`:10937`/`:10938`/`:11197`/`:11198`/`:11220`），未接收 `spec.tlsAlign`，而 F-10 的提升只落在 `link-so`/Dyn 路径（`:11553`/`:11802`/`:11841`）——即 v0.23.76-dev 修掉的 PT_TLS 恒 16 问题在单源 `build-so` 的 SysV 分支里仍有一半残留。

**A-16 后续复核（无新缺陷）**：`writeSharedObjectDyn` 用 `dynSize = dyn.size()*sizeof(...)`（`:11545`）并显式 `DT_NULL` 收尾（`:11544`），不存在 `kDynEntries` 堆越界读；`linkSharedObjects` 同理。本 checkout 上一轮在 `writeSharedObject` 加的 `dyn.resize(kDynEntries, Elf64Dyn{0,0})`（`:11048-11049`）已把该侧修好，`:11029` 的 `dynSize` 与 resize 后的 `dyn.size()` 一致。

### D-09（P2）词法器静默接受并截断畸形浮点字面量

**位置**：`src/aster.cpp:443-474`（数字 token 扫描循环）、`:1885`（`nn->fv=std::strtod(tok.s.c_str(),nullptr);`）

**机理**：fractional 分支（`:452-456`）与 exponent 分支（`:462-472`）在取完一段后 `continue` 回到同一个 `for(;;)` 顶部，因此**同一个数字 token 可以反复拥有小数点和指数**：`1e2e3` 会被完整拼成一个 `TK::Number`，`1.5.2` 同理。随后 `strtod` 用 `nullptr` 作 `endptr`，既不检查是否消费了整个 token，也不检查 `ERANGE`，于是尾部垃圾被静默丢弃，字面量取 `strtod` 能解析的前缀值。`float-literal-checks.sh:80-82` 只测了 `1e` / `1.5e+` / `1e9u` 三种拒绝，没有覆盖「重复分段」。

**复现与对照**（`D09_malformed_float_literal.ast`，`return i32(x);` 读回实际值；`aarch64-linux-gnu-gcc -O2 -c` 作第三方裁判）：

| 字面量 | Aster | 实际值 | gcc |
| --- | --- | --- | --- |
| `1e2e3` | 编译通过 | `100.0` | `error: invalid suffix "e3" on floating constant` |
| `1.5e2e3` | 编译通过 | `150.0` | `error: invalid suffix "e3" on floating constant` |
| `1.5.2` | 编译通过 | `1.5` | `error: too many decimal points in number` |
| `1.2.3` | 编译通过 | `1.2` | `error: too many decimal points in number` |
| `1e2`（对照） | 编译通过 | `100.0` | 接受 |
| `1e400` | 编译通过 | `inf`（`i32` 饱和，退出码 255） | 接受（带溢出警告） |

`strtod` 参考值由 libc 直接读回：`1e2e3 -> 100.0`、`1.5.2 -> 1.5`、`1e400 -> inf`，与 Aster 的实测值逐项吻合，证实是「前缀截断」而非某种自定义语义。`1e400` 的 inf 与 gcc 一致（C 也接受），不升级；但 `1e2e3` / `1.5.2` 这类 gcc 明确拒绝的输入被静默改义，属于接受非法程序（P2）。

---

## 4. 门禁有效性元发现

第二轮审计的 G-01…G-07 在当前 `ci.sh` 里**全部仍成立**（行号已更新），本轮用受控实验重新实测了其中三条，并新增 G-08。

**受控实验**（`G_gate_experiment.sh`，用 `CI_SUITE_DIR` 指向 `/tmp` 的假套件，不污染工作树）：

```
zero-assert.sh   = #!/bin/sh ; exit 0
silent-skip.sh   = #!/bin/sh ; echo "SKIP: no oracle on this host" ; exit 77
legacy-skip.sh   = #!/bin/sh ; echo "SKIP: no oracle on this host" ; exit 0

CI_SUITE_DIR=... CI_SUITES="..." CI_SKIP_APK_GATE=1 sh tests/ci.sh
  zero-assert.sh   PASS
  silent-skip.sh   SKIP
  legacy-skip.sh   SKIP
  CI SUMMARY: 1 passed, 2 skipped, 0 failed (of 3 suites)
  APK GATES : 0 passed, 1 skipped, 0 failed
  CI_EXIT=0
```

| 编号 | 当前位置 | 结论 |
| --- | --- | --- |
| G-01 | `ci.sh:395-402` | `rc==0` 且非 legacy-skip 即 `PASS+1`，**不要求 `pass_marks>0`**；`:356` 的 grep 只用于区分 legacy |
| G-02 | `ci.sh:558-559`、`:586` | `GATE_SKIP` 不进终判；`ci-protocol-checks.sh:296` 自身就以 `CI_SKIP_APK_GATE=1` 调 `ci.sh` |
| G-03 | `difftest-checks.sh:111-116` 等 8 处 | 「no compiler change」层只断言 `rows == 393`，不比较任何哈希字节；改掉 digest 保持行数即可溜过 |
| G-04 | `coverage-checks.sh:53-100,116`、`mutation-score-checks.sh:22-24,38,44,60`、`ci-protocol-checks.sh:388-392` | 覆盖/变异棘轮是静态 grep + 硬编码 `FLOOR=80`；每条 CLI 都 `>/dev/null 2>&1 \|\| :`，崩溃也只算「进入过函数」；`mutation-score` 不运行任何变异体，仅 grep 声明数与 `KILL` 正则文本就宣称 100% caught |
| G-05 | `section-align-contract-checks.sh:475-493`、`lib/baseline.sh:57-59` | 393 行 = 131 examples × 3 写出器，`address_of_abi` 被豁免；复现循环以基线为输入，永不构建它；`build-pie`/`build-obj`(非 pic)/`link-*` 无字节钉；58 行 `FAILED` 占位只钉「仍失败」 |
| G-06 | `union-checks.sh:533-541`、`stride-scale-checks.sh:331-336` | 「变异被注意到」=整个 ELF 任意字节不同，不验证变化落在被变异规则上 |
| G-07 | `ci.sh:496-505` | `grep -qv 'TMPD'` 意为「存在一行不含 TMPD」，几乎恒真；判定退化为「含字面 `/tmp/` 才串行」 |
| **G-08（新）** | `ci.sh:86`、`:288-302`、`wide-int-literal-checks.sh:432-437`、`coverage-checks.sh:42` | `CRITICAL` 是 25 个老套件的硬编码列表；17 个 v0.23.77-dev 新套件**全部不在**。非 CRITICAL 套件 `rc=77` 静默 SKIP 不计 FAIL；`wide-int-literal-checks.sh` 在 HOSTCC 非 AArch64 时只 `echo SKIP` 而不 exit，C 差分层静默跳过、套件其余层照跑 `exit 0`；`coverage-checks.sh` 缺 gcov 时 `aster_skip` → 静默绿 |

**门禁覆盖最薄的新增代码面**（按第五路判断）：project CLI 全流程（`project-checks.sh` 有 16 层退出码/日志断言，但字节基线完全不覆盖，且 `coverage-checks.sh:79-90` 里所有 project 调用 `|| :` 吞错误）；`address_of_abi.ast`（唯一被字节基线豁免的 example）；`f64-short-circuit-checks.sh`（660 B，仅 1 层 happy-path）；`build-pie`/`build-obj`(非 pic)/`link-*` 写出器。相对最扎实的是 `--compact-frames`（`frame-size-checks.sh` 10 层，含 pin 8192、CFI 列表比对、mutation、深度溢出）——**但 D-01 恰好落在它没测的那个组合上**。

**孤儿复核**：`ci-protocol-checks.sh:343-366` 的 allowlist 枚举全部 `tests/*.sh`；磁盘上 6 个未注册脚本均在允许列表，无 `*-checks.sh` 孤儿，150 个注册套件文件均存在。本轮新增的证据文件在 `tests/audit-evidence/` 子目录，不参与该枚举。

---

## 5. 静态确认 / 待动态观察

| 编号 | 位置 | 内容 | 状态 |
| --- | --- | --- | --- |
| S-01 | `:10747`、`:10769-10774`、`:10798` | `resolveRelocations` 对 `r.patch` 仍无边界检查；link 路径由 `parseObject:10599-10604` 的 `need=4/8` 兜底，但 `writeSharedObject(:10974)`/`writeSharedObjectDyn(:11724)` 的 pending 来自 `build-so` 直接 codegen（`:14944`），未经 parseObject | 第二轮遗留，仍未修，未动态复现 |
| S-09 | `:11960-11966`、`:11968`、`:11972-11975`、`:12054` vs `:12304` | `ownerOf` 的键经 `remapPrivateStringSymbol`，`initRefs` 仅剥 `__aster_gat_` 前缀未 remap，A-25 私有字符串依赖漏检；`link-so` 对 FDE 调用 remap 而 `link-obj` 未调用，两 linker 分叉 | 中置信，未动态复现 |
| S-10 | `:10415-10434`、`:10650-10652`、`:12044-12045`、`:12293-12296` | `dwarfCuStmtListOffset` 命中 `DW_AT_stmt_list` 时直接 return，未校验 `p+4<=info.size()`；畸形 `-g` 对象可令 `slOff` 逼近末尾，link 写四字节越界 | 中置信，需 ELF 节头手术 + ASAN |
| S-11 | `:11493`、`:11828-11831`、`:12090` | `rodataVaddr` 仅 `alignUp(...,pageSize)`，却校验 `spec.rodataAlign`（合并 `maxRodataAlign` 可达 65536），>4096 时直接 throw 拒链；注释「every request is <= 4096」未受输入约束 | 低-中置信，需节头手术注入高对齐 |
| S-12 | `:14441-14446` | APK v1 覆盖检查跳过整个 `META-INF/`，可追加未签名、未覆盖的 `META-INF/*`；不影响已签名 payload 摘要，属搭车而非绕过验签 | 低置信，威胁模型依赖 |
| S-04 | `:15940`、`buildApk:14803` | 预编译 `.so` 与 `--page-size` 组合仍不校验/重排 ELF `p_align` | 第二轮遗留 |
| S-05 | `:13415-13417` | 原子写忽略目录 fsync——**复核为已修**：当前已 `open(dir,O_DIRECTORY\|O_CLOEXEC)` + `fsync(dfd)` | 关闭 |
| K-01 | 全局 | `typeOf` / `exprType` 语义分歧、TypedIR 豁免名单 | 已知治本项，沿用 |

**已实证但不升级的项**：D-06（`aster.proj` 重复源行 → `duplicate global symbol 'add'`，对照 `aster add` 正确提示 `is already in aster.proj`，P2）；D-07（含空格路径第二次构建仍 `1 compiled, 2 reused`，对照无空格 `0 compiled, 3 reused`，观察）；D-08（`PATH` 无 qemu 时 `aster run` 只报 `Exec format error`，`:153` 把 `execvp` 的 ENOENT 覆盖回 `execErrno`，观察）。这三项都是配置/诊断/性能层面，不构成误编译。

**复核为无误的项**：A-14（`--abi` 与 `e_machine` 校验，`:14727-14753`）完整；A-13（`.debug_abbrev` 一致性，`:12037-12039`/`:12288-12290`）两 linker 均覆盖；A-22 非误拒（见 D-03）；A-03 维持撤回（`parseArgs`/`build-apk`/`build|run`/`test` 四处一致用 `parseCliUInt(...,16384)` + `!=4096&&!=16384`）；A-16 后续在 Dyn writer 无等价缺陷。

---

## 6. 全绿门禁下的覆盖盲区

在**同一份** `HEAD=6e7a148` 上重跑相关常驻套件，全部 `rc=0`：

```
float-checks.sh          PASS: f64 and f32 (... the FP calling convention, refusals)
float-literal-checks.sh  PASS: exponent float literals (...)
frame-size-checks.sh     PASS: frame sizing (default pinned, compact leaf, stack args, CFI, mutation)
project-checks.sh        PASS: project workflow (new, build cache, deps, error paths, mutation)
```

盲区的精确形状：

- `frame-size-checks.sh:130` 的 compact 栈参数用例是 `examples/stack_arg_abi.ast`，紧凑帧远小于 4096，`incomingBaseWords` 的 patch 合法；**没有「紧凑帧 > 4095 + 栈上传入参数」的组合**。
- `float-checks.sh:119` 的 `a_nine` 有九个 f64 参数但**没有局部变量**，错误的 `slot*64` 偏移在参数区内部自洽；**没有「f64 变量 + 足够多其它 slot」的组合**。
- 132 个 `examples/*.ast` 中 `f64`/`f32` 出现 **0** 次；393 行字节基线只钉 3 个写出器的既有例子，对这两个新特性没有任何字节钉。
- `--compact-frames` 未出现在 `aster` 的 usage 帮助里（`src/aster.cpp` 的 usage 块），但 `docs/language-reference.md`、`FEATURE_STATUS.md`、`VERSION_HISTORY.md` 已有记载——文档一致性缺口（P3）。
- `float-checks.sh` 文件头的 Layers 注释仍写「7 层」且称参数/返回/全局初值「被拒绝」，实际已打印 `[2/9]…[9/9]` 且 `[7/9]` 测了 FP 调用约定——注释与实现不同步（P3）。

这与前两轮审计的元结论完全一致，但这次更刺眼：两个 P0 都是**本版本刚加入的特性**，且都不是边界条件，而是「一个数组 + 一个函数参数」「一个 double + 几个局部变量」这种入门级组合。

---

## 7. 建议修复路线（后续版本，一轮一主题）

沿用「一轮一个版本、一个 coherent theme、9 层常驻套件、impl → tests → docs 三批提交」的纪律，建议按风险排序分版本落地；**本轮不改任何编译器行为**。

| 建议版本 | 主题 | 内容 | 必配的门禁 |
| --- | --- | --- | --- |
| v0.23.78-dev | **修两个 P0** | D-01：把 `incomingBaseWords` 的 patch 改用与 `framePair()` 相同的两段式编码（或复用 `emitAddOff`），覆盖 `[4096,8191]` 全区间；D-02：F64 分支 imm12 由 `slot*8` 改为 `slot`，并核对所有 `loadVarT/storeVarT` 调用点 | 一个 9 层常驻套件：≥8 档 `frameBytes` 扫描（含恰好 4096 的静默误编译点）× 有/无栈参数 × compact/normal；f64 slot 0/1/7 与 f32/i32 对照矩阵；C oracle 差分；mutation 6/6；字节基线零漂移 |
| v0.23.79-dev | **链接与项目配置契约** | D-03：`initRefs` 收敛到「真正的全局写集」或排除 `STT_FUNC`/`CALL26`；D-04：`filePage` 采用 `spec.pageSize ?: ps`，或明确拒绝项目文件里的该键；D-05：SysV writer 的 `.tbss` off 对齐与 `tlsAlign` 贯通 | 跨对象初始化器顺序矩阵（函数调用 / 读常量 / 读真全局 / 反序）；项目 `page-size` 4096/16384 的 `readelf -lW` 断言；两个 `.so` writer 的节头/PT_TLS 对照 |
| v0.23.80-dev | **门禁硬化** | G-01：`rc==0` 必须有 `pass_marks>0`；G-02：`GATE_SKIP` 进终判或显式要求 `--allow-skip`；G-08：把 17 个新套件纳入 `CRITICAL` 或按套件自声明 criticality；G-03/G-05：把「no compiler change」层换成真实字节复现并补 `build-pie`/`link-*` 写出器 | 自证式套件的反向 mutation（删断言必须变红）；孤儿与 allowlist 双向校验 |
| 后续 | **静态观察项与前端收紧** | S-01 补 `r.patch` 边界检查；S-09 统一两个 linker 的 remap；S-10 补 `p+4` 校验并用节头手术 + ASAN 复现；S-11 抬升 Dyn writer 的 `.rodata` 起点对齐；D-09 让数字 token 扫描拒绝重复小数点/指数并让 `strtod` 检查 `endptr`；D-06/07/08 与两个 P3 文档项 | 每项按复现难度单独成轮 |

**修 D-01/D-02 时必须注意**：两者都会改变部分既有例子的输出字节（`--compact-frames` 与含 f64 的例子），但 393 行基线不含 f64 例子、也不钉 compact 产物，预期**零漂移**；若出现漂移必须在验证报告里精确说明范围，不得顺手重录基线掩盖。

---

## 8. 本轮交付物与纪律

- `AUDIT-v0.23.77-dev.md`（本文件）
- `tests/audit-evidence/v0.23.77-dev/`：`EVIDENCE.md` + 12 个 `.ast` 探针 + 1 个 C oracle + 2 个复现脚本（共 16 个文件），全部只读、可重放
- 不改 `src/aster.cpp`、不改 `tests/ci.sh`、不改任何既有套件、不重录 `tests/baseline/v0.23.77-dev/example-hashes.txt`
- 审计用编译器由严格编译重建；所有探针在 `qemu-aarch64` 实测；所有 ELF 结论由 `readelf`/`objdump` 读回；所有 C 语义结论由 `aarch64-linux-gnu-gcc` oracle 对照
