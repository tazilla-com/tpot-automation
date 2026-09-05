# tpot-automation

An unattended installer for the [T-Pot](https://github.com/telekom-security/tpotce) honeypot
platform. It preflights the host, installs its own prerequisites, drives upstream T-Pot's
installer in upstream's unattended mode at a pinned ref, configures what that mode leaves
undone, verifies the result, and exits with a code a caller can branch on.

It asks no questions, requires no terminal, and vendors no upstream code.

**Version 0.1.0.** Tested on Debian 13 (x86_64). See [Supported platforms](#supported-platforms)
and `tests/MATRIX-STATUS.md`.

---

## Contents

- [What it does to the host](#what-it-does-to-the-host)
- [Requirements](#requirements)
- [Supported platforms](#supported-platforms)
- [Installing](#installing)
- [Exit codes](#exit-codes)
- [Configuration](#configuration)
- [Credentials](#credentials)
- [The upstream pin](#the-upstream-pin)
- [Telemetry](#telemetry)
- [Firewall](#firewall)
- [Scope](#scope)
- [Licence](#licence)
- [Documentation](#documentation)

---

## What it does to the host

Read this before running anything. A T-Pot install is not reversible in place, and two of its
effects will lock you out of the machine if you are not expecting them.

**Administrative SSH moves to TCP/64295.** Upstream reconfigures `sshd`. After the install,
`ssh you@host` on port 22 does not reach this machine's shell.

**TCP/22 becomes a honeypot.** It accepts connections and presents what looks like a shell.
Nothing typed there executes on the host; everything typed there is recorded as attacker
activity. Which honeypot listens depends on the edition — Cowrie in the default `h` (hive)
edition, Endlessh in `t` (tarpit), Beelzebub in `l` (LLM).

**The host becomes internet-facing by design.** Ports other than administrative SSH, the
dashboard and the loopback-only search engine are exposed on purpose. This installer adds no
firewall rules; see [Firewall](#firewall).

**Use a dedicated machine.** Upstream removes packages it considers conflicting, adds the install
account to the `docker` group (equivalent to root on that host), and installs a root cron job
that reboots the machine nightly at a time it randomises per install.

`install.sh` prints the following notice on a successful run. It is generated from
`lib/notice.sh` and embedded here verbatim; `tests/check-notice-doc.sh` fails the build if the two
differ. Regenerate with `tests/check-notice-doc.sh --print`; do not edit it by hand.

<!-- BEGIN GENERATED NOTICE - tests/check-notice-doc.sh -->
```
================================================================
 T-Pot is installed. READ THIS BEFORE YOU LOG OUT.
================================================================
  Administrative SSH has MOVED to port 64295:
        ssh -p 64295 you@<host>
  Write that command down before you disconnect.

  PORT 22 IS NOW COWRIE, A HONEYPOT. It is not your
  administrative SSH and it will never give you a shell on this
  machine. Everything typed there is recorded as attacker
  activity.

  Dashboard:      https://<host>:64297/    user: <tpot_web_user>
                  (self-signed certificate -- your browser will warn;
                  that is normal here)
  Elasticsearch:  127.0.0.1:64298          (loopback only)

  This host is now an internet-facing honeypot. Ports other than
  the three above are deliberately exposed to attack, and THIS
  INSTALLER ADDED NO FIREWALL RULES OF ITS OWN -- see
  docs/firewall.md.

  WHAT UPSTREAM T-POT CHANGED HERE. Installing T-Pot is not a no-op
  on the rest of the system. Upstream's playbook moved sshd to
  64295, disabled the DNS stub listener, added Docker's own
  repository and installed Docker, removed packages it considers
  conflicting, put the install account in the `docker` group --
  which is equivalent to root on this box -- and added a root cron
  job that REBOOTS THIS HOST EVERY DAY, at
  a time upstream randomised between 00:00 and 04:59.
  On Red Hat family distributions it also set the firewalld public
  zone target to ACCEPT and put SELinux into monitor (permissive)
  mode, so a firewall that was filtering here before is not
  filtering now.

  Upstream T-Pot telemetry:  DISABLED   (community submission to
                             sicherheitstacho.eu)
  IoC forwarding:            DISABLED   (not implemented in this release)

  A REBOOT IS REQUIRED.  After it:   install.sh --verify-only
  Transcript: /var/log/tpot-automation/install-<run-id>.log
  Result:     /var/lib/tpot-automation/result.json      exit code 20
================================================================
```
<!-- END GENERATED NOTICE -->

The block renders the shipped defaults. On a real run the ports, the dashboard user, the honeypot
named on port 22 and the reboot time come from that host's own configuration.

---

## Requirements

**Host**

| | |
|---|---|
| Machine | dedicated, freshly installed |
| Privilege | root. `install.sh` refuses otherwise |
| Init | `systemd`, with `/run` on tmpfs |
| Packages | `apt`-based distribution |
| Architecture | `x86_64` or `aarch64` |
| Network | IPv4, non-proxied, outbound 80/443 to the OS mirror, GitHub, GHCR and Docker Hub |

Upstream's own installer refuses to run *as* root, so it is invoked as an unprivileged account
this installer creates.

**Resources**

| | Hard floor | Recommended | Source |
|---|---|---|---|
| Memory | 8192 MiB | 16384 MiB | upstream's sensor minimum and hive recommendation |
| CPUs | 2 | 4 | no upstream figure exists; the floor is the lower of two disputed values |
| Free disk | 64 GiB | 256 GiB | recommendation is upstream's hive figure; the floor is lower than upstream asks |

Below a floor the run stops with exit `11`. `--force-low-resources` continues and records that it
was forced in `result.json`.

The disk floor is deliberately half of upstream's stated minimum, so that a modest test host can
complete a run. T-Pot retains 30 days of captured data by default and re-pulls its images at every
start, so a host near the floor fills up over time; Elasticsearch is where that surfaces first.

Note that `MemTotal` is physical RAM minus firmware and kernel reservations, so a machine
provisioned with exactly 8192 MiB reports less and does not meet the memory floor. Provision
above it.

---

## Supported platforms

| Platform | Status |
|---|---|
| Debian 13, x86_64 | **Tested** — installed and verified 2026-09-05 |
| Ubuntu 26.04, x86_64 | Supported, never run |

Support is the intersection of upstream's own distribution gate at the pinned ref and this
installer's `apt-get` requirement. It is computed by `tools/pin-upstream.sh`, not chosen: move the
pin and the list is recomputed.

Any Debian 13 host is expected to work regardless of how it was provisioned; the version gate
compares the major number only. Ubuntu 26.04 and `aarch64` are expected to work and have not been
run.

**`docs/compatibility.md`** has upstream's gate row by row, why each excluded platform is
excluded, what "expected to work" means, and how to reach an older release by pinning an older
ref. A platform becomes *tested* only through a dated run in `tests/MATRIX-STATUS.md`.

---

## Installing

Two invocations, because T-Pot requires a reboot and an unrebooted host cannot be verified.

```sh
# 1. answer file, outside this repository, root-owned
./install.sh --example-config > /root/tpot.yml
chmod 0600 /root/tpot.yml
"$EDITOR" /root/tpot.yml

# 2. dashboard password in its own root-owned file, never on a command line
install -m 0600 /dev/null /root/tpot-web-password
"$EDITOR" /root/tpot-web-password

# 3. install. Closing stdin makes "nothing is prompted" a property, not a promise.
./install.sh --config /root/tpot.yml \
             --web-password-file /root/tpot-web-password </dev/null
#   exit 20  ->  installed; a reboot is required before it can be verified

reboot

# 4. reconnect on the new port and verify
ssh -p 64295 you@your-host
./install.sh --verify-only </dev/null
#   exit 0   ->  installed and verified
```

Run `--preflight-only` first: it performs every check, prints the report, changes nothing, and
exits `0`, `11` or `12`. `--check` additionally runs the playbook in check mode.

### Installing over SSH

The install moves `sshd` to 64295 while it runs. If the administrative port is firewalled, open a
multiplexed session **before** starting — an established connection survives the move, a new one
cannot be made — and detach the run so a dropped session cannot kill it:

```sh
ssh -M -S ~/.tpot.sock -fN -o ServerAliveInterval=30 you@your-host
ssh -S ~/.tpot.sock you@your-host \
    'setsid nohup sudo ./install.sh ... </dev/null >/var/log/tpot-install.out 2>&1 &'
```

### Verification after the reboot

If the second invocation is never made, the host finishes verifying itself. `roles/finalize`
installs a systemd unit that re-runs verification on the next boot, rewrites `result.json`, and
disarms itself — necessary because upstream's cron job reboots the host nightly, and a unit left
armed would re-assert a dated record every day.

The unit reads the configuration this host was installed with from
`/var/lib/tpot-automation/verify-config.json` (root-owned `0600`), written by `roles/finalize`
from the merged public document with every secret-typed key removed. Without it the unit would
verify the shipped defaults — the wrong account, the wrong edition, the wrong ports — fail, and
never clear its arming marker.

That file is also the manual recovery path, because it is exactly what the unit runs:

```sh
install.sh --verify-only --config /var/lib/tpot-automation/verify-config.json
```

It lives under the state directory because both `lib/config.py` and `lib/preflight.sh` refuse an
answer file that resolves inside an installer tree.

---

## Exit codes

The exit status is the interface. A caller must be able to branch on the outcome without parsing
English.

* **`0` means installed *and* verified**, and nothing weaker. A fresh install that has not
  rebooted returns `20`.
* **`20` is not a failure.** It is the successful first invocation. After the reboot,
  `--verify-only` turns it into `0`.
* **Every failure code says how far the run got.** `11` never touched the host; `14` never ran
  upstream's installer; `16` has T-Pot installed and one assertion unhappy.
* **`result.json` is written on every path**, including an interruption mid-run, by an exit trap.
  The exception is a state directory that cannot be created, where the trap warns on stderr.

<!-- BEGIN GENERATED: exit-table -->
```text
CODE  NAME              MEANING
   0  EX_OK             installed and verified; nothing further is required
  10  EX_USAGE          bad flag, unknown environment or answer-file key, missing required input, --set on a secret key, or an answer file that is inside the tree or not root-owned 0600
  11  EX_PREFLIGHT      not root, unsupported operating system, memory/CPU/disk below the hard floor, a required port already bound by something other than the host sshd, upstream/apt/Galaxy/PyPI unreachable, /run not tmpfs, or no systemd
  12  EX_INCONCLUSIVE   --preflight-only only: nothing failed, but some checks could not be exercised on this box
  13  EX_DEPS           dependency bootstrap failed: apt, ansible-core, or ansible-galaxy
  14  EX_UPSTREAM       the pinned upstream T-Pot installer could not be fetched, or its sha256 did not match
  15  EX_DRIVER         upstream's own installer failed: it exited non-zero, or it exceeded tpot_driver_install_timeout
  16  EX_VERIFY         T-Pot installed, but a post-install assertion failed
  20  EX_REBOOT         installed and pre-reboot checks passed; a REBOOT IS REQUIRED before verification. Not a failure
  30  EX_INTERRUPT      interrupted by SIGINT, SIGTERM or SIGHUP; the trap still wrote result.json
  40  EX_INTERNAL       a bug in this installer, or a credential reached the transcript; file an issue and attach the transcript
```
<!-- END GENERATED: exit-table -->

`lib/exitcodes.sh` is the source of truth. `tests/check-exit-table.sh` compares this copy, the one
in `docs/exit-codes.md` and the one `--help` renders against it. `docs/exit-codes.md` says what to
do about each code.

---

## Configuration

Every setting has one name — the Ansible variable name — in all three channels.

| Channel | Form | Notes |
|---|---|---|
| Flag | `--set key=value`, or the equivalent long flag | highest precedence; refused for secret keys |
| Environment | the key uppercased: `tpot_install_type` → `TPOT_INSTALL_TYPE` | a misspelt `TPOT_*` or `IOC_*` name is a usage error naming itself |
| Answer file | `--config FILE`, YAML or JSON, repeatable | must be outside the installer tree; root-owned `0600`/`0400` if it holds a secret |

Later answer files override earlier ones; flags override everything.

`examples/tpot.example.yml` is a commented answer file, identical to `--example-config` output.
`inventories/example/group_vars/all.yml` documents every setting once.

---

## Credentials

**No credential reaches a command line.** A process argument list is world-readable in `/proc` for
the lifetime of the process, and a T-Pot install runs for tens of minutes.

* No flag takes a password as its value. `--web-password-file` and `--os-user-password-file` take
  a path, root-owned mode `0600`. `--set` refuses secret keys.
* The merged configuration reaches Ansible as a file reference (`-e @PATH`), never as `key=value`.
  `tests/check-argv-hygiene.sh` enforces this statically.
* The transcript is redacted as it is written, then searched for each supplied secret; a hit
  truncates the log and fails the run.
* The dashboard password reaches `htpasswd` on standard input. `htpasswd -b`, which would take it
  as an argument, is forbidden and the argv gate looks for it by name.

**Upstream is driven so that it never receives a credential.** Upstream's installer takes the
dashboard password only as a command-line argument, and passes it on a child process's command
line as well; there is no environment path into it. So this installer invokes upstream as an
unattended **sensor** install (`-s -t s`, plus `-b` for the pinned ref) — the one code path that
never asks for a credential — and afterwards performs the two steps the credentialed path would
have done: copy the chosen edition's compose file over `docker-compose.yml`, and write the
dashboard user into upstream's `.env` as the base64 of an `htpasswd` record. Both are operations
upstream documents.

Upstream's own `.env` edit silently does nothing when the target line is absent, so this
installer checks that the write landed. Upstream manages `LS_WEB_USER` itself; this installer
never writes it.

`SECURITY.md` carries the full position, including the passwordless `sudo` grant that upstream's
unattended mode requires.

---

## The upstream pin

```text
tpot_upstream_ref   fdafa483e1e0f36b0a7b0cbb6bae1031fe06fc37
sha256(install.sh)  0e0b893b86aeca80f4ef43c30b851850b0370f43ced37bcda36ecee52faeda50
```

**It is a commit, not a tag.** Upstream grew its unattended flags on `master` and has not cut a
release since. Its install-type and credential flags landed on 2025-07-05; the two that pin the
payload, `-b` and `-r`, followed thirteen months later. No tag contains either group. The newest tag, `24.04.1`, has no positional-parameter
handling at all — driven non-interactively it hangs rather than failing. Ten much older tags
(`18.11` through `22.04.0`) offer a different unattended mechanism (`--conf=`) that would require
a different design.

**The full 40-character sha is required.** `lib/varschema.json` refuses an abbreviation: `git`
accepts a short sha and checks out the full one, so upstream's re-run check compares seven
characters against forty, concludes the checkout is somebody else's, and exits `1`.

**A pin pins the recipe, not the software.** `tpot_upstream_ref` sets two things — the `install.sh`
this project fetches and verifies against the sha256 above, and the `-b` argument deciding which
payload upstream clones. What upstream clones names a *mutable* image tag: its `.env` sets
`TPOT_VERSION=24.04.1`, every service is `${TPOT_REPO}/<name>:${TPOT_VERSION}`, and
`TPOT_PULL_POLICY=always`. Two installs from the same commit a month apart can run different
containers, and the nightly reboot re-pulls them again. `result.json` reports this as
`upstream.pins_payload: false`, permanently.

**A sha pin makes re-running less safe, not more.** With a sha, upstream's `check_tpot_clone`
matches an existing checkout and skips the clone — over a tree it never refreshes (`update: no`)
and never integrity-checks, so a modified `docker-compose.yml` passes silently. This is why
`tpot_force_reinstall` is documented as what it does: `rm -rf ~/tpotce`.

Everything else about a ref is measured once, at pin time, by `tools/pin-upstream.sh` and written
to `roles/tpot_install/vars/upstream-<ref>.yml`: the sha256, each edition's compose file, the
container floor verification compares against, and upstream's distribution gate row by row with a
reason per verdict. That file is generated — move the pin and read the diff.

---

## Telemetry

T-Pot can submit attack data to the Sicherheitstacho community project. That submission is
upstream's, and **this installer disables it by default** (`tpot_upstream_telemetry: "off"`).

There is no `.env` key and no upstream flag for it. Upstream's documented opt-out is to remove the
`ewsposter` service from `docker-compose.yml`, so `off` does exactly that: `roles/tpot_install`
removes the service and the network only it uses by rewriting the parsed compose document rather
than editing text, then asserts it is gone; `roles/tpot_verify` asserts the same absence on the
installed host. `"on"` leaves upstream's file untouched. Either way the closing notice and
`result.json` state which it is.

Two limitations:

* The edit is a working-tree modification inside upstream's git checkout, and upstream's
  `update.sh` overwrites local changes. **The opt-out does not survive an upstream update.**
* Removing the service does not remove the image, which upstream still pulls. Nothing runs it.
* In YAML, quote the value: bare `off` is a boolean, not the string.

---

## Firewall

**This installer configures no firewall.** `tpot_firewall_mode` accepts only `none` in this
release. No rules are added and none removed. Filtering in front of an internet-facing honeypot,
if you want it, belongs off the host.

**Upstream is not neutral about the host's filtering.** Its playbook:

* moves administrative `sshd` to TCP/64295 and disables the DNS stub listener;
* on Red Hat family distributions, sets the `firewalld` public zone target to `ACCEPT` and puts
  SELinux into permissive mode — a firewall that was filtering before is not filtering after;
* adds Docker's repository, installs Docker, and adds the install account to the `docker` group,
  which is equivalent to root on that machine;
* removes packages it considers conflicting, installs shell aliases, and enables `tpot.service`;
* installs a root cron job that reboots the host nightly, stopping T-Pot and pruning containers,
  images and volumes first. The hour comes from `range(0, 5)` and the minute from `range(0, 60)`,
  chosen at install time, so no two hosts share a schedule and no document can name yours. The
  installer reads the job it wrote and prints the time in the closing notice; `crontab -l -u root`
  is where it lives.

`docs/firewall.md` carries the port list, the evidence behind this section, and a worked
`nftables` example.

---

## Scope

**This is an automation wrapper around upstream T-Pot.** No upstream code is vendored: the
honeypots, dashboard, compose files and playbook are all fetched at install time from the pinned
ref.

It is not a hardening tool, not a firewall, and not a fleet orchestrator — it runs as root on the
machine that is to become the honeypot, one host per run, with no remote-target mode.

**IoC forwarding is not implemented.** The `ioc_*` namespace is reserved and documented. With the
default (`ioc_forwarding_enabled: false`) no connection is opened to any endpoint of yours.
Setting it `true` **refuses to run** rather than silently doing nothing, and is refused twice:
`roles/preflight` stops the play on its first check with `11`, whose published meaning is that
nothing on the host was changed; `roles/ioc_forward` keeps its own assertion as a last line of
defence and answers `10`, reachable only if the preflight stage was skipped by tag selection. Two
codes for one input, because by the time the second can fire, "nothing happened" is no longer
true.

---

## Licence

**There is no licence yet. `LICENSE` is a deliberate placeholder and all rights are reserved.** No
permission is granted to use, copy, modify, distribute or sell this software while that file says
what it says.

Re-licensing a published project requires the agreement of every contributor, so the choice is
made once, before the first public commit. Replacing `LICENSE` is that event, and that commit also
owes an SPDX identifier in the repository metadata.

This project installs but does not redistribute upstream T-Pot or the Ansible collections in
`requirements.yml`. Each carries its own licence.

---

## Documentation

| | |
|---|---|
| `install.sh --help` | the complete flag surface, with the exit table |
| `docs/compatibility.md` | upstream's distribution gate, what is tested, what is expected to work |
| `docs/exit-codes.md` | what to do about each exit code |
| `docs/firewall.md` | ports, what upstream changes, and a worked ruleset |
| `SECURITY.md` | credential handling, the `sudo` grant, and how to report a vulnerability |
| `tests/MATRIX-STATUS.md` | dated record of which (ref × platform) pairs have been installed |
| `examples/tpot.example.yml` | commented answer file |
| `inventories/example/group_vars/all.yml` | every setting, documented once |
| `support-matrix.yml` | the platform tiers and their basis |
| `tools/pin-upstream.sh` | how the per-ref data file and the supported list are produced |
| `CHANGELOG.md` | what changed, per version |

Upstream T-Pot's documentation is at <https://github.com/telekom-security/tpotce>. Every claim
this file makes about upstream's behaviour was read from upstream's source at the pinned commit.
Move the pin and those claims are owed a re-check.
