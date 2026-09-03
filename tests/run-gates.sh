#!/usr/bin/env bash
# tests/run-gates.sh -- run every build gate and say honestly what happened.
#
# WHAT A GATE IS
#   Each tests/check-*.sh turns one promise of this product into a build
#   break: nothing prompts a human, no credential reaches a command line, the
#   customer this work derives from is named nowhere, the deleted
#   screen-scraping driver stays deleted, the locale is UTF-8, the three
#   copies of the variable surface agree, every written copy of the exit
#   table is the generated one, the README's notice is the real one, and every
#   path this tree names either exists or is declared absent in one registry
#   that is checked in both directions. Run this before every commit and in
#   CI.
#
# HOW GATES ARE FOUND
#   Every executable tests/check-*.sh, in name order. Nothing is listed here,
#   so a gate added tomorrow runs tomorrow without anyone remembering to add
#   it -- a runner with a hand-maintained list is a runner that silently
#   stops running the newest check.
#
# THE THREE VERDICTS, AND WHY SKIP IS NOT PASS
#   PASS    exit 0. The gate ran and found nothing.
#   FAIL    exit 1. The gate ran and found something. Its findings are above
#           the summary, with file and line.
#   SKIP    exit 3. The gate could not run: what it checks does not exist
#           yet. It is printed in the summary as its own verdict and never
#           counted as a pass, because "checked nothing" and "found nothing"
#           are different facts and only one of them is reassuring.
#   BROKEN  any other exit. The gate itself is wrong. Treated as a failure.
#
#   Exit status: 0 when nothing failed, 1 when anything failed or is broken.
#   With --strict a skip fails too, which is what a release build should use.
#
# THE LAST LINE REPORTS COUNTS, NOT A VERDICT IT HAS NOT EARNED
#   The summary ends "8 passed, 1 skipped", never "all gates passed" while
#   anything skipped. It used to say the latter -- seventy lines after this
#   same runner had printed "a skip checked nothing; it is not a pass" -- and
#   that is the untrue assertion every gate in this directory exists to
#   catch, committed by the tool doing the catching. The DEFAULT EXIT STATUS
#   is unchanged and still 0 on a skip: that is the deliberate choice
#   documented directly above, and --strict is how a release build reverses
#   it. Only the wording was wrong, and only the wording changed.
#
# --self-test: PROVING THE GATES CAN FAIL
#   A gate whose pattern matches nothing passes forever while checking
#   nothing, and it is worse than no gate at all because everyone downstream
#   believes the property holds. This mode builds a deliberately violating
#   tree in a temporary directory OUTSIDE the repository, points each gate at
#   it, and requires the gate to FAIL. Then it deletes it. A gate that passes
#   its own violating fixture is reported as UNSOUND, which is a failure.
#
#   The fixtures are written with `@@` inserted into every forbidden literal
#   and removed just before the file is written. Otherwise this file would
#   itself contain the strings the gates forbid -- a vendor name, a plain-C
#   locale, a flag that takes a password -- and running the gates over the
#   repository would fail on the runner. The gates read raw text on purpose;
#   this is the price, and it is a small one.
#
#   A gate with no fixture registered here is reported as UNPROVEN. That is
#   printed loudly but does not fail the run: a gate this file did not write
#   may carry its own proof, and claiming otherwise would be its own untrue
#   assertion.
#
# THE EXEMPTION INVENTORY, PRINTED AFTER EVERY RUN
#   A gate rule that fires on a line which is not a defect can be exempted
#   with a `gate-allow` marker naming that one rule and giving a reason;
#   tests/gate-common.sh holds the syntax, the parser and the rest of the
#   convention. Every such marker in the tree is listed at the end of a run,
#   with its file, line, rule and reason -- an exemption nobody can see is an
#   exemption nobody reviews, and one nobody reviews is permanent.
#
#   The list is also where two defects surface that no single gate can see,
#   because both are about a marker no gate ever looked at:
#     * a marker naming a rule id NO GATE OWNS -- a typo, or a rule that has
#       since been renamed or deleted. It silences nothing and reads as
#       though it does.
#     * a marker with no reason on a line no rule fired on.
#   Either fails the run. The rule ids are not listed here: each gate declares
#   its own with `gate_rule`, and this file collects the declarations while it
#   runs them, so a rule added tomorrow is known tomorrow.
#
# USAGE
#   tests/run-gates.sh [--strict] [--self-test] [--list]

set -uo pipefail

TESTS_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
REPO_ROOT=$(cd -- "$TESTS_DIR/.." && pwd)

# The gates' own helpers, for gate_files/gate_rel/gate_marker_scan. Sourcing
# them here rather than re-implementing the marker parser is the point of the
# convention: one parser, read the same way by the gates and by this summary.
. "$TESTS_DIR/gate-common.sh"

MODE='run'
STRICT=0
for arg in "$@"; do
    case $arg in
        --strict)    STRICT=1 ;;
        --self-test) MODE='self-test' ;;
        --list)      MODE='list' ;;
        -h|--help)
            grep '^#' -- "${BASH_SOURCE[0]}" | cut -c3-
            exit 0
            ;;
        *)
            printf 'run-gates.sh: unknown option %s\n' "$arg" >&2
            exit 2
            ;;
    esac
done

GATES=()
while IFS= read -r gate; do
    [[ -n $gate ]] && GATES+=("$gate")
done < <(find "$TESTS_DIR" -maxdepth 1 -type f -name 'check-*.sh' -printf '%f\n' 2>/dev/null \
         | LC_ALL=C.UTF-8 sort)

if (( ${#GATES[@]} == 0 )); then
    printf 'run-gates.sh: no tests/check-*.sh found. Nothing was checked.\n' >&2
    exit 2
fi

if [[ $MODE == list ]]; then
    printf '%s\n' "${GATES[@]}"
    exit 0
fi

# Each gate appends its `gate_rule` declarations here, so the inventory below
# knows which rule ids exist without a hand-maintained list in a third place.
RULES_FILE=$(mktemp "${TMPDIR:-/tmp}/tpot-gate-rules.XXXXXXXX") || exit 2
export GATE_RULES_OUT="$RULES_FILE"
CLEANUP=("$RULES_FILE")
trap 'rm -rf -- "${CLEANUP[@]}"' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# Fixtures for --self-test. Each writes a tree that MUST make its gate fail.
# `@@` is stripped from every heredoc before it is written; see the header.
# ---------------------------------------------------------------------------
_write() {
    # _write PATH  <<'EOF' ... EOF
    local path=$1 body
    mkdir -p -- "$(dirname -- "$path")"
    body=$(cat)
    printf '%s\n' "${body//@@/}" > "$path"
}

_fixture_check_no_tty() {
    local d=$1
    _write "$d/prompt.sh" <<'EOF'
#!/usr/bin/env bash
# A sentence about how we could not re@@ad the file must not trip the gate.
while IFS= re@@ad -r line; do echo "$line"; done < /etc/hostname
re@@ad -p "T-Pot dashboard password: " pw
EOF
    _write "$d/bare.sh" <<'EOF'
#!/usr/bin/env bash
re@@ad answer
EOF
}

_fixture_check_argv_hygiene() {
    local d=$1
    _write "$d/bad.sh" <<'EOF'
#!/usr/bin/env bash
ansible-playbook site.yml -e tpot_web_password="$TPOT_WEB_PASSWORD"
htpass@@wd -b -n "$user" "$pass"
/home/honeypot/install.sh -s -t h -@@u "$web_user" -@@p "$web_password" -b 24.04.1
EOF
    _write "$d/README.md" <<'EOF'
      --web-pass@@word PASSWORD   the dashboard password
EOF
}

_fixture_check_no_vendor() {
    local d=$1
    _write "$d/innocent.md" <<'EOF'
Precision, decision, incision, decisive, incisor. None of these may match.
EOF
    _write "$d/leak.yml" <<'EOF'
tenant: Taz@@illa
note: CI@@SO integration
endpoint: https://api.example.@@sk/v1/ioc
EOF
}

_fixture_check_no_expect() {
    local d=$1
    _write "$d/drive.exp" <<'EOF'
set time@@out 600
sp@@awn ./install.sh
EOF
    _write "$d/deps.sh" <<'EOF'
#!/usr/bin/env bash
apt-get install -y ex@@pect
EOF
}

_fixture_check_locale() {
    local d=$1
    _write "$d/good.sh" <<'EOF'
export LC@@_ALL=C.UTF-8
export LA@@NG=C.UTF-8
EOF
    _write "$d/bad.sh" <<'EOF'
export LC@@_ALL=C
export LA@@NG=C
EOF
}

_fixture_check_variable_surface() {
    local d=$1
    mkdir -p "$d/lib" "$d/inventories/example/group_vars"
    cp -- "$REPO_ROOT/lib/varschema.json" "$REPO_ROOT/lib/config.py" "$d/lib/" 2>/dev/null || return 1
    # The example inventory documents a key the schema does not define, and
    # is missing one the schema does.
    _write "$d/inventories/example/group_vars/all.yml" <<'EOF'
---
# tpot_os_user: honeypot
# tpot_invented_key: yes
EOF
}

_fixture_check_notice_doc() {
    local d=$1
    mkdir -p "$d/lib"
    cp -- "$REPO_ROOT/lib/notice.sh" "$REPO_ROOT/lib/exitcodes.sh" "$d/lib/" 2>/dev/null || return 1
    # A README that exists but carries no notice block is a failure, not a
    # skip: the notice is the one thing that keeps a reader off port 22.
    _write "$d/README.md" <<'EOF'
# tpot-automation

Install it and enjoy.
EOF
}

_fixture_check_exit_table() {
    local d=$1 begin end
    mkdir -p "$d/lib" "$d/docs"
    cp -- "$REPO_ROOT/lib/exitcodes.sh" "$d/lib/" 2>/dev/null || return 1
    begin='<!-- BEGIN GENERATED: exit-table -->'
    end='<!-- END GENERATED: exit-table -->'
    # One document carries the generated block correctly...
    {
        printf '# Exit codes\n\n%s\n```text\n' "$begin"
        LC_ALL=C.UTF-8 bash "$d/lib/exitcodes.sh" || exit 1
        printf '```\n%s\n' "$end"
    } > "$d/docs/exit-codes.md" || return 1
    # ...and the other has had one meaning quietly reworded in place, which
    # is the shape this drift really takes: a helpful edit to the copy
    # somebody was reading, never to the file it is generated from.
    {
        printf '# tpot-automation\n\n%s\n```text\n' "$begin"
        LC_ALL=C.UTF-8 bash "$d/lib/exitcodes.sh" \
            | sed 's/^  20  EX_REBOOT .*/  20  EX_REBOOT         installed; reboot whenever suits you/' \
            || exit 1
        printf '```\n%s\n' "$end"
    } > "$d/README.md" || return 1
    grep -q 'whenever suits you' -- "$d/README.md" || return 1
}

_fixture_check_references() {
    local d=$1
    # Both classes at once, because the gate exists for both and a proof that
    # exercised one would leave the other exactly as unverified as it was.
    #
    # (b) THE INVERSE, and the one that keeps recurring: the registry declares
    #     site.yml absent, here it EXISTS, and a document still calls it
    #     unwritten. That is the shape of the docs/firewall.md round.
    _write "$d/site.yml" <<'EOF'
---
- hosts: honeypothost
EOF
    _write "$d/docs/exit-codes.md" <<'EOF'
**The Ansible play does not exist in this tree.** `site.yml` is unwritten.
EOF
    # (a) A DANGLING REFERENCE. The `@@` matters here for a reason particular
    #     to this gate: without it THIS file would carry the dangling
    #     reference, and running the gates over the repository would fail on
    #     the runner. The gate rejects any token containing an "@", so the
    #     literal above is invisible to it and the file written from it is not.
    _write "$d/README.md" <<'EOF'
The variable reference is in docs/no-such-@@file.md.
EOF
}

_fixture_for() {
    case $1 in
        check-no-tty.sh)           printf '_fixture_check_no_tty' ;;
        check-argv-hygiene.sh)     printf '_fixture_check_argv_hygiene' ;;
        check-no-vendor.sh)        printf '_fixture_check_no_vendor' ;;
        check-no-expect.sh)        printf '_fixture_check_no_expect' ;;
        check-locale.sh)           printf '_fixture_check_locale' ;;
        check-variable-surface.sh) printf '_fixture_check_variable_surface' ;;
        check-notice-doc.sh)       printf '_fixture_check_notice_doc' ;;
        check-exit-table.sh)       printf '_fixture_check_exit_table' ;;
        check-references.sh)       printf '_fixture_check_references' ;;
        *)                         printf '' ;;
    esac
}

# ---------------------------------------------------------------------------
NAMES=(); VERDICTS=()
failures=0; skips=0; unproven=0; passes=0; proven=0

if [[ $MODE == self-test ]]; then
    scratch=$(mktemp -d "${TMPDIR:-/tmp}/tpot-gate-selftest.XXXXXXXX") || exit 2
    CLEANUP+=("$scratch")
    printf 'Negative proofs. Each gate is pointed at a deliberately violating\n'
    printf 'tree under %s and must FAIL.\n\n' "$scratch"

    for gate in "${GATES[@]}"; do
        fixture=$(_fixture_for "$gate")
        NAMES+=("$gate")
        if [[ -z $fixture ]]; then
            printf '== %-28s UNPROVEN -- no negative fixture is registered here.\n' "$gate"
            VERDICTS+=('UNPROVEN')
            unproven=$(( unproven + 1 ))
            continue
        fi
        dir="$scratch/${gate%.sh}"
        mkdir -p -- "$dir"
        if ! "$fixture" "$dir"; then
            printf '== %-28s BROKEN   -- its fixture could not be built.\n' "$gate"
            VERDICTS+=('BROKEN')
            failures=$(( failures + 1 ))
            continue
        fi
        out=$(GATE_SCAN_ROOT="$dir" "$TESTS_DIR/$gate" 2>&1)
        rc=$?
        if (( rc == 1 )); then
            printf '== %-28s ok       -- failed on its violating fixture, as it must.\n' "$gate"
            VERDICTS+=('PROVEN')
            proven=$(( proven + 1 ))
        else
            printf '== %-28s UNSOUND  -- exit %d on a tree that violates it. A gate that\n' "$gate" "$rc"
            printf '   cannot fail is worse than no gate: it reports a property nobody is checking.\n'
            printf '%s\n' "$out" | sed 's/^/   | /'
            VERDICTS+=('UNSOUND')
            failures=$(( failures + 1 ))
        fi
    done
else
    for gate in "${GATES[@]}"; do
        "$TESTS_DIR/$gate"
        rc=$?
        NAMES+=("$gate")
        case $rc in
            0) VERDICTS+=('PASS'); passes=$(( passes + 1 )) ;;
            1) VERDICTS+=('FAIL'); failures=$(( failures + 1 )) ;;
            3) VERDICTS+=('SKIP'); skips=$(( skips + 1 )) ;;
            *) VERDICTS+=("BROKEN($rc)"); failures=$(( failures + 1 )) ;;
        esac
        printf '\n'
    done
fi

printf '%s\n' '----------------------------------------------------------------'
for (( i = 0; i < ${#NAMES[@]}; i++ )); do
    printf '  %-28s %s\n' "${NAMES[i]}" "${VERDICTS[i]}"
done
printf '%s\n' '----------------------------------------------------------------'

if (( skips > 0 )); then
    printf '  %d gate(s) SKIPPED. A skip checked nothing; it is not a pass.\n' "$skips"
fi
if (( unproven > 0 )); then
    printf '  %d gate(s) UNPROVEN -- no negative fixture here. If they carry\n' "$unproven"
    printf '  their own, say so; otherwise they are unverified.\n'
fi

# ---------------------------------------------------------------------------
# Every live exemption in the tree. See the header for why this is printed
# unconditionally rather than on request.
# ---------------------------------------------------------------------------
declare -A RULE_OWNER=()
if [[ -s $RULES_FILE ]]; then
    while IFS=$'\t' read -r rid rgate rscope; do
        [[ -n $rid ]] || continue
        if [[ -n $rscope ]]; then
            RULE_OWNER[$rid]="$rgate, only in $rscope"
        else
            RULE_OWNER[$rid]="$rgate"
        fi
    done < "$RULES_FILE"
fi

printf '\n%s\n' 'Active exemptions -- every gate-allow marker in the tree:'
marker_count=0
marker_bad=0
while IFS= read -r mpath; do
    mrel=$(gate_rel "$mpath")
    while IFS=$'\t' read -r mline mid mreason; do
        [[ -n $mid ]] || continue
        marker_count=$(( marker_count + 1 ))
        if [[ -n ${RULE_OWNER[$mid]+set} ]]; then
            printf '  %s:%s\n      rule   %s  (%s)\n' "$mrel" "$mline" "$mid" "${RULE_OWNER[$mid]}"
        else
            printf '  %s:%s\n      rule   %s  !! NO GATE OWNS THIS RULE ID -- it silences nothing.\n' \
                "$mrel" "$mline" "$mid"
            marker_bad=$(( marker_bad + 1 ))
        fi
        if _gate_reason_ok "$mreason"; then
            printf '      why    %s\n' "$mreason"
        else
            printf '      why    !! NONE GIVEN. An exemption nobody explained is one nobody can review.\n'
            marker_bad=$(( marker_bad + 1 ))
        fi
    done < <(gate_marker_scan "$mpath")
done < <(gate_files)
if (( marker_count == 0 )); then
    printf '  (none -- no rule in this tree is exempted anywhere)\n'
else
    printf '  %d exemption(s). Each one is a rule this tree does not enforce on that line.\n' \
        "$marker_count"
fi
if (( marker_bad > 0 )); then
    printf '  %d defective marker(s) above. Fixing them is not optional: see the\n' "$marker_bad"
    printf '  exemption-marker section of tests/gate-common.sh.\n'
fi
printf '%s\n' '----------------------------------------------------------------'

# ---------------------------------------------------------------------------
# _tally -- the counts this run actually has, in the vocabulary of its mode.
#
# Every terminal line below is built from this and nothing else, so the last
# thing a reader sees can only ever be arithmetic over the verdict list
# printed above it. The line it replaced was a fixed string, "all gates
# passed", and a fixed string cannot know that one of them skipped.
# ---------------------------------------------------------------------------
_tally() {
    local parts=() out='' p
    if [[ $MODE == self-test ]]; then
        (( proven   > 0 )) && parts+=("$proven proven")
        (( unproven > 0 )) && parts+=("$unproven unproven")
        (( failures > 0 )) && parts+=("$failures unsound or broken")
    else
        (( passes   > 0 )) && parts+=("$passes passed")
        (( failures > 0 )) && parts+=("$failures failed")
        (( skips    > 0 )) && parts+=("$skips skipped")
    fi
    (( ${#parts[@]} > 0 )) || parts+=('nothing ran')
    for p in "${parts[@]}"; do
        [[ -n $out ]] && out+=', '
        out+=$p
    done
    printf '%s' "$out"
}

if (( failures > 0 )); then
    printf '  %s. NOT a clean run.\n' "$(_tally)"
    exit 1
fi
if (( marker_bad > 0 )); then
    printf '  %s -- but %d exemption marker(s) are defective, so the run is not clean.\n' \
        "$(_tally)" "$marker_bad"
    exit 1
fi
if (( STRICT && skips > 0 )); then
    printf '  %s. --strict: a skip is a failure here.\n' "$(_tally)"
    exit 1
fi
if (( skips > 0 )); then
    # The exit status is 0 by design (see the header). The wording is not
    # allowed to round that up into a claim that everything was checked.
    printf '  %s. NOT a clean run: %d gate(s) checked nothing, and a skip is\n' \
        "$(_tally)" "$skips"
    printf '  never a pass. Exit status is 0 by default here; --strict makes it 1.\n'
    exit 0
fi
if (( unproven > 0 )); then
    printf '  %s. Every gate with a fixture here failed it, as it must; the\n' "$(_tally)"
    printf '  unproven ones were not exercised by this file at all.\n'
    exit 0
fi
if [[ $MODE == self-test ]]; then
    printf '  %s. Every gate failed its own violating fixture, as it must.\n' "$(_tally)"
    exit 0
fi
printf '  %s. Every gate ran and found nothing.\n' "$(_tally)"
exit 0
