#!/usr/bin/env bash
#
# tools/example-config.sh -- print a commented answer file to stdout.
#
# WHY THIS FILE EXISTS
#   `install.sh --example-config` prints the same thing. Both of them print a
#   FILE that lives in the tree -- examples/tpot.example.yml -- rather than a
#   here-document, so there is exactly one copy of the example and it cannot
#   drift from the one that ships. This script is the standalone form, for
#   somebody who has the repository but is not about to install anything:
#
#       tools/example-config.sh          > /root/tpot.yml
#       tools/example-config.sh --json   > /root/tpot.json
#       chown root:root /root/tpot.yml && chmod 0600 /root/tpot.yml
#
#   The JSON form exists for a box without PyYAML, where a YAML answer file is
#   a usage error rather than a silent skip. It carries the same settings and
#   the same prose: JSON has no comments, so a key whose name begins with '#'
#   is a comment there, and lib/config.py ignores it.
#
# WHAT IT DOES NOT DO
#   It prints. It does not check for root, open a transcript, create anything,
#   consult the environment or touch the network -- so it is safe anywhere,
#   including on the machine you are typing on rather than the one being
#   installed. Nothing it prints is a real value; every credential in it is a
#   placeholder.

set -euo pipefail

_TPOT_TOOL_DIR=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
_TPOT_REPO_DIR=$(cd -- "${_TPOT_TOOL_DIR}/.." && pwd)

_tpot_example_usage() {
    cat <<'USAGE'
usage: tools/example-config.sh [--yaml | --json] [-h|--help]

  --yaml   print examples/tpot.example.yml   (the default)
  --json   print examples/tpot.example.json  (for a box without PyYAML)

Redirect it to a file outside this directory, then edit it:

  tools/example-config.sh > /root/tpot.yml
  chown root:root /root/tpot.yml
  chmod 0600      /root/tpot.yml
  install.sh --config /root/tpot.yml

An answer file inside this directory is refused, and one that carries a secret
must be owned by root and mode 0600 or 0400. Both rules are checked.
USAGE
}

_tpot_example_die() {
    printf 'example-config: %s\n' "$1" >&2
    printf "Run 'tools/example-config.sh --help' for the two forms it prints.\n" >&2
    # 10 is EX_USAGE in lib/exitcodes.sh, which this script does not source:
    # it deliberately depends on nothing, so that it works in a checkout that
    # has never been run.
    exit 10
}

_tpot_example_main() {
    local wanted=yml

    while (( $# > 0 )); do
        case $1 in
            --yaml|--yml) wanted=yml ;;
            --json)       wanted=json ;;
            -h|--help)    _tpot_example_usage; return 0 ;;
            --)           shift; break ;;
            *)            _tpot_example_die "unknown option '$1'" ;;
        esac
        shift
    done
    if (( $# > 0 )); then
        _tpot_example_die "unexpected argument '$1'"
    fi

    local source_file="${_TPOT_REPO_DIR}/examples/tpot.example.${wanted}"
    if [[ ! -r $source_file ]]; then
        _tpot_example_die "$source_file is missing from this checkout"
    fi

    # cat, not a loop: the file is printed byte for byte, and a shell loop
    # would mangle a backslash or drop a final line without a newline.
    cat -- "$source_file"
}

_tpot_example_main "$@"
