# SPDX-License-Identifier: Apache-2.0
# tests/bats/helper.bash -- the shared harness for the unit suite.
#
# Sourced by every .bats file in this directory:
#
#     load helper
#
# WHAT THIS SUITE IS FOR, AND HOW IT DIFFERS FROM tests/check-*.sh
#   The build gates in tests/ read the tree as TEXT: they check that two copies
#   of a table agree, that no credential is on a command line, that every path
#   named here exists. They never execute the thing they are checking.
#
#   This suite executes it. It sources lib/*.sh, calls the functions, and
#   asserts on what comes back -- which is the only way to catch a function
#   that is written correctly and behaves wrongly. Both layers are needed and
#   neither replaces the other: the gates caught a documented exit code the
#   tree did not produce, and only running the code catches an `ex_code` that
#   returns the right number for the wrong name.
#
# NO THIRD-PARTY BATS LIBRARIES, DELIBERATELY
#   bats-support and bats-assert are the usual companions and they are not used
#   here. This project pins one Ansible collection to a RANGE and installs
#   nothing else unpinned; vendoring two more repositories to get `assert_equal`
#   would be a larger dependency surface than the assertions are worth. The
#   handful of helpers below are what those libraries would have provided, in
#   about sixty lines, with failure output shaped for this tree's conventions.
#
# EVERY TEST RUNS AGAINST A COPY, NEVER THE REPOSITORY
#   `setup()` puts each test in its own temporary directory and points REPO at
#   the real tree read-only. Nothing here may create, edit or delete a file in
#   the repository, and nothing may touch /var/log, /var/lib or /run outside
#   the test's own scratch. A unit suite that mutates the tree it is testing
#   produces a second run that disagrees with the first.
#
# WHAT IT MAY NOT ASSUME
#   No root. No network. No docker. No systemd. No T-Pot. Nothing in this
#   project has ever been installed anywhere, and a test that needs any of
#   those is a test for a tier this suite is not -- skip it loudly with
#   `skip_unless`, so the reason appears in the output rather than the test
#   quietly not existing.

# ---------------------------------------------------------------------------
# Paths. BATS_TEST_FILENAME is this file's caller, so the repository root is
# two directories up from it regardless of where `bats` was invoked from.
# ---------------------------------------------------------------------------
REPO="$(cd -- "$(dirname -- "$(dirname -- "$(dirname -- "${BATS_TEST_FILENAME}")")")" && pwd)"
export REPO
export LIB="$REPO/lib"

setup() {
    # One scratch directory per TEST, not per file: a test that leaves debris
    # must not be able to change the result of the next one.
    TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/tpot-bats.XXXXXXXX")"
    export TMP
    cd "$TMP" || return 1
    # The tree pins these everywhere for byte-stable, diffable output. Plain
    # `C` is forbidden: ansible-core refuses to start under it and there is a
    # build gate saying so, so the suite must not normalise to something the
    # product may not use.
    export LANG=C.UTF-8 LC_ALL=C.UTF-8
}

teardown() {
    [[ -n ${TMP:-} && -d ${TMP:-} ]] && rm -rf -- "$TMP"
    return 0
}

# ---------------------------------------------------------------------------
# Assertions.
#
# Each prints the expectation AND what actually happened, because a bats
# failure shows only the line that failed and "assert_equal returned 1" sends
# the reader back to the source to find out what was being compared.
# ---------------------------------------------------------------------------

# assert_eq EXPECTED ACTUAL [WHAT]
assert_eq() {
    local want=$1 got=$2 what=${3:-value}
    if [[ $want != "$got" ]]; then
        printf 'expected %s: %q\n     got %s: %q\n' "$what" "$want" "$what" "$got" >&2
        return 1
    fi
}

# assert_ne UNWANTED ACTUAL [WHAT]
assert_ne() {
    local nope=$1 got=$2 what=${3:-value}
    if [[ $nope == "$got" ]]; then
        printf '%s must NOT be %q, and it is\n' "$what" "$nope" >&2
        return 1
    fi
}

# assert_rc EXPECTED -- compares against bats' own $status, and prints $output
#   on failure. The output is the diagnosis nine times out of ten.
assert_rc() {
    local want=$1
    if [[ ${status:-} != "$want" ]]; then
        printf 'expected exit %s, got %s\noutput:\n%s\n' \
            "$want" "${status:-<unset>}" "${output:-<none>}" >&2
        return 1
    fi
}

# assert_contains NEEDLE HAYSTACK [WHAT] -- substring, literal, no globbing.
assert_contains() {
    local needle=$1 hay=$2 what=${3:-output}
    if [[ $hay != *"$needle"* ]]; then
        printf '%s does not contain %q\n%s was:\n%s\n' "$what" "$needle" "$what" "$hay" >&2
        return 1
    fi
}

# refute_contains NEEDLE HAYSTACK [WHAT]
#   The one that matters most here. Used for credentials, so it prints the
#   COUNT and the surrounding line rather than the whole haystack -- a failure
#   that dumped the transcript would put the secret it just caught into the
#   test output, which is the same defect one directory up.
refute_contains() {
    local needle=$1 hay=$2 what=${3:-output}
    local n
    n=$(printf '%s' "$hay" | grep -F -c -- "$needle" 2>/dev/null) || n=0
    if (( n > 0 )); then
        printf '%s contains the sentinel %d time(s); it must appear zero times.\n' "$what" "$n" >&2
        printf '(the matching text is NOT reproduced here, deliberately)\n' >&2
        return 1
    fi
}

# assert_matches ERE ACTUAL [WHAT]
assert_matches() {
    local re=$1 got=$2 what=${3:-value}
    if [[ ! $got =~ $re ]]; then
        printf '%s does not match /%s/\n     got: %q\n' "$what" "$re" "$got" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# skip_unless COMMAND... -- skip loudly when a precondition is genuinely
#   absent, naming what was missing. Never used to skip a test that merely
#   fails: this suite runs on a box with no root and no network, and the
#   difference between "cannot be tested here" and "does not work" is the
#   whole point of saying which.
# ---------------------------------------------------------------------------
skip_unless() {
    local what=$1; shift
    if ! "$@" >/dev/null 2>&1; then
        skip "needs $what, which is not available here"
    fi
}

# have CMD -- is a command on PATH?
have() { command -v "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# lib_source FILE... -- source one or more lib/*.sh in a subshell-safe way.
#
#   `set -u` is NOT enabled here even though install.sh runs under it. The
#   libraries are written to be sourced by a script that has already set its
#   own options, and a test that imposed different ones would be testing a
#   configuration the product never uses.
# ---------------------------------------------------------------------------
lib_source() {
    local f
    for f in "$@"; do
        # shellcheck disable=SC1090
        . "$LIB/$f" || return 1
    done
}

# ---------------------------------------------------------------------------
# run_install ARGS... -- run the real install.sh, fully unattended, with every
#   directory it writes to redirected into this test's scratch.
#
#   `</dev/null` and `setsid --wait` together are the product's central
#   promise: no controlling terminal, nothing on stdin. A `read` that reached
#   a person would hang here instead of prompting, and the suite would stall
#   rather than pass -- which is why the timeout is not optional.
#
#   This NEVER installs anything. The box these tests run on is unprivileged,
#   so every acting invocation stops in preflight stage A on the root check.
# ---------------------------------------------------------------------------
run_install() {
    mkdir -p "$TMP/state" "$TMP/log"
    run timeout 120 setsid --wait bash "$REPO/install.sh" \
        --state-dir "$TMP/state" --log-dir "$TMP/log" "$@" </dev/null
}
