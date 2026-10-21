// copy-twin.c — C twin of examples/copy.ast.
//
// The same stdin-to-stout copy in 256-byte chunks the example performs, on the
// same raw Linux system calls (read(2)/write(2)/close(2)), so an AArch64
// aarch64-linux-gnu-gcc build of this file is the independent oracle for the
// v0.23.40-dev syscall intrinsics. Built and run by tests/syscall-io-checks.sh.
#include <unistd.h>

static unsigned char buf[256];

int main(void) {
    long n = read(0, buf, 256);
    while (n > 0) {
        write(1, buf, n);
        n = read(0, buf, 256);
    }
    close(0);
    close(1);
    return 0;
}
