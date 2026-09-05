#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# lib/exitcodes.sh -- THE source of truth for this installer's exit codes.
#
# WHY THIS FILE EXISTS
#   The automation contract is the product. A caller that cannot tell "the box
#   is installed and verified" from "the box is installed and needs a reboot"
#   from "the box was never touched" has no product at all, only a script. The
#   exit table is therefore written down exactly once, here, and everything
#   that repeats it -- `install.sh --help`, docs/exit-codes.md, README.md -- is
#   diffed against this file in CI rather than maintained beside it.
#
# HOW TO USE IT
#   Sourced:   . "${REPO_DIR}/lib/exitcodes.sh"   then use $EX_USAGE, ex_name...
#   Executed:  bash lib/exitcodes.sh              prints the table and exits 0.
#              That is how docs/exit-codes.md is regenerated and how the test
#              that diffs the two gets its reference copy.
#
# HOW TO CHANGE IT
#   Add or edit a row in EX_TABLE_ROWS below, then regenerate the documented
#   copies. Never renumber an existing code: the numbers are the contract, and
#   somebody's CI is branching on them. Retire a code by leaving its row in
#   place with a meaning that says so.
#
# shellcheck shell=bash

# Sourcing this file twice must be harmless. Without the guard, the second
# `readonly` assignment fails and, under `set -e`, takes the caller with it.
if [[ -n ${_TPOT_EXITCODES_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_EXITCODES_SH_LOADED=1

# ---------------------------------------------------------------------------
# The codes.
#
# 0 is success and only success. 10-16 are failures, grouped so that the tens
# digit tells a caller how far the run got. 20 is a success that is not
# finished. 30 and 40 are the two ways a run ends without deciding anything.
# ---------------------------------------------------------------------------
readonly EX_OK=0
readonly EX_USAGE=10
readonly EX_PREFLIGHT=11
readonly EX_INCONCLUSIVE=12
readonly EX_DEPS=13
readonly EX_UPSTREAM=14
readonly EX_DRIVER=15
readonly EX_VERIFY=16
readonly EX_REBOOT=20
readonly EX_INTERRUPT=30
readonly EX_INTERNAL=40

# ---------------------------------------------------------------------------
# The table. One row per code: code|name|meaning.
#
# The meaning is one line of plain ASCII. It is printed verbatim into --help
# and into the documentation, so it is written for someone reading a terminal
# at the end of a failed run, not for someone reading source.
# ---------------------------------------------------------------------------
readonly EX_TABLE_ROWS=(
    "0|EX_OK|installed and verified; nothing further is required"
    "10|EX_USAGE|bad flag, unknown environment or answer-file key, missing required input, --set on a secret key, or an answer file that is inside the tree or not root-owned 0600"
    "11|EX_PREFLIGHT|not root, unsupported operating system, memory/CPU/disk below the hard floor, a required port already bound by something other than the host sshd, upstream/apt/Galaxy/PyPI unreachable, /run not tmpfs, or no systemd"
    "12|EX_INCONCLUSIVE|--preflight-only only: nothing failed, but some checks could not be exercised on this box"
    "13|EX_DEPS|dependency bootstrap failed: apt, ansible-core, or ansible-galaxy"
    "14|EX_UPSTREAM|the pinned upstream T-Pot installer could not be fetched, or its sha256 did not match"
    "15|EX_DRIVER|upstream's own installer failed: it exited non-zero, or it exceeded tpot_driver_install_timeout"
    "16|EX_VERIFY|T-Pot installed, but a post-install assertion failed"
    "20|EX_REBOOT|installed and pre-reboot checks passed; a REBOOT IS REQUIRED before verification. Not a failure"
    "30|EX_INTERRUPT|interrupted by SIGINT, SIGTERM or SIGHUP; the trap still wrote result.json"
    "40|EX_INTERNAL|a bug in this installer, or a credential reached the transcript; file an issue and attach the transcript"
)

# ---------------------------------------------------------------------------
# ex_table
#   Print the whole table, header included, one row per line.
#   This output IS the contract: docs/exit-codes.md and README.md embed it
#   byte-for-byte between markers, and --help prints it.
# ---------------------------------------------------------------------------
ex_table() {
    local row code name meaning
    printf '%4s  %-16s  %s\n' 'CODE' 'NAME' 'MEANING'
    for row in "${EX_TABLE_ROWS[@]}"; do
        code=${row%%|*}
        meaning=${row#*|}
        name=${meaning%%|*}
        meaning=${meaning#*|}
        printf '%4s  %-16s  %s\n' "$code" "$name" "$meaning"
    done
}

# ---------------------------------------------------------------------------
# ex_codes            every code, in table order, one per line
# ex_names            every name, in table order, one per line
# ---------------------------------------------------------------------------
ex_codes() {
    local row
    for row in "${EX_TABLE_ROWS[@]}"; do
        printf '%s\n' "${row%%|*}"
    done
}

ex_names() {
    local row rest
    for row in "${EX_TABLE_ROWS[@]}"; do
        rest=${row#*|}
        printf '%s\n' "${rest%%|*}"
    done
}

# ---------------------------------------------------------------------------
# ex_name CODE
#   Print the name for a numeric code. Exit 1 and print nothing if the code is
#   not one of ours -- which is itself useful: it is how install.sh decides
#   that $RUNDIR/failure-class was unparseable and falls back to EX_INTERNAL.
# ---------------------------------------------------------------------------
ex_name() {
    local want=${1:-} row rest
    for row in "${EX_TABLE_ROWS[@]}"; do
        if [[ ${row%%|*} == "$want" ]]; then
            rest=${row#*|}
            printf '%s\n' "${rest%%|*}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# ex_code NAME
#   Print the numeric code for a name. Case-insensitive, and the EX_ prefix is
#   optional: ex_code EX_REBOOT, ex_code reboot and ex_code Reboot all print 20.
#   Exit 1 and print nothing if the name is not one of ours.
# ---------------------------------------------------------------------------
ex_code() {
    local want=${1:-} row rest
    want=${want^^}
    [[ $want == EX_* ]] || want="EX_${want}"
    for row in "${EX_TABLE_ROWS[@]}"; do
        rest=${row#*|}
        if [[ ${rest%%|*} == "$want" ]]; then
            printf '%s\n' "${row%%|*}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# ex_meaning CODE_OR_NAME
#   Print the one-line meaning. Accepts either form.
#   Exit 1 and print nothing if it is not one of ours.
# ---------------------------------------------------------------------------
ex_meaning() {
    local want=${1:-} code row rest
    if [[ $want =~ ^[0-9]+$ ]]; then
        code=$want
    else
        code=$(ex_code "$want") || return 1
    fi
    for row in "${EX_TABLE_ROWS[@]}"; do
        if [[ ${row%%|*} == "$code" ]]; then
            rest=${row#*|}
            printf '%s\n' "${rest#*|}"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# ex_describe CODE_OR_NAME
#   One line, for an error message or the last line of a transcript:
#       20 (EX_REBOOT): installed and pre-reboot checks passed; ...
#   Falls back to a truthful line for a code we do not own, because the worst
#   possible behaviour here is to be silent about an unexpected exit status.
# ---------------------------------------------------------------------------
ex_describe() {
    local want=${1:-} code name meaning
    if [[ $want =~ ^[0-9]+$ ]]; then
        code=$want
    else
        code=$(ex_code "$want") || code=''
    fi
    if [[ -n $code ]] && name=$(ex_name "$code"); then
        meaning=$(ex_meaning "$code")
        printf '%s (%s): %s\n' "$code" "$name" "$meaning"
        return 0
    fi
    printf '%s (unknown): not an exit code this installer defines\n' "$want"
    return 1
}

# ---------------------------------------------------------------------------
# ex_is_code CODE
#   True when CODE is one of ours. Prints nothing.
# ---------------------------------------------------------------------------
ex_is_code() {
    ex_name "${1:-}" >/dev/null 2>&1
}

# Run rather than sourced: print the table. Nothing else in lib/ is executable
# by design, but a table that can only be obtained by writing a shell script
# is a table that will be copied by hand and then drift.
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    ex_table
    exit 0
fi
