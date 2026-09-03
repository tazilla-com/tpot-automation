# lib/args.sh -- the command-line parser, --help and --version.
#
# WHY THIS FILE EXISTS
#   The automation contract is the product, and the contract starts at argv.
#   Everything a caller can say to this installer is enumerated here, once, in
#   one shape: long flags, no positional arguments, and no flag anywhere that
#   takes a password as its VALUE. That last rule is the reason this file is
#   written as a parser rather than a getopts call -- the shape of the input
#   surface is a security property, not a convenience.
#
# WHAT IT MAY AND MAY NOT DO
#   args_parse touches the filesystem never, and the environment never. It
#   reads "$@", it writes OPT_* and the three directory globals, and it exits
#   EX_USAGE naming the offending flag. Everything that needs to read the
#   variable surface off disk -- the environment audit and the --set key check
#   -- lives in its own function, called by install.sh after args_parse has
#   returned.
#
# THE PUBLIC SURFACE, in the order install.sh uses it
#   args_parse "$@"                  parse; set every OPT_*; exit 10 on a bad flag
#   args_mode                        print install | preflight | verify | check
#   args_usage                       print the help text, including the exit table
#   args_version                     print "tpot-automation <version>"
#   args_env_check                   audit TPOT_*/IOC_*; exit 10 naming a typo
#   args_web_password_action         print supplied | prompt | missing | not-needed
#   args_prompt_web_password         the terminal fallback; the value on STDOUT
#   args_die_missing_web_password    the three-way message, then exit 10
#   args_is_known_key KEY            verdict; prints nothing
#   args_is_secret_key KEY           verdict; prints nothing
#
# WHERE THE KEY LIST COMES FROM
#   inventories/example/group_vars/all.yml, parsed with the same expression
#   tests/check-variable-surface.sh uses. There is no second copy of the
#   variable surface in this file, because a second copy is a copy that drifts,
#   and a drifted copy here rejects a legitimate --set with a message that
#   blames the user.
#
# shellcheck shell=bash

# Sourcing this file twice must be harmless: under `set -e`, a re-run of the
# readonly-adjacent setup would otherwise take the caller down.
if [[ -n ${_TPOT_ARGS_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_ARGS_SH_LOADED=1

# ---------------------------------------------------------------------------
# Locating the tree.
#
# install.sh sets REPO_DIR before it sources anything, and that is the normal
# path. The fallback exists so that a test can source this file on its own
# without staging a whole run, and it is computed once, here, rather than in
# every function that needs a path.
# ---------------------------------------------------------------------------
_TPOT_ARGS_FALLBACK_ROOT=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/.." && pwd)

_tpot_args_root() {
    if [[ -n ${REPO_DIR:-} ]]; then
        printf '%s\n' "$REPO_DIR"
    else
        printf '%s\n' "$_TPOT_ARGS_FALLBACK_ROOT"
    fi
}

# The exit table is the source of truth for every code this file exits with,
# and --help prints it verbatim. Source it if install.sh has not already.
if [[ -z ${_TPOT_EXITCODES_SH_LOADED:-} ]]; then
    # shellcheck source=lib/exitcodes.sh
    . "$(_tpot_args_root)/lib/exitcodes.sh"
fi

# ---------------------------------------------------------------------------
# Diagnostics.
#
# log.sh is not initialised yet at parse time -- the transcript is opened at
# step 2, after the flags have been read -- so these write straight to the
# real stderr. They never print a value that came from a secret channel.
# ---------------------------------------------------------------------------
_tpot_args_die() {
    local code=$1 fmt=$2
    shift 2
    # shellcheck disable=SC2059
    printf "install.sh: ${fmt}\n" "$@" >&2
    exit "$code"
}

_tpot_args_warn() {
    local fmt=$1
    shift
    # shellcheck disable=SC2059
    printf "install.sh: WARN ${fmt}\n" "$@" >&2
}

_tpot_args_version() {
    local file value
    if [[ -n ${TPOT_VERSION:-} ]]; then
        printf '%s\n' "$TPOT_VERSION"
        return 0
    fi
    file="$(_tpot_args_root)/VERSION"
    value=''
    if [[ -r $file ]]; then
        IFS= read -r value < "$file" || true
        value=${value//[[:space:]]/}
    fi
    printf '%s\n' "${value:-unknown}"
}

# ===========================================================================
# The variable surface
# ===========================================================================
#
# ARGS_KNOWN_KEYS   every key this installer understands, in file order
# ARGS_SECRET_KEYS  the subset that may never appear as a command-line value
#
# Both are read from inventories/example/group_vars/all.yml, which is the
# human-readable copy of the variable surface and the file lib/varschema.json
# is checked against. The key expression is the one the build check uses:
#
#     ^# (tpot|ioc)_[a-z0-9_]+:
#
# Secrecy is read from the same file's own markers: a comment line that BEGINS
# with the word SECRET makes the keys its block introduces secret, and the
# form "SECRET: <key>" names one key in a block that introduces several. The
# marker has to start the line, because the file also says "NO SECRET MAY BE
# PUT HERE" in the middle of a paragraph about a key that is entirely public.
#
# That marker parse is then UNIONED with a name rule -- a key ending in
# _password or _auth_header_value is secret whatever the prose says. The union
# is deliberate and it fails closed: if somebody rewords the file and the
# marker parse comes back empty, --set is still refused for the keys that
# matter, and an empty union is treated as a bug in this installer rather than
# as permission to put a credential on a command line.
# ---------------------------------------------------------------------------
ARGS_KNOWN_KEYS=()
ARGS_SECRET_KEYS=()
_TPOT_ARGS_KEYSPEC_LOADED=''

args_load_keyspec() {
    [[ -n $_TPOT_ARGS_KEYSPEC_LOADED ]] && return 0

    local file line key
    local block_marker=0
    local -a block_named=()

    file="$(_tpot_args_root)/inventories/example/group_vars/all.yml"
    if [[ ! -r $file ]]; then
        _tpot_args_die "$EX_INTERNAL" \
            "cannot read the variable surface at %s. This is a bug in the installer, not in your input." \
            "$file"
    fi

    ARGS_KNOWN_KEYS=()
    ARGS_SECRET_KEYS=()

    while IFS= read -r line || [[ -n $line ]]; do
        # A blank line ends a comment block, and with it the reach of any
        # SECRET marker the block carried.
        if [[ -z ${line//[[:space:]]/} ]]; then
            block_marker=0
            block_named=()
            continue
        fi

        # A key line. Same expression as tests/check-variable-surface.sh.
        if [[ $line =~ ^\#\ ((tpot|ioc)_[a-z0-9_]+): ]]; then
            key=${BASH_REMATCH[1]}
            ARGS_KNOWN_KEYS+=("$key")
            if (( ${#block_named[@]} > 0 )); then
                local named
                for named in "${block_named[@]}"; do
                    [[ $named == "$key" ]] && ARGS_SECRET_KEYS+=("$key")
                done
            elif (( block_marker )); then
                ARGS_SECRET_KEYS+=("$key")
            fi
            continue
        fi

        # Prose. The marker is a comment line that BEGINS with the word
        # SECRET -- which is how the file writes it, and which is what keeps
        # "NO SECRET MAY BE PUT HERE", three lines above a perfectly public
        # key, from marking that key as a credential.
        if [[ $line =~ ^\#[[:space:]]*SECRET:[[:space:]]+((tpot|ioc)_[a-z0-9_]+) ]]; then
            block_named+=("${BASH_REMATCH[1]}")
        elif [[ $line =~ ^\#[[:space:]]*SECRET([^A-Za-z]|$) ]]; then
            block_marker=1
        fi
    done < "$file"

    # The name rule, unioned in. Fail closed: a key that looks like a
    # credential is treated as one even if the prose never said so. The scan
    # is written out rather than calling args_is_secret_key, because that
    # function loads the keyspec and we are inside the load.
    local already candidate
    for key in "${ARGS_KNOWN_KEYS[@]}"; do
        [[ $key == *_password || $key == *_auth_header_value ]] || continue
        already=0
        for candidate in ${ARGS_SECRET_KEYS[@]+"${ARGS_SECRET_KEYS[@]}"}; do
            [[ $candidate == "$key" ]] && already=1
        done
        (( already )) || ARGS_SECRET_KEYS+=("$key")
    done

    if (( ${#ARGS_KNOWN_KEYS[@]} == 0 )) || (( ${#ARGS_SECRET_KEYS[@]} == 0 )); then
        local msg
        msg="the variable surface in %s parsed to %d keys and %d secrets. Refusing to continue: "
        msg+="with no secret list, a credential could reach a command line."
        _tpot_args_die "$EX_INTERNAL" "$msg" "$file" "${#ARGS_KNOWN_KEYS[@]}" "${#ARGS_SECRET_KEYS[@]}"
    fi

    _TPOT_ARGS_KEYSPEC_LOADED=1
    return 0
}

args_is_known_key() {
    local want=${1:-} key
    args_load_keyspec
    for key in "${ARGS_KNOWN_KEYS[@]}"; do
        [[ $key == "$want" ]] && return 0
    done
    return 1
}

args_is_secret_key() {
    local want=${1:-} key
    args_load_keyspec
    for key in "${ARGS_SECRET_KEYS[@]}"; do
        [[ $key == "$want" ]] && return 0
    done
    return 1
}

# _tpot_args_suggest WANT SHAPE
#   Print the known key whose name shares the longest prefix with WANT, when
#   that prefix is long enough to be a typo rather than a coincidence. SHAPE is
#   `environment` (compare uppercased) or `key`. Prints nothing when there is no
#   plausible candidate -- a wrong guess is worse than no guess.
_tpot_args_suggest() {
    local want=${1:-} shape=${2:-key}
    local cand cmp best='' best_len=0 len
    args_load_keyspec
    for cand in "${ARGS_KNOWN_KEYS[@]}"; do
        if [[ $shape == environment ]]; then
            cmp=${cand^^}
        else
            cmp=$cand
        fi
        len=0
        while (( len < ${#want} && len < ${#cmp} )) && [[ ${want:len:1} == "${cmp:len:1}" ]]; do
            len=$(( len + 1 ))
        done
        if (( len > best_len )); then
            best_len=$len
            best=$cmp
        fi
    done
    if (( best_len >= 10 )); then
        printf '%s\n' "$best"
    fi
    return 0
}

# ===========================================================================
# The parsed-flag variables
# ===========================================================================
#
# Every one is initialised here, before parsing, and nothing relies on a
# variable being unset: a caller's environment may have set any of these
# names, and an installer that inherits its own switches from the environment
# is an installer that cannot be reasoned about.
#
# Booleans are the strings 0 and 1. They are shell values, not JSON.
# ---------------------------------------------------------------------------
_tpot_args_init_opts() {
    OPT_CONFIG_FILES=()
    OPT_OVERRIDES=()
    OPT_SECRET_FILES=()

    OPT_PREFLIGHT_ONLY=0
    OPT_VERIFY_ONLY=0
    OPT_CHECK=0
    OPT_EXAMPLE_CONFIG=0
    OPT_JSON=0
    OPT_HELP=0
    OPT_VERSION=0
    OPT_INSTALL_DEPS=1
    OPT_TREE_CLEAN=1
    OPT_VERBOSE=0

    OPT_LOG_DIR=/var/log/tpot-automation
    OPT_STATE_DIR=/var/lib/tpot-automation
    OPT_RUNTIME_PARENT=/run

    # Defined here as well as in _tpot_args_resolve_dirs, because --help,
    # --version and --example-config stop parsing where they are found and
    # never reach the resolver. Leaving them undefined would hand install.sh
    # an unbound variable under `set -u` on the three paths that are supposed
    # to be the simplest in the whole product.
    TPOT_LOG_DIR=$OPT_LOG_DIR
    TPOT_STATE_DIR=$OPT_STATE_DIR

    # -y is implied whenever stdin is not a terminal. This is the single
    # mechanism that makes `install.sh --config ... </dev/null` under setsid
    # structurally unable to reach a prompt: there is no mode to forget to
    # pass, because not having a terminal IS the mode.
    if [[ -t 0 ]]; then
        OPT_NON_INTERACTIVE=0
    else
        OPT_NON_INTERACTIVE=1
    fi

    ARGS_ENV_SUPPLIED=()
    ARGS_ENV_CHECKED=0
}

# ---------------------------------------------------------------------------
# Value handling for the flags that take one.
#
# Both spellings are accepted -- `--config FILE` and `--config=FILE` -- because
# a caller writing a cloud-init runcmd line will use whichever they know, and
# rejecting one of them is a usage error with no purpose.
#
# These helpers communicate through _av_* rather than through arguments,
# because the loop below has to be able to consume the NEXT token, and a
# function cannot shift its caller's argument list.
# ---------------------------------------------------------------------------
_tpot_args_take_value() {
    _av_used=0
    if (( _av_has )); then
        _av_out=$_av_inline
        return 0
    fi
    if (( ! _av_next_ok )); then
        _tpot_args_die "$EX_USAGE" "%s takes a value and none was given. Try 'install.sh --help'." "$_av_key"
    fi
    # A value that looks like a flag is nearly always a forgotten argument,
    # and the failure it causes otherwise -- a missing file, an unreadable
    # timezone -- names the wrong thing.
    if [[ $_av_next == -* && $_av_next != -[0-9]* && $_av_next != - ]]; then
        _tpot_args_die "$EX_USAGE" \
            "%s takes a value, but the next argument is the flag '%s'. Try 'install.sh --help'." \
            "$_av_key" "$_av_next"
    fi
    _av_out=$_av_next
    _av_used=1
    return 0
}

_tpot_args_no_value() {
    if (( _av_has )); then
        _tpot_args_die "$EX_USAGE" "%s takes no value. Try 'install.sh --help'." "$_av_key"
    fi
    return 0
}

# _tpot_args_add_set SPEC
#   Validate and record one KEY=VALUE override, from --set or from a
#   convenience flag. This is the single gate through which a value reaches
#   OPT_OVERRIDES, so the secret-key refusal cannot be routed around.
_tpot_args_add_set() {
    local spec=${1:-} key value hint
    if [[ $spec != *=* ]]; then
        _tpot_args_die "$EX_USAGE" "--set takes KEY=VALUE; got '%s'." "$spec"
    fi
    key=${spec%%=*}
    value=${spec#*=}
    if [[ ! $key =~ ^[a-z][a-z0-9_]*$ ]]; then
        _tpot_args_die "$EX_USAGE" "--set key '%s' is not a variable name." "$key"
    fi
    if ! args_is_known_key "$key"; then
        hint=$(_tpot_args_suggest "$key" key)
        if [[ -n $hint ]]; then
            _tpot_args_die "$EX_USAGE" "--set %s: no such variable. Did you mean %s?" "$key" "$hint"
        fi
        _tpot_args_die "$EX_USAGE" \
            "--set %s: no such variable. 'install.sh --example-config' lists every one." "$key"
    fi
    if args_is_secret_key "$key"; then
        local msg
        msg="--set is refused for the secret variable %s: a flag value is world-readable in /proc "
        msg+="for the lifetime of the process. Supply it %s"
        _tpot_args_die "$EX_USAGE" "$msg" "$key" "$(_tpot_args_secret_channels "$key")"
    fi
    OPT_OVERRIDES+=("$key=$value")
    return 0
}

# _tpot_args_secret_channels KEY
#   The one-line "supply it this way instead" tail, per secret key. The flag
#   names here are this file's own, so they cannot drift from anything else.
_tpot_args_secret_channels() {
    case ${1:-} in
        tpot_web_password)
            printf 'with --web-password-file PATH, with TPOT_WEB_PASSWORD, or in an answer file (--config).\n'
            ;;
        tpot_os_user_password)
            printf 'with --os-user-password-file PATH, with TPOT_OS_USER_PASSWORD, or in an answer file (--config).\n'
            ;;
        *)
            printf 'with %s, or in an answer file (--config).\n' "${1^^}"
            ;;
    esac
}

# ===========================================================================
# args_parse
# ===========================================================================
args_parse() {
    _tpot_args_init_opts

    local -a argv=("$@")
    local n=${#argv[@]}
    local i=0 arg key value has
    local _av_key _av_has _av_inline _av_next _av_next_ok _av_out _av_used

    while (( i < n )); do
        arg=${argv[i]}

        # --name=value is split before dispatch; --name and -x are not.
        if [[ $arg == --*=* ]]; then
            key=${arg%%=*}
            value=${arg#*=}
            has=1
        else
            key=$arg
            value=''
            has=0
        fi

        _av_key=$key
        _av_has=$has
        _av_inline=$value
        _av_out=''
        _av_used=0
        if (( i + 1 < n )); then
            _av_next_ok=1
            _av_next=${argv[i + 1]}
        else
            _av_next_ok=0
            _av_next=''
        fi

        case $key in
            # -- Modes that do nothing else. Each stops parsing on the spot,
            #    so `install.sh --help` prints help even when the rest of the
            #    line is wrong, which is exactly when it is asked for.
            -h|--help)
                _tpot_args_no_value
                OPT_HELP=1
                return 0
                ;;
            -V|--version)
                _tpot_args_no_value
                OPT_VERSION=1
                return 0
                ;;
            --example-config)
                _tpot_args_no_value
                OPT_EXAMPLE_CONFIG=1
                return 0
                ;;

            # -- Input channels
            -c|--config)
                _tpot_args_take_value
                OPT_CONFIG_FILES+=("$_av_out")
                ;;
            --set)
                _tpot_args_take_value
                _tpot_args_add_set "$_av_out"
                ;;
            -y|--non-interactive)
                _tpot_args_no_value
                OPT_NON_INTERACTIVE=1
                ;;

            # -- Secrets. A PATH, never a value.
            --web-password-file)
                _tpot_args_take_value
                OPT_SECRET_FILES+=("tpot_web_password=$_av_out")
                ;;
            --os-user-password-file)
                _tpot_args_take_value
                OPT_SECRET_FILES+=("tpot_os_user_password=$_av_out")
                ;;

            # -- Run modes
            --preflight-only)
                _tpot_args_no_value
                OPT_PREFLIGHT_ONLY=1
                ;;
            --verify-only)
                _tpot_args_no_value
                OPT_VERIFY_ONLY=1
                ;;
            --check)
                _tpot_args_no_value
                OPT_CHECK=1
                ;;
            --json)
                _tpot_args_no_value
                OPT_JSON=1
                ;;

            # -- Convenience flags. Every one is an override with a friendlier
            #    spelling; none of them has a variable of its own, so there is
            #    one precedence order and one place it is implemented.
            --os-user)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_os_user=$_av_out"
                ;;
            --os-user-password)
                _tpot_args_no_value
                _tpot_args_add_set "tpot_os_user_password_policy=set"
                ;;
            --web-user)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_web_user=$_av_out"
                ;;
            --install-type)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_install_type=$_av_out"
                ;;
            --timezone)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_timezone=$_av_out"
                ;;
            --no-timezone)
                _tpot_args_no_value
                _tpot_args_add_set "tpot_timezone=null"
                ;;
            --locale)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_locale=$_av_out"
                ;;
            --no-locale)
                _tpot_args_no_value
                _tpot_args_add_set "tpot_locale=null"
                ;;
            --upstream-url)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_upstream_url=$_av_out"
                ;;
            --upstream-ref)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_upstream_ref=$_av_out"
                ;;
            --upstream-repo-url)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_upstream_repo_url=$_av_out"
                ;;
            --upstream-checksum)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_upstream_checksum=$_av_out"
                ;;
            --reboot)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_reboot_policy=$_av_out"
                ;;
            --os-upgrade)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_os_upgrade=$_av_out"
                ;;
            --ansible-source)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_ansible_source=$_av_out"
                ;;
            --telemetry)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_upstream_telemetry=$_av_out"
                ;;
            --firewall)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_firewall_mode=$_av_out"
                ;;
            --force-unsupported-os)
                _tpot_args_no_value
                _tpot_args_add_set "tpot_force_unsupported_os=true"
                ;;
            --force-low-resources)
                _tpot_args_no_value
                _tpot_args_add_set "tpot_force_low_resources=true"
                ;;
            --force-reinstall)
                _tpot_args_no_value
                _tpot_args_add_set "tpot_force_reinstall=true"
                ;;
            --no-install-deps)
                _tpot_args_no_value
                OPT_INSTALL_DEPS=0
                _tpot_args_add_set "tpot_install_deps=false"
                ;;
            --no-tree-clean)
                _tpot_args_no_value
                OPT_TREE_CLEAN=0
                _tpot_args_add_set "tpot_normalize_line_endings=false"
                ;;

            # -- Directories. Flag-only by design (see the note in --help).
            --log-dir)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_log_dir=$_av_out"
                ;;
            --state-dir)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_state_dir=$_av_out"
                ;;
            --runtime-dir)
                _tpot_args_take_value
                _tpot_args_add_set "tpot_runtime_dir=$_av_out"
                ;;

            # -- Diagnostics
            --verbose)
                _tpot_args_no_value
                OPT_VERBOSE=$(( OPT_VERBOSE + 1 ))
                ;;
            -v|-vv|-vvv|-vvvv)
                OPT_VERBOSE=$(( OPT_VERBOSE + ${#key} - 1 ))
                ;;

            --)
                _tpot_args_die "$EX_USAGE" \
                    "this installer has no positional arguments, so '--' separates nothing. %s" \
                    "Try 'install.sh --help'."
                ;;
            -*)
                _tpot_args_die "$EX_USAGE" "unrecognised option '%s'. Try 'install.sh --help'." "$key"
                ;;
            *)
                _tpot_args_die "$EX_USAGE" \
                    "unrecognised argument '%s'. This installer takes options only. Try 'install.sh --help'." \
                    "$key"
                ;;
        esac

        i=$(( i + 1 + _av_used ))
    done

    _tpot_args_resolve_dirs
    _tpot_args_check_modes
    return 0
}

# ---------------------------------------------------------------------------
# The three directory settings are resolved here rather than in lib/config.py,
# because the transcript is opened at step 2 and the merge does not happen
# until step 4. Both channels are flag-level, so both are read out of
# OPT_OVERRIDES in command-line order and the last one wins -- which keeps a
# single precedence rule instead of a special case.
# ---------------------------------------------------------------------------
_tpot_args_resolve_dirs() {
    local entry key value
    for entry in ${OPT_OVERRIDES[@]+"${OPT_OVERRIDES[@]}"}; do
        key=${entry%%=*}
        value=${entry#*=}
        case $key in
            tpot_log_dir)     OPT_LOG_DIR=$value ;;
            tpot_state_dir)   OPT_STATE_DIR=$value ;;
            tpot_runtime_dir) OPT_RUNTIME_PARENT=$value ;;
        esac
    done
    # Named without the OPT_ prefix because they outlive parsing: log.sh and
    # result.sh read them. They are shell variables and nothing more -- see
    # the preamble in install.sh for why none of them is exported.
    TPOT_LOG_DIR=$OPT_LOG_DIR
    TPOT_STATE_DIR=$OPT_STATE_DIR
    return 0
}

# result.json records exactly one invocation mode, so exactly one may be
# asked for. Catching it here means the run stops before it has opened a
# transcript, rather than at the point one of the two is silently ignored.
_tpot_args_check_modes() {
    local -a asked=()
    (( OPT_PREFLIGHT_ONLY )) && asked+=("--preflight-only")
    (( OPT_VERIFY_ONLY ))    && asked+=("--verify-only")
    (( OPT_CHECK ))          && asked+=("--check")
    if (( ${#asked[@]} > 1 )); then
        _tpot_args_die "$EX_USAGE" "%s and %s cannot be combined: a run has one mode." "${asked[0]}" "${asked[1]}"
    fi
    return 0
}

# args_mode -- the string result.json's invocation.mode carries.
args_mode() {
    if (( OPT_PREFLIGHT_ONLY )); then
        printf 'preflight\n'
    elif (( OPT_VERIFY_ONLY )); then
        printf 'verify\n'
    elif (( OPT_CHECK )); then
        printf 'check\n'
    else
        printf 'install\n'
    fi
}

# ===========================================================================
# The environment channel
# ===========================================================================
#
# lib/config.py harvests the environment for real, as part of the merge. This
# function exists because two of its jobs have to happen EARLIER than that:
#
#   1. A misspelt TPOT_WEB_PASSWD must be named as a misspelling. If it waited
#      for the merge it would arrive as "tpot_web_password is required", which
#      sends the user to look at the one thing they did supply.
#   2. Whether a password came from the environment decides whether there is
#      anything to ask for on a terminal, and that decision is taken at step 1.
#
# It reads NAMES only. No value is read, printed or copied anywhere.
# ---------------------------------------------------------------------------

# Upstream T-Pot's own two variables. A user may legitimately have them set,
# and failing on somebody else's namespace would be hostile. They are ignored
# with a warning, and they are not ours to drift from: they belong to
# upstream's installer, not to this project's variable surface.
_TPOT_ARGS_ENV_IGNORE=(TPOT_BRANCH TPOT_REPO_URL)

# The four names install.sh unsets in its own preamble before anything else
# runs. They reach this function only if the preamble was skipped, so the
# check is defence in depth -- and the message is the useful one either way.
_TPOT_ARGS_ENV_FLAG_ONLY=(
    TPOT_LOG:--log-dir
    TPOT_LOG_DIR:--log-dir
    TPOT_STATE_DIR:--state-dir
    TPOT_RUNTIME_DIR:--runtime-dir
)

args_env_check() {
    local name lower ignore pair hint
    local -a unknown=()

    args_load_keyspec
    ARGS_ENV_SUPPLIED=()

    while IFS= read -r name; do
        [[ $name == TPOT_* || $name == IOC_* ]] || continue

        # Upstream's namespace: warn, do not fail.
        ignore=0
        for pair in "${_TPOT_ARGS_ENV_IGNORE[@]}"; do
            [[ $name == "$pair" ]] && ignore=1
        done
        if (( ignore )); then
            _tpot_args_warn "%s belongs to upstream T-Pot, not to this installer, and is ignored here." "$name"
            continue
        fi

        # Flag-only settings: the transcript is open before any answer file
        # has been read, so these cannot be merged. Name the flag.
        for pair in "${_TPOT_ARGS_ENV_FLAG_ONLY[@]}"; do
            if [[ $name == "${pair%%:*}" ]]; then
                _tpot_args_die "$EX_USAGE" \
                    "%s is not read from the environment; use %s DIR." "$name" "${pair#*:}"
            fi
        done

        lower=${name,,}
        if args_is_known_key "$lower"; then
            ARGS_ENV_SUPPLIED+=("$lower")
        else
            unknown+=("$name")
        fi
    done < <(compgen -e || true)

    if (( ${#unknown[@]} > 0 )); then
        for name in "${unknown[@]}"; do
            hint=$(_tpot_args_suggest "$name" environment)
            if [[ -n $hint ]]; then
                printf 'install.sh: %s is not a variable this installer understands. Did you mean %s?\n' \
                    "$name" "$hint" >&2
            else
                printf 'install.sh: %s is not a variable this installer understands.\n' "$name" >&2
            fi
        done
        local msg
        msg="%d unrecognised TPOT_/IOC_ name(s) in the environment. Every one is the variable name "
        msg+="uppercased; 'install.sh --example-config' lists them all."
        _tpot_args_die "$EX_USAGE" "$msg" "${#unknown[@]}"
    fi

    ARGS_ENV_CHECKED=1
    return 0
}

# args_env_has KEY -- verdict: was this key supplied through the environment?
args_env_has() {
    local want=${1:-} key
    for key in ${ARGS_ENV_SUPPLIED[@]+"${ARGS_ENV_SUPPLIED[@]}"}; do
        [[ $key == "$want" ]] && return 0
    done
    return 1
}

# ===========================================================================
# The web password: supplied, asked for, or a usage error
# ===========================================================================

# _tpot_args_override_value KEY -- print the last --set/flag value for KEY.
_tpot_args_override_value() {
    local want=${1:-} entry out=''
    for entry in ${OPT_OVERRIDES[@]+"${OPT_OVERRIDES[@]}"}; do
        [[ ${entry%%=*} == "$want" ]] && out=${entry#*=}
    done
    printf '%s\n' "$out"
}

# _tpot_args_install_type -- the install type as far as argv and the
# environment can settle it. An answer file can still change it, which is why
# the only decision taken on this value is whether to ASK for a password: a
# type that turns out not to need one simply ignores what was supplied.
_tpot_args_install_type() {
    local value
    value=$(_tpot_args_override_value tpot_install_type)
    if [[ -z $value ]]; then
        value=${TPOT_INSTALL_TYPE:-}
    fi
    printf '%s\n' "${value:-h}"
}

# args_web_password_action -- one of:
#   not-needed  this run does not need a dashboard password
#   supplied    one was given, or may have been given in an answer file
#   prompt      nothing was given, there is a terminal: ask once and confirm
#   missing     nothing was given and there is no terminal: usage error
args_web_password_action() {
    local entry itype

    if (( OPT_HELP || OPT_VERSION || OPT_EXAMPLE_CONFIG || OPT_VERIFY_ONLY )); then
        printf 'not-needed\n'
        return 0
    fi

    # --preflight-only runs with the password downgraded to optional, so that
    # a box -- or, when someone builds the CI tier this tree does not yet have,
    # a container per distribution -- can be checked without inventing a
    # real-looking credential. Preflight records input_complete as
    # inconclusive rather than ok, precisely because the run never had the one
    # input a real install requires.
    if (( OPT_PREFLIGHT_ONLY )); then
        printf 'not-needed\n'
        return 0
    fi

    itype=$(_tpot_args_install_type)
    case $itype in
        s|m)
            printf 'not-needed\n'
            return 0
            ;;
    esac

    for entry in ${OPT_SECRET_FILES[@]+"${OPT_SECRET_FILES[@]}"}; do
        if [[ ${entry%%=*} == tpot_web_password ]]; then
            printf 'supplied\n'
            return 0
        fi
    done

    # Read by name rather than through ARGS_ENV_SUPPLIED, deliberately: this
    # function is called inside a command substitution, and a subshell that
    # exits takes nothing with it, so it must not be able to need a check that
    # may not have run yet. The name is all that is looked at; the value is
    # never read here.
    if [[ -n ${TPOT_WEB_PASSWORD+x} ]]; then
        printf 'supplied\n'
        return 0
    fi

    # An answer file may carry it. This function cannot read one -- that is
    # the merge's job, and it has the permission and location rules -- so a
    # --config file counts as "may have been supplied". If it was not, the
    # merge says so, with the same three-way message.
    if (( ${#OPT_CONFIG_FILES[@]} > 0 )); then
        printf 'supplied\n'
        return 0
    fi

    if (( OPT_NON_INTERACTIVE )); then
        printf 'missing\n'
    else
        printf 'prompt\n'
    fi
    return 0
}

# args_die_missing_web_password -- the message the spec fixes, then exit 10.
args_die_missing_web_password() {
    cat >&2 <<'MISSING'
tpot_web_password is required and was not supplied.
Set it one of three ways:
  --web-password-file /root/.tpot-web-pw   (root-owned, 0600)
  TPOT_WEB_PASSWORD=...                    (environment)
  tpot_web_password: "..."                 in --config /root/tpot.yml
Run `install.sh --example-config > /root/tpot.yml` for a starting point.
MISSING
    exit "$EX_USAGE"
}

# ---------------------------------------------------------------------------
# args_prompt_web_password
#
# The terminal fallback: one short function, not a mode. It exists so that a
# person typing `install.sh` on a console is not told to go and write a file
# first, and it is unreachable without a terminal because -y is implied when
# stdin is not one.
#
# HOW TO CALL IT. The value is written to STDOUT and to nothing else, so the
# caller must connect stdout to a pipe -- never to the transcript:
#
#     python3 "$REPO_DIR/lib/config.py" merge ... --secret-stdin tpot_web_password \
#         < <(args_prompt_web_password)
#
# The prompt itself is written to /dev/tty, and the value is read from
# /dev/tty, so neither depends on where stdin and stdout have been pointed.
# Writing to a terminal is refused outright: that would put the password on
# the screen and, worse, into the transcript through the redaction pump before
# there is anything registered to redact.
#
# The two `read` statements below are the only interactive reads in the tree.
# tests/check-no-tty.sh keeps it that way: it fails the build on a read that
# looks interactive -- a -p or -s option cluster, a /dev/tty source, or a bare
# read with no redirection, loop or pipe -- anywhere at all, and it exempts
# one only in THIS file, only on a line carrying the `gate-allow: <rule-id>`
# marker for the rule named interactive-read, with a written reason. (That id
# is spelt out in the two markers below and deliberately not here: the parser
# reads any bare id after the colon as a real exemption, so prose writes the
# placeholder instead.) Reads that take a redirection or a pipe are
# not touched by it, here or elsewhere; they cannot reach a person.
# ---------------------------------------------------------------------------
args_prompt_web_password() {
    local first second attempt

    if [[ -t 1 ]]; then
        local msg
        msg="the password prompt was called with its output on a terminal. This is a bug in the "
        msg+="installer; the value must go to a pipe."
        _tpot_args_die "$EX_INTERNAL" "$msg"
    fi
    if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
        args_die_missing_web_password
    fi

    # The two reads below are the entire interactive surface of this product,
    # and tests/check-no-tty.sh is right to fire on both: a gate reads text,
    # and the text alone cannot show that neither line is reachable without a
    # person at a terminal. Two separate guarantees make that so, and both are
    # above this loop rather than in it. First, -y is implied whenever stdin is
    # not a terminal (_tpot_args_reset), and args_web_password_action then
    # answers `missing`, so install.sh never calls this function at all -- it
    # prints the three-way usage error instead. Second, this function returns
    # through args_die_missing_web_password unless /dev/tty is BOTH readable
    # and writable, which is what covers the case where stdin is a terminal but
    # the controlling terminal has gone. There is no flag that turns the prompt
    # on: not having a terminal IS the non-interactive mode.
    for attempt in 1 2; do
        printf 'T-Pot dashboard password (not shown): ' > /dev/tty
        # gate-allow: interactive-read the sanctioned prompt; unreachable without a TTY -- see the guard above
        IFS= read -rs first < /dev/tty || first=''
        printf '\n' > /dev/tty
        printf 'Repeat it: ' > /dev/tty
        # gate-allow: interactive-read the confirming half of that same prompt; same guard, same single fallback
        IFS= read -rs second < /dev/tty || second=''
        printf '\n' > /dev/tty

        if [[ -z $first ]]; then
            printf 'The password cannot be empty.\n' > /dev/tty
        elif [[ $first != "$second" ]]; then
            printf 'The two entries differ.\n' > /dev/tty
        else
            printf '%s' "$first"
            return 0
        fi
    done

    _tpot_args_die "$EX_USAGE" \
        "the password was not confirmed after two attempts. Supply it with --web-password-file PATH instead."
}

# ===========================================================================
# --help and --version
# ===========================================================================
args_version() {
    printf 'tpot-automation %s\n' "$(_tpot_args_version)"
    return 0
}

args_usage() {
    printf 'tpot-automation %s -- unattended T-Pot honeypot installer\n\n' "$(_tpot_args_version)"
    cat <<'TPOT_HELP_BODY'
USAGE
  install.sh [OPTION]...

  Runs as root, on the machine that is to become the honeypot. There are no
  positional arguments. Options are long form; -c, -y, -v, -h and -V are the
  only short aliases.

MODES -- at most one of the first three
      --preflight-only         run the checks, print the report, exit. Changes
                               nothing at all. Exits 0, 11 or 12.
      --verify-only            run verification only. This is how a rebooted
                               box reaches 0 after a first run returned 20.
      --check                  preflight, then the playbook in check mode.
                               Changes nothing on the box.
      --example-config         print a commented answer file on stdout, exit 0
  -h, --help                   print this text, exit 0
  -V, --version                print the version, exit 0

INPUT
  -c, --config FILE            answer file, YAML or JSON. Repeatable; a later
                               file wins. Must be root-owned, mode 0600 or
                               0400, and outside this repository.
      --set KEY=VALUE          set one variable. Repeatable; highest
                               precedence. Refused for a secret key -- see
                               PASSWORDS.
  -y, --non-interactive        never ask anything; missing required input
                               becomes a usage error. IMPLIED AUTOMATICALLY
                               whenever stdin is not a terminal.

PASSWORDS
      --web-password-file FILE       read the dashboard password from FILE
      --os-user-password-file FILE   read the OS account password from FILE

  No flag takes a password as its value: argv is world-readable in /proc.
  Both flags take a PATH, root-owned and mode 0600. A password may also come
  from the environment (TPOT_WEB_PASSWORD) or from an answer file. Given none
  of those, and a terminal, install.sh asks once and confirms.

CONFIGURATION
      --os-user NAME           the unprivileged account that owns T-Pot
      --os-user-password       give that account a password rather than
                               locking it; supply the value with
                               --os-user-password-file
      --web-user NAME          the dashboard user (default: the OS account)
      --install-type CHAR      h hive | s sensor | l llm | i mini
                               | m mobile | t tarpit
      --timezone TZ            set the timezone
      --no-timezone            leave the timezone alone
      --locale LOCALE          set the locale
      --no-locale              leave the locale alone
      --os-upgrade LEVEL       none | safe | full            (default: safe)
      --reboot POLICY          never | if-required | always  (default: never)
      --telemetry off|on       upstream T-Pot's own data submissions
      --firewall none          reserved; only `none` is accepted in this
                               release, and it is what the product delivers
      --ansible-source SOURCE  auto | distro | venv | preinstalled

UPSTREAM T-POT
      --upstream-ref REF       the tag or commit to install. Never a branch.
      --upstream-url URL       where upstream's install.sh is fetched from
      --upstream-repo-url URL  the repository upstream clones the payload from
      --upstream-checksum SHA  the sha256 the fetched install.sh must match

OVERRIDES AND DIAGNOSTICS
      --force-unsupported-os   install on a distribution outside the matrix
      --force-low-resources    continue below the hard resource floors
      --force-reinstall        re-run upstream's installer on an installed box
      --no-install-deps        install no prerequisites; fail instead if one
                               is missing
      --no-tree-clean          do not normalise line endings in this tree
      --json                   print result.json on stdout; human output goes
                               to stderr
  -v, --verbose                repeatable; raises the playbook's verbosity

DIRECTORIES
      --log-dir DIR            default /var/log/tpot-automation
      --state-dir DIR          default /var/lib/tpot-automation
      --runtime-dir DIR        the tmpfs parent of this run's 0700 work
                               directory. Default /run.

  These three are flag-only and are not read from the environment: the
  transcript is opened before any answer file has been read, so a value that
  arrived later could not have applied to it.

PRECEDENCE, highest first
      --set and the long flags
        > the environment (TPOT_* / IOC_*)
          > --config FILE, a later file winning
            > the built-in default

  The environment name is the variable name uppercased, with no lookup table:
  tpot_web_password is TPOT_WEB_PASSWORD. An unrecognised TPOT_ or IOC_ name
  is a usage error naming it, so that a typo cannot degrade into a
  missing-input error pointing somewhere else.

EXIT CODES
TPOT_HELP_BODY
    printf '\n'
    ex_table
    printf '\n'
    cat <<'TPOT_HELP_FOOT'
FILES
  /var/log/tpot-automation/install-<run>.log   the transcript, mode 0600
  /var/lib/tpot-automation/result.json         the outcome, mode 0600

THE TWO-INVOCATION HAPPY PATH
  install.sh --example-config > /root/tpot.yml
  chmod 600 /root/tpot.yml
  install.sh --config /root/tpot.yml     # 20: installed, a reboot is required
  reboot
  install.sh --verify-only               # 0: installed and verified

  THE 20 AND THE 0 ABOVE ARE THE CONTRACT, NOT A TRANSCRIPT. This build has
  never installed anything and cannot: site.yml and verify.yml are two of the
  seventeen files preflight stage A requires and neither has been written. So
  both of the runs that would touch this machine stop in stage A and exit 11
  instead, having changed nothing. (--example-config is unaffected: it prints
  and exits 0, well before preflight.) docs/exit-codes.md says what is
  reachable today, and what is only specified.

AFTER IT FINISHES, READ THE NOTICE
  A finished box has moved administrative SSH to 64295 by default -- the
  port is tpot_admin_ssh_port -- and TCP/22 has been taken over by a
  honeypot. Port 22 is NOT your administrative SSH and it will never give
  you a shell on this machine.

  Which honeypot answers there is a property of the install type, so this
  text does not name one: upstream binds Cowrie for type h, Endlessh for t
  and Beelzebub for l, and its own documentation does not say for s, i or
  m. The closing notice names the program when it knows and says "a
  honeypot" when it does not; `dps` on the finished host shows what is
  actually running.

  Write the administrative SSH command down before you disconnect.
TPOT_HELP_FOOT
    return 0
}
