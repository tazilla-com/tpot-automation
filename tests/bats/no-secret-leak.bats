#!/usr/bin/env bats
#
# tests/bats/no-secret-leak.bats -- the promise that a credential supplied to
# this installer never appears in anything the run leaves behind.
#
# WHY THIS FILE IS FIRST AMONG THE UNIT TESTS
#   This platform has had two credential incidents. NEITHER was a
#   secrets-management failure -- the values were encrypted at rest both
#   times. Both were a run's own persisted output:
#
#     * a shell builtin printing the environment into a transcript the
#       harness then wrote to disk;
#     * an application logging its own configuration object at startup, under
#       a comment saying that it did not.
#
#   lib/log.sh is the answer to both, and its header says so at length. It
#   redacts every line on the way past IN PURE BASH -- piping to sed would put
#   the pattern into sed's argv, where /proc makes it world-readable -- and
#   then greps the FINISHED transcript and ansible's own log for each
#   registered value, truncating both and failing the run with exit 40 if one
#   is found.
#
#   Every one of those sentences is a claim about behaviour, and the build
#   gates cannot check any of them: tests/check-argv-hygiene.sh reads the tree
#   as text and can only see that the code is written the right way. This file
#   runs it.
#
# WHAT A FAILURE HERE MUST NOT DO
#   Print the credential. helper.bash's `refute_contains` prints a COUNT and
#   says outright that the matching text is withheld, because a test that
#   dumped the transcript in order to report a leak would be the same defect
#   one directory up. Every assertion below goes through it.
#
# THE SENTINEL IS BUILT INSIDE THIS FILE, AND THAT IS LOAD-BEARING
#   `leak_sentinel` writes the value with a printf BUILTIN into a shell
#   variable, and it reaches install.sh through the ENVIRONMENT or through a
#   file -- never as an argument to anything. If a test passed it on a command
#   line, the `ps auxww` test at the foot of this file would find it in the
#   harness's own argv and either fail for the wrong reason or, worse, be
#   "fixed" by loosening the assertion.
#
# WHAT HAS NEVER HAPPENED, AND IS NOT CLAIMED HERE
#   No run of install.sh has ever installed anything, here or anywhere. On
#   this box every acting invocation stops in preflight stage A on the root
#   check and exits 11, having changed nothing -- so the end-to-end tests
#   below exercise steps 1 to 3 of ten, with the sentinel sitting in the
#   run's environment the whole time. That is precisely the shape of incident
#   one, so it is worth testing; it is not a claim about a finished install.
#   The redactor and the tripwire are tested directly against lib/log.sh,
#   where no privilege is needed and the coverage is real.

load helper

# ---------------------------------------------------------------------------
# leak_sentinel
#   The value every end-to-end test below hands the installer. Hostile on
#   purpose: glob metacharacters (* ? [ ] { }), regex metacharacters (. * ? |
#   ^ $ ( ) + -), shell metacharacters (& ; < > ` ~ #), a backslash, a double
#   quote and an embedded space. A redactor that treats its pattern as a glob,
#   or a tripwire that treats it as a regex, gets a different answer for this
#   value than for a plain one -- which is the entire point of choosing it.
#
#   It carries no single quote, so it can be written into a YAML answer file
#   in single-quoted style without any escaping to get wrong.
# ---------------------------------------------------------------------------
leak_sentinel() {
    printf '%s%s' "$(leak_sentinel_prefix)" "$(leak_sentinel_tail)"
}

# leak_sentinel_tail -- the hostile half on its own, so that the argv test can
#   put the same punctuation behind a marker of its own making.
leak_sentinel_tail() {
    printf '%s' '!$*?[]{}|&;<>#%^()`~"\ ,.=+-@'
}

# ---------------------------------------------------------------------------
# leak_sentinel_prefix
#   The metacharacter-free head of the same value, and every end-to-end test
#   below refutes BOTH.
#
#   THE REASON IS A DEFECT THIS FILE'S OWN FIRST DRAFT HAD. A leak does not
#   always reproduce the value byte for byte: `export -p`, `declare -p` and
#   `set` all print a value QUOTED, so the sentinel above comes back with
#   backslashes inserted before its $, its backtick, its double quote and its
#   own backslash. A literal search for the whole value then finds nothing and
#   the test reports clean while the credential is sitting in the transcript.
#   Proved on 2026-09-04, by adding `export -p` to install.sh IN A THROWAWAY
#   COPY of the tree and running this file against it: the full-value
#   assertion stayed green and only this prefix caught the leak.
#
#   The prefix survives any quoting scheme, because there is nothing in it to
#   quote. That is what makes it the assertion that actually holds.
# ---------------------------------------------------------------------------
leak_sentinel_prefix() {
    printf '%s' 'TPOTBATS-Sentinel-9x'
}

# ---------------------------------------------------------------------------
# refute_sentinel_in_tree NEEDLE ROOT
#   NEEDLE appears in no file anywhere under ROOT.
#
#   It fails when ROOT holds no files at all. An assertion that walks an empty
#   directory and reports success is the "matches nothing" failure the gates'
#   own header warns about: it would go green for ever the day the state
#   directory moved.
# ---------------------------------------------------------------------------
refute_sentinel_in_tree() {
    local needle=$1 root=$2 file count=0
    while IFS= read -r file; do
        count=$(( count + 1 ))
        refute_contains "$needle" "$(cat -- "$file" 2>/dev/null)" "$file" || return 1
    done < <(find "$root" -type f 2>/dev/null | LC_ALL=C.UTF-8 sort)
    if (( count == 0 )); then
        printf 'no files were found under %s, so this assertion checked nothing\n' "$root" >&2
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# log_driver SNIPPET
#   Run one snippet of bash with lib/exitcodes.sh and lib/log.sh sourced, in a
#   process of its own.
#
#   A separate process is not tidiness. log_init redirects the CALLING shell's
#   stdout and stderr into its pump; doing that inside a bats test would take
#   bats' own output capture with it, and the failure would look like the
#   suite hanging rather than like a test.
#
#   `set -e` is deliberately NOT set. install.sh runs under it, but these
#   snippets need to observe the return code of a function that is documented
#   to return non-zero -- log_tripwire returning 1 on a hit is the whole
#   subject of half this file.
# ---------------------------------------------------------------------------
log_driver() {
    local snippet=$1
    cat >"$TMP/log-driver.sh" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
. "$LIB/exitcodes.sh"
. "$LIB/log.sh"
. "$1"
DRIVER
    run bash "$TMP/log-driver.sh" "$snippet"
}

# ===========================================================================
# END TO END -- the sentinel through the real install.sh
# ===========================================================================

# The environment channel, which is the shape of incident one: the value is
# in the run's own environment for every line the run prints. Anything that
# printed the environment -- a stray `set -x`, a debugging `env`, a library
# dumping its configuration -- puts it in the transcript, and the transcript
# is persisted.
@test "a sentinel password in the environment appears in nothing the run leaves behind" {
    local sentinel
    sentinel=$(leak_sentinel)
    export TPOT_WEB_PASSWORD=$sentinel

    run_install

    # 11: not root. Recorded so that a future box where this suite CAN reach
    # further does not silently start testing something else.
    assert_rc 11

    local prefix
    prefix=$(leak_sentinel_prefix)

    refute_contains "$sentinel" "$output" 'the run output'
    refute_contains "$prefix" "$output" 'the run output'
    refute_sentinel_in_tree "$sentinel" "$TMP/log"
    refute_sentinel_in_tree "$prefix" "$TMP/log"
    refute_sentinel_in_tree "$sentinel" "$TMP/state"
    refute_sentinel_in_tree "$prefix" "$TMP/state"

    # Named individually as well, because these three are the files a support
    # request attaches and the ones the tripwire exists to protect.
    [[ -f $TMP/state/result.json ]]
    refute_contains "$prefix" "$(cat "$TMP/state/result.json")" 'result.json'
    local f
    for f in "$TMP"/log/install-*.log "$TMP"/log/ansible-*.log; do
        [[ -f $f ]] || continue
        refute_contains "$prefix" "$(cat "$f")" "$f"
    done
}

# The answer-file channel. Preflight stage A greps the file for the three
# secret-typed key names to decide whether the root-owned-0600 rule applies to
# it, so the run reads a file with the sentinel inside and then reports on it.
# What it must report is the PATH. The installer this project replaces kept a
# live tenant's credentials in an inventory file, which is how they reached a
# repository, so a message that quoted the offending line would be a straight
# repeat of that.
@test "a sentinel password inside an answer file is never echoed by the run that reads it" {
    local sentinel answers
    sentinel=$(leak_sentinel)
    answers="$TMP/answers.yml"

    # printf is a builtin: the value goes from shell state into a file without
    # becoming any process's argument.
    {
        printf -- '---\n'
        printf "tpot_web_password: '%s'\n" "$sentinel"
    } >"$answers"
    chmod 0600 -- "$answers"

    run_install --config "$answers"

    # 10, not 11: an answer file that is not root-owned 0600 is the CALLER's
    # mistake, and pf_usage_error is checked before the stage A verdict.
    assert_rc 10
    assert_contains "$answers" "$output" 'the run output'
    assert_contains 'must be root-owned' "$output" 'the run output'

    local prefix
    prefix=$(leak_sentinel_prefix)
    refute_contains "$sentinel" "$output" 'the run output'
    refute_contains "$prefix" "$output" 'the run output'
    refute_sentinel_in_tree "$prefix" "$TMP/log"
    refute_sentinel_in_tree "$prefix" "$TMP/state"
}

# Incident one, stated as an assertion. `export`, `env`, `printenv` and a bare
# `set` all print every exported name AND value; `set -x` prints expanded
# arguments. The canary below is a name nothing in this tree knows about, so
# the only way it can appear in the output is that something printed the
# environment wholesale.
@test "a run prints nothing that looks like the environment" {
    local sentinel canary
    sentinel=$(leak_sentinel)
    canary='canary-2f9d41-nothing-in-this-tree-reads-this'
    export TPOT_WEB_PASSWORD=$sentinel
    # Deliberately NOT a TPOT_/IOC_ name: those are a usage error by design,
    # and the point here is a name the installer has no opinion about at all.
    export BATS_LEAK_CANARY_NAME=$canary

    run_install

    refute_contains "$canary" "$output" 'the run output'
    refute_contains "$(leak_sentinel_prefix)" "$output" 'the run output'
    refute_contains 'BATS_LEAK_CANARY_NAME' "$output" 'the run output'
    # `declare -x NAME="value"` is what `export` and `set` print in bash.
    refute_contains 'declare -x' "$output" 'the run output'
    refute_sentinel_in_tree "$canary" "$TMP/log"
    refute_sentinel_in_tree "$canary" "$TMP/state"
}

# ===========================================================================
# THE REDACTOR -- prevention, on the way past
# ===========================================================================

@test "the redactor replaces a registered value in the transcript and on the human stream" {
    local sentinel
    sentinel=$(leak_sentinel)
    printf '%s' "$sentinel" >"$TMP/secret"

    cat >"$TMP/snippet.sh" <<'SNIP'
secret=$(cat "$TMP/secret")
TPOT_LOG_DIR="$TMP/log"
TPOT_RUN_ID='bats'
log_init || { printf 'log_init failed\n' >&2; exit 9; }
log_add_secret "$secret"
log_info  'the password is %s and nothing else' "$secret"
log_warn  'still %s here' "$secret"
log_error 'and %s there' "$secret"
# Not through a log_* function at all: anything the run writes to stdout or
# stderr goes through the same pump, which is what makes a library that logs
# its own configuration object harmless.
printf 'a bare printf carrying %s\n' "$secret"
printf 'a bare printf on stderr carrying %s\n' "$secret" >&2
# fd 3, the --json path, which never touches the pump and is redacted by
# log_redact instead.
log_emit_stdout "the result document would carry $secret"
log_stop
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0

    refute_contains "$sentinel" "$output" 'the human stream'
    assert_contains '[REDACTED]' "$output" 'the human stream'

    local transcript="$TMP/log/install-bats.log"
    [[ -f $transcript ]]
    local text
    text=$(cat "$transcript")
    refute_contains "$sentinel" "$text" 'the transcript'
    assert_contains 'the password is [REDACTED] and nothing else' "$text" 'the transcript'
    assert_contains 'a bare printf carrying [REDACTED]' "$text" 'the transcript'
}

# THE QUOTES IN ${line//"$secret"/...} ARE LOAD-BEARING, and lib/log.sh says so
# in a paragraph of its own. Unquoted, bash reads the pattern as a GLOB: the
# registered value `[abc]` would then match any single a, b or c anywhere in
# the line and leave the literal `[abc]` alone -- redacting the wrong thing
# and not the right one, silently, in both directions at once.
@test "a value made of glob metacharacters is redacted literally and destroys nothing else" {
    cat >"$TMP/snippet.sh" <<'SNIP'
TPOT_LOG_DIR="$TMP/log"
TPOT_RUN_ID='bats'
log_init || exit 9
log_add_secret '[abc]'
log_info 'a big cabbage and the literal [abc] in one line'
log_stop
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0

    local text
    text=$(cat "$TMP/log/install-bats.log")
    assert_contains 'a big cabbage and the literal [REDACTED] in one line' "$text" 'the transcript'
    # Said twice on purpose: the words either side of the value must survive
    # untouched, and under glob semantics they do not.
    assert_contains 'cabbage' "$text" 'the transcript'
    refute_contains '[abc]' "$text" 'the transcript'
}

# A password may contain a newline, and the channel to the pump is
# line-oriented. Without _tpot_log_fragments a multi-line value passes the
# redactor untouched, one visible line at a time -- the leak arrives split in
# half, which is no better.
@test "a value containing a newline is redacted one line at a time" {
    cat >"$TMP/snippet.sh" <<'SNIP'
TPOT_LOG_DIR="$TMP/log"
TPOT_RUN_ID='bats'
log_init || exit 9
log_add_secret 'firsthalf-9x2q
secondhalf-7k4m'
log_info 'one line holding firsthalf-9x2q on its own'
log_info 'another holding secondhalf-7k4m on its own'
log_stop
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0

    local text
    text=$(cat "$TMP/log/install-bats.log")
    refute_contains 'firsthalf-9x2q' "$text" 'the transcript'
    refute_contains 'secondhalf-7k4m' "$text" 'the transcript'
    assert_contains 'one line holding [REDACTED] on its own' "$text" 'the transcript'
}

# The floor is deliberate and it is documented: a three-character value occurs
# by coincidence in ordinary transcript text -- "tmp", "log", a version
# number -- and redacting it would destroy the transcript while protecting
# nothing. Preflight's own secret_length check is where a too-short password
# is reported to the user. This test exists so that nobody "fixes" the floor
# to zero without meeting the reason.
@test "a value shorter than the redactor's floor is not registered at all" {
    cat >"$TMP/snippet.sh" <<'SNIP'
TPOT_LOG_DIR="$TMP/log"
TPOT_RUN_ID='bats'
log_init || exit 9
log_add_secret 'abc'
log_info 'the string abc survives in a transcript'
log_stop
printf 'COUNT=%s\n' "$(log_secret_count)"
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0
    assert_contains 'COUNT=0' "$output" 'the driver output'
    assert_contains 'the string abc survives in a transcript' \
        "$(cat "$TMP/log/install-bats.log")" 'the transcript'
}

@test "the registered secret count is a count and never a value" {
    local sentinel
    sentinel=$(leak_sentinel)
    printf '%s' "$sentinel" >"$TMP/secret"

    cat >"$TMP/snippet.sh" <<'SNIP'
secret=$(cat "$TMP/secret")
log_add_secret "$secret"
log_add_secret "$secret"          # idempotent: still one
log_add_secret 'another-value-entirely'
printf 'COUNT=%s\n' "$(log_secret_count)"
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0
    assert_contains 'COUNT=2' "$output" 'the driver output'
    refute_contains "$sentinel" "$output" 'the driver output'
    refute_contains 'another-value-entirely' "$output" 'the driver output'
}

# ===========================================================================
# THE TRIPWIRE -- the check on the FINISHED files
# ===========================================================================
#
# A tripwire nobody has seen fire is a tripwire nobody knows works. These
# tests fire it.

# ansible-core writes its own log directly to ANSIBLE_LOG_PATH and never
# passes through our pump, so `no_log: true` on the tasks that touch a
# credential is the only thing keeping that file clean. That is the exact
# reason the tripwire exists rather than trusting the redactor, so it is the
# file this test plants the value in.
@test "the tripwire fires on ansible's own log, truncates both files and reports credential_leaked_to_log" {
    local sentinel
    sentinel=$(leak_sentinel)
    printf '%s' "$sentinel" >"$TMP/secret"

    cat >"$TMP/snippet.sh" <<'SNIP'
secret=$(cat "$TMP/secret")
TPOT_LOG="$TMP/install.log"
TPOT_ANSIBLE_LOG="$TMP/ansible.log"
printf 'a line of ordinary transcript\n' >"$TPOT_LOG"
printf 'TASK [tpot_install : drive upstream] ok\n' >"$TPOT_ANSIBLE_LOG"
printf 'the value was %s\n' "$secret" >>"$TPOT_ANSIBLE_LOG"
log_add_secret "$secret"

rc=0; log_tripwire || rc=$?
printf 'TRIPWIRE_RC=%s\n' "$rc"
src=0; log_tripwire_scrub || src=$?
printf 'SCRUB_RC=%s\n' "$src"
printf 'OUTCOME=%s\n' "${TPOT_OUTCOME:-<unset>}"
printf 'EXIT_CODE=%s\n' "${TPOT_EXIT_CODE:-<unset>}"
# A verdict rather than a byte count: the count would pin the exact wording
# of the fixture lines above and break the day somebody rewords them, which
# is the kind of test that gets deleted rather than fixed.
printf 'TRANSCRIPT_TRUNCATED=%s\n' "$([[ -s $TPOT_LOG ]] && printf 'no' || printf 'yes')"
printf 'ANSIBLE_TRUNCATED=%s\n' "$([[ -s $TPOT_ANSIBLE_LOG ]] && printf 'no' || printf 'yes')"
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0

    assert_contains 'TRIPWIRE_RC=1' "$output" 'the driver output'
    assert_contains 'SCRUB_RC=1' "$output" 'the driver output'
    assert_contains 'OUTCOME=credential_leaked_to_log' "$output" 'the driver output'
    # 40 = EX_INTERNAL. A leaked credential is never a successful install.
    assert_contains 'EXIT_CODE=40' "$output" 'the driver output'
    # Truncation is destructive and it is meant to be: a file holding a live
    # credential is a liability that outlives the run.
    assert_contains 'TRANSCRIPT_TRUNCATED=yes' "$output" 'the driver output'
    assert_contains 'ANSIBLE_TRUNCATED=yes' "$output" 'the driver output'
    refute_contains "$sentinel" "$output" 'the driver output'
}

# The message is what somebody pastes into a bug report. It must state the
# fact and nothing else -- not the line, not the key, not even the count.
@test "the tripwire's own message repeats nothing about the match" {
    local sentinel
    sentinel=$(leak_sentinel)
    printf '%s' "$sentinel" >"$TMP/secret"

    cat >"$TMP/snippet.sh" <<'SNIP'
secret=$(cat "$TMP/secret")
TPOT_LOG="$TMP/install.log"
TPOT_ANSIBLE_LOG="$TMP/ansible.log"
printf 'leaked here: %s\n' "$secret" >"$TPOT_LOG"
: >"$TPOT_ANSIBLE_LOG"
log_add_secret "$secret"
log_tripwire_scrub || true
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0
    refute_contains "$sentinel" "$output" 'the tripwire message'
    assert_contains 'was found in its own log output' "$output" 'the tripwire message'
    assert_contains 'Both log files have been truncated' "$output" 'the tripwire message'
    assert_contains 'rotate it' "$output" 'the tripwire message'
}

@test "log_tripwire_enforce exits 40 when a value reached the transcript" {
    local sentinel
    sentinel=$(leak_sentinel)
    printf '%s' "$sentinel" >"$TMP/secret"

    cat >"$TMP/snippet.sh" <<'SNIP'
secret=$(cat "$TMP/secret")
TPOT_LOG="$TMP/install.log"
TPOT_ANSIBLE_LOG="$TMP/ansible.log"
printf 'leaked here: %s\n' "$secret" >"$TPOT_LOG"
: >"$TPOT_ANSIBLE_LOG"
log_add_secret "$secret"
log_tripwire_enforce
printf 'REACHED_THE_LINE_AFTER_ENFORCE\n'
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 40
    refute_contains 'REACHED_THE_LINE_AFTER_ENFORCE' "$output" 'the driver output'
    refute_contains "$sentinel" "$output" 'the driver output'
}

# THE DEFECT THIS PINS, named because it would otherwise look redundant:
# `grep -f` with no pattern lines, or with one EMPTY pattern line, matches
# EVERY line of the file. A tripwire written without the guard therefore fires
# on every run that supplied no secret at all, and every such run exits 40 --
# the installer would be unusable and the message would blame a credential
# leak. lib/log.sh calls this "the single most likely way to get this file
# wrong" and guards it explicitly; this is the test that keeps the guard.
@test "a run that registered no secret does not fire the tripwire" {
    cat >"$TMP/snippet.sh" <<'SNIP'
TPOT_LOG="$TMP/install.log"
TPOT_ANSIBLE_LOG="$TMP/ansible.log"
printf 'an entirely ordinary transcript\nwith several lines\nand nothing secret\n' >"$TPOT_LOG"
printf 'TASK [something] ok\n' >"$TPOT_ANSIBLE_LOG"
rc=0; log_tripwire || rc=$?
printf 'TRIPWIRE_RC=%s\n' "$rc"
src=0; log_tripwire_scrub || src=$?
printf 'SCRUB_RC=%s\n' "$src"
printf 'OUTCOME=%s\n' "${TPOT_OUTCOME:-<unset>}"
printf 'TRANSCRIPT_TRUNCATED=%s\n' "$([[ -s $TPOT_LOG ]] && printf 'no' || printf 'yes')"
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0
    assert_contains 'TRIPWIRE_RC=0' "$output" 'the driver output'
    assert_contains 'SCRUB_RC=0' "$output" 'the driver output'
    assert_contains 'OUTCOME=<unset>' "$output" 'the driver output'
    # The transcript is intact: nothing was truncated.
    assert_contains 'TRANSCRIPT_TRUNCATED=no' "$output" 'the driver output'
}

# The two floors are different on purpose and the asymmetry is the right way
# round: over-redacting is free, over-failing costs the whole run. Between 4
# and 8 characters a value is scrubbed from the stream but a sighting of it is
# not treated as proof of a leak.
@test "a value between the redactor's floor and the tripwire's does not fail the run" {
    cat >"$TMP/snippet.sh" <<'SNIP'
TPOT_LOG="$TMP/install.log"
TPOT_ANSIBLE_LOG="$TMP/ansible.log"
printf 'the string abcde appears here\n' >"$TPOT_LOG"
: >"$TPOT_ANSIBLE_LOG"
log_add_secret 'abcde'
printf 'COUNT=%s\n' "$(log_secret_count)"
rc=0; log_tripwire || rc=$?
printf 'TRIPWIRE_RC=%s\n' "$rc"
printf 'REDACTED=%s\n' "$(log_redact 'the string abcde appears here')"
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0
    assert_contains 'COUNT=1' "$output" 'the driver output'
    # registered, and therefore redacted from the stream ...
    assert_contains 'REDACTED=the string [REDACTED] appears here' "$output" 'the driver output'
    # ... but too short to be proof of a leak, so the run is not failed.
    assert_contains 'TRIPWIRE_RC=0' "$output" 'the driver output'
}

# `grep -F` and nothing else. Without it a password made of regex
# metacharacters fires the tripwire on text that merely MATCHES it as a
# pattern -- here, an ordinary word that the value happens to describe. The
# cost of that mistake is a run that exits 40 telling the operator to rotate a
# credential that never leaked, and a truncated transcript proving nothing.
@test "the tripwire matches literally, so a password of regex metacharacters cannot fire on text that merely matches it" {
    cat >"$TMP/snippet.sh" <<'SNIP'
TPOT_LOG="$TMP/install.log"
TPOT_ANSIBLE_LOG="$TMP/ansible.log"
# As a regex, p.*ssw0rd!! matches the word below. As a literal it does not.
printf 'the account uses passw0rd!! today\n' >"$TPOT_LOG"
: >"$TPOT_ANSIBLE_LOG"
log_add_secret 'p.*ssw0rd!!'
rc=0; log_tripwire || rc=$?
printf 'TRIPWIRE_RC=%s\n' "$rc"

# And the other half of the same property: the literal value DOES fire.
printf 'and here it is: p.*ssw0rd!!\n' >>"$TPOT_LOG"
rc2=0; log_tripwire || rc2=$?
printf 'LITERAL_RC=%s\n' "$rc2"
SNIP

    log_driver "$TMP/snippet.sh"
    assert_rc 0
    assert_contains 'TRIPWIRE_RC=0' "$output" 'the driver output'
    assert_contains 'LITERAL_RC=1' "$output" 'the driver output'
}

# ===========================================================================
# ARGV -- the leak surface no transcript would ever show
# ===========================================================================

# /proc/<pid>/cmdline is world-readable for the lifetime of a process, so a
# credential passed as a command-line VALUE is readable by any local user
# while it runs -- worse than the transcript, which is at least 0600. That is
# why the merged document reaches ansible-playbook as `-e @PATH`, why the
# redactor is pure bash rather than a pipe into sed, and why log_add_secret
# takes its value as a function argument.
#
# tests/check-argv-hygiene.sh reads the tree for that property. This watches
# the running system instead.
#
# HOW IT AVOIDS BEING A FLAKY TEST, which was the whole difficulty: a run
# lasts about a fifth of a second here, so a single snapshot would usually
# miss it and a passing test would mean nothing. So the sampler runs flat out
# in the background across several runs, and the test then requires PROOF that
# it saw something before it is willing to report a clean result:
#
#   * install.sh's own command line must appear in the snapshots -- otherwise
#     the sampler never overlapped the run at all;
#   * a decoy process, started beside each run and living about as long as
#     one, must appear too -- otherwise the sampler is not catching
#     short-lived processes and a child of install.sh would slip past it.
#
# If either proof is missing the test SKIPS with that reason rather than
# passing. A vacuous pass here would retire the assertion permanently.
@test "no process command line carries the sentinel while the installer runs" {
    skip_unless 'the ps command' have ps

    # A MARKER UNIQUE TO THIS RUN, and this is not decoration. The other tests
    # in this file search FILES, where nothing but the run can have written.
    # This one searches every command line on the box, so a shared literal
    # would make the test fail whenever anything unrelated happened to carry
    # it -- an editor with this file open, someone grepping the tree, a
    # sibling agent. Observed exactly that on 2026-09-04, from a shell whose
    # own command line held the string. A per-run marker cannot collide, and
    # it reaches the sampler in a FILE rather than as an argument, because an
    # argument would put the marker into a process that is alive while the
    # snapshots are being taken.
    local marker value
    marker="TPOTBATS-PS-$$-${RANDOM}${RANDOM}"
    value="${marker}$(leak_sentinel_tail)"
    printf '%s' "$value"  >"$TMP/secret"
    printf '%s' "$marker" >"$TMP/ps-marker"

    # The decoy is named by its PATH, so its marker is in argv for as long as
    # it lives. A `bash -c '<one command>' MARKER` decoy does NOT work: bash
    # optimises a single simple command into a direct exec, and the marker is
    # gone from argv before the first snapshot is taken.
    mkdir -p "$TMP/decoy"
    printf '#!/usr/bin/env bash\nsleep 0.30\n' >"$TMP/decoy/tpotbats-argv-decoy.sh"

    cat >"$TMP/ps-sampler.sh" <<'SAMPLER'
#!/usr/bin/env bash
# WORKDIR REPO RUNS SECRET_FILE MARKER_FILE DECOY
set -uo pipefail
work=$1; repo=$2; runs=$3; secret_file=$4; marker_file=$5; decoy=$6

# The value reaches install.sh through the environment and through nothing
# else. Putting it on this script's own command line would plant it in the
# very snapshots the test then searches.
TPOT_WEB_PASSWORD=$(cat "$secret_file"); export TPOT_WEB_PASSWORD

snapshots="$work/ps-snapshots"; : >"$snapshots"
mkdir -p "$work/state" "$work/log"

: >"$work/sampling"
( while [[ -e "$work/sampling" ]]; do ps auxww >>"$snapshots" 2>/dev/null; done ) &
sampler=$!

for (( n = 0; n < runs; n++ )); do
    bash "$decoy" & decoy_pid=$!
    setsid --wait bash "$repo/install.sh"         --state-dir "$work/state" --log-dir "$work/log" --preflight-only         </dev/null >>"$work/out" 2>>"$work/err" || true
    wait "$decoy_pid" 2>/dev/null || true
done

rm -f -- "$work/sampling"
wait "$sampler" 2>/dev/null || true

# Counted against PATTERN FILES, so neither the value nor the marker becomes
# an argument to grep either -- and this runs after sampling has stopped, so
# these greps cannot see themselves.
printf 'SAW_INSTALL=%s
' "$(grep -F -c -- 'install.sh' "$snapshots" || true)"
printf 'SAW_DECOY=%s
'   "$(grep -F -c -- 'tpotbats-argv-decoy' "$snapshots" || true)"
printf 'SENTINEL_HITS=%s
' "$(grep -F -c -f "$secret_file" -- "$snapshots" || true)"
# The marker on its own as well: a value that reached argv through a quoting
# layer -- `export -p` escapes $ and backslash -- would not match the whole
# value literally, and the head of it has nothing in it to quote.
printf 'MARKER_HITS=%s
' "$(grep -F -c -f "$marker_file" -- "$snapshots" || true)"
SAMPLER

    mkdir -p "$TMP/ps"
    run bash "$TMP/ps-sampler.sh" "$TMP/ps" "$REPO" 4 "$TMP/secret" "$TMP/ps-marker" \
        "$TMP/decoy/tpotbats-argv-decoy.sh"
    assert_rc 0

    local saw_install saw_decoy
    saw_install=$(sed -n 's/^SAW_INSTALL=//p' <<<"$output" | head -n 1)
    saw_decoy=$(sed -n 's/^SAW_DECOY=//p' <<<"$output" | head -n 1)

    if [[ ${saw_install:-0} == 0 ]]; then
        skip "the sampler never caught install.sh running, so it proved nothing about argv"
    fi
    if [[ ${saw_decoy:-0} == 0 ]]; then
        skip "the sampler never caught the decoy, so it cannot see a short-lived process here"
    fi

    assert_eq '0' "$(sed -n 's/^SENTINEL_HITS=//p' <<<"$output" | head -n 1)" \
        'command lines carrying the password'
    assert_eq '0' "$(sed -n 's/^MARKER_HITS=//p' <<<"$output" | head -n 1)" \
        'command lines carrying the marker'

    # And the runs the sampler made still leaked nothing into their artefacts.
    refute_sentinel_in_tree "$marker" "$TMP/ps/log"
    refute_sentinel_in_tree "$marker" "$TMP/ps/state"
}
