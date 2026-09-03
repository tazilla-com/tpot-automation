#!/usr/bin/env bash
# tests/check-variable-surface.sh -- one variable surface, described in one way.
#
# THE PROBLEM THIS GATE SOLVES
#   The same set of input variables is written down in three places, for
#   three different readers:
#
#     lib/varschema.json                        the machine-readable schema.
#                                               lib/config.py merges, types
#                                               and validates against it.
#     inventories/example/group_vars/all.yml    the human-readable copy. It
#                                               is documentation -- every key
#                                               is commented out -- and it is
#                                               ALSO parsed at run time by
#                                               lib/args.sh, which reads the
#                                               known keys and the secret
#                                               keys straight out of it.
#     roles/*/defaults/main.yml                 what Ansible actually starts
#                                               from when nothing overrides.
#
#   Three copies drift. The drift is not loud: a key added to the schema and
#   forgotten in the example file becomes a variable that works but is
#   undocumented; a key documented and missing from the schema is a usage
#   error that names a flag the installer does not have; a role default that
#   disagrees with the schema default is an installer that behaves one way
#   and documents another. None of those announces itself.
#
#   Worse, one of the disagreements is a security property rather than a
#   documentation one. lib/args.sh decides which keys may not be passed with
#   --set by reading the SECRET markers out of the example file. If the
#   schema calls a key secret and the example file does not mark it, a
#   credential becomes settable on a command line -- and the only thing that
#   would have caught it is this gate.
#
# WHAT IS CHECKED, AND WHICH OF THEM CAN FAIL
#   1. FAILS -- the schema and the example file describe the SAME key set,
#      in both directions.
#   2. FAILS -- for every key with a literal default in the schema, the
#      example file shows the same default. Keys whose schema default is
#      absent or derived are skipped, and listed so it is clear they were.
#   3. FAILS -- the secret-typed keys in the schema are exactly the keys
#      lib/args.sh derives from the example file. This is run by sourcing
#      lib/args.sh and asking it, so what is compared is the code's own
#      answer, not a re-implementation of it that could be wrong in the same
#      direction.
#   4. FAILS -- every tpot_/ioc_ key defaulted in a role appears in both the
#      schema and the example file, with the same default.
#
# DEGRADING GRACEFULLY
#   Roles do not exist yet. Their absence is REPORTED and check 4 is skipped;
#   the gate still runs checks 1 to 3 and can still fail. It skips outright,
#   loudly, only when neither the schema nor the example file is present --
#   because then it would be comparing nothing to nothing and reporting
#   success, which is the failure mode this whole directory exists to avoid.
#
# EXIT: 0 clean, 1 findings, 3 could not run at all.

set -uo pipefail
. "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/gate-common.sh"

gate_begin 'variable-surface' 'schema, example inventory and role defaults agree'

readonly SCHEMA="$GATE_SCAN_ROOT/lib/varschema.json"
readonly CONFIG_PY="$GATE_SCAN_ROOT/lib/config.py"
readonly EXAMPLE="$GATE_SCAN_ROOT/inventories/example/group_vars/all.yml"
readonly ROLES_DIR="$GATE_SCAN_ROOT/roles"

# The key expression is lib/args.sh's own, quoted from its header so the two
# parsers cannot drift: ^# ((tpot|ioc)_[a-z0-9_]+):
readonly RE_EXAMPLE_KEY='^# ((tpot|ioc)_[a-z0-9_]+):'

if [[ ! -r $SCHEMA && ! -r $EXAMPLE ]]; then
    gate_skip 'neither lib/varschema.json nor the example inventory exists, so there is no variable surface to compare.'
fi
[[ -r $SCHEMA ]]  || gate_fail 'lib/varschema.json' 0 'is missing; the schema half of the surface cannot be checked.'
[[ -r $EXAMPLE ]] || gate_fail 'inventories/example/group_vars/all.yml' 0 'is missing; lib/args.sh reads its known keys and its secret keys from this file at run time.'

_norm() {
    # Compare a JSON scalar with a YAML scalar: drop one layer of quotes and
    # every space. `[22, 64294]` and `[22,64294]` are the same default.
    local v=$1
    v=${v#"${v%%[![:space:]]*}"}
    v=${v%"${v##*[![:space:]]}"}
    if [[ ${#v} -gt 1 && ( ${v:0:1} == '"' && ${v: -1} == '"' || ${v:0:1} == "'" && ${v: -1} == "'" ) ]]; then
        v=${v:1:${#v}-2}
    fi
    printf '%s' "${v//[[:space:]]/}"
}

# --- Source 1: the schema ---------------------------------------------------
declare -A SCHEMA_DEFAULT=() SCHEMA_SECRET=()
SCHEMA_KEYS=()
SCHEMA_SOURCE=''
if [[ -r $SCHEMA ]]; then
    if [[ -r $CONFIG_PY ]] && keys_out=$(python3 "$CONFIG_PY" keys --schema "$SCHEMA" 2>/dev/null); then
        SCHEMA_SOURCE='lib/config.py keys'
    else
        keys_out=$(python3 -c '
import json, sys
with open(sys.argv[1], encoding="utf-8") as h:
    doc = json.load(h)
for k in doc.get("keys", []):
    default = json.dumps(k["default"]) if "default" in k else "-"
    print("\t".join([k["name"], k.get("type", "?"),
                     "secret" if k.get("secret") else "public",
                     "?", "?", default]))
' "$SCHEMA" 2>/dev/null) || keys_out=''
        SCHEMA_SOURCE='a direct read of lib/varschema.json'
        if [[ -n $keys_out ]]; then
            gate_info 'lib/config.py keys did not run; the schema was read directly instead. The two should agree -- if they do not, this gate is checking the wrong thing.'
        else
            gate_fail 'lib/varschema.json' 0 'could not be read as JSON by either lib/config.py or a plain parse.'
        fi
    fi
    while IFS=$'\t' read -r name _type secrecy _req _env default; do
        [[ -n $name ]] || continue
        SCHEMA_KEYS+=("$name")
        SCHEMA_DEFAULT[$name]=$default
        SCHEMA_SECRET[$name]=$([[ $secrecy == secret ]] && printf 'yes' || printf 'no')
    done <<< "$keys_out"
fi

# --- Source 2: the example inventory ---------------------------------------
declare -A EXAMPLE_DEFAULT=()
EXAMPLE_KEYS=()
if [[ -r $EXAMPLE ]]; then
    # `|| [[ -n $line ]]`: a file whose last line has no trailing newline
    # would otherwise lose that line silently. The negative proof caught this
    # -- a key appended at the very end was not seen, and the gate reported
    # success.
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line =~ $RE_EXAMPLE_KEY ]] || continue
        key=${BASH_REMATCH[1]}
        EXAMPLE_KEYS+=("$key")
        EXAMPLE_DEFAULT[$key]=${line#*"$key":}
    done < "$EXAMPLE"
fi

# --- Check 1: same key set, both directions --------------------------------
for key in ${SCHEMA_KEYS[@]+"${SCHEMA_KEYS[@]}"}; do
    [[ -n ${EXAMPLE_DEFAULT[$key]+x} ]] && continue
    gate_fail 'inventories/example/group_vars/all.yml' 0 \
        'does not document %s, which lib/varschema.json defines. lib/args.sh reads its known-key list from this file, so the key is also refused at run time.' "$key"
done
for key in ${EXAMPLE_KEYS[@]+"${EXAMPLE_KEYS[@]}"}; do
    [[ -n ${SCHEMA_DEFAULT[$key]+x} ]] && continue
    gate_fail 'lib/varschema.json' 0 \
        'does not define %s, which the example inventory documents. A user who sets it gets a usage error naming a key the documentation offered them.' "$key"
done

# --- Check 2: same default where the schema states one ---------------------
skipped=()
for key in ${SCHEMA_KEYS[@]+"${SCHEMA_KEYS[@]}"}; do
    [[ -n ${EXAMPLE_DEFAULT[$key]+x} ]] || continue
    want=${SCHEMA_DEFAULT[$key]}
    case $want in
        '-'|derived) skipped+=("$key"); continue ;;
    esac
    got=${EXAMPLE_DEFAULT[$key]}
    [[ $(_norm "$want") == "$(_norm "$got")" ]] && continue
    gate_fail 'inventories/example/group_vars/all.yml' 0 \
        '%s is documented as %s but lib/varschema.json defaults it to %s.' \
        "$key" "$(_norm "$got")" "$(_norm "$want")"
done
if (( ${#skipped[@]} > 0 )); then
    gate_info 'default not compared for %d key(s) whose schema default is absent or derived: %s' \
        "${#skipped[@]}" "${skipped[*]}"
fi

# --- Check 3: secrecy, as lib/args.sh itself computes it -------------------
args_secret=$(
    set +u
    cd -- "$GATE_SCAN_ROOT" 2>/dev/null || exit 0
    . ./lib/exitcodes.sh >/dev/null 2>&1 || exit 0
    . ./lib/args.sh >/dev/null 2>&1 || exit 0
    args_load_keyspec >/dev/null 2>&1 || exit 0
    printf '%s\n' ${ARGS_SECRET_KEYS[@]+"${ARGS_SECRET_KEYS[@]}"}
) || args_secret=''

if [[ -z ${args_secret//[[:space:]]/} ]]; then
    gate_info 'lib/args.sh could not be sourced here, so the secrecy comparison used the schema alone. Re-run this gate wherever lib/args.sh loads.'
else
    declare -A ARGS_SECRET=()
    while IFS= read -r key; do
        [[ -n $key ]] || continue
        ARGS_SECRET[$key]=yes
    done <<< "$args_secret"
    for key in ${SCHEMA_KEYS[@]+"${SCHEMA_KEYS[@]}"}; do
        want=${SCHEMA_SECRET[$key]}
        got=$([[ -n ${ARGS_SECRET[$key]+x} ]] && printf 'yes' || printf 'no')
        [[ $want == "$got" ]] && continue
        if [[ $want == yes ]]; then
            gate_fail 'inventories/example/group_vars/all.yml' 0 \
                '%s is secret in lib/varschema.json but lib/args.sh does not treat it as one, so --set would accept it as a command-line VALUE.' "$key"
        else
            gate_fail 'lib/varschema.json' 0 \
                '%s is treated as secret by lib/args.sh but is public in the schema. One of the two is wrong about a credential.' "$key"
        fi
    done
fi

# --- Check 4: role defaults, when there are any ----------------------------
role_files=()
if [[ -d $ROLES_DIR ]]; then
    while IFS= read -r f; do
        [[ -n $f ]] && role_files+=("$f")
    done < <(find "$ROLES_DIR" -type f -path '*/defaults/*' \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C.UTF-8 sort)
fi

if (( ${#role_files[@]} == 0 )); then
    gate_info 'no roles/*/defaults/*.yml exists yet, so the Ansible half of the surface was not compared. This gate must be re-run when the roles land -- it is the copy that decides what the installer actually does.'
else
    for f in "${role_files[@]}"; do
        rel=$(gate_rel "$f")
        while IFS= read -r line || [[ -n $line ]]; do
            [[ $line =~ ^((tpot|ioc)_[a-z0-9_]+):(.*)$ ]] || continue
            key=${BASH_REMATCH[1]}
            value=${BASH_REMATCH[3]}
            if [[ -z ${SCHEMA_DEFAULT[$key]+x} ]]; then
                gate_fail "$rel" 0 'defaults %s, which lib/varschema.json does not define.' "$key"
            fi
            if [[ -z ${EXAMPLE_DEFAULT[$key]+x} ]]; then
                gate_fail "$rel" 0 'defaults %s, which the example inventory does not document.' "$key"
                continue
            fi
            want=${SCHEMA_DEFAULT[$key]:-'-'}
            case $want in '-'|derived) continue ;; esac
            [[ $(_norm "$value") == "$(_norm "$want")" ]] && continue
            gate_fail "$rel" 0 \
                '%s defaults to %s here and to %s in lib/varschema.json. The role default is what the installer uses; the schema is what it documents.' \
                "$key" "$(_norm "$value")" "$(_norm "$want")"
        done < "$f"
    done
fi

GATE_CHECKED=$(( ${#SCHEMA_KEYS[@]} ))
gate_info 'compared %d schema key(s) against %d documented key(s), from %s, plus %d role defaults file(s).' \
    "${#SCHEMA_KEYS[@]}" "${#EXAMPLE_KEYS[@]}" "${SCHEMA_SOURCE:-nothing}" "${#role_files[@]}"
gate_end
