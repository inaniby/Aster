// A host-side stand-in for Android's liblog.so. Aster's build-so links any
// `__android_log*` symbol against liblog.so (src/aster.cpp auto-NEEDED rule),
// exactly as an NDK build does. On a device the real liblog provides
// __android_log_print; under the qemu harness this stub stands in for it,
// printing to stderr so the lifecycle events are observable on the host.
//
// Built for AArch64 by tests/lifecycle-callbacks.sh and placed on
// LD_LIBRARY_PATH so the .so's single PLT import resolves at load time.

#include <stdarg.h>
#include <stdio.h>

int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio;
    va_list ap;
    fprintf(stderr, "[%s] ", tag ? tag : "");
    va_start(ap, fmt);
    vfprintf(stderr, fmt ? fmt : "", ap);
    va_end(ap);
    fputc('\n', stderr);
    return 0;
}
