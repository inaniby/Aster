# Validation — v0.23.66-dev, the parts of an ELF image nobody runs

> **`AUDIT-v0.23.61-dev.md` 第二部分：**「以下为源码审阅定位、尚未构造复现用例的项……标注「待验」意味着可能存在误判，实施修复前应先复现。」

这一轮把第二部分的 ELF/链接器表**逐项复现**。v0.23.65-dev 已经处理了其中两项（`.eh_frame` 页对齐、`kRelTlsOff` 截断），本轮处理其余全部。结论：**五处真缺陷、一处防御性缺口、一处审计判错**。

---

## 1. `kRelTlsOff` 越界读写（高，唯一一处内存安全问题）

审计原文：`resolveRelocations` 的 `kRelTlsOff` 分支读写 `text[patch+4 .. patch+7]`，但 `parseObject` 只校验 `text.size() - offset >= 4`。

### 复现

`kRelTlsOff` 填的是 `MOVZ X17,#imm16` / `MOVK X17,#imm16,LSL#16` **一对**指令——8 字节。取一个 Aster 自己产出的对象，把 `.rela.text` 里 5 条 `kRelTlsOff` 重定位的 `r_offset` 全部改写为 `text.size() - 4`，再用 ASAN 构建的编译器链接它：

```
==3788168==ERROR: AddressSanitizer: heap-buffer-overflow on address 0x50d000000198
READ of size 1 at 0x50d000000198 thread T0
    #0 0x5651540491ab in resolveRelocations src/aster.cpp:9071
    #1 0x5651542ee7c0 in linkObjects src/aster.cpp:10495
0x50d000000198 is located 0 bytes after 136-byte region [0x50d000000110, 0x50d000000198)
SUMMARY: AddressSanitizer: heap-buffer-overflow src/aster.cpp:9071 in resolveRelocations
```

9071 行正是 `MOVK` 的读取循环 `text[(size_t)r.patch+4+i]`；紧随其后的是同一区间的**写**。

### 修复

边界按类型计算，不再恒为一条指令：

```cpp
// before
if(r.offset>result.text.size()||result.text.size()-r.offset<4||r.offset%4) throw ...;

// after
const uint64_t need=(type==kRelTlsOff)?8u:4u;
if(r.offset>result.text.size()||r.offset%4)
    throw Error(input+": relocation offset is out of bounds or unaligned");
if(result.text.size()-r.offset<need)
    throw Error(input+": relocation at offset "+std::to_string(r.offset)+" needs "+
                std::to_string(need)+" bytes of .text and only "+
                std::to_string(result.text.size()-r.offset)+" remain");
```

```
aster: error: /tmp/t.o: relocation at offset 132 needs 8 bytes of .text and only 4 remain
```

**对照组**：未篡改的对象照常链接。ASAN 构建**不**产生任何 sanitizer 报告——拒绝来自检查，不是来自运气。

Aster 自己写出的对象不会把一对指令放在 `.text` 末尾，所以这不可从源码触发；但 `parseObject` 是 `link-*` 读外部输入的入口，越过 `std::vector` 就是未定义行为，与能否触发无关。

---

## 2. 四个节头字段

判定「什么是对的」一律用**工具**，不用审计的猜测。GNU ld 的对照产物是 `aarch64-linux-gnu-gcc -shared -fPIC -Wl,--hash-style=sysv`。

| 字段 | 修复前 | 修复后 | 权威 |
|---|---|---|---|
| `.symtab` `sh_info`（`-g` 对象） | `1`，而 local 的 `STT_SECTION` 符号写在 GLOBAL 中间 | `symBase`（第一个 GLOBAL 的索引） | `readelf`：`Warning: local symbol 2 found at index >= .symtab's sh_info value of 1` |
| `.hash` `sh_entsize` | `0` | `4` | GNU ld 的 readelf `ES` 列是 `04` |
| `.rela.plt` `sh_info` | `0` | `.got.plt` 的索引 | GNU ld：`Inf 20`，而 `.plt` 是第 8 节 |
| `.bss`/`.tbss` `sh_offset` | 固定写 `relroEnd` | `sh_addr` − 所属段的 (vaddr−offset) 差 | GNU ld：`.bss` 为 `Address 0x20038` / `Off 0x10038`，差 `0x10000` 正是其 `PT_LOAD` 段差 |

### 2.1 符号表顺序

只有 `-g` 才写 `.text` 的 STT_SECTION 符号，它被写在紧邻线程局部之前的槽位——**GLOBAL 中间**，而 `sh_info` 恒为 1。修复后段符号占槽 1（紧跟 null 项），全局符号从 `symBase = 1 + dbgSym` 起：

```
修复前                                   修复后
  0: NOTYPE  LOCAL                         0: NOTYPE  LOCAL
  1: FUNC    GLOBAL  _start                1: SECTION LOCAL   .text
  2: SECTION LOCAL   .text   <-- readelf   2: FUNC    GLOBAL  _start
  3: OBJECT  GLOBAL  __aster_tls_a         3: OBJECT  GLOBAL  __aster_tls_a
  ...                                      ...
readelf: local symbol 2 found at index     [12] .symtab ... Inf 2
>= .symtab's sh_info value of 1
```

### 2.2 NOBITS 的偏移

`.tbss` 只占地址空间、不占文件字节，所以有 TLS 时 `.bss` 的地址在 `.tbss` 之后，而它的 `sh_offset` 停在 RELRO 末尾：

```
修复前   .bss   Address 0x3018  Off 0x3000     （差 0x18）
         .tbss  Address 0x3010  Off 0x3004     （差 0xc）
修复后   .bss   Address 0x3018  Off 0x3018
         .tbss  Address 0x3010  Off 0x3010
```

`build-elf`（base `0x400000`）同样成立：`.bss` `Address 0x402014` / `Off 0x2014`，差正好是 base。

---

## 3. 审计判错的一项

审计写：`.rela.plt` 的 `sh_info=0`（应为 `S_PLT`）。

GNU ld 的实测：

```
  [ 6] .rela.plt  RELA   00000000000004c0 0004c0 000060 18  AI  3  20  8
  [ 8] .plt       PROGBITS 0000000000000540 000540 000060 00  AX  0   0 16
  [20] .got.plt   PROGBITS 000000000001ffe8 00ffe8 000048 08  WA  0   0  8
```

`sh_info` 是 **20 = `.got.plt`**，不是 8 = `.plt`。而 ld 是对的：`R_AARCH64_JUMP_SLOT` 填的是 GOT 里的槽，不是 `.plt` 里的桩。

套件的 GNU ld 差分先对 ld 自己的产物断言同一组不变量，因此「对」由工具定义，修法跟随工具。这与上一轮页对齐那一项同构——**错的都是断言，不是代码**，区别只在于这次错的是审计而不是套件。

**`.gnu.hash` 记录为非缺陷**：它的 `sh_entsize` 是 0，GNU ld 的同样是 0。套件**断言 0**，以免后一轮把它「修」成缺陷。

---

## 4. 两处防御性补齐

| 项 | 内容 |
|---|---|
| PLT 的 `ADRP x16` | 同一条指令在 `resolveRelocations` 里有 `±2^20` 页检查（`pageDelta<-(1<<20)||pageDelta>=(1<<20)`），PLT 生成处没有，直接截断写进 21 位字段。当前不可达（`.plt` 与 `.got.plt` 相距数十字节），改为拒绝，两条路径不再不一致 |
| 纯 `.tbss` 对象的对齐 | `maxTlsAlign` 只从 `tdataAlign` 更新，所以线程局部全为零初始化的对象对合并块的对齐毫无贡献。`ParsedObject` 增加 `tbssAlign`，两个链接器都纳入 |

---

## 5. 字节影响

**只有 `.so` 动，且只动在节头表里。** 对全部 121 个例子逐一比对 v0.23.65 与本轮的 `build-so` 产物：

```
build-so 可编译: 121
文件长度不变:    121
差异字节 <= 4:   121
```

单个例子（`examples/arena.ast`）的逐字节定位：

```
differing bytes: 2
  run at 0x4300 -> section [5] .hash      field offset 56   (sh_entsize 0 -> 4)
  run at 0x4374 -> section [7] .rela.plt  field offset 44   (sh_info 0 -> .got.plt)
```

基线：360 行中 **116 行变化**，全部是 `build-so`；`build-elf` 与 `build-obj --pic` 一行未动（那两个写出器不写 `.hash`/`.rela.plt`，且例子里没有「同时有 `.bss` 与 `.tbss`」的组合）。`tests/baseline/v0.23.66-dev/` 已重录。

---

## 6. 新常驻套件 `tests/elf-metadata-checks.sh`

| 层 | 内容 |
|---|---|
| [1/9] | 严格构建 `g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror` |
| [2/9] | 21 条源码守卫，把七处修复钉在原处（含 `.gnu.hash` 的 0 与 `.rela.plt` 的 `.got.plt`） |
| [3/9] | 独立读者：`readelf`（能说的）＋ 解码器（readelf 不会告诉你 NOBITS 所属段的 offset/address 差）。8 条断言覆盖 3 种产物 |
| [4/9] | **GNU ld 差分**：对两个 ld 链接的 `.so` 断言同一组不变量，把「什么是对的」钉在工具上 |
| [5/9] | 拒绝矩阵 + **ASAN 构建**：篡改对象必须被拒绝，且**不**产生 sanitizer 报告 |
| [6/9] | qemu 见证：`build-elf` / `build-pie` 跑通并退出 18 |
| [7/9] | 覆盖计数（解码器断言 ≥6、源码守卫 ≥12） |
| [8/9] | 3 个变异体，逐一撤回一处修复，各自被对应层抓住 |
| [9/9] | 360 行字节基线 + 121 个例子 × 3 模式 |

---

## 7. 门禁

```
CI SUMMARY: 123 passed, 0 skipped, 0 failed (of 123 suites)
APK GATES : 3 passed, 0 skipped, 0 failed
```

本轮新增 1 个套件（122 → 123）。

---

## 8. 仍未处理

- **第 3 批第 13 项**：语言缺口 `typedef` / `const` / `void`（按审计路线排队）。
- **`.rodata` 的 `addralign` 是 1**，GNU ld 用 8，因此 `@embed` 的数据无法要求大于字节的对齐。这不是今天的缺陷（AArch64 容忍未对齐加载），但会移动字节，故留作独立一轮，已记入 `ROADMAP.md` backlog。
- `regression-symtab.sh` 的 `ET_REL` 分支仍未执行过（11 个用例只有 7 个固件被提交）。
