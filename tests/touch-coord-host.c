/* v0.23.15-dev test host for tests/touch-coord-test.ast: dlopen the shared
 * object the coordinate-capture chain was built into, resolve the exported
 * check with dlsym, call it and propagate its return value as this process's
 * exit status, so tests/touch-checks.sh can assert on it under qemu.
 *
 * Build for the target architecture, e.g.
 *   aarch64-linux-gnu-gcc -O1 -o touch-coord-host tests/touch-coord-host.c -ldl
 */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "./touch-coord.so";
    void *h = dlopen(path, RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 2; }
    int (*check)(void) = (int (*)(void))dlsym(h, "coord_check");
    if (!check) { printf("dlsym failed: %s\n", dlerror()); return 3; }
    int r = check();
    printf("coord_check=%d\n", r);
    return r;
}
