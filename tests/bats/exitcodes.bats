#!/usr/bin/env bats
# tests/bats/exitcodes.bats -- the exit contract, executed.
#
# WHY THIS FILE EXISTS, GIVEN tests/check-exit-table.sh ALREADY RUNS
#   That gate reads the tree as text: it proves docs/exit-codes.md, README.md
#   and `install.sh --help` carry the same bytes `bash lib/exitcodes.sh`
#   renders. What it cannot see is whether the FUNCTIONS agree with the table
#   they render. A caller does not read docs/exit-codes.md at three in the
#   morning; it branches on a number, and install.sh maps a failure class to
#   that number through ex_code and ex_name. An ex_code that returns the right
#   number for the wrong name would leave every document in this repository
#   byte-identical and every automated caller wrong.
#
#   So this file calls them. Nothing here reads the source of lib/exitcodes.sh
#   or asserts on how a function is written; every assertion is about what
#   comes back from a call.
#
# WHAT THE CONTRACT IS
#   install.sh's exit status IS the product -- the whole point of an unattended
#   installer is that something else can tell "installed and verified" from
#   "installed, reboot first" from "never touched the box" without parsing
#   English. lib/exitcodes.sh is the one place those numbers are written down.
#   The properties pinned below are the ones a caller depends on:
#
#     * 0 means success and only success
#     * every code round-trips: code -> name -> code, and both forms reach the
#       same meaning
#     * the EX_* constants agree with the table (nothing else checks this)
#     * a code we do not own is REPORTED, never silently swallowed
#     * sourcing the file twice is harmless -- see the guard test, which is the
#       one that encodes a real defect
#
# NO ROOT, NO NETWORK, NO INSTALL. This file sources a library and runs bash.

load helper

# ---------------------------------------------------------------------------
# The table, and the constants beside it.
# ---------------------------------------------------------------------------

@test "every code round-trips from code to name to code and back to one meaning" {
    lib_source exitcodes.sh
    local code name back by_code by_name n=0
    for code in $(ex_codes); do
        if ! name=$(ex_name "$code"); then
            printf 'ex_name %s returned non-zero for a code the table lists\n' "$code" >&2
            return 1
        fi
        if ! back=$(ex_code "$name"); then
            printf 'ex_code %s returned non-zero for a name the table lists\n' "$name" >&2
            return 1
        fi
        assert_eq "$code" "$back" "round-trip of $name"
        if ! by_code=$(ex_meaning "$code") || ! by_name=$(ex_meaning "$name"); then
            printf 'ex_meaning has no answer for %s / %s\n' "$code" "$name" >&2
            return 1
        fi
        assert_eq "$by_code" "$by_name" "meaning of $name reached by code and by name"
        assert_ne "" "$by_code" "meaning of $name"
        n=$(( n + 1 ))
    done
    (( n >= 11 )) || {
        printf 'only %d codes were round-tripped; the table has shrunk unexpectedly\n' "$n" >&2
        return 1
    }
}

@test "0 is success, and success is the only thing 0 means" {
    lib_source exitcodes.sh
    assert_eq "EX_OK" "$(ex_name 0)" "the name of code 0"
    assert_eq "0" "$(ex_code EX_OK)" "the code of EX_OK"
    # No second row may claim 0. A caller that treats 0 as "it worked" is the
    # entire reason the other ten codes exist, and a failure sharing 0 would
    # make every one of them undetectable.
    local code zeros=0
    for code in $(ex_codes); do
        [[ $code == 0 ]] && zeros=$(( zeros + 1 ))
    done
    assert_eq "1" "$zeros" "number of rows claiming code 0"
    # And nothing that is not success is 0.
    local name
    for name in $(ex_names); do
        if [[ $name != EX_OK ]]; then
            assert_ne "0" "$(ex_code "$name")" "code of $name"
        fi
    done
}

@test "the codes are unique and so are the names" {
    lib_source exitcodes.sh
    local dup
    dup=$(ex_codes | sort | uniq -d)
    assert_eq "" "$dup" "duplicate exit codes"
    dup=$(ex_names | sort | uniq -d)
    assert_eq "" "$dup" "duplicate exit-code names"
    assert_eq "$(ex_codes | wc -l)" "$(ex_names | wc -l)" "rows seen by ex_codes and ex_names"
}

@test "the EX_ constants a caller uses hold the codes the table documents" {
    # NOTHING ELSE CHECKS THIS. tests/check-exit-table.sh compares the RENDERED
    # table against the documents; the readonly EX_* variables are a second
    # copy of the same numbers, in the same file, and install.sh exits with the
    # variable rather than with the table. A row edited without its variable --
    # or the reverse -- documents one contract and ships another.
    lib_source exitcodes.sh
    local name code
    for name in $(ex_names); do
        if [[ -z ${!name+set} ]]; then
            printf '%s is a row of the table but no such variable is defined\n' "$name" >&2
            return 1
        fi
        code=$(ex_code "$name")
        assert_eq "$code" "${!name}" "\$$name"
    done
}

@test "every row of the table is code, name and a one-line plain-ASCII meaning" {
    # The meaning is printed verbatim into --help and into two documents that
    # are compared byte for byte. A tab, a second line or a non-ASCII character
    # in a meaning does not fail here in an obvious way -- it fails in the gate,
    # far from the edit that caused it.
    lib_source exitcodes.sh
    local row rest code name meaning stray
    for row in "${EX_TABLE_ROWS[@]}"; do
        assert_matches '^[0-9]+\|EX_[A-Z]+\|.+$' "$row" "table row"
        code=${row%%|*}
        rest=${row#*|}
        name=${rest%%|*}
        meaning=${rest#*|}
        assert_matches '^[0-9]+$' "$code" "the code of $name"
        assert_ne "" "$meaning" "the meaning of $name"
        # Printable ASCII only, checked WITHOUT setting a locale.
        #
        # The obvious spelling prefixes `tr -d '[:print:]'` with the plain C
        # locale, and it is correct -- [:print:] is byte-oriented there and
        # multibyte-aware under C.UTF-8, so only the byte-oriented one finds a
        # stray UTF-8 byte. But tests/check-locale.sh fails the build on that
        # assignment anywhere in the tree, for a good reason unrelated to this
        # line:
        # ansible-core REFUSES TO START under a plain C locale, and upstream's
        # install.sh runs a nested ansible-playbook, so the string appearing
        # here at all is a hazard the gate is right to be blunt about.
        #
        # Rather than take an exemption for a line that only wants a byte
        # range, ask for the byte range. python3 is already a hard dependency
        # of this installer, this is locale-independent, and it says what it
        # means: every character must be in 0x20..0x7e.
        stray=$(printf '%s' "$meaning" | python3 -c \
            'import sys; sys.stdout.write(str(sum(1 for c in sys.stdin.read() if not (0x20 <= ord(c) <= 0x7e))))')
        assert_eq "0" "$stray" "non-printable or non-ASCII bytes in the meaning of $name"
    done
}

# ---------------------------------------------------------------------------
# Lookups: the forgiving direction, and the strict one.
# ---------------------------------------------------------------------------

@test "a name is accepted in any case and with the EX_ prefix optional" {
    lib_source exitcodes.sh
    # install.sh reads a failure class out of a file written by another stage.
    # These four spellings are the ones a human or a play might plausibly put
    # there, and the header promises all of them resolve.
    assert_eq "20" "$(ex_code EX_REBOOT)" "ex_code EX_REBOOT"
    assert_eq "20" "$(ex_code reboot)"    "ex_code reboot"
    assert_eq "20" "$(ex_code Reboot)"    "ex_code Reboot"
    assert_eq "20" "$(ex_code ex_reboot)" "ex_code ex_reboot"
    assert_eq "0"  "$(ex_code ok)"        "ex_code ok"
    assert_eq "$(ex_meaning EX_PREFLIGHT)" "$(ex_meaning preflight)" "meaning by either spelling"
}

@test "a name the table does not define is refused, and nothing is printed" {
    lib_source exitcodes.sh
    local bad
    for bad in NOSUCH ex_nosuch '' ' ' 'EX_OK EX_USAGE' 'OK*'; do
        run ex_code "$bad"
        assert_rc 1
        assert_eq "" "$output" "output of ex_code '$bad'"
    done
}

@test "a code the table does not define is refused, and nothing is printed" {
    lib_source exitcodes.sh
    local bad
    # 1 and 2 matter: they are what a shell error or a bad invocation produces,
    # and this installer deliberately owns neither. 99 is the "somebody else's
    # number" case, and "0 " is the whitespace one -- an unparseable class file
    # must not resolve to success.
    for bad in 1 2 17 99 255 '' '0 ' ' 0' '1|EX_OK'; do
        run ex_name "$bad"
        assert_rc 1
        assert_eq "" "$output" "output of ex_name '$bad'"
        run ex_meaning "$bad"
        assert_rc 1
        assert_eq "" "$output" "output of ex_meaning '$bad'"
    done
}

@test "ex_is_code agrees with ex_name on every code, and prints nothing either way" {
    # It is called inside a condition. A helper that printed on the way to
    # returning false would put a stray line in the transcript at the exact
    # moment install.sh is deciding it does not understand its own state.
    lib_source exitcodes.sh
    local code
    for code in $(ex_codes); do
        run ex_is_code "$code"
        assert_rc 0
        assert_eq "" "$output" "output of ex_is_code $code"
    done
    local bad
    for bad in 1 2 99 '' 'EX_OK' 'twenty'; do
        run ex_is_code "$bad"
        assert_rc 1
        assert_eq "" "$output" "output of ex_is_code '$bad'"
    done
}

# ---------------------------------------------------------------------------
# ex_describe -- the line a human reads at the end of a run.
# ---------------------------------------------------------------------------

@test "a code we own is described as its number, its name and its meaning" {
    lib_source exitcodes.sh
    local code name meaning got
    for code in $(ex_codes); do
        name=$(ex_name "$code")
        meaning=$(ex_meaning "$code")
        got=$(ex_describe "$code")
        assert_eq "${code} (${name}): ${meaning}" "$got" "ex_describe $code"
        # Either spelling reaches the same line.
        assert_eq "$got" "$(ex_describe "$name")" "ex_describe $name"
    done
}

@test "an exit status we do not own is described truthfully, never silently" {
    # This is the property the header calls the worst possible behaviour to get
    # wrong: install.sh describes whatever status it is about to exit with, and
    # an unexpected one -- 1 from a shell error, 137 from an OOM kill -- must
    # produce a line saying so rather than an empty string that reads like
    # nothing happened.
    lib_source exitcodes.sh
    local bad out rc
    for bad in 1 2 99 137 255 NOSUCH ''; do
        rc=0
        out=$(ex_describe "$bad" 2>/dev/null) || rc=$?
        assert_eq "1" "$rc" "exit status of ex_describe '$bad'"
        assert_ne "" "$out" "ex_describe '$bad' must say something"
        assert_contains "unknown" "$out" "ex_describe '$bad'"
        assert_contains "not an exit code this installer defines" "$out" "ex_describe '$bad'"
    done
    # It goes to stdout: the transcript is stdout, and a diagnosis written only
    # to stderr is a diagnosis missing from the file people send with an issue.
    out=$(ex_describe 137 2>/dev/null) || true
    assert_contains "137" "$out" "ex_describe 137 on stdout"
}

# ---------------------------------------------------------------------------
# The load guard. This is the one test here that pins a named defect.
# ---------------------------------------------------------------------------

@test "sourcing the file twice is harmless under errexit" {
    # THE DEFECT THE GUARD EXISTS FOR, quoted from the file's own header: the
    # second `readonly` assignment fails and, under `set -e`, takes the caller
    # with it. install.sh runs under `set -euo pipefail`, so a second source --
    # from a helper, a tool, or a gate that sources several libraries -- would
    # not be a warning, it would be the installer exiting at line one with no
    # message anybody could act on.
    run bash -c '
        set -euo pipefail
        . "$1/lib/exitcodes.sh"
        . "$1/lib/exitcodes.sh"
        printf "%s %s\n" "$EX_REBOOT" "$(ex_name 20)"
    ' bash "$REPO"
    assert_rc 0
    assert_eq "20 EX_REBOOT" "$output" "state after a second source"
}

@test "without the guard the second source is fatal, which is what the guard is for" {
    # The NEGATIVE CONTROL for the test above, and the reason it is not
    # vacuous. Defeating the guard costs one `unset` and needs no edit to the
    # repository: the second pass then re-runs `readonly EX_OK=0` against an
    # already-readonly variable, which is an error, which errexit turns into a
    # dead installer. If this test ever passes by printing SURVIVED, the
    # assignments have stopped being readonly and the test above proves nothing.
    run bash -c '
        set -euo pipefail
        . "$1/lib/exitcodes.sh"
        unset _TPOT_EXITCODES_SH_LOADED
        . "$1/lib/exitcodes.sh"
        printf "SURVIVED\n"
    ' bash "$REPO"
    if (( status == 0 )); then
        printf 'the guarded double-source test is vacuous: an unguarded second source succeeded\n' >&2
        printf 'output:\n%s\n' "$output" >&2
        return 1
    fi
    refute_contains "SURVIVED" "$output" "unguarded second source"
}

# ---------------------------------------------------------------------------
# Executed rather than sourced.
# ---------------------------------------------------------------------------

@test "running the file rather than sourcing it prints the table and exits 0" {
    # docs/exit-codes.md and README.md are regenerated from this invocation and
    # tests/check-exit-table.sh compares them to it byte for byte. A non-zero
    # exit here, or a table on stderr, would break the regeneration path and the
    # gate would report a documentation drift nobody caused.
    run bash "$REPO/lib/exitcodes.sh"
    assert_rc 0
    assert_matches '^CODE[[:space:]]+NAME[[:space:]]+MEANING' "$output" "the table header"

    lib_source exitcodes.sh
    local row code rest name meaning n_rows n_lines
    for row in "${EX_TABLE_ROWS[@]}"; do
        code=${row%%|*}
        rest=${row#*|}
        name=${rest%%|*}
        meaning=${rest#*|}
        assert_matches "(^|"$'\n'")[[:space:]]*${code}[[:space:]]+${name}[[:space:]]+" \
            "$output" "the rendered row for $name"
        assert_contains "$meaning" "$output" "the rendered meaning of $name"
    done
    n_rows=${#EX_TABLE_ROWS[@]}
    n_lines=$(printf '%s\n' "$output" | wc -l | tr -d ' ')
    assert_eq "$(( n_rows + 1 ))" "$n_lines" "lines printed (one header plus one per row)"
}

@test "the executed table and the sourced ex_table are the same table" {
    # The rendering a caller gets by executing the file must be the rendering
    # install.sh --help gets by calling the function, because the gate treats
    # them as interchangeable copies of one contract.
    lib_source exitcodes.sh
    local sourced executed
    sourced=$(ex_table)
    executed=$(bash "$REPO/lib/exitcodes.sh")
    assert_eq "$sourced" "$executed" "ex_table vs the executed file"
}
