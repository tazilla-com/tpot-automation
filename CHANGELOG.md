# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

The first version. Nothing has been released, so everything below is initial
implementation rather than a change to something earlier.

### What this build actually is

**A slice, and this file says so rather than implying a finished tool.** The
entrypoint, the libraries it sources and the build gates are written. **The
Ansible play is not**: `site.yml`, `verify.yml` and the whole of `roles/` are
a separate slice and are absent from this tree, and so are
`tools/pin-upstream.sh`, the `bats` suite, the CI workflows and
`tests/MATRIX-STATUS.md`.

**Nothing has ever been installed by this code.** There has been no virtual
machine, no root, no network and no T-Pot. Every claim below about what
happens on a real host is a claim about what the code is written to do, not a
report of it having been done.

`install.sh` is built to refuse rather than to pretend. The switch is whether
the play file is present on disk: with no `site.yml` there, it logs what is
missing, leaves the box unchanged at that step, records `internal_error` and
returns `40`. **No run of this build can reach exit `0` or exit `20`.**

### Added

- `install.sh`: a single unattended entrypoint that runs as root on the target
  host, parses long-form flags, merges configuration from four channels,
  preflights the box, bootstraps its own dependencies, invokes the play and
  maps a failure class to a documented exit code.
- One configuration surface, merged in one place, with one precedence order:
  `--set`/flag beats environment beats answer file (later file wins) beats the
  built-in default. Keys are the Ansible variable names verbatim, so an answer
  file is directly consumable as `ansible-playbook -e @file`.
- `lib/exitcodes.sh` as the single source of truth for the exit table.
  `docs/exit-codes.md` and `README.md` embed its output between generated
  markers and `install.sh --help` prints it; all three agree with it byte for
  byte today, and the check that keeps them agreeing is listed below as not
  yet built.
- Preflight in two stages that mutate nothing: stage A before any dependency
  exists, stage B after the merge. `--preflight-only` reports and exits, and
  distinguishes "nothing failed" from "some checks could not be exercised".
- A machine-readable outcome at `/var/lib/tpot-automation/result.json`,
  schema `tpot-automation/result@1`, written by an exit trap so it exists on
  every path including interruption. It reports the pinned ref, the ref
  upstream was actually given, whether the two agree, and
  `upstream.pins_payload: false` -- which is permanent, because pinning a ref
  pins the recipe and never the container images.
- `lib/notice.sh`: the closing notice that tells the operator what the box has
  become -- the sshd move to 64295, which honeypot took TCP/22 for the edition
  installed, what upstream changed about filtering, and whether upstream's
  community submission is on or off.
- `support-matrix.yml` with two tiers, and a reader for it in both `bash` and
  YAML that `tests/check-matrix-parse.sh` proves equivalent.
- `inventories/example/group_vars/all.yml`: the complete variable surface as
  commented placeholders, so every knob is discoverable without any file in
  the tree holding a real value.
- Eight build gates under `tests/`, run by `tests/run-gates.sh`, each turning
  one promise into a build break: no interactive prompt anywhere, no
  credential or bare value on a command line, no screen-scraping driver, no
  trace of the customer this work derives from, `C.UTF-8` and never plain `C`,
  the matrix readers agreeing, the notice block matching its documentation,
  and the variable surface agreeing across schema and example inventory. Each
  gate ships a negative proof, and a gate that cannot run reports `SKIP`,
  which `tests/run-gates.sh` never counts as a pass.
- A reserved `ioc_*` namespace: IoC forwarding is declared and documented as
  five variables that this release does not implement.
- `README.md`, `SECURITY.md`, `docs/exit-codes.md` and this file, each written
  against what the tree contains and each stating plainly where it describes
  something that is designed and not built.

### Designed, specified, and not built in this release

Listed here because a changelog that omitted them would read as though they
shipped. Each is specified; none of it exists in this tree.

- **The Ansible play and every role.** `site.yml`, `verify.yml` and `roles/`.
  Everything that changes the box lives there, which is why this build cannot
  install anything.
- **The verification role**, split across the reboot T-Pot requires, so that
  exit `0` will mean installed *and* verified and never anything weaker.
- **The post-boot systemd oneshot** that re-runs verification on the next
  boot and rewrites `result.json`, so that an unattended caller which never
  makes a second invocation still ends up with a true outcome file.
  **It must disarm itself after its first successful verification.** Upstream
  T-Pot's own playbook installs a root cron job that reboots the host every
  day at 02:42, so a unit left armed would fire every night and rewrite
  `result.json` daily -- turning a dated record of one verified install into a
  file that silently re-asserts itself against a box nobody has looked at
  since. Disarming after the first success is a requirement of the unit, not
  a refinement of it.
- **The `.env` and compose work** that follows the upstream run: copying the
  requested edition's compose file over upstream's `docker-compose.yml`, and
  writing the dashboard credential into upstream's `.env`. See `SECURITY.md`
  for why this project does these itself.
- **The refusal that makes the reserved namespace real.** Setting
  `ioc_forwarding_enabled: true` is specified to fail with a message naming
  the release it is planned for; today the variable is documented as reserved
  and validated as a boolean, and the assertion that refuses it lives in the
  role that does not exist yet.
- **`tools/pin-upstream.sh`**, which fetches upstream's `install.sh` at a ref,
  prints its sha256 and scaffolds the per-ref data file. Until it is run, no
  ref is pinned -- see *Verification status*.
- **The CI workflows and the `bats` suite**, including the check that keeps
  `lib/exitcodes.sh`, `docs/exit-codes.md`, `README.md` and `--help` from
  drifting apart, and the release gate that refuses a tag while
  `tests/MATRIX-STATUS.md` has a missing or stale row.
- **Three referenced documents**: `docs/firewall.md`, `docs/verification.md`
  and `docs/roadmap-ioc.md`. Each is cited by a file that does ship, and none
  of them is written.

### Changed

Relative to the installer this project derives from, which is not published
here:

- Upstream T-Pot is driven through its own documented unattended mode instead
  of by an `expect` script matching its interactive prompts byte for byte.
  That mechanism is deleted rather than generalised -- its failure mode was to
  fire canned answers into the wrong state for an hour and then exit `0` on a
  host that was never installed -- and `tests/check-no-expect.sh` keeps it
  deleted.
- The invocation is `-s -t s -b <ref>`: unattended, sensor type, pinned ref.
  It is a decision and a documented rule, not yet a running invocation -- the
  task that performs it is in the role that has not landed.
  Upstream is never handed a username or a password. The sensor type is
  chosen precisely because that code path never enters upstream's credential
  branch, and it runs the identical playbook; the two things a credentialed
  install type would have done -- choosing the compose file and writing the
  dashboard user into `.env` -- this project does itself, with the password on
  standard input. `SECURITY.md` is the long form, and the argv gate fails the
  build on any line that claims otherwise.
- One variable, `tpot_upstream_ref`, decides both the URL upstream's
  `install.sh` is fetched from and the ref argument it is given. They may
  never be set apart: upstream never re-fetches or re-executes itself, so its
  distribution gate and its sudo handling are whatever copy was executed,
  while the ref argument governs only the playbook that copy then clones --
  and given no ref argument, outside a git work tree, upstream silently falls
  back to its own default branch. This project's own sha256 check on the
  fetched file is not replaced by upstream's pinning; the sha256 pins the
  entrypoint, upstream's ref argument pins the payload.
- The support matrix is two tiers rather than one list of nine releases. See
  *Verification status*.

### Security

- No secret is ever a command-line argument value in this project's own code,
  and `tests/check-argv-hygiene.sh` fails the tree if a flag that would take
  one is added. There is no dashboard-password flag that takes a value; there
  is `--web-password-file`, which takes a path.
- Secrets reach Ansible as a path to a mode-0600 document on tmpfs, and are
  specified to reach `htpasswd` on standard input in the role that has not
  landed. `htpasswd -b`, which takes the password as an argument, is forbidden
  and the gate checks for it.
- The transcript is redacted as it is written and then searched for each
  supplied secret; a hit truncates the log, records
  `credential_leaked_to_log` and fails the run with `40`.
- `result.json` is built from a document with every secret-typed key already
  removed, so it cannot carry a credential. It also records the flags upstream
  was given, with any password value masked and a warning attached -- because
  on this project's own path that can never happen, so seeing it means
  something drove upstream a different way.
- The OS account is specified to be created locked, with its passwordless
  sudo grant stated explicitly rather than inherited from a module default.
  Upstream's unattended mode refuses to run without that grant.
- Nothing in the tree prints the whole environment: no bare `export`, `env`,
  `printenv` or `set`. That one is held by review rather than by a gate.

### Verification status

**Not releasable, and nothing here has been proven on a machine.** No
virtual-machine run has ever been made. This build has never installed T-Pot;
there is no host anywhere that it produced, and no transcript of it having
run. `tests/MATRIX-STATUS.md` is where a dated per-cell record is to live, and
that file does not exist yet -- so there is no row to read and none to trust.

What *has* been executed is the tree's own gates, unprivileged, on a
development box: `tests/run-gates.sh`. That is evidence about this repository,
not about any installed host.

The support matrix has two tiers, and the honest statement of each is:

- **Supported and tested is currently empty.** A release is supported on
  exactly the distributions the *pinned* upstream ref accepts, and no ref is
  pinned in this tree. `support-matrix.yml` therefore ships an empty supported
  tier rather than a claim, and `tests/check-matrix-parse.sh` fails the build
  if anything is listed as supported while the ref is unset.
- **Legacy is nine older releases, documented and never claimed as tested:**
  Debian 11/12/13, Ubuntu 20.04/22.04/24.04 and Linux Mint 20/21/22. They are
  the releases the earlier installer was used on. Upstream T-Pot's own
  `install.sh` refuses eight of the nine outright -- Linux Mint is absent from
  its distribution list entirely, Debian is compared against major `13` and
  Ubuntu against the exact string `26.04`, both with string inequality and no
  ordering, and there is no override flag of any kind. Reaching a legacy row
  therefore means pinning an older upstream ref, and whether any given
  (ref x distribution) pair works is unrecorded until a dated run says so.
  Evidence: upstream's `install.sh` distribution and version gates, executed
  against fixture `/etc/os-release` files under `tests/os-release/`; full
  reading in the project's `notes/upstream-facts.md`.

The earlier installer's "works on nine distributions" was never evidence that
transfers here: it fetched upstream's `install.sh` from a moving branch, with
a guard that stopped a second run from refreshing it, so it is a statement
about whichever copy that branch served on the day it was tested.
