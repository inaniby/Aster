# v0.23.72-dev 审计证据语料

本目录是 `AUDIT-v0.23.72-dev.md` 的**可复现证据**，不是常驻测试套件：

- 它**不注册进** `tests/ci.sh` 的 `DEFAULT_SUITES`，也**不**出现在 `tests/smoke.sh` 里；
- `tests/ci-protocol-checks.sh` 的孤儿检测只枚举 `tests/*.sh`（本目录在子目录里，且 `.ast`/`.bin`/`.c`/`.py` 都不是套件脚本），因此不会触发 orphan 判定；
- 这里的程序**故意保留缺陷**：它们是「现状会出错」的最小复现，不是「应该通过」的断言。修复轮（v0.23.73-dev 起）应把它们转成正经的回归套件再注册进 CI。

## 工具链

```
g++ -std=c++17 -O2 -Wall -Wextra -pedantic -Werror src/aster.cpp -o ./aster
qemu-aarch64
aarch64-linux-gnu-gcc -static -O2        # C oracle
aarch64-linux-gnu-objdump -d             # 读回实际发射的编码
aarch64-linux-gnu-readelf -SW / -lW      # 节头与程序头契约
python3 bump_align.py                    # ELF64 节头 sh_addralign 手术
```

从仓库根运行所有命令。`bump_align.py <in.o> <out.o> .section=align ...` 直接改写
ELF64 `Shdr+48` 的 `sh_addralign` 字段——`parseObject` 接受外部对象节头
`addralign ≤ 65536`，而 Aster 自己写出的对象只声明 16/64，这是触达高对齐路径的唯一办法。

## 通用运行方式

```sh
./aster build-elf <probe>.ast -o /tmp/<probe>.elf     # 或 build-obj / build-so
qemu-aarch64 /tmp/<probe>.elf; echo "EXIT=$?"
aarch64-linux-gnu-objdump -d /tmp/<probe>.elf | grep -E 'uxtw|uxtx|undefined'
```

> **低 8 位陷阱**：进程退出码只保留低 8 位。`10852 & 0xff = 100`、
> `10752 & 0xff = 0` 曾让两轮探针出现假阴性。凡涉及「读回值是否正确」，
> 一律用条件返回（`if (v == expected) return 0; return 1;`），不要直接返回读回值。

## 语言级探针实测（`build-elf` + `qemu-aarch64`）

| 文件 | 对应 | 实测 | 说明 |
| --- | --- | --- | --- |
| `F01_stack_arg_lost.ast` | F-01 | `EXIT=0` | 预期 60；`w` 的三个字段读到未初始化字节 |
| `F01_ctl_8_scalars.ast` | 对照 | `EXIT=88` | 8 标量全进 x0–x7，正确 |
| `F01_ctl_agg_in_x6x7.ast` | 对照 | `EXIT=60` | 聚合落在 x6/x7，正确 |
| `F01_ctl_9th_on_stack.ast` | 对照 | `EXIT=9` | 第 9 参落栈但 `ngrn` 已 8，正确 |
| `F02_stride_sh5.ast` | F-02 | `EXIT=132` core | `UXTW #5` 保留编码 → SIGILL |
| `F02_stride_sh8.ast` | F-02 | `EXIT=1` | `0x6000` → `LSL #0`（`uxtx`），缩放 ×1 |
| `F02_stride_sh10.ast` | F-02 | `EXIT=1` | `0x6800` → `LSL #2`，缩放 ×4 |
| `F02_struct32.ast` | F-02 | `EXIT=132` core | `emitElemIndex` 同源：32B 元素 → SIGILL |
| `F02_ctl_sh4.ast` | 对照 | `EXIT=0` | `UXTW #4` 合法 |
| `F02_ctl_nonpow2.ast` | 对照 | `EXIT=0` | 非 2 幂 stride 走 UMADDL，正确 |
| `F03_u64_global_const.ast` | F-03 | `REJECTED` | `addition overflows i64 in global variable initializer` |
| `F03_ctl_single_literal.ast` | 对照 | `BUILD_OK` | 同值单字面量被接受 |
| `F03_ctl_runtime.ast` | 对照 | `BUILD_OK` | 同式在运行时按 u64 回绕 |
| `F04_label_shadow.ast` | F-04 | `REJECTED` | `expected P, got i32`：alias 被 struct 遮蔽 |
| `F04_ctl_reverse.ast` | 对照 | `REJECTED` | 反序报 `type alias conflicts with a struct: P` |
| `F04_ctl_alias_only.ast` | 对照 | `EXIT=5` | 只有 alias 时正常 |
| `F05_switch_enum_case.ast` | F-05 | `EXIT=1` | case `2^32` 被截成 0 撞上 Red |
| `F05_ctl_i32_subject.ast` | 对照 | `REJECTED` | 同 case 值在 i32 主题被拒 |
| `F06_overflow_index.ast` | F-06 | `EXIT=11` | 越界检查被跳过，回绕读到 `a[0]` |
| `F06_ctl_const_oob.ast` | 对照 | `REJECTED` | `index 4, length 4` |
| `F07_mixed_sign_cmp.ast` | F-07 | `EXIT=0` | 预期 1 |
| `F07_ctl_both_i64.ast` | 对照 | `EXIT=1` | 两边 i64 正确 |
| `F07_mixed_sign_div.ast` | F-07 | `EXIT=0` | UDIV 得巨值 |
| `F11_deref_bool.ast` | F-11 | `EXIT=1` | `*p = true` 被接受，`a` 读回 1 |
| `F11_ctl_assign_bool.ast` | 对照 | `REJECTED` | `type mismatch assigning variable: a` |
| `F13_embed_absolute.ast` | F-13 | `RC=0` | 产物含 13 字节 `/etc/hostname` |
| `F13_embed_traversal.ast` | F-13 | `RC=0` | `../../../` 同样成功 |

C oracle：

```sh
aarch64-linux-gnu-gcc -static -O2 -o /tmp/f07_oracle F07_oracle.c
qemu-aarch64 /tmp/f07_oracle; echo "EXIT=$?"       # 1：有符号比较为真
```

objdump 佐证（`F02_stride_sh5.ast` 产物）：

```
401058: 8b215610  .inst 0x8b215610 ; undefined      # UXTW #5
401074: 8b215610  .inst 0x8b215610 ; undefined
```

`0x8b215610` 解码：`0x8b200000 | (1<<16) | (0b010<<13) | (5<<10) | (16<<5) | 16`，
即 `ADD X16,X16,W1,UXTW #5`；imm3 = 5 超出 UXTW 允许的 0–4。`sh=8` 时
`8<<10 = 0x2000` 进位到 option 字段，把 `0b010`（UXTW）改成 `0b011`（LSL/UXTX）。

## ELF 节头手术实验

```sh
# F-08 (.tbss 起点固定 16) 与 F-12 (addralign=0 被误拒)
./aster build-obj F08_tbss_align.ast -o /tmp/tbss.o
python3 bump_align.py /tmp/tbss.o /tmp/tbss32.o .tdata=32 .tbss=32
./aster link-obj /tmp/tbss32.o -o /tmp/tbss32.elf
aarch64-linux-gnu-readelf -SW /tmp/tbss32.elf | grep -E '\.tdata|\.tbss'
# 实际: .tdata 0x402040 (Align 32, OK) ; .tbss 0x402050 (Align 32, Addr%32=16 -> 违约)
aarch64-linux-gnu-readelf -lW /tmp/tbss32.elf | grep -A1 TLS    # p_align=0x20, OK

python3 bump_align.py /tmp/tbss.o /tmp/tls0.o .tdata=0 .tbss=0
./aster link-obj /tmp/tls0.o -o /tmp/tls0.elf
# 实际: "unsupported .tdata section attributes"；而 .rodata=0 同法被放行

# F-09 (.data 只按 pageSize 对齐)
./aster build-obj F09_data_align.ast -o /tmp/smalldata.o
python3 bump_align.py /tmp/smalldata.o /tmp/data8192.o .data=8192
./aster link-obj /tmp/data8192.o -o /tmp/data8192.elf
aarch64-linux-gnu-readelf -SW /tmp/data8192.elf | grep '\.data'
# 实际: .data 0x403000, Align 8192 -> Addr%8192 = 4096 (违约)
# 对照 .data=4096 -> 0x403000, Align 4096, 全对齐

# F-10 (link-so 的 PT_TLS 恒 16)
./aster build-obj --pic F10_sotls.ast -o /tmp/sotls.o
python3 bump_align.py /tmp/sotls.o /tmp/sotls32.o .tdata=32 .tbss=32
./aster link-so --soname libsotls.so /tmp/sotls32.o -o /tmp/libsotls.so
aarch64-linux-gnu-readelf -lW /tmp/libsotls.so | grep -A1 TLS   # p_align=0x10 (16)
# 与 .tdata=16/.tbss=16 的产物完全相同 -> maxTlsAlign 是死变量
```

## 门禁假阳性实验（第 5 路）

```sh
cat > tests/zz_audit_probe.sh <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x tests/zz_audit_probe.sh
CI_SUITES=zz_audit_probe.sh CI_SKIP_APK_GATE=1 sh tests/ci.sh
rm -f tests/zz_audit_probe.sh
```

实测输出：

```
zz_audit_probe.sh                            PASS
SKIP (CI_SKIP_APK_GATE=1)
CI SUMMARY: 1 passed, 0 skipped, 0 failed (of 1 suites)
APK GATES : 0 passed, 1 skipped, 0 failed
```

一个零断言、零输出的 `exit 0` 套件被判 `PASS`（G-01）；三个 APK gate 被
一键跳过后终判仍绿（G-02）。实验用的临时套件已从工作树删除。

## 误判记录

`X-01`（`0x_a` 的分隔符校验）被实测推翻，本目录**不保留**其探针：

```
fn main() -> i32 { return 0x_a; }   -> REJECTED "hexadecimal literal has no digits"
fn main() -> i32 { return 1_a; }    -> REJECTED "digit separator '_' must be between two digits"
```

hex 分支在剥离分隔符前就因无数字失败，推断的「返回 10」不成立。
