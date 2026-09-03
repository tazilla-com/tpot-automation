# lib/deps.sh -- dependency bootstrap: apt prerequisites, ansible-core, collections.
#
# WHY THIS FILE EXISTS
#   Step 7 of install.sh's order of operations is the first step that installs
#   software, and it is the step where the installer this project replaces did
#   its worst damage. It ran:
#
#       rm -rf /root/.ansible/collections/ansible_collections/community
#       ansible-galaxy collection install community.general --force
#
#   -- destroying whatever the operator had, replacing it with an unpinned
#   version, and printing "Proceeding with native modules only" when that
#   failed. There is no native fallback: the play would then die much later at
#   a task that needs community.general, blaming the wrong thing.
#
#   So this file obeys four rules, and every one of them is the negative of
#   something that actually happened:
#
#     1. THE USER'S OWN ~/.ansible IS NEVER WRITTEN, MOVED OR DELETED.
#        Collections go to a path this project owns, named once in ansible.cfg.
#     2. --force is never passed to ansible-galaxy. An acceptable version that
#        is already installed is left exactly as it is.
#     3. requirements.yml pins a RANGE and this file reads that range from
#        requirements.yml rather than restating it.
#     4. A failed dependency step is EX_DEPS with the real error from the tool
#        that failed. There is no "continuing anyway" branch anywhere below.
#
# WHAT IT MAY AND MAY NOT DO
#   It runs after preflight, so it may change the box: that is its job. It may
#   not read a credential -- it reads $PUBLIC_JSON, the merged document with
#   every secret-typed key removed -- and it puts no value on any command line
#   except package names, paths and version ranges.
#
# THE PUBLIC SURFACE
#   deps_bootstrap        resolve everything; log_die EX_DEPS on failure
#   deps_ansible_bin      print the absolute path of the ansible-playbook to run
#   deps_ansible_home     print the ANSIBLE_HOME this project uses for its children
#   deps_report           write $RUNDIR/deps.json
#
# shellcheck shell=bash

if [[ -n ${_TPOT_DEPS_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_DEPS_SH_LOADED=1

# ---------------------------------------------------------------------------
# Constants.
#
# _TPOT_DEPS_COLLECTIONS_PATH must agree with `collections_path` in
# ansible.cfg. It is written in both places because ansible.cfg is read by
# ansible-core and cannot be read back reliably across the core versions in
# the support matrix; tests/check-variable-surface.sh is where the two are
# compared. Changing one without the other installs collections somewhere the
# play will not look, which fails at the first community.general task with a
# message about a missing module rather than a missing collection.
# ---------------------------------------------------------------------------
readonly _TPOT_DEPS_COLLECTIONS_PATH=/usr/local/share/tpot-automation/collections
readonly _TPOT_DEPS_VENV=/opt/tpot-automation/venv

# The oldest ansible-core that satisfies requirements.yml's range for
# community.general and the modules this project uses from it.
readonly _TPOT_DEPS_MIN_CORE=2.15

# State, filled in by deps_bootstrap and serialised by deps_report.
_TPOT_DEPS_SOURCE=''
_TPOT_DEPS_CORE_VERSION=''
_TPOT_DEPS_PLAYBOOK_BIN=''
_TPOT_DEPS_GALAXY_BIN=''
_TPOT_DEPS_CG_VERSION=''
_TPOT_DEPS_APT_UPDATED=0

# ---------------------------------------------------------------------------
# ANSIBLE_HOME.
#
# ansible-core >= 2.13 reads this and puts its per-user state -- the galaxy
# response cache above all -- under it instead of under ~/.ansible. Older
# cores ignore it, which is harmless: with `-p` on every galaxy call and no
# --force anywhere, the worst an old core does is write a cache file.
#
# It is set as a COMMAND PREFIX on the two children that care, never with
# `export`. install.sh exports six names and this is deliberately not one of
# them: an exported value would be inherited by every child of the run,
# including lib/config.py, and the run's own internals have no business in a
# child's environment.
# ---------------------------------------------------------------------------
deps_ansible_home() {
    printf '%s\n' "${TPOT_STATE_DIR:-/var/lib/tpot-automation}/ansible-home"
    return 0
}

# ---------------------------------------------------------------------------
# Small helpers.
# ---------------------------------------------------------------------------
_tpot_deps_have() {
    command -v -- "${1:-}" >/dev/null 2>&1
}

_tpot_deps_say() {
    if declare -F log_info >/dev/null 2>&1; then
        log_info "$@"
        return 0
    fi
    local fmt=${1-}
    if (( $# > 1 )); then shift; else shift $#; fi
    local msg
    # shellcheck disable=SC2059  # printf-style API, as log_info's
    printf -v msg -- "$fmt" "$@"
    printf '%s\n' "$msg" >&2
    return 0
}

_tpot_deps_warn() {
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$@"
        return 0
    fi
    local fmt=${1-}
    if (( $# > 1 )); then shift; else shift $#; fi
    local msg
    # shellcheck disable=SC2059
    printf -v msg -- "$fmt" "$@"
    printf 'WARN: %s\n' "$msg" >&2
    return 0
}

# _tpot_deps_fail FMT [ARGS...]
#   Every failure in this file goes through here, so the exit code is written
#   down once. log_die keeps the EXIT trap armed, so result.json is still
#   written with outcome deps_failed.
_tpot_deps_fail() {
    if declare -F log_die >/dev/null 2>&1; then
        log_die "${EX_DEPS:-13}" "$@"
    fi
    local fmt=${1-}
    if (( $# > 1 )); then shift; else shift $#; fi
    # shellcheck disable=SC2059
    printf "deps: ${fmt}\n" "$@" >&2
    exit "${EX_DEPS:-13}"
}

# ---------------------------------------------------------------------------
# _tpot_deps_vercmp A B
#   Compare two dotted version strings numerically, component by component.
#   Prints nothing. Exit status: 0 when A >= B, 1 when A < B, 2 when either
#   is unparseable -- and an unparseable version is never treated as good
#   enough, because "we could not tell" is not "it passed".
# ---------------------------------------------------------------------------
_tpot_deps_vercmp() {
    local a=${1:-} b=${2:-}
    local -a pa=() pb=()
    local i n x y

    a=${a%%[!0-9.]*}
    b=${b%%[!0-9.]*}
    [[ -n $a && -n $b ]] || return 2

    local IFS_SAVE=${IFS-}
    IFS='.'
    # shellcheck disable=SC2206  # deliberate split on '.' with IFS set locally
    pa=($a)
    # shellcheck disable=SC2206
    pb=($b)
    IFS=$IFS_SAVE

    n=${#pa[@]}
    (( ${#pb[@]} > n )) && n=${#pb[@]}
    for (( i = 0; i < n; i++ )); do
        x=${pa[i]:-0}
        y=${pb[i]:-0}
        [[ $x =~ ^[0-9]+$ ]] || return 2
        [[ $y =~ ^[0-9]+$ ]] || return 2
        (( 10#$x > 10#$y )) && return 0
        (( 10#$x < 10#$y )) && return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_deps_core_version BIN
#   Print the ansible-core version an ansible-playbook binary reports.
#
#   Two spellings are handled. Since ansible-core 2.10 the first line is
#       ansible-playbook [core 2.14.16]
#   and before that it was
#       ansible-playbook 2.9.27
#   The older spelling matters: Debian 11 and Ubuntu 20.04 ship it, and
#   telling "too old" apart from "unreadable" is what decides between the
#   distro path and the venv path.
# ---------------------------------------------------------------------------
_tpot_deps_core_version() {
    local bin=${1:-} output='' rest='' line='' value=''
    [[ -n $bin ]] || return 1

    # stderr is captured with stdout, not discarded, and EVERY line is looked
    # at rather than just the first. Both of those are the result of watching
    # this go wrong: ansible-core refuses to start at all when the locale
    # encoding is not UTF-8, printing one line on stderr and exiting 1, and a
    # probe that threw that line away reported "no usable ansible-core" about
    # a perfectly good 2.21 -- sending the run off to build a virtual
    # environment it did not need, for a reason nothing anywhere stated.
    #
    # The whole output is captured and split with parameter expansion rather
    # than piped into `head`: install.sh sets `pipefail`, and `head -n 1`
    # closes the pipe, so the writer takes SIGPIPE and the pipeline reports
    # 141 for a command that did exactly what was asked.
    output=$("$bin" --version 2>&1) || output=''
    [[ -n $output ]] || return 1

    rest=$output
    while [[ -n $rest ]]; do
        line=${rest%%$'\n'*}
        if [[ $rest == *$'\n'* ]]; then
            rest=${rest#*$'\n'}
        else
            rest=''
        fi
        if [[ $line == *"[core "* ]]; then
            value=${line#*"[core "}
            value=${value%%]*}
            value=${value%% *}
            if [[ $value =~ ^[0-9]+\.[0-9]+ ]]; then
                printf '%s\n' "$value"
                return 0
            fi
        fi
        if [[ $line == ansible-playbook[[:space:]]* || $line == ansible[[:space:]]* ]]; then
            value=${line##* }
            if [[ $value =~ ^[0-9]+\.[0-9]+ ]]; then
                printf '%s\n' "$value"
                return 0
            fi
        fi
    done

    # Nothing in the output looked like a version. Say what it did print --
    # that line is the diagnosis, and hiding it is how a locale error became a
    # message about the wrong subject.
    _tpot_deps_warn 'deps: %s would not report a version. It said: %s' \
        "$bin" "${output%%$'\n'*}"
    return 1
}

# ---------------------------------------------------------------------------
# _tpot_deps_required_cg_range
#   Print the community.general version range, read from requirements.yml.
#
#   requirements.yml is the single writer of that fact and this reads it back
#   rather than repeating it. The parse is a line match, not a YAML parse:
#   this runs before anything has established that PyYAML is importable, and
#   the file is one this project writes and lints.
# ---------------------------------------------------------------------------
_tpot_deps_required_cg_range() {
    local file="${REPO_DIR:-.}/requirements.yml" value=''
    local -a lines=()
    [[ -r $file ]] || return 1
    mapfile -t lines < "$file"
    local line
    for line in ${lines[@]+"${lines[@]}"}; do
        [[ $line =~ ^[[:space:]]*version:[[:space:]]*(.*)$ ]] || continue
        value=${BASH_REMATCH[1]}
        value=${value%%#*}
        value=${value//\"/}
        value=${value//\'/}
        value=${value//[[:space:]]/}
        [[ -n $value ]] && break
    done
    [[ -n $value ]] || return 1
    printf '%s\n' "$value"
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_deps_range_ok VERSION RANGE
#   True when VERSION satisfies RANGE, where RANGE is the comma-separated
#   comparator list requirements.yml uses (">=8.0.0,<12.0.0").
#
#   Only the four comparators this project's own file can contain are
#   implemented, and an unrecognised one returns "does not satisfy" rather
#   than "satisfies": a range we cannot read must not silently pass.
# ---------------------------------------------------------------------------
_tpot_deps_range_ok() {
    local version=${1:-} range=${2:-} clause op want rc
    local -a clauses=()
    [[ -n $version && -n $range ]] || return 1

    local IFS_SAVE=${IFS-}
    IFS=','
    # shellcheck disable=SC2206  # deliberate split on ',' with IFS set locally
    clauses=($range)
    IFS=$IFS_SAVE

    for clause in ${clauses[@]+"${clauses[@]}"}; do
        clause=${clause//[[:space:]]/}
        [[ -n $clause ]] || continue
        case $clause in
            '>='*) op='>='; want=${clause#>=} ;;
            '<='*) op='<='; want=${clause#<=} ;;
            '>'*)  op='>';  want=${clause#>}  ;;
            '<'*)  op='<';  want=${clause#<}  ;;
            '=='*) op='=='; want=${clause#==} ;;
            *)     return 1 ;;
        esac
        rc=0
        _tpot_deps_vercmp "$version" "$want" || rc=$?
        case $op in
            '>=') (( rc == 0 )) || return 1 ;;
            '>')  (( rc == 0 )) || return 1
                  if [[ $version == "$want" ]]; then return 1; fi ;;
            '<')  (( rc == 1 )) || return 1 ;;
            '<=') if (( rc == 2 )); then return 1; fi
                  if (( rc == 0 )) && [[ $version != "$want" ]]; then return 1; fi ;;
            '==') [[ $version == "$want" ]] || return 1 ;;
        esac
    done
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_deps_cfg KEY
#   One value out of the merged PUBLIC document. Empty when it is absent or
#   the document cannot be read; every caller has a documented default, and
#   this file never reads $MERGED_JSON, so it can never hold a credential.
# ---------------------------------------------------------------------------
_tpot_deps_cfg() {
    local key=${1:-} out=''
    local schema="${REPO_DIR:-.}/lib/varschema.json"
    local doc=${PUBLIC_JSON:-}
    [[ -n $key && -n $doc && -r $doc && -r $schema ]] || return 0
    _tpot_deps_have python3 || return 0
    out=$(python3 "${REPO_DIR:-.}/lib/config.py" get --schema "$schema" --from "$doc" "$key" 2>/dev/null) || out=''
    printf '%s\n' "$out"
    return 0
}

# ---------------------------------------------------------------------------
# apt.
#
# Every apt call is non-interactive and quiet enough to read in a transcript.
# DEBIAN_FRONTEND is one of the six names install.sh exports, so it is already
# in the environment here and is not set again per command.
# ---------------------------------------------------------------------------
_tpot_deps_apt_update() {
    (( _TPOT_DEPS_APT_UPDATED )) && return 0
    _tpot_deps_have apt-get || return 1
    _tpot_deps_say 'deps: refreshing the package index'
    apt-get update -qq || return 1
    _TPOT_DEPS_APT_UPDATED=1
    return 0
}

# _tpot_deps_apt_install PKG...
#   Install packages, returning non-zero on failure. The caller decides
#   whether that is fatal, because "python3-venv is missing" is fatal on the
#   venv path and irrelevant on the distro path.
_tpot_deps_apt_install() {
    (( $# > 0 )) || return 0
    if (( ${OPT_INSTALL_DEPS:-1} == 0 )); then
        _tpot_deps_warn 'deps: --no-install-deps was given, so %s was not installed' "$1"
        return 1
    fi
    _tpot_deps_have apt-get || return 1
    _tpot_deps_apt_update || return 1
    _tpot_deps_say 'deps: installing %s' "$*"
    apt-get install -y --no-install-recommends -- "$@" || return 1
    return 0
}

# ---------------------------------------------------------------------------
# The three ways ansible-core can arrive.
#
# Each one sets _TPOT_DEPS_PLAYBOOK_BIN, _TPOT_DEPS_GALAXY_BIN,
# _TPOT_DEPS_CORE_VERSION and _TPOT_DEPS_SOURCE, or returns non-zero having
# changed nothing. `auto` tries them in the order below; the three explicit
# values of tpot_ansible_source pick exactly one and fail if it is not usable,
# because a caller that named a source wants that source and not a surprise.
# ---------------------------------------------------------------------------

# preinstalled: whatever is already on PATH, if it is new enough.
_tpot_deps_try_preinstalled() {
    local bin galaxy version rc=0
    bin=$(command -v ansible-playbook 2>/dev/null) || return 1
    version=$(_tpot_deps_core_version "$bin") || return 1
    _tpot_deps_vercmp "$version" "$_TPOT_DEPS_MIN_CORE" || rc=$?
    (( rc == 0 )) || return 1
    galaxy=$(command -v ansible-galaxy 2>/dev/null) || return 1
    _TPOT_DEPS_PLAYBOOK_BIN=$bin
    _TPOT_DEPS_GALAXY_BIN=$galaxy
    _TPOT_DEPS_CORE_VERSION=$version
    _TPOT_DEPS_SOURCE=preinstalled
    return 0
}

# distro: the packaged ansible-core. `ansible-core` is the modern package
# name; `ansible` is what the older supported releases call it, and it is
# tried second so that a box carrying both does not get the batteries-included
# one by accident.
_tpot_deps_try_distro() {
    local bin galaxy version rc=0
    if ! _tpot_deps_have ansible-playbook; then
        _tpot_deps_apt_install ansible-core || _tpot_deps_apt_install ansible || return 1
    fi
    bin=$(command -v ansible-playbook 2>/dev/null) || return 1
    galaxy=$(command -v ansible-galaxy 2>/dev/null) || return 1
    version=$(_tpot_deps_core_version "$bin") || return 1
    _tpot_deps_vercmp "$version" "$_TPOT_DEPS_MIN_CORE" || rc=$?
    (( rc == 0 )) || return 1
    _TPOT_DEPS_PLAYBOOK_BIN=$bin
    _TPOT_DEPS_GALAXY_BIN=$galaxy
    _TPOT_DEPS_CORE_VERSION=$version
    _TPOT_DEPS_SOURCE=distro
    return 0
}

# venv: a virtual environment this project owns, with a pinned core spec.
# This is the path Debian 11 and Ubuntu 20.04 take: their packaged core is far
# older than community.general 8 supports, and installing the collection
# against it produces failures that look like bugs in this project.
_tpot_deps_try_venv() {
    local spec bin galaxy version rc=0
    spec=$(_tpot_deps_cfg tpot_ansible_core_spec)
    [[ -n $spec ]] || spec='>=2.15,<2.19'

    if [[ ! -x "$_TPOT_DEPS_VENV/bin/ansible-playbook" ]]; then
        if (( ${OPT_INSTALL_DEPS:-1} == 0 )); then
            return 1
        fi
        if ! python3 -c 'import venv' >/dev/null 2>&1; then
            _tpot_deps_apt_install python3-venv || return 1
        fi
        _tpot_deps_say 'deps: building a virtual environment at %s' "$_TPOT_DEPS_VENV"
        mkdir -p -- "$(dirname -- "$_TPOT_DEPS_VENV")" || return 1
        python3 -m venv -- "$_TPOT_DEPS_VENV" || return 1
        "$_TPOT_DEPS_VENV/bin/python" -m pip install --upgrade --quiet pip || return 1
        # The spec is a version range on a package name, not a value: nothing
        # secret ever reaches a command line here.
        "$_TPOT_DEPS_VENV/bin/python" -m pip install --quiet "ansible-core${spec}" || return 1
    fi

    bin="$_TPOT_DEPS_VENV/bin/ansible-playbook"
    galaxy="$_TPOT_DEPS_VENV/bin/ansible-galaxy"
    [[ -x $bin && -x $galaxy ]] || return 1
    version=$(_tpot_deps_core_version "$bin") || return 1
    _tpot_deps_vercmp "$version" "$_TPOT_DEPS_MIN_CORE" || rc=$?
    (( rc == 0 )) || return 1
    _TPOT_DEPS_PLAYBOOK_BIN=$bin
    _TPOT_DEPS_GALAXY_BIN=$galaxy
    _TPOT_DEPS_CORE_VERSION=$version
    _TPOT_DEPS_SOURCE=venv
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_deps_resolve_core
#   Apply tpot_ansible_source. Fails (EX_DEPS) with a message naming what was
#   asked for, what was found, and the flag that changes it.
# ---------------------------------------------------------------------------
_tpot_deps_resolve_core() {
    local source msg
    source=$(_tpot_deps_cfg tpot_ansible_source)
    [[ -n $source ]] || source=auto

    case $source in
        preinstalled)
            _tpot_deps_try_preinstalled && return 0
            msg='tpot_ansible_source is "preinstalled" but no ansible-playbook of at least '
            msg+='core %s is on PATH. Install one, or use --ansible-source auto.'
            _tpot_deps_fail "$msg" "$_TPOT_DEPS_MIN_CORE"
            ;;
        distro)
            _tpot_deps_try_distro && return 0
            msg='tpot_ansible_source is "distro" but the packaged ansible-core could not be '
            msg+='installed, or is older than %s. Use --ansible-source venv on this release.'
            _tpot_deps_fail "$msg" "$_TPOT_DEPS_MIN_CORE"
            ;;
        venv)
            _tpot_deps_try_venv && return 0
            msg='tpot_ansible_source is "venv" but the virtual environment at %s could not be '
            msg+='built. The error from python3 -m venv or pip is above.'
            _tpot_deps_fail "$msg" "$_TPOT_DEPS_VENV"
            ;;
        auto)
            _tpot_deps_try_preinstalled && return 0
            _tpot_deps_try_distro && return 0
            _tpot_deps_try_venv && return 0
            msg='no usable ansible-core: nothing on PATH is at least %s, the packaged one '
            msg+='could not be installed or is too old, and the virtual environment at %s '
            msg+='could not be built. The errors from apt, python3 -m venv and pip are above.'
            _tpot_deps_fail "$msg" "$_TPOT_DEPS_MIN_CORE" "$_TPOT_DEPS_VENV"
            ;;
        *)
            _tpot_deps_fail \
                'tpot_ansible_source "%s" is not one of auto, distro, venv, preinstalled.' "$source"
            ;;
    esac
}

# ---------------------------------------------------------------------------
# _tpot_deps_cg_installed_version
#   Print the community.general version already present at this project's own
#   collections path, or nothing.
#
#   MANIFEST.json is read directly rather than asking `ansible-galaxy
#   collection list`, whose output format has changed between the core
#   versions in the support matrix and whose exit status is 0 when it finds
#   nothing.
# ---------------------------------------------------------------------------
_tpot_deps_cg_installed_version() {
    local manifest="$_TPOT_DEPS_COLLECTIONS_PATH/ansible_collections/community/general/MANIFEST.json"
    local out=''
    [[ -r $manifest ]] || return 1
    _tpot_deps_have python3 || return 1
    out=$(python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        doc = json.load(fh)
except Exception:
    raise SystemExit(1)
info = doc.get("collection_info") or {}
version = info.get("version")
if not version:
    raise SystemExit(1)
sys.stdout.write(str(version))
' "$manifest" 2>/dev/null) || return 1
    [[ -n $out ]] || return 1
    printf '%s\n' "$out"
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_deps_collections
#   Make requirements.yml true at this project's own collections path.
#
#   An acceptable version already there is left alone -- that is the whole
#   point of reading the range rather than reinstalling unconditionally. When
#   an install is needed it is `-r requirements.yml -p <our path>`, with NO
#   --force, and a failure is fatal.
# ---------------------------------------------------------------------------
_tpot_deps_collections() {
    local range have ansible_home msg
    range=$(_tpot_deps_required_cg_range) || range=''
    if [[ -z $range ]]; then
        msg='requirements.yml carries no version range for community.general, so there is '
        msg+='nothing to check an installed collection against. This is a defect in this checkout.'
        _tpot_deps_fail "$msg"
    fi

    if have=$(_tpot_deps_cg_installed_version); then
        if _tpot_deps_range_ok "$have" "$range"; then
            _TPOT_DEPS_CG_VERSION=$have
            _tpot_deps_say 'deps: community.general %s at %s satisfies %s' \
                "$have" "$_TPOT_DEPS_COLLECTIONS_PATH" "$range"
            return 0
        fi
        _tpot_deps_say 'deps: community.general %s at %s does not satisfy %s; installing beside it' \
            "$have" "$_TPOT_DEPS_COLLECTIONS_PATH" "$range"
    fi

    if (( ${OPT_INSTALL_DEPS:-1} == 0 )); then
        msg='--no-install-deps was given and community.general satisfying %s is not installed '
        msg+='at %s. There is no fallback to native modules: os_prep would fail at '
        msg+='community.general.timezone. Install it, or drop --no-install-deps.'
        _tpot_deps_fail "$msg" "$range" "$_TPOT_DEPS_COLLECTIONS_PATH"
    fi

    mkdir -p -- "$_TPOT_DEPS_COLLECTIONS_PATH" || _tpot_deps_fail \
        'cannot create %s' "$_TPOT_DEPS_COLLECTIONS_PATH"
    chmod 0755 -- "$_TPOT_DEPS_COLLECTIONS_PATH" 2>/dev/null || true

    ansible_home=$(deps_ansible_home)
    mkdir -p -- "$ansible_home" 2>/dev/null || true
    chmod 0700 -- "$ansible_home" 2>/dev/null || true

    _tpot_deps_say 'deps: installing collections from requirements.yml into %s' \
        "$_TPOT_DEPS_COLLECTIONS_PATH"

    # ANSIBLE_HOME as a command prefix, never exported: it keeps galaxy's
    # response cache out of the invoking user's ~/.ansible. No --force, so an
    # unrelated collection at that path is never overwritten.
    if ! ANSIBLE_HOME="$ansible_home" "$_TPOT_DEPS_GALAXY_BIN" collection install \
            -r "${REPO_DIR:-.}/requirements.yml" \
            -p "$_TPOT_DEPS_COLLECTIONS_PATH"; then
        msg='ansible-galaxy could not install the collections in requirements.yml into %s. '
        msg+='Its own error is above. There is no fallback to native modules, because os_prep '
        msg+='needs community.general.timezone and would fail much later with a message '
        msg+='pointing at the wrong thing.'
        _tpot_deps_fail "$msg" "$_TPOT_DEPS_COLLECTIONS_PATH"
    fi

    if have=$(_tpot_deps_cg_installed_version); then
        if ! _tpot_deps_range_ok "$have" "$range"; then
            msg='ansible-galaxy reported success but community.general at %s is version %s, '
            msg+='which does not satisfy %s.'
            _tpot_deps_fail "$msg" "$_TPOT_DEPS_COLLECTIONS_PATH" "$have" "$range"
        fi
        _TPOT_DEPS_CG_VERSION=$have
        return 0
    fi
    _tpot_deps_fail \
        'ansible-galaxy reported success but community.general is not present at %s.' \
        "$_TPOT_DEPS_COLLECTIONS_PATH"
}

# ---------------------------------------------------------------------------
# deps_bootstrap
#   Step 7. Resolve ansible-core, then the collections, then report.
#
#   With --no-install-deps it installs nothing but still MEASURES, and still
#   fails when what is present is unusable: the flag means "do not change my
#   box", not "pretend the requirements are met".
# ---------------------------------------------------------------------------
deps_bootstrap() {
    if (( ${OPT_INSTALL_DEPS:-1} == 0 )); then
        _tpot_deps_say 'deps: --no-install-deps -- checking what is present, installing nothing'
    fi
    _tpot_deps_resolve_core
    _tpot_deps_say 'deps: ansible-core %s (%s) at %s' \
        "$_TPOT_DEPS_CORE_VERSION" "$_TPOT_DEPS_SOURCE" "$_TPOT_DEPS_PLAYBOOK_BIN"
    _tpot_deps_collections
    deps_report || _tpot_deps_warn 'deps: %s/deps.json could not be written' "${RUNDIR:-}"
    return 0
}

# ---------------------------------------------------------------------------
# deps_ansible_bin
#   The absolute path of the ansible-playbook to run. Empty and non-zero
#   before deps_bootstrap has resolved one.
# ---------------------------------------------------------------------------
deps_ansible_bin() {
    [[ -n $_TPOT_DEPS_PLAYBOOK_BIN ]] || return 1
    printf '%s\n' "$_TPOT_DEPS_PLAYBOOK_BIN"
    return 0
}

# ---------------------------------------------------------------------------
# deps_report
#   Write $RUNDIR/deps.json, mode 0600. This file is the ONLY writer of
#   result.json's `ansible` object: the play must not report its own version,
#   because a run that never reached the play still has to say what it
#   resolved.
#
#   Serialised by python3, like every other JSON in this project. No JSON
#   string is built by concatenation in bash anywhere in this tree.
# ---------------------------------------------------------------------------
deps_report() {
    local dest
    [[ -n ${RUNDIR:-} && -d ${RUNDIR:-} ]] || return 0
    dest="$RUNDIR/deps.json"
    _tpot_deps_have python3 || return 1

    ( umask 077
      python3 -c '
import json, sys
source, version, binary, cg, dest = sys.argv[1:6]
document = {
    "schema": "tpot-automation/deps@1",
    "source": source or None,
    "core_version": version or None,
    "ansible_playbook": binary or None,
    "collections": {},
}
if cg:
    document["collections"]["community.general"] = cg
with open(dest, "w", encoding="utf-8") as handle:
    json.dump(document, handle, ensure_ascii=False, indent=2, sort_keys=False)
    handle.write("\n")
    handle.flush()
    import os
    os.fsync(handle.fileno())
' "$_TPOT_DEPS_SOURCE" "$_TPOT_DEPS_CORE_VERSION" "$_TPOT_DEPS_PLAYBOOK_BIN" \
  "$_TPOT_DEPS_CG_VERSION" "$dest" ) || return 1

    chmod 0600 -- "$dest" 2>/dev/null || true
    return 0
}
