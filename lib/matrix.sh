# lib/matrix.sh -- the bash reader for support-matrix.yml, and its two tiers.
#
# WHY THIS FILE EXISTS
#   Preflight stage A decides what this box is, and it runs before Ansible
#   exists on the box, before python3 has been confirmed usable and before
#   anything has been installed. So the check cannot be a YAML library call. It
#   is a small parser over the one file that holds the matrix, written so that
#   the answer it gives is identical to the answer `include_vars` gives the
#   Ansible preflight role later in the same run.
#   tests/check-matrix-parse.sh asserts that equality tier by tier;
#   support-matrix.yml states the format and the match rule both readers
#   implement, and what each tier means.
#
# THE TWO TIERS, AND THE ONE THING NOT TO GET WRONG (D-07)
#   support-matrix.yml carries two lists, not one:
#
#     supported   what the PINNED upstream ref accepts, intersected with what
#                 this installer can drive. Derived from the pin, written by
#                 tools/pin-upstream.sh, never by hand. Two rows at the ref
#                 this tree pins (D-11); EMPTY in a checkout with no pin, and
#                 empty is an answer rather than a broken file.
#                 DERIVED, NEVER TESTED -- see below.
#     legacy      the nine releases the automation this project replaces was
#                 installed on. Reachable by pinning an older upstream ref.
#                 DOCUMENTED, NEVER TESTED.
#
#   So "is this box in the matrix?" is no longer one question, and this library
#   refuses to answer it as though it were:
#
#     matrix_supports   is it in the SUPPORTED tier. Nothing else. This is the
#                       only function whose true answer licenses the word
#                       "supported" in a message or in result.json. It
#                       licenses "tested" nowhere: nothing in this file has
#                       any evidence about a real install.
#     matrix_known      is it in EITHER tier. A legacy box is known and
#                       reachable; it is not supported.
#     matrix_tier       WHICH tier matched -- "supported" or "legacy".
#     matrix_match      both at once, "<tier><TAB><row>", one parse.
#
#   A caller that only has matrix_supports and wants to be kind to a legacy box
#   must call matrix_tier as well and record what it says. It must not widen
#   matrix_supports, and it must not infer the tier from the id. Recording a
#   legacy box as supported is the untrue assertion this whole split exists to
#   prevent -- see support-matrix.yml's header for what the evidence behind
#   each tier actually is.
#
#   CHANGED BEHAVIOUR, CALLED OUT BECAUSE IT IS SILENT OTHERWISE: before D-07
#   this file had one flat list and matrix_supports was true for all nine
#   releases. It is now true only for what the pinned ref's own gate accepts
#   and this installer can drive. Against the matrix this tree ships, asked
#   row by row on 2026-09-04, that is debian:13 and ubuntu:26.04 and nothing
#   else -- so eight of the old nine now answer false, and debian:13 answers
#   true from the supported tier rather than the legacy one it is also in,
#   because matrix_match searches supported first. In a checkout with no pin
#   the answer is true for nothing at all, which is the CLOSED direction: an
#   unpinned installer claims nothing. Callers that want the old breadth want
#   matrix_known, and they owe the tier in their output.
#
#   WHAT A TRUE matrix_supports STILL DOES NOT MEAN: that anybody ran it. The
#   tier is derived from upstream's gate at the pin; the evidence of a real
#   install would be a dated row in tests/MATRIX-STATUS.md, and that file does
#   not exist because no such install has happened.
#
# WHAT IT DELIBERATELY DOES NOT DO
#   It does not parse YAML. It reads known keys from one known file whose
#   format is constrained by its own header comment, and it FAILS rather than
#   guessing when it meets a line under one of those keys it does not
#   recognise. A partial answer here would be an unsupported box silently
#   declared supported, which is the one outcome worth failing loudly to avoid.
#   For the same reason a tier whose key is ABSENT is an error, while a tier
#   declared `[]` is a valid, empty tier: "nobody has pinned anything" is an
#   answer, "the file is not the file I expected" is not.
#
#   It never sources /etc/os-release. That file is shell syntax on most boxes
#   and arbitrary code on a hostile one, and preflight runs as root.
#
#   It uses `mapfile`, never `read`. Not style: tests/check-no-tty.sh fails the
#   build on `read` outside lib/args.sh, because the product's core promise is
#   that no code path can block on a terminal.
#
# HOW TO USE IT
#   . "${REPO_DIR}/lib/matrix.sh"
#
#   matrix_tiers                       -> "supported", "legacy" -- precedence order
#   matrix_list                        -> every row of every tier, one per line
#   matrix_list_tier supported         -> the rows of one tier (may be none)
#   matrix_supported_ref               -> the ref the supported tier came from
#   matrix_ids                         -> the distinct ids, both tiers
#   matrix_versions debian             -> the versions for one id, both tiers
#   matrix_summary                     -> the user-facing sentence about both tiers
#   matrix_summary_tier legacy         -> "debian 11/12/13, ubuntu 20.04/..."
#   matrix_match debian 13             -> "supported<TAB>debian:13"
#   matrix_key debian 12               -> "debian:12"   (the row, whichever tier)
#   matrix_tier linuxmint 21.3         -> "legacy"
#   matrix_supports debian 13          -> verdict, SUPPORTED TIER ONLY
#   matrix_known linuxmint 21.3        -> verdict, either tier
#   matrix_identify [OS_RELEASE]       -> "<id><TAB><version_id>"
#   matrix_os_release_field ID [FILE]  -> one field of an os-release file
#
#   Every function that takes an optional FILE takes the matrix file; the two
#   os-release functions take an os-release file instead, defaulting to
#   /etc/os-release. Reading functions print to stdout and return non-zero with
#   nothing printed when they have no answer. THE ONE EXCEPTION, because the
#   distinction is load-bearing: matrix_list_tier returns 0 having printed
#   nothing when the tier is declared and empty. Zero rows is an answer; an
#   unreadable file is not, and that is rc 1.
#
#   matrix_match, matrix_key and matrix_tier distinguish two failures:
#   rc 1 means "no row matches this box", rc 2 means "the matrix could not be
#   read at all". Preflight must not report the second as the first -- it would
#   send somebody to reinstall their operating system over a missing file.
#
# shellcheck shell=bash

# Sourcing this file twice must be harmless.
if [[ -n ${_TPOT_MATRIX_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_MATRIX_SH_LOADED=1

# The tiers, IN PRECEDENCE ORDER. A row may appear in both -- debian:13
# legitimately does -- and the first tier listed here wins, so a box that is
# both tested and historical is reported as tested. Written once so that the
# order cannot drift between the lookup and the summary.
readonly _TPOT_MATRIX_TIER_LIST=(supported legacy)

# The key each tier lives under, in this file and in Ansible's variable
# namespace, plus the scalar carrying the ref the supported tier was derived
# from. Written once so the two readers cannot drift.
readonly _TPOT_MATRIX_KEY_SUPPORTED='tpot_support_matrix_supported'
readonly _TPOT_MATRIX_KEY_LEGACY='tpot_support_matrix_legacy'
readonly _TPOT_MATRIX_KEY_REF='tpot_support_matrix_supported_ref'

# The ONE entry shape this reader accepts, assembled in pieces so it stays
# readable. Capture groups, in order:
#
#   1  the opening quote, if any        4  the closing quote, if any
#   2  the id                           5  a trailing comment, if any
#   3  the version
#
# Groups 1 and 4 must be equal, which is how a half-quoted row is rejected
# rather than silently accepted with a quote inside the version. The version
# must begin with a digit and the id with a lower-case letter: both are
# properties of the /etc/os-release fields they are compared against, and
# requiring them here means a typo becomes a refusal instead of a row that can
# never match anything.
readonly _TPOT_MATRIX_ENTRY_RE=''\
'^[[:space:]]*-[[:space:]]*'\
'("|'"'"')?'\
'([a-z][a-z0-9._-]*)'\
':'\
'([0-9][0-9a-z._-]*)'\
'("|'"'"')?'\
'[[:space:]]*(#.*)?$'

# A top-level key line, with an optional empty flow sequence as its value:
#
#     tpot_support_matrix_legacy:          -> group 1 = the key, group 2 empty
#     tpot_support_matrix_supported: []    -> group 1 = the key, group 2 = "[]"
#
# Anything else at column zero -- a key with a scalar value, a document marker,
# a stray word -- is not one of our list keys and merely ENDS whichever list
# was open. Only `[]` is accepted as an inline value, deliberately: a real
# inline list would be a second format for the same fact.
readonly _TPOT_MATRIX_TOPKEY_RE='^([A-Za-z_][A-Za-z0-9_]*):[[:space:]]*(\[\])?[[:space:]]*(#.*)?$'

# ---------------------------------------------------------------------------
# _tpot_matrix_path [FILE]
#   Resolve which matrix file to read: the argument, else $REPO_DIR's copy,
#   else the copy beside this library. The last case is what makes the reader
#   usable from a test that has not set REPO_DIR.
# ---------------------------------------------------------------------------
_tpot_matrix_path() {
    local file=${1:-}
    if [[ -n $file ]]; then
        printf '%s\n' "$file"
        return 0
    fi
    if [[ -n ${REPO_DIR:-} ]]; then
        printf '%s\n' "${REPO_DIR}/support-matrix.yml"
        return 0
    fi
    printf '%s\n' "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/support-matrix.yml"
}

# ---------------------------------------------------------------------------
# _tpot_matrix_tier_key TIER
#   The YAML key one tier lives under. Returns 1, printing nothing, for a tier
#   name this library does not know -- a typo in a caller must not silently
#   become an empty tier.
# ---------------------------------------------------------------------------
_tpot_matrix_tier_key() {
    case ${1:-} in
        supported) printf '%s\n' "$_TPOT_MATRIX_KEY_SUPPORTED" ;;
        legacy)    printf '%s\n' "$_TPOT_MATRIX_KEY_LEGACY" ;;
        *)         return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# matrix_tiers
#   The tier names, one per line, in precedence order. Callers iterate this
#   rather than hard-coding the names, so adding a tier is one edit here.
# ---------------------------------------------------------------------------
matrix_tiers() {
    printf '%s\n' "${_TPOT_MATRIX_TIER_LIST[@]}"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_list_tier TIER [FILE]
#   Print every row of one tier as "id:version", one per line, in file order.
#
#   Return 0 when the tier's key was found and every line under it parsed --
#   INCLUDING when it holds no rows, which is what `[]` declares and what the
#   supported tier ships as. Zero rows and rc 0 is the honest representation of
#   "no upstream ref is pinned yet".
#
#   Return 1, having printed nothing useful, when the tier name is unknown, the
#   file is unreadable, the key is ABSENT, the key appears twice, or a line
#   under the key is not a recognisable entry. Absent and empty are different
#   answers and this is where they are told apart.
#
#   The parser is a three-state walk: outside the key, inside the key, done. A
#   line that starts in column zero with a letter or an underscore is a
#   top-level YAML key and ends the list, which is what stops the next key from
#   being read as part of this tier.
# ---------------------------------------------------------------------------
matrix_list_tier() {
    local tier=${1:-} file key
    if ! key=$(_tpot_matrix_tier_key "$tier"); then
        return 1
    fi
    file=$(_tpot_matrix_path "${2:-}")
    if [[ ! -r $file ]]; then
        return 1
    fi

    local -a lines=()
    mapfile -t lines < "$file"

    local line entry open close
    local in_key=0 seen_key=0 empty_flow=0 count=0
    for line in "${lines[@]}"; do
        line=${line%$'\r'}

        if [[ $line =~ ^[A-Za-z_] ]]; then
            in_key=0
            if [[ $line =~ $_TPOT_MATRIX_TOPKEY_RE ]] && [[ ${BASH_REMATCH[1]} == "$key" ]]; then
                # The same key twice is a file PyYAML and this reader would
                # disagree about -- PyYAML keeps the last, this walk would
                # concatenate both. Refuse instead.
                if (( seen_key == 1 )); then
                    return 1
                fi
                seen_key=1
                in_key=1
                if [[ -n ${BASH_REMATCH[2]} ]]; then
                    empty_flow=1
                fi
            fi
            continue
        fi

        if (( in_key == 0 )); then
            continue
        fi

        # Blank lines and whole-line comments are structure, not entries.
        if [[ $line =~ ^[[:space:]]*(#.*)?$ ]]; then
            continue
        fi

        if [[ $line =~ $_TPOT_MATRIX_ENTRY_RE ]]; then
            # `key: []` followed by entries is not valid YAML and the two
            # readers would part company on it, so it is refused here too.
            if (( empty_flow == 1 )); then
                return 1
            fi
            open=${BASH_REMATCH[1]}
            close=${BASH_REMATCH[4]}
            if [[ $open != "$close" ]]; then
                return 1
            fi
            entry="${BASH_REMATCH[2]}:${BASH_REMATCH[3]}"
            printf '%s\n' "$entry"
            count=$(( count + 1 ))
            continue
        fi

        # Something under our key that is not an entry. Refusing here is the
        # whole point: a skipped line is a release that silently stops being
        # supported, or one that silently starts.
        return 1
    done

    if (( seen_key == 0 )); then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# matrix_list [FILE]
#   Every row of every tier, one per line: the supported tier first, then the
#   legacy tier, each in file order.
#
#   DUPLICATES ACROSS TIERS ARE EXPECTED AND ARE NOT COLLAPSED -- debian:13 is
#   both what today's upstream accepts and one of the nine the old installer
#   ran on, and hiding that would make the output disagree with the file. Use
#   matrix_list_tier when the tier matters, which is most of the time.
#
#   Return 1 when any tier could not be read, or when the two tiers together
#   hold no rows at all: a matrix with nothing in either tier is a broken file,
#   not an empty answer. This is the call preflight uses to tell "the matrix is
#   unreadable" apart from "this box is not in it".
# ---------------------------------------------------------------------------
matrix_list() {
    local file=${1:-} tier out
    local -a all=()
    for tier in "${_TPOT_MATRIX_TIER_LIST[@]}"; do
        if ! out=$(matrix_list_tier "$tier" "$file"); then
            return 1
        fi
        if [[ -n $out ]]; then
            mapfile -t -O "${#all[@]}" all <<< "$out"
        fi
    done
    if (( ${#all[@]} == 0 )); then
        return 1
    fi
    printf '%s\n' "${all[@]}"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_supported_ref [FILE]
#   The upstream ref the supported tier was derived from, or return 1 having
#   printed nothing when there is none -- the key absent, or its value empty.
#   Both mean the same thing operationally: nothing is pinned, so nothing is
#   claimed. The invariant tests/check-matrix-parse.sh asserts is that this and
#   the supported tier are empty together or non-empty together.
#
#   The value is read as a YAML scalar with one layer of matching quotes
#   removed. An unquoted value ends at " #", which is YAML's own rule.
# ---------------------------------------------------------------------------
matrix_supported_ref() {
    local file
    file=$(_tpot_matrix_path "${1:-}")
    if [[ ! -r $file ]]; then
        return 1
    fi

    local -a lines=()
    mapfile -t lines < "$file"

    local line val result='' found=0 first last
    for line in "${lines[@]}"; do
        line=${line%$'\r'}
        if [[ ! $line =~ ^${_TPOT_MATRIX_KEY_REF}:[[:space:]]*(.*)$ ]]; then
            continue
        fi
        val=${BASH_REMATCH[1]}
        while [[ $val == *[[:space:]] ]]; do
            val=${val%?}
        done
        if (( ${#val} >= 2 )); then
            first=${val:0:1}
            last=${val: -1}
            if [[ ( $first == '"' && $last == '"' ) || ( $first == "'" && $last == "'" ) ]]; then
                val=${val:1:${#val}-2}
            elif [[ $val == *" #"* ]]; then
                val=${val%%" #"*}
                while [[ $val == *[[:space:]] ]]; do
                    val=${val%?}
                done
            fi
        fi
        result=$val
        found=1
    done

    if (( found == 0 )) || [[ -z $result ]]; then
        return 1
    fi
    printf '%s\n' "$result"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_ids [FILE]
#   The distinct ids across both tiers, in tier-then-file order, one per line.
#   An id listed in both tiers is printed once.
# ---------------------------------------------------------------------------
matrix_ids() {
    local out
    if ! out=$(matrix_list "${1:-}"); then
        return 1
    fi
    local -a entries=()
    mapfile -t entries <<< "$out"

    local entry id seen=''
    for entry in "${entries[@]}"; do
        id=${entry%%:*}
        if [[ $seen != *"|${id}|"* ]]; then
            printf '%s\n' "$id"
            seen+="|${id}|"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# matrix_versions ID [FILE]
#   The versions listed for one id across both tiers, in tier-then-file order,
#   one per line, each printed once. Returns 1 when the id has no rows.
# ---------------------------------------------------------------------------
matrix_versions() {
    local want=${1:-} out
    if [[ -z $want ]]; then
        return 1
    fi
    if ! out=$(matrix_list "${2:-}"); then
        return 1
    fi
    local -a entries=()
    mapfile -t entries <<< "$out"

    local entry ver seen='' found=0
    for entry in "${entries[@]}"; do
        if [[ ${entry%%:*} != "$want" ]]; then
            continue
        fi
        ver=${entry#*:}
        if [[ $seen == *"|${ver}|"* ]]; then
            continue
        fi
        printf '%s\n' "$ver"
        seen+="|${ver}|"
        found=1
    done
    (( found == 1 ))
}

# ---------------------------------------------------------------------------
# matrix_summary_tier TIER [FILE]
#   One line naming a single tier, grouped by id:
#       debian 11/12/13, ubuntu 20.04/22.04/24.04, linuxmint 20/21/22
#   Returns 1, printing nothing, when the tier is empty or unreadable -- an
#   empty tier has no summary, and a caller must say so in its own words rather
#   than print an empty phrase inside a sentence.
# ---------------------------------------------------------------------------
matrix_summary_tier() {
    local tier=${1:-} out
    if ! out=$(matrix_list_tier "$tier" "${2:-}"); then
        return 1
    fi
    if [[ -z $out ]]; then
        return 1
    fi
    local -a entries=()
    mapfile -t entries <<< "$out"

    local entry id ver cur='' group='' text=''
    for entry in "${entries[@]}"; do
        id=${entry%%:*}
        ver=${entry#*:}
        if [[ $id != "$cur" ]]; then
            if [[ -n $cur ]]; then
                if [[ -n $text ]]; then
                    text+=", "
                fi
                text+="${cur} ${group}"
            fi
            cur=$id
            group=$ver
        else
            group+="/${ver}"
        fi
    done
    if [[ -n $cur ]]; then
        if [[ -n $text ]]; then
            text+=", "
        fi
        text+="${cur} ${group}"
    fi
    printf '%s\n' "$text"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_summary [FILE]
#   THE user-facing sentence about what this installer claims, for the message
#   preflight prints when a box is not supported. It names both tiers and it
#   lets NEITHER of them read as tested.
#
#   With a pin:     supported at the pinned upstream ref, never tested:
#                   debian 13, ubuntu 26.04 (upstream ref fdafa483...);
#                   legacy, documented but not tested: debian 11/12/13, ...
#   Without one:    supported: none -- no upstream ref is pinned, so nothing
#                   is claimed; run tools/pin-upstream.sh. Legacy, documented
#                   but not tested: debian 11/12/13, ...
#
#   NEITHER HALF MAY SAY "TESTED" OF THE SUPPORTED TIER. It said "supported
#   and tested" until 2026-09-04, which was invisible while the tier shipped
#   empty and became a printed claim the moment D-11 pinned a ref: the string
#   went out on every run on a box in neither tier, asserting a test campaign
#   that has never happened. The tier is derived from upstream's gate; the
#   evidence of an install is a dated row in tests/MATRIX-STATUS.md.
#
#   Returns 1, printing nothing, only when the matrix cannot be read at all.
#   An empty supported tier is an answer and gets the second sentence, because
#   "supported: (nothing)" inside a preflight message is how a reader concludes
#   the installer is broken rather than unpinned.
# ---------------------------------------------------------------------------
matrix_summary() {
    local file=${1:-} supported legacy ref text

    if ! matrix_list "$file" >/dev/null 2>&1; then
        return 1
    fi

    if supported=$(matrix_summary_tier supported "$file"); then
        # "never tested" is not hedging. See the note above the function: the
        # tier is derived from the pinned ref's gate, and nothing here has
        # evidence that any row was installed.
        text="supported at the pinned upstream ref, never tested: ${supported}"
        if ref=$(matrix_supported_ref "$file"); then
            text+=" (upstream ref ${ref})"
        fi
    else
        text="supported: none -- no upstream ref is pinned, so nothing is"
        text+=" claimed; run tools/pin-upstream.sh"
    fi

    if legacy=$(matrix_summary_tier legacy "$file"); then
        text+="; legacy, documented but not tested: ${legacy}"
    fi

    printf '%s\n' "$text"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_match ID VERSION_ID [FILE]
#   Print "<tier><TAB><row>" for the matrix row this box matches, or return
#   non-zero having printed nothing: 1 when nothing matches, 2 when the matrix
#   could not be read. Every other lookup in this file goes through here, so
#   there is one implementation of the rule.
#
#   THE MATCH RULE, and it is the same one support-matrix.yml documents and the
#   Ansible role implements: VERSION_ID matches a row when it equals the row's
#   version, or when its first dot-separated component does. The full version
#   is tried first, so ubuntu:20.04 can never be reached by a box reporting
#   20.10 even though both share the major.
#
#   TIER PRECEDENCE IS THE OUTER LOOP. The supported tier is searched
#   completely -- full version, then major -- before the legacy tier is looked
#   at, so a release listed in both is reported as supported. Never the other
#   way round: reporting a tested box as legacy would understate, but the loop
#   order is what stops the far worse inverse.
#
#   ID is compared verbatim against the row. ID_LIKE is not consulted, here or
#   anywhere: see the raspbian fixture and the note in support-matrix.yml.
#
#   An empty VERSION_ID -- Debian testing and sid have none -- matches nothing,
#   which is correct: we do not claim a release that will not name itself.
#   tests/os-release/debian-testing.os-release holds that case.
#
#   MEMBERSHIP IS AN EXACT COMPARISON OF WHOLE ROWS, IN A LOOP, WITH THE
#   RIGHT-HAND SIDE QUOTED so that no character in an untrusted /etc/os-release
#   is a pattern. It is written out rather than done with the shorter
#   `[[ " ${arr[@]} " =~ " $x " ]]` idiom, which upstream's own installer uses
#   for this same job at install.sh:298: the right-hand side is quoted there,
#   so bash compares it LITERALLY against the space-joined array, and measured
#   under bash 5.2.37 it accepts the bare strings "Linux", "GNU/Linux" and
#   "Enterprise Linux" as distribution names, and accepts a value spanning two
#   array elements. Our version of that mistake would be a box declared
#   supported because its id happened to be a substring of the joined matrix.
#   tests/check-matrix-parse.sh proves by execution that this loop rejects
#   every one of those shapes, and runs the upstream idiom beside it as a
#   negative control so the difference is demonstrated rather than asserted.
# ---------------------------------------------------------------------------
matrix_match() {
    local id=${1:-} ver=${2:-} file=${3:-}
    local -a candidates=()
    local -a entries=()
    local tier out entry candidate matched='' total=0

    if [[ -n $ver ]]; then
        candidates+=("$ver")
        if [[ $ver == *.* ]]; then
            candidates+=("${ver%%.*}")
        fi
    fi

    # Every tier is read even after a hit, because an unreadable tier is rc 2
    # whatever else is true: the caller must be able to tell "we could not
    # look" from "we looked and it is not there", and a half-read matrix is
    # the first of those however good the half we read was.
    for tier in "${_TPOT_MATRIX_TIER_LIST[@]}"; do
        if ! out=$(matrix_list_tier "$tier" "$file"); then
            return 2
        fi
        entries=()
        if [[ -n $out ]]; then
            mapfile -t entries <<< "$out"
        fi
        total=$(( total + ${#entries[@]} ))
        if [[ -n $matched || -z $id || ${#candidates[@]} -eq 0 ]]; then
            continue
        fi
        for candidate in "${candidates[@]}"; do
            for entry in "${entries[@]}"; do
                if [[ $entry == "${id}:${candidate}" ]]; then
                    matched="${tier}"$'\t'"${entry}"
                    break 2
                fi
            done
        done
    done

    # Nothing in either tier is a broken file, not an empty answer.
    if (( total == 0 )); then
        return 2
    fi
    if [[ -z $matched ]]; then
        return 1
    fi
    printf '%s\n' "$matched"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_key ID VERSION_ID [FILE]
#   The matrix row this box matches, whichever tier it came from. rc 1 no
#   match, rc 2 the matrix could not be read.
#
#   A ROW ALONE DOES NOT SAY WHETHER THE BOX IS TESTED. Callers that put this
#   in a message or in result.json owe matrix_tier beside it.
# ---------------------------------------------------------------------------
matrix_key() {
    local out rc=0
    # `|| rc=$?` and not a bare assignment: install.sh runs under `set -e`, and
    # a bare `out=$(...)` that fails takes the whole installer down.
    out=$(matrix_match "${1:-}" "${2:-}" "${3:-}") || rc=$?
    if (( rc != 0 )); then
        return "$rc"
    fi
    printf '%s\n' "${out#*$'\t'}"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_tier ID VERSION_ID [FILE]
#   Which tier this box is in: "supported" or "legacy". rc 1 when it is in
#   neither, rc 2 when the matrix could not be read. THIS is the value that
#   belongs in host.json and in result.json, because it is the one that stays
#   true when the pin moves.
# ---------------------------------------------------------------------------
matrix_tier() {
    local out rc=0
    # See matrix_key: `set -e` makes a bare failing assignment fatal.
    out=$(matrix_match "${1:-}" "${2:-}" "${3:-}") || rc=$?
    if (( rc != 0 )); then
        return "$rc"
    fi
    printf '%s\n' "${out%%$'\t'*}"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_supports ID VERSION_ID [FILE]
#   Verdict only, SUPPORTED TIER ONLY. Prints nothing, on any path, so it is
#   safe in a condition.
#
#   True here is the ONLY licence in this codebase for the words "supported" or
#   "tested". A legacy box is false, and a caller that wants to proceed anyway
#   should ask matrix_tier what it is and record the answer, not widen this.
# ---------------------------------------------------------------------------
matrix_supports() {
    local tier
    tier=$(matrix_tier "${1:-}" "${2:-}" "${3:-}" 2>/dev/null) || return 1
    [[ $tier == "supported" ]]
}

# ---------------------------------------------------------------------------
# matrix_known ID VERSION_ID [FILE]
#   Verdict only: is this box in the matrix at all, in either tier. Prints
#   nothing. This is the "we have heard of this release" test -- reachable, not
#   supported. Anything it licenses must name the tier alongside.
# ---------------------------------------------------------------------------
matrix_known() {
    matrix_match "${1:-}" "${2:-}" "${3:-}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# matrix_os_release_field FIELD [FILE]
#   Print one field of an os-release file, unquoted, or return 1 having
#   printed nothing.
#
#   The file is PARSED, never sourced. os-release is shell-compatible syntax,
#   which means sourcing it executes whatever is in it, as root, before we have
#   decided whether we trust this box at all.
#
#   Assignments accumulate and the LAST one wins, which is what sourcing would
#   have done and therefore what every other consumer on the box sees.
# ---------------------------------------------------------------------------
matrix_os_release_field() {
    local field=${1:-} file=${2:-/etc/os-release}
    if [[ -z $field || ! -r $file ]]; then
        return 1
    fi

    local -a lines=()
    mapfile -t lines < "$file"

    local line key val result='' found=0 first last
    for line in "${lines[@]}"; do
        line=${line%$'\r'}
        if [[ $line =~ ^[[:space:]]*(#.*)?$ ]]; then
            continue
        fi
        if [[ ! $line =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            continue
        fi
        key=${BASH_REMATCH[1]}
        val=${BASH_REMATCH[2]}
        if [[ $key != "$field" ]]; then
            continue
        fi

        # Trailing whitespace is not part of the value.
        while [[ $val == *[[:space:]] ]]; do
            val=${val%?}
        done

        # One layer of matching quotes, then the four escapes os-release
        # permits inside double quotes. An unquoted value is taken verbatim,
        # which is how Fedora writes VERSION_ID and how everyone writes ID.
        if (( ${#val} >= 2 )); then
            first=${val:0:1}
            last=${val: -1}
            if [[ $first == '"' && $last == '"' ]]; then
                val=${val:1:${#val}-2}
                val=${val//\\\\/$'\001'}
                val=${val//\\\"/\"}
                val=${val//\\\$/\$}
                val=${val//\\\`/\`}
                val=${val//$'\001'/\\}
            elif [[ $first == "'" && $last == "'" ]]; then
                val=${val:1:${#val}-2}
            fi
        fi

        result=$val
        found=1
    done

    if (( found == 0 )); then
        return 1
    fi
    printf '%s\n' "$result"
    return 0
}

# ---------------------------------------------------------------------------
# matrix_identify [OS_RELEASE_FILE]
#   Print "<id><TAB><version_id>" for a box. VERSION_ID may legitimately be
#   empty (Debian testing); ID may not, and its absence returns 1 -- a file
#   with no ID is not an os-release file we can act on.
#
#   ID is lower-cased. The specification says it already is, and a box that
#   disagrees should be told what it is for the right reason.
# ---------------------------------------------------------------------------
matrix_identify() {
    local file=${1:-/etc/os-release} id ver
    if ! id=$(matrix_os_release_field ID "$file"); then
        return 1
    fi
    if [[ -z $id ]]; then
        return 1
    fi
    id=${id,,}
    if ! ver=$(matrix_os_release_field VERSION_ID "$file"); then
        ver=''
    fi
    printf '%s\t%s\n' "$id" "$ver"
    return 0
}
