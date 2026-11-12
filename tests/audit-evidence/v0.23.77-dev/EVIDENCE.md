# 第四轮全量源码审计 · 只读证据（v0.23.77-dev）

**审计对象**：`HEAD = 6e7a148369ee88aa447463dff550ac38927151d1`，`ASTER_VERSION_STRING = "0.23.77-dev"`，`src/aster.cpp` 16,094 行。
**基线门禁**：150 passed / 0 skipped / 0 failed，APK gates 3 passed，`CI_EXIT=0`；`tests/baseline/v0.23.77-dev/example-hashes.txt` 393 行；工作树干净，`HEAD == origin/main`。
**纪律**：本目录只含只读证据（探针源码、C oracle、复现脚本与记录）。本轮为纯审计轮，**不改编译器、不改门禁、不重录基线**。
**工具链**：审计用编译器由 `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o /tmp/aster_audit` 严格重建；产物在 `qemu-aarch64 -L /usr/aarch64-linux-gnu` 下运行；C oracle 用 `aarch64-linux-gnu-gcc -O2 -fwrapv -static`；指令用 `aarch64-linux-gnu-objdump -d` 读回；ELF 用 `aarch64-linux-gnu-readelf -SW/-lW/-rW/-sW` 读回。
**低 8 位陷阱**：凡「读回值是否正确」的判定一律用 `if (x == expected) { return 0; } return 1;` 的条件返回。第一轮 `fcvtzs` 探针就因为 32 位写只扰动了 double 的尾数末位而漏报，改用逐位相等后才捕获。

---

## D-01（P0）`--compact-frames` 的栈参数基址立即数溢出

**源码**：`src/aster.cpp:7358-7359`

```cpp
if(compact&&frameBytes!=8192u)
    for(size_t at:incomingBaseWords)code[at]=0x910003f0u|(frameBytes<<10);
```

`0x910003f0` 是 `ADD X16, SP, #0`，imm12 占 bit[21:10]，最大 4095。当 `frameBytes > 4095` 时，`frameBytes<<10` 把 bit 22（AArch64 ADD immediate 的 `shift` 位）一并置起，指令变成 `ADD X16, SP, #imm12, LSL #12`，实际加的是 `(frameBytes & 0xfff) << 12`。序言的 `framePair()`（7340–7346）正确处理了 >4095 的情况（拆成 SUB/ADD 两条），此处却没有。

| 探针 / pad | frameBytes | 发射的 `ADD X16, SP` | 期望 | 实测 | 判定 |
| --- | --- | --- | --- | --- | --- |
| `D01_ctl_small_frame.ast` / 100 | 0x480 | `#0x480` | 8 | 8 | 正确 |
| pad 465 | 4080 | `#0xff0` | 8 | 8 | 正确 |
| **`D01_compact_stack_arg.ast` / 467** | **4096** | **`#0x0, lsl #12`（= SP+0）** | **8** | **0** | **静默误编译** |
| pad 469 | 4112 | `#0x10, lsl #12`（= 65536） | 8 | SIGSEGV (-11 / rc 139) | 崩溃 |
| pad 480 | 4192 | `#0x60, lsl #12`（= 393216） | 8 | SIGSEGV | 崩溃 |
| 同一探针，不带 `--compact-frames` | 8192 | `#0x2, lsl #12` | 8 | 8 | 正确 |
| `D01_ctl_no_stack_arg.ast`（大帧、无栈参数） | 8192 | 无 `incomingBaseWords` | 7 | 7 | 正确 |

`frameBytes == 4096` 时 X16 指向本帧开头，于是 `LDR W16,[X16]` 读到第一个参数 `a=1` 而不是第 9 个栈参数 `j=9`，`j - a` 变成 `1 - 1 = 0`——不崩溃，静默给出错误结果。

反汇编（`D01`，pad=480，compact）：

```
4010b8: d14007ff  sub  sp, sp, #0x1, lsl #12     ; 4096
4010bc: d10183ff  sub  sp, sp, #0x60             ;   96  => frame 4192
4010c0: f9082ffe  str  x30, [sp, #4184]          ; raOff = 4192-8，正确
4010e4: 914183f0  add  x16, sp, #0x60, lsl #12   ; 应为 #4192，实为 393216
4010e8: b9400210  ldr  w16, [x16]                ; -> SIGSEGV
```

对照组（`D01`，normal）：`add x16, sp, #0x2, lsl #12` = 8192，正确。

---

## D-02（P0）f64 帧槽的立即数被放大 8 倍

**源码**：`src/aster.cpp:4005-4021`

```cpp
if(t==Ty::F32)return 0xbd4003e0u|(uint32_t(slot*2)<<10)|uint32_t(reg);  // 正确：STR S 缩放 4，slot*2 -> byte slot*8
if(t==Ty::F64)return 0xfd4003e0u|(uint32_t(slot*8)<<10)|uint32_t(reg);  // 错误：STR D 缩放 8，slot*8 -> byte slot*64
```

`storeVarT` / `loadVarT` 的 F64 分支把「字节偏移」当成了 imm12，而 LDR/STR D 本身按 8 缩放；正确值应为 `slot`（对比 `loadVar64` 用 `slot`）。同一个文件里 `loadStackT`/`storeStackT`（4572/4580）、`loadAtT`/`storeAtT`（5705/5713）、`loadGlobalT`（4554）、栈上传入 FP 参数（7256）都用 `off/8`，是**唯一一处**写错。F32 分支用 `off/4` 的等价形式 `slot*2`，正确。

| 探针 | 期望 | Aster | C oracle | 判定 |
| --- | --- | --- | --- | --- |
| `D02_f64_slot1.ast`（x 在 slot 1，p7 在 slot 8） | 0 | **1** | 0 | **误编译** |
| 同上但 7 个 `i64` 变量（8 字节覆写） | 0 | **1** | 0 | **误编译** |
| `D02_ctl_slot0.ast`（x 在 slot 0，`0*64 == 0`） | 0 | 0 | — | 正确 |
| `D02_ctl_f32_slot1.ast`（同形状，f32） | 0 | 0 | 0 | 正确 |
| `D02_nine_f64_params.ast`（9 个 f64 参数 + 局部数组） | 8 | **255**（=-1） | 8 | **误编译** |
| 同形状但 9 个 `i32` 参数 + 局部数组 | 8 | 8 | — | 正确 |

反汇编（`D02_f64_slot1.ast`，x 应在 `[sp,#8]`）：

```
401020: fd0023e0  str  d0, [sp, #64]      ; x = 2.5 -> slot 1 被写成 byte 64
401058: b90043e0  str  w0, [sp, #64]      ; p7 = 0  -> slot 8，覆写 x 的低 32 位
401060: b90043e0  str  w0, [sp, #64]      ; p7 = 99 -> 再次覆写
401064: fd4023e0  ldr  d0, [sp, #64]      ; x 读回被污染的位型
```

`D02_nine_f64_params.ast` 的 `f()`：参数按 slot 0,8,16,…,64 存到 `[sp,#0],[sp,#64],…,[sp,#512]`，而 `let pad: i64[480] = 0;` 从 `[sp,#72]` 起逐 8 字节清零，把 c..j 全部抹成 0.0；`j - a` 于是 `0.0 - 1.0 = -1.0`，`i32()` 返回 -1 → 退出码 255。

注意 `tests/float-checks.sh:119` 的 `a_nine` 是同样的九个 f64 参数但**没有局部变量**，参数区自洽，所以它 PASS；这正是缺陷能溜过 150 套件全绿门禁的原因。

---

## D-03（P1）`checkInitOrder` 把「调用函数」误判成「读取后面对象的全局」

**源码**：`src/aster.cpp:11909-11928`、`11968-11976`

`initRefs[i]` 收集 `__aster_init` 范围内**所有**重定位符号（含 `R_AARCH64_CALL26` 到别的函数、函数地址、静态常量），`ownerOf` 含**所有**定义符号（含 `STT_FUNC`），`initNameByInput` 只记「对象带初始化器」。判据是「引用了 j 定义的任意符号且 j 也有初始化器」，缺「写集」信息。

| 命令 | 期望 | 实测 |
| --- | --- | --- |
| `link-so a.o b.o -o ab.so` | 成功 | `error: a.o: its run-time global initializer reads 'helper', which b.o sets in its own initializer; ... must be listed before a.o` |
| `link-so b.o a.o -o ba.so`（反序） | 成功 | 成功 |
| `link-so a.o b2.o -o ab2.so`（B 无运行期初始化器） | 成功 | 成功 |

`readelf -rW a.o`：`R_AARCH64_CALL26 helper + 0`，落在 `__aster_init`（size 48）内；`readelf -sW a.o` 显示 `helper` 是 `UND FUNC`。A 只是**调用一个函数**，不读 B 的任何全局状态，两种链接顺序语义等价，却被顺序依赖地拒绝。

---

## D-04（P1）`aster.proj` 的 `page-size` 是死设置

**源码**：`spec.pageSize` 全文件只有两处：`:15140`（解析赋值）与 `:15709`（范围校验）；`:15710` 无条件 `const uint64_t filePage = ps;`（`ps` 是 CLI 值，默认 4096）。

受控实验（`D04_project_page_size.sh`）：

```
aster new --apk p16 ; printf 'page-size 16384\n' >> p16/aster.proj ; cd p16 ; aster build
  -> rc=0，无任何告警
  -> build/.cache/*.meta:  flags --p|4096
  -> readelf -lW build/.cache/p16.so:  LOAD ... Align 0x1000
对照：同一项目 aster build --no-cache --page-size 16384
  -> LOAD ... Align 0x4000
```

配置被解析、被校验、被静默丢弃；产物在要求 16 KB 页对齐的 Android 15+ 设备上无法加载，而用户没有任何提示。CLI 可绕过。

---

## D-05（P2）SysV `.so` writer 的 `.tbss` sh_offset ≠ sh_addr

**源码**：`src/aster.cpp:11198`（`setSh(kTbssIdx, ..., tbssVaddr, tdataVaddr+tdataSize, ...)`）、`11220`（`ptls.align=kTlsBlockAlign`）

用 `D05_sysv_tbss.ast`（.tdata 4 字节 + .tbss 16 字节）：

| 命令 | .tbss Address | .tbss Off | PT_TLS Align |
| --- | --- | --- | --- |
| `build-so tls.ast -o sysv.so`（无 soname/needed → SysV writer） | `0x3010` | **`0x3004`** | `0x10` |
| `build-so --soname libdyn.so tls.ast -o dyn.so`（Dyn writer） | `0x3010` | `0x3010` | `0x10` |

在 addr==file-offset 的 identity map 下，NOBITS 节的 `sh_offset` 应与 `sh_addr` 一致；Dyn writer（11842）如此，SysV writer 用了未对齐的 `tdataVaddr+tdataSize`。另外 SysV writer 全程硬编码 `kTlsBlockAlign=16`，未接收 `spec.tlsAlign`，而 F-10 的提升只落在 `link-so`/Dyn 路径（11553/11802/11841）。

---

## G-01 / G-02 / G-08（门禁元发现）零断言 PASS / 静默 SKIP / APK gate 一键跳过

受控实验（`G_gate_experiment.sh`，用 `CI_SUITE_DIR` 指向 /tmp 的假套件，不污染工作树）：

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

对应 `tests/ci.sh:395-402`（`rc==0` 不要求 `pass_marks>0`）、`:558-559` 与 `:586`（`GATE_SKIP` 不进终判）、`:86` 的 `CRITICAL` 只含 25 个老套件。这复现了第二轮审计的 G-01/G-02，以及本轮新增的 G-08（17 个 v0.23.77-dev 新套件全部不在 `CRITICAL`；非 CRITICAL 套件的 `rc=77` 静默 SKIP 不计 FAIL）。

---

## D-06 / D-07 / D-08（P2/观察）其它已实证项

| 项 | 实验 | 结果 |
| --- | --- | --- |
| D-06 · `aster.proj` 重复源行 | `aster new p; echo src/util.ast >> aster.proj; aster build` | `error: duplicate global symbol 'add' across input objects`；对照 `aster add src/util.ast` 正确提示 `is already in aster.proj` |
| D-07 · 含空格路径的缓存 meta | `src/my extra.ast` 连跑两次 `aster build` | `3 compiled, 0 reused` → `1 compiled, 2 reused`（该对象永不命中）；对照无空格 `0 compiled, 3 reused` |
| D-08 · `execAarch64Image` 的 errno | `PATH=<无 qemu> aster run` | 只报 `aster run: Exec format error`（ENOEXEC），而不是 qemu 缺失；源码 `:153` 把 `execvp` 的 ENOENT 覆盖回 `execErrno` |

---

## D-09（P2）畸形浮点字面量被静默截断

**源码**：`src/aster.cpp:443-474`（数字 token 扫描循环，fractional 与 exponent 分支 `continue` 后可重复进入）、`:1885`（`std::strtod(tok.s.c_str(), nullptr)`，`endptr` 为 null）

| 字面量 | Aster `i32(x)` | libc `strtod` | `aarch64-linux-gnu-gcc -O2 -c` |
| --- | --- | --- | --- |
| `1e2e3` | 100 | 100.0 | `error: invalid suffix "e3" on floating constant` |
| `1.5e2e3` | 150 | 150.0 | `error: invalid suffix "e3" on floating constant` |
| `1.5.2` | 1 | 1.5 | `error: too many decimal points in number` |
| `1.2.3` | 1 | 1.2 | `error: too many decimal points in number` |
| `1e2`（对照） | 100 | 100.0 | 接受 |
| `1e400` | 255（inf 饱和） | inf | 接受（溢出警告） |

复现探针：`D09_malformed_float_literal.ast`（内含四种拼写的说明，逐个替换 `let x` 的初值即可）。`float-literal-checks.sh:80-82` 只拒绝 `1e` / `1.5e+` / `1e9u`，未覆盖重复分段。

---

## 「门禁全绿但缺陷存在」的直接证据

在**同一份** `HEAD=6e7a148` 上重跑相关常驻套件，全部 `rc=0`：

```
float-checks.sh          PASS: f64 and f32 (... the FP calling convention, refusals)
float-literal-checks.sh  PASS: exponent float literals (...)
frame-size-checks.sh     PASS: frame sizing (default pinned, compact leaf, stack args, CFI, mutation)
project-checks.sh        PASS: project workflow (new, build cache, deps, error paths, mutation)
```

覆盖盲区的具体形状：
- `frame-size-checks.sh:130` 的 compact 栈参数用例是 `examples/stack_arg_abi.ast`，帧小于 4096，`incomingBaseWords` 的 patch 合法；没有「紧凑帧 > 4095 + 栈上传入参数」的组合。
- `float-checks.sh:119` 的 `a_nine` 有九个 f64 参数但**没有局部变量**，参数区自洽；没有「f64 变量 + 足够多其它 slot」的组合。
- 全部 132 个 `examples/*.ast` 中使用 `f64`/`f32` 的数量为 **0**，393 行字节基线对这两个缺陷没有任何钉子。
- `--compact-frames` 未出现在 `aster` 的 usage 帮助里，但文档（`docs/language-reference.md`、`FEATURE_STATUS.md`、`VERSION_HISTORY.md`）已有记载。
