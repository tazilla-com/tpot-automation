#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tests/check-references.sh -- every path this tree names either exists, or is
#                              declared absent here. Both directions.
#
# WHY THIS GATE EXISTS
#   Two defects have reached this repository, one per round, and neither was
#   found by anything in this directory. They are mirror images:
#
#     (a) A DANGLING REFERENCE. A shipped file names a path that is not in the
#         tree. lib/preflight.sh prints a pointer to a document; a stranger
#         who clones this repository cannot open it. The tool is telling the
#         truth about its own design and a lie about what the reader can do
#         next.
#
#     (b) THE INVERSE, AND IT IS THE ONE THAT KEEPS BITING. A "not built yet"
#         list names something that now exists. Writing docs/firewall.md in
#         one round falsified seven statements in five files at a stroke --
#         every one of them true when it was written, and none of them
#         re-read. CHANGELOG.md says of its own not-built list that it "is
#         worth nothing the first time something is left off it"; it was wrong
#         in the other direction inside one round.
#
#   A list of what does not exist rots faster than any other prose in a
#   repository, because the event that falsifies it -- somebody doing the
#   work -- is the event nobody thinks to go and check prose over. So the list
#   is not prose here. It is the registry below, and this gate reads it in
#   both directions: a reference must resolve to something the registry
#   declares or to something on disk, and every path the registry declares
#   absent must actually be absent.
#
# WHY A REGISTRY, AND NOT "READ THE SENTENCE AROUND IT"
#   The obvious rule is to let a reference dangle when the prose next to it
#   already says the file is missing. That was tried and measured against this
#   tree before it was rejected, and it fails in both directions at once:
#
#     * The absence vocabulary is not reserved. "the key is absent", "python3
#       is not present", "a tier whose key is ABSENT" -- this tree says those
#       about configuration keys and packages far more often than about files.
#     * The phrase belongs to a DIFFERENT tree in the most important case.
#       tests/check-notice-doc.sh says "README.md does not exist yet" in a
#       message about the tree it was pointed at. README.md exists here. A
#       line-scoped cue rule reads that as a claim about this repository and
#       fires on a message that is correct.
#     * The list form defeats line scope anyway. README.md writes "What does
#       not exist yet -- none of these files are in the tree:" and then names
#       them in bullets underneath. The cue and the paths are never on the
#       same line, which is exactly the shape that produced defect (b).
#
#   So the cue rule would have missed the defect it was invented for while
#   firing on prose that is right. The registry is duller and it is checked,
#   which is the trade this gate wants: it is one place, it is named in the
#   failure message, and it cannot drift from itself.
#
#   The prose lists in README.md and CHANGELOG.md stay -- a reader needs them.
#   They are narrative. This registry is the copy that breaks the build, and
#   when an entry goes stale the failure enumerates every file and line in the
#   tree that cites that path, so whoever removes the entry is handed the
#   exact set of sentences to re-read.
#
# WHAT COUNTS AS A REFERENCE -- THE TOKEN GRAMMAR
#   Every file in the tree is scanned as text: code, comments, prose, error
#   messages, help output, fixtures. A candidate token is a maximal run of
#     A-Z a-z 0-9 . _ - / ~ @ * : < >
#   and it is then thrown away unless it survives all of the following. Each
#   exclusion is here because something in this tree hits it.
#
#     rejected            because                                example here
#     ------------------  -----------------------------------  --------------
#     contains :: with /  a URL, and its path is not ours      upstream links
#     contains ~ or @     a home-relative path, or an address  a maintainer
#     contains < or >     a placeholder, or a redirection      upstream-<ref>
#     starts with /       an absolute path on the host         /etc/os-release
#     contains * (inner)  a glob; it names a set, not a file   *.os-release
#     contains : (kept)   a port, a scheme, a shell default    TMPDIR default
#
#   One rewrite, not a rejection: a slashed token whose first segment is
#   ALL-CAPS and is not itself a top-level entry has that segment dropped. It
#   is a shell variable holding the repository root, and the reference is
#   what follows it. Without this the gate harness is invisible, because it
#   writes every path it touches through such a variable.
#
#   A trailing :NNN or :NNN-MMM is a line citation and is stripped before the
#   colon rule runs, so install.sh at a line number is still a reference to
#   install.sh. Leading and trailing runs of * are markdown emphasis and are
#   stripped before the glob rule runs, so a bold path is still a reference. A
#   trailing . , ; - is punctuation. A trailing / is remembered first -- it is
#   how prose says "directory" -- and then trimmed.
#
# THE ANCHOR RULE, WHICH IS WHAT KEEPS THIS PRECISE
#   A surviving token is a reference to THIS repository only if it is anchored
#   in this repository's own namespace:
#
#     * a token containing a slash, when its first segment is a top-level
#       entry of the tree or the first segment of a registry entry;
#     * a token with no slash, when the whole token is a top-level entry of
#       the tree or a registry entry that is itself slash-free.
#
#   That second half is narrow on purpose. lib/notice.sh contains the sentence
#   "and notes that ports repeat across editions": "notes" is an English verb,
#   and it is also the first segment of the one workspace record cited in this
#   tree. Anchoring bare words on the first segment of a registry entry would
#   fire there. Anchoring them on the whole entry does not, while "site.yml"
#   written bare in a sentence is still a reference, because site.yml is an
#   entry in its own right.
#
#   Measured on this tree the rule resolves 1006 references over 61 files with
#   not one false positive, and it was measured against a file written to
#   break it: a version like 24.04.1, a port like 64295/tcp, a release list
#   like 20.04/22.04/24.04, an option list like h/s/l/i/m/t, a sed expression,
#   an email address, a bracketed IPv6 socket, an English word with a slash in
#   it, and every upstream URL are all outside the anchor set and never reach
#   the filesystem check. Re-run that measurement if the grammar changes; the
#   count in this paragraph is the only thing here that goes stale quietly.
#
#   ITS BLIND SPOT, STATED PLAINLY: a dangling reference whose first segment
#   is neither in the tree nor in the registry is not seen. A typo in the
#   first segment is the realistic case. The alternative -- resolving every
#   slash-bearing token -- fires on TCP/IP and and/or, and a gate everyone
#   learns to ignore checks nothing at all.
#
# THE THREE LISTS, AND WHY THE THIRD IS NOT SYMMETRIC
#   KNOWN_ABSENT   paths this repository does not contain. Cross-checked BOTH
#                  ways: a reference to one is fine, and an entry that exists
#                  is a failure. This is the not-built list of record.
#   WORKSPACE      records kept in the project workspace, outside this
#                  repository, which shipped files cite as evidence. Named one
#                  by one, never by a pattern over a directory: a pattern on
#                  the first segment would swallow real dangling references
#                  under the same name. Also checked both ways, and an entry
#                  that turns up here is a worse failure than a stale one --
#                  it means workspace material got committed.
#   RUNTIME        paths a RUN creates in the working tree and no commit ever
#                  carries. Only the reference direction is checked, because
#                  existing is legitimate for these. In exchange each one must
#                  be covered by .gitignore, which is checked, so the list
#                  cannot be used to excuse a file that could be committed.
#
#   .gitignore IS IN SCOPE, WHICH IS A JUDGEMENT AND NOT AN OVERSIGHT. An
#   ignore file is the one file whose purpose is to name things that are not
#   in the repository, so it is the obvious candidate for an exclusion. It
#   does not get one: every anchored pattern in it resolves today, and an
#   ignore rule left behind after the thing it named was renamed is a real, if
#   small, defect this gate can see for free. When a rule must name something
#   only a run creates, that path belongs in RUNTIME -- where the two halves
#   check each other, because RUNTIME then requires the ignore rule to exist.
#   Excluding the file instead would be the move that quietly opens a hole.
#
# NO EXEMPTION MARKER
#   There is none, deliberately. The registry already is the escape hatch, and
#   a second mechanism would mean two places to look for the answer to "is
#   this file missing on purpose". If a reference must dangle, say so in the
#   registry with a reason, where the inverse check can see it.
#
#   Prose in this file therefore writes a hypothetical path with an
#   angle-bracket placeholder -- docs/<name>.md -- the same device
#   tests/gate-common.sh uses to write about its own marker without leaving
#   one. The grammar above rejects it, so this header describes the rule
#   without tripping it.
#
# MAINTAINING IT
#   Creating a file in the registry: delete its entry in the same commit. The
#   failure tells you which files cite it; re-read every one.
#   Adding a reference to something not yet written: add an entry with a
#   reason. The reason is the not-built list's actual content.
#
# EXIT: 0 clean, 1 findings, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'references' 'every path named here exists, or is declared absent here'

# ---------------------------------------------------------------------------
# THE REGISTRY. path <TAB> why this repository does not contain it.
#
# This is the not-built list that breaks the build. Keep the reasons specific:
# they are what a reader gets instead of the file.
# ---------------------------------------------------------------------------
readonly -a KNOWN_ABSENT=(
    "tests/fixtures"$'\t'"the /proc fixtures a preflight test would substitute for the real ones; the unit suite exists and builds its fixtures in its own scratch instead, so nothing needs this path yet"
    ".github"$'\t'"the CI workflows, including the release gate that refuses a tag while the matrix status is missing or stale"
    "docs/answer-file.md"$'\t'"the answer-file reference, cited by lib/config.py"
    "docs/variables.md"$'\t'"the variable reference, cited by lib/config.py"
    "docs/verification.md"$'\t'"what verification asserts, cited by lib/preflight.sh"
    "docs/roadmap-ioc.md"$'\t'"the reserved IoC namespace and when it is planned, cited by both example answer files and the example inventory"
)

# Project-workspace records, named individually. Cited as evidence by shipped
# files; the repository never carries them.
readonly -a WORKSPACE=(
    "notes/upstream-facts.md"$'\t'"the project's record of what upstream's own installer does, read from its source; it is kept in the workspace beside this repository and is not published with it"
)

# Created by a run, never committed. Must be covered by .gitignore.
readonly -a RUNTIME=(
    "inventories/local/hosts.yml"$'\t'"the inventory install.sh generates on every run"
)

declare -A ABSENT_WHY=() WORKSPACE_WHY=() RUNTIME_WHY=()
declare -A CITES=()
_load() {
    local -n _out=$1
    shift
    local entry
    for entry in "$@"; do
        _out["${entry%%$'\t'*}"]="${entry#*$'\t'}"
    done
}
_load ABSENT_WHY    "${KNOWN_ABSENT[@]}"
_load WORKSPACE_WHY "${WORKSPACE[@]}"
_load RUNTIME_WHY   "${RUNTIME[@]}"

# ---------------------------------------------------------------------------
# The anchor set. See THE ANCHOR RULE in the header: bare tokens and slashed
# tokens are anchored differently, and the difference is the whole reason the
# false-positive count is zero.
# ---------------------------------------------------------------------------
declare -A ANCHOR_BARE=() ANCHOR_SEG=()
while IFS= read -r name; do
    [[ -n $name ]] || continue
    ANCHOR_BARE[$name]=1
    ANCHOR_SEG[$name]=1
done < <(find "$GATE_SCAN_ROOT" -maxdepth 1 -mindepth 1 -not -name .git -printf '%f\n' 2>/dev/null)

for entry in "${!ABSENT_WHY[@]}" "${!WORKSPACE_WHY[@]}" "${!RUNTIME_WHY[@]}"; do
    ANCHOR_SEG["${entry%%/*}"]=1
    [[ $entry == */* ]] || ANCHOR_BARE[$entry]=1
done

if (( ${#ANCHOR_SEG[@]} == 0 )); then
    gate_skip 'nothing at the top level of %s, so no reference can be anchored.' "$GATE_SCAN_ROOT"
fi

# ---------------------------------------------------------------------------
# Scan. The token pass is one awk over every text file: a bash loop over the
# ~100k raw tokens in this tree takes minutes, and awk takes 70ms. The anchor
# sets are handed to awk as its first input file so that a file name
# containing a space cannot break the hand-off.
# ---------------------------------------------------------------------------
TMPBASE=$(mktemp -d "${TMPDIR:-/tmp}/tpot-gate-refs.XXXXXXXX") || exit 2
trap 'rm -rf -- "$TMPBASE"' EXIT INT TERM HUP

for name in "${!ANCHOR_BARE[@]}"; do printf 'B\t%s\n' "$name"; done > "$TMPBASE/anchors"
for name in "${!ANCHOR_SEG[@]}";  do printf 'S\t%s\n' "$name"; done >> "$TMPBASE/anchors"

FILES=()
BINARY=0
while IFS= read -r path; do
    # An empty file names nothing. A binary one has no references either, and
    # awk over one produces noise; there are none in this tree today, and this
    # keeps that from becoming a surprise rather than a silent change.
    [[ -s $path ]] || continue
    if ! grep -Iq . -- "$path" 2>/dev/null; then
        BINARY=$(( BINARY + 1 ))
        continue
    fi
    FILES+=("$path")
done < <(gate_files)

if (( ${#FILES[@]} == 0 )); then
    gate_skip 'no readable text file under %s.' "$GATE_SCAN_ROOT"
fi
GATE_CHECKED=${#FILES[@]}

awk '
BEGIN { FS = "\t" }
FILENAME == ANCHORS {
    if ($1 == "B") bare[$2] = 1; else seg[$2] = 1
    next
}
{
    s = $0
    while (match(s, /[A-Za-z0-9._\/~@*:<>-]+/)) {
        t = substr(s, RSTART, RLENGTH)
        s = substr(s, RSTART + RLENGTH)

        # A token cut short by an interpolation is HALF a path, and resolving
        # the half is a false positive every time. `$` is not in the token
        # character class, so `vars/upstream-${ref}.yml` yields the token
        # `vars/upstream-`, whose trailing hyphen the punctuation trim below
        # then removes -- leaving `vars/upstream`, a file that has no reason
        # to exist and never will. The same happens to a Jinja `{{ ... }}`.
        #
        # Look at the character the token stopped on rather than at the token:
        # nothing about `vars/upstream-` says it was truncated, and everything
        # about the `$` that follows it does. Found when tools/pin-upstream.sh
        # landed and reported two dangling references to a path it prints
        # correctly at run time.
        nextch = substr(s, 1, 1)
        if (nextch == "$" || nextch == "{") continue

        if (t ~ /:\/\//) continue              # a URL
        if (t ~ /[~@]/)  continue              # home-relative, or an address
        if (t ~ /[<>]/)  continue              # a placeholder, or a redirection
        if (t ~ /^\//)   continue              # absolute: a path on the host

        sub(/^\*+/, "", t); sub(/\*+$/, "", t) # markdown emphasis
        if (t ~ /\*/)    continue              # a glob names a set, not a file

        sub(/:[0-9]+(-[0-9]+)?$/, "", t)       # a file:line citation
        if (t ~ /:/)     continue              # a port, a scheme, a default

        slashed = (t ~ /\//)                   # a trailing / says "directory"
        sub(/[.,;\/-]+$/, "", t)
        if (t == "")     continue

        if (slashed) { first = t; sub(/\/.*$/, "", first) } else { first = t }

        # A shell variable holding the repository root: $REPO_ROOT/lib/... .
        # An ALL-CAPS first segment that is not itself a top-level entry is a
        # variable name, never a directory in this tree, so the reference is
        # what follows it. Dropping this rule loses every path in the gate
        # harness, which writes all of them that way.
        if (slashed && first ~ /^[A-Z][A-Z0-9_]*$/ && !(first in seg)) {
            sub(/^[^\/]*\//, "", t)
            if (t == "") continue
            slashed = (t ~ /\//)
            if (slashed) { first = t; sub(/\/.*$/, "", first) } else { first = t }
        }

        if (slashed) { if (!(first in seg))  continue }
        else         { if (!(t in bare))     continue }

        print FILENAME "\t" FNR "\t" t
    }
}' ANCHORS="$TMPBASE/anchors" "$TMPBASE/anchors" "${FILES[@]}" \
    | LC_ALL=C.UTF-8 sort -u -t"$(printf '\t')" -k1,1 -k2,2n -k3,3 > "$TMPBASE/refs"

# ---------------------------------------------------------------------------
# Resolve. A reference is fine when it is on disk, or when the registry
# declares it -- directly, or through a prefix, because nothing under a
# directory that does not exist can exist either.
# ---------------------------------------------------------------------------
REF_TOTAL=0
REF_ON_DISK=0
REF_DECLARED=0

_declared_prefix() {
    local p=$1
    while :; do
        if [[ -n ${ABSENT_WHY[$p]+set} || -n ${WORKSPACE_WHY[$p]+set} || -n ${RUNTIME_WHY[$p]+set} ]]; then
            printf '%s' "$p"
            return 0
        fi
        [[ $p == */* ]] || return 1
        p=${p%/*}
    done
}

while IFS=$'\t' read -r path lineno token; do
    [[ -n $token ]] || continue
    rel=$(gate_rel "$path")
    REF_TOTAL=$(( REF_TOTAL + 1 ))
    # The citation is recorded BEFORE the on-disk test, not after it. A
    # reference to a registry path that HAS been written resolves on disk and
    # would otherwise be recorded nowhere -- which is precisely the moment the
    # citation list is wanted, because that is the moment the entry goes stale
    # and every sentence citing it becomes untrue. Recording only unresolved
    # references made the stale-absence failure report "none in this tree"
    # while three files named the path; found by the negative proof, not by
    # reading.
    if declared=$(_declared_prefix "$token"); then
        CITES[$declared]+="${CITES[$declared]:+ }$rel:$lineno"
    fi
    if [[ -e $GATE_SCAN_ROOT/$token ]]; then
        REF_ON_DISK=$(( REF_ON_DISK + 1 ))
        continue
    fi
    if [[ -n $declared ]]; then
        REF_DECLARED=$(( REF_DECLARED + 1 ))
        continue
    fi
    gate_fail "$rel" "$lineno" \
        'names "%s", which is not in this tree. A reader who clones this repository cannot open it. Either write the file, or add it to the registry in tests/check-references.sh with a reason -- the registry is the one place this repository says a path is missing on purpose, and it is checked in both directions.' \
        "$token"
done < "$TMPBASE/refs"

# ---------------------------------------------------------------------------
# The inverse. This is the direction that keeps being got wrong, so it runs
# over the registry itself and not over anything a reference happened to
# mention: an entry nobody cites is checked too.
# ---------------------------------------------------------------------------
for entry in "${!ABSENT_WHY[@]}"; do
    [[ -e $GATE_SCAN_ROOT/$entry ]] || continue
    gate_fail 'tests/check-references.sh' 0 \
        'the registry declares "%s" absent -- and it EXISTS. Every sentence in this tree that calls it unwritten is now untrue. Delete the entry, and re-read these citations: %s' \
        "$entry" "${CITES[$entry]:-none in this tree; the entry is simply stale}"
done

for entry in "${!WORKSPACE_WHY[@]}"; do
    [[ -e $GATE_SCAN_ROOT/$entry ]] || continue
    gate_fail 'tests/check-references.sh' 0 \
        '"%s" is a project-workspace record, and it is IN THIS REPOSITORY. Workspace material is not published: remove it here, and if the citation still needs evidence, quote the finding rather than shipping the record. Cited from: %s' \
        "$entry" "${CITES[$entry]:-nowhere}"
done

# The runtime list buys its asymmetry by being unable to hide a committable
# file: each entry must be matched by a .gitignore rule.
GITIGNORE="$GATE_SCAN_ROOT/.gitignore"
if [[ -r $GITIGNORE ]]; then
    for entry in "${!RUNTIME_WHY[@]}"; do
        covered=0
        probe=$entry
        while :; do
            while IFS= read -r rule; do
                case $rule in
                    "$probe"|"$probe/"|"$probe/*"|"$probe/**") covered=1; break ;;
                esac
            done < <(grep -v '^[[:space:]]*[#!]' -- "$GITIGNORE" | sed 's/[[:space:]]*$//')
            (( covered )) && break
            [[ $probe == */* ]] || break
            probe=${probe%/*}
        done
        (( covered )) && continue
        gate_fail '.gitignore' 0 \
            'does not ignore "%s", which the registry in tests/check-references.sh calls run-time-only and therefore exempts from the existence check. Untracked by nothing is not untracked: either ignore it, or move it to KNOWN_ABSENT where its absence is enforced.' \
            "$entry"
    done
elif (( ${#RUNTIME_WHY[@]} > 0 )); then
    gate_info 'no .gitignore under %s: the ignore-coverage of %d run-time path(s) was NOT checked.' \
        "$GATE_SCAN_ROOT" "${#RUNTIME_WHY[@]}"
fi

# ---------------------------------------------------------------------------
# The inventory, printed every run for the same reason run-gates.sh prints
# every exemption: a list of what this product does not have is only worth
# something while somebody is looking at it.
# ---------------------------------------------------------------------------
gate_info '%d path reference(s) resolved: %d on disk, %d declared absent.' \
    "$REF_TOTAL" "$REF_ON_DISK" "$REF_DECLARED"
(( BINARY > 0 )) && gate_info '%d binary file(s) were not scanned for references.' "$BINARY"
gate_info 'Declared absent -- the not-built list of record:'
for entry in $(printf '%s\n' "${!ABSENT_WHY[@]}" | LC_ALL=C.UTF-8 sort); do
    n=0
    for _ in ${CITES[$entry]:-}; do n=$(( n + 1 )); done
    gate_info '  %-24s cited %2d time(s)  %s' "$entry" "$n" "${ABSENT_WHY[$entry]}"
done
for entry in $(printf '%s\n' "${!WORKSPACE_WHY[@]}" | LC_ALL=C.UTF-8 sort); do
    n=0
    for _ in ${CITES[$entry]:-}; do n=$(( n + 1 )); done
    gate_info '  %-24s cited %2d time(s)  workspace record, outside this repository' "$entry" "$n"
done
for entry in $(printf '%s\n' "${!RUNTIME_WHY[@]}" | LC_ALL=C.UTF-8 sort); do
    gate_info '  %-24s run-time only     %s' "$entry" "${RUNTIME_WHY[$entry]}"
done

gate_end
