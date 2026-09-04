# lib/result.sh -- builds and writes result.json.
#
# WHY THIS FILE EXISTS
#   The automation contract is the product. An exit code says what happened;
#   result.json says what happened in enough detail to act on without a human
#   reading a transcript. It is the artefact a Packer build, a cloud-init run
#   or a CI job keeps, and it must therefore exist on EVERY path -- success,
#   every class of failure, and interruption. install.sh installs res_exit_trap
#   as its EXIT handler for exactly that reason: a run killed with Ctrl-C at
#   minute 40 still leaves a true, complete file behind.
#
# WHY IT CANNOT CONTAIN A CREDENTIAL
#   This is structural, not a promise anybody has to keep.
#
#   lib/config.py writes TWO documents: merged.json, which holds every value
#   including the three secret-typed ones, and public.json, which is the same
#   document with those keys REMOVED -- not blanked, removed. This file reads
#   public.json and never opens merged.json; the Python that serialises the
#   document refuses outright to open a file called merged.json, so a future
#   edit that wires the wrong path in fails loudly instead of leaking.
#
#   A secret key is still REPORTED, because "was a password supplied, and
#   where from?" is a real diagnostic question: it appears as
#   {"secret": true, "supplied": true, "source": "password-file"} with no
#   value member at any time. The absence is not filtering -- there is nothing
#   to filter, because the value was never in the document this file reads.
#
# WHY PYTHON SERIALISES IT
#   No JSON string is ever built by string concatenation in bash. Quoting a
#   value into JSON by hand is how a hostname containing a quote, or a warning
#   containing a backslash, turns the artefact into unparseable text -- and
#   the one artefact a caller depends on is the worst place to discover that.
#   Bash collects facts as TSV; python3 (standard library only) does every
#   piece of quoting and typing.
#
# WHERE THE CONTENT COMES FROM -- one writer per fact, and none of them is here
#   $RUNDIR/public.json          config values, minus secrets   (lib/config.py)
#   $RUNDIR/sources.json         which channel supplied each    (lib/config.py)
#   $RUNDIR/host.json            the box                        (lib/preflight.sh)
#   $RUNDIR/preflight.tsv        the checks and their verdicts  (lib/preflight.sh)
#   $RUNDIR/deps.json            ansible-core and collections   (lib/deps.sh)
#   $RUNDIR/ansible-report.json  upstream, invocation, accounts,
#                                verification                   (roles/report, in both plays)
#   $RUNDIR/result-kv.tsv        what install.sh itself decided (res_set, here)
#   lib/notice.sh                ports and notice lines         (notice_*)
#
# THE THREE FACTS THIS FILE NORMALISES RATHER THAN PASSES THROUGH
#   Everything else is copied from whoever measured it. These three are
#   re-derived here because getting them wrong produces a document that reads
#   true and is not, which is the failure this artefact exists to prevent:
#
#     host.matrix_tier      which tier of the two-tier support matrix the box
#                           was in. Preferred from host.json; derived when
#                           preflight did not say, never assumed to be the
#                           good answer.
#     upstream.ref_consistent   whether the ENTRYPOINT and the PAYLOAD came
#                           from the same upstream ref. One variable drives
#                           both and they may never be set apart; if they ever
#                           are, a run succeeds while this document names a ref
#                           the box is not running.
#     driver.*              shaped for the one native invocation, with the two
#                           dead fields of the abandoned design removed and a
#                           credential-on-argv treated as a defect to report
#                           rather than a redaction to perform quietly.
#
# shellcheck shell=bash

if [[ -n ${_TPOT_RESULT_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_RESULT_SH_LOADED=1

readonly _TPOT_RESULT_SCHEMA='tpot-automation/result@1'

# Facts install.sh has decided, as `key<TAB>value`, in the order they were
# set. Kept in memory and materialised as $RUNDIR/result-kv.tsv at write time,
# so res_set works before $RUNDIR exists -- an argument-parsing failure has to
# produce a result.json too, and at that point there is no run directory.
declare -ga _TPOT_RES_KV=()

# ---------------------------------------------------------------------------
# res_set KEY VALUE
#   Record one fact. Later wins for the single-valued keys; the repeatable
#   ones accumulate.
#
#   The closed vocabulary, and nothing else is interpreted:
#
#     single-valued
#       run_id tool_version started_at finished_at
#       outcome exit_code exit_name
#       mode                 install | preflight | verify | check
#       non_interactive      true | false
#       json                 true | false
#       log                  path of this run's transcript
#       reboot.required          true | false
#       reboot.performed         true | false
#       reboot.post_boot_verify_armed  true | false
#       already_installed    true | false
#
#     repeatable
#       forced   one --force-* override, by VARIABLE name
#       warning  one line of English
#       error    one line of English
#       notice   one entry of result.json's notice array
#
#     generated
#       port.<role>  one of admin_ssh dashboard elasticsearch honeypot_ssh
#                    The fourth role is deliberately not the name of a
#                    honeypot. Which program upstream binds to TCP/22 is a
#                    property of the install type -- Cowrie, Endlessh and
#                    Beelzebub across the editions upstream documents -- so
#                    the ROLE is recorded here and lib/notice.sh names the
#                    program only where upstream says which it is.
#
#   Tabs and newlines are stripped: the interchange format is TSV, and a value
#   carrying either would silently truncate the record.
# ---------------------------------------------------------------------------
res_set() {
    local key=${1-} value=${2-}
    [[ -n $key ]] || return 1
    value=${value//$'\t'/ }
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    _TPOT_RES_KV+=("${key}"$'\t'"${value}")
    return 0
}

res_add_warning() { res_set 'warning' "${1-}"; }
res_add_error()   { res_set 'error'   "${1-}"; }
res_add_forced()  { res_set 'forced'  "${1-}"; }

# ---------------------------------------------------------------------------
# res_outcome_for_code CODE
#   The exit code -> outcome mapping, which is one-to-one and closed.
#
#   `credential_leaked_to_log` is the one outcome no code maps to: it shares
#   exit 40 with an ordinary internal error and is set explicitly by
#   lib/log.sh's tripwire, which is why res_write prefers an already-set
#   TPOT_OUTCOME over anything derived here.
# ---------------------------------------------------------------------------
res_outcome_for_code() {
    case ${1-} in
        0)  printf 'ok\n' ;;
        10) printf 'usage_error\n' ;;
        11) printf 'preflight_failed\n' ;;
        12) printf 'inconclusive\n' ;;
        13) printf 'deps_failed\n' ;;
        14) printf 'upstream_failed\n' ;;
        15) printf 'driver_failed\n' ;;
        16) printf 'verify_failed\n' ;;
        20) printf 'reboot_required\n' ;;
        30) printf 'interrupted\n' ;;
        40) printf 'internal_error\n' ;;
        *)  printf 'internal_error\n' ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_res_collect_notice
#   Copy lib/notice.sh's ports and notice lines into the record, if it is
#   loaded. This is what makes "what the terminal said" and "what the artefact
#   says" the same sentence: both are rendered from _NOTICE, and neither has a
#   port number written as a literal.
#
#   Appended to the kv FILE at write time rather than to the in-memory array,
#   so writing result.json twice in one run cannot duplicate them.
# ---------------------------------------------------------------------------
_tpot_res_collect_notice() {
    local dest=${1-} role port line
    local -a rows=()
    [[ -n $dest ]] || return 0
    declare -F notice_ports_tsv >/dev/null 2>&1 || return 0

    # mapfile, never `read`: the product's core promise is that no code path
    # can block on a terminal, and the build check that enforces it is a grep
    # for `read` outside lib/args.sh. These loops consume a process
    # substitution and could never block -- but a rule with a documented
    # exception in it stops being checkable, so there is no exception.
    mapfile -t rows < <(notice_ports_tsv)
    for line in "${rows[@]}"; do
        [[ -n $line ]] || continue
        role=${line%%$'\t'*}
        port=${line#*$'\t'}
        [[ -n $role ]] && printf 'port.%s\t%s\n' "$role" "$port" >>"$dest"
    done

    declare -F notice_lines >/dev/null 2>&1 || return 0
    mapfile -t rows < <(notice_lines)
    for line in "${rows[@]}"; do
        [[ -n $line ]] && printf 'notice\t%s\n' "$line" >>"$dest"
    done
    return 0
}

# ---------------------------------------------------------------------------
# res_write [EXIT_CODE]
#   Build result.json and put it at $TPOT_RESULT_JSON, mode 0600, root:root.
#
#   Atomic: python writes and fsyncs a sibling temporary file, bash renames it
#   over the destination. A caller that reads the file concurrently sees
#   either the previous complete document or the new complete document, never
#   a half-written one.
#
#   It never fails the run. A result.json that could not be written is a
#   diagnostic loss; a result.json that took down the EXIT trap on its way out
#   would replace the run's real exit code with this file's, which is exactly
#   the failure the exit contract exists to prevent. Problems are reported and
#   the function returns non-zero.
# ---------------------------------------------------------------------------
res_write() {
    local code=${1:-${TPOT_EXIT_CODE:-${EX_INTERNAL:-40}}}
    local outcome=${TPOT_OUTCOME:-}
    local state_dir=${TPOT_STATE_DIR:-/var/lib/tpot-automation}
    local dest=${TPOT_RESULT_JSON:-$state_dir/result.json}
    local rundir=${RUNDIR:-}
    local kv tmp_out name rc=0

    [[ -n $outcome ]] || outcome=$(res_outcome_for_code "$code")

    if ! command -v python3 >/dev/null 2>&1; then
        _tpot_res_warn 'python3 is unavailable; %s was not written' "$dest"
        return 1
    fi

    mkdir -p -- "$state_dir" 2>/dev/null || {
        _tpot_res_warn 'cannot create %s; result.json was not written' "$state_dir"
        return 1
    }
    chmod 0750 -- "$state_dir" 2>/dev/null || true

    # The kv file lives on tmpfs with everything else when there is a run
    # directory. Before there is one -- a usage error, a failed preflight
    # stage A -- it goes beside the destination as a dotfile and is removed
    # immediately. It carries no secret in either case.
    if [[ -n $rundir && -d $rundir ]]; then
        kv="$rundir/result-kv.tsv"
    else
        kv="$state_dir/.result-kv.$$.tsv"
    fi
    tmp_out="$state_dir/.result.json.tmp"

    ( umask 0177; : >"$kv" ) 2>/dev/null || {
        _tpot_res_warn 'cannot write %s; result.json was not written' "$kv"
        return 1
    }
    chmod 0600 -- "$kv" 2>/dev/null || true

    {
        printf 'schema\t%s\n'       "$_TPOT_RESULT_SCHEMA"
        printf 'run_id\t%s\n'       "${TPOT_RUN_ID:-}"
        printf 'tool_version\t%s\n' "${TPOT_VERSION:-}"
        printf 'started_at\t%s\n'   "${TPOT_STARTED_AT:-}"
        printf 'finished_at\t%s\n'  "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'log\t%s\n'          "${TPOT_LOG:-}"
    } >>"$kv"

    # Everything install.sh set, in order, so a later res_set wins.
    if (( ${#_TPOT_RES_KV[@]} > 0 )); then
        printf '%s\n' "${_TPOT_RES_KV[@]}" >>"$kv"
    fi

    # The decided outcome and code go last so nothing can override them.
    {
        printf 'exit_code\t%s\n' "$code"
        printf 'outcome\t%s\n'   "$outcome"
        if declare -F ex_name >/dev/null 2>&1 && name=$(ex_name "$code" 2>/dev/null); then
            printf 'exit_name\t%s\n' "$name"
        fi
    } >>"$kv"

    _tpot_res_collect_notice "$kv"

    # The inputs the play and the other libraries wrote. Before $RUNDIR
    # exists none of them do, and every one is optional: an empty path means
    # "this fact is not known", and the serialiser emits null rather than
    # inventing a value.
    local -a pyargs=("$kv")
    if [[ -n $rundir && -d $rundir ]]; then
        pyargs+=(
            "$rundir/public.json"
            "$rundir/sources.json"
            "$rundir/preflight.tsv"
            "$rundir/host.json"
            "$rundir/deps.json"
            "$rundir/ansible-report.json"
        )
    else
        pyargs+=('' '' '' '' '' '')
    fi
    pyargs+=("$tmp_out")

    # TMPDIR on tmpfs: bash materialises a here-document as a temporary file,
    # and it should land in the run directory with everything else rather than
    # in /tmp. The program below contains no value of any kind, but the habit
    # is the point -- this is the call that handles the run's own artefact.
    local py_tmpdir=${TMPDIR:-/tmp}
    [[ -n $rundir && -d $rundir ]] && py_tmpdir=$rundir

    TMPDIR="$py_tmpdir" python3 - "${pyargs[@]}" <<'TPOT_RESULT_PY' || rc=$?
# Serialise result.json.  Standard library only; python3 >= 3.9.
#
# Every input is optional.  An absent or unreadable input means the fact is
# not known, and an unknown fact is emitted as null -- never as a plausible
# default.  A run that failed in preflight has no upstream object because no
# upstream was fetched, and saying so is the point of the artefact.
import json
import os
import sys
from datetime import datetime

SCHEMA = "tpot-automation/result@1"
TS_FMT = "%Y-%m-%dT%H:%M:%SZ"

BOOL_KEYS = {
    "non_interactive",
    "json",
    "already_installed",
    "reboot.required",
    "reboot.performed",
    "reboot.post_boot_verify_armed",
}
LIST_KEYS = ("forced", "warning", "error", "notice")


def fail(message):
    sys.stderr.write("result: %s\n" % message)
    raise SystemExit(40)


def load_json(path):
    if not path or not os.path.isfile(path):
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def as_bool(value, default=False):
    if isinstance(value, bool):
        return value
    if value is None:
        return default
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def as_int(value, default=None):
    try:
        return int(str(value).strip())
    except Exception:
        return default


# Upstream's own getopts string, install.sh:215 -- ":sb:r:t:u:p:h".  Only
# one half of it is needed to read an argv back: the letters that take a
# value, because the shape a value can be written in depends entirely on
# whether its letter takes one.  Every other letter -- upstream's two
# flagless ones, and anything upstream would report as unknown -- is skipped
# the same way getopts skips it, by carrying on to the next letter.
UPSTREAM_VALUE_OPTS = "brtup"
# The two whose value may never survive into this document.
UPSTREAM_SECRET_OPTS = "up"
MASK = "***"
# The English for each maskable letter, so a warning names what was on the
# command line rather than leaving a reader to look the letter up.
SECRET_OPT_SUBJECT = {"p": "a credential", "u": "a web username"}


def scan_upstream_argv(flags):
    """Read an argv list the way upstream's own getopts reads it.

    Returns one record per option occurrence, in order:

        (letter, value, value_index, tail_offset)

    `value` is None when the option was last in the list with nothing after
    it -- upstream sees that as a missing argument, which is not the same as
    an empty value.  When the value came from the tail of the SAME element,
    `value_index` is that element and `tail_offset` is the character the
    value starts at; when it came from the following element, `value_index`
    is that element and `tail_offset` is None.  A caller that wants only the
    value ignores both.

    This is a scanner rather than "the token after -x" because getopts
    accepts three shapes for one option, and the first version of this file
    knew only the first of them:

        separated   two elements, the value second
        attached    one element, the value in the tail
        clustered   flagless letters, then one that takes a value, then the
                    value -- in the same element or the next one

    Measured under bash 5.2.37 against a transcription of upstream's own
    getopts call: all three reach the same letter with the same OPTARG.  Two
    shapes that look like they ought to be options are measured too, and are
    deliberately NOT treated as one: everything after a value-taking letter
    is that letter's value, so a cluster ending in a word is one option with
    a wordy value; and an ordinary-looking word after a single dash is read
    by getopts as its first letter plus a value, which is why a leading
    value-taking letter is treated as an option and not as a word.

    One deliberate departure from getopts: a bare `--` is not treated as the
    end of the options.  Upstream would stop there and pass the rest on as
    operands, but this list is not being executed here -- it is being written
    into a document that gets attached to bug reports.  Something
    credential-shaped after a `--` is still a credential sitting in an argv,
    so it is still found and still masked.

    What no scanner can see, stated rather than left to be discovered: a
    BARE OPERAND.  A value with no option in front of it is indistinguishable
    from a hostname, so if a caller ever builds a list where a credential
    stands alone, nothing here will recognise it.
    """
    records = []
    index = 0
    while index < len(flags):
        token = flags[index]
        if len(token) < 2 or not token.startswith("-"):
            index += 1
            continue
        position = 1
        while position < len(token):
            letter = token[position]
            if letter not in UPSTREAM_VALUE_OPTS:
                position += 1
                continue
            tail = token[position + 1:]
            if tail:
                records.append((letter, tail, index, position + 1))
            elif index + 1 < len(flags):
                records.append((letter, flags[index + 1], index + 1, None))
                index += 1
            else:
                records.append((letter, None, None, None))
            break
        index += 1
    return records


def mask_upstream_credentials(flags):
    """Blank every credential-bearing value in an argv list.

    Returns the masked list and the warnings the masking earned.  Masking is
    not the point -- the warning is.  This project's own invocation never
    puts a credential on a command line at all, so anything found here means
    something drove upstream the other way, and a silent replacement would
    turn a real defect into a clean-looking document.
    """
    masked = list(flags)
    warnings = []
    for letter, value, value_index, tail_offset in scan_upstream_argv(masked):
        if letter not in UPSTREAM_SECRET_OPTS:
            continue
        if value is None:
            warnings.append(
                "upstream was invoked with -%s and nothing followed it: "
                "there was no value to replace, and this project's own "
                "invocation never passes -%s at all" % (letter, letter))
            continue
        if tail_offset is None:
            masked[value_index] = MASK
        else:
            masked[value_index] = masked[value_index][:tail_offset] + MASK
        warnings.append(
            "upstream was invoked with -%s: %s reached a command line, "
            "which this project's own invocation never does"
            % (letter, SECRET_OPT_SUBJECT[letter]))
    return masked, warnings


def flag_value(flags, name):
    """The value upstream's getopts would have read for one option.

    Used to read facts back out of the argv that was actually used, rather
    than out of a second field somebody has to remember to keep in step with
    it.  The LAST occurrence wins, because upstream assigns its variable on
    every pass of its own getopts loop and the last assignment is the one
    the box ends up running.  An option with nothing after it yields None.
    """
    letter = name.lstrip("-")
    found = None
    for opt_letter, value, _value_index, _tail_offset in \
            scan_upstream_argv(flags):
        if opt_letter == letter and value is not None:
            found = value
    return found


TIERS = ("supported", "legacy", "unsupported", "unknown")


def as_tier(value):
    """One of the four matrix tiers, or `unknown`.

    `unknown` is a real answer and the safe default: it says nothing measured
    the box against the matrix, which is different from measuring it and
    finding it unsupported.
    """
    text = str(value).strip().lower() if value is not None else ""
    return text if text in TIERS else "unknown"


args = sys.argv[1:]
if len(args) != 8:
    fail("wrong number of inputs (%d)" % len(args))
kv_path, public_path, sources_path, preflight_path, host_path, deps_path, \
    report_path, out_path = args

# A hard refusal rather than a convention.  merged.json is the ONE document
# that holds the supplied credentials; nothing in this file may open it, and a
# future edit that wires the wrong path in should stop here rather than write
# a password into the artefact everybody keeps.
for candidate in (public_path, sources_path, preflight_path, host_path,
                  deps_path, report_path):
    if candidate and os.path.basename(candidate) == "merged.json":
        fail("refusing to read merged.json: it holds the supplied secrets")

scalars = {}
lists = {name: [] for name in LIST_KEYS}
ports = {}
if kv_path and os.path.isfile(kv_path):
    try:
        with open(kv_path, "r", encoding="utf-8") as handle:
            for raw in handle:
                raw = raw.rstrip("\n")
                if not raw:
                    continue
                key, _, value = raw.partition("\t")
                if key.startswith("port."):
                    number = as_int(value)
                    if number is not None:
                        ports[key[5:]] = number
                elif key in lists:
                    if value != "":
                        lists[key].append(value)
                else:
                    scalars[key] = value
    except Exception as exc:  # noqa: BLE001 -- reported, never raised further
        fail("cannot read %s: %s" % (kv_path, exc.__class__.__name__))

public = load_json(public_path) or {}
sources = load_json(sources_path) or {}
host = load_json(host_path)
deps = load_json(deps_path)
report = load_json(report_path)
if not isinstance(public, dict):
    public = {}
if not isinstance(sources, dict):
    sources = {}
if not isinstance(report, dict):
    report = None

started = scalars.get("started_at", "")
finished = scalars.get("finished_at", "")
duration = None
try:
    duration = int(
        (datetime.strptime(finished, TS_FMT)
         - datetime.strptime(started, TS_FMT)).total_seconds()
    )
except Exception:
    duration = None

# --- config -----------------------------------------------------------------
# public.json is the merged document with the secret-typed keys REMOVED, so a
# key that sources.json knows about and public.json does not is exactly a
# supplied secret.  Its entry carries no value member, and there is no value
# available here to put in one even by mistake.
config = {}
for key in list(public.keys()) + [k for k in sources if k not in public]:
    if key in config:
        continue
    origin = sources.get(key)
    if not isinstance(origin, dict):
        origin = {}
    source = origin.get("source", "default")
    detail = origin.get("detail")
    if key in public:
        entry = {"value": public[key], "source": source}
        if detail:
            entry["detail"] = detail
    else:
        entry = {"secret": True, "supplied": True, "source": source}
    config[key] = entry

# --- host -------------------------------------------------------------------
# `supported` is the old single-tier boolean and it is kept, because it is what
# preflight actually measured: does this box match a row of support-matrix.yml.
# `matrix_tier` is the question that boolean can no longer answer on its own.
#
# The matrix has two tiers.  SUPPORTED is whatever the PINNED upstream ref's
# own gate accepts, and it is derived from the pin rather than asserted, so it
# cannot be read off support-matrix.yml at all.  LEGACY is the older releases
# that file lists: reachable by pinning an older ref, documented, and never
# claimed as tested.  Upstream's gate has no override, and forcing past OUR
# preflight cannot touch it.
#
# So: use what preflight recorded if it recorded anything.  Otherwise derive
# the weakest true statement -- a matrix row match today means the LEGACY tier,
# because the supported tier is a property of a pin this run may not even have
# -- and say `unknown` when nothing measured it.  Preflight owns this fact and
# should write `matrix_tier` into host.json; the derivation below is a fallback
# that must not quietly promote a box into the tested tier.
host_obj = None
if isinstance(host, dict):
    if host.get("matrix_tier") is not None:
        matrix_tier = as_tier(host.get("matrix_tier"))
    elif host.get("supported") is None:
        matrix_tier = "unknown"
    elif as_bool(host.get("supported")):
        matrix_tier = "legacy"
    else:
        matrix_tier = "unsupported"
    host_obj = {
        "os_id": host.get("os_id"),
        "os_version": host.get("os_version_id", host.get("os_version")),
        "supported": as_bool(host.get("supported")),
        "matrix_tier": matrix_tier,
        "forced": as_bool(host.get("forced")),
        "arch": host.get("arch"),
        "memory_mb": as_int(host.get("memory_mb")),
        "cpus": as_int(host.get("cpus")),
        "disk_free_gb": host.get("disk_free_gb") or {},
        "max_map_count": as_int(host.get("max_map_count")),
    }

# --- ansible ----------------------------------------------------------------
# lib/deps.sh is the only writer of this object.  The play must not report its
# own version: it does not run at all on the paths where this matters most.
ansible_obj = None
if isinstance(deps, dict):
    ansible_obj = {
        "source": deps.get("source"),
        "core_version": deps.get("core_version"),
        "collections": deps.get("collections") or {},
    }

# --- preflight --------------------------------------------------------------
preflight = []
if preflight_path and os.path.isfile(preflight_path):
    try:
        with open(preflight_path, "r", encoding="utf-8") as handle:
            for raw in handle:
                raw = raw.rstrip("\n")
                if not raw:
                    continue
                fields = raw.split("\t")
                while len(fields) < 3:
                    fields.append("")
                preflight.append({
                    "id": fields[0],
                    "status": fields[1],
                    "detail": fields[2],
                })
    except Exception:
        preflight = []

# --- what the play reported -------------------------------------------------
upstream_obj = None
driver_obj = None
accounts_obj = None
verification = []
report_warnings = []
already_installed = as_bool(scalars.get("already_installed"), False)
reboot_required = as_bool(scalars.get("reboot.required"), False)
if report is not None:
    upstream_obj = report.get("upstream")
    driver_obj = report.get("driver")
    accounts_obj = report.get("accounts")
    if isinstance(report.get("verification"), list):
        for record in report["verification"]:
            if not isinstance(record, dict):
                continue
            status = record.get("status")
            # A check that did not run is skipped with a reason, never pass.
            verification.append({
                "id": record.get("id"),
                "phase": record.get("phase"),
                "status": status,
                "reason": record.get("reason"),
            })
    if isinstance(report.get("warnings"), list):
        report_warnings = [str(w) for w in report["warnings"]]
    if "reboot_required" in report:
        reboot_required = as_bool(report.get("reboot_required"),
                                  reboot_required)
    if "already_installed" in report:
        already_installed = as_bool(report.get("already_installed"),
                                    already_installed)

# --- driver -----------------------------------------------------------------
# Shaped for the ONE invocation this product has: upstream's own unattended
# mode, driven natively.  There is no second driver and no selector variable.
#
# The field list below is a WHITELIST, not a formatting preference.  This
# object has a fixed shape, and an earlier design of this installer -- since
# deleted -- carried per-prompt bookkeeping fields here that mean nothing now.
# Building the object from a declared list rather than from whatever arrived
# means no such field can return to the artefact by accident; anything else
# the play sends is dropped, and the drop is reported on stderr so it is a
# visible decision rather than a silent loss.
#
# `upstream_install_type` is read back out of the argv that was actually used,
# and it is NOT the same fact as the configured `tpot_install_type` in the
# config object.  Upstream is always told the SENSOR type, because that is the
# one type whose code path never enters its credential branch; the configured
# type selects which compose file this project copies over
# `docker-compose.yml` afterwards.  Reporting only one of the two would hide
# the difference, and the difference is the whole reason no credential ever
# reaches a command line.
#
# The credential pass is therefore not a redaction that is expected to fire.
# Our invocation never puts a credential on a command line at all, so a "-u"
# or a "-p" arriving here means something drove upstream the other way: the
# value is replaced AND a warning says so, because a silent success would
# hide a real defect behind a clean-looking document.
#
# `flags` has a writer now: roles/tpot_install builds the argv it hands
# upstream out of one list, and roles/report sends that same list -- not a
# second copy somebody has to keep in step with it.  What it holds is
# `-s -t <type> -b <ref> -r <url>`, plus whatever tpot_upstream_extra_flags
# adds, so the pass is fed and is still not expected to fire.  That role
# refuses `-u` and `-p` as extra flags before it builds the vector, which is
# the first line of defence and not the last: it compares whole elements, so
# an ATTACHED value walks past it and arrives here.  This pass is what reads
# it the way getopts would.  It has never fired, and nothing has exercised it
# either: no run has reached the play at all.  The masking was written before
# its feeder existed and that ordering was deliberate -- SECURITY.md tells a
# vulnerability reporter that result.json holds no credential and invites them
# to attach it, so this has to be right before the first run that could test
# it, not after.
#
# It reads the list the way upstream's own getopts reads it, which is the
# defect the first version had: it recognised only a value written as a
# separate element, and let an attached or clustered one through in clear
# text with no warning at all.  See `scan_upstream_argv` above for the shapes
# and for what was measured.
DRIVER_FIELDS = ("name", "rc", "duration_s", "flags", "upstream_install_type")

driver_warnings = []
driver_flags = []
if isinstance(driver_obj, dict):
    for field in list(driver_obj):
        if field not in DRIVER_FIELDS:
            del driver_obj[field]
            sys.stderr.write(
                "result: dropped the undeclared driver field %s\n" % field)
    if not driver_obj.get("name"):
        driver_obj["name"] = "native"
    if isinstance(driver_obj.get("flags"), list):
        driver_flags = [str(f) for f in driver_obj["flags"]]
        driver_flags, flag_warnings = mask_upstream_credentials(driver_flags)
        driver_warnings.extend(flag_warnings)
        driver_obj["flags"] = driver_flags
    driver_obj["upstream_install_type"] = flag_value(driver_flags, "-t")
    # Declared order, so two artefacts from two runs read the same way.
    driver_obj = {field: driver_obj[field]
                  for field in DRIVER_FIELDS if field in driver_obj}

# --- upstream ---------------------------------------------------------------
# One variable pins two different things and they are reported apart, so that
# a reader can see whether they agree:
#
#   ref          the pin this run was asked for
#   url          where install.sh -- the ENTRYPOINT -- was fetched from
#   payload_ref  what upstream received as its own -b flag, which pins only
#                the playbook upstream then clones
#
# Upstream never re-fetches or re-execs itself, so its distribution gate, its
# port check and its sudo handling are whatever copy was executed, while -b
# governs the payload alone.  With no -b, and run outside a git work tree --
# exactly how a fetched-and-executed install.sh runs -- upstream falls back to
# its own default branch, silently.  `ref_consistent` is the field that says
# whether this box is running the ref this document names; null means there
# was not enough information to tell, which is not the same as yes.
if isinstance(upstream_obj, dict):
    up_ref = upstream_obj.get("ref") or ""
    up_url = upstream_obj.get("url") or ""
    payload_ref = upstream_obj.get("payload_ref") or flag_value(
        driver_flags, "-b")
    ref_consistent = None
    if up_ref and payload_ref:
        ref_consistent = bool(
            payload_ref == up_ref
            and (not up_url or ("/%s/" % up_ref) in up_url)
        )
    elif up_ref and driver_flags:
        # Upstream ran and received no -b at all.  That is not an unknown: it
        # is the documented silent fallback to upstream's own default branch,
        # so the payload is definitely NOT the ref named above.  Saying null
        # here would round a known mismatch up to "cannot tell".
        ref_consistent = False
    upstream_obj = {
        "url": up_url or None,
        "ref": up_ref or None,
        "repo_url": upstream_obj.get("repo_url"),
        "sha256": upstream_obj.get("sha256"),
        # Our own sha256 of the fetched install.sh.  It is not replaced by
        # upstream's -b: -b pins the payload, this pins the entrypoint.
        "verified": (as_bool(upstream_obj.get("verified"))
                     if "verified" in upstream_obj else None),
        "payload_ref": payload_ref or None,
        "ref_consistent": ref_consistent,
        # FALSE, and it stays false.  Pinning a ref pins the recipe and never
        # the images: T-Pot's own TPOT_PULL_POLICY defaults to `always`, so it
        # re-pulls its container images every time it starts.  The software
        # running on this box therefore changes after we verified it, and it
        # keeps changing on every reboot -- including the daily one upstream's
        # playbook installs in root's crontab.  This flag is the honest name
        # for that gap, not a to-do item.
        "pins_payload": False,
    }

warnings = []
for item in lists["warning"] + report_warnings + driver_warnings:
    if item and item not in warnings:
        warnings.append(item)

document = {
    "schema": SCHEMA,
    "tool_version": scalars.get("tool_version", ""),
    "run_id": scalars.get("run_id", ""),
    "outcome": scalars.get("outcome", "internal_error"),
    "exit_code": as_int(scalars.get("exit_code"), 40),
    "exit_name": scalars.get("exit_name"),
    "started_at": started,
    "finished_at": finished,
    "duration_seconds": duration,
    "invocation": {
        "mode": scalars.get("mode", "install"),
        "non_interactive": as_bool(scalars.get("non_interactive")),
        "json": as_bool(scalars.get("json")),
        "forced": lists["forced"],
    },
    "host": host_obj,
    "config": config,
    "ansible": ansible_obj,
    "upstream": upstream_obj,
    "driver": driver_obj,
    "accounts": accounts_obj,
    "preflight": preflight,
    "verification": verification,
    "reboot": {
        "required": reboot_required,
        "performed": as_bool(scalars.get("reboot.performed")),
        "post_boot_verify_armed": as_bool(
            scalars.get("reboot.post_boot_verify_armed")),
    },
    "already_installed": already_installed,
    "ports": ports,
    "warnings": warnings,
    "errors": lists["error"],
    "log": scalars.get("log", ""),
    "notice": lists["notice"],
}

# Last line of defence.  If a secret-typed entry ever acquired a value member,
# drop it and say so on stderr rather than write the file as it stands.
for key, entry in document["config"].items():
    if isinstance(entry, dict) and entry.get("secret") and "value" in entry:
        del entry["value"]
        sys.stderr.write(
            "result: dropped a value from the secret entry %s\n" % key)

flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
descriptor = os.open(out_path, flags, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(document, handle, indent=2, ensure_ascii=True, sort_keys=False)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
TPOT_RESULT_PY

    if [[ -z $rundir || ! -d $rundir ]]; then
        rm -f -- "$kv" 2>/dev/null || true
    fi

    if (( rc != 0 )); then
        rm -f -- "$tmp_out" 2>/dev/null || true
        _tpot_res_warn 'result.json could not be serialised (python exit %s)' "$rc"
        return 1
    fi

    chmod 0600 -- "$tmp_out" 2>/dev/null || true
    if [[ $(id -u 2>/dev/null || printf '1') == '0' ]]; then
        chown root:root -- "$tmp_out" 2>/dev/null || true
    fi
    mv -f -- "$tmp_out" "$dest" || {
        _tpot_res_warn 'cannot place %s' "$dest"
        return 1
    }
    return 0
}

# ---------------------------------------------------------------------------
# res_exit_trap
#   The EXIT handler install.sh installs. Preserves the code the shell is
#   already exiting with, writes the document, and returns -- it must never
#   change the exit status, because the status IS the contract.
# ---------------------------------------------------------------------------
res_exit_trap() {
    local code=$?
    [[ -n ${TPOT_EXIT_CODE:-} ]] && code=$TPOT_EXIT_CODE
    res_write "$code" || true
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_res_warn FMT [ARGS...]
#   Report through lib/log.sh when it is loaded (so the message is redacted
#   and lands in the transcript), and to stderr when it is not. result.sh is
#   usable without log.sh; the tests source it alone.
# ---------------------------------------------------------------------------
_tpot_res_warn() {
    if declare -F log_warn >/dev/null 2>&1; then
        log_warn "$@"
        return 0
    fi
    local fmt=${1-}
    if (( $# > 1 )); then shift; else shift $#; fi
    local msg
    # shellcheck disable=SC2059  # printf-style API, as log_warn's
    printf -v msg -- "$fmt" "$@"
    printf 'WARN: %s\n' "$msg" >&2
    return 0
}
