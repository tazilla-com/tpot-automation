#!/usr/bin/env bash
# tests/check-stage-map.sh -- the play's stage-to-exit-code map is the
#                             documented one, and it is total.
#
# WHY THIS GATE EXISTS
#   install.sh communicates through its exit status, and lib/exitcodes.sh is
#   the source of truth for what each number MEANS. But the number a failed
#   install actually produces is chosen somewhere else: the play records which
#   stage it was in, its rescue writes `<code> <stage>` to
#   $RUNDIR/failure-class, and install.sh reads that file. So the mapping from
#   a stage to a code is a second, independent statement about the contract,
#   and it lives in three places:
#
#       roles/report/vars/main.yml   the map the MACHINE acts on
#       docs/exit-codes.md           the table a READER acts on
#       roles/*/tasks/*.yml          the stage names that actually occur
#
#   tests/check-exit-table.sh already keeps the rendered exit TABLE identical
#   everywhere it is written down. It cannot see this, because a stage map is
#   not a copy of that table -- it is a different fact about the same numbers,
#   and it can drift on its own while every copy of the table stays perfect.
#
# THE DRIFT THIS IS ACTUALLY FOR
#   Adding a role. Somebody writes roles/<name>, gives it
#   `tpot_stage: snapshot`, and does not add a row anywhere. Nothing breaks:
#   the play runs, and the day it fails in that role the stage is unknown to
#   the map, install.sh exits 40, and the operator is told "a bug in this
#   installer, file an issue" about an ordinary failure with a perfectly good
#   diagnosis sitting in the transcript. That is a silent contract regression,
#   it is invisible until the bad day, and check 3 below is the whole reason
#   this file was written.
#
# WHAT IS CHECKED
#   1. EVERY CODE IN THE MAP IS ONE lib/exitcodes.sh DEFINES. A map naming 17
#      would make install.sh fall back to 40 while the play believed it had
#      said something precise.
#   2. THE MAP AND docs/exit-codes.md AGREE, both directions. A stage in one
#      and not the other is documentation describing an installer that does
#      not exist, or an installer nobody documented.
#   3. THE MAP IS TOTAL OVER THE STAGES THAT OCCUR. Every literal
#      `tpot_stage: <name>` anywhere in the tree is a row in the map.
#
#   Check 3 scans the plays as well as the roles, which is why `init` is a row
#   -- site.yml sets it before any role has claimed a stage, so a failure in
#   the very first include really can report it. It maps to 40, and that is
#   the true answer rather than a gap: the play broke before it got far enough
#   to have a better one.
#
# WHAT IS DELIBERATELY NOT CHECKED
#   Whether each stage was given the RIGHT code. That is a judgement, it is
#   argued in docs/exit-codes.md's "Why that code" column, and a test that
#   asserted it would only be restating the map a third time.
#
# EXIT: 0 clean, 1 findings, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'stage-map' 'the play stage-to-exit-code map is the documented one, and total'

readonly MAP_FILE="$GATE_SCAN_ROOT/roles/report/vars/main.yml"
readonly DOC_FILE="$GATE_SCAN_ROOT/docs/exit-codes.md"
readonly EXITCODES="$GATE_SCAN_ROOT/lib/exitcodes.sh"

# The play slice may legitimately not exist -- this gate shipped alongside it,
# but a checkout of an earlier release has no roles/ at all. Skipping loudly is
# right there; skipping silently is what this directory exists to prevent.
if [[ ! -r $MAP_FILE ]]; then
    gate_skip 'roles/report/vars/main.yml does not exist, so there is no stage map to check. The play slice is not in this tree.'
fi
[[ -r $EXITCODES ]] || gate_skip 'lib/exitcodes.sh is missing; the codes cannot be validated against anything.'

# ---------------------------------------------------------------------------
# The codes lib/exitcodes.sh actually defines. Taken from the file's own
# accessor rather than by parsing it, so this gate cannot disagree with the
# source of truth about what the source of truth says.
# ---------------------------------------------------------------------------
declare -A VALID_CODE=()
while IFS= read -r code; do
    [[ -n $code ]] || continue
    VALID_CODE[$code]=1
done < <(LC_ALL=C.UTF-8 bash -c '. "$1" >/dev/null 2>&1; ex_codes' _ "$EXITCODES" 2>/dev/null)

if (( ${#VALID_CODE[@]} == 0 )); then
    gate_skip 'lib/exitcodes.sh produced no codes, so nothing could be validated against it.'
fi

# ---------------------------------------------------------------------------
# Source 1 -- the map the machine acts on.
#
# Parsed with a line matcher rather than a YAML parser on purpose: this gate
# must run on a box with no PyYAML, which is the same reason lib/matrix.sh
# reads support-matrix.yml with grep. The format it accepts is therefore also
# the format the map is required to keep -- two-space indented `name: number`
# under the key, one per line, no flow mapping.
# ---------------------------------------------------------------------------
declare -A MAP=()
in_map=0
while IFS= read -r line || [[ -n $line ]]; do
    if [[ $line =~ ^tpot_report_stage_exit_codes: ]]; then
        in_map=1
        continue
    fi
    (( in_map )) || continue
    # A new top-level key ends the mapping.
    [[ $line =~ ^[^[:space:]#] ]] && break
    [[ $line =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*$ ]] && continue
    if [[ $line =~ ^[[:space:]]+([a-z_][a-z0-9_]*):[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
        MAP[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
    fi
done < "$MAP_FILE"

if (( ${#MAP[@]} == 0 )); then
    gate_fail 'roles/report/vars/main.yml' 0 \
        'defines no tpot_report_stage_exit_codes entries this gate can read. Every failing stage would map to 40, so the play would report "a bug in this installer" for every ordinary failure.'
    gate_end
fi

# --- Check 1: every code is one lib/exitcodes.sh defines --------------------
for stage in $(printf '%s\n' "${!MAP[@]}" | LC_ALL=C.UTF-8 sort); do
    [[ -n ${VALID_CODE[${MAP[$stage]}]+set} ]] && continue
    gate_fail 'roles/report/vars/main.yml' 0 \
        'maps stage "%s" to %s, which lib/exitcodes.sh does not define. install.sh refuses a code it does not recognise and falls back to 40, so the play would be reporting a number that means nothing to the thing that reads it.' \
        "$stage" "${MAP[$stage]}"
done

# ---------------------------------------------------------------------------
# Source 2 -- the table a reader acts on. Rows look like
#
#     | `preflight` | 11 `EX_PREFLIGHT` | the same conditions as stage A/B ... |
#
# Only the first two columns are compared. The third is prose and is where the
# justification belongs; a gate that compared it would be asking a human to
# write the same sentence twice.
# ---------------------------------------------------------------------------
declare -A DOC=()
if [[ -r $DOC_FILE ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^\|[[:space:]]*\`([a-z_][a-z0-9_]*)\`[[:space:]]*\|[[:space:]]*([0-9]+)[[:space:]]+\`(EX_[A-Z_]+)\`[[:space:]]*\| ]]; then
            DOC[${BASH_REMATCH[1]}]=${BASH_REMATCH[2]}
        fi
    done < "$DOC_FILE"
else
    gate_info 'docs/exit-codes.md is not readable, so the documented half of the comparison was skipped.'
fi

# --- Check 2: the map and the document agree, both directions ---------------
if (( ${#DOC[@]} > 0 )); then
    for stage in $(printf '%s\n' "${!MAP[@]}" | LC_ALL=C.UTF-8 sort); do
        if [[ -z ${DOC[$stage]+set} ]]; then
            gate_fail 'docs/exit-codes.md' 0 \
                'does not document stage "%s", which roles/report/vars/main.yml maps to %s. A reader branching on this contract has no way to learn that stage exists.' \
                "$stage" "${MAP[$stage]}"
            continue
        fi
        [[ ${DOC[$stage]} == "${MAP[$stage]}" ]] && continue
        gate_fail 'docs/exit-codes.md' 0 \
            'documents stage "%s" as exit %s; roles/report/vars/main.yml maps it to %s. The map is what the installer DOES; the document is what somebody wrote their automation against.' \
            "$stage" "${DOC[$stage]}" "${MAP[$stage]}"
    done
    for stage in $(printf '%s\n' "${!DOC[@]}" | LC_ALL=C.UTF-8 sort); do
        [[ -n ${MAP[$stage]+set} ]] && continue
        gate_fail 'roles/report/vars/main.yml' 0 \
            'has no row for stage "%s", which docs/exit-codes.md documents as exit %s. The documented code would never be produced.' \
            "$stage" "${DOC[$stage]}"
    done
fi

# ---------------------------------------------------------------------------
# Check 3 -- the map is total over the stages that actually occur.
#
# This is the direction that catches somebody adding a role. It scans for the
# literal a role uses to claim a stage, everywhere in the tree, and requires a
# row for each. A stage set from a variable rather than a literal is invisible
# here and always will be -- which is a good reason for roles to keep setting
# it as a literal, and is said in roles/report/vars/main.yml.
# ---------------------------------------------------------------------------
declare -A SEEN=()
declare -A SEEN_WHERE=()
while IFS= read -r hit; do
    [[ -n $hit ]] || continue
    path=${hit%%:*}
    rest=${hit#*:}
    lineno=${rest%%:*}
    text=${rest#*:}
    [[ $text =~ tpot_stage:[[:space:]]*[\"\']?([a-z_][a-z0-9_]*)[\"\']?[[:space:]]*$ ]] || continue
    stage=${BASH_REMATCH[1]}
    SEEN[$stage]=1
    rel=$(gate_rel "$path")
    SEEN_WHERE[$stage]="${SEEN_WHERE[$stage]:+${SEEN_WHERE[$stage]}, }$rel:$lineno"
done < <(grep -rn --include='*.yml' --include='*.yaml' -- 'tpot_stage:' \
             "$GATE_SCAN_ROOT" 2>/dev/null | grep -v '/roles/report/vars/')

# `${!SEEN[@]}` on an empty associative array is an error under `set -u`, and
# the usual `${arr[@]+...}` guard cannot be combined with the `!` key
# expansion -- bash reads the two together as an indirection and reports
# "invalid variable name". Testing the length first is the form that works.
seen_keys=()
(( ${#SEEN[@]} > 0 )) && mapfile -t seen_keys < <(printf '%s\n' "${!SEEN[@]}" | LC_ALL=C.UTF-8 sort)
for stage in ${seen_keys[@]+"${seen_keys[@]}"}; do
    [[ -n $stage ]] || continue
    [[ -n ${MAP[$stage]+set} ]] && continue
    gate_fail 'roles/report/vars/main.yml' 0 \
        'has no row for stage "%s", which is set at %s. A failure there writes a class install.sh does not recognise, so an ordinary failure with a good diagnosis in the transcript is reported as exit 40 -- "a bug in this installer". Add the row here and in docs/exit-codes.md together.' \
        "$stage" "${SEEN_WHERE[$stage]}"
done

# The inverse is deliberately NOT a failure. A row for a stage nothing sets
# yet is how a role is prepared before it is written, and this project has
# shipped exactly that on purpose more than once. It is reported, because a
# row nobody can reach is still worth seeing.
for stage in $(printf '%s\n' "${!MAP[@]}" | LC_ALL=C.UTF-8 sort); do
    [[ -n ${SEEN[$stage]+set} ]] && continue
    gate_info 'stage "%s" (exit %s) is mapped but nothing sets it; no role claims that stage yet.' \
        "$stage" "${MAP[$stage]}"
done

GATE_CHECKED=${#MAP[@]}
gate_info '%d mapped stage(s), %d documented, %d actually set in the tree.' \
    "${#MAP[@]}" "${#DOC[@]}" "${#SEEN[@]}"
gate_end
