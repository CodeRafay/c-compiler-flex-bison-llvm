#!/bin/bash
# Test runner for the compiler. Run it with "make test" (or ./tests/run_tests.sh -v
# to also list the passing tests).
#
# Three kinds of tests:
#   tests/cases/*.txt  small programs: compile, run with lli, check the exit code
#                      (main's return value) and, optionally, what they print
#   tests/errors.txt   wrong programs: the compiler must report the expected
#                      error, exit with 1 and write no output.ll
#   tests/examples.txt the sample programs in testCaseExamples/

cd "$(dirname "$0")/.." || exit 1
ROOT=$(pwd)
COMPILER="$ROOT/compiler"
VERBOSE=0
[ "$1" = "-v" ] && VERBOSE=1

if [ ! -x "$COMPILER" ]; then
    echo "compiler not found; run make first"
    exit 1
fi

# Each test runs in its own empty directory, so output.ll files never mix
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

passed=0
failed=0

pass() {
    passed=$((passed + 1))
    [ $VERBOSE = 1 ] && echo "  PASS  $1"
}

fail() {
    failed=$((failed + 1))
    echo "  FAIL  $1"
    echo "        $2"
}

# Compile $1 in the work directory. Sets compile_rc and leaves the compiler's
# messages in $WORK/log.
compile() {
    rm -f "$WORK/output.ll"
    (cd "$WORK" && timeout 10 "$COMPILER" "$1" > log 2>&1)
    compile_rc=$?
}

# Run the compiled output.ll. Sets run_rc and run_out.
run_program() {
    run_out=$(cd "$WORK" && timeout 10 lli output.ll < /dev/null)
    run_rc=$?
}

# Compare a run against the expected exit code and output ("-" = don't check).
# Expected output is written with \n for newlines; printf '%b' turns them into
# real newlines.
check_run() {
    local name="$1" want_rc="$2" want_out="$3"
    if [ "$run_rc" != "$want_rc" ]; then
        fail "$name" "expected exit $want_rc, got $run_rc"
    elif [ "$want_out" != "-" ] && [ "$run_out" != "$(printf '%b' "$want_out")" ]; then
        fail "$name" "expected output [$want_out], got [$(echo "$run_out" | tr '\n' '|')]"
    else
        pass "$name"
    fi
}

# 1. Programs that must compile and run correctly
for file in tests/cases/*.txt; do
    echo "$(basename "$file" .txt)"
    while IFS='|' read -r want_rc want_out source; do
        case "$want_rc" in ''|'#'*) continue ;; esac
        echo "$source" > "$WORK/test.c"
        compile "$WORK/test.c"
        if [ $compile_rc != 0 ]; then
            fail "$source" "did not compile: $(grep -E 'Error|failed' "$WORK/log" | head -2 | tr '\n' ' ')"
            continue
        fi
        run_program
        check_run "$source" "$want_rc" "$want_out"
    done < "$file"
done

# 2. Programs that must be rejected with an error
echo "errors"
while IFS='|' read -r message source; do
    case "$message" in ''|'#'*) continue ;; esac
    echo "$source" > "$WORK/test.c"
    compile "$WORK/test.c"
    if [ $compile_rc != 1 ]; then
        fail "$source" "expected the compiler to exit with 1, got $compile_rc"
    elif [ -f "$WORK/output.ll" ]; then
        fail "$source" "output.ll was written even though compilation failed"
    elif ! grep -qF "$message" "$WORK/log"; then
        fail "$source" "expected error containing [$message]"
    else
        pass "$source"
    fi
done < tests/errors.txt

# 3. The sample programs
echo "examples"
while IFS='|' read -r name want_compile want_rc want_out; do
    case "$name" in ''|'#'*) continue ;; esac
    compile "$ROOT/testCaseExamples/$name"
    if [ "$compile_rc" != "$want_compile" ]; then
        fail "$name" "expected the compiler to exit with $want_compile, got $compile_rc"
    elif [ "$want_compile" != 0 ]; then
        pass "$name"
    else
        run_program
        check_run "$name" "$want_rc" "$want_out"
    fi
done < tests/examples.txt

echo
echo "$passed passed, $failed failed"
[ $failed = 0 ]
