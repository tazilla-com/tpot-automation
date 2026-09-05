#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# tests/bats/install-report.bats -- step 10's reboot decision, and the three
# artefacts it can be taken from.
#
# WHAT THIS FILE IS ABOUT
#   On a successful install roles/tpot_install sets tpot_reboot_required, so
#   $RUNDIR/ansible-report.json is the ONLY thing that separates exit 20 --
#   installed, a reboot is required -- from exit 0, which asserts that the box
#   has been installed AND verified. roles/report writes that file inside the
#   play's `always:` with failed_when: false, deliberately, so that a report
#   which cannot be written never replaces a real diagnosis with its own.
#
#   The consequence is that the file can be absent with nothing anywhere
#   saying so, and install.sh used to answer that silence with exit 0 and a
#   banner reading "This box has been installed and verified" for a machine
#   that had never rebooted. _tpot_step_10 now falls back to the
#   verify-pending marker, says which artefact answered, and returns
#   EX_INTERNAL rather than 0 when neither exists. That behaviour is what is
#   asserted here.
#
# WHY IT NEEDS A SEAM, AND WHAT THE SEAM IS
#   The report is written by the play, and the play needs a root box with
#   T-Pot on it -- so none of the three states can be reached by running
#   install.sh the way tests/bats/helper.bash's run_install does: every
#   acting invocation on an unprivileged box stops in preflight stage A, ten
#   steps short of the code under test.
#
#   So install.sh is SOURCED. Everything in it above the last twelve lines is
#   declarations, and the `[[ ${BASH_SOURCE[0]} == "$0" ]]` guard at its foot
#   means a sourced copy installs no traps, runs no main, writes nothing and
#   cannot exit the shell that sourced it. _tpot_step_10 is then called
#   directly against fabricated run and state directories, which is enough:
#   the function's whole input surface is the play's exit status, two files,
#   and the merged public document.
#
# WHAT IT DOES NOT COVER
#   Nothing here proves that roles/report writes a good document, or that
#   roles/finalize touches the marker -- those are the play's, and the play is
#   exercised on a real host. This file covers the shell's reading of them,
#   including the readings it can only do when they are wrong.

bats_require_minimum_version 1.5.0

load helper

# ---------------------------------------------------------------------------
# fabricate -- one run's directories, and the driver that sources install.sh
#   and calls step 10 against them.
#
#   The driver is a FILE rather than `bash -c`, so that a failure prints a
#   line number in something the reader can open, and so the sourcing happens
#   exactly the way the guard at the foot of install.sh describes.
#
#   T_REPO and T_SCRATCH carry the paths in rather than TPOT_STATE_DIR and
#   friends: install.sh unsets its own internal names out of the environment
#   at line 112 and records them as declined, which is the behaviour under
#   test elsewhere and would be noise here. The real names are assigned AFTER
#   the source, which is what install.sh's own main does.
# ---------------------------------------------------------------------------
fabricate() {
    mkdir -p "$TMP/run" "$TMP/state" "$TMP/log"
    cat > "$TMP/drive.sh" <<'DRIVER'
# install.sh sets -euo pipefail as it is sourced, so this driver runs under
# exactly the options the product runs under. Nothing is set here that main
# would not have set by the time step 10 is reached.
set -uo pipefail
. "$T_REPO/install.sh"

# The product's own initialiser, rather than a hand-written list of switches
# that would drift the first time one is added.
_tpot_args_init_opts

RUNDIR="$T_SCRATCH/run"
FAILURE_CLASS="$RUNDIR/failure-class"
TPOT_STATE_DIR="$T_SCRATCH/state"
TPOT_RESULT_JSON="$TPOT_STATE_DIR/result.json"
TPOT_LOG="$T_SCRATCH/log/install.log"

_tpot_step_10 "${T_PLAY_RC:-0}"
DRIVER
}

# write_report JSON -- the play's report, exactly as roles/report would leave
#   it in the run directory. Passed as text so a test can hand it something
#   that is not JSON at all.
write_report() {
    printf '%s\n' "$1" > "$TMP/run/ansible-report.json"
}

# arm_marker -- the verify-pending file roles/finalize touches as its last
#   act. Its EXISTENCE is the whole signal; it has no content, and
#   roles/finalize's own comment says content would only invite someone to
#   parse it.
arm_marker() {
    : > "$TMP/state/verify-pending"
}

# step10 [PLAY_RC] -- run the driver. $status is the code install.sh would
#   have exited with.
step10() {
    run env T_REPO="$REPO" T_SCRATCH="$TMP" T_PLAY_RC="${1:-0}" \
        bash "$TMP/drive.sh"
}

# jget FILE EXPR -- one value out of result.json, with the three non-string
#   scalars printed distinguishably. Same shape as the helper in
#   result-json.bats; the two files are read independently and neither is
#   worth a shared module.
jget() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    d = json.load(handle)
value = eval(sys.argv[2], {"__builtins__": {"len": len, "sorted": sorted}}, {"d": d})
if value is None:
    sys.stdout.write("<null>")
elif isinstance(value, bool):
    sys.stdout.write("true" if value else "false")
elif isinstance(value, (dict, list)):
    sys.stdout.write(json.dumps(value, sort_keys=True))
else:
    sys.stdout.write(str(value))
PY
}

# The sentence the defect produced. It is asserted against by name in three
# tests, so it is written once: a banner that stops printing it for a reason
# nobody intended must fail these rather than pass them quietly.
VERIFIED_CLAIM='This box has been installed and verified'


# ===========================================================================
# The seam itself. If this breaks, every test below is testing nothing.
# ===========================================================================

@test "install.sh can be sourced without running, and defines step 10" {
    fabricate
    run env T_REPO="$REPO" bash -c '
        set -uo pipefail
        . "$T_REPO/install.sh"
        declare -F _tpot_step_10 >/dev/null || exit 3
        declare -F main          >/dev/null || exit 4
        # A sourced copy installs no traps: the EXIT trap is what writes
        # result.json, and a test harness that inherited it would leave one
        # behind on every run.
        [[ -z $(trap -p EXIT) ]] || exit 5
        echo sourced
    '
    assert_rc 0
    assert_contains 'sourced' "$output"
}

@test "sourcing install.sh writes nothing into the state directory" {
    fabricate
    run env T_REPO="$REPO" bash -c 'set -uo pipefail; . "$T_REPO/install.sh"'
    assert_rc 0
    # Nothing at all: not a result document, not a log, not a run directory.
    assert_eq '' "$(ls -A "$TMP/state")" 'contents of the state directory'
    assert_eq '' "$(ls -A "$TMP/log")"   'contents of the log directory'
}


# ===========================================================================
# STATE 1 -- the report is there and readable. The path every good install
# takes, and the one the two fallbacks must not disturb.
# ===========================================================================

@test "a report asking for a reboot answers 20" {
    fabricate
    write_report '{"reboot_required": true, "already_installed": false}'
    step10 0
    assert_rc 20
    assert_eq 'true' "$(jget "$TMP/state/result.json" 'd["reboot"]["required"]')" \
        'reboot.required'
    assert_eq 'reboot_required' "$(jget "$TMP/state/result.json" 'd["outcome"]')" 'outcome'
}

@test "a report saying no reboot is required answers 0" {
    fabricate
    write_report '{"reboot_required": false, "already_installed": true}'
    step10 0
    assert_rc 0
    assert_eq 'false' "$(jget "$TMP/state/result.json" 'd["reboot"]["required"]')" \
        'reboot.required'
    assert_eq 'ok' "$(jget "$TMP/state/result.json" 'd["outcome"]')" 'outcome'
    # This is the one run in this file entitled to the sentence, and it is
    # asserted so that the three tests refuting it elsewhere are refuting
    # something that really does get printed.
    assert_contains "$VERIFIED_CLAIM" "$output" 'the banner'
}

@test "a readable report leaves the warnings and errors arrays empty" {
    fabricate
    write_report '{"reboot_required": true}'
    step10 0
    assert_rc 20
    assert_eq '[]' "$(jget "$TMP/state/result.json" 'd["warnings"]')" 'warnings'
    assert_eq '[]' "$(jget "$TMP/state/result.json" 'd["errors"]')"   'errors'
}


# ===========================================================================
# STATE 2 -- no readable report, but the marker is armed. Fall back to it,
# warn, and say in the artefact which artefact answered.
# ===========================================================================

@test "a missing report with the marker armed answers 20, not 0" {
    fabricate
    arm_marker
    step10 0
    assert_rc 20
    assert_ne 0 "$status" 'the exit code'
    assert_eq 'true' "$(jget "$TMP/state/result.json" 'd["reboot"]["required"]')" \
        'reboot.required'
}

@test "an unparseable report with the marker armed answers 20, not 0" {
    fabricate
    # Truncated mid-write is the realistic shape of this: the copy task was
    # interrupted, or the filesystem filled. json.load raises, and
    # _tpot_report_value prints nothing, which is the same input the missing
    # file produces.
    write_report '{"reboot_required": tr'
    arm_marker
    step10 0
    assert_rc 20
    assert_eq 'true' "$(jget "$TMP/state/result.json" 'd["reboot"]["required"]')" \
        'reboot.required'
}

@test "a report with no reboot_required key at all falls back to the marker" {
    fabricate
    # Valid JSON, valid object, and silent on the one question step 10 is
    # asking. "We do not know" has to look the same here as a missing file,
    # or a report that loses the key in a future edit becomes an exit 0.
    write_report '{"already_installed": false, "verification": []}'
    arm_marker
    step10 0
    assert_rc 20
}

@test "the marker fallback names both artefacts in result.json" {
    fabricate
    arm_marker
    step10 0
    assert_rc 20
    local warnings
    warnings=$(jget "$TMP/state/result.json" 'd["warnings"]')
    assert_contains 'verify-pending marker' "$warnings" 'result.json warnings'
    assert_contains 'ansible-report.json'   "$warnings" 'result.json warnings'
    # The decision source is the point of the record: a reader who was not
    # here must be able to tell a 20 taken from the report from a 20 taken
    # from the marker, and the artefact is where they will look.
    assert_contains 'reboot.required was taken from the verify-pending marker' \
        "$warnings" 'result.json warnings'
}

@test "the marker fallback warns on the human stream too" {
    fabricate
    arm_marker
    step10 0
    assert_rc 20
    assert_contains 'WARN:' "$output" 'the transcript'
    assert_contains 'ansible-report.json' "$output" 'the transcript'
}

@test "the marker fallback still says a reboot is required in the banner" {
    fabricate
    arm_marker
    step10 0
    assert_rc 20
    assert_contains 'A REBOOT IS REQUIRED' "$output" 'the banner'
    refute_contains "$VERIFIED_CLAIM" "$output" 'the banner'
}


# ===========================================================================
# STATE 3 -- neither artefact exists. Nothing on the box says how far the run
# got, so there is no answer to give and 0 is not available.
# ===========================================================================

@test "no report and no marker answers 40, never 0" {
    fabricate
    step10 0
    assert_rc 40
    assert_eq 'internal_error' "$(jget "$TMP/state/result.json" 'd["outcome"]')" 'outcome'
    assert_eq '40' "$(jget "$TMP/state/result.json" 'd["exit_code"]')" 'exit_code'
}

@test "no report and no marker records why in result.json" {
    fabricate
    step10 0
    assert_rc 40
    local errors
    errors=$(jget "$TMP/state/result.json" 'd["errors"]')
    assert_contains 'the reboot decision has no source' "$errors" 'result.json errors'
    assert_contains 'ansible-report.json'  "$errors" 'result.json errors'
    assert_contains 'verify-pending'       "$errors" 'result.json errors'
}

@test "no report and no marker never claims the box was verified" {
    fabricate
    step10 0
    assert_rc 40
    # The whole defect in one assertion. Before the fallback existed this run
    # exited 0 under a banner reading exactly this sentence.
    refute_contains "$VERIFIED_CLAIM" "$output" 'the banner'
    assert_contains 'THIS BOX HAS CHANGED' "$output" 'the banner'
}


# ===========================================================================
# What the fallback must NOT touch.
# ===========================================================================

@test "a failed play keeps its own failure class when the report is missing" {
    fabricate
    # The marker is armed and the report is gone -- state 2's inputs exactly.
    # The play still failed, so the failure class is the answer and the
    # fallback has no business changing it into a 20.
    arm_marker
    printf '16 verify\n' > "$TMP/run/failure-class"
    step10 2
    assert_rc 16
    assert_eq 'verify_failed' "$(jget "$TMP/state/result.json" 'd["outcome"]')" 'outcome'
}

@test "a failed play with no failure class is still 40, not the fallback's 40" {
    fabricate
    arm_marker
    step10 2
    assert_rc 40
    local errors
    errors=$(jget "$TMP/state/result.json" 'd["errors"]')
    assert_contains 'recorded no failure class' "$errors" 'result.json errors'
    # The reboot fallback did not fire: its sentence is about a play that
    # SUCCEEDED, and saying it here would send the reader after the wrong
    # defect.
    refute_contains 'the reboot decision has no source' "$errors" 'result.json errors'
}

@test "already_installed is still read from the report" {
    fabricate
    write_report '{"reboot_required": false, "already_installed": true}'
    step10 0
    assert_rc 0
    assert_eq 'true' "$(jget "$TMP/state/result.json" 'd["already_installed"]')" \
        'already_installed'
}
