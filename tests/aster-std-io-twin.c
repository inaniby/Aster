/* tests/aster-std-io-twin.c — the C twin of tests/stdlib-io-demo.ast.
 * Same file operations through POSIX, same buffer and vector arithmetic, same
 * summary line; the suite diffs the two outputs byte for byte. */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

int main(void) {
    int ok = 0;
    const char *msg = "hello, library\n";

    /* 1. write, measure, read back */
    int fd = open("io-demo.txt", O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) ok++;
    ssize_t wrote = 0;
    while (wrote < 15) {
        ssize_t w = write(fd, msg + wrote, (size_t)(15 - wrote));
        if (w <= 0) { wrote = -1; break; }
        wrote += w;
    }
    close(fd);
    if (wrote == 15) ok++;
    struct stat st;
    long size = stat("io-demo.txt", &st) == 0 ? (long)st.st_size : -1;
    if (size == 15) ok++;
    char text[64];
    memset(text, 0, sizeof text);
    fd = open("io-demo.txt", O_RDONLY);
    ssize_t got = read(fd, text, sizeof text - 1);
    close(fd);
    if (got == 15) ok++;
    if (strlen(text) == 15) ok++;
    if (access("io-demo-missing.txt", F_OK) != 0) ok++;

    /* 2. a buffer: the demo appends "abc=", then '1', then 2345 */
    char buf[64];
    size_t blen = 0;
    snprintf(buf, sizeof buf, "abc=%d", 12345);
    blen = strlen(buf);
    if (blen == 9) ok++;

    /* 3. vectors */
    int v[100];
    for (int i = 0; i < 100; i++) v[i] = i * 3;
    if (v[99] == 297 && v[1] == 3) ok++;
    const void *pv[2] = { text, text };
    if (pv[1] == text) ok++;

    /* 4. a big allocation and a copy */
    static unsigned char big[200000];
    if (big != NULL) ok++;
    big[199999] = 'B';
    if (big[199999] == 'B') ok++;
    unsigned char src[3] = {'A', 'B', 'C'};
    unsigned char copy[64];
    memcpy(copy, src, 3);
    if (copy[0] == 'A' && copy[2] == 'C') ok++;

    printf("%d|%d|%d|%d\n", ok, (int)size, (int)blen, v[99]);
    return ok == 12 ? 0 : 1;
}
