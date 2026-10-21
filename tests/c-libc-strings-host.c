#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t (*aster_strlen_fn)(const char *);
typedef int32_t (*aster_memcmp_fn)(const void *, const void *, int32_t);

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s libaster_libc_strings.so\n", argv[0]); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 1; }
    aster_strlen_fn aster_strlen = NULL;
    aster_memcmp_fn aster_memcmp = NULL;
    void *sym_strlen = dlsym(h, "aster_strlen");
    void *sym_memcmp = dlsym(h, "aster_memcmp");
    memcpy(&aster_strlen, &sym_strlen, sizeof aster_strlen);
    memcpy(&aster_memcmp, &sym_memcmp, sizeof aster_memcmp);
    if (!aster_strlen || !aster_memcmp) { fprintf(stderr, "dlsym: %s\n", dlerror()); return 1; }
    const char left[] = "Aster on Android";
    const char same[] = "Aster on Android";
    const char different[] = "Aster on Aardvark";
    int32_t length = aster_strlen(left);
    int32_t equal = aster_memcmp(left, same, (int32_t)sizeof(left));
    int32_t unequal = aster_memcmp(left, different, (int32_t)sizeof(left));
    printf("strlen=%d\n", length);
    printf("memcmp_equal=%d\n", equal);
    printf("memcmp_different=%d\n", unequal);
    if (length != (int32_t)strlen(left) || equal != 0 || unequal == 0) return 1;
    puts("PASS: C -> Aster -> Bionic strlen/memcmp with pointer arguments");
    puts("PASS: Aster v0.22.7-dev external pointer-call ABI test");
    dlclose(h);
    return 0;
}
