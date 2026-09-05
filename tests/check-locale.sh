#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tests/check-locale.sh -- the byte-stable locale must be C.UTF-8, never plain C.
#
# THE FAILURE THIS GATE EXISTS TO PREVENT
#   Setting the locale to `C` is the reflex for byte-stable, English tool
#   output, and everything in this tree wants that: the transcript is diffed,
#   the notice block is compared byte-for-byte against the README, and
#   error strings are parsed.
#
#   But ansible-core refuses to start under a non-UTF-8 locale. It exits 1
#   before doing anything, with:
#
#       Ansible requires the locale encoding to be UTF-8; Detected None.
#
#   Ansible is what drives this install, and upstream T-Pot's own install.sh
#   runs a NESTED ansible-playbook of its own -- so a plain-C locale anywhere
#   in the chain is a total failure on every box in both support tiers, and
#   it presents as "no usable ansible-core", which points the reader at the
#   wrong thing entirely. It was found by execution while wiring install.sh,
#   not by reading, which is why it is a build break now.
#
#   C.UTF-8 buys the same byte stability, needs no locale-gen, and is present
#   on every release this project can install on. There is no reason to write
#   plain C, ever.
#
# WHAT IS CHECKED
#   Every line of every file, PROSE AND COMMENTS INCLUDED. That is deliberate
#   and it is the unusual part: a comment or an example that tells a reader
#   to set the locale to C is a latent total failure sitting in the
#   documentation waiting to be copied.
#
#   Three names are watched -- LC_ALL, LC_CTYPE and LANG -- in two spellings:
#   the shell/dotenv one, NAME then an equals sign then the value, and the
#   YAML mapping one, NAME then a colon then the value, which is how an
#   Ansible `environment:` block writes it. (Written out in words here so
#   that this file does not carry the text it forbids and does not fail
#   itself; the patterns further down are the authority.)
#
# THE EXEMPTION MARKER
#   This gate owns one rule id, `locale-prose`, and unlike the one in
#   tests/check-no-tty.sh it is honoured in ANY file. Naming the forbidden
#   setting in order to warn against it is legitimate everywhere, and this
#   gate reads prose and comments on purpose -- so without a marker it punishes
#   exactly the warning that keeps the next reader out of the trap.
#   lib/preflight.sh's header is the case in point: it quotes the ansible-core
#   error and the setting that causes it, which is the whole value of the
#   comment.
#
#   The name says what it is for. `locale-prose` exempts PROSE. It must never
#   go on a line that actually sets the locale, nor on a document that tells a
#   reader the locale IS plain C when it is not -- those are the two defects
#   this gate exists to find, and a marker on one of them is a lie with a
#   comment character in front of it.
#
#   Syntax, mandatory reason and the stale-marker rule are shared and live in
#   tests/gate-common.sh. The shape, with the id written as a placeholder so
#   this comment is not itself read as an exemption:
#
#       # gate-allow: <rule-id> <why, in words>
#
#   A value fails when it is C, POSIX, or empty. Everything else passes,
#   including C.UTF-8, C.utf8 and en_US.UTF-8.
#
# WHY THIS FILE DOES NOT FAIL ITSELF
#   The patterns below never write one of those names immediately followed by
#   `=` or `:`; the name list is an alternation and the value is a character
#   class, so the forbidden text does not occur here.
#
# EXIT: 0 clean, 1 findings, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'locale' 'the locale is C.UTF-8 everywhere, never plain C'

readonly ALLOW_ID='locale-prose'
gate_rule "$ALLOW_ID"

# The value stops at the first character that cannot be part of a locale
# name, so a trailing sentence period is NOT eaten and a prose mention ending
# in one still yields the bare value -- which is the bug being hunted.
readonly RE_ENVFORM='(LC_ALL|LC_CTYPE|LANG)=[A-Za-z0-9_@]*(\.[A-Za-z0-9_@-]+)*'
readonly RE_YAMLFORM='(LC_ALL|LC_CTYPE|LANG):[[:space:]]*"?'"'"'?[A-Za-z0-9_@]*(\.[A-Za-z0-9_@-]+)*'

_verdict() {
    # _verdict VALUE -> prints why it is wrong, or nothing when it is fine.
    case ${1^^} in
        C|POSIX) printf 'the locale is %s, which is not UTF-8; ansible-core exits 1 under it' "$1" ;;
        '')      printf 'the locale is set to nothing, which ansible-core reports as "Detected None"' ;;
        *)       : ;;
    esac
}

while IFS= read -r path; do
    rel=$(gate_rel "$path")
    GATE_CHECKED=$(( GATE_CHECKED + 1 ))

    while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        lineno=${hit%%:*}
        token=${hit#*:}
        value=${token#*=}
        why=$(_verdict "$value")
        [[ -n $why ]] || continue
        gate_exempt "$path" "$lineno" "$ALLOW_ID" && continue
        gate_fail "$rel" "$lineno" '%s -- write C.UTF-8. (%s)' "$why" "$token"
    done < <(grep -noE -e "$RE_ENVFORM" -- "$path" 2>/dev/null || true)

    while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        lineno=${hit%%:*}
        token=${hit#*:}
        value=${token#*:}
        value=${value#"${value%%[![:space:]]*}"}
        value=${value#\"}
        value=${value#\'}
        why=$(_verdict "$value")
        [[ -n $why ]] || continue
        gate_exempt "$path" "$lineno" "$ALLOW_ID" && continue
        gate_fail "$rel" "$lineno" '%s -- write C.UTF-8. (%s)' "$why" "$token"
    done < <(grep -noE -e "$RE_YAMLFORM" -- "$path" 2>/dev/null || true)
done < <(gate_files)

gate_end
