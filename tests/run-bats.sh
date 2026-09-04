#!/usr/bin/env bash
# tests/run-bats.sh -- the unit suite. The other half of tests/run-gates.sh.
#
# THE TWO LAYERS, AND WHY BOTH
#   tests/check-*.sh read the tree as TEXT and never execute it: they catch two
#   copies of a table disagreeing, a credential on a command line, a path named
#   here that a reader cannot open.
#   THIS runs the code. It sources lib/*.sh, calls the functions and asserts on
#   what comes back -- the only way to catch something written correctly and
#   behaving wrongly.
#   Neither replaces the other. The gates caught a documented exit code the
#   tree did not produce; only execution catches a function returning the right
#   number for the wrong name.
#
# IT DOES NOT INSTALL ANYTHING, AND CANNOT
#   Every test runs in its own scratch directory with the state and log
#   directories redirected into it. The suite needs no root, no network, no
#   docker and no systemd; where a test would need one it skips LOUDLY, naming
#   what was missing, because "cannot be tested here" and "does not work" must
#   never look the same in the output.
#
# WHEN bats IS ABSENT
#   It exits 3 and says so, in the same shape tests/gate-common.sh uses for a
#   skip. A test runner that exits 0 with nothing run is the single worst
#   behaviour in this directory: it reports a property nobody checked.
#
#   Install it with:  npm install -g --prefix ~/.local bats
#
# EXIT: 0 all passed, 1 failures, 3 could not run.

set -uo pipefail
TESTS_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
SUITE="$TESTS_DIR/bats"

if ! command -v bats >/dev/null 2>&1; then
    printf 'run-bats: SKIPPED -- bats is not on PATH, so NOTHING was executed.\n' >&2
    printf 'run-bats: this is not a pass. Install it with:\n' >&2
    printf 'run-bats:     npm install -g --prefix ~/.local bats\n' >&2
    exit 3
fi

if [[ ! -d $SUITE ]]; then
    printf 'run-bats: SKIPPED -- %s does not exist.\n' "$SUITE" >&2
    exit 3
fi

mapfile -t FILES < <(find "$SUITE" -maxdepth 1 -type f -name '*.bats' | LC_ALL=C.UTF-8 sort)
if (( ${#FILES[@]} == 0 )); then
    printf 'run-bats: SKIPPED -- no .bats files in %s.\n' "$SUITE" >&2
    exit 3
fi

printf '%s -- %d file(s), %s\n\n' "$(bats --version)" "${#FILES[@]}" "$SUITE"
# --print-output-on-failure: a failing assertion in this suite prints the
# expectation and what actually happened, and that is worthless if bats
# swallows it.
bats --print-output-on-failure "${FILES[@]}"
rc=$?
printf '\n'
if (( rc == 0 )); then
    printf 'run-bats: every test passed.\n'
else
    printf 'run-bats: FAILURES. A skipped test is not a passed one -- read the skips too.\n' >&2
fi
exit "$rc"
