/* Validate that a DT_NEEDED dependency stays loaded while its importer lives,
 * even after the dependency's explicit dlopen handle is closed. Run this mode
 * in a fresh process so final-close/reload state checks are deterministic. */
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef int (*fn0)(void);
static fn0 get_fn(void *h, const char *name) {
    (void)dlerror();
    void *raw = dlsym(h, name);
    fn0 fn = NULL;
    memcpy(&fn, &raw, sizeof(fn));
    const char *err = dlerror();
    if (err) fprintf(stderr, "FAIL: dlsym(%s): %s\n", name, err);
    return err ? NULL : fn;
}
static int check(const char *label, int got, int expected) {
    if (got != expected) {
        fprintf(stderr, "FAIL: %s got=%d expected=%d\n", label, got, expected);
        return 0;
    }
    printf("PASS: %s = %d\n", label, got);
    return 1;
}
int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <dependency.so> <importer.so>\n", argv[0]);
        return 2;
    }
    int ok = 1;
    void *dep = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!dep) { fprintf(stderr, "FAIL: dlopen dependency: %s\n", dlerror()); return 1; }
    fn0 dep_value = get_fn(dep, "value");
    fn0 dep_bump = get_fn(dep, "bump");
    if (!dep_value || !dep_bump) { dlclose(dep); return 1; }
    ok &= check("dependency initial state through direct handle", dep_value(), 5);

    void *client = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (!client) { fprintf(stderr, "FAIL: dlopen importer with DT_NEEDED dependency: %s\n", dlerror()); dlclose(dep); return 1; }
    fn0 read_counter = get_fn(client, "read_counter");
    fn0 bump_counter = get_fn(client, "bump_counter");
    fn0 call_add = get_fn(client, "call_add");
    if (!read_counter || !bump_counter || !call_add) { dlclose(client); dlclose(dep); return 1; }
    puts("PASS: importer loaded with its DT_NEEDED dependency");
    ok &= check("importer reads dependency global", read_counter(), 5);
    ok &= check("importer mutates dependency global", bump_counter(), 6);
    ok &= check("direct dependency handle observes importer mutation", dep_value(), 6);

    if (dlclose(dep) != 0) {
        fprintf(stderr, "FAIL: close explicit dependency handle: %s\n", dlerror());
        dlclose(client); return 1;
    }
    puts("PASS: explicit dependency handle closed while importer remains loaded");
    ok &= check("importer still reads dependency after direct handle close", read_counter(), 6);
    ok &= check("importer still calls dependency after direct handle close", call_add(), 42);
    ok &= check("importer still mutates dependency after direct handle close", bump_counter(), 7);

    if (dlclose(client) != 0) { fprintf(stderr, "FAIL: close importer final reference: %s\n", dlerror()); return 1; }
    puts("PASS: importer final handle closed");
    client = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (!client) { fprintf(stderr, "FAIL: reload importer after final close: %s\n", dlerror()); return 1; }
    read_counter = get_fn(client, "read_counter");
    if (!read_counter) { dlclose(client); return 1; }
    ok &= check("dependency state reset after importer final close and reload", read_counter(), 5);
    if (dlclose(client) != 0) { fprintf(stderr, "FAIL: cleanup reload handle: %s\n", dlerror()); return 1; }
    if (!ok) return 1;
    puts("PASS: DT_NEEDED dependency lifetime follows importer reference and resets after final unload");
    return 0;
}
