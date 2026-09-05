#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# tests/bats/preflight.bats -- lib/preflight.sh, stages A and B, EXECUTED.
#
# WHY THIS FILE EXISTS, AND WHAT IT IS ANSWERABLE FOR
#   lib/preflight.sh names this file twice, in the two places where it makes a
#   promise it cannot keep on its own:
#
#     * above pf_ids -- "tests/bats/preflight.bats compares this with what a
#       full run recorded, so a check that was added without being documented,
#       or documented without being performed, fails the build";
#     * beside THE SIX TEST SEAMS -- three of which (PF_PROC_MEMINFO,
#       PF_PROC_CPUINFO, PF_PROC_MAX_MAP_COUNT) had never been pointed at
#       anything, so the threshold arithmetic of memory, cpus and
#       max_map_count had only ever run against whichever developer box a
#       session happened to be on.
#
#   Both promises are kept here. The id contract is asserted as a set AND as
#   an order, and every seam is fed fixtures built in $TMP.
#
#   A FIXTURE IS ONLY WORTH ITS LINE IF THE REAL WORLD CAN PRODUCE IT. The
#   memory tests below carried 8388608 kB -- 8192 MiB, dead on the floor --
#   for as long as they existed, and that is the one value an 8 GiB machine
#   can never report: MemTotal excludes the firmware and kernel reservation,
#   so a real 8 GiB guest says about 7880. The suite was green and the product
#   refused the exact machine upstream calls its minimum. The awkward numbers
#   are the ones to write down.
#
#   THE FIXTURES ARE BUILT IN $TMP AND NOT IN tests/fixtures/ ON PURPOSE.
#   tests/check-references.sh registers "tests/fixtures" as a path this tree
#   deliberately does not have; creating it would break that gate. A fixture
#   this suite writes, uses and deletes needs no home in the repository.
#
# WHAT THIS BOX CAN AND CANNOT SHOW
#   THIS SUITE RUNS UNPRIVILEGED, and that is the point of it: every acting
#   invocation of install.sh from here stops in preflight stage A on the root
#   check and exits 11, which is asserted below rather than assumed. What it
#   therefore cannot show is anything that needs root, docker, systemd or a
#   T-Pot -- and none of that is a gap in the product's evidence, because that
#   half is answered somewhere else. Real installs are made on real guests and
#   dated in tests/MATRIX-STATUS.md, one row per (upstream ref x platform);
#   this file answers for the code paths, that file answers for the platforms,
#   and neither can stand in for the other.
#
#   That has one structural consequence for this file: a real run of
#   install.sh on this box NEVER REACHES STAGE B, because stage A fails on
#   uid and install.sh exits before $RUNDIR is even created. So the stage A
#   contract is asserted against the real entrypoint, and the stage B half is
#   asserted by sourcing the library and calling pf_stage_b directly -- which
#   is exactly the caller lib/preflight.sh's own _tpot_pf_need_matrix comment
#   anticipates ("a bats test ... can source lib/preflight.sh alone and still
#   get a real answer instead of a crash").
#
# THE SEAMS THIS FILE USES
#   PF_OS_RELEASE          the fifteen fixtures in tests/os-release/, with
#                          their expected.tsv manifest as the second opinion
#   PF_PROC_MEMINFO        written here
#   PF_PROC_CPUINFO        written here
#   PF_PROC_MAX_MAP_COUNT  written here
#   PF_APT_ROOT            a sources tree built here, mirror+file: included
#   PF_DOCKER_DIR          a path here that this suite creates, or does not
#   plus the seam lib/preflight.sh describes but does not name: a COMMAND is
#   replaced by putting a fixture earlier on $PATH. curl, ss, uname, nproc
#   and df are all replaced that way below, and nothing in lib/ needs to know.
#
# WHAT IS DELIBERATELY NOT ASSERTED
#   Wording. The details are English and they will be reworded; this file
#   asserts a detail's TEXT only where the text is the behaviour -- the flag
#   a failure tells you to re-run with, the tier it names, the sentence a
#   supported box is forbidden from claiming, and the "--runtime-dir
#   /dev/shm" that is the entire remedy for a non-tmpfs /run.

load helper

# ===========================================================================
# Helpers used only by this file.
# ===========================================================================

# pf_load [REPO_DIR] -- source the libraries under test.
#
#   exitcodes.sh first so that pf_verdict prints the REAL numbers rather than
#   its ${EX_PREFLIGHT:-11} fallbacks: a test that accepted the fallback would
#   pass against a tree whose exit table had been renumbered.
pf_load() {
    export REPO_DIR="${1:-$REPO}"
    lib_source exitcodes.sh matrix.sh preflight.sh
}

# _pf_line ID -- the whole TSV record for one check id, or rc 1 with a
#   diagnosis naming every id that WAS recorded.
_pf_line() {
    local id=$1 line
    local -a lines=()
    mapfile -t lines < <(pf_records)
    for line in "${lines[@]}"; do
        if [[ ${line%%$'\t'*} == "$id" ]]; then
            printf '%s\n' "$line"
            return 0
        fi
    done
    printf 'no check recorded the id %q.\nrecorded: %s\n' \
        "$id" "$(pf_ids_recorded | tr '\n' ' ')" >&2
    return 1
}

pf_status() { local l; l=$(_pf_line "$1") || return 1; l=${l#*$'\t'}; printf '%s\n' "${l%%$'\t'*}"; }
pf_detail() { local l; l=$(_pf_line "$1") || return 1; l=${l#*$'\t'}; printf '%s\n' "${l#*$'\t'}"; }

# pf_ids_recorded -- the ids in the order they were recorded.
pf_ids_recorded() {
    local line
    local -a lines=()
    mapfile -t lines < <(pf_records)
    for line in "${lines[@]}"; do
        printf '%s\n' "${line%%$'\t'*}"
    done
    return 0
}

# assert_check ID STATUS -- the assertion this file makes most often. It
#   prints the DETAIL on failure, because the detail is the diagnosis.
assert_check() {
    local id=$1 want=$2 got
    got=$(pf_status "$id") || return 1
    if [[ $got != "$want" ]]; then
        printf 'check %s: expected status %s, got %s\n  detail: %s\n' \
            "$id" "$want" "$got" "$(pf_detail "$id")" >&2
        return 1
    fi
}

# no_network -- a curl that reaches nothing, first on $PATH.
#
#   Not to make the tests pass: they pass without it. It is here so the four
#   reachability checks take no wall-clock time and give the same answer on a
#   box with a network as on this one, which has none.
no_network() {
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\nexit 7\n' > "$TMP/bin/curl"
    chmod +x "$TMP/bin/curl"
    PATH="$TMP/bin:$PATH"
}

# public_json BODY -- the merged PUBLIC document stage B reads. The real one
#   is written by lib/config.py into $RUNDIR with every secret-typed key
#   already removed; this is the same shape, minus the merge.
public_json() {
    printf '{%s}\n' "$1" > "$TMP/public.json"
    export PUBLIC_JSON="$TMP/public.json"
}

# copy_tree DEST -- a copy of the installer tree, without .git, to run against
#   and to break. NOTHING in this file may touch the repository itself.
copy_tree() {
    mkdir -p "$1"
    tar -C "$REPO" --exclude=./.git -cf - . | tar -C "$1" -xf -
}

# tree_manifest DIR -- path, type, size, mode and mtime of everything under
#   DIR, sorted. Two of these compared is the "preflight mutates nothing"
#   assertion; %T@ is there so that a rewrite which happens to preserve the
#   byte count is still caught.
tree_manifest() {
    find "$1" -mindepth 1 -printf '%P\t%y\t%s\t%m\t%T@\n' | LC_ALL=C.UTF-8 sort
}

# ===========================================================================
# THE ID CONTRACT
#
# lib/preflight.sh states it above pf_ids. These two tests are that sentence.
# ===========================================================================

@test "pf_ids declares exactly the checks a run of both stages performs, in the order it performs them" {
    # THE POINT OF THE ORDERING. A set comparison catches a check that was
    # added without being declared and one declared without being performed.
    # Comparing the ORDER as well catches the third case: an id moved between
    # PF_IDS_STAGE_A and PF_IDS_STAGE_B without the check moving with it,
    # which would make docs/verification.md and result.json describe a stage
    # the check does not run in.
    #
    # NO ID LEGITIMATELY GOES MISSING HERE, and that is the design rather than
    # luck: every _tpot_pf_check_* function calls pf_record on every path it
    # can take, including the paths where it could not measure anything. A
    # check that cannot be exercised records `inconclusive` -- it does not
    # vanish. So the comparison is exact equality in both directions, and a
    # check that started returning early instead of recording would fail it.
    pf_load
    no_network
    export RUNDIR="$TMP/run"
    mkdir -p "$RUNDIR"
    # distro, so reachability_pypi takes its not-applicable arm rather than
    # depending on what ansible-core this box happens to carry.
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_a || true
    pf_stage_b || true

    assert_eq "$(pf_ids)" "$(pf_ids_recorded)" "the declared ids against the recorded ones"
}

@test "the preflight table a real run prints names every stage A check, in the declared order" {
    # The real entrypoint, unattended, stdin closed. It stops in stage A on
    # the root check -- see the exit-code test below -- so this is the whole
    # of stage A and none of stage B, which is the most a run on an
    # unprivileged box can show. Stage B's half of the contract is the test
    # above.
    pf_load
    run_install --preflight-only
    assert_rc 11

    local -a lines=() ids=()
    local line status rest id
    mapfile -t lines <<< "$output"
    for line in "${lines[@]}"; do
        # The table is two spaces, a 14-wide status, two spaces, the id.
        # Split with parameter expansion, never with word splitting: a detail
        # can contain a `*` and an unquoted expansion would glob it against
        # the working directory.
        if [[ $line != "  "* ]]; then
            continue
        fi
        line=${line#  }
        status=${line%%[[:space:]]*}
        case $status in
            OK|WARN|FAIL|INCONCLUSIVE|NOT-APPLICABLE) ;;
            *) continue ;;
        esac
        rest=${line#"$status"}
        while [[ $rest == " "* ]]; do rest=${rest# }; done
        id=${rest%%[[:space:]]*}
        ids+=("$id")
    done

    assert_eq "$(printf '%s\n' "${PF_IDS_STAGE_A[@]}")" "$(printf '%s\n' "${ids[@]}")" \
        "the stage A ids the run printed"
}

@test "an unprivileged run stops in stage A, exits 11, and says nothing was changed" {
    # The one sentence this whole suite rests on: on this box every acting
    # invocation stops here. If this test ever passes for a different reason,
    # every "nothing was installed" claim in this file needs re-reading.
    pf_load
    run_install --preflight-only
    assert_rc "$EX_PREFLIGHT"
    assert_contains 'must run as root' "$output" 'the root check'
    assert_contains 'nothing on this box was changed' "$output" 'the closing line'
}

# ===========================================================================
# PREFLIGHT MUTATES NOTHING
#
# This is the property the whole order-of-operations design exists to give.
# The installer this one replaces rewrote its own tree with `sed -i` BEFORE it
# checked whether it was root, so an unprivileged run left a half-rewritten
# credentials file behind and reported a failure that had already happened.
#
# Both tests run against a COPY under $TMP, never against the repository:
# a copy cannot be edited by anything else while the test is running, and a
# release tarball is what a stranger actually unpacks.
# ===========================================================================

@test "a --preflight-only run changes not one byte of the installer tree" {
    copy_tree "$TMP/tree"
    tree_manifest "$TMP/tree" > "$TMP/before"

    mkdir -p "$TMP/state" "$TMP/log"
    run timeout 120 setsid --wait bash "$TMP/tree/install.sh" \
        --state-dir "$TMP/state" --log-dir "$TMP/log" --preflight-only </dev/null
    assert_rc 11

    tree_manifest "$TMP/tree" > "$TMP/after"
    run diff -u "$TMP/before" "$TMP/after"
    assert_rc 0
}

@test "running both preflight stages changes not one byte of the tree either" {
    # The test above stops at the root check, so by itself it only proves the
    # part of the run BEFORE stage A finishes. This one drives both stages to
    # completion against the same copy, which is the furthest an unprivileged
    # box can take the property.
    #
    # $RUNDIR points into $TMP and is deliberately OUTSIDE the copy: preflight
    # may write preflight.tsv and host.json, and nowhere else. If it ever
    # wrote them relative to the tree instead, this is what would say so.
    pf_load "$TMP/tree"
    no_network
    copy_tree "$TMP/tree"
    export RUNDIR="$TMP/run"
    mkdir -p "$RUNDIR"
    public_json '"tpot_ansible_source": "distro"'

    tree_manifest "$TMP/tree" > "$TMP/before"
    pf_stage_a || true
    pf_stage_b || true
    pf_flush || true
    tree_manifest "$TMP/tree" > "$TMP/after"

    run diff -u "$TMP/before" "$TMP/after"
    assert_rc 0
    # ... and it did write, so the comparison above is not vacuous.
    [[ -s "$RUNDIR/preflight.tsv" ]]
}

# ===========================================================================
# pf_verdict -- records in, exit code out
#
# 0, 11 or 12 and nothing else. The 12 is the one that earns its keep: it is
# what lets a tier running preflight in containers report what it DECLINED to
# test instead of green-lighting it.
# ===========================================================================

@test "a preflight with nothing worse than a warning exits 0" {
    pf_load
    pf_record os warn 'a legacy row'
    pf_record memory ok '16384 MiB'
    assert_eq "$EX_OK" "$(pf_verdict 0)" 'the verdict of a full run'
    assert_eq "$EX_OK" "$(pf_verdict 1)" 'the verdict under --preflight-only'
}

@test "any failed check makes the verdict 11, in both modes" {
    pf_load
    pf_record os ok 'fine'
    pf_record ports fail 'tcp/25 held by exim4'
    assert_eq "$EX_PREFLIGHT" "$(pf_verdict 0)" 'the verdict of a full run'
    assert_eq "$EX_PREFLIGHT" "$(pf_verdict 1)" 'the verdict under --preflight-only'
}

@test "a hard check that could not be exercised fails closed with 11 in a full run" {
    # reachability_apt is hard. Not being able to test the package mirror is
    # not a pass, and a full run must not proceed to install from it.
    pf_load
    pf_record reachability_apt inconclusive 'could not be tested'
    assert_eq "$EX_PREFLIGHT" "$(pf_verdict 0)" 'the verdict of a full run'
}

@test "the same hard inconclusive is 12 under --preflight-only, so a run can report what it declined to test" {
    pf_load
    pf_record reachability_apt inconclusive 'could not be tested'
    assert_eq "$EX_INCONCLUSIVE" "$(pf_verdict 1)" 'the verdict under --preflight-only'
}

@test "a soft check that could not be exercised does not stop a full run, and still reports 12 under --preflight-only" {
    # upstream_gate is soft, deliberately: it pre-empts a gate belonging to
    # whichever copy of upstream's install.sh the run fetches (D-10), so being
    # unable to answer it is the normal state of a tree and not a reason to
    # refuse to install.
    pf_load
    pf_record upstream_gate inconclusive 'the pinned ref was not the ref these rules were read at'
    assert_eq "$EX_OK" "$(pf_verdict 0)" 'the verdict of a full run'
    assert_eq "$EX_INCONCLUSIVE" "$(pf_verdict 1)" 'the verdict under --preflight-only'
}

@test "not-applicable changes no exit code, in either mode" {
    # The fifth status exists because the fourth was being avoided:
    # reachability_pypi recorded `ok` on two paths where pypi.org had never
    # been contacted. `not-applicable` says the true thing -- this run has no
    # such dependency -- and it must be as harmless as `ok`, or the honest
    # answer would cost a run its exit code.
    pf_load
    pf_record reachability_pypi not-applicable 'no virtualenv is built, so PyPI is not a dependency of this run'
    pf_record exposure ok 'no firewall will be configured'
    assert_eq "$EX_OK" "$(pf_verdict 0)" 'the verdict of a full run'
    assert_eq "$EX_OK" "$(pf_verdict 1)" 'the verdict under --preflight-only'
}

@test "a check recorded with a status nobody recognises becomes inconclusive rather than disappearing" {
    # Losing a check to a typo is the failure this file exists to prevent, so
    # the downgrade lands on the status that fails closed -- and the record
    # says out loud that it was downgraded.
    pf_load
    pf_record root OKAY 'uid 0'
    assert_check root inconclusive
    assert_contains 'invalid status' "$(pf_detail root)" 'the downgraded record'
    assert_eq "$EX_PREFLIGHT" "$(pf_verdict 0)" 'the verdict of a full run'
}

# ===========================================================================
# STAGE A -- os
#
# Three outcomes, not two (D-07): supported is `ok`, legacy is `warn`, and
# neither tier is `fail`. The fifteen fixtures are driven through pf_stage_a
# rather than through the check function, because the entrypoint is what
# install.sh calls.
# ===========================================================================

@test "every os-release fixture resolves to the tier its manifest records" {
    # expected.tsv is a DELIBERATE SECOND STATEMENT of the answer, and the
    # only one in the tree: a test that derived the tier with the same rule
    # the code uses would agree with itself no matter what the rule was. The
    # Mint truncation is the case that proves it -- linuxmint 21.3 must match
    # the row linuxmint:21, and a regression that made it linuxmint:21.3
    # would pass every other test here.
    #
    # The manifest's tier names are the MATRIX's (supported / legacy /
    # unknown); this check's statuses are what a tier MEANS for a run. The
    # mapping is the subject of the test:
    #     supported -> ok      the pinned ref's gate accepts it
    #     legacy    -> warn    documented, never claimed as tested
    #     unknown   -> fail    in neither tier
    # with one row that never reaches the mapping at all: Debian testing
    # publishes no VERSION_ID, and an unmatchable box is `inconclusive`, not
    # unsupported.
    #
    # WHY THE SWEEP RUNS IN A SCRIPT OF ITS OWN. bats installs a DEBUG trap on
    # every command so it can report which line failed, and lib/matrix.sh is a
    # line-by-line parser: fifteen fixtures through the trap take thirty
    # seconds, and the same fifteen in a plain bash take one. The code under
    # test is identical either way -- this is the real pf_stage_a, reading the
    # real support-matrix.yml, through the PF_OS_RELEASE seam.
    local -a rows=() fixtures=()
    local row fixture ver tier rest want

    cat > "$TMP/os-sweep.sh" <<'SWEEP'
#!/usr/bin/env bash
# Written by tests/bats/preflight.bats. One process, every fixture named on
# the command line, "<fixture> <status of the os check>" per line.
repo=$1
shift
export REPO_DIR="$repo"
. "$repo/lib/exitcodes.sh"
. "$repo/lib/matrix.sh"
. "$repo/lib/preflight.sh"
for fixture in "$@"; do
    export PF_OS_RELEASE="${repo}/tests/os-release/${fixture}"
    pf_stage_a >/dev/null 2>&1 || true
    status='<no os record>'
    for rec in "${_PF_RECORDS[@]}"; do
        if [[ ${rec%%$'\t'*} == os ]]; then
            rest=${rec#*$'\t'}
            status=${rest%%$'\t'*}
        fi
    done
    printf '%s %s\n' "$fixture" "$status"
done
SWEEP

    mapfile -t rows < "$REPO/tests/os-release/expected.tsv"
    : > "$TMP/want"
    for row in "${rows[@]}"; do
        if [[ -z $row || $row == '#'* ]]; then
            continue
        fi
        # Split on tabs by hand. `mapfile` plus parameter expansion, because
        # splitting with IFS=$'\t' COLLAPSES ADJACENT TABS -- tab is IFS
        # whitespace -- and the debian-testing row is exactly two adjacent
        # tabs. A splitter that collapses them reads the tier out of the
        # version column and silently asserts nothing. expected.tsv's own
        # header warns about this, in those words.
        fixture=${row%%$'\t'*};  rest=${row#*$'\t'}
        rest=${rest#*$'\t'}
        ver=${rest%%$'\t'*};     rest=${rest#*$'\t'}
        tier=${rest%%$'\t'*}
        fixtures+=("$fixture")
        if [[ -z $ver ]]; then
            want=inconclusive
        else
            case $tier in
                supported) want=ok ;;
                legacy)    want=warn ;;
                *)         want=fail ;;
            esac
        fi
        printf '%s %s\n' "$fixture" "$want" >> "$TMP/want"
    done
    assert_eq 15 "${#fixtures[@]}" 'the number of fixtures the manifest lists'

    bash "$TMP/os-sweep.sh" "$REPO" "${fixtures[@]}" > "$TMP/got"
    run diff -u "$TMP/want" "$TMP/got"
    assert_rc 0
}

@test "a supported box is not described as having been tested" {
    # A REAL PAST DEFECT, and the reason this test is worth its line count.
    # This message used to end "...and exercised by this project's tests". It
    # was written while the supported tier shipped EMPTY, so nobody could read
    # the claim; D-11 pinned a ref, the tier became two rows, and the sentence
    # started printing on every run on a supported box -- asserting a test
    # campaign that had not happened.
    #
    # Both pairs in the supported tier have since been installed and dated in
    # tests/MATRIX-STATUS.md, which makes the distinction sharper rather than
    # moot: the tier is DERIVED from the pin, so moving the pin recomputes it
    # and repopulates it with rows nobody has installed yet. A message that
    # let a reader infer a test from a tier would be the same defect in a new
    # form, whatever the dated file happens to say this month.
    pf_load
    export PF_OS_RELEASE="$REPO/tests/os-release/debian-13.os-release"
    pf_stage_a || true
    assert_check os ok
    local detail
    detail=$(pf_detail os)
    assert_contains 'SUPPORTED tier' "$detail" 'the os record'
    assert_contains 'NOT a claim that it has been tested' "$detail" 'the os record'
    refute_contains 'exercised by this' "$detail" 'the os record'
}

@test "a legacy box warns and names the tier rather than passing in silence" {
    # `warn` and not `ok`: a silent pass here is precisely how "works on nine
    # distributions" outlived the evidence for it (D-07).
    pf_load
    export PF_OS_RELEASE="$REPO/tests/os-release/debian-11.os-release"
    pf_stage_a || true
    assert_check os warn
    assert_contains 'LEGACY tier' "$(pf_detail os)" 'the os record'
}

@test "a box in neither tier fails, and says which flag would let it through" {
    pf_load
    export PF_OS_RELEASE="$REPO/tests/os-release/kali-2024.2.os-release"
    pf_stage_a || true
    assert_check os fail
    assert_contains '--force-unsupported-os' "$(pf_detail os)" 'the os record'
}

@test "TPOT_FORCE_UNSUPPORTED_OS downgrades that failure to a warning and records that it was forced" {
    # Stage A runs BEFORE any answer file is read, so the only two channels
    # that can reach it are the flag and the environment. The record says so
    # itself, which is the whole point: a user who put the override in an
    # answer file needs to be told why it did nothing.
    pf_load
    export PF_OS_RELEASE="$REPO/tests/os-release/kali-2024.2.os-release"
    export TPOT_FORCE_UNSUPPORTED_OS=true
    pf_stage_a || true
    assert_check os warn
    assert_contains 'tpot_force_unsupported_os is set' "$(pf_detail os)" 'the forced os record'
    assert_contains 'unsupported and forced' "$(pf_detail os)" 'the forced os record'
}

@test "an os-release file that cannot be read is inconclusive, never unsupported" {
    # The distinction this arm exists for: reporting "your distribution is not
    # supported" when the truth is "the file was missing" sends somebody to
    # reinstall their operating system over a typo.
    pf_load
    export PF_OS_RELEASE="$TMP/no-such-os-release"
    pf_stage_a || true
    assert_check os inconclusive
    assert_contains 'missing, unreadable' "$(pf_detail os)" 'the os record'
}

@test "host.json records the tier and not only the supported boolean" {
    # D-07 again, at the artefact that outlives the run: `supported` is true
    # only for the supported tier, so a legacy box is `false` -- and false
    # alone cannot be told from "we have never heard of this release".
    # `matrix_tier` is what carries that, and result.json copies it through.
    #
    # THE KEY NAME IS ASSERTED, NOT INCIDENTAL. This producer wrote `os_tier`
    # while lib/result.sh read `matrix_tier`, so the tier preflight had
    # correctly computed was dropped on every run and result.json published a
    # value nothing had measured. Both sides are spelt matrix_tier now, and a
    # test that only checked the VALUE would have watched that happen.
    pf_load
    no_network
    export PF_OS_RELEASE="$REPO/tests/os-release/ubuntu-22.04.os-release"
    export RUNDIR="$TMP/run"
    mkdir -p "$RUNDIR"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_a || true
    pf_stage_b || true

    [[ -r "$RUNDIR/host.json" ]]
    run python3 -c 'import json, sys
doc = json.load(open(sys.argv[1]))
assert "os_tier" not in doc, "host.json still carries the key nothing reads: os_tier"
print(doc["os_id"], doc["os_version_id"], doc["matrix_tier"], doc["supported"])' "$RUNDIR/host.json"
    assert_rc 0
    assert_eq 'ubuntu 22.04 legacy False' "$output" 'what host.json says about this box'
}

# ===========================================================================
# STAGE A -- arch, systemd, runtime_dir
# ===========================================================================

@test "an architecture outside the supported set fails and names the ones that work" {
    pf_load
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\nprintf %%s\\\\n armv7l\n' > "$TMP/bin/uname"
    chmod +x "$TMP/bin/uname"
    PATH="$TMP/bin:$PATH"
    pf_stage_a || true
    assert_check arch fail
    assert_contains 'x86_64' "$(pf_detail arch)" 'the arch record'
    assert_contains 'aarch64' "$(pf_detail arch)" 'the arch record'
}

@test "aarch64 passes as well as x86_64" {
    # T-Pot runs on both and the matrix does not distinguish them; a check
    # that only ever saw the box it was written on would not know that.
    pf_load
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\nprintf %%s\\\\n aarch64\n' > "$TMP/bin/uname"
    chmod +x "$TMP/bin/uname"
    PATH="$TMP/bin:$PATH"
    pf_stage_a || true
    assert_check arch ok
    assert_eq 'aarch64' "$(pf_detail arch)" 'the arch record'
}

@test "a uname that answers nothing is inconclusive, not a failure" {
    pf_load
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/uname"
    chmod +x "$TMP/bin/uname"
    PATH="$TMP/bin:$PATH"
    pf_stage_a || true
    assert_check arch inconclusive
}

@test "a runtime parent that is not tmpfs fails and names --runtime-dir /dev/shm" {
    # The merged document holds the dashboard password. Writing it to a
    # persistent filesystem is the failure; the flag in the message is the
    # entire remedy, so it is asserted as behaviour and not as wording.
    #
    # The candidates are searched rather than assumed: this suite runs from
    # wherever the tree was unpacked, and a checkout under /tmp is itself on
    # tmpfs on most boxes -- which would make "$REPO" pass the check it is
    # here to fail. If nothing on this box is persistent, the test skips
    # loudly instead of asserting nothing.
    pf_load
    local candidate parent=''
    for candidate in "$REPO" "$HOME" /var/tmp /usr /etc; do
        if [[ -d $candidate ]] && [[ $(stat -f -c %T "$candidate" 2>/dev/null) != tmpfs ]]; then
            parent=$candidate
            break
        fi
    done
    skip_unless 'a directory on a persistent filesystem' test -n "$parent"
    OPT_RUNTIME_PARENT="$parent"
    pf_stage_a || true
    assert_check runtime_dir fail
    assert_contains 'not tmpfs' "$(pf_detail runtime_dir)" 'the runtime_dir record'
    assert_contains '--runtime-dir /dev/shm' "$(pf_detail runtime_dir)" 'the runtime_dir record'
}

@test "a tmpfs runtime parent passes and says which filesystem it saw" {
    pf_load
    skip_unless '/dev/shm on tmpfs' bash -c '[[ $(stat -f -c %T /dev/shm) == tmpfs ]]'
    OPT_RUNTIME_PARENT=/dev/shm
    pf_stage_a || true
    assert_check runtime_dir ok
    assert_contains 'tmpfs' "$(pf_detail runtime_dir)" 'the runtime_dir record'
}

@test "a runtime parent that does not exist fails before anything tries to use it" {
    pf_load
    OPT_RUNTIME_PARENT="$TMP/not-a-directory"
    pf_stage_a || true
    assert_check runtime_dir fail
    assert_contains 'does not exist' "$(pf_detail runtime_dir)" 'the runtime_dir record'
}

# ===========================================================================
# STAGE A -- answer_file
#
# Two rules, and a third property: a violation is the CALLER's mistake, so it
# is EX_USAGE (10) and not EX_PREFLIGHT (11). pf_verdict is contractually
# 0/11/12, so that fact travels separately through pf_usage_error.
# ===========================================================================

@test "supplying no answer file at all is not a problem" {
    pf_load
    pf_stage_a || true
    assert_check answer_file ok
    run pf_usage_error
    assert_rc 1
}

@test "an answer file inside the installer tree is refused, wherever it points" {
    # THE DEFECT THIS RULE EXISTS FOR: the installer this project replaces
    # kept a live tenant's passwords in a file committed to its own tree, one
    # `git add` away from being published. The check compares RESOLVED paths,
    # so a symlink from outside into the tree is caught too.
    #
    # REPO_DIR points at a decoy under $TMP, deliberately: proving this needs
    # a file inside "the tree", and no test in this suite may create one
    # inside the real repository.
    pf_load
    mkdir -p "$TMP/fakerepo"
    printf 'tpot_web_password: placeholder-never-a-real-value\n' > "$TMP/fakerepo/answers.yml"
    chmod 600 "$TMP/fakerepo/answers.yml"
    REPO_DIR="$TMP/fakerepo"
    OPT_CONFIG_FILES=("$TMP/fakerepo/answers.yml")
    pf_stage_a || true
    assert_check answer_file fail
    assert_contains 'inside the installer tree' "$(pf_detail answer_file)" 'the answer_file record'
    run pf_usage_error
    assert_rc 0
}

@test "a symlink that resolves into the installer tree is refused too" {
    pf_load
    mkdir -p "$TMP/fakerepo"
    printf 'tpot_web_password: placeholder-never-a-real-value\n' > "$TMP/fakerepo/answers.yml"
    ln -s "$TMP/fakerepo/answers.yml" "$TMP/outside.yml"
    REPO_DIR="$TMP/fakerepo"
    OPT_CONFIG_FILES=("$TMP/outside.yml")
    pf_stage_a || true
    assert_check answer_file fail
    assert_contains 'inside the installer tree' "$(pf_detail answer_file)" 'the answer_file record'
}

@test "an answer file with no secret in it has no permission requirement" {
    # There is nothing in it to protect. A rule that demanded 0600 of a file
    # holding only a port number would be theatre, and would train people to
    # chmod everything.
    pf_load
    printf 'tpot_install_type: h\n' > "$TMP/plain.yml"
    chmod 644 "$TMP/plain.yml"
    OPT_CONFIG_FILES=("$TMP/plain.yml")
    pf_stage_a || true
    assert_check answer_file ok
    assert_contains 'permissions not enforced' "$(pf_detail answer_file)" 'the answer_file record'
}

@test "an answer file that supplies a secret must be root-owned and 0600" {
    pf_load
    printf 'tpot_web_password: placeholder-never-a-real-value\n' > "$TMP/secret.yml"
    chmod 644 "$TMP/secret.yml"
    OPT_CONFIG_FILES=("$TMP/secret.yml")
    pf_stage_a || true
    assert_check answer_file fail
    assert_contains 'root-owned and 0600 or 0400' "$(pf_detail answer_file)" 'the answer_file record'
    run pf_usage_error
    assert_rc 0
}

@test "the JSON spelling of a secret key is recognised as well as the YAML one" {
    # The rule is a grep for the three secret-typed key names at the start of
    # a line, not a parse: stage A must work before python3 has been
    # established and must not need PyYAML. This is the JSON half of that
    # claim, in the shape a JSON answer file is actually written.
    pf_load
    printf '{\n  "tpot_web_password": "placeholder-never-a-real-value"\n}\n' > "$TMP/secret.json"
    chmod 644 "$TMP/secret.json"
    OPT_CONFIG_FILES=("$TMP/secret.json")
    pf_stage_a || true
    assert_check answer_file fail
    assert_contains 'root-owned and 0600 or 0400' "$(pf_detail answer_file)" 'the answer_file record'
}

@test "a single-line JSON answer file is held to the same permission rule" {
    # KNOWN GAP, found by this suite on 2026-09-04 and NOT a limitation of
    # this box, which is why it is skipped rather than deleted or inverted.
    #
    # The rule is anchored at the start of a line, so a compact one-line
    # document -- {"tpot_web_password": "..."} -- has `{` before the key and
    # is recorded as "no secret key; permissions not enforced". The
    # pretty-printed spelling above is caught; this one is not, and
    # lib/preflight.sh's header claims the grep "reads both the YAML and the
    # JSON spelling".
    #
    # What it costs: only the EARLY gate. lib/config.py checks the same two
    # rules again at the merge, from the parsed document, so a real run still
    # stops with EX_USAGE -- after the transcript has been opened, which is
    # what stage A exists to get in front of. Un-skip this the moment the
    # anchor accounts for a leading brace.
    skip 'known gap: the stage A secret-key grep is line-anchored, so compact JSON is missed'
    pf_load
    printf '{"tpot_web_password": "placeholder-never-a-real-value"}\n' > "$TMP/compact.json"
    chmod 644 "$TMP/compact.json"
    OPT_CONFIG_FILES=("$TMP/compact.json")
    pf_stage_a || true
    assert_check answer_file fail
}

@test "a password file given on the command line is held to the same rule, under the same id" {
    # --web-password-file is a PATH, never a value. A file whose entire
    # purpose is to hold a credential has no weaker claim on 0600 than an
    # answer file that happens to contain one.
    pf_load
    printf 'placeholder-never-a-real-value\n' > "$TMP/pw"
    chmod 644 "$TMP/pw"
    OPT_SECRET_FILES=("tpot_web_password=$TMP/pw")
    pf_stage_a || true
    assert_check answer_file fail
    assert_contains 'tpot_web_password' "$(pf_detail answer_file)" 'the answer_file record'
    assert_contains 'root-owned and 0600 or 0400' "$(pf_detail answer_file)" 'the answer_file record'
}

@test "an answer file that does not exist is refused rather than ignored" {
    pf_load
    OPT_CONFIG_FILES=("$TMP/never-written.yml")
    pf_stage_a || true
    assert_check answer_file fail
    assert_contains 'does not exist' "$(pf_detail answer_file)" 'the answer_file record'
}

@test "a root-owned 0600 answer file is accepted" {
    # The only arm of this rule that cannot be exercised without root: every
    # file this suite creates is owned by the unprivileged user running it, so
    # the accepting branch is unreachable here. Skipped loudly rather than
    # quietly absent -- "cannot be tested here" and "does not work" must never
    # look the same in the output.
    skip_unless 'root, to create a root-owned answer file' test "$(id -u)" = 0
    pf_load
    printf 'tpot_web_password: placeholder-never-a-real-value\n' > "$TMP/secret.yml"
    chmod 600 "$TMP/secret.yml"
    OPT_CONFIG_FILES=("$TMP/secret.yml")
    pf_stage_a || true
    assert_check answer_file ok
}

@test "a bad answer file exits 10 and not 11, even though the box also fails the root check" {
    # The real entrypoint, and the reason pf_usage_error exists at all: this
    # box fails `root` as well, and `fail` alone would make the run exit 11.
    # install.sh consults pf_usage_error FIRST, so the caller is told it made
    # a usage mistake rather than that the box was unsuitable.
    pf_load
    printf 'tpot_web_password: placeholder-never-a-real-value\n' > "$TMP/secret.yml"
    chmod 644 "$TMP/secret.yml"
    run_install --preflight-only --config "$TMP/secret.yml"
    assert_rc "$EX_USAGE"
    assert_contains 'broke the location or permission rule' "$output" 'the closing line'
}

# ===========================================================================
# STAGE A -- repo_tree
#
# An incomplete extraction and a world-writable tree: both free to check, both
# invisible until much later if they are not.
# ===========================================================================

@test "the shipped tree carries all seventeen files the manifest requires" {
    # The number is restated here on purpose. Growing the manifest is a
    # deliberate change to what a release must contain, and it should cost
    # two edits, not one.
    #
    # The status is ok OR warn: a clone made by a user whose umask leaves the
    # directory group-writable warns, and this box is one of those.
    pf_load
    pf_stage_a || true
    local status
    status=$(pf_status repo_tree)
    assert_matches '^(ok|warn)$' "$status" 'the repo_tree status against the real tree'
    assert_contains '17 required files' "$(pf_detail repo_tree)" 'the repo_tree record'
}

@test "one missing library is caught before anything is installed" {
    # The failure this replaces named a missing file three steps later, in the
    # middle of a dependency bootstrap that had already installed packages.
    copy_tree "$TMP/tree"
    rm -f "$TMP/tree/lib/args.sh"
    pf_load "$TMP/tree"
    pf_stage_a || true
    assert_check repo_tree fail
    assert_contains 'lib/args.sh' "$(pf_detail repo_tree)" 'the repo_tree record'
    assert_contains 'incomplete' "$(pf_detail repo_tree)" 'the repo_tree record'
}

@test "a checkout missing only the play says it is partial, not damaged" {
    # Two very different situations produce the same missing-file list and the
    # run stops either way, so the only thing left for the record to get right
    # is which one the reader should go and look at. A message saying merely
    # "this copy is incomplete" sends somebody to re-download files that are
    # not damaged.
    #
    # This branch does not fire in the shipped tree -- every manifest file is
    # present -- so a constructed tree is the only way it is ever executed.
    copy_tree "$TMP/tree"
    rm -f "$TMP/tree/site.yml" "$TMP/tree/verify.yml"
    pf_load "$TMP/tree"
    pf_stage_a || true
    assert_check repo_tree fail
    assert_contains 'play slice' "$(pf_detail repo_tree)" 'the repo_tree record'
    assert_contains 'partial rather than damaged' "$(pf_detail repo_tree)" 'the repo_tree record'
}

@test "a world-writable installer tree is refused, because root is about to execute what is in it" {
    copy_tree "$TMP/tree"
    chmod 777 "$TMP/tree"
    pf_load "$TMP/tree"
    pf_stage_a || true
    assert_check repo_tree fail
    assert_contains 'world-writable' "$(pf_detail repo_tree)" 'the repo_tree record'
}

@test "a group-writable installer tree warns without stopping the run" {
    copy_tree "$TMP/tree"
    chmod 775 "$TMP/tree"
    pf_load "$TMP/tree"
    pf_stage_a || true
    assert_check repo_tree warn
    assert_contains 'group-writable' "$(pf_detail repo_tree)" 'the repo_tree record'
}

# ===========================================================================
# STAGE B -- the resource thresholds
#
# These are the three checks whose seams stayed shut longest: PF_PROC_* were
# never pointed at anything, so the arithmetic, the unit handling and the
# unreadable-file arms had only ever run against one developer machine. The
# fixtures below are the point of this file.
#
# THE VALUE OF A FIXTURE IS WHETHER A REAL BOX CAN PRODUCE IT. Every memory
# fixture here was once a round number, and 8388608 kB -- exactly 8192 MiB --
# was doing the work of "a box at the floor". No machine reports that: MemTotal
# is physical RAM minus what firmware and the kernel reserved, so real guests
# of this project measured 7880, 8876 and 8864 MiB against assignments of
# 8192, 9216 and 9216 MB. The round fixture passed, the real 8 GiB box was
# refused, and the suite had nothing to say about it. Both ends of the
# tolerance are now pinned below with numbers a box can actually report.
#
# Stage B is driven through pf_stage_b with a merged PUBLIC document, rather
# than by calling the check functions, because that is how the thresholds
# reach them in a real run.
# ===========================================================================

# stage_b_with MEMINFO_KB PUBLIC_BODY -- the shared setup of the tests below.
stage_b_mem() {
    pf_load
    no_network
    printf 'MemTotal:       %s kB\nMemFree:         1000 kB\n' "$1" > "$TMP/meminfo"
    export PF_PROC_MEMINFO="$TMP/meminfo"
    public_json "$2"
    pf_stage_b || true
}

@test "memory at or above the recommendation passes" {
    stage_b_mem 33554432 '"tpot_ansible_source": "distro"'
    assert_check memory ok
    assert_contains '32768 MiB' "$(pf_detail memory)" 'the memory record'
}

@test "memory between the floor and the recommendation warns" {
    # 8 GiB is upstream's own sensor figure and this project's floor; 16 is
    # the hive figure and the recommendation. Between them the honest answer
    # is "this works and upstream does not promise it will".
    #
    # 8388608 kB is 8192 MiB EXACTLY, which is the arithmetic case and not a
    # real box: see the next two tests for what an 8 GiB machine reports.
    stage_b_mem 8388608 '"tpot_ansible_source": "distro"'
    assert_check memory warn
    assert_contains 'below the recommendation' "$(pf_detail memory)" 'the memory record'
}

@test "a real 8 GiB box reporting 7880 MiB is not refused for missing the 8192 floor" {
    # THE DEFECT THIS PINS. 8069120 kB is 7880 MiB, measured on a guest given
    # 8192 MB -- firmware and the kernel reserve the difference before
    # /proc/meminfo is written, so this is what the machine upstream calls its
    # Sensor minimum actually reports, and no amount of provisioning makes it
    # say 8192. Compared against the floor as a bare number it FAILED, and the
    # operator was told to pass --force-low-resources to install on hardware
    # that meets the requirement. The comparison now allows for the
    # reservation; the floor itself is untouched, because 8192 is upstream's
    # figure and not ours to move.
    stage_b_mem 8069120 '"tpot_ansible_source": "distro"'
    assert_check memory warn
    assert_contains 'below the recommendation' "$(pf_detail memory)" 'the memory record'
    refute_contains 'below the hard floor' "$(pf_detail memory)" 'the memory record'
    # The record has to show its working: an operator reading result.json and
    # finding 7880 recorded against a floor of 8192 is owed both numbers.
    assert_contains 'min 8192' "$(pf_detail memory)" 'the memory record'
    assert_contains '7782' "$(pf_detail memory)" 'the memory record'
}

@test "the tolerance is a few percent and not an open door" {
    # 7967744 kB is 7781 MiB, one MiB under the effective threshold of 7782
    # (95% of 8192, rounded down by integer arithmetic). A box this far below
    # the floor is still refused, which is what stops the tolerance from
    # becoming a silent second floor: it exists to absorb a firmware
    # reservation of a few percent, measured at 3.7-3.9% on three guests, and
    # nothing wider.
    stage_b_mem 7967744 '"tpot_ansible_source": "distro"'
    assert_check memory fail
    assert_contains 'below the hard floor' "$(pf_detail memory)" 'the memory record'
}

@test "memory below the floor fails and names the flag that would override it" {
    stage_b_mem 4194304 '"tpot_ansible_source": "distro"'
    assert_check memory fail
    assert_contains 'below the hard floor' "$(pf_detail memory)" 'the memory record'
    assert_contains '--force-low-resources' "$(pf_detail memory)" 'the memory record'
}

@test "--force-low-resources downgrades that failure to a warning and records that it was forced" {
    # A forced run that looked identical to a clean one would make the
    # artefact a lie the first time somebody read it back to explain why a box
    # fell over. tpot_force_low_resources is what --force-low-resources merges
    # into the public document, so this is the flag's real path.
    stage_b_mem 4194304 '"tpot_ansible_source": "distro", "tpot_force_low_resources": true'
    assert_check memory warn
    assert_contains 'BELOW THE HARD FLOOR' "$(pf_detail memory)" 'the forced memory record'
    assert_contains 'recorded as forced' "$(pf_detail memory)" 'the forced memory record'
}

@test "the memory floor comes from the merged configuration when it sets one" {
    # Same box, different threshold: 4 GiB fails against the shipped floor and
    # passes against a configured one. A check that ignored the merged
    # document would give the same answer twice.
    stage_b_mem 4194304 '"tpot_ansible_source": "distro", "tpot_min_memory_mb": 1024, "tpot_warn_memory_mb": 2048'
    assert_check memory ok
    assert_contains 'min 1024' "$(pf_detail memory)" 'the memory record'
}

@test "a meminfo with no MemTotal line is inconclusive, and never zero" {
    # The arm that matters most: treating an unparseable file as 0 MiB would
    # hard-fail a box with plenty of memory, and treating it as fine would
    # pass one with none.
    pf_load
    no_network
    printf 'SwapTotal:      0 kB\n' > "$TMP/meminfo"
    export PF_PROC_MEMINFO="$TMP/meminfo"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check memory inconclusive
    assert_contains 'no usable MemTotal' "$(pf_detail memory)" 'the memory record'
}

@test "an unreadable meminfo is inconclusive and still names both thresholds" {
    pf_load
    no_network
    export PF_PROC_MEMINFO="$TMP/no-such-meminfo"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check memory inconclusive
    assert_contains 'min 8192' "$(pf_detail memory)" 'the memory record'
    assert_contains 'recommended 16384' "$(pf_detail memory)" 'the memory record'
}

@test "a single-processor box fails the cpu floor of two" {
    # The floor is 2 and the recommendation 4, and NEITHER HAS AN UPSTREAM
    # SOURCE: upstream states no CPU figure at all, and the two inherited
    # tenant guides disagree with each other (4 against 8). The floor sits
    # below both so that the only outcome which can stop a run rests on a
    # number nobody argues about. This test pins the arithmetic, not the
    # justification.
    pf_load
    no_network
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\nprintf %%s\\\\n 1\n' > "$TMP/bin/nproc"
    chmod +x "$TMP/bin/nproc"
    PATH="$TMP/bin:$PATH"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check cpus fail
    assert_contains 'min 2' "$(pf_detail cpus)" 'the cpus record'
    assert_contains '--force-low-resources' "$(pf_detail cpus)" 'the cpus record'
}

@test "two processors clear the floor and warn about the recommendation" {
    pf_load
    no_network
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\nprintf %%s\\\\n 2\n' > "$TMP/bin/nproc"
    chmod +x "$TMP/bin/nproc"
    PATH="$TMP/bin:$PATH"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check cpus warn
    assert_contains 'below the recommendation' "$(pf_detail cpus)" 'the cpus record'
}

@test "the processor count falls back to cpuinfo when nproc and getconf are both absent" {
    # The third seam, and the one no box this was written on could exercise:
    # both commands exist everywhere a developer works. A container tier for
    # the legacy tier's minimal images is exactly where they would not.
    pf_load
    printf 'processor\t: 0\nvendor\t: fake\nprocessor\t: 1\nprocessor\t: 2\nprocessor\t: 3\n' > "$TMP/cpuinfo"
    export PF_PROC_CPUINFO="$TMP/cpuinfo"
    mkdir -p "$TMP/nobin"
    # A command substitution is its own subshell, so $PATH outside this line
    # is untouched -- teardown still has an `rm` to call.
    local out
    out=$( PATH="$TMP/nobin"; _PF_RECORDS=(); _tpot_pf_check_cpus; pf_records )
    assert_contains $'cpus\tok\t4 ' "$out" 'the cpus record with no nproc and no getconf'
}

@test "a cpuinfo naming no processors is inconclusive rather than a zero-cpu box" {
    pf_load
    printf 'vendor\t: fake\n' > "$TMP/cpuinfo"
    export PF_PROC_CPUINFO="$TMP/cpuinfo"
    mkdir -p "$TMP/nobin"
    local out
    out=$( PATH="$TMP/nobin"; _PF_RECORDS=(); _tpot_pf_check_cpus; pf_records )
    assert_contains $'cpus\tinconclusive' "$out" 'the cpus record'
}

# df_stub -- a df reporting 10 GiB free on one filesystem, first on $PATH.
df_stub() {
    mkdir -p "$TMP/bin"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf %%s\\\\n "Filesystem 1024-blocks Used Available Capacity Mounted-on"\n'
        printf 'printf %%s\\\\n "/dev/fake 209715200 100 10485760 99%% /"\n'
    } > "$TMP/bin/df"
    chmod +x "$TMP/bin/df"
    PATH="$TMP/bin:$PATH"
}

@test "a filesystem below the disk floor fails, separately for home and for docker" {
    # Measured separately on purpose: /home and the docker directory are
    # frequently different devices, and the one that fills is usually not the
    # one somebody checked.
    #
    # THIS TEST ASSERTS ONLY WHAT IS TRUE ON EVERY BOX. It also asserted the
    # words "does not exist yet" in the disk_docker record -- a clause the
    # check emits only when the docker directory is ABSENT. That passed on a
    # developer box with no docker and failed on a GitHub runner, whose image
    # has docker installed and where the record is correct and differently
    # worded. The product was right both times; the test had baked in a
    # property of the machine it was written on, and CI found it on the first
    # run that reached this far. Both wordings have a test each, below.
    pf_load
    no_network
    df_stub
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check disk_home fail
    assert_check disk_docker fail
    assert_contains '10 GiB free' "$(pf_detail disk_home)" 'the disk_home record'
    assert_contains '10 GiB free' "$(pf_detail disk_docker)" 'the disk_docker record'
    assert_contains 'below the hard floor' "$(pf_detail disk_docker)" 'the disk_docker record'
}

@test "when the docker directory is absent the record names the filesystem that will hold it" {
    pf_load
    no_network
    df_stub
    export PF_DOCKER_DIR="$TMP/no-such-docker-dir"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check disk_docker fail
    assert_contains 'does not exist yet' "$(pf_detail disk_docker)" 'the disk_docker record'
    assert_contains 'will hold it' "$(pf_detail disk_docker)" 'the disk_docker record'
}

@test "when the docker directory exists the record does not claim it is absent" {
    # The arm a runner with docker installed takes, and the one that was
    # untested until CI ran the suite somewhere other than a developer box.
    pf_load
    no_network
    df_stub
    export PF_DOCKER_DIR="$TMP/docker"
    mkdir -p "$PF_DOCKER_DIR"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check disk_docker fail
    assert_contains "$PF_DOCKER_DIR" "$(pf_detail disk_docker)" 'the disk_docker record'
    refute_contains 'does not exist yet' "$(pf_detail disk_docker)" 'the disk_docker record'
}

@test "--force-low-resources downgrades a disk failure as well, and says which floor was crossed" {
    pf_load
    no_network
    mkdir -p "$TMP/bin"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'printf %%s\\\\n "Filesystem 1024-blocks Used Available Capacity Mounted-on"\n'
        printf 'printf %%s\\\\n "/dev/fake 209715200 100 10485760 99%% /"\n'
    } > "$TMP/bin/df"
    chmod +x "$TMP/bin/df"
    PATH="$TMP/bin:$PATH"
    public_json '"tpot_ansible_source": "distro", "tpot_force_low_resources": true'
    pf_stage_b || true
    assert_check disk_home warn
    assert_contains 'recorded as forced' "$(pf_detail disk_home)" 'the forced disk_home record'
}

@test "a df that will not answer is inconclusive, not an empty disk" {
    pf_load
    no_network
    mkdir -p "$TMP/bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/bin/df"
    chmod +x "$TMP/bin/df"
    PATH="$TMP/bin:$PATH"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check disk_home inconclusive
    assert_check disk_docker inconclusive
}

@test "max_map_count below what Elasticsearch needs warns and never fails" {
    # WARN ONLY, on purpose: os_prep raises it later through its own
    # /etc/sysctl.d file. What the record is for is the BEFORE value, so that
    # somebody reading result.json can tell a box that was already tuned from
    # one this installer tuned.
    pf_load
    no_network
    printf '65530\n' > "$TMP/mmc"
    export PF_PROC_MAX_MAP_COUNT="$TMP/mmc"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check max_map_count warn
    assert_contains '262144' "$(pf_detail max_map_count)" 'the max_map_count record'
}

@test "max_map_count already high enough passes" {
    pf_load
    no_network
    printf '262144\n' > "$TMP/mmc"
    export PF_PROC_MAX_MAP_COUNT="$TMP/mmc"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check max_map_count ok
}

@test "a max_map_count that is not a number is inconclusive" {
    pf_load
    no_network
    printf 'not-a-number\n' > "$TMP/mmc"
    export PF_PROC_MAX_MAP_COUNT="$TMP/mmc"
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check max_map_count inconclusive
}

# ===========================================================================
# STAGE B -- ports
#
# The union of two disjoint sets. Ours is configurable; upstream's tcp/25,
# tcp/53 and udp/53 are not, because relaxing them here would not make the
# install work -- it would only move upstream's refusal to a point where we
# had already changed the box.
# ===========================================================================

# ss_stub TCP_LINES UDP_LINES -- a listening-socket fixture, first on $PATH.
#   `ss -H -t -l -n -p` and `ss -H -u -l -n -p` are two invocations and the
#   stub tells them apart the same way ss does, by the flag.
ss_stub() {
    mkdir -p "$TMP/bin"
    printf '%s\n' "$1" > "$TMP/ss-tcp"
    printf '%s\n' "$2" > "$TMP/ss-udp"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'for a in "$@"; do if [[ $a == -*u* ]]; then cat %q; exit 0; fi; done\n' "$TMP/ss-udp"
        printf 'cat %q\n' "$TMP/ss-tcp"
    } > "$TMP/bin/ss"
    chmod +x "$TMP/bin/ss"
    PATH="$TMP/bin:$PATH"
}

@test "a listener on tcp/25 fails here, because upstream aborts on it after the box has been changed" {
    # THE DEFECT THIS UNION FIXES. This check used to look only at ours --
    # 22, 64295, 64297, 64298 -- while upstream's install.sh aborts on tcp/25,
    # tcp/53 and udp/53, which we never looked at. A stock Debian netinst
    # ships exim4 on 127.0.0.1:25 and upstream's own comment says a
    # loopback-only listener counts, so such a box passed here, was mutated by
    # os_prep, and was refused an hour later by a check we could have run in
    # milliseconds while it was still untouched.
    pf_load
    no_network
    ss_stub 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 100 127.0.0.1:25 0.0.0.0:* users:(("exim4",pid=2,fd=4))' ''
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check ports fail
    assert_contains 'tcp/25' "$(pf_detail ports)" 'the ports record'
    assert_contains 'UPSTREAM aborts' "$(pf_detail ports)" 'the ports record'
    assert_contains 'not configurable' "$(pf_detail ports)" 'the ports record'
}

@test "the host's own sshd on 22 is not a conflict, because upstream moves it and puts a honeypot there" {
    pf_load
    no_network
    ss_stub 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' ''
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check ports ok
    assert_contains 'layout pre_install' "$(pf_detail ports)" 'the ports record'
}

@test "systemd-resolved on 53 is exempt, exactly as upstream exempts it" {
    # Mirrored from upstream's own check, TRUNCATED NAME AND ALL: the unit is
    # systemd-resolveD, but ss cuts the process name at 15 characters, so what
    # upstream compares against -- and what arrives here -- is
    # `systemd-resolve`. Comparing the full name would match nothing, and
    # would match nothing silently.
    pf_load
    no_network
    ss_stub 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))
LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=3,fd=17))' \
'UNCONN 0 0 127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=3,fd=16))'
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check ports ok
    assert_contains "upstream's own port check exempts" "$(pf_detail ports)" 'the ports record'
}

@test "a port held by a process this run may not identify is inconclusive, not free" {
    # Without privilege ss prints no users:((...)) field. That is not "the
    # port is free" and it is not "sshd has it" -- it is a check that could
    # not be exercised, and in a full run stage A has already failed on uid,
    # so this only ever surfaces under --preflight-only, which is exactly
    # where honesty about it matters.
    pf_load
    no_network
    ss_stub 'LISTEN 0 128 0.0.0.0:64297 0.0.0.0:*' ''
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check ports inconclusive
    assert_contains 'not privileged to identify' "$(pf_detail ports)" 'the ports record'
}

@test "without ss the ports check is inconclusive and names the package that provides it" {
    pf_load
    no_network
    mkdir -p "$TMP/nobin"
    local out
    out=$( PATH="$TMP/nobin"; _PF_RECORDS=(); _tpot_pf_check_ports; pf_records )
    assert_contains $'ports\tinconclusive' "$out" 'the ports record with no ss'
    assert_contains 'iproute2' "$out" 'the ports record with no ss'
}

# ===========================================================================
# reachability_apt and the mirror-list indirection.
#
# These exist because of a measured failure, not a hypothetical one. On
# 2026-09-05 the first real install of this project ran `--check` against a
# stock Debian 13 cloud image and exited 11 with EVERY row reading OK, WARN or
# INCONCLUSIVE and no FAIL anywhere. The cause was reachability_apt: that image
# configures no apt URL at all, only
#
#     URIs: mirror+file:///etc/apt/mirrors/debian.list
#
# which the old _tpot_pf_apt_mirror skipped as "local". reachability_apt is a
# HARD check, and pf_verdict turns a hard inconclusive into EX_PREFLIGHT in a
# full run -- so the installer refused to start on the only distribution this
# release claims to support, and said nothing that would lead anyone to the
# reason. The fixtures below are that image's real layout, byte for byte.
# ===========================================================================

# Build a sources tree under $TMP and point the PF_APT_ROOT seam at it.
_apt_tree() {
    mkdir -p "$TMP/root/etc/apt/sources.list.d" "$TMP/root/etc/apt/mirrors"
    export PF_APT_ROOT="$TMP/root"
}

@test "a Debian cloud image's mirror+file: source is followed to the mirror it names" {
    _apt_tree
    printf '# see sources.list.d\n' > "$TMP/root/etc/apt/sources.list"
    cat > "$TMP/root/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb deb-src
URIs: mirror+file:///etc/apt/mirrors/debian.list
Suites: trixie trixie-updates trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    printf 'https://deb.debian.org/debian\n' > "$TMP/root/etc/apt/mirrors/debian.list"
    pf_load
    assert_eq 'https://deb.debian.org/debian' "$(_tpot_pf_apt_mirror)" 'the mirror the indirection resolves to'
    assert_eq 'deb.debian.org' "$(_tpot_pf_url_host "$(_tpot_pf_apt_mirror)")" 'the host that will be tested'
}

@test "that image does not produce the hard inconclusive that refused to install on it" {
    # The regression, stated as the property that was violated rather than as
    # the message that was printed.
    _apt_tree
    cat > "$TMP/root/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: mirror+file:///etc/apt/mirrors/debian.list
Suites: trixie
Components: main
EOF
    printf 'https://deb.debian.org/debian\n' > "$TMP/root/etc/apt/mirrors/debian.list"
    pf_load
    run _tpot_pf_apt_mirror
    assert_rc 0
    assert_ne 'local-only' "$output" 'the resolution of a cloud-image sources tree'
}

@test "a URL stated outright in the sources beats one that has to be read out of a list" {
    _apt_tree
    printf 'deb http://ftp.uk.debian.org/debian trixie main\n' > "$TMP/root/etc/apt/sources.list"
    cat > "$TMP/root/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: mirror+file:///etc/apt/mirrors/debian.list
Suites: trixie
Components: main
EOF
    printf 'https://deb.debian.org/debian\n' > "$TMP/root/etc/apt/mirrors/debian.list"
    pf_load
    assert_eq 'http://ftp.uk.debian.org/debian' "$(_tpot_pf_apt_mirror)" 'the source preferred'
}

@test "a REMOTE mirror list is tested at the host serving the list, without following it" {
    # mirror+http:// is a different animal from mirror+file://: the list is
    # itself fetched over the network, so that host is a real dependency and
    # is the right thing to reach for.
    _apt_tree
    printf 'deb mirror+https://mirrors.example.net/list trixie main\n' > "$TMP/root/etc/apt/sources.list"
    pf_load
    assert_eq 'https://mirrors.example.net/list' "$(_tpot_pf_apt_mirror)" 'the remote mirror list'
}

@test "the pre-2.0 mirror:// spelling resolves over http" {
    _apt_tree
    printf 'deb mirror://mirrors.example.net/list trixie main\n' > "$TMP/root/etc/apt/sources.list"
    pf_load
    assert_eq 'http://mirrors.example.net/list' "$(_tpot_pf_apt_mirror)" 'the legacy spelling'
}

@test "a mirror list that names no URL falls back to local-only rather than claiming a mirror" {
    _apt_tree
    cat > "$TMP/root/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: mirror+file:///etc/apt/mirrors/debian.list
Suites: trixie
Components: main
EOF
    printf '# every mirror commented out\n' > "$TMP/root/etc/apt/mirrors/debian.list"
    pf_load
    assert_eq 'local-only' "$(_tpot_pf_apt_mirror)" 'a mirror list with nothing in it'
}

@test "a mirror list that does not exist is not fatal" {
    _apt_tree
    cat > "$TMP/root/etc/apt/sources.list.d/debian.sources" <<'EOF'
Types: deb
URIs: mirror+file:///etc/apt/mirrors/absent.list
Suites: trixie
Components: main
EOF
    pf_load
    run _tpot_pf_apt_mirror
    assert_rc 0
    assert_eq 'local-only' "$output" 'a mirror+file: pointing at nothing'
}

@test "an apt configuration that is only file: sources is not-applicable, and costs the run nothing" {
    # The reachability_pypi precedent. A local repository is not a measurement
    # we failed to take; it is a dependency this box does not have. Recording
    # `inconclusive` for it would abort a working offline install, because
    # reachability_apt is HARD.
    _apt_tree
    printf 'deb file:///srv/mirror trixie main\n' > "$TMP/root/etc/apt/sources.list"
    pf_load
    assert_eq 'local-only' "$(_tpot_pf_apt_mirror)" 'a purely local apt setup'
    _tpot_pf_check_reachability_apt
    assert_eq 'not-applicable' "$(pf_status reachability_apt)" 'the status recorded for a local repository'
    assert_eq "$EX_OK" "$(pf_verdict 0)" 'the verdict of a full run against a local repository'
}

@test "no readable apt sources at all is still inconclusive, because that is a box we could not measure" {
    # The one arm that must NOT become not-applicable: an apt with no sources
    # is not "no dependency", it is a box nobody can explain.
    _apt_tree
    pf_load
    run _tpot_pf_apt_mirror
    assert_rc 1
    _tpot_pf_check_reachability_apt
    assert_eq 'inconclusive' "$(pf_status reachability_apt)" 'the status recorded for an unreadable apt'
    assert_eq "$EX_PREFLIGHT" "$(pf_verdict 0)" 'a full run must not install from a box it could not measure'
}

# ===========================================================================
# Socket activation, and the port-22 holder.
#
# THE DEFECT THESE COVER, MEASURED ON 2026-09-05.
#   Under systemd socket activation, ssh.socket owns the listening socket and
#   sshd_config's `Port` is IGNORED -- not overridden, not consulted. Upstream
#   T-Pot's port move appends `Port 64295` to sshd_config, so on such a host it
#   changes nothing about the listener: `sshd -T` reports 64295 and the kernel
#   reports 22, permanently.
#
#   preflight had an arm for exactly this, and it was UNREACHABLE. It required
#   the port-22 holder list to be exactly "systemd", but `ss` names every
#   process holding the socket -- so an open ssh session, which is how anybody
#   runs an installer on a remote box, adds a per-connection sshd and the list
#   becomes "sshd/systemd". The arm fired only on a host nobody was logged in
#   to. Reproduced on a real guest by putting Debian into Ubuntu's shape.
#
#   It also recorded the host as ALLOWED, which was the worse half: the install
#   would complete, administrative ssh would never move, the honeypot could not
#   bind 22 after the reboot, and the closing notice would tell the operator to
#   reconnect on a port that is not listening.
#
#   Debian ships ssh.socket disabled. UBUNTU ENABLES IT BY DEFAULT, and ubuntu
#   is the other half of the supported tier.
# ===========================================================================

# systemctl_stub UNIT... -- a systemctl whose `is-active` succeeds only for the
#   units named here. Everything else about it is inert.
systemctl_stub() {
    mkdir -p "$TMP/bin"
    printf '%s\n' "$@" > "$TMP/active-units"
    {
        printf '#!/usr/bin/env bash\n'
        printf 'if [[ ${1:-} == is-active ]]; then\n'
        printf '  u=${!#}\n'
        printf '  grep -qx -- "$u" %q && exit 0\n' "$TMP/active-units"
        printf '  exit 3\n'
        printf 'fi\n'
        printf 'exit 0\n'
    } > "$TMP/bin/systemctl"
    chmod +x "$TMP/bin/systemctl"
    PATH="$TMP/bin:$PATH"
}

@test "a socket-activated host is refused, and the reason names socket activation rather than the holder" {
    pf_load
    no_network
    # The shape a live ssh session produces: TWO holders, which is what made
    # the old exact-match arm unreachable.
    ss_stub 'LISTEN 0 4096 *:22 *:* users:(("sshd",pid=976,fd=3),("systemd",pid=1,fd=92))' ''
    systemctl_stub ssh.socket
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check ports fail
    local d; d=$(pf_detail ports)
    assert_contains 'SOCKET-ACTIVATED' "$d" 'the ports record'
    assert_contains 'ssh.socket' "$d" 'the ports record'
    # The remedy is the point: a refusal that does not say what to change is
    # a refusal the operator cannot act on.
    assert_contains 'systemctl disable --now' "$d" 'the ports record'
    refute_contains 'which is not the host ssh' "$d" 'the ports record'
}

@test "socket activation is recognised with no session open, which is the only case the old arm caught" {
    pf_load
    no_network
    ss_stub 'LISTEN 0 4096 *:22 *:* users:(("systemd",pid=1,fd=92))' ''
    systemctl_stub ssh.socket
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check ports fail
    assert_contains 'SOCKET-ACTIVATED' "$(pf_detail ports)" 'the ports record'
}

@test "an ordinary sshd on 22 still passes, and is not mistaken for socket activation" {
    # The no-regression half. Debian ships ssh.socket disabled and this is
    # the shape every install so far has run against.
    pf_load
    no_network
    ss_stub 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=705,fd=6))' ''
    systemctl_stub
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check ports ok
    local d; d=$(pf_detail ports)
    assert_contains 'allowed' "$d" 'the ports record'
    refute_contains 'SOCKET-ACTIVATED' "$d" 'the ports record'
}

@test "a holder that is neither ssh nor systemd is still refused, and says so plainly" {
    pf_load
    no_network
    ss_stub 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("nginx",pid=99,fd=7))' ''
    systemctl_stub ssh.socket
    public_json '"tpot_ansible_source": "distro"'
    pf_stage_b || true
    assert_check ports fail
    assert_contains 'not the host ssh' "$(pf_detail ports)" 'the ports record'
}
