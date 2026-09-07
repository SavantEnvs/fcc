/* mayhem/fcc-fuzz.c — ELF file-input shim for the fcc Mayhem target.
 *
 * Why this exists: fcc derives its .s intermediate from the INPUT path
 * (src/options.c:150, filext(input,"s")) and src/asm.c:asmInit() never NULL-checks
 * its fopen(). Mayhem hands `@@` as a path in a directory the target cannot write,
 * so the fopen fails, ctx->file stays NULL, and the first asmOutLn() aborts under
 * UBSan (asm.c:40, "null pointer passed as argument 1") on EVERY input — including
 * trivially valid C. Mayhem then rejects the run outright with "target crashes on
 * every test case in the test suite" and never starts fuzzing.
 *
 * A shell wrapper does not work here: Mayhem requires an ELF target
 * ("Target is not an ELF ... if it is a shell script, please pull out the portion
 * of the file which is a compiled program"), so this is a compiled shim. It copies
 * the testcase into a writable scratch dir and execs fcc, so the traced process is
 * fcc itself and sanitizer aborts/signals still propagate unchanged.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>

int main(int argc, char** argv) {
    if (argc < 2) return 2;
    mkdir("/tmp/fccwork", 0700);

    char dst[256];
    snprintf(dst, sizeof dst, "/tmp/fccwork/in.%d.c", (int) getpid());

    FILE* in = fopen(argv[1], "rb");
    if (!in) return 2;
    FILE* out = fopen(dst, "wb");
    if (!out) { fclose(in); return 2; }

    char buf[65536];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, in)) > 0) {
        if (fwrite(buf, 1, n, out) != n) { fclose(in); fclose(out); return 2; }
    }
    fclose(in);
    if (fclose(out) != 0) return 2;

    execl("/mayhem/fcc", "fcc", "-S", dst, (char*) NULL);
    return 2;
}
