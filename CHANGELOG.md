# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

The first version. Nothing has been released, so everything below is initial
implementation rather than a change to something earlier.

### What this build actually is

**A slice -- a much larger one since the play landed, and still a slice.** The
entrypoint, the libraries it sources, the build gates, the Ansible play, its
eight roles, the tool that pins an upstream ref, the `bats` suite and
`tests/MATRIX-STATUS.md` are all written. What is not: `tests/fixtures/`, the CI
workflows and the four documents other shipped files cite. The complete list is
*Designed, specified, and not built in this release*, below.

**This code has now installed T-Pot once.** On 2026-09-05, unattended, on a
stock Debian 13 cloud image at upstream ref `fdafa483…`: exit 20, all 14
pre-reboot checks passing, and after a reboot TCP/22 answering as a honeypot
rather than as the host's sshd. `tests/MATRIX-STATUS.md` carries the row, and is
as specific about what that run did not establish as about what it did. Every
other cell of the matrix, in both tiers, remains unrun. There has been no other
machine, no root, no network and no T-Pot. Every claim below about what
happens on a real host is a claim about what the code is written to do, not a
report of it having been done. That was true while the play did not exist and it
is exactly as true now that it does: the play has been syntax-checked, linted
and read, and it has never executed one task against a machine.

**What a run does today, measured rather than predicted.** On this project's own
development box every invocation that would act on a machine -- a full install
with the password in the environment, `--preflight-only`, `--verify-only` and
`--check`, each under `setsid --wait` with stdin closed -- stops in preflight
stage A and exits `11` (`EX_PREFLIGHT`) on the `root` check, having changed
nothing. All four wrote their `result.json` when given a writable `--state-dir`,
and the supplied dashboard password appeared in none of the artefacts they
produced.

**That is a different refusal from the one this file used to describe, and the
change is the whole reason for this release's documentation sweep.** Stage A also
checks that the seventeen files this installer is made of are present, and until
the play landed `site.yml` and `verify.yml` were two it could not find; every
earlier version of this section said so, and said it accurately. They are there
now and that check passes. What stops a run today is that this project has never
had root, a network, or a guest running a release the pinned ref accepts.

`install.sh` still refuses at step 9 if `site.yml` is absent from the checkout it
is running from: it logs what is missing, records `internal_error` and returns
`40`. That arm has never executed and, in a release containing the play, cannot.
It exists so that a build without a play cannot report success, and the guarantee
it shares with preflight is unchanged: **no run that has ever been made could
reach exit `0` or exit `20`**, so none of them claimed to install anything.

### Added

- `install.sh`: a single unattended entrypoint that runs as root on the target
  host, parses long-form flags, merges configuration from four channels,
  preflights the box, bootstraps its own dependencies, invokes the play and
  maps a failure class to a documented exit code.
- `site.yml` and `verify.yml`, the install play and the verification play, and
  the eight roles they are built from: `preflight`, `os_prep`, `tpot_user`,
  `tpot_install`, `tpot_verify`, `finalize`, `ioc_forward` and `report`.
  Everything that would change a box is there -- the OS preparation, the pinned
  upstream fetch and its sha256 check, upstream's own installer driven
  unattended, the compose swap, the `.env` credential write, the telemetry
  removal, verification either side of the reboot, and the post-boot systemd
  unit. It is syntax-clean, `yamllint` clean and passes `ansible-lint`'s
  `production` profile with no failures. It has never run on a machine.
- `roles/report`, which the build spec did not name. `site.yml` and `verify.yml`
  both have to write the same two output documents --
  `$RUNDIR/ansible-report.json` and `$RUNDIR/failure-class` -- and a schema
  copied into two plays is a schema nobody diffs. It also owns the
  stage-to-exit-code map, in `vars/` rather than `defaults/` so that no answer
  file can move it.
- `tests/check-stage-map.sh`, the gate that keeps that map in step with
  `docs/exit-codes.md` and with `lib/exitcodes.sh`, and fails when a role claims
  a stage no table gives a row. A stage with no row resolves to `40`, so without
  this gate a renamed stage would quietly report every ordinary failure in that
  role as *"a bug in this installer"*.
- One configuration surface, merged in one place, with one precedence order:
  `--set`/flag beats environment beats answer file (later file wins) beats the
  built-in default. Keys are the Ansible variable names verbatim, so an answer
  file is directly consumable as `ansible-playbook -e @file`.
- `lib/exitcodes.sh` as the single source of truth for the exit table.
  `docs/exit-codes.md` and `README.md` embed its output between generated
  markers and `install.sh --help` prints it; all three agree with it byte for
  byte, and `tests/check-exit-table.sh` is the build gate that keeps them
  agreeing rather than leaving it to whoever remembers.
- Preflight in two stages that mutate nothing: stage A before any dependency
  exists, stage B after the merge. `--preflight-only` reports and exits, and
  distinguishes "nothing failed" from "some checks could not be exercised".
- A machine-readable outcome at `/var/lib/tpot-automation/result.json`,
  schema `tpot-automation/result@1`, written by an exit trap so it exists on
  every path including interruption -- the single exception, observed on an
  unprivileged developer run, being a state directory that cannot be created,
  where the trap warns on stderr and writes nothing. It reports the pinned ref,
  the ref upstream was actually given, whether the two agree, and
  `upstream.pins_payload: false` -- which is permanent, because pinning a ref
  pins the recipe and never the container images.
- `/var/lib/tpot-automation/verify-config.json` -- `{{ tpot_state_dir }}` in the
  role -- written root-owned `0600` by `roles/finalize`, and the `--config` the
  post-boot verification unit is started with. It is the merged **public**
  document: every secret-typed key already removed by `lib/config.py`, which owns
  that rule, then filtered to drop the three keys `lib/varschema.json` marks
  `config_file: false`, because a verbatim copy of the merged document is refused
  by `config.py` with exit `10`. It lives under the state directory rather than
  beside `install.sh` because both `lib/config.py` and `lib/preflight.sh` refuse
  an answer file that resolves inside the installer tree -- and the permanent
  copy the unit runs, at `/usr/local/lib/tpot-automation`, is an installer tree.
  Both refusals were measured, not assumed.
  `install.sh --verify-only --config /var/lib/tpot-automation/verify-config.json`
  is the documented manual recovery path, because it is exactly what the unit
  runs.
- `lib/notice.sh`: the closing notice that tells the operator what the box has
  become -- the sshd move to 64295, which honeypot took TCP/22 for the edition
  installed, what upstream changed about filtering, and whether upstream's
  community submission is on or off.
- **An upstream ref, pinned**: commit
  `fdafa483e1e0f36b0a7b0cbb6bae1031fe06fc37`, whose `install.sh` has sha256
  `0e0b893b86aeca80f4ef43c30b851850b0370f43ced37bcda36ecee52faeda50`. A commit
  and not a tag, because no tag carries upstream's unattended flags at all: `-s`,
  `-t`, `-u` and `-p` landed on `master` on 2025-07-05 and `-b` and `-r`
  thirteen and a half months later, while the newest tag (`24.04.1`,
  2024-12-11) has no positional-parameter handling -- driven non-interactively
  it does not fail, it hangs. `lib/varschema.json` refuses an abbreviated sha
  and says why: git accepts a short one and checks out the full one, so
  upstream's own re-run check would compare seven characters against forty and
  exit `1` on every second run. It also gained a `pattern_help` field so that a
  regex refusal can state the right form instead of printing the regex.
- `tools/pin-upstream.sh`, which produced that pin and everything derived from
  it, and is the only supported way to move it: the sha256, the compose file
  each edition copies, the per-edition container floor counted from upstream's
  own compose files after the telemetry service is removed, upstream's
  distribution gate row by row with a reason for each verdict, and the supported
  tier of `support-matrix.yml` together with the ref it came from. Two generated
  files, rewritten in one edit, never by hand. **A pin pins the recipe and not
  the software**: upstream's `.env` names a mutable image tag
  (`TPOT_VERSION=24.04.1`) with `TPOT_PULL_POLICY=always`, so two installs from
  this same commit a month apart can run different containers.
  `upstream.pins_payload: false` in `result.json` has always meant exactly this;
  it now has a version string behind it.
- **A supported tier with two rows in it**, `debian:13` and `ubuntu:26.04`,
  derived from the pinned ref's own gate intersected with what this installer
  can drive: the four Red Hat family releases and openSUSE Tumbleweed upstream
  also accepts drop out as `dnf`, `yum` and `zypper` boxes, and Raspberry Pi OS
  drops out because nobody here has installed T-Pot on one. **Derived is not
  tested**, and this file uses the two words apart on purpose -- see
  *Verification status*.
- `support-matrix.yml` with two tiers, and a reader for it in both `bash` and
  YAML that `tests/check-matrix-parse.sh` proves equivalent.
- `inventories/example/group_vars/all.yml`: the complete variable surface as
  commented placeholders, so every knob is discoverable without any file in
  the tree holding a real value.
- Build gates under `tests/`, run by `tests/run-gates.sh`, each turning one
  promise into a build break: no interactive prompt anywhere, no credential or
  bare value on a command line, no screen-scraping driver, no trace of the
  customer this work derives from, `C.UTF-8` and never plain `C`, the matrix
  readers agreeing, the notice block matching its documentation, every written
  copy of the exit table matching `lib/exitcodes.sh`, the variable surface
  agreeing across schema and example inventory, the play's stage-to-exit-code map
  agreeing with both documents that publish it, and every path this tree names
  either existing on disk or being declared absent in the gate's own registry --
  which is what a not-built list becomes when it has to survive somebody doing
  the work. All of them pass on this tree and the runner exits `0`, printing the
  five live `gate-allow` exemptions under its summary.
- Negative proof for the gates themselves, because a gate whose pattern
  matches nothing passes forever while checking nothing.
  `tests/run-gates.sh --self-test` builds a deliberately violating tree
  outside the repository, points each gate at it, and requires it to fail. **A
  gate with no fixture registered in the runner comes back `UNPROVEN`** rather
  than being counted as a pass. `check-matrix-parse.sh` is one of those, and
  `UNPROVEN` is not the same as untested: its negative controls live inside its
  own assertions instead -- rejections of a glob, a prefix, a suffix, an empty
  value and a value spanning two rows, plus a control that reproduces
  upstream's own membership idiom and demonstrates it accepting four strings that are not
  distribution names. What is missing is the runner-level proof, and the summary
  prints `UNPROVEN` rather than implying otherwise.
- A gate that cannot run reports `SKIP`: its own verdict in the summary, never
  shown as a pass, because "checked nothing" and "found nothing" are different
  facts and only one of them is reassuring. The runner says so in words -- a
  run with a skip in it is reported as not clean, not as "all gates passed" --
  and `--strict` makes it a failing exit status. No gate skips on this tree.
- A reserved `ioc_*` namespace: IoC forwarding is declared and documented as
  five variables that this release does not implement -- and, since the play
  landed, refuses rather than accepts. See *Fixed* for why the refusal is in two
  places with two different exit codes.
- `README.md`, `SECURITY.md`, `docs/exit-codes.md` and this file, each written
  against what the tree contains and each stating plainly where it describes
  something that is written but has never run -- and, where something is still
  unbuilt, saying which gate would break if that stopped being true.
- `docs/firewall.md`: the firewall position in full -- what this installer
  configures (nothing), what upstream's playbook changes about a host's
  filtering anyway, the administrative ports, why no default ruleset is
  shipped when nobody has written down which ports a honeypot must leave
  open, and a worked `nftables` example. That example has never been loaded on
  a host running T-Pot, and the document says so at the top rather than at the
  bottom.

### Designed, specified, and not built in this release

Listed here because a changelog that omitted them would read as though they
shipped. Each is specified; none of it exists in this tree.

- **The CI workflows**, including the release gate that refuses a tag while
  `tests/MATRIX-STATUS.md` has a missing or stale row. (Two things have left this
  list: the check that keeps `lib/exitcodes.sh`, `docs/exit-codes.md`, `README.md`
  and `--help` from drifting apart shipped as `tests/check-exit-table.sh`, and the
  `bats` suite shipped -- it now runs 304 tests over the libraries.)
- **Four referenced documents.** Every one is cited by a file that does ship,
  and none is written: `docs/answer-file.md` and `docs/variables.md`, both
  cited by `lib/config.py`; `docs/verification.md`, cited by
  `lib/preflight.sh`; and `docs/roadmap-ioc.md`, cited by the example answer
  files and the example inventory. The list is exhaustive as of this release
  and is meant to stay that way -- a not-built list whose whole value is being
  complete is worth nothing the first time something is left off it, and it is
  worth no more the first time it keeps something that has since been written.
  It said five, and `docs/firewall.md` was the fifth: that document is now in
  the tree, cited by `lib/notice.sh`, `lib/preflight.sh`, `SECURITY.md`,
  `README.md`, both example answer files and the example inventory. It is
  listed under *Added* instead.
- **`tests/fixtures/`**, the `/proc` and configuration fixtures the unit suite
  would read. `.gitignore`, `.yamllint` and `.ansible-lint` already carve out
  the path and `lib/preflight.sh` names it; the directory does not exist.

**Six entries left this list in one day, and that is the failure mode this
section is built around.** The Ansible play and every role, the verification
split across the reboot, the post-boot systemd unit that re-runs it and disarms
itself, the `.env` and compose work, the refusal that makes the reserved IoC
namespace real, and `tools/pin-upstream.sh` were all described here as
specified-and-absent; every one of them is now under *Added*. A list of what does
not exist rots faster than any other prose in a repository, because the event
that falsifies it -- somebody doing the work -- is the event nobody thinks to go
and check prose over. That is why this list is no longer only prose:
`tests/check-references.sh` holds it as a registry and fails the build in both
directions, so a path declared absent that has since been written breaks the
build and names every sentence in the tree that still cites it.

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
  The task that performs it is in `roles/tpot_install`; it is written and has
  never been executed, so this remains a documented rule rather than an observed
  one. Upstream is never handed a username or a password. The sensor type is
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

### Fixed

Nothing has been released, so nothing here was ever shipped broken. These are
defects found by reading and reviewing the play before any of it ran, recorded
because the reasoning is the useful part -- and because three of them are the
kind that end in a run reporting the wrong thing rather than failing.

- **A `--check` run reported every failure as `40`.** `ansible.builtin.copy`
  supports check mode, so under `--check` it announces `changed` and writes
  nothing -- measured here on ansible-core 2.21.2. The play's two output
  documents, `$RUNDIR/ansible-report.json` and `$RUNDIR/failure-class`, are
  written with `copy`, so a dry run produced neither: `install.sh` then had no
  failure-class file to read, and a missing one is `EX_INTERNAL`. Every dry-run
  failure, at every stage, therefore collapsed to `40` -- *"a bug in this
  installer, file an issue"* -- for a run that behaved exactly as designed, while
  `result.json` carried an empty verification list and neither `reboot_required`
  nor `already_installed`. Both tasks now set `check_mode: false`. That is safe
  because both files land in `$RUNDIR`, the 0700 tmpfs directory `install.sh`
  creates for the run and shreds afterwards: a check run still changes nothing an
  operator could find.
- **`ioc_forwarding_enabled: true` was refused by the last role in the play.** A
  run with that flag set would have installed a complete T-Pot over some ninety
  minutes and then reported *"bad flag, nothing happened"* -- which is the exact
  failure this project exists to remove. `roles/preflight` now refuses it as its
  first check, in about two seconds, with `11`, whose published meaning is
  *nothing on this box was changed*: true at preflight and false after
  `finalize`. `roles/ioc_forward` keeps its own assert as the last line of
  defence and answers `10`, reachable only when the preflight stage was skipped
  by tag selection. The two codes are not two answers to one question, and the
  `ioc` row of the stage table describes the second gate only.
- **`--verify-only` could return `0` for a box whose containers were never
  counted.** A missing or unparseable `docker-compose.yml` produced a container
  floor of `0`, which any count satisfies, and the two checks that would have
  noticed went quiet together -- so a run that established nothing reported
  *"installed and verified"*. Two new pre-reboot checks, `compose_file_present`
  and `container_floor`, close that input, and a gate at the foot of the role
  fails a verify run in which a post-reboot check the caller asked for came back
  `skipped`. `16` now covers *"a check could not be run at all"* as well as *"a
  check ran and failed"*. **The exit-`20` path is untouched**: in a `site.yml`
  run the post-reboot checks are skipped by design, because the reboot has not
  happened yet, and edition-absent checks -- a sensor has no dashboard, mobile
  has no Elasticsearch -- are legitimately skipped too. Neither fails a run.
- **The post-boot verification unit re-derived every input from schema
  defaults.** Any install that changed the OS account, the install type, a port
  or the telemetry setting would have got a post-boot verification aimed at a box
  that does not exist: it fails, burns `StartLimitBurst`, never removes the
  `verify-pending` marker, and leaves `result.json` reporting
  `post_boot_verify_armed: true` for ever. The unit's `ExecStart` now passes
  `--config` to the file `roles/finalize` writes for it; see *Added*.
- **`lib/preflight.sh` asserted a test campaign that has never happened.** Its
  `SUPPORTED` tier message ended *"...and exercised by this project's tests"*.
  That was written while the tier shipped empty and no box could reach the
  branch; pinning a ref made it reachable, and it began printing on every run on
  a supported release. It now says the pinned ref's gate accepts the release and
  this installer can drive it, and states plainly that this is **not** a claim it
  has been tested.

**None of these corrections has run on a real box either.** They are readings of
the code, and where a number appears it was measured on the development machine.

### Security

- No secret is ever a command-line argument value in this project's own code,
  and `tests/check-argv-hygiene.sh` fails the tree if a flag that would take
  one is added. There is no dashboard-password flag that takes a value; there
  is `--web-password-file`, which takes a path.
- Secrets reach Ansible as a path to a mode-0600 document on tmpfs, and reach
  `htpasswd` on standard input in `roles/tpot_install` -- written, never run.
  `htpasswd -b`, which takes the password as an argument, is forbidden and the
  gate checks for it.
- The configuration `roles/finalize` leaves on disk for the post-boot
  verification unit is the merged **public** document, with every secret-typed
  key removed by `lib/config.py` before the role sees it. The role asserts that
  no secret key is present in what it is about to write, and fails rather than
  writing a file it cannot vouch for.
- The transcript is redacted as it is written and then searched for each
  supplied secret; a hit truncates the log, records
  `credential_leaked_to_log` and fails the run with `40`.
- `result.json` is built from a document with every secret-typed key already
  removed, so it cannot carry a credential. It also records the flags upstream
  was given, with any password value masked and a warning attached -- because
  on this project's own path that can never happen, so seeing it means
  something drove upstream a different way.
- The OS account is created locked in `roles/tpot_user`, with its passwordless
  sudo grant written out explicitly rather than inherited from a module default
  -- `community.general.sudoers` defaults `nopassword: true`, which is how an
  account ends up with `NOPASSWD ALL` that nobody wrote down. Upstream's
  unattended mode refuses to run without that grant. Like the rest of the play,
  that role has never run.
- Nothing in the tree prints the whole environment: no bare `export`, `env`,
  `printenv` or `set`. That one is held by review rather than by a gate.

### Verification status

**Not releasable, and one cell of the matrix has been proven on a machine.**
A single virtual-machine run has been made: 2026-09-05, Debian 13, upstream ref
`fdafa483…`, installed to exit 20 and then rebooted, after which TCP/22 answered
as a honeypot. `tests/MATRIX-STATUS.md` holds the dated record, including the
list of what the run did NOT establish -- most importantly that the post-reboot
verification records were written on the box and never read, because that
network cannot be reached from where the run was driven. **Exit 0 has still
never been observed from this product.**

What *has* been executed is the tree's own gates, unprivileged, on a
development box -- `tests/run-gates.sh`, every gate passing, exit `0`; the play
and its roles through `yamllint`, `ansible-lint --offline` (0 failures, and the
stricter `production` profile passes) and `ansible-playbook --syntax-check`; and
`install.sh` itself, run to its refusal with stdin closed under `setsid --wait`
in every mode it offers. Each of those runs exited `11` and wrote
`result.json`; in the ones that were given a dashboard password, that password
appears nowhere in the terminal output, the transcript or the result file.

**A lint is not a run and a syntax check is not an install.** That is evidence
about this repository, not about any host: no run reached a step that changes a
machine, and none could have.

The support matrix has two tiers, and the honest statement of each is:

- **Supported is two rows, and neither of them is tested.** A release is
  supported on exactly the distributions the *pinned* upstream ref accepts and
  this installer can drive; at commit `fdafa483` that is `debian:13` and
  `ubuntu:26.04`, written into `support-matrix.yml` by `tools/pin-upstream.sh`
  together with the ref they were derived from.
  `tests/check-matrix-parse.sh` requires the tier and that ref to be empty or
  non-empty together, so a supported row can never appear without the pin it came
  from. **Tested** is a different word needing a different artefact -- a dated
  row in `tests/MATRIX-STATUS.md`. Exactly one cell has one: `debian:13` at ref
  `fdafa483…`. `ubuntu:26.04` is supported by derivation and has never been run.
- **Legacy is a historical record of where the predecessor ran, not a
  compatibility claim by this project (D-12):** Debian 11/12/13, Ubuntu
  20.04/22.04/24.04 and Linux Mint 20/21/22. Upstream T-Pot's own
  `install.sh` refuses eight of the nine outright -- Linux Mint is absent from
  its distribution list entirely, Debian is compared against major `13` and
  Ubuntu against the exact string `26.04`, both with string inequality and no
  ordering, and there is no override flag of any kind. Reaching a legacy row
  therefore means pinning an older upstream ref, and whether any given
  (ref x distribution) pair works is unrecorded until a dated run says so.
  Evidence: upstream's `install.sh` distribution and version gates, executed
  against fixture `/etc/os-release` files under `tests/os-release/`; full
  reading in `notes/upstream-facts.md`, a project record kept outside this
  repository, which no clone of it contains -- see the end of `README.md`.

The earlier installer's "works on nine distributions" was never evidence that
transfers here: it fetched upstream's `install.sh` from a moving branch, with
a guard that stopped a second run from refreshing it, so it is a statement
about whichever copy that branch served on the day it was tested.
