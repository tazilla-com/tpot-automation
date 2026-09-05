#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
#
# tests/bats/no-tty.bats -- the promise that this installer cannot block on a
# prompt.
#
# THE PROMISE, IN THE PRODUCT'S OWN WORDS
#   `install.sh --config /root/tpot.yml </dev/null` under setsid, cloud-init
#   or CI cannot block on a prompt. Not "should not". There is exactly ONE
#   interactive read in this tree -- the two `read` statements of the password
#   prompt in lib/args.sh, taking a value and its confirmation from /dev/tty --
#   and it is reachable only when stdin IS a terminal, because `-y` is implied
#   the moment stdin is not one. Not having a terminal IS the non-interactive
#   mode; there is no flag to forget to pass.
#
# WHY THIS IS NOT ALREADY COVERED BY tests/check-no-tty.sh
#   That gate reads the tree as TEXT. It fails the build on a `read` that
#   looks interactive, on `select`, on whiptail/dialog/zenity and on Python's
#   input()/getpass -- anywhere at all, with one narrowly scoped exemption in
#   lib/args.sh. It is a good gate and it cannot answer the question this file
#   asks, because the shape of a program is not the same as its behaviour: a
#   run can block on something no grep would call a prompt (a child inheriting
#   a terminal, a package manager waiting on a dialogue, a tool that opens
#   /dev/tty itself). The only way to know is to give the process a stdin that
#   never delivers a byte and watch what happens.
#
# WHY </dev/null IS NOT THE TEST, AND A FIFO IS
#   /dev/null returns END OF FILE immediately. A bare `read` against it does
#   not block -- it returns non-zero at once and the script carries on, which
#   is why helper.bash's own run_install can use it. That is the wrong shape
#   for a cloud-init box, where stdin is typically a pipe or a socket that is
#   simply never written to. So every test below gives install.sh a FIFO,
#   opened read-write by the driver so the write end stays open for ever, and
#   NEVER WRITES A BYTE INTO IT. A real read() there waits until the heat
#   death of the universe.
#
#   That is also why every test here needs a watchdog: without one, a
#   regression would not fail this suite, it would HANG it, and a hung CI job
#   is diagnosed hours later as "the runner is broken".
#
# MEASURED, AND WHAT IT MEANS
#   All of these return in about two tenths of a second on this box, and the
#   deadline below is fifteen seconds. That gap is not tuning -- there is no
#   value between "returned" and "waiting for a person" that a correct run
#   could land in. A deadline that is generous costs nothing when the code is
#   right and diagnoses precisely when it is not.
#
# HONESTY
#   No run of install.sh has ever installed anything, here or anywhere. On
#   this unprivileged box every acting mode below stops in preflight stage A
#   on the root check and exits 11. That is enough for this file's question:
#   the run reaches step 3 of ten, through argument parsing, the environment
#   check, the password decision and the transcript, and it is those steps
#   that hold the only interactive read in the tree.

load helper

# ---------------------------------------------------------------------------
# write_fifo_driver
#   Materialise the watchdog into this test's scratch directory.
#
#   argv: WORKDIR DEADLINE_TENTHS MODE COMMAND [ARG...]
#
#   MODE is `empty` -- nothing is ever written to the FIFO, which is the
#   blocking case -- or `primed`, where exactly one line is written before the
#   command starts and is expected to be still there afterwards.
#
#   It prints a small report and exits 0 when the command returned, 1 when the
#   watchdog had to kill it, 3 when the FIFO could not be made:
#
#       VERDICT=returned|hung
#       RC=<exit status>            (returned only)
#       WAITED_TENTHS=<polls>
#       STDIN=<the primed line, or a marker saying it was consumed>
#       --- stdout --- / --- stderr ---   the command's own output
#
#   THE PROCESS GROUP IS RECORDED ON PURPOSE. `setsid` puts the command in a
#   new session, so killing the pid we waited on kills setsid and leaves the
#   real process orphaned and still blocked. A test suite that leaks a blocked
#   process on every failure poisons every run after it, so the inner shell
#   writes its own pid -- which is the new session's process group id -- and
#   the watchdog kills the group.
# ---------------------------------------------------------------------------
write_fifo_driver() {
    cat >"$TMP/fifo-driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
work=$1; deadline=$2; mode=$3; shift 3
mkdir -p -- "$work" || exit 3

fifo="$work/stdin.fifo"
rm -f -- "$fifo"
mkfifo -m 0600 -- "$fifo" || { printf 'VERDICT=nofifo\n'; exit 3; }

# Read-write, so this shell holds the write end open without blocking and
# without ever writing. Opening a FIFO write-only would block until a reader
# arrived, and opening it read-only would hand the far side an immediate EOF
# -- which is the /dev/null case this file exists to be harder than.
exec 9<>"$fifo"

if [[ $mode == primed ]]; then
    printf 'TPOT-BATS-STDIN-UNTOUCHED\n' >&9
fi

: >"$work/pgid"
setsid --wait bash -c 'printf "%s" "$$" >"$1"; shift; exec "$@"' \
    _ "$work/pgid" "$@" <&9 >"$work/out" 2>"$work/err" &
pid=$!

waited=0
while (( waited < deadline )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    waited=$(( waited + 1 ))
done

if kill -0 "$pid" 2>/dev/null; then
    printf 'VERDICT=hung\n'
    printf 'WAITED_TENTHS=%s\n' "$waited"
    printf 'the process was still running with stdin an open FIFO that is never\n'
    printf 'written. That is a read() waiting for a person, which is the one\n'
    printf 'thing this installer promises cannot happen.\n'
    pg=$(cat -- "$work/pgid" 2>/dev/null) || pg=''
    [[ -n $pg ]] && kill -9 -- "-$pg" 2>/dev/null
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    printf -- '--- stdout ---\n'; cat -- "$work/out" 2>/dev/null
    printf -- '--- stderr ---\n'; cat -- "$work/err" 2>/dev/null
    exec 9>&-
    exit 1
fi

wait "$pid"; rc=$?

# Was the primed byte left alone? A bare `read` in the command would have
# eaten it, which is the silent half of this defect: nothing hangs, and the
# caller's own input has quietly gone missing.
stdin_state='<not primed>'
if [[ $mode == primed ]]; then
    if IFS= read -r -t 2 stdin_state <&9; then :; else
        stdin_state='<CONSUMED-OR-EMPTY>'
    fi
fi
exec 9>&-

printf 'VERDICT=returned\n'
printf 'RC=%s\n' "$rc"
printf 'WAITED_TENTHS=%s\n' "$waited"
printf 'STDIN=%s\n' "$stdin_state"
printf -- '--- stdout ---\n'; cat -- "$work/out" 2>/dev/null
printf -- '--- stderr ---\n'; cat -- "$work/err" 2>/dev/null
exit 0
DRIVER
}

# ---------------------------------------------------------------------------
# run_fifo MODE DEADLINE_TENTHS -- ARGS...
#   install.sh under the watchdog, with the state and log directories pointed
#   into this test's scratch exactly as helper.bash's run_install does.
# ---------------------------------------------------------------------------
run_fifo() {
    local mode=$1 deadline=$2
    shift 2
    write_fifo_driver
    mkdir -p "$TMP/state" "$TMP/log" "$TMP/fifo"
    run bash "$TMP/fifo-driver.sh" "$TMP/fifo" "$deadline" "$mode" \
        bash "$REPO/install.sh" --state-dir "$TMP/state" --log-dir "$TMP/log" "$@"
}

# fifo_field KEY -- one value out of the driver's report.
fifo_field() {
    sed -n "s/^${1}=//p" <<<"$output" | head -n 1
}

# assert_returned EXPECTED_RC -- the promise, stated once.
assert_returned() {
    local want=$1
    assert_rc 0
    assert_eq 'returned' "$(fifo_field VERDICT)" 'the watchdog verdict'
    assert_eq "$want" "$(fifo_field RC)" 'the exit status'
}

# A password for the modes that require one. It is not a secret and is not
# treated as one here: tests/bats/no-secret-leak.bats is where a credential's
# handling is tested, and mixing the two would make both harder to read.
NO_TTY_PASSWORD='bats-no-tty-placeholder-not-a-real-password'

# ===========================================================================
# The positive control -- FIRST, because everything below is worthless if the
# watchdog cannot tell a hang from a return.
# ===========================================================================
#
# A three-line fixture doing the exact thing check-no-tty.sh forbids: a bare
# `read` with no redirection, consuming the script's own stdin. Under a FIFO
# that is never written it waits for ever, and the watchdog must say so. Its
# deadline is deliberately short -- this is the one test here that is SUPPOSED
# to reach it, and two seconds is enough to prove the mechanism without
# costing the suite fifteen.
@test "the watchdog can see a process that blocks on stdin" {
    write_fifo_driver
    mkdir -p "$TMP/fifo"
    cat >"$TMP/blocker.sh" <<'BLOCKER'
#!/usr/bin/env bash
printf 'about to wait for a person\n' >&2
IFS= read -r answer
printf 'got: %s\n' "$answer" >&2
BLOCKER

    run bash "$TMP/fifo-driver.sh" "$TMP/fifo" 20 empty bash "$TMP/blocker.sh"

    assert_rc 1
    assert_eq 'hung' "$(fifo_field VERDICT)" 'the watchdog verdict'
    assert_contains 'waiting for a person' "$output" 'the watchdog report'
}

# ===========================================================================
# Every acting mode, with a stdin that never delivers
# ===========================================================================

@test "a full run cannot block on a prompt when stdin never delivers a byte" {
    export TPOT_WEB_PASSWORD=$NO_TTY_PASSWORD
    run_fifo empty 150
    # 11 = EX_PREFLIGHT: not root. Asserted rather than ignored so that this
    # test cannot quietly start measuring something else.
    assert_returned 11
    assert_contains 'must run as root' "$output" 'the run output'
}

@test "--preflight-only cannot block on a prompt when stdin never delivers a byte" {
    run_fifo empty 150 --preflight-only
    assert_returned 11
}

@test "--verify-only cannot block on a prompt when stdin never delivers a byte" {
    run_fifo empty 150 --verify-only
    assert_returned 11
}

@test "--check cannot block on a prompt when stdin never delivers a byte" {
    export TPOT_WEB_PASSWORD=$NO_TTY_PASSWORD
    run_fifo empty 150 --check
    assert_returned 11
}

# ===========================================================================
# The three print-and-exit modes
# ===========================================================================
#
# They stop parsing where they are found and must print, exit 0 and ask
# nothing. `install.sh --help` on a box with no terminal is the first thing a
# confused operator types, and it is exactly the moment a prompt would be
# least welcome.
#
# WHAT IS DELIBERATELY NOT ASSERTED HERE, having been checked and found to
# mean something other than it looks: that these modes leave no result.json
# under the state directory. They do leave none -- but not for the reason a
# reader would assume, so an assertion about it would be a green light nobody
# could interpret. `-h` returns from args_parse ON THE SPOT, before
# _tpot_args_resolve_dirs runs, so `--state-dir DIR --help` never adopts DIR
# at all and TPOT_STATE_DIR is still the compiled-in default. The directory
# this suite watches is therefore not the directory a print mode would write
# to even if it started writing one. The property that IS worth holding them
# to -- print, exit 0, never block -- is asserted below.

@test "--help prints and exits with no terminal anywhere" {
    run_fifo empty 150 --help
    assert_returned 0
    assert_contains 'USAGE' "$output" 'the help text'
    assert_contains 'install.sh [OPTION]...' "$output" 'the help text'
}

@test "--version prints and exits with no terminal anywhere" {
    run_fifo empty 150 --version
    assert_returned 0
    assert_contains 'tpot-automation' "$output" 'the version line'
}

@test "--example-config prints and exits with no terminal anywhere" {
    run_fifo empty 150 --example-config
    assert_returned 0
    assert_contains 'tpot_web_password' "$output" 'the example config'
}

# ===========================================================================
# Missing input with no terminal: a usage error, not a prompt and not a hang
# ===========================================================================

# This is the sentence the whole design turns on. With no terminal there is
# nobody to ask, so the run must say what it needs and how to supply it --
# immediately, in the first thing a cloud-init log shows, before preflight and
# before anything is touched. The three ways are named in full because a
# message saying only "tpot_web_password is required" sends the reader to look
# at the one thing they did supply.
@test "with no terminal and no password the run is a usage error naming all three ways to supply it" {
    run_fifo empty 150
    assert_returned 10

    assert_contains 'tpot_web_password is required and was not supplied' "$output" 'the message'
    assert_contains '--web-password-file' "$output" 'the message'
    assert_contains 'TPOT_WEB_PASSWORD' "$output" 'the message'
    assert_contains 'tpot_web_password: "..."' "$output" 'the message'
    assert_contains '--example-config' "$output" 'the message'

    # Not a prompt. Neither half of the courtesy prompt's wording may appear.
    refute_contains 'dashboard password (not shown)' "$output" 'the message'
    refute_contains 'Repeat it' "$output" 'the message'
}

# A run that fails at step 1 still leaves the artefact a caller reads when the
# exit code alone is not enough -- and it records that the run was
# non-interactive, which is the decision this whole file is about. That value
# comes from `[[ -t 0 ]]` and from nothing else: no flag was passed here.
@test "result.json records that a run with no terminal was non-interactive" {
    run_fifo empty 150
    assert_returned 10

    [[ -f $TMP/state/result.json ]]
    local doc
    doc=$(cat "$TMP/state/result.json")
    assert_contains '"non_interactive": true' "$doc" 'result.json'
    assert_contains '"outcome": "usage_error"' "$doc" 'result.json'
}

# ===========================================================================
# The other half of the defect: stdin that is read without blocking
# ===========================================================================

# A bare `read` does not always hang. When the caller's stdin happens to have
# a byte on it -- a here-document, a pipeline, a provisioning tool feeding a
# script list -- the read SUCCEEDS and silently eats input that belonged to
# somebody else. Nothing errors and nothing hangs; the next consumer just
# finds a line missing. check-no-tty.sh calls this out as the shape that
# "silently consumes the script's own stdin".
@test "a run leaves the byte waiting on its own stdin unread" {
    export TPOT_WEB_PASSWORD=$NO_TTY_PASSWORD
    run_fifo primed 150 --preflight-only
    assert_returned 11
    assert_eq 'TPOT-BATS-STDIN-UNTOUCHED' "$(fifo_field STDIN)" 'the byte left on stdin'
}

# ===========================================================================
# The courtesy prompt itself
# ===========================================================================

# lib/args.sh's prompt is the only interactive read in the tree, and it has
# two guards. The first is the one everything above tests: -y is implied when
# stdin is not a terminal, so install.sh never calls the function. The second
# is inside the function -- it refuses to run when /dev/tty is not available,
# which covers the case where stdin IS a terminal but the controlling terminal
# has gone.
#
# What is asserted here is the part that matters most and is true: called
# under setsid, with no controlling terminal, the prompt FAILS FAST with a
# usage error instead of waiting for a person. It cannot hang.
#
# ▲ It does not fail the way lib/args.sh says it does, and that is worth
#   knowing before someone reads this test as proof of the comment. The second
#   guard is `[[ -r /dev/tty && -w /dev/tty ]]`, and that is an access(2)
#   permission check on a device node whose mode is 0666 -- it passes whether
#   or not the process has a controlling terminal. So the function does not
#   return through args_die_missing_web_password as its comment states; it
#   falls into the retry loop, every /dev/tty redirection fails with "No such
#   device or address", and after two attempts it exits 10 with the WRONG
#   message -- the one about a password that was not confirmed, rather than
#   the three-way message naming how to supply one. The exit code is right by
#   coincidence. This test therefore asserts exit 10 and non-blocking, both of
#   which survive a fix to the guard.
@test "the password prompt fails fast instead of waiting when there is no controlling terminal" {
    write_fifo_driver
    mkdir -p "$TMP/fifo"
    cat >"$TMP/prompt.sh" <<'PROMPT'
#!/usr/bin/env bash
set -uo pipefail
. "$LIB/exitcodes.sh"
. "$LIB/args.sh"
_tpot_args_init_opts
# Called exactly as install.sh calls it: the value must go to a PIPE, because
# the function refuses outright to write it to a terminal, and the status is
# taken from the command substitution. `exit` inside a substitution ends the
# subshell and not the caller, so a fixture that ignored the status would
# report success no matter what the prompt did.
rc=0
value=$(args_prompt_web_password) || rc=$?
printf 'PROMPT_RC=%s\n' "$rc"
if [[ -n $value ]]; then
    printf 'IT_RETURNED_A_VALUE\n'
fi
exit "$rc"
PROMPT

    run bash "$TMP/fifo-driver.sh" "$TMP/fifo" 100 empty bash "$TMP/prompt.sh"

    assert_eq 'returned' "$(fifo_field VERDICT)" 'the watchdog verdict'
    # 10 = EX_USAGE. It never returns a value, and it never waits.
    assert_eq '10' "$(fifo_field RC)" 'the exit status'
    assert_contains 'PROMPT_RC=10' "$output" 'the driver output'
    refute_contains 'IT_RETURNED_A_VALUE' "$output" 'the driver output'
}
