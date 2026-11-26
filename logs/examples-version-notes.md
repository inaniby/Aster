<!-- Moved from README.md (original lines 514–560 (comment lines only)), 2026-11-26. -->
<!-- The original lines were `> ` blockquote paragraphs; the `> ` markers are
     removed here and the wording is otherwise unchanged. -->

# Version notes from the README examples

These were `# vX.Y.Z-dev: …` comment lines inside the `## Examples` code block of README.md. The example commands themselves stay in README.md; only the version annotations moved here. For the condensed per-version history, see `docs/VERSION_HISTORY.md`.

## v0.23.48-dev

*Source: README.md:514.*

```sh
# v0.23.48-dev: u64 and the T(x) cast — every cast direction, one bit per group
```

## v0.23.39-dev

*Source: README.md:516.*

```sh
# v0.23.39-dev: a discarded-call statement — fire-and-forget, the result is dropped
```

## v0.23.45-dev

*Source: README.md:518.*

```sh
# v0.23.45-dev: the bootstrap compiler's semantic stage — bootstrap/aster.ast adds a type-check pass; on success it re-emits M3b's AST dump, on failure it prints an S-error and empty stdout
```

## v0.23.44-dev

*Source: README.md:520.*

```sh
# v0.23.44-dev: the bootstrap compiler's parser stage — bootstrap/aster.ast reads Aster source, dumps the AST
```

## v0.23.43-dev

*Source: README.md:522.*

```sh
# v0.23.43-dev: the bootstrap compiler's lexer stage — bootstrap/aster.ast reads Aster source, dumps the token stream
```

## v0.23.42-dev

*Source: README.md:524.*

```sh
# v0.23.42-dev: the Aster standard library — build the library object, link it to its consumer
```

## v0.23.41-dev

*Source: README.md:526.*

```sh
# v0.23.41-dev: raw memory — mmap/brk with no allocator; a bump allocator is 25 lines on top
```

## v0.23.40-dev

*Source: README.md:528.*

```sh
# v0.23.40-dev: raw syscalls — copy stdin to stdout with read/write/close (no libc)
```

## v0.23.38-dev

*Source: README.md:530.*

```sh
# v0.23.38-dev: a callback table — a struct field of function type, called where it is named
```

## v0.23.38-dev

*Source: README.md:532.*

```sh
# v0.23.38-dev: a function that returns a function pointer — the signature rides in the return slot
```

## v0.23.37-dev

*Source: README.md:534.*

```sh
# v0.23.37-dev: a function pointer with a signature — fn(i32) : i32
```

## v0.23.33-dev

*Source: README.md:536.*

```sh
# v0.23.33-dev: -g also adds .eh_frame — a debugger can walk a stack, not only print the frame
```

## v0.23.32-dev

*Source: README.md:539.*

```sh
# v0.23.32-dev: -g adds DWARF .debug_line + .debug_info — a debugger can print a variable by name
```

## v0.23.31-dev

*Source: README.md:541.*

```sh
# v0.23.31-dev: a second subscript — T[N][M], where a[i] is a row and a[i][j] the element
```

## v0.23.30-dev

*Source: README.md:543.*

```sh
# v0.23.30-dev: an array has an address — &buf is a ptr, so a T[N] travels by reference
```

## v0.23.29-dev

*Source: README.md:545.*

```sh
# v0.23.29-dev: a struct field that is an array — nums: i32[4], pts: Vec3[2]
```

## v0.23.28-dev

*Source: README.md:547.*

```sh
# v0.23.28-dev: an array of any element type — bool[4], Point[3], ptr[3], a 12-byte struct
```

## v0.23.13-dev

*Source: README.md:555.*

```sh
# v0.23.13-dev: the same two-file program with `include` instead of a hand-written extern
```

## v0.23.14-dev

*Source: README.md:559–560.*

```sh
# v0.23.14-dev: touch input — the first interactive native app (on-screen check needs a device;
#               the pipeline itself was inert on-device until the v0.23.15-dev fix)
```
