/* v0.17.0 test host: load a static PIE (ET_DYN executable, no PT_INTERP) at a base chosen by this
 * process and jump into it. The image terminates the process itself through syscall 93, so this
 * host exits with the PIE's exit status. Running the same image at several unrelated bases proves
 * that no instruction depends on the link-time address.
 *
 * Build for the target architecture, e.g.
 *   aarch64-linux-gnu-gcc -O1 -o pie-loader tests/pie-loader.c
 */
#define _GNU_SOURCE
#include <elf.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: pie-loader <pie>\n"); return 2; }
    int fd = open(argv[1], O_RDONLY);
    if (fd < 0) { perror("open"); return 2; }
    off_t sz = lseek(fd, 0, SEEK_END);
    lseek(fd, 0, SEEK_SET);
    unsigned char *buf = malloc((size_t)sz);
    if (!buf || read(fd, buf, (size_t)sz) != sz) { perror("read"); return 2; }
    close(fd);
    Elf64_Ehdr *eh = (Elf64_Ehdr *)buf;
    if (memcmp(eh->e_ident, ELFMAG, 4) != 0 || eh->e_type != ET_DYN) {
        fprintf(stderr, "pie-loader: not an ET_DYN image\n");
        return 2;
    }
    Elf64_Phdr *ph = (Elf64_Phdr *)(buf + eh->e_phoff);
    uint64_t lo = ~0ull, hi = 0;
    for (int i = 0; i < eh->e_phnum; i++)
        if (ph[i].p_type == PT_LOAD) {
            if (ph[i].p_vaddr < lo) lo = ph[i].p_vaddr;
            if (ph[i].p_vaddr + ph[i].p_memsz > hi) hi = ph[i].p_vaddr + ph[i].p_memsz;
        }
    uint64_t span = (hi - lo + 0xfff) & ~0xfffull;
    uint64_t seed = 0;
    int ur = open("/dev/urandom", O_RDONLY);
    if (ur >= 0) { if (read(ur, &seed, sizeof seed) != (ssize_t)sizeof seed) seed = 0; close(ur); }
    uint64_t base = (0x400000000ull + (seed % 0x4000ull) * 0x10000ull) & ~0xfffull;
    void *map = mmap((void *)base, span, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
    if (map == MAP_FAILED) {
        map = mmap(NULL, span, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (map == MAP_FAILED) { perror("mmap"); return 2; }
        base = (uint64_t)map & ~0xfffull;
    }
    fprintf(stderr, "pie-loader: base=0x%llx span=0x%llx entry=0x%llx\n",
            (unsigned long long)base, (unsigned long long)span, (unsigned long long)(base + eh->e_entry));
    for (int i = 0; i < eh->e_phnum; i++) {
        if (ph[i].p_type != PT_LOAD) continue;
        memcpy((void *)(base + ph[i].p_vaddr), buf + ph[i].p_offset, ph[i].p_filesz);
        memset((void *)(base + ph[i].p_vaddr + ph[i].p_filesz), 0, ph[i].p_memsz - ph[i].p_filesz);
        int prot = 0;
        if (ph[i].p_flags & PF_R) prot |= PROT_READ;
        if (ph[i].p_flags & PF_W) prot |= PROT_WRITE;
        if (ph[i].p_flags & PF_X) prot |= PROT_EXEC;
        uint64_t start = (base + ph[i].p_vaddr) & ~0xfffull;
        uint64_t len = ((ph[i].p_vaddr & 0xfff) + ph[i].p_memsz + 0xfff) & ~0xfffull;
        if (mprotect((void *)start, len, prot) != 0) { perror("mprotect"); return 2; }
    }
    void (*entry)(void) = (void (*)(void))(base + eh->e_entry);
    entry();
    return 3; /* unreachable: the PIE exits through syscall 93 */
}
