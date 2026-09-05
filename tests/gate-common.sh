# SPDX-License-Identifier: Apache-2.0
# tests/gate-common.sh -- shared machinery for the build gates.
#
# WHAT A GATE IS
#   Each tests/check-*.sh file turns one promise this product makes into a
#   build break. The promises are the kind that cannot be re-checked by
#   reading: "nothing in this tree ever asks a human a question", "no
#   credential ever reaches a command line", "the tenant this code was
#   derived from is not named anywhere".
#
#   A gate is only worth having if it fails when it should. A regex that
#   matches nothing passes on every tree, forever, and reports success while
#   checking nothing -- which is worse than having no gate, because everyone
#   downstream now believes the property holds. So every gate in this
#   directory ships with a NEGATIVE PROOF: tests/run-gates.sh --self-test
#   builds a violating file in a scratch directory OUTSIDE the repository,
#   runs the gate at it, requires a failure, and deletes it.
#
# THE BRACKETED-LETTER IDIOM
#   Several gates forbid a literal string. If the gate wrote that string
#   plainly it would match itself and could never be green, and excluding
#   itself is exactly the "matches nothing" failure above. So a forbidden
#   literal is written with its first character in a one-character class:
#
#       [r]ead    matches "read"    but the file does not contain "read"
#
#   The regex behaves identically; a grep over the published tree for the
#   forbidden word does not find this file. Every gate that uses it says so
#   in its own header.
#
# EXIT CODES
#   0  the gate passed
#   1  the gate failed -- findings were printed
#   3  the gate could not run: something it checks does not exist yet.
#      A skip is printed loudly and is NOT a pass. run-gates.sh reports it
#      separately and never counts it as success.
#   2  the gate itself is broken (bad usage, missing helper)
#
# THE EXEMPTION MARKER -- "gate-allow"
#   Every rule below is mechanical, and a mechanical rule eventually fires on
#   a line that is not a defect. The commonest case by far is PROSE THAT HAS
#   TO WRITE THE FORBIDDEN THING OUT IN ORDER TO FORBID IT: a comment warning
#   the reader never to set the locale to plain C has to contain the setting
#   it warns about.
#
#   A gate with no way to say that gets silenced by whoever hits it next --
#   the rule is loosened, or the file is excluded, or the gate is dropped from
#   CI -- and that is strictly worse than no gate, because the property is
#   still being claimed. So there is one exemption marker, with one syntax,
#   read by one parser here.
#
#   THE SYNTAX, and there is no other:
#
#       # gate-allow: <rule-id> <why, in words>
#
#   on the offending line itself, or on the line directly above it. The
#   comment character is whatever the file uses -- the marker is looked for as
#   text in the ORIGINAL file, because comments are stripped out before a gate
#   lexes anything. One marker per line; a second on the same line is not read.
#
#   THREE THINGS MAKE IT A MARKER, and all three are required:
#
#     1. THE RULE ID IS SPECIFIC. Not "this gate" -- one named rule. Each gate
#        declares the ids it owns with `gate_rule`; `tests/run-gates.sh`
#        collects those declarations and reports any marker naming an id no
#        gate owns. An exemption is a statement about one rule, so a marker
#        that silenced a whole gate would silence rules nobody considered.
#
#     2. THE REASON IS MANDATORY. A marker with no words after the id is a
#        FAILURE, and the message says why: an exemption whose reason nobody
#        wrote is an exemption nobody can review, re-check, or ever delete
#        with confidence. It becomes permanent by default. The bar is low on
#        purpose -- at least ten characters, at least one of them a letter --
#        because the point is that a human wrote a sentence, not that the
#        sentence is long.
#
#     3. THE RULE MUST ACTUALLY FIRE THERE. A marker on a line where its rule
#        found nothing is a FAILURE too. Code moves and rules change; a
#        surviving marker then reads as "this line is a known exception" when
#        it is nothing of the kind, and it silently pre-authorises whatever is
#        written on that line next.
#
#   SCOPE. A rule may be exempt-able everywhere, or in exactly one file.
#   `interactive-read` is the second kind: the one courtesy prompt lives in
#   lib/args.sh, and a marker for that rule anywhere else is a failure rather
#   than a licence. `gate_rule ID GLOB` declares the narrow form.
#
#   VISIBILITY. `tests/run-gates.sh` prints every live exemption in the tree
#   at the end of a run -- file, line, rule, reason. An exemption nobody can
#   see is an exemption nobody reviews.
#
#   WRITING ABOUT THE MARKER WITHOUT LEAVING ONE. Documentation has the same
#   problem the marker exists to solve. The parser only sees a marker when a
#   BARE LOWERCASE ID follows the colon, so prose writes the id as a
#   placeholder in angle brackets -- `gate-allow: <rule-id> ...`, as above --
#   and names the real id in an ordinary sentence beside it. Never write a
#   concrete id straight after the colon in a comment that is not itself an
#   exemption.
#
#   NOT AN ESCAPE HATCH FOR PRODUCT CODE. The marker's home case is prose. The
#   one exemption in this tree today is the other legitimate case -- a test
#   harness, where the -e values the argv rule objected to are file paths in a
#   temporary directory and there is no credential in the process at all. If
#   you are marking a line that runs during an install, the line is the defect.
#
# shellcheck shell=bash

if [[ -n ${_TPOT_GATE_COMMON_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_GATE_COMMON_SH_LOADED=1

GATE_TESTS_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
GATE_ROOT=$(cd -- "$GATE_TESTS_DIR/.." && pwd)
GATE_STRIP="$GATE_TESTS_DIR/gate-strip.py"

GATE_ID=''
GATE_TITLE=''
GATE_FAILURES=0
GATE_CHECKED=0
GATE_SKIP_REASON=''

# The root the gate scans. Overridable so the negative proofs can point a
# gate at a scratch tree outside the repository without copying the gate.
GATE_SCAN_ROOT="${GATE_SCAN_ROOT:-$GATE_ROOT}"

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
gate_begin() {
    GATE_ID=$1
    GATE_TITLE=$2
    GATE_FAILURES=0
    GATE_CHECKED=0
    GATE_SKIP_REASON=''
    printf '== %s: %s\n' "$GATE_ID" "$GATE_TITLE"
    if [[ ! -r $GATE_STRIP ]]; then
        printf '   BROKEN: %s is missing; the gate cannot lex anything.\n' "$GATE_STRIP" >&2
        exit 2
    fi
}

# gate_fail RELPATH LINE FMT [ARGS...]
gate_fail() {
    local path=$1 line=$2 fmt=$3
    shift 3
    GATE_FAILURES=$(( GATE_FAILURES + 1 ))
    if [[ -n $line && $line != 0 ]]; then
        printf '   FAIL %s:%s  ' "$path" "$line"
    else
        printf '   FAIL %s  ' "$path"
    fi
    # shellcheck disable=SC2059
    printf "$fmt\n" "$@"
}

gate_info() {
    local fmt=$1
    shift
    printf '   ---- '
    # shellcheck disable=SC2059
    printf "$fmt\n" "$@"
}

# gate_skip FMT [ARGS...] -- loud, and never a pass.
gate_skip() {
    local fmt=$1
    shift
    # shellcheck disable=SC2059
    GATE_SKIP_REASON=$(printf "$fmt" "$@")
    printf '   SKIP %s\n' "$GATE_SKIP_REASON"
    printf '   SKIP this gate checked NOTHING. It is not a pass.\n'
    exit 3
}

gate_end() {
    gate_check_markers
    if (( GATE_FAILURES > 0 )); then
        printf '   FAILED: %d finding(s) over %d file(s).\n' "$GATE_FAILURES" "$GATE_CHECKED"
        exit 1
    fi
    printf '   ok (%d file(s) checked)\n' "$GATE_CHECKED"
    exit 0
}

# ---------------------------------------------------------------------------
# Finding files
#
# `git` is deliberately not used: a gate must work on an exported tarball,
# in CI before a checkout is a work tree, and on the scratch trees the
# negative proofs build. The exclusions below are directories that hold
# generated or vendored content, never product source.
# ---------------------------------------------------------------------------
gate_files() {
    find "$GATE_SCAN_ROOT" \
            \( -name .git -o -name collections -o -name __pycache__ \
               -o -name .venv -o -name node_modules \) -prune -o \
            -type f \
            ! -name '*.pyc' ! -name '*.retry' \
            -print \
        | LC_ALL=C.UTF-8 sort
}

# gate_rel PATH -- the path as a reader of the repository would write it.
gate_rel() {
    printf '%s' "${1#"$GATE_SCAN_ROOT"/}"
}

# gate_kind PATH -> shell | md | yaml | python | json | other
gate_kind() {
    local path=$1 head
    case $path in
        *.sh|*.bash) printf 'shell'; return 0 ;;
        *.md)        printf 'md';    return 0 ;;
        *.yml|*.yaml) printf 'yaml'; return 0 ;;
        *.py)        printf 'python'; return 0 ;;
        *.json)      printf 'json';  return 0 ;;
        *.j2)        printf 'other'; return 0 ;;
    esac
    head=$(head -n 1 -- "$path" 2>/dev/null || true)
    case $head in
        '#!'*sh|'#!'*sh\ *|'#!'*/env\ *sh*) printf 'shell'; return 0 ;;
        '#!'*python*)                        printf 'python'; return 0 ;;
    esac
    printf 'other'
}

# gate_lex MODE PATH -- "lineno<TAB>kind<TAB>text" records.
gate_lex() {
    python3 "$GATE_STRIP" "$1" "$2"
}

# gate_lex_auto PATH -- lex a file in the mode its kind implies. Files with
# no code-bearing mode produce nothing, which is the point: a gate that
# scans prose as though it were code is the false-positive machine.
gate_lex_auto() {
    local path=$1
    case $(gate_kind "$path") in
        shell)  gate_lex shell "$path" ;;
        md)     gate_lex md "$path" ;;
        yaml)   gate_lex yaml "$path" ;;
        python) gate_lex raw "$path" ;;
        *)      : ;;
    esac
}

# ---------------------------------------------------------------------------
# The exemption marker -- the ONE parser
#
# Read the "THE EXEMPTION MARKER" section of this file's header first; it says
# what the convention is and why each half of it exists. This is the code, and
# it is deliberately the only implementation: three gates honour markers and
# all three go through here, so there is nothing for a fourth to reimplement
# slightly differently.
#
# The pieces:
#   gate_rule ID [GLOB]       a gate declares a rule id it owns, optionally
#                             narrowed to one file (a path glob, relative to
#                             the scan root).
#   gate_exempt PATH LINE ID  a gate asks whether a finding it just made is
#                             exempted here.
#   gate_check_markers        run from gate_end: every marker for an owned id
#                             that no finding consumed is reported. This is
#                             what makes a stale exemption a build break
#                             rather than a comment nobody re-reads.
#   gate_marker_scan PATH     every marker in one file, as records.
#
# A marker is recognised only when a BARE LOWERCASE ID follows the colon, so
# a line writing `gate-allow: <rule-id> ...` is documentation and not an
# exemption. That is what lets these files describe the convention.
# ---------------------------------------------------------------------------

# Rules this gate owns: id -> file glob ('' means any file).
declare -A GATE_RULE_SCOPE=()
GATE_RULE_IDS=()
# Markers a finding has consumed, keyed "rel:markerline:id".
declare -A GATE_MARKER_USED=()

GATE_M_ID=''
GATE_M_REASON=''

# gate_rule ID [SCOPE_GLOB] -- declare a rule id, and where its marker counts.
#
# Declaring is not optional: gate_exempt refuses an undeclared id (that is a
# bug in the gate, not in the tree), and gate_check_markers only polices ids
# somebody claimed. When GATE_RULES_OUT names a file, the declaration is
# appended to it -- that is how run-gates.sh learns the full set of rule ids
# without a hand-maintained list going stale in a third place.
gate_rule() {
    local id=$1 scope=${2:-}
    if [[ ! $id =~ ^[a-z][a-z0-9-]*$ ]]; then
        printf '   BROKEN: rule id %q is not a bare lowercase identifier.\n' "$id" >&2
        exit 2
    fi
    GATE_RULE_SCOPE[$id]=$scope
    GATE_RULE_IDS+=("$id")
    if [[ -n ${GATE_RULES_OUT:-} ]]; then
        printf '%s\t%s\t%s\n' "$id" "${GATE_ID:-?}" "$scope" >> "$GATE_RULES_OUT"
    fi
}

# _gate_reason_clean TEXT -- the reason with a closing comment delimiter and
# surrounding blanks removed. `-->` and `*/` and `#}` are the ones a marker in
# markdown, C-ish or Jinja context would end with.
_gate_reason_clean() {
    local r=$1
    r=${r#"${r%%[![:space:]]*}"}
    r=${r%"${r##*[![:space:]]}"}
    r=${r%-->}
    r=${r%\*/}
    r=${r%\#\}}
    r=${r%"${r##*[![:space:]]}"}
    printf '%s' "$r"
}

# _gate_reason_ok REASON -- true when a human plainly wrote something.
# Ten characters and one letter. The bar is low on purpose: this rejects an
# empty marker and a placeholder, and does not pretend to judge prose.
_gate_reason_ok() {
    local r=$1
    (( ${#r} >= 10 )) || return 1
    [[ $r == *[A-Za-z]* ]] || return 1
    return 0
}

# gate_marker_scan PATH -- "lineno<TAB>id<TAB>reason" for every marker in the
# file. Reads the ORIGINAL text: comments are gone by the time a gate lexes.
gate_marker_scan() {
    local path=$1 hit ln body
    [[ -r $path && -f $path ]] || return 0
    while IFS= read -r hit; do
        ln=${hit%%:*}
        body=${hit#*:}
        [[ $body =~ gate-allow:[[:space:]]*([a-z][a-z0-9-]*)[[:space:]]*(.*)$ ]] || continue
        printf '%s\t%s\t%s\n' "$ln" "${BASH_REMATCH[1]}" \
            "$(_gate_reason_clean "${BASH_REMATCH[2]}")"
    done < <(grep -anE 'gate-allow:[[:space:]]*[a-z]' -- "$path" 2>/dev/null || true)
}

# _gate_marker_at PATH LINE ID -- true when that exact line carries a marker
# for ID; sets GATE_M_REASON.
_gate_marker_at() {
    local path=$1 line=$2 id=$3 rec recln recid
    while IFS=$'\t' read -r recln recid GATE_M_REASON; do
        [[ $recln == "$line" && $recid == "$id" ]] || continue
        GATE_M_ID=$recid
        return 0
    done < <(gate_marker_scan "$path")
    GATE_M_REASON=''
    return 1
}

# gate_exempt PATH LINE ID -- the question a gate asks about a finding.
#
# TRUE means: do not report your own finding here. That covers two cases, and
# the distinction matters when reading the code:
#   * the line is properly exempted -- nothing is printed;
#   * the marker is present but DEFECTIVE (no reason) -- a failure describing
#     the defective marker has already been printed, and the caller adding its
#     own finding on the same line would only bury it.
# FALSE means: report normally. A marker used outside its rule's scope also
# returns false, and separately reports itself, because the underlying finding
# is real and must not be lost behind a marker that never applied.
gate_exempt() {
    local path=$1 line=$2 id=$3
    local rel from ln scope
    [[ -n $path && -n $line && $line != 0 ]] || return 1
    if [[ -z ${GATE_RULE_SCOPE[$id]+set} ]]; then
        printf '   BROKEN: rule %q was never declared with gate_rule.\n' "$id" >&2
        exit 2
    fi
    rel=$(gate_rel "$path")
    scope=${GATE_RULE_SCOPE[$id]}
    from=$(( line > 1 ? line - 1 : 1 ))
    for (( ln = from; ln <= line; ln++ )); do
        _gate_marker_at "$path" "$ln" "$id" || continue
        GATE_MARKER_USED["$rel:$ln:$id"]=1
        # shellcheck disable=SC2053
        if [[ -n $scope && $rel != $scope ]]; then
            gate_fail "$rel" "$ln" \
                'exempts rule "%s", which is exempt-able only in %s. Here the marker grants nothing, and the finding below stands.' \
                "$id" "$scope"
            return 1
        fi
        if ! _gate_reason_ok "$GATE_M_REASON"; then
            gate_fail "$rel" "$ln" \
                'exempts rule "%s" and gives no reason. Write one after the id: an exemption nobody explained is one nobody can review or ever delete, so it becomes permanent by default. Ten characters is enough.' \
                "$id"
            return 0
        fi
        return 0
    done
    return 1
}

# gate_check_markers -- called from gate_end. Every marker in the tree naming
# a rule this gate owns must have been consumed by a finding; one that was not
# is stale, and a stale exemption is exactly the thing that quietly
# pre-authorises whatever gets written on that line next.
gate_check_markers() {
    local path rel ln id reason scope
    (( ${#GATE_RULE_IDS[@]} > 0 )) || return 0
    while IFS= read -r path; do
        rel=$(gate_rel "$path")
        while IFS=$'\t' read -r ln id reason; do
            [[ -n $id ]] || continue
            [[ -n ${GATE_RULE_SCOPE[$id]+set} ]] || continue
            [[ -n ${GATE_MARKER_USED["$rel:$ln:$id"]:-} ]] && continue
            scope=${GATE_RULE_SCOPE[$id]}
            # shellcheck disable=SC2053
            if [[ -n $scope && $rel != $scope ]]; then
                gate_fail "$rel" "$ln" \
                    'exempts rule "%s", which is exempt-able only in %s. Here it is inert and misleading; delete it.' \
                    "$id" "$scope"
                continue
            fi
            if ! _gate_reason_ok "$reason"; then
                gate_fail "$rel" "$ln" \
                    'exempts rule "%s" and gives no reason, on a line where that rule found nothing. Both halves are wrong: delete it.' \
                    "$id"
                continue
            fi
            gate_fail "$rel" "$ln" \
                'exempts rule "%s", but that rule found nothing on this line or the one below it. The exemption is stale -- delete it. (%s)' \
                "$id" "$reason"
        done < <(gate_marker_scan "$path")
    done < <(gate_files)
}

# ---------------------------------------------------------------------------
# Shell function names defined anywhere in the tree.
#
# Used by the argv gate: passing a value to a shell FUNCTION starts no
# process, so it never reaches /proc. Passing the same value to an external
# command does.
# ---------------------------------------------------------------------------
gate_shell_functions() {
    local path
    while IFS= read -r path; do
        [[ $(gate_kind "$path") == shell ]] || continue
        gate_lex shell "$path"
    done < <(gate_files) \
        | cut -f3- \
        | grep -oE '(^|[;&|[:space:]])(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)' \
        | grep -oE '[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*\(\)' \
        | sed 's/[[:space:]]*()$//' \
        | LC_ALL=C.UTF-8 sort -u
}
