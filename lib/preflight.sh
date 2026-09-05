# lib/preflight.sh -- the two preflight stages, in bash, before Ansible exists.
#
# WHY THIS FILE EXISTS
#   A honeypot installer runs for thirty to ninety minutes and it runs
#   unattended. Everything it can find out cheaply and safely, it must find out
#   BEFORE it changes anything: the installer this one replaces mutated the
#   whole tree with `sed -i` and only then asked whether it was root, so a run
#   that aborted for being unprivileged had already rewritten its own
#   credentials file.
#
#   Preflight therefore comes first and MUTATES NOTHING. That is meant
#   literally: nothing here creates, writes, installs, downloads or configures
#   anything outside $RUNDIR -- the run's own 0700 directory on tmpfs, which
#   install.sh created and the exit trap destroys. The two files written there,
#   preflight.tsv and host.json, are this process talking to itself.
#
# THE FIVE STATUSES, AND WHY THERE ARE FIVE
#   ok              checked, and it passed
#   warn            checked, below the recommendation but above the floor
#   fail            checked, and it failed
#   inconclusive    COULD NOT BE CHECKED AT ALL
#   not-applicable  there was nothing to check -- this run has no such
#                   dependency, so the question does not arise
#
#   The fourth one is the point of the design. A check that could not be
#   exercised is not a pass, and a report that silently drops it green-lights
#   exactly what it declined to test. In a full run an inconclusive HARD check
#   stops the run with EX_PREFLIGHT -- it fails closed. Only --preflight-only
#   downgrades it, to EX_INCONCLUSIVE (12) -- which is what WOULD let a CI tier
#   running preflight in containers be honest about a distribution in seconds
#   instead of installing on it for hours. NO SUCH TIER EXISTS IN THIS TREE:
#   there is no .github/workflows and no container definition, and the nine
#   distributions such a tier would cover are the LEGACY tier of D-07 --
#   documented, and never claimed as tested. The supported tier is empty until
#   a ref is pinned.
#
#   THE FIFTH EXISTS BECAUSE THE FOURTH WAS BEING AVOIDED. reachability_pypi
#   recorded `ok` on two paths where pypi.org had never been contacted: the
#   reasoning was sound -- no virtualenv will be built, so that host is not a
#   dependency of this run -- but `ok` is the word for a check that ran and
#   passed, and this one did not run. `inconclusive` was not the answer
#   either: reachability_pypi is a HARD check, so it would have aborted every
#   legitimate `tpot_ansible_source: distro` run with EX_PREFLIGHT for a host
#   nothing was going to contact. `not-applicable` says the third thing, which
#   is the thing that was true, and pf_verdict treats it exactly as it treats
#   `ok`: it is neither a failure nor a missing measurement, because there was
#   nothing to measure.
#
#   IT IS NOT A SOFTER `inconclusive`, and the distinction is the whole value
#   of having it. `not-applicable` means the dependency does not exist on this
#   path. `inconclusive` means it exists and could not be tested. Using the
#   first where the second is true green-lights precisely what was declined --
#   the failure this file exists to prevent.
#
#   result.json carries the status string through verbatim (lib/result.sh
#   copies the TSV field and interprets none of it), so a consumer can tell a
#   not-applicable check from a failed one and from an untested one without a
#   lookup table. Anything written LATER that switches on the status has to
#   learn the fifth value: docs/verification.md and the bats suite are the two
#   named throughout these comments, and neither exists yet.
#
# THE TWO STAGES
#   Stage A  zero dependency, zero mutation, BEFORE the configuration merge.
#            It may assume nothing except a POSIX shell and coreutils, because
#            its whole job is to establish that the box is one we know how to
#            talk to. It is also what proves /run is usable, so it runs before
#            $RUNDIR exists and buffers its records in memory.
#   Stage B  after the merge, still zero mutation. It has thresholds, ports and
#            paths from the merged configuration, so it can measure the box
#            against what this particular run intends to do.
#
# WHAT IT READS, AND WHAT IT DELIBERATELY DOES NOT
#   Stage B reads $PUBLIC_JSON -- the merged document with every secret-typed
#   key REMOVED -- and never $MERGED_JSON. Preflight therefore cannot print a
#   credential even by mistake, because it never has one. The single exception
#   is the `secret_length` check, which reads the LENGTHS of the values
#   lib/log.sh registered for redaction, and never a value.
#
# CONVENTIONS THIS FILE OBEYS
#   * No `read` builtin anywhere. `tests/check-no-tty.sh` fails the build on
#     one, because "this installer structurally cannot block on a prompt" is
#     the product's central promise. Line-oriented input uses `mapfile`, and
#     fields are split with parameter expansion, never with `read -a`.
#   * Nothing prints the environment. Nothing runs `sed`, `awk` or `eval`.
#   * It inherits install.sh's C.UTF-8 locale and never sets the two plain-C
#     spellings. They are written out below rather than alluded to, because a
#     warning that will not name what it forbids is not a warning -- and each
#     naming therefore carries its own exemption for tests/check-locale.sh,
#     which hunts exactly this text and is right to:
#     gate-allow: locale-prose the next line NAMES the setting in order to forbid it; nothing here sets one
#       `LC_ALL=C` and
#     gate-allow: locale-prose the same again, for the second spelling this paragraph warns against
#       `LANG=C` look like the same byte-stability guarantee as C.UTF-8 and are
#     not: ansible-core refuses to start under them -- "Ansible requires the
#     locale encoding to be UTF-8; Detected None", exit 1 before it does
#     anything -- so a plain C anywhere in this tree is a latent total failure
#     that surfaces an hour into a run. C.UTF-8 is byte-stable in exactly the
#     same way and needs no locale-gen; that it is PRESENT has been verified
#     only on the box this was written on, and is assumed elsewhere.
#   * Every _tpot_pf_check_* function returns 0 unconditionally and reports its
#     verdict by calling pf_record. install.sh runs under `set -e`, so a check
#     that returned non-zero would abort the run instead of reporting.
#
# shellcheck shell=bash

# Sourcing this file twice must be harmless: the second `readonly` would
# otherwise fail and, under `set -e`, take the caller down with it.
if [[ -n ${_TPOT_PREFLIGHT_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_PREFLIGHT_SH_LOADED=1

# ---------------------------------------------------------------------------
# The closed lists of check ids.
#
# An id is part of the contract: docs/verification.md, tests/bats/preflight.bats
# and result.json all name checks by these strings. Adding one is a documented
# change, not an implementation detail, which is why they are written here in
# the order they are performed rather than being scattered through the file.
# ---------------------------------------------------------------------------
readonly PF_IDS_STAGE_A=(
    root apt python3 os arch systemd runtime_dir answer_file repo_tree
)
readonly PF_IDS_STAGE_B=(
    memory cpus disk_home disk_docker max_map_count ports upstream_gate
    reachability_upstream reachability_apt reachability_galaxy reachability_pypi
    existing_tpot exposure input_complete secret_length
)

# Hard checks stop a run. A hard check that could not be exercised stops it
# too -- that is the fail-closed rule. Everything not named here is soft: it
# can warn, it can be informational, and being unable to run it is not grounds
# to refuse to install.
#
# `answer_file` is listed as hard so that a caller which ignores
# pf_usage_error still stops; the correct code for it is EX_USAGE, not
# EX_PREFLIGHT, and pf_usage_error is how install.sh learns that.
#
# `upstream_gate` is deliberately SOFT, and it is the one place in this file
# where that needs defending. It pre-empts a gate that belongs to somebody
# else: upstream's install.sh applies it on the box, and the copy that applies
# it is whichever copy this run fetches (D-10), not one we can read from here.
# Not being able to answer that question is therefore the normal state of a
# tree whose ref is not pinned yet, and failing closed on it would refuse every
# run for a reason that is not about this box. It can still stop a run: a
# `fail` from any check, hard or soft, is EX_PREFLIGHT -- and this check does
# return `fail`, but only when the gate rules are known to hold for the ref
# that is actually pinned, which no legal pin can currently make true (see the
# dormancy note beside _PF_UPSTREAM_GATE_VALID_REFS below: the list holds only
# `master`, and the schema refuses `master`). So today upstream_gate can warn
# and it can be inconclusive; it cannot stop a run. An unpinned ref already
# stops a full run through `reachability_upstream`, which IS hard.
_tpot_pf_is_hard() {
    case ${1:-} in
        root|apt|python3|os|arch|systemd|runtime_dir|answer_file|repo_tree)
            return 0 ;;
        memory|cpus|disk_home|disk_docker|ports)
            return 0 ;;
        reachability_upstream|reachability_apt|reachability_galaxy|reachability_pypi)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Built-in fallbacks.
#
# These are the shipped defaults from inventories/example/group_vars/all.yml.
# They are used ONLY when the merged document could not be read, and that
# situation is itself recorded as `input_complete: inconclusive` -- so a stage
# B run on defaults is never mistaken for a stage B run on real configuration.
# ---------------------------------------------------------------------------
readonly _PF_DEF_MIN_MEMORY_MB=8192
readonly _PF_DEF_WARN_MEMORY_MB=16384
readonly _PF_DEF_MIN_CPUS=2
readonly _PF_DEF_WARN_CPUS=4
readonly _PF_DEF_MIN_DISK_GB=64
readonly _PF_DEF_WARN_DISK_GB=256
readonly _PF_DEF_MAX_MAP_COUNT=262144

# OUR port set. Configurable through tpot_required_ports, all TCP.
#
# 64294 is here because a sensor reaches its hive on it and this list was
# missing it entirely; 64295 is administrative ssh after upstream moves it,
# 64297 the dashboard and 64298 the search engine.
#
# IT IS NOT THE WHOLE CHECK. Upstream's own set below is disjoint from this
# one, and the ports check tests the union -- see the comment above
# _tpot_pf_check_ports for why a half-union is worse than useless.
readonly _PF_DEF_REQUIRED_PORTS="22,64294,64295,64297,64298"

# UPSTREAM's port set, and it is deliberately not configurable.
#
# upstream install.sh sets myCONFLICT_PORTS="tcp/25 tcp/53 udp/53" and exits 1
# on a listener there -- including a loopback-only one, which its own comment
# says explicitly. That check runs AFTER ours and AFTER os_prep has already
# changed this box. Relaxing these here would not make the install work; it
# would only move the refusal to a point where we had already mutated the box.
readonly _PF_UPSTREAM_CONFLICT_PORTS="tcp/25 tcp/53 udp/53"

# The one holder upstream exempts on 53, mirrored exactly.
#
# NOTE THE MISSING `d`. The unit is systemd-resolveD, but `ss` truncates the
# process name to 15 characters, so what arrives in its output -- and what
# upstream's own comparison is written against -- is `systemd-resolve`.
# Comparing against the full name would match nothing, and would match nothing
# silently.
readonly _PF_PORT_EXEMPT_HOLDER="systemd-resolve"

readonly _PF_DEF_OS_USER="honeypot"
readonly _PF_DEF_ADMIN_SSH_PORT=64295
readonly _PF_DEF_DASHBOARD_PORT=64297
readonly _PF_DEF_ELASTICSEARCH_PORT=64298
readonly _PF_SUPPORTED_ARCH="x86_64 aarch64"

# ---------------------------------------------------------------------------
# Upstream's own distribution gate, as read from its source.
#
# WHAT THIS IS FOR. Upstream's install.sh gates twice -- membership on the
# NAME field of /etc/os-release, then an exact version comparison -- before it
# handles -s, before its port preflight, before anything. Both gates are
# `exit 1` with no override flag. Pre-empting them here is worth doing because
# the alternative is discovering the refusal after os_prep has changed the box.
#
# WHAT IT IS NOT. It is not authority. `-b` pins upstream's PAYLOAD; the gate
# that runs is whatever copy of install.sh this run fetched (D-10), so these
# rules are only known to hold for the ref they were read at. That ref is
# recorded below and the check downgrades itself when the pinned ref is a
# different one -- an "upstream will accept this box" that had not checked the
# pinned ref would be exactly the untrue assertion D-10 exists to prevent.
#
# WHEN A REF IS PINNED, tools/pin-upstream.sh should read the gate out of the
# install.sh it is pinning and extend _PF_UPSTREAM_GATE_VALID_REFS (or move
# both of these into the per-release data file). IT NOW DOES HALF OF THAT: it
# reads the gate at the ref it pins and writes it out row by row, with a
# verdict and a reason per distribution, into that ref's data file under
# roles/tpot_install/vars/. It does not touch either constant below, and this
# file cannot read what it wrote: preflight is bash, it runs before the
# dependency bootstrap has put ansible-core anywhere, and the only YAML it can
# read is support-matrix.yml through lib/matrix.sh's constrained parser. So
# the two statements of upstream's gate are not yet joined up, and the one
# below is still what this check compares against.
#
# READ THE NEXT SENTENCE BEFORE TRUSTING THIS CHECK. The list below holds one
# entry, `master`, and lib/varschema.json's pattern for tpot_upstream_ref
# REFUSES master, main and HEAD outright. So the two arms of this check that
# return an authoritative answer -- `ok` and `fail` -- cannot be reached by any
# legal pin today: every one of them falls through to `warn` or
# `inconclusive`. That is the safe direction and it is deliberate, but it means
# the check currently pre-empts nothing with authority; it reports what the
# copy read on 2026-09-02 would have said, labelled as coming from a different
# ref. It becomes a verdict when tools/pin-upstream.sh extends this list from
# the install.sh it actually pinned, and not before.
readonly _PF_UPSTREAM_GATE_SOURCE="telekom-security/tpotce master, read 2026-09-02"
readonly _PF_UPSTREAM_GATE_VALID_REFS="master"

# Upstream's own words, quoted rather than paraphrased, because the point of
# this check is to tell a user what upstream will say to them.
readonly _PF_UPSTREAM_GATE_POLICY="T-Pot follows the current release of each distribution, the installer will stop on an older one"

# The oldest ansible-core that satisfies requirements.yml. Preflight uses it
# only to decide whether pypi.org matters on this box; lib/deps.sh remains the
# authority on where ansible-core actually comes from.
readonly _PF_MIN_CORE_MAJOR=2
readonly _PF_MIN_CORE_MINOR=15

# ---------------------------------------------------------------------------
# State. _PF_RECORDS is the report; everything else is measurement that
# stage B serialises into host.json.
# ---------------------------------------------------------------------------
_PF_RECORDS=()
declare -gA _PF_CFG=()
_PF_OS_ID=""
_PF_OS_VERSION_ID=""
_PF_OS_MAJOR=""
_PF_OS_PRETTY=""
_PF_OS_SUPPORTED="false"
_PF_OS_FORCED="false"
# Which tier of the two-tier matrix this box is in (D-07): supported, legacy,
# unsupported, or unknown when the matrix could not be consulted at all. It is
# recorded rather than collapsed into the boolean above, because "in our matrix
# but not claimed as tested" is a real state and neither true nor false is an
# honest answer to it.
_PF_OS_TIER="unknown"
_PF_OS_TIER_HOW=""
_PF_ARCH=""
_PF_RUNTIME_FSTYPE=""
_PF_MEMORY_MB=""
_PF_CPUS=""
_PF_DISK_HOME_GB=""
_PF_DISK_DOCKER_GB=""
_PF_MAX_MAP_COUNT=""
_PF_USAGE_ERROR=0
_PF_CFG_LOADED=0
# The already-installed state, measured once per stage B run. `ports` needs it
# before `existing_tpot` reports it, which is why it is a global rather than
# something each check works out for itself.
_PF_INSTALLED=0
_PF_INSTALLED_DONE=0
_PF_INSTALLED_INFERRED=0
_PF_INSTALLED_EVIDENCE=""
# pre_install, post_install, post_install_incomplete, or unknown.
_PF_PORT_LAYOUT="unknown"

# THE FIVE TEST SEAMS, and the reason there are exactly five.
#
# Everything preflight measures comes from either a COMMAND or a FILE. A
# command is replaced in a test by putting a fixture earlier on $PATH -- that
# is how `ss`, `nproc`, `df`, `curl`, `getent` and `systemctl` would be
# exercised, and it needs nothing from this file. A file cannot be replaced
# that way, so the files preflight reads directly are named by variables that
# default to the real thing. Four of them name one file each. The fifth,
# PF_APT_ROOT, names a prefix, because reachability_apt follows a path out of
# the sources files and a per-file seam could not cover where it lands.
#
# WHAT ACTUALLY EXISTS TO POINT THEM AT, TODAY:
#
#   PF_OS_RELEASE            tests/os-release/ holds fifteen fixtures -- the
#                            nine of the LEGACY tier (Debian 11/12/13, Ubuntu
#                            20.04/22.04/24.04, Mint 20/21/22: documented, and
#                            NEVER claimed as tested, D-07), plus Ubuntu 26.04,
#                            Kali, Raspbian, Fedora, AlmaLinux and a
#                            versionless Debian testing. Two of them --
#                            Debian 13 and Ubuntu 26.04 -- are in the SUPPORTED
#                            tier at the ref this tree pins, which means
#                            upstream's gate accepts them and this installer
#                            can drive them. It does not mean either has been
#                            installed: nothing has.
#   PF_PROC_MEMINFO          NOTHING. tests/fixtures/ does not exist.
#   PF_PROC_CPUINFO          NOTHING. Same.
#   PF_PROC_MAX_MAP_COUNT    NOTHING. Same.
#   PF_APT_ROOT              tests/bats/preflight.bats builds sources trees in
#                            $TMP and points this at them -- including the
#                            mirror+file: indirection a Debian cloud image
#                            uses, which is what made this seam necessary.
#
# So three of the five seams are open at one end. The memory, cpus and
# max_map_count checks have never been run against anything but whichever box
# a session happened to be on -- one meminfo, one processor count, one
# max_map_count, all of them this developer machine's. Their threshold
# arithmetic, their unit handling and their unreadable-file arms are untested,
# and the seams are here so that stops being true; writing those fixtures is
# the cheapest missing test in this file. Until they exist, the honest word
# for those three checks is "unexercised", not "covered".
#
# The bats suite named throughout these comments EXISTS as of 2026-09-04 --
# tests/bats/preflight.bats runs this file's stages against fixtures and
# compares what they recorded with pf_ids(). What it does NOT do is set these
# variables: they remain a seam for a caller that needs to substitute a
# /proc file, and nothing in the suite or the tree does that today.
#
# NOTHING SETS THESE IN PRODUCTION and nothing should: install.sh does not
# read them, they are not input keys, and lib/config.py has never heard of
# them.
: "${PF_OS_RELEASE:=/etc/os-release}"
: "${PF_PROC_MEMINFO:=/proc/meminfo}"
: "${PF_PROC_CPUINFO:=/proc/cpuinfo}"
: "${PF_PROC_MAX_MAP_COUNT:=/proc/sys/vm/max_map_count}"

# The fifth seam, and the only one that is a PREFIX rather than a file.
#
# reachability_apt does not read one path: it reads the sources files and then
# follows a path it finds INSIDE them, which on a Debian cloud image lands on
# /etc/apt/mirrors/debian.list. A per-file variable cannot cover where that
# lands, so this one is a root to prepend -- empty in production, a $TMP tree
# in a test, and the indirection is then covered end to end by construction.
: "${PF_APT_ROOT:=}"

# ===========================================================================
# THE RECORD
# ===========================================================================

# ---------------------------------------------------------------------------
# pf_record ID STATUS DETAIL
#   Append one record. No filesystem access: stage A runs before $RUNDIR
#   exists, and buffering in memory is what lets the /run check be a check
#   rather than an assumption.
#
#   DETAIL is one line of English naming the measured value and, where there
#   is one, the threshold. Tabs, newlines and carriage returns are folded to
#   spaces because the interchange format is TSV and a detail that broke it
#   would silently truncate the report.
#
#   An invalid STATUS is not silently accepted and not fatal either: it
#   becomes `inconclusive` and says so in the detail. Losing a check because
#   somebody typed OKAY is exactly the failure this file exists to prevent.
#   The downgrade is deliberately to `inconclusive` and not to
#   `not-applicable`: a typo must land on the status that fails closed.
# ---------------------------------------------------------------------------
pf_record() {
    local id=${1:-} status=${2:-} detail=${3:-} marker=""
    status=${status,,}
    case $status in
        ok|warn|fail|inconclusive|not-applicable) ;;
        *)
            marker=" [preflight recorded an invalid status and downgraded it]"
            status="inconclusive"
            ;;
    esac
    detail=${detail//$'\t'/ }
    detail=${detail//$'\n'/ }
    detail=${detail//$'\r'/ }
    while [[ $detail == *"  "* ]]; do
        detail=${detail//  / }
    done
    detail=${detail# }
    detail=${detail% }
    _PF_RECORDS+=("${id}"$'\t'"${status}"$'\t'"${detail}${marker}")
    return 0
}

# ---------------------------------------------------------------------------
# pf_ids
#   Print the closed list of check ids, stage A then stage B, in order.
#   tests/bats/preflight.bats compares this with what a full run recorded, so
#   a check that was added without being documented, or documented without
#   being performed, fails the build.
# ---------------------------------------------------------------------------
pf_ids() {
    printf '%s\n' "${PF_IDS_STAGE_A[@]}" "${PF_IDS_STAGE_B[@]}"
    return 0
}

# ---------------------------------------------------------------------------
# pf_records
#   Print the records as TSV, one per line: id<TAB>status<TAB>detail.
#   The same bytes pf_flush writes. Exists so a test can read the report
#   without a filesystem.
# ---------------------------------------------------------------------------
pf_records() {
    if (( ${#_PF_RECORDS[@]} == 0 )); then
        return 0
    fi
    printf '%s\n' "${_PF_RECORDS[@]}"
    return 0
}

# Field accessors. The record is three tab-separated fields; splitting it with
# parameter expansion keeps this file free of `read`.
_tpot_pf_rec_id()     { local r=${1:-}; printf '%s\n' "${r%%$'\t'*}"; }
_tpot_pf_rec_status() { local r=${1:-} s; s=${r#*$'\t'}; printf '%s\n' "${s%%$'\t'*}"; }
_tpot_pf_rec_detail() { local r=${1:-} s; s=${r#*$'\t'}; printf '%s\n' "${s#*$'\t'}"; }

# ---------------------------------------------------------------------------
# pf_flush
#   Write the records to $RUNDIR/preflight.tsv, mode 0600. Called once $RUNDIR
#   exists (so stage A's buffered records land) and again after stage B.
#
#   Returns 0 when it wrote, and also when there is nowhere yet to write to --
#   stage A legitimately runs before $RUNDIR exists. Returns 1 only when the
#   write itself failed, which on a tmpfs run directory means something is
#   wrong that the caller should know about.
# ---------------------------------------------------------------------------
pf_flush() {
    local dir=${RUNDIR:-} dest
    if [[ -z $dir || ! -d $dir ]]; then
        return 0
    fi
    dest="${dir}/preflight.tsv"
    if (( ${#_PF_RECORDS[@]} == 0 )); then
        if ! ( umask 077; : > "$dest" ); then
            return 1
        fi
    else
        if ! ( umask 077; printf '%s\n' "${_PF_RECORDS[@]}" > "$dest" ); then
            return 1
        fi
    fi
    chmod 0600 "$dest" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# pf_print
#   The aligned human table. Status upper case, then the check id, then the
#   detail. The status column is 14 wide because NOT-APPLICABLE is 14
#   characters; INCONCLUSIVE, the next longest, is 12.
#   The id and not a prettier label, because one fact has one name:
#   what the table shows is what result.json records, what the tests assert
#   and what docs/verification.md explains.
#
#   Written with printf rather than through log.sh: the table is already
#   formatted and must not be re-formatted, and the caller has redirected
#   stdout into the redacting pump, so this output is redacted like any other.
# ---------------------------------------------------------------------------
pf_print() {
    local rec id status detail
    printf 'PREFLIGHT\n'
    if (( ${#_PF_RECORDS[@]} == 0 )); then
        printf '  %-14s  %-23s  %s\n' 'INCONCLUSIVE' '(no checks)' \
            'preflight recorded nothing; this is a bug in the installer'
        return 0
    fi
    for rec in "${_PF_RECORDS[@]}"; do
        id=$(_tpot_pf_rec_id "$rec")
        status=$(_tpot_pf_rec_status "$rec")
        detail=$(_tpot_pf_rec_detail "$rec")
        printf '  %-14s  %-23s  %s\n' "${status^^}" "$id" "$detail"
    done
    return 0
}

# ---------------------------------------------------------------------------
# pf_verdict [PREFLIGHT_ONLY]
#   Print the exit code the run should use: 0, 11 or 12. Prints nothing else.
#
#   any fail                     -> 11
#   a HARD check inconclusive    -> 11 in a full run (fail closed)
#                                   12 under --preflight-only
#   a SOFT check inconclusive    -> 0  in a full run (it could only ever warn)
#                                   12 under --preflight-only
#   otherwise                    -> 0
#
#   `not-applicable` falls into `otherwise` and is meant to: it is not a
#   failure and not a missing measurement, so it changes no exit code. That is
#   also why it may only be recorded where the dependency genuinely does not
#   exist on this path -- it is the one status that can never stop a run.
#
#   The argument defaults to $OPT_PREFLIGHT_ONLY so the caller normally passes
#   nothing; it is accepted explicitly so a test can exercise both modes
#   against one set of records.
# ---------------------------------------------------------------------------
pf_verdict() {
    local preflight_only=${1:-${OPT_PREFLIGHT_ONLY:-0}}
    local rec id status has_fail=0 hard_inconclusive=0 soft_inconclusive=0
    if (( ${#_PF_RECORDS[@]} > 0 )); then
        for rec in "${_PF_RECORDS[@]}"; do
            id=$(_tpot_pf_rec_id "$rec")
            status=$(_tpot_pf_rec_status "$rec")
            case $status in
                fail)
                    has_fail=1
                    ;;
                inconclusive)
                    if _tpot_pf_is_hard "$id"; then
                        hard_inconclusive=1
                    else
                        soft_inconclusive=1
                    fi
                    ;;
            esac
        done
    fi
    if (( has_fail )); then
        printf '%s\n' "${EX_PREFLIGHT:-11}"
        return 0
    fi
    if (( hard_inconclusive )); then
        if (( preflight_only )); then
            printf '%s\n' "${EX_INCONCLUSIVE:-12}"
        else
            printf '%s\n' "${EX_PREFLIGHT:-11}"
        fi
        return 0
    fi
    if (( soft_inconclusive )) && (( preflight_only )); then
        printf '%s\n' "${EX_INCONCLUSIVE:-12}"
        return 0
    fi
    printf '%s\n' "${EX_OK:-0}"
    return 0
}

# ---------------------------------------------------------------------------
# pf_usage_error
#   True when a check failed for a reason that is the CALLER's mistake rather
#   than the box's: today that is the answer-file rule -- a file inside the
#   repository tree, or one holding a secret without being root-owned 0600.
#
#   The exit table gives those EX_USAGE (10), not EX_PREFLIGHT (11), and
#   pf_verdict is contractually limited to 0/11/12. So install.sh consults
#   this first:
#
#       if pf_usage_error; then exit "$EX_USAGE"; fi
#       code=$(pf_verdict); ...
#
#   Ignoring it is safe but less accurate: the record is also a `fail`, so the
#   run still stops, with 11 instead of 10.
# ---------------------------------------------------------------------------
pf_usage_error() {
    (( _PF_USAGE_ERROR ))
}

# ===========================================================================
# HELPERS
#
# All private. Each one is written to be safe under `set -euo pipefail`: no
# bare arithmetic that can evaluate to zero, no `a && b` as a statement, and
# every command substitution guarded.
# ===========================================================================

# ---------------------------------------------------------------------------
# _tpot_pf_field N STRING
#   Print the Nth whitespace-separated field. Written with parameter expansion
#   rather than array word-splitting because `ss` output contains `*` in the
#   peer-address column, and an unquoted expansion would glob it against the
#   working directory.
# ---------------------------------------------------------------------------
_tpot_pf_field() {
    local n=${1:-1} s=${2:-} i=0 tok
    s=${s//$'\t'/ }
    while [[ -n $s ]]; do
        while [[ $s == " "* ]]; do
            s=${s# }
        done
        if [[ -z $s ]]; then
            break
        fi
        tok=${s%%[[:space:]]*}
        i=$(( i + 1 ))
        if (( i == n )); then
            printf '%s\n' "$tok"
            return 0
        fi
        s=${s#"$tok"}
    done
    return 1
}

# ---------------------------------------------------------------------------
# _tpot_pf_split_ws STRING
#   One whitespace-separated token per line. The same parameter-expansion walk
#   as _tpot_pf_field, for the same reason: an unquoted expansion of a string
#   that came out of `ss` would glob a `*` against the working directory.
# ---------------------------------------------------------------------------
_tpot_pf_split_ws() {
    local s=${1:-} tok
    s=${s//$'\t'/ }
    while [[ -n $s ]]; do
        while [[ $s == " "* ]]; do
            s=${s# }
        done
        if [[ -z $s ]]; then
            break
        fi
        tok=${s%%[[:space:]]*}
        printf '%s\n' "$tok"
        s=${s#"$tok"}
    done
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_worse A B
#   Print the more severe of two statuses:
#   not-applicable < ok < warn < inconclusive < fail.
#
#   inconclusive outranks warn because a warning is a measurement and an
#   inconclusive is the absence of one: a report that showed WARN for a check
#   which had also failed to run would be claiming to have looked.
#
#   not-applicable ranks BELOW ok, so combining it with anything yields the
#   other: a composite check where one part did not apply is described by the
#   parts that did. It is listed explicitly rather than left to the default
#   arm, which means inconclusive -- exactly the collapse this status exists
#   to avoid.
# ---------------------------------------------------------------------------
_tpot_pf_worse() {
    local a=${1:-ok} b=${2:-ok} ra=0 rb=0
    # An unrecognised status is treated as inconclusive, for the same reason
    # pf_record downgrades one: losing severity to a typo is the failure this
    # file exists to prevent.
    case $a in not-applicable) ra=-1 ;; ok) ra=0 ;; warn) ra=1 ;; fail) ra=3 ;; *) ra=2 ;; esac
    case $b in not-applicable) rb=-1 ;; ok) rb=0 ;; warn) rb=1 ;; fail) rb=3 ;; *) rb=2 ;; esac
    if (( rb > ra )); then
        printf '%s\n' "$b"
    else
        printf '%s\n' "$a"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_have COMMAND
#   True when COMMAND is on PATH. `command -v` and nothing else: `which` is a
#   separate package on some of the legacy-tier releases, and `type` prints for
#   builtins we do not want.
# ---------------------------------------------------------------------------
_tpot_pf_have() {
    command -v -- "${1:-}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# _tpot_pf_early_flag KEY
#   True when a --force-* override is in effect AT STAGE A -- that is, before
#   any answer file has been read.
#
#   Stage A runs before the merge by design, so it can honour only the two
#   channels that exist that early: a command-line flag (already parsed into
#   OPT_OVERRIDES by lib/args.sh) and the environment. An answer file cannot
#   reach a stage A check, and the failure messages say so rather than leaving
#   a user to discover it.
# ---------------------------------------------------------------------------
_tpot_pf_early_flag() {
    local key=${1:-} envname item val=""
    envname=${key^^}
    if declare -p OPT_OVERRIDES >/dev/null 2>&1; then
        for item in "${OPT_OVERRIDES[@]}"; do
            if [[ ${item%%=*} == "$key" ]]; then
                val=${item#*=}
            fi
        done
    fi
    if [[ -z $val ]]; then
        val=${!envname:-}
    fi
    case ${val,,} in
        true|yes|on|1) return 0 ;;
        *)             return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# _tpot_pf_cfg KEY [FALLBACK]
#   Print a value from the merged public document, or FALLBACK when the key
#   was absent, null or empty.
# ---------------------------------------------------------------------------
_tpot_pf_cfg() {
    local key=${1:-} fallback=${2:-} val
    val=${_PF_CFG[$key]:-}
    if [[ -z $val ]]; then
        printf '%s\n' "$fallback"
    else
        printf '%s\n' "$val"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_cfg_bool KEY
#   True when the merged document says KEY is true.
# ---------------------------------------------------------------------------
_tpot_pf_cfg_bool() {
    local val
    val=$(_tpot_pf_cfg "${1:-}" "false")
    case ${val,,} in
        true|yes|on|1) return 0 ;;
        *)             return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# _tpot_pf_load_config FILE KEY...
#   Fill _PF_CFG from a flat JSON document -- $PUBLIC_JSON in a real run, which
#   is the merged document with every secret-typed key REMOVED. Returns 1 when
#   the file is missing, unreadable or not a flat object, and the caller then
#   records `input_complete: inconclusive` rather than pretending it had
#   configuration.
#
#   One python3 invocation for all the keys: the alternative is twenty
#   subprocesses, and a loop of subprocesses in a preflight is how a "fast"
#   check becomes a slow one on the smallest supported box.
#
#   Key NAMES are on the command line. Values never are: this document has no
#   secret in it, and the values come back on stdout.
# ---------------------------------------------------------------------------
_tpot_pf_load_config() {
    local file=${1:-}
    shift || true
    local -a lines=()
    local line key val
    if [[ -z $file || ! -r $file ]]; then
        return 1
    fi
    if ! _tpot_pf_have python3; then
        return 1
    fi
    mapfile -t lines < <(python3 -c '
import sys, json
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception:
    sys.exit(1)
if not isinstance(doc, dict):
    sys.exit(1)
for k in sys.argv[2:]:
    if k not in doc:
        continue
    v = doc[k]
    if isinstance(v, bool):
        s = "true" if v else "false"
    elif v is None:
        s = ""
    elif isinstance(v, (list, tuple)):
        s = ",".join(str(x) for x in v)
    elif isinstance(v, dict):
        s = ",".join(sorted(str(x) for x in v))
    else:
        s = str(v)
    s = s.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    sys.stdout.write(k + "\t" + s + "\n")
' "$file" "$@" 2>/dev/null)
    if (( ${#lines[@]} == 0 )); then
        # An empty document is legitimate, but so is a parse failure, and the
        # two are indistinguishable from here. Re-test readability cheaply:
        # a file that parses to nothing still leaves _PF_CFG empty, and every
        # caller falls back to the shipped defaults.
        if ! python3 -c '
import sys, json
with open(sys.argv[1], encoding="utf-8") as fh:
    doc = json.load(fh)
sys.exit(0 if isinstance(doc, dict) else 1)
' "$file" >/dev/null 2>&1; then
            return 1
        fi
        return 0
    fi
    for line in "${lines[@]}"; do
        key=${line%%$'\t'*}
        val=${line#*$'\t'}
        if [[ -n $key ]]; then
            _PF_CFG["$key"]=$val
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_url_host URL   /   _tpot_pf_url_scheme URL
#   Split a URL without a regex engine and without curl. Handles userinfo,
#   an explicit port, and a bracketed IPv6 literal.
# ---------------------------------------------------------------------------
_tpot_pf_url_scheme() {
    local url=${1:-}
    if [[ $url != *"://"* ]]; then
        return 1
    fi
    printf '%s\n' "${url%%://*}"
    return 0
}

_tpot_pf_url_host() {
    local url=${1:-} rest hostport
    if [[ $url != *"://"* ]]; then
        return 1
    fi
    rest=${url#*://}
    hostport=${rest%%/*}
    hostport=${hostport%%\?*}
    hostport=${hostport##*@}
    if [[ $hostport == "["* ]]; then
        hostport=${hostport#\[}
        printf '%s\n' "${hostport%%\]*}"
        return 0
    fi
    hostport=${hostport%%:*}
    if [[ -z $hostport ]]; then
        return 1
    fi
    printf '%s\n' "$hostport"
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_reachable SCHEME HOST
#   0  the host answered
#   1  the host did not answer  (a reason is printed)
#   2  reachability could not be tested at all (a reason is printed)
#
#   curl is the mechanism, with a hard 10-second cap, because an unattended
#   installer that hangs on a DNS lookup has failed in the worst way available.
#   Its exit status is read carefully: an HTTP error (22) or an untrusted
#   certificate (60) both mean THE HOST ANSWERED, which is the only question
#   being asked. Treating those as unreachable would fail a perfectly good box
#   because a mirror returns 403 to a bare GET of its root.
#
#   Without curl, a bare TCP connect through bash's /dev/tcp, wrapped in
#   `timeout` -- and if `timeout` is missing too, the answer is "could not
#   test", never an unbounded connect.
# ---------------------------------------------------------------------------
_tpot_pf_reachable() {
    local scheme=${1:-https} host=${2:-} port rc=0
    if [[ -z $host ]]; then
        printf '%s\n' "no host to test"
        return 2
    fi
    # tpot_upstream_url is user input, and the host comes out of it. Before the
    # value is used it is constrained to what a host can actually be: letters,
    # digits, dot, hyphen, underscore, and colon for an IPv6 literal. Without
    # this a host of the shape `example.test;<command>` would reach the
    # /dev/tcp fallback below as shell text.
    if [[ ! $host =~ ^[A-Za-z0-9._:-]+$ ]]; then
        printf '%s\n' "the host is not a plausible hostname or address"
        return 2
    fi
    case $scheme in
        http)  port=80 ;;
        https) port=443 ;;
        *)     scheme="https"; port=443 ;;
    esac
    if _tpot_pf_have curl; then
        curl -fsS --max-time 10 -o /dev/null "${scheme}://${host}/" >/dev/null 2>&1 || rc=$?
        case $rc in
            0|22|60)
                return 0
                ;;
            6)
                printf '%s\n' "DNS lookup failed"
                return 1
                ;;
            7)
                printf '%s\n' "connection refused or no route"
                return 1
                ;;
            28)
                printf '%s\n' "timed out after 10s"
                return 1
                ;;
            35)
                printf '%s\n' "TLS handshake failed"
                return 1
                ;;
            *)
                printf '%s\n' "curl exit ${rc}"
                return 1
                ;;
        esac
    fi
    if _tpot_pf_have timeout; then
        # The host and port are POSITIONAL ARGUMENTS, never interpolated into
        # the script text. /dev/tcp performs parameter expansion on the
        # redirection target, so this connects to exactly what was passed and
        # to nothing a value could smuggle in.
        if timeout 10 bash -c 'exec 3<>/dev/tcp/"$1"/"$2"' _ "$host" "$port" >/dev/null 2>&1; then
            return 0
        fi
        printf '%s\n' "tcp connect to port ${port} failed"
        return 1
    fi
    printf '%s\n' "neither curl nor timeout is installed; cannot test safely"
    return 2
}

# ---------------------------------------------------------------------------
# _tpot_pf_nearest_existing PATH
#   Print the deepest existing ancestor of PATH, so `df` can be asked about a
#   filesystem that will hold a directory which does not exist yet. Preflight
#   runs before anything is created, so this is the normal case, not an edge.
# ---------------------------------------------------------------------------
_tpot_pf_nearest_existing() {
    local p=${1:-/}
    while [[ -n $p && ! -e $p ]]; do
        if [[ $p != */* ]]; then
            p="/"
            break
        fi
        p=${p%/*}
        if [[ -z $p ]]; then
            p="/"
        fi
    done
    if [[ -z $p ]]; then
        p="/"
    fi
    printf '%s\n' "$p"
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_free_gb PATH
#   Free space in GiB on the filesystem holding PATH, floored. `df -P -k` for
#   the POSIX single-line format: without -P a long device name wraps onto a
#   second line and field 4 becomes the wrong number.
# ---------------------------------------------------------------------------
_tpot_pf_free_gb() {
    local path=${1:-/} out avail
    local -a lines=()
    if ! _tpot_pf_have df; then
        return 1
    fi
    mapfile -t lines < <(df -P -k -- "$path" 2>/dev/null)
    if (( ${#lines[@]} < 2 )); then
        return 1
    fi
    out=${lines[1]}
    avail=$(_tpot_pf_field 4 "$out") || return 1
    if [[ ! $avail =~ ^[0-9]+$ ]]; then
        return 1
    fi
    printf '%s\n' "$(( avail / 1048576 ))"
    return 0
}

# ===========================================================================
# THE SUPPORT MATRIX
#
# The matrix itself is read by lib/matrix.sh, not here. That reader is the bash
# half of a pair: the other half is Ansible's own include_vars, which
# roles/preflight uses on the same file later in the same run. What holds the
# pair together is the comparison. tests/check-matrix-parse.sh
# reads support-matrix.yml three ways -- lib/matrix.sh, ansible-core's
# include_vars through a throwaway playbook, and PyYAML -- and fails the build
# unless all three produce identical lists. So a second parser living in THIS
# file would be a fourth opinion about what "supported" means, and an
# unchecked one. Preflight asks the reader a question and reports the answer.
# ===========================================================================

# ---------------------------------------------------------------------------
# _tpot_pf_need_matrix
#   True once lib/matrix.sh is loaded. install.sh normally sources it before
#   this file; the fallback exists so that a bats test, or a container tier
#   that runs preflight with no Ansible on the box, can source lib/preflight.sh
#   alone and still get a real answer instead of a crash. THE FIRST OF THOSE
#   CALLERS NOW EXISTS: tests/bats/preflight.bats sources this file by itself
#   and exercises this path, which is what the fallback was written for. There
#   is still no container tier in this tree.
# ---------------------------------------------------------------------------
_tpot_pf_need_matrix() {
    local candidate here
    if declare -F matrix_supports >/dev/null 2>&1; then
        return 0
    fi
    here=$(dirname -- "${BASH_SOURCE[0]}") || here="."
    for candidate in "${REPO_DIR:-}/lib/matrix.sh" "${here}/matrix.sh"; do
        if [[ -n $candidate && -r $candidate ]]; then
            # shellcheck source=lib/matrix.sh
            . "$candidate" || true
            if declare -F matrix_supports >/dev/null 2>&1; then
                return 0
            fi
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# _tpot_pf_matrix_tier ID VERSION_ID
#   Print two lines: the tier this box is in, then how it was decided.
#
#       supported | legacy | unsupported
#       tier-function | tier-predicate | single-tier-fallback
#
#   Returns 1, having printed nothing, when the matrix reader exposes no
#   interface this file recognises -- which is an inconclusive `os` check, not
#   an unsupported box.
#
# WHY AN ADAPTER AND NOT A CALL. D-07 split the matrix in two: "supported and
# tested" is whatever the PINNED upstream ref's own gate accepts, and the nine
# older releases become a documented "legacy" tier reachable only by pinning an
# older ref. lib/matrix.sh is the single reader of support-matrix.yml and is
# being reworked for that; this file must not grow a second opinion about what
# supported means, so it asks, and it accepts either of the two shapes that
# question can reasonably take:
#
#   matrix_tier ID VERSION            prints the tier. rc 1 means the box is in
#                                     neither tier; rc 2 and above mean the
#                                     matrix could not be READ, which is an
#                                     inconclusive check and emphatically not
#                                     an unsupported box -- telling somebody to
#                                     reinstall their operating system over a
#                                     missing file is the mistake this
#                                     distinction exists to prevent
#   matrix_supports_tier TIER ID VER  a predicate, asked twice, supported first
#
# THE THIRD PATH IS THE ONE TO READ CAREFULLY. The single-tier reader that
# shipped before D-07 exposes only matrix_supports, which answers "is this row
# in support-matrix.yml" and cannot answer "in which tier". A match is then
# reported as LEGACY -- not as supported -- because that is what
# support-matrix.yml's own header says its rows currently are: the supported
# tier is derived from the pin, tpot_upstream_ref ships unset, and so nothing
# is in it yet. Reporting a match as `supported` would claim a test nobody has
# run, which is the assertion D-07 was written to stop. The `os` record says
# which of the three paths produced its answer, so this is never invisible.
# ---------------------------------------------------------------------------
_tpot_pf_matrix_tier() {
    local id=${1:-} ver=${2:-} out="" rc=0
    if [[ -z $id || -z $ver ]]; then
        return 1
    fi
    if declare -F matrix_tier >/dev/null 2>&1; then
        out=$(matrix_tier "$id" "$ver" 2>/dev/null) || rc=$?
        out=${out%%$'\n'*}
        out=${out,,}
        out=${out//[[:space:]]/}
        if (( rc > 1 )); then
            return 1
        fi
        if (( rc == 1 )) && [[ -z $out ]]; then
            printf '%s\n%s\n' unsupported tier-function
            return 0
        fi
        case $out in
            supported|legacy|unsupported)
                printf '%s\n%s\n' "$out" tier-function
                return 0
                ;;
        esac
        # It answered something this file does not understand. That is not a
        # verdict, and guessing which way it leaned is how a box gets declared
        # supported by accident.
        return 1
    fi
    if declare -F matrix_supports_tier >/dev/null 2>&1; then
        if matrix_supports_tier supported "$id" "$ver" >/dev/null 2>&1; then
            printf '%s\n%s\n' supported tier-predicate
            return 0
        fi
        if matrix_supports_tier legacy "$id" "$ver" >/dev/null 2>&1; then
            printf '%s\n%s\n' legacy tier-predicate
            return 0
        fi
        printf '%s\n%s\n' unsupported tier-predicate
        return 0
    fi
    if declare -F matrix_supports >/dev/null 2>&1; then
        if matrix_supports "$id" "$ver" >/dev/null 2>&1; then
            printf '%s\n%s\n' legacy single-tier-fallback
            return 0
        fi
        printf '%s\n%s\n' unsupported single-tier-fallback
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# _tpot_pf_matrix_summary [TIER]
#   One line naming the matrix, or the named tier of it when the reader can
#   split them. Always prints something: the message it feeds is about a box
#   being refused, and "see support-matrix.yml" is a better sentence than an
#   empty one.
#
#   An EMPTY tier and an UNKNOWN one are told apart with matrix_list_tier,
#   which returns 0 printing nothing for a tier that exists and holds no rows.
#   The supported tier is not empty at the ref this tree pins, but it is empty
#   in any checkout whose pin has been cleared, and "none" is the true sentence
#   for that, where falling back to the whole matrix would quietly answer a
#   different question.
# ---------------------------------------------------------------------------
_tpot_pf_matrix_summary() {
    local tier=${1:-} out=""
    if [[ -n $tier ]] && declare -F matrix_summary_tier >/dev/null 2>&1; then
        out=$(matrix_summary_tier "$tier" 2>/dev/null) || out=""
        if [[ -n $out ]]; then
            printf '%s\n' "$out"
            return 0
        fi
        if declare -F matrix_list_tier >/dev/null 2>&1; then
            if matrix_list_tier "$tier" >/dev/null 2>&1; then
                printf '%s\n' "none -- the ${tier} tier is empty, which is what an unpinned tpot_upstream_ref means; set it with tools/pin-upstream.sh, which derives the tier from the pinned ref's own gate"
                return 0
            fi
        fi
    fi
    if declare -F matrix_summary >/dev/null 2>&1; then
        out=$(matrix_summary 2>/dev/null) || out=""
        if [[ -n $out ]]; then
            printf '%s\n' "$out"
            return 0
        fi
    fi
    printf '%s\n' "see support-matrix.yml"
    return 0
}

# ===========================================================================
# STAGE A -- zero dependency, zero mutation, before the merge
# ===========================================================================

_tpot_pf_check_root() {
    local uid
    uid=$(id -u 2>/dev/null) || uid=""
    if [[ $uid == "0" ]]; then
        pf_record root ok "uid 0"
        return 0
    fi
    if [[ -z $uid ]]; then
        pf_record root inconclusive "could not determine the effective uid; id(1) failed"
        return 0
    fi
    pf_record root fail \
        "uid ${uid} -- this installer must run as root (uid 0). Try: sudo -i, then ./install.sh"
    return 0
}

_tpot_pf_check_apt() {
    local path
    if path=$(command -v apt-get 2>/dev/null); then
        pf_record apt ok "apt-get at ${path}"
        return 0
    fi
    pf_record apt fail \
        "apt-get was not found -- this installer targets Debian, Ubuntu and Linux Mint"
    return 0
}

_tpot_pf_check_python3() {
    local path ver major minor
    if ! path=$(command -v python3 2>/dev/null); then
        pf_record python3 fail \
            "python3 was not found -- it is required to read configuration and to run Ansible"
        return 0
    fi
    ver=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null) || ver=""
    if [[ -z $ver ]]; then
        pf_record python3 inconclusive \
            "python3 is at ${path} but would not report its version"
        return 0
    fi
    major=${ver%%.*}
    minor=${ver#*.}
    minor=${minor%%.*}
    if [[ ! $major =~ ^[0-9]+$ || ! $minor =~ ^[0-9]+$ ]]; then
        pf_record python3 inconclusive "python3 ${ver} at ${path}: unparseable version"
        return 0
    fi
    if (( major > 3 )) || { (( major == 3 )) && (( minor >= 9 )); }; then
        pf_record python3 ok "python3 ${ver} at ${path} (min 3.9)"
        return 0
    fi
    pf_record python3 fail "python3 ${ver} at ${path} is older than the minimum 3.9"
    return 0
}

# ---------------------------------------------------------------------------
# os -- THREE outcomes, not two (D-07)
#
# The matrix has two tiers and this check must distinguish three states, not
# the two a boolean can hold:
#
#   SUPPORTED    accepted by the PINNED upstream ref's own gate. `ok`.
#   LEGACY       one of the older releases the automation this project replaces
#                was installed on. Reachable only by pinning an older upstream
#                ref, documented, and NOT claimed as tested. `warn` -- because
#                it is neither a failure nor something to wave through in
#                silence, and a silent pass here is precisely how "works on
#                nine distributions" outlived the evidence for it.
#   UNSUPPORTED  in neither tier. `fail`, or `warn` when forced.
#
# The tier itself comes from lib/matrix.sh through _tpot_pf_matrix_tier; this
# function decides what a tier MEANS for a run, and records which of the three
# it saw in the record, in host.json, and so in result.json.
#
# tpot_force_unsupported_os relaxes THIS check and nothing else. Upstream's own
# gate has no override flag at all, which is why upstream_gate exists as a
# separate check further down.
# ---------------------------------------------------------------------------
_tpot_pf_check_os() {
    local ident summary forced="no" tier how note="" sref=""
    local -a tier_out=()

    if ! _tpot_pf_need_matrix; then
        pf_record os inconclusive \
            "lib/matrix.sh could not be loaded, so the supported matrix could not be consulted"
        return 0
    fi

    # PRETTY_NAME is for the record, not for the decision. matrix.sh parses
    # /etc/os-release rather than sourcing it: that file is shell syntax, and
    # sourcing it would execute whatever is in it, as root, before this box
    # has been established as one we trust.
    _PF_OS_PRETTY=$(matrix_os_release_field PRETTY_NAME "$PF_OS_RELEASE" 2>/dev/null) || _PF_OS_PRETTY=""

    if ! ident=$(matrix_identify "$PF_OS_RELEASE"); then
        pf_record os inconclusive \
            "${PF_OS_RELEASE} is missing, unreadable or carries no ID, so the distribution could not be identified"
        return 0
    fi
    _PF_OS_ID=${ident%%$'\t'*}
    _PF_OS_VERSION_ID=${ident#*$'\t'}
    _PF_OS_MAJOR=${_PF_OS_VERSION_ID%%.*}

    if [[ -z $_PF_OS_VERSION_ID ]]; then
        pf_record os inconclusive \
            "${_PF_OS_ID} reports no VERSION_ID, so it cannot be matched against the supported matrix"
        return 0
    fi

    if _tpot_pf_early_flag tpot_force_unsupported_os; then
        forced="yes"
        _PF_OS_FORCED="true"
    fi

    # An unreadable or unparseable matrix is not an unsupported box. The two
    # are told apart here, because reporting the second when the first is true
    # would send somebody to reinstall their operating system over a missing
    # file.
    if ! matrix_list >/dev/null 2>&1; then
        pf_record os inconclusive \
            "${_PF_OS_ID} ${_PF_OS_VERSION_ID}: support-matrix.yml is missing, empty or has a line lib/matrix.sh does not recognise, so the supported matrix could not be consulted"
        return 0
    fi

    mapfile -t tier_out < <(_tpot_pf_matrix_tier "$_PF_OS_ID" "$_PF_OS_VERSION_ID")
    tier=${tier_out[0]:-}
    how=${tier_out[1]:-}
    if [[ -z $tier ]]; then
        pf_record os inconclusive \
            "${_PF_OS_ID} ${_PF_OS_VERSION_ID}: lib/matrix.sh exposes no interface this preflight recognises (matrix_tier, matrix_supports_tier or matrix_supports), so the two-tier matrix could not be consulted"
        return 0
    fi
    _PF_OS_TIER=$tier
    _PF_OS_TIER_HOW=$how
    if [[ $how == "single-tier-fallback" ]]; then
        note=" lib/matrix.sh exposes no tier interface, so a matching row was read as LEGACY -- which is what support-matrix.yml's own header says its rows currently are, the supported tier being derived from a pin that ships unset (D-07)"
    fi

    # The supported tier is DERIVED from a pin, so name the pin it was derived
    # from wherever the reader can tell us. Stage A cannot see the ref this run
    # will use -- that comes from the merge -- so whether the two agree is
    # checked later, by upstream_gate.
    sref=""
    if declare -F matrix_supported_ref >/dev/null 2>&1; then
        sref=$(matrix_supported_ref 2>/dev/null) || sref=""
    fi

    case $tier in
        supported)
            _PF_OS_SUPPORTED="true"
            summary=$(_tpot_pf_matrix_summary supported)
            if [[ -n $sref ]]; then
                summary="${summary}; derived from upstream ref ${sref}"
            fi
            # WHAT "SUPPORTED" MAY AND MAY NOT CLAIM.
            #
            # This message used to end "...and exercised by this project's
            # tests". That was written while the supported tier shipped EMPTY,
            # so this branch was unreachable and nobody could read the claim.
            # D-11 pinned a ref, the tier became two rows, and the sentence
            # started printing on every run on a supported box -- asserting a
            # test campaign that has never happened. Nothing in this project
            # has ever been installed on any box, and the file that would
            # record such a run, tests/MATRIX-STATUS.md, does not exist.
            #
            # So the tier means exactly two things, and the message now says
            # only those two: the pinned upstream's own gate accepts this
            # release, and this installer can drive it (apt, and an
            # architecture we accept). Whether it WORKS is a separate question
            # that a dated run has to answer.
            pf_record os ok \
                "${_PF_OS_ID} ${_PF_OS_VERSION_ID} -- SUPPORTED tier: the pinned upstream ref's own gate accepts this release and this installer can drive it (${summary}). NOT a claim that it has been tested: this line reports the TIER, which is derived from the pin, and the tier says nothing about which of its releases anyone has installed. That evidence is a dated run in tests/MATRIX-STATUS.md, which names the pairs that have one.${note}"
            return 0
            ;;
        legacy)
            # Not `ok`: nothing has proven this row against the ref that is
            # pinned, and upstream may refuse the box outright -- see the
            # upstream_gate check. Not `fail` either: it is a documented,
            # deliberate path, and refusing it would abandon every user the
            # automation this project replaces serves today.
            _PF_OS_SUPPORTED="false"
            summary=$(_tpot_pf_matrix_summary supported)
            pf_record os warn \
                "${_PF_OS_ID} ${_PF_OS_VERSION_ID} -- LEGACY tier (D-07): documented, reachable only by pinning an older tpot_upstream_ref, and NOT claimed as tested. Upstream's own gate may refuse this box before anything is installed; see the upstream_gate check. Supported tier: ${summary}.${note}"
            return 0
            ;;
    esac

    _PF_OS_SUPPORTED="false"
    summary=$(_tpot_pf_matrix_summary)
    if [[ $forced == "yes" ]]; then
        pf_record os warn \
            "${_PF_OS_ID} ${_PF_OS_VERSION_ID} is in neither tier of the support matrix (${summary}); proceeding because tpot_force_unsupported_os is set, and result.json will record it as unsupported and forced. That flag relaxes THIS check only -- upstream's own distribution gate has no override at all.${note}"
        return 0
    fi
    pf_record os fail \
        "${_PF_OS_ID} ${_PF_OS_VERSION_ID} is in neither tier of the support matrix (${summary}). Re-run with --force-unsupported-os to proceed anyway; the result will be recorded as unsupported. Stage A runs before any answer file is read, so this override must come from the flag or from TPOT_FORCE_UNSUPPORTED_OS.${note}"
    return 0
}

_tpot_pf_check_arch() {
    local arch
    arch=$(uname -m 2>/dev/null) || arch=""
    _PF_ARCH=$arch
    if [[ -z $arch ]]; then
        pf_record arch inconclusive "uname -m produced nothing"
        return 0
    fi
    if [[ " ${_PF_SUPPORTED_ARCH} " == *" ${arch} "* ]]; then
        pf_record arch ok "$arch"
        return 0
    fi
    pf_record arch fail \
        "unsupported architecture ${arch} -- this installer supports ${_PF_SUPPORTED_ARCH// /, }"
    return 0
}

_tpot_pf_check_systemd() {
    if [[ -d /run/systemd/system ]]; then
        pf_record systemd ok "present (/run/systemd/system)"
        return 0
    fi
    pf_record systemd fail \
        "/run/systemd/system does not exist -- T-Pot ships a systemd unit and this box is not running systemd"
    return 0
}

_tpot_pf_check_runtime_dir() {
    local parent fstype=""
    parent=${OPT_RUNTIME_PARENT:-/run}
    if [[ ! -d $parent ]]; then
        pf_record runtime_dir fail \
            "${parent} does not exist or is not a directory; the run directory holding merged configuration cannot be created there"
        return 0
    fi
    if _tpot_pf_have findmnt; then
        fstype=$(findmnt -no FSTYPE -- "$parent" 2>/dev/null) || fstype=""
    fi
    if [[ -z $fstype ]] && _tpot_pf_have stat; then
        fstype=$(stat -f -c %T -- "$parent" 2>/dev/null) || fstype=""
    fi
    _PF_RUNTIME_FSTYPE=$fstype
    if [[ -z $fstype ]]; then
        pf_record runtime_dir inconclusive \
            "could not determine the filesystem type of ${parent}; neither findmnt nor stat -f answered"
        return 0
    fi
    case $fstype in
        tmpfs|ramfs)
            pf_record runtime_dir ok "${parent} is ${fstype}"
            return 0
            ;;
    esac
    pf_record runtime_dir fail \
        "${parent} is ${fstype}, not tmpfs -- the merged configuration holds the dashboard password and would be written to a persistent filesystem. Use --runtime-dir /dev/shm"
    return 0
}

# ---------------------------------------------------------------------------
# answer_file
#
# Two rules, and both are checked rather than merely documented:
#
#   LOCATION    the file's resolved path must not be inside $REPO_DIR. This is
#               what stops an inventory-shaped credential store from growing
#               back: the installer this one replaces kept a live tenant's
#               passwords in a file committed to its own tree.
#   PERMISSION  a file that supplies any secret-typed key must be root-owned
#               and mode 0600 or 0400. A file with no secret in it has no
#               permission requirement, because there is nothing in it to
#               protect.
#
# A violation is the CALLER's mistake, so its exit code is EX_USAGE (10) and
# not EX_PREFLIGHT (11). pf_verdict is contractually 0/11/12, so the fact is
# carried separately in _PF_USAGE_ERROR and read by pf_usage_error.
#
# `--web-password-file` and `--os-user-password-file` are held to the same
# permission rule and reported under the same id: a file whose entire purpose
# is to hold a credential has no weaker claim on 0600 than an answer file that
# happens to contain one.
#
# Whether a file supplies a secret is decided by a grep for the three
# secret-typed key names at the start of a line, which reads both the YAML and
# the JSON spelling. It is deliberately not a parse: stage A must work before
# python3 has been established and must not depend on PyYAML being installed.
#
# lib/config.py enforces both rules again, authoritatively, when it merges --
# it has parsed the file by then and knows exactly which keys it supplies.
# This is the earlier and cheaper gate: it runs before the merge, before the
# transcript has anything in it and before a single package has been touched,
# which is the whole reason stage A exists.
# ---------------------------------------------------------------------------
_tpot_pf_secret_key_re='^[[:space:]]*["'\'']?(tpot_web_password|tpot_os_user_password|ioc_auth_header_value)["'\'']?[[:space:]]*:'

_tpot_pf_file_holds_secret() {
    local file=${1:-}
    if ! _tpot_pf_have grep; then
        return 2
    fi
    if grep -qE -e "$_tpot_pf_secret_key_re" -- "$file" 2>/dev/null; then
        return 0
    fi
    return 1
}

# Print "uid mode" for a file, e.g. "0 600". Returns 1 when stat cannot answer.
_tpot_pf_owner_mode() {
    local file=${1:-} out
    if ! _tpot_pf_have stat; then
        return 1
    fi
    out=$(stat -c '%u %a' -- "$file" 2>/dev/null) || return 1
    if [[ -z $out ]]; then
        return 1
    fi
    printf '%s\n' "$out"
    return 0
}

# Append one problem to the caller's accumulator, or one confirmation.
_tpot_pf_check_answer_file() {
    local -a problems=() good=()
    local repo_real="" file real uid mode holds entry key path
    local n_files=0

    if [[ -n ${REPO_DIR:-} ]]; then
        if _tpot_pf_have readlink; then
            repo_real=$(readlink -f -- "$REPO_DIR" 2>/dev/null) || repo_real=$REPO_DIR
        else
            repo_real=$REPO_DIR
        fi
    fi

    if declare -p OPT_CONFIG_FILES >/dev/null 2>&1; then
        for file in "${OPT_CONFIG_FILES[@]}"; do
            n_files=$(( n_files + 1 ))
            if [[ ! -e $file ]]; then
                problems+=("${file}: does not exist")
                continue
            fi
            if [[ ! -r $file ]]; then
                problems+=("${file}: is not readable")
                continue
            fi
            real=$file
            if _tpot_pf_have readlink; then
                real=$(readlink -f -- "$file" 2>/dev/null) || real=$file
            fi
            if [[ -n $repo_real && ( $real == "$repo_real" || $real == "$repo_real"/* ) ]]; then
                problems+=("${file}: resolves to ${real}, inside the installer tree ${repo_real} -- an answer file must live outside it")
                continue
            fi
            # 0 = holds a secret key, 1 = does not, 2 = could not tell.
            holds=0
            _tpot_pf_file_holds_secret "$file" || holds=$?
            if (( holds == 2 )); then
                problems+=("${file}: grep is unavailable, so it could not be established whether the file holds a secret key")
                continue
            fi
            if (( holds != 0 )); then
                good+=("${file} (no secret key; permissions not enforced)")
                continue
            fi
            if ! uid=$(_tpot_pf_owner_mode "$file"); then
                problems+=("${file}: supplies a secret key and its ownership could not be read")
                continue
            fi
            mode=${uid#* }
            uid=${uid%% *}
            if [[ $uid != "0" || ( $mode != "600" && $mode != "400" ) ]]; then
                problems+=("${file}: supplies a secret key but is owned by uid ${uid} with mode ${mode}; it must be root-owned and 0600 or 0400")
                continue
            fi
            good+=("${file} (root-owned ${mode}, outside the tree)")
        done
    fi

    if declare -p OPT_SECRET_FILES >/dev/null 2>&1; then
        for entry in "${OPT_SECRET_FILES[@]}"; do
            key=${entry%%=*}
            path=${entry#*=}
            n_files=$(( n_files + 1 ))
            if [[ ! -e $path ]]; then
                problems+=("${path}: was given as the file holding ${key} but does not exist")
                continue
            fi
            if [[ ! -r $path ]]; then
                problems+=("${path}: was given as the file holding ${key} but is not readable")
                continue
            fi
            if ! uid=$(_tpot_pf_owner_mode "$path"); then
                problems+=("${path}: holds the value of ${key} and its ownership could not be read")
                continue
            fi
            mode=${uid#* }
            uid=${uid%% *}
            if [[ $uid != "0" || ( $mode != "600" && $mode != "400" ) ]]; then
                problems+=("${path}: holds the value of ${key} but is owned by uid ${uid} with mode ${mode}; it must be root-owned and 0600 or 0400")
                continue
            fi
            good+=("${path} (${key}, root-owned ${mode})")
        done
    fi

    if (( ${#problems[@]} > 0 )); then
        _PF_USAGE_ERROR=1
        local joined="${problems[0]}"
        local i
        for (( i = 1; i < ${#problems[@]}; i++ )); do
            joined="${joined}; ${problems[$i]}"
        done
        pf_record answer_file fail "$joined"
        return 0
    fi
    if (( n_files == 0 )); then
        pf_record answer_file ok "no answer file and no password file were supplied"
        return 0
    fi
    if (( ${#good[@]} == 0 )); then
        pf_record answer_file inconclusive \
            "${n_files} file(s) were supplied but none was examined; this is a bug in the installer"
        return 0
    fi
    local joined="${good[0]}"
    local i
    for (( i = 1; i < ${#good[@]}; i++ )); do
        joined="${joined}; ${good[$i]}"
    done
    pf_record answer_file ok "$joined"
    return 0
}

# ---------------------------------------------------------------------------
# repo_tree
#
# Two things a run cannot recover from, both free to check and both invisible
# until much later if they are not:
#
#   * an incomplete extraction -- a half-downloaded release, a zip that was
#     unpacked with a filter, a clone missing a submodule. The failure that
#     follows names a missing file three steps later, in the middle of a
#     dependency bootstrap that has already installed packages.
#   * a world-writable installer tree. Root is about to source and execute
#     every file in it; if any local user can rewrite one first, the box is
#     already lost and no later check will notice.
# ---------------------------------------------------------------------------
_tpot_pf_repo_manifest() {
    printf '%s\n' \
        VERSION \
        install.sh \
        ansible.cfg \
        requirements.yml \
        support-matrix.yml \
        site.yml \
        verify.yml \
        lib/exitcodes.sh \
        lib/matrix.sh \
        lib/args.sh \
        lib/preflight.sh \
        lib/deps.sh \
        lib/log.sh \
        lib/notice.sh \
        lib/result.sh \
        lib/config.py \
        lib/varschema.json
    return 0
}

_tpot_pf_check_repo_tree() {
    local root=${REPO_DIR:-} rel missing="" n_missing=0 n_play=0 mode note=""
    local -a manifest=()
    if [[ -z $root || ! -d $root ]]; then
        pf_record repo_tree inconclusive \
            "REPO_DIR is not set to a directory, so the installer tree could not be checked"
        return 0
    fi
    mapfile -t manifest < <(_tpot_pf_repo_manifest)
    for rel in "${manifest[@]}"; do
        if [[ ! -r "${root}/${rel}" ]]; then
            n_missing=$(( n_missing + 1 ))
            # The play slice is counted separately. See the note below the
            # `fail` branch: an absent site.yml is a checkout that is partial,
            # not a download that arrived broken, and telling a reader the
            # wrong one of those wastes an hour.
            case $rel in
                site.yml|verify.yml) n_play=$(( n_play + 1 )) ;;
            esac
            if (( n_missing <= 6 )); then
                if [[ -n $missing ]]; then
                    missing="${missing}, ${rel}"
                else
                    missing=$rel
                fi
            fi
        fi
    done
    if (( n_missing > 6 )); then
        missing="${missing} and $(( n_missing - 6 )) more"
    fi
    if (( n_missing > 0 )); then
        # WHICH incompleteness this is. Two very different situations produce
        # the same missing-file list, and the run stops either way, so the only
        # thing the record can still get right is which one a reader should go
        # and look at:
        #   * an extraction or clone that lost files -- the case this check was
        #     written for;
        #   * a checkout carrying the entrypoint and its libraries and none of
        #     the play. Nothing is wrong with the files that are on disk; the
        #     repair is to fetch the rest, not to re-download these.
        # THE SECOND BRANCH DOES NOT FIRE IN THIS TREE, and has not since the
        # play slice landed on 2026-09-04: every file in the manifest is
        # present here, so this whole block is skipped. It is kept because a
        # partial checkout of a release still meets it, and because a message
        # saying only "this copy of the installer is incomplete" sends that
        # reader to re-download something that is not damaged.
        if (( n_play == n_missing )); then
            note=" -- these are the play slice (site.yml, verify.yml and roles/**), which a complete release carries. Nothing is wrong with the files you do have: this checkout is partial rather than damaged, so fetch the whole release rather than replacing files one at a time. The installer cannot install without the play, and it refuses rather than pretending"
        else
            note=" -- this copy of the installer is incomplete"
        fi
        pf_record repo_tree fail \
            "${root} is missing ${n_missing} of ${#manifest[@]} required files (${missing})${note}"
        return 0
    fi
    mode=$(stat -c '%a' -- "$root" 2>/dev/null) || mode=""
    if [[ -z $mode ]]; then
        pf_record repo_tree inconclusive \
            "all ${#manifest[@]} required files are present in ${root}, but its permissions could not be read"
        return 0
    fi
    if [[ ${mode: -1} == [2367] ]]; then
        pf_record repo_tree fail \
            "${root} is world-writable (mode ${mode}) and root is about to execute what is in it"
        return 0
    fi
    if [[ ${mode: -2:1} == [2367] ]]; then
        pf_record repo_tree warn \
            "all ${#manifest[@]} required files are present in ${root}, which is group-writable (mode ${mode})"
        return 0
    fi
    pf_record repo_tree ok "all ${#manifest[@]} required files present in ${root} (mode ${mode})"
    return 0
}

# ---------------------------------------------------------------------------
# pf_stage_a
#   Run the stage A checks in the documented order. Returns 1 when any of them
#   produced `fail`, 0 otherwise -- but the exit CODE comes from pf_verdict,
#   which also accounts for the inconclusive ones.
#
#   Resets the record list: stage A is always the first thing preflight does,
#   and a second run of it must not double the report.
# ---------------------------------------------------------------------------
pf_stage_a() {
    local rec status
    _PF_RECORDS=()
    _PF_USAGE_ERROR=0
    _tpot_pf_check_root
    _tpot_pf_check_apt
    _tpot_pf_check_python3
    _tpot_pf_check_os
    _tpot_pf_check_arch
    _tpot_pf_check_systemd
    _tpot_pf_check_runtime_dir
    _tpot_pf_check_answer_file
    _tpot_pf_check_repo_tree
    for rec in "${_PF_RECORDS[@]}"; do
        status=$(_tpot_pf_rec_status "$rec")
        if [[ $status == "fail" ]]; then
            return 1
        fi
    done
    return 0
}

# ===========================================================================
# STAGE B -- after the merge, still zero mutation
# ===========================================================================

# The keys stage B reads out of the merged PUBLIC document. Listed once, here,
# because they are also the argument list of the single python3 call that
# loads them.
_tpot_pf_config_keys() {
    printf '%s\n' \
        tpot_min_memory_mb tpot_warn_memory_mb \
        tpot_min_cpus tpot_warn_cpus \
        tpot_min_disk_gb tpot_warn_disk_gb \
        tpot_max_map_count tpot_required_ports \
        tpot_os_user tpot_install_type \
        tpot_upstream_url tpot_upstream_ref \
        tpot_ansible_source tpot_firewall_mode \
        tpot_admin_ssh_port tpot_dashboard_port tpot_elasticsearch_port \
        tpot_force_low_resources tpot_force_reinstall tpot_force_unsupported_os
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_int KEY DEFAULT
#   A threshold from the merged document, or DEFAULT when it is absent or not
#   an integer. A non-integer threshold is a configuration error the merge
#   should already have refused; falling back rather than dividing by it keeps
#   preflight from being the thing that crashes.
# ---------------------------------------------------------------------------
_tpot_pf_int() {
    local val
    val=$(_tpot_pf_cfg "${1:-}" "${2:-0}")
    if [[ $val =~ ^-?[0-9]+$ ]]; then
        printf '%s\n' "$val"
    else
        printf '%s\n' "${2:-0}"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_colon_field N STRING
#   Nth colon-separated field, for /etc/passwd records.
# ---------------------------------------------------------------------------
_tpot_pf_colon_field() {
    local n=${1:-1} s=${2:-} i=0 tok
    while true; do
        i=$(( i + 1 ))
        tok=${s%%:*}
        if (( i == n )); then
            printf '%s\n' "$tok"
            return 0
        fi
        if [[ $s != *:* ]]; then
            return 1
        fi
        s=${s#*:}
    done
}

# ---------------------------------------------------------------------------
# _tpot_pf_record_threshold ID VALUE MIN WARN DETAIL
#   The shared shape of the three resource checks: below the floor is a
#   failure, between floor and recommendation is a warning, above is fine.
#
#   --force-low-resources downgrades the failure to a warning, and the record
#   SAYS SO. A forced run that looked identical to a clean one would make the
#   artefact a lie the first time somebody read it back to explain why a box
#   fell over.
# ---------------------------------------------------------------------------
_tpot_pf_record_threshold() {
    local id=${1:-} value=${2:-0} min=${3:-0} warn=${4:-0} detail=${5:-} note=${6:-}
    if [[ -n $note ]]; then
        note="; ${note}"
    fi
    if (( value < min )); then
        if _tpot_pf_cfg_bool tpot_force_low_resources; then
            pf_record "$id" warn \
                "${detail} -- BELOW THE HARD FLOOR; downgraded to a warning by tpot_force_low_resources, and recorded as forced${note}"
            return 0
        fi
        pf_record "$id" fail \
            "${detail} -- below the hard floor. Re-run with --force-low-resources to install anyway${note}"
        return 0
    fi
    if (( value < warn )); then
        pf_record "$id" warn "${detail} -- below the recommendation${note}"
        return 0
    fi
    pf_record "$id" ok "${detail}${note}"
    return 0
}

_tpot_pf_check_memory() {
    local -a lines=()
    local line kb="" mb min warn
    min=$(_tpot_pf_int tpot_min_memory_mb "$_PF_DEF_MIN_MEMORY_MB")
    warn=$(_tpot_pf_int tpot_warn_memory_mb "$_PF_DEF_WARN_MEMORY_MB")
    if [[ ! -r $PF_PROC_MEMINFO ]]; then
        pf_record memory inconclusive \
            "${PF_PROC_MEMINFO} is unreadable; installed memory could not be measured (min ${min} MiB, recommended ${warn} MiB)"
        return 0
    fi
    mapfile -t lines < "$PF_PROC_MEMINFO"
    for line in "${lines[@]}"; do
        if [[ $line == "MemTotal:"* ]]; then
            kb=$(_tpot_pf_field 2 "$line") || kb=""
            break
        fi
    done
    if [[ ! $kb =~ ^[0-9]+$ ]]; then
        pf_record memory inconclusive \
            "${PF_PROC_MEMINFO} has no usable MemTotal line (min ${min} MiB, recommended ${warn} MiB)"
        return 0
    fi
    mb=$(( kb / 1024 ))
    _PF_MEMORY_MB=$mb
    _tpot_pf_record_threshold memory "$mb" "$min" "$warn" \
        "${mb} MiB (min ${min}, recommended ${warn})"
    return 0
}

# ---------------------------------------------------------------------------
# cpus -- hard floor 2, recommendation 4, and NEITHER NUMBER HAS AN UPSTREAM
# SOURCE.
#
# UPSTREAM STATES NO CPU FIGURE AT ALL. Its README gives memory and disk and is
# silent on processors, and its install.sh contains no CPU, RAM or disk check
# of any kind. So unlike memory and disk below, there is nothing here to cite
# and nothing to deviate from: these thresholds rest entirely on the two tenant
# guides this project inherited, WHICH DISAGREE WITH EACH OTHER -- one says 4,
# the other 8.
#
# That disagreement is why the two numbers sit where they do. Hard-failing an
# install on a figure two sources contradict each other about would be the
# worst available option: it turns an unresolved question into a refusal, on
# somebody else's box. So the WARNING is 4 -- the lower of the two disputed
# figures, and the point at which one of the guides would already have
# objected -- and the FLOOR is 2, below both of them, so that the only outcome
# that can stop a run rests on a number neither document argues about.
#
# NOTHING SOURCES 2 ITSELF. It is a deliberately conservative floor and not a
# measurement: no upstream figure, no benchmark, and no run of this installer
# stands behind it, because there has not been one. Do not write a sentence
# here claiming what happens below it. Both thresholds are overridable with
# --force-low-resources, which the record then says was used.
# ---------------------------------------------------------------------------
_tpot_pf_check_cpus() {
    local n="" min warn line
    local -a lines=()
    min=$(_tpot_pf_int tpot_min_cpus "$_PF_DEF_MIN_CPUS")
    warn=$(_tpot_pf_int tpot_warn_cpus "$_PF_DEF_WARN_CPUS")
    if _tpot_pf_have nproc; then
        n=$(nproc 2>/dev/null) || n=""
    fi
    if [[ ! $n =~ ^[0-9]+$ ]] && _tpot_pf_have getconf; then
        n=$(getconf _NPROCESSORS_ONLN 2>/dev/null) || n=""
    fi
    if [[ ! $n =~ ^[0-9]+$ ]] && [[ -r $PF_PROC_CPUINFO ]]; then
        n=0
        mapfile -t lines < "$PF_PROC_CPUINFO"
        for line in "${lines[@]}"; do
            if [[ $line == "processor"*:* ]]; then
                n=$(( n + 1 ))
            fi
        done
    fi
    if [[ ! $n =~ ^[0-9]+$ ]] || (( n == 0 )); then
        pf_record cpus inconclusive \
            "the processor count could not be established (min ${min}, recommended ${warn})"
        return 0
    fi
    _PF_CPUS=$n
    _tpot_pf_record_threshold cpus "$n" "$min" "$warn" \
        "${n} (min ${min}, recommended ${warn})"
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_pf_home_path
#   Print the directory whose filesystem will hold the T-Pot account's home,
#   and on stderr-free stdout a second line saying how it was determined.
#
#   On a fresh box the account does not exist yet -- preflight runs before
#   anything is created, so that is the NORMAL case. The check then measures
#   the nearest existing ancestor of where the account will be created and
#   says so in its detail, rather than reporting a filesystem nobody asked
#   about or refusing to answer.
# ---------------------------------------------------------------------------
_tpot_pf_home_path() {
    local user entry="" home="" line
    local -a lines=()
    user=$(_tpot_pf_cfg tpot_os_user "$_PF_DEF_OS_USER")
    if _tpot_pf_have getent; then
        entry=$(getent passwd "$user" 2>/dev/null) || entry=""
    fi
    if [[ -z $entry && -r /etc/passwd ]]; then
        mapfile -t lines < /etc/passwd
        for line in "${lines[@]}"; do
            if [[ $line == "${user}:"* ]]; then
                entry=$line
                break
            fi
        done
    fi
    if [[ -n $entry ]]; then
        home=$(_tpot_pf_colon_field 6 "$entry") || home=""
    fi
    if [[ -n $home ]]; then
        printf '%s\n' "$home"
        printf '%s\n' "existing"
        return 0
    fi
    printf '%s\n' "$(_tpot_pf_nearest_existing "/home/${user}")"
    printf '%s\n' "prospective"
    return 0
}

# ---------------------------------------------------------------------------
# disk_home and disk_docker -- 64 GiB floor, and it is BELOW UPSTREAM'S OWN
# STATED MINIMUM. That is deliberate, and it is written here so that nobody
# "corrects" it back and nobody quotes it as though upstream agreed.
#
# UPSTREAM SAYS: "at least 8-16 GB RAM, 128 GB free disk space" (README), and
# per role: Hive 16 GB RAM / 256 GB SSD, Sensor 8 GB RAM / 128 GB SSD. Upstream
# also states a working non-proxied internet connection and an IPv4 address as
# requirements. Its install.sh checks none of them.
#
# WE USE 64 GiB as the hard floor and 256 GiB as the recommendation. The
# recommendation matches upstream's Hive figure. The floor is HALF upstream's
# stated minimum, and it has exactly one reason: this project's own test guest
# is capped at about 190 GB by the 200G refquota on the dataset it lives on,
# and a floor at upstream's 128 GB would leave no headroom to speak of. The
# inherited tenant guide does not support a lower floor either -- it asks for
# 256 GB -- so nothing outside this paragraph stands behind 64. It is a
# deviation from upstream, not a reading of it, and no install has yet been
# run at it or anywhere near it.
#
# WHAT THAT COSTS. T-Pot's persistence cycle defaults to 30 days of captured
# data and TPOT_PULL_POLICY defaults to `always`, so images are re-pulled at
# every start; a box near the floor fills up quietly, and Elasticsearch is
# where it shows first. Below 128 GB the honest statement is "this works and
# upstream does not promise it will", which is what the warning band between
# 64 and 256 is for.
#
# Both filesystems are measured separately and on purpose: /home and
# /var/lib/docker are frequently different devices, and the one that fills is
# usually not the one somebody checked.
# ---------------------------------------------------------------------------
_tpot_pf_check_disk_home() {
    local min warn path kind gb user note
    local -a out=()
    min=$(_tpot_pf_int tpot_min_disk_gb "$_PF_DEF_MIN_DISK_GB")
    warn=$(_tpot_pf_int tpot_warn_disk_gb "$_PF_DEF_WARN_DISK_GB")
    user=$(_tpot_pf_cfg tpot_os_user "$_PF_DEF_OS_USER")
    mapfile -t out < <(_tpot_pf_home_path)
    path=${out[0]:-/}
    kind=${out[1]:-prospective}
    if [[ ! -e $path ]]; then
        path=$(_tpot_pf_nearest_existing "$path")
    fi
    if ! gb=$(_tpot_pf_free_gb "$path"); then
        pf_record disk_home inconclusive \
            "free space on the filesystem holding ${path} could not be measured (min ${min} GiB, recommended ${warn} GiB)"
        return 0
    fi
    _PF_DISK_HOME_GB=$gb
    note=""
    if [[ $kind == "prospective" ]]; then
        note="the account ${user} does not exist yet, so this is the filesystem that will hold its home"
    fi
    _tpot_pf_record_threshold disk_home "$gb" "$min" "$warn" \
        "${gb} GiB free on ${path} (min ${min}, recommended ${warn})" "$note"
    return 0
}

_tpot_pf_check_disk_docker() {
    local min warn path gb note=""
    min=$(_tpot_pf_int tpot_min_disk_gb "$_PF_DEF_MIN_DISK_GB")
    warn=$(_tpot_pf_int tpot_warn_disk_gb "$_PF_DEF_WARN_DISK_GB")
    path="/var/lib/docker"
    if [[ ! -e $path ]]; then
        path=$(_tpot_pf_nearest_existing "$path")
        note="/var/lib/docker does not exist yet, so this is the filesystem that will hold it"
    fi
    if ! gb=$(_tpot_pf_free_gb "$path"); then
        pf_record disk_docker inconclusive \
            "free space on the filesystem holding ${path} could not be measured (min ${min} GiB, recommended ${warn} GiB)"
        return 0
    fi
    _PF_DISK_DOCKER_GB=$gb
    _tpot_pf_record_threshold disk_docker "$gb" "$min" "$warn" \
        "${gb} GiB free on ${path} (min ${min}, recommended ${warn})" "$note"
    return 0
}

# ---------------------------------------------------------------------------
# max_map_count -- WARN ONLY, NEVER FAIL.
#
# Elasticsearch will not start without it, and roles/os_prep sets it through
# /etc/sysctl.d/99-tpot-automation.conf -- its own file, rather than the
# /etc/sysctl.conf upstream writes and never reloads. Preflight runs BEFORE
# that role, so what it records here is the box's own value: a run which later
# fails inside Elasticsearch has the before value written down, and somebody
# reading result.json can tell a box that was already tuned from one this
# installer tuned.
# ---------------------------------------------------------------------------
_tpot_pf_check_max_map_count() {
    local want current
    want=$(_tpot_pf_int tpot_max_map_count "$_PF_DEF_MAX_MAP_COUNT")
    if [[ ! -r $PF_PROC_MAX_MAP_COUNT ]]; then
        pf_record max_map_count inconclusive \
            "${PF_PROC_MAX_MAP_COUNT} is unreadable; os_prep will still set it to ${want}"
        return 0
    fi
    current=$(cat -- "$PF_PROC_MAX_MAP_COUNT" 2>/dev/null) || current=""
    current=${current//[[:space:]]/}
    if [[ ! $current =~ ^[0-9]+$ ]]; then
        pf_record max_map_count inconclusive \
            "${PF_PROC_MAX_MAP_COUNT} did not contain a number; os_prep will still set it to ${want}"
        return 0
    fi
    _PF_MAX_MAP_COUNT=$current
    if (( current < want )); then
        pf_record max_map_count warn \
            "${current} -- os_prep will raise it to ${want}, which Elasticsearch requires"
        return 0
    fi
    pf_record max_map_count ok "${current} (at or above the required ${want})"
    return 0
}

# ---------------------------------------------------------------------------
# ports -- THE UNION OF TWO DISJOINT SETS, AND TWO POSSIBLE LAYOUTS
#
# WHY A UNION. This check used to look at 22, 64295, 64297 and 64298 -- ours --
# while upstream's install.sh aborts on tcp/25, tcp/53 and udp/53, which we
# never looked at. The two sets do not overlap anywhere. Upstream's check runs
# AFTER this one and AFTER os_prep has already changed the box, so a stock
# Debian netinst -- which ships exim4 on 127.0.0.1:25, and upstream's own
# comment says a loopback-only listener counts -- would pass here, be mutated,
# and then be refused an hour later by a check we could have run in
# milliseconds while the box was still untouched. So the union is checked.
#
# The two origins stay distinguishable, and only one of them is configurable:
# tpot_required_ports is ours to relax, upstream's three are not. Relaxing
# those here would not make the install work; it would only move the refusal to
# a point where we had already changed the box.
#
# WHY TWO `ss` INVOCATIONS. udp/53 cannot be seen with -t. A check that
# silently only did TCP would report a box running a DNS server as clean and
# upstream would still refuse it.
#
# UPSTREAM'S ONE EXEMPTION, mirrored exactly: a holder named `systemd-resolve`
# on tcp/53 or udp/53 is not a conflict. See _PF_PORT_EXEMPT_HOLDER for why the
# name has no trailing `d`.
#
# THE TWO LAYOUTS, and this is what makes exit 20 recoverable.
#
#   PRE-INSTALL   the box is clean. Port 22 belongs to the host's own sshd and
#                 to nothing else; every other port in the union must be free,
#                 apart from upstream's exemption on 53.
#   POST-INSTALL  T-Pot is already installed. sshd has MOVED to 64295, 22 is a
#                 honeypot container, and 25 and 53 are expected to be held by
#                 T-Pot's containers as well -- INFERRED from upstream refusing
#                 exactly those three before it installs, because neither
#                 upstream file states the mapping. tools/pin-upstream.sh does
#                 now fetch and read every compose file at the ref it pins, but
#                 only for service counts, restart policies and the telemetry
#                 service: no port mapping is extracted from them, so this
#                 inference is still unchecked. Every one of those is a
#                 hard failure under the pre-install rules, so the documented
#                 recovery from exit 20 ("re-run it") used to fail at
#                 EX_PREFLIGHT on a box where nothing was wrong.
#
# So the layout is established BEFORE anything is judged, from two independent
# signals: the installed-state detection (an existing .env, a tpot.service unit)
# and, failing that, the shape of the sockets themselves -- sshd on the
# administrative port while 22 is held by something that is not sshd is the
# post-install layout however it got there. Under it, NO holder is a failure;
# the worst outcome is a warning, and the layout that was observed is named in
# the record and written to host.json.
#
# Without privilege `ss` prints no `users:((...))` field. That is not "the port
# is free" and it is not "the port is held by sshd" -- it is a check that could
# not be exercised, and it is recorded as inconclusive. In a full run stage A
# has already failed on uid, so this only ever shows up under --preflight-only,
# which is exactly where honesty about it matters.
# ---------------------------------------------------------------------------
_tpot_pf_ss_procs() {
    local line=${1:-} rest name
    if [[ $line != *"users:("* ]]; then
        return 0
    fi
    rest=${line#*users:(}
    while [[ $rest == *'("'* ]]; do
        rest=${rest#*'("'}
        name=${rest%%'"'*}
        if [[ -n $name ]]; then
            printf '%s\n' "$name"
        fi
        rest=${rest#*'"'}
    done
    return 0
}

# Print the name of an active ssh socket unit, or return 1 having printed
# nothing. Under systemd socket activation the listener on 22 belongs to pid 1
# and `ss` names it `systemd`, not `sshd` -- that is how current Ubuntu ships,
# and Ubuntu is a release upstream's own gate accepts (at 26.04 exactly). It is
# not in OUR supported tier, because nothing is until a ref is pinned; it is a
# legacy-tier row today. Accepting the name `systemd` on
# trust would accept any socket-activated service; accepting it only when an
# ssh socket unit is genuinely active accepts the one thing the exception is
# for.
_tpot_pf_ssh_socket_unit() {
    local unit
    if ! _tpot_pf_have systemctl; then
        return 1
    fi
    for unit in ssh.socket sshd.socket; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            printf '%s\n' "$unit"
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# _tpot_pf_detect_installed
#   Establish, once per stage B run, whether T-Pot is already on this box.
#   Sets _PF_INSTALLED and _PF_INSTALLED_EVIDENCE and prints nothing.
#
#   A function that sets globals rather than one that prints them, because
#   `ports` needs the answer before `existing_tpot` reports it and a command
#   substitution would run in a subshell whose assignments are thrown away.
# ---------------------------------------------------------------------------
_tpot_pf_detect_installed() {
    local home envfile found="" units=""
    local -a out=()
    if (( _PF_INSTALLED_DONE )); then
        return 0
    fi
    _PF_INSTALLED_DONE=1
    mapfile -t out < <(_tpot_pf_home_path)
    home=${out[0]:-}
    if [[ -n $home ]]; then
        envfile="${home}/tpotce/.env"
        if [[ -e $envfile ]]; then
            found="an existing T-Pot configuration at ${envfile}"
        fi
    fi
    if _tpot_pf_have systemctl; then
        units=$(systemctl list-unit-files --no-legend --no-pager tpot.service 2>/dev/null) || units=""
    fi
    if [[ -n $units ]]; then
        if [[ -n $found ]]; then
            found="${found}, and a tpot.service unit"
        else
            found="a tpot.service unit"
        fi
    fi
    if [[ -n $found ]]; then
        _PF_INSTALLED=1
        _PF_INSTALLED_EVIDENCE=$found
    fi
    return 0
}

# Upstream's own conflict set, one "proto/port" per line. A function rather
# than an array expansion so the single string constant stays the one place it
# is written down.
_tpot_pf_upstream_conflict_entries() {
    _tpot_pf_split_ws "$_PF_UPSTREAM_CONFLICT_PORTS"
    return 0
}

# Deduplicate a whitespace-separated holder list, preserving order, joined with
# "/". One listening socket per `ss` line, so a host with an IPv4 and an IPv6
# sshd contributes the same name twice; "sshd/sshd" is still only sshd.
_tpot_pf_uniq_words() {
    local out="" p
    local -a words=()
    mapfile -t words < <(_tpot_pf_split_ws "${1:-}")
    for p in "${words[@]}"; do
        if [[ "/${out}/" != *"/${p}/"* ]]; then
            if [[ -n $out ]]; then
                out="${out}/${p}"
            else
                out=$p
            fi
        fi
    done
    printf '%s\n' "$out"
    return 0
}

_tpot_pf_check_ports() {
    local ports_csv rest tok rc=0 line addr lport key entry proto port dup
    local detail="" worst="ok" state names p all_ssh admin unit
    local ours_empty=0 need_udp=0 udp_ok=1 ss_out=""
    local sshd_on_admin=0 alien_on_22=0 layout_note=""
    local -a ours=() entries=() up_entries=() lines=() procs=()
    declare -A holders=()
    declare -A unknown=()

    admin=$(_tpot_pf_cfg tpot_admin_ssh_port "$_PF_DEF_ADMIN_SSH_PORT")
    if [[ ! $admin =~ ^[0-9]+$ ]]; then
        admin=$_PF_DEF_ADMIN_SSH_PORT
    fi

    # --- the union ---------------------------------------------------------
    ports_csv=$(_tpot_pf_cfg tpot_required_ports "$_PF_DEF_REQUIRED_PORTS")
    rest=${ports_csv//[\[\] ]/}
    while [[ -n $rest ]]; do
        tok=${rest%%,*}
        if [[ $tok =~ ^[0-9]+$ ]]; then
            ours+=("$tok")
        fi
        if [[ $rest != *,* ]]; then
            break
        fi
        rest=${rest#*,}
    done
    if (( ${#ours[@]} == 0 )); then
        ours_empty=1
    fi
    for tok in "${ours[@]}"; do
        entries+=("tcp/${tok}")
    done
    # Upstream's three are appended, never substituted: an empty or malformed
    # tpot_required_ports must not silently take upstream's set down with it.
    mapfile -t up_entries < <(_tpot_pf_upstream_conflict_entries)
    for entry in "${up_entries[@]}"; do
        dup=0
        for tok in "${entries[@]}"; do
            if [[ $tok == "$entry" ]]; then
                dup=1
            fi
        done
        if (( dup == 0 )); then
            entries+=("$entry")
        fi
    done
    for entry in "${entries[@]}"; do
        if [[ $entry == udp/* ]]; then
            need_udp=1
        fi
    done

    # --- what is listening -------------------------------------------------
    if ! _tpot_pf_have ss; then
        pf_record ports inconclusive \
            "ss is not installed (package iproute2), so none of ${entries[*]} could be checked. Upstream's installer requires ss too, treats its absence as a hard error, and installs no package that provides it"
        return 0
    fi
    ss_out=$(ss -H -t -l -n -p 2>/dev/null) || rc=$?
    if (( rc != 0 )); then
        pf_record ports inconclusive \
            "ss -t exited ${rc}; ports ${entries[*]} could not be checked"
        return 0
    fi
    mapfile -t lines < <(printf '%s\n' "$ss_out")
    for line in "${lines[@]}"; do
        if [[ -z $line ]]; then
            continue
        fi
        addr=$(_tpot_pf_field 4 "$line") || continue
        lport=${addr##*:}
        if [[ ! $lport =~ ^[0-9]+$ ]]; then
            continue
        fi
        key="tcp/${lport}"
        mapfile -t procs < <(_tpot_pf_ss_procs "$line")
        if (( ${#procs[@]} == 0 )); then
            unknown["$key"]=1
        else
            holders["$key"]="${holders[$key]:-} ${procs[*]}"
        fi
    done
    if (( need_udp )); then
        rc=0
        ss_out=$(ss -H -u -l -n -p 2>/dev/null) || rc=$?
        if (( rc != 0 )); then
            udp_ok=0
        else
            mapfile -t lines < <(printf '%s\n' "$ss_out")
            for line in "${lines[@]}"; do
                if [[ -z $line ]]; then
                    continue
                fi
                addr=$(_tpot_pf_field 4 "$line") || continue
                lport=${addr##*:}
                if [[ ! $lport =~ ^[0-9]+$ ]]; then
                    continue
                fi
                key="udp/${lport}"
                mapfile -t procs < <(_tpot_pf_ss_procs "$line")
                if (( ${#procs[@]} == 0 )); then
                    unknown["$key"]=1
                else
                    holders["$key"]="${holders[$key]:-} ${procs[*]}"
                fi
            done
        fi
    fi

    # --- which layout is this ----------------------------------------------
    mapfile -t procs < <(_tpot_pf_split_ws "${holders[tcp/${admin}]:-}")
    for p in "${procs[@]}"; do
        case $p in
            sshd|sshd-session) sshd_on_admin=1 ;;
        esac
    done
    mapfile -t procs < <(_tpot_pf_split_ws "${holders[tcp/22]:-}")
    for p in "${procs[@]}"; do
        case $p in
            sshd|sshd-session|systemd) ;;
            *)                         alien_on_22=1 ;;
        esac
    done
    _tpot_pf_detect_installed
    if (( _PF_INSTALLED == 0 )) && (( sshd_on_admin == 1 )) && (( alien_on_22 == 1 )); then
        # No .env and no unit, but the sockets are unambiguous. Believing them
        # is what keeps the documented recovery from exit 20 -- re-run it --
        # from failing on a box where nothing is wrong.
        _PF_INSTALLED=1
        _PF_INSTALLED_INFERRED=1
        _PF_INSTALLED_EVIDENCE="administrative ssh on ${admin} and 22 held by something that is not sshd"
    fi
    if (( _PF_INSTALLED )); then
        if (( sshd_on_admin )); then
            _PF_PORT_LAYOUT="post_install"
        else
            _PF_PORT_LAYOUT="post_install_incomplete"
        fi
    else
        _PF_PORT_LAYOUT="pre_install"
    fi

    # --- judge it ----------------------------------------------------------
    for entry in "${entries[@]}"; do
        proto=${entry%%/*}
        port=${entry##*/}
        if [[ $proto == "udp" ]] && (( udp_ok == 0 )); then
            state="${entry} could not be checked: ss -u failed"
            worst=$(_tpot_pf_worse "$worst" inconclusive)
        elif [[ -n ${holders[$entry]:-} ]]; then
            names=$(_tpot_pf_uniq_words "${holders[$entry]}")
            mapfile -t procs < <(_tpot_pf_split_ws "${holders[$entry]}")
            all_ssh=1
            for p in "${procs[@]}"; do
                case $p in
                    sshd|sshd-session) ;;
                    *)                 all_ssh=0 ;;
                esac
            done
            if (( _PF_INSTALLED )); then
                # Nothing here is a failure. T-Pot is on this box and the ports
                # it serves are supposed to be busy.
                if [[ $proto == "tcp" && $port == "$admin" ]]; then
                    if (( all_ssh )); then
                        state="${entry} ${names} (administrative ssh, which is where it belongs after an install)"
                    else
                        state="${entry} held by ${names}, which is not the host ssh -- on an installed box this is where administrative ssh belongs"
                        worst=$(_tpot_pf_worse "$worst" warn)
                    fi
                elif [[ $entry == "tcp/22" ]] && (( all_ssh )); then
                    state="22 ${names} -- T-Pot is installed but administrative ssh has not moved to ${admin}; the install did not finish, or sshd was moved back"
                    worst=$(_tpot_pf_worse "$worst" warn)
                else
                    state="${entry} held by ${names} (expected: T-Pot is installed and serves this port)"
                fi
            elif [[ $entry == "tcp/22" ]]; then
                if (( all_ssh )); then
                    state="22 ${names} (allowed; upstream moves administrative ssh to ${admin} and puts a honeypot here)"
                elif [[ $names == "systemd" ]] && unit=$(_tpot_pf_ssh_socket_unit); then
                    state="22 held by systemd for ${unit}, which is the host ssh under socket activation (allowed; upstream moves administrative ssh to ${admin})"
                else
                    state="22 held by ${names}, which is not the host ssh"
                    worst=$(_tpot_pf_worse "$worst" fail)
                fi
            elif [[ $entry == "tcp/53" || $entry == "udp/53" ]] && [[ $names == "$_PF_PORT_EXEMPT_HOLDER" ]]; then
                state="${entry} ${names} (allowed: upstream's own port check exempts exactly this holder on 53, and the playbook disables the stub listener)"
            elif [[ $entry == "tcp/25" || $entry == "tcp/53" || $entry == "udp/53" ]]; then
                state="${entry} held by ${names} -- UPSTREAM aborts on this port, including a loopback-only listener"
                worst=$(_tpot_pf_worse "$worst" fail)
            else
                state="${entry} held by ${names}"
                worst=$(_tpot_pf_worse "$worst" fail)
            fi
        elif [[ -n ${unknown[$entry]:-} ]]; then
            state="${entry} in use by a process this run is not privileged to identify"
            worst=$(_tpot_pf_worse "$worst" inconclusive)
        else
            state="${entry} free"
            if (( _PF_INSTALLED )) && [[ $proto == "tcp" && $port == "$admin" ]]; then
                state="${entry} free -- T-Pot is installed but nothing is listening where administrative ssh belongs"
                worst=$(_tpot_pf_worse "$worst" warn)
            fi
        fi
        if [[ -n $detail ]]; then
            detail="${detail}, ${state}"
        else
            detail=$state
        fi
    done

    if (( ours_empty )); then
        detail="tpot_required_ports produced no port numbers (${ports_csv}), so only upstream's own conflict set was checked: ${detail}"
        worst=$(_tpot_pf_worse "$worst" inconclusive)
    fi
    layout_note="layout ${_PF_PORT_LAYOUT}"
    if (( _PF_INSTALLED )); then
        layout_note="${layout_note} (${_PF_INSTALLED_EVIDENCE})"
        if (( _PF_INSTALLED_INFERRED )); then
            layout_note="${layout_note}, inferred from the sockets rather than from an existing configuration"
        fi
    fi
    detail="${detail} [${layout_note}; tcp/25, tcp/53 and udp/53 are upstream's own conflict set and are not configurable]"
    pf_record ports "$worst" "$detail"
    return 0
}

# ---------------------------------------------------------------------------
# upstream_gate -- tell the user what UPSTREAM will say, before we change
# anything
#
# Upstream's install.sh gates twice before it will do anything at all:
# membership of /etc/os-release's NAME field in a fixed list, then an exact
# version comparison. Both are `exit 1`. Neither has an override flag, and
# tpot_force_unsupported_os relaxes OUR check and cannot touch theirs. Against
# the copy read on 2026-09-02, exactly one of this project's nine inherited
# releases survives them (D-07).
#
# ▲ Corrected 2026-09-04. This comment used to say the gates "run before its
# own -s handling", and that is backwards: `-s` is parsed by the getopts loop
# at install.sh:215 and the gates are at :294-339, so the gates run AFTER `-s`
# has been read. They simply never consult it -- which is why unattended mode
# cannot reach past them, and why the conclusion above is unaffected. The
# distinction is kept because "runs before" is a claim someone could go and
# check, find false, and then reasonably doubt the rest of the paragraph.
#
# Pre-empting that here is worth doing because the alternative is discovering
# it at minute 40, on a box os_prep has already changed.
#
# WHY IT IS NOT ALWAYS A VERDICT. `-b` pins upstream's PAYLOAD, not the copy of
# install.sh that runs -- that is whichever copy this run fetched (D-10). So
# these rules are known only for the ref they were read at, and this check says
# so rather than pretending otherwise:
#
#   ref unset                       inconclusive. Nothing to pre-empt yet, and
#                                   saying which variable pins it is more
#                                   useful than a green line.
#   rules known for the pinned ref  ok, or FAIL -- an authoritative answer.
#                                   DORMANT: see below. No legal pin reaches
#                                   either of these two today.
#   rules from a different ref,
#     and they refuse this box      warn. Loud, actionable, and honest about
#                                   where the rules came from.
#   rules from a different ref,
#     and they accept this box      INCONCLUSIVE, not ok. "Upstream will accept
#                                   this box" without having read the pinned
#                                   ref's gate is exactly the untrue assertion
#                                   D-10 exists to prevent.
#
# THE FIRST TWO OUTCOMES ARE DORMANT, and reading the table without this
# paragraph overstates what the check does. "Rules known for the pinned ref"
# means the ref appears in _PF_UPSTREAM_GATE_VALID_REFS, which holds exactly
# one entry -- `master` -- while lib/varschema.json's pattern for
# tpot_upstream_ref refuses master, main and HEAD. The two sets are therefore
# disjoint by construction, so every legal pin lands on `warn` or
# `inconclusive` and this check never returns a verdict. It fails in the safe
# direction, which is why it is written this way and not the other; but the ok
# and fail arms are code waiting for tools/pin-upstream.sh to extend the list
# from the install.sh it pinned. That tool exists now and still does not do
# it: it writes the gate it read into the pinned ref's data file under
# roles/tpot_install/vars/, and preflight cannot read that file -- it is bash,
# it runs before the dependency bootstrap, and lib/matrix.sh is the only YAML
# reader it has. Until the two are joined up, treat every outcome of this
# check as advisory.
#
# MEMBERSHIP IS AN EXACT WHOLE-ELEMENT COMPARISON IN A LOOP. Upstream's own
# test is `[[ ! " ${arr[@]} " =~ " ${x} " ]]` with the right-hand side quoted,
# so bash compares it literally against the space-joined array -- measured
# accepting the bare string "Linux" and accepting a value spanning two array
# elements. We reproduce upstream's ANSWERS, never its idiom.
# ---------------------------------------------------------------------------
#
# Upstream's gate as data: NAME<TAB>comparison<TAB>required.
#   major    compare ${VERSION_ID%%.*}   full   compare VERSION_ID verbatim
#   rolling  no version gate at all (upstream skips it for a rolling release)
# Note the asymmetry between Debian and Ubuntu -- it is upstream's, not a typo.
_tpot_pf_upstream_gate_table() {
    printf '%s\t%s\t%s\n' \
        "AlmaLinux"                major   10 \
        "Debian GNU/Linux"         major   13 \
        "Fedora Linux"             major   44 \
        "openSUSE Tumbleweed"      rolling "" \
        "Raspbian GNU/Linux"       major   13 \
        "Red Hat Enterprise Linux" major   10 \
        "Rocky Linux"              major   10 \
        "Ubuntu"                   full    26.04
    return 0
}

_tpot_pf_check_upstream_gate() {
    local ref name ver rowname cmp want have line rest tok sref="" coupling=""
    local found=0 known=0 verdict="" reason=""
    local -a rows=() refs=()

    ref=$(_tpot_pf_cfg tpot_upstream_ref "")
    if [[ -z $ref ]]; then
        pf_record upstream_gate inconclusive \
            "tpot_upstream_ref is not pinned, so upstream's own distribution gate could not be pre-empted. Set it to a tag or a full 40-character commit sha of upstream T-Pot; tools/pin-upstream.sh derives it and writes everything that follows from it. Upstream applies that gate on this box, before it will do anything at all, and it has no override flag"
        return 0
    fi
    if [[ -z $_PF_OS_ID ]]; then
        pf_record upstream_gate inconclusive \
            "this box could not be identified (see the os check), so upstream's gate could not be pre-empted"
        return 0
    fi
    if ! _tpot_pf_need_matrix; then
        pf_record upstream_gate inconclusive \
            "lib/matrix.sh could not be loaded, so ${PF_OS_RELEASE} could not be read for the NAME field upstream's gate compares"
        return 0
    fi

    # THE COUPLING D-07 NAMES, checked rather than merely documented.
    # support-matrix.yml's supported tier is DERIVED from an upstream ref, and
    # this run pins one. When they are not the same ref, "supported" is a claim
    # about a box nobody is installing, and this is the only check in the run
    # that can see both halves: the tier comes from a file read at stage A, the
    # pin from the merge.
    if declare -F matrix_supported_ref >/dev/null 2>&1; then
        sref=$(matrix_supported_ref 2>/dev/null) || sref=""
    fi
    if [[ -z $sref ]]; then
        coupling=" NOTE: support-matrix.yml names no ref for its supported tier, so that tier is empty and nothing in it is currently claimed as tested (D-07)"
    elif [[ $sref != "$ref" ]]; then
        coupling=" NOTE: support-matrix.yml derives its supported tier from ref ${sref} while this run pins ${ref}. The two are coupled (D-07): re-derive the tier from the ref being installed, or the os check above is a claim about a different upstream"
    fi
    # NAME, not ID. Upstream matches on NAME and the two differ exactly where
    # it matters: Linux Mint reports ID=linuxmint and NAME="Linux Mint", and
    # NAME is what is absent from upstream's list.
    name=$(matrix_os_release_field NAME "$PF_OS_RELEASE" 2>/dev/null) || name=""
    if [[ -z $name ]]; then
        pf_record upstream_gate inconclusive \
            "${PF_OS_RELEASE} carries no NAME field, and NAME -- not ID -- is what upstream's gate compares"
        return 0
    fi
    ver=$_PF_OS_VERSION_ID

    mapfile -t rows < <(_tpot_pf_upstream_gate_table)
    for line in "${rows[@]}"; do
        rowname=${line%%$'\t'*}
        if [[ $rowname == "$name" ]]; then
            found=1
            rest=${line#*$'\t'}
            cmp=${rest%%$'\t'*}
            want=${rest#*$'\t'}
            break
        fi
    done

    if (( found == 0 )); then
        verdict="refuse"
        reason="NAME=\"${name}\" is not on upstream's supported-distribution list at all"
    elif [[ $cmp == "rolling" ]]; then
        verdict="accept"
        reason="NAME=\"${name}\" is a rolling release, and upstream skips its version gate"
    else
        if [[ $cmp == "major" ]]; then
            have=${ver%%.*}
        else
            have=$ver
        fi
        if [[ -z $have ]]; then
            pf_record upstream_gate inconclusive \
                "this box reports no VERSION_ID, and upstream's gate for NAME=\"${name}\" compares one"
            return 0
        fi
        if [[ $have == "$want" ]]; then
            verdict="accept"
            reason="NAME=\"${name}\" requires ${want} and this box reports ${have}"
        else
            verdict="refuse"
            reason="upstream requires ${want} for NAME=\"${name}\" and this box reports ${have}. The comparison is exact string inequality -- no ordering, no override. Upstream states the policy itself: \"${_PF_UPSTREAM_GATE_POLICY}\""
        fi
    fi

    mapfile -t refs < <(_tpot_pf_split_ws "$_PF_UPSTREAM_GATE_VALID_REFS")
    for tok in "${refs[@]}"; do
        if [[ $tok == "$ref" ]]; then
            known=1
        fi
    done

    if (( known )); then
        if [[ $verdict == "refuse" ]]; then
            pf_record upstream_gate fail \
                "UPSTREAM WILL REFUSE THIS BOX at ref ${ref}: ${reason}. It exits 1 before installing anything, so nothing here has been changed -- pin a ref whose gate accepts this release, or install on one it does.${coupling}"
            return 0
        fi
        pf_record upstream_gate ok \
            "upstream's gate at ref ${ref} accepts this box: ${reason}.${coupling}"
        return 0
    fi

    if [[ $verdict == "refuse" ]]; then
        pf_record upstream_gate warn \
            "UPSTREAM IS LIKELY TO REFUSE THIS BOX: ${reason}. These gate rules were read from ${_PF_UPSTREAM_GATE_SOURCE}, not from the pinned ref ${ref}, and the gate that actually runs belongs to whichever copy of install.sh this run fetches (D-10) -- so this is a warning and not a verdict.${coupling}"
        return 0
    fi
    pf_record upstream_gate inconclusive \
        "upstream's gate was NOT checked for the pinned ref ${ref}: the only rules on hand were read from ${_PF_UPSTREAM_GATE_SOURCE}, and by those this box would be accepted (${reason}). The gate that runs belongs to whichever copy of install.sh this run fetches (D-10), so this is not a pass.${coupling}"
    return 0
}
# ---------------------------------------------------------------------------
# Reachability.
#
# Four separate checks with four separate ids, because "the network is fine"
# is four different questions and a single answer to them is unactionable at
# three in the morning. Each one names the host it could not reach.
# ---------------------------------------------------------------------------
_tpot_pf_record_reachability() {
    local id=${1:-} scheme=${2:-https} host=${3:-} what=${4:-} soft=${5:-0}
    local reason rc=0
    reason=$(_tpot_pf_reachable "$scheme" "$host") || rc=$?
    if (( rc == 0 )); then
        pf_record "$id" ok "${host} answered (${what})"
        return 0
    fi
    if (( rc == 2 )); then
        pf_record "$id" inconclusive "${host} (${what}) could not be tested: ${reason}"
        return 0
    fi
    if (( soft )); then
        pf_record "$id" warn "${host} (${what}) is unreachable: ${reason}"
        return 0
    fi
    pf_record "$id" fail "${host} (${what}) is unreachable: ${reason} -- the install needs it"
    return 0
}

_tpot_pf_check_reachability_upstream() {
    local url ref scheme host
    url=$(_tpot_pf_cfg tpot_upstream_url "")
    if [[ -z $url ]]; then
        ref=$(_tpot_pf_cfg tpot_upstream_ref "")
        if [[ -z $ref ]]; then
            pf_record reachability_upstream inconclusive \
                "no upstream host to test: tpot_upstream_ref is not pinned. Set it with tools/pin-upstream.sh, which derives it and writes its per-release data file (roles/tpot_install/vars/upstream-<ref>.yml)"
        else
            pf_record reachability_upstream inconclusive \
                "no upstream host to test: tpot_upstream_ref is ${ref} but tpot_upstream_url is unset"
        fi
        return 0
    fi
    scheme=$(_tpot_pf_url_scheme "$url") || scheme="https"
    host=$(_tpot_pf_url_host "$url") || host=""
    if [[ -z $host ]]; then
        pf_record reachability_upstream inconclusive \
            "tpot_upstream_url does not contain a host that could be parsed"
        return 0
    fi
    _tpot_pf_record_reachability reachability_upstream "$scheme" "$host" \
        "upstream T-Pot installer" 0
    return 0
}

# Print the first apt source on this box that names a network host, following
# the mirror-list indirection Debian's own cloud images use.
#
# WHY THE INDIRECTION HAS TO BE FOLLOWED, AND WHAT SKIPPING IT COST
#   A stock Debian 13 cloud image configures no apt URL at all. Its
#   /etc/apt/sources.list.d/debian.sources says
#
#       URIs: mirror+file:///etc/apt/mirrors/debian.list
#
#   and THAT file holds the real mirror, one URL per line. This function used
#   to skip anything not literally http(s), so on that image it found nothing,
#   and reachability_apt -- a HARD check -- recorded `inconclusive`. pf_verdict
#   turns a hard inconclusive into EX_PREFLIGHT in a full run. The installer
#   therefore refused to start, with exit 11 and no FAIL row to explain it, on
#   the one distribution this release claims to support. Measured on the first
#   real install, 2026-09-05, and it is the reason that install exists.
#
#   Following the list is not a workaround for our own check. It is a strictly
#   BETTER measurement: the host it ends up testing, deb.debian.org, is the
#   host apt will really contact.
#
# WHAT IT PRINTS -- three outcomes, because there are three situations
#   a URL             something names a network host; test it
#   `local-only`      sources exist and every one is genuinely local
#                     (file:, cdrom:, copy:) and no mirror list named a host
#   nothing, exit 1   there are no readable source files at all
_tpot_pf_apt_mirror() {
    local -a files=() lines=() mirror_lists=()
    local f line t i tok path saw_local=0

    if [[ -r ${PF_APT_ROOT}/etc/apt/sources.list ]]; then
        files+=("${PF_APT_ROOT}/etc/apt/sources.list")
    fi
    for f in "${PF_APT_ROOT}"/etc/apt/sources.list.d/*.list "${PF_APT_ROOT}"/etc/apt/sources.list.d/*.sources; do
        if [[ -r $f ]]; then
            files+=("$f")
        fi
    done
    if (( ${#files[@]} == 0 )); then
        return 1
    fi

    for f in "${files[@]}"; do
        mapfile -t lines < "$f"
        for line in "${lines[@]}"; do
            t=${line%%#*}
            if [[ $t == *"URIs:"* ]]; then
                t=${t#*URIs:}
            fi
            i=1
            while tok=$(_tpot_pf_field "$i" "$t"); do
                i=$(( i + 1 ))
                case $tok in
                    http://*|https://*)
                        printf '%s\n' "$tok"
                        return 0
                        ;;
                    mirror+http://*|mirror+https://*)
                        # A REMOTE mirror list. The host serving the list is
                        # itself the network dependency, so it is the right
                        # thing to test and needs no further indirection.
                        printf '%s\n' "${tok#mirror+}"
                        return 0
                        ;;
                    mirror://*)
                        # The pre-2.0 spelling; apt fetches it over http.
                        printf 'http://%s\n' "${tok#mirror://}"
                        return 0
                        ;;
                    mirror+file:/*)
                        # Deferred rather than followed here: a later source may
                        # name a URL outright, and a URL stated in the sources
                        # beats one read out of a list.
                        saw_local=1
                        mirror_lists+=("${tok#mirror+file:}")
                        ;;
                    file:/*|cdrom:*|copy:/*)
                        saw_local=1
                        ;;
                esac
            done
        done
    done

    # Nothing named a host directly. Follow the mirror lists, in the order the
    # sources named them, and take the first URL any of them yields.
    for path in "${mirror_lists[@]}"; do
        # `mirror+file:///x` leaves `///x` here: drop the empty authority.
        path=${path#//}
        [[ $path == /* ]] || path=/$path
        path=${PF_APT_ROOT}${path}
        [[ -f $path && -r $path ]] || continue
        mapfile -t lines < "$path"
        for line in "${lines[@]}"; do
            t=${line%%#*}
            i=1
            while tok=$(_tpot_pf_field "$i" "$t"); do
                i=$(( i + 1 ))
                case $tok in
                    http://*|https://*)
                        printf '%s\n' "$tok"
                        return 0
                        ;;
                esac
            done
        done
    done

    if (( saw_local )); then
        printf 'local-only\n'
        return 0
    fi
    return 1
}

_tpot_pf_check_reachability_apt() {
    local uri scheme host
    if ! uri=$(_tpot_pf_apt_mirror); then
        pf_record reachability_apt inconclusive \
            "no apt source could be read from /etc/apt/sources.list or /etc/apt/sources.list.d, so the package mirror could not be tested"
        return 0
    fi
    if [[ $uri == local-only ]]; then
        # The reachability_pypi precedent, for the same reason spelled out
        # above that check: this is not a measurement we failed to take, it is
        # a dependency this box does not have. `inconclusive` would abort a
        # perfectly good install against a local repository, because
        # reachability_apt is HARD.
        pf_record reachability_apt not-applicable \
            "every configured apt source is local (file:, cdrom: or copy:) and no mirror list named a network host, so this run has no package mirror to reach"
        return 0
    fi
    scheme=$(_tpot_pf_url_scheme "$uri") || scheme="http"
    host=$(_tpot_pf_url_host "$uri") || host=""
    if [[ -z $host ]]; then
        pf_record reachability_apt inconclusive \
            "the first apt source (${uri}) has no host that could be parsed"
        return 0
    fi
    _tpot_pf_record_reachability reachability_apt "$scheme" "$host" "apt package mirror" 0
    return 0
}

_tpot_pf_check_reachability_galaxy() {
    _tpot_pf_record_reachability reachability_galaxy https galaxy.ansible.com \
        "Ansible collections named in requirements.yml" 0
    return 0
}

# Print MAJOR.MINOR of an ansible-core already on this box, or fail.
_tpot_pf_ansible_core_version() {
    local bin out
    for bin in ansible-playbook ansible; do
        if _tpot_pf_have "$bin"; then
            out=$("$bin" --version 2>/dev/null) || out=""
            if [[ -n $out && $out =~ core[[:space:]]+\[?([0-9]+)\.([0-9]+) ]]; then
                printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
                return 0
            fi
            if [[ -n $out && $out =~ ^ansible[[:space:]]+([0-9]+)\.([0-9]+) ]]; then
                printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
                return 0
            fi
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# pypi.org matters only when ansible-core has to be built into a virtualenv.
#
#   tpot_ansible_source: venv                  it is required -> unreachable is a failure
#   tpot_ansible_source: distro|preinstalled   it is not needed at all
#   tpot_ansible_source: auto                  it depends on what this box has.
#       If an ansible-core new enough for requirements.yml is already here,
#       auto will use it and pypi is irrelevant. If not, auto will build a
#       virtualenv -- but lib/deps.sh makes that decision, not preflight, so
#       an unreachable pypi is a WARNING that names the condition rather than
#       a refusal to install.
#
# TWO OF THOSE FOUR PATHS NEVER CONTACT pypi.org, AND THEY SAY SO.
# They used to record `ok`, which claimed a check that had not been made; this
# file's own doctrine at the top is that a check which could not be exercised
# is not a pass, and that doctrine is the reason exit code 12 exists.
# `inconclusive` was not available to them either -- reachability_pypi is a
# HARD check (_tpot_pf_is_hard), so it would abort a perfectly good
# `tpot_ansible_source: distro` run with EX_PREFLIGHT over a host nothing
# intends to contact. They record `not-applicable`, which is the true
# statement: this run has no PyPI dependency.
#
# The distro/preinstalled arm is a fact -- the configuration says so outright.
# The auto arm is an INFERENCE, and the detail says whose: preflight applies
# the same minimum-version rule lib/deps.sh applies, but lib/deps.sh takes the
# decision. If the two ever diverge, the run builds a virtualenv preflight said
# was not needed and fails at the fetch, so the detail names the version it
# found and the minimum it compared against rather than just asserting.
# ---------------------------------------------------------------------------
_tpot_pf_check_reachability_pypi() {
    local source core major minor
    source=$(_tpot_pf_cfg tpot_ansible_source "auto")
    case $source in
        distro|preinstalled)
            pf_record reachability_pypi not-applicable \
                "pypi.org was NOT contacted, and is not a dependency of this run: tpot_ansible_source is ${source}, so no virtualenv is built and nothing installs from PyPI. This is not a reachability pass"
            return 0
            ;;
        venv)
            _tpot_pf_record_reachability reachability_pypi https pypi.org \
                "ansible-core for the virtualenv" 0
            return 0
            ;;
    esac
    if core=$(_tpot_pf_ansible_core_version); then
        major=${core%%.*}
        minor=${core#*.}
        if (( major > _PF_MIN_CORE_MAJOR )) || \
           { (( major == _PF_MIN_CORE_MAJOR )) && (( minor >= _PF_MIN_CORE_MINOR )); }; then
            pf_record reachability_pypi not-applicable \
                "pypi.org was NOT contacted, and is not expected to be a dependency of this run: ansible-core ${core} is already installed and satisfies the minimum ${_PF_MIN_CORE_MAJOR}.${_PF_MIN_CORE_MINOR}, so tpot_ansible_source=auto should use it rather than build a virtualenv. lib/deps.sh takes that decision, not preflight, and this line applies the same rule to predict it. This is not a reachability pass"
            return 0
        fi
    fi
    _tpot_pf_record_reachability reachability_pypi https pypi.org \
        "ansible-core, needed only if tpot_ansible_source=auto has to build a virtualenv" 1
    return 0
}

# ---------------------------------------------------------------------------
# existing_tpot
#
# Informational, and it changes what the run will do: with T-Pot already
# present the upstream installer is skipped, and everything else -- the
# checksum, the .env credential, the verification -- still runs. That is
# deliberate, so that a re-run is a real re-run rather than a no-op that hides
# staleness.
#
# It reports the state _tpot_pf_detect_installed established, which the `ports`
# check has already used to decide which layout to judge this box against. One
# measurement, two consumers: a second opinion here could disagree with the one
# that decided whether a port conflict was a failure.
#
# --force-reinstall is NOT simply "run upstream again". Upstream's own
# check_tpot_clone compares the existing ~/tpotce against what was requested and
# exits 1 telling the user to remove it -- and because a tag checkout is a
# detached HEAD, it resolves to a commit sha that can never equal the tag name,
# so every second run against a pinned tag hard-fails there. Reinstalling means
# removing ~/tpotce first, which is the play's job, not preflight's.
# ---------------------------------------------------------------------------
_tpot_pf_check_existing_tpot() {
    local found note=""
    _tpot_pf_detect_installed
    if (( _PF_INSTALLED == 0 )); then
        pf_record existing_tpot ok "no existing T-Pot installation was found"
        return 0
    fi
    found=$_PF_INSTALLED_EVIDENCE
    if (( _PF_INSTALLED_INFERRED )); then
        note=" This was inferred from the listening sockets, not from an existing configuration file or unit, so the installation may be partial"
    fi
    if _tpot_pf_cfg_bool tpot_force_reinstall; then
        pf_record existing_tpot ok \
            "${found}; tpot_force_reinstall is set, so the existing checkout is removed and upstream's installer runs again over it. Port conflicts were judged against the post-install layout.${note}"
        return 0
    fi
    pf_record existing_tpot warn \
        "${found}; upstream's installer will be SKIPPED and only configuration and verification will run. Port conflicts were judged against the post-install layout rather than treated as conflicts. Re-run with --force-reinstall to install over it.${note}"
    return 0
}

# ---------------------------------------------------------------------------
# exposure
#
# Always recorded, always informational, never a failure. This installer
# configures no firewall -- a honeypot's whole purpose is to be reachable, and
# which of the remaining ports a site wants closed is a site decision. What
# would be indefensible is not SAYING so, so the fact is in the preflight
# table, in result.json and in the closing notice, and docs/firewall.md
# carries a worked example.
#
# TWO CAVEATS THIS RECORD MUST NOT OVERSTATE. First, "no firewall is
# configured" is OUR statement about OUR play; upstream's own playbook sets
# the firewalld public zone target to ACCEPT and SELinux to Monitor Mode on
# the RHEL family, so on those releases something else did touch the host's
# filtering. That is recorded in notes/upstream-facts.md, "What the playbook
# actually does to the box" -- a project record kept outside this repository
# and not shipped in it; the evidence behind it is upstream's own playbook,
# read from source. Second, which program answers on 22 is a property of the
# install type -- Cowrie for h, Endlessh for t, Beelzebub for l, and upstream
# does not say for s, i or m -- so neither the name of the honeypot nor what
# it does with input belongs in a line that cannot know the type it will run
# under. lib/notice.sh derives that sentence; this one stays generic.
# ---------------------------------------------------------------------------
_tpot_pf_check_exposure() {
    local mode admin dash es
    mode=$(_tpot_pf_cfg tpot_firewall_mode "none")
    admin=$(_tpot_pf_cfg tpot_admin_ssh_port "$_PF_DEF_ADMIN_SSH_PORT")
    dash=$(_tpot_pf_cfg tpot_dashboard_port "$_PF_DEF_DASHBOARD_PORT")
    es=$(_tpot_pf_cfg tpot_elasticsearch_port "$_PF_DEF_ELASTICSEARCH_PORT")
    pf_record exposure ok \
        "no firewall will be configured by this installer (tpot_firewall_mode=${mode}): ${admin}/tcp administrative ssh and ${dash}/tcp dashboard will be world-reachable, ${es}/tcp binds to loopback only, and 22/tcp stops being administrative ssh and is taken over by a honeypot -- which one depends on the install type, so this line does not name it. See docs/firewall.md"
    return 0
}

# ---------------------------------------------------------------------------
# input_complete
#
# Did this run actually get the input a real install needs?
#
# Under --preflight-only, install.sh passes `--optional tpot_web_password` to
# the merge, so the run deliberately has no dashboard credential. That is what
# would let a CI container tier check the legacy tier's nine distributions in
# seconds instead of installing on them for hours -- no such tier is built, and
# there is no CI in this tree at all, but the property is real and holds now.
# What follows from it is that the answer here is INCONCLUSIVE, never `ok`: a
# preflight that reported success without ever having the one required input
# would be green-lighting exactly what it declined to test.
# ---------------------------------------------------------------------------
_tpot_pf_check_input_complete() {
    local itype supplied=""
    local -a got=()
    if (( ${_PF_CFG_LOADED:-0} == 0 )); then
        pf_record input_complete inconclusive \
            "the merged configuration could not be read from ${PUBLIC_JSON:-an unset PUBLIC_JSON}, so stage B measured this box against built-in defaults rather than against what this run intends to do"
        return 0
    fi
    if (( ${OPT_PREFLIGHT_ONLY:-0} )); then
        pf_record input_complete inconclusive \
            "--preflight-only makes tpot_web_password optional, so this run has not established that a real install would have the one input it requires"
        return 0
    fi
    itype=$(_tpot_pf_cfg tpot_install_type "h")
    case $itype in
        s|m)
            pf_record input_complete ok \
                "install type ${itype} needs no dashboard credential"
            return 0
            ;;
    esac
    if [[ -z ${SOURCES_JSON:-} || ! -r ${SOURCES_JSON:-} ]]; then
        pf_record input_complete inconclusive \
            "install type ${itype} requires tpot_web_password, and the source map was not readable, so it could not be established that it was supplied"
        return 0
    fi
    mapfile -t got < <(python3 -c '
import sys, json
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception:
    sys.exit(1)
if isinstance(doc, dict) and sys.argv[2] in doc:
    entry = doc[sys.argv[2]]
    src = entry.get("source") if isinstance(entry, dict) else None
    sys.stdout.write(str(src or "supplied") + "\n")
' "${SOURCES_JSON}" tpot_web_password 2>/dev/null)
    supplied=${got[0]:-}
    if [[ -z $supplied ]]; then
        pf_record input_complete fail \
            "install type ${itype} requires tpot_web_password and it was not supplied by any channel"
        return 0
    fi
    pf_record input_complete ok \
        "every required input is present; tpot_web_password came from ${supplied}"
    return 0
}

# ---------------------------------------------------------------------------
# secret_length
#
# lib/log.sh redacts registered values of four characters or more from the
# transcript, and its tripwire scans for values of eight or more. Below those
# lengths a credential would survive into a file this run writes to disk.
#
# This check reads the LENGTHS of the registered values and never a value:
# there is no branch here that can print one, which is the only acceptable way
# to ask this question at all.
# ---------------------------------------------------------------------------
_tpot_pf_check_secret_length() {
    local s n_total=0 n_short=0 n_weak=0
    if ! declare -p _TPOT_SECRETS >/dev/null 2>&1; then
        pf_record secret_length inconclusive \
            "lib/log.sh has registered nothing for redaction, so it could not be established that supplied credentials are long enough to be redacted from the transcript"
        return 0
    fi
    if (( ${#_TPOT_SECRETS[@]} > 0 )); then
        for s in "${_TPOT_SECRETS[@]}"; do
            n_total=$(( n_total + 1 ))
            if (( ${#s} < 4 )); then
                n_short=$(( n_short + 1 ))
            elif (( ${#s} < 8 )); then
                n_weak=$(( n_weak + 1 ))
            fi
        done
    fi
    if (( n_total == 0 )); then
        pf_record secret_length ok "no secret values were supplied to this run"
        return 0
    fi
    if (( n_short > 0 )); then
        pf_record secret_length warn \
            "${n_short} of ${n_total} supplied secret values are shorter than 4 characters and will NOT be redacted from the transcript; a value that short is not usefully secret in the first place"
        return 0
    fi
    if (( n_weak > 0 )); then
        pf_record secret_length warn \
            "${n_weak} of ${n_total} supplied secret values are shorter than 8 characters: they are redacted from the transcript, but the leak tripwire does not scan for values that short"
        return 0
    fi
    pf_record secret_length ok \
        "${n_total} supplied secret value(s), all long enough to be redacted and to be covered by the leak tripwire"
    return 0
}

# ---------------------------------------------------------------------------
# $RUNDIR/host.json
#
# What preflight MEASURED, as a document, so that lib/result.sh can build
# result.json from files bash wrote and never from the play's own opinion of
# the box. It exists even when the play never ran, which is the point.
#
# max_map_count here is the value as it was BEFORE os_prep raised it. Whether
# it is effective afterwards is a verification question, not this one.
#
# `supported` is TRUE ONLY FOR THE SUPPORTED TIER (D-07). A legacy row -- one
# of the older releases reachable by pinning an older upstream ref -- reports
# `supported: false` with `os_tier: legacy`, because "in our matrix" and
# "tested against the ref this run pins" stopped being the same statement when
# the matrix gained a second tier. Read os_tier, not the boolean, when the
# distinction matters.
#
# `port_layout` says which of the two port layouts the ports check judged this
# box against: pre_install, post_install, post_install_incomplete, or unknown.
#
# The JSON is serialised by python3 from a typed TSV on stdin. No JSON string
# is ever built by string concatenation in bash: a hostname with a quote in it
# would otherwise produce a document that parses as something else.
# ---------------------------------------------------------------------------
_tpot_pf_write_host_json() {
    local dest hostname
    if [[ -z ${RUNDIR:-} || ! -d ${RUNDIR:-} ]]; then
        return 0
    fi
    if ! _tpot_pf_have python3; then
        return 1
    fi
    dest="${RUNDIR}/host.json"
    hostname=$(hostname 2>/dev/null) || hostname=""
    if [[ -z $hostname && -r /proc/sys/kernel/hostname ]]; then
        hostname=$(cat /proc/sys/kernel/hostname 2>/dev/null) || hostname=""
    fi
    if ! (
        umask 077
        {
            printf '%s\t%s\t%s\n' os_id s "$_PF_OS_ID"
            printf '%s\t%s\t%s\n' os_version_id s "$_PF_OS_VERSION_ID"
            printf '%s\t%s\t%s\n' os_major s "$_PF_OS_MAJOR"
            printf '%s\t%s\t%s\n' os_pretty s "$_PF_OS_PRETTY"
            printf '%s\t%s\t%s\n' supported b "$_PF_OS_SUPPORTED"
            printf '%s\t%s\t%s\n' os_tier s "$_PF_OS_TIER"
            printf '%s\t%s\t%s\n' forced b "$_PF_OS_FORCED"
            printf '%s\t%s\t%s\n' arch s "$_PF_ARCH"
            printf '%s\t%s\t%s\n' hostname s "$hostname"
            printf '%s\t%s\t%s\n' memory_mb i "$_PF_MEMORY_MB"
            printf '%s\t%s\t%s\n' cpus i "$_PF_CPUS"
            printf '%s\t%s\t%s\n' disk_free_gb.home i "$_PF_DISK_HOME_GB"
            printf '%s\t%s\t%s\n' disk_free_gb.docker i "$_PF_DISK_DOCKER_GB"
            printf '%s\t%s\t%s\n' max_map_count i "$_PF_MAX_MAP_COUNT"
            printf '%s\t%s\t%s\n' runtime_fstype s "$_PF_RUNTIME_FSTYPE"
            printf '%s\t%s\t%s\n' port_layout s "$_PF_PORT_LAYOUT"
        } | python3 -c '
import sys, json
doc = {}
for line in sys.stdin.read().splitlines():
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) != 3:
        continue
    key, kind, raw = parts
    if kind == "i":
        try:
            val = int(raw)
        except ValueError:
            val = None
    elif kind == "b":
        val = (raw == "true")
    else:
        val = raw if raw != "" else None
    if "." in key:
        head, tail = key.split(".", 1)
        doc.setdefault(head, {})[tail] = val
    else:
        doc[key] = val
json.dump(doc, sys.stdout, indent=1, sort_keys=False)
sys.stdout.write("\n")
' > "$dest"
    ); then
        return 1
    fi
    chmod 0600 "$dest" 2>/dev/null || true
    return 0
}

# ---------------------------------------------------------------------------
# pf_stage_b
#   Load the merged PUBLIC document, run the stage B checks in the documented
#   order, write host.json. Returns 1 when any check produced `fail`.
#
#   $PUBLIC_JSON and not $MERGED_JSON, deliberately: the public document is
#   the merged one with every secret-typed key removed, so preflight cannot
#   print a credential even by accident. It never has one to print.
# ---------------------------------------------------------------------------
pf_stage_b() {
    local rec status first i
    local -a keys=()
    # Where stage B's own records begin. Each stage answers for itself: a
    # stage A failure is stage A's to report, and pf_verdict is what accounts
    # for the run as a whole.
    first=${#_PF_RECORDS[@]}
    _PF_CFG=()
    _PF_CFG_LOADED=0
    # Re-measure the installed state on every stage B run: a test may call
    # stage B twice against two different fixtures, and a cached answer from
    # the first would silently decide the second.
    _PF_INSTALLED=0
    _PF_INSTALLED_DONE=0
    _PF_INSTALLED_INFERRED=0
    _PF_INSTALLED_EVIDENCE=""
    _PF_PORT_LAYOUT="unknown"
    mapfile -t keys < <(_tpot_pf_config_keys)
    if _tpot_pf_load_config "${PUBLIC_JSON:-}" "${keys[@]}"; then
        _PF_CFG_LOADED=1
    fi
    if _tpot_pf_cfg_bool tpot_force_unsupported_os; then
        _PF_OS_FORCED="true"
    fi
    _tpot_pf_check_memory
    _tpot_pf_check_cpus
    _tpot_pf_check_disk_home
    _tpot_pf_check_disk_docker
    _tpot_pf_check_max_map_count
    _tpot_pf_check_ports
    _tpot_pf_check_upstream_gate
    _tpot_pf_check_reachability_upstream
    _tpot_pf_check_reachability_apt
    _tpot_pf_check_reachability_galaxy
    _tpot_pf_check_reachability_pypi
    _tpot_pf_check_existing_tpot
    _tpot_pf_check_exposure
    _tpot_pf_check_input_complete
    _tpot_pf_check_secret_length
    _tpot_pf_write_host_json || true
    for (( i = first; i < ${#_PF_RECORDS[@]}; i++ )); do
        rec=${_PF_RECORDS[$i]}
        status=$(_tpot_pf_rec_status "$rec")
        if [[ $status == "fail" ]]; then
            return 1
        fi
    done
    return 0
}
