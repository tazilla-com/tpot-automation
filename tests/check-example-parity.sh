#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tests/check-example-parity.sh -- the two example answer files are one file
#                                  written twice, and say the same thing.
#
# WHY THIS GATE EXISTS
#   examples/tpot.example.yml and examples/tpot.example.json are the same
#   document in two syntaxes. The JSON one exists for a box with no PyYAML,
#   and its own header says so outright: "IT IS THE SAME FILE AS
#   examples/tpot.example.yml IN THE OTHER FORM". Both are printed by
#   `install.sh --example-config` and `tools/example-config.sh --json`, so
#   they are the first thing most users will ever read about the variable
#   surface, and for a user without PyYAML the JSON one is the ONLY thing.
#
#   Until this gate, nothing checked that claim. They agreed by care, which is
#   a state and not a property -- the same distinction tests/check-exit-table.sh
#   was written for, and the same one that produced the defect it now prevents.
#   The JSON file had at one point claimed to be GENERATED from the YAML one;
#   that claim was corrected to the truth rather than made true, and this is
#   the check that makes the weaker, honest claim -- that they agree -- into
#   something a build can rely on.
#
# THE FAILURE THIS PREVENTS, CONCRETELY
#   Somebody adds a variable, documents it in the YAML file, and does not
#   touch the JSON one. tests/check-variable-surface.sh does NOT catch it: it
#   compares lib/varschema.json against the example INVENTORY
#   (inventories/example/group_vars/all.yml), and these two files are not in
#   that comparison at all. So the user with PyYAML gets a documented setting
#   and the user without gets silence -- and the second user is by definition
#   on the more awkward box, where they need the documentation more.
#
#   The reverse is worse and quieter: prose corrected in one file and not the
#   other leaves two documents that disagree about what a setting DOES, with
#   nothing to say which is current.
#
# WHAT IS COMPARED
#   1. THE KEY SET, both directions. A key documented in one file and not the
#      other is a failure.
#   2. THE DEFAULT SHOWN for each key, normalised across the two syntaxes:
#      one layer of quotes and all whitespace are dropped, so `"0600"` and
#      '0600' and 0600 compare equal, and `[22, 64294]` equals `[22,64294]`.
#      YAML `null` and JSON `null` are the same value written the same way.
#   3. THE PROSE for each key, word by word. The YAML file carries it as the
#      comment lines immediately above the key; the JSON file carries it as
#      the "#help <key>" array. They are compared after collapsing whitespace,
#      because one wraps at 78 columns and the other is a JSON array whose
#      line breaks fall wherever the array elements do -- so a difference in
#      WRAPPING is not a difference in what the document says, and a gate that
#      failed on it would be teaching people to ignore it.
#
# WHAT IS DELIBERATELY NOT COMPARED
#   The file headers. They describe two different syntaxes and legitimately
#   say different things -- the JSON one has to explain the '#'-prefixed-key
#   convention, which has no YAML counterpart because YAML has comments.
#
# EXIT: 0 clean, 1 findings, 3 could not run.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'example-parity' 'the YAML and JSON answer files document the same surface, identically'

readonly YAML_FILE="$GATE_SCAN_ROOT/examples/tpot.example.yml"
readonly JSON_FILE="$GATE_SCAN_ROOT/examples/tpot.example.json"

if [[ ! -r $YAML_FILE && ! -r $JSON_FILE ]]; then
    gate_skip 'neither example answer file exists, so there is no parity to check.'
fi
[[ -r $YAML_FILE ]] || gate_fail 'examples/tpot.example.yml' 0 'is missing; the YAML half of the pair cannot be compared.'
[[ -r $JSON_FILE ]] || gate_fail 'examples/tpot.example.json' 0 'is missing; a box without PyYAML has no documented answer file at all.'
[[ -r $YAML_FILE && -r $JSON_FILE ]] || gate_end

# ---------------------------------------------------------------------------
# Both files are read by python3 (standard library only) and reduced to the
# same shape: key -> (default, prose). Bash then does the comparing and the
# reporting, so the failure messages read like every other gate's.
#
# Reduced with a parser rather than by hand because the JSON file's own
# convention -- a key whose name begins with '#' is a comment -- is
# lib/config.py's, and reimplementing it with grep is how the two would come
# to disagree about which keys exist.
# ---------------------------------------------------------------------------
TMPBASE=$(mktemp -d "${TMPDIR:-/tmp}/tpot-gate-parity.XXXXXXXX") || exit 2
trap 'rm -rf -- "$TMPBASE"' EXIT INT TERM HUP

# The here-document body begins on the line after the one carrying `<<`, so
# the exit status has to be tested AFTER the terminator rather than with a
# `|| { ... }` on the command line -- which would silently become the first
# two lines of the Python program.
_parity_rc=0
python3 - "$YAML_FILE" "$JSON_FILE" "$TMPBASE" <<'TPOT_PARITY_PY' || _parity_rc=$?
import json
import re
import sys

yaml_path, json_path, out_dir = sys.argv[1:4]

KEY = re.compile(r'^# ((?:tpot|ioc)_[a-z0-9_]+):(.*)$')
COMMENT = re.compile(r'^#\s?(.*)$')


def squash(text):
    """Collapse every run of whitespace. One file wraps at 78 columns and the
    other wraps wherever its JSON array elements fall; that is a difference in
    typesetting, not in meaning."""
    return ' '.join(text.split())


# --- the YAML file ----------------------------------------------------------
# Prose for a key is the run of comment lines immediately above it, back to
# the last blank line. A `# ---` rule or a section banner is separated by a
# blank line from the key it precedes, so it is not picked up.
yaml_keys = {}
block = []
with open(yaml_path, encoding='utf-8') as handle:
    for raw in handle:
        line = raw.rstrip('\n')
        match = KEY.match(line)
        if match:
            yaml_keys[match.group(1)] = {
                'default': match.group(2).strip(),
                'prose': squash(' '.join(block)),
            }
            block = []
            continue
        if not line.strip():
            block = []
            continue
        comment = COMMENT.match(line)
        if comment:
            block.append(comment.group(1))
        else:
            block = []

# --- the JSON file ----------------------------------------------------------
with open(json_path, encoding='utf-8') as handle:
    document = json.load(handle)

json_keys = {}
for name, value in document.items():
    if not name.startswith('# '):
        continue
    key = name[2:].strip()
    if not re.match(r'^(?:tpot|ioc)_[a-z0-9_]+$', key):
        continue
    json_keys[key] = {
        'default': json.dumps(value, ensure_ascii=False, separators=(',', ':')),
        'prose': '',
    }
for name, value in document.items():
    if not name.startswith('#help '):
        continue
    key = name[6:].strip()
    if key not in json_keys:
        continue
    if isinstance(value, list):
        json_keys[key]['prose'] = squash(' '.join(str(v) for v in value))
    else:
        json_keys[key]['prose'] = squash(str(value))

for name, table in (('yaml', yaml_keys), ('json', json_keys)):
    with open('%s/%s.tsv' % (out_dir, name), 'w', encoding='utf-8') as handle:
        for key in sorted(table):
            handle.write('%s\t%s\t%s\n' % (key, table[key]['default'],
                                           table[key]['prose']))
TPOT_PARITY_PY

if (( _parity_rc != 0 )); then
    gate_fail 'examples/tpot.example.json' 0 \
        'could not be read as JSON, or examples/tpot.example.yml could not be scanned (python3 exited %d). The two example answer files were NOT compared.' \
        "$_parity_rc"
    gate_end
fi

declare -A Y_DEFAULT=() Y_PROSE=() J_DEFAULT=() J_PROSE=()

# _slurp_tsv ARRAY_DEFAULT ARRAY_PROSE FILE
#   Split on tabs BY HAND rather than with `IFS=$'\t' read`. Tab is an IFS
#   WHITESPACE character, so `read` collapses a run of them: a key with no
#   default -- `# tpot_min_containers:` in the YAML file, which is how that
#   file writes "unset" -- emits `key<TAB><TAB>prose`, and read then puts the
#   PROSE in the default field. The gate's first run reported exactly that as
#   a defect in the tree, which it was not.
_slurp_tsv() {
    local -n _d=$1
    local -n _p=$2
    local file=$3 line key rest
    while IFS= read -r line || [[ -n $line ]]; do
        [[ -n $line ]] || continue
        key=${line%%$'\t'*}
        rest=${line#*$'\t'}
        [[ -n $key ]] || continue
        _d[$key]=${rest%%$'\t'*}
        _p[$key]=${rest#*$'\t'}
    done < "$file"
}
_slurp_tsv Y_DEFAULT Y_PROSE "$TMPBASE/yaml.tsv"
_slurp_tsv J_DEFAULT J_PROSE "$TMPBASE/json.tsv"

if (( ${#Y_DEFAULT[@]} == 0 )) || (( ${#J_DEFAULT[@]} == 0 )); then
    gate_fail 'examples/tpot.example.yml' 0 \
        'one of the two example files yielded no keys at all (yaml %d, json %d), so nothing was compared. The scan convention has probably changed.' \
        "${#Y_DEFAULT[@]}" "${#J_DEFAULT[@]}"
    gate_end
fi

# _norm -- compare a JSON scalar with a YAML scalar. One layer of quotes and
# every space, exactly as tests/check-variable-surface.sh does it, so the two
# gates cannot disagree about whether two defaults are the same default.
_norm() {
    local v=$1
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    # "Unset" is written two ways and both files say so in their own prose:
    # YAML leaves the value off entirely, JSON has to write `null` because it
    # has no way to express a key with no value. They are the same statement.
    [[ -z $v || $v == 'null' || $v == '~' ]] && { printf '<unset>'; return 0; }
    if [[ ${#v} -gt 1 && ( ${v:0:1} == '"' && ${v: -1} == '"' || ${v:0:1} == "'" && ${v: -1} == "'" ) ]]; then
        v=${v:1:${#v}-2}
    fi
    printf '%s' "${v//[[:space:]]/}"
}

# --- 1. the key set, both directions ---------------------------------------
for key in $(printf '%s\n' "${!Y_DEFAULT[@]}" | LC_ALL=C.UTF-8 sort); do
    [[ -n ${J_DEFAULT[$key]+set} ]] && continue
    gate_fail 'examples/tpot.example.json' 0 \
        'does not document %s, which examples/tpot.example.yml does. The JSON file is the ONLY documented answer file on a box without PyYAML, so that reader is the one who loses the setting.' \
        "$key"
done
for key in $(printf '%s\n' "${!J_DEFAULT[@]}" | LC_ALL=C.UTF-8 sort); do
    [[ -n ${Y_DEFAULT[$key]+set} ]] && continue
    gate_fail 'examples/tpot.example.yml' 0 \
        'does not document %s, which examples/tpot.example.json does. The two files claim to be one document in two syntaxes.' \
        "$key"
done

# --- 2. the default shown ---------------------------------------------------
for key in $(printf '%s\n' "${!Y_DEFAULT[@]}" | LC_ALL=C.UTF-8 sort); do
    [[ -n ${J_DEFAULT[$key]+set} ]] || continue
    [[ $(_norm "${Y_DEFAULT[$key]}") == "$(_norm "${J_DEFAULT[$key]}")" ]] && continue
    gate_fail 'examples/tpot.example.json' 0 \
        '%s is shown as %s here and as %s in examples/tpot.example.yml. A user copying one file gets a different starting point from a user copying the other.' \
        "$key" "$(_norm "${J_DEFAULT[$key]}")" "$(_norm "${Y_DEFAULT[$key]}")"
done

# --- 3. the prose -----------------------------------------------------------
shared_prose=()
one_sided_prose=()
for key in $(printf '%s\n' "${!Y_DEFAULT[@]}" | LC_ALL=C.UTF-8 sort); do
    [[ -n ${J_PROSE[$key]+set} ]] || continue
    y=${Y_PROSE[$key]}
    j=${J_PROSE[$key]}
    if [[ -z $y && -z $j ]]; then
        # Neither side attributes prose to this key, and that is normal: both
        # files document some settings in PAIRS under one paragraph -- the
        # hard floor and the warning threshold for memory, for CPUs, for disk.
        # The second key of such a pair follows the first with no comment
        # between them, so "the prose immediately above" belongs to the first.
        # Both files doing it for the same key is itself evidence they agree.
        shared_prose+=("$key")
        continue
    fi
    if [[ -z $y || -z $j ]]; then
        # One side gives the key its own paragraph and the other folds it into
        # the paragraph above. Not a contradiction, and not worth failing a
        # build over -- but it IS the one shape in which these two files can
        # tell a reader different amounts without this gate noticing, so it is
        # named rather than counted.
        one_sided_prose+=("$key")
        continue
    fi
    [[ $y == "$j" ]] && continue
    # Name the first word that differs. A diff of two paragraphs in a build
    # log is unreadable; the word where they part company is what a reader
    # actually needs in order to find the edit that was made twice and
    # finished once.
    read -r -a ywords <<< "$y"
    read -r -a jwords <<< "$j"
    idx=0
    while (( idx < ${#ywords[@]} && idx < ${#jwords[@]} )); do
        [[ ${ywords[idx]} == "${jwords[idx]}" ]] || break
        idx=$(( idx + 1 ))
    done
    gate_fail 'examples/tpot.example.json' 0 \
        'the prose for %s differs from examples/tpot.example.yml from word %d: this file says "%s", the YAML file says "%s". Wrapping is normalised before comparing, so this is a real difference in what the two documents tell a reader.' \
        "$key" "$(( idx + 1 ))" \
        "${jwords[idx]:-<the text ends here>}" "${ywords[idx]:-<the text ends here>}"
done

if (( ${#shared_prose[@]} > 0 )); then
    gate_info '%d key(s) share a paragraph with the setting above them in BOTH files, so there is no per-key prose to compare: %s' \
        "${#shared_prose[@]}" "${shared_prose[*]}"
fi
if (( ${#one_sided_prose[@]} > 0 )); then
    gate_info 'PROSE NOT COMPARED for %d key(s): one file gives them their own paragraph and the other folds them into the one above. This is the gap in this gate, stated rather than hidden: %s' \
        "${#one_sided_prose[@]}" "${one_sided_prose[*]}"
fi

GATE_CHECKED=${#Y_DEFAULT[@]}
gate_info 'compared %d key(s) in examples/tpot.example.yml against %d in examples/tpot.example.json.' \
    "${#Y_DEFAULT[@]}" "${#J_DEFAULT[@]}"
gate_end
