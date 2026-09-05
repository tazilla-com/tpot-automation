#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tests/check-notice-doc.sh -- the README's notice block is the real one.
#
# WHAT THE NOTICE IS
#   A finished T-Pot box has one property that will lock a stranger out of
#   their own machine: the host's administrative sshd moves to tcp/64295 and
#   tcp/22 is taken over by a honeypot that ACCEPTS the connection and answers
#   as though it were a real system. Somebody who logs out without reading
#   that will reconnect on 22, appear to succeed, and be talking to a decoy.
#
#   lib/notice.sh is the single copy of the text that says so. install.sh
#   prints it, lib/result.sh copies it into result.json, and README.md
#   embeds it so a reader knows before they start.
#
# WHY IT IS A BUILD GATE AND NOT A CONVENTION
#   A README that describes ports the installer does not use is worse than a
#   README with no ports in it: the reader trusts it, writes the wrong number
#   down, and locks themselves out. Documentation drift is normally a
#   cosmetic problem; here it is the failure the notice exists to prevent.
#   So the two copies are compared byte for byte, and there is no tolerance
#   for whitespace, wrapping or a "clearer" rewording -- reword lib/notice.sh
#   and let the README follow.
#
# THE MARKERS
#   README.md carries, at the point the block belongs:
#
#       <!-- BEGIN GENERATED NOTICE - tests/check-notice-doc.sh -->
#       ```
#       ...the output of notice_canonical, verbatim...
#       ```
#       <!-- END GENERATED NOTICE -->
#
#   The fenced block is optional as far as this gate is concerned -- with or
#   without it the bytes must match -- but it is what keeps Markdown from
#   reflowing the text, so use it.
#
#   `tests/check-notice-doc.sh --print` writes exactly that block to stdout,
#   ready to paste. That is the supported way to update the README after
#   changing lib/notice.sh.
#
# WHAT MAKES IT SKIP, AND WHY A SKIP IS SHOUTED
#   A missing README.md, and nothing else. That skip is shouted rather than
#   taken as a quiet exit 0, because a gate that reports success while its
#   subject is absent is the exact failure this directory is built to avoid:
#   it would report green for as long as the README stayed missing, and then
#   keep reporting green for the first README that arrived with a hand-typed
#   notice in it.
#
#   README.md exists, so this gate does not skip -- it compares, and a
#   MISSING BLOCK IS A FAILURE rather than a skip: a README without the
#   notice is a README that does not carry the one sentence that keeps a
#   reader out of trouble.
#
# EXIT: 0 clean, 1 findings, 2 usage/broken, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

readonly BEGIN_MARK='<!-- BEGIN GENERATED NOTICE - tests/check-notice-doc.sh -->'
readonly END_MARK='<!-- END GENERATED NOTICE -->'
readonly README="$GATE_SCAN_ROOT/README.md"
readonly NOTICE_SH="$GATE_SCAN_ROOT/lib/notice.sh"
readonly EXITCODES_SH="$GATE_SCAN_ROOT/lib/exitcodes.sh"

_canonical() {
    (
        set +u
        cd -- "$GATE_SCAN_ROOT" || exit 1
        [[ -r ./lib/exitcodes.sh ]] && . ./lib/exitcodes.sh >/dev/null 2>&1
        . ./lib/notice.sh >/dev/null 2>&1 || exit 1
        notice_canonical
    )
}

_block() {
    printf '%s\n' "$BEGIN_MARK"
    printf '```\n'
    _canonical
    printf '```\n'
    printf '%s\n' "$END_MARK"
}

if [[ ${1:-} == '--print' ]]; then
    if [[ ! -r $NOTICE_SH ]]; then
        printf 'check-notice-doc.sh: %s is missing.\n' "$NOTICE_SH" >&2
        exit 2
    fi
    _block
    exit 0
fi

gate_begin 'notice-doc' 'the README notice block is byte-identical to lib/notice.sh'

if [[ ! -r $NOTICE_SH ]]; then
    gate_fail 'lib/notice.sh' 0 'is missing. It is the single copy of the text install.sh prints, result.json records and README.md embeds.'
    gate_end
fi
[[ -r $EXITCODES_SH ]] || gate_info 'lib/exitcodes.sh is missing; lib/notice.sh was sourced without it.'

canonical=$(_canonical) || canonical=''
if [[ -z ${canonical//[[:space:]]/} ]]; then
    gate_fail 'lib/notice.sh' 0 \
        'produced nothing from notice_canonical. Whatever the README says, it cannot be checked against a notice that does not render.'
    gate_end
fi

if [[ ! -r $README ]]; then
    gate_skip 'README.md does not exist yet, so there is nothing to compare the notice against. When it lands it must carry the block between %s and %s -- run "tests/check-notice-doc.sh --print" to get it verbatim.' \
        "$BEGIN_MARK" "$END_MARK"
fi

GATE_CHECKED=1

begin_line=$(grep -nF -e "$BEGIN_MARK" -- "$README" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
end_line=$(grep -nF -e "$END_MARK" -- "$README" 2>/dev/null | head -n 1 | cut -d: -f1 || true)

if [[ -z $begin_line || -z $end_line ]]; then
    gate_fail 'README.md' 0 \
        'does not carry the generated notice block. Paste the output of "tests/check-notice-doc.sh --print" where the block belongs; the markers are %s and %s.' \
        "$BEGIN_MARK" "$END_MARK"
    gate_end
fi
if (( end_line <= begin_line )); then
    gate_fail 'README.md' "$end_line" 'the end marker is at or above the begin marker.'
    gate_end
fi

# The bytes between the markers, with one optional fence stripped from each end.
embedded=$(sed -n "$(( begin_line + 1 )),$(( end_line - 1 ))p" -- "$README")
embedded=${embedded#$'\n'}
embedded=${embedded%$'\n'}
first=${embedded%%$'\n'*}
last=${embedded##*$'\n'}
if [[ $first == '```'* && $last == '```'* ]]; then
    embedded=${embedded#*$'\n'}
    embedded=${embedded%$'\n'*}
fi

if [[ $embedded == "$canonical" ]]; then
    gate_end
fi

gate_fail 'README.md' "$(( begin_line + 1 ))" \
    'the embedded notice differs from what lib/notice.sh renders. Replace the block with the output of "tests/check-notice-doc.sh --print"; do not edit it in place.'
gate_info 'first differing line:'
diff_out=$(diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$embedded") 2>/dev/null | head -n 12 || true)
if [[ -n $diff_out ]]; then
    printf '%s\n' "$diff_out" | while IFS= read -r l; do printf '        %s\n' "$l"; done
fi
gate_end
