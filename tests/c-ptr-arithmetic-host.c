#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *(*ptr_offset_fn)(void *, int32_t);
typedef void *(*ptr_reversed_fn)(int32_t, void *);

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s shared-object\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    void *sym_add = dlsym(h, "aster_ptr_add");
    void *sym_sub = dlsym(h, "aster_ptr_sub");
    void *sym_reversed = dlsym(h, "aster_ptr_add_reversed");
    ptr_offset_fn add = NULL, sub = NULL;
    ptr_reversed_fn reversed = NULL;
    /* POSIX dlsym returns a callable symbol address; memcpy avoids ISO C cast warnings. */
    if (sizeof add != sizeof sym_add || sizeof sub != sizeof sym_sub || sizeof reversed != sizeof sym_reversed) {
        fprintf(stderr, "function pointer representation mismatch\n"); return 1;
    }
    memcpy(&add, &sym_add, sizeof add);
    memcpy(&sub, &sym_sub, sizeof sub);
    memcpy(&reversed, &sym_reversed, sizeof reversed);
    if (!add || !sub || !reversed) { fprintf(stderr, "dlsym: missing pointer arithmetic export\n"); return 1; }
    unsigned char bytes[32];
    void *base = bytes + 12;
    if (add(base, 7) != bytes + 19) { fprintf(stderr, "ptr + 7 mismatch\n"); return 1; }
    if (sub(base, 5) != bytes + 7) { fprintf(stderr, "ptr - 5 mismatch\n"); return 1; }
    if (reversed(3, base) != bytes + 15) { fprintf(stderr, "3 + ptr mismatch\n"); return 1; }
    if (add(base, -4) != bytes + 8) { fprintf(stderr, "ptr + negative offset mismatch\n"); return 1; }
    printf("base=%p add=%p sub=%p\n", base, add(base, 7), sub(base, 5));
    puts("PASS: C -> Aster byte-based pointer addition/subtraction");
    puts("PASS: signed i32 offsets and reversed addition");
    puts("PASS: Aster v0.22.5-dev pointer arithmetic ABI test");
    dlclose(h);
    return 0;
}
