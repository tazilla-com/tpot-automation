# tpot-automation

An **unattended installer for the [T-Pot](https://github.com/telekom-security/tpotce)
honeypot platform**. Point it at a clean, dedicated Linux box, give it one answer
file, and it preflights the machine, installs its own prerequisites, drives
upstream T-Pot's own installer in upstream's documented unattended mode at a
pinned ref, configures what that mode leaves undone, verifies the result, and
exits with a code a script can branch on. It never asks a question, needs no
terminal, and is not a fork of T-Pot.

> ### Version 0.1.0. Nothing has ever been installed with it.
>
> There has never been a real T-Pot install from this repository: no VM, no
> root, no network, no box that afterwards ran a honeypot. The only things ever
> executed are unit-level runs on an unprivileged developer machine. Large parts
> of the product — the Ansible play and every role, the verification step, the
> pinning tool, the unit-test suite and CI — **are not written yet**, and no
> upstream ref is pinned, so a full run stops at preflight by design.
> [What exists and what does not](#status--what-exists-and-what-does-not) is the
> third section of this file. Read it before you plan anything around this.

---

## Before you install: what this does to your machine

This is the section that stops you locking yourself out of your own server. It
is deliberately before the instructions.

**1. Administrative SSH moves off port 22, to TCP/64295.** Upstream's playbook
reconfigures `sshd`. If you disconnect without noting that, your next
`ssh you@host` does not reach this machine's shell.

**2. TCP/22 becomes a honeypot that answers convincingly.** It accepts your
connection and gives you what looks like a shell. It is not one. Nothing typed
there runs on the machine, and everything typed there is recorded as attacker
activity. Which honeypot listens depends on the edition you install — Cowrie in
the default hive edition, Endlessh in the tarpit edition, Beelzebub in the LLM
edition — so the installer derives that sentence from your configuration rather
than guessing.

**3. The box becomes internet-facing and deliberately exposed.** That is the
point of a honeypot: ports other than administrative SSH, the dashboard and the
loopback-only search engine are open to attack on purpose. **This installer adds
no firewall rules of its own**, and upstream is not neutral either — see
[Firewall, and what upstream changes](#firewall-and-what-upstream-changes).

**4. Use a dedicated machine.** Upstream removes packages it considers
conflicting, puts the install account in the `docker` group (which is equivalent
to root on that box), and installs a root cron job that **reboots the host every
day at 02:42**. Nothing about this is safe to bolt onto a server that has
another job.

This is the notice `install.sh` prints at the end of a successful run. It is
generated from `lib/notice.sh` and embedded here verbatim; `tests/check-notice-doc.sh`
fails the build if the two ever differ, so what you read here is what the
installer says. Regenerate it with `tests/check-notice-doc.sh --print` — never
edit it by hand.

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
  job that REBOOTS THIS HOST EVERY DAY AT 02:42.
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

The block above renders the shipped defaults, including the default edition
(`h`, hive). On a real run the ports, the dashboard user and the honeypot named
on port 22 come from your own configuration.

---

## Status — what exists and what does not

**Nothing in this repository has ever installed T-Pot.** There has been no VM,
no root, no network access, and no host that became a honeypot. Everything that
has been executed was executed unprivileged, on a developer box, at the level of
individual functions and build gates. Where this README describes a component
that is designed but not built, it says so in the same breath.

**What exists today**

| | |
|---|---|
| `install.sh` | the entrypoint: flag parsing, the four-channel config merge, two non-mutating preflight stages, dependency bootstrap, the tmpfs secret channel, exit-code mapping, `result.json`, the reboot decision and the notice |
| `lib/` | the libraries the entrypoint is made of — exit codes, logging and redaction, the preflight checks, the support-matrix reader, the notice, the result writer, the config merger and its schema |
| `support-matrix.yml` | the two tiers of distribution releases, and the only place either is written down |
| `examples/`, `inventories/example/` | the complete input surface as commented placeholders, in YAML and JSON |
| `tests/` | eight build gates and the `/etc/os-release` fixtures they run against |
| `docs/exit-codes.md`, `SECURITY.md`, `CHANGELOG.md` | the exit contract, the security position, the change log |

**What does not exist yet** — none of these files are in the tree:

* `site.yml` and `verify.yml`, the two playbooks `install.sh` invokes;
* **all of `roles/`** — OS preparation, the upstream driver, the compose swap,
  the `.env` credential write, the telemetry removal, the verification role, and
  the post-boot systemd oneshot that would verify the host after its reboot;
* `tools/pin-upstream.sh`, which is the only supported way to pin an upstream ref
  and to derive the supported tier from it;
* the unit-test suite (bats), `.github/workflows/` (CI), `tests/MATRIX-STATUS.md`
  (which release was proven at which ref, with dates) and `tests/fixtures/`;
* `docs/firewall.md`, `docs/verification.md` and `docs/roadmap-ioc.md`, each of
  which is referenced by a file that does ship.

**What that means if you run it right now**

* **No upstream ref is pinned.** `tpot_upstream_ref` ships empty on purpose:
  nothing may be claimed as supported until something is pinned. Preflight's
  upstream reachability check is a *hard* check, and with no ref it can only
  report `inconclusive` — which in a full run is `11` (`EX_PREFLIGHT`) and under
  `--preflight-only` is `12` (`EX_INCONCLUSIVE`). **A full run therefore stops at
  preflight, before touching the box.** That is the designed behaviour, not a bug.
* **If you pin a ref by hand** with `--upstream-ref` and the rest of preflight
  passes, the run reaches the playbook step, finds no `site.yml`, logs that
  nothing was installed, and exits `40` (`EX_INTERNAL`). This is deliberate: a
  build with no play **cannot** reach `0` or `20`, so it can never claim to have
  installed anything.
* **`--verify-only` behaves the same way**, because `verify.yml` is absent too.
* **Neither support tier has a real run behind it.** Not one row, at any ref.

**What has actually been exercised**, all of it unprivileged and on one
developer machine: the build gates in `tests/`, the support-matrix readers
cross-checked against PyYAML and against `ansible-core`'s own `include_vars`,
and upstream's distribution gate replayed against the `/etc/os-release` fixtures
in `tests/os-release/`. Run `tests/run-gates.sh` to see the current state of the
tree — some gates fail today, on files still being written, and **a `SKIP` is
not a pass**.

---

## What this is, and what it is not

**It is** an automation wrapper around upstream T-Pot: it checks the box, brings
its own dependencies, downloads and runs upstream's `install.sh` unattended at a
pinned ref, does the few things upstream's unattended path leaves undone, then
verifies and reports a machine-readable outcome.

**It is not:**

* **Not a fork or a copy of T-Pot.** No upstream code is vendored here. The
  honeypots, the dashboard, the compose files and the playbook that installs
  them are all upstream's, fetched at install time from the ref you pin.
* **Not a hardening tool, and not a firewall.** It exposes a machine on purpose
  and configures no packet filtering — see below.
* **Not a fleet orchestrator.** It runs as root on the machine that is to become
  the honeypot, one box per run. There is no remote-target mode.
* **Not an IoC forwarder.** The `ioc_*` namespace is reserved and documented,
  and there is no forwarding code in the tree at all: with the default
  (`ioc_forwarding_enabled: false`) this installer opens no connection to any
  endpoint of yours. The design is that setting it `true` *refuses to run*
  rather than silently doing nothing — **and that refusal is not implemented in
  this build.** Today the setting changes one line of the end-of-run notice and
  nothing else, so do not rely on it to stop you. The mock receiver the roadmap
  describes is not in this repository either.

---

## Requirements

**The machine**

* A **dedicated** box — freshly installed, doing nothing else.
* **Root.** `install.sh` runs as root and refuses otherwise. (Upstream's own
  installer refuses to run *as* root, so it is invoked as an unprivileged account
  this installer creates.)
* `systemd`, `/run` on tmpfs, an `apt`-based distribution, and `x86_64` or
  `aarch64`.
* **An IPv4 address and a working, non-proxied internet connection**, upstream's
  requirement, plus outbound 80/443 to your OS mirrors, GitHub and DockerHub.

**Size.** Upstream's own figures are *"at least 8-16 GB RAM, 128 GB free disk
space"*, and per role Hive 16 GB RAM / 256 GB SSD, Sensor 8 GB RAM / 128 GB SSD.
Upstream states no CPU figure at all, and upstream's `install.sh` checks none of
these. This installer does check, at these thresholds:

| | hard floor | recommended | where the number comes from |
|---|---|---|---|
| memory | 8192 MiB | 16384 MiB | upstream's own sensor minimum and hive recommendation |
| CPUs | 2 | 4 | **no upstream figure exists.** The two inherited guides disagree (4 against 8), so the floor is the lower disputed number rather than either document's own |
| free disk | 64 GiB | 256 GiB | recommendation matches upstream's hive figure; **the floor is a deliberate deviation, below upstream's stated minimum** |

**The disk floor is half of what upstream asks for, on purpose.** 64 GiB lets a
modest test guest complete a run at all. It is a deviation from upstream, not a
reading of it, and it has a cost: T-Pot keeps 30 days of captured data by
default and re-pulls its container images at every start, so a box near the floor
fills up quietly and Elasticsearch is where you notice first. Between 64 and 256
GiB the honest statement is "this works and upstream does not promise it will",
which is what the warning band is for. Below the floor the run stops;
`--force-low-resources` continues anyway and records that it was forced.

---

## Supported releases

There are **two tiers**, and only one of them is a claim.

**Supported and tested** — releases the *pinned* upstream ref accepts, that this
installer can also drive, **and** that have a dated real run behind them.
**This tier is empty.** Not because nothing works: because no upstream ref is
pinned yet, so there is no ref whose gate could have been consulted and no run
that could have been made. An empty list is the honest answer; a list of
plausible releases would be a claim with no evidence under it. It is *derived*
from the pin by `tools/pin-upstream.sh` (not yet written), never edited by hand.

**Legacy** — nine releases the automation this project replaces was installed on:
`debian:11`, `debian:12`, `debian:13`, `ubuntu:20.04`, `ubuntu:22.04`,
`ubuntu:24.04`, `linuxmint:20`, `linuxmint:21`, `linuxmint:22`. They are
documented so the users of that older automation are not silently abandoned, they
are reachable only by pinning an older upstream ref, and **they are not tested and
may never be described as tested.** The evidence behind them is a run of a
*different* installer against whichever `install.sh` upstream's master branch
served on an unrecorded day, and it has already expired.

**Why an older release needs an older ref rather than a flag.** Upstream's own
installer gates on `/etc/os-release` before it reads any argument. Its
supported-distribution list matches on the `NAME` field and does not contain
Linux Mint at all; its version gate then requires Debian major `13`, Ubuntu
exactly `26.04`, compared with string inequality — no ordering, no "or newer",
and no override flag. Replayed against the fixtures in `tests/os-release/`, only
Debian 13 of those nine passes. `--force-unsupported-os` relaxes **this
installer's** preflight and cannot touch upstream's refusal, which arrives on the
box, before anything is installed.

---

## Installing

**The happy path is two invocations**, because T-Pot needs a reboot and a host
that has not rebooted cannot honestly be called verified.

```sh
# 1. an answer file, outside this repository, owned by root
./install.sh --example-config > /root/tpot.yml
chmod 0600 /root/tpot.yml
"$EDITOR" /root/tpot.yml

# 2. the dashboard password in its own root-owned file -- never on a command line
install -m 0600 /dev/null /root/tpot-web-password
"$EDITOR" /root/tpot-web-password

# 3. install. Nothing is prompted; closing stdin makes that a property.
./install.sh --config /root/tpot.yml \
             --web-password-file /root/tpot-web-password </dev/null
#   exit 20  ->  installed; a REBOOT IS REQUIRED before it can be verified

reboot

# 4. reconnect on the NEW port, and verify
ssh -p 64295 you@your-host
./install.sh --verify-only </dev/null
#   exit 0   ->  installed AND verified
```

`--preflight-only` runs every check, prints the report, changes nothing at all,
and exits `0`, `11` or `12`. Run it first. `--check` goes further — preflight
plus the playbook in check mode — and still changes nothing on the box.

**Today this example does not complete**, and the [Status](#status--what-exists-and-what-does-not)
section says exactly where it stops: at preflight with `11` while no ref is
pinned, or at the playbook step with `40` if you pin one by hand, because
`site.yml` is not written yet. The contract above is what the finished product
owes you; it is not a transcript of something that has happened.

---

## Exit codes

`install.sh` communicates through its exit status — that *is* the product, and a
caller must be able to branch on the outcome without parsing English.

* **`0` means installed AND verified**, and nothing weaker. A fresh install that
  has not rebooted returns `20`, never `0`.
* **`20` is not a failure.** It is the successful first invocation: installed,
  pre-reboot checks passed, reboot required. After the reboot, `--verify-only`
  turns it into `0`.
* **Every failure code says how far the run got** — `11` never touched the box,
  `14` never ran upstream's installer, `16` has T-Pot installed and one assertion
  unhappy.
* **`result.json` is written on every path**, including an interruption at minute
  70, by an exit trap.

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

`lib/exitcodes.sh` is the source of truth; the block above is its output
verbatim, regenerated with `bash lib/exitcodes.sh`. Unlike the notice block,
this copy has no build gate watching it yet, so regenerate it by hand whenever
the table changes. `docs/exit-codes.md` says what to do about each code.

---

## Input: flags, environment and the answer file

Every setting has the same name in all three channels: the Ansible variable
name, verbatim. There is no lookup table and no second spelling.

| channel | how | notes |
|---|---|---|
| flags | `--set key=value`, or the equivalent long flag | highest precedence; refused for a secret |
| environment | the key name **uppercased**: `tpot_install_type` is `TPOT_INSTALL_TYPE` | a misspelt `TPOT_*` or `IOC_*` name is a usage error that names itself |
| answer file | `--config FILE`, YAML or JSON, repeatable | must be outside this repository, and root-owned `0600`/`0400` if it holds a secret |
| default | built in | `install.sh --example-config` prints them all, commented out |

**Precedence, highest first:** `--set` and the long flags **>** the environment
**>** `--config` files, a later file winning **>** the built-in default.

`--log-dir`, `--state-dir` and `--runtime-dir` are flag-only and are *not* read
from the environment: the transcript is opened before any answer file has been
read, so a value arriving later could not have applied to it.

**An unknown key stops the run.** It is not a warning. A setting that is silently
ignored is discovered at the wrong end of a 90-minute install.

The settings you are most likely to touch:

```text
--upstream-ref REF        the tag or commit of upstream T-Pot to install.
                          Never a branch: with no ref pinned, upstream
                          silently falls back to its own default branch.
--install-type CHAR       h hive (default) | s sensor | l llm | i mini
                          | m mobile | t tarpit
--web-user NAME           dashboard user (default: the OS account)
--os-user NAME            the unprivileged account that owns T-Pot
--telemetry off|on        upstream's own data submission (default: off)
--os-upgrade LEVEL        none | safe | full            (default: safe)
--reboot POLICY           never | if-required | always  (default: never)
--preflight-only          check and report; change nothing
--json                    print result.json on stdout
```

`install.sh --help` prints the complete surface, and
`inventories/example/group_vars/all.yml` documents every key in one place.

---

## How credentials are handled

**No credential ever reaches a command line in this project's code.** A process
argument list is world-readable in `/proc` for the lifetime of the process, and
a T-Pot install runs for thirty to ninety minutes. So:

* **No flag takes a password as its value.** `--web-password-file` and
  `--os-user-password-file` take a **path**, root-owned and mode `0600`. A
  password may also come from the environment or from an answer file, and
  `--set` refuses a secret key outright.
* **The merged configuration reaches Ansible as a file reference**, never as
  `key=value` on a command line.
* **The transcript is redacted as it is written**, and then searched for each
  supplied secret; a hit truncates the log and fails the run.
* **The dashboard password is to reach `htpasswd` on standard input** — that
  step lives in a role that is not written yet, and the paragraph below says so
  again because it is the one part of this list that is design rather than code.

**The divergence worth explaining.** Upstream's installer takes the dashboard
password only as a command-line argument, and then passes it on the command line
of a child process as well. There is no environment path into it. So this
installer does not use that door: **upstream is driven as an unattended sensor
install** (`-s -t s`, plus `-b` for the pinned ref), which is a code path that
never asks for a credential at all — and afterwards this installer performs, by
itself, the exact two things the credentialed install type would have done: copy
the chosen edition's compose file over `docker-compose.yml`, and write the
dashboard user into upstream's `.env` as the base64 of an `htpasswd` record.
Both are operations upstream documents for its users. The flags that carry a
username or a password are never passed.

The cost is that this installer now *owns* those two steps, and both are
**designed but not built** — they live in the roles that do not exist yet.
Upstream's own `.env` edit silently does nothing when the target line is absent,
so ours must check that the write landed rather than assume it. Upstream also
manages `LS_WEB_USER` itself, which is sensor-to-hive state; this installer must
never write it.

`SECURITY.md` carries the full position, including the passwordless `sudo` grant
that upstream's unattended mode requires.

---

## Upstream telemetry: off by default

T-Pot can submit attack data to the **Sicherheitstacho** community project
(`sicherheitstacho.eu`). That submission is upstream's, not this project's, and
**this installer disables it by default** — `tpot_upstream_telemetry: "off"`.
For a tool whose whole job is pointing a stranger's machine at the internet,
nothing should leave that machine to a third party unless it was asked for.

**How the opt-out works, and why it is unusual.** There is no `.env` key and no
upstream flag for it. Upstream's documented opt-out is to remove the `ewsposter`
service block from the `docker-compose.yml` in its checkout. So `off` is
specified to do exactly that, with verification then asserting the block is
**gone** rather than that the edit was attempted — **and both halves live in
roles that are not written yet.** `"on"` leaves upstream's file untouched.
Either way, the end-of-install notice, this README and `result.json` state which
it is.

Two limitations, stated rather than glossed:

* The edit is a working-tree modification inside upstream's own git checkout,
  and upstream's `update.sh` overwrites local changes — **the opt-out does not
  survive an upstream update.**
* In YAML, quote the value: bare `off` is a boolean there, not the string.

---

## Firewall, and what upstream changes

**This installer configures no firewall.** `tpot_firewall_mode` accepts only
`none` in this release, and that is what is delivered: no rules are added, none
are removed. If you need filtering in front of an internet-facing honeypot,
provide it yourself, off the box.

**Upstream is not neutral about your host's filtering either.** Its playbook, by
upstream's own list:

* moves administrative `sshd` to TCP/64295 and disables the DNS stub listener;
* **on Red Hat family distributions, sets the `firewalld` public zone target to
  `ACCEPT` and puts SELinux into permissive (monitor) mode** — a firewall that
  was filtering on that host before is not filtering after;
* adds Docker's repository, installs Docker, and **adds the install account to
  the `docker` group, which is equivalent to root on that machine**;
* removes packages it considers conflicting, installs shell aliases, and adds and
  enables `tpot.service`;
* **installs a root cron job that reboots the host every day at 02:42**, stopping
  T-Pot and pruning containers, images and volumes first.

**And the software keeps moving after you verify it.** T-Pot's pull policy
defaults to `always`, so the container images are re-pulled at **every** start —
including the daily 02:42 reboot. Pinning the upstream ref pins the recipe; it
does not pin the images, so the software running on a box is not necessarily the
software that was verified on it. `result.json` carries that as a field —
`upstream.pins_payload`, which is `false` and stays `false` — rather than
implying otherwise.

The notice printed at the end of a run points at `docs/firewall.md`. **That file
is not written yet**; what you have just read is the substance it owes you.

---

## Licence, and publication status

**There is no licence yet, and `LICENSE` is a deliberate placeholder.** All
rights are reserved: no permission is granted to use, copy, modify, distribute or
sell this software while that file says what it says. It is not an oversight and
not an omission to be fixed casually — re-licensing a published project needs the
agreement of every contributor in it, so the choice is made once, deliberately,
before the first public commit.

**This repository is not published.** It is a private working repository.
Replacing `LICENSE` with a real licence *is* the event that makes this project
open source, and that commit also owes the choice stated here, an SPDX
identifier in the repository metadata, and the reasoning recorded in the
project's decision log.

This project **installs** but does not contain or redistribute upstream T-Pot
and the Ansible collections in `requirements.yml`. Each carries its own licence,
unaffected by any of the above.

---

## Where to read next

| | |
|---|---|
| `install.sh --help` | the complete flag surface, with the exit table |
| `docs/exit-codes.md` | what to do about each exit code |
| `SECURITY.md` | credential handling, the `sudo` grant, what the installed box becomes, and how to report a vulnerability |
| `examples/tpot.example.yml` | a commented answer file — the same content as `--example-config` |
| `inventories/example/group_vars/all.yml` | every setting, documented once |
| `support-matrix.yml` | the two tiers, and why each release is in the one it is in |
| `CHANGELOG.md` | what has changed, per version |

Upstream T-Pot's own documentation is at
<https://github.com/telekom-security/tpotce>. **Every claim this file makes about
upstream's behaviour was read from upstream's `master` branch as it stood on
2026-09-02**, and `master` moves. Those claims are why this installer is built
the way it is, and each one has to be re-checked against whichever ref is
actually pinned here — which, today, is none.
