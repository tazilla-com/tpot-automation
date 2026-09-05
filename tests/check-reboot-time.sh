#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# tests/check-reboot-time.sh -- no document names a fixed time for upstream's
# daily reboot, because upstream does not have one.
#
# THE FAILURE THIS GATE EXISTS TO PREVENT
#   Upstream T-Pot installs a root cron job that reboots the host every night.
#   Its own task is named "Setup a randomized daily reboot" and it picks the
#   schedule when it runs:
#
#       random_minute: "{{ range(0, 60) | random }}"
#       random_hour:   "{{ range(0, 5)  | random }}"
#       (installer/install/tpot.yml:1229-1239 at the pinned ref)
#
#   So the time differs on every install and NO fixed time can be true of two
#   boxes. Until 2026-09-05 this tree stated "02:42" in SEVEN files -- README.md
#   twice over, SECURITY.md, docs/firewall.md, lib/varschema.json, the example
#   inventory, both example answer files, and the closing notice itself, which
#   is the single piece of text an unattended install is most likely to be read
#   from. It was wrong everywhere, and it was wrong in the same words, because
#   it had been copied rather than checked.
#
#   gate-allow: reboot-time the measurement that refuted it, quoted so a reader can check it
#   The first real install measured it: that box reboots at 01:16, and nobody
#   planning maintenance around the copied time would have been rebooted then.
#
#   One wrong sentence in seven places is a class, not a typo, and the class is
#   "a fact about somebody else's software, copied forward, never re-read". The
#   remedy for the reboot time specifically is that install.sh now READS the job
#   upstream wrote and prints that; the remedy for the class is this file.
#
# WHAT IT FORBIDS
#   A line that talks about rebooting or about upstream's cron job AND carries a
#   clock literal. The two bounds of the documented range, 00:00 and 04:59, are
#   not clock literals in that sense -- they describe the range rather than
#   claiming a time -- so they are allowed by name.
#
# HOW TO SATISFY IT
#   Describe the randomisation, or name where the real value is: the notice
#   prints it, and `crontab -l -u root` holds it. If a line genuinely must
#   quote the historical error -- the tests and the code comments that explain
#   this defect do -- mark it:
#
#       # gate-allow: <rule-id> <why this line quotes a time>
set -o errexit -o nounset -o pipefail

_here=$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd)
# shellcheck source=tests/gate-common.sh
. "$_here/gate-common.sh"

ALLOW_ID='reboot-time'

gate_begin 'reboot-time' 'no document names a fixed time for upstream daily reboot'
gate_rule "$ALLOW_ID"

# A clock literal. The range bounds are excluded in the loop, not here, so the
# failure message can still show what it matched.
TIME_RE='(^|[^0-9:])([0-9]{1,2}:[0-9]{2})([^0-9:]|$)'
# The subject. Without this a gate over clock literals would flag every
# timestamp, duration and log line in the tree.
SUBJ_RE='[Rr]eboot|[Cc]ron'

while IFS= read -r path; do
    rel=$(gate_rel "$path")
    GATE_CHECKED=$(( GATE_CHECKED + 1 ))
    lineno=0
    while IFS= read -r line; do
        lineno=$(( lineno + 1 ))
        [[ $line =~ $SUBJ_RE ]] || continue
        [[ $line =~ $TIME_RE ]] || continue
        found=${BASH_REMATCH[2]}
        # The documented bounds of upstream's own range describe it; they do
        # not assert a time this box will reboot at.
        [[ $found == '00:00' || $found == '04:59' ]] && continue
        gate_exempt "$path" "$lineno" "$ALLOW_ID" && continue
        gate_fail "$rel" "$lineno" \
            'names %s as a reboot time -- upstream randomises it per install, so no fixed time is true. Describe the range, or point at the notice, which prints the real one' \
            "$found"
    done < "$path"
done < <(gate_files)

gate_end
