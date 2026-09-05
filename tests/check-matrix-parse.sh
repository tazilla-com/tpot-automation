#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# tests/check-matrix-parse.sh -- the two readers of support-matrix.yml agree,
# tier by tier, and the tiers mean what they say.
#
# WHAT IT ASSERTS
#   1. The bash reader in lib/matrix.sh reads BOTH tiers of both matrix files:
#      every row well-formed, no duplicates within a tier, and each tier's key
#      present. A tier declared `[]` is empty and valid; a tier whose key is
#      absent is a malformed file and must be refused.
#   2. The shipped support-matrix.yml is HONEST about its pin: the supported
#      tier and the ref it was derived from are empty together, or populated
#      together, and never one without the other. That invariant is the whole of
#      D-07 expressed as a check -- a supported tier with no pin behind it is a
#      claim with no evidence under it. The file is pinned today (D-11), so the
#      populated half is the one now exercised against it.
#   3. A REAL YAML PARSER, reading the same file, produces the byte-identical
#      list for each tier, in the same order. That is the point: preflight
#      stage A greps this file before Ansible exists on the box, and the
#      Ansible preflight role loads it with include_vars an hour later. If the
#      two ever disagree, a box is one tier to one half of the run and another
#      tier to the other, and the flat-string format is what keeps them honest.
#   4. MEMBERSHIP IS AN EXACT-ELEMENT COMPARISON, proven by execution against
#      every shape that would slip past a sloppier test -- a partial token, a
#      value spanning two rows, a shell glob. The idiom upstream uses for this
#      same job is run beside it as a NEGATIVE CONTROL, on upstream's own data,
#      so the difference is measured here rather than asserted in a comment.
#   5. Every fixture in tests/os-release/ resolves the way
#      tests/os-release/expected.tsv says it must -- id, VERSION_ID, and then
#      tier and row against BOTH matrix files.
#   6. Tier precedence: a release listed in both tiers resolves as supported.
#
# THE SECOND MATRIX FILE, AND WHY THERE IS STILL ONE
#   It was written when support-matrix.yml had an EMPTY supported tier, so that
#   the supported half of the reader was exercised at all.
#
#   D-11 pinned a commit on 2026-09-04 and the shipped file now carries two
#   supported rows, so it exercises that half by itself. The pinned example is
#   KEPT because agreeing is a fact worth checking rather than assuming: it
#   carries a ref this project will never pin and a tier written by hand, so
#   running every assertion against both proves the reader gives the same answer
#   for a matrix it has never seen as for the one it ships with.
#
#   NEITHER FILE IS A CLAIM THAT ANYTHING WAS INSTALLED. Exactly one release
#   has been installed by anyone here -- debian 13, at ref fdafa483, on
#   2026-09-05 -- and that evidence lives in tests/MATRIX-STATUS.md, not in
#   either of these files. Parsing a row correctly says nothing about having
#   run it.
#
# HOW IT PICKS ITS REFERENCE READER, AND WHY IT SAYS WHICH
#   ansible-playbook, when it is on PATH, is the real consumer: the playbook
#   below does exactly what roles/preflight does, include_vars and all. python3
#   with PyYAML is the fallback, and it is genuinely a different parser rather
#   than a restatement of the bash one. Both run when both are available.
#   THE MODE IS PRINTED, always: a test that quietly degraded to checking less
#   than it says it checks is worse than one that did not run.
#
# EXIT
#   0  every assertion passed; the modes that ran are named on stdout
#   1  a real mismatch -- the readers disagree, a file is malformed, a fixture
#      does not resolve as it must, or the membership test accepted something
#      it must reject
#   2  INCONCLUSIVE: no reference YAML parser was available, so assertion 3
#      could not be exercised at all. Deliberately not 0. This project's whole
#      preflight design says an assertion that could not be run is not a pass.
#
# It reads. It writes only inside a temporary directory it creates and removes.

set -euo pipefail
shopt -s inherit_errexit

# WHY THIS HONOURS GATE_SCAN_ROOT, THOUGH IT DOES NOT USE gate-common.sh
#   This gate carries its own harness -- it makes hundreds of individual
#   assertions rather than reporting findings against file:line, so the shared
#   one does not fit. But tests/run-gates.sh --self-test proves a gate can FAIL
#   by pointing GATE_SCAN_ROOT at a deliberately violating tree, and a gate that
#   resolves its own inputs from $0 ignores that entirely: it re-runs against
#   the real repository and passes, and the runner reports it UNPROVEN.
#
#   That is exactly what happened here. This file was the one gate the
#   self-test could not prove, and the reason was recorded as "no negative
#   fixture is registered for it" -- which was true, and was the SYMPTOM. The
#   cause was that no fixture could have worked, because nothing this gate read
#   could be redirected. Honouring the variable is the whole fix; the fixture
#   in run-gates.sh then does what it does for every other gate.
#
#   lib/matrix.sh is read from the scan root too, so the fixture must copy it.
#   That is deliberate rather than convenient: the reader and the data it reads
#   are one unit, and a self-test that ran the CURRENT reader against OLD data
#   would be proving something nobody ships.
REPO_DIR=${GATE_SCAN_ROOT:-$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)}
readonly REPO_DIR
readonly FIXTURE_DIR="${REPO_DIR}/tests/os-release"
readonly MANIFEST="${FIXTURE_DIR}/expected.tsv"

# The two matrix files, and what each one is for. The first is the product's;
# the second exists so the supported tier is exercised at all.
readonly MATRIX_SHIPPED="${REPO_DIR}/support-matrix.yml"
readonly MATRIX_PINNED="${FIXTURE_DIR}/support-matrix.pinned-example.yml"

# shellcheck source=../lib/matrix.sh
. "${REPO_DIR}/lib/matrix.sh"

FAILURES=0
MODES=()
COMPARED=0

TMPDIR_RUN=$(mktemp -d "${TMPDIR:-/tmp}/check-matrix-parse.XXXXXXXX")
readonly TMPDIR_RUN
cleanup() { rm -rf -- "$TMPDIR_RUN"; }
trap cleanup EXIT

pass() { printf 'ok    %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*" >&2; FAILURES=$(( FAILURES + 1 )); }
info() { printf '      %s\n' "$*"; }
head2() { printf '\n== %s\n' "$*"; }

# Split one tab-separated line into fields, one per line of output. Written out
# with parameter expansion rather than `read -ra` because tests/check-no-tty.sh
# fails the build on `read` anywhere outside lib/args.sh, and because splitting
# on $IFS would silently collapse two adjacent tabs into one -- which is
# exactly the malformed manifest row this wants to catch, and which the
# debian-testing row legitimately contains.
split_tsv() {
    local rest=${1:-} field
    while [[ $rest == *$'\t'* ]]; do
        field=${rest%%$'\t'*}
        printf '%s\n' "$field"
        rest=${rest#*$'\t'}
    done
    printf '%s\n' "$rest"
}

# A short name for a matrix file, for messages.
label_of() {
    case $1 in
        "$MATRIX_SHIPPED") printf 'shipped\n' ;;
        "$MATRIX_PINNED")  printf 'pinned-example\n' ;;
        *)                 printf '%s\n' "$(basename -- "$1")" ;;
    esac
}

# ===========================================================================
# 1. The bash reader, per file, per tier.
# ===========================================================================
check_bash_reader() {
    local file=$1 label tier out rows n dup
    label=$(label_of "$file")

    if [[ ! -r $file ]]; then
        fail "${label}: ${file} is missing or unreadable"
        return 1
    fi

    for tier in $(matrix_tiers); do
        rows="${TMPDIR_RUN}/bash.${label}.${tier}"
        if ! out=$(matrix_list_tier "$tier" "$file"); then
            fail "${label}/${tier}: the bash reader refused the tier -- key absent, declared twice,"\
                 "or a line under it is not an entry"
            : > "$rows"
            continue
        fi
        if [[ -n $out ]]; then
            printf '%s\n' "$out" > "$rows"
        else
            : > "$rows"
        fi
        n=$(wc -l < "$rows" | tr -d ' ')
        pass "${label}/${tier}: ${n} row(s)"

        local -a tier_rows=()
        if [[ -s $rows ]]; then
            mapfile -t tier_rows < "$rows"
        fi

        local row malformed=0
        for row in "${tier_rows[@]}"; do
            if [[ ! $row =~ ^[a-z][a-z0-9._-]*:[0-9][0-9a-z._-]*$ ]]; then
                fail "${label}/${tier}: row is not <id>:<version>: '${row}'"
                malformed=1
            fi
        done
        if (( malformed == 0 )) && (( ${#tier_rows[@]} > 0 )); then
            pass "${label}/${tier}: every row is <id>:<version>"
        fi

        # Duplicates WITHIN a tier are an error. Duplicates ACROSS tiers are
        # expected -- debian:13 is both -- and are checked for precedence in
        # section 6 instead of being banned here.
        if (( ${#tier_rows[@]} > 0 )); then
            dup=$(printf '%s\n' "${tier_rows[@]}" | sort | uniq -d)
            if [[ -n $dup ]]; then
                local -a dup_rows=()
                mapfile -t dup_rows <<< "$dup"
                local d
                for d in "${dup_rows[@]}"; do
                    fail "${label}/${tier}: duplicate row '${d}'"
                done
            else
                pass "${label}/${tier}: no duplicate rows within the tier"
            fi
        fi
    done

    local summary
    if summary=$(matrix_summary "$file"); then
        pass "${label}: matrix_summary -- ${summary}"
    else
        fail "${label}: matrix_summary produced nothing"
    fi
    return 0
}

head2 "1. the bash reader"
check_bash_reader "$MATRIX_SHIPPED"
check_bash_reader "$MATRIX_PINNED"

# ===========================================================================
# 2. The pin invariant: the supported tier and the ref it came from are empty
#    together or non-empty together.
# ===========================================================================
head2 "2. the pin invariant (D-07)"
check_pin_invariant() {
    local file=$1 label rows ref_present=0 ref=''
    label=$(label_of "$file")
    rows="${TMPDIR_RUN}/bash.${label}.supported"
    if [[ ! -f $rows ]]; then
        fail "${label}: the supported tier was not read, so the invariant cannot be checked"
        return 0
    fi
    if ref=$(matrix_supported_ref "$file"); then
        ref_present=1
    fi
    if [[ -s $rows ]]; then
        if (( ref_present == 1 )); then
            pass "${label}: supported tier is non-empty and names its ref (${ref})"
        else
            fail "${label}: the supported tier claims releases but no upstream ref was derived"\
                 "from -- a claim with no pin behind it"
        fi
    else
        if (( ref_present == 0 )); then
            pass "${label}: supported tier is empty and so is the ref -- honestly unpinned"
        else
            fail "${label}: an upstream ref (${ref}) is recorded but the supported tier is empty"\
                 "-- the pin moved and the tier was not derived again"
        fi
    fi
    return 0
}
check_pin_invariant "$MATRIX_SHIPPED"
check_pin_invariant "$MATRIX_PINNED"

# The shipped file specifically must be the unpinned one. If somebody fills in
# the supported tier by hand this says so loudly, because the CI assert that
# the tier matches the pinned ref's own gate does not exist yet.
if [[ -s "${TMPDIR_RUN}/bash.shipped.supported" ]]; then
    info "NOTE: support-matrix.yml now has a non-empty supported tier."
    info "      CI still owes the assert that every row in it is one the pinned"
    info "      ref's own gate accepts, and that this ref is tpot_upstream_ref."
else
    pass "shipped: nothing is claimed as supported while no ref is pinned"
fi

# ===========================================================================
# 3. Reference readers.
# ===========================================================================
head2 "3. bash reader vs a real YAML parser"

# --- 3a. Ansible, exactly as roles/preflight reads it. ----------------------
#
# The playbook writes the loaded tiers as JSON rather than as lines, because
# join('\n') has to survive both YAML quoting and Jinja string escaping on the
# way in and there is no reason to bet the test on that. JSON is unambiguous
# and python3's standard library turns it back into lines with no YAML support
# needed -- which matters, because this branch must work on a box that has
# ansible but no PyYAML importable by the python3 on PATH.
HAVE_ANSIBLE=0
if command -v ansible-playbook >/dev/null 2>&1; then
    HAVE_ANSIBLE=1
    cat > "${TMPDIR_RUN}/load-matrix.yml" <<'PLAYBOOK'
---
- name: Read the support matrix the way roles/preflight reads it
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Load the matrix file
      ansible.builtin.include_vars:
        file: "{{ matrix_file }}"

    - name: Fail when either tier is absent or is not a list
      ansible.builtin.assert:
        that:
          - tpot_support_matrix_supported is defined
          - tpot_support_matrix_supported is sequence
          - tpot_support_matrix_supported is not string
          - tpot_support_matrix_legacy is defined
          - tpot_support_matrix_legacy is sequence
          - tpot_support_matrix_legacy is not string
          - tpot_support_matrix_supported_ref is defined
          - tpot_support_matrix_supported_ref is string
        fail_msg: >-
          the matrix file must define tpot_support_matrix_supported and
          tpot_support_matrix_legacy as lists, and
          tpot_support_matrix_supported_ref as a string

    - name: Write both tiers and the ref as JSON
      ansible.builtin.copy:
        content: >-
          {{ {'supported': tpot_support_matrix_supported,
              'legacy': tpot_support_matrix_legacy,
              'ref': tpot_support_matrix_supported_ref} | to_json }}
        dest: "{{ out_file }}"
        mode: "0600"
PLAYBOOK
    : > "${TMPDIR_RUN}/empty.cfg"
else
    info "ansible-playbook is not on PATH; skipping the Ansible reader"
fi

HAVE_PYYAML=0
if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    HAVE_PYYAML=1
else
    info "python3 with PyYAML is not available; skipping the python reader"
fi

# Turn one reference reader's JSON into per-tier line files, then diff each
# tier against what the bash reader produced.
compare_reference() {
    local name=$1 file=$2 json=$3 label tier ref_bash ref_json
    label=$(label_of "$file")

    for tier in $(matrix_tiers); do
        local want="${TMPDIR_RUN}/${name}.${label}.${tier}"
        python3 -c 'import json,sys
doc = json.load(open(sys.argv[1], encoding="utf-8"))
rows = doc[sys.argv[2]]
if not isinstance(rows, list):
    raise SystemExit("%s is not a list" % sys.argv[2])
for row in rows:
    if not isinstance(row, str):
        raise SystemExit("%s contains a non-string: %r" % (sys.argv[2], row))
    print(row)
' "$json" "$tier" > "$want"
        COMPARED=$(( COMPARED + 1 ))
        if diff -u "${TMPDIR_RUN}/bash.${label}.${tier}" "$want" > "${TMPDIR_RUN}/diff.${name}.${label}.${tier}"; then
            pass "${label}/${tier}: bash reader == ${name} reader ($(wc -l < "$want" | tr -d ' ') rows, same order)"
        else
            fail "${label}/${tier}: bash reader != ${name} reader"
            sed 's/^/      /' "${TMPDIR_RUN}/diff.${name}.${label}.${tier}" >&2
        fi
    done

    # The ref is read by a hand-written scalar parser too, so it gets the same
    # treatment. matrix_supported_ref returns 1 for an empty ref; the JSON
    # carries "" for the same state.
    ref_json=$(python3 -c 'import json,sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["ref"])' "$json")
    if ! ref_bash=$(matrix_supported_ref "$file"); then
        ref_bash=''
    fi
    if [[ $ref_bash == "$ref_json" ]]; then
        pass "${label}: bash reader == ${name} reader on the ref ('${ref_bash}')"
    else
        fail "${label}: ref disagreement -- bash '${ref_bash}', ${name} '${ref_json}'"
    fi
}

for matrix_file in "$MATRIX_SHIPPED" "$MATRIX_PINNED"; do
    file_label=$(label_of "$matrix_file")

    if (( HAVE_ANSIBLE == 1 )); then
        ansible_out="${TMPDIR_RUN}/ansible.${file_label}.json"
        ansible_log="${TMPDIR_RUN}/ansible.${file_label}.log"
        # A private, empty config and a one-host inventory: the repository's own
        # ansible.cfg points at a generated inventory that does not exist until
        # an install has run, and this test must not depend on that.
        # gate-allow: extra-vars-value both values are FILE PATHS handed to a throwaway playbook under a private temporary directory. The rule keeps CREDENTIALS off argv; a path is not one, and this harness has no secret to leak.
        if ANSIBLE_CONFIG="${TMPDIR_RUN}/empty.cfg" \
           ANSIBLE_LOCALHOST_WARNING=False \
           ANSIBLE_INVENTORY_UNPARSED_WARNING=False \
           ANSIBLE_DEPRECATION_WARNINGS=False \
           ANSIBLE_FORCE_COLOR=0 \
           ansible-playbook \
               -i localhost, \
               -e "matrix_file=${matrix_file}" \
               -e "out_file=${ansible_out}" \
               "${TMPDIR_RUN}/load-matrix.yml" > "$ansible_log" 2>&1
        then
            compare_reference ansible "$matrix_file" "$ansible_out"
        else
            fail "${file_label}: ansible-playbook could not read the matrix; last lines follow"
            tail -20 "$ansible_log" >&2 || true
        fi
    fi

    if (( HAVE_PYYAML == 1 )); then
        python_out="${TMPDIR_RUN}/python.${file_label}.json"
        if python3 -c 'import sys, json, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
if not isinstance(doc, dict):
    raise SystemExit("the matrix file is not a mapping")
out = {}
for tier, key in (("supported", "tpot_support_matrix_supported"),
                  ("legacy", "tpot_support_matrix_legacy")):
    rows = doc.get(key)
    if not isinstance(rows, list):
        raise SystemExit("%s is missing or is not a list" % key)
    for row in rows:
        if not isinstance(row, str):
            raise SystemExit("%s contains a non-string: %r" % (key, row))
    out[tier] = rows
ref = doc.get("tpot_support_matrix_supported_ref")
if not isinstance(ref, str):
    raise SystemExit("tpot_support_matrix_supported_ref is missing or is not a string")
out["ref"] = ref
json.dump(out, open(sys.argv[2], "w", encoding="utf-8"))
' "$matrix_file" "$python_out" 2>"${TMPDIR_RUN}/python.${file_label}.err"
        then
            compare_reference python3 "$matrix_file" "$python_out"
        else
            fail "${file_label}: python3 + PyYAML could not read the matrix:"\
                 "$(cat "${TMPDIR_RUN}/python.${file_label}.err")"
        fi
    fi
done

if (( HAVE_ANSIBLE == 1 )); then
    MODES+=("ansible (include_vars, $(ansible-playbook --version 2>/dev/null | head -1))")
fi
if (( HAVE_PYYAML == 1 )); then
    MODES+=("python3 (PyYAML $(python3 -c 'import yaml; print(yaml.__version__)'))")
fi

# ===========================================================================
# 4. Membership is an exact-element comparison. Proven, not asserted.
# ===========================================================================
head2 "4. exact-element membership"

# --- 4a. The NEGATIVE CONTROL. ---------------------------------------------
#
# THIS IS THE IDIOM WE DO NOT USE. It is upstream's install.sh:298, transcribed
# with upstream's own distribution list, and it is here so that the claim in
# lib/matrix.sh's header is MEASURED on the box the test runs on rather than
# quoted from a document. Nothing in lib/ or in the product may look like this.
#
# It reads as a regex test and is not one: the right-hand side is double
# quoted, so bash compares it literally against the array joined with spaces.
# Anything that is a space-delimited subsequence of that joined string is
# accepted -- including a fragment of one element, and a value spanning two.
upstream_idiom_accepts() {
    local needle=$1
    shift
    local -a arr=("$@")
    [[ " ${arr[@]} " =~ " ${needle} " ]]
}

readonly -a UPSTREAM_NAMES=(
    "AlmaLinux" "Debian GNU/Linux" "Fedora Linux" "openSUSE Tumbleweed"
    "Raspbian GNU/Linux" "Red Hat Enterprise Linux" "Rocky Linux" "Ubuntu"
)

control_ok=1
for needle in "Linux" "GNU/Linux" "Enterprise Linux" "Raspbian GNU/Linux Red Hat"; do
    if upstream_idiom_accepts "$needle" "${UPSTREAM_NAMES[@]}"; then
        info "negative control: the upstream idiom accepts '${needle}' as a distribution name"
    else
        fail "negative control: the upstream idiom REJECTED '${needle}' -- this box's bash does"\
             "not behave as measured, so section 4 proves less than it claims"
        control_ok=0
    fi
done
if upstream_idiom_accepts "Linux Mint" "${UPSTREAM_NAMES[@]}"; then
    fail "negative control: the upstream idiom accepted 'Linux Mint', which contradicts the recorded measurement"
    control_ok=0
fi
if (( control_ok == 1 )); then
    pass "negative control: upstream's idiom accepts 4 strings that are not distributions (bash ${BASH_VERSION})"
fi

# --- 4b. Ours rejects every shape of that, on our own data. -----------------
#
# Each probe is a whole-row lookup that a substring, joined-list or glob
# comparison would accept. matrix_match must reject all of them, against BOTH
# matrix files, and it must still accept the legitimate lookups underneath.
probe_reject() {
    local why=$1 id=$2 ver=$3 file=$4 label out rc=0
    label=$(label_of "$file")
    out=$(matrix_match "$id" "$ver" "$file") || rc=$?
    if (( rc == 0 )); then
        fail "${label}: matrix_match ACCEPTED id='${id}' version='${ver}' as ${out} -- ${why}"
        return 0
    fi
    if (( rc != 1 )); then
        fail "${label}: matrix_match returned ${rc} for id='${id}' version='${ver}';"\
             "1 (no match) was expected -- ${why}"
        return 0
    fi
    if [[ -n $out ]]; then
        fail "${label}: matrix_match printed '${out}' while returning ${rc}"
        return 0
    fi
    pass "${label}: rejected id='${id}' version='${ver}' -- ${why}"
    return 0
}

probe_accept() {
    local want_tier=$1 want_row=$2 id=$3 ver=$4 file=$5 label out rc=0
    label=$(label_of "$file")
    out=$(matrix_match "$id" "$ver" "$file") || rc=$?
    if (( rc != 0 )); then
        fail "${label}: matrix_match rejected id='${id}' version='${ver}' (rc ${rc});"\
             "${want_tier} ${want_row} was expected"
        return 0
    fi
    if [[ $out != "${want_tier}"$'\t'"${want_row}" ]]; then
        fail "${label}: matrix_match returned '${out//$'\t'/ }' for id='${id}' version='${ver}';"\
             "'${want_tier} ${want_row}' was expected"
        return 0
    fi
    pass "${label}: id='${id}' version='${ver}' -> ${want_tier} ${want_row}"
    return 0
}

for matrix_file in "$MATRIX_SHIPPED" "$MATRIX_PINNED"; do
    probe_reject "a prefix of an id is not an id"                 "debia"  "11"   "$matrix_file"
    probe_reject "a suffix of an id is not an id"                 "ebian"  "11"   "$matrix_file"
    probe_reject "a prefix of a version is not a version"         "debian" "1"    "$matrix_file"
    probe_reject "a value spanning two rows is not a row"         "debian" "11 debian:12" "$matrix_file"
    probe_reject "an id spanning two rows is not an id"           "debian:11 debian" "12" "$matrix_file"
    probe_reject "a glob is a literal, not a pattern"             "*"      "*"    "$matrix_file"
    probe_reject "a glob in the id is a literal"                  "*"      "11"   "$matrix_file"
    probe_reject "a glob in the version is a literal"             "debian" "*"    "$matrix_file"
    probe_reject "a single-character wildcard is a literal"       "?ebian" "11"   "$matrix_file"
    probe_reject "an empty version matches nothing"               "debian" ""     "$matrix_file"
    probe_reject "an empty id matches nothing"                    ""       "11"   "$matrix_file"
    # The legitimate lookups the rules above must not have broken.
    probe_accept legacy "debian:11"    "debian"    "11"   "$matrix_file"
    probe_accept legacy "debian:11"    "debian"    "11.5" "$matrix_file"
    probe_accept legacy "linuxmint:21" "linuxmint" "21.3" "$matrix_file"
done

# The version rule is granularity-by-row, not per-distribution: an Ubuntu
# interim release shares the major with an LTS row and must still not match.
probe_reject "20.10 shares a major with ubuntu:20.04 and is not it" "ubuntu" "20.10" "$MATRIX_SHIPPED"

# ===========================================================================
# 5. The fixtures resolve as the manifest says, against both matrix files.
# ===========================================================================
head2 "5. fixtures"
if [[ ! -r $MANIFEST ]]; then
    fail "tests/os-release/expected.tsv is missing"
else
    mapfile -t manifest_rows < <(grep -v '^#' "$MANIFEST" | grep -v '^[[:space:]]*$')

    fixture_count=0
    for f in "$FIXTURE_DIR"/*.os-release; do
        [[ -e $f ]] || continue
        fixture_count=$(( fixture_count + 1 ))
    done

    if (( fixture_count == ${#manifest_rows[@]} )); then
        pass "${fixture_count} fixtures, ${#manifest_rows[@]} manifest rows"
    else
        fail "${fixture_count} fixtures but ${#manifest_rows[@]} manifest rows -- one of them was not updated"
    fi

    for line in "${manifest_rows[@]}"; do
        mapfile -t col < <(split_tsv "$line")
        if (( ${#col[@]} != 7 )); then
            fail "manifest row is not 7 tab-separated columns: '${line}'"
            continue
        fi
        fixture=${col[0]}
        want_id=${col[1]}
        want_ver=${col[2]}
        path="${FIXTURE_DIR}/${fixture}"

        if [[ ! -r $path ]]; then
            fail "${fixture}: named in the manifest, not in the directory"
            continue
        fi

        if ! ident=$(matrix_identify "$path"); then
            fail "${fixture}: matrix_identify found no ID"
            continue
        fi
        got_id=${ident%%$'\t'*}
        got_ver=${ident#*$'\t'}

        if [[ $got_id != "$want_id" || $got_ver != "$want_ver" ]]; then
            fail "${fixture}: parsed '${got_id}' '${got_ver}', manifest says '${want_id}' '${want_ver}'"
            continue
        fi

        fixture_ok=1
        for pair in "3:${MATRIX_SHIPPED}" "5:${MATRIX_PINNED}"; do
            base=${pair%%:*}
            matrix_file=${pair#*:}
            want_tier=${col[$base]}
            want_row=${col[$(( base + 1 ))]}
            label=$(label_of "$matrix_file")

            rc=0
            got=$(matrix_match "$got_id" "$got_ver" "$matrix_file") || rc=$?
            if (( rc == 0 )); then
                got_tier=${got%%$'\t'*}
                got_row=${got#*$'\t'}
            elif (( rc == 1 )); then
                got_tier=unknown
                got_row='-'
            else
                fail "${fixture} (${label}): matrix_match returned ${rc} -- the matrix could not be read"
                fixture_ok=0
                continue
            fi

            if [[ $got_tier != "$want_tier" || $got_row != "$want_row" ]]; then
                fail "${fixture} (${label}): resolved ${got_tier} ${got_row}, manifest says ${want_tier} ${want_row}"
                fixture_ok=0
                continue
            fi

            # matrix_supports is the verdict preflight uses and it licenses the
            # word "supported". It must be true for the supported tier and for
            # nothing else -- a legacy box answering true here is the exact
            # untrue assertion D-07 exists to stop. matrix_known must be true
            # for both tiers. Neither may print anything: they are called
            # inside conditions.
            noise=$( { matrix_supports "$got_id" "$got_ver" "$matrix_file"
                       matrix_known "$got_id" "$got_ver" "$matrix_file"; } 2>&1 || true )
            if [[ -n $noise ]]; then
                fail "${fixture} (${label}): matrix_supports/matrix_known printed something"
                fixture_ok=0
                continue
            fi

            if matrix_supports "$got_id" "$got_ver" "$matrix_file"; then
                got_supported=yes
            else
                got_supported=no
            fi
            if matrix_known "$got_id" "$got_ver" "$matrix_file"; then
                got_known=yes
            else
                got_known=no
            fi

            want_supported=no
            want_known=yes
            case $want_tier in
                supported) want_supported=yes ;;
                legacy)    ;;
                unknown)   want_known=no ;;
            esac

            if [[ $got_supported != "$want_supported" ]]; then
                fail "${fixture} (${label}): matrix_supports said ${got_supported} for a ${want_tier} box"
                fixture_ok=0
                continue
            fi
            if [[ $got_known != "$want_known" ]]; then
                fail "${fixture} (${label}): matrix_known said ${got_known} for a ${want_tier} box"
                fixture_ok=0
                continue
            fi
        done

        if (( fixture_ok == 1 )); then
            pass "${fixture} -> ${got_id} ${got_ver} -> shipped ${col[3]} ${col[4]} / pinned ${col[5]} ${col[6]}"
        fi
    done
fi

# ===========================================================================
# 6. Tier precedence, stated directly.
# ===========================================================================
head2 "6. tier precedence"
if grep -q '^  - "debian:13"$' "$MATRIX_PINNED"; then
    both=$(grep -c '^  - "debian:13"$' "$MATRIX_PINNED")
    if (( both == 2 )); then
        pass "pinned-example lists debian:13 in both tiers, which is what makes this test mean anything"
    else
        fail "pinned-example lists debian:13 ${both} time(s); 2 were expected, one per tier"
    fi
else
    fail "pinned-example no longer lists debian:13, so precedence is untested"
fi
probe_accept supported "debian:13" "debian" "13" "$MATRIX_PINNED"
if tier=$(matrix_tier debian 13 "$MATRIX_PINNED") && [[ $tier == supported ]]; then
    pass "matrix_tier debian 13 -> supported (the supported tier is searched first)"
else
    fail "matrix_tier debian 13 -> '${tier:-<nothing>}'; 'supported' was expected"
fi
if matrix_supports debian 13 "$MATRIX_PINNED"; then
    pass "matrix_supports debian 13 -> true against a pin that accepts it"
else
    fail "matrix_supports debian 13 -> false against a pin that accepts it"
fi
# The shipped file's answer for debian:13 depends on whether a ref is pinned,
# so this asserts the RULE rather than a snapshot of the day it was written.
#
# It used to hardcode "false, because nothing is pinned", which was true until
# D-11 pinned a commit and then became a test failure reporting a correct tree.
# A test that has to be edited every time the thing it describes legitimately
# changes teaches people to edit tests, so this one now derives its expectation
# the same way lib/matrix.sh does: pinned and carrying debian:13 -> supported;
# unpinned -> nothing may be called supported at all. check_pin_invariant above
# separately guarantees the ref and the tier are empty together, so these two
# between them leave no state unchecked.
_shipped_ref=$(matrix_supported_ref "$MATRIX_SHIPPED" 2>/dev/null) || _shipped_ref=''
if [[ -n $_shipped_ref ]]; then
    if matrix_supports debian 13 "$MATRIX_SHIPPED"; then
        pass "matrix_supports debian 13 -> true against the SHIPPED file, pinned at ${_shipped_ref}"
    else
        fail "matrix_supports debian 13 -> false against the SHIPPED file, which is pinned at"\
             "${_shipped_ref} and lists debian:13 as supported"
    fi
else
    if matrix_supports debian 13 "$MATRIX_SHIPPED"; then
        fail "matrix_supports debian 13 -> true against the SHIPPED file, whose supported tier is"\
             "empty -- nothing may be called supported while nothing is pinned"
    else
        pass "matrix_supports debian 13 -> false while nothing is pinned"
    fi
fi
if matrix_known debian 13 "$MATRIX_SHIPPED"; then
    pass "matrix_known debian 13 -> true against the shipped file (legacy is reachable)"
else
    fail "matrix_known debian 13 -> false; the legacy tier must stay reachable"
fi

# ===========================================================================
# 7. A malformed matrix is refused rather than half-read.
# ===========================================================================
head2 "7. malformed files are refused"
refuse() {
    local why=$1 body=$2 f="${TMPDIR_RUN}/bad.$$.$RANDOM.yml"
    printf '%s\n' "$body" > "$f"
    if matrix_list_tier legacy "$f" >/dev/null 2>&1; then
        fail "accepted a matrix it must refuse: ${why}"
    else
        pass "refused: ${why}"
    fi
    rm -f -- "$f"
}
refuse "the legacy key is absent" 'tpot_support_matrix_supported: []'
refuse "a line under the key is not an entry" 'tpot_support_matrix_legacy:
  - "debian:11"
  what is this'
refuse "a half-quoted row" 'tpot_support_matrix_legacy:
  - "debian:11
  - "debian:12"'
refuse "the same tier declared twice" 'tpot_support_matrix_legacy:
  - "debian:11"
tpot_support_matrix_legacy:
  - "debian:12"'
refuse "an empty flow sequence with entries under it" 'tpot_support_matrix_legacy: []
  - "debian:11"'
refuse "a version that does not start with a digit" 'tpot_support_matrix_legacy:
  - "debian:bookworm"'

# An empty tier is NOT malformed, and this is the distinction the whole
# two-tier design rests on.
printf '%s\n' 'tpot_support_matrix_supported_ref: ""
tpot_support_matrix_supported: []
tpot_support_matrix_legacy:
  - "debian:11"' > "${TMPDIR_RUN}/empty-supported.yml"
if out=$(matrix_list_tier supported "${TMPDIR_RUN}/empty-supported.yml") && [[ -z $out ]]; then
    pass "accepted, with no rows: a tier declared []"
else
    fail "a tier declared [] must read as empty and succeed, not fail"
fi

# ===========================================================================
# Verdict.
# ===========================================================================
printf '\n'
if (( ${#MODES[@]} > 0 )); then
    printf 'reference readers that ran: %s\n' "$(printf '%s; ' "${MODES[@]}")"
else
    printf 'reference readers that ran: none\n'
fi
printf 'tier comparisons made: %d\n' "$COMPARED"

if (( FAILURES > 0 )); then
    printf '%d assertion(s) failed.\n' "$FAILURES" >&2
    exit 1
fi

if (( COMPARED == 0 )); then
    printf 'INCONCLUSIVE: no YAML parser was available, so the bash reader was never\n' >&2
    printf 'compared with anything. Install ansible-core, or python3-yaml, and re-run.\n' >&2
    exit 2
fi

printf 'All assertions passed.\n'
exit 0
