// tests/layout-boundary-twin.c — the C half of tests/layout-boundary-checks.sh.
//
// AUDIT-v0.23.61-dev.md item 9 asked for the ELF/linker claims to be checked
// empirically, and item 10 for `layoutStruct` to accumulate with an overflow
// check. Both turned out to be about the same thing: **layout arithmetic that
// silently wraps**. This file is the twin for the half of that which C can
// answer — struct layout — plus the property the thread-local defect destroys
// (two distinct thread-locals do not alias).
//
// What is deliberately *not* twinned, and why:
//
//   * The 4 GiB thread-local block. Reproducing it in C would ask the C
//     compiler for a 4 GiB per-thread allocation, which is not a thing this
//     test can honestly request; and the property under test — "the offset
//     must fit the 32-bit MOVZ/MOVK pair a local-exec access carries" — is a
//     property of Aster's own code sequence, not of C's. So the TLS half is
//     asserted structurally instead: the emitted MOVZ/MOVK pair is read back
//     out of the image and its immediate is checked against the symbol's
//     block offset.
//   * The 2^32 struct. gcc refuses it (`size of array exceeds maximum object
//     size`), so there is no C answer to compare against — the Aster side has
//     to refuse too, and the refusal is its own witness.
//
// Cases L1..L4 mirror the layout witnesses, L5..L6 the aliasing property.
#include <stddef.h>
#include <stdio.h>

struct L1 { long long a[128]; };                 /* 1024 */
struct L2 { long long a[127]; unsigned char b; };/* 1016 + 1 -> round to 1024 */
struct L3 { unsigned char a; long long b; unsigned short c; }; /* 0, 8, 16 -> 24 */
struct L4i { int x, y; };
struct L4 { struct L4i a[2]; };                  /* 16 */

static __thread long long t_a;
static __thread long long t_b;

int main(void) {
    int bad = 0;
#define SHOW(name, expr, want) do { \
        long long got_ = (long long)(expr); \
        if (got_ != (long long)(want)) { \
            printf("FAIL %s: got %lld want %lld\n", name, got_, (long long)(want)); \
            bad = 1; \
        } else { \
            printf("%s %lld\n", name, got_); \
        } \
    } while (0)

    /* An Aster `return r` is the process exit status, so it is r & 0xff and a
       size above 255 cannot travel back unchanged. The suite therefore diffs
       the /256 form of the two 1024-byte cases, and the raw form of the two
       that fit. Both spellings are printed so the file reads on its own. */
    SHOW("L1.size",         sizeof(struct L1),       1024);
    SHOW("L2.size",         sizeof(struct L2),       1024);
    SHOW("L1.size_over_256", sizeof(struct L1) / 256, 4);
    SHOW("L2.size_over_256", sizeof(struct L2) / 256, 4);
    SHOW("L3.size",  sizeof(struct L3),  24);
    SHOW("L3.off_b", offsetof(struct L3, b), 8);
    SHOW("L3.off_c", offsetof(struct L3, c), 16);
    SHOW("L4.size",  sizeof(struct L4),  16);

    /* L5/L6: two thread-locals at different block offsets hold independent
       values. Aster's truncated-offset bug made the second one land on the
       first, so this is exactly the property that disappeared. */
    t_a = 0; t_b = 0;
    t_b = 1;
    SHOW("L5.t_a_after_t_b", t_a, 0);
    SHOW("L6.t_b",           t_b, 1);

    return bad;
}
