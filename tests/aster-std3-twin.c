/* tests/aster-std3-twin.c — the C twin of tests/stdlib3-demo.ast. Same lines,
 * printed with printf's "%.*f", so a divergence in the library's rounding,
 * padding, sign or inf/nan spelling shows up as a byte difference. */
#include <stdio.h>
#include <string.h>

int main(void) {
    int ok = 0;
    char b[64], c[64];

    snprintf(b, sizeof b, "%.2f", 3.14159);
    if (strcmp(b, "3.14") == 0) ok++;
    printf("%s\n", b);

    snprintf(b, sizeof b, "%.1f", -2.718);
    if (strcmp(b, "-2.7") == 0) ok++;
    printf("%s\n", b);

    snprintf(b, sizeof b, "%.0f", 2.6);
    if (strcmp(b, "3") == 0) ok++;
    printf("%s\n", b);

    snprintf(b, sizeof b, "%.3f", 100.0);
    if (strlen(b) == 7) ok++;
    printf("%s\n", b);

    snprintf(b, sizeof b, "%.1f", 0.5);
    if (strcmp(b, "0.5") == 0) ok++;
    printf("%s\n", b);

    snprintf(b, sizeof b, "%.9f", 1.0 / 3.0);
    printf("%s\n", b);

    snprintf(c, sizeof c, "%.9f", 0.125);        /* the clamp: 99 -> 9 digits */
    if (strlen(c) == 11) ok++;                    /* "0.125000000" */
    printf("%s\n", c);

    snprintf(b, sizeof b, "%.2f", 0.5);
    if (strlen(b) == 4) ok++;
    printf("%s\n", b);

    snprintf(b, sizeof b, "%.6f", (float)(1.0f / 3.0f));
    printf("%s\n", b);

    snprintf(b, sizeof b, "%.2f", 1.0 / 0.0);
    if (strcmp(b, "inf") == 0) ok++;
    printf("%s\n", b);

    snprintf(b, sizeof b, "%.2f", 0.0 / 0.0);
    if (strcmp(b, "nan") == 0) ok++;
    printf("%s\n", b);

    int n = snprintf(b, sizeof b, "%d and %.2f", -7, 0.75);
    printf("%s\n", b);
    if (n == 11) ok++;

    printf("checks %d\n", ok);
    return ok == 10 ? 0 : 1;
}
