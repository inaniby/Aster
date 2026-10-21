/* Runtime negative tests for missing DT_NEEDED libraries and unresolved imports. */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <shared-object> <expected-error-substring>\n", argv[0]);
        return 2;
    }
    (void)dlerror();
    void *handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (handle) {
        dlclose(handle);
        printf("FAIL: dlopen unexpectedly accepted %s\n", argv[1]);
        return 1;
    }
    const char *error = dlerror();
    if (!error || !*error) {
        printf("FAIL: dlopen failed without a diagnostic for %s\n", argv[1]);
        return 1;
    }
    printf("loader diagnostic: %s\n", error);
    if (strstr(error, argv[2]) == NULL) {
        printf("FAIL: expected loader diagnostic to mention '%s'\n", argv[2]);
        return 1;
    }
    printf("PASS: dlopen rejects %s with a diagnostic mentioning %s\n", argv[1], argv[2]);
    return 0;
}
