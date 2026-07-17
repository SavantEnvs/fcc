#!/usr/bin/env bash
# fcc/mayhem/build.sh — build Fedjmike's C compiler (fcc) as the fuzz target, plus a clean
# normal-flags build for fcc's own test suite (mayhem/test.sh).
#
# fcc is a small self-hosting C compiler: `make` builds `bin/release/fcc`, the binary that runs the
# whole C FRONT END (lexer, preprocessor/`using`, parser, analyzer, type checking) and the x86 code
# emitter. By default it then shells out to the system `cc` to ASSEMBLE+LINK the emitted .s into an
# executable. For fuzzing we drive ONLY the front end + codegen: `fcc -S <input>` compiles a C source
# to assembly and STOPS (modeNoAssemble) — it never invokes cc/as/ld — so the fuzz target needs no
# assembler/linker/multilib toolchain. That whole in-process pipeline is the fuzz surface.
#
# The Mayhem target is FILE-INPUT (CLI): `/mayhem/fcc -S @@` runs the compiler on the fuzz bytes as a
# C source file. No libFuzzer harness — the natural fuzz surface is the compiler itself on a source file.
#
# Two builds from the same in-tree Makefile (config.h/objs live in obj/$CONFIG), done sequentially:
#   (1) NORMAL-flags build -> build-tests/fcc   (honest oracle for test.sh; no sanitizer noise)
#   (2) SANITIZED build     -> /mayhem/fcc        (the fuzz target; project built WITH $SANITIZER_FLAGS)
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty value
# (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (the compiler's natural crash). fcc has
# no external libs to link, so the empty-sanitizer build links cleanly with no extra flags.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer -g}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX MAYHEM_JOBS

cd "$SRC"

# fcc's Makefile sets a long -Werror-free warning wall in CFLAGS via `+=`; passing CFLAGS on the make
# command line overrides ALL of it (and the per-config -O3), so we supply the flags fcc needs:
#   -std=c11           the dialect fcc is written in
#   -include defaults.h  the generated arch defaults the sources expect (Makefile adds this; we keep it)
#   -Wno-error -w        fcc's clean build is warning-heavy under clang; warnings don't affect codegen
# We compile (CFLAGS) and link (LDFLAGS) with the same flags so the sanitizer runtime is linked in.
#
# BENIGN UBSan RELAX (shift + signed-integer-overflow + function): fcc's symbol/keyword interning hashes
# every identifier with Jenkins' one-at-a-time hash (src/hashmap.c hashstr), whose `hash += hash << 10` /
# `hash << 3` deliberately overflow a signed intptr_t on essentially EVERY input — even the empty file.
# SEPARATELY, fcc's generic hashmap (src/hashmap.c) stores hash/compare/destructor callbacks as generic
# function pointers and CALLS them through typedef'd signatures that don't exactly match the concrete
# functions (e.g. hashint via `long(*)(const char*,int)`, parserResultDestroy via `void(*)(void*)`).
# That trips `-fsanitize=function` on EVERY input — including a perfectly valid .c program — so under
# halting UBSan even a valid compile aborts with exit 1, leaving Mayhem with ZERO passing test cases.
# We relax ONLY `shift`, `signed-integer-overflow` and `function` for the FUZZ build, keeping ASan
# (heap/stack/global overflow, UAF) and the REST of UBSan on and halting. (Cohort precedent for a narrow
# per-check relax: hh-suite signed-integer-overflow, swftools shift, genometools function.) The TEST
# build uses normal flags.
COMMON_CFLAGS="-std=c11 -include defaults.h -Wno-error -w -O2 $DEBUG_FLAGS"

# ---------------------------------------------------------------------------
# (1) TEST build — fcc's normal flags, NO sanitizer. Produces the oracle binary that mayhem/test.sh
#     drives via `make tests` (compile+assemble+link+run fcc's checked-in C programs and the error
#     known-answer test). Built first, stashed, then the tree is cleaned for the sanitized build
#     (the Makefile is in-tree, so the two builds can't share one objdir).
# ---------------------------------------------------------------------------
make clean >/dev/null 2>&1 || true
rm -f defaults.h
make CONFIG=release CC="$CC" CFLAGS="$COMMON_CFLAGS" -j"$MAYHEM_JOBS"
mkdir -p "$SRC/build-tests"
cp -f bin/release/fcc "$SRC/build-tests/fcc"

# ---------------------------------------------------------------------------
# (2) FUZZ build — the PROJECT itself compiled WITH $SANITIZER_FLAGS so the fuzzed code is instrumented
#     (ASan + UBSan, halting, minus the two benign hash checks above). /mayhem/fcc is the file-input
#     Mayhem target. LeakSanitizer stays ON: fcc tears down its config/compiler state on exit
#     (configDestroy/compilerEnd), so it does NOT leak per-input — no detect_leaks=0 needed.
# ---------------------------------------------------------------------------
FUZZ_SAN="$SANITIZER_FLAGS"
if printf '%s' "$SANITIZER_FLAGS" | grep -q undefined; then
  FUZZ_SAN="$SANITIZER_FLAGS -fno-sanitize=shift,signed-integer-overflow,function"
fi
make clean >/dev/null 2>&1 || true
rm -f defaults.h
make CONFIG=release CC="$CC" \
     CFLAGS="-std=c11 -include defaults.h -Wno-error -w $DEBUG_FLAGS $FUZZ_SAN" \
     LDFLAGS="$FUZZ_SAN" -j"$MAYHEM_JOBS"
cp -f bin/release/fcc /mayhem/fcc

echo "build.sh: built /mayhem/fcc (sanitized fuzz target) and build-tests/fcc (test oracle)"
ls -l /mayhem/fcc "$SRC/build-tests/fcc"
