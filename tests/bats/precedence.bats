#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# tests/bats/precedence.bats -- lib/config.py, the four-channel configuration
# merge. Two properties are tested here, and the first is worth more than
# everything else in this suite put together.
#
#   1. BYTE IDENTITY. What goes in comes out, byte for byte, for every byte.
#   2. PRECEDENCE AND REFUSAL. Which channel wins, which of the three written
#      documents each value lands in, and the inputs the merge must reject.
#
# THE DEFECT THE BYTE-IDENTITY TESTS PIN, WHICH IS REAL AND SHIPPED
#   The installer this project replaces built its configuration by running
#   `sed` over a YAML template to substitute the dashboard password into a
#   double-quoted scalar. Its escaping function handled a backslash, a slash
#   and an ampersand -- and nothing else. A password containing the two
#   characters backslash and n therefore arrived in the YAML file as an escape
#   sequence, parsed cleanly as a newline, and SILENTLY INSTALLED A DIFFERENT
#   PASSWORD FROM THE ONE TYPED. There was no error, ever. The operator found
#   out when they could not log in, with nothing anywhere to explain why.
#
#   lib/config.py has no escaping step at all: values are carried as Python
#   strings from the moment they are read to the moment json.dump encodes
#   them, and the JSON encoder is the only thing that ever quotes anything.
#   That is a property, not an implementation detail, so it is tested as one.
#   A hostile value goes in through a channel, comes back out of the merged
#   document, and the BYTES are compared with cmp -- never with a shell string
#   comparison, which normalises a trailing newline and stops at a NUL.
#
#   Reintroducing any escaping step -- a sed, a printf %b, a shell expansion
#   of the value -- turns these red. That is the whole point of writing them.
#
# WHAT CANNOT BE TESTED HERE, AND SAYS SO
#   Two of the merge's rules require root: an answer file or a password file
#   that supplies a secret must be owned by uid 0. This box is unprivileged,
#   so the ACCEPTANCE half of each is skipped loudly by name. The REFUSAL half
#   is tested in full, because refusing a file we own is exactly what an
#   unprivileged run produces.
#
#   Nothing here installs anything, opens a socket, or writes outside the
#   test's own scratch directory. lib/config.py never does any of those.

load helper

# ---------------------------------------------------------------------------
# Running the merge
#
# The environment is ONE OF THE FOUR CHANNELS under test, so it is wiped and
# rebuilt rather than inherited. A stray TPOT_* or IOC_* variable belonging to
# whoever ran `bats` would otherwise become a fifth input -- and an unknown one
# is a usage error, so the failure would look like the product's when it was
# the harness's.
#
#   MERGE_ENV       extra VAR=VALUE words for the run: the environment channel
#   MERGE_REPO_DIR  what --repo-dir is given. The answer-file location rule is
#                   measured against it, so a test that needs a "repository" to
#                   put a file inside points this at one it built in $TMP.
#
# The three output paths are written as "$TMP/..." at every use rather than
# held in variables: $TMP is created by helper.bash's setup(), which runs
# AFTER this file's top level, so a variable assigned up here would be empty.
#
# The dashboard password is the one required input, so every test that is not
# about it passes --optional for it -- exactly as install.sh does for
# --preflight-only and --verify-only. Supplying a dummy password instead would
# quietly make that dummy the thing under test.
# ---------------------------------------------------------------------------

PW_OPTIONAL=(--optional tpot_web_password)

config_merge() {
    local repo_dir=${MERGE_REPO_DIR:-$REPO}
    run env -i \
        PATH="$PATH" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
        ${MERGE_ENV[@]+"${MERGE_ENV[@]}"} \
        python3 "$LIB/config.py" merge \
        --schema "$LIB/varschema.json" \
        --repo-dir "$repo_dir" \
        --out "$TMP/merged.json" \
        --public-out "$TMP/public.json" \
        --sources-out "$TMP/sources.json" \
        "$@"
}

# ---------------------------------------------------------------------------
# Reading a value back out, AS BYTES
#
# Deliberately not `jq`: it is not installed here and is not a dependency this
# product has. Deliberately not a shell variable either -- a value may end in a
# newline and $( ) eats those. The bytes go to a file, and files are compared.
# ---------------------------------------------------------------------------
json_bytes() {
    local document=$1 key=$2 out=$3
    python3 - "$document" "$key" "$out" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    document = json.load(handle)
value = document[sys.argv[2]]          # a KeyError here is a real failure
with open(sys.argv[3], "wb") as handle:
    handle.write(value.encode("utf-8"))
PY
}

# json_text DOCUMENT KEY -- for values that are safe to put in a variable.
json_text() {
    json_bytes "$1" "$2" "$TMP/.text.bin" && cat "$TMP/.text.bin"
}

digest() {
    python3 - "$1" <<'PY'
import hashlib, sys
with open(sys.argv[1], "rb") as handle:
    sys.stdout.write(hashlib.sha256(handle.read()).hexdigest())
PY
}

# assert_bytes_identical WANT GOT [WHAT]
#   On failure it prints lengths, digests and the offset of the first
#   difference -- and NOT the bytes. These are passwords, and this harness
#   persists its output to disk; a failure that dumped the value would be the
#   same defect one directory up. Length plus digest separates "truncated"
#   from "mangled" from "a different value entirely", which is the whole of
#   the diagnosis anyone needs.
assert_bytes_identical() {
    local want=$1 got=$2 what=${3:-value}
    if ! cmp -s -- "$want" "$got"; then
        printf '%s did not survive the merge byte for byte.\n' "$what" >&2
        printf '  wanted %s bytes, sha256 %s\n' "$(wc -c <"$want")" "$(digest "$want")" >&2
        printf '     got %s bytes, sha256 %s\n' "$(wc -c <"$got")" "$(digest "$got")" >&2
        printf '  %s\n' "$(cmp -- "$want" "$got" 2>&1 || true)" >&2
        return 1
    fi
}

# secret_survives WANTFILE
#   Push the exact bytes of WANTFILE through the merge as the dashboard
#   password on standard input, and require them back unchanged.
#
#   One newline is appended on the way in, because the reader strips exactly
#   one trailing newline -- that is what makes a value typed at a prompt and a
#   value in a text file mean the same thing. Appending one and expecting it
#   gone tests the "exactly one, and never more" half of that rule for every
#   case below, including the cases that already end in a newline.
#
#   $status and $output are left as the merge produced them, so a caller can
#   go on to assert about the warning it printed.
secret_survives() {
    local want=$1
    cat -- "$want" > "$TMP/stdin.bin"
    printf '\n' >> "$TMP/stdin.bin"

    config_merge --secret-stdin tpot_web_password < "$TMP/stdin.bin"
    assert_rc 0

    json_bytes "$TMP/merged.json" tpot_web_password "$TMP/got.bin"
    assert_bytes_identical "$want" "$TMP/got.bin" 'the dashboard password'

    # A byte-exact secret written into the wrong document is not a pass.
    if ! python3 - "$TMP/public.json" <<'PY'
import json, sys
document = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(1 if "tpot_web_password" in document else 0)
PY
    then
        printf 'the dashboard password is present in public.json\n' >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# The hostile corpus, for the channels that carry a value as a shell word.
#
# One file per case, so a failure names the case. Every byte here is a byte
# that has broken a configuration writer somewhere: shell metacharacters,
# printf format specifiers, YAML indicators, the two-character escapes that
# defeated the tool this replaces, sed's own replacement syntax, and text
# outside ASCII.
#
# NUL is absent for one honest reason: a shell variable cannot hold one, so a
# test driving --set or the environment could not construct the input. Control
# bytes reach the stdin channel directly in the tests above.
# ---------------------------------------------------------------------------
write_corpus() {
    local dir=$1
    mkdir -p "$dir"
    printf '%s' 'pw\nmore'                            > "$dir/01-backslash-n"
    printf '%s' 'a\tb\bc\\d\"eAf\x41g\0h'        > "$dir/02-escape-soup"
    printf '%s' "it's a \"quoted\" thing"             > "$dir/03-quotes"
    printf '%s' 'x`id`$(id)${HOME}$USER$((1+1))'      > "$dir/04-substitution"
    printf '%s' 'a|b;c&d>e<f*g?h[i]j!k~l#m'           > "$dir/05-metacharacters"
    printf '%s' '%s %d %% %n %045d %(x)s'             > "$dir/06-format-specifiers"
    printf '%s' '{"a": 1} - b: [c] #d --- %YAML *x'   > "$dir/07-structure-markers"
    printf '%s' 'héllo Ωmega 漢字テスト 🐝🔑 ćčžšđ'    > "$dir/08-utf8"
    printf '%s' '   padded	and spaced   '            > "$dir/09-padding"
    # The three characters the old escaping function DID handle, beside the
    # sed replacement syntax it did not: & is "the whole match", \1 a group.
    printf '%s' 's/a/b/g & \& \1 \\& /etc/x'          > "$dir/10-sed-replacement"
    printf 'line one\nline two\n'                     > "$dir/11-real-newlines"
}

# read_exact VARNAME FILE -- the file's exact content, trailing newlines and
#   all. `-d ''` reads to end of file rather than to a newline, which is what
#   $(cat) cannot do.
read_exact() {
    local varname=$1 file=$2
    IFS= read -r -d '' "$varname" < "$file" || true
}

have_pyyaml() {
    python3 -c 'import yaml' 2>/dev/null
}

# ---------------------------------------------------------------------------
# BYTE IDENTITY -- the dashboard password, through the one secret channel an
# unprivileged box can drive.
# ---------------------------------------------------------------------------

# THE defect: two characters, a backslash and an n, in a password. The tool
# this replaces turned them into a newline inside a YAML double-quoted scalar
# and installed something else without a word.
@test "a password containing a literal backslash-n survives the merge byte for byte" {
    printf '%s' 'Correct\nHorse\nBattery' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

# The rest of the two-character sequences a double-quoted YAML or JSON scalar
# would have absorbed: tab, backspace, an escaped backslash, an escaped quote,
# a unicode escape, a hex escape and a NUL escape. All seven defeated the old
# escaping function, which knew about three characters.
@test "a password of two-character escape sequences survives the merge byte for byte" {
    printf '%s' 'a\tb\bc\\d\"eAf\x41g\0h\r\n' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

@test "a password containing single and double quotes survives the merge byte for byte" {
    printf '%s' "don't \"stop\" -- it's 'fine'" > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

# If any part of the path ever evaluated the value as shell, this test records
# a uid instead of the password and goes red. That is what it is for.
@test "a password containing backticks and command substitution survives the merge byte for byte" {
    printf '%s' 'x`id`$(id)${HOME}$USER$((1+1))' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

@test "a password of shell metacharacters survives the merge byte for byte" {
    printf '%s' 'a|b;c&d>e<f*g?h[i]j!k~l#m' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

# lib/config.py builds every message with %-formatting. A value that reached a
# format string rather than an argument would raise, mangle, or -- worst of
# the three -- print. None of those may happen.
@test "a password of printf format specifiers survives the merge byte for byte" {
    printf '%s' '%s %d %% %n %045d %(x)s' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

@test "a password containing a real newline survives the merge byte for byte" {
    printf 'first line\nsecond line\nthird' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

# A value that already ends in a newline is where "strip exactly one" earns
# its keep: secret_survives appends one, and both must not come off.
@test "a password ending in a newline survives the merge byte for byte" {
    printf 'ends with a newline\n' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

# A carriage return in the middle of a value is just a byte, and gets no
# commentary: the warning below is about a file's LINE ENDINGS.
@test "a password containing a carriage return survives the merge byte for byte" {
    printf 'before\rafter' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
    refute_contains 'carriage return' "$output" 'the merge output'
}

# A trailing carriage return is what a CRLF password file produces. The merge
# REPORTS it and uses the value exactly as it is: trimming it would be an
# escaping step, and this file has none. The warning describes the file's line
# endings and never the value.
@test "a password ending in a carriage return is reported and used unrepaired" {
    printf 'from a CRLF file\r' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
    assert_contains 'carriage return' "$output" 'the merge output'
    refute_contains 'from a CRLF file' "$output" 'the warning'
}

@test "a password of accented Latin, CJK and an emoji survives the merge byte for byte" {
    printf '%s' 'héllo Ωmega 漢字テスト 🐝🔑 ćčžšđ' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

@test "a password whose ends are spaces and tabs survives the merge byte for byte" {
    printf '%s' '   leading and trailing	' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

@test "a password of YAML and JSON structure markers survives the merge byte for byte" {
    printf '%s' '{"k": [1,2]} --- #c &a *b !!str >- |+ %YAML @x `y' > "$TMP/want.bin"
    secret_survives "$TMP/want.bin"
}

# Length is its own failure mode: a buffer, a line-oriented read and an argv
# limit all TRUNCATE rather than corrupt, and truncation is silent.
@test "a four-kibibyte password of hostile punctuation survives the merge byte for byte" {
    local unit='X\n$(id)`w`"'"'"'%s;|&<>' i
    : > "$TMP/want.bin"
    for ((i = 0; i < 256; i++)); do
        printf '%s' "$unit" >> "$TMP/want.bin"
    done
    # The fixture really is the size this test claims to be about.
    (( $(wc -c < "$TMP/want.bin") > 4096 ))
    secret_survives "$TMP/want.bin"
}

# Not byte identity but its neighbour: bytes that are not text at all are
# REFUSED. Decoding with errors="replace" would install a different password
# just as quietly as the defect this file exists for.
@test "a password that is not valid UTF-8 is refused rather than repaired" {
    printf '\xff\xfe\x41\x42\n' > "$TMP/stdin.bin"
    config_merge --secret-stdin tpot_web_password < "$TMP/stdin.bin"
    assert_rc 10
    assert_contains 'not valid UTF-8' "$output" 'the refusal'
}

@test "an empty password is refused rather than installed" {
    printf '\n' > "$TMP/stdin.bin"
    config_merge --secret-stdin tpot_web_password < "$TMP/stdin.bin"
    assert_rc 10
    assert_contains 'is empty' "$output" 'the refusal'
}

# ---------------------------------------------------------------------------
# BYTE IDENTITY -- the other three channels.
#
# ioc_sensor_id carries these: a plain string with no pattern, so a value is
# never refused for its shape and the only question is whether it came back
# unchanged. It is not secret, so it is also readable in the public document,
# which is asserted too -- that document is written by a SECOND json.dump and
# could in principle differ from the first.
# ---------------------------------------------------------------------------

@test "every hostile value survives the --set channel byte for byte" {
    write_corpus "$TMP/corpus"
    local file value
    for file in "$TMP/corpus"/*; do
        read_exact value "$file"
        config_merge "${PW_OPTIONAL[@]}" --set "ioc_sensor_id=$value"
        assert_rc 0
        json_bytes "$TMP/merged.json" ioc_sensor_id "$TMP/got.bin"
        assert_bytes_identical "$file" "$TMP/got.bin" "--set, $(basename "$file")"
        json_bytes "$TMP/public.json" ioc_sensor_id "$TMP/got-public.bin"
        assert_bytes_identical "$file" "$TMP/got-public.bin" "public.json, $(basename "$file")"
    done
}

@test "every hostile value survives the environment channel byte for byte" {
    write_corpus "$TMP/corpus"
    local file value
    for file in "$TMP/corpus"/*; do
        read_exact value "$file"
        MERGE_ENV=(IOC_SENSOR_ID="$value")
        config_merge "${PW_OPTIONAL[@]}"
        assert_rc 0
        json_bytes "$TMP/merged.json" ioc_sensor_id "$TMP/got.bin"
        assert_bytes_identical "$file" "$TMP/got.bin" "the environment, $(basename "$file")"
    done
}

# The answer file is the channel the old tool got wrong, so the fixture is
# written the way an operator's file is -- as a document a serialiser produced
# -- and read back through whichever parser this box has.
#
# THE FIXTURE IS WRITTEN AS LITERAL UTF-8, ensure_ascii=False, AND THAT IS NOT
# COSMETIC. Found 2026-09-04, and still true: an answer file that escapes a
# character outside the basic plane as a JSON surrogate PAIR -- exactly what
# Python's json.dump writes by default, and what `jq -a` writes -- crashes the
# merge. PyYAML decodes 🐝 as two lone surrogates rather than one
# emoji, and json.dump then cannot encode them:
#
#     config: internal error: UnicodeEncodeError at __init__.py:180
#     exit 40, and a truncated merged.json left behind
#
# That is a defect in lib/config.py -- the operator is told to file an issue
# about their own file's encoding -- and it belongs to whoever fixes it, not
# to this fixture. Do not "simplify" the line below back to the default and
# assume the resulting exit 40 is something you broke.
@test "every hostile value survives an answer file byte for byte" {
    write_corpus "$TMP/corpus"
    local file
    for file in "$TMP/corpus"/*; do
        python3 - "$file" "$TMP/answers.json" <<'PY'
import json, sys
with open(sys.argv[1], "rb") as handle:
    value = handle.read().decode("utf-8")
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump({"ioc_sensor_id": value}, handle, ensure_ascii=False)
PY
        config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
        assert_rc 0
        json_bytes "$TMP/merged.json" ioc_sensor_id "$TMP/got.bin"
        assert_bytes_identical "$file" "$TMP/got.bin" "an answer file, $(basename "$file")"
    done
}

# The escaped form of the same thing, within the basic plane, where both
# parsers agree. é and \t are decoded by the reader, not passed through,
# so what comes out is the character and not the six bytes that spelt it.
@test "an answer file's own escape sequences are decoded, not passed through" {
    printf '{"ioc_sensor_id": "caf\\u00e9\\tstop\\u0021"}\n' > "$TMP/answers.json"
    printf 'café\tstop!' > "$TMP/want.bin"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
    assert_rc 0
    json_bytes "$TMP/merged.json" ioc_sensor_id "$TMP/got.bin"
    assert_bytes_identical "$TMP/want.bin" "$TMP/got.bin" 'the decoded value'
}

# ---------------------------------------------------------------------------
# PRECEDENCE
#
# The order lib/config.py implements, lowest first:
#     built-in default  <  answer file  <  environment  <  flag
# and within the two levels that can appear more than once, a later one wins.
#
# The answer files below are JSON rather than YAML so that the same fixture
# works on a box with PyYAML and on one without: with it, the YAML parser
# reads JSON, which is a subset; without it, lib/config.py routes a .json file
# to the JSON parser. Tests whose SUBJECT is a YAML behaviour say so and skip.
# ---------------------------------------------------------------------------

@test "a value nobody supplied comes from the built-in default" {
    config_merge "${PW_OPTIONAL[@]}"
    assert_rc 0
    assert_eq 'honeypot' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
    run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tpot_os_user"]["source"])' \
        "$TMP/sources.json"
    assert_eq 'default' "$output" 'the recorded source'
}

@test "an answer file beats the built-in default" {
    printf '{"tpot_os_user": "fromfile"}\n' > "$TMP/answers.json"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
    assert_rc 0
    assert_eq 'fromfile' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
}

@test "the environment beats an answer file" {
    printf '{"tpot_os_user": "fromfile"}\n' > "$TMP/answers.json"
    MERGE_ENV=(TPOT_OS_USER=fromenv)
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
    assert_rc 0
    assert_eq 'fromenv' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
}

@test "a flag beats both the environment and an answer file" {
    printf '{"tpot_os_user": "fromfile"}\n' > "$TMP/answers.json"
    MERGE_ENV=(TPOT_OS_USER=fromenv)
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json" --set tpot_os_user=fromflag
    assert_rc 0
    assert_eq 'fromflag' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
}

@test "a later --config beats an earlier one" {
    printf '{"tpot_os_user": "first", "tpot_timezone": "Pacific/Auckland"}\n' > "$TMP/one.json"
    printf '{"tpot_os_user": "second"}\n' > "$TMP/two.json"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/one.json" --config "$TMP/two.json"
    assert_rc 0
    assert_eq 'second' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
    # A later file overrides key by key. It does not replace the earlier file,
    # which is what makes a small "just this box" file on top of a site-wide
    # one work at all.
    assert_eq 'Pacific/Auckland' "$(json_text "$TMP/merged.json" tpot_timezone)" 'tpot_timezone'
}

@test "a later --set beats an earlier one" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_os_user=first --set tpot_os_user=second
    assert_rc 0
    assert_eq 'second' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
}

@test "--no-env removes the environment from the merge entirely" {
    MERGE_ENV=(TPOT_OS_USER=fromenv)
    config_merge "${PW_OPTIONAL[@]}" --no-env
    assert_rc 0
    assert_eq 'honeypot' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
}

# The environment name is the variable name uppercased, with no lookup table
# to drift, so a misspelling is a variable this installer does not have. It is
# a refusal rather than a shrug: an install that quietly ignored a setting is
# worse than one that would not start.
@test "an unknown TPOT_ variable in the environment is a usage error" {
    MERGE_ENV=(TPOT_OS_USR=typo)
    config_merge "${PW_OPTIONAL[@]}"
    assert_rc 10
    assert_contains 'TPOT_OS_USR is not a variable' "$output" 'the refusal'
}

# TPOT_BRANCH and TPOT_REPO_URL belong to upstream T-Pot's own installer, and
# a box where somebody has run upstream by hand may well have them exported.
# Ignoring them with a word is right; failing on them would make this
# installer refuse to run on the machines most likely to want it.
@test "an environment variable that belongs to upstream is ignored with a warning" {
    MERGE_ENV=(TPOT_BRANCH=master TPOT_REPO_URL=https://example.test/x)
    config_merge "${PW_OPTIONAL[@]}"
    assert_rc 0
    assert_contains 'TPOT_BRANCH belongs to upstream T-Pot' "$output" 'the warning'
    assert_contains 'TPOT_REPO_URL belongs to upstream T-Pot' "$output" 'the warning'
}

# The three directory settings are resolved by lib/args.sh at parse time,
# because the transcript is opened before any of this runs. Reading one from
# the environment later would name a directory the log is already not in.
@test "a variable the schema marks env:false is refused from the environment" {
    MERGE_ENV=(TPOT_LOG_DIR=/tmp/elsewhere)
    config_merge "${PW_OPTIONAL[@]}"
    assert_rc 10
    assert_contains 'is not read from the environment' "$output" 'the refusal'
    assert_contains '--log-dir' "$output" 'the refusal'
}

# ---------------------------------------------------------------------------
# sources.json -- which channel supplied each key
# ---------------------------------------------------------------------------

@test "sources.json records the channel and the detail for every key" {
    printf '{"tpot_timezone": "Pacific/Auckland"}\n' > "$TMP/answers.json"
    MERGE_ENV=(TPOT_OS_UPGRADE=full)
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json" --set tpot_install_type=t
    assert_rc 0
    run python3 - "$TMP/sources.json" "$TMP/answers.json" <<'PY'
import json, sys
sources = json.load(open(sys.argv[1], encoding="utf-8"))
want = {
    "tpot_os_user":      ("default", None),
    "tpot_timezone":     ("config-file", sys.argv[2]),
    "tpot_os_upgrade":   ("env", "TPOT_OS_UPGRADE"),
    "tpot_install_type": ("flag", "--set"),
    "tpot_web_user":     ("derived", "tpot_os_user"),
}
for name, (source, detail) in sorted(want.items()):
    entry = sources.get(name)
    if entry is None:
        raise SystemExit("%s: absent from sources.json" % name)
    if entry.get("source") != source:
        raise SystemExit("%s: source is %r, wanted %r" % (name, entry.get("source"), source))
    if detail is not None and entry.get("detail") != detail:
        raise SystemExit("%s: detail is %r, wanted %r" % (name, entry.get("detail"), detail))
print("ok")
PY
    assert_rc 0
    assert_eq 'ok' "$output" 'the provenance check'
}

# ---------------------------------------------------------------------------
# public.json -- the merged document with the secret-typed keys REMOVED
#
# lib/result.sh depends on exactly this difference: a key that sources.json
# knows about and public.json does not is a SUPPLIED SECRET, and it writes
# {"secret": true, "supplied": true} for it, with no value member and no value
# available to put in one even by mistake. Blanking a secret instead of
# removing it, or leaving it out of sources.json, would make result.json claim
# that a password nobody typed was typed -- or the reverse.
# ---------------------------------------------------------------------------

@test "a supplied secret is in the private document, absent from the public one, and named in sources.json" {
    printf 'chosen-by-the-operator\n' > "$TMP/stdin.bin"
    config_merge --secret-stdin tpot_web_password < "$TMP/stdin.bin"
    assert_rc 0
    run python3 - "$TMP/merged.json" "$TMP/public.json" "$TMP/sources.json" <<'PY'
import json, sys
merged, public, sources = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:4])
assert "tpot_web_password" in merged, "the private document lost the secret"
assert "tpot_web_password" not in public, "the public document carries the secret"
assert "tpot_web_password" in sources, "sources.json does not record that it was supplied"
print(sources["tpot_web_password"]["source"])
PY
    assert_rc 0
    assert_eq 'flag' "$output" 'the recorded source'
    # And the value must appear nowhere in either readable document, under any
    # key and in no detail field.
    refute_contains 'chosen-by-the-operator' "$(cat "$TMP/public.json")" 'public.json'
    refute_contains 'chosen-by-the-operator' "$(cat "$TMP/sources.json")" 'sources.json'
}

# The other half of the same distinction: a secret nobody supplied is absent
# from all three documents, so result.json cannot report it as supplied.
@test "a secret nobody supplied is absent from all three documents" {
    config_merge "${PW_OPTIONAL[@]}"
    assert_rc 0
    run python3 - "$TMP/merged.json" "$TMP/public.json" "$TMP/sources.json" <<'PY'
import json, sys
for path in sys.argv[1:4]:
    document = json.load(open(path, encoding="utf-8"))
    for name in ("tpot_web_password", "ioc_auth_header_value", "tpot_os_user_password"):
        assert name not in document, "%s: %s is present" % (path, name)
print("ok")
PY
    assert_rc 0
    assert_eq 'ok' "$output" 'the absence check'
}

@test "the public document is the private one minus the secret keys, in the same order" {
    printf 'a-password\n' > "$TMP/stdin.bin"
    config_merge --secret-stdin tpot_web_password --set ioc_sensor_id=sensor-7 \
        < "$TMP/stdin.bin"
    assert_rc 0
    run python3 - "$TMP/merged.json" "$TMP/public.json" "$LIB/varschema.json" <<'PY'
import json, sys
merged, public, schema = (json.load(open(p, encoding="utf-8")) for p in sys.argv[1:4])
secret = {key["name"] for key in schema["keys"] if key.get("secret")}
expected = [(k, v) for k, v in merged.items() if k not in secret]
if list(public.items()) != expected:
    raise SystemExit("public.json is not the private document minus the secret keys")
print("ok")
PY
    assert_rc 0
    assert_eq 'ok' "$output" 'the public/private comparison'
}

# ---------------------------------------------------------------------------
# The answer-file rules. Each is a refusal, and each has a reason.
# ---------------------------------------------------------------------------

# An answer file holds the whole configuration. Inside the tree it is one
# `git add .` away from being published -- which is how an inventory file
# became a credential store in the installer this replaces.
#
# The rule is measured against --repo-dir, so this builds its own "repository"
# in the scratch directory. Putting a file into the real tree to test this
# would be a unit suite editing the thing it is testing.
@test "an answer file inside the repository tree is refused" {
    mkdir -p "$TMP/fakerepo/inventories"
    printf '{"tpot_os_user": "x"}\n' > "$TMP/fakerepo/inventories/answers.json"
    MERGE_REPO_DIR="$TMP/fakerepo"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/fakerepo/inventories/answers.json"
    assert_rc 10
    assert_contains 'is inside the repository tree' "$output" 'the refusal'
}

# The same rule against the REAL tree, using a file that is already there and
# is a perfectly valid answer file: the shipped example. It is refused because
# of where it is, which is why the documentation says to copy it out first.
@test "the shipped example answer file is refused while it is still in the tree" {
    config_merge "${PW_OPTIONAL[@]}" --config "$REPO/examples/tpot.example.json"
    assert_rc 10
    assert_contains 'is inside the repository tree' "$output" 'the refusal'
}

# The rule is about where the file RESOLVES, not about what was typed: a
# symlink from outside the tree to a file inside it is the same file.
@test "an answer file whose symlink resolves inside the repository tree is refused" {
    mkdir -p "$TMP/fakerepo" "$TMP/outside"
    printf '{"tpot_os_user": "x"}\n' > "$TMP/fakerepo/real.json"
    ln -s "$TMP/fakerepo/real.json" "$TMP/outside/link.json"
    MERGE_REPO_DIR="$TMP/fakerepo"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/outside/link.json"
    assert_rc 10
    assert_contains 'is inside the repository tree' "$output" 'the refusal'
}

# A file that supplies a secret must be root-owned and 0600 or 0400. This box
# is unprivileged, so what is proved here is the refusal -- the outcome for
# every file this suite is able to create.
@test "an answer file that supplies a secret and is not root-owned is refused" {
    printf '{"tpot_web_password": "s3cr3t"}\n' > "$TMP/answers.json"
    chmod 0600 "$TMP/answers.json"
    config_merge --config "$TMP/answers.json"
    assert_rc 10
    assert_contains 'must be owned by root and mode 0600 or 0400' "$output" 'the refusal'
    # The refusal names the file, the uid and the mode, and never the value.
    refute_contains 's3cr3t' "$output" 'the refusal'
}

@test "an answer file that supplies a secret at mode 0644 is refused" {
    printf '{"tpot_web_password": "s3cr3t"}\n' > "$TMP/answers.json"
    chmod 0644 "$TMP/answers.json"
    config_merge --config "$TMP/answers.json"
    assert_rc 10
    assert_contains 'must be owned by root and mode 0600 or 0400' "$output" 'the refusal'
}

# The permission rule applies to files that SUPPLY A SECRET and to no others.
# A world-readable file of ports and timeouts is not a credential store, and
# demanding 0600 for one would train people to chmod everything.
@test "an answer file that supplies no secret is read at mode 0644" {
    printf '{"tpot_os_user": "nosecrethere"}\n' > "$TMP/answers.json"
    chmod 0644 "$TMP/answers.json"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
    assert_rc 0
    assert_eq 'nosecrethere' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
}

@test "an answer file supplying a secret is accepted when root owns it at 0600" {
    skip_unless "root, to create a root-owned answer file" test "$(id -u)" = 0
    printf '{"tpot_web_password": "s3cr3t"}\n' > "$TMP/answers.json"
    chmod 0600 "$TMP/answers.json"
    config_merge --config "$TMP/answers.json"
    assert_rc 0
}

@test "a key the schema does not define is a usage error naming the file" {
    printf '{"tpot_os_user": "fine", "tpot_no_such_key": 1}\n' > "$TMP/answers.json"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
    assert_rc 10
    assert_contains "unknown key 'tpot_no_such_key'" "$output" 'the refusal'
    assert_contains "$TMP/answers.json" "$output" 'the refusal'
}

# A YAML answer file additionally carries the line, which is the difference
# between "somewhere in this file" and a place to put the cursor.
@test "a YAML answer file reports the line an unknown key is on" {
    skip_unless "PyYAML, which is how a .yml answer file is read" have_pyyaml
    printf 'tpot_os_user: fine\ntpot_no_such_key: 1\n' > "$TMP/answers.yml"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.yml"
    assert_rc 10
    assert_contains "unknown key 'tpot_no_such_key' (line 2)" "$output" 'the refusal'
}

# The merge reports every problem of the first class it finds, so somebody
# with three misspelt keys learns about three rather than discovering them one
# run at a time -- and each run of this installer is a long one.
@test "three misspelt keys are all reported in one run" {
    printf '{"tpot_no_a": 1, "tpot_no_b": 2, "tpot_no_c": 3}\n' > "$TMP/answers.json"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
    assert_rc 10
    assert_contains "'tpot_no_a'" "$output" 'the refusal'
    assert_contains "'tpot_no_b'" "$output" 'the refusal'
    assert_contains "'tpot_no_c'" "$output" 'the refusal'
}

# The three flag-only keys: tpot_state_dir, tpot_log_dir and tpot_runtime_dir.
# lib/args.sh resolves all three before the transcript is opened, so a value
# read out of a file afterwards would name a directory the log is already not
# in -- and the message says so rather than just refusing.
@test "a key marked config_file:false cannot be set in an answer file" {
    local name
    for name in tpot_state_dir tpot_log_dir tpot_runtime_dir; do
        printf '{"%s": "/tmp/elsewhere"}\n' "$name" > "$TMP/answers.json"
        config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
        assert_rc 10
        assert_contains "'$name' cannot be set in an answer file" "$output" "the refusal for $name"
    done
}

# Found on 2026-09-04. public.json is a merged document and looks exactly like
# a ready-made answer file, so somebody will copy one and use it as a starting
# point. It carries two of the three flag-only keys, and they are refused --
# that refusal is correct and must not be relaxed, which is why roles/finalize
# FILTERS them out when it writes a document meant to be re-used.
@test "a verbatim copy of public.json is refused as an answer file" {
    config_merge "${PW_OPTIONAL[@]}"
    assert_rc 0
    cp "$TMP/public.json" "$TMP/copied-answers.json"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/copied-answers.json"
    assert_rc 10
    assert_contains 'cannot be set in an answer file' "$output" 'the refusal'
    assert_contains 'tpot_state_dir' "$output" 'the refusal'
    assert_contains 'tpot_log_dir' "$output" 'the refusal'
}

# A key written twice is a file whose author believed two things. Taking the
# later one silently is how a password ends up as the value that was supposed
# to have been replaced.
@test "a key repeated in an answer file is refused, not silently resolved" {
    printf '{"tpot_os_user": "first", "tpot_os_user": "second"}\n' > "$TMP/answers.json"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
    assert_rc 10
    assert_contains 'appears more than once' "$output" 'the refusal'
}

# An answer file with nothing but comments is what
# `install.sh --example-config > /root/tpot.yml` produces before it is edited.
# It sets nothing, and it is not malformed.
@test "an answer file of nothing but comments sets nothing and is not an error" {
    skip_unless "PyYAML, which is how a .yml answer file is read" have_pyyaml
    printf '# tpot_os_user: notthis\n# nothing here\n' > "$TMP/answers.yml"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.yml"
    assert_rc 0
    assert_eq 'honeypot' "$(json_text "$TMP/merged.json" tpot_os_user)" 'tpot_os_user'
}

# ---------------------------------------------------------------------------
# The flag channel's own refusals
# ---------------------------------------------------------------------------

# A command-line argument is world-readable in /proc for the lifetime of the
# process, and an install runs for thirty to ninety minutes.
@test "a secret key cannot be set with --set" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_web_password=hunter2
    assert_rc 10
    assert_contains 'is a secret and cannot be set this way' "$output" 'the refusal'
    assert_contains '--web-password-file' "$output" 'the refusal'
    refute_contains 'hunter2' "$output" 'the refusal'
}

@test "every secret-typed key is refused by --set, not only the dashboard password" {
    local name
    for name in tpot_web_password tpot_os_user_password ioc_auth_header_value; do
        config_merge "${PW_OPTIONAL[@]}" --set "$name=hunter2"
        assert_rc 10
        assert_contains "'$name' is a secret and cannot be set this way" "$output" \
            "the refusal for $name"
        refute_contains 'hunter2' "$output" "the refusal for $name"
    done
}

@test "--password-file refuses a key that is not a secret" {
    printf 'x\n' > "$TMP/value.txt"
    config_merge "${PW_OPTIONAL[@]}" --password-file "tpot_os_user=$TMP/value.txt"
    assert_rc 10
    assert_contains 'is not a secret key' "$output" 'the refusal'
}

# The same two file rules as an answer file, on the channel meant for a
# secret. Unprivileged, the refusals are what can be proved here.
@test "a password file that is not root-owned is refused" {
    printf 'hunter2\n' > "$TMP/pw.txt"
    chmod 0600 "$TMP/pw.txt"
    config_merge --password-file "tpot_web_password=$TMP/pw.txt"
    assert_rc 10
    assert_contains 'must be owned by root and mode 0600 or 0400' "$output" 'the refusal'
    refute_contains 'hunter2' "$output" 'the refusal'
}

@test "a password file inside the repository tree is refused" {
    mkdir -p "$TMP/fakerepo"
    printf 'hunter2\n' > "$TMP/fakerepo/pw.txt"
    MERGE_REPO_DIR="$TMP/fakerepo"
    config_merge --password-file "tpot_web_password=$TMP/fakerepo/pw.txt"
    assert_rc 10
    assert_contains 'is inside the repository tree' "$output" 'the refusal'
    refute_contains 'hunter2' "$output" 'the refusal'
}

# The documented path for an unattended install, and the one this box cannot
# exercise: it needs a file owned by uid 0.
@test "a password file supplies the password byte for byte when root owns it at 0600" {
    skip_unless "root, to create a root-owned password file" test "$(id -u)" = 0
    printf 'p@ss\\nword\n' > "$TMP/pw.txt"
    chmod 0600 "$TMP/pw.txt"
    config_merge --password-file "tpot_web_password=$TMP/pw.txt"
    assert_rc 0
    printf '%s' 'p@ss\nword' > "$TMP/want.bin"
    json_bytes "$TMP/merged.json" tpot_web_password "$TMP/got.bin"
    assert_bytes_identical "$TMP/want.bin" "$TMP/got.bin" 'the dashboard password'
}

@test "the dashboard password being absent names all three ways of supplying it" {
    config_merge
    assert_rc 10
    assert_contains 'tpot_web_password is required and was not supplied' "$output" 'the refusal'
    assert_contains '--web-password-file' "$output" 'the refusal'
    assert_contains 'TPOT_WEB_PASSWORD' "$output" 'the refusal'
    assert_contains '--config' "$output" 'the refusal'
}

# ---------------------------------------------------------------------------
# Type coercion and validation
# ---------------------------------------------------------------------------

@test "an enum refuses a value outside its choices and lists them" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_install_type=zz
    assert_rc 10
    assert_contains 'tpot_install_type: wanted one of h s l i m t' "$output" 'the refusal'
}

@test "an integer key refuses a value that is not a whole number" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_min_cpus=two
    assert_rc 10
    assert_contains 'tpot_min_cpus: wanted a whole number' "$output" 'the refusal'
}

@test "an integer key refuses a value below its minimum" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_max_map_count=100
    assert_rc 10
    assert_contains 'is below the minimum of 65530' "$output" 'the refusal'
}

@test "an integer key refuses a value above its maximum" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_dashboard_port=70000
    assert_rc 10
    assert_contains 'is above the maximum of 65535' "$output" 'the refusal'
}

@test "an integer key accepts a value at each end of its range" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_dashboard_port=1
    assert_rc 0
    config_merge "${PW_OPTIONAL[@]}" --set tpot_dashboard_port=65535
    assert_rc 0
}

# YAML 1.1 reads a bare off, no, yes or on as a BOOLEAN, so an enum whose
# choices are the words "off" and "on" is a trap the schema warns about in
# prose. The refusal has to say what to do about it: "found a boolean" alone
# leaves somebody staring at a line that looks perfectly correct.
@test "a bare YAML off is a boolean and is refused with the quoting hint" {
    skip_unless "PyYAML, which is how a .yml answer file is read" have_pyyaml
    printf 'tpot_upstream_telemetry: off\n' > "$TMP/answers.yml"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.yml"
    assert_rc 10
    assert_contains 'found a boolean, wanted text' "$output" 'the refusal'
    assert_contains 'quote the value' "$output" 'the refusal'
}

@test "a quoted off is text and is accepted" {
    printf '{"tpot_upstream_telemetry": "off"}\n' > "$TMP/answers.json"
    config_merge "${PW_OPTIONAL[@]}" --config "$TMP/answers.json"
    assert_rc 0
    assert_eq 'off' "$(json_text "$TMP/merged.json" tpot_upstream_telemetry)" 'the telemetry setting'
}

@test "a boolean is accepted in every documented spelling" {
    local word
    for word in true yes on 1; do
        config_merge "${PW_OPTIONAL[@]}" --set "tpot_install_deps=$word"
        assert_rc 0
        run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tpot_install_deps"])' \
            "$TMP/merged.json"
        assert_eq 'True' "$output" "tpot_install_deps from '$word'"
    done
    for word in false no off 0; do
        config_merge "${PW_OPTIONAL[@]}" --set "tpot_install_deps=$word"
        assert_rc 0
        run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tpot_install_deps"])' \
            "$TMP/merged.json"
        assert_eq 'False' "$output" "tpot_install_deps from '$word'"
    done
}

@test "a boolean refuses a word that is not one of the accepted spellings" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_install_deps=maybe
    assert_rc 10
    assert_contains 'wanted a boolean' "$output" 'the refusal'
}

@test "a list is accepted as a comma-separated string and as a JSON array alike" {
    config_merge "${PW_OPTIONAL[@]}" --set 'tpot_required_ports=22,64295'
    assert_rc 0
    run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tpot_required_ports"])' \
        "$TMP/merged.json"
    assert_eq '[22, 64295]' "$output" 'tpot_required_ports'
    config_merge "${PW_OPTIONAL[@]}" --set 'tpot_required_ports=[22, 64295]'
    assert_rc 0
    run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tpot_required_ports"])' \
        "$TMP/merged.json"
    assert_eq '[22, 64295]' "$output" 'tpot_required_ports'
}

@test "a list of integers refuses an entry that is not a whole number" {
    config_merge "${PW_OPTIONAL[@]}" --set 'tpot_required_ports=22,http'
    assert_rc 10
    assert_contains 'wanted a list of whole numbers' "$output" 'the refusal'
}

# ---------------------------------------------------------------------------
# tpot_upstream_ref -- the pattern with the most expensive failure behind it.
#
# ansible.builtin.git accepts an ABBREVIATED sha and leaves HEAD at the full
# one, so upstream's own re-run check then compares seven characters against
# forty and exits 1 on every second run. No generic "is not in the form this
# variable requires" could ever lead somebody to that, which is why this key
# carries a pattern_help sentence and why the refusal must quote it.
# ---------------------------------------------------------------------------

@test "tpot_upstream_ref accepts a full forty-character lowercase sha" {
    config_merge "${PW_OPTIONAL[@]}" \
        --set tpot_upstream_ref=0123456789abcdef0123456789abcdef01234567
    assert_rc 0
    assert_eq '0123456789abcdef0123456789abcdef01234567' \
        "$(json_text "$TMP/merged.json" tpot_upstream_ref)" 'the pinned ref'
}

@test "tpot_upstream_ref refuses a tag, a branch, an abbreviated sha and an uppercase sha" {
    local bad
    for bad in 24.04.1 v1.2.3 master main 0123456 0123456789abcdef \
               0123456789ABCDEF0123456789ABCDEF01234567 \
               0123456789abcdef0123456789abcdef012345678 \
               ' 0123456789abcdef0123456789abcdef01234567'; do
        config_merge "${PW_OPTIONAL[@]}" --set "tpot_upstream_ref=$bad"
        assert_rc 10
        assert_contains 'tpot_upstream_ref:' "$output" "the refusal for '$bad'"
    done
}

# The message a person reads has to be the sentence written for them, not the
# regex. A regex tells somebody their input is wrong and nothing whatever
# about what would be right.
@test "the refusal for tpot_upstream_ref quotes its pattern_help, never the regex" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_upstream_ref=24.04.1
    assert_rc 10
    assert_contains 'not a tag, not a branch, not an abbreviated sha' "$output" 'the refusal'
    assert_contains 'tools/pin-upstream.sh' "$output" 'the refusal'
    refute_contains '[0-9a-f]{40}' "$output" 'the refusal'
    refute_contains '^[0-9a-f]' "$output" 'the refusal'
}

# The URL is DERIVED from the ref, which is what keeps upstream's entrypoint
# and upstream's payload on one commit. Deriving is a channel of its own in
# sources.json, so the record shows the operator did not choose it.
@test "the upstream URL is derived from the ref and recorded as derived" {
    config_merge "${PW_OPTIONAL[@]}" \
        --set tpot_upstream_ref=0123456789abcdef0123456789abcdef01234567
    assert_rc 0
    assert_contains '0123456789abcdef0123456789abcdef01234567' \
        "$(json_text "$TMP/merged.json" tpot_upstream_url)" 'the upstream URL'
    run python3 -c \
        'import json,sys; print(json.load(open(sys.argv[1]))["tpot_upstream_url"]["source"])' \
        "$TMP/sources.json"
    assert_eq 'derived' "$output" 'the recorded source'
}

# A key with no default and nothing supplied is OMITTED, never written as
# null. The distinction is load-bearing: the Ansible side asks `is defined`
# for exactly these keys, so that a per-release data file can supply what this
# installer does not know.
@test "a key with no default and no supplied value is omitted, not written as null" {
    config_merge "${PW_OPTIONAL[@]}"
    assert_rc 0
    run python3 - "$TMP/merged.json" <<'PY'
import json, sys
merged = json.load(open(sys.argv[1], encoding="utf-8"))
for name in ("tpot_upstream_ref", "tpot_upstream_checksum", "tpot_min_containers"):
    assert name not in merged, "%s was written as %r" % (name, merged[name])
print("ok")
PY
    assert_rc 0
    assert_eq 'ok' "$output" 'the omission check'
}

# `null` is the documented way of saying "leave this alone", and it means the
# key is unset rather than set to the four letters. On the one required key
# that comes out as a REFUSAL, which is the safe outcome: an operator whose
# password really is the word null is told the installer has no password
# rather than being given a working install with a different one.
@test "the word null on the secret channel means absent, and is refused rather than installed" {
    printf 'null\n' > "$TMP/stdin.bin"
    config_merge --secret-stdin tpot_web_password < "$TMP/stdin.bin"
    assert_rc 10
    assert_contains 'tpot_web_password is required and was not supplied' "$output" 'the refusal'
}

# ---------------------------------------------------------------------------
# The written documents themselves
# ---------------------------------------------------------------------------

# merged.json holds every secret in clear text. It is created at 0600 before a
# byte is written -- not written and then chmodded, which leaves a window in
# which it is readable.
@test "all three documents are created mode 0600" {
    printf 'a-password\n' > "$TMP/stdin.bin"
    config_merge --secret-stdin tpot_web_password < "$TMP/stdin.bin"
    assert_rc 0
    local path
    for path in merged.json public.json sources.json; do
        run stat -c '%a' "$TMP/$path"
        assert_eq '600' "$output" "the mode of $path"
    done
}

# A merge that refuses its input must not leave a half-written document behind
# for the next step to read as though it were complete.
@test "a merge that refuses its input writes nothing" {
    config_merge "${PW_OPTIONAL[@]}" --set tpot_install_type=zz
    assert_rc 10
    local path
    for path in merged.json public.json sources.json; do
        if [[ -e $TMP/$path ]]; then
            printf '%s exists after a merge that refused its input\n' "$path" >&2
            return 1
        fi
    done
}

# lib/config.py never prints a supplied value on any path -- not in an error
# message, not in a diagnostic, not even when the problem IS the value's
# format. This runs a merge in which every channel carries the same sentinel
# and requires it to appear nowhere in the output. Two of the four refusals
# are ABOUT the value, which is exactly when a message is most tempted to
# quote it.
@test "no channel's value is ever echoed in the merge's own output" {
    local sentinel='SENTINEL-e6a1c9-NEVER-PRINT'
    printf '{"tpot_os_user": "%s"}\n' "$sentinel" > "$TMP/answers.json"
    MERGE_ENV=(IOC_SENSOR_ID="$sentinel")
    printf '%s\n' "$sentinel" > "$TMP/stdin.bin"
    config_merge --config "$TMP/answers.json" --set "ioc_endpoint_url=$sentinel" \
        --secret-stdin tpot_web_password < "$TMP/stdin.bin"
    assert_rc 10
    refute_contains "$sentinel" "$output" 'the merge output'
}
