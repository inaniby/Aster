/* v0.21.0: inspect real loader page permissions after dlopen(RTLD_NOW).
 * This must run on the target AArch64 Android/Linux system (or through qemu-user).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>

static const char *target_name;
static uintptr_t relro_start, relro_end;
static int found_object;

static int find_relro(struct dl_phdr_info *info, size_t size, void *data) {
    (void)size; (void)data;
    if (!info->dlpi_name || !strstr(info->dlpi_name, target_name)) return 0;
    found_object = 1;
    for (ElfW(Half) i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr) *p = &info->dlpi_phdr[i];
        if (p->p_type == PT_GNU_RELRO) {
            relro_start = (uintptr_t)info->dlpi_addr + p->p_vaddr;
            relro_end = relro_start + p->p_memsz;
            return 1;
        }
    }
    return 1;
}

static int permissions(uintptr_t address, char out[5]) {
    FILE *f = fopen("/proc/self/maps", "r");
    if (!f) return 0;
    char line[512]; unsigned long lo, hi; char perms[5];
    while (fgets(line, sizeof line, f)) {
        if (sscanf(line, "%lx-%lx %4s", &lo, &hi, perms) == 3 &&
            address >= (uintptr_t)lo && address < (uintptr_t)hi) {
            memcpy(out, perms, 5); fclose(f); return 1;
        }
    }
    fclose(f); return 0;
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: %s shared-object\n", argv[0]); return 2; }
    const char *path = argv[1];
    const char *slash = strrchr(path, '/'); target_name = slash ? slash + 1 : path;
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { fprintf(stderr, "FAIL: dlopen: %s\n", dlerror()); return 1; }
    dl_iterate_phdr(find_relro, NULL);
    if (!found_object || relro_end <= relro_start) {
        fprintf(stderr, "FAIL: loader did not expose PT_GNU_RELRO for %s\n", target_name); return 1;
    }
    long page = sysconf(_SC_PAGESIZE);
    if (page <= 0 || relro_start % (uintptr_t)page || relro_end % (uintptr_t)page) {
        fprintf(stderr, "FAIL: RELRO runtime range is not page-aligned: %p-%p\n",
                (void *)relro_start, (void *)relro_end); return 1;
    }
    for (uintptr_t p = relro_start; p < relro_end; p += (uintptr_t)page) {
        char perms[5] = {0};
        if (!permissions(p, perms)) { fprintf(stderr, "FAIL: no mapping for RELRO page %p\n", (void *)p); return 1; }
        if (perms[1] == 'w') { fprintf(stderr, "FAIL: RELRO page %p remains writable (%s)\n", (void *)p, perms); return 1; }
    }
    puts("PASS: Android/Linux loader mapped every PT_GNU_RELRO page read-only after eager relocation");

    int *counter = (int *)dlsym(h, "counter");
    void *bump_sym = dlsym(h, "bump");
    void *value_sym = dlsym(h, "value");
    int (*bump)(void) = NULL;
    int (*value)(void) = NULL;
    if (sizeof bump != sizeof bump_sym || sizeof value != sizeof value_sym) {
        fprintf(stderr, "FAIL: function/data pointer sizes differ on this platform\n"); return 1;
    }
    memcpy(&bump, &bump_sym, sizeof bump);
    memcpy(&value, &value_sym, sizeof value);
    if (!counter || !bump || !value) { fprintf(stderr, "FAIL: exported counter/bump/value missing: %s\n", dlerror()); return 1; }
    char perms[5] = {0};
    if (!permissions((uintptr_t)counter, perms) || perms[1] != 'w') {
        fprintf(stderr, "FAIL: ordinary exported .data counter is not writable (%s)\n", perms); return 1;
    }
    if (*counter != 5 || value() != 5 || bump() != 6 || *counter != 6) {
        fprintf(stderr, "FAIL: writable global behavior broke across dlopen/relocations\n"); return 1;
    }
    puts("PASS: ordinary .data global remains writable and PLT/GOT-backed code reads/writes it");
    dlclose(h);
    return 0;
}
