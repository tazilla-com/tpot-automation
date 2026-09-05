#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# tests/bats/result-json.bats -- lib/result.sh, the machine-readable outcome.
#
# WHY THIS FILE IS LONGER THAN THE FUNCTION IT TESTS
#   result.json is the only thing a caller reads when the exit code alone is
#   not enough, and SECURITY.md goes further: it invites a vulnerability
#   reporter to ATTACH the file to their report, on the stated grounds that it
#   "cannot contain a credential". Both halves of that sentence are properties
#   of this one serialiser -- that the document says something true, and that
#   it says nothing it must not. Neither can be checked by reading the tree,
#   because both are about what comes out the other end.
#
#   The build gates already read lib/result.sh as text. Nothing in here
#   asserts on how the file is written; every test feeds it inputs and reads
#   the document back.
#
# THE TWO SEAMS, AND WHY BOTH ARE USED
#   res_write is the real entry point and it is driven directly for the facts
#   it owns: the spine of the document, and the exit_code/exit_name agreement
#   with lib/exitcodes.sh.
#
#   The serialiser is a here-document inside res_write that takes EIGHT input
#   paths, and res_write only ever hands it six fixed filenames inside
#   $RUNDIR. The interesting inputs -- a report from the play, a config
#   document with a supplied secret in it, and above all a path named
#   merged.json -- cannot be reached through that seam at all. So the program
#   is lifted out into the test's own scratch directory and run against
#   fixtures. It is the same bytes: `res_serialiser` fails loudly if the
#   extraction comes back too short to be the program.
#
# WHAT IT DOES NOT AND CANNOT COVER
#   Nothing in this project has ever been installed anywhere: no root, no
#   docker, no T-Pot, no run has ever reached the play. So every `driver` and
#   `upstream` fixture below is a transcription of what roles/report is
#   documented to send, not a capture of one. The masking pass in particular
#   has never fired in anger -- lib/result.sh says so itself, and says why it
#   was written before its feeder existed. These tests are the only thing that
#   has ever exercised it.
#
#   The last-line-of-defence loop at the foot of the serialiser -- the one
#   that strips a `value` from an entry already marked secret -- is deliberately
#   NOT tested here. It cannot be reached from the input surface: the only
#   place a `secret` entry is constructed never puts a value in one. It is a
#   guard against a future edit, and a test would have to edit the code to
#   reach it, which would be a test of the edit.
#
#   It was nonetheless exercised while this file was written, by making that
#   constructor put a value in the entry: the guard stripped it, said so on
#   stderr, and the two tests below that read the config object stayed green
#   because the document was still clean. So the guard works, and it is the
#   reason those two tests do NOT go red on that particular defect -- do not
#   read their silence as the guard being dead code.

bats_require_minimum_version 1.5.0

load helper

# The one value that must never appear in the artefact. Distinctive so that a
# grep over a failing run's output finds it and nothing else.
SECRET='Sw0rdf1sh-DO-NOT-LEAK'

# ---------------------------------------------------------------------------
# res_serialiser -- lift the embedded Python out of lib/result.sh and print
#   the path to the copy. See the header: this is the only way to reach the
#   eight input paths individually.
#
#   The length check is not decoration. An awk range that stopped matching --
#   because the here-document marker was renamed, or the program moved to a
#   file of its own -- would silently produce an EMPTY program, and every test
#   below would then be asserting against `python3` running nothing. A test
#   suite that passes on an empty program is the failure this whole directory
#   exists to prevent.
# ---------------------------------------------------------------------------
res_serialiser() {
    local out="$TMP/serialiser.py" n
    if [[ ! -s $out ]]; then
        awk '/<<.TPOT_RESULT_PY./ { inside = 1; next }
             /^TPOT_RESULT_PY$/   { inside = 0 }
             inside' "$LIB/result.sh" >"$out"
    fi
    n=$(wc -l <"$out")
    if (( n < 200 )); then
        printf 'could not lift the serialiser out of %s: got %s lines.\n' \
            "$LIB/result.sh" "$n" >&2
        printf 'the here-document marker has moved; fix this helper.\n' >&2
        return 1
    fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# serialise -- run the lifted serialiser over this test's fixtures.
#
#   Every input defaults to the empty string, which the serialiser reads as
#   "this fact is not known". A test sets only the ones it is about, so the
#   fixture in a failing test is the whole of what produced the document.
#
#   --separate-stderr because two properties below are specifically about what
#   is said on stderr while the document is still written successfully.
# ---------------------------------------------------------------------------
res_reset() {
    KV=''; PUBLIC=''; SOURCES=''; PREFLIGHT=''
    HOST=''; DEPS=''; REPORT=''
    OUT="$TMP/result.json"
    rm -f -- "$OUT"
}

serialise() {
    local py
    py=$(res_serialiser) || return 1
    run --separate-stderr python3 "$py" \
        "$KV" "$PUBLIC" "$SOURCES" "$PREFLIGHT" "$HOST" "$DEPS" "$REPORT" "$OUT"
}

# fixture NAME CONTENT -- write a file into the scratch dir, print its path.
fixture() {
    local path="$TMP/$1"
    printf '%s' "$2" >"$path"
    printf '%s\n' "$path"
}

# A kv file with the spine res_write always writes. Tabs are the record
# separator, so they are written as literal $'\t' rather than typed.
kv_default() {
    local f="$TMP/kv.tsv"
    {
        printf 'schema\t%s\n'       'tpot-automation/result@1'
        printf 'run_id\t%s\n'       '20260904T100000Z'
        printf 'tool_version\t%s\n' '0.1.0'
        printf 'started_at\t%s\n'   '2026-09-04T10:00:00Z'
        printf 'finished_at\t%s\n'  '2026-09-04T10:05:00Z'
        printf 'exit_code\t%s\n'    '0'
        printf 'outcome\t%s\n'      'ok'
        printf 'exit_name\t%s\n'    'EX_OK'
    } >"$f"
    printf '%s\n' "$f"
}

# report_with FLAGS_JSON [EXTRA_JSON] -- an ansible-report.json carrying a
# driver object with the given flags list, and optionally more.
report_flags() {
    local flags=$1 extra=${2:-}
    fixture 'ansible-report.json' \
        "{\"driver\": {\"name\": \"native\", \"rc\": 0, \"duration_s\": 3, \
\"flags\": ${flags}}${extra:+, ${extra}}}"
}

# ---------------------------------------------------------------------------
# jget FILE EXPR -- read one thing back out of a JSON document.
#
#   jq is not a dependency of this tree and is not on this box; python3 is
#   both, because the serialiser itself requires it. EXPR is a Python
#   expression over `d`, so a failing assertion names the path it was reading
#   rather than an index into something the reader has to reconstruct.
#
#   The three JSON scalars that are not strings are printed distinguishably:
#   `<null>`, `true` and `false`. upstream.ref_consistent has three legal
#   answers and collapsing any two of them is the defect this file is most
#   concerned with, so the reader may not blur them.
# ---------------------------------------------------------------------------
jget() {
    python3 - "$1" "$2" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    d = json.load(handle)
value = eval(sys.argv[2], {"__builtins__": {"len": len, "sorted": sorted}}, {"d": d})
if value is None:
    sys.stdout.write("<null>")
elif isinstance(value, bool):
    sys.stdout.write("true" if value else "false")
elif isinstance(value, (dict, list)):
    sys.stdout.write(json.dumps(value, sort_keys=True))
else:
    sys.stdout.write(str(value))
PY
}

# json_ok FILE -- the document parses. Used on its own wherever "valid JSON in
# every case" is the property being asserted.
json_ok() {
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1"
}


# ===========================================================================
# The spine: what every document carries, on every path.
# ===========================================================================

@test "every result document carries the schema, the outcome and both exit fields" {
    lib_source exitcodes.sh result.sh
    export TPOT_STATE_DIR="$TMP/state" TPOT_RESULT_JSON="$TMP/state/result.json"
    TPOT_VERSION=0.1.0 TPOT_RUN_ID=RUNID TPOT_STARTED_AT=2026-09-04T10:00:00Z

    run res_write 0
    assert_rc 0

    json_ok "$TPOT_RESULT_JSON"
    assert_eq 'tpot-automation/result@1' \
        "$(jget "$TPOT_RESULT_JSON" 'd["schema"]')" 'schema'
    assert_eq 'ok'      "$(jget "$TPOT_RESULT_JSON" 'd["outcome"]')" 'outcome'
    assert_eq '0'       "$(jget "$TPOT_RESULT_JSON" 'd["exit_code"]')" 'exit_code'
    assert_eq 'EX_OK'   "$(jget "$TPOT_RESULT_JSON" 'd["exit_name"]')" 'exit_name'
    assert_eq '2026-09-04T10:00:00Z' \
        "$(jget "$TPOT_RESULT_JSON" 'd["started_at"]')" 'started_at'
    assert_matches '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
        "$(jget "$TPOT_RESULT_JSON" 'd["finished_at"]')" 'finished_at'
}

# The gates caught a documented exit code the tree did not produce; only
# running the code catches the mirror image of that -- the right number
# carrying the wrong name. Every code lib/exitcodes.sh defines is written and
# read back, rather than a sample, because the table is the contract.
@test "exit_name agrees with exit_code for every code the exit table defines" {
    lib_source exitcodes.sh result.sh
    export TPOT_STATE_DIR="$TMP/state" TPOT_RESULT_JSON="$TMP/state/result.json"
    TPOT_STARTED_AT=2026-09-04T10:00:00Z

    local code want got
    for code in $(ex_codes); do
        res_write "$code" || {
            printf 'res_write failed for code %s\n' "$code" >&2
            return 1
        }
        want=$(ex_name "$code")
        got=$(jget "$TPOT_RESULT_JSON" 'd["exit_name"]')
        assert_eq "$want" "$got" "exit_name for exit $code"
        assert_eq "$code" "$(jget "$TPOT_RESULT_JSON" 'd["exit_code"]')" \
            "exit_code for exit $code"
        assert_eq "$(res_outcome_for_code "$code")" \
            "$(jget "$TPOT_RESULT_JSON" 'd["outcome"]')" "outcome for exit $code"
    done
}

# A code the table does not define must produce a null name, not a guess. The
# outcome still falls back to internal_error, which is the honest answer for
# "this installer exited with something it does not define".
@test "an exit code the table does not define leaves exit_name null rather than guessing" {
    lib_source exitcodes.sh result.sh
    export TPOT_STATE_DIR="$TMP/state" TPOT_RESULT_JSON="$TMP/state/result.json"
    TPOT_STARTED_AT=2026-09-04T10:00:00Z

    res_write 99
    json_ok "$TPOT_RESULT_JSON"
    assert_eq '99' "$(jget "$TPOT_RESULT_JSON" 'd["exit_code"]')" 'exit_code'
    assert_eq '<null>' "$(jget "$TPOT_RESULT_JSON" 'd["exit_name"]')" 'exit_name'
    assert_eq 'internal_error' \
        "$(jget "$TPOT_RESULT_JSON" 'd["outcome"]')" 'outcome'
}

# The document is read by a machine that may keep it, and it can carry
# hostnames, paths and the operator's own config values. 0600 is what
# res_write promises and what SECURITY.md repeats.
@test "the document is written 0600" {
    lib_source exitcodes.sh result.sh
    export TPOT_STATE_DIR="$TMP/state" TPOT_RESULT_JSON="$TMP/state/result.json"
    TPOT_STARTED_AT=2026-09-04T10:00:00Z

    res_write 0
    assert_eq '600' "$(stat -c '%a' "$TPOT_RESULT_JSON")" 'result.json mode'
}

# Writing twice in one run is the normal case, not an edge one: install.sh
# writes the document at the end of the run so the notice can quote it, and
# the EXIT trap writes it again with the final state. The document is rebuilt
# from scratch each time, so nothing may accumulate.
@test "writing the document twice does not duplicate what it collected" {
    lib_source exitcodes.sh result.sh
    export TPOT_STATE_DIR="$TMP/state" TPOT_RESULT_JSON="$TMP/state/result.json"
    TPOT_STARTED_AT=2026-09-04T10:00:00Z
    # With a run directory, which is the situation install.sh is actually in:
    # the collected facts are materialised there and survive between the two
    # writes, so anything that accumulated would show up in the second.
    RUNDIR="$TMP/run"; mkdir -p "$RUNDIR"

    res_add_warning 'the same warning'
    res_add_error 'the same error'
    res_add_forced 'TPOT_FORCE_OS'
    res_write 0
    res_write 0

    assert_eq '1' "$(jget "$TPOT_RESULT_JSON" 'len(d["warnings"])')" 'warning count'
    assert_eq '1' "$(jget "$TPOT_RESULT_JSON" 'len(d["errors"])')" 'error count'
    assert_eq '1' "$(jget "$TPOT_RESULT_JSON" 'len(d["invocation"]["forced"])')" \
        'forced count'
}


# The document merges warnings from three writers -- install.sh's own, the
# play's, and the masking pass below -- and a reader acts on the list. The same
# sentence arriving twice is one condition, not two, and a document that
# reported it twice would read as though something happened twice.
@test "a warning that reaches the document from two writers is reported once" {
    res_reset
    KV="$TMP/kv.tsv"
    {
        printf 'started_at\t%s\n'  '2026-09-04T10:00:00Z'
        printf 'finished_at\t%s\n' '2026-09-04T10:05:00Z'
        printf 'exit_code\t%s\n'   '0'
        printf 'outcome\t%s\n'     'ok'
        printf 'warning\t%s\n'     'the same condition, seen twice'
        printf 'warning\t%s\n'     'and one only install.sh saw'
    } >"$KV"
    REPORT=$(fixture 'ansible-report.json' \
        '{"warnings": ["the same condition, seen twice"]}')

    serialise
    assert_rc 0
    assert_eq '2' "$(jget "$OUT" 'len(d["warnings"])')" 'warning count'
}


# ===========================================================================
# Unknown facts are null. This is the artefact's whole point.
# ===========================================================================

# On this box every acting invocation stops in preflight stage A on the root
# check and exits 11 -- nothing is installed, and nothing ever has been. That
# makes it the one real end-to-end run available here, and it is exactly the
# case the null rule exists for: no upstream was fetched, so there is no
# upstream object to report, and inventing an empty one would read as "we
# looked and found nothing".
@test "a run that failed in preflight reports no upstream object at all" {
    # A password is supplied so that the run gets PAST the merge and into
    # preflight; without one it would stop at a usage error one stage earlier,
    # which has no upstream object either and would prove nothing.
    export TPOT_WEB_PASSWORD="$SECRET"
    run_install --non-interactive
    assert_rc 11

    local doc="$TMP/state/result.json"
    [[ -r $doc ]] || {
        printf 'no result.json at %s; run output was:\n%s\n' "$doc" "$output" >&2
        return 1
    }
    json_ok "$doc"
    assert_eq 'preflight_failed' "$(jget "$doc" 'd["outcome"]')" 'outcome'
    assert_eq 'EX_PREFLIGHT'     "$(jget "$doc" 'd["exit_name"]')" 'exit_name'
    assert_eq '<null>' "$(jget "$doc" 'd["upstream"]')" 'upstream'
    assert_eq '<null>' "$(jget "$doc" 'd["driver"]')"   'driver'
    assert_eq '<null>' "$(jget "$doc" 'd["accounts"]')" 'accounts'
    assert_eq '<null>' "$(jget "$doc" 'd["ansible"]')"  'ansible'
}

# The same run, read for the other property SECURITY.md claims. The password
# is supplied through the environment channel, reaches the merge, and must
# appear nowhere in the artefact -- not masked, not truncated, absent.
@test "a supplied password appears nowhere in the document of a real run" {
    export TPOT_WEB_PASSWORD="$SECRET"
    run_install --non-interactive
    assert_rc 11

    local doc="$TMP/state/result.json"
    [[ -r $doc ]] || return 1
    refute_contains "$SECRET" "$(cat "$doc")" 'result.json'
}

@test "a document built from no inputs at all is still valid JSON" {
    res_reset
    serialise
    assert_rc 0
    json_ok "$OUT"
    assert_eq '<null>' "$(jget "$OUT" 'd["host"]')" 'host'
    assert_eq '<null>' "$(jget "$OUT" 'd["upstream"]')" 'upstream'
    assert_eq '{}'     "$(jget "$OUT" 'd["config"]')" 'config'
    assert_eq '[]'     "$(jget "$OUT" 'd["preflight"]')" 'preflight'
    # No kv file means no decided outcome either, and the honest fallback for
    # that is an internal error rather than success.
    assert_eq 'internal_error' "$(jget "$OUT" 'd["outcome"]')" 'outcome'
    assert_eq '40' "$(jget "$OUT" 'd["exit_code"]')" 'exit_code'
}

# An input that is present and unreadable as JSON is the same fact as an
# absent one -- not known. What it may never be is a crash, because the
# document is written from an EXIT trap and a serialiser that raised would
# leave the run with no artefact at the moment one is most wanted.
@test "a document built from malformed inputs is still valid JSON" {
    res_reset
    KV=$(kv_default)
    local junk
    junk=$(fixture 'junk.json' 'not json at all {{{ "')
    PUBLIC=$junk; SOURCES=$junk; HOST=$junk; DEPS=$junk; REPORT=$junk
    PREFLIGHT=$(fixture 'preflight.tsv' $'incomplete-row\n')

    serialise
    assert_rc 0
    json_ok "$OUT"
    assert_eq '<null>' "$(jget "$OUT" 'd["host"]')" 'host'
    assert_eq '<null>' "$(jget "$OUT" 'd["ansible"]')" 'ansible'
    assert_eq '<null>' "$(jget "$OUT" 'd["upstream"]')" 'upstream'
    assert_eq '{}'     "$(jget "$OUT" 'd["config"]')" 'config'
    # A short preflight row is padded rather than dropped: the row was
    # measured, only its detail is missing.
    assert_eq 'incomplete-row' "$(jget "$OUT" 'd["preflight"][0]["id"]')" 'preflight id'
    assert_eq ''               "$(jget "$OUT" 'd["preflight"][0]["detail"]')" 'detail'
    # The kv file was fine, so the run's own verdict survives its inputs.
    assert_eq 'ok' "$(jget "$OUT" 'd["outcome"]')" 'outcome'
}


# ===========================================================================
# The hard refusal: merged.json may never be an input.
# ===========================================================================

# merged.json is the ONE document that holds the supplied credentials.
# lib/result.sh reads public.json, which is the same document with those keys
# removed, and the serialiser refuses outright to open a file by the other
# name -- so an edit that wires the wrong path in stops here rather than
# writing a password into the artefact SECURITY.md invites people to attach.
#
# Every one of the six input positions is tried, because a guard that covered
# five of them would pass a test that checked one.
@test "the serialiser refuses to read a file named merged.json, in any input position" {
    res_reset
    KV=$(kv_default)
    local merged position py rc
    merged=$(fixture 'merged.json' "{\"tpot_web_password\": \"${SECRET}\"}")
    py=$(res_serialiser)

    for position in 2 3 4 5 6 7; do
        local -a argv=("$KV" '' '' '' '' '' '' "$OUT")
        argv[$((position - 1))]=$merged
        rm -f -- "$OUT"
        run --separate-stderr python3 "$py" "${argv[@]}"
        assert_rc 40
        assert_contains 'refusing to read merged.json' "$stderr" \
            "stderr for input position $position"
        refute_contains "$SECRET" "$stderr" "stderr for input position $position"
        [[ -e $OUT ]] && {
            printf 'input position %s wrote %s anyway\n' "$position" "$OUT" >&2
            return 1
        }
    done
    return 0
}

# The guard is on the basename, so it holds wherever the file is. A run
# directory is a mktemp path nobody predicted, and a guard that only matched a
# literal known path would be no guard at all.
@test "the refusal holds for a merged.json in any directory" {
    res_reset
    KV=$(kv_default)
    mkdir -p "$TMP/run"
    printf '{"tpot_web_password": "%s"}' "$SECRET" >"$TMP/run/merged.json"
    PUBLIC="$TMP/run/merged.json"

    serialise
    assert_rc 40
    assert_contains 'refusing to read merged.json' "$stderr" 'stderr'
    [[ -e $OUT ]] && return 1
    return 0
}


# ===========================================================================
# config: a public key carries a value, a supplied secret carries none.
# ===========================================================================

# public.json holds every non-secret value; sources.json holds an origin for
# EVERY key including the secret ones. So a key sources.json knows about and
# public.json does not is exactly a supplied secret, and there is no value
# available at this point to put in its entry even by mistake.
@test "a public config key carries its value and where it came from" {
    res_reset
    KV=$(kv_default)
    PUBLIC=$(fixture 'public.json' \
        '{"tpot_install_type": "sensor", "tpot_web_user": "webmaster"}')
    SOURCES=$(fixture 'sources.json' \
        '{"tpot_install_type": {"source": "config-file", "detail": "/root/tpot.yml"},
          "tpot_web_user": {"source": "default"}}')

    serialise
    assert_rc 0
    assert_eq 'sensor' \
        "$(jget "$OUT" 'd["config"]["tpot_install_type"]["value"]')" 'value'
    assert_eq 'config-file' \
        "$(jget "$OUT" 'd["config"]["tpot_install_type"]["source"]')" 'source'
    assert_eq '/root/tpot.yml' \
        "$(jget "$OUT" 'd["config"]["tpot_install_type"]["detail"]')" 'detail'
    # A default has no detail to report and must not invent one.
    assert_eq 'false' \
        "$(jget "$OUT" '"detail" in d["config"]["tpot_web_user"]')" 'detail present'
}

@test "a supplied secret is reported as supplied and carries no value member" {
    res_reset
    KV=$(kv_default)
    PUBLIC=$(fixture 'public.json' '{"tpot_web_user": "webmaster"}')
    SOURCES=$(fixture 'sources.json' \
        '{"tpot_web_user": {"source": "default"},
          "tpot_web_password": {"source": "password-file",
                                "detail": "/root/.tpot-web-pw"}}')

    serialise
    assert_rc 0
    # "was a password supplied, and where from?" is a real diagnostic
    # question, so the key is reported rather than omitted.
    assert_eq 'true' \
        "$(jget "$OUT" 'd["config"]["tpot_web_password"]["secret"]')" 'secret'
    assert_eq 'true' \
        "$(jget "$OUT" 'd["config"]["tpot_web_password"]["supplied"]')" 'supplied'
    assert_eq 'password-file' \
        "$(jget "$OUT" 'd["config"]["tpot_web_password"]["source"]')" 'source'
    # And the answer to "what was it?" is not in the document at any time.
    assert_eq 'false' \
        "$(jget "$OUT" '"value" in d["config"]["tpot_web_password"]')" 'value member'
}

# The same fixture with the credential actually present in the channel the
# serialiser reads. This is the leak the two-document design prevents, written
# as a test so that the assertion above is known to be load-bearing rather
# than merely true of a fixture that never had a secret in it.
@test "a supplied password does not reach the document through the config channel" {
    res_reset
    KV=$(kv_default)
    PUBLIC=$(fixture 'public.json' '{"tpot_web_user": "webmaster"}')
    SOURCES=$(fixture 'sources.json' \
        "{\"tpot_web_password\": {\"source\": \"password-file\",
                                  \"detail\": \"/root/.tpot-web-pw\"}}")
    # The value itself is only ever in merged.json, which is not an input.
    printf '{"tpot_web_password": "%s"}' "$SECRET" >"$TMP/merged.json"

    serialise
    assert_rc 0
    refute_contains "$SECRET" "$(cat "$OUT")" 'result.json'
}


# ===========================================================================
# driver: a whitelist, and the drop is reported.
# ===========================================================================

# An earlier design of this installer -- since deleted -- carried per-prompt
# bookkeeping fields in this object. Building it from a declared list rather
# than from whatever arrived is what stops such a field returning to the
# artefact by accident. The drop goes to stderr so that it is a visible
# decision and not a silent loss: a field the play sends and the document
# does not carry is either a bug in the play or a whitelist that needs
# extending, and neither is discoverable from a quiet success.
@test "an undeclared driver field is dropped and the drop is named on stderr" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"driver": {"name": "native", "rc": 0, "duration_s": 7,
                     "flags": ["-s", "-t", "s"],
                     "prompt_count": 12, "expect_log": "/tmp/driver.log"}}')

    serialise
    assert_rc 0
    assert_eq 'false' "$(jget "$OUT" '"prompt_count" in d["driver"]')" 'prompt_count'
    assert_eq 'false' "$(jget "$OUT" '"expect_log" in d["driver"]')" 'expect_log'
    assert_contains 'dropped the undeclared driver field prompt_count' "$stderr" 'stderr'
    assert_contains 'dropped the undeclared driver field expect_log' "$stderr" 'stderr'
    # The declared ones survive, in the declared order.
    assert_eq '["duration_s", "flags", "name", "rc", "upstream_install_type"]' \
        "$(jget "$OUT" 'sorted(d["driver"])')" 'driver fields'
}

@test "a driver object with no name is named native" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"driver": {"rc": 0, "flags": ["-s", "-t", "s"]}}')

    serialise
    assert_rc 0
    assert_eq 'native' "$(jget "$OUT" 'd["driver"]["name"]')" 'driver.name'
}


# ===========================================================================
# driver.upstream_install_type: derived by reading the argv as getopts would.
# ===========================================================================

# The type is read back out of the argv that was ACTUALLY used, rather than
# out of a second field somebody has to keep in step with it. Upstream is
# always told the sensor type, because that is the one code path that never
# enters its credential branch -- so this field is not the same fact as the
# configured tpot_install_type, and reporting only one of the two would hide
# the difference that keeps a credential off every command line.
#
# getopts accepts three shapes for one option and the first version of this
# file knew only the first of them. All three are covered below.

@test "the install type is read from a separated flag -t s" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags '["-s", "-t", "s", "-b", "REF1"]')
    serialise
    assert_rc 0
    assert_eq 's' "$(jget "$OUT" 'd["driver"]["upstream_install_type"]')" 'install type'
}

@test "the install type is read from an attached flag -ts" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags '["-s", "-ts", "-b", "REF1"]')
    serialise
    assert_rc 0
    assert_eq 's' "$(jget "$OUT" 'd["driver"]["upstream_install_type"]')" 'install type'
}

@test "the install type is read from a cluster, whether the value is attached or not" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags '["-sts", "-b", "REF1"]')
    serialise
    assert_rc 0
    assert_eq 's' "$(jget "$OUT" 'd["driver"]["upstream_install_type"]')" \
        'install type from -sts'

    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags '["-st", "s", "-b", "REF1"]')
    serialise
    assert_rc 0
    assert_eq 's' "$(jget "$OUT" 'd["driver"]["upstream_install_type"]')" \
        'install type from -st s'
}

# Upstream assigns its variable on every pass of its own getopts loop, so the
# last -t is the one the box ends up running. A reader that took the first
# would name a type the install did not use.
@test "the install type is the last one on the command line, as upstream would read it" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags '["-t", "h", "-t", "s"]')
    serialise
    assert_rc 0
    assert_eq 's' "$(jget "$OUT" 'd["driver"]["upstream_install_type"]')" 'install type'
}

@test "an argv with no -t leaves the install type null rather than assuming sensor" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags '["-s", "-b", "REF1"]')
    serialise
    assert_rc 0
    assert_eq '<null>' "$(jget "$OUT" 'd["driver"]["upstream_install_type"]')" \
        'install type'
}


# ===========================================================================
# Credential masking. Masking is not the point -- the warning is.
# ===========================================================================

# This project's own invocation never puts a credential on a command line at
# all, so a -u or a -p arriving here means something drove upstream the other
# way. A silent replacement would turn a real defect into a clean-looking
# document, which is why every case below asserts the warning as well as the
# mask. SECURITY.md states this behaviour as enforced today; these tests are
# what enforce it.

@test "a separated -p value is replaced and earns a warning" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags "[\"-s\", \"-p\", \"${SECRET}\"]")
    serialise
    assert_rc 0
    refute_contains "$SECRET" "$(cat "$OUT")" 'result.json'
    assert_eq '["-s", "-p", "***"]' "$(jget "$OUT" 'd["driver"]["flags"]')" 'flags'
    assert_contains 'upstream was invoked with -p' \
        "$(jget "$OUT" 'd["warnings"]')" 'warnings'
    assert_contains 'a credential reached a command line' \
        "$(jget "$OUT" 'd["warnings"]')" 'warnings'
}

# THE PAST DEFECT THIS TEST EXISTS FOR: an earlier version of lib/result.sh
# recognised only a value written as a SEPARATE element. An attached one --
# which is what getopts reads a value out of the tail of the same word --
# walked straight through in clear text, with no warning at all. Do not delete
# this as a duplicate of the separated case; it is the case that was wrong.
@test "an attached -p value is replaced too, and does not walk past in clear text" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags "[\"-s\", \"-p${SECRET}\"]")
    serialise
    assert_rc 0
    refute_contains "$SECRET" "$(cat "$OUT")" 'result.json'
    assert_eq '["-s", "-p***"]' "$(jget "$OUT" 'd["driver"]["flags"]')" 'flags'
    assert_contains 'upstream was invoked with -p' \
        "$(jget "$OUT" 'd["warnings"]')" 'warnings'
}

# roles/tpot_install refuses -u and -p as extra flags before it builds the
# vector, but it compares WHOLE ELEMENTS -- so a clustered or attached value
# walks past that first line of defence and arrives here. This is the shape
# that does.
@test "a clustered -p value is replaced, in both of its shapes" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags "[\"-sp${SECRET}\"]")
    serialise
    assert_rc 0
    refute_contains "$SECRET" "$(cat "$OUT")" 'result.json'
    assert_eq '["-sp***"]' "$(jget "$OUT" 'd["driver"]["flags"]')" 'flags'
    assert_contains 'upstream was invoked with -p' \
        "$(jget "$OUT" 'd["warnings"]')" 'warnings'

    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags "[\"-sp\", \"${SECRET}\"]")
    serialise
    assert_rc 0
    refute_contains "$SECRET" "$(cat "$OUT")" 'result.json'
    assert_eq '["-sp", "***"]' "$(jget "$OUT" 'd["driver"]["flags"]')" 'flags'
}

# A deliberate departure from getopts, and the reason is worth keeping: this
# list is not being executed, it is being written into a document that gets
# attached to bug reports. Something credential-shaped after a `--` is still a
# credential sitting in an argv.
@test "a credential after a bare -- is still found and still masked" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags "[\"--\", \"-p\", \"${SECRET}\"]")
    serialise
    assert_rc 0
    refute_contains "$SECRET" "$(cat "$OUT")" 'result.json'
    assert_eq '["--", "-p", "***"]' "$(jget "$OUT" 'd["driver"]["flags"]')" 'flags'
}

@test "a -u web username is masked and warned about as well as a password" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags "[\"-s\", \"-u\", \"${SECRET}\"]")
    serialise
    assert_rc 0
    refute_contains "$SECRET" "$(cat "$OUT")" 'result.json'
    assert_eq '["-s", "-u", "***"]' "$(jget "$OUT" 'd["driver"]["flags"]')" 'flags'
    assert_contains 'a web username reached a command line' \
        "$(jget "$OUT" 'd["warnings"]')" 'warnings'
}

# Nothing to mask is not nothing to say. -p with nothing after it is what
# upstream would see as a missing argument, and it still means somebody put a
# credential flag on the command line.
@test "a trailing -p with no value still earns a warning" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags '["-s", "-p"]')
    serialise
    assert_rc 0
    assert_eq '["-s", "-p"]' "$(jget "$OUT" 'd["driver"]["flags"]')" 'flags'
    assert_contains 'nothing followed it' \
        "$(jget "$OUT" 'd["warnings"]')" 'warnings'
}

# The invocation this project actually makes. It must produce no warning at
# all, or the warning above stops meaning anything.
@test "this project's own invocation earns no credential warning" {
    res_reset
    KV=$(kv_default)
    REPORT=$(report_flags \
        '["-s", "-t", "s", "-b", "REF1", "-r", "https://example.test/tpot.git"]')
    serialise
    assert_rc 0
    assert_eq '[]' "$(jget "$OUT" 'd["warnings"]')" 'warnings'
}


# ===========================================================================
# upstream.ref_consistent: three answers, and they may not collapse into two.
# ===========================================================================

# One variable pins two different things -- the ENTRYPOINT that was fetched
# and the PAYLOAD upstream then clones with its own -b -- and they are
# reported apart so a reader can see whether they agree. `ref_consistent` is
# the field that says whether this box is running the ref the document names.

@test "ref_consistent is true when the ref, the url and the payload ref agree" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"upstream": {"ref": "REF1",
                       "url": "https://example.test/tpot/REF1/install.sh",
                       "payload_ref": "REF1", "verified": true},
          "driver": {"flags": ["-s", "-t", "s", "-b", "REF1"]}}')
    serialise
    assert_rc 0
    assert_eq 'true' "$(jget "$OUT" 'd["upstream"]["ref_consistent"]')" 'ref_consistent'
}

# The payload ref is read back out of the argv when the report does not state
# it, for the same reason the install type is: the argv is what ran.
@test "ref_consistent is true when the payload ref is only visible in the argv" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"upstream": {"ref": "REF1",
                       "url": "https://example.test/tpot/REF1/install.sh"},
          "driver": {"flags": ["-s", "-b", "REF1"]}}')
    serialise
    assert_rc 0
    assert_eq 'REF1' "$(jget "$OUT" 'd["upstream"]["payload_ref"]')" 'payload_ref'
    assert_eq 'true' "$(jget "$OUT" 'd["upstream"]["ref_consistent"]')" 'ref_consistent'
}

@test "ref_consistent is false when the payload ref disagrees with the pinned ref" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"upstream": {"ref": "REF1",
                       "url": "https://example.test/tpot/REF1/install.sh",
                       "payload_ref": "REF2"}}')
    serialise
    assert_rc 0
    assert_eq 'false' "$(jget "$OUT" 'd["upstream"]["ref_consistent"]')" 'ref_consistent'
}

@test "ref_consistent is false when the fetch url does not carry the pinned ref" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"upstream": {"ref": "REF1",
                       "url": "https://example.test/tpot/main/install.sh",
                       "payload_ref": "REF1"}}')
    serialise
    assert_rc 0
    assert_eq 'false' "$(jget "$OUT" 'd["upstream"]["ref_consistent"]')" 'ref_consistent'
}

# THE ONE THAT MUST NOT ROUND UP TO NULL. Upstream never re-fetches or
# re-execs itself, and with no -b -- run outside a git work tree, which is
# exactly how a fetched-and-executed install.sh runs -- it falls back to its
# own default branch SILENTLY. So an argv that reached upstream without a -b
# is not an unknown: the payload is definitely not the ref named above.
@test "ref_consistent is false, not null, when upstream ran and received no -b at all" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"upstream": {"ref": "REF1",
                       "url": "https://example.test/tpot/REF1/install.sh"},
          "driver": {"flags": ["-s", "-t", "s"]}}')
    serialise
    assert_rc 0
    assert_eq '<null>' "$(jget "$OUT" 'd["upstream"]["payload_ref"]')" 'payload_ref'
    assert_eq 'false' "$(jget "$OUT" 'd["upstream"]["ref_consistent"]')" 'ref_consistent'
}

# And the third answer, which is neither of the first two: nothing ran, so
# nothing can be said. Null here means "there was not enough information to
# tell", which is not the same as "no".
@test "ref_consistent is null when upstream never ran, and when no ref was pinned" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"upstream": {"ref": "REF1",
                       "url": "https://example.test/tpot/REF1/install.sh"}}')
    serialise
    assert_rc 0
    assert_eq '<null>' "$(jget "$OUT" 'd["upstream"]["ref_consistent"]')" \
        'ref_consistent with no driver at all'

    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"upstream": {"url": "https://example.test/tpot/main/install.sh"},
          "driver": {"flags": ["-s", "-b", "REF1"]}}')
    serialise
    assert_rc 0
    assert_eq '<null>' "$(jget "$OUT" 'd["upstream"]["ref_consistent"]')" \
        'ref_consistent with no pinned ref'
}

# Pinning a ref pins the recipe and never the images: T-Pot's own
# TPOT_PULL_POLICY defaults to `always`, so the software on the box changes
# after we verified it and keeps changing on every reboot. This flag is the
# honest name for that gap, so it is false even when something upstream of it
# claims otherwise -- SECURITY.md tells a reader it reports false.
@test "upstream.pins_payload is false, and stays false even if the report says true" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' \
        '{"upstream": {"ref": "REF1", "url": "https://example.test/tpot/REF1/x",
                       "payload_ref": "REF1", "pins_payload": true}}')
    serialise
    assert_rc 0
    assert_eq 'false' "$(jget "$OUT" 'd["upstream"]["pins_payload"]')" 'pins_payload'
}

# `verified` is our own sha256 check on the fetched entrypoint, and it is not
# replaced by upstream's -b. A report that never mentioned it must leave it
# null: "we did not check" and "we checked and it failed" are different
# sentences and both are answers a reader acts on.
@test "upstream.verified is null when nothing said whether the entrypoint was verified" {
    res_reset
    KV=$(kv_default)
    REPORT=$(fixture 'ansible-report.json' '{"upstream": {"ref": "REF1"}}')
    serialise
    assert_rc 0
    assert_eq '<null>' "$(jget "$OUT" 'd["upstream"]["verified"]')" 'verified'
}


# ===========================================================================
# host.matrix_tier: the derivation that must never promote a box.
# ===========================================================================

# The matrix has two tiers. SUPPORTED is whatever the PINNED upstream ref's
# own gate accepts, so it is a property of the pin and cannot be read off
# support-matrix.yml at all. When preflight did not record a tier, the
# weakest true statement is LEGACY -- a matrix row matched, and that is all.
# Deriving `supported` here would quietly promote a box into the tested tier
# on the strength of a fact that does not say so.
@test "a matched matrix row with no recorded tier derives legacy, never supported" {
    res_reset
    KV=$(kv_default)
    HOST=$(fixture 'host.json' '{"supported": true, "os_id": "debian"}')
    serialise
    assert_rc 0
    assert_eq 'legacy' "$(jget "$OUT" 'd["host"]["matrix_tier"]')" 'matrix_tier'
    assert_eq 'true'   "$(jget "$OUT" 'd["host"]["supported"]')" 'supported'
}

@test "a host nothing measured against the matrix is unknown, not unsupported" {
    res_reset
    KV=$(kv_default)
    HOST=$(fixture 'host.json' '{"os_id": "debian"}')
    serialise
    assert_rc 0
    assert_eq 'unknown' "$(jget "$OUT" 'd["host"]["matrix_tier"]')" 'matrix_tier'

    # Measured and found not to match is a different answer, and it is given.
    res_reset
    KV=$(kv_default)
    HOST=$(fixture 'host.json' '{"supported": false, "os_id": "arch"}')
    serialise
    assert_rc 0
    assert_eq 'unsupported' "$(jget "$OUT" 'd["host"]["matrix_tier"]')" 'matrix_tier'
}

@test "a tier preflight recorded is used as recorded, and a nonsense one is unknown" {
    res_reset
    KV=$(kv_default)
    HOST=$(fixture 'host.json' '{"supported": true, "matrix_tier": "supported"}')
    serialise
    assert_rc 0
    assert_eq 'supported' "$(jget "$OUT" 'd["host"]["matrix_tier"]')" 'matrix_tier'

    res_reset
    KV=$(kv_default)
    HOST=$(fixture 'host.json' '{"supported": true, "matrix_tier": "excellent"}')
    serialise
    assert_rc 0
    assert_eq 'unknown' "$(jget "$OUT" 'd["host"]["matrix_tier"]')" 'matrix_tier'
}


# ===========================================================================
# Values that would break a hand-built JSON string.
# ===========================================================================

# No JSON string in this tree is built by concatenation, and this is why: a
# hostname with a quote in it, or a warning with a backslash, would turn the
# one artefact a caller depends on into unparseable text. python3 does every
# piece of quoting; this test is the evidence that it still does.
@test "a warning full of quotes and backslashes survives as valid JSON" {
    lib_source exitcodes.sh result.sh
    export TPOT_STATE_DIR="$TMP/state" TPOT_RESULT_JSON="$TMP/state/result.json"
    TPOT_STARTED_AT=2026-09-04T10:00:00Z

    local nasty=$'he said "no" \\ and left\ta tab, then\na newline'
    res_add_warning "$nasty"
    res_write 0

    json_ok "$TPOT_RESULT_JSON"
    # The quote and the backslash reach the document unharmed. The tab and the
    # newline become spaces, because res_set strips both: the interchange
    # format between bash and the serialiser is TSV, and a value carrying
    # either would silently truncate the record rather than fail.
    assert_eq 'he said "no" \ and left a tab, then a newline' \
        "$(jget "$TPOT_RESULT_JSON" 'd["warnings"][0]')" 'warning'
}

@test "a stage A refusal reaches result.json instead of leaving preflight empty" {
    # THE GAP THIS CLOSES, MEASURED 2026-09-05.
    #   preflight records live in $RUNDIR/preflight.tsv, and $RUNDIR is created
    #   at step 4 -- AFTER stage A, which is step 3. So on any stage A refusal
    #   pf_flush had nowhere to write, returned 0 having written nothing, and
    #   this artefact recorded `"preflight": []`.
    #
    #   That is not an edge case. Stage A is root, apt, python3, os, arch,
    #   systemd, runtime_dir, answer_file and repo_tree -- every "your box is
    #   wrong" refusal, and precisely the set a CI system or a provisioning
    #   tool would branch on. The terminal named the failing check; the
    #   machine-readable artefact whose whole purpose is a true outcome did
    #   not.
    #
    #   This box is unprivileged, so the root check fails and the run stops in
    #   stage A -- which makes it the exact condition the defect needed.
    #
    #   --preflight-only rather than a full run: a full run is refused at
    #   argument parsing for the missing tpot_web_password and exits 10 before
    #   preflight is reached at all, which would test the wrong thing.
    run_install --non-interactive --preflight-only
    assert_rc 11
    local doc="$TMP/state/result.json"
    [[ -f $doc ]] || { printf 'no result.json at %s\n' "$doc" >&2; return 1; }

    local n
    n=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("preflight",[])))' "$doc")
    [[ $n -gt 0 ]] || {
        printf 'result.json carries %s preflight records for a stage A refusal\n' "$n" >&2
        return 1
    }

    # The refusal itself must be in there, not merely some records.
    local failed
    failed=$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(",".join(r["id"] for r in d.get("preflight",[]) if r.get("status")=="fail"))' "$doc")
    assert_contains 'root' "$failed" 'the failing checks recorded in result.json'
}

@test "the fallback leaves no dotfile behind in the state directory" {
    # It is written beside the destination as a $$-scoped dotfile, mirroring
    # the kv file, and removed on the same path. A run that littered the state
    # directory would be a worse defect than the one this fixed.
    run_install --non-interactive --preflight-only
    assert_rc 11
    local leftovers
    leftovers=$(find "$TMP/state" -maxdepth 1 -name '.result-preflight.*' -o -maxdepth 1 -name '.result-kv.*' | tr '\n' ' ')
    [[ -z ${leftovers// /} ]] || {
        printf 'the state directory still holds: %s\n' "$leftovers" >&2
        return 1
    }
}
