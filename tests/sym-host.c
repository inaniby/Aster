/* v0.17.0 test host: dlopen an Aster-generated shared object and resolve source-level names with
 * dlsym. The names come from the object's .dynsym, but the calls must still go through the object's
 * globals (reached via its .got slots), so the checks only pass when the image was unaffected by the
 * appended .symtab/.strtab.
 *
 * Build for the target architecture, e.g.
 *   aarch64-linux-gnu-gcc -O1 -o sym-host tests/sym-host.c -ldl
 */
#include <dlfcn.h>
#include <stdio.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "./tmp-sym.so";
    void *h = dlopen(path, RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 2; }
    int (*bump)(int)     = (int (*)(int))dlsym(h, "bump");
    int (*mainfn)(void)  = (int (*)(void))dlsym(h, "main");
    if (!bump || !mainfn) { printf("dlsym failed: %s\n", dlerror()); return 3; }
    int b = bump(6);      /* 42 */
    int m = mainfn();     /* counter=5 -> 6, bump(6)+zeroed(0)+spare[1](3) = 45 */
    printf("bump(6)=%d main()=%d\n", b, m);
    if (dlclose(h) != 0) { printf("dlclose failed\n"); return 5; }
    return (b == 42 && m == 45) ? 0 : 4;
}
