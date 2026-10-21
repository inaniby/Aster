/* v0.17.0 test host: dlopen an Aster-generated shared object, resolve the exported functions with
 * dlsym, call them and check the results. The exported functions read and write the object's
 * globals through their .got slots, so the checks only pass if the dynamic loader applied the
 * R_AARCH64_RELATIVE relocations in .rela.dyn.
 *
 * Build for the target architecture, e.g.
 *   aarch64-linux-gnu-gcc -O1 -o so-host tests/so-host.c -ldl
 */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "./so_math.so";
    void *h = dlopen(path, RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 2; }
    int (*add)(int, int)          = (int (*)(int, int))dlsym(h, "add");
    int (*mul)(int, int)          = (int (*)(int, int))dlsym(h, "mul");
    int (*accumulate)(int)        = (int (*)(int))dlsym(h, "accumulate");
    int (*current)(void)          = (int (*)(void))dlsym(h, "current");
    int (*untouched_value)(void)  = (int (*)(void))dlsym(h, "untouched_value");
    if (!add || !mul || !accumulate || !current || !untouched_value) {
        printf("dlsym failed: %s\n", dlerror());
        return 3;
    }
    int a = add(20, 22);
    int m = mul(6, 7);
    int c0 = current();          /* accumulator starts at 7  (.data global) */
    int c1 = accumulate(30);     /* 37 */
    int c2 = accumulate(5);      /* 42 */
    int c3 = current();
    int z = untouched_value();   /* stays 0 (.bss global) */
    printf("add(20,22)=%d mul(6,7)=%d current=%d accumulate(30)=%d accumulate(5)=%d current=%d untouched=%d\n",
           a, m, c0, c1, c2, c3, z);
    if (dlclose(h) != 0) { printf("dlclose failed\n"); return 5; }
    return (a == 42 && m == 42 && c0 == 7 && c1 == 37 && c2 == 42 && c3 == 42 && z == 0) ? 0 : 4;
}
