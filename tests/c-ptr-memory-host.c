#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t (*load_fn)(int32_t *);
typedef int32_t (*store_fn)(int32_t *, int32_t);
static void *symbol(void *h, const char *name) {
    dlerror(); void *p = dlsym(h, name); const char *e = dlerror();
    if (e || !p) { fprintf(stderr, "FAIL: dlsym %s: %s\n", name, e ? e : "null symbol"); exit(3); }
    return p;
}
int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "./libaster_ptr_memory.so";
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "FAIL: dlopen: %s\n", dlerror()); return 2; }
    void *s = symbol(h, "aster_ptr_load"); load_fn load = NULL; memcpy(&load, &s, sizeof(load));
    s = symbol(h, "aster_ptr_store"); store_fn store = NULL; memcpy(&store, &s, sizeof(store));
    int32_t value = 0x1234567;
    int32_t got = load(&value);
    printf("load=%d\n", got);
    if (got != value) { fputs("FAIL: dereference load mismatch\n", stderr); return 4; }
    got = store(&value, -123456789);
    printf("stored=%d memory=%d\n", got, value);
    if (got != -123456789 || value != -123456789) { fputs("FAIL: dereference store mismatch\n", stderr); return 5; }
    if (dlclose(h) != 0) { fprintf(stderr, "FAIL: dlclose: %s\n", dlerror()); return 6; }
    puts("PASS: C -> Aster i32 pointer dereference load/store");
    return 0;
}
