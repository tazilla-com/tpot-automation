#!/usr/bin/env bash
# tests/check-no-expect.sh -- no screen-scraping driver, ever.
#
# THE DECISION THIS GATE ENFORCES
#   The installer this project derives from drove upstream T-Pot's
#   INTERACTIVE installer by matching seven of its prompt strings
#   byte-for-byte and typing answers at them. It worked, and its failure mode
#   is the worst kind: the scripting tool's timeout RETURNS rather than
#   errors, so an upstream wording change means roughly seventy minutes of
#   canned answers fired into the wrong state, followed by a zero exit code
#   on a host where nothing was installed. The drift had already begun -- the
#   inherited script matched a three-option prompt against an upstream that
#   now prints six.
#
#   Upstream has a documented unattended mode. We use it. The scraping
#   driver is not hardened, not kept behind a selector, not written at all.
#   That is a project decision, and this gate is what keeps it true when
#   somebody hits a prompt at three in the morning and reaches for the
#   familiar tool.
#
# WHAT IS FORBIDDEN
#   1. Any file with the .exp extension.
#   2. A shebang naming the interpreter.
#   3. Installing its package -- through a package manager on a command line,
#      or through an Ansible package module's name.
#   4. Its language constructs, at a command position:
#        the spawn command; the wait-for command bare, brace-opened or
#        with -re; its _before / _after / _out / _background variants;
#        the send command with a string argument; the interact command;
#        and the tcl `set timeout <n>` that configures all of them.
#
# WHAT IS PERMITTED, PRECISELY
#   The ordinary English verb, in prose. This gate reads CODE, not text: for
#   shell it reads what gate-strip.py reports as code, with comments removed
#   and the interior of quoted strings emptied; for Markdown, only fenced
#   code blocks; for YAML, only shell-module scalars plus the package-name
#   rule above. So a sentence in a comment or a paragraph explaining why the
#   tool is not used will not fire, and a line of its syntax will.
#
#   That is the entire allowlist. There is no marker, and no file is exempt.
#   In particular this file is not exempt: every forbidden literal below is
#   written with its first character in a one-character class -- [x]yz
#   matches "xyz" while this file does not contain it -- so the gate passes
#   over its own source rather than skipping it.
#
# EXIT: 0 clean, 1 findings, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'no-expect' 'the deleted screen-scraping driver stays deleted'

readonly CMD='(^|[;&|(){}[]|[[:space:]])'

# regex <TAB> what to tell the reader
readonly -a CONSTRUCTS=(
    "${CMD}[s]pawn[[:space:]]"$'\t''the spawn command'
    "${CMD}[e]xpect([[:space:]]|\{|$)"$'\t''the wait-for command'
    "${CMD}[e]xpect_(before|after|out|background)"$'\t''a wait-for variant'
    "${CMD}[i]nteract([[:space:]]|$)"$'\t''the interact command'
    "${CMD}send[[:space:]]+(--[[:space:]]+)?[\"'\$-]"$'\t''the send command'
    "${CMD}set[[:space:]]+timeout[[:space:]]+[0-9]"$'\t''the tcl timeout setting'
)

readonly RE_PKG_SHELL='(apt-get|apt|yum|dnf|zypper|apk|pacman|pkg)([[:space:]]|$).*(^|[[:space:]])[e]xpect([[:space:]]|$)'
readonly RE_PKG_YAML='^[[:space:]]*(-[[:space:]]+)?(name:[[:space:]]*)?["'"'"']?[e]xpect["'"'"']?[[:space:]]*$'
readonly RE_SHEBANG='^#!.*[e]xpect'

while IFS= read -r path; do
    rel=$(gate_rel "$path")
    kind=$(gate_kind "$path")
    GATE_CHECKED=$(( GATE_CHECKED + 1 ))

    # 1. The file extension.
    if [[ $rel == *.exp ]]; then
        gate_fail "$rel" 0 'is a script for the deleted screen-scraping driver (.exp).'
    fi

    # 2. The shebang.
    if head -n 1 -- "$path" 2>/dev/null | grep -qE "$RE_SHEBANG"; then
        gate_fail "$rel" 1 'its shebang names the deleted driver.'
    fi

    # 3. Package name, YAML spelling. Scanned over the whole file rather than
    #    over shell-module scalars, because an Ansible package module is not
    #    a shell command and would otherwise never be looked at.
    if [[ $kind == yaml ]]; then
        while IFS= read -r hit; do
            [[ -n $hit ]] || continue
            gate_fail "$rel" "${hit%%:*}" \
                'installs the deleted driver as a package: %s' "${hit#*:}"
        done < <(grep -anE -e "$RE_PKG_YAML" -- "$path" 2>/dev/null || true)
    fi

    # A .exp or .tcl file, or one whose shebang names the interpreter, is
    # lexed as shell so its constructs are reported too, not just its name.
    case $rel in
        *.exp|*.tcl) kind=shell ;;
    esac
    case $kind in
        shell|md|yaml) ;;
        *) continue ;;
    esac

    while IFS= read -r rec; do
        lineno=${rec%%$'\t'*}
        rest=${rec#*$'\t'}
        reckind=${rest%%$'\t'*}
        text=${rest#*$'\t'}
        [[ $reckind == code ]] || continue

        if [[ $text =~ $RE_PKG_SHELL ]]; then
            gate_fail "$rel" "$lineno" \
                'installs the deleted driver as a package: %s' "$text"
            # One line, one finding: the construct patterns would also match
            # the package name and report it as a language keyword, which is
            # true of the bytes and false of the intent.
            continue
        fi

        for entry in "${CONSTRUCTS[@]}"; do
            pattern=${entry%%$'\t'*}
            what=${entry#*$'\t'}
            if [[ $text =~ $pattern ]]; then
                gate_fail "$rel" "$lineno" \
                    'uses %s of the deleted screen-scraping driver: %s' "$what" "$text"
            fi
        done
    done < <(if [[ $kind == shell ]]; then gate_lex shellq "$path"; else gate_lex_auto "$path"; fi)
done < <(gate_files)

gate_end
