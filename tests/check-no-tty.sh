#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tests/check-no-tty.sh -- nothing in this tree asks a human a question.
#
# THE PROMISE THIS GATE DEFENDS
#   This installer's reason to exist is that it runs unattended: from
#   cloud-init, from a provisioning pipeline, from a cron job, on a box with
#   no terminal attached. One forgotten prompt turns a 90-minute install into
#   a process that blocks forever, produces no error, and is discovered when
#   somebody notices the machine never came up. Upstream T-Pot has two such
#   loops itself -- `while` around a `read` with no EOF handling, which spin
#   rather than fail when stdin is not a terminal -- which is exactly why we
#   drive it with flags that never reach them.
#
#   So: no code in this tree obtains input from a human. The one exception is
#   the courtesy prompt in lib/args.sh, which exists for a person typing
#   `install.sh` at a keyboard and is reachable only when a terminal is
#   present, and which is allowlisted here by name.
#
# WHAT COUNTS AS A VIOLATION
#   1. The shell `read` builtin used to OBTAIN INPUT. That means:
#        * an option cluster containing -p (prompt) or -s (no echo);
#        * reading from /dev/tty or /dev/console;
#        * a "bare" read -- no input redirection, not the head of a
#          while/until loop, and no pipe feeding it. That is the shape that
#          silently consumes the script's own stdin.
#   2. The `select` builtin, which is a menu and blocks for a keypress.
#   3. An interactive prompting program: whiptail, dialog, zenity.
#   4. In Python: input(), raw_input(), or anything out of getpass.
#
# WHAT IS EXPLICITLY PERMITTED, AND WHY
#   `read` used to ITERATE is not input from a human, and this tree uses it
#   constantly and correctly:
#
#       while IFS= read -r line; do ... done < "$file"
#       while IFS= read -r line; do ... done < <(some_command)
#       IFS= read -r value < "$file"
#       IFS= read -r line <<< "$string"
#       ... | while IFS= read -r line; do ... done
#
#   A here-document body is data, and the lexer reports it separately, so
#   text inside one is never mistaken for a command.
#
# THE EXEMPTION MARKER
#   This gate owns one rule id, `interactive-read`, and it is the NARROW kind:
#   exempt-able in lib/args.sh and in no other file. The marker appearing
#   anywhere else is itself a failure, so the escape hatch cannot spread --
#   that scoping is the whole point, because an allowlist anyone may use is
#   not an allowlist.
#
#   The syntax, the mandatory reason and the stale-marker rule are shared with
#   every other gate and live in tests/gate-common.sh; this file adds nothing
#   of its own. The shape, written with the id as a placeholder so that this
#   comment is not itself read as an exemption:
#
#       # gate-allow: <rule-id> <why, in words>
#
# THE BRACKETED-LETTER IDIOM
#   The word this gate forbids is written [r]ead in its patterns, so the
#   regex matches "read" while this file does not contain it at a command
#   position and therefore does not fail itself. See tests/gate-common.sh.
#
# WHY STRING INTERIORS ARE BLANKED FIRST
#   The gate looks at shell files through gate-strip.py's `shellq` mode,
#   which empties the interior of every quoted string. Without it the
#   sentence "could not read the matrix", inside an error message, is
#   reported as a prompt -- nineteen such findings on the first run of this
#   gate, every one of them noise. The /dev/tty test is done against the
#   UNBLANKED line, so a terminal named inside quotes is still caught.
#
# NOT THIS GATE'S JOB
#   Package managers that prompt when not given -y are an unattended-install
#   defect of the same family, but they belong with the Ansible role that
#   invokes them, not here.
#
# EXIT: 0 clean, 1 findings, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'no-tty' 'no code in this tree asks a human a question'

readonly ALLOW_ID='interactive-read'
readonly ALLOW_FILE='lib/args.sh'

# One rule, narrowed to one file. gate_rule records the scope; gate_exempt
# enforces it at the point of a finding, and gate_check_markers -- which
# gate_end runs -- reports any marker for this rule that is out of scope,
# unexplained, or left behind on a line where nothing fires. None of that is
# implemented here any more: there is one parser, in tests/gate-common.sh.
gate_rule "$ALLOW_ID" "$ALLOW_FILE"

# --- Patterns ---------------------------------------------------------------
# `read` at a command position, optionally behind an IFS= assignment.
readonly RE_READ='(^|[;&|(){}]|[[:space:]])(IFS=[^[:space:]]*[[:space:]]+)*[r]ead([[:space:]]|$)'
# An option cluster carrying -p (prompt) or -s (silent). Both mean a human.
readonly RE_READ_PROMPT='[r]ead[[:space:]]+(-[a-zA-Z]*[ps][a-zA-Z]*)([[:space:]]|$)'
readonly RE_TTY='/dev/(tty|console)'
readonly RE_LOOP='(^|[;&|(){}]|[[:space:]])(while|until)([[:space:]]|$)'
readonly RE_REDIRECT='<[^<]|<<<|<&|<\('
readonly RE_SELECT='(^|[;&|(){}]|[[:space:]])select[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in([[:space:]]|$)'
readonly RE_PROMPTER='(^|[;&|(){}=]|[[:space:]])(whiptail|dialog|zenity)([[:space:]]|$)'
readonly RE_PY_INPUT='(^|[^A-Za-z0-9_.])(input|raw_input)[[:space:]]*\(|getpass'

while IFS= read -r path; do
    kind=$(gate_kind "$path")
    rel=$(gate_rel "$path")

    if [[ $kind == python ]]; then
        GATE_CHECKED=$(( GATE_CHECKED + 1 ))
        while IFS= read -r rec; do
            lineno=${rec%%$'\t'*}
            text=${rec#*$'\t'}
            text=${text#*$'\t'}
            [[ $text =~ $RE_PY_INPUT ]] || continue
            gate_exempt "$path" "$lineno" "$ALLOW_ID" && continue
            gate_fail "$rel" "$lineno" \
                'reads from a human in Python. Nothing in this tree may prompt: %s' "$text"
        done < <(gate_lex raw "$path")
        continue
    fi

    case $kind in
        shell|md|yaml) ;;
        *) continue ;;
    esac
    GATE_CHECKED=$(( GATE_CHECKED + 1 ))

    # The unblanked logical line, kept so the /dev/tty test and the reported
    # text see what was actually written.
    unset -v RAWLINE
    declare -A RAWLINE=()
    if [[ $kind == shell ]]; then
        while IFS= read -r rec; do
            RAWLINE[${rec%%$'\t'*}]=${rec#*$'\t'*$'\t'}
        done < <(gate_lex shell "$path")
    fi

    while IFS= read -r rec; do
        lineno=${rec%%$'\t'*}
        rest=${rec#*$'\t'}
        reckind=${rest%%$'\t'*}
        text=${rest#*$'\t'}
        [[ $reckind == code ]] || continue
        raw=${RAWLINE[$lineno]:-$text}

        if [[ $text =~ $RE_SELECT ]]; then
            gate_exempt "$path" "$lineno" "$ALLOW_ID" && continue
            gate_fail "$rel" "$lineno" \
                'uses the `select` builtin, which blocks for a keypress: %s' "$text"
        fi

        if [[ $text =~ $RE_PROMPTER ]]; then
            gate_exempt "$path" "$lineno" "$ALLOW_ID" && continue
            gate_fail "$rel" "$lineno" \
                'invokes an interactive prompting program: %s' "$text"
        fi

        [[ $text =~ $RE_READ ]] || continue

        why=''
        if [[ $text =~ $RE_READ_PROMPT ]]; then
            why='the option cluster carries -p or -s, which only a human needs'
        elif [[ $raw =~ $RE_TTY ]]; then
            why='it obtains input from the terminal device directly'
        elif [[ ! $text =~ $RE_LOOP && ! $text =~ $RE_REDIRECT && $text != *'|'* ]]; then
            why='it is a bare read: no redirection, no loop, no pipe, so it consumes stdin'
        fi
        [[ -n $why ]] || continue

        gate_exempt "$path" "$lineno" "$ALLOW_ID" && continue
        if [[ $rel == "$ALLOW_FILE" ]]; then
            gate_fail "$rel" "$lineno" \
                'interactive read, and %s is the one file allowed to have one -- but this line is not marked. Add "# gate-allow: %s <why, in words>" on it or the line above. (%s)' \
                "$ALLOW_FILE" "$ALLOW_ID" "$why"
        else
            gate_fail "$rel" "$lineno" \
                'obtains input from a human: %s. %s' "$why" "$raw"
        fi
    done < <(if [[ $kind == shell ]]; then gate_lex shellq "$path"; else gate_lex_auto "$path"; fi)
done < <(gate_files)

gate_end
