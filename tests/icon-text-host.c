/* v0.23.7-dev demo host: dlopen the Aster-built shared object for
 * examples/icon_text_demo.ast and ask it to draw into a caller-supplied
 * RGBA8888 buffer, then write that buffer out as a PPM.
 *
 * The pixels in the output are Aster's own: this host supplies the memory and
 * the file format, nothing else. dlopen is RTLD_LAZY because the object also
 * imports ANativeWindow_* and __android_log_print, which do not exist here and
 * are never called on this path.
 *
 *   aarch64-linux-gnu-gcc -O1 -o icon-text-host tests/icon-text-host.c -ldl
 *   ./icon-text-host libicontext.so 360 640 out.ppm
 */
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "./libicontext.so";
    int w = argc > 2 ? atoi(argv[2]) : 360;
    int h = argc > 3 ? atoi(argv[3]) : 640;
    const char *out = argc > 4 ? argv[4] : "preview.ppm";

    void *handle = dlopen(path, RTLD_LAZY);
    if (!handle) { fprintf(stderr, "dlopen failed: %s\n", dlerror()); return 2; }

    /* DT_INIT_ARRAY runs on dlopen, so the @embed globals already hold their
     * addresses by the time we get here.
     *
     * The result of dlsym is assigned through a void* lvalue rather than cast:
     * ISO C forbids converting an object pointer to a function pointer, which
     * -Wpedantic is right to reject even though every POSIX platform does it. */
    int (*render)(void *, int, int, int) = 0;
    *(void **)(&render) = dlsym(handle, "render_rgba");
    if (!render) { fprintf(stderr, "dlsym render_rgba failed: %s\n", dlerror()); return 3; }

    unsigned char *buf = calloc((size_t)w * (size_t)h, 4);
    if (!buf) { fprintf(stderr, "out of memory\n"); return 4; }

    /* Start from opaque magenta: anything Aster fails to write stays visible
     * as magenta instead of looking like a correct black background. */
    for (long i = 0; i < (long)w * h; ++i) {
        buf[i * 4 + 0] = 255; buf[i * 4 + 1] = 0;
        buf[i * 4 + 2] = 255; buf[i * 4 + 3] = 255;
    }

    render(buf, w, h, w);

    FILE *f = fopen(out, "wb");
    if (!f) { fprintf(stderr, "cannot open %s\n", out); return 5; }
    fprintf(f, "P6\n%d %d\n255\n", w, h);
    for (long i = 0; i < (long)w * h; ++i)
        fwrite(buf + i * 4, 1, 3, f);
    fclose(f);

    printf("rendered %dx%d -> %s\n", w, h, out);
    free(buf);
    dlclose(handle);
    return 0;
}
