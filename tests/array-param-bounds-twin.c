/*
 * gcc twin for tests/array-param-bounds-checks.sh [7/9] differential layer.
 *
 * Mirrors the Aster source exactly: a function that takes a fixed-size array
 * parameter and a run-time index, reads through it, and main drives all four
 * slots in range. Aster is compiled with --bounds-check, this with -O2; both
 * must return the same value, which is the whole point of a bounds check that
 * only fires on a genuinely out-of-range index.
 */
int pick(int a[4], int k) { return a[k]; }

int main(void) {
    int arr[4] = {0, 0, 0, 0};
    arr[0] = 3;
    arr[1] = 1;
    arr[2] = 4;
    arr[3] = 1;
    int s = pick(arr, 0) + pick(arr, 1) * pick(arr, 2) - pick(arr, 3);
    return s; /* 3 + 1*4 - 1 == 6 */
}
