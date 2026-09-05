#!/usr/bin/env bats
# SPDX-License-Identifier: Apache-2.0
# tests/bats/notice.bats -- lib/notice.sh, the banner install.sh signs off with.
#
# WHY THIS FILE EXISTS
#   The banner is the last thing a person reads, and on an unattended install
#   it is often the ONLY thing they read. Its three branches make four
#   different factual claims about the box -- what moved, what is listening,
#   what is now a honeypot -- and until 2026-09-05 one of those branches was
#   reachable in a situation where every claim in it was false.
#
#   That was measured, not imagined. The first real install of this project ran
#   `install.sh --check` against a clean Debian 13 box. The playbook failed in
#   finalize (check mode had not written the unit file the enable task needs),
#   install.sh exited 16, and the banner announced:
#
#       T-Pot was NOT fully installed, and THIS BOX HAS CHANGED.
#         * administrative SSH may already have moved to port 64295
#         * TCP/22 may already be a honeypot ...
#   gate-allow: reboot-time the banner as it stood, quoted so this test's reason survives its rewording
#         * Docker, its repository and a daily 02:42 reboot cron job ...
#
#   Nothing of the kind had happened. `_tpot_notice_untouched` could not have
#   caught it either: that predicate is keyed on exit codes 10, 11 and 12, and
#   a --check run that reaches the playbook and fails there exits 16 like any
#   other play failure. The mode is the fact that matters, not the code.
#
# WHAT IS ASSERTED HERE, AND WHAT DELIBERATELY IS NOT
#   The CLAIMS, not the wording. A banner may be reworded; it may not start
#   telling somebody their sshd has moved when it has not. So each test names
#   the property -- "does not assert a change that did not happen" -- and
#   matches only the few strings that ARE the behaviour.

load helper

notice_load() {
    lib_source notice.sh
}

@test "a --check run does not tell the operator their box has changed" {
    notice_load
    notice_set check yes
    notice_set exit_code 16
    run notice_text
    assert_rc 0
    [[ $output != *"THIS BOX HAS CHANGED"* ]] || {
        printf 'a --check run must never claim the box changed. banner:\n%s\n' "$output" >&2
        return 1
    }
    [[ $output == *"--check run"* ]] || {
        printf 'the banner does not say which mode produced it:\n%s\n' "$output" >&2
        return 1
    }
}

@test "a --check run asserts the four things that did NOT happen, in the negative" {
    notice_load
    notice_set check yes
    notice_set exit_code 16
    run notice_text
    local claim
    for claim in "has NOT moved" "is NOT a honeypot" "no dashboard is listening" \
                 "docker was NOT installed"; do
        [[ $output == *"$claim"* ]] || {
            printf 'the check-mode banner does not carry the claim %q:\n%s\n' "$claim" "$output" >&2
            return 1
        }
    done
}

@test "the check-mode banner still admits the one thing check mode does not cover" {
    # install.sh installs ansible-core BEFORE the playbook, outside check
    # mode's reach. On the measured run that was the only change to the box,
    # and a banner that said "nothing changed" without qualification would be
    # the same class of untruth in the other direction.
    notice_load
    notice_set check yes
    notice_set exit_code 16
    run notice_text
    [[ $output == *"prerequisites"* && $output == *"--no-install-deps"* ]] || {
        printf 'the check banner does not mention the dependencies it did install:\n%s\n' "$output" >&2
        return 1
    }
}

@test "a real part-finished run still gets the warnings, which is what they are for" {
    # The branch above must not have swallowed the one that matters: a run
    # that really did stop half way has to say so, loudly.
    notice_load
    notice_set exit_code 16
    run notice_text
    assert_rc 0
    [[ $output == *"THIS BOX HAS CHANGED"* ]] || {
        printf 'a part-finished real run must still warn. banner:\n%s\n' "$output" >&2
        return 1
    }
}

@test "a preflight refusal still reports the box as untouched" {
    notice_load
    notice_set exit_code 11
    run notice_text
    assert_rc 0
    [[ $output == *"Your box is unchanged"* ]] || {
        printf 'exit 11 must render the untouched banner. banner:\n%s\n' "$output" >&2
        return 1
    }
}

@test "check mode never claims an install, whatever the state field says" {
    # Defence in depth: install.sh only sets state=installed when the play
    # succeeded AND it was not a check run, but the banner is the thing an
    # operator believes, so it must not depend on that being right.
    notice_load
    notice_set check yes
    notice_set exit_code 0
    run notice_text
    [[ $output != *"T-Pot is installed."* ]] || {
        printf 'a --check run rendered the installed banner:\n%s\n' "$output" >&2
        return 1
    }
}

@test "the documented copy in README.md is the finished-install one, not a check run" {
    # notice_canonical renders from _NOTICE_DEFAULT, and tests/check-notice-doc.sh
    # diffs it against README.md byte for byte. A `check` default of anything
    # but `no` would silently rewrite the documentation.
    notice_load
    run notice_canonical
    assert_rc 0
    [[ $output == *"T-Pot is installed."* ]] || {
        printf 'the canonical banner is no longer the installed one:\n%s\n' "$output" >&2
        return 1
    }
    [[ $output != *"--check run"* ]] || {
        printf 'the canonical banner leaked the check-mode branch:\n%s\n' "$output" >&2
        return 1
    }
}

@test "the banner names the honeypot on port 22, rather than rendering a placeholder" {
    # install_type was missing from _tpot_fill_notice's pair list until
    # 2026-09-05, so every banner that ever printed said
    #     "decided by the compose file for install type '?'"
    # The default install type is h, whose ssh honeypot is Cowrie, and the
    # canonical copy must name it.
    notice_load
    run notice_canonical
    assert_rc 0
    [[ $output != *"install type '?'"* ]] || {
        printf 'the banner still renders the placeholder install type:\n%s\n' "$output" >&2
        return 1
    }
}

@test "the banner does not assert a fixed time for upstream's daily reboot" {
    # Upstream randomises it -- random_hour: range(0, 5), random_minute:
    # range(0, 60) -- so no fixed time is true of two installs. The default
    # describes the range; install.sh replaces it with the real one after
    # reading the job upstream actually wrote.
    #
    # The assertion mirrors tests/check-reboot-time.sh: look only at the lines
    # that talk about rebooting, drop the two bounds that DESCRIBE the range,
    # and require that nothing resembling a clock survives. Matching the whole
    # banner would flag "between 00:00 and 04:59" -- which is the correct text
    # -- and that is exactly how this test failed when it was first written.
    notice_load
    notice_set state installed
    run notice_canonical
    assert_rc 0
    local leftover
    leftover=$(printf '%s\n' "$output" \
               | grep -iE 'reboot|cron' \
               | sed -e 's/00:00//g' -e 's/04:59//g' \
               | grep -oE '[0-9]{1,2}:[0-9]{2}' || true)
    [[ -z $leftover ]] || {
        printf 'the banner asserts a clock time for the reboot: %q\nbanner:\n%s\n' \
            "$leftover" "$output" >&2
        return 1
    }
    [[ $output == *"randomised"* ]] || {
        printf 'the banner does not say the reboot time is randomised:\n%s\n' "$output" >&2
        return 1
    }
}

@test "a run that read the real schedule prints it instead of the range" {
    # The reboot sentence lives in the FINISHED-install banner -- that is the
    # one an operator reads when the box is about to start rebooting itself --
    # so the state has to say so or this asserts against the wrong branch.
    notice_load
    notice_set state installed
    # gate-allow: reboot-time the fixture IS a measured schedule; this test exists to prove one reaches the banner
    notice_set reboot_cron '01:16 -- upstream randomises this per install'
    run notice_text
    [[ $output == *"01:16"* ]] || {
        printf 'the measured schedule did not reach the banner:\n%s\n' "$output" >&2
        return 1
    }
}
