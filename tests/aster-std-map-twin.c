/* tests/aster-std-map-twin.c — the C twin of tests/stdlib-map-demo.ast.
 * Its own open-addressing table (same probing rule) and qsort; the summary
 * line must come out byte for byte the same. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct { char *key; void *val; } Slot;

static Slot *table;
static size_t cap = 8, used = 0;

static void init_map(size_t want) {
    while (cap < want) cap *= 2;
    table = calloc(cap, sizeof(Slot));
}

static size_t hash_of(const char *s) {
    unsigned long long h = 14695981039346656037ULL;
    while (*s) { h ^= (unsigned char)*s++; h *= 1099511628211ULL; }
    return (size_t)h;
}

/* 1 when the key is new, 0 when it replaced a value */
static int put(const char *key, void *val) {
    if (!table) init_map(8);
    if ((used + 1) * 2 > cap) {
        Slot *old = table; size_t oldcap = cap;
        cap *= 2; table = calloc(cap, sizeof(Slot)); used = 0;
        for (size_t i = 0; i < oldcap; i++)
            if (old[i].key) { put(old[i].key, old[i].val); }
        free(old);
    }
    size_t mask = cap - 1, i = hash_of(key) & mask;
    while (table[i].key) {
        if (strcmp(table[i].key, key) == 0) { table[i].val = val; return 0; }
        i = (i + 1) & mask;
    }
    table[i].key = strdup(key);
    table[i].val = val;
    used++;
    return 1;
}

static void *get(const char *key) {
    if (!table || used == 0) return NULL;
    size_t mask = cap - 1, i = hash_of(key) & mask;
    while (table[i].key) {
        if (strcmp(table[i].key, key) == 0) return table[i].val;
        i = (i + 1) & mask;
    }
    return NULL;
}

static int cmp_i32_asc(const void *a, const void *b) {
    int x = *(const int *)a, y = *(const int *)b;
    return (x > y) - (x < y);
}
static int cmp_desc(const void *a, const void *b) { return cmp_i32_asc(b, a); }
static int cmp_i64_asc(const void *a, const void *b) {
    long long x = *(const long long *)a, y = *(const long long *)b;
    return (x > y) - (x < y);
}
static int cmp_u8_asc(const void *a, const void *b) {
    int x = *(const unsigned char *)a, y = *(const unsigned char *)b;
    return (x > y) - (x < y);
}
static int cmp_str_asc(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

int main(void) {
    int ok = 0;
    static long long cell[8];

    /* 1. the map */
    init_map(4);
    if (put("alpha", &cell[0]) == 1) ok++;
    if (put("beta", &cell[1]) == 1) ok++;
    if (put("alpha", &cell[2]) == 0) ok++;
    if (get("alpha") == &cell[2]) ok++;
    if (get("beta") == &cell[1]) ok++;
    if (get("gamma") == NULL) ok++;
    if (get("gamma") == NULL) ok++;              /* has */
    char k[16];
    for (int i = 0; i < 200; i++) {
        snprintf(k, sizeof k, "%d", i);
        if (put(k, &cell[3]) != 1) { printf("put failed\n"); return 3; }
    }
    int count = (int)used;
    if (count == 202) ok++;
    if (get("137") == &cell[3] && get("alpha") == &cell[2]) ok++;

    /* 2. the typed sorts */
    int a[5] = {5, -3, 9, 0, 2};
    qsort(a, 5, sizeof a[0], cmp_i32_asc);
    if (a[0] == -3 && a[4] == 9) ok++;
    long long l[4] = {5000000000LL, -1LL, 7LL, 0LL};
    qsort(l, 4, sizeof l[0], cmp_i64_asc);
    if (l[0] == -1 && l[3] == 5000000000LL) ok++;
    unsigned char u[4] = {200, 3, 255, 0};
    qsort(u, 4, sizeof u[0], cmp_u8_asc);
    if (u[0] == 0 && u[3] == 255) ok++;
    const char *names[3] = {"pear", "apple", "fig"};
    qsort(names, 3, sizeof names[0], cmp_str_asc);
    if (strcmp(names[0], "apple") == 0) ok++;
    if (strcmp(names[2], "pear") == 0) ok++;

    /* 3. the general form */
    int d[4] = {1, 4, 2, 3};
    qsort(d, 4, sizeof d[0], cmp_desc);
    if (d[0] == 4 && d[3] == 1) ok++;
    int pairs[6] = {2, 20, 1, 10, 3, 30};
    qsort(pairs, 3, 8, cmp_i32_asc);
    if (pairs[0] == 1 && pairs[1] == 10 && pairs[2] == 2 && pairs[3] == 20 && pairs[4] == 3) ok++;

    printf("%d|%d|%d|%d|%d|%d|%d\n", ok, count, a[0], a[4], u[3], (unsigned char)names[0][0], d[0]);
    return ok == 16 ? 0 : 1;
}
