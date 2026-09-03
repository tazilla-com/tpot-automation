# Exit codes

`install.sh` communicates through its exit status. That is the product: a
caller -- cloud-init, Packer, a CI job, a colleague's shell script -- must be
able to branch on the outcome without parsing English.

Three properties are designed to hold:

* **`0` means installed AND verified.** It is never returned for a host that
  has not been checked. A T-Pot that has not rebooted cannot be verified, so
  the first invocation of a fresh install returns `20`, not `0`.
* **Every failure code names how far the run got.** `11` never touched the
  box; `14` never ran upstream's installer; `16` has T-Pot installed and one
  assertion unhappy. The number is enough to decide whether to retry, roll the
  machine back, or read the transcript. The one place this is blunter than it
  looks is `15` versus `16`, and `15` says why.
* **Something is always written.** `result.json` is produced by an exit trap,
  so it exists on every path -- including an interruption at minute 70. The one
  way to get no file is a state directory that cannot be created at all; the
  trap then warns on stderr instead, which is what an unprivileged run on a
  developer box produces.

## What this build can and cannot return

**The Ansible play does not exist in this tree.** `site.yml`, `verify.yml` and
the whole of `roles/` are a separate slice and have not been written, so
**this build has never installed anything and cannot**. There has been no
virtual machine, no root and no network. What has been executed is the tree's
own gate suite and `install.sh` itself, unprivileged, run to the refusal
described below -- never past it.

`install.sh` refuses rather than pretends, and it does so **twice over**.

The outer refusal is the one that actually fires. Preflight stage A checks that
the seventeen files this installer is made of are on disk; `site.yml` and
`verify.yml` are two of them; a tree missing them fails that check and the run
returns **`11`** at step 3 of the ten steps a run performs -- before the
configuration is merged, and before anything on the box is touched. No
`--force-*` flag relaxes it, and `--verify-only`, `--preflight-only` and
`--check` are all stopped by it too.

The inner refusal is the one described in `install.sh` itself: at step 9 the
play is looked for again, and when it is absent the run logs what is missing,
sets the outcome to `internal_error` and returns `40`. **Step 9 is never
reached in this build.** That arm is written, it is shadowed by the check above,
and it has never executed.

So in this build:

* `10` and `11` are reachable and are the real behaviour of the code in this
  tree -- argument handling and preflight stage A are written, and both numbers
  above were produced by running it;
* **`11` is what every full run returns today**, with `repo_tree` named in the
  preflight report as the check that failed -- and, on the unprivileged
  development box these runs were made on, `root` named beside it;
* `12` is `--preflight-only`'s code for "nothing failed, something could not be
  measured", so it needs stage A to pass first, which cannot happen while the
  play is missing. The unpinned upstream ref that would otherwise produce it is
  a stage B check, and stage B is never reached;
* `13` through `16` and `20` describe the contract and are **not exercisable
  yet** -- every one of them names a stage that lives in the play. Nothing below
  that describes them is a report of observed behaviour;
* `30` is written and would be produced by the exit trap on a signal; nothing
  here has exercised it;
* `40` is written and, in this build, **unreachable**, for the reason above.
* **So no run of this build can reach `0` or `20`.** That is the guarantee both
  refusals exist for, and it holds whichever one of them fires.

Everything else in this document is written in the present tense because it is
the contract the codes name, not because a machine has demonstrated it. When
the play lands, this section is what has to change.

## The table

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

The block above is generated. `lib/exitcodes.sh` is the source of truth;
regenerate the copies with:

```sh
bash lib/exitcodes.sh
```

Three copies of that table exist -- this file, `README.md` and
`install.sh --help` -- and all three agree with `lib/exitcodes.sh` byte for
byte. That is now a property rather than a state: **`tests/check-exit-table.sh`
is a build gate**, it runs in `tests/run-gates.sh`, and it fails the build when
any copy drifts. Regenerate them after a change to `lib/exitcodes.sh` rather
than editing one in place; the gate will tell you if you forget.

## What to do about each one

### 0 -- `EX_OK`

Nothing. The host is installed and every verification assertion passed.
Administrative SSH is on 64295 and port 22 is a honeypot -- which honeypot
depends on the edition you installed, and the notice `install.sh` printed
names it where upstream documents which one it is. Read that notice before you
log out.

### 10 -- `EX_USAGE`

You supplied something this installer does not accept, or did not supply
something it requires. The message names the offending flag, key or file and
the rule it broke. Nothing on the box was changed.

The four common cases:

* a typo in a `TPOT_*` or `IOC_*` environment variable -- an unrecognised name
  is an error rather than a silent default, so that a misspelt password
  variable cannot turn into a confusing "missing input" message later;
* an unknown key in an answer file -- same reasoning;
* `--set` on a secret key -- refused by design, because a flag value is
  world-readable in `/proc`. Use `--web-password-file`, the environment, or an
  answer file;
* an answer file that is inside the repository, or that holds a secret while
  not being root-owned `0600`/`0400`.

### 11 -- `EX_PREFLIGHT`

The box is not in a state this installer will act on, and **nothing was
changed**. Preflight runs before the first mutation for exactly this reason.

**In this build `11` is what you get from anything that would act on the box**
-- `--help`, `--version` and `--example-config` print and exit `0` without
reaching preflight -- and on a box you would really install on the failing
check is `repo_tree`: stage A verifies that the seventeen files this installer
is made of are present, and `site.yml` and `verify.yml` have not been written
yet. The preflight report names them and says so. Nothing is wrong with your
copy, no flag relaxes it, and note that the one-line meaning for `11` in the
table above does not list this condition -- the preflight report is what tells
you which check failed.

The runs behind that paragraph were made unprivileged, on a development box, so
the report they produced names **two** failures rather than one: `root` fails
there too, because the run was not root. Read `repo_tree` as the one that
survives on a root shell, and `root` as an artefact of where the measurement was
taken.

Resource floors can be overridden with `--force-low-resources`, and the
supported-distribution check with `--force-unsupported-os`; both are recorded
in `result.json`, so a forced run stays distinguishable from a clean one
forever. A bound port, a missing `systemd`, a non-tmpfs `/run` and an
unreachable upstream have no override: they are conditions under which the
install cannot succeed, not preferences.

**`--force-unsupported-os` relaxes this project's check and nothing else.**
Upstream T-Pot's installer gates on `/etc/os-release` itself, before it reads
any of its own flags, and that gate has no override in any form -- no flag, no
environment variable. Forcing past our check on a distribution the pinned
upstream ref refuses buys you a mutated box and an upstream failure later, not
an install. The supported way to reach an older release is the **legacy tier**:
pin an older `tpot_upstream_ref`, whose own gate accepted it.
`support-matrix.yml` is the one place either tier is written down, and neither
tier is a claim that a particular pair was tested. **No pair has been
tested.**
`tests/MATRIX-STATUS.md` is where a dated record would live and that file does
not exist yet.

### 12 -- `EX_INCONCLUSIVE`

Only ever returned by `--preflight-only`. Nothing failed, but some checks
could not be exercised on this box -- typically inside a container, where
there is no `systemd` to ask and no real block device to measure.

It exists because **a check that could not run is not a pass**. Reporting one
as green is how a test tier ends up green-lighting precisely what it declined
to test. In a full run there is no such downgrade: an inconclusive hard check
fails closed as `11`.

### 13 -- `EX_DEPS`

Bootstrapping this installer's own prerequisites failed: an `apt` operation,
the resolution of `ansible-core`, or the collection install.

There is deliberately **no fallback to "native modules only"**. The play would
then fail later at a task that needs `community.general`, with an error that
points at the wrong thing. The real error from the failing tool is in the
transcript.

### 14 -- `EX_UPSTREAM`

Upstream T-Pot's installer could not be fetched at the pinned ref, or its
sha256 did not match the expected value for that ref.

A mismatch is not automatically an attack -- upstream may have moved a tag --
but it is always a reason to stop. The intended workflow is to re-derive the
checksum with `tools/pin-upstream.sh <ref>`, read the diff, and commit the
updated per-ref data file. **Neither that tool nor any per-ref data file
exists yet, and no ref is pinned**, which is also why the supported tier of
`support-matrix.yml` is empty. Never pass `--upstream-checksum` to get past a
mismatch on a real host.

**One variable pins two things.** `tpot_upstream_ref` decides both the URL
`install.sh` is fetched from and the ref argument upstream is given, and they
may never be set apart. Upstream never re-fetches itself, so its distribution
gate, its port check and its sudo handling are whatever copy was executed,
while the ref argument governs only the playbook that copy then clones -- and
given no ref argument, outside a git work tree, upstream silently falls back
to its own default branch. `result.json` reports `upstream.payload_ref` and
`upstream.ref_consistent` so that a reader can see whether the entrypoint and
the payload came from the same ref. Upstream's own pinning does **not** replace
the sha256 check above: the checksum pins the entrypoint, upstream's ref
argument pins the payload.

Note also the honest limit recorded as `upstream.pins_payload`, which is
always `false`. Pinning a ref pins the recipe and never the images: T-Pot's own
pull policy defaults to `always`, so it re-pulls its container images every
time it starts. The software running on a verified box therefore changes after
we verified it, and changes again at every one of the daily reboots upstream's
playbook schedules. And when `tpot_upstream_ref` is a tag rather than an
immutable commit, the tag can still be moved at the source.

### 15 -- `EX_DRIVER`

Upstream's own installer ran and failed -- it exited non-zero, or it produced
nothing for longer than `tpot_driver_install_timeout` (90 minutes by default).

Read the transcript from the bottom: upstream's output is in it verbatim,
minus any redacted value. This is also the code returned when T-Pot's `.env`
is missing after a run that claimed to succeed, because an install that did
not produce it did not happen.

**This code fires less often than it should, and `16` is its partner.**
Upstream's installer sets no `errexit`, checks the result of
neither its image pull nor its compose copy, and ends on an `echo` -- so its
own exit status is `0` after failures that leave the box without its
containers. A zero exit from upstream is therefore not evidence that the
images are on the machine. Only this project's own verification catches that
class, which means the run ends at `16` and names the verification assertion
rather than the stage that actually failed. If `16` reports missing or
too-few containers, suspect the driver stage and read upstream's transcript,
not the verification code.

One more asymmetry worth knowing before you trust an upstream exit status:
upstream returns `0` both when it finished and when a human declined its
confirmation prompt. Under this project's unattended invocation that prompt is
never reached, but it is the reason exit status alone is not the evidence --
verification is.

### 16 -- `EX_VERIFY`

T-Pot is installed, and a check on the finished host failed. The failing
assertion is named in the message and recorded in `result.json` under
`verification[]` with its phase.

This code is the point of the whole design: it separates "the installer ran"
from "the honeypot works". A run that reaches it has changed the box, so treat
it as a machine to inspect rather than one to re-run blindly.

### 20 -- `EX_REBOOT`

**Not a failure.** T-Pot is installed, every pre-reboot assertion passed, and
the host must reboot before the rest can be checked.

```sh
install.sh --config /root/tpot.yml   #  -> 20
reboot
install.sh --verify-only             #  -> 0, or 16 naming the failing check
```

That is the specified sequence. In this build both invocations return `11`
instead, and neither of them reaches the play at all: `site.yml` and
`verify.yml` are two of the seventeen files preflight stage A requires, so the
run refuses there, at step 3 of ten.

`--verify-only` is the documented recovery, and it is the one to use.

**A caller that never runs it is meant to get a true outcome file anyway**, by
way of a post-boot systemd oneshot that re-runs verification on the next boot
and rewrites `result.json`. **That unit is designed and not built**; when it
lands it carries one requirement that is easy to miss:

> **The unit must disarm itself after its first successful verification.**
> Upstream T-Pot's playbook installs a root cron job that reboots the host
> every day at 02:42. A unit left armed therefore fires every night and
> rewrites `result.json` daily -- so a file that should record one dated,
> verified install instead re-asserts itself indefinitely against a box nobody
> has looked at since, and its timestamp stops meaning anything. Disarming on
> first success is part of the unit's contract, not an optimisation.

**A full re-run of `install.sh` on an installed host is not idempotent, and
this is the trap to know about.** Two independent things break it. Preflight
wants port 22 free or held by the host's own sshd, and after a successful
install sshd is on 64295 while 22 belongs to a honeypot, so a re-run fails at
`11` on a perfectly healthy box. And upstream refuses to reuse an existing
checkout whose branch does not match what was requested; a pinned tag is a
detached HEAD, which resolves to a commit hash and never equals the tag name,
so every second run against a pinned tag stops and tells you to remove the
checkout. Re-installing means removing upstream's checkout first, not passing
a flag. Verifying means `--verify-only`.

With `--reboot always` or `--reboot if-required` the host reboots after
`result.json` has been written and flushed to disk. In that mode the exit code
is meaningless by definition -- the process is killed by its own reboot -- and
`result.json` is the answer.

### 30 -- `EX_INTERRUPT`

The run received `SIGINT`, `SIGTERM` or `SIGHUP`. The trap still wrote
`result.json` and still shredded the run directory, so no credential survives
the interruption.

The box is in whatever state the interrupted step left it. Re-running is safe
in the sense that every step is idempotent, but read `result.json` first to
see how far it got.

### 40 -- `EX_INTERNAL`

A bug in this installer, not in your input or your box. Three things produce
it:

* an unhandled error -- the `ERR` trap fired somewhere no failure class was
  set, or `$RUNDIR/failure-class` was missing or unreadable after the play
  failed;
* **the log tripwire**: the finished transcript was searched for each supplied
  secret and one was found. The transcript is truncated, `result.json` records
  `"outcome": "credential_leaked_to_log"`, and the run ends here. That
  outcome is a defect in this project's redaction, and a bug report for it is
  worth more than any other;
* **the play is not in this build.** `site.yml` and `verify.yml` have not been
  written, and the step that would run them refuses and returns `40` rather than
  reporting a success it cannot have had. **That arm is unreachable today**, and
  this is the correction worth carrying: the same two files are part of the
  manifest preflight stage A checks, so a run stops at `11` six steps earlier
  and never gets there. If you do see `40` from this build it is one of the two
  causes above, and it is worth an issue -- it is not the missing play.

For the first two, please file an issue with the transcript attached. It is
redacted by construction and mode `0600`; read it before you attach it anyway.

## How a failure inside Ansible becomes one of these codes

**This describes the play, which is not in this tree.** The mapping is
specified; nothing has exercised it.

`ansible-playbook` has a coarse exit status of its own, so the play does the
mapping and the shell reads the answer rather than guessing it. Each role's
first task records which stage it is, the play's single `rescue:` writes
`<code> <stage>` to `$RUNDIR/failure-class`, and `install.sh` reads that file.
The reading half is written; the writing half is not.

| Stage | Code | Why that code |
|---|---|---|
| `preflight` | 11 `EX_PREFLIGHT` | the same conditions as stage A/B, re-asserted where `--check` can see them |
| `os_prep` | 13 `EX_DEPS` | everything it does is package and system preparation |
| `user` | 40 `EX_INTERNAL` | an account this project fully controls did not reach the state it announced; that is a defect here or a broken box, and either way the transcript is required |
| `upstream` | 14 `EX_UPSTREAM` | fetch or checksum |
| `driver` | 15 `EX_DRIVER` | upstream's installer itself |
| `env` | 15 `EX_DRIVER` | T-Pot's `.env` is missing or unwritable, which means the install did not finish |
| `verify` | 16 `EX_VERIFY` | installed, assertion failed |
| `finalize` | 16 `EX_VERIFY` | T-Pot is installed but the run never reached a verified state |
| `ioc` | 10 `EX_USAGE` | `ioc_forwarding_enabled` was set true and forwarding is not implemented in this release |

If the play fails and no failure class was written -- a syntax error, an
inventory that does not parse, `ansible-playbook` not found -- the code is
`40`. If the play succeeds, the file is ignored even when present.
