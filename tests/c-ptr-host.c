#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef void *(*aster_ptr_fn)(void *);

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "./libaster_ptr.so";
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "FAIL: dlopen: %s\n", dlerror()); return 2; }
    dlerror();
    void *symbol = dlsym(handle, "aster_ptr_echo");
    const char *error = dlerror();
    if (error || !symbol) { fprintf(stderr, "FAIL: dlsym: %s\n", error ? error : "null symbol"); dlclose(handle); return 3; }
    aster_ptr_fn echo = NULL;
    if (sizeof(echo) != sizeof(symbol)) { fputs("FAIL: function pointer size mismatch\n", stderr); dlclose(handle); return 4; }
    memcpy(&echo, &symbol, sizeof(echo));

    uintptr_t payload = (uintptr_t)0x123456789abcdef0ULL;
    void *input = &payload;
    void *output = echo(input);
    printf("input=%p\noutput=%p\n", input, output);
    if (output != input) { fputs("FAIL: pointer value was not preserved\n", stderr); dlclose(handle); return 5; }
    if (echo(NULL) != NULL) { fputs("FAIL: null pointer was not preserved\n", stderr); dlclose(handle); return 6; }
    if (dlclose(handle) != 0) { fprintf(stderr, "FAIL: dlclose: %s\n", dlerror()); return 7; }
    puts("PASS: C -> Aster -> C 64-bit pointer round trip");
    puts("PASS: null pointer round trip");
    return 0;
}
