# lib/notice.sh -- THE notice block. It exists exactly once, and this is it.
#
# WHY THIS FILE EXISTS
#   A finished T-Pot box has one property that will lock a stranger out of
#   their own machine: the host's administrative sshd moves to port 64295 and
#   TCP/22 is taken over by a honeypot, which accepts the connection and
#   answers as though it were a real system. Somebody who disconnects without
#   reading that will reconnect on 22, appear to succeed, and be talking to a
#   decoy.
#
#   So the text is written down once, here, and everything that repeats it
#   reads it from here:
#     * install.sh prints it (notice_print) as the last thing it does;
#     * lib/result.sh copies notice_lines and notice_ports_tsv into the
#       "notice" and "ports" members of result.json;
#     * README.md embeds notice_canonical between markers, and
#       tests/check-notice-doc.sh fails the build when the two have drifted.
#
# WHY THE PORTS ARE VARIABLES AND NEVER LITERALS
#   The same four numbers are checked by preflight, asserted by verification,
#   announced by this notice and recorded in result.json. Written as literals
#   in four places they would drift, and the failure mode of that drift is a
#   notice that tells a user to connect somewhere nothing is listening. There
#   is one setter (notice_set) and one reader (notice_get), so what is
#   checked, what is said and what is recorded cannot disagree.
#
# WHY THE HONEYPOT ON TCP/22 IS NOT NAMED AS A CONSTANT
#   It is not the same program in every edition. Upstream binds Cowrie there
#   in the hive/standard edition, Endlessh in the tarpit edition and Beelzebub
#   in the LLM edition, and for the remaining editions upstream's own
#   documentation does not say. The sentence is therefore DERIVED from
#   install_type, and where the answer is not known it says a honeypot rather
#   than naming the wrong one. This is the one sentence that stops a stranger
#   locking themselves out of their own machine, so it has to be true and not
#   approximately true.
#
#   Sources, at the upstream copy read on 2026-09-02: upstream's own
#   "Required Ports" table lists Cowrie, Endlessh and Beelzebub on tcp/22, and
#   notes that ports repeat across editions because each edition ships a
#   different compose file. RE-CHECK THE TABLE BELOW AT PIN TIME against
#   compose/<edition>.yml of the ref actually pinned; it is a property of
#   upstream, not of this project.
#
# HOW TO USE IT
#   . "$REPO_DIR/lib/notice.sh"
#   notice_set admin_ssh_port "$(config get tpot_admin_ssh_port)"   # etc.
#   notice_set install_type   "$(config get tpot_install_type)"
#   notice_set state installed
#   notice_print                    # to the human stream (stderr, hence the log)
#
# shellcheck shell=bash

if [[ -n ${_TPOT_NOTICE_SH_LOADED:-} ]]; then
    return 0 2>/dev/null || exit 0
fi
_TPOT_NOTICE_SH_LOADED=1

# ---------------------------------------------------------------------------
# The state of the world this notice describes.
#
# Every value has a shipped default, and the defaults are the placeholders
# README.md embeds -- so `notice_canonical` is renderable on a box that has
# installed nothing, which is what makes the documentation check possible.
#
# Keys, and nothing else is accepted:
#
#   state              installed | pending
#                      `pending` means T-Pot is NOT on this box: the run ended
#                      before the install completed. The banner then says what
#                      has NOT happened, because a notice that announces a
#                      moved sshd on a box whose sshd did not move is worse
#                      than no notice at all. Whether the box was left
#                      UNCHANGED is a separate question, and it is answered
#                      from exit_code rather than assumed -- see
#                      _tpot_notice_untouched.
#   install_type       h | s | l | i | m | t, upstream's edition letter.
#                      EMPTY when the run never got far enough to know, and
#                      empty is handled: the honeypot on TCP/22 is then
#                      described but not named.
#   admin_ssh_port     where the host's own sshd now listens          (64295)
#   dashboard_port     the T-Pot web dashboard                        (64297)
#   elasticsearch_port loopback-only Elasticsearch                    (64298)
#   honeypot_ssh_port  the port a honeypot takes over from sshd       (22)
#                      Upstream binds it here as a consequence of moving
#                      sshd; it is not a knob today. It is named once, here,
#                      so the sentence, the check and the record agree.
#   host               what to type after `you@` and in the dashboard URL
#   web_user           the dashboard username
#   telemetry          off | on   -- upstream T-Pot's own data submission
#   ioc                off | on   -- IoC forwarding (always off in this release)
#   firewall           none       -- the only accepted mode in this release
#   reboot_required    true | false
#   log                path of this run's transcript
#   result             path of this run's result.json
#   check              yes | no -- whether this was a --check run. It gets its
#                      own banner because NEITHER of the other two is true of
#                      one: the playbook changed nothing, so the part-finished
#                      warnings are all false, and yet `untouched` is keyed on
#                      exit codes 10/11/12 and a --check run that fails inside
#                      the playbook exits 16.
#   reboot_cron        when upstream's daily reboot job fires. It is a FIELD
#                      and not a literal because upstream RANDOMISES it: its
#                      own task is called "Setup a randomized daily reboot"
#                      and reads
#                          random_minute: "{{ range(0, 60) | random }}"
#                          random_hour:   "{{ range(0, 5)  | random }}"
#                      (installer/install/tpot.yml:1229-1239 at the pinned
#                      ref). So no fixed time is true of two installs, and
#                      gate-allow: reboot-time both times are quoted on purpose -- the claim this tree copied for months, and the measurement that refuted it
#                      every copy of this text said 02:42; the box that found it reboots at 01:16.
#                      The default is the honest description of the range, and
#                      install.sh replaces it with the schedule THIS box got.
#   exit_code          the code this run is about to exit with
# ---------------------------------------------------------------------------
declare -gA _NOTICE=(
    [state]='pending'
    [check]='no'
    [reboot_cron]='a time upstream randomised between 00:00 and 04:59'
    [install_type]=''
    [admin_ssh_port]='64295'
    [dashboard_port]='64297'
    [elasticsearch_port]='64298'
    [honeypot_ssh_port]='22'
    [host]='<host>'
    [web_user]='<tpot_web_user>'
    [telemetry]='off'
    [ioc]='off'
    [firewall]='none'
    [reboot_required]='true'
    [log]='/var/log/tpot-automation/install-<run-id>.log'
    [result]='/var/lib/tpot-automation/result.json'
    [exit_code]='20'
)

# The shipped defaults, kept so that notice_canonical can render the
# documentation copy after install.sh has already overwritten the live ones.
#
# Two of them are overridden below rather than taken from the live table:
# `state`, because the documented copy is the one a finished install prints,
# and `install_type`, because the documented copy must be deterministic and
# the product's own default install type is `h`. The LIVE default for
# install_type stays empty on purpose -- if install.sh never sets it, the
# banner must fall back to the unnamed wording rather than assert Cowrie on a
# box that is running Endlessh.
declare -gA _NOTICE_DEFAULT=()
for _tpot_notice_k in "${!_NOTICE[@]}"; do
    _NOTICE_DEFAULT[$_tpot_notice_k]=${_NOTICE[$_tpot_notice_k]}
done
unset -v _tpot_notice_k
_NOTICE_DEFAULT[state]='installed'
_NOTICE_DEFAULT[install_type]='h'

# ---------------------------------------------------------------------------
# notice_set KEY VALUE
#   Set one field. An unknown key is a programming error and says so on
#   stderr, returning 1 -- silently accepting it would produce a notice with a
#   field nobody notices is missing.
#   Tabs and newlines are stripped: these values are also serialised into a
#   TSV interchange file and into result.json.
# ---------------------------------------------------------------------------
notice_set() {
    local key=${1-} value=${2-}
    if [[ -z $key || -z ${_NOTICE[$key]+x} ]]; then
        printf 'notice_set: unknown field "%s"\n' "$key" >&2
        return 1
    fi
    value=${value//$'\t'/ }
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    _NOTICE[$key]=$value
    return 0
}

# ---------------------------------------------------------------------------
# notice_get KEY
#   Print one field. Unknown key: nothing on stdout, exit 1.
# ---------------------------------------------------------------------------
notice_get() {
    local key=${1-}
    [[ -n $key && -n ${_NOTICE[$key]+x} ]] || return 1
    printf '%s\n' "${_NOTICE[$key]}"
    return 0
}

# ---------------------------------------------------------------------------
# notice_ssh_honeypot
#   The name of the honeypot upstream binds to honeypot_ssh_port for this
#   install type, or NOTHING when upstream's documentation does not say.
#
#   The three known rows are upstream's; the silence for s, i and m is also
#   upstream's, and it is reproduced here rather than filled in. An unknown
#   letter -- a future edition, or a value that never reached this file --
#   lands in the same silent branch, which is the safe direction: the banner
#   still warns about the port, it just does not name a program.
# ---------------------------------------------------------------------------
notice_ssh_honeypot() {
    case ${_NOTICE[install_type]} in
        h) printf 'Cowrie\n' ;;
        t) printf 'Endlessh\n' ;;
        l) printf 'Beelzebub\n' ;;
        *) return 1 ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# notice_ports_tsv
#   The four ports as `name<TAB>number`, in the order result.json wants them.
#   This is the ONLY place the mapping from a port's role to its number is
#   turned into data, and lib/result.sh builds result.json's "ports" object
#   from exactly this output.
#
#   The fourth role is `honeypot_ssh`, not the name of a honeypot: which
#   program binds it is an edition property, so a role name that hard-coded
#   one would be false on two of the six editions.
# ---------------------------------------------------------------------------
notice_ports_tsv() {
    printf 'admin_ssh\t%s\n'     "${_NOTICE[admin_ssh_port]}"
    printf 'dashboard\t%s\n'     "${_NOTICE[dashboard_port]}"
    printf 'elasticsearch\t%s\n' "${_NOTICE[elasticsearch_port]}"
    printf 'honeypot_ssh\t%s\n'  "${_NOTICE[honeypot_ssh_port]}"
    return 0
}

# ---------------------------------------------------------------------------
# notice_lines
#   The short form: result.json's "notice" array, one entry per line.
#
#   These say the same things the banner says, in the compressed form a
#   machine consumer can act on, and they are generated from the same fields
#   -- so an operator reading result.json and a human reading the terminal
#   cannot be told different port numbers.
#
#   With state=pending nothing is printed: none of these statements is true of
#   a box T-Pot was never installed on, and an empty array is the honest
#   answer.
#
#   The last line is upstream's, not ours, and it is here because it is the
#   change to the host that surprises people most after the ports: upstream's
#   playbook installs a root cron job that reboots the machine daily.
# ---------------------------------------------------------------------------
notice_lines() {
    [[ ${_NOTICE[state]} == 'installed' ]] || return 0
    local pot
    printf 'host sshd has moved to %s\n' "${_NOTICE[admin_ssh_port]}"
    if pot=$(notice_ssh_honeypot); then
        printf 'TCP/%s is now the %s honeypot, not administrative SSH\n' \
            "${_NOTICE[honeypot_ssh_port]}" "$pot"
    else
        printf 'TCP/%s is now a honeypot, not administrative SSH\n' \
            "${_NOTICE[honeypot_ssh_port]}"
    fi
    if [[ ${_NOTICE[firewall]} == 'none' ]]; then
        printf 'this installer added no firewall rules of its own\n'
        printf 'upstream sets the firewalld public zone to ACCEPT and SELinux to permissive on Red Hat family hosts\n'
    else
        printf 'firewall mode %s was requested\n' "${_NOTICE[firewall]}"
    fi
    printf 'the install account is in the docker group, which is equivalent to root here\n'
    printf 'upstream installed a root cron job that reboots this host daily, at %s\n' \
        "${_NOTICE[reboot_cron]}"
    return 0
}

# ---------------------------------------------------------------------------
# _tpot_notice_onoff VALUE
#   `off` -> DISABLED, anything else -> ENABLED. One helper so the two
#   telemetry/forwarding lines cannot disagree about what "off" renders as.
# ---------------------------------------------------------------------------
_tpot_notice_onoff() {
    if [[ ${1-} == 'off' || ${1-} == 'false' || ${1-} == '0' ]]; then
        printf 'DISABLED'
    else
        printf 'ENABLED '
    fi
}

# ---------------------------------------------------------------------------
# _tpot_notice_untouched
#   True when this run can honestly claim the box is UNCHANGED.
#
#   Derived from exit_code, which this file already holds, so it needs no new
#   input from install.sh. 10 (usage), 11 (preflight) and 12 (inconclusive)
#   are the three codes whose contract is that nothing was mutated: preflight
#   runs before the first change for exactly that reason. Every other code --
#   including 16, where T-Pot IS installed and an assertion failed -- reaches
#   the box, so the banner warns instead of reassuring.
#
#   The default direction is the safe one: an unrecognised or empty code is
#   treated as "the box was changed", because telling somebody their machine
#   is untouched when its sshd has moved is the failure that locks them out.
# ---------------------------------------------------------------------------
_tpot_notice_untouched() {
    case ${_NOTICE[exit_code]} in
        10|11|12) return 0 ;;
        *)        return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# notice_text
#   The whole banner, on stdout, rendered from the current field values.
#
#   The text is deliberately plain ASCII: the transcript is written with
#   LC_ALL=C.UTF-8 and is diffed byte-for-byte against README.md, and a dash
#   that renders as three bytes in one place and a question mark in another is
#   a diff nobody can read. C.UTF-8 rather than plain C, because a non-UTF-8
#   locale makes ansible-core refuse to start at all -- and ansible-core is
#   what drives the install.
# ---------------------------------------------------------------------------
notice_text() {
    local rule='================================================================'
    local -a out=()
    local pot

    if [[ ${_NOTICE[state]} != 'installed' ]]; then
        if [[ ${_NOTICE[check]} == 'yes' ]]; then
            # WHY THIS BRANCH EXISTS, MEASURED RATHER THAN IMAGINED
            #   On 2026-09-05 a `--check` run against a clean Debian 13 box
            #   failed inside the playbook and exited 16, so it rendered the
            #   part-finished banner below: it announced that the box had
            #   changed, that administrative SSH may already have moved, that
            #   TCP/22 may already be a honeypot, and that docker and a daily
            #   reboot cron job may already be installed. Every one of those
            #   was false -- check mode had changed nothing. A banner that
            #   tells an operator to go and check four things that cannot have
            #   happened is worse than no banner, because the next one they
            #   read will be believed a little less.
            #
            #   `untouched` could not cover it: that predicate is keyed on
            #   exit codes 10, 11 and 12, and a --check run that gets as far as
            #   the playbook and fails there exits 16 like any other play
            #   failure. The mode is the fact that matters here, not the code.
            out+=(
                "$rule"
                " This was a --check run. The playbook changed nothing."
                "$rule"
                "  Check mode does not touch the box, so none of the changes an"
                "  install makes have been made:"
                ""
                "    * administrative SSH has NOT moved to port ${_NOTICE[admin_ssh_port]}"
                "    * TCP/${_NOTICE[honeypot_ssh_port]} is NOT a honeypot; it is whatever it was before"
                "    * no dashboard is listening on ${_NOTICE[dashboard_port]}"
                "    * docker was NOT installed and no reboot job was created"
                ""
                "  One thing IS different, and check mode does not cover it:"
                "  install.sh installs its own prerequisites -- ansible-core"
                "  above all -- BEFORE the playbook starts, so those may be on"
                "  this box now. --no-install-deps is how a run refuses that."
                ""
                "  A --check run cannot prove an install will succeed. Tasks"
                "  whose input is a file an earlier task would have written"
                "  have nothing to read, and report that rather than guessing."
                ""
            )
        elif _tpot_notice_untouched; then
            out+=(
                "$rule"
                " T-Pot was NOT installed. Your box is unchanged."
                "$rule"
                "  This run stopped before it changed anything, so none of the"
                "  changes an install makes have been made:"
                ""
                "    * administrative SSH has NOT moved to port ${_NOTICE[admin_ssh_port]}"
                "    * TCP/${_NOTICE[honeypot_ssh_port]} is NOT a honeypot; it is whatever it was before"
                "    * no dashboard is listening on ${_NOTICE[dashboard_port]}"
                ""
            )
        else
            out+=(
                "$rule"
                " T-Pot was NOT fully installed, and THIS BOX HAS CHANGED."
                "$rule"
                "  This run got past its checks and then stopped, so the host"
                "  is in a part-finished state. CHECK THESE BEFORE YOU LOG OUT,"
                "  because any of them may already be true:"
                ""
                "    * administrative SSH may already have moved to port ${_NOTICE[admin_ssh_port]}"
                "      -- test it with a SECOND session before closing this one:"
                "            ssh -p ${_NOTICE[admin_ssh_port]} you@${_NOTICE[host]}"
                "    * TCP/${_NOTICE[honeypot_ssh_port]} may already be a honeypot that answers as if it"
                "      were a real shell"
                "    * Docker, its repository and a daily reboot cron job"
                "      may already be installed"
                ""
                "  Read the transcript below before re-running anything."
                ""
            )
        fi
        out+=(
            "  Transcript: ${_NOTICE[log]}"
            "  Result:     ${_NOTICE[result]}      exit code ${_NOTICE[exit_code]}"
            "$rule"
        )
        printf '%s\n' "${out[@]}"
        return 0
    fi

    out+=(
        "$rule"
        " T-Pot is installed. READ THIS BEFORE YOU LOG OUT."
        "$rule"
        "  Administrative SSH has MOVED to port ${_NOTICE[admin_ssh_port]}:"
        "        ssh -p ${_NOTICE[admin_ssh_port]} you@${_NOTICE[host]}"
        "  Write that command down before you disconnect."
        ""
    )

    if pot=$(notice_ssh_honeypot); then
        out+=(
            "  PORT ${_NOTICE[honeypot_ssh_port]} IS NOW ${pot^^}, A HONEYPOT. It is not your"
            "  administrative SSH and it will never give you a shell on this"
            "  machine. Everything typed there is recorded as attacker"
            "  activity."
        )
    else
        out+=(
            "  PORT ${_NOTICE[honeypot_ssh_port]} IS NOW A HONEYPOT. It is not your administrative"
            "  SSH and it will never give you a shell on this machine."
            "  Everything typed there is recorded as attacker activity."
            "  Which honeypot answers there is decided by the compose file"
            "  for install type '${_NOTICE[install_type]:-?}'; run \`dps\` on the host to see it."
        )
    fi

    out+=(
        ""
        "  Dashboard:      https://${_NOTICE[host]}:${_NOTICE[dashboard_port]}/    user: ${_NOTICE[web_user]}"
        "                  (self-signed certificate -- your browser will warn;"
        "                  that is normal here)"
        "  Elasticsearch:  127.0.0.1:${_NOTICE[elasticsearch_port]}          (loopback only)"
        ""
    )

    if [[ ${_NOTICE[firewall]} == 'none' ]]; then
        out+=(
            "  This host is now an internet-facing honeypot. Ports other than"
            "  the three above are deliberately exposed to attack, and THIS"
            "  INSTALLER ADDED NO FIREWALL RULES OF ITS OWN -- see"
            "  docs/firewall.md."
        )
    else
        out+=(
            "  This host is now an internet-facing honeypot. Ports other than"
            "  the three above are deliberately exposed to attack. Firewall"
            "  mode ${_NOTICE[firewall]} was requested -- see docs/firewall.md."
        )
    fi

    # What upstream's own playbook did. Saying only "no firewall was
    # configured" would imply nothing was touched, and that is false on every
    # distribution and most false on the Red Hat family, where upstream opens
    # the firewall that was there and puts SELinux into permissive mode.
    out+=(
        ""
        "  WHAT UPSTREAM T-POT CHANGED HERE. Installing T-Pot is not a no-op"
        "  on the rest of the system. Upstream's playbook moved sshd to"
        "  ${_NOTICE[admin_ssh_port]}, disabled the DNS stub listener, added Docker's own"
        "  repository and installed Docker, removed packages it considers"
        "  conflicting, put the install account in the \`docker\` group --"
        "  which is equivalent to root on this box -- and added a root cron"
        "  job that REBOOTS THIS HOST EVERY DAY, at"
        "  ${_NOTICE[reboot_cron]}."
        "  On Red Hat family distributions it also set the firewalld public"
        "  zone target to ACCEPT and put SELinux into monitor (permissive)"
        "  mode, so a firewall that was filtering here before is not"
        "  filtering now."
        ""
        "  Upstream T-Pot telemetry:  $(_tpot_notice_onoff "${_NOTICE[telemetry]}")   (community submission to"
        "                             sicherheitstacho.eu)"
        "  IoC forwarding:            $(_tpot_notice_onoff "${_NOTICE[ioc]}")   (not implemented in this release)"
        ""
    )

    if [[ ${_NOTICE[reboot_required]} == 'true' ]]; then
        out+=("  A REBOOT IS REQUIRED.  After it:   install.sh --verify-only")
    else
        out+=("  No reboot is required. This box has been installed and verified.")
    fi

    out+=(
        "  Transcript: ${_NOTICE[log]}"
        "  Result:     ${_NOTICE[result]}      exit code ${_NOTICE[exit_code]}"
        "$rule"
    )

    printf '%s\n' "${out[@]}"
    return 0
}

# ---------------------------------------------------------------------------
# notice_canonical
#   notice_text rendered from the SHIPPED defaults, with state=installed and
#   install_type=h.
#
#   This is the copy README.md embeds and tests/check-notice-doc.sh diffs, so
#   the documented block is deterministic on any box and does not depend on
#   whether an install happened to run first. It restores the live values
#   afterwards, so calling it is safe at any point.
# ---------------------------------------------------------------------------
notice_canonical() {
    local key
    local -A saved=()
    for key in "${!_NOTICE[@]}"; do
        saved[$key]=${_NOTICE[$key]}
        _NOTICE[$key]=${_NOTICE_DEFAULT[$key]}
    done
    notice_text
    for key in "${!saved[@]}"; do
        _NOTICE[$key]=${saved[$key]}
    done
    return 0
}

# ---------------------------------------------------------------------------
# notice_print
#   The banner to the human stream.
#
#   stderr, not stdout: stdout belongs to --json, and while lib/log.sh is
#   running both descriptors go into the redaction pump, so printing here is
#   also what puts the banner in the transcript.
# ---------------------------------------------------------------------------
notice_print() {
    notice_text >&2
    return 0
}
