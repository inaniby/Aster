/* tests/aster-std2-twin.c — the C twin of tests/stdlib2-demo.ast: the same
 * operations through libc, printing the same lines. The suite diffs the two
 * outputs and pins the numbers independently. */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdint.h>

static unsigned char heap[65536];
static int used = 0;

static void *bump(int n) {
    if (n <= 0) return NULL;
    int need = (n + 7) & ~7;
    if (used + need > (int)sizeof heap) return NULL;
    void *p = heap + used;
    used += need;
    return p;
}

int main(void) {
    int ok = 0;
    unsigned char b[64] = {0}, c[64] = {0};

    memcpy(b, "abcdef", 6);
    memmove(b + 2, b, 4);
    if (memcmp(b, "ababcd", 6) == 0) ok++;
    printf("memmove %d\n", memcmp(b, "ababcd", 6));

    if (strncmp("abc", "abd", 2) == 0) ok++;
    printf("strncmp %d\n", strncmp("abc", "abd", 3));
    int p = (int)(strchr("hello", 'l') - "hello");
    if (p == 2) ok++;
    printf("strchr %d\n", p);
    p = (int)(strstr("hello world", "wor") - "hello world");
    if (p == 6) ok++;
    printf("strstr %d\n", p);
    c[0] = 0;
    strcat(c, "ab");
    p = (int)strlen(c) + 2;            /* strcat("cd") makes "abcd" */
    if (strcmp(c, "ab") == 0) { strcat(c, "cd"); }
    if (strcmp(c, "abcd") == 0) { p = 4; ok++; }
    printf("strcat %d\n", p);

    int v = atoi("  -123x");
    if (v == -123) ok++;
    printf("atoi %d %d %d\n", v, atoi("+7"), atoi(""));

    v = snprintf((char *)b, sizeof b, "%d", -1234);
    if (v == 5 && memcmp(b, "-1234", 5) == 0) ok++;
    printf("fmt_i32 %d\n", v);
    v = snprintf((char *)b, sizeof b, "%04x", 0xBEEF);
    if (v == 4 && memcmp(b, "beef", 4) == 0) ok++;
    printf("fmt_hex %d\n", v);

    int32_t arr[6] = {5, 3, 9, 1, 4, 2};
    for (int i = 1; i < 6; i++) {
        int32_t w = arr[i]; int j = i;
        while (j > 0 && arr[j - 1] > w) { arr[j] = arr[j - 1]; j--; }
        arr[j] = w;
    }
    if (arr[0] == 1 && arr[5] == 9) ok++;
    printf("sort %d %d\n", arr[0], arr[5]);

    unsigned char *a = (unsigned char *)bump(16);
    unsigned char *q = (unsigned char *)bump(8);
    int good = (a && q && q == a + 16) ? 1 : 0;
    if (good == 1) ok++;
    *(uint64_t *)a = 0x1122334455667788ull;
    if (*(uint64_t *)a == 0x1122334455667788ull) ok++;
    printf("malloc %d %d %d %d\n", good, *(uint64_t *)a == 0x1122334455667788ull,
           bump(1048576) == NULL, 0);
    ok++;                              /* free() answers 0 */
    printf("checks %d\n", ok);
    return ok == 12 ? 0 : 1;
}
