#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# tests/bats/args.bats -- lib/args.sh, the command-line parser.
#
# WHAT THIS FILE IS FOR
#   The automation contract starts at argv, and lib/args.sh is where that
#   contract is enumerated. The build gates already read this file's TEXT:
#   tests/check-argv-hygiene.sh fails the tree if a flag whose name ends in
#   -password would take a value, and tests/check-exit-table.sh keeps --help's
#   copy of the exit table honest. Neither of them ever calls args_parse.
#
#   This file calls it. Everything below asserts on what the parser RETURNS
#   and PRINTS -- exit status, the OPT_* it leaves behind, the words in the
#   message -- and nothing below asserts on how any of it is written. A test
#   that broke when a case label moved would be deleted by the first person it
#   inconvenienced, and it would deserve to be.
#
# THE ONE THAT MATTERS MOST
#   `--set` must refuse a SECRET key. lib/args.sh does not carry a list of
#   secrets; it DERIVES one at run time by parsing
#   inventories/example/group_vars/all.yml -- markers in the prose, unioned
#   with a name rule -- so the refusal is only as good as that parse. If the
#   derivation ever came back short, a credential would become settable as a
#   command-line VALUE, and on Linux argv is world-readable in /proc for the
#   whole life of the process: thirty to ninety minutes for an install. So the
#   refusal is asserted for EVERY key the schema marks secret, the acceptance
#   is asserted for every key it does not, and the two lists are compared
#   against lib/varschema.json rather than typed out here. A second copy of
#   the variable surface in this file would be a copy that drifts, and a
#   drifted copy is how this test starts passing while the property is gone.
#
# WHAT IT DOES NOT NEED
#   No root, no network, no docker, no systemd. Nothing here installs
#   anything: run_install stops in preflight stage A on the root check on this
#   box, and every other test in this file is a function call. Two tests need
#   a pseudo-terminal and skip loudly without one; three need python3 and skip
#   loudly without it.

load helper

# The exit numbers below are read from the table rather than typed, so that a
# renumbering breaks lib/exitcodes.sh's own gate and not thirty assertions
# here. (Renumbering is forbidden -- see the header of that file -- which is
# exactly why a test should not quietly encode a number it did not check.)
setup_exit_codes() {
    lib_source exitcodes.sh
}

# The value handed to a flag in the tests that check a message never contains
# a real credential, but it is written as a sentinel so that a message which
# echoed it back would be caught by refute_contains rather than by a reader.
SENTINEL='S3NTINEL-not-a-real-password'

# ---------------------------------------------------------------------------
# The three print-and-exit modes.
#
# --help, --version and --example-config stop parsing where they are found and
# exit 0 without opening a transcript, creating a state directory or reaching
# preflight. docs/exit-codes.md states that plainly beside the note that 11 is
# what every run of this project has ever returned.
# ---------------------------------------------------------------------------

@test "--help prints the usage text and exits 0" {
    run_install --help
    assert_rc 0
    assert_contains 'install.sh [OPTION]...' "$output"
    assert_contains 'PASSWORDS' "$output"
    assert_contains 'EXIT CODES' "$output"
}

@test "-h returns 0, and not the 1 that upstream T-Pot's -h returns" {
    # Upstream's install.sh routes -h, an unknown flag and a missing argument
    # to the same print_help, which exits 1 -- so on upstream, asking for help
    # is a failure. This installer is driven by automation that branches on
    # the exit code, and a help request is not a failed run. The number is the
    # point of this test; the text is checked by the test above.
    run_install -h
    assert_rc 0
    assert_contains 'install.sh [OPTION]...' "$output"
}

@test "--help prints the help even when the rest of the command line is wrong" {
    # Which is exactly when it is asked for. --help stops parsing on the spot,
    # so nothing after it is read -- including a --set that would otherwise be
    # refused, whose value must not turn up in the output either.
    run_install --help --nope --set "tpot_web_password=$SENTINEL"
    assert_rc 0
    assert_contains 'install.sh [OPTION]...' "$output"
    refute_contains "$SENTINEL" "$output" 'the help output'
}

@test "--version prints the version in the VERSION file and exits 0" {
    run_install --version
    assert_rc 0
    assert_eq "tpot-automation $(cat "$REPO/VERSION")" "$output" 'the version line'
}

@test "-V is --version" {
    run_install -V
    assert_rc 0
    assert_eq "tpot-automation $(cat "$REPO/VERSION")" "$output" 'the version line'
}

@test "--example-config prints an answer file and exits 0" {
    run_install --example-config
    assert_rc 0
    assert_contains 'tpot_web_password' "$output"
    assert_contains 'tpot_upstream_ref' "$output"
}

@test "the answer file --example-config prints is parseable YAML that sets nothing" {
    # The example is the starting point every user is sent to, and its whole
    # promise is that a copy of it behaves exactly like no answer file at all:
    # every line is commented out. A file that parsed to a mapping would be
    # setting something nobody chose.
    skip_unless "python3 with PyYAML" python3 -c 'import yaml'
    run_install --example-config
    assert_rc 0
    printf '%s\n' "$output" > "$TMP/example.yml"
    run python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print("EMPTY" if d is None else type(d).__name__)' "$TMP/example.yml"
    assert_rc 0
    assert_eq 'EMPTY' "$output" 'the parsed example answer file'
}

@test "a print-and-exit mode writes no result.json and no directory warning" {
    # install.sh sets _TPOT_WANT_RESULT=0 on these three paths. It matters
    # because the exit trap writes result.json for every real run, and a run
    # that only printed help has no outcome to report -- on an unprivileged
    # box the trap would instead print "cannot create /var/lib/tpot-automation"
    # underneath the help text. It also pins the reason _tpot_args_init_opts
    # defines TPOT_LOG_DIR and TPOT_STATE_DIR before parsing: --help returns
    # before the directory resolver runs, and under `set -u` an undefined one
    # would take down the simplest path in the product.
    run_install --help
    assert_rc 0
    refute_contains 'result.json was not written' "$output" 'the help output'
    [[ ! -e "$TMP/state/result.json" ]] || {
        printf 'a --help run left a result.json behind\n' >&2
        return 1
    }
}

# ---------------------------------------------------------------------------
# Usage errors. Every one of them is EX_USAGE and every one of them names the
# thing the caller got wrong -- a parser that says only "usage:" sends the
# reader back to the manual to find out which of nine flags was the problem.
# ---------------------------------------------------------------------------

@test "an unknown flag is a usage error naming the flag" {
    setup_exit_codes
    run_install --definitely-not-a-flag
    assert_rc "$EX_USAGE"
    assert_contains '--definitely-not-a-flag' "$output"
    assert_contains "install.sh --help" "$output"
}

@test "a positional argument is a usage error saying this installer takes options only" {
    setup_exit_codes
    lib_source args.sh
    run args_parse install
    assert_rc "$EX_USAGE"
    assert_contains "unrecognised argument 'install'" "$output"
    assert_contains 'options only' "$output"
}

@test "-- is refused, because there is nothing for it to separate" {
    setup_exit_codes
    lib_source args.sh
    run args_parse --
    assert_rc "$EX_USAGE"
    assert_contains 'no positional arguments' "$output"
}

@test "two run modes cannot be combined, and the message names both" {
    setup_exit_codes
    lib_source args.sh
    run args_parse --check --preflight-only
    assert_rc "$EX_USAGE"
    assert_contains '--preflight-only' "$output"
    assert_contains '--check' "$output"
    assert_contains 'a run has one mode' "$output"
}

@test "a flag that takes a value refuses to swallow the next flag instead" {
    # `--config --json` is a forgotten filename. Accepting "--json" as the
    # path would fail much later, as an unreadable answer file, naming the
    # wrong thing entirely.
    setup_exit_codes
    lib_source args.sh
    run args_parse --config --json
    assert_rc "$EX_USAGE"
    assert_contains '--config' "$output"
    assert_contains "the flag '--json'" "$output"
}

@test "a flag that takes a value, given none at the end of the line, is a usage error" {
    setup_exit_codes
    lib_source args.sh
    run args_parse --web-password-file
    assert_rc "$EX_USAGE"
    assert_contains 'takes a value and none was given' "$output"
    assert_contains '--web-password-file' "$output"
}

# ---------------------------------------------------------------------------
# --set, and the refusal that is the reason this parser is hand-written.
# ---------------------------------------------------------------------------

@test "--set is refused for every key the schema marks secret" {
    # THE SHARP ONE, and the reason it reads lib/varschema.json rather than
    # ARGS_SECRET_KEYS: lib/args.sh does not carry a secret list, it DERIVES
    # one by parsing inventories/example/group_vars/all.yml at run time. A
    # test that looped over the derived list would loop over a SHORTER list
    # once the derivation broke, refuse every key on it, and pass -- while the
    # key it had lost became settable as a command-line VALUE, world-readable
    # in /proc for the ninety minutes an install takes. So the list under test
    # comes from the schema lib/config.py enforces, and the two lists are
    # compared against each other separately below.
    #
    # The refusal must also not echo the value back: a message that printed
    # the password would copy it into every log that catches stderr, which is
    # the same exposure in a different file.
    skip_unless "python3" have python3
    setup_exit_codes
    lib_source args.sh
    local key checked=0
    local -a not_refused=() echoed=()
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        checked=$(( checked + 1 ))
        run args_parse --set "$key=$SENTINEL"
        [[ $status == "$EX_USAGE" ]] || not_refused+=("$key")
        if [[ $output == *"$SENTINEL"* ]]; then echoed+=("$key"); fi
        assert_contains "$key" "$output"
    done < <(python3 "$LIB/config.py" keys --schema "$LIB/varschema.json" \
        | awk -F'\t' '$3=="secret"{print $1}')
    # A loop that read an empty list would refuse nothing and pass, which is
    # the failure mode this whole file exists to avoid.
    assert_ne 0 "$checked" 'the number of secret keys the schema listed'
    assert_eq '' "${not_refused[*]:-}" 'secret keys that --set did NOT refuse'
    assert_eq '' "${echoed[*]:-}" 'secret keys whose value the refusal echoed'
}

@test "the secret refusal points at a channel that is not a command line" {
    setup_exit_codes
    lib_source args.sh
    run args_parse --set "tpot_web_password=$SENTINEL"
    assert_rc "$EX_USAGE"
    assert_contains '/proc' "$output"
    assert_contains '--web-password-file' "$output"
    assert_contains 'TPOT_WEB_PASSWORD' "$output"
    assert_contains '--config' "$output"
}

@test "--set is accepted for every key the schema does not mark secret" {
    # The other half, and the half that stops the refusal being made safe by
    # refusing everything: a parser that rejected a legitimate --set would
    # blame the user for a bug in this installer. It reads the schema for the
    # same reason the test above does -- looping over lib/args.sh's own idea
    # of which keys are public would silently stop testing a key the moment
    # the derivation started calling it secret.
    skip_unless "python3" have python3
    lib_source args.sh
    local key checked=0
    local -a rejected=()
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        checked=$(( checked + 1 ))
        run args_parse --set "$key=x"
        [[ $status == 0 ]] || rejected+=("$key")
    done < <(python3 "$LIB/config.py" keys --schema "$LIB/varschema.json" \
        | awk -F'\t' '$3!="secret"{print $1}')
    assert_ne 0 "$checked" 'the number of public keys the schema listed'
    assert_eq '' "${rejected[*]:-}" 'public keys that --set refused'
}

@test "a public key whose name merely contains 'password' is still settable" {
    # tpot_os_user_password_policy lives in the same commented block as
    # tpot_os_user_password and its name contains the word. It is public: it
    # chooses between a locked account and a password-protected one, and the
    # password itself arrives elsewhere. This is the case the marker parse in
    # args_load_keyspec is careful about -- the file also says "NO SECRET MAY
    # BE PUT HERE" in a paragraph about a key that is entirely public, and a
    # looser rule would refuse a flag the help text documents.
    lib_source args.sh
    run args_parse --set tpot_os_user_password_policy=set
    assert_rc 0
    ! args_is_secret_key tpot_os_user_password_policy
}

@test "--set on an unknown key that is nearly a real one suggests the real one" {
    setup_exit_codes
    lib_source args.sh
    run args_parse --set tpot_web_passwrd=x
    assert_rc "$EX_USAGE"
    assert_contains 'Did you mean tpot_web_password?' "$output"
}

@test "--set on an unknown key with no near miss points at --example-config" {
    # A wrong guess is worse than no guess, so the suggestion is withheld
    # unless the shared prefix is long enough to be a typo.
    setup_exit_codes
    lib_source args.sh
    run args_parse --set tpot_zzz=1
    assert_rc "$EX_USAGE"
    assert_contains 'no such variable' "$output"
    assert_contains '--example-config' "$output"
    refute_contains 'Did you mean' "$output" 'the message'
}

@test "--set demands KEY=VALUE, and a key that is not a variable name" {
    setup_exit_codes
    lib_source args.sh
    run args_parse --set tpot_os_user
    assert_rc "$EX_USAGE"
    assert_contains 'takes KEY=VALUE' "$output"

    # The environment spelling is uppercase; the --set spelling is not.
    run args_parse --set TPOT_OS_USER=x
    assert_rc "$EX_USAGE"
    assert_contains 'is not a variable name' "$output"
}

@test "repeated --set is accepted and recorded in command-line order" {
    # Later wins, and precedence is settled downstream by the merge; what the
    # parser owes is the order. Called directly rather than through `run`,
    # because OPT_OVERRIDES is what is being read and a subshell would take it
    # with it.
    lib_source args.sh
    args_parse --set tpot_os_user=first --set tpot_timezone=Etc/UTC --set tpot_os_user=last </dev/null
    assert_eq 3 "${#OPT_OVERRIDES[@]}" 'the number of overrides'
    assert_eq 'tpot_os_user=first'  "${OPT_OVERRIDES[0]}" 'the first override'
    assert_eq 'tpot_os_user=last'   "${OPT_OVERRIDES[2]}" 'the last override'
}

@test "an = in the value is kept, so a URL or a base64 value survives --set" {
    lib_source args.sh
    args_parse --set 'tpot_upstream_url=https://example.test/i.sh?a=b&c=d' </dev/null
    assert_eq 'tpot_upstream_url=https://example.test/i.sh?a=b&c=d' \
        "${OPT_OVERRIDES[0]}" 'the override'
}

# ---------------------------------------------------------------------------
# Passwords: a PATH, never a value.
#
# The property tests/check-argv-hygiene.sh defends by reading, asserted here
# by running. No dashboard-password flag that takes a value exists at all, by
# design, and the two flags that do exist put a PATH into OPT_SECRET_FILES
# rather than a value into OPT_OVERRIDES.
#
# (That gate reads this file too, and it fired on the first draft of this very
# paragraph -- prose describing the forbidden shape has the shape. The wording
# above avoids it rather than carrying an exemption marker, because an
# exemption is a thing someone has to review for ever and a sentence is not.)
# ---------------------------------------------------------------------------

@test "--web-password-file takes a path, and records a path and not a value" {
    lib_source args.sh
    args_parse --web-password-file /root/.tpot-web-pw </dev/null
    assert_eq 1 "${#OPT_SECRET_FILES[@]}" 'the number of secret files'
    assert_eq 'tpot_web_password=/root/.tpot-web-pw' "${OPT_SECRET_FILES[0]}" 'the secret file entry'
    assert_eq 0 "${#OPT_OVERRIDES[@]}" 'the number of overrides'
}

@test "--os-user-password-file takes a path, in either spelling" {
    lib_source args.sh
    args_parse --os-user-password-file=/root/.tpot-os-pw </dev/null
    assert_eq 'tpot_os_user_password=/root/.tpot-os-pw' "${OPT_SECRET_FILES[0]}" 'the secret file entry'
    assert_eq 0 "${#OPT_OVERRIDES[@]}" 'the number of overrides'
}

@test "there is no --web-password flag that takes a value" {
    # Not "it is refused" -- it does not exist, so it lands on the unknown-flag
    # branch. What matters as much as the refusal is that the message names the
    # FLAG and never the value: argv is world-readable, and an error message
    # that echoed the password would copy it into every log that catches
    # stderr.
    setup_exit_codes
    lib_source args.sh
    run args_parse --web-password "$SENTINEL"
    assert_rc "$EX_USAGE"
    assert_contains "unrecognised option '--web-password'" "$output"
    refute_contains "$SENTINEL" "$output" 'the usage error'
}

@test "--os-user-password is a policy switch that takes no value" {
    # It says "give that account a password rather than locking it"; the value
    # comes from --os-user-password-file. Given a value in the = spelling it is
    # refused, and the refusal does not echo the value.
    setup_exit_codes
    lib_source args.sh
    run args_parse "--os-user-password=$SENTINEL"
    assert_rc "$EX_USAGE"
    assert_contains 'takes no value' "$output"
    refute_contains "$SENTINEL" "$output" 'the usage error'

    args_parse --os-user-password </dev/null
    assert_eq 'tpot_os_user_password_policy=set' "${OPT_OVERRIDES[0]}" 'the override it sets'
}

# ---------------------------------------------------------------------------
# The keyspec itself.
#
# lib/varschema.json is what lib/config.py enforces; the commented example
# inventory is what lib/args.sh parses. They are two files, and this is where
# a disagreement between them would show up as a settable credential or a
# rejected flag.
# ---------------------------------------------------------------------------

@test "args_load_keyspec finds exactly the keys the schema defines" {
    skip_unless "python3" have python3
    lib_source args.sh
    args_load_keyspec
    local from_schema from_args
    from_schema=$(python3 "$LIB/config.py" keys --schema "$LIB/varschema.json" \
        | cut -f1 | LC_ALL=C.UTF-8 sort)
    from_args=$(printf '%s\n' "${ARGS_KNOWN_KEYS[@]}" | LC_ALL=C.UTF-8 sort)
    assert_eq "$from_schema" "$from_args" 'the key list'
}

@test "exactly three keys are secret, and they are the three the schema marks secret" {
    # Three: the dashboard password, the OS account password, and the IoC
    # auth header value. The count is asserted as well as the membership,
    # because a derivation that returned a superset would still contain them.
    skip_unless "python3" have python3
    lib_source args.sh
    args_load_keyspec
    assert_eq 3 "${#ARGS_SECRET_KEYS[@]}" 'the number of secret keys'
    local from_schema from_args
    from_schema=$(python3 "$LIB/config.py" keys --schema "$LIB/varschema.json" \
        | awk -F'\t' '$3=="secret"{print $1}' | LC_ALL=C.UTF-8 sort)
    from_args=$(printf '%s\n' "${ARGS_SECRET_KEYS[@]}" | LC_ALL=C.UTF-8 sort)
    assert_eq "$from_schema" "$from_args" 'the secret key list'
}

@test "args_is_known_key and args_is_secret_key give a verdict and print nothing" {
    lib_source args.sh
    run args_is_known_key tpot_os_user
    assert_rc 0
    assert_eq '' "$output" 'the output of a verdict function'
    run args_is_known_key tpot_not_a_key
    assert_rc 1
    run args_is_secret_key tpot_web_password
    assert_rc 0
    assert_eq '' "$output" 'the output of a verdict function'
    run args_is_secret_key tpot_os_user
    assert_rc 1
}

# ---------------------------------------------------------------------------
# No terminal.
#
# -y is implied whenever stdin is not a terminal. This is the single mechanism
# that makes `install.sh --config ... </dev/null` under setsid structurally
# unable to reach a prompt: there is no mode to forget to pass, because not
# having a terminal IS the mode.
# ---------------------------------------------------------------------------

@test "with no terminal on stdin, --non-interactive is implied" {
    lib_source args.sh
    args_parse </dev/null
    assert_eq 1 "$OPT_NON_INTERACTIVE" 'OPT_NON_INTERACTIVE with no terminal'
}

@test "on a terminal, -y is not implied but can still be asked for" {
    # Both halves of the branch, and the only place either is observable: with
    # no terminal the answer is 1 whatever the flags say, so a -y that had
    # become a no-op would look correct everywhere except here. script(1)
    # gives a real pty; without it this cannot be established on this box and
    # is skipped, not quietly dropped.
    skip_unless "script(1), for a pseudo-terminal" have script
    cat > "$TMP/tty-probe.sh" <<PROBE
. "$LIB/args.sh"
[ -t 0 ] && printf 'TTY=yes\n'
args_parse
printf 'IMPLIED=%s\n' "\$OPT_NON_INTERACTIVE"
args_parse -y
printf 'ASKED_FOR=%s\n' "\$OPT_NON_INTERACTIVE"
PROBE
    run script -qec "bash $TMP/tty-probe.sh" /dev/null
    assert_rc 0
    assert_contains 'TTY=yes' "$output"          # the pty is real, or the rest means nothing
    assert_contains 'IMPLIED=0' "$output"
    assert_contains 'ASKED_FOR=1' "$output"
}

@test "with no terminal and no password, the usage error names all three ways to supply it" {
    # run_install closes stdin under setsid, which is the shape a cloud-init
    # runcmd has. The message is the first thing that log will show, so it has
    # to carry every channel: the file, the environment variable and the
    # answer file. Naming two of the three sends the reader to write the file
    # they were trying to avoid writing.
    setup_exit_codes
    run_install
    assert_rc "$EX_USAGE"
    assert_contains 'tpot_web_password is required' "$output"
    assert_contains '--web-password-file' "$output"
    assert_contains 'TPOT_WEB_PASSWORD' "$output"
    assert_contains '--config' "$output"
    assert_contains '--example-config' "$output"
}

@test "--preflight-only does not demand a password" {
    # A box can be checked without inventing a real-looking credential.
    # HONESTLY: on this box the run then stops in preflight stage A on the
    # root check and returns 11 -- nothing in this project has ever been
    # installed anywhere. What is asserted is that it got PAST the password
    # decision, which is the property of lib/args.sh under test.
    setup_exit_codes
    run_install --preflight-only
    refute_contains 'tpot_web_password is required' "$output" 'the preflight output'
    assert_contains 'PREFLIGHT' "$output"
    assert_rc "$EX_PREFLIGHT"
}

# ---------------------------------------------------------------------------
# Everything else the parser owes its caller.
# ---------------------------------------------------------------------------

@test "repeated -c/--config is accepted, and both spellings are one flag" {
    lib_source args.sh
    args_parse -c /root/base.yml --config /root/site.yml --config=/root/last.yml </dev/null
    assert_eq 3 "${#OPT_CONFIG_FILES[@]}" 'the number of answer files'
    assert_eq '/root/base.yml' "${OPT_CONFIG_FILES[0]}" 'the first answer file'
    assert_eq '/root/last.yml' "${OPT_CONFIG_FILES[2]}" 'the last answer file'
}

@test "args_mode reports the one mode result.json records" {
    lib_source args.sh
    args_parse </dev/null;                 assert_eq install   "$(args_mode)" 'the default mode'
    args_parse --preflight-only </dev/null; assert_eq preflight "$(args_mode)" 'the mode'
    args_parse --verify-only </dev/null;    assert_eq verify    "$(args_mode)" 'the mode'
    args_parse --check </dev/null;          assert_eq check     "$(args_mode)" 'the mode'
}

@test "verbosity accumulates across -v, -vvv and --verbose" {
    lib_source args.sh
    args_parse </dev/null;                     assert_eq 0 "$OPT_VERBOSE" 'the default verbosity'
    args_parse -v </dev/null;                  assert_eq 1 "$OPT_VERBOSE" 'the verbosity'
    args_parse -vvv </dev/null;                assert_eq 3 "$OPT_VERBOSE" 'the verbosity'
    args_parse -vvv --verbose -v </dev/null;   assert_eq 5 "$OPT_VERBOSE" 'the verbosity'
}

@test "parsing the same options twice leaves the same state, not twice the state" {
    # args_parse re-initialises every OPT_* before it reads anything, so a
    # caller's environment cannot pre-set a switch and a second parse cannot
    # accumulate onto the first. An installer that inherited its own switches
    # from the environment could not be reasoned about.
    lib_source args.sh
    args_parse --set tpot_os_user=bob -c /root/a.yml -v </dev/null
    args_parse --set tpot_os_user=bob -c /root/a.yml -v </dev/null
    assert_eq 1 "${#OPT_OVERRIDES[@]}"    'the number of overrides after two parses'
    assert_eq 1 "${#OPT_CONFIG_FILES[@]}" 'the number of answer files after two parses'
    assert_eq 1 "$OPT_VERBOSE"            'the verbosity after two parses'
}

@test "the directory flags are resolved at parse time, last one winning" {
    # log.sh and result.sh read TPOT_LOG_DIR and TPOT_STATE_DIR, and the
    # transcript is opened at step 2 -- long before the merge. So these three
    # are settled here, out of OPT_OVERRIDES, in command-line order.
    lib_source args.sh
    args_parse --log-dir /tmp/one --state-dir /tmp/two --log-dir /tmp/three </dev/null
    assert_eq /tmp/three "$TPOT_LOG_DIR"   'TPOT_LOG_DIR'
    assert_eq /tmp/two   "$TPOT_STATE_DIR" 'TPOT_STATE_DIR'
}

@test "a refused --set stops the parse there rather than carrying on" {
    # _tpot_args_add_set is the single gate a value passes through on its way
    # into OPT_OVERRIDES, and it EXITS rather than returning. The proof that
    # the refusal is a refusal and not a warning is that the parse never
    # reaches the obviously-broken flag after it: a parser that reported
    # `tpot_zzz` here would be one that had already let the credential past.
    setup_exit_codes
    lib_source args.sh
    run args_parse --set "tpot_web_password=$SENTINEL" --set tpot_zzz=1
    assert_rc "$EX_USAGE"
    assert_contains 'secret variable tpot_web_password' "$output"
    refute_contains 'tpot_zzz' "$output" 'the refusal'
    refute_contains "$SENTINEL" "$output" 'the refusal'
}
