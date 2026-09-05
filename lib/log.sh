# SPDX-License-Identifier: Apache-2.0
# lib/log.sh -- the transcript, the redactor, and the leak tripwire.
#
# WHY THIS FILE IS THE ONE TO READ CLOSELY
#   A secrets manager protects a value at rest. Nothing protects it in a run's
#   own output. Both credential incidents this platform has had were exactly
#   that -- a shell builtin printing the environment, and an application
#   logging its own configuration object at startup under a comment claiming it
#   did not. Neither was a secrets-management failure. So this file assumes the
#   transcript is the leak surface and treats it as one:
#
#     1. every byte the run writes to stdout or stderr passes through an
#        in-process redactor BEFORE it reaches the terminal or the file;
#     2. after the run, the FINISHED files are searched for each registered
#        value, and a hit truncates them and fails the run.
#
#   (1) is prevention and (2) is the tripwire that catches what (1) could not
#   see -- above all ansible-core's own log, which ansible writes directly to
#   ANSIBLE_LOG_PATH without passing through us.
#
# WHY THE REDACTOR IS PURE BASH, AND WHY THAT IS NOT A STYLE CHOICE
#   The obvious implementation is a pipe into `sed`, `perl` or `awk`. Every one
#   of those puts the secret pattern into that process's ARGUMENT LIST, and on
#   Linux /proc/<pid>/cmdline is world-readable for the lifetime of the
#   process. The redactor would then become the very leak it exists to
#   prevent -- and a worse one, because argv is readable by any local user
#   while the transcript is at least mode 0600. So the substitution is done
#   with bash parameter expansion, `${line//"$secret"/[REDACTED]}`, which
#   happens inside this shell and touches no process boundary at all.
#
#   The same reasoning is why the tripwire's patterns reach `grep` on a file
#   descriptor via process substitution (`-f <(printf ...)`) rather than as
#   arguments, and why log_add_secret takes its value as a FUNCTION argument:
#   function arguments are shell state, not process arguments.
#
# THE QUOTES IN ${line//"$secret"/...} ARE LOAD-BEARING
#   Unquoted, bash treats the pattern as a glob. A password containing `*`,
#   `?` or `[` would then match the wrong thing or nothing at all, and the
#   failure is silent. Quoted, it is a literal substring.
#
# HOW IT IS WIRED
#   log_init saves the real stdout and stderr on fds 3 and 4, then redirects
#   both into a background "pump" over a FIFO. The pump reads a line, redacts
#   it, and writes it twice: to fd 4 (the human stream) and to the transcript.
#   Human output is therefore on stderr and fd 3 stays clean, which is what
#   makes `--json` able to put the result document alone on real stdout.
#
#   The pump is a forked shell, so it cannot see values registered later in the
#   parent. Secrets therefore travel to it IN BAND, over the pipe that already
#   exists: log_add_secret writes one control line, tagged with a per-run
#   random nonce, carrying the value base64-encoded. The pump consumes that
#   line -- it is never emitted and never written -- and adds the value to its
#   own set. The value stays on a file descriptor from end to end: never argv,
#   never a file, never the environment. Pipe ordering also makes it race-free:
#   a value is registered before any line that could contain it can be read.
#
# shellcheck shell=bash

if [[ -n ${_TPOT_LOG_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_LOG_SH_LOADED=1

# ---------------------------------------------------------------------------
# Constants.
#
# _TPOT_REDACT_MIN_LEN -- values shorter than this are not redacted from the
#   stream. A three-character value occurs by coincidence in ordinary
#   transcript text ("tmp", "log", a version number), and redacting it would
#   destroy the transcript while protecting nothing worth protecting.
#   Preflight's `secret_length` check is where a too-short password is
#   reported to the user.
#
# _TPOT_TRIPWIRE_MIN_LEN -- the tripwire's own, higher, floor. The tripwire
#   searches finished text for a literal string and a hit costs the whole run,
#   so its false-positive tolerance is much lower than the redactor's. Between
#   the two thresholds a value is scrubbed from the stream but not treated as
#   proof of a leak, which is the right way round: over-redacting is free,
#   over-failing is not.
# ---------------------------------------------------------------------------
readonly _TPOT_REDACT_MIN_LEN=4
readonly _TPOT_TRIPWIRE_MIN_LEN=8
readonly _TPOT_REDACT_TOKEN='[REDACTED]'

# Registered plaintext values, in the parent shell. The tripwire and
# log_redact read this; the pump keeps its own copy, fed over the pipe.
declare -ga _TPOT_SECRETS=()

_TPOT_LOG_ACTIVE=0
_TPOT_LOG_PUMP_PID=''
_TPOT_LOG_MAGIC=''
_TPOT_LOG_FD3=0

# ---------------------------------------------------------------------------
# _tpot_log_nonce
#   A per-run tag for the in-band control line. It must be unguessable, so
#   that no output produced by a child process can be mistaken for a secret
#   registration and swallowed. /dev/urandom when available, and a
#   pid/RANDOM/clock mix when it is not -- which is weaker but still not
#   something a honeypot's own log output arrives at by accident.
# ---------------------------------------------------------------------------
_tpot_log_nonce() {
    local n=''
    if [[ -r /dev/urandom ]]; then
        n=$(od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n') || n=''
    fi
    if [[ -z $n ]]; then
        n="$$-${RANDOM}${RANDOM}${RANDOM}-$(date -u +%s 2>/dev/null || printf '0')"
    fi
    printf 'TPOT-LOG-SECRET-%s' "$n"
}

# ---------------------------------------------------------------------------
# _tpot_log_fragments MINLEN VALUE
#   Print the substrings of VALUE that a line-oriented matcher can usefully
#   look for, one per line, dropping any shorter than MINLEN.
#
#   A value with no newline in it is its own only fragment. A value that
#   CONTAINS a newline can never match a single line of output, so it is split
#   on newlines and each piece is matched separately. Without this, a
#   multi-line password would pass through the redactor untouched, one visible
#   line at a time.
#
#   It also guarantees no empty pattern ever reaches grep -f, where an empty
#   pattern line matches every line of the file and would fire the tripwire on
#   every run.
# ---------------------------------------------------------------------------
_tpot_log_fragments() {
    local min=${1:-4} value=${2-} rest frag
    rest=$value
    while [[ $rest == *$'\n'* ]]; do
        frag=${rest%%$'\n'*}
        rest=${rest#*$'\n'}
        if (( ${#frag} >= min )); then
            printf '%s\n' "$frag"
        fi
    done
    if (( ${#rest} >= min )); then
        printf '%s\n' "$rest"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_log_pump MAGIC LOGFILE TOKEN MINLEN
#   The background reader. Runs in a forked shell with the FIFO on stdin, the
#   original stderr on fd 4, and the transcript opened on fd 5.
#
#   It ignores INT/TERM/HUP deliberately: when the user interrupts the run, the
#   pump must outlive the interrupt long enough to drain what is still in the
#   pipe. Otherwise the last lines before the interrupt -- often the most
#   interesting ones -- are lost, and the tripwire ends up scanning a truncated
#   file and calling it clean.
# ---------------------------------------------------------------------------
_tpot_log_pump() {
    local magic=${1-} log=${2-} token=${3-} minlen=${4:-4}
    local line out s frag
    local -a secrets=()

    trap '' INT TERM HUP

    # The pump must outlive every kind of trouble the run itself has. `set -e`
    # is inherited from install.sh, and under it a single failed write to a
    # closed terminal would kill the reader -- which then kills the installer
    # with SIGPIPE on its next line of output, and loses the transcript.
    set +e

    if ! { : >>"$log"; } 2>/dev/null; then
        log=/dev/null
    fi
    exec 5>>"$log"

    # One redaction pass, factored so the loop body and the final partial-line
    # flush below cannot diverge.
    _pump_redact() {
        out=${1-}
        local pat
        if (( ${#secrets[@]} > 0 )); then
            for pat in "${secrets[@]}"; do
                [[ -n $pat ]] || continue
                # The quotes around "$pat" are what stop bash treating a
                # password containing * ? or [ as a glob. Do not remove them.
                out=${out//"$pat"/$token}
            done
        fi
    }

    # `<&0` is redundant to bash and deliberate to a reader: this loop's input
    # is the FIFO the invocation redirected onto stdin, and it is never, on any
    # path, a terminal. The product's core promise is that install.sh cannot
    # reach an interactive prompt, so every `read` in this tree says out loud
    # where its bytes come from.
    while IFS= read -r line <&0; do
        if [[ -n $magic && $line == "$magic "* ]]; then
            # A registration, not output. Decode it, remember it, emit nothing.
            s=$(printf '%s' "${line#"$magic" }" | base64 -d 2>/dev/null) || s=''
            if [[ -n $s ]]; then
                while IFS= read -r frag; do
                    secrets+=("$frag")
                done < <(_tpot_log_fragments "$minlen" "$s")
            fi
            continue
        fi
        _pump_redact "$line"
        printf '%s\n' "$out" >&4
        printf '%s\n' "$out" >&5
    done

    # `read` returns non-zero at EOF but has already assigned whatever it
    # managed to read, so a final line with no trailing newline -- a progress
    # bar, a prompt -- lives here and nowhere else. Flushing it without adding
    # a newline keeps the transcript byte-faithful.
    if [[ -n ${line:-} ]]; then
        _pump_redact "$line"
        printf '%s' "$out" >&4
        printf '%s' "$out" >&5
    fi

    exec 5>&-
    return 0
}

# ---------------------------------------------------------------------------
# log_init
#   Create the log directory 0750 and this run's two files 0600, then start
#   the pump and redirect stdout and stderr into it.
#
#   Reads TPOT_LOG_DIR and TPOT_RUN_ID; sets TPOT_LOG and TPOT_ANSIBLE_LOG.
#   Those four names are also, uppercased, input-variable names, which is why
#   install.sh unsets them before anything else runs -- and why nothing here
#   may ever `export` one. Exporting would hand our internal path to
#   lib/config.py as though a user had supplied it.
#
#   Idempotent. Returns non-zero without starting anything if the directory or
#   the files cannot be created, so install.sh can fail with a real message
#   rather than half-logging.
# ---------------------------------------------------------------------------
log_init() {
    (( _TPOT_LOG_ACTIVE == 1 )) && return 0

    local dir=${TPOT_LOG_DIR:-/var/log/tpot-automation}
    local run=${TPOT_RUN_ID:-}
    [[ -n $run ]] || run=$(date -u +%Y%m%dT%H%M%SZ)
    TPOT_LOG_DIR=$dir
    TPOT_RUN_ID=$run

    mkdir -p -- "$dir" || return 1
    chmod 0750 -- "$dir" || return 1

    TPOT_LOG="$dir/install-$run.log"
    TPOT_ANSIBLE_LOG="$dir/ansible-$run.log"

    local f
    for f in "$TPOT_LOG" "$TPOT_ANSIBLE_LOG"; do
        : >>"$f" || return 1
        chmod 0600 -- "$f" || return 1
    done

    _TPOT_LOG_MAGIC=$(_tpot_log_nonce)

    # A named pipe rather than `exec > >(...)`: process substitution's PID is
    # not reliably available across the bash versions in the support matrix,
    # and log_stop MUST be able to wait for this specific child. Without that
    # wait the last lines of the transcript are still in flight when the
    # tripwire scans the file.
    local fifo="$dir/.pump-$run.$$"
    rm -f -- "$fifo"
    mkfifo -m 0600 -- "$fifo" || return 1

    exec 3>&1 4>&2
    _TPOT_LOG_FD3=1

    _tpot_log_pump "$_TPOT_LOG_MAGIC" "$TPOT_LOG" "$_TPOT_REDACT_TOKEN" \
        "$_TPOT_REDACT_MIN_LEN" <"$fifo" &
    _TPOT_LOG_PUMP_PID=$!

    # Blocks until the pump has the read end open, then both ends exist and
    # the FIFO's name is no longer needed by anyone.
    exec >"$fifo" 2>&1
    rm -f -- "$fifo"

    _TPOT_LOG_ACTIVE=1

    # Anything registered before the pump existed is pushed now, before the
    # first line of output can be written.
    local s
    if (( ${#_TPOT_SECRETS[@]} > 0 )); then
        for s in "${_TPOT_SECRETS[@]}"; do
            _tpot_log_push_secret "$s"
        done
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_log_push_secret VALUE
#   Send one value to the pump as an in-band control line.
#
#   base64 because a password may contain a newline and the channel is
#   line-oriented. `printf` is a bash builtin, so the value never becomes a
#   process argument on the way into base64's stdin.
# ---------------------------------------------------------------------------
_tpot_log_push_secret() {
    local v=${1-} b64
    [[ -n $v && -n $_TPOT_LOG_MAGIC ]] || return 0
    b64=$(printf '%s' "$v" | base64 2>/dev/null | tr -d '\n') || b64=''
    [[ -n $b64 ]] || return 0

    # A write larger than PIPE_BUF is not atomic, so a very large value could
    # interleave with concurrent output and arrive corrupted -- which would
    # mean silently not redacting it. Refusing loudly is the only honest
    # option; the message names no value and no key.
    if (( ${#b64} > 3000 )); then
        printf 'WARN: a supplied value is too large to register with the log redactor; it will NOT be redacted\n' >&2
        return 0
    fi
    printf '%s %s\n' "$_TPOT_LOG_MAGIC" "$b64"
    return 0
}

# ---------------------------------------------------------------------------
# log_add_secret PLAINTEXT
#   Register one value for redaction. Idempotent; values shorter than
#   _TPOT_REDACT_MIN_LEN are ignored (see the constant's comment).
#
#   The value arrives as a function argument, which is shell state and never
#   appears in /proc. install.sh obtains it from `config.py secrets` through
#   process substitution and decodes it with a builtin printf into base64 -d,
#   so it is on a file descriptor at every step.
# ---------------------------------------------------------------------------
log_add_secret() {
    local v=${1-} s
    [[ -n $v ]] || return 0
    (( ${#v} >= _TPOT_REDACT_MIN_LEN )) || return 0

    if (( ${#_TPOT_SECRETS[@]} > 0 )); then
        for s in "${_TPOT_SECRETS[@]}"; do
            [[ $s == "$v" ]] && return 0
        done
    fi
    _TPOT_SECRETS+=("$v")

    if (( _TPOT_LOG_ACTIVE == 1 )); then
        _tpot_log_push_secret "$v"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# log_secret_count
#   How many values are registered. The count only -- never a value, never a
#   length, never a key name.
# ---------------------------------------------------------------------------
log_secret_count() {
    printf '%s\n' "${#_TPOT_SECRETS[@]}"
    return 0
}

# ---------------------------------------------------------------------------
# log_redact STRING
#   Print STRING with every registered value replaced. Used for the paths that
#   do not go through the pump: fd 3 (--json output) and any message written
#   before log_init has run.
# ---------------------------------------------------------------------------
log_redact() {
    local out=${1-} s frag
    if (( ${#_TPOT_SECRETS[@]} > 0 )); then
        for s in "${_TPOT_SECRETS[@]}"; do
            [[ -n $s ]] || continue
            if (( ${#s} >= _TPOT_REDACT_MIN_LEN )); then
                # Quoted pattern: literal substring, not a glob.
                out=${out//"$s"/$_TPOT_REDACT_TOKEN}
            fi
            if [[ $s == *$'\n'* ]]; then
                while IFS= read -r frag; do
                    out=${out//"$frag"/$_TPOT_REDACT_TOKEN}
                done < <(_tpot_log_fragments "$_TPOT_REDACT_MIN_LEN" "$s")
            fi
        done
    fi
    printf '%s\n' "$out"
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_log_say LEVEL FMT [ARGS...]
#   The one place a message is formatted and emitted. printf -v formats in
#   process, so no argument list is created for anything.
# ---------------------------------------------------------------------------
_tpot_log_say() {
    local level=${1-} fmt=${2-}
    if (( $# > 2 )); then shift 2; else shift $#; fi
    local msg
    # shellcheck disable=SC2059  # the format string is the documented API
    printf -v msg -- "$fmt" "$@"
    [[ -n $level ]] && msg="$level: $msg"
    if (( _TPOT_LOG_ACTIVE == 1 )); then
        # The pump redacts on the way past.
        printf '%s\n' "$msg" >&2
    else
        log_redact "$msg" >&2
    fi
    return 0
}

# log_info / log_warn / log_error -- printf-style, to the human stream.
log_info()  { _tpot_log_say ''      "$@"; }
log_warn()  { _tpot_log_say 'WARN'  "$@"; }
log_error() { _tpot_log_say 'ERROR' "$@"; }

# ---------------------------------------------------------------------------
# log_die CODE FMT [ARGS...]
#   Report and exit. The EXIT trap installed by install.sh still runs, so
#   result.json is written on this path like every other.
# ---------------------------------------------------------------------------
log_die() {
    local code=${1:-40}
    if (( $# > 1 )); then shift; else shift $#; fi
    _tpot_log_say 'ERROR' "$@"
    exit "$code"
}

# ---------------------------------------------------------------------------
# log_emit_stdout STRING
#   Write to the REAL stdout (fd 3), redacted. The only writer of fd 3, and
#   the only way `--json` gets the result document onto stdout while every
#   human byte goes to stderr.
# ---------------------------------------------------------------------------
log_emit_stdout() {
    local s
    s=$(log_redact "${1-}")
    if (( _TPOT_LOG_FD3 == 1 )); then
        printf '%s\n' "$s" >&3
    else
        printf '%s\n' "$s"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# log_stop
#   Restore the real descriptors and WAIT for the pump to drain.
#
#   The wait is not optional. Restoring fd 1 and 2 drops our write ends of the
#   pipe, the pump reads EOF and exits -- but until it has, the tail of the
#   transcript is still in the pipe, and a tripwire that ran first would scan
#   an incomplete file and find nothing.
# ---------------------------------------------------------------------------
log_stop() {
    (( _TPOT_LOG_ACTIVE == 1 )) || return 0
    _TPOT_LOG_ACTIVE=0
    exec 1>&3 2>&4
    if [[ -n $_TPOT_LOG_PUMP_PID ]]; then
        wait "$_TPOT_LOG_PUMP_PID" 2>/dev/null || true
        _TPOT_LOG_PUMP_PID=''
    fi
    return 0
}

# ---------------------------------------------------------------------------
# log_tripwire
#   Scan the FINISHED log files for each registered value.
#   Returns 1 when one is found, 0 otherwise. No side effects, nothing
#   printed: log_tripwire_enforce is what acts on the verdict.
#
#   Both files are scanned. The transcript should be clean because everything
#   in it came through the redactor; ansible-core's own log did NOT, because
#   ansible writes it directly, and `no_log: true` on the tasks that touch a
#   credential is the only thing keeping it clean. That is precisely why a
#   tripwire exists rather than trusting the redactor.
#
#   Patterns reach grep on a file descriptor through process substitution, so
#   they never enter an argument list. -F makes them literal, so a password
#   full of regex metacharacters is matched as typed.
# ---------------------------------------------------------------------------
log_tripwire() {
    local s frag rc=0
    local -a patterns=() files=()

    if (( ${#_TPOT_SECRETS[@]} > 0 )); then
        for s in "${_TPOT_SECRETS[@]}"; do
            [[ -n $s ]] || continue
            while IFS= read -r frag; do
                patterns+=("$frag")
            done < <(_tpot_log_fragments "$_TPOT_TRIPWIRE_MIN_LEN" "$s")
        done
    fi

    # MANDATORY, and the single most likely way to get this file wrong:
    # `grep -f` with no patterns, or with a zero-length pattern line, matches
    # EVERY line. Without this guard the tripwire fires on every run that
    # supplied no secret, and every such run exits 40.
    (( ${#patterns[@]} == 0 )) && return 0

    [[ -n ${TPOT_LOG:-} && -f ${TPOT_LOG:-} ]] && files+=("$TPOT_LOG")
    [[ -n ${TPOT_ANSIBLE_LOG:-} && -f ${TPOT_ANSIBLE_LOG:-} ]] && files+=("$TPOT_ANSIBLE_LOG")
    (( ${#files[@]} == 0 )) && return 0

    if command -v grep >/dev/null 2>&1; then
        rc=0
        grep -F -q -f <(printf '%s\n' "${patterns[@]}") -- "${files[@]}" || rc=$?
        case $rc in
            0) return 1 ;;   # a hit
            1) return 0 ;;   # clean
            *)
                # grep could not read a file. An unexercised check is not a
                # pass, so fall through to the in-shell scan rather than
                # reporting clean.
                ;;
        esac
    fi

    # Fallback: the same search in bash, for a box where grep is missing or
    # errored. Slower, and identical in meaning.
    local file line pat
    for file in "${files[@]}"; do
        while IFS= read -r line || [[ -n $line ]]; do
            for pat in "${patterns[@]}"; do
                [[ $line == *"$pat"* ]] && return 1
            done
        done <"$file"
    done
    return 0
}

# ---------------------------------------------------------------------------
# log_tripwire_scrub
#   Run the tripwire and act on a hit: truncate both log files and record the
#   outcome and the exit code. Returns 1 on a hit, 0 when the logs are clean.
#   It does NOT exit, so it is safe to call from inside an EXIT trap.
#
#   It prints the FACT and nothing else. Not the line, not the key, not the
#   count -- a diagnostic that quotes the leak is the same leak, and this is
#   the message someone will paste into a bug report.
#
#   Truncation is deliberate and it is destructive: the transcript is the
#   thing you would want in order to debug the run, and destroying it costs
#   real diagnostic value. It is still right. A file containing a live
#   credential is a liability that outlives the run, and it has usually been
#   copied somewhere before anyone reads this message.
# ---------------------------------------------------------------------------
log_tripwire_scrub() {
    if log_tripwire; then
        return 0
    fi

    local f
    for f in "${TPOT_LOG:-}" "${TPOT_ANSIBLE_LOG:-}"; do
        [[ -n $f && -f $f ]] && : >"$f"
    done

    TPOT_OUTCOME='credential_leaked_to_log'
    TPOT_EXIT_CODE=${EX_INTERNAL:-40}

    printf '%s\n' \
        'ERROR: a value supplied to this run was found in its own log output.' \
        'Both log files have been truncated. Nothing further about the match is' \
        'printed here, deliberately: naming it would repeat the leak.' \
        'Treat the credential as exposed on this host and rotate it.' \
        'This is a bug in the installer -- please report it, without the logs.' >&2

    return 1
}

# ---------------------------------------------------------------------------
# log_tripwire_enforce
#   log_tripwire_scrub, then exit. Use this from ordinary code: the EXIT trap
#   install.sh set is still armed, so result.json is written and carries the
#   credential_leaked_to_log outcome that log_tripwire_scrub just set.
#
#   Do NOT use it from inside an EXIT trap -- call log_tripwire_scrub there,
#   then res_write, then exit with $TPOT_EXIT_CODE. Which of the two you want
#   depends only on where you stand, and getting it wrong the other way round
#   costs the artefact rather than the exit code.
# ---------------------------------------------------------------------------
log_tripwire_enforce() {
    log_tripwire_scrub && return 0
    exit "${EX_INTERNAL:-40}"
}

# ---------------------------------------------------------------------------
# LOG ROTATION IS NOT DONE HERE, AND THAT IS DELIBERATE.
#
# The transcripts this file creates accumulate -- one install-<run id>.log and
# one ansible-<run id>.log per invocation, plus the copy of upstream's log
# that roles/tpot_install saves beside them -- so something has to bound them.
# The policy is lib/tpot-automation.logrotate and roles/finalize installs it,
# in section 6 of its tasks/main.yml.
#
# It used to be installed from here, by a function with no callers, while the
# shipped policy file asserted in its own header that it WAS installed that
# way. Two implementations, one of them dead and the other one prose, is worse
# than one: the honest place for it is the role that already writes this
# installer's other permanent artefacts -- the tree copy and the post-boot
# unit -- and that is where it now lives. Nothing in this library mutates
# /etc.
# ---------------------------------------------------------------------------
