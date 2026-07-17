/* Mayhem driver for fcc: gives the input a path whose hash is never slot 0 before fcc runs.
 *
 * fcc keys its module table (src/hashmap.c) on the input path and, when that path hashes to slot 0 of
 * the still-empty table, calls strcmp(NULL, path) in generalmapIsMatch. Mayhem hands the input over as
 * @@ under a different path every time, so ~1 in 1024 executions of ANY input (valid ones included)
 * crashed depending only on the file name. Here the input is copied to a fresh "in<N>.c" (N chosen so
 * the name's hash is safe) and fcc is pointed at that copy; its assembly output (in<N>.s) lands beside
 * the copy, in a directory we can write (the @@ directory may be read-only, where fcc then crashed on
 * every input that compiled). */
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

int fcc_main (int argc, char** argv);

/* Leak detection stays off at build time (fleet policy); ASan and UBSan stay on. */
int __lsan_is_turned_off (void) {
    return 1;
}

/* Same hash as hashstr() in src/hashmap.c, masked to the largest module table we could see (4096). */
static int hashIsSafe (const char* key) {
    intptr_t hash = 0;

    for (int i = 0; key[i]; i++) {
        hash += (signed char) key[i];
        hash += (intptr_t) ((uintptr_t) hash << 10);
        hash ^= hash >> 6;
    }

    hash += (intptr_t) ((uintptr_t) hash << 3);
    hash ^= hash >> 11;
    hash += (intptr_t) ((uintptr_t) hash << 15);

    return (hash & 4095) != 0;
}

static char copyPath[PATH_MAX];
static char asmPath[PATH_MAX];

static void cleanup (void) {
    unlink(copyPath);
    unlink(asmPath);
}

/* ASan/UBSan abort without running atexit hooks; their death callback is the one place left to clean up. */
void __sanitizer_set_death_callback (void (*callback) (void)) __attribute__((weak));

static int copyInput (const char* src, const char* dir) {
    int in = open(src, O_RDONLY);

    if (in < 0)
        return 0;

    for (int n = (int) getpid(), tries = 0; tries < 64; n++, tries++) {
        snprintf(copyPath, sizeof copyPath, "%sin%d.c", dir, n);

        if (!hashIsSafe(copyPath))
            continue;

        int out = open(copyPath, O_WRONLY | O_CREAT | O_EXCL, 0600);

        if (out < 0)
            continue;

        char buf[4096];
        ssize_t got;
        int ok = 1;

        while (ok && (got = read(in, buf, sizeof buf)) > 0)
            for (ssize_t done = 0, put; done < got; done += put)
                if ((put = write(out, buf + done, (size_t) (got - done))) <= 0) {
                    ok = 0;
                    break;
                }

        close(out);
        close(in);

        if (!ok) {
            unlink(copyPath);
            return 0;
        }

        snprintf(asmPath, sizeof asmPath, "%sin%d.s", dir, n);
        return 1;
    }

    close(in);
    return 0;
}

int main (int argc, char** argv) {
    int input = -1;

    for (int i = 1; i < argc && input < 0; i++) {
        struct stat st;

        if (argv[i][0] != '-' && stat(argv[i], &st) == 0 && S_ISREG(st.st_mode))
            input = i;
    }

    if (input >= 0) {
        const char* tmp = getenv("TMPDIR");
        char tmpDir[PATH_MAX];
        snprintf(tmpDir, sizeof tmpDir, "%s/", tmp && tmp[0] ? tmp : "/tmp");

        if (copyInput(argv[input], "") || copyInput(argv[input], tmpDir)) {
            argv[input] = copyPath;
            atexit(cleanup);

            if (__sanitizer_set_death_callback)
                __sanitizer_set_death_callback(cleanup);
        }
    }

    return fcc_main(argc, argv);
}
