#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tests/release-gate.sh -- refuse a release whose evidence is missing or stale.
#
# WHY THIS IS NOT tests/check-*.sh
#   tests/run-gates.sh discovers every tests/check-*.sh and runs them all, on
#   every commit. This rule must not be in that set, and the reason is a real
#   workflow rather than a preference: tools/pin-upstream.sh writes a new
#   roles/tpot_install/vars/upstream-<ref>.yml the moment a ref is pinned, and
#   nobody has installed at that ref yet. A rule that demanded a dated run
#   immediately would fail every commit between pinning a ref and finishing an
#   install on it -- which is exactly the window in which the tree is being
#   worked on.
#
#   So it is a RELEASE gate. It runs on a tag, and it runs by hand, and it is
#   deliberately absent from the per-commit suite.
#
# WHAT IT ASSERTS
#   1. tests/MATRIX-STATUS.md exists and is not empty.
#   2. Every pinned ref the tree carries -- one per
#      roles/tpot_install/vars/upstream-<40 hex>.yml -- has a section in it.
#      A ref this installer can be pointed at with no dated run behind it is
#      precisely what "supported but never tested" means, and a release may
#      claim the first and not the second.
#   3. That section carries a date, and the date is not older than the
#      per-ref data file's own derived_at. A row measured BEFORE the pin data
#      it claims to be about describes a different ref's run.
#   4. VERSION is a plausible semantic version, and CHANGELOG.md has a heading
#      for it. A tag whose changelog does not mention it is a release nobody
#      can read the notes for.
#
# WHAT IT DOES NOT ASSERT
#   That every SUPPORTED platform has been run. It has not: ubuntu:26.04 is
#   supported by derivation from the pin and has never been installed, and
#   docs/compatibility.md says so. Demanding otherwise here would either block
#   every release or force the tree to lie about a platform, and this file is
#   not going to be the reason for either.
#
# EXIT: 0 clean, 1 findings, 3 could not run.
set -uo pipefail

ROOT=${GATE_SCAN_ROOT:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}
STATUS="$ROOT/tests/MATRIX-STATUS.md"
VARS="$ROOT/roles/tpot_install/vars"
findings=0

fail() { printf '   FAIL %s\n' "$(printf "$@")"; findings=$(( findings + 1 )); }
note() { printf '   ---- %s\n' "$(printf "$@")"; }

printf '== release-gate: the evidence a release claims is present and current\n'

if [[ ! -s $STATUS ]]; then
    fail 'tests/MATRIX-STATUS.md is missing or empty. A release may not claim a tested platform without it.'
    printf '   FAILED: %d finding(s).\n' "$findings"; exit 1
fi
status_text=$(cat -- "$STATUS")

shopt -s nullglob
refs=("$VARS"/upstream-*.yml)
shopt -u nullglob
checked=0
for f in "${refs[@]}"; do
    base=${f##*/}; ref=${base#upstream-}; ref=${ref%.yml}
    # upstream-default.yml is the shipped fallback, not a pin.
    [[ $ref =~ ^[0-9a-f]{40}$ ]] || { note 'skipping %s -- not a pinned ref' "$base"; continue; }
    checked=$(( checked + 1 ))

    # A HEADING that names the ref, not a mention of it. This distinction is
    # the whole gate, and getting it wrong made this file worthless: the first
    # version matched the ref ANYWHERE and then took the next `| Date |` row,
    # so a status file reading
    #
    #     Superseding the earlier pin <ref>, which was never run.
    #     ## <a completely different ref> x debian:13
    #     | Date | 2026-09-05 |
    #
    # passed a release whose pinned ref had no run at all -- it borrowed
    # another ref's date. Reproduced 2026-09-05 before this was rewritten.
    if ! grep -qE "^#+ .*${ref}" -- "$STATUS"; then
        if [[ $status_text == *"$ref"* ]]; then
            fail 'MATRIX-STATUS.md MENTIONS the pinned ref %s but has no section headed by it. A mention is not a run.' "$ref"
        else
            fail 'no section in MATRIX-STATUS.md names the pinned ref %s. Pinning a ref makes a platform SUPPORTED; only a dated run makes it TESTED.' "$ref"
        fi
        continue
    fi

    derived=$(sed -n 's/^[[:space:]]*derived_at:[[:space:]]*"\{0,1\}\([0-9-]\{10\}\).*/\1/p' "$f" | head -n 1)
    # The date from INSIDE that ref's own section: start at its heading, stop
    # at the next heading, and take the `| Date |` row between them. A date
    # that belongs to the next section is a different run.
    row=$(awk -v ref="$ref" '
        /^#+ / { inside = ($0 ~ ref) ? 1 : 0; next }
        inside && /^\| *Date *\|/ { print; exit }
    ' "$STATUS" | sed -n 's/.*| *\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\) *|.*/\1/p')

    if [[ -z $row ]]; then
        fail 'the section for %s carries no `| Date | YYYY-MM-DD |` row, so nothing dates the run.' "$ref"
    elif [[ -n $derived && $row < $derived ]]; then
        fail 'the run recorded for %s is dated %s, which is BEFORE the pin data it claims to describe (derived_at %s). That row is about a different measurement.' \
             "$ref" "$row" "$derived"
    else
        note 'ref %s: dated %s, pin data %s' "$ref" "$row" "${derived:-unrecorded}"
    fi
done
(( checked > 0 )) || fail 'no pinned ref data file was found under roles/tpot_install/vars/, so there is nothing a release could be about.'

version=$(head -n 1 -- "$ROOT/VERSION" 2>/dev/null | tr -d '[:space:]')
if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail 'VERSION reads %q, which is not MAJOR.MINOR.PATCH.' "$version"
elif ! grep -q -- "\[$version\]" "$ROOT/CHANGELOG.md" 2>/dev/null; then
    fail 'CHANGELOG.md has no heading for [%s]. A tag whose notes are missing is a release nobody can read.' "$version"
else
    note 'VERSION %s, and CHANGELOG.md has its heading' "$version"
fi

if (( findings )); then
    printf '   FAILED: %d finding(s).\n' "$findings"; exit 1
fi
printf '   ok (%d pinned ref(s) checked)\n' "$checked"
