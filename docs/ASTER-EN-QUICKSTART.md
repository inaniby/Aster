# Aster Bilingual Frontend Tutorial

This guide covers the implemented English source syntax. Chinese and English
files compile to the same AST, types, and AArch64 ABI, but each source file
uses one structural language. The Chinese companion is
[`ASTER-CN-QUICKSTART.md`](ASTER-CN-QUICKSTART.md).

## Build and run

Build the compiler once, then use the `aster` command:

```sh
cmake -S . -B build/cn
cmake --build build/cn --target aster
aster build-cn-obj hello.ast -o hello.o
aster link-obj hello.o -o hello
```

The bilingual frontend emits AArch64 ELF64 relocatable objects. Programs that
construct classes or use string runtime operations also need the standard
library object:

```sh
aster build-obj stdlib/aster_std.ast -o aster_std.o
aster link-obj hello.o aster_std.o -o hello
```

Use `aster fmt source.ast`, `aster fmt --check source.ast`, and
`aster fmt --write source.ast` for four-space formatting.

Bilingual frontend diagnostics begin with a stable code such as `[A-010]` for
a mismatched block or `[A-050]` for a type-checking failure. Chinese sources
receive a Chinese summary and English sources receive an English summary; the
parenthesized detail remains available for command-line tools and IDEs. The
same semantic error uses the same code in both languages.

## First program and return syntax

```aster
// aster:language=en
fn main(): i32 {
    let answer: i32 = 40 + 2;
    return answer;
}
```

`main` is the English entry point and must return `i32`. Return types follow a
colon. A method may omit its return type: `fn log()` is equivalent to
`fn log(): void`. In Chinese sources the arrow `->` separates the binding
list from the object in foreach and enumloop; in English sources the
separator is `in` (`foreach (index, item in list)`), and `->` is not a
return-type operator in either language.

## Keywords and types

| Keyword | Meaning |
| --- | --- |
| `fn`, `let`, `const`, `return` | Functions, variables, constants, returns |
| `if`, `else if`, `else` | Conditional branches |
| `while`, `for` | Conditional and count loops |
| `foreach`, `enumloop` | Array/string-byte and field iteration |
| `switch`, `case` | Integer or enum matching |
| `break`, `continue` | Loop control |
| `class`, `interface class`, `struct`, `enum` | Type declarations |
| `package` | Source package declaration |

Built-in types include `i8`, `i16`, `i32`, `i64`, `u8`, `u16`, `u32`, `u64`,
`f32`, `f64`, `bool`, `char`, `string`, and `ptr`. `void` is a return type;
`null` is the empty pointer or class reference value.

Count and foreach loops use the implemented forms:

```aster
for (i = 1, 3) {
    if (i == 2) { continue; }
}

foreach index, item in values {
    sum = sum + item;
}

enumloop field in record {
    visits = visits + 1;
}
```

Foreach index and element bindings are read-only. Enumloop exposes public
fields of a structure or class.

## Annotations and access

Annotations apply to the following declaration. The implemented annotations
are:

| Annotation | Meaning |
| --- | --- |
| `@static` | Class field or method accessed through `Class.member` |
| `@constructor` | The one instance constructor of a class; returns `void` |
| `@override` | Exact-signature override of an inherited instance method |
| `@private` | Visible only in the declaring class, or declaring source for top-level declarations |
| `@protected` | Class members: declaring class and subclasses (not valid on top-level declarations; use `@private` there) |
| `@import("package").alias("name")` | Import a source package under a local alias |

`@protected` is the English spelling of Chinese `@受限`; the English frontend
does not use `@restricted`. `@static` is not valid on top-level functions or
interface methods. Static fields cannot be accessed through an object, and
static methods do not have `this`.

## Classes, constructors, inheritance, and interfaces

```aster
class Counter {
    let value: i32;
    @static
    let total: i32 = 0;

    @constructor
    fn initialize(initial: i32): void {
        this.value = initial;
        Counter.total = Counter.total + 1;
    }

    fn read(): i32 { return this.value; }
}

class DoubleCounter: Counter {
    @override
    fn read(): i32 { return super.read() * 2; }
}
```

`Counter()` allocates and default-initializes an object, then invokes its
constructor. A derived constructor may start with `super(args)` to pass values
to its direct base constructor. Calls through an object use runtime dispatch;
`super.method(...)` calls the base implementation directly. Interface method
signatures may omit their return type, which then defaults to `void`. A class
implements an interface with the same colon form, for example `class Reader: Readable`.

An interface value can be stored in a structure or class field, or in an
element of a one-dimensional fixed array. Reading it back preserves runtime
dispatch through that value's method table:

```aster
interface class Readable {
    fn read(): i32;
}

class Item: Readable {
    fn read(): i32 { return 21; }
}

struct StructHolder {
    value: Readable
    values: Readable[2]
}

class ClassHolder {
    let value: Readable;
    let values: Readable[2];
}

fn main(): i32 {
    let structHolder: StructHolder;
    structHolder.value = Item();
    structHolder.values[0] = Item();
    let classHolder: ClassHolder = ClassHolder();
    classHolder.value = Item();
    classHolder.values[0] = Item();
    return structHolder.value.read() + structHolder.values[0].read() +
        classHolder.value.read() + classHolder.values[0].read() - 84;
}
```

Static fields support scalar values, strings, one-dimensional scalar arrays,
one-dimensional string arrays, and function pointers:

```aster
fn addTwo(value: i32): i32 { return value + 2; }

class Callbacks {
    @static
    let callback: fn(i32): i32 = addTwo;
    @static
    let callbackArray: fn(i32): i32[2] = [addTwo, addTwo];
    @static
    let labels: string[2] = ["first", "second"];
    @static
    let values: i32[2] = [7, 8];
}

fn main(): i32 {
    if (Callbacks.labels[0] == "first" && Callbacks.labels[1] == "second" &&
        Callbacks.values[0] == 7) {
        return Callbacks.callback(40) + Callbacks.callbackArray[1](1);
    }
    return 0;
}
```

Instance fields can also store a typed function pointer. The field is part of
the object layout, so inherited objects carry it and calls use the object's
field value:

```aster
class Worker {
    let callback: fn(i32): i32 = addTwo;
    fn run(value: i32): i32 { return this.callback(value); }
}
```

Scalar struct static fields and one-dimensional struct static arrays support
explicit initializers, default values, and nested reads and writes.
One-dimensional function-pointer arrays are also supported and checked by
complete signature. String arrays use runtime initialization and default to
empty strings when no initializer is written.

Class references default to null. Calling an instance method through a null
class reference, reading or writing one of its instance fields, or using it as
an `enumloop` object, triggers `BRK #1` (SIGTRAP), the same behavior as a null
interface call.

## Packages and imports

The package declaration is the first non-comment declaration. No extra module
description file is required. Multiple files can share one package name and
must use the same alias list:

```aster
// aster:language=en
package example.math = 示例.数学;

fn cube(value: i32): i32 {
    return value * value * value;
}
```

Import a package with an annotation and use its local alias:

```aster
@import("example.math").alias("math")
fn main(): i32 {
    return math.cube(2);
}
```

Compile with the package source directory in the search path:

```sh
aster build-cn-obj --language en --module-dir packages app.ast -o app.o
aster link-obj app.o -o app
```

Public functions, globals, classes, interfaces, enums, and static members are
available through the alias. `@private` and `@protected` are checked at the
import site. An imported static function-pointer field can be called directly,
and inherited static callbacks use the declaring class's signature and access
rules.

External C or system functions use `extern fn name` in English. Chinese source
uses `外部("ASCII符号") 方法 中文方法名` so the source-facing name can stay
localized while the ABI symbol remains explicit. The mapping is required,
non-empty, and ASCII-only:

```aster
extern fn puts(text: ptr): i32;
```

```aster
外部("puts") 方法 输出(文本: 指针): 整数
```

External global objects use `extern let name: type;` in English and
`外部("ASCII符号") 变量 中文名: 类型` in Chinese. External globals cannot have
an initializer; the type may be a scalar, fixed-size array, string, or function
pointer:

```aster
extern let native_counter: i32;
```

```aster
外部("native_counter") 变量 计数: 整数
```

The first bilingual standard-library package is `standard.text`, with the
Chinese alias `标准库.文本`. It exposes `length`, `concat`, `equals`, and
`less`; the Chinese entry points are `长度`, `拼接`, `相等`, and `更小`.
Both language entry points use the same string runtime and `string_view` ABI:

```aster
@import("standard.text").alias("text")
fn main(): i32 {
    let value: i64 = text.length(text.concat("A", "ster"));
    return i32(value);
}
```

## Closures, enums, and examples

Closures use `fn [captures](...)` and the recursive type form
`closure(P, ...): R`. Captures are copied into a compiler-generated environment
and closures can be stored in locals, structure fields, fixed arrays, or passed
as callback arguments.

```aster
enum Color { Red, Blue = 4 }

fn main(): i32 {
    let offset: i32 = 1;
    let add = fn [offset] (value: i32): i32 {
        return value + offset;
    };
    return add(41);
}
```

The repository examples are in `examples/cn/`; `hello.ast` demonstrates count
loops and `oop.ast` demonstrates classes and static members. The formatter is
available to IDE integrations through `src/cn_formatter.hpp`.

## Declarative layout (D-2a)

A `layout` declaration is a named function returning a `View`; its body is
the tree expression. An `event` block is a top-level block whose header uses
a **name**, not a numeric key. Layout and event blocks close with braces;
an `if` inside a layout body still uses braces in English files. Ordinary
methods write the return type after a colon (`fn f(): i32`); the English
`layout` declaration does the same (`layout …: View`):

```aster
event Inc:tap() {
    g_app.count = g_app.count + 1;
    aui_state_set(1, g_app.count);
    aui_invalidate();
}

layout page_counter(s: ptr<App>, user: ptr) : View {
    Column MainCol, Padding(20), Gap(16) {
        Label Title, ptr("Counter")
        Row ButtonRow, Gap(12) {
            Button Dec, ptr("-")
            Number Count, s.count
            Button Inc, ptr("+")
        }
        Button Reset, ptr("Reset")
        if (s.count == 0) {
            Label Zero, ptr("Count is zero.")
        } else {
            Label NonZero, ptr("Count is non-zero.")
        }
    }
}
```

A node row is `Kind Name, args..., modifier calls..., { child rows... }` and
never appears in argument position. The node name is its identity: names are
unique within one layout declaration, and
`key = FNV-1a(declarationName.nodeName)` (32-bit, names hashed as UTF-8
bytes); a collision within one application is a compile error, overridable
with the named parameter `key = N` (`Column MainCol, key = 1001, Padding(20)
{ ... }` — an override parameter, not a modifier). `key(name)` is a
compile-time builtin that folds to an `i32` constant
(`aui_text_value(key(Input))`); referring to an unknown node name is a
compile error. Modifiers are calls (`Padding(20)`, `Gap(16)`,
`Background(...)`, `Radius(...)`, `TextSize(...)`, `Foreground(...)`,
`Selectable(...)`, `Size(...)`, `Align(...)`, `Weight(...)`, `Grow(...)`);
repeating one in a row is a compile error and string dimensions are refused.
`Grow` has no landing yet — the framework has no `aui_grow`, so writing
`Grow(...)` is a compile error, not a silent drop. An event block body may
only use globals and getters, never build locals; writing two blocks for the
same (key, event) is a compile error; statements after the tree expression
are post-mount statements and run in source order. The full node-kind,
modifier, and event-kind tables are in `docs/ASTER-CN-DESIGN.md` §2.16. The
bootstrap compiler rejects all D-2a forms (see the design §3.7).

## Current limits

The frontend currently targets the implemented subset of the language. One-
dimensional global structure arrays support structure literal lists, default
values, indexed member reads, and writes, subject to the existing constant
structure-field limits; string fields are not supported in global structure
array initializers or defaults. Methods accept one-dimensional fixed-length
array parameters by address; the declared length feeds bounds checks, and
named array arguments are checked for matching element types and lengths. Closures do not
accept array parameters. Multidimensional arrays, range matching, and string
matching are not connected. One-dimensional global string arrays support
literal initialization, default empty strings, indexing, and content
comparison. The standard
library is linked as an object. Manual `link-obj` still includes each input
object as a whole, while a bilingual project built with `aster build/run`
performs conservative function-level reachability pruning from `_start` when
`-g` is not enabled. Unused library functions are removed from bilingual
project executables; `-g` keeps the complete text so debug information remains
valid. Manual links can opt into the same pass with `--gc-sections`.
