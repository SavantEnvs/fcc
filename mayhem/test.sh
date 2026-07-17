#!/usr/bin/env bash
# fcc/mayhem/test.sh — RUN fcc's OWN test suite (the Makefile `tests` target) against the normal-flags
# fcc that mayhem/build.sh produced → CTRF. PATCH-grade oracle: it never compiles fcc itself.
#
# fcc's `make tests` is a KNOWN-ANSWER / behavioral suite:
#   * bin/tests/xor-list, bin/tests/hashset — fcc COMPILES, ASSEMBLES (cc -m32), LINKS and RUNS each
#     program; the program exercises real codegen (a 100k-insert hashset, an xor-linked list) and must
#     exit 0. A no-op / exit(0) "patch" emits empty/wrong assembly → the assemble/link/run step fails →
#     the test fails. It asserts the compiler PRODUCES A WORKING PROGRAM, not merely that fcc exits 0.
#   * bin/tests/xor-list-error.txt — fcc must REJECT malformed C with exit 1 (Makefile asserts `[ $? -eq 1 ]`).
# Needs a 32-bit assemble/link toolchain (gcc-multilib + libc6-dev-i386, installed in mayhem/Dockerfile)
# because fcc targets x86-32 and shells out to `cc -m32` to assemble/link the test programs.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/build-tests/fcc"
[ -x "$BIN" ] || { echo "missing $BIN — run mayhem/build.sh first" >&2; exit 2; }

# The Makefile's default test set: TOUT = xor-list hashset xor-list-error.txt → 3 named tests. We drive
# `make tests` with FCC pointed at the normal-flags oracle binary and VALGRIND disabled (not needed for
# the behavioral oracle; valgrind on a 32-bit target isn't guaranteed in the base). The target rebuilds
# each bin/tests/* from scratch and FAILS the make if any test program fails to compile/link/run or if
# the error test isn't rejected. We run each test individually so a clean failure count maps to CTRF.
TESTS="xor-list hashset xor-list-error.txt"
passed=0; failed=0
mkdir -p bin/tests
for t in $TESTS; do
  rm -f "bin/tests/$t"
  if make -s VALGRIND= FCC="$BIN" "bin/tests/$t" >/tmp/fcc-test-$t.log 2>&1; then
    echo "PASS $t"; passed=$((passed+1))
  else
    echo "FAIL $t"; tail -15 "/tmp/fcc-test-$t.log"; failed=$((failed+1))
  fi
done

emit_ctrf "fcc-make-tests" "$passed" "$failed"
