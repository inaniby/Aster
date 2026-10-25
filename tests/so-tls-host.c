/* v0.23.52-dev test host: dlopen an Aster-generated shared object that carries
 * thread-local storage, then call one exported function from three threads and
 * check that each thread sees its own copy of the block.
 *
 * This is the witness a structural check cannot give. readelf can show that the
 * .so has a PT_TLS segment, a .tbss section and one R_AARCH64_TLS_TPREL64 per
 * variable; only the real loader can show that every thread gets a fresh copy
 * of .tdata's initializers and a zeroed .tbss, which is what those bytes mean.
 *
 * Build for the target architecture, e.g.
 *   aarch64-linux-gnu-gcc -O2 -o so-tls-host tests/so-tls-host.c -ldl -lpthread
 * Usage: so-tls-host <lib.so> <symbol> <first> <second>
 *
 * The host calls <symbol> twice on the main thread and twice in each of two
 * pthreads; every one of those six calls must return <first> then <second>. A
 * shared block would make the later threads continue where the main thread left
 * off (36, 39, ...), and a .tbss that was not zeroed per thread would show up
 * as a constant error in all six.
 */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

static int (*fn)(void);
static int want_first, want_second;
static int failures = 0;

static void *thread_body(void *arg) {
    long id = (long)arg;
    int a = fn(), b = fn();
    printf("thread %ld: first=%d second=%d\n", id, a, b);
    if (a != want_first || b != want_second) {
        printf("thread %ld: expected %d then %d\n", id, want_first, want_second);
        failures++;
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr, "usage: so-tls-host <lib.so> <symbol> <first> <second>\n");
        return 2;
    }
    want_first = atoi(argv[3]);
    want_second = atoi(argv[4]);
    void *h = dlopen(argv[1], RTLD_NOW);
    if (!h) { printf("dlopen failed: %s\n", dlerror()); return 2; }
    fn = (int (*)(void))dlsym(h, argv[2]);
    if (!fn) { printf("dlsym failed: %s\n", dlerror()); return 3; }

    int a = fn(), b = fn();
    printf("main: first=%d second=%d\n", a, b);
    if (a != want_first || b != want_second) {
        printf("main: expected %d then %d\n", want_first, want_second);
        failures++;
    }
    /* And once more on the main thread: a third call must not see a fresh
     * block either — it continues this thread's own state. */
    int c = fn();
    printf("main: third=%d (expected %d)\n", c, want_second + (want_second - want_first));
    if (c != want_second + (want_second - want_first)) failures++;

    pthread_t t1, t2;
    if (pthread_create(&t1, NULL, thread_body, (void *)1L) != 0) { printf("pthread_create failed\n"); return 5; }
    if (pthread_create(&t2, NULL, thread_body, (void *)2L) != 0) { printf("pthread_create failed\n"); return 5; }
    pthread_join(t1, NULL);
    pthread_join(t2, NULL);

    dlclose(h);
    if (failures) { printf("FAILED: %d thread(s) saw the wrong TLS state\n", failures); return 1; }
    printf("PASS: every thread got its own block (%d then %d)\n", want_first, want_second);
    return 0;
}
