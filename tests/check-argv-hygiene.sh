#!/usr/bin/env bash
# tests/check-argv-hygiene.sh -- no credential ever reaches a command line.
#
# THE PROPERTY THIS GATE DEFENDS
#   On Linux the process argument list is world-readable in /proc for the
#   whole lifetime of the process, and a T-Pot install runs for thirty to
#   ninety minutes. A password passed as a flag value is therefore readable
#   by every local account on the box for an hour and a half. So in this
#   project's own code a secret travels on a file descriptor or in a
#   mode-0600 document on tmpfs, never as an argument. There is no flag that
#   takes a password as its value, only flags that take a PATH.
#
#   The rules below are proxies for that property. They are deliberately
#   mechanical: a rule a build can check beats a rule a reviewer has to
#   remember.
#
# THE FIVE RULES
#   1. EXTRA-VARS MUST BE A FILE REFERENCE. An `--extra-vars` or `-e` option
#      to ansible must be followed by @PATH. `-e key=value` puts the value on
#      the command line of every task-running child, which is exactly the
#      exposure being avoided -- and the merged document this project builds
#      is the one that holds the dashboard password.
#
#   2. NO `htpasswd -b`. The -b form takes the password as an argument. The
#      -i form reads it from standard input and is what this project uses.
#      Upstream T-Pot runs the -b form itself, at a line we deliberately
#      never reach; that is one of the two reasons we drive it the way we do.
#
#   3. NO FLAG DEFINITION WHOSE NAME ENDS IN -password AND TAKES A VALUE. A
#      `--web-password-file FILE` is fine -- its name ends in -file and its
#      value is a path. The defect is the same flag without the -file suffix,
#      shown in a usage line with a metavariable after it. That is checked
#      two ways: a shell case label that goes on to consume a value, and a
#      usage line of that shape anywhere in the tree. (The bad form is not
#      written out here, because this gate reads its own source too.)
#
#   4. NO SECRET-SHAPED VARIABLE ON AN EXTERNAL COMMAND LINE. A value handed
#      to a shell BUILTIN or to a function defined in this tree starts no
#      process and reaches no /proc entry. Handed to an external program it
#      does. So the rule is about the command word, not the variable.
#
#   5. UPSTREAM IS NEVER GIVEN -u OR -p. Upstream T-Pot is driven as an
#      unattended sensor install, which never enters its credential branch at
#      all; the two things the credentialed install type would have done --
#      choosing the compose file and writing the dashboard user into .env --
#      this project does itself, with the password on standard input. Passing
#      -u or -p would put the password in upstream's argv AND in a child's
#      argv, and it would do so for ninety minutes. Any line that carries
#      upstream's unattended flag set together with -u or -p fails, including
#      a line of documentation that merely CLAIMS we do it -- a README that
#      describes an exposure the code does not have is its own defect.
#
# WHAT IS AND IS NOT READ
#   Shell files are read as code, with comments removed. Markdown is read
#   only inside fenced code blocks, so a paragraph explaining that the -b
#   form is forbidden does not itself fail -- SECURITY.md contains exactly
#   that sentence. Rules 3 and 5 additionally read every line of every file,
#   because a usage line and a false claim about our own behaviour are
#   defects wherever they are written.
#
# KNOWN LIMITS, STATED RATHER THAN HIDDEN
#   Rule 4 recognises a secret by the SHAPE OF ITS NAME. A password held in a
#   variable called `first` is invisible to it -- lib/args.sh has one, on
#   purpose, and hands it to a builtin. Rule 4 is a tripwire for the obvious
#   mistake, not a proof. The proof is that no secret-typed key is ever
#   expanded into an argument anywhere, and that is what review is for.
#
# THE EXEMPTION MARKERS -- ONE ID PER RULE, AND TWO RULES WITH NONE
#   An exemption is a statement about one rule, so this gate owns four rule
#   ids rather than one gate-wide id. Marking a line silences the rule you
#   named there and nothing else:
#
#       extra-vars-value    rule 1 -- a value passed through -e
#       password-flag       rule 3 -- a -password flag that takes a value
#       secret-on-argv      rule 4 -- a secret-shaped name on a command line
#       upstream-claim      rule 5, claim half -- text describing -u/-p
#
#   RULE 2 AND THE INVOCATION HALF OF RULE 5 TAKE NO MARKER AT ALL, and that
#   is deliberate. `htpasswd -b` and `install.sh ... -u/-p` are not shapes
#   prose needs: a document can describe them in a sentence without writing
#   the command, and code that runs them is the defect this project was built
#   to remove. There is no id to name, so there is nothing to write.
#
#   The markable four are honoured in any file. They exist for the one
#   legitimate case: prose that has to write the forbidden form out in order
#   to forbid it, and a test harness whose -e value is a FILE PATH rather than
#   a credential. Never for product code -- if you are marking a line that
#   runs in an install, the line is the bug.
#
#   Syntax, the mandatory reason and the stale-marker rule are shared and live
#   in tests/gate-common.sh. The shape, with the id written as a placeholder
#   so this comment is not itself read as an exemption:
#
#       # gate-allow: <rule-id> <why, in words>
#
# THE BRACKETED-LETTER IDIOM
#   Forbidden literals are written [x]yz so this file does not contain the
#   text it forbids and does not fail itself. See tests/gate-common.sh.
#
# EXIT: 0 clean, 1 findings, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'argv-hygiene' 'no credential and no bare value on any command line'

# One id per rule; see the header for why, and for the two rules that have
# none. gate_rule declares them so gate_check_markers can report a marker
# left behind on a line where its rule no longer fires.
readonly R_EXTRA_VARS='extra-vars-value'
readonly R_PASSWORD_FLAG='password-flag'
readonly R_SECRET_ARGS='secret-on-argv'
readonly R_UPSTREAM_CLAIM='upstream-claim'
gate_rule "$R_EXTRA_VARS"
gate_rule "$R_PASSWORD_FLAG"
gate_rule "$R_SECRET_ARGS"
gate_rule "$R_UPSTREAM_CLAIM"

GATE_PATH=''

# --- What is safe to hand a value to ---------------------------------------
# Shell builtins and keywords start no process. `export` and `eval` are
# deliberately ABSENT: exporting a secret puts it in /proc/<pid>/environ of
# every child, and eval can build anything.
readonly SAFE_WORDS=' if then elif else fi while until do done case esac in for select function time coproc ! printf echo local declare typeset readonly unset shift return exit source . cd pwd test [ [[ (( let true false : break continue wait trap set shopt getopts hash type command builtin mapfile readarray alias unalias jobs kill disown pushd popd dirs umask ulimit '

readonly ARRAY_LINE='^[[:space:]]*(local[[:space:]]+)?(-a[[:space:]]+)?(argv|cmd|command|args|arguments|opts|flags|invocation)\+?=\('
readonly SECRET_NAME='^([A-Za-z0-9_]*_)?(password|passwd|passphrase|pass|pw|secret|secrets|token|credential|credentials|apikey|api_key|auth_header_value)$'
readonly ANSIBLE_CMD='^(.*/)?ansible(-playbook|-console|-pull)?$'
readonly UPSTREAM_CMD='^(.*/)?install\.sh$'
readonly META='--[a-z0-9-]*-password[[:space:]=]+[A-Z][A-Z_0-9-]*'
readonly PY_FLAG='add_argument\([[:space:]]*["'"'"']--[a-z0-9-]*-password["'"'"']'
readonly TAKES_VALUE='_tpot_args_take_value|shift[[:space:]]+2|OPTARG|=[\"'"'"']?\$2'

SHELL_FUNCS=" $(gate_shell_functions | tr '\n' ' ') "

_is_safe_word() {
    [[ $SAFE_WORDS == *" $1 "* ]] && return 0
    [[ $SHELL_FUNCS == *" $1 "* ]] && return 0
    return 1
}

# _flag REL LINENO RULE FMT [ARGS...]
#   Every markable finding goes through here. The rule id is an argument
#   rather than a constant: a marker names one rule, so the finding has to
#   say which rule it is before the shared parser can decide anything.
_flag() {
    local rel=$1 lineno=$2 rule=$3
    shift 3
    if [[ -n $GATE_PATH && $lineno != 0 ]] \
        && gate_exempt "$GATE_PATH" "$lineno" "$rule"; then
        return 0
    fi
    gate_fail "$rel" "$lineno" "$@"
}

_unquote() {
    local v=$1
    v=${v#[\"\']}
    v=${v%[\"\']}
    printf '%s' "$v"
}

# _scan_segments REL LINENO TEXT
#   Split a logical line into command segments and apply rules 1, 2, 4 and
#   the invocation half of rule 5 to each.
_scan_segments() {
    local rel=$1 lineno=$2 text=$3
    local work seg tok cmd rest i n
    local -a tokens=()

    if [[ $text =~ $ARRAY_LINE ]]; then
        # An array being built to be executed later. Treat the whole line as
        # one argument vector: the command word is not visible here, so only
        # the value rules apply.
        _rule_extra_vars "$rel" "$lineno" "$text" 'an argument vector'
        _rule_secret_args "$rel" "$lineno" "$text" 'an argument vector'
    fi

    work=${text//\$\(/$'\n'}
    work=${work//\`/$'\n'}
    work=${work//;/$'\n'}
    work=${work//|/$'\n'}
    work=${work//&/$'\n'}
    work=${work//(/$'\n'}
    work=${work//)/$'\n'}

    while IFS= read -r seg; do
        [[ -n ${seg//[[:space:]]/} ]] || continue
        # shellcheck disable=SC2206
        tokens=( $seg )
        n=${#tokens[@]}
        i=0
        while (( i < n )); do
            tok=${tokens[i]}
            case $tok in
                # A compound command: what follows is a variable name and a
                # word list, not a command. `for pat in "${secrets[@]}"` is
                # not an invocation of `pat`.
                for|select|case|in|esac|done|fi|do)
                    i=$n
                    break
                    ;;
                # A declaration or a builtin that takes the whole line:
                # nothing here starts a process.
                local|declare|typeset|readonly|unset|printf|echo|test|'['|'[['|'((')
                    i=$n
                    break
                    ;;
            esac
            if _is_safe_word "$tok"; then
                i=$(( i + 1 ))
                continue
            fi
            [[ $tok =~ ^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?= ]] && { i=$(( i + 1 )); continue; }
            break
        done
        (( i < n )) || continue
        cmd=$(_unquote "${tokens[i]}")
        # A command word this gate cannot resolve -- an expansion, an
        # option, or debris left by splitting inside a double-quoted string.
        # Skipping it is the honest choice: guessing produces findings that
        # name a "command" nobody wrote.
        [[ $cmd =~ ^[A-Za-z0-9_.][A-Za-z0-9_./+:@-]*$ ]] || continue
        rest=${seg#*"${tokens[i]}"}

        if [[ $cmd =~ $ANSIBLE_CMD ]]; then
            _rule_extra_vars "$rel" "$lineno" "$rest" "$cmd"
        fi
        if [[ $(basename -- "$cmd") == 'htpasswd' ]]; then
            _rule_htpasswd "$rel" "$lineno" "$rest"
        fi
        if [[ $cmd =~ $UPSTREAM_CMD ]]; then
            _rule_upstream_flags "$rel" "$lineno" "$rest" "$cmd"
        fi
        _rule_secret_args "$rel" "$lineno" "$rest" "$cmd"
    done <<< "$work"
}

# Rule 1 -- an extra-vars option must be followed by @PATH.
_rule_extra_vars() {
    local rel=$1 lineno=$2 rest=$3 cmd=$4
    local -a tokens=()
    local i n tok value
    # shellcheck disable=SC2206
    tokens=( $rest )
    n=${#tokens[@]}
    for (( i = 0; i < n; i++ )); do
        tok=${tokens[i]}
        value=''
        case $tok in
            --extra-vars=*|-e=*) value=${tok#*=} ;;
            --extra-vars|-e)
                (( i + 1 < n )) || continue
                value=${tokens[i + 1]}
                ;;
            *) continue ;;
        esac
        value=$(_unquote "$value")
        [[ $value == @* ]] && continue
        _flag "$rel" "$lineno" "$R_EXTRA_VARS" \
            'passes a VALUE to %s through %s, not a file reference. Use -e @PATH: a value here is world-readable in /proc for the life of the process. (%s %s)' \
            "$cmd" "$tok" "$tok" "$value"
    done
}

# Rule 2 -- the -b form of the password hasher.
_rule_htpasswd() {
    local rel=$1 lineno=$2 rest=$3 tok
    for tok in $rest; do
        if [[ $tok =~ ^-[a-zA-Z]*b[a-zA-Z]*$ ]]; then
            gate_fail "$rel" "$lineno" \
                'runs the password hasher with %s, which takes the password as an argument. Use the -i form, which reads it from standard input.' \
                "$tok"
            return 0
        fi
    done
}

# Rule 4 -- a secret-shaped expansion handed to an external command.
_rule_secret_args() {
    local rel=$1 lineno=$2 rest=$3 cmd=$4 name
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        [[ ${name,,} =~ $SECRET_NAME ]] || continue
        _flag "$rel" "$lineno" "$R_SECRET_ARGS" \
            'expands $%s into the command line of %s. A value on argv is world-readable in /proc; pass it on a file descriptor instead.' \
            "$name" "$cmd"
    done < <(printf '%s\n' "$rest" \
        | grep -oE '\$\{?[A-Za-z_][A-Za-z0-9_]*' \
        | tr -d '${' \
        | LC_ALL=C.UTF-8 sort -u)
}

# Rule 5, invocation half -- upstream given -u or -p directly.
_rule_upstream_flags() {
    local rel=$1 lineno=$2 rest=$3 cmd=$4 tok
    for tok in $rest; do
        case $tok in
            -u|-p|-u*|-p*)
                [[ $tok =~ ^-[up]([^a-zA-Z-]|$) ]] || [[ $tok == -u || $tok == -p ]] || continue
                gate_fail "$rel" "$lineno" \
                    'passes %s to %s. Upstream is driven as an unattended sensor install, which never asks for a credential; -u and -p put it in upstream argv and in a child argv.' \
                    "$tok" "$cmd"
                return 0
                ;;
        esac
    done
}

# Rule 5, claim half -- upstream unattended flag set carrying -u or -p, on
# any line of any file. A document that says we do this is wrong even when
# the code does not.
_rule_upstream_claim() {
    local rel=$1 lineno=$2 text=$3
    local has_s=0 has_t=0 has_ref=0 bad='' i n
    local -a tokens=() clean=()
    # shellcheck disable=SC2206
    tokens=( $text )
    for (( i = 0; i < ${#tokens[@]}; i++ )); do
        tok=${tokens[i]}
        tok=${tok#"${tok%%[!\`\'\"([]*}"}
        tok=${tok%"${tok##*[!\`\'\"),.;:]}"}
        clean+=("$tok")
    done
    n=${#clean[@]}
    for (( i = 0; i < n; i++ )); do
        case ${clean[i]} in
            -s) has_s=1 ;;
            -t) has_t=1 ;;
            -b|-r) has_ref=1 ;;
            -u|-p)
                # An operand must follow, or this is a LIST of flag names --
                # "do not put -s, -t, -u, -p here" is a prohibition, not an
                # invocation, and a gate that cannot tell them apart punishes
                # the documentation that gets it right.
                if (( i + 1 < n )) && [[ -n ${clean[i + 1]} && ${clean[i + 1]} != -* ]]; then
                    bad=${clean[i]}
                fi
                ;;
        esac
    done
    (( has_s && has_t && has_ref )) || return 0
    [[ -n $bad ]] || return 0
    _flag "$rel" "$lineno" "$R_UPSTREAM_CLAIM" \
        'describes upstream being driven with %s alongside its unattended flags. It is not, and must not be: the credential branch is never entered. (%s)' \
        "$bad" "$text"
}

# ---------------------------------------------------------------------------
while IFS= read -r path; do
    rel=$(gate_rel "$path")
    kind=$(gate_kind "$path")
    GATE_PATH=$path
    GATE_CHECKED=$(( GATE_CHECKED + 1 ))

    # --- Rules 3 and 5-claim: every line of every file ---------------------
    while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        _flag "$rel" "${hit%%:*}" "$R_PASSWORD_FLAG" \
            'documents a flag whose name ends in -password and which takes a VALUE. Name it -password-file and take a PATH. (%s)' \
            "${hit#*:}"
    done < <(grep -anE -e "$META" -- "$path" 2>/dev/null || true)

    while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        line=${hit#*:}
        grep -qE 'store_true|store_const|action="count"' <<< "$line" && continue
        _flag "$rel" "${hit%%:*}" "$R_PASSWORD_FLAG" \
            'defines a Python flag whose name ends in -password and which takes a value. (%s)' "$line"
    done < <(grep -anE -e "$PY_FLAG" -- "$path" 2>/dev/null || true)

    while IFS= read -r hit; do
        [[ -n $hit ]] || continue
        _rule_upstream_claim "$rel" "${hit%%:*}" "${hit#*:}"
    done < <(grep -anE -e '(^|[^A-Za-z0-9])-[a-z]([^a-zA-Z]|$)' -- "$path" 2>/dev/null || true)

    # --- Code rules --------------------------------------------------------
    case $kind in
        shell|md|yaml) ;;
        *) continue ;;
    esac

    LINENOS=(); TEXTS=()
    while IFS= read -r rec; do
        lineno=${rec%%$'\t'*}
        rest=${rec#*$'\t'}
        reckind=${rest%%$'\t'*}
        text=${rest#*$'\t'}
        [[ $reckind == code ]] || continue
        LINENOS+=("$lineno")
        TEXTS+=("$text")
    done < <(if [[ $kind == shell ]]; then gate_lex shellq1 "$path"; else gate_lex_auto "$path"; fi)

    total=${#TEXTS[@]}
    for (( idx = 0; idx < total; idx++ )); do
        text=${TEXTS[idx]}
        lineno=${LINENOS[idx]}
        _scan_segments "$rel" "$lineno" "$text"

        # Rule 3, shell case-label form: `--x-password)` that goes on to
        # consume a value before the branch ends.
        if [[ $text =~ ^[[:space:]]*(-[^\)\|]*\|)*--[a-z0-9-]*-password\)[[:space:]]*$ ]]; then
            for (( look = idx + 1; look < total && look < idx + 12; look++ )); do
                [[ ${TEXTS[look]} == *';;'* ]] && break
                if [[ ${TEXTS[look]} =~ $TAKES_VALUE ]]; then
                    _flag "$rel" "$lineno" "$R_PASSWORD_FLAG" \
                        'defines a flag whose name ends in -password and which consumes a value at line %s. Take a PATH instead and name it -password-file.' \
                        "${LINENOS[look]}"
                    break
                fi
            done
        fi
    done
done < <(gate_files)

gate_end
