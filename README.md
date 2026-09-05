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
> executed are unit-level runs on an unprivileged developer machine. What is new
> is that the Ansible play, its eight roles, the verification split across the
> reboot and the pinning tool are now written, and an upstream ref is pinned —
> so what stops a run today is the machine you point it at, not a hole in the
> tree. Still missing: the unit-test suite, CI, the dated per-release record,
> and four documents this tree cites. **Written is not the same as proven**, and
> this file is careful about the difference throughout.
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
night, at an hour and minute it randomises per install** (upstream's own task is
called "Setup a randomized daily reboot", `random_hour: range(0, 5)`). Nothing
about this is safe to bolt onto a server that has another job.

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
<!-- END GENERATED NOTICE -->

The block above renders the shipped defaults, including the default edition
(`h`, hive). On a real run the ports, the dashboard user and the honeypot named
on port 22 come from your own configuration.

---

## Status — what exists and what does not

**Nothing in this repository has ever installed T-Pot.** There has been no VM,
no root, no network access, and no host that became a honeypot. Everything that
has been executed was executed unprivileged, on a developer box, at the level of
individual functions and build gates. Where this README describes something that
is written but has never run against a real machine, it says so in the same
breath — and that is now most of the product.

**What exists today**

| | |
|---|---|
| `install.sh` | the entrypoint: flag parsing, the four-channel config merge, two non-mutating preflight stages, dependency bootstrap, the tmpfs secret channel, exit-code mapping, `result.json`, the reboot decision and the notice |
| `lib/` | the libraries the entrypoint is made of — exit codes, logging and redaction, the preflight checks, the support-matrix reader, the notice, the result writer, the config merger and its schema |
| `site.yml`, `verify.yml` | the install play and the verification play — the two playbooks `install.sh` invokes |
| `roles/` | eight roles — `preflight`, `os_prep`, `tpot_user`, `tpot_install`, `tpot_verify`, `finalize`, `ioc_forward` and `report`. Everything that would change the box is here: the OS preparation, the upstream driver, the compose swap, the `.env` credential write, the telemetry removal, verification either side of the reboot, and the post-boot systemd unit |
| `tools/pin-upstream.sh` | the only supported way to pin an upstream ref, and the tool that derives everything which follows from one: the sha256, the per-edition container floor, upstream's own distribution gate, and the supported tier of `support-matrix.yml` |
| `support-matrix.yml` | the two tiers of distribution releases, and the only place either is written down |
| `examples/`, `inventories/example/` | the complete input surface as commented placeholders, in YAML and JSON |
| `tests/` | the build gates and the `/etc/os-release` fixtures they run against |
| `docs/exit-codes.md`, `docs/firewall.md` | the exit contract, and the firewall position with a worked example ruleset nobody here has ever loaded on a host |
| `SECURITY.md`, `CHANGELOG.md` | the security position, and the change log |

**What does not exist yet** — none of these are in the tree:

* the unit-test suite (`bats`) and `tests/fixtures/`, the `/proc` and
  configuration fixtures it would read;
* `.github/` — the CI workflows, including the release gate that refuses a tag
  while the matrix record is missing or stale;
* `tests/MATRIX-STATUS.md`, where a dated record of which (ref × distribution)
  pair was proven on a real box would live. **Nothing has been proven, so there
  is no file** — and that absence is why nothing on this page is called tested;
* **four referenced documents**, none of them written and every one of them
  cited by a file that does ship: `docs/answer-file.md` and `docs/variables.md`
  (cited by `lib/config.py`), `docs/verification.md` (by `lib/preflight.sh`)
  and `docs/roadmap-ioc.md` (by the example answer files and the example
  inventory). `docs/firewall.md` was the fifth entry on this list until it was
  written; it is in the tree now, and the table above carries it.

That list is not prose. `tests/check-references.sh` holds it as a registry and
fails the build in both directions: a path this tree names that is neither on
disk nor declared absent, **and a path declared absent that has since been
written**. `site.yml`, `verify.yml`, `roles/` and `tools/pin-upstream.sh` were
on it until the play landed. The second direction is why this section was
rewritten rather than left to rot: a list of what does not exist is falsified by
somebody doing the work, which is the one event nobody thinks to check prose
over.

**What that means if you run it right now**

* **On this project's own developer box it stops in stage A of preflight and
  exits `11` (`EX_PREFLIGHT`), on the `root` check** — because that box is not
  root, which is the first thing stage A asks. Measured today, on this tree, for
  every invocation that would act on a machine: a full install with the password
  in the environment, `--preflight-only`, `--verify-only` and `--check`, each
  under `setsid --wait` with stdin closed. All four exited `11`, all four wrote
  their `result.json` when given a writable `--state-dir`, and the supplied
  password appeared in none of the artefacts any of them produced. `--help`,
  `--version` and `--example-config` are unaffected: they print and exit `0`
  without ever reaching preflight, and a bad flag or a missing required input is
  still `10`, before preflight runs at all.
* **The file manifest is no longer the thing that refuses.** Stage A also checks
  that the seventeen files this installer is made of are present, and until the
  play landed `site.yml` and `verify.yml` were two of the seventeen it could not
  find — which is what every earlier version of this section described. They are
  there now and that check passes. What changed is which check you hit first, not
  the guarantee.
* **What stops a run today is the machine, not the tree.** Root, an `apt`-based
  release the pinned upstream ref accepts, and a working internet connection are
  all genuinely required, and no `--force-*` flag conjures any of them. **No box
  with all three has ever been offered to this code**, so the furthest it has
  ever got is preflight, and everything past that point is written and
  unobserved.
* **Exit `40` for a missing play is now unreachable in a release, which is what
  it was always for.** `install.sh` still refuses at step 9 if `site.yml` is
  absent from the checkout it is running from — it logs what is missing, records
  `internal_error` and returns `40` (`EX_INTERNAL`) — so that a build without a
  play cannot report success. A release that contains `site.yml` never reaches
  that arm, and it has never executed.
* **Neither support tier has a run behind it.** Not one row, at any ref. The pin
  decides which releases may be called *supported*; only a dated run recorded in
  `tests/MATRIX-STATUS.md` could call one *tested*, and there is no such file.

**What has actually been exercised**, all of it unprivileged and on one
developer machine: the build gates in `tests/`; the support-matrix readers
cross-checked against PyYAML and against `ansible-core`'s own `include_vars`;
upstream's distribution gate replayed against the `/etc/os-release` fixtures in
`tests/os-release/`; the play and its roles put through `yamllint` (clean),
`ansible-lint --offline` (0 failures, and the stricter `production` profile
passes) and `ansible-playbook --syntax-check` on both playbooks; and
`install.sh` itself, run to its refusal in every mode it offers, as described
above.

**A syntax check is not a run.** Nothing in that list executed a single task
against a machine, and `--check` — which would at least walk the play — has
never got past preflight either, for the same reason everything else has not.

Run `tests/run-gates.sh` to see the state of the tree for yourself: **every gate
passes today and the runner exits `0`**, listing the five `gate-allow`
exemptions under its summary. No gate skips; a gate that could not run would
report `SKIP`, which is its own verdict in that summary and is never shown as a
pass — the runner says in words that the run was not clean, and `--strict` turns
it into a failing exit status. `tests/run-gates.sh --self-test` asks the harder
question — it points each gate at a deliberately violating tree and requires it
to fail — and reports `PROVEN` only for the gates the runner has a negative
fixture for. The rest come back `UNPROVEN` rather than being quietly counted as
passes; `check-matrix-parse.sh` is one of them, and the note in the CHANGELOG
says what it carries instead.

None of that is evidence about a host. A green gate suite says this repository
keeps its own promises; it does not say a honeypot has ever come up.

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
  endpoint of yours. Setting it `true` **refuses to run** rather than silently
  doing nothing — and it is refused twice, deliberately. `roles/preflight` stops
  the play on its very first check, in a couple of seconds, with `11`, whose
  published meaning is *nothing on this box was changed*. `roles/ioc_forward`
  keeps its own assertion as the last line of defence and answers `10`,
  reachable only when the preflight stage was skipped by tag selection. Two
  codes for one input, because by the time the second one can fire, "nothing
  happened" has stopped being true — and the earlier design, where the only
  refusal was the last role in the play, would have installed a complete T-Pot
  over ninety minutes and *then* reported that nothing had happened. Neither
  refusal has ever run on a real box, and the mock receiver the roadmap
  describes is not in this repository.

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

## The upstream pin, and what it does not pin

```text
tpot_upstream_ref   fdafa483e1e0f36b0a7b0cbb6bae1031fe06fc37
sha256(install.sh)  0e0b893b86aeca80f4ef43c30b851850b0370f43ced37bcda36ecee52faeda50
```

**That is a commit, and not for want of looking for a tag.** Upstream grew its
unattended flags on `master` and has not cut a release since: `-s`, `-t`, `-u`
and `-p` landed there on 2025-07-05, `-b` and `-r` thirteen and a half months
later, and no tag contains either group. The newest tag, `24.04.1`
(2024-12-11), has no positional-parameter handling at all — driven
non-interactively it does not fail, it **hangs**, which for an unattended
installer is the worst of the available outcomes. Ten much older tags, `18.11`
through `22.04.0`, do offer an unattended mechanism, but a different one
(`--conf=`) that would mean a different design. A commit is the only ref at
which the invocation this installer makes exists at all.

**It must be the full 40-character sha**, and `lib/varschema.json` refuses an
abbreviated one with a message saying why: `git` accepts a short sha and checks
out the full one, so upstream's own re-run check compares your seven characters
against its forty, concludes the checkout is somebody else's, and exits `1` on
every second run.

**A pin pins the recipe. It does not pin the software.** One variable pins two
things — the `install.sh` this project fetches and verifies against the sha256
above, and the `-b` argument deciding which payload upstream then clones — and
that is where it stops. What upstream clones names a *mutable* image tag: its
`.env` sets `TPOT_VERSION=24.04.1`, every service is
`${TPOT_REPO}/<name>:${TPOT_VERSION}`, and `TPOT_PULL_POLICY=always`. Two
installs from this same commit, a month apart, can run different containers, and
the daily reboot upstream installs re-pulls them again on a box nobody has
touched. `result.json` reports that as `upstream.pins_payload: false`, which is
permanent rather than a placeholder. **Wherever this project says a ref is
pinned, this paragraph is the other half of the sentence.**

**A pinned sha also makes re-running less safe, not more.** With a sha, upstream's
own `check_tpot_clone` *matches* an existing checkout and skips the clone — over
a tree it never refreshes (`update: no`) and never integrity-checks, so a
modified `docker-compose.yml` or a deleted `env.example` passes it silently.
That is why `tpot_force_reinstall` is documented as what it actually does:
`rm -rf ~/tpotce`.

Everything else this project needs to know about a ref is **measured once, at
pin time**, by `tools/pin-upstream.sh`, and written into
`roles/tpot_install/vars/upstream-<ref>.yml` beside the role that reads it: the
sha256, the compose file each edition copies, the container floor verification
compares against (counted from upstream's own compose files, after the telemetry
service is removed), and upstream's distribution gate row by row with a reason
for each. That file is generated — move the pin and read the diff, never edit
it — and **none of it is evidence that anything was installed.** It is a careful
reading of upstream's source at one commit, done on 2026-09-04.

---

## Supported releases

There are **two tiers**, and neither of them says anything has been tested.

**Supported** — the releases the *pinned* upstream ref's own gate accepts and
this installer can also drive. At the commit pinned above, that is two:

```text
debian:13        ubuntu:26.04
```

**Derived, and not tested — the distinction is the whole point of the tier.**
Nobody here chose that list. `tools/pin-upstream.sh` reads it out of upstream's
`install.sh` at the pinned commit and intersects it with what this installer can
drive at all: of the eight releases upstream's gate names there, four Red Hat
family entries and openSUSE Tumbleweed drop out because upstream installs their
packages with `dnf`, `yum` or `zypper` while this installer requires `apt-get`,
and Raspberry Pi OS drops out because no T-Pot has ever been installed on it
here. The gate is recorded row by row, with the reason for each verdict, in the
per-ref data file under `roles/tpot_install/vars/`.

**Not one of the two rows has a run behind it.** A run would be recorded with
its date in `tests/MATRIX-STATUS.md`, and that file does not exist — which is
why preflight, on recognising your release, says the pinned ref's gate accepts it
and this installer can drive it, and then says in the same message that this is
not a claim it has been tested. That message used to end *"and exercised by this
project's tests"*. It was written while the tier shipped empty and no box could
reach that branch of the check; pinning a ref made it reachable, and it began
printing on every run on a supported release, asserting a test campaign that has
never happened.

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

**Nobody has ever completed this sequence.** The reason is no longer that a file
is missing — the play, its roles and the pin are all in the tree. It is that this
project has never had a machine to point at: no root, no network, no guest
running a release the pinned ref accepts. On the developer box where all of this
was written, every one of those invocations stops in stage A of preflight and
exits `11` on the `root` check. The contract above is what the finished product
owes you; it is not a transcript of something that has happened, and
[Status](#status--what-exists-and-what-does-not) has the measurements.

**If you never make the second invocation, the box is specified to finish
verifying itself.** `roles/finalize` installs a systemd unit that re-runs
verification on the next boot, rewrites `result.json`, and then disarms itself —
which it must, because upstream's own cron job reboots this host every night and
a unit left armed would re-assert a dated record daily against a box nobody has
looked at since.

**That unit does not re-derive its inputs, and the file it reads is part of the
product's permanent on-disk surface.** It reads the configuration this box was
installed with from `{{ tpot_state_dir }}/verify-config.json` —
`/var/lib/tpot-automation/verify-config.json` by default, root-owned `0600` —
which `roles/finalize` writes for it from the merged **public** document: every
secret-typed key already removed by `lib/config.py`, which owns that rule, and
then the three keys `lib/varschema.json` marks `config_file: false`
(`tpot_state_dir`, `tpot_log_dir`, `tpot_runtime_dir`) filtered out on top,
because a verbatim copy of the merged document is refused by `config.py` with
exit `10` — measured, not assumed. Without that file the unit would verify a box
that does not exist: the shipped default OS account, the shipped default
edition, the shipped default ports. It would fail, burn its `StartLimitBurst`,
never clear the arming marker, and leave `result.json` reporting
`post_boot_verify_armed: true` for ever.

The same file is the documented manual recovery path, because it is exactly what
the unit runs:

```sh
install.sh --verify-only --config /var/lib/tpot-automation/verify-config.json
```

It lives under the state directory rather than beside `install.sh` because both
`lib/config.py` and `lib/preflight.sh` refuse an answer file that resolves inside
the installer tree — and the permanent copy the unit runs, at
`/usr/local/lib/tpot-automation`, is an installer tree. That refusal was measured
too. Like everything else in this section, the unit has never run.

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
* **`result.json` is written on every path**, including an interruption at
  minute 70, by an exit trap — unless the state directory itself cannot be
  created, in which case the trap warns on stderr and writes nothing.
  Unprivileged runs on a developer box hit exactly that, which is how it is
  known.

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
verbatim, regenerated with `bash lib/exitcodes.sh`. Like the notice block, it
has a build gate watching it: `tests/check-exit-table.sh` compares this copy,
the one in `docs/exit-codes.md` and the one `install.sh --help` renders against
`lib/exitcodes.sh`, so editing one in place breaks the build rather than
drifting quietly. `docs/exit-codes.md` says what to do about each code.

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
* **The merged configuration reaches Ansible as a file reference** (`-e @PATH`),
  never as `key=value` on a command line. That is how `install.sh` invokes
  `ansible-playbook`, in the single place it does so — a line no run has reached
  yet, because no run has got past preflight — and `tests/check-argv-hygiene.sh`
  holds the rule statically meanwhile, failing the build on `--extra-vars`
  followed by anything that is not `@`.
* **The transcript is redacted as it is written**, and then searched for each
  supplied secret; a hit truncates the log and fails the run.
* **The dashboard password reaches `htpasswd` on standard input.**
  `roles/tpot_install` hands it to the task as `stdin`, never as an argument;
  `htpasswd -b`, which would take it on the command line, is forbidden and the
  argv gate looks for it by name. That task is written and has never run.

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

The cost is that this installer now *owns* those two steps. Both are written, in
`roles/tpot_install`, and neither has ever run against upstream's real checkout.
Upstream's own `.env` edit silently does nothing when the target line is absent,
so ours checks that the write landed rather than assuming it. Upstream also
manages `LS_WEB_USER` itself, which is sensor-to-hive state; this installer never
writes it.

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
service block from the `docker-compose.yml` in its checkout. So `off` does
exactly that: `roles/tpot_install` removes the service — and the network only it
uses — by rewriting the parsed compose document rather than by editing text, and
then asserts it is gone; `roles/tpot_verify` asserts the same absence again on
the installed box. What is checked is that the block is **not there**, never that
an edit was attempted. `"on"` leaves upstream's file untouched. Either way, the
end-of-install notice, this README and `result.json` state which it is. Neither
role has run on a real box.

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
* **installs a root cron job that reboots the host every night at a RANDOMISED
  time**, stopping T-Pot and pruning containers, images and volumes first. The
  hour comes from `range(0, 5)` and the minute from `range(0, 60)`, chosen when
  you install, so no two boxes share a time and no document can name yours. The
  installer reads the job it actually wrote and prints that time in the closing
  notice; `crontab -l -u root` is where to look for it afterwards.

**And the software keeps moving after you verify it.** T-Pot's pull policy
defaults to `always`, so the container images are re-pulled at **every** start —
including that nightly reboot. Pinning the upstream ref pins the recipe; it
does not pin the images, so the software running on a box is not necessarily the
software that was verified on it — see
[The upstream pin](#the-upstream-pin-and-what-it-does-not-pin), which names the
mutable image tag and the pull policy that make it true. `result.json` carries
that as a field — `upstream.pins_payload`, which is `false` and stays `false` —
rather than implying otherwise.

Two messages point at `docs/firewall.md` — the closing notice, and the exposure
line in the preflight report — and neither has ever been printed, because no run
has yet got as far as either one. The file itself is in the tree: it carries
this section's evidence, the ports, why no default firewall is shipped, and a
worked `nftables` example. **Nothing on that page has been applied to a running
T-Pot by this project**, and it opens by saying so.

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
| `docs/firewall.md` | what this installer configures (nothing), what upstream changes anyway, the ports, and a worked example ruleset nobody here has run |
| `SECURITY.md` | credential handling, the `sudo` grant, what the installed box becomes, and how to report a vulnerability |
| `examples/tpot.example.yml` | a commented answer file — the same content as `--example-config` |
| `inventories/example/group_vars/all.yml` | every setting, documented once |
| `support-matrix.yml` | the two tiers, and why each release is in the one it is in |
| `roles/tpot_install/vars/` | the per-ref data file: everything measured about the pinned upstream ref, and upstream's own distribution gate row by row |
| `tools/pin-upstream.sh` | how that file and the supported tier are produced, and why they may never be written by hand |
| `CHANGELOG.md` | what has changed, per version |

Upstream T-Pot's own documentation is at
<https://github.com/telekom-security/tpotce>. **Every claim this file makes about
upstream's behaviour was read from upstream's `master` branch as it stood on
2026-09-02**, and `master` moves. Those claims are why this installer is built
the way it is, and each one has to be re-checked against whichever ref is
actually pinned here. Today that ref is commit `fdafa483`, which *is* that
branch at that moment, so the reading and the pin are the same bytes;
`tools/pin-upstream.sh` recorded the parts a machine needs beside the role that
consumes them. Move the pin and the re-check is owed again.

**Where a file here cites `notes/upstream-facts.md`, it is citing a project
record kept outside this repository, which does not ship with it and which no
clone of this repository contains.** That record is the reconciled reading
behind the upstream claims in this tree, and several files here name it in
place of repeating it. It is not a file you have. Follow any of those citations
to upstream's own source at the ref you pin instead: that is where the reading
was done, and it is the only copy that can be re-checked.
