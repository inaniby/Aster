/* v0.17.0 test host: dlopen an Aster-generated shared object, resolve one exported function with
 * dlsym, call it, and compare the result with the expected exit value. Used to prove that a
 * run-time global initializer really ran: shared objects have no entry point of their own, so the
 * compiler hangs the generated __aster_init routine off DT_INIT_ARRAY and the dynamic loader calls
 * it during dlopen, before this host ever resolves a symbol.
 *
 * Build for the target architecture, e.g.
 *   aarch64-linux-gnu-gcc -O1 -o so-init-host tests/so-init-host.c -ldl
 * Usage: so-init-host <lib.so> <symbol> <expected>
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: so-init-host <lib.so> <symbol> <expected>\n"); return 2; }
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 2; }
    int (*fn)(void) = (int (*)(void))dlsym(h, argv[2]);
    if (!fn) { printf("dlsym failed: %s\n", dlerror()); return 3; }
    int got = fn();
    int want = atoi(argv[3]);
    printf("%s()=%d expected=%d\n", argv[2], got, want);
    dlclose(h);
    return got == want ? 0 : 4;
}
