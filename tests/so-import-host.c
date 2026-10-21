/* v0.18.0 test host: exercise cross-.so imports.
 *
 * argv[1] = a shared object built with `build-so` that imports a function and a global from
 *           the exporting library through its PLT and GOT;
 * argv[2] = a shared object built with `link-so` from several object files;
 * argv[3] = a shared object built with `link-so` that imports from argv[2].
 *
 * The host is compiled for the target architecture, e.g.
 *   aarch64-linux-gnu-gcc -O1 -o so-import-host tests/so-import-host.c -ldl
 */
#include <dlfcn.h>
#include <stdio.h>

static void *h1, *h2, *h3;
static int fails;

static void *sym(void *h, const char *n) {
    void *p = dlsym(h, n);
    if (!p) { printf("FAIL: dlsym %s: %s\n", n, dlerror()); ++fails; }
    return p;
}
static void check(const char *what, int got, int want) {
    if (got == want) printf("PASS: %s = %d\n", what, got);
    else { printf("FAIL: %s expected %d, got %d\n", what, want, got); ++fails; }
}
int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *importer = argc > 1 ? argv[1] : "./libimport.so";
    const char *linked   = argc > 2 ? argv[2] : "./liblinked.so";
    const char *client   = argc > 3 ? argv[3] : "./libclient.so";

    int (*call_add)(void), (*call_mul)(void), (*read_counter)(void), (*bump_counter)(void), (*add_counter)(int);
    int (*add)(int,int), (*scaled)(int), (*sum_base)(int), (*bump_base)(void);
    int (*client_sum)(void), (*client_scaled)(void), (*client_base)(void), (*client_bump_base)(void);

    h1 = dlopen(importer, RTLD_NOW);
    if (!h1) { printf("FAIL: dlopen %s: %s\n", importer, dlerror()); return 1; }
    printf("PASS: dlopen %s (DT_NEEDED library resolved)\n", importer);
    call_add     = (int (*)(void))sym(h1, "call_add");
    call_mul     = (int (*)(void))sym(h1, "call_mul");
    read_counter = (int (*)(void))sym(h1, "read_counter");
    bump_counter = (int (*)(void))sym(h1, "bump_counter");
    add_counter  = (int (*)(int))sym(h1, "add_counter");

    h2 = dlopen(linked, RTLD_NOW);
    if (!h2) { printf("FAIL: dlopen %s: %s\n", linked, dlerror()); return 1; }
    printf("PASS: dlopen %s (link-so output)\n", linked);
    add       = (int (*)(int,int))sym(h2, "add");
    scaled    = (int (*)(int))sym(h2, "scaled");
    sum_base  = (int (*)(int))sym(h2, "sum_base");
    bump_base = (int (*)(void))sym(h2, "bump_base");

    h3 = dlopen(client, RTLD_NOW);
    if (!h3) { printf("FAIL: dlopen %s: %s\n", client, dlerror()); return 1; }
    printf("PASS: dlopen %s (cross-.so client of link-so output)\n", client);
    client_sum       = (int (*)(void))sym(h3, "client_sum");
    client_scaled    = (int (*)(void))sym(h3, "client_scaled");
    client_base      = (int (*)(void))sym(h3, "client_base");
    client_bump_base = (int (*)(void))sym(h3, "client_bump_base");

    if (fails) return 1;

    /* imported function calls: PLT + R_AARCH64_JUMP_SLOT */
    check("call_add (PLT add(20,22))", call_add(), 42);
    check("call_mul (PLT mul(6,7))", call_mul(), 42);
    /* imported data: GOT + R_AARCH64_GLOB_DAT */
    check("read_counter (GOT read)", read_counter(), 5);
    check("bump_counter (GOT write)", bump_counter(), 6);
    check("read_counter after bump", read_counter(), 6);
    check("add_counter(36) uses imported global", add_counter(36), 42);
    /* link-so output: intra-.so resolution across two objects */
    check("linked add(20,22)", add(20, 22), 42);
    check("linked scaled(4) uses part A global", scaled(4), 40);
    check("linked sum_base(32) crosses objects", sum_base(32), 42);
    check("linked bump_base (part B writes part A global)", bump_base(), 11);
    /* cross-.so client of the link-so output */
    check("client_sum (PLT into linked lib)", client_sum(), 43);
    check("client_scaled (GOT base + PLT scaled)", client_scaled(), 44);
    check("client_base (GOT read of linked global)", client_base(), 11);
    check("client_bump_base (GOT write into linked lib)", client_bump_base(), 12);

    dlclose(h3); dlclose(h2); dlclose(h1);
    if (fails) { printf("FAIL: %d cross-.so check(s) failed\n", fails); return 1; }
    printf("PASS: all cross-.so import checks passed\n");
    return 0;
}
