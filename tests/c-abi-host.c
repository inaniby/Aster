#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int (*aster_unary_fn)(int);
typedef int (*aster_nullary_fn)(void);
typedef int (*aster_eight_fn)(int, int, int, int, int, int, int, int);
typedef int (*aster_twelve_fn)(int, int, int, int, int, int, int, int, int, int, int, int);

static void *load_symbol(void *handle, const char *name, void *function_storage,
                         size_t function_size) {
    dlerror();
    void *symbol = dlsym(handle, name);
    const char *error = dlerror();
    if (error || !symbol) {
        fprintf(stderr, "FAIL: dlsym(%s): %s\n", name, error ? error : "null symbol");
        return NULL;
    }
    if (function_size != sizeof(symbol)) {
        fprintf(stderr, "FAIL: function pointer size mismatch for %s\n", name);
        return NULL;
    }
    memcpy(function_storage, &symbol, function_size);
    return symbol;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "./libaster_cabi.so";
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        fprintf(stderr, "FAIL: dlopen(%s): %s\n", path, dlerror());
        return 2;
    }

    aster_unary_fn aster_abs = NULL;
    aster_eight_fn aster_sum8 = NULL;
    aster_eight_fn aster_mix8 = NULL;
    aster_twelve_fn aster_sum12 = NULL;
    aster_twelve_fn aster_mix12 = NULL;
    aster_nullary_fn aster_call_sum12 = NULL;
    if (!load_symbol(handle, "aster_abs", &aster_abs, sizeof(aster_abs)) ||
        !load_symbol(handle, "aster_sum8", &aster_sum8, sizeof(aster_sum8)) ||
        !load_symbol(handle, "aster_mix8", &aster_mix8, sizeof(aster_mix8)) ||
        !load_symbol(handle, "aster_sum12", &aster_sum12, sizeof(aster_sum12)) ||
        !load_symbol(handle, "aster_mix12", &aster_mix12, sizeof(aster_mix12)) ||
        !load_symbol(handle, "aster_call_sum12", &aster_call_sum12, sizeof(aster_call_sum12))) {
        dlclose(handle);
        return 3;
    }

    const int abs_a = aster_abs(-42);
    const int abs_b = aster_abs(7);
    const int sum = aster_sum8(1, 2, 3, 4, 5, 6, 7, 8);
    const int mix = aster_mix8(80, 7, 6, 5, 4, 3, 2, 1);
    const int sum12 = aster_sum12(1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12);
    const int mix12 = aster_mix12(100, 9, 8, 7, 6, 5, 4, 3, 2, 1, 10, 11);
    const int nested_sum12 = aster_call_sum12();
    printf("aster_abs(-42)=%d\naster_abs(7)=%d\n", abs_a, abs_b);
    printf("aster_sum8(1..8)=%d\naster_mix8(80,7,6,5,4,3,2,1)=%d\n", sum, mix);
    printf("aster_sum12(1..12)=%d\naster_mix12(100,9,8,7,6,5,4,3,2,1,10,11)=%d\n", sum12, mix12);
    printf("aster_call_sum12()=%d\n", nested_sum12);

    if (abs_a != 42 || abs_b != 7 || sum != 36 || mix != 76 || sum12 != 78 || mix12 != 94 || nested_sum12 != 78) {
        fprintf(stderr, "FAIL: C ABI argument/result mismatch\n");
        dlclose(handle);
        return 4;
    }
    if (dlclose(handle) != 0) {
        fprintf(stderr, "FAIL: dlclose: %s\n", dlerror());
        return 5;
    }
    puts("PASS: C -> Aster i32 exports and Aster -> Aster 12-argument stack call");
    puts("PASS: Aster -> Android libc abs(int)");
    return 0;
}
