#!/usr/bin/env bash
# tests/check-exit-table.sh -- every written copy of the exit table is the
# generated one.
#
# WHAT THE EXIT TABLE IS
#   install.sh communicates through its exit status, and that status is the
#   product: a caller -- cloud-init, Packer, a CI job, somebody's shell
#   script -- has to branch on the outcome without parsing English. The
#   numbers and their meanings are written down once, in lib/exitcodes.sh,
#   whose EX_TABLE_ROWS array is the source of truth and whose `ex_table`
#   renders it.
#
#   Four things then repeat it, and until this gate existed nothing kept them
#   together:
#
#       bash lib/exitcodes.sh    the source, rendered
#       install.sh --help        renders it live, by calling ex_table
#       docs/exit-codes.md       a block between generated markers
#       README.md                the same block again
#
#   They were byte-identical when this gate was written, and byte-identical
#   by hand is a state, not a property. lib/exitcodes.sh's own header already
#   claimed the copies were "diffed against this file in CI"; docs and README
#   said the opposite in plainer words -- that no such check had been built.
#   This is that check.
#
# WHY IT IS A BUILD GATE AND NOT A CONVENTION
#   A documented exit code that does not match the code is worse than an
#   undocumented one. The reader writes `if rc -eq 20` into their automation
#   on the strength of a table, and a table that has drifted sends a fleet of
#   machines down the wrong branch silently -- no error, no diagnostic, just
#   a caller that believes an unfinished install finished. Documentation
#   drift is usually cosmetic; on this table it is the contract breaking.
#
#   Modelled on tests/check-notice-doc.sh, for the same reason and with the
#   same intolerance: no allowance for whitespace, rewrapping or a "clearer"
#   wording. Edit lib/exitcodes.sh and regenerate.
#
# THE TWO RULES
#   1. REGISTERED COPIES MATCH, BYTE FOR BYTE. docs/exit-codes.md and
#      README.md must carry the block between
#
#          <!-- BEGIN GENERATED: exit-table -->
#          ```text
#          ...the output of `bash lib/exitcodes.sh`, verbatim...
#          ```
#          <!-- END GENERATED: exit-table -->
#
#      and `install.sh --help` must print those same lines. The fence is
#      optional to this gate but is what stops Markdown reflowing the table,
#      so keep it. No exemption marker: a copy that differs is never
#      acceptable, and there is no line here where the rule "fires wrongly".
#
#   2. NO FIFTH COPY. A line of the rendered table appearing verbatim in any
#      file other than the registered three is a new, ungenerated duplicate --
#      the exact thing this gate exists to stop happening again. That rule is
#      `exit-table-copy` and it DOES take an exemption marker, because prose
#      quoting one row while explaining a change is a real and legitimate
#      thing to write. See tests/gate-common.sh for the syntax.
#
# WHY IT EXECUTES install.sh
#   `install.sh --help` is the fourth copy, and it is the one a static read
#   cannot check: today it calls `ex_table`, so it cannot drift -- but the
#   defect this gate guards against is somebody replacing that call with a
#   pasted table, and a grep for `ex_table` would still be satisfied by a
#   file that prints something else. So the gate runs it, with stdin closed
#   and under `timeout` where one exists, and reads what it actually printed.
#   `--help` is the one invocation install.sh documents as writing nothing
#   anywhere; it disarms its own exit trap for it.
#
# WHAT MAKES IT SKIP
#   Only a tree where NONE of the three files exists: there is then no
#   documentation to compare and the gate says so rather than reporting a
#   pass. If some exist and others do not, the missing ones are FAILURES --
#   the guarantee is that every documented copy agrees, and a copy that has
#   vanished is a change somebody made without regenerating anything.
#
#   `tests/check-exit-table.sh --print` writes the block to stdout, ready to
#   paste. That is the supported way to update a document after changing
#   lib/exitcodes.sh.
#
# EXIT: 0 clean, 1 findings, 2 usage/broken, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

readonly BEGIN_MARK='<!-- BEGIN GENERATED: exit-table -->'
readonly END_MARK='<!-- END GENERATED: exit-table -->'
readonly EXITCODES_SH="$GATE_SCAN_ROOT/lib/exitcodes.sh"
readonly INSTALL_SH="$GATE_SCAN_ROOT/install.sh"

# The documents that are allowed to hold a verbatim copy, and the one file
# the table is generated from. Anything else carrying a table line is rule 2.
readonly REGISTERED_DOCS=('docs/exit-codes.md' 'README.md')
readonly COPY_ALLOWED=('lib/exitcodes.sh' 'docs/exit-codes.md' 'README.md')

readonly COPY_ID='exit-table-copy'

# ---------------------------------------------------------------------------
# _canonical -- the table as lib/exitcodes.sh renders it.
#
# Executed, not sourced: `bash lib/exitcodes.sh` printing the table is the
# documented interface, and it is what the regeneration instructions in both
# documents tell a human to run. Checking the same thing the human runs is
# the point.
# ---------------------------------------------------------------------------
_canonical() {
    ( cd -- "$GATE_SCAN_ROOT" && LC_ALL=C.UTF-8 bash ./lib/exitcodes.sh 2>/dev/null )
}

_block() {
    printf '%s\n' "$BEGIN_MARK"
    printf '```text\n'
    _canonical
    printf '```\n'
    printf '%s\n' "$END_MARK"
}

if [[ ${1:-} == '--print' ]]; then
    if [[ ! -r $EXITCODES_SH ]]; then
        printf 'check-exit-table.sh: %s is missing.\n' "$EXITCODES_SH" >&2
        exit 2
    fi
    _block
    exit 0
fi

gate_begin 'exit-table' 'every written copy of the exit table is the generated one'
gate_rule "$COPY_ID"

if [[ ! -r $EXITCODES_SH ]]; then
    gate_fail 'lib/exitcodes.sh' 0 \
        'is missing. It is the source of truth for the exit status this installer communicates through -- the contract itself, not documentation of it.'
    gate_end
fi

canonical=$(_canonical) || canonical=''
if [[ -z ${canonical//[[:space:]]/} ]]; then
    gate_fail 'lib/exitcodes.sh' 0 \
        'printed nothing when run. Whatever the documents say, it cannot be checked against a table that does not render; try "bash lib/exitcodes.sh".'
    gate_end
fi

# The canonical lines, kept as an array for rule 2 and for slicing the help
# output to the same length.
CANON_LINES=()
while IFS= read -r _cl; do
    CANON_LINES+=("$_cl")
done < <(printf '%s\n' "$canonical")
readonly CANON_N=${#CANON_LINES[@]}
readonly CANON_HEAD=${CANON_LINES[0]}

# ---------------------------------------------------------------------------
# Rule 1a -- the two documents.
# ---------------------------------------------------------------------------
present=0
for rel in "${REGISTERED_DOCS[@]}"; do
    doc="$GATE_SCAN_ROOT/$rel"
    [[ -r $doc && -f $doc ]] || continue
    present=$(( present + 1 ))
done

# install.sh counts as a subject too: a tree with none of the three has
# nothing to compare, and that is the only shape that may skip.
[[ -r $INSTALL_SH && -f $INSTALL_SH ]] && present=$(( present + 1 ))

if (( present == 0 )); then
    gate_skip 'neither %s nor %s nor install.sh exists yet, so no written copy of the exit table can be compared against lib/exitcodes.sh. When one lands it must carry the block between %s and %s -- run "tests/check-exit-table.sh --print" to get it verbatim.' \
        "${REGISTERED_DOCS[0]}" "${REGISTERED_DOCS[1]}" "$BEGIN_MARK" "$END_MARK"
fi

for rel in "${REGISTERED_DOCS[@]}"; do
    doc="$GATE_SCAN_ROOT/$rel"
    if [[ ! -r $doc || ! -f $doc ]]; then
        gate_fail "$rel" 0 \
            'is missing, but other copies of the exit table are present. Every documented copy has to agree with lib/exitcodes.sh; one that has disappeared is a change nobody regenerated. Restore it, or take this file out of REGISTERED_DOCS in %s and say why.' \
            'tests/check-exit-table.sh'
        continue
    fi
    GATE_CHECKED=$(( GATE_CHECKED + 1 ))

    begin_line=$(grep -nF -e "$BEGIN_MARK" -- "$doc" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
    end_line=$(grep -nF -e "$END_MARK" -- "$doc" 2>/dev/null | head -n 1 | cut -d: -f1 || true)

    if [[ -z $begin_line || -z $end_line ]]; then
        gate_fail "$rel" 0 \
            'does not carry the generated exit-table block. Paste the output of "tests/check-exit-table.sh --print" where the table belongs; the markers are %s and %s.' \
            "$BEGIN_MARK" "$END_MARK"
        continue
    fi
    if (( end_line <= begin_line )); then
        gate_fail "$rel" "$end_line" 'the end marker is at or above the begin marker.'
        continue
    fi

    # The bytes between the markers, with one optional fence stripped from
    # each end. ```text and a bare ``` are both accepted.
    embedded=$(sed -n "$(( begin_line + 1 )),$(( end_line - 1 ))p" -- "$doc")
    embedded=${embedded#$'\n'}
    embedded=${embedded%$'\n'}
    first=${embedded%%$'\n'*}
    last=${embedded##*$'\n'}
    if [[ $first == '```'* && $last == '```'* ]]; then
        embedded=${embedded#*$'\n'}
        embedded=${embedded%$'\n'*}
    fi

    [[ $embedded == "$canonical" ]] && continue

    gate_fail "$rel" "$(( begin_line + 1 ))" \
        'the embedded exit table differs from what lib/exitcodes.sh renders. Replace the block with the output of "tests/check-exit-table.sh --print"; do not edit it in place.'
    gate_info 'first differing lines:'
    diff_out=$(diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$embedded") 2>/dev/null | head -n 12 || true)
    if [[ -n $diff_out ]]; then
        printf '%s\n' "$diff_out" | while IFS= read -r l; do printf '        %s\n' "$l"; done
    fi
done

# ---------------------------------------------------------------------------
# Rule 1b -- what install.sh --help actually prints.
#
# See the header for why this is executed rather than read. Nothing is passed
# but --help, stdin is /dev/null so a hang cannot come from waiting on input,
# and `timeout` bounds it where the box has one.
# ---------------------------------------------------------------------------
if [[ -r $INSTALL_SH && -f $INSTALL_SH ]]; then
    GATE_CHECKED=$(( GATE_CHECKED + 1 ))
    help_out=''
    help_rc=0
    if command -v timeout >/dev/null 2>&1; then
        help_out=$( cd -- "$GATE_SCAN_ROOT" \
            && LC_ALL=C.UTF-8 timeout 120 bash ./install.sh --help </dev/null 2>/dev/null )
        help_rc=$?
    else
        help_out=$( cd -- "$GATE_SCAN_ROOT" \
            && LC_ALL=C.UTF-8 bash ./install.sh --help </dev/null 2>/dev/null )
        help_rc=$?
    fi

    if (( help_rc != 0 )); then
        gate_fail 'install.sh' 0 \
            '"install.sh --help" exited %d. It is one of the copies of the exit table and it has to be readable by a machine as well as by a person; a --help that fails cannot be compared with lib/exitcodes.sh.' \
            "$help_rc"
    else
        head_line=$(printf '%s\n' "$help_out" \
            | grep -nF -x -e "$CANON_HEAD" 2>/dev/null | head -n 1 | cut -d: -f1 || true)
        if [[ -z $head_line ]]; then
            gate_fail 'install.sh' 0 \
                '"install.sh --help" does not print the exit table. lib/args.sh calls ex_table for exactly this; if the help text has stopped rendering it, the flag that documents the contract no longer documents it.'
        else
            help_table=$(printf '%s\n' "$help_out" \
                | sed -n "${head_line},$(( head_line + CANON_N - 1 ))p")
            if [[ $help_table != "$canonical" ]]; then
                gate_fail 'install.sh' 0 \
                    '"install.sh --help" prints an exit table that differs from what lib/exitcodes.sh renders. The help text must render the table (lib/args.sh calls ex_table), never hold a pasted copy of it.'
                gate_info 'first differing lines:'
                diff_out=$(diff <(printf '%s\n' "$canonical") <(printf '%s\n' "$help_table") 2>/dev/null | head -n 12 || true)
                if [[ -n $diff_out ]]; then
                    printf '%s\n' "$diff_out" | while IFS= read -r l; do printf '        %s\n' "$l"; done
                fi
            fi
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Rule 2 -- no fifth copy.
#
# A whole rendered line, matched fixed-string and whole-line, in a file that
# is not one of the three registered ones. Whole-line matching is what keeps
# this off ordinary source: install.sh mentions EX_REBOOT constantly, and
# lib/exitcodes.sh holds the rows in their `code|name|meaning` form, neither
# of which is a rendered line.
# ---------------------------------------------------------------------------
_copy_allowed() {
    local rel=$1 a
    for a in "${COPY_ALLOWED[@]}"; do
        [[ $rel == "$a" ]] && return 0
    done
    return 1
}

canon_pat=$(mktemp "${TMPDIR:-/tmp}/tpot-exit-table.XXXXXXXX") || exit 2
trap 'rm -f -- "$canon_pat"' EXIT INT TERM HUP
# Blank lines are dropped: an empty pattern in a -f file matches every line
# of every file, which would turn this rule into noise over the whole tree.
printf '%s\n' "${CANON_LINES[@]}" | grep -v '^[[:space:]]*$' > "$canon_pat"
if [[ ! -s $canon_pat ]]; then
    gate_fail 'lib/exitcodes.sh' 0 \
        'rendered only blank lines, so rule 2 has nothing to look for. That is a broken table, not a clean tree.'
    gate_end
fi

# _report_run FILE REL FIRST LAST -- one finding for one contiguous run.
#
# Consecutive matching lines are reported ONCE, at the first of them. A
# pasted table is contiguous and a paragraph quoting a row is not, so this
# gives one finding for the defect and one exemptible line for the prose --
# rather than twelve identical findings for a single paste, which is how a
# rule teaches people to stop reading it.
_report_run() {
    local file=$1 rel=$2 first=$3 last=$4 n=$(( $4 - $3 + 1 )) where
    gate_exempt "$file" "$first" "$COPY_ID" && return 0
    if (( n == 1 )); then
        where="line $first is"
    else
        where="lines ${first}-${last} are"
    fi
    gate_fail "$rel" "$first" \
        '%s a verbatim copy of %d line(s) of the generated exit table, in a file that is not one of the registered copies. A further written copy is a further thing to forget: either add this file to REGISTERED_DOCS in tests/check-exit-table.sh so it is kept in step, or mark it with "gate-allow: %s <why>" if it is prose quoting the table.' \
        "$where" "$n" "$COPY_ID"
}

while IFS= read -r path; do
    rel=$(gate_rel "$path")
    _copy_allowed "$rel" && continue
    run_first=0
    run_last=0
    while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        lineno=${hit%%:*}
        [[ $lineno =~ ^[0-9]+$ ]] || continue
        if (( run_first == 0 )); then
            run_first=$lineno
            run_last=$lineno
        elif (( lineno == run_last + 1 )); then
            run_last=$lineno
        else
            _report_run "$path" "$rel" "$run_first" "$run_last"
            run_first=$lineno
            run_last=$lineno
        fi
    done < <(grep -nF -x -f "$canon_pat" -- "$path" 2>/dev/null || true)
    (( run_first > 0 )) && _report_run "$path" "$rel" "$run_first" "$run_last"
done < <(gate_files)

gate_end
