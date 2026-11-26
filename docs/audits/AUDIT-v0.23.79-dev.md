# Aster 第五轮全量源码审计报告

**审计对象**：Aster 编译器 v0.23.79-dev，`HEAD = e729840`（"local arrays in the bootstrap subset, one dimension, host-shaped"）
**审计基准**：`src/aster.cpp` 16,145 行、`bootstrap/aster.ast` 7,650 行、`tests/codegen-twin.c`、152 个 `tests/*.sh`（CI 注册 152 个套件）、132 个 `examples/*.ast`、393 行冻结字节基线、3 个 APK gate
**审计方法**：只读源码审阅 + 严格编译探针 + 行为复现（链接 / 项目构建 / ELF 读回）→ 每项配对照组；只保留有复现证据或逐行可推导的项
**状态**：**确认 1 个新的 P0（E-01，bootstrap 本地数组槽位重叠，静态确认、高置信，待 qemu/AArch64 实测）**；D-03 / D-04 / D-05 / D-09 四项已修复（行为实测确认）；D-06 / D-07 / D-08 三项仍开放（行为复现）；G-01 部分修复、G-08 部分修复，其余门禁元发现 G-02…G-07 全部仍成立；S-01 / S-04 / S-09 / S-10 / S-11 / S-12 静态确认仍在；K-01 技术债沿用。**本轮为纯审计轮，不改编译器、不改门禁、不重录字节基线；只新增本报告。**

> **本轮最重要的一句话**：这又是一次「全绿门禁下的审计」，而且新 P0 的形状和上一轮的 D-01/D-02 一模一样——**落在 v0.23.79-dev 刚引入的新代码面**（bootstrap 本地数组），**只需要最普通的合法组合**（「一个本地数组 + 后面再声明一个局部变量」），而**唯一覆盖它的 fixture 只断言了未被破坏的那两个元素**（`a[1]` 与 `b[0]`），被破坏的 `a[2]`/`a[3]` 从未被观测。更刺眼的是：防住这类 bug 的差分门禁（twin 与 bootstrap 字节同一）这次**两侧同时错**——`tests/codegen-twin.c` 里是同一行错误代码，所以字节同一、门禁全绿、程序静默算错。

> **环境限制（本轮如实记录）**：审计在 x86_64 主机上进行，`qemu-aarch64` 与 `aarch64-linux-gnu-gcc` 均不在 PATH，因此**无法执行任何 AArch64 产物、无法跑全量 CI**。宿主编译器本身可在 x86 上构建并输出 AArch64 ELF，所有「行为实测」均为链接 / 项目构建 / Python ELF 读回，不含执行。E-01 的动态确认（在 qemu 或 AArch64 主机上跑 §3.1 的探针）留待有该环境的下一轮；静态证据链已完整到无需执行即可定级，见 §3.1。

---

## 1. 范围、方法与纪律

### 1.1 审计路线

| 路 | 主题 |
| --- | --- |
| 一 | 上轮缺陷的修复验证：D-03 / D-04 / D-05 / D-09（行为复现，对照组齐全） |
| 二 | 本轮新代码面：bootstrap 本地数组（`bootstrap/aster.ast` v0.23.79-dev 新增）与 `codegen-twin.c` 的同步改动 |
| 三 | 上轮遗留的确认缺陷 D-06 / D-07 / D-08（行为复现） |
| 四 | 门禁有效性：G-01…G-08 在 v0.23.79-dev 的 `tests/ci.sh` 中的当前状态（受控实验复测 G-01/G-02） |
| 五 | 静态观察项 S-01 / S-04 / S-09 / S-10 / S-11 / S-12 与 K-01 的当前行号复核 |

### 1.2 验证纪律

- **推断不算缺陷**。每个「确认」条目都有编译探针、对照组或逐行可推导的地址算术；做不到的降为 §5 的「静态确认」。
- **严格编译**。审计对象用 `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror` 重建到 `/tmp/aster_audit_v79` 后使用，原工作树中的产物不动；`BUILD_EXIT=0`，banner `Aster bootstrap compiler v0.23.79-dev`。
- **不污染工作树**。所有探针、项目、假套件都在 `/tmp`（`/tmp/aster_audit_probes/`、`/tmp/aster_gate/`）；交付物只新增本报告。
- **历史被压缩**。本 checkout 的 git 历史只有 1 个提交，无法按版本 diff；所有「已修复 / 仍开放」的判断均以当前源码行号 + 行为实测为准，不依赖提交历史。

### 1.3 分级标准

沿用 `AUDIT-v0.23.77-dev.md` §1.3：P0 = 合法程序静默产出错误结果或崩溃且影响常见合法组合；P1 = 语义/契约错误（含拒绝合法程序）；P2 = 一致性或诊断层面；门禁 = 回归能溜过门禁；观察 = 静态确认、未动态复现。

---

## 2. 结论总表

| # | 路 | 条目 | verdict | 级别 |
| --- | --- | --- | --- | --- |
| **E-01** | 二 | bootstrap 本地数组只占 1 个槽位，后续局部变量与数组尾部元素同址 | **确认（静态，高置信；待动态）** | **P0** |
| E-02 | 二 | bootstrap 本地数组无长度界（ host 限 1..1000）且接受非常量初始化器 | 静态确认 | 观察 |
| D-03 | 一 | 跨对象 `extern fn` 调用被 `checkInitOrder` 误拒 | **已修复（行为实测）** | — |
| D-04 | 一 | `aster.proj` 的 `page-size` 被解析后丢弃 | **已修复（行为实测）** | — |
| D-05 | 一 | SysV `.so` writer 的 `.tbss` `sh_offset ≠ sh_addr`，PT_TLS `p_align` 硬编码 16 | **已修复（行为实测）** | — |
| D-09 | 一 | 词法器把 `1e2e3` / `1.5.2` 静默截断成合法 token | **已修复（行为实测）** | — |
| D-06 | 三 | `aster.proj` 重复源行 → 缓存伪装成「复用」，链接报晦涩的重复符号 | **仍开放（行为复现）** | P2 |
| D-07 | 三 | 含空格路径的缓存 meta 按首个空格切分，该对象永不命中缓存 | **仍开放（行为复现）** | 观察 |
| D-08 | 三 | `execAarch64Image` 把 qemu 缺失的 ENOENT 覆盖回 ENOEXEC，掩盖真正原因 | **仍开放（源码确认）** | 观察 |
| G-01 | 四 | 零断言 `exit 0` 被判 `PASS` | **部分修复**：CRITICAL 套件无断言现判 FAIL；非 CRITICAL 仍判 `PASS (no assertions!)`，仅计入 `NO_EVIDENCE` 报告，终判仍绿 | 门禁 |
| G-02 | 四 | `CI_SKIP_APK_GATE=1` 三 gate 全跳而终判仍绿 | **仍开放（受控实验确认）** | 门禁 |
| G-03 | 四 | 8 个套件的「no compiler change」层只数 393 行，无字节 oracle | 静态确认 | 门禁 |
| G-04 | 四 | 覆盖/变异棘轮是静态 grep + 硬编码 floor，`|| :` 吞错误 | 静态确认 | 门禁 |
| G-05 | 四 | 字节基线只钉 3 个写出器、豁免 1 个 example、58 行 `FAILED` 占位 | 静态确认 | 门禁 |
| G-06 | 四 | 部分套件变异用整文件 sha256 差分而非不变量 | 静态确认 | 门禁 |
| G-07 | 四 | `CI_JOBS` 分组靠字面 `/tmp/`，`grep -qv TMPD` 恒真退化 | 静态确认 | 门禁 |
| G-08 | 四 | 17 个 v0.23.77-dev 新套件全部不在 `CRITICAL` | **部分修复**：`CRITICAL` 25 → 27（新增 `frame-slot-contract`、`link-project-contract`）；其余 125/152 个套件仍不在列 | 门禁 |
| S-01 | 五 | `resolveRelocations` 对 `r.patch` 仍无边界检查 | 静态确认，未动态复现 | 观察 |
| S-09 | 五 | `initRefs` 未做 `remapPrivateStringSymbol`，A-25 私有字符串依赖漏检 | 静态确认，中置信 | 观察 |
| S-10 | 五 | `dwarfCuStmtListOffset` 命中 `DW_AT_stmt_list` 时缺 `p+4` 边界检查 | 静态确认，中置信 | 观察 |
| S-11 | 五 | `writeSharedObjectDyn` 的 `.rodata` 仅按 `pageSize` 对齐却校验 `spec.rodataAlign` | 静态确认，低-中置信 | 观察 |
| S-12 | 五 | APK v1 覆盖检查跳过整个 `META-INF/`，非签名文件可无摘要搭车 | 静态确认，低置信 | 观察 |
| S-04 | 五 | `build-apk` 预编译 `.so` 与 `--page-size` 组合仍无 ELF `p_align` 校验 | 静态确认 | 观察 |
| K-01 | — | `typeOf` / `exprType` 语义分歧、TypedIR 豁免名单 | 已知治本项，沿用 | 技术债 |

---

## 3. 新确认的缺陷

### E-01（P0）bootstrap 本地数组只占一个槽位，后续局部变量与数组尾部同址

**位置**：`bootstrap/aster.ast:5238-5251`（`cg_add_local`）、`:6580-6592`（`S_Let` 数组分支）；**同一错误同步存在于** `tests/codegen-twin.c:2868-2874`（`:2874`）、`:3648-3658`（数组分支）。

```aster
// bootstrap/aster.ast:5249 — cnt 参数被收下（:5247 存入 cg_loc_cnt），
// 但推进下一槽位时完全不用它：
cg_next_slot = cg_next_slot + ty_slots(ty);   // v0.23.77-dev: a struct needs several
// ty_slots (:2303-2306)：struct 按 (size+7)/8，否则一律返回 1。
// 对 `let a: i32[4]`，ty 是元素类型 TY_I32，ty_slots = 1，与 cnt=4 无关。
```

**机理**：宿主编译器为本地数组保留 `ceil(N*sizeof(T)/8)` 个槽位（`src/aster.cpp:6761-6796`，并有 `1000` 元素上限与越限拒绝 `:6785`）。bootstrap 的 `cg_add_local` 只按**元素类型**的槽数推进（标量恒为 1），数组的 `cnt` 只记在 `cg_loc_cnt` 里供寻址用，不参与分配。于是：

- 数组初始化（`:6580-6592`）按 `slot*8 + k2*w`（`k2 < cnt`）逐元素写；
- 数组下标读/写（`gen_index` `:5776`、`gen_index_addr` `:6480`、`gen_var` `:6342`）按同一公式寻址；
- 但**下一个声明的局部变量**拿到的槽位是 `slot+1`，正好落在数组第 2 个槽位上。

**逐字节算术（以仓库自带的 fixture 为例）**：`tests/codegen-fixtures/local_array.ast`

```aster
fn main() -> i32 {
    let a: i32[4] = 5;
    a[1] = 7;
    let b: u8[8] = 0;
    b[0] = 3;
    if (a[1] == 7 && b[0] == 3) { return 1; }
    return 0;
}
```

局部槽位从 32 起（`cg_reset_frame` `:5217`）。`a` 得槽 32，`cg_next_slot` 只进到 33；`b` 得槽 33。

| 写操作 | 地址（相对 SP） | 覆盖 |
| --- | --- | --- |
| `a` 初始化广播 5 | 256、260、264、268（`a[0..3]`） | — |
| `b` 初始化广播 0 | 264…271（`b[0..7]`，每元 1 字节） | `a[2]`（264…267）与 `a[3]`（268…271）被清零 |
| `a[1] = 7` | 260 | 未被破坏 |
| `b[0] = 3` | 264 | 未被破坏 |

`a[2]` 在 bootstrap 产物里变成 `3`（264 字节被 `b[0]=3` 改写，其余三字节为 0），宿主产物里是 `5`。**fixture 的断言恰好只测了未被破坏的两个量**（`a[1]==7 && b[0]==3`），所以它在 bootstrap 与宿主下都返回 1——测试通过，程序算错。这是上一轮 D-02 的 f64 探针漏报的同一形状：被破坏的元素从未被观测。

**为什么门禁没抓住**：`tests/codegen-checks.sh` [5/6] 要求 twin 与 bootstrap 对同一语料**字节同一**。但 twin 是 bootstrap 编译器的 C 语言复刻，`:2874` 是**同一行错误代码**（`cg_next_slot += ty_slots(ty);`），两侧发出同样的重叠槽位，字节同一、门禁全绿。`bootstrap-loop-checks.sh` [6/7] 只把 `return_42` 与 `globals_and_write` 两个 fixture 跑成产品，`local_array.ast` 从未被执行过。宿主侧的 `local-array-checks.sh` [8/8] 只测宿主编译器，不碰 bootstrap。

**影响范围**：只影响**自举编译器**（`bootaster`）编译出的程序；宿主编译器 `src/aster.cpp` 的本地数组分配正确，不受影响。触发条件极普通：函数内一个本地数组后面再声明任何局部变量（且数组跨过 8 字节边界，即 `cnt*sizeof(T) > 8`；`i32[2]` 恰好占满一槽，不触发；`i32[3]` 及以上、`i64[2]`、`u8[9]` 及以上均触发）。数组若为函数内最后一个局部变量，则尾部写操作落在其后未被分配的槽位上，不破坏已声明变量，但仍越出保留区（见 E-02 的长度界问题）。

**待动态确认（留待有 qemu / AArch64 主机的环境）**：用自举编译器编译以下探针并运行，预期 bootstrap 返回 `3`、宿主返回 `5`：

```aster
fn main() -> i32 {
    let a: i32[4] = 5;
    let b: u8[8] = 0;
    b[0] = 3;
    return a[2];
}
```

**修复方向**：`cg_add_local` 按数组实际占用推进——`cg_next_slot += (cnt * ty_width(ty) + 7) / 8`（标量 `cnt=1` 时退化为现有行为；struct 分支保持 `ty_slots`），**bootstrap 与 twin 两处同步改**；在 `tests/codegen-fixtures/local_array.ast` 或新增 fixture 中断言 `a[2]`、`a[3]` 与一个后声明局部变量的值（即把本轮探针收编为常驻用例）；`PARSER-SPEC.md` B11（见 E-02）同步更新。

### E-02（观察）bootstrap 本地数组无长度界，且接受非常量初始化器

- **长度无界**。宿主在解析层拒绝 `0` 与 `>1000`（`src/aster.cpp:1722`、`:2390-2391`），并在 codegen 层以帧上限拒绝超大数组（`:6785`）。bootstrap 解析层（`bootstrap/aster.ast:2767-2800`）只检查「是数字、后跟 `]`、一维、有 `=`」，不检查 `cnt` 的范围：`i32[0]` 会落到标量路径，`i32[2000]` 会按 `slot*8 + k*4` 写到 `SP+256…SP+8256`，越过 8192 字节帧、写进调用者区域。`cg_add_local` 的 `cg_next_slot >= 532` 上限对此无效，因为数组根本不推进 `cg_next_slot`（即 E-01 的同一行）。
- **非常量初始化器被接受**。解析层注释称「initialized by a constant that fills every element」（`:2767-2769`），但代码只 `parse_expr()`，不做常量检查；codegen（`:6580-6592`）把表达式求值一次再广播到每个元素。宿主拒绝非常量本地数组初始化器（`../FEATURE_STATUS.md:256`）。bootstrap 接受 `let a: i32[4] = f();` 并静默广播一次求值结果，与宿主语义分歧。
- **文档不同步**。`bootstrap/PARSER-SPEC.md:838` 的 B11 仍写「local arrays are not in the bootstrap subset」，而解析器自 v0.23.79-dev 起已接受一维本地数组；`SEMANTIC-SPEC.md:185` 的 S22（禁止返回本地数组）倒是已存在。B11 应改为已支持的形状与限制。

---

## 4. 上轮缺陷的修复验证（行为实测）

### D-03（P1）—— 已修复

源码：`src/aster.cpp:12000-12015` 与 `:12260-12265` 的 `initRefs` 收集现排除函数符号（`ownerOf` 只收 `(s.info&0xfu)!=2` 的数据符号）并跳过 `CALL26`（`r.type!=283`）；`checkInitOrder`（`:11947-11966`）本身未变。

实测（`/tmp/aster_audit_v79`，`/tmp/aster_audit_probes/d03/`，沿用 `tests/audit-evidence/v0.23.77-dev/D03_*.ast` 的形状，补 `extern fn` 声明与 `main`）：

| 命令 | 结果 |
| --- | --- |
| `link-obj a.o b.o`（a 的初始化器只调用 b 的 `helper`） | exit 0 |
| `link-obj b.o a.o`（反序） | exit 0 |
| `link-so a_pic.o b_pic.o` / 反序 | exit 0 |
| 对照：a 的初始化器读 b 的数据全局 `g`，`link-obj a_data.o b_data.o` | 仍拒绝：`its run-time global initializer reads 'g' … must be listed before`（A-21 保持） |

注：`../validations/VALIDATION-v0.23.79-dev.md` 称过滤器覆盖 "CALL26/JUMP26"，源码里类型过滤只有 `r.type!=283`（CALL26），无 `282`（JUMP26）的字面出现；但 JUMP26 的目标是函数符号，而 `ownerOf` 已排除 `STT_FUNC`，故等效安全。这是验证报告措辞上的不精确，不是缺陷。

### D-04（P1）—— 已修复

源码：`src/aster.cpp:15483` 与 `:15761` 的 `filePage = cliPageSet ? ps : (spec.pageSize ? spec.pageSize : ps)`。

实测：`aster new` 脚手架项目在 `aster.proj` 中加 `page-size 16384` 后构建，Python ELF 读回 `PT_LOAD p_align = 0x4000`；再以 `--page-size 4096` 构建，读回 `0x1000`（CLI 优先成立）。

### D-05（P2）—— 已修复

源码：`src/aster.cpp:9604-9605` 由每个 TLS 全局的 `align` 推导 `L.tlsAlign`；SysV writer `:11234` 的 `.tbss` 设 `off == addr`，`:11256` 的 `PT_TLS p_align = tlsAlign`。

实测（`tls let a: i32 @align(64) = 10; tls let c: i32 @align(64) = 0;`）：`build-so` 产物 `PT_TLS p_align = 0x40`，`.tdata`/`.tbss` 的 `sh_addralign = 0x40` 且 `.tbss off == addr == 0x3040`。静态 `build-elf` 产物的 `.tdata off != addr` 是固定基址 `0x400000` 下的正常现象，不属 D-05。

### D-09（P2）—— 已修复

实测：`let x: f64 = 1e2e3;` 与 `let x: f64 = 1.5.2;` 均被拒绝（exit 1）。注：报错是解析层措辞（"expected ';'" / "expected field name after '.'"），而非词法层点名 malformed literal；拒绝本身成立，诊断可读性可另行打磨。

---

## 5. 仍开放的确认缺陷（行为复现）

### D-06（P2）—— `aster.proj` 重复源行仍无去重

源码：`parseProjectFile`（`src/aster.cpp:15149-15206`）对无法识别的行一律 `spec.sources.push_back(l)`，无去重；`aster add`（`:15410` 附近）会正确拒绝重复，但手写 `aster.proj` 不受保护。

实测：脚手架项目 `aster.proj` 追加一行重复的 `src/main.ast` 后 `aster build`，exit 1：`aster: error: duplicate global symbol '_start' across input objects`。用户看到的是链接器内部符号名，而非「`src/main.ast` 在 aster.proj 里出现了两次」。修复应在解析层去重并报出源文件名，或至少把重复符号错误映射回重复的源行。

### D-07（观察）—— 含空格的源路径永不命中缓存

源码：两处缓存 meta 解析（`src/aster.cpp:15216`、`:15789`）对 `src <path> <hash>` 行用 `rest.find(' ')` 取**首个**空格切分；路径含空格时 `q != sp`，`ok=false`，永不复用。注意 `dep` 行格式是 `dep <hash> <path>`，首空格切分对其正确，只有 `src` 行是反的。

实测：源文件名为 `src/my file.ast` 的项目连续构建三次，均为 `(1 compiled, 1 reused)`——带空格的那个对象每次都重编；对照项目（无空格）第二次构建即 `(0 compiled, 2 reused)`。性能问题，不构成误编译。

### D-08（观察）—— `execAarch64Image` 仍把 qemu 缺失掩盖成格式错误

源码：`src/aster.cpp:134-153`。`execv` 得 ENOEXEC 后尝试 `execvp("qemu-aarch64")`；qemu 不存在时 `execvp` 失败置 `errno=ENOENT`，函数末尾 `errno=execErrno` 又把它盖回 ENOEXEC，调用方 `perror` 只报 `Exec format error`。注释称「with errno set to the original exec error」——原错误确被保留，但 qemu 缺失这一**真正原因**被丢弃。修复：`execvp` 失败且 `errno==ENOENT` 时保留 ENOENT（或直接提示缺少 qemu）。

---

## 6. 门禁有效性元发现（v0.23.79-dev 当前状态）

### G-01 —— 部分修复（受控实验复测）

`tests/ci.sh:394-408` 新增分支：`pass_marks==0` 时 CRITICAL 套件判 FAIL，非 CRITICAL 判 `PASS (no assertions!)` 并计入 `NO_EVIDENCE`。但终判（`:607-614`）只看 `FAIL`/`GATE_FAIL`，`NO_EVIDENCE` 不影响 exit code。

复测（`CI_SUITE_DIR` 指向 `/tmp/aster_gate/suites` 的假套件，`CI_ALLOW_MISSING=1 CI_SKIP_APK_GATE=1`，因本机无 qemu）：

```text
zero-assert.sh   PASS (no assertions!)
silent-skip.sh   SKIP (no oracle on this host)
CI SUMMARY: 1 passed, 1 skipped, 0 failed (of 2 suites)
APK GATES : 0 passed, 1 skipped, 0 failed
NO EVIDENCE: 1 suite(s) exited 0 without printing an assertion
CI_EXIT=0
```

结论：零断言的非 CRITICAL 套件**仍然绿**，只是现在会被点名。按 §7 的原建议，`rc==0` 必须有 `pass_marks>0` 才算 PASS（或至少让 `NO_EVIDENCE>0` 使终判失败）。

### G-02 —— 仍开放（同一实验确认）

`CI_SKIP_APK_GATE=1` 时 `GATE_SKIP` 只打印（`ci.sh:574`），不进终判（`:607`）；上实验三 gate 全跳，`CI_EXIT=0`。`ci-protocol-checks.sh:296` 自身仍以该变量调 `ci.sh`。

### G-03…G-07 —— 静态确认，全部仍成立

| 编号 | 当前位置 | 现状 |
| --- | --- | --- |
| G-03 | `tests/difftest-checks.sh:111-116` | 「no compiler change」层仍只断言 `rows == 393`，不比较任何哈希字节 |
| G-04 | `tests/coverage-checks.sh:53-63,116`、`tests/mutation-score-checks.sh:22-24,56` | `FLOOR=80` 与变异 census 仍是静态 grep + 硬编码数；`coverage-checks.sh:53-63` 的每条构建调用仍 `>/dev/null 2>&1 \|\| :` |
| G-05 | `tests/lib/baseline.sh`、`tests/baseline/v0.23.79-dev/example-hashes.txt` | 393 行仍只钉 3 个写出器（`build-elf` / `build-obj --pic` / `build-so`），无 `build-pie`/`link-*` 行；`address_of_abi` 仍被豁免；58 行仍是 `FAILED` 占位（53 行 `build-elf` + 5 行 `build-so`） |
| G-06 | `tests/union-checks.sh:533-541` 等 | 「变异被注意到」仍是整文件 sha256 差分，不验证变化落在被变异规则上 |
| G-07 | `tests/ci.sh:512-513` | `grep -qv 'TMPD'` 仍为「存在一行不含 TMPD」，判定仍退化 |

### G-08 —— 部分修复

`CRITICAL` 由 25 个增至 27 个（`tests/ci.sh:86`：新增 `frame-slot-contract-checks.sh`、`link-project-contract-checks.sh`），`../validations/VALIDATION-v0.23.79-dev.md` §9 亦承认只关了「新套件在 CRITICAL」这一项。但 152 个套件中仍有 **125 个不在 `CRITICAL`**，包括 `coverage-checks.sh`、`mutation-score-checks.sh`、`ci-protocol-checks.sh`、`difftest-checks.sh`、`bootstrap-loop-checks.sh`、`wide-int-literal-checks.sh`——即上一轮点名的 C 差分 / coverage 静默跳过路径仍可静默 SKIP。`wide-int-literal-checks.sh:432-437` 在 HOSTCC 非 AArch64 时只 `echo SKIP` 而不 exit 的写法未复核改动。

---

## 7. 静态确认 / 待动态观察（行号已更新至 v0.23.79-dev）

| 编号 | 位置 | 内容 | 状态 |
| --- | --- | --- | --- |
| S-01 | `src/aster.cpp:10779`、`:10801-10806`、`:10830` | `resolveRelocations` 在 `text[(size_t)r.patch+i]` 读写前仍无边界检查；`r.patch` 来自 `parseObject` 的 `need=4/8` 兜底只覆盖 link 路径，`build-so` 直接 codegen 的 pending 未经该路径 | 第二轮遗留，仍未修，未动态复现 |
| S-09 | `src/aster.cpp:12015`、`:12265` vs `:12000`、`:12250` | `ownerOf` 的键经 `remapPrivateStringSymbol`，`initRefs` 只剥 `__aster_gat_` 前缀未 remap；A-25 私有字符串依赖在初始化器顺序检查中仍漏检；两 linker 的该段代码已同步为同一写法，漏检亦同步 | 中置信，未动态复现 |
| S-10 | `src/aster.cpp:10419-10471` | `dwarfCuStmtListOffset` 命中 `DW_AT_stmt_list`（`af.first==0x10`）时直接 `out=p; return true;`，未校验 `p+4<=info.size()`；其后的 `p+=size; if(p>info.size()) return false;` 被该 return 绕过 | 中置信，需 ELF 节头手术 + ASAN |
| S-11 | `src/aster.cpp:11529`、`:11865-11868` | Dyn writer 的 `rodataVaddr` 只 `alignUp(...,pageSize)`，却在 `spec.rodataAlign>4096` 时直接 throw 拒链；注释「every request is <= 4096」未受输入约束 | 低-中置信 |
| S-12 | `src/aster.cpp:14486` | APK v1 覆盖检查跳过整个 `META-INF/`，可追加未签名、未覆盖的 `META-INF/*`；不影响已签名 payload 摘要，属搭车而非绕过验签 | 低置信，威胁模型依赖 |
| S-04 | `src/aster.cpp:14759`、`buildApk` 的 `pageSize` 参数 | 预编译 `.so` 与 `--page-size` 组合仍不校验/重排 ELF `p_align`（`buildApk` 收 `pageSize` 但未见对输入 `.so` 的 `p_align` 校验） | 第二轮遗留 |
| K-01 | 全局 | `typeOf` / `exprType` 语义分歧、TypedIR 豁免名单 | 已知治本项，沿用 |

**复核为无误的项**：D-01/D-02 的修复策略（帧 >4095 回退 8192、f64 imm12 改 `slot`）在当前源码中保持；D-03 的数据读对照（A-21）仍拒绝；`aster add` 的去重提示与 `parseProjectFile` 的重复行问题是同一功能的两面（见 D-06）。

---

## 8. 覆盖盲区的精确形状（本轮新增）

- `tests/codegen-fixtures/local_array.ast` 是 bootstrap 本地数组**唯一**的执行形状探针，且只观测 `a[1]` 与 `b[0]`——恰好是 E-01 不破坏的两个量。`a[2]`/`a[3]` 与「数组后声明的局部变量」从未被观测。
- `tests/codegen-checks.sh` [5/6] 的 twin-vs-bootstrap 字节同一，对「两侧共享同一错误」没有防御：本轮 E-01 的两侧就是同一行代码。宿主侧 `local-array-checks.sh` [8/8] 的正确实现（`src/aster.cpp:6761-6796`）没有对应的 bootstrap 侧断言。
- 393 行字节基线不含任何 bootstrap 产物（它钉的是宿主编译器对 `examples/*.ast` 的输出），对 E-01 没有钉子。

---

## 9. 建议修复路线（后续版本，一轮一主题）

沿用「一轮一个版本、一个 coherent theme、9 层常驻套件、impl → tests → docs 三批提交」的纪律；**本轮不改任何编译器行为**。

| 建议版本 | 主题 | 内容 | 必配的门禁 |
| --- | --- | --- | --- |
| v0.23.80-dev | **修 P0：bootstrap 本地数组槽位** | E-01：`cg_add_local` 按 `ceil(cnt*esz/8)` 推进（bootstrap 与 twin 同步）；E-02：长度限 1..1000、拒绝非常量初始化器；更新 `PARSER-SPEC.md` B11 | 新 fixture 断言 `a[2]`/`a[3]` 与数组后局部变量的值（即 §3.1 探针收编）；twin 与 bootstrap 各自对宿主做字节/行为差分——不能只比 twin 与 bootstrap 彼此；mutation：把 `cnt` 推进改回 `ty_slots(ty)` 必须变红 |
| v0.23.81-dev | **门禁硬化**（沿用上轮 §7 排队） | G-01：`rc==0` 必须有 `pass_marks>0`（或 `NO_EVIDENCE>0` 使终判失败）；G-02：`GATE_SKIP` 进终判或显式要求 `--allow-skip`；G-08：把剩余关键套件（coverage / mutation / ci-protocol / difftest / bootstrap-loop）纳入 `CRITICAL` 或按套件自声明 criticality；G-03/G-05：把「no compiler change」层换成真实字节复现并补 `build-pie`/`link-*` 写出器 | 自证式套件的反向 mutation（删断言必须变红） |
| 后续 | **项目配置与静态观察项** | D-06 解析层去重并报源文件名；D-07 `src` 行按**末个**空格切分（或改写 meta 格式）；D-08 保留 qemu 缺失的 ENOENT；S-01 补 `r.patch` 边界检查；S-09 统一两个 linker 的 remap；S-10 补 `p+4` 校验并用节头手术 + ASAN 复现；S-11 抬升 Dyn writer 的 `.rodata` 起点对齐；S-12 / S-04 按威胁模型定级 | 每项按复现难度单独成轮 |

**修 E-01 时必须注意**：它会改变 bootstrap 产物中含本地数组的程序的输出字节，但 393 行基线不含 bootstrap 产物、也不钉本地数组 fixture 的执行结果，预期**零漂移**；若出现漂移必须在验证报告里精确说明范围，不得顺手重录基线掩盖。twin 与 bootstrap 必须**分别**与宿主行为对照，不能只互相比。

---

## 10. 本轮交付物与纪律

- 本报告：`AUDIT-v0.23.79-dev.md`（新增，唯一写入工作树的文件）。
- 探针与假套件均在 `/tmp`（`/tmp/aster_audit_v79` 为严格构建的编译器；`/tmp/aster_audit_probes/` 为 D-03/D-04/D-05/D-06/D-07/D-09 探针；`/tmp/aster_gate/` 为 G-01/G-02 受控实验），工作树除本报告外干净。
- 未跑全量 CI（本机无 `qemu-aarch64` 与 `aarch64-linux-gnu-gcc`）；`../validations/VALIDATION-v0.23.79-dev.md` §7a 的 `152 passed, 0 skipped, 0 failed` 是上游在其 8 GiB runner 上的结果，本轮未复核、亦未推翻。
- E-01 的动态确认是本轮唯一未闭合的证据链：需在 qemu 或 AArch64 主机上跑 §3.1 的探针（bootstrap 返回 `3`、宿主返回 `5` 即确认；若两者同为 `5`，则本报告的 E-01 定级作废，以实测为准）。
