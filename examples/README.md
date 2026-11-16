# examples/ — Aster 语言示例索引

本目录是 Aster 语言的示例程序（`.ast`），既是语言文档的可执行版，
也是测试语料：门禁的 153 个套件大多直接编译它们，
`tests/baseline/` 的冻结基线就是它们三个编译模式的逐字节哈希。

> 数字以实测为准（v0.23.82-dev，HEAD `449ad2a`）：
> **132 个 `.ast` 文件**，另有 2 个资源目录
> （`demo_assets/`、`embed_align_assets/`，供 `@embed` 示例用）。
> 基线行数 132 × 3 − 3 = **393 行**，算法见下。

## 示例分组（132 个）

### 1. 入门、控制流与表达式（26 个）

语言最小集：hello world、算术、赋值、条件、循环、递归、调用。

`hello.ast`、`arithmetic.ast`、`assignment.ast`、`condition.ast`、
`if_equal.ast`、`if_greater_equal.ast`、`if_greater_false.ast`、
`if_less.ast`、`if_less_equal.ast`、`if_not_equal_false.ast`、
`if_return.ast`、`while_break.ast`、`while_continue.ast`、`while_count.ast`、
`nested_while.ast`、`nested_loop_break.ast`、`nested_if.ast`、
`nested_calls.ast`、`recursion.ast`、`copy.ast`、`scope_shadow.ast`、
`long_expression.ast`、`precedence.ast`、`eight_args.ast`、`arguments.ast`、
`call-stmt.ast`

### 2. 函数、类型与字面量（20 个）

函数类型、一等函数、类型别名、枚举、联合体、整数转换、符号性与字面量。

`functions.ast`、`fn_ret.ast`、`fn_type.ast`、`indirect_call.ast`、
`cb_table.ast`、`char_return.ast`、`void_return.ast`、`const_binding.ast`、
`const_fold_u64.ast`、`literals.ast`、`cast-conversions.ast`、
`integer_cast.ast`、`type_alias.ast`、`union_layout.ast`、`enum_demo.ast`、
`signedness.ast`、`sizeof_len.ast`、`negative_division.ast`、
`front_sema.ast`、`switch.ast`

### 3. 数组、结构、全局量与初始化（27 个）

数组、结构体字段、全局变量（bss/data/共享定义）、运行时初始化、取地址。

`array_address.ast`、`array_bss.ast`、`array_elem_types.ast`、
`array_extern_defs.ast`、`array_extern_main.ast`、`array_index_expr.ast`、
`array_rw.ast`、`array_sum.ast`、`multi_dim_array.ast`、
`struct_array_field.ast`、`c_struct_abi.ast`、`align_global.ast`、
`global_bss.ast`、`global_mixed.ast`、`global_rw.ast`、`global_shadow.ast`、
`global_shared_defs.ast`、`global_shared_main.ast`、`symbols_demo.ast`、
`symbols_init.ast`、`address_of.ast`、`address_of_abi.ast`、
`pie_global_rw.ast`、`runtime_init.ast`、`runtime_init_order_defs.ast`、
`runtime_init_order_main.ast`、`many_locals.ast`

### 4. 指针、窄整数与 C ABI（17 个）

指针算术/取址/解引用、窄整数（i8/i16/u8…）的调用与内存表示、
与 C 代码互操作的 ABI 形状；是 `tests/e2e-c-*` 与 `tests/c-*-structural.sh`
的输入。

`c_abi_32_args.ast`、`c_abi_32_external_call.ast`、`c_libc_strings.ast`、
`c_mixed_ptr_stack.ast`、`c_ptr_arithmetic.ast`、`c_ptr_difference.ast`、
`c_ptr_echo.ast`、`c_ptr_index.ast`、`c_ptr_memory.ast`、`c_ptr_u8.ast`、
`narrow_args.ast`、`narrow_mem.ast`、`narrow_return.ast`、`narrow_so.ast`、
`narrow_stack_arg.ast`、`stack_arg_abi.ast`、`libc_abs.ast`

### 5. 嵌入、多目标文件与模块化（12 个）

`@embed` 嵌入文件、`@include` 与多文件模块、多个 `.rodata` 目标的链接。

`embed_align.ast`、`include_demo_defs.ast`、`include_demo_main.ast`、
`modular_helper.ast`、`modular_main.ast`、`multi_object_rodata_a.ast`、
`multi_object_rodata_b.ast`、`multi_object_rodata_c.ast`、
`multi_object_rodata_d.ast`、`multi_object_rodata_e.ast`、
`pie_modular_helper.ast`、`pie_modular_main.ast`

### 6. 共享对象与动态链接（17 个）

`.so` 的依赖链、作用域、缺失依赖/符号、TLS、版本串；是 `tests/so-*`
与 `tests/e2e-so-*` 的输入。

`link_so_client.ast`、`link_so_part_a.ast`、`link_so_part_b.ast`、
`so_chain_base.ast`、`so_chain_client.ast`、`so_chain_middle.ast`、
`so_chain_middle_unresolved.ast`、`so_link_import.ast`、`so_link_lib.ast`、
`so_math.ast`、`so_missing_dependency.ast`、`so_missing_symbol.ast`、
`so_scope_a.ast`、`so_scope_b.ast`、`so_tls_demo.ast`、`so_verstrlen.ast`、
`tls_demo.ast`

### 7. 标准库、字符串与杂项（7 个）

标准库演示、字符串字面量、空指针、步长缩放。

`stdlib_demo.ast`、`arena.ast`、`string_literals.ast`、
`string_literal_exec.ast`、`write_hello.ast`、`null_ptr.ast`、
`stride_scale.ast`

### 8. APK、UI 与原生（6 个）

NativeActivity 生命周期、原生渲染/触摸、图标文字演示、像素偏移自检；
是 `tests/apk-checks.sh` 等 APK 套件的输入。

`native_activity.ast`、`native_render.ast`、`native_touch.ast`、
`icon_text_demo.ast`、`pixel_offset_selfcheck.ast`、`lifecycle.ast`

## 示例与基线（`tests/baseline/*/example-hashes.txt`）的关系

每个示例在基线里占 **3 行**，一行一个编译模式：

| 模式 | 基线键 | 产物 |
| --- | --- | --- |
| `build-elf` | `<名>.build-elf` | 静态可执行文件 |
| `build-so` | `<名>.build-so` | 共享对象 |
| `build-obj --pic` | `<名>.build-obj_--pic` | 位置无关目标文件 |

每行是 `<键> <sha256 | FAILED>`（建不出来记 `FAILED`）。行数算法：

```text
132 个示例 × 3 个模式 − 3 行 = 393 行
```

减掉的 3 行是 `address_of_abi` 的三个模式——该示例在所有版本里都被
排除在基线比对之外（见 `tests/alias-const-checks.sh` 的 `[9/9]` 节，
它用 `grep -v '^address_of_abi\.'` 过滤后再与基线 diff）。

因此：

- **改任一示例的源码、改代码生成、改链接布局，都会动基线哈希**——
  44 个套件通过 `tests/lib/baseline.sh` 定位当前版本的基线文件并逐行
  比对，`tests/difftest-checks.sh` 还会断言总行数正好是 393。
- **新增示例**会让行数变成 393 + 3，必须同时重录新版本的基线，否则
  门禁直接失败（基线校验会报“行名对不上示例”或行数断言失败）。
- **删除/改名示例**同理：基线里不许出现指向不存在示例的行
  （`aster_baseline_check` 会逐行校验）。
- 重录规矩（复制最新快照、只改本轮动到的行、跑哪些套件验证）见
  `tests/baseline/README.md`。不要手工改旧版本的基线文件。

## 与 `tests/baseline/v0.16.0/` 的关系

`tests/regression-symtab.sh` 的 11 个对照产品（`CASES`）对应本目录的
10 个示例：`hello.ast`（`exec_plain` 与 `pie_plain` 共用）、
`symbols_demo.ast`、`align_global.ast`、`runtime_init.ast`（`exec_rtinit`
与 `so_rtinit` 共用）、`pie_global_rw.ast`、`global_rw.ast`、
`array_rw.ast`、`global_shared_main.ast`、`global_shared_defs.ast`、
`so_math.ast`。其中 `so_math.ast` 的 v0.16.0 夹具缺失，改用
`tests/baseline/symtab-frozen/`。
其中 7 个产品的 v0.16.0 产物以无后缀文件名冻结在
`tests/baseline/v0.16.0/`，原因见 `tests/baseline/README.md`。
