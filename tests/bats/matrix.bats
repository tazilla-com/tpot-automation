#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# tests/bats/matrix.bats -- the two-tier support matrix reader, against files
# this file writes.
#
# WHAT THIS COVERS THAT tests/check-matrix-parse.sh DOES NOT
#   That gate is thorough and this file deliberately does not repeat it. It
#   asserts the bash reader and a real YAML parser agree tier by tier, that
#   every os-release fixture resolves as tests/os-release/expected.tsv says,
#   that membership is an exact-element comparison with upstream's idiom run
#   beside it as a negative control, and that a handful of malformed files are
#   refused. Every one of those assertions runs against ONE OF THE TWO SHIPPED
#   MATRIX FILES.
#
#   This file runs against matrices it constructs in $TMP, which is the axis
#   the gate cannot reach:
#
#     * the FAILURE MODES a caller has to tell apart -- rc 1 "this box is in
#       neither tier" against rc 2 "the matrix could not be read at all". The
#       gate treats rc 2 as a test failure, so no case in it exercises the
#       distinction, and preflight reporting the second as the first would tell
#       somebody to reinstall their operating system over a missing file.
#     * the rules that only bite when the DATA is arranged adversarially: tier
#       precedence when the legacy key is written first, tier precedence
#       against a more specific version in the other tier, one tier's rows
#       leaking into the other.
#     * matrix_supported_ref's scalar forms, and matrix_summary's wording,
#       which is a sentence users read and which asserted a test campaign that
#       has never happened until it was corrected on 2026-09-04.
#
#   Everything below is a call and an assertion on what came back. Nothing here
#   reads lib/matrix.sh as text.
#
# THE RULES BEING PINNED, all of them stated in support-matrix.yml:
#   - membership is an EXACT element comparison, never a substring or a pattern
#   - VERSION_ID matches a row if it equals it, or if its first dot-component
#     does; so 21.3 matches linuxmint:21 and 20.10 matches nothing
#   - ID is compared verbatim and ID_LIKE is never consulted
#   - a row in both tiers is SUPPORTED, and the supported tier is searched first
#   - a tier written `[]` is empty and valid; a tier whose key is ABSENT is a
#     malformed file
#   - nothing may describe the supported tier as tested
#
# NO ROOT, NO NETWORK, NO INSTALL. It reads files this test wrote in $TMP and
# the repository's own support-matrix.yml, which it never modifies.

load helper

# ---------------------------------------------------------------------------
# Fixtures. Each writes one matrix file into $TMP and prints its path, so a
# test reads as the file it is about rather than as a heredoc.
# ---------------------------------------------------------------------------

# A matrix with both tiers populated and a ref pinned. debian:13 is in BOTH
# tiers, exactly as the shipped file has it, because that is what makes the
# precedence tests mean anything.
fx_pinned() {
    cat > "$TMP/pinned.yml" <<'YAML'
---
tpot_support_matrix_supported_ref: "abc123def456"
tpot_support_matrix_supported:
  - "debian:13"
  - "ubuntu:26.04"
tpot_support_matrix_legacy:
  - "debian:11"
  - "debian:12"
  - "debian:13"
  - "ubuntu:20.04"
  - "linuxmint:21"
YAML
    printf '%s\n' "$TMP/pinned.yml"
}

# The unpinned shape: the supported tier declared empty, the ref empty with it.
fx_unpinned() {
    cat > "$TMP/unpinned.yml" <<'YAML'
---
tpot_support_matrix_supported_ref: ""
tpot_support_matrix_supported: []
tpot_support_matrix_legacy:
  - "debian:11"
  - "debian:12"
  - "ubuntu:22.04"
YAML
    printf '%s\n' "$TMP/unpinned.yml"
}

# ---------------------------------------------------------------------------
# The tiers themselves.
# ---------------------------------------------------------------------------

@test "the tiers are supported then legacy, and that order is the precedence" {
    lib_source matrix.sh
    local got
    got=$(matrix_tiers)
    assert_eq "supported"$'\n'"legacy" "$got" "matrix_tiers"
}

@test "a tier name this library does not know is refused, not read as empty" {
    # The failure this prevents: a caller typing matrix_list_tier tested, or
    # capitalising Supported, and getting rc 0 with no rows -- which reads
    # exactly like a legitimately empty supported tier and would quietly
    # unsupport every box.
    lib_source matrix.sh
    local file bad
    file=$(fx_pinned)
    for bad in tested Supported LEGACY supported_ref '' 'supported legacy'; do
        run matrix_list_tier "$bad" "$file"
        assert_rc 1
        assert_eq "" "$output" "output of matrix_list_tier '$bad'"
    done
}

@test "one tier's rows never appear in the other, whichever key is written first" {
    # The parser walks the file and has to stop at the next top-level key. If
    # it did not, the supported tier would swallow the legacy rows underneath
    # it and nine documented releases would silently become supported ones.
    lib_source matrix.sh
    cat > "$TMP/legacy-first.yml" <<'YAML'
---
tpot_support_matrix_legacy:
  - "ubuntu:20.04"
  - "debian:13"
tpot_support_matrix_supported_ref: "deadbeef"
tpot_support_matrix_supported:
  - "debian:13"
YAML
    assert_eq "debian:13" "$(matrix_list_tier supported "$TMP/legacy-first.yml")" "the supported tier"
    assert_eq "ubuntu:20.04"$'\n'"debian:13" \
        "$(matrix_list_tier legacy "$TMP/legacy-first.yml")" "the legacy tier"
}

@test "rows come back in file order, comments and quoting styles aside" {
    lib_source matrix.sh
    cat > "$TMP/styles.yml" <<'YAML'
tpot_support_matrix_supported: []
tpot_support_matrix_legacy:

  # a whole-line comment is structure, not a row
  - 'debian:11'
  - "debian:12"   # a trailing comment is not part of the version
  - debian:13
YAML
    assert_eq "debian:11"$'\n'"debian:12"$'\n'"debian:13" \
        "$(matrix_list_tier legacy "$TMP/styles.yml")" "the legacy tier"
}

@test "a matrix file with CRLF line endings reads identically" {
    # Somebody will edit this file on Windows, or a release pipeline will
    # normalise it. A stray carriage return riding along on the version would
    # make every row unmatchable while the file still looked correct in a
    # terminal -- the failure would surface as "your box is unsupported".
    #
    # The property is defended TWICE over -- the reader strips a trailing \r
    # from every line, and the entry and key patterns both tolerate trailing
    # whitespace, which \r is in this locale -- so this test goes red only when
    # both are gone. That is deliberate: it pins the behaviour a caller sees,
    # not either mechanism, and it is the assertion that survives a rewrite of
    # the parser.
    lib_source matrix.sh
    printf 'tpot_support_matrix_supported: []\r\ntpot_support_matrix_legacy:\r\n  - "debian:11"\r\n  - "ubuntu:22.04"\r\n' \
        > "$TMP/crlf.yml"
    assert_eq "debian:11"$'\n'"ubuntu:22.04" \
        "$(matrix_list_tier legacy "$TMP/crlf.yml")" "the legacy tier read from a CRLF file"
    local got
    got=$(matrix_match ubuntu 22.04 "$TMP/crlf.yml")
    assert_eq "legacy"$'\t'"ubuntu:22.04" "$got" "matrix_match against a CRLF file"
}

# ---------------------------------------------------------------------------
# The match rule.
# ---------------------------------------------------------------------------

@test "a row in both tiers is reported as supported, even when legacy is written first" {
    # SUPPORTED WINS is the whole of D-07 expressed as a lookup. Reporting a
    # supported box as legacy would understate; the inverse -- which the tier
    # loop order is what prevents -- is the untrue assertion the two-tier split
    # exists to stop. File order must not be able to change the answer.
    lib_source matrix.sh
    cat > "$TMP/both.yml" <<'YAML'
tpot_support_matrix_legacy:
  - "debian:13"
tpot_support_matrix_supported_ref: "r"
tpot_support_matrix_supported:
  - "debian:13"
YAML
    assert_eq "supported"$'\t'"debian:13" "$(matrix_match debian 13 "$TMP/both.yml")" "matrix_match"
    assert_eq "debian:13" "$(matrix_key debian 13 "$TMP/both.yml")" "matrix_key"
}

@test "tier precedence outranks version specificity" {
    # The subtle case, and the one a reader guesses wrong: the tier loop is the
    # OUTER one, so a coarse row in the supported tier beats an exact row in
    # the legacy tier. Asked about 20.04 with supported holding ubuntu:20 and
    # legacy holding ubuntu:20.04, the answer is the supported row. If this
    # ever inverts, a box in both tiers starts being recorded as legacy.
    lib_source matrix.sh
    cat > "$TMP/spec.yml" <<'YAML'
tpot_support_matrix_supported_ref: "r"
tpot_support_matrix_supported:
  - "ubuntu:20"
tpot_support_matrix_legacy:
  - "ubuntu:20.04"
YAML
    assert_eq "supported"$'\t'"ubuntu:20" "$(matrix_match ubuntu 20.04 "$TMP/spec.yml")" "matrix_match"
}

@test "within a tier the full version is preferred to its major" {
    lib_source matrix.sh
    cat > "$TMP/prefer.yml" <<'YAML'
tpot_support_matrix_supported_ref: "r"
tpot_support_matrix_supported:
  - "ubuntu:20"
  - "ubuntu:20.04"
tpot_support_matrix_legacy: []
YAML
    assert_eq "supported"$'\t'"ubuntu:20.04" \
        "$(matrix_match ubuntu 20.04 "$TMP/prefer.yml")" "matrix_match ubuntu 20.04"
    # ...and the major-only row still answers for a version that has no row.
    assert_eq "supported"$'\t'"ubuntu:20" \
        "$(matrix_match ubuntu 20.10 "$TMP/prefer.yml")" "matrix_match ubuntu 20.10"
}

@test "a VERSION_ID matches a row when its first dot-component does" {
    lib_source matrix.sh
    local file
    file=$(fx_pinned)
    # Mint reports a point release that tracks its Ubuntu base; every point
    # release of a series is the same base, so the row is the major.
    assert_eq "legacy"$'\t'"linuxmint:21" "$(matrix_match linuxmint 21.3 "$file")" "linuxmint 21.3"
    assert_eq "legacy"$'\t'"debian:11"    "$(matrix_match debian 11.5 "$file")"    "debian 11.5"
    # An exact hit is still an exact hit.
    assert_eq "supported"$'\t'"ubuntu:26.04" "$(matrix_match ubuntu 26.04 "$file")" "ubuntu 26.04"
}

@test "an interim release that shares a major with an LTS row matches nothing" {
    # Granularity is a property of the ROW: ubuntu:20.04 carries both
    # components precisely so that 20.10 cannot reach it. This is the case
    # where a "close enough" match rule would install T-Pot on a release
    # upstream refuses.
    lib_source matrix.sh
    local file rc=0 out
    file=$(fx_pinned)
    out=$(matrix_match ubuntu 20.10 "$file") || rc=$?
    assert_eq "1" "$rc" "matrix_match ubuntu 20.10"
    assert_eq "" "$out" "output of matrix_match ubuntu 20.10"
}

@test "ID is compared verbatim and ID_LIKE is never consulted" {
    # Raspberry Pi OS reports ID=raspbian, ID_LIKE=debian, VERSION_ID="12".
    # Folding it into debian:12 through ID_LIKE would claim a distribution
    # nobody here has installed T-Pot on -- and it is one upstream's own gate
    # does accept, so nothing downstream would object.
    lib_source matrix.sh
    local file rc=0
    file=$(fx_pinned)
    matrix_match raspbian 12 "$file" >/dev/null || rc=$?
    assert_eq "1" "$rc" "matrix_match raspbian 12 against a matrix listing debian:12"
}

@test "membership is an exact element comparison, on a caller-supplied file too" {
    # tests/check-matrix-parse.sh proves this rule against the shipped matrices
    # and runs upstream's own joined-list idiom beside it as a negative control;
    # that measurement is not repeated here. What is pinned here is that the
    # rule holds for a file the CALLER hands in -- the argument every function
    # in this library takes, and the path no assertion in that gate exercises.
    lib_source matrix.sh
    cat > "$TMP/one.yml" <<'YAML'
tpot_support_matrix_supported: []
tpot_support_matrix_legacy:
  - "debian:11"
YAML
    local id ver rc out
    # id, version, why it must be refused
    while IFS='|' read -r id ver why; do
        [[ -n $why ]] || continue
        rc=0
        out=$(matrix_match "$id" "$ver" "$TMP/one.yml") || rc=$?
        if (( rc != 1 )); then
            printf 'matrix_match %q %q returned %s; 1 was expected -- %s\n' "$id" "$ver" "$rc" "$why" >&2
            return 1
        fi
        assert_eq "" "$out" "output for id='$id' version='$ver'"
    done <<'PROBES'
debia|11|a prefix of an id is not an id
debian:11|11|the whole row is not an id
debian|1|a prefix of a version is not a version
debian|1.1|a version whose first component is not the row is not the row
DEBIAN|11|an id is compared case-sensitively, as os-release promises it is written
*|*|a glob is a literal, not a pattern
debian|*|a glob in the version is a literal
?ebian|11|a single-character wildcard is a literal
debian|11 debian:11|a value spanning the row is not the row
PROBES
    # ...and the legitimate lookup underneath is untouched.
    assert_eq "legacy"$'\t'"debian:11" "$(matrix_match debian 11 "$TMP/one.yml")" "the real row"
}

# ---------------------------------------------------------------------------
# "No match" against "could not look". THE distinction, and the one the gate
# cannot make.
# ---------------------------------------------------------------------------

@test "no row matching this box is rc 1, and an unreadable matrix is rc 2" {
    # lib/matrix.sh's header: preflight must not report the second as the
    # first -- it would send somebody to reinstall their operating system over
    # a missing file. Both failures print nothing, so the code is the only
    # signal there is.
    lib_source matrix.sh
    local file rc out
    file=$(fx_pinned)

    rc=0; out=$(matrix_match fedora 44 "$file") || rc=$?
    assert_eq "1" "$rc" "a box in neither tier"
    assert_eq "" "$out" "output for a box in neither tier"

    rc=0; out=$(matrix_match debian 13 "$TMP/does-not-exist.yml" 2>/dev/null) || rc=$?
    assert_eq "2" "$rc" "a matrix file that does not exist"
    assert_eq "" "$out" "output for a missing matrix file"
}

@test "a malformed matrix is rc 2, not a box that happens not to match" {
    # A line under a tier key that is not an entry is refused rather than
    # skipped, because a skipped line is a release that silently stops being
    # supported. The verdict a caller sees for that file must be "I could not
    # read it", not "you are not in it".
    lib_source matrix.sh
    local rc out

    cat > "$TMP/garbage.yml" <<'YAML'
tpot_support_matrix_supported: []
tpot_support_matrix_legacy:
  - "debian:13"
  what is this
YAML
    rc=0; out=$(matrix_match debian 13 "$TMP/garbage.yml") || rc=$?
    assert_eq "2" "$rc" "a line under the key that is not an entry"
    assert_eq "" "$out" "output for a malformed matrix"

    # A tier whose key is ABSENT is malformed too -- this is the half of the
    # empty/absent distinction that decides an exit code.
    cat > "$TMP/no-legacy.yml" <<'YAML'
tpot_support_matrix_supported_ref: "r"
tpot_support_matrix_supported:
  - "debian:13"
YAML
    rc=0; out=$(matrix_match debian 13 "$TMP/no-legacy.yml") || rc=$?
    assert_eq "2" "$rc" "a matrix whose legacy key is absent"

    # Nothing in either tier is a broken file, not an empty answer.
    cat > "$TMP/empty-both.yml" <<'YAML'
tpot_support_matrix_supported_ref: ""
tpot_support_matrix_supported: []
tpot_support_matrix_legacy: []
YAML
    rc=0; out=$(matrix_match debian 13 "$TMP/empty-both.yml") || rc=$?
    assert_eq "2" "$rc" "a matrix with no rows in either tier"
}

@test "a tier declared empty still lets a lookup answer 'not in the matrix'" {
    # The other half of the same distinction, and the reason `[]` is not just
    # tidier than omitting the key: an unpinned installer must still be able to
    # say "this box is in neither tier" (rc 1) rather than "I am broken" (rc 2).
    lib_source matrix.sh
    local file rc out
    file=$(fx_unpinned)
    rc=0; out=$(matrix_match fedora 44 "$file") || rc=$?
    assert_eq "1" "$rc" "a box in neither tier of an unpinned matrix"
    # The declared-empty tier itself reads as empty and SUCCEEDS.
    run matrix_list_tier supported "$file"
    assert_rc 0
    assert_eq "" "$output" "the rows of a tier declared []"
}

@test "matrix_key prints the row alone and carries both failure codes through" {
    lib_source matrix.sh
    local file rc out
    file=$(fx_pinned)
    assert_eq "ubuntu:26.04" "$(matrix_key ubuntu 26.04 "$file")" "matrix_key"
    # The row must be the second half of what matrix_match printed, with no tier
    # and no tab: it is what goes into result.json beside the tier, not instead
    # of it.
    assert_eq "$(matrix_match ubuntu 26.04 "$file" | cut -f2)" \
        "$(matrix_key ubuntu 26.04 "$file")" "matrix_key against matrix_match"
    refute_contains $'\t' "$(matrix_key ubuntu 26.04 "$file")" "matrix_key output"

    rc=0; out=$(matrix_key fedora 44 "$file") || rc=$?
    assert_eq "1" "$rc" "matrix_key for a box in neither tier"
    assert_eq "" "$out" "output of matrix_key for a box in neither tier"

    rc=0; out=$(matrix_key debian 13 "$TMP/missing.yml" 2>/dev/null) || rc=$?
    assert_eq "2" "$rc" "matrix_key against a missing file"
    assert_eq "" "$out" "output of matrix_key against a missing file"
}

# ---------------------------------------------------------------------------
# The pinned ref.
# ---------------------------------------------------------------------------

@test "the supported ref is read whether it is quoted, bare or followed by a comment" {
    lib_source matrix.sh
    local body
    for body in '"abc123"' "'abc123'" 'abc123' 'abc123  # derived 2026-09-04'; do
        printf 'tpot_support_matrix_supported_ref: %s\ntpot_support_matrix_supported:\n  - "debian:13"\ntpot_support_matrix_legacy: []\n' \
            "$body" > "$TMP/ref.yml"
        assert_eq "abc123" "$(matrix_supported_ref "$TMP/ref.yml")" "the ref written as: $body"
    done
}

@test "no pin is a return of 1 with nothing printed, however it is written" {
    # An empty ref and an absent ref mean the same thing operationally --
    # nothing is pinned, so nothing is claimed -- and matrix_summary branches
    # on exactly this. A ref that came back as the empty STRING with rc 0 would
    # put "(upstream ref )" into the sentence users read.
    lib_source matrix.sh
    local file
    file=$(fx_unpinned)
    run matrix_supported_ref "$file"
    assert_rc 1
    assert_eq "" "$output" "the ref of an unpinned matrix"

    cat > "$TMP/no-ref-key.yml" <<'YAML'
tpot_support_matrix_supported: []
tpot_support_matrix_legacy:
  - "debian:11"
YAML
    run matrix_supported_ref "$TMP/no-ref-key.yml"
    assert_rc 1
    assert_eq "" "$output" "the ref of a matrix with no ref key"

    run matrix_supported_ref "$TMP/does-not-exist.yml"
    assert_rc 1
    assert_eq "" "$output" "the ref of a file that does not exist"
}

# ---------------------------------------------------------------------------
# The sentences users read.
# ---------------------------------------------------------------------------

@test "a tier is summarised as versions grouped under each id, in file order" {
    lib_source matrix.sh
    local file
    file=$(fx_pinned)
    assert_eq "debian 13, ubuntu 26.04" "$(matrix_summary_tier supported "$file")" "the supported tier"
    assert_eq "debian 11/12/13, ubuntu 20.04, linuxmint 21" \
        "$(matrix_summary_tier legacy "$file")" "the legacy tier"
}

@test "an empty tier has no summary, rather than an empty phrase inside a sentence" {
    # The caller builds a sentence out of this. Returning 0 with an empty
    # string would produce "supported: " followed by nothing, which reads as a
    # broken installer rather than an unpinned one.
    lib_source matrix.sh
    local file
    file=$(fx_unpinned)
    run matrix_summary_tier supported "$file"
    assert_rc 1
    assert_eq "" "$output" "the summary of an empty tier"

    run matrix_summary_tier tested "$file"
    assert_rc 1
    assert_eq "" "$output" "the summary of a tier name that does not exist"

    run matrix_summary_tier legacy "$TMP/does-not-exist.yml"
    assert_rc 1
    assert_eq "" "$output" "the summary of an unreadable matrix"
}

@test "the summary never calls the supported tier tested" {
    # THE DEFECT THIS PINS, corrected 2026-09-04: this sentence said "supported
    # and tested" while the supported tier shipped empty, so nothing printed
    # it. The moment D-11 pinned a ref it became a claim that went out on every
    # run on an unrecognised box -- asserting a test campaign that has never
    # happened. Nothing has ever been installed on any guest; the evidence
    # would be a dated row in tests/MATRIX-STATUS.md, which does not exist.
    #
    # The assertion is deliberately not a match on today's wording: every
    # occurrence of "tested" is stripped of its negation first, and what is left
    # must not contain the word at all. A rewrite is free to say this
    # differently and is not free to drop the negation.
    lib_source matrix.sh
    local file text stripped
    for file in "$(fx_pinned)" "$(fx_unpinned)" "$REPO/support-matrix.yml"; do
        text=$(matrix_summary "$file")
        assert_ne "" "$text" "matrix_summary of $file"
        stripped=${text//never tested/}
        stripped=${stripped//not tested/}
        refute_contains "tested" "$stripped" "matrix_summary of $file, negations removed"
        # The legacy tier is named and is never claimed either.
        assert_contains "legacy" "$text" "matrix_summary of $file"
    done
}

@test "the summary names the pin when there is one and the way to get one when there is not" {
    lib_source matrix.sh
    local pinned unpinned text
    pinned=$(fx_pinned)
    unpinned=$(fx_unpinned)

    text=$(matrix_summary "$pinned")
    assert_contains "abc123def456" "$text" "the pinned summary"
    assert_contains "debian 13, ubuntu 26.04" "$text" "the pinned summary"
    assert_contains "debian 11/12/13" "$text" "the legacy half of the pinned summary"

    text=$(matrix_summary "$unpinned")
    # An unpinned installer claims nothing, and says what to do about it.
    assert_contains "supported: none" "$text" "the unpinned summary"
    assert_contains "tools/pin-upstream.sh" "$text" "the unpinned summary"
    refute_contains "(upstream ref" "$text" "the unpinned summary"
    # ...and still names the legacy tier, which is reachable.
    assert_contains "debian 11/12" "$text" "the legacy half of the unpinned summary"
}

@test "the summary is silent only when the matrix cannot be read at all" {
    lib_source matrix.sh
    run matrix_summary "$TMP/does-not-exist.yml"
    assert_rc 1
    assert_eq "" "$output" "the summary of a missing matrix"

    cat > "$TMP/garbage2.yml" <<'YAML'
tpot_support_matrix_supported: []
tpot_support_matrix_legacy:
  - "debian:13"
  not an entry
YAML
    run matrix_summary "$TMP/garbage2.yml"
    assert_rc 1
    assert_eq "" "$output" "the summary of a malformed matrix"
}

@test "the matrix this repository ships answers every public call it declares" {
    # A smoke test over the REAL file, read-only: the reader is only worth
    # anything if it reads the one matrix the product actually ships. It
    # asserts shape, never a particular release, because the supported tier is
    # derived from the pin and moving the pin legitimately changes it -- a test
    # that had to be edited whenever the tree changed correctly would teach
    # people to edit tests.
    lib_source matrix.sh
    local file rows ref summary tier
    file="$REPO/support-matrix.yml"
    [[ -r $file ]] || skip "support-matrix.yml is not readable from here"

    for tier in $(matrix_tiers); do
        run matrix_list_tier "$tier" "$file"
        assert_rc 0
    done

    rows=$(matrix_list_tier supported "$file")
    if ref=$(matrix_supported_ref "$file"); then
        # Pinned: the tier must be non-empty, and the summary must name the ref.
        assert_ne "" "$rows" "the supported tier of a pinned matrix"
        summary=$(matrix_summary "$file")
        assert_contains "$ref" "$summary" "the shipped summary"
    else
        # Unpinned: nothing may be claimed.
        assert_eq "" "$rows" "the supported tier of an unpinned matrix"
    fi

    # The legacy tier is reachable whatever the pin says, and every row of both
    # tiers is a well-formed id:version.
    local row
    while IFS= read -r row; do
        [[ -n $row ]] || continue
        assert_matches '^[a-z][a-z0-9._-]*:[0-9][0-9a-z._-]*$' "$row" "a row of the shipped matrix"
    done < <(matrix_list "$file")
}
