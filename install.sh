#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# install.sh -- unattended T-Pot honeypot installer. THE entrypoint.
#
# Runs as root, on the machine that is to become the honeypot. It owns the
# order in which things happen and nothing else: argument parsing, the config
# merge, preflight, dependency bootstrap, the tmpfs secret channel, invoking
# the play, mapping a failure class to an exit code, writing result.json, the
# reboot decision and the notice. Everything that CHANGES the box lives in
# Ansible, which is what makes --check meaningful.
#
# THE ORDER IS ITSELF A FIX
#   The installer this project replaces rewrote its whole tree with `sed -i`
#   at lines 9-13 and only asked whether it was root at line 17. A run that
#   aborted for being unprivileged had already mutated its own credentials
#   file. So:
#
#     1  parse flags                                        no mutation
#     2  open the transcript through the redactor            creates the log dir
#     3  preflight STAGE A                                   NO mutation
#     4  merge config -> merged.json, 0600, on tmpfs         tmpfs only
#     5  preflight STAGE B                                   NO mutation
#        `-- --preflight-only exits here: 0, 11 or 12
#     6  tree hygiene: CRLF, .DS_Store, __MACOSX             FIRST mutation
#     7  dependency bootstrap                                yes
#     8  generate inventories/local/hosts.yml                yes
#     9  ansible-playbook site.yml -e @<merged>              yes
#    10  failure class -> exit code; result.json; reboot;    yes
#        the notice
#
#   STEP 9 HAS A PLAY TO RUN. site.yml, verify.yml and roles/** landed on
#   2026-09-04. The banner above step 9 says what still guards a release that
#   ships without them, and why that guard is not redundant with the file
#   manifest preflight checks at step 3.
#
#   THIS FILE HAS INSTALLED T-POT. Debian 13, 2026-09-05, three times: exit
#   20 twice -- the second with no --force override of any kind -- and once a
#   correct refusal at 11 on a deliberately socket-activated host. After the
#   reboot the honeypot answered on tcp/22. tests/MATRIX-STATUS.md is the
#   dated record and is as specific about what those runs did NOT establish
#   as about what they did; exit 0 is still among them.
#
#   ON THE DEVELOPMENT BOX it still stops where it always did. Measured
#   fully unattended -- the password in the environment, no controlling
#   terminal, stdin from /dev/null -- the run stops in preflight stage A and
#   exits 11 on the ROOT check, having changed nothing, because that machine
#   is not root.
#
#   Steps 1 to 5 leave the machine byte-identical to how they found it. That
#   is a property, not an aspiration: preflight writes only inside $RUNDIR,
#   the run's own 0700 directory on tmpfs, and the exit trap destroys it.
#
# THE PRODUCT'S CENTRAL PROMISE, AND HOW IT IS KEPT
#   `install.sh --config /root/tpot.yml </dev/null` under setsid, cloud-init
#   or CI cannot block on a prompt. Not "should not": there is exactly one
#   INTERACTIVE read in this tree -- the two `read` statements of the password
#   prompt in lib/args.sh, which take a value and its confirmation from
#   /dev/tty and are reachable only when stdin IS a terminal. Every other
#   `read` in the tree takes a redirection, a pipe or a here-string and can
#   never touch a person. tests/check-no-tty.sh fails the build on any other
#   interactive one, and the two that remain carry a gate-allow marker naming
#   the rule and the reason.
#   With no terminal, --non-interactive is implied and missing input is a
#   usage error with a message naming all three ways to supply it.
#
# WHAT IT NEVER DOES
#   * no secret is ever a command-line argument value: the merged document
#     reaches Ansible as `-e @PATH`, never as a value;
#   * nothing prints the environment -- no bare `export`, `env`, `printenv`
#     or `set`, anywhere, ever;
#   * the user's own ~/.ansible is never written, moved or deleted.
#
set -euo pipefail
set -E
shopt -s inherit_errexit 2>/dev/null || true

# ===========================================================================
# STEP 0a -- the startup preamble that stops the environment poisoning itself
# ===========================================================================
#
# Bash imports an environment variable into a shell variable of the same name
# WITH THE EXPORT ATTRIBUTE STILL SET. Several of this script's own globals
# are, uppercased, also input-variable names -- TPOT_LOG_DIR is the internal
# path and `tpot_log_dir` is a user key -- so assigning to one of them would
# change what lib/config.py reads out of the environment two steps later, and
# the run would silently configure itself from its own internals.
#
# The three directory settings are flags for a reason: the transcript is
# opened before any answer file has been read, so a value that arrived later
# could not have applied to it. A value here is therefore a usage error, not
# something to merge. The remaining names are purely internal and have no
# flag; supplying one is refused for the same reason, with a message that says
# so rather than one blaming a typo.
#
# `unset -v` removes the variable AND its environment entry, so no child sees
# it. TPOT_BRANCH and TPOT_REPO_URL belong to upstream T-Pot and are left
# alone here; lib/args.sh warns about them and ignores them.
_tpot_declined=()
for _tpot_n in TPOT_LOG TPOT_LOG_DIR TPOT_STATE_DIR TPOT_RUNTIME_DIR \
               TPOT_VERSION TPOT_RUN_ID TPOT_STARTED_AT TPOT_ANSIBLE_LOG \
               TPOT_RESULT_JSON TPOT_EXIT_CODE TPOT_OUTCOME; do
    if [[ -n ${!_tpot_n+x} ]]; then
        _tpot_declined+=("$_tpot_n")
    fi
done
unset -v TPOT_LOG TPOT_LOG_DIR TPOT_STATE_DIR TPOT_RUNTIME_DIR \
         TPOT_VERSION TPOT_RUN_ID TPOT_STARTED_AT TPOT_ANSIBLE_LOG \
         TPOT_RESULT_JSON TPOT_EXIT_CODE TPOT_OUTCOME \
         REPO_DIR RUNDIR MERGED_JSON PUBLIC_JSON SOURCES_JSON FAILURE_CLASS
unset -v _tpot_n

# ===========================================================================
# STEP 0b -- globals, then the libraries
# ===========================================================================
REPO_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)

TPOT_VERSION='unknown'
if [[ -r "$REPO_DIR/VERSION" ]]; then
    TPOT_VERSION=$(head -n 1 -- "$REPO_DIR/VERSION")
    TPOT_VERSION=${TPOT_VERSION//[[:space:]]/}
fi
[[ -n $TPOT_VERSION ]] || TPOT_VERSION='unknown'

# One instant, two spellings. They must agree: the run id names the transcript
# and started_at is what result.json's duration is measured from.
TPOT_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
TPOT_RUN_ID=$(date -u -d "$TPOT_STARTED_AT" +%Y%m%dT%H%M%SZ 2>/dev/null) \
    || TPOT_RUN_ID=$(date -u +%Y%m%dT%H%M%SZ)

# Set as the run proceeds; every one is read by the exit trap, which must work
# no matter how early the run ended.
RUNDIR=''
MERGED_JSON=''
PUBLIC_JSON=''
SOURCES_JSON=''
FAILURE_CLASS=''
TPOT_RESULT_JSON=''
TPOT_EXIT_CODE=''
TPOT_OUTCOME=''

# Guards the exit trap. Set to 0 for --help, --version and --example-config,
# which print and exit and must touch nothing at all.
_TPOT_WANT_RESULT=1
# Set the moment step 6 runs. The notice's "your box is unchanged" wording is
# only true before it.
_TPOT_MUTATED=0
_TPOT_NOTICE_PRINTED=0
_TPOT_IN_EXIT_TRAP=0

# ---------------------------------------------------------------------------
# The six exported names, and there are never any others.
#
# Every one of them exists for a CHILD PROCESS we invoke, and each is here
# rather than beside its caller so that the whole exported surface of this run
# is readable in one place:
#
#   LANG / LC_ALL      byte-stable, English output from every tool, so the
#                      transcript is diffable and the redactor is matching
#                      bytes rather than whatever the box's locale renders.
#                      C.UTF-8 and NOT plain C: ansible-core refuses to start
#                      at all when the locale encoding is not UTF-8 --
#                      "Ansible requires the locale encoding to be UTF-8;
#                      Detected None." on stderr, exit 1, before it does
#                      anything else. Plain C would therefore break every
#                      invocation of the play on every box, and the symptom
#                      would arrive as "no usable ansible-core". C.UTF-8
#                      sorts and formats exactly like C and needs no
#                      locale-gen. Its PRESENCE has been verified only on the
#                      box this was written on; on the rest of either tier it
#                      is assumed, because this installer has not yet run
#                      anywhere else.
#   DEBIAN_FRONTEND    apt must never open a dialogue: this installer is
#                      unattended by construction
#   ANSIBLE_FORCE_COLOR  no escape sequences in a file somebody will grep
#   ANSIBLE_CONFIG     ansible-core reads exactly ONE configuration file and
#                      picks it by search order. Naming ours outright means a
#                      run started from any directory behaves identically.
#   ANSIBLE_LOG_PATH   set once the transcript directory exists, so ansible's
#                      own log is a sibling of ours and inside the same 0750
#                      directory. It carries the run id, which is why it is
#                      deliberately not in ansible.cfg.
#
# THE TWO ANSIBLE_* EXPORTS ARE NOT UNAMBIGUOUSLY GOOD, AND THE DRIVER TASK
# MUST UNDO THEM. They are exported for the whole process tree, and upstream
# T-Pot's install.sh runs a NESTED ansible-playbook of its own with no
# ANSIBLE_CONFIG -- so it would inherit ours: our collections_path would
# REPLACE its default search list, our log path would interleave its
# transcript with ours, and with tpot_ansible_source set to venv our PATH and
# VIRTUAL_ENV would resolve its `ansible-playbook` to OUR ansible-core instead
# of the distro package it had just installed for itself. The task that
# invokes upstream must therefore scrub, from the child environment,
# ANSIBLE_CONFIG, ANSIBLE_LOG_PATH, PATH, VIRTUAL_ENV and PYTHONPATH -- and
# set `chdir`, because upstream wgets its playbook into $PWD and ansible-core
# would then find ./ansible.cfg anyway. Evidence and line numbers are in
# notes/upstream-facts.md, "CWD is load-bearing" -- a project record kept in
# the workspace beside this repository and NOT PUBLISHED WITH IT, so a reader
# who cloned this repository will not find that path here. It is cited rather
# than dropped because the underlying evidence is real and checkable: it is
# upstream T-Pot's own install.sh, read from source at the ref recorded there.
#
# THE DRIVER TASK DOES THAT NOW, in roles/tpot_install, and it removes the
# names rather than blanking them: Ansible's `environment:` keyword cannot
# remove anything -- measured 2026-09-04, a null value arrives in the child
# as the literal string "None" -- so the removal is done by /usr/bin/env with
# its unset option and is visible in the argv the run records. PATH is the
# one handled the other way round: it is SET to a fixed system PATH rather
# than unset, because upstream needs one and an absent PATH is not a safer
# answer than a stated one.
#
# IT HAS NOT BEEN WATCHED AGAINST THE REAL UPSTREAM. No run of this file has
# reached step 9. What was verified, on 2026-09-04, is the scrub itself,
# against a stand-in for upstream with all five names set in the parent: the
# child reported every one of them absent. The note stays here because the
# exports are set in THIS file, and whoever adds a sixth will be reading that
# task, not this preamble.
#
# No TPOT_* or IOC_* name is exported at any point. That is a correctness
# rule, not style: an exported internal would be read back by lib/config.py as
# though a user had supplied it.
# ---------------------------------------------------------------------------
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export DEBIAN_FRONTEND=noninteractive
export ANSIBLE_FORCE_COLOR=0
export ANSIBLE_CONFIG="$REPO_DIR/ansible.cfg"

# shellcheck source=lib/exitcodes.sh
. "$REPO_DIR/lib/exitcodes.sh"
# shellcheck source=lib/log.sh
. "$REPO_DIR/lib/log.sh"
# shellcheck source=lib/args.sh
. "$REPO_DIR/lib/args.sh"
# shellcheck source=lib/matrix.sh
. "$REPO_DIR/lib/matrix.sh"
# shellcheck source=lib/preflight.sh
. "$REPO_DIR/lib/preflight.sh"
# shellcheck source=lib/deps.sh
. "$REPO_DIR/lib/deps.sh"
# shellcheck source=lib/notice.sh
. "$REPO_DIR/lib/notice.sh"
# shellcheck source=lib/result.sh
. "$REPO_DIR/lib/result.sh"

# ===========================================================================
# The traps
# ===========================================================================
#
# THE ORDER INSIDE THE EXIT TRAP IS THE WHOLE POINT, and it is this:
#
#   1. stop the log pump and WAIT for it, so the transcript is complete;
#   2. run the leak tripwire over the FINISHED files;
#   3. write result.json -- and fsync it -- while $RUNDIR still exists,
#      because result.json is built from six files inside it;
#   4. only then shred and remove $RUNDIR.
#
# Getting 3 and 4 the wrong way round produces a result.json with a null host,
# null config and null preflight on every single run, and nothing anywhere
# says why. Getting 1 and 2 the wrong way round scans a truncated file and
# reports clean.

# _tpot_wipe_rundir
#   Shred every file in the run directory, then remove the tree.
#
#   On tmpfs `shred` cannot overwrite in place in any meaningful sense -- the
#   pages are freed and never written to a device. It is still done: --runtime-dir
#   exists, /dev/shm is the documented fallback, and somebody will one day
#   point it somewhere persistent. `rm -rf` is what actually guarantees the
#   removal, and it runs whether or not shred was available.
_tpot_wipe_rundir() {
    local dir=${RUNDIR:-}
    [[ -n $dir && -d $dir ]] || return 0
    if command -v shred >/dev/null 2>&1; then
        find "$dir" -type f -exec shred -u -n 1 -- {} + 2>/dev/null || true
    fi
    rm -rf -- "$dir" 2>/dev/null || true
    return 0
}

# _tpot_emit_result_json
#   --json puts the result document, and nothing else, on the REAL stdout.
#   Human output has been on stderr throughout. Emitted from the exit trap so
#   that it appears on every path, including an interruption.
_tpot_emit_result_json() {
    local file=${TPOT_RESULT_JSON:-} line
    local -a lines=()
    (( ${OPT_JSON:-0} )) || return 0
    [[ -n $file && -r $file ]] || return 0
    mapfile -t lines < "$file"
    for line in ${lines[@]+"${lines[@]}"}; do
        log_emit_stdout "$line"
    done
    return 0
}

_tpot_on_exit() {
    local code=$?
    set +e
    trap - EXIT INT TERM HUP ERR
    (( _TPOT_IN_EXIT_TRAP )) && return 0
    _TPOT_IN_EXIT_TRAP=1

    if [[ -n ${TPOT_EXIT_CODE:-} ]]; then
        code=$TPOT_EXIT_CODE
    fi

    # The notice is printed from exactly one place in a normal run (step 10).
    # This is the other one: a run that changed the box and then failed still
    # owes the operator the statement that T-Pot is NOT installed.
    if (( _TPOT_MUTATED )) && (( ! _TPOT_NOTICE_PRINTED )); then
        _tpot_print_notice "$code"
    fi

    # 1. the transcript is only complete once the pump has drained.
    log_stop

    # 2. the tripwire, over the finished files. A hit truncates both logs,
    #    sets TPOT_OUTCOME=credential_leaked_to_log and makes this run a 40 --
    #    a leaked credential is never a successful install.
    if ! log_tripwire_scrub; then
        code=${EX_INTERNAL:-40}
    fi
    TPOT_EXIT_CODE=$code

    # 3. result.json, before the run directory it is built from goes away.
    if (( _TPOT_WANT_RESULT )); then
        res_write "$code"
        _tpot_emit_result_json
    fi

    # 4. and only now.
    _tpot_wipe_rundir

    exit "$code"
}

_tpot_on_signal() {
    local signal=${1:-INT}
    set +e
    TPOT_EXIT_CODE=${EX_INTERRUPT:-30}
    TPOT_OUTCOME='interrupted'
    res_add_error "interrupted by SIG${signal}"
    log_error 'interrupted by SIG%s -- writing result.json and shredding the run directory' "$signal"
    exit "${EX_INTERRUPT:-30}"
}

_tpot_on_err() {
    local status=$? line=${1:-0} command=${2:-}
    set +e
    trap - ERR
    # BASH_COMMAND is the command TEXT before expansion, so it names a
    # variable rather than its value. It still goes through the redactor.
    TPOT_EXIT_CODE=${EX_INTERNAL:-40}
    TPOT_OUTCOME='internal_error'
    res_add_error "internal error at install.sh:${line} (status ${status})"
    log_error 'a command failed at install.sh:%s with status %s: %s' "$line" "$status" "$command"
    log_error 'this is a bug in the installer. Please file an issue and attach the transcript.'
    exit "${EX_INTERNAL:-40}"
}

# ===========================================================================
# Helpers
# ===========================================================================

# _tpot_bool N -- print `true` for a non-zero shell boolean, `false` otherwise.
#   A one-line function rather than `(( x )) && printf true || printf false`,
#   because that idiom inside a command substitution runs under errexit and
#   its failing first branch is a trap away from ending the run.
_tpot_bool() {
    if (( ${1:-0} )); then
        printf 'true\n'
    else
        printf 'false\n'
    fi
    return 0
}

# _tpot_cfg KEY
#   One value out of the merged PUBLIC document -- the merged document with
#   every secret-typed key REMOVED. install.sh never reads $MERGED_JSON, so
#   it cannot print a credential even by mistake; the only thing it ever does
#   with the private document is pass its PATH to ansible-playbook.
#   Prints the empty string when the key is absent or the document is not
#   there yet; every caller has a documented default.
_tpot_cfg() {
    local key=${1:-} out=''
    [[ -n $key && -n ${PUBLIC_JSON:-} && -r ${PUBLIC_JSON:-} ]] || return 0
    out=$(python3 "$REPO_DIR/lib/config.py" get \
            --schema "$REPO_DIR/lib/varschema.json" \
            --from "$PUBLIC_JSON" "$key" 2>/dev/null) || out=''
    printf '%s\n' "$out"
    return 0
}

# _tpot_cfg_true KEY -- verdict: is this boolean key true in the merged doc?
_tpot_cfg_true() {
    [[ $(_tpot_cfg "${1:-}") == 'true' ]]
}

# _tpot_report_value KEY
#   One top-level value out of $RUNDIR/ansible-report.json, which the play
#   writes in its `always:`. Empty when the play never ran, which is exactly
#   what "we do not know" should look like.
_tpot_report_value() {
    local key=${1:-} file="${RUNDIR:-}/ansible-report.json" out=''
    [[ -n $key && -r $file ]] || return 0
    out=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        document = json.load(handle)
except Exception:
    raise SystemExit(0)
if not isinstance(document, dict):
    raise SystemExit(0)
value = document.get(sys.argv[2])
if value is None:
    raise SystemExit(0)
if isinstance(value, bool):
    sys.stdout.write("true" if value else "false")
else:
    sys.stdout.write(str(value))
' "$file" "$key" 2>/dev/null) || out=''
    printf '%s\n' "$out"
    return 0
}

# ===========================================================================
# STEP 2 -- the transcript
# ===========================================================================
#
# log_init creates $TPOT_LOG_DIR (0750) and the two 0600 files inside it, then
# redirects this process's stdout and stderr through a redacting pump. From
# here on every byte the run writes is scanned for registered secrets before
# it reaches the terminal or the file.
#
# WHEN IT CANNOT BE OPENED, the answer depends on who we are, and the split is
# deliberate:
#
#   not root -- almost certainly the real problem, and preflight stage A is
#               about to say so far better than a message about a directory.
#               Warn, continue without a transcript, and let stage A produce
#               the diagnosis the operator can act on.
#   root     -- something is genuinely wrong with /var/log, and continuing
#               would run the rest of this installer with no redactor between
#               a credential and the terminal. Stop.
_tpot_open_transcript() {
    local uid
    if log_init; then
        # A sibling of our own transcript, inside the same 0750 directory.
        # ansible writes this file directly, without passing through our
        # redactor, which is exactly why the leak tripwire scans it too.
        export ANSIBLE_LOG_PATH="$TPOT_ANSIBLE_LOG"
        log_info 'tpot-automation %s -- run %s' "$TPOT_VERSION" "$TPOT_RUN_ID"
        log_info 'transcript: %s' "$TPOT_LOG"
        log_info 'ansible log: %s' "$TPOT_ANSIBLE_LOG"
        return 0
    fi
    uid=$(id -u 2>/dev/null) || uid=''
    if [[ $uid == '0' ]]; then
        TPOT_EXIT_CODE=$EX_PREFLIGHT
        TPOT_OUTCOME='preflight_failed'
        res_add_error "the transcript directory ${TPOT_LOG_DIR} could not be created"
        log_error 'cannot create the transcript directory %s.' "$TPOT_LOG_DIR"
        log_error 'refusing to continue without a redacted transcript. Use --log-dir DIR.'
        exit "$EX_PREFLIGHT"
    fi
    # No pump, so nothing has moved stdout out of the way -- and "human output
    # on stderr, stdout reserved for --json" is a contract, not a side effect
    # of logging being on. Set the descriptors up the way log_init would have:
    # fd 3 becomes the real stdout, fd 4 the real stderr, and fd 1 is pointed
    # at stderr so that pf_print and every other plain printf lands there.
    # _TPOT_LOG_FD3 is lib/log.sh's own flag for "fd 3 holds the real stdout",
    # and log_emit_stdout is what reads it.
    exec 3>&1 4>&2 1>&2
    _TPOT_LOG_FD3=1
    log_warn 'cannot create the transcript directory %s; continuing without a transcript' \
        "$TPOT_LOG_DIR"
    log_warn 'nothing this run prints will be redacted, and nothing will be kept'
    res_add_warning "no transcript: ${TPOT_LOG_DIR} could not be created"
    return 0
}

# ===========================================================================
# STEP 3.5 -- the run directory
# ===========================================================================
#
# 0700, on tmpfs, holding merged.json and the five interchange files. Created
# only after stage A has established that its parent IS tmpfs, because the
# whole reason it is here rather than in /tmp is that the merged document
# holds the dashboard password and must never touch a persistent filesystem.
_tpot_make_rundir() {
    local parent=${OPT_RUNTIME_PARENT:-/run}

    RUNDIR=$(mktemp -d -p "$parent" tpot-automation.XXXXXXXX) || {
        TPOT_EXIT_CODE=$EX_PREFLIGHT
        TPOT_OUTCOME='preflight_failed'
        log_error 'cannot create a run directory under %s. Use --runtime-dir DIR.' "$parent"
        exit "$EX_PREFLIGHT"
    }
    chmod 0700 -- "$RUNDIR"

    MERGED_JSON="$RUNDIR/merged.json"
    PUBLIC_JSON="$RUNDIR/public.json"
    SOURCES_JSON="$RUNDIR/sources.json"
    FAILURE_CLASS="$RUNDIR/failure-class"
    return 0
}

# ===========================================================================
# STEP 4 -- the merge
# ===========================================================================
#
# lib/config.py implements the precedence order once, and this is its only
# caller. Three documents come out: merged.json (everything, 0600, tmpfs),
# public.json (the same minus every secret-typed key -- removed, not blanked)
# and sources.json (which channel supplied each key, by name).
#
# THE SECRET NEVER TOUCHES ARGV. Answer files and password FILES arrive as
# paths; a value typed at a terminal arrives on stdin. The only thing that
# ever goes near a command line is a key name.
_tpot_merge_config() {
    local action=$1
    local rc=0 entry password=''
    local -a argv=(
        merge
        --schema     "$REPO_DIR/lib/varschema.json"
        --repo-dir   "$REPO_DIR"
        --out        "$MERGED_JSON"
        --public-out "$PUBLIC_JSON"
        --sources-out "$SOURCES_JSON"
    )

    for entry in ${OPT_CONFIG_FILES[@]+"${OPT_CONFIG_FILES[@]}"}; do
        argv+=(--config "$entry")
    done
    for entry in ${OPT_OVERRIDES[@]+"${OPT_OVERRIDES[@]}"}; do
        argv+=(--set "$entry")
    done
    for entry in ${OPT_SECRET_FILES[@]+"${OPT_SECRET_FILES[@]}"}; do
        argv+=(--password-file "$entry")
    done

    # The three directory settings are resolved by lib/args.sh at parse time,
    # because the transcript opens before the merge. They are written into the
    # merged document last so that what Ansible, result.json and this shell
    # believe about them cannot differ. tpot_runtime_dir records the RESOLVED
    # run directory, not its parent: the parent is the flag, the directory is
    # the fact.
    argv+=(--set "tpot_log_dir=$TPOT_LOG_DIR")
    argv+=(--set "tpot_state_dir=$TPOT_STATE_DIR")
    argv+=(--set "tpot_runtime_dir=$RUNDIR")

    # --preflight-only and --verify-only genuinely do not need the dashboard
    # password: the first installs nothing and the second only inspects a box
    # that is already installed. Demanding one would make the documented
    # two-invocation recovery -- `install.sh --verify-only` on its own after a
    # reboot -- impossible. Preflight records `input_complete` as inconclusive
    # in that case, which is what makes --preflight-only exit 12 rather than
    # implying a real run would have worked.
    if (( OPT_PREFLIGHT_ONLY || OPT_VERIFY_ONLY )); then
        argv+=(--optional tpot_web_password)
    fi

    if [[ $action == 'prompt' ]]; then
        # The value is written to the function's STDOUT and to nothing else.
        # It is captured into a shell variable -- shell state, never argv --
        # and handed to python3 on a pipe by the printf BUILTIN, so it does
        # not become a process argument at any point and no file is created.
        if ! password=$(args_prompt_web_password); then
            exit "$EX_USAGE"
        fi
        argv+=(--secret-stdin tpot_web_password)
        printf '%s' "$password" | python3 "$REPO_DIR/lib/config.py" "${argv[@]}" || rc=$?
        unset -v password
    else
        python3 "$REPO_DIR/lib/config.py" "${argv[@]}" </dev/null || rc=$?
    fi

    case $rc in
        0)  ;;
        10) TPOT_EXIT_CODE=$EX_USAGE
            TPOT_OUTCOME='usage_error'
            exit "$EX_USAGE"
            ;;
        *)  TPOT_EXIT_CODE=$EX_INTERNAL
            TPOT_OUTCOME='internal_error'
            log_error 'the configuration merge failed with status %s. This is a bug in the installer.' "$rc"
            exit "$EX_INTERNAL"
            ;;
    esac

    chmod 0600 -- "$MERGED_JSON" "$PUBLIC_JSON" "$SOURCES_JSON" 2>/dev/null || true
    return 0
}

# ===========================================================================
# STEP 4.5 -- teach the redactor what to hide
# ===========================================================================
#
# The ONLY path by which a secret reaches lib/log.sh. `config.py secrets`
# prints one base64 line per secret-typed value that is present; base64
# because a password may contain a newline and this channel is line-oriented.
# Process substitution keeps the values on a file descriptor, and
# log_add_secret takes its value as a FUNCTION argument, which is shell state
# and never appears in /proc.
#
# mapfile rather than a `read` loop: the only INTERACTIVE reads in this tree
# are the two in lib/args.sh's password prompt, and tests/check-no-tty.sh
# fails the build on any other. The contract's illustrative snippet uses
# `read`; mapfile is the same operation under the rule the same contract
# sets.
_tpot_register_secrets() {
    local encoded
    local -a encoded_lines=()
    [[ -n ${MERGED_JSON:-} && -r ${MERGED_JSON:-} ]] || return 0
    mapfile -t encoded_lines < <(
        python3 "$REPO_DIR/lib/config.py" secrets \
            --schema "$REPO_DIR/lib/varschema.json" \
            --from "$MERGED_JSON" 2>/dev/null
    )
    for encoded in ${encoded_lines[@]+"${encoded_lines[@]}"}; do
        [[ -n $encoded ]] || continue
        log_add_secret "$(printf '%s' "$encoded" | base64 -d)"
    done
    unset -v encoded encoded_lines
    return 0
}

# ===========================================================================
# STEP 6 -- tree hygiene
# ===========================================================================
#
# The installer this project replaces began by rewriting every file in its own
# tree with `sed -i` -- before its root check, unscoped, and including .git.
# The intent was sound: a release downloaded and unzipped on Windows arrives
# with CRLF line endings that break the shebang of every script in it, and one
# unzipped on macOS carries .DS_Store, ._* and __MACOSX/ debris.
#
# So the cleanup is kept and everything wrong with it is fixed. It is the
# FIRST mutation of the run rather than the first statement; it is confined to
# $REPO_DIR; .git is pruned so no object is ever touched; it runs only on
# files whose names say they are text; and it reports what it changed instead
# of doing it silently. --preflight-only, --check and --no-tree-clean skip it
# entirely.
_tpot_tree_hygiene() {
    local file changed=0 removed=0 tmp
    local -a candidates=() debris=()

    if (( ! OPT_TREE_CLEAN )); then
        log_info 'tree: --no-tree-clean, so line endings and archive debris were left alone'
        return 0
    fi
    _TPOT_MUTATED=1

    mapfile -t debris < <(
        find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o \
            \( -name '.DS_Store' -o -name '._*' -o -name '__MACOSX' \) -print 2>/dev/null
    )
    for file in ${debris[@]+"${debris[@]}"}; do
        [[ -e $file ]] || continue
        rm -rf -- "$file" 2>/dev/null || continue
        removed=$(( removed + 1 ))
        log_info 'tree: removed archive debris %s' "$file"
    done

    mapfile -t candidates < <(
        find "$REPO_DIR" -path "$REPO_DIR/.git" -prune -o -type f \
            \( -name '*.sh'   -o -name '*.py'  -o -name '*.yml'  -o -name '*.yaml' \
            -o -name '*.json' -o -name '*.md'  -o -name '*.cfg'  -o -name '*.j2'   \
            -o -name '*.txt'  -o -name '*.tsv' -o -name '*.service' -o -name '*.hcl' \
            -o -name 'VERSION' -o -name 'LICENSE' \) -print 2>/dev/null
    )
    for file in ${candidates[@]+"${candidates[@]}"}; do
        [[ -f $file && -w $file ]] || continue
        grep -q -m 1 -e $'\r' -- "$file" 2>/dev/null || continue
        tmp="$RUNDIR/hygiene.$$"
        if tr -d '\r' < "$file" > "$tmp" 2>/dev/null && cat -- "$tmp" > "$file" 2>/dev/null; then
            changed=$(( changed + 1 ))
            log_info 'tree: normalised CRLF line endings in %s' "$file"
        else
            log_warn 'tree: could not normalise line endings in %s' "$file"
        fi
        rm -f -- "$tmp" 2>/dev/null || true
    done

    if (( changed == 0 && removed == 0 )); then
        log_info 'tree: nothing to clean -- no CRLF line endings and no archive debris'
    else
        log_info 'tree: %d file(s) normalised, %d item(s) of archive debris removed' \
            "$changed" "$removed"
    fi
    return 0
}

# ===========================================================================
# STEP 8 -- the generated inventory
# ===========================================================================
#
# One host, always the machine this is running on, always a local connection.
# It is GENERATED on every run and gitignored, because this is not a
# deployment topology file and must never become one: user input lives in an
# answer file. The installer this project replaces kept a live tenant's
# credentials in an inventory, which is how they reached a repository.
_tpot_write_inventory() {
    local dir="$REPO_DIR/inventories/local"
    local dest="$dir/hosts.yml"

    _TPOT_MUTATED=1
    mkdir -p -- "$dir" || {
        log_die "$EX_INTERNAL" 'cannot create %s' "$dir"
    }
    {
        printf -- '---\n'
        printf '# GENERATED by install.sh run %s -- every run overwrites this file.\n' "$TPOT_RUN_ID"
        printf '# It is gitignored. It holds no configuration and never a credential:\n'
        printf '# user input reaches Ansible through -e @<merged document>, on tmpfs.\n'
        printf 'all:\n'
        printf '  hosts:\n'
        printf '    tpot:\n'
        printf '      ansible_connection: local\n'
    } > "$dest" || log_die "$EX_INTERNAL" 'cannot write %s' "$dest"
    chmod 0644 -- "$dest" 2>/dev/null || true
    log_info 'inventory: %s -- one host "tpot", ansible_connection: local' "$dest"
    return 0
}

# ===========================================================================
# STEP 9 -- run the play
# ===========================================================================
#
# ############################################################################
# #                                                                          #
# #  THE PLAY IS IN THIS TREE. THE REFUSING ARM STAYS ANYWAY.                #
# #                                                                          #
# #  site.yml, verify.yml and roles/** landed on 2026-09-04, so in any       #
# #  complete copy of this repository tpot_run_playbook selects the          #
# #  first of its two arms:                                                  #
# #                                                                          #
# #    * _tpot_exec_playbook -- the REAL invocation, and the only place      #
# #      ansible-playbook is run. It holds no placeholder and needs no       #
# #      edit to enable: the play file being on disk is what selects it.     #
# #      It has NEVER BEEN EXECUTED, because no run of install.sh has        #
# #      reached step 9 -- so "written in full" is still a statement         #
# #      about the code and not about a passing install.                     #
# #                                                                          #
# #    * _tpot_playbook_absent -- the refusing arm, and it is not dead       #
# #      code left behind by the slice landing. It is what a PARTIAL         #
# #      checkout meets. It logs what is missing, sets the outcome to        #
# #      internal_error and returns EX_INTERNAL (40), so a tree with no      #
# #      play CANNOT report success, cannot reach exit 0, and cannot         #
# #      reach exit 20.                                                      #
# #                                                                          #
# #  IT IS THE LAST GUARD RATHER THAN THE FIRST, AND THAT IS THE POINT.      #
# #  Preflight stage A checks this tree against a manifest of 17             #
# #  required files, and site.yml and verify.yml are two of the              #
# #  seventeen -- so a checkout missing them stops at step 3 with            #
# #  EX_PREFLIGHT (11) and this arm never fires. Two independent             #
# #  statements of one rule is the right number here. Deleting the           #
# #  second because the first happens to fire first leaves the rule          #
# #  standing only for as long as nobody reorders the steps, skips a         #
# #  stage or teaches preflight a new manifest; the thing that must          #
# #  never happen -- a tree with no play reporting success -- is             #
# #  refused by both, from different information.                            #
# #                                                                          #
# #  WHAT A READER OBSERVES TODAY IS NEITHER OF THOSE NUMBERS.               #
# #  Measured here on 2026-09-04, with the manifest complete and the         #
# #  run fully unattended -- the password in the environment, no             #
# #  controlling terminal, stdin from /dev/null -- it exits 11 on the        #
# #  ROOT check, on an unprivileged box where nothing about the play is      #
# #  wrong. The 40 above is what this guard RETURNS; no exit code from       #
# #  step 9 has been observed from this file at all.                         #
# #                                                                          #
# #  There is no flag, no variable and no environment value that selects     #
# #  between the arms: the switch is whether the play file is present on     #
# #  disk. A release that contains site.yml never reaches the refusing       #
# #  arm, and a release that does not contain it can never claim to have     #
# #  installed anything.                                                     #
# #                                                                          #
# ############################################################################

_tpot_playbook_absent() {
    local playbook=$1
    log_error '%s is not present in this checkout, so nothing was installed.' "$playbook"
    log_error 'A release carries the play and its roles beside the entrypoint, so this'
    log_error 'copy is partial rather than damaged: fetch the whole release instead of'
    log_error 'replacing files one at a time. The box has not been changed by this step,'
    log_error 'and no run without a play can report success.'
    TPOT_OUTCOME='internal_error'
    return "$EX_INTERNAL"
}

# _tpot_exec_playbook PATH
#   The real invocation, and the only place ansible-playbook is run.
#
#   -e @PATH, never -e KEY=VALUE: the merged document holds the dashboard
#   password and a command-line VALUE is world-readable in /proc for the
#   lifetime of the process. tests/check-argv-hygiene.sh fails the build on
#   `--extra-vars` followed by anything that is not `@`.
_tpot_exec_playbook() {
    local playbook=$1
    local binary verbosity='' index rc=0

    binary=$(deps_ansible_bin) || log_die "$EX_DEPS" \
        'no ansible-playbook was resolved; this is a bug in the dependency bootstrap.'

    for (( index = 0; index < OPT_VERBOSE && index < 4; index++ )); do
        verbosity+='v'
    done

    local -a command=(
        "$binary" "$playbook"
        -i "$REPO_DIR/inventories/local/hosts.yml"
        -e "@$MERGED_JSON"
    )
    if (( OPT_CHECK )); then
        command+=(--check --diff)
    fi
    if [[ -n $verbosity ]]; then
        command+=("-$verbosity")
    fi

    _TPOT_MUTATED=1
    if (( OPT_CHECK )); then
        log_info 'running %s in check mode -- nothing on this box will be changed' \
            "${playbook##*/}"
    else
        log_info 'running %s' "${playbook##*/}"
    fi

    # ANSIBLE_HOME as a command prefix rather than an export: it keeps
    # ansible's per-user state out of the invoking account's ~/.ansible
    # without putting the name into every other child's environment.
    ANSIBLE_HOME="$(deps_ansible_home)" "${command[@]}" || rc=$?
    return "$rc"
}

# tpot_run_playbook PLAYBOOK
#   The single seam: which arm runs is decided by whether the play file is on
#   disk, and nothing above or below it needs an edit either way. In this tree
#   that selects the real invocation. It is still a property of how this is
#   written rather than a tested one: no run has reached step 9, so neither
#   arm has ever been called.
tpot_run_playbook() {
    local playbook=$1
    local path="$REPO_DIR/$playbook"

    local rc=0
    if [[ -f $path ]]; then
        _tpot_exec_playbook "$path" || rc=$?
        return "$rc"
    fi
    _tpot_playbook_absent "$playbook" || rc=$?
    return "$rc"
}

# ===========================================================================
# STEP 10 -- the exit code, result.json, the reboot, the notice
# ===========================================================================

# _tpot_failure_class
#   Read $RUNDIR/failure-class and print the exit code it names.
#
#   The parsing rule, exactly: take the first whitespace-separated field; if
#   lib/exitcodes.sh recognises it, that is the code. Otherwise -- and if the
#   file is missing or unreadable -- the code is 40. A play that failed
#   without saying how far it got is a defect in the play, and 40 is what
#   says so.
_tpot_failure_class() {
    local file=${FAILURE_CLASS:-} first=''
    local -a lines=()
    if [[ -n $file && -r $file ]]; then
        mapfile -t lines < "$file"
        first=${lines[0]:-}
        first=${first%%[[:space:]]*}
    fi
    if [[ -n $first ]] && ex_is_code "$first"; then
        printf '%s\n' "$first"
        return 0
    fi
    printf '%s\n' "$EX_INTERNAL"
    return 0
}

_tpot_failure_stage() {
    local file=${FAILURE_CLASS:-} line=''
    local -a lines=()
    [[ -n $file && -r $file ]] || return 0
    mapfile -t lines < "$file"
    line=${lines[0]:-}
    [[ $line == *[[:space:]]* ]] || return 0
    line=${line#*[[:space:]]}
    printf '%s\n' "${line%%[[:space:]]*}"
    return 0
}

# _tpot_reboot_cron_schedule
#   Print HH:MM for the daily reboot upstream installed, or fail.
#
#   Upstream's task is named "Setup a randomized daily reboot" and picks the
#   hour from range(0, 5) and the minute from range(0, 60) at install time
#   (installer/install/tpot.yml:1229-1239 at the pinned ref), writing the job
#   into ROOT's crontab -- not /etc/cron.d, which is where somebody looking
#   for it will look first. Every document in this tree used to state 02:42.
#   That was never true of anything; the first real install landed on 01:16.
#
#   Failing is normal and is not an error: on a --check run, on a preflight
#   refusal, and on any run that stopped before upstream did, the job does not
#   exist yet. The caller then leaves the field at its default, which
#   describes the range rather than inventing a time.
_tpot_reboot_cron_schedule() {
    local line minute hour
    command -v crontab >/dev/null 2>&1 || return 1
    line=$(crontab -l -u root 2>/dev/null \
           | grep -F 'T-Pot Daily Reboot' \
           | grep -v '^[[:space:]]*#' \
           | head -n 1) || return 1
    [[ -n $line ]] || return 1
    read -r minute hour _ <<<"$line" || return 1
    [[ $minute =~ ^[0-9]{1,2}$ && $hour =~ ^[0-9]{1,2}$ ]] || return 1
    printf '%02d:%02d -- upstream randomises this per install\n' "$hour" "$minute"
}

# _tpot_fill_notice CODE
#   Point lib/notice.sh at this run's real values. Every port, the dashboard
#   user, the telemetry and forwarding states and both file paths come from
#   the merged document or from this shell -- never from a literal written
#   twice -- so the banner, result.json and the checks cannot disagree about
#   a port number.
_tpot_fill_notice() {
    local code=$1 value
    local -a pairs=(
        # install_type was missing from this list until 2026-09-05, so the
        # banner rendered "for install type '?'" on every run that ever
        # printed it -- which, until the first real install, was none.
        install_type:tpot_install_type
        admin_ssh_port:tpot_admin_ssh_port
        dashboard_port:tpot_dashboard_port
        elasticsearch_port:tpot_elasticsearch_port
        web_user:tpot_web_user
        telemetry:tpot_upstream_telemetry
        firewall:tpot_firewall_mode
    )
    local pair
    for pair in "${pairs[@]}"; do
        value=$(_tpot_cfg "${pair#*:}")
        [[ -n $value ]] && notice_set "${pair%%:*}" "$value"
    done

    if _tpot_cfg_true ioc_forwarding_enabled; then
        notice_set ioc 'on'
    else
        notice_set ioc 'off'
    fi

    value=$(uname -n 2>/dev/null) || value=''
    [[ -n $value ]] && notice_set host "$value"

    # The daily reboot upstream schedules is RANDOMISED per install, so the
    # only way to name it truthfully is to read the job it actually wrote.
    value=$(_tpot_reboot_cron_schedule) || value=''
    [[ -n $value ]] && notice_set reboot_cron "$value"

    [[ -n ${TPOT_LOG:-} ]] && notice_set log "$TPOT_LOG"
    [[ -n ${TPOT_RESULT_JSON:-} ]] && notice_set result "$TPOT_RESULT_JSON"
    notice_set exit_code "$code"
    return 0
}

# _tpot_print_notice CODE
#   The one place lib/notice.sh is printed, called from step 10 and -- for a
#   run that mutated the box and then failed -- from the exit trap.
_tpot_print_notice() {
    local code=${1:-${TPOT_EXIT_CODE:-40}}
    (( _TPOT_NOTICE_PRINTED )) && return 0
    _TPOT_NOTICE_PRINTED=1
    _tpot_fill_notice "$code"
    notice_print
    return 0
}

# _tpot_perform_reboot
#   Reboot, having already written and flushed result.json. In this mode the
#   exit code is meaningless by definition -- the process is killed by its own
#   reboot -- and result.json is the answer. That is the documented contract
#   for --reboot always|if-required, and it is why `never` is the default:
#   Packer, cloud-init and CI all have their own reboot-and-reconnect
#   primitives and hate having the floor pulled out from under them.
_tpot_perform_reboot() {
    log_info 'rebooting now. result.json has been written and flushed; the exit code of'
    log_info 'this process is meaningless from here on. After the reboot, verification'
    log_info 'runs from the systemd unit, which passes the settings this run used:'
    log_info '  install.sh --verify-only --config %s/verify-config.json' "$TPOT_STATE_DIR"
    log_info 'is the same command by hand. --verify-only with no answer file re-derives'
    log_info 'every setting from the shipped defaults, so on a box that changed any of'
    log_info 'them it verifies the wrong thing.'
    sync

    # The run directory is deliberately NOT destroyed here. `systemctl reboot`
    # returns immediately and the machine goes down asynchronously, so this
    # process usually lives long enough for its own exit trap to run -- and
    # that trap needs the run directory to rebuild result.json, then shreds it
    # itself. Nothing is left at risk either way: $RUNDIR is on tmpfs, which
    # preflight proved and which the reboot clears in any case.
    if command -v systemctl >/dev/null 2>&1; then
        systemctl reboot && return 0
    fi
    if command -v shutdown >/dev/null 2>&1; then
        shutdown -r now && return 0
    fi
    log_warn 'no systemctl and no shutdown were found; this box must be rebooted by hand'
    # result.json said the reboot was performed, because it is written before
    # the reboot is attempted -- a successful one leaves no chance to write
    # anything afterwards. It was not performed, so correct the record: the
    # exit trap writes the document again from these same facts.
    res_set reboot.performed false
    res_add_error 'the reboot could not be performed: neither systemctl nor shutdown was found'
    return 1
}

# _tpot_step_10 PLAY_RC
#   Turn the play's coarse status into this project's exit code, record every
#   fact result.json needs, print the notice, and decide about the reboot.
_tpot_step_10() {
    local play_rc=$1
    local code stage='' policy required='' armed='false'

    if (( play_rc == 0 )); then
        code=$EX_OK
    else
        code=$(_tpot_failure_class)
        stage=$(_tpot_failure_stage)
        if [[ -n $stage ]]; then
            log_error 'the play failed in stage "%s"' "$stage"
            res_add_error "the play failed in stage ${stage}"
        else
            log_error 'the play failed and recorded no failure class'
            res_add_error 'the play failed and recorded no failure class'
        fi
    fi

    required=$(_tpot_report_value reboot_required)
    if [[ -n $(_tpot_report_value already_installed) ]]; then
        res_set already_installed "$(_tpot_report_value already_installed)"
    fi
    if [[ -f "${TPOT_STATE_DIR}/verify-pending" ]]; then
        armed='true'
    fi

    policy=$(_tpot_cfg tpot_reboot_policy)
    [[ -n $policy ]] || policy='never'

    # The play succeeded. Whether that is a 0 or a 20 is the whole reason this
    # product has an exit contract: 0 is reserved for a box that has actually
    # been verified, and a T-Pot that has not rebooted cannot be verified.
    if (( code == EX_OK )) && [[ $required == 'true' ]]; then
        case $policy in
            never)
                code=$EX_REBOOT
                res_set reboot.required true
                res_set reboot.performed false
                res_set reboot.post_boot_verify_armed "$armed"
                notice_set reboot_required true
                ;;
            if-required|always)
                res_set reboot.required true
                res_set reboot.performed true
                res_set reboot.post_boot_verify_armed "$armed"
                notice_set reboot_required true
                ;;
        esac
    else
        res_set reboot.required "${required:-false}"
        res_set reboot.performed false
        res_set reboot.post_boot_verify_armed "$armed"
        notice_set reboot_required "${required:-false}"
    fi

    if (( code == EX_OK )) && [[ $policy == 'always' && $required != 'true' ]]; then
        res_set reboot.performed true
    fi

    # The notice's own state: `installed` says the honeypot properties below
    # are now true of this box, and it is claimed only when the play actually
    # completed. --check changes nothing, so it never claims it.
    if (( play_rc == 0 )) && (( ! OPT_CHECK )) && (( ! OPT_PREFLIGHT_ONLY )); then
        notice_set state installed
    fi

    # The mode, so the banner can say the true thing about a --check run that
    # failed inside the playbook. See notice_text's first branch for what it
    # used to say instead.
    if (( OPT_CHECK )); then
        notice_set check yes
    fi

    TPOT_EXIT_CODE=$code
    TPOT_OUTCOME=$(res_outcome_for_code "$code")

    # result.json is written HERE as well as in the exit trap, because the
    # notice quotes it and a reboot may kill this process before the trap gets
    # to run. The trap writes it again with the final state; the document is
    # rebuilt from scratch each time, so writing twice cannot duplicate a
    # field.
    _tpot_fill_notice "$code"
    res_write "$code" || log_warn 'result.json could not be written'
    sync

    _tpot_print_notice "$code"

    if (( play_rc == 0 )) && (( ! OPT_CHECK )); then
        case $policy in
            always)
                _tpot_perform_reboot || true
                ;;
            if-required)
                if [[ $required == 'true' ]]; then
                    _tpot_perform_reboot || true
                fi
                ;;
        esac
    fi

    exit "$code"
}

# ===========================================================================
# main
# ===========================================================================
main() {
    local password_action stage_a_ok=1 stage_b_ok=1 verdict play_rc=0 name

    # -- STEP 1 -----------------------------------------------------------
    # Parsing touches the filesystem never and the environment never. The
    # three print-and-exit modes stop parsing where they are found, so
    # `install.sh --help` prints help even when the rest of the line is
    # wrong -- which is exactly when it is asked for.
    args_parse "$@"

    if (( OPT_HELP )); then
        _TPOT_WANT_RESULT=0
        args_usage
        exit 0
    fi
    if (( OPT_VERSION )); then
        _TPOT_WANT_RESULT=0
        args_version
        exit 0
    fi
    if (( OPT_EXAMPLE_CONFIG )); then
        _TPOT_WANT_RESULT=0
        # The example is a FILE in the tree, not a here-document, so there is
        # exactly one copy of it and it cannot drift from the one that ships.
        if [[ ! -r "$REPO_DIR/examples/tpot.example.yml" ]]; then
            printf 'install.sh: %s is missing from this checkout\n' \
                "$REPO_DIR/examples/tpot.example.yml" >&2
            exit "$EX_INTERNAL"
        fi
        cat -- "$REPO_DIR/examples/tpot.example.yml"
        exit 0
    fi

    # From here on this is a real run, and a real run always leaves a
    # result.json behind -- including one that fails in the next five lines.
    TPOT_RESULT_JSON="$TPOT_STATE_DIR/result.json"
    res_set mode "$(args_mode)"
    res_set non_interactive "$(_tpot_bool "$OPT_NON_INTERACTIVE")"
    res_set json "$(_tpot_bool "$OPT_JSON")"

    if (( ${#_tpot_declined[@]} > 0 )); then
        for name in "${_tpot_declined[@]}"; do
            case $name in
                TPOT_LOG|TPOT_LOG_DIR)
                    printf 'install.sh: %s is not read from the environment; use --log-dir DIR.\n' \
                        "$name" >&2 ;;
                TPOT_STATE_DIR)
                    printf 'install.sh: %s is not read from the environment; use --state-dir DIR.\n' \
                        "$name" >&2 ;;
                TPOT_RUNTIME_DIR)
                    printf 'install.sh: %s is not read from the environment; use --runtime-dir DIR.\n' \
                        "$name" >&2 ;;
                *)
                    printf 'install.sh: %s is an internal name of this installer%s' \
                        "$name" ' and is not read from the environment.' >&2
                    printf '\n' >&2 ;;
            esac
        done
        TPOT_EXIT_CODE=$EX_USAGE
        TPOT_OUTCOME='usage_error'
        exit "$EX_USAGE"
    fi

    # Names only. No value is read, printed or copied anywhere. A misspelt
    # TPOT_WEB_PASSWD is named as a misspelling here, rather than arriving
    # later as "tpot_web_password is required" -- which would send the reader
    # to look at the one thing they did supply.
    args_env_check

    # Decided now, acted on at step 4. A run with no terminal and no password
    # is a usage error BEFORE anything else is checked, because that is what
    # makes the three-way message the first thing a cloud-init log shows.
    password_action=$(args_web_password_action)
    if [[ $password_action == 'missing' ]]; then
        TPOT_EXIT_CODE=$EX_USAGE
        TPOT_OUTCOME='usage_error'
        args_die_missing_web_password
    fi

    # -- STEP 2 -----------------------------------------------------------
    _tpot_open_transcript

    # -- STEP 3 -----------------------------------------------------------
    # Zero dependency, zero mutation. It runs before $RUNDIR exists because
    # proving that /run is usable is one of its own checks.
    log_info 'preflight stage A -- nothing on this box is changed by it'
    pf_stage_a || stage_a_ok=0

    if pf_usage_error; then
        pf_print
        log_error 'an answer file broke the location or permission rule; nothing was changed.'
        TPOT_EXIT_CODE=$EX_USAGE
        TPOT_OUTCOME='usage_error'
        exit "$EX_USAGE"
    fi
    if (( ! stage_a_ok )); then
        pf_print
        verdict=$(pf_verdict)
        log_error 'preflight stage A failed; nothing on this box was changed.'
        TPOT_EXIT_CODE=$verdict
        TPOT_OUTCOME=$(res_outcome_for_code "$verdict")
        exit "$verdict"
    fi

    # -- STEP 3.5 ---------------------------------------------------------
    _tpot_make_rundir
    pf_flush || log_warn 'the preflight report could not be written to %s' "$RUNDIR"

    # -- STEP 4 -----------------------------------------------------------
    _tpot_merge_config "$password_action"
    # -- STEP 4.5 ---------------------------------------------------------
    _tpot_register_secrets

    if _tpot_cfg_true tpot_force_unsupported_os; then res_add_forced tpot_force_unsupported_os; fi
    if _tpot_cfg_true tpot_force_low_resources;  then res_add_forced tpot_force_low_resources;  fi
    if _tpot_cfg_true tpot_force_reinstall;      then res_add_forced tpot_force_reinstall;      fi

    # -- STEP 5 -----------------------------------------------------------
    log_info 'preflight stage B -- still nothing on this box is changed by it'
    pf_stage_b || stage_b_ok=0
    pf_flush || true
    pf_print
    verdict=$(pf_verdict)

    if (( OPT_PREFLIGHT_ONLY )); then
        TPOT_EXIT_CODE=$verdict
        TPOT_OUTCOME=$(res_outcome_for_code "$verdict")
        case $verdict in
            "$EX_OK")           log_info 'preflight passed. Nothing was changed.' ;;
            "$EX_INCONCLUSIVE") log_info 'preflight found no failure, but some checks could not be exercised here.' ;;
            *)                  log_error 'preflight failed. Nothing was changed.' ;;
        esac
        exit "$verdict"
    fi

    if (( OPT_VERIFY_ONLY )); then
        # A box that already has T-Pot on it legitimately fails stage B's port
        # check: administrative sshd has moved to 64295 and TCP/22 is now the
        # honeypot, which is the state --verify-only exists to confirm. So in
        # this mode stage B is MEASUREMENT -- its records are kept, reported
        # and written into result.json -- and it does not gate. Stage A still
        # does: root, the operating system and systemd matter as much here.
        if (( verdict != EX_OK )); then
            log_warn 'preflight stage B did not pass, and in --verify-only it does not gate:'
            log_warn 'an installed T-Pot moves administrative sshd to %s and puts a honeypot' \
                "$(_tpot_cfg tpot_admin_ssh_port)"
            log_warn 'on TCP/22, so the port check is meant to look like this. Continuing.'
            res_add_warning 'preflight stage B did not pass; not gated in --verify-only mode'
        fi
    elif (( verdict != EX_OK )); then
        log_error 'preflight failed. Nothing on this box was changed.'
        TPOT_EXIT_CODE=$verdict
        TPOT_OUTCOME=$(res_outcome_for_code "$verdict")
        exit "$verdict"
    fi

    # -- STEP 6 -----------------------------------------------------------
    # The first mutation of the run. --check changes nothing on the box, so it
    # does not change the tree either.
    if (( OPT_CHECK )); then
        log_info 'tree: --check, so line endings and archive debris were left alone'
    else
        _tpot_tree_hygiene
    fi

    # -- STEP 7 -----------------------------------------------------------
    _TPOT_MUTATED=1
    deps_bootstrap

    # -- STEP 8 -----------------------------------------------------------
    _tpot_write_inventory

    # -- STEP 9 -----------------------------------------------------------
    if (( OPT_VERIFY_ONLY )); then
        tpot_run_playbook verify.yml || play_rc=$?
    else
        tpot_run_playbook site.yml || play_rc=$?
    fi

    # -- STEP 10 ----------------------------------------------------------
    _tpot_step_10 "$play_rc"
}

# The traps are installed BEFORE main, so that a failure inside argument
# parsing still leaves a result.json -- which is the one artefact a caller
# reads when the exit code alone is not enough. The three print-and-exit modes
# clear _TPOT_WANT_RESULT the moment they are recognised, so `install.sh
# --help` writes nothing anywhere.
trap '_tpot_on_exit' EXIT
trap '_tpot_on_signal INT'  INT
trap '_tpot_on_signal TERM' TERM
trap '_tpot_on_signal HUP'  HUP
trap '_tpot_on_err "$LINENO" "$BASH_COMMAND"' ERR

main "$@"
