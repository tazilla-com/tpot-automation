#!/usr/bin/env bash
#
# tools/pin-upstream.sh -- pin an upstream T-Pot ref, and derive everything
#                          that follows from it.
#
# WHY THIS FILE EXISTS
#   One value decides almost everything this installer does. tpot_upstream_ref
#   names the install.sh that gets fetched and verified, it is handed straight
#   back to that installer as the ref of the payload it clones (D-10), and --
#   because upstream gates on /etc/os-release before it reads any flag -- it
#   also decides which distribution releases this project may call supported
#   (D-07). Three facts, one variable, and they may never be set apart.
#
#   Everything that follows from the ref is therefore MEASURED here, once, at
#   pin time, and written into files. Nothing downstream guesses:
#
#     * the sha256 of upstream's install.sh at that ref, which is the only
#       thing standing between this installer and running whatever bytes the
#       network handed it with passwordless sudo;
#     * how many containers a healthy T-Pot has, per edition, which neither
#       upstream file states anywhere and which verification compares against;
#     * which install types that ref knows about, and which compose file each
#       one copies;
#     * the supported tier of support-matrix.yml, and the ref it came from.
#
# WHAT IT IS NOT
#   It is NOT part of an install. It is run by a maintainer, on a machine with
#   network access, in a checkout of this repository, and its output is a diff
#   to be read and committed. It never touches a host being installed, it
#   never needs root, and install.sh never calls it. If you are looking for
#   something to run on the honeypot, this is the wrong file.
#
# WHAT IT WRITES -- TWO FILES, AND THEY MOVE TOGETHER
#
#   roles/tpot_install/vars/upstream-<ref>.yml
#       The per-ref data file. roles/tpot_install loads it by name and reads
#       the sha256, the telemetry service and the install types out of it; the
#       container counts and the gate are recorded there for verification and
#       for preflight. GENERATED. Never edited by hand.
#
#   support-matrix.yml
#       Exactly two keys in it -- tpot_support_matrix_supported and
#       tpot_support_matrix_supported_ref -- rewritten in place, in the same
#       edit, with every comment and the whole legacy tier untouched. The
#       invariant tests/check-matrix-parse.sh asserts is that those two are
#       empty together or non-empty together, so nothing here writes one
#       without the other.
#
# THE DERIVATION, WHICH IS THE PART THAT IS SUBTLER THAN IT LOOKS
#
#       supported = (what the pinned ref's own gate accepts)
#                     INTERSECTED WITH
#                   (what this installer can drive at all)
#                     MINUS
#                   (releases nobody here has ever installed T-Pot on)
#
#   The first two halves are the formula support-matrix.yml states. The third
#   is stated in that file's prose and omitted from its formula, and leaving
#   it implicit is how the wrong answer gets shipped: without it the formula
#   yields THREE rows at the commit this tree pins, because Raspberry Pi OS
#   passes upstream's gate and is apt-based. The intended answer is two. So
#   the exclusion is a TABLE below with a reason per row, not an accident of
#   which fixtures happen to exist -- see _PIN_NEVER_INSTALLED_WHY.
#
#   The first two halves are read out of upstream's own source at the ref
#   being pinned, never from a table here:
#
#     accepted names   the mySUPPORTED_DISTRIBUTIONS array (install.sh:295 at
#                      the commit this tree pins)
#     version per name the case block on ${myCURRENT_DISTRIBUTION} that sets
#                      mySUPPORTED_VERSION (install.sh:310-331). Note the
#                      asymmetry it encodes: the Debian family is compared on
#                      the MAJOR only, Ubuntu on the full VERSION_ID, and both
#                      comparisons are exact string inequality -- there is no
#                      ordering and no override flag.
#     drivable by us   the SECOND case block, the one that installs packages
#                      (install.sh:412-484). Whether upstream reaches for apt,
#                      dnf, yum or zypper on a given distribution is upstream's
#                      own statement about that distribution, and our preflight
#                      hard-requires apt-get (lib/preflight.sh:1149-1158). So
#                      "can this installer drive it" is read from upstream too,
#                      rather than being a second opinion that can drift.
#
#   ONE TABLE IS OURS AND HAS TO BE. Upstream matches on the NAME field of
#   /etc/os-release; support-matrix.yml matches on ID, because ID is the field
#   the specification calls machine-readable and stable. Nothing derives one
#   from the other, so _PIN_ID_OF below maps them by hand -- and a NAME with
#   no row there is a hard failure, not a silent omission. Guessing an ID from
#   a NAME is how a release quietly stops being claimed, or quietly starts.
#
#   OUR ARCHITECTURE CHECK does not filter rows and is not applied here: it
#   accepts x86_64 and aarch64 (lib/preflight.sh:215) and that is a property
#   of the box, not of the release. It is mentioned because it is the second
#   half of the sentence "what this installer can drive": a supported row is
#   not a promise about every machine that release runs on.
#
# WHAT A DERIVED ROW IS AND IS NOT
#   A row in the supported tier says: the pinned ref's own gate accepts this
#   release, and this installer could drive it. It does NOT say anybody ran
#   it. The evidence for that is a dated run per (ref x release) pair in
#   tests/MATRIX-STATUS.md, an undated row there blocks a release tag, and
#   this tool prints that sentence every time it writes a row precisely
#   because the tier it fills in is the one whose name invites the other
#   reading.
#
# USAGE
#
#     tools/pin-upstream.sh <ref>
#     tools/pin-upstream.sh --repo /path/to/tpotce <ref>
#     tools/pin-upstream.sh --dry-run <ref>
#
#   <ref> is the upstream commit to pin: a FULL 40-character lowercase sha.
#   Abbreviated is refused, and so are master, main and HEAD -- see
#   _pin_check_ref for the two failures each of those causes and why neither
#   of them looks like the ref.
#
# EXIT
#   0   the derivation succeeded; files were written, or --dry-run printed
#   10  usage error. 10 is EX_USAGE in lib/exitcodes.sh, which this script
#       deliberately does not source: it depends on nothing in lib/ except
#       lib/matrix.sh, and that only to check its own output afterwards
#   1   the derivation failed, or a file could not be written. NOTHING is
#       left half-written: both files are written to a temporary beside the
#       target and moved into place, and the matrix is re-read afterwards
#
# NOTHING HERE HAS EVER FETCHED ANYTHING OVER A NETWORK. The box this tool was
# written on has none. The pin committed to this tree was produced with
# --repo, from a local clone, and the network path is specified rather than
# exercised. Anything it claims about curl or wget is read from their manuals,
# not measured.

set -uo pipefail

_PIN_TOOL_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
_PIN_REPO_DIR=$(cd -- "${_PIN_TOOL_DIR}/.." && pwd)
readonly _PIN_TOOL_DIR _PIN_REPO_DIR

readonly _PIN_MATRIX_FILE="${_PIN_REPO_DIR}/support-matrix.yml"
readonly _PIN_MATRIX_LIB="${_PIN_REPO_DIR}/lib/matrix.sh"
readonly _PIN_SCHEMA_FILE="${_PIN_REPO_DIR}/lib/varschema.json"
readonly _PIN_VARS_DIR="${_PIN_REPO_DIR}/roles/tpot_install/vars"

# The two keys rewritten in support-matrix.yml, spelled once. lib/matrix.sh
# holds the same two strings and tests/check-matrix-parse.sh proves the two
# readers agree; if one of these is ever renamed, both files change together.
readonly _PIN_KEY_SUPPORTED='tpot_support_matrix_supported'
readonly _PIN_KEY_REF='tpot_support_matrix_supported_ref'

# The service removed from every compose file before the containers are
# counted (D-09: upstream's telemetry is off by default, and there is no .env
# key for it -- the service block goes). The count written into the data file
# is therefore the count of a T-Pot as THIS installer leaves it, which is what
# verification compares a running box against. Overridable because a future
# ref may rename the service; the tool refuses to write a count if the name it
# was given is not actually in the compose files, because "removed nothing"
# and "removed one" differ by exactly one container and by nothing visible.
readonly _PIN_TELEMETRY_DEFAULT='ewsposter'

# ---------------------------------------------------------------------------
# NAME (upstream, /etc/os-release NAME) -> ID (ours, /etc/os-release ID).
#
# The one table in this file that is not read from upstream, because nothing
# derives it: upstream compares the NAME field and support-matrix.yml compares
# the ID field, and the two are different strings for the same distribution.
# A NAME arriving from upstream with no row here stops the run. That is
# deliberate -- the alternative is a release that upstream started accepting
# and this tool silently dropped, which nobody would ever see.
#
# The values are the lower-case ID each distribution actually publishes.
# ---------------------------------------------------------------------------
declare -A _PIN_ID_OF=(
    ["AlmaLinux"]="almalinux"
    ["Debian GNU/Linux"]="debian"
    ["Fedora Linux"]="fedora"
    ["Raspbian GNU/Linux"]="raspbian"
    ["Red Hat Enterprise Linux"]="rhel"
    ["Rocky Linux"]="rocky"
    ["Ubuntu"]="ubuntu"
    ["openSUSE Tumbleweed"]="opensuse-tumbleweed"
)

# ---------------------------------------------------------------------------
# THE THIRD FILTER. Releases upstream accepts, that this installer could
# technically drive, and that are still not rows we may claim -- because
# nobody here has ever installed T-Pot on one.
#
# It is a table with a reason per row rather than a judgement made at the
# point of use, so that the exclusion survives somebody re-reading this file
# in a year and so that removing a row is a deliberate act with a date on it.
# Empty the entry and the release becomes claimable the moment a run is dated
# in tests/MATRIX-STATUS.md.
# ---------------------------------------------------------------------------
declare -A _PIN_NEVER_INSTALLED_WHY=(
    ["raspbian"]="no T-Pot has ever been installed on Raspberry Pi OS by this project, and the match rule forbids folding it into debian through ID_LIKE. Upstream's own Raspbian path also looks broken at this pin -- its gate wants major 13 and download.docker.com/linux/raspbian publishes no trixie suite, a 404 checked 2026-09-04 -- but that is a second reason, not the reason. Delete this row when a real run is dated in tests/MATRIX-STATUS.md, not before"
)

# ---------------------------------------------------------------------------
# Small output helpers. Everything diagnostic goes to stderr so that stdout
# stays the derivation report a maintainer reads in a terminal or redirects.
# ---------------------------------------------------------------------------
_pin_say()  { printf '%s\n' "$*"; }
_pin_note() { printf 'pin-upstream: %s\n' "$*" >&2; }
_pin_warn() { printf 'pin-upstream: WARNING: %s\n' "$*" >&2; }

_pin_die() {
    printf 'pin-upstream: %s\n' "$1" >&2
    exit 1
}

_pin_usage_die() {
    printf 'pin-upstream: %s\n' "$1" >&2
    printf "Run 'tools/pin-upstream.sh --help' for what it takes and what it writes.\n" >&2
    exit 10
}

_pin_usage() {
    cat <<'USAGE'
usage: tools/pin-upstream.sh [options] <ref>

Pin an upstream T-Pot ref and derive everything that follows from it. Run by a
maintainer on a machine with network access, in a checkout of this repository.
It is not part of an install and never runs on a host being installed.

  <ref>                  the upstream commit to pin: a FULL 40-character
                         lowercase sha. Abbreviated shas, master, main and
                         HEAD are refused

  --repo DIR             read the ref out of a local clone of upstream T-Pot
                         (git -C DIR show <ref>:<path>) instead of fetching it
                         over the network. The clone must already contain the
                         commit; this tool never fetches into it
  --telemetry-service N  the service block removed before containers are
                         counted (default: ewsposter). Only for a future ref
                         that renames it
  --dry-run              derive and print the report; write nothing
  --allow-non-sha        accept a ref that is not a 40-character sha. The play
                         itself will refuse it, so this is for inspecting a
                         tag, not for pinning one
  -h, --help             this text

It writes exactly two things, and they move together:

  roles/tpot_install/vars/upstream-<ref>.yml   the per-ref data file: the
      sha256 of upstream's install.sh, the container count per install type
      measured from that ref's compose files with the telemetry service
      removed, the telemetry service name, the install types the ref knows,
      and the distribution gate it applies
  support-matrix.yml   its tpot_support_matrix_supported tier and the
      tpot_support_matrix_supported_ref it was derived from, rewritten in
      place in one edit. Every comment and the whole legacy tier are left
      exactly as they were

The supported tier is derived as: what the pinned ref's own gate accepts,
intersected with what this installer can drive (apt-get only), minus releases
nobody here has ever installed T-Pot on. A row it writes says upstream would
accept the release and this installer could drive it. IT DOES NOT SAY ANYBODY
RAN IT -- that evidence is a dated run per (ref x release) pair in
tests/MATRIX-STATUS.md, and an undated row there blocks a release tag.

Read the diff before committing it. Both files are the product's claims about
what it will do to somebody's machine.
USAGE
}

# ---------------------------------------------------------------------------
# _pin_check_ref REF
#   Refuse a ref that will fail later in a way that does not look like the ref.
#
#   * master, main and HEAD are branches. Pinning a branch pins nothing: the
#     entrypoint fetched today and the payload cloned tomorrow are different
#     code, and lib/varschema.json's own pattern refuses all three.
#   * an ABBREVIATED sha installs correctly ONCE and then makes every re-run
#     exit 1: ansible.builtin.git leaves HEAD at the full sha and upstream's
#     check_tpot_clone compares that against the string it was given.
#   * a ref containing a slash or a space cannot be a file name, and the data
#     file is looked up BY NAME (upstream-<ref>.yml) by roles/tpot_install.
#   * anything that is not 40 lowercase hex is refused unless --allow-non-sha,
#     because roles/tpot_install/vars/main.yml holds the play to '^[0-9a-f]{40}$'
#     and would refuse it on the box, an hour after this tool said it was fine.
# ---------------------------------------------------------------------------
_pin_check_ref() {
    local ref=$1 allow_non_sha=$2

    if [[ -z $ref ]]; then
        _pin_usage_die "no ref given. It is the one argument this tool takes."
    fi
    case $ref in
        master|main|HEAD)
            _pin_usage_die "'${ref}' is a branch, not a ref. A branch pins nothing: the install.sh fetched today and the payload cloned tomorrow would be different code. lib/varschema.json refuses it too."
            ;;
    esac
    if [[ $ref =~ [^A-Za-z0-9._+-] ]]; then
        _pin_usage_die "'${ref}' contains a character that cannot appear in a file name, and the per-ref data file is looked up by name as upstream-<the ref>.yml."
    fi
    if [[ $ref =~ ^[0-9a-fA-F]{7,39}$ ]]; then
        _pin_usage_die "'${ref}' looks like an abbreviated sha. Use the full 40 characters: git leaves HEAD at the full sha, so upstream's own re-run check compares your short string against the long one and exits 1 on every second run."
    fi
    if [[ ! $ref =~ ^[0-9a-f]{40}$ ]]; then
        if (( allow_non_sha == 0 )); then
            _pin_usage_die "'${ref}' is not a full 40-character lowercase commit sha. roles/tpot_install/vars/main.yml holds the play to exactly that shape, so a tag pinned here is refused on the box an hour into a run. Pass --allow-non-sha only to INSPECT a tag; do not commit the result."
        fi
        _pin_warn "'${ref}' is not a 40-character sha. roles/tpot_install/vars/main.yml will refuse it at run time. This report is for inspection only; do not commit it."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _pin_entrypoint_url REF
#   The URL upstream's install.sh is fetched from, for this ref.
#
#   READ OUT OF lib/varschema.json RATHER THAN RESTATED. That file's
#   default_format for tpot_upstream_url is what the configuration merge uses
#   to derive the URL the PLAY fetches from, and the sha256 recorded here is
#   only meaningful for the bytes at that URL. Two copies of the same URL
#   template is precisely the kind of near-duplicate that goes wrong quietly,
#   so there is one, and it lives with the schema.
#
#   A missing or unreadable schema is a hard failure rather than a fallback to
#   a constant. A built-in default would produce a checksum for whatever this
#   tool happened to fetch, under a ref the play would fetch from somewhere
#   else, and nothing would ever say so.
# ---------------------------------------------------------------------------
_pin_entrypoint_url() {
    local ref=$1 fmt=''
    local -a hits=()

    if [[ ! -r $_PIN_SCHEMA_FILE ]]; then
        _pin_die "lib/varschema.json is not readable, so the URL upstream's installer is fetched from cannot be read. That template is the schema's, not this tool's."
    fi
    mapfile -t hits < <(grep -o '"default_format"[[:space:]]*:[[:space:]]*"[^"]*install\.sh"' -- "$_PIN_SCHEMA_FILE")
    if (( ${#hits[@]} != 1 )); then
        _pin_die "lib/varschema.json holds ${#hits[@]} default_format entries ending in install.sh; exactly one (tpot_upstream_url's) was expected. Read it and say which is meant before pinning anything."
    fi
    fmt=${hits[0]#*: }
    fmt=${fmt#\"}
    fmt=${fmt%\"}
    if [[ $fmt != *"{tpot_upstream_ref}"* ]]; then
        _pin_die "the URL template in lib/varschema.json does not contain {tpot_upstream_ref}: '${fmt}'. It cannot be a per-ref URL."
    fi
    printf '%s\n' "${fmt//\{tpot_upstream_ref\}/$ref}"
}

# ---------------------------------------------------------------------------
# _pin_raw_url REF PATH
#   Any other file at the same ref, from the same host and repository as the
#   entrypoint. Derived by chopping "install.sh" off the entrypoint URL, so
#   the compose files are provably fetched from the same place as the script
#   whose sha256 is being recorded.
# ---------------------------------------------------------------------------
_pin_raw_url() {
    local ref=$1 path=$2 url base
    url=$(_pin_entrypoint_url "$ref") || exit 1
    base=${url%install.sh}
    if [[ $base == "$url" ]]; then
        _pin_die "the URL template does not end in install.sh, so no sibling path can be derived from it: '${url}'"
    fi
    printf '%s%s\n' "$base" "$path"
}

# ---------------------------------------------------------------------------
# _pin_fetch REF PATH DEST
#   Put one file from upstream at REF into DEST. Either out of a local clone,
#   which is what --repo is for and what produced the pin in this tree, or
#   over the network.
#
#   THE LOCAL PATH IS git show, NOT a checkout. It reads the blob at that
#   exact commit without touching the clone's working tree or its HEAD, so
#   pointing --repo at a clone somebody is working in cannot disturb them and
#   cannot silently read their uncommitted edits.
#
#   THE NETWORK PATH IS SPECIFIED, NOT MEASURED. The box this was written on
#   has no network. curl is preferred for its non-zero exit on an HTTP error
#   (--fail), which a naive wget invocation does not give; both are pinned to
#   https by their arguments so that a redirect cannot downgrade the transport
#   carrying the bytes whose checksum is about to become a security control.
# ---------------------------------------------------------------------------
_pin_fetch() {
    local ref=$1 path=$2 dest=$3 repo=$4 url rc=0

    if [[ -n $repo ]]; then
        git -C "$repo" show "${ref}:${path}" > "$dest" 2>/dev/null || rc=$?
        if (( rc != 0 )); then
            _pin_die "git could not read ${path} at ${ref} in ${repo} (rc ${rc}). Fetch that commit into the clone first: this tool never fetches into it, so that a pin cannot depend on the state of somebody's working directory."
        fi
        return 0
    fi

    url=$(_pin_raw_url "$ref" "$path") || exit 1
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
             --max-time 60 --output "$dest" -- "$url" || rc=$?
        if (( rc != 0 )); then
            _pin_die "curl could not fetch ${url} (rc ${rc}). A 404 here usually means the ref does not exist upstream, or the file was renamed at that ref."
        fi
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget --quiet --https-only --timeout=60 --output-document="$dest" -- "$url" || rc=$?
        if (( rc != 0 )); then
            _pin_die "wget could not fetch ${url} (rc ${rc}). A 404 here usually means the ref does not exist upstream, or the file was renamed at that ref."
        fi
        return 0
    fi
    _pin_die "neither curl nor wget is on PATH, so nothing can be fetched. Install one, or use --repo with a local clone of upstream T-Pot."
}

# ---------------------------------------------------------------------------
# _pin_sha256 FILE
#   The sha256 of one file, as 64 lowercase hex characters and nothing else.
#   sha256sum first because that is what the boxes this project targets have;
#   shasum is the fallback for a maintainer on macOS.
# ---------------------------------------------------------------------------
_pin_sha256() {
    local file=$1 out=''
    if command -v sha256sum >/dev/null 2>&1; then
        out=$(sha256sum -- "$file" 2>/dev/null)
    elif command -v shasum >/dev/null 2>&1; then
        out=$(shasum -a 256 -- "$file" 2>/dev/null)
    else
        _pin_die "neither sha256sum nor shasum is on PATH. The checksum is the whole point of this tool; there is no sensible way to continue without one."
    fi
    out=${out%% *}
    if [[ ! $out =~ ^[0-9a-f]{64}$ ]]; then
        _pin_die "the checksum program returned something that is not 64 hex characters: '${out}'"
    fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# _pin_parse_install_sh FILE
#   Read upstream's distribution gate, its package-manager choice and its
#   install types out of one install.sh. Prints tab-separated records:
#
#     NAME <TAB> <upstream NAME>                    accepted by the gate
#     GATE <TAB> <NAME> <TAB> <version> <TAB> <major|full>
#     PKG  <TAB> <NAME> <TAB> <space-separated package managers>
#     TYPE <TAB> <letter> <TAB> <compose file stem>
#
#   ONE awk PASS, and it is deliberately literal about the shapes it accepts:
#   a case-arm label is a line of quoted names (or a bare *) separated by
#   pipes and ending in a close paren, at exactly two spaces of indent. A
#   sloppier pattern would match `sudo subscription-manager ... $(arch)-rpms`
#   inside an arm and start attributing package managers to the wrong
#   distribution. If upstream reformats, this stops matching and the caller
#   fails loudly on an empty result rather than deriving a short list.
# ---------------------------------------------------------------------------
_pin_parse_install_sh() {
    local file=$1
    awk '
        # --- the accepted NAMEs -------------------------------------------
        /^mySUPPORTED_DISTRIBUTIONS=\(/ {
            line = $0
            sub(/^[^(]*\(/, "", line)
            sub(/\).*$/, "", line)
            n = split(line, parts, /"/)
            for (i = 2; i <= n; i += 2) {
                if (parts[i] != "") printf "NAME\t%s\n", parts[i]
            }
        }

        # --- which case block are we in ------------------------------------
        # There are two on ${myCURRENT_DISTRIBUTION}: the first gates the
        # version, the second installs packages. They are told apart by
        # order, which is the only thing upstream gives us -- neither carries
        # a marker.
        /^case \$\{myCURRENT_DISTRIBUTION\} in/ { blk++; inblk = 1; nc = 0; next }
        /^esac/ { inblk = 0; nc = 0; next }

        # --- a case-arm label, in either block ------------------------------
        inblk && /^  ("[^"]*"|\*)(\|("[^"]*"|\*))*\)[[:space:]]*$/ {
            arm = $0
            sub(/^[[:space:]]*/, "", arm)
            sub(/\)[[:space:]]*$/, "", arm)
            n = split(arm, alts, /\|/)
            delete cur
            nc = 0
            for (i = 1; i <= n; i++) {
                a = alts[i]
                gsub(/"/, "", a)
                if (a != "" && a != "*") cur[++nc] = a
            }
            next
        }

        # --- block 1: the version gate --------------------------------------
        inblk && blk == 1 && nc > 0 && /mySUPPORTED_VERSION=/ {
            v = $0
            sub(/.*mySUPPORTED_VERSION="?/, "", v)
            sub(/".*$/, "", v)
            sub(/[[:space:]]*$/, "", v)
            for (i = 1; i <= nc; i++) ver_of[cur[i]] = v
        }
        # %%. is bash trimming VERSION_ID to its major; anything else is the
        # full VERSION_ID. That difference is the granularity of the row we
        # write, so it is recorded rather than assumed.
        inblk && blk == 1 && nc > 0 && /myCURRENT_VERSION=/ {
            cmp = ($0 ~ /%%\./) ? "major" : "full"
            for (i = 1; i <= nc; i++) cmp_of[cur[i]] = cmp
        }

        # --- block 2: which package manager upstream reaches for ------------
        inblk && blk == 2 && nc > 0 {
            if ($0 ~ /(^|[[:space:];&|"])apt([[:space:]]|-get[[:space:]])/) _add("apt")
            if ($0 ~ /(^|[[:space:];&|"])dnf[[:space:]]/)                   _add("dnf")
            if ($0 ~ /(^|[[:space:];&|"])yum[[:space:]]/)                   _add("yum")
            if ($0 ~ /(^|[[:space:];&|"])zypper[[:space:]]/)                _add("zypper")
        }

        # --- the install-type menu -------------------------------------------
        # An arm of the type case looks like `    h|H)`. The compose file it
        # copies is the authority on the edition, not the letter: h is
        # standard and i is mini, and nothing about the letters says so.
        /^[[:space:]]*[a-z]\|[A-Z]\)[[:space:]]*$/ {
            t = $0
            sub(/^[[:space:]]*/, "", t)
            letter = substr(t, 1, 1)
            next
        }
        letter != "" && /cp .*\/compose\/[A-Za-z0-9_.-]+\.yml/ {
            c = $0
            sub(/^.*\/compose\//, "", c)
            sub(/\.yml.*$/, "", c)
            if (!(letter in type_of)) {
                type_of[letter] = c
                order[++ntypes] = letter
            }
        }

        function _add(pm,   i) {
            for (i = 1; i <= nc; i++) {
                if (index(" " pm_of[cur[i]] " ", " " pm " ") == 0) {
                    pm_of[cur[i]] = (pm_of[cur[i]] == "") ? pm : pm_of[cur[i]] " " pm
                }
            }
        }

        END {
            for (k in ver_of) {
                if (k == "") continue
                printf "GATE\t%s\t%s\t%s\n", k, ver_of[k], (k in cmp_of ? cmp_of[k] : "none")
            }
            for (k in pm_of) {
                if (k == "") continue
                printf "PKG\t%s\t%s\n", k, pm_of[k]
            }
            for (i = 1; i <= ntypes; i++) {
                printf "TYPE\t%s\t%s\n", order[i], type_of[order[i]]
            }
        }
    ' < "$file"
}

# ---------------------------------------------------------------------------
# _pin_count_services FILE TELEMETRY
#   Count the service blocks in one compose file. Prints one tab-separated
#   record:
#
#     <services> <TAB> <telemetry blocks> <TAB> <restart lines> <TAB>
#     <restart: always lines> <TAB> <duplicate service names> <TAB>
#     <telemetry network present: 1|0>
#
#   WHY COUNTING SERVICE BLOCKS IS COUNTING CONTAINERS, AT THIS PIN. Every
#   service in every one of upstream's compose files declares
#   `restart: always`; none is a one-shot that runs and exits. So one service
#   block is one running container, and the caller ASSERTS that premise from
#   these numbers rather than trusting this comment -- if a future ref adds a
#   one-shot, the restart counts stop matching the service count and the tool
#   refuses to write a container count it can no longer justify.
#
#   A three-state walk, not a YAML parser: outside the services mapping,
#   inside it, and back out at the next column-zero key. Comment lines at
#   column zero are structure inside upstream's files -- there are banners
#   between the service blocks -- so they do not end the mapping.
# ---------------------------------------------------------------------------
_pin_count_services() {
    local file=$1 telemetry=$2
    awk -v telemetry="$telemetry" '
        # A column-zero line that is not a comment is a top-level key (or a
        # document marker). It ends whatever mapping was open, and starts the
        # services mapping when that is what it names.
        /^[^[:space:]#]/ {
            in_services = ($0 ~ /^services:[[:space:]]*(#.*)?$/) ? 1 : 0
            next
        }
        !in_services { next }

        # A service name: exactly two spaces, a name, a colon, nothing else.
        /^  [A-Za-z0-9][A-Za-z0-9._-]*:[[:space:]]*(#.*)?$/ {
            name = $0
            sub(/^[[:space:]]*/, "", name)
            sub(/:.*$/, "", name)
            if (name in seen) dupes++
            seen[name] = 1
            services++
            if (name == telemetry) telemetry_blocks++
            next
        }

        # The restart policy of the service block we are inside.
        /^    restart:/ {
            restarts++
            if ($0 ~ /^    restart:[[:space:]]*always[[:space:]]*(#.*)?$/) always++
        }

        END {
            printf "%d\t%d\t%d\t%d\t%d\n",
                   services + 0, telemetry_blocks + 0, restarts + 0, always + 0, dupes + 0
        }
    ' < "$file"
}

# ---------------------------------------------------------------------------
# _pin_has_network_key FILE NAME
#   Whether the top-level networks mapping declares NAME. Recorded because
#   roles/tpot_install removes the telemetry service's own network alongside
#   the service, composing the name as <service>_local -- upstream's
#   convention, declared nowhere -- and a data file that says whether that
#   name was actually present turns a silent no-op into something a reader
#   can check.
# ---------------------------------------------------------------------------
_pin_has_network_key() {
    local file=$1 name=$2
    awk -v want="$name" '
        /^[^[:space:]#]/ { in_networks = ($0 ~ /^networks:[[:space:]]*(#.*)?$/) ? 1 : 0; next }
        !in_networks { next }
        /^  [A-Za-z0-9][A-Za-z0-9._-]*:[[:space:]]*(#.*)?$/ {
            n = $0
            sub(/^[[:space:]]*/, "", n)
            sub(/:.*$/, "", n)
            if (n == want) found = 1
        }
        END { print (found ? 1 : 0) }
    ' < "$file"
}

# ---------------------------------------------------------------------------
# _pin_yaml_escape STRING
#   A double-quoted YAML scalar. Only backslash and double quote need
#   escaping inside one, and every string this tool writes is a ref, a URL, a
#   distribution name or a sentence of our own -- but the escape is done
#   rather than assumed, because the alternative is a generated file that does
#   not parse and a maintainer reading a YAML error instead of a diff.
# ---------------------------------------------------------------------------
_pin_yaml_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# ---------------------------------------------------------------------------
# _pin_yaml_field INDENT KEY VALUE
#   Write one `key: value` line of the generated data file, as a quoted scalar
#   when it fits and as a FOLDED block scalar (>-) when it does not.
#
#   The reasons this tool writes are sentences, and one of them is a
#   paragraph. A single 300-column line would be a yamllint line-length
#   warning in a file nobody typed, which trains a reader to ignore that
#   warning everywhere else. Folded is the right scalar because it means the
#   same string either way -- YAML folds the single newlines back into spaces
#   -- so the value roles/tpot_install would read does not depend on how wide
#   the sentence happened to be.
#
#   `fold -s` leaves the space it broke on at the END of the line, and a
#   trailing space is both an .editorconfig violation and a yamllint error, so
#   every line is stripped before it is printed. That detail is the whole
#   reason this is a function rather than three lines at the call site.
# ---------------------------------------------------------------------------
_pin_yaml_field() {
    local indent=$1 key=$2 value=$3
    local quoted line
    local -a wrapped=() stripped=()

    quoted=$(_pin_yaml_escape "$value")
    if (( ${#indent} + ${#key} + ${#quoted} + 2 <= 110 )) || ! command -v fold >/dev/null 2>&1; then
        printf '%s%s: %s\n' "$indent" "$key" "$quoted"
        return 0
    fi

    mapfile -t wrapped < <(printf '%s\n' "$value" | fold -s -w 88)

    # FOLDING JOINS WITH A SPACE, SO IT IS ONLY SAFE WHERE A SPACE ALREADY
    # WAS. `fold -s` breaks on spaces WHEN IT CAN and hard-breaks a long word
    # when it cannot -- and the value most likely to be long here is a URL,
    # which has no spaces in it at all. A folded URL comes back with a space
    # in the middle of the ref, and the play then fetches a 404 while every
    # document says the ref is pinned.
    #
    # So the fold is checked before it is used: strip the trailing space
    # `fold -s` leaves on each line, rejoin with single spaces, and use the
    # folded form ONLY if that reproduces the original byte for byte.
    # Otherwise the long quoted line is written, which is a yamllint
    # line-length WARNING and not a wrong value.
    local rejoined=''
    for line in "${wrapped[@]}"; do
        while [[ $line == *' ' ]]; do line=${line% }; done
        stripped+=("$line")
        rejoined=${rejoined:+${rejoined} }${line}
    done
    if [[ $rejoined != "$value" ]]; then
        printf '%s%s: %s\n' "$indent" "$key" "$quoted"
        return 0
    fi

    printf '%s%s: >-\n' "$indent" "$key"
    for line in "${stripped[@]}"; do
        printf '%s  %s\n' "$indent" "$line"
    done
    return 0
}

# ---------------------------------------------------------------------------
# _pin_wrap_reason TEXT
#   Print one exclusion reason under the table, wrapped to the width of a
#   terminal rather than run out to three hundred columns. `fold -s` breaks on
#   spaces, so a distribution name or a URL is never split down the middle; if
#   it is missing the sentence is printed whole, because a reason nobody can
#   read is still better than no reason.
# ---------------------------------------------------------------------------
_pin_wrap_reason() {
    local text="-> $1" line
    local -a wrapped=()
    if command -v fold >/dev/null 2>&1; then
        mapfile -t wrapped < <(printf '%s\n' "$text" | fold -s -w 92)
    else
        wrapped=("$text")
    fi
    for line in "${wrapped[@]}"; do
        printf '  %-26s %s\n' '' "$line"
    done
    return 0
}

# ===========================================================================
# MAIN
# ===========================================================================
_pin_main() {
    local ref='' repo='' telemetry="$_PIN_TELEMETRY_DEFAULT"
    local dry_run=0 allow_non_sha=0

    while (( $# > 0 )); do
        case $1 in
            --repo)
                shift
                (( $# > 0 )) || _pin_usage_die "--repo needs a directory"
                repo=$1
                ;;
            --repo=*) repo=${1#--repo=} ;;
            --telemetry-service)
                shift
                (( $# > 0 )) || _pin_usage_die "--telemetry-service needs a name"
                telemetry=$1
                ;;
            --telemetry-service=*) telemetry=${1#--telemetry-service=} ;;
            --dry-run)        dry_run=1 ;;
            --allow-non-sha)  allow_non_sha=1 ;;
            -h|--help)        _pin_usage; return 0 ;;
            --)               shift; break ;;
            -*)               _pin_usage_die "unknown option '$1'" ;;
            *)
                [[ -z $ref ]] || _pin_usage_die "two refs given ('${ref}' and '$1'); this tool pins one"
                ref=$1
                ;;
        esac
        shift
    done
    while (( $# > 0 )); do
        [[ -z $ref ]] || _pin_usage_die "two refs given ('${ref}' and '$1'); this tool pins one"
        ref=$1
        shift
    done

    _pin_check_ref "$ref" "$allow_non_sha"
    if [[ -n $telemetry && ! $telemetry =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        _pin_usage_die "'${telemetry}' is not a compose service name"
    fi
    if [[ -n $repo ]]; then
        if [[ ! -d $repo ]]; then
            _pin_usage_die "--repo ${repo} is not a directory"
        fi
        if ! command -v git >/dev/null 2>&1; then
            _pin_usage_die "--repo needs git on PATH"
        fi
        local resolved=''
        resolved=$(git -C "$repo" rev-parse --verify --quiet "${ref}^{commit}" 2>/dev/null)
        if [[ -z $resolved ]]; then
            _pin_die "${ref} is not a commit in ${repo}. Fetch it there first; this tool never fetches into somebody's clone."
        fi
        # A ref that resolves to a DIFFERENT sha is a tag or a branch wearing
        # a commit's clothes. Say which, rather than pinning one string and
        # measuring another.
        if [[ $ref =~ ^[0-9a-f]{40}$ && $resolved != "$ref" ]]; then
            _pin_die "${ref} resolves to ${resolved} in ${repo}. Those are different commits."
        fi
    fi

    local work=''
    work=$(mktemp -d "${TMPDIR:-/tmp}/pin-upstream.XXXXXXXX") || _pin_die "could not create a working directory"
    # shellcheck disable=SC2064
    trap "rm -rf -- '${work}'" EXIT INT TERM HUP

    # -----------------------------------------------------------------------
    # 1. The entrypoint: fetch it, and checksum it.
    # -----------------------------------------------------------------------
    local url sha
    url=$(_pin_entrypoint_url "$ref") || return 1
    _pin_note "reading upstream install.sh at ${ref}"
    _pin_fetch "$ref" "install.sh" "${work}/install.sh" "$repo"
    sha=$(_pin_sha256 "${work}/install.sh") || return 1

    # -----------------------------------------------------------------------
    # 2. Read the gate, the package managers and the install types out of it.
    # -----------------------------------------------------------------------
    local -a records=()
    mapfile -t records < <(_pin_parse_install_sh "${work}/install.sh")
    if (( ${#records[@]} == 0 )); then
        _pin_die "nothing was recognised in upstream's install.sh at ${ref}. Either the file is not what it was, or upstream reformatted the shapes this tool reads (see _pin_parse_install_sh). Read it before pinning it."
    fi

    local -a accepted_names=() type_letters=()
    declare -A gate_version=() gate_compare=() pkg_of=() compose_of=()
    local rec kind rest a b c
    for rec in "${records[@]}"; do
        kind=${rec%%$'\t'*}
        rest=${rec#*$'\t'}
        case $kind in
            NAME) accepted_names+=("$rest") ;;
            GATE)
                a=${rest%%$'\t'*}; rest=${rest#*$'\t'}
                b=${rest%%$'\t'*}; c=${rest#*$'\t'}
                gate_version[$a]=$b
                gate_compare[$a]=$c
                ;;
            PKG)
                a=${rest%%$'\t'*}; b=${rest#*$'\t'}
                pkg_of[$a]=$b
                ;;
            TYPE)
                a=${rest%%$'\t'*}; b=${rest#*$'\t'}
                type_letters+=("$a")
                compose_of[$a]=$b
                ;;
        esac
    done

    if (( ${#accepted_names[@]} == 0 )); then
        _pin_die "upstream's distribution list could not be read out of install.sh at ${ref}."
    fi
    if (( ${#type_letters[@]} == 0 )); then
        _pin_die "no install types could be read out of install.sh at ${ref}, so no compose file can be counted."
    fi

    # -----------------------------------------------------------------------
    # 3. Derive the supported tier. Three filters, applied in order, each one
    #    recording its reason so the report explains every exclusion.
    # -----------------------------------------------------------------------
    local -a matrix_rows=() report_rows=()
    local name id version compare pkgs verdict reason row
    for name in "${accepted_names[@]}"; do
        id=${_PIN_ID_OF[$name]:-}
        if [[ -z $id ]]; then
            _pin_die "upstream accepts NAME='${name}' at ${ref} and this tool has no /etc/os-release ID for it. Add a row to _PIN_ID_OF -- upstream matches on NAME and support-matrix.yml matches on ID, and nothing derives one from the other. Guessing is how a release silently stops being claimed."
        fi
        version=${gate_version[$name]:-}
        compare=${gate_compare[$name]:-none}
        pkgs=${pkg_of[$name]:-}
        verdict=''
        reason=''
        row=''

        if [[ -z $version ]]; then
            verdict='excluded'
            reason='upstream applies no version gate to it at this ref (a rolling release), so there is no version to write as a row'
        elif [[ " ${pkgs} " != *" apt "* ]]; then
            verdict='excluded'
            reason="upstream installs its packages there with ${pkgs:-no package manager this tool recognised}; this installer requires apt-get (lib/preflight.sh)"
        elif [[ -n ${_PIN_NEVER_INSTALLED_WHY[$id]:-} ]]; then
            verdict='excluded'
            reason=${_PIN_NEVER_INSTALLED_WHY[$id]}
        else
            # The granularity of the row is upstream's own comparison: a gate
            # that truncates VERSION_ID to its major can only ever be satisfied
            # by a major, and a row carrying more than upstream compares would
            # claim a precision upstream does not have.
            if [[ $compare == major && $version == *.* ]]; then
                _pin_die "upstream compares only the major version of ${name} but its required version is '${version}'. That gate can never be satisfied; read install.sh at ${ref} before pinning it."
            fi
            verdict='supported'
            row="${id}:${version}"
            reason='upstream accepts it at this ref and this installer can drive it'
            matrix_rows+=("$row")
        fi
        # The record carries the RAW values -- an empty version for a rolling
        # release, an empty row for an excluded one. The report substitutes a
        # readable placeholder at print time and the data file writes the
        # empty string, so neither of them has to be parsed back later.
        report_rows+=("${name}"$'\t'"${id}"$'\t'"${version}"$'\t'"${compare}"$'\t'"${pkgs}"$'\t'"${verdict}"$'\t'"${row}"$'\t'"${reason}")
    done

    # -----------------------------------------------------------------------
    # 4. Count the containers, per install type, from that ref's own compose
    #    files, with the telemetry service removed (D-09).
    # -----------------------------------------------------------------------
    local -A count_after=() count_before=()
    local letter stem counts services tele restarts always dupes
    local netpresent=0 netfound=0
    for letter in "${type_letters[@]}"; do
        stem=${compose_of[$letter]}
        _pin_fetch "$ref" "compose/${stem}.yml" "${work}/${stem}.yml" "$repo"
        counts=$(_pin_count_services "${work}/${stem}.yml" "$telemetry")
        services=${counts%%$'\t'*}; counts=${counts#*$'\t'}
        tele=${counts%%$'\t'*};     counts=${counts#*$'\t'}
        restarts=${counts%%$'\t'*}; counts=${counts#*$'\t'}
        always=${counts%%$'\t'*};   dupes=${counts#*$'\t'}

        if (( services == 0 )); then
            _pin_die "compose/${stem}.yml at ${ref} has no services mapping this tool can read. A container count of zero would turn verification into a rubber stamp."
        fi
        if (( dupes > 0 )); then
            _pin_die "compose/${stem}.yml at ${ref} declares ${dupes} duplicate service name(s). Compose keeps the last; this counter would count both, so the number would be wrong."
        fi
        if (( restarts != services || always != services )); then
            _pin_die "compose/${stem}.yml at ${ref} has ${services} service(s) but ${restarts} restart policy(ies), ${always} of them 'always'. The premise behind every count this tool writes -- one service block is one running container, because nothing is a one-shot -- no longer holds at this ref. Read the file and decide what a healthy container count is before pinning it."
        fi
        if (( tele == 0 )); then
            _pin_die "compose/${stem}.yml at ${ref} has no service called '${telemetry}'. This installer removes that block before starting T-Pot (D-09), and a removal that removes nothing is exactly one container's difference with nothing visible to show for it. Pass --telemetry-service with the name it has at this ref."
        fi
        if (( tele > 1 )); then
            _pin_die "compose/${stem}.yml at ${ref} declares '${telemetry}' ${tele} times."
        fi
        count_before[$letter]=$services
        count_after[$letter]=$(( services - tele ))

        # The telemetry service's own network, checked in EVERY compose file
        # rather than in the first one. roles/tpot_install removes it
        # alongside the service, composing the name as <service>_local --
        # upstream's convention, declared nowhere -- so a file where that
        # name is absent is a file where the removal quietly does nothing.
        if [[ $(_pin_has_network_key "${work}/${stem}.yml" "${telemetry}_local") == 1 ]]; then
            netfound=$(( netfound + 1 ))
        fi
    done

    if (( netfound == ${#type_letters[@]} )); then
        netpresent=1
    else
        netpresent=0
        _pin_warn "'${telemetry}_local' is declared in ${netfound} of ${#type_letters[@]} compose file(s) at this ref. roles/tpot_install composes that network name from the service name and removes it with the service, so in the others the network removal has nothing to remove. Recorded as telemetry_network_declared: false."
    fi

    # -----------------------------------------------------------------------
    # 5. The report. Printed whether or not anything is written, because a
    #    --dry-run that printed less than the real run would be a different
    #    tool.
    # -----------------------------------------------------------------------
    _pin_say "upstream ref        ${ref}"
    _pin_say "entrypoint          ${url}"
    _pin_say "sha256(install.sh)  ${sha}"
    _pin_say "read from           ${repo:-the network}"
    _pin_say ""
    _pin_say "upstream's own distribution gate at this ref, and what this installer may claim:"
    _pin_say ""
    printf '  %-26s %-20s %-9s %-8s %-8s %s\n' 'upstream NAME' 'our id' 'requires' 'compares' 'packages' 'verdict'
    printf '  %-26s %-20s %-9s %-8s %-8s %s\n' \
        '--------------------------' '--------------------' '---------' '--------' '--------' '-------'
    local line f_name f_id f_ver f_cmp f_pkg f_verdict f_row f_reason
    for line in "${report_rows[@]}"; do
        f_name=${line%%$'\t'*};  line=${line#*$'\t'}
        f_id=${line%%$'\t'*};    line=${line#*$'\t'}
        f_ver=${line%%$'\t'*};   line=${line#*$'\t'}
        f_cmp=${line%%$'\t'*};   line=${line#*$'\t'}
        f_pkg=${line%%$'\t'*};   line=${line#*$'\t'}
        f_verdict=${line%%$'\t'*}; line=${line#*$'\t'}
        f_row=${line%%$'\t'*};   f_reason=${line#*$'\t'}
        printf '  %-26s %-20s %-9s %-8s %-8s %s\n' \
            "$f_name" "$f_id" "${f_ver:-(rolling)}" "$f_cmp" "${f_pkg:-?}" \
            "$( [[ $f_verdict == supported ]] && printf '%s' "SUPPORTED  ${f_row}" || printf 'excluded' )"
        if [[ $f_verdict != supported ]]; then
            _pin_wrap_reason "$f_reason"
        fi
    done
    _pin_say ""
    if (( ${#matrix_rows[@]} == 0 )); then
        _pin_say "supported tier      (none) -- nothing this ref accepts is drivable by this installer"
    else
        _pin_say "supported tier      ${matrix_rows[*]}"
    fi
    _pin_say ""
    _pin_say "containers per install type, measured from this ref's compose files,"
    _pin_say "with the '${telemetry}' service removed (D-09):"
    _pin_say ""
    printf '  %-6s %-24s %-10s %s\n' 'type' 'compose file' 'services' 'after removal'
    printf '  %-6s %-24s %-10s %s\n' '------' '------------------------' '----------' '-------------'
    for letter in "${type_letters[@]}"; do
        printf '  %-6s %-24s %-10s %s\n' \
            "$letter" "compose/${compose_of[$letter]}.yml" "${count_before[$letter]}" "${count_after[$letter]}"
    done
    _pin_say ""

    # THE SENTENCE THAT HAS TO BE PRINTED EVERY TIME. The tier this tool fills
    # in is called "supported and tested", and this tool can only ever
    # establish the first half of that name.
    if (( ${#matrix_rows[@]} > 0 )); then
        _pin_say "NOT ONE OF THOSE ROWS HAS BEEN INSTALLED BY ANYBODY. A derived row says upstream"
        _pin_say "would accept the release and this installer could drive it. The evidence that it"
        _pin_say "WORKS is a dated run per (ref x release) pair in tests/MATRIX-STATUS.md, and an"
        _pin_say "undated row there blocks a release tag."
        _pin_say ""
    fi

    if (( dry_run == 1 )); then
        _pin_note "--dry-run: nothing was written."
        return 0
    fi

    # -----------------------------------------------------------------------
    # 6. Write the two files.
    # -----------------------------------------------------------------------
    _pin_write_fallback
    _pin_write_data_file "$ref" "$url" "$sha" "$telemetry" "$netpresent" \
        report_rows type_letters compose_of count_before count_after matrix_rows
    _pin_rewrite_matrix "$ref" matrix_rows
    _pin_verify_matrix "$ref" matrix_rows

    _pin_say "Read both diffs before committing them:"
    _pin_say "  roles/tpot_install/vars/upstream-${ref}.yml"
    _pin_say "  support-matrix.yml"
    return 0
}

# ---------------------------------------------------------------------------
# _pin_write_data_file REF URL SHA TELEMETRY NETPRESENT \
#                      <report_rows> <type_letters> <compose_of> \
#                      <count_before> <count_after> <matrix_rows>
#
#   Write roles/tpot_install/vars/upstream-<ref>.yml. The arrays are passed BY
#   NAME and read through namerefs: passing six arrays through "$@" would mean
#   flattening and re-splitting them, and a distribution name with a space in
#   it is exactly the value that would come back wrong.
#
#   THE SHAPE IS THE ONE roles/tpot_install READS. That role accepts the data
#   under a tpot_install_upstream mapping, under flat tpot_install_* keys, or
#   under bare names; the mapping is written here because bare `sha256` and
#   `install_types` in a file loaded with include_vars are global variable
#   names, and a global called sha256 is a collision waiting to happen.
# ---------------------------------------------------------------------------
_pin_write_data_file() {
    local ref=$1 url=$2 sha=$3 telemetry=$4 netpresent=$5
    local -n _report=$6
    local -n _letters=$7
    local -n _compose=$8
    local -n _before=$9
    local -n _after=${10}
    local -n _rows=${11}

    local dest="${_PIN_VARS_DIR}/upstream-${ref}.yml"
    local tmp='' today rc=0
    today=$(date -u '+%Y-%m-%d')

    if ! mkdir -p -- "$_PIN_VARS_DIR"; then
        _pin_die "could not create ${_PIN_VARS_DIR}"
    fi
    tmp=$(mktemp "${dest}.XXXXXX") || _pin_die "could not create a temporary beside ${dest}"

    {
        printf '%s\n' '---'
        printf '%s\n' "# roles/tpot_install/vars/upstream-${ref}.yml"
        cat <<'HEADER'
#
# GENERATED BY tools/pin-upstream.sh. DO NOT EDIT BY HAND -- re-run the tool
# against the ref instead, and read the diff.
#
# WHAT THIS FILE IS. Everything about ONE upstream ref that this project must
# know and cannot infer. roles/tpot_install loads it by name
# (tasks/fetch-upstream.yml) and refuses to install if it is missing or does
# not carry a usable sha256.
#
# WHAT IT IS NOT. It is not evidence that anything was installed. Every number
# here was read out of upstream's source at the ref named below; no T-Pot has
# been installed by this project, on any release, at any ref. The ledger for
# real runs is tests/MATRIX-STATUS.md.
#
# THE CONTAINER COUNTS ARE MEASURED, NOT GUESSED, AND THEY ARE POST-REMOVAL.
# Neither upstream file states a container count anywhere. These are the
# service blocks in each edition's compose file at this ref, with the
# telemetry service removed (D-09), and the tool refuses to write them unless
# every service in every file declares `restart: always` -- which is what
# makes "one service block is one running container" true rather than
# convenient. `services` below is the count BEFORE the removal, kept so that
# the subtraction is visible instead of asserted.
#
# min_containers IS KEYED BY THE INSTALL TYPE LETTER, NEVER BY UPSTREAM'S
# INTERNAL TYPE. Upstream maps h, l, i and t all to HIVE while copying four
# different compose files, so the internal type is not a key at all.
#
# A NOTE ON WHAT A PIN DOES NOT PIN. The ref pins the entrypoint and the
# playbook upstream clones. It does not pin the software: T-Pot's own .env
# names a mutable image tag and sets a pull policy of `always`, so the
# containers are re-pulled at every start. Say so wherever you say "pinned".
HEADER
        printf '\n'
        printf '%s\n' 'tpot_install_upstream:'
        printf '  is_fallback: false\n'
        printf '  ref: %s\n'    "$(_pin_yaml_escape "$ref")"
        _pin_yaml_field '  ' 'url' "$url"
        printf '  sha256: %s\n' "$(_pin_yaml_escape "$sha")"
        printf '  derived_at: %s\n' "$(_pin_yaml_escape "$today")"
        printf '  derived_by: "tools/pin-upstream.sh"\n'
        printf '\n'
        printf '%s\n' '  # The service block removed from docker-compose.yml before T-Pot is'
        printf '%s\n' '  # started, and the network only it uses. The SERVICE was confirmed'
        printf '%s\n' '  # present in every compose file at this ref -- the pin refuses'
        printf '%s\n' '  # otherwise -- and the counts below are after its removal. The'
        printf '%s\n' '  # NETWORK is reported rather than required: true below means every'
        printf '%s\n' '  # compose file declares it, false means at least one does not.'
        printf '  telemetry_service: %s\n' "$(_pin_yaml_escape "$telemetry")"
        printf '  telemetry_network: %s\n' "$(_pin_yaml_escape "${telemetry}_local")"
        printf '  telemetry_network_declared: %s\n' "$( (( netpresent == 1 )) && printf 'true' || printf 'false' )"
        printf '\n'
        printf '%s\n' '  # The install types this ref knows, and the compose file each one copies'
        printf '%s\n' '  # over docker-compose.yml. The compose file is the authority on the'
        printf '%s\n' '  # edition: nothing about the letters says that h is standard and i is mini.'
        local letter first=1 list=''
        for letter in "${_letters[@]}"; do
            if (( first == 1 )); then list="\"${letter}\""; first=0; else list="${list}, \"${letter}\""; fi
        done
        printf '  install_types: [%s]\n' "$list"
        printf '  compose_files:\n'
        for letter in "${_letters[@]}"; do
            printf '    "%s": %s\n' "$letter" "$(_pin_yaml_escape "compose/${_compose[$letter]}.yml")"
        done
        printf '\n'
        printf '%s\n' '  # Service blocks per compose file, before the telemetry removal.'
        printf '  services:\n'
        for letter in "${_letters[@]}"; do
            printf '    "%s": %s\n' "$letter" "${_before[$letter]}"
        done
        printf '\n'
        printf '%s\n' '  # How many containers a healthy T-Pot of each edition has, as this'
        printf '%s\n' '  # installer leaves it. This is the floor verification compares against.'
        printf '  min_containers:\n'
        for letter in "${_letters[@]}"; do
            printf '    "%s": %s\n' "$letter" "${_after[$letter]}"
        done
        printf '\n'
        printf '%s\n' "  # Upstream's own distribution gate at this ref, read from its source."
        printf '%s\n' '  # It runs BEFORE upstream reads any flag and it has no override, so a'
        printf '%s\n' '  # release it refuses cannot be reached from here by any setting. Kept'
        printf '%s\n' '  # per ref because the gate is a property of the install.sh that executes,'
        printf '%s\n' '  # never of the payload the ref also pins (D-10).'
        printf '%s\n' '  #'
        printf '%s\n' '  #   verdict "supported"  upstream accepts it AND this installer can drive'
        printf '%s\n' '  #                        it. It does NOT mean anybody has run it.'
        printf '%s\n' '  #   verdict "excluded"   the reason says which filter removed it.'
        printf '  gate:\n'
        printf '    source: %s\n' "$(_pin_yaml_escape "upstream install.sh at ${ref}")"
        printf '    read_on: %s\n' "$(_pin_yaml_escape "$today")"
        printf '    rows:\n'
        local line f_name f_id f_ver f_cmp f_pkg f_verdict f_row f_reason
        for line in "${_report[@]}"; do
            f_name=${line%%$'\t'*};    line=${line#*$'\t'}
            f_id=${line%%$'\t'*};      line=${line#*$'\t'}
            f_ver=${line%%$'\t'*};     line=${line#*$'\t'}
            f_cmp=${line%%$'\t'*};     line=${line#*$'\t'}
            f_pkg=${line%%$'\t'*};     line=${line#*$'\t'}
            f_verdict=${line%%$'\t'*}; line=${line#*$'\t'}
            f_row=${line%%$'\t'*};     f_reason=${line#*$'\t'}
            printf '      - name: %s\n' "$(_pin_yaml_escape "$f_name")"
            _pin_yaml_field '        ' 'id'       "$f_id"
            _pin_yaml_field '        ' 'version'  "$f_ver"
            _pin_yaml_field '        ' 'compares' "$f_cmp"
            _pin_yaml_field '        ' 'packages' "$f_pkg"
            _pin_yaml_field '        ' 'verdict'  "$f_verdict"
            _pin_yaml_field '        ' 'row'      "$f_row"
            _pin_yaml_field '        ' 'reason'   "$f_reason"
        done
        printf '\n'
        printf '%s\n' "  # The supported tier this ref produced, recorded here as the pin's own"
        printf '%s\n' '  # record. support-matrix.yml carries the OPERATIVE copy, for whichever'
        printf '%s\n' '  # ref is pinned now; this one stays true for this ref for ever.'
        if (( ${#_rows[@]} == 0 )); then
            printf '  supported: []\n'
        else
            printf '  supported:\n'
            local r
            for r in "${_rows[@]}"; do
                printf '    - %s\n' "$(_pin_yaml_escape "$r")"
            done
        fi
        printf '  proven: false  # this tool proves nothing; tests/MATRIX-STATUS.md is the record\n'
    } > "$tmp" || rc=$?

    if (( rc != 0 )); then
        rm -f -- "$tmp"
        _pin_die "could not write ${dest}"
    fi
    chmod 0644 -- "$tmp" && mv -f -- "$tmp" "$dest" || {
        rm -f -- "$tmp"
        _pin_die "could not move the new data file into place at ${dest}"
    }
    _pin_note "wrote ${dest#"${_PIN_REPO_DIR}/"}"
    return 0
}

# ---------------------------------------------------------------------------
# _pin_write_fallback
#   Create roles/tpot_install/vars/upstream-default.yml if it is not there.
#
#   THIS FILE IS THE LOUD FALLBACK, AND ITS WHOLE JOB IS TO FAIL. roles/tpot_install
#   looks for a data file named after the pinned ref and falls back to this one
#   (tasks/fetch-upstream.yml, first_found). Everything in it is empty on
#   purpose: a fallback carrying plausible numbers would let a run reach the end
#   using another ref's checksum and another ref's container counts, and report
#   success. Empty means the role's own assertion -- "no usable sha256" -- fires
#   at the upstream stage, before anything of upstream's has been executed.
#
#   IT IS NOT REGENERATED ON EVERY PIN. Nothing in it depends on the ref, so
#   re-writing it each time would put an unread diff in front of a maintainer
#   who is trying to read the two that matter. It is created once and then left
#   alone; delete it to have it written again.
# ---------------------------------------------------------------------------
_pin_write_fallback() {
    local dest="${_PIN_VARS_DIR}/upstream-default.yml" tmp='' rc=0

    if [[ -e $dest ]]; then
        return 0
    fi
    if ! mkdir -p -- "$_PIN_VARS_DIR"; then
        _pin_die "could not create ${_PIN_VARS_DIR}"
    fi
    tmp=$(mktemp "${dest}.XXXXXX") || _pin_die "could not create a temporary beside ${dest}"

    cat > "$tmp" <<'FALLBACK' || rc=$?
---
# roles/tpot_install/vars/upstream-default.yml -- the LOUD FALLBACK.
#
# WHAT THIS FILE IS FOR. roles/tpot_install loads the data file named after the
# pinned upstream ref, and falls back to this one when there is none
# (tasks/fetch-upstream.yml, ansible.builtin.first_found). Its job is to make
# that fall-back FAIL, immediately and with a sentence, rather than to stand in
# for the missing file.
#
# WHY EVERYTHING BELOW IS EMPTY. A per-ref data file carries three things
# nothing can infer: the sha256 of upstream's install.sh, the container count of
# each edition, and the install types that ref knows about. All three are
# properties of ONE upstream commit. A fallback carrying numbers from some other
# commit is worse than no fallback at all -- the run would fetch an installer
# whose checksum was never checked against anything, install it, and then
# "verify" the result against a container count belonging to a different ref.
# That produces either a rubber stamp or a false alarm, and in both cases a
# report that reads exactly like a successful one.
#
# WHAT HAPPENS WHEN THIS FILE IS THE ONE THAT GETS LOADED. Two things, in this
# order, and both of them name the tool:
#
#   1. roles/tpot_install appends a warning to the run saying that the numbers
#      in use belong to some other ref and that tools/pin-upstream.sh must be
#      run for the pinned one;
#   2. its next assertion -- "Refuse to install without a sha256 for the pinned
#      installer" -- fails, because the sha256 below is empty. The run stops at
#      the upstream stage, which is exit 14, and exit 14 means precisely that
#      nothing of upstream's has been executed.
#
# THE FIX IS NEVER TO EDIT THIS FILE. It is:
#
#     tools/pin-upstream.sh <the full 40-character commit sha>
#
# which writes roles/tpot_install/vars/upstream-<that ref>.yml beside this one,
# derives the supported tier from that ref's own distribution gate, and updates
# support-matrix.yml in the same edit. Read the diff, then commit it.
#
# THIS FILE IS NOT EVIDENCE OF ANYTHING, and neither is the one the tool writes.
# No T-Pot has been installed by this project, at any ref, on any release. The
# ledger for real runs is tests/MATRIX-STATUS.md.

tpot_install_upstream:
  # The marker a reader (and any future consumer) can test. Everything else
  # here is empty, and this says the emptiness is deliberate.
  is_fallback: true

  # EMPTY ON PURPOSE. This is the value that stops the run: roles/tpot_install
  # requires 64 lowercase hex characters and gets nothing, so it refuses before
  # anything is fetched. Do not put a checksum here -- a checksum that is not
  # the pinned ref's is a security control that passes while checking nothing.
  sha256: ""

  # EMPTY ON PURPOSE. The role has its own default for the telemetry service
  # name and would apply it, but no run reaches that code with this file
  # loaded: the assertion above fires first.
  telemetry_service: ""

  # EMPTY ON PURPOSE. An empty list means the role skips its "does this ref
  # know this install type" assertion rather than answering it from another
  # ref's data, which would be an answer about the wrong software.
  install_types: []

  # EMPTY ON PURPOSE. Keyed by install type letter in a real data file. There
  # is no honest number to put here: upstream states a container count nowhere,
  # and the only source is the compose file at the ref actually being pinned.
  min_containers: {}

  # There is no ref, so there is nothing derived from one.
  ref: ""
  url: ""
  supported: []
  proven: false
FALLBACK

    if (( rc != 0 )); then
        rm -f -- "$tmp"
        _pin_die "could not write ${dest}"
    fi
    chmod 0644 -- "$tmp" && mv -f -- "$tmp" "$dest" || {
        rm -f -- "$tmp"
        _pin_die "could not move the fallback data file into place at ${dest}"
    }
    _pin_note "created ${dest#"${_PIN_REPO_DIR}/"} -- the loud fallback for a ref with no data file"
    return 0
}

# ---------------------------------------------------------------------------
# _pin_rewrite_matrix REF <matrix_rows>
#   Rewrite tpot_support_matrix_supported and tpot_support_matrix_supported_ref
#   in support-matrix.yml, in one edit, leaving every comment and the whole
#   legacy tier exactly as they were.
#
#   THE BLOCK RULE, stated because a rewrite of somebody else's file needs one
#   that can be checked rather than felt: the supported tier's block is its
#   key line plus every following line up to, but not including, the first
#   line that is blank or begins in column zero. In the shipped file the key
#   line is followed immediately by a blank line, so the block is the key line
#   alone; after this tool has run it is the key line and its rows. Both cases
#   round-trip, and nothing this tool writes inside the block is a comment, so
#   nothing can accumulate there across re-runs.
#
#   NO TRAILING COMMENT IS WRITTEN ON THE REF LINE, AND THIS IS NOT STYLE.
#   lib/matrix.sh strips one layer of matching quotes first and only then
#   looks for " #", so `key: "abc"  # note` comes back as the five characters
#   "abc" WITH the quotes, and the bash reader and PyYAML would disagree about
#   the ref -- which is the exact failure tests/check-matrix-parse.sh exists
#   to catch. The derivation date belongs in the data file, where it does not
#   have to survive two parsers.
# ---------------------------------------------------------------------------
_pin_rewrite_matrix() {
    local ref=$1
    local -n _rows=$2
    local tmp='' block='' refline rc=0

    if [[ ! -r $_PIN_MATRIX_FILE ]]; then
        _pin_die "support-matrix.yml is not readable at ${_PIN_MATRIX_FILE}"
    fi

    # The invariant, enforced where the two values are produced rather than
    # only where they are read: the ref is empty if and only if the tier is.
    if (( ${#_rows[@]} == 0 )); then
        refline="${_PIN_KEY_REF}: \"\""
        _pin_warn "nothing this ref accepts is drivable by this installer, so the supported tier is being written empty -- and the ref with it, because a ref with no tier under it is a pin nobody derived anything from."
    else
        refline="${_PIN_KEY_REF}: $(_pin_yaml_escape "$ref")"
    fi

    block=$(mktemp "${_PIN_MATRIX_FILE}.block.XXXXXX") || _pin_die "could not create a temporary beside support-matrix.yml"
    if (( ${#_rows[@]} == 0 )); then
        printf '%s: []\n' "$_PIN_KEY_SUPPORTED" > "$block"
    else
        printf '%s:\n' "$_PIN_KEY_SUPPORTED" > "$block"
        local r
        for r in "${_rows[@]}"; do
            printf '  - %s\n' "$(_pin_yaml_escape "$r")" >> "$block"
        done
    fi

    tmp=$(mktemp "${_PIN_MATRIX_FILE}.XXXXXX") || {
        rm -f -- "$block"
        _pin_die "could not create a temporary beside support-matrix.yml"
    }

    awk -v refline="$refline" -v supkey="$_PIN_KEY_SUPPORTED" -v refkey="$_PIN_KEY_REF" \
        -v blockfile="$block" '
        $0 ~ "^" refkey ":" { print refline; seen_ref++; in_block = 0; next }
        $0 ~ "^" supkey ":" {
            while ((getline l < blockfile) > 0) print l
            close(blockfile)
            seen_sup++
            in_block = 1
            next
        }
        in_block == 1 {
            # Blank, or column zero: the block is over and this line is not
            # part of it, so fall through and print it.
            if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[^[:space:]]/) { in_block = 0 }
            else next
        }
        { print }
        END {
            if (seen_ref != 1) { printf "the ref key appears %d time(s)\n", seen_ref + 0 > "/dev/stderr"; exit 2 }
            if (seen_sup != 1) { printf "the supported key appears %d time(s)\n", seen_sup + 0 > "/dev/stderr"; exit 2 }
        }
    ' < "$_PIN_MATRIX_FILE" > "$tmp" || rc=$?

    rm -f -- "$block"
    if (( rc != 0 )); then
        rm -f -- "$tmp"
        _pin_die "support-matrix.yml was NOT rewritten: each of ${_PIN_KEY_SUPPORTED} and ${_PIN_KEY_REF} must appear exactly once at column zero. The file is unchanged."
    fi

    chmod 0644 -- "$tmp" && mv -f -- "$tmp" "$_PIN_MATRIX_FILE" || {
        rm -f -- "$tmp"
        _pin_die "could not move the rewritten support-matrix.yml into place. The file is unchanged."
    }
    _pin_note "rewrote support-matrix.yml: ${_PIN_KEY_SUPPORTED} and ${_PIN_KEY_REF}"
    if (( ${#_rows[@]} > 0 )); then
        # This tool rewrites two keys. It cannot rewrite an essay, and the
        # essay above those keys -- and the matrix section of README.md --
        # says the supported tier ships empty BECAUSE no ref is pinned. That
        # sentence was true until the line above ran. Saying so here is the
        # difference between a stale document somebody notices and one nobody
        # does; leaving it to be discovered is how a repository ends up
        # asserting two contradictory things about itself.
        _pin_warn "support-matrix.yml's header, and README.md's matrix section, still say the supported tier is empty because no ref is pinned. One is now pinned. Re-read both before committing: this tool rewrites two keys, not the prose around them."
    fi
    return 0
}

# ---------------------------------------------------------------------------
# _pin_verify_matrix REF <matrix_rows>
#   Read the file back with the product's own reader and check that it says
#   what this tool meant. A generator that never reads its own output is a
#   generator that will one day emit something only PyYAML can parse, and the
#   bash reader is the one that runs first on the box.
#
#   A check that could not run is reported as SKIPPED with a reason, never as
#   a pass -- the same rule the play's verification results follow.
# ---------------------------------------------------------------------------
_pin_verify_matrix() {
    local ref=$1
    local -n _rows=$2
    local got_ref='' rc=0
    local -a got_rows=()

    if [[ ! -r $_PIN_MATRIX_LIB ]]; then
        _pin_warn "SKIPPED: lib/matrix.sh is not readable, so the rewritten support-matrix.yml was not read back. The file was written; nothing has confirmed the product's own reader can parse it."
        return 0
    fi

    # shellcheck source=../lib/matrix.sh
    . "$_PIN_MATRIX_LIB" || {
        _pin_warn "SKIPPED: lib/matrix.sh would not load, so the rewritten support-matrix.yml was not read back."
        return 0
    }

    # NOT `mapfile < <(matrix_list_tier ...)`: mapfile's own exit status is
    # the one the shell reports, so a reader that FAILED would look like a
    # reader that returned no rows, and the wrong message would be printed
    # for the worse failure. Capture first, check, then split -- which is the
    # idiom lib/matrix.sh uses on itself for the same reason.
    local out=''
    out=$(matrix_list_tier supported "$_PIN_MATRIX_FILE") || rc=$?
    if (( rc != 0 )); then
        _pin_die "the rewritten support-matrix.yml cannot be read by lib/matrix.sh. Restore it from git and read the diff this tool would have made."
    fi
    if [[ -n $out ]]; then
        mapfile -t got_rows <<< "$out"
    fi

    if [[ "${got_rows[*]-}" != "${_rows[*]-}" ]]; then
        _pin_die "lib/matrix.sh reads the supported tier as '${got_rows[*]-}' and this tool derived '${_rows[*]-}'. The file is written but it does not say what was meant; read it."
    fi

    got_ref=$(matrix_supported_ref "$_PIN_MATRIX_FILE") || got_ref=''
    if (( ${#_rows[@]} == 0 )); then
        if [[ -n $got_ref ]]; then
            _pin_die "the supported tier is empty but lib/matrix.sh still reads a ref ('${got_ref}'). That breaks the invariant tests/check-matrix-parse.sh asserts."
        fi
        _pin_note "verified: the supported tier and its ref are both empty, which is the honest unpinned state."
        return 0
    fi
    if [[ $got_ref != "$ref" ]]; then
        _pin_die "lib/matrix.sh reads the derived-from ref as '${got_ref}' and this tool wrote '${ref}'."
    fi

    _pin_note "verified: lib/matrix.sh reads back ${#got_rows[@]} supported row(s) and the ref they came from."
    _pin_note "next: run tests/check-matrix-parse.sh and tests/run-gates.sh, then read both diffs."
    return 0
}

_pin_main "$@"
