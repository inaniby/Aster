// Function-level probe for resolveRelocations patch bounds (ELF-P2-5 / S-01).
//
// The linker refuses an out-of-bounds relocation offset while parsing the
// object (parseObject's need=4/8 check), so no .o input can reach
// resolveRelocations with a bad patch: the check this probes is
// defence-in-depth, and the only way to exercise it is to call the function
// directly. The suite builds this file against a copy of src/aster.cpp with
// main() renamed (see tests/linker-checks.sh), so it always tests the real
// function. Each case runs in a forked child:
//   - child exits 0 with "refused" printed  -> the patch was refused cleanly
//   - child dies to ASan / a signal          -> the function touched text[] OOB
//   - child exits 0 with "applied" printed  -> valid patch applied (control)
// Parent exit 0 = every OOB patch refused, valid patch applied.
// Must be built with -fsanitize=address: without it an out-of-bounds read is
// silent and the probe cannot tell a refusal from luck.
#include "aster-harness-src.cpp"
#include <cstdio>
#include <sys/wait.h>
#include <unistd.h>

static int failures = 0;
static bool runCase(const char* name, int id) {
    pid_t pid = fork();
    if (pid == 0) {
        std::map<std::string, uint64_t> vaddr{{"f", 0x400000}, {"tlsvar", 0x1000}};
        std::map<std::string, int> kind{{"f", 0}, {"tlsvar", 4}};
        try {
            if (id == 1) {  // CALL26 patch exactly at end of text
                std::vector<uint8_t> text{0x00, 0x00, 0x00, 0x94};
                resolveRelocations(text, {{4, "f", 0, 283}}, vaddr, kind, 0x400000);
            } else if (id == 2) {  // CALL26 patch 2 bytes before the end
                std::vector<uint8_t> text{0x00, 0x00, 0x00, 0x94};
                resolveRelocations(text, {{2, "f", 0, 283}}, vaddr, kind, 0x400000);
            } else if (id == 3) {  // TLS patch in the last 4 bytes (needs 8)
                std::vector<uint8_t> text{0x00, 0x00, 0x00, 0x94, 0x00, 0x00, 0x00, 0x94};
                resolveRelocations(text, {{4, "tlsvar", 0, 4096}}, vaddr, kind,
                                   0x400000, false, 0x1000);
            } else if (id == 4) {  // TLS patch at UINT64_MAX
                std::vector<uint8_t> text{0x00, 0x00, 0x00, 0x94};
                resolveRelocations(text, {{0xffffffffffffffffULL, "tlsvar", 0, 4096}},
                                   vaddr, kind, 0x400000, false, 0x1000);
            } else {  // valid CALL26 at patch 0 (control)
                std::vector<uint8_t> text{0x00, 0x00, 0x00, 0x94};
                resolveRelocations(text, {{0, "f", 0, 283}}, vaddr, kind, 0x400000);
                std::printf("%s: applied (ins=%02x %02x %02x %02x)\n", name,
                            text[0], text[1], text[2], text[3]);
                _exit(2);  // 2 = applied, expected only for the control
            }
        } catch (const Error& e) {
            std::printf("%s: refused cleanly: %s\n", name, e.what());
            _exit(0);
        }
        std::printf("%s: NOT REFUSED (returned normally)\n", name);
        _exit(3);
    }
    int st = 0;
    waitpid(pid, &st, 0);
    if (id == 5) {
        if (WIFEXITED(st) && WEXITSTATUS(st) == 2) return true;  // control applied
        std::printf("%s: FAIL (control did not apply)\n", name);
        return false;
    }
    if (WIFEXITED(st) && WEXITSTATUS(st) == 0) return true;  // refused cleanly
    // ASan halts with _exit(1) after its report; any other exit means the
    // function returned normally instead of refusing.
    if (WIFEXITED(st) && WEXITSTATUS(st) == 1)
        std::printf("%s: FAIL (ASan report above: out-of-bounds access)\n", name);
    else if (WIFEXITED(st)) std::printf("%s: FAIL (exit %d, not refused)\n", name, WEXITSTATUS(st));
    else if (WIFSIGNALED(st)) std::printf("%s: FAIL (killed by signal %d: OOB access, see report above)\n", name, WTERMSIG(st));
    return false;
}

int main() {
    setvbuf(stdout, NULL, _IONBF, 0);  // children use _exit: no flush
    if (!runCase("H1-call26-at-end", 1)) ++failures;
    if (!runCase("H2-call26-last2", 2)) ++failures;
    if (!runCase("H3-tls-last4", 3)) ++failures;
    if (!runCase("H4-tls-huge", 4)) ++failures;
    if (!runCase("H5-valid-call26", 5)) ++failures;
    if (failures) { std::printf("HARNESS FAIL: %d case(s)\n", failures); return 1; }
    std::printf("HARNESS PASS\n");
    return 0;
}
