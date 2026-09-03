#!/usr/bin/env bash
# tests/check-no-vendor.sh -- no trace of the organisation this work derives from.
#
# WHY THIS GATE EXISTS
#   This installer was re-derived from a working one built for a single
#   customer. That original is full of that customer's names, hostnames and
#   endpoint shapes. None of it may reach this repository -- not in code, not
#   in a comment, not in an example, not in a file name -- and the reason is
#   not tidiness: git history is not retractable in practice. A name
#   committed and then deleted is still in the object store, in every clone
#   and in every fork of every clone. The check has to run before the commit,
#   which is what a build gate is.
#
# WHAT IS FORBIDDEN
#   Six identifier strings -- the organisation, its product, two related
#   names, the city and a locale tag -- matched CASE-INSENSITIVELY and
#   anywhere at all: code, comments, prose, examples, and the names of files
#   and directories.
#
#   Plus the shape of the customer's own API host, which is what the original
#   installer forwarded to. Three sub-rules, none of which needs the host's
#   real value to be written down here:
#     * a URL whose host carries one of the six strings;
#     * a URL under the customer's country top-level domain -- derived from
#       the locale tag that is already on the list, not from copying an
#       address out of the supplied material;
#     * a URL that carries a credential in its authority section -- a
#       user and a password before the "@" of the host -- which is a leak
#       shape regardless of whose host it is.
#
# THE LIST IS NOT WRITTEN OUT HERE
#   Every forbidden string appears below with its first character in a
#   one-character class -- [x]yz. The regex matches "xyz"; the file does not
#   contain it. Two things follow, and both are the point: this gate passes
#   over its own source, and a search of the published tree for the customer
#   finds nothing, INCLUDING the file whose job is to look for them. A gate
#   that had to exclude itself would be a gate with a hole in it.
#
# PRECISION, WHICH IS THE HARD PART
#   One of the six is a short string that occurs inside ordinary English
#   words. Each pattern therefore requires a NON-LETTER (or start of line)
#   immediately before it, so "incisor" and "incisors" do not match, while
#   the bare word, the word in parentheses, and the word hyphenated onto
#   another all do. tests/run-gates.sh --self-test asserts both directions
#   against precision, decision, incision, decisive and incisor.
#
#   One known and accepted false positive: a word from organic chemistry
#   beginning with one of the six strings would match. It is not a word this
#   project will ever use, and loosening the rule to exclude it would open a
#   hole in the rule that matters.
#
# NO ALLOWLIST
#   There is no marker for this gate. There is no legitimate reason for any
#   of these strings to be in this repository, including "to explain that it
#   must not be here" -- that explanation belongs in the workspace, which is
#   not published.
#
# EXIT: 0 clean, 1 findings, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'no-vendor' 'the customer this work derives from is named nowhere'

readonly BOUND='(^|[^A-Za-z])'

# regex <TAB> what a reader should be told when it fires
readonly -a FORBIDDEN=(
    "${BOUND}[t]azilla"$'\t''the customer organisation'
    "${BOUND}[c]iso"$'\t''the customer product noun'
    "${BOUND}[i]tacon"$'\t''a related organisation name'
    "${BOUND}[r]edbyte"$'\t''a related organisation name'
    "${BOUND}[b]ratislava"$'\t''the customer city'
    "${BOUND}[s]k[_-]SK"$'\t''the customer locale tag'
)

# A URL under the customer country TLD, and a URL carrying credentials.
readonly RE_CCTLD='https?://[A-Za-z0-9._~%+-]*\.[s]k([:/?#]|$)'
readonly RE_URLCRED='[a-z][a-z0-9+.-]*://[^/[:space:]"]*:[^/@[:space:]"]*@'

# --- File and directory names ----------------------------------------------
while IFS= read -r path; do
    rel=$(gate_rel "$path")
    for entry in "${FORBIDDEN[@]}"; do
        pattern=${entry%%$'\t'*}
        what=${entry#*$'\t'}
        if [[ $rel =~ $pattern ]]; then
            gate_fail "$rel" 0 'the PATH itself names %s.' "$what"
        fi
    done
done < <(gate_files)

# --- Contents ---------------------------------------------------------------
while IFS= read -r path; do
    rel=$(gate_rel "$path")
    GATE_CHECKED=$(( GATE_CHECKED + 1 ))

    for entry in "${FORBIDDEN[@]}"; do
        pattern=${entry%%$'\t'*}
        what=${entry#*$'\t'}
        while IFS= read -r hit; do
            [[ -n $hit ]] || continue
            gate_fail "$rel" "${hit%%:*}" \
                'names %s. Nothing from the supplied material may be committed, in any file: %s' \
                "$what" "${hit#*:}"
        done < <(grep -aniE -e "$pattern" -- "$path" 2>/dev/null || true)
    done

    while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        gate_fail "$rel" "${hit%%:*}" \
            'a URL under the customer country top-level domain: %s' "${hit#*:}"
    done < <(grep -aniE -e "$RE_CCTLD" -- "$path" 2>/dev/null || true)

    while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        gate_fail "$rel" "${hit%%:*}" \
            'a URL with a credential embedded in it: %s' "${hit#*:}"
    done < <(grep -aniE -e "$RE_URLCRED" -- "$path" 2>/dev/null || true)
done < <(gate_files)

gate_end
