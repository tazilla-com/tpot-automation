# Exit codes

`install.sh` communicates through its exit status. That is the product: a
caller -- cloud-init, Packer, a CI job, a colleague's shell script -- must be
able to branch on the outcome without parsing English.

Four properties are designed to hold:

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
* **A code is never given for a fact the run could not establish.** The three
  above are about what a number means; this one is about what the installer
  does when it cannot tell. A run that finishes the play and then finds
  nothing on the box saying whether a reboot is required does not resolve the
  gap in its own favour: it falls back to the next artefact, says in
  `result.json` which artefact answered, and returns `40` when there is no
  artefact at all. `0` is a claim, and a claim needs evidence. See `40`.

## What this build can and cannot return

**The Ansible play is in this tree.** `site.yml`, `verify.yml` and the eight
roles under `roles/` are on disk; they pass `ansible-playbook --syntax-check`
and `ansible-lint`'s production profile, and `tests/check-stage-map.sh` is a
build gate holding their stage-to-code map against the table at the foot of
this page.

**T-Pot has been installed with them, on two platforms**, both on 2026-09-05.
`tests/MATRIX-STATUS.md` is the dated record and is the authority for anything
in this section; it is as specific about what each run did *not* establish as
about what it did.

* **Debian 13** -- exit `20`, then rebooted with T-Pot answering on TCP/22.
  Three runs on that platform: `20` twice, the second with no `--force-*`
  override of any kind, and one correct refusal at `11` on a host deliberately
  put into Ubuntu's socket-activated shape.
* **Ubuntu 26.04** -- exit `20`, rebooted, then **exit `0`** from
  `--verify-only`, with 25 of 25 checks passing. That is this product's first
  `0`, and it is what makes the sentence at the top of this page a report
  rather than a design intention. The same run also produced a `16` on its
  own: the post-boot unit fired while T-Pot was still starting, found 36 of
  the expected 39 containers, and declined to call it verified.

So `0`, `11`, `16` and `20` have all been produced by real runs on real
hosts, and `10` and `12` by runs on a development box -- `12` is what
`--preflight-only` returns on a clean box that cannot reach upstream's
distribution gate without acting. **`13`, `14`, `15`, `30` and `40` have still
never been produced by a real run.** Each of those is the contract the code is
written to and not a report of observed behaviour; `13`, `14` and `15` name
stages a healthy install walks straight past, `30` needs a signal at the right
moment, and `40` is a defect nobody has yet triggered.

**What a run does on this project's own development box** -- an unprivileged
account, no root -- is unchanged and worth knowing, because it is where most
of this tree's commands are exercised: `./install.sh`,
`install.sh --preflight-only` and `install.sh --verify-only` each return
**`11`** at step 3 of the ten steps a run performs, and the failing check is
**`root`** -- uid 1000, where this installer requires uid 0. Preflight runs
before the first mutation, so nothing on that box is changed by any of them.
That is a fact about where the measurement was taken and not a property of the
build: on a root shell the check passes and the run continues into stage B,
which the two platforms above went through.

Everything below is written in the present tense because it is the contract
the codes name. For `0`, `11`, `16`, `20` and the refusals that produce them,
that contract has been executed on a real host. For `13`, `14`, `15`, `30` and
`40`, it has not.

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

**One arm of `10` is the exception to "nothing on the box was changed", and it
is the last role in the play.** `roles/ioc_forward` refuses
`ioc_forwarding_enabled: true`, and it runs after the install. A full run
never reaches it: `roles/preflight` refuses the same input as its first check,
before anything is touched, and that refusal is `11`. The `ioc` arm of `10` is
reached only when the preflight stage was skipped by tag selection --
`--tags ioc_forward` runs the include and filters out every task inside it --
so a `10` naming the `ioc` stage means the box *has* been installed and the
paragraph above does not apply to it. The two codes are not two answers to one
question: they are two statements about how far the run got, which is what
every code on this page is.

### 11 -- `EX_PREFLIGHT`

The box is not in a state this installer will act on, and **nothing was
changed**. Preflight runs before the first mutation for exactly this reason.

**`11` is the most-observed code in this project's history, and for two
different reasons.** On the unprivileged development box every acting
invocation returns it with `root` named as the failing check -- `--help`,
`--version` and `--example-config` print and exit `0` without reaching
preflight, and everything else stops here. On the two platforms in
`tests/MATRIX-STATUS.md` it appeared as the answer it was designed for: a
Debian 13 cloud image whose only apt source could not be reached, and an
Ubuntu 26.04 host whose TCP/22 was held by `ssh.socket`. Both refusals named
the failing check and changed nothing; the second one names the remedy, and
applying it made the install proceed.

Note that the one-line meaning for `11` in the table above does not enumerate
every condition. The preflight report is what tells you *which* check failed,
and it is worth reading rather than inferring from the number.

**`11` is also what a run asking for IoC forwarding gets.**
`roles/preflight`'s first check refuses `ioc_forwarding_enabled: true`,
because this release contains no forwarding code at all -- no client, no
pipeline, no endpoint template -- and it refuses it before anything is
touched, which is what keeps `11`'s published meaning true for that run. See
`10` above for the residual arm that answers the same input differently.

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
tier is a claim that a particular pair was *tested*: it says what this
installer can drive, which is a claim about code. **What has actually been
installed is in `tests/MATRIX-STATUS.md`, and a platform may be called tested
only if it has a row there.** Two do -- `debian:13` and `ubuntu:26.04`, both
at the pinned ref, both dated 2026-09-05. Every other pair in either tier is
untested, which is not the same as broken and not the same as working.

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
but it is always a reason to stop. The workflow is to re-derive the checksum
with `tools/pin-upstream.sh <ref>`, read the diff, and commit the updated
per-ref data file; that tool writes
`roles/tpot_install/vars/upstream-<ref>.yml` and the supported tier of
`support-matrix.yml` from the same reading. Never pass `--upstream-checksum`
to get past a mismatch on a real host.

**The shipped pin is a commit rather than a tag, and that is not a
preference.** No upstream tag carries the flag surface this product's
invocation is built on; the newest one has no positional-parameter handling at
all, so driven non-interactively it does not fail -- it **hangs**. The pin
must also be a *full* 40-character sha, and `lib/varschema.json` refuses an
abbreviated one with a message saying why: `ansible.builtin.git` accepts a
short sha and checks out the full one, so upstream's own re-run check would
compare seven characters against forty and exit 1 on every second run.

**The tier that pin produces is derived, not tested.** It is what the pinned
ref's own distribution gate accepts, intersected with what this installer can
drive. Two of its rows have since been installed and are recorded with dates
and evidence in `tests/MATRIX-STATUS.md`; the rest of the tier is still a
derivation, and `support-matrix.yml` -- the one place either tier is written
down -- says what can be driven rather than what has been.

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
playbook schedules. When `tpot_upstream_ref` is a tag rather than an immutable
commit, the tag can also be moved at the source -- but pinning a commit does
not close this either: upstream's `.env` sets `TPOT_VERSION` to a *mutable
registry tag*, every image is `${TPOT_REPO}/<name>:${TPOT_VERSION}`, and
`TPOT_PULL_POLICY` is `always`. Two installs from the same commit a month
apart can run different containers. `upstream.pins_payload: false` has always
meant this; it now has a version string behind it.

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

**There are two ways to arrive here, and they are different findings.** The
first is a check that ran and failed -- the case above. The second is a check
the caller asked for that **could not be run at all**: a gate at the foot of
`roles/tpot_verify` fails a `--verify-only` run in which any post-reboot check
the caller asked for came back `skipped`. Without that gate the run answered
`0` -- "installed and verified" -- for a box whose containers were never
counted, because a `docker ps` that exited non-zero left three checks with no
verdict and nothing then acted on them. A check that could not look is not a
pass, and this installer does not return `0` for a host it has not examined.
The reasons are in `result.json` under `verification[]`; read those before
the assertion text.

Two kinds of `skipped` are legitimate and do not fail a run. Every post-reboot
check in a `site.yml` run is skipped by design, because the box has not
rebooted yet -- that run's answer is `20`. And a check this edition has
nothing to answer for is a final answer rather than a hole: a sensor ships no
dashboard, and the mobile edition ships no Elasticsearch.

### 20 -- `EX_REBOOT`

**Not a failure.** T-Pot is installed, every pre-reboot assertion passed, and
the host must reboot before the rest can be checked.

```sh
install.sh --config /root/tpot.yml   #  -> 20
reboot
install.sh --verify-only             #  -> 0, or 16 naming the failing check
```

**That whole sequence has been performed end to end**, on Ubuntu 26.04 on
2026-09-05: `20`, reboot, then `0` with 25 of 25 checks passing. It is this
product's first `0` and the row that carries it is in
`tests/MATRIX-STATUS.md`. The Debian 13 row the day before got as far as `20`
and no further -- not because verification failed, but because after an
install the network the run was driven from could no longer reach the
administrative port; widening that pinhole is what made the Ubuntu row
possible. On this project's own development box both invocations stop at `11`
on the `root` check, at step 3 of ten.

Two things that run showed about the middle line, both worth knowing before
you rely on the sequence. Run before the reboot, `--verify-only` correctly
refuses with `16` -- `listen_admin_ssh` passes and the two container listeners
do not. Run too *soon* after the reboot it can also answer `16`, because
T-Pot's containers are still starting: the post-boot unit hit exactly that,
found 36 of 39, and declined to call it verified. Neither is a failure of the
install; both are the design refusing to call an unfinished box good.

`--verify-only` is the documented recovery, and it is the one to use.

**`20` can also arrive as a fallback, and `result.json` says when it did.**
The reboot decision normally comes from the play's own report. When that
report is missing or unparseable, step 10 takes the answer from the
`verify-pending` marker instead and returns `20` rather than `0` -- and
records in the document's `warnings` that the marker, not the report,
answered. A `20` with that warning means "the install looks finished and this
installer could not read its own report"; read `40` for why the alternative
was not a `0`.

**A caller that never runs it gets a true outcome file anyway**, by way of a
post-boot systemd oneshot that re-runs verification on the next boot and
rewrites `result.json`. `roles/finalize` writes and enables that unit. Two of
its properties decide whether you can trust what it leaves behind:

> **It disarms itself after its first successful verification.** Upstream
> T-Pot's playbook installs a root cron job that reboots the host every day,
> so a unit left armed would fire on every one of those boots and rewrite
> `result.json` nightly -- a file that should record one dated, verified
> install instead re-asserting itself indefinitely against a box nobody has
> looked at since, its timestamp meaning nothing. The unit is gated on a
> marker file under `tpot_state_dir` and deletes that marker from
> `ExecStartPost`, which systemd runs only after a successful `ExecStart`: a
> failed verification keeps the marker and is retried, a successful one is the
> last.

> **It verifies the box that was actually installed, because it is handed the
> configuration that installed it.** `roles/finalize` writes
> `{{ tpot_state_dir }}/verify-config.json` -- root-owned, mode `0600` -- and
> the unit's `ExecStart` passes `--config` to it. A post-boot run given
> nothing re-derives every input from the schema defaults, so an install that
> changed the OS account, the install type, a port or the telemetry setting
> would be verified against a box that does not exist -- and the failure mode
> is quiet rather than loud: the unit fails, retries until it has burned
> `StartLimitBurst`, never removes the marker, and `result.json` goes on
> saying `post_boot_verify_armed: true` for the life of the machine. That was
> the arrangement before this file existed. When it cannot be written --
> because the state directory resolves inside the installer tree, where this
> installer refuses an answer file -- the unit is armed without it, and
> `result.json` says so in its warnings.

The unit's own command is the manual recovery path, and running it by hand
reproduces exactly what the unit runs:

```sh
install.sh --verify-only --json --config /var/lib/tpot-automation/verify-config.json
```

That file carries no credential. It is built from the merged **public**
document, from which `lib/config.py` removes every secret-typed key, and
`--verify-only` does not ask for a dashboard password -- so nothing has to be
supplied alongside it.

**A full re-run of `install.sh` on an installed host does not install
anything, and this is the behaviour to know about.** Preflight detects the
existing installation, records `existing_tpot` as a warning, and switches its
port expectations to the post-install layout -- so administrative ssh on 64295
and a honeypot on 22 are what it expects to find rather than conflicts, and the
run does not stop at `11` over them. It then proceeds without installing:
upstream's installer is skipped, and only configuration and verification are
applied. `--force-reinstall` is what removes the existing checkout (`rm -rf
~/tpotce`) and runs upstream's installer over it.

If all you want is to check a host, use `--verify-only`; that is what it is
for, and it is the only invocation that asks for no dashboard password.

*(This paragraph said the opposite until 2026-09-05 -- that a re-run "fails at
`11` on a perfectly healthy box" over the port check. That was true of an
earlier preflight; `_PF_PORT_LAYOUT` has switched to `post_install` on a
detected installation since, and `_tpot_pf_check_existing_tpot` says so in its
own message. Corrected against the code, not against a memory of it.)*

The second half of this trap changed shape when the ref was pinned to a full
commit sha, and it is worth stating in the new form. Upstream refuses to reuse
a checkout whose HEAD is not the one it asked for, which is what made every
second run against a pinned *tag* stop -- a tag resolves to a commit hash and
never equals the tag name. A full-sha pin **matches**, and the match is not
good news: upstream clones with update disabled and compares HEAD and the
origin URL and nothing else, so a checkout whose `docker-compose.yml` has been
edited and whose `env.example` has been deleted passes that comparison
unchanged. The play therefore warns, every time, that an existing checkout is
being reused unrefreshed. `tpot_force_reinstall` is the switch that gets you a
fresh one, and it really is `rm -rf` on `~/tpotce` -- including any captured
attack data underneath it.

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

A bug in this installer, not in your input or your box. Four things produce
it, and only the first three can occur in this tree:

* an unhandled error -- the `ERR` trap fired somewhere no failure class was
  set, or `$RUNDIR/failure-class` was missing or unreadable after the play
  failed;
* **the log tripwire**: the finished transcript was searched for each supplied
  secret and one was found. The transcript is truncated, `result.json` records
  `"outcome": "credential_leaked_to_log"`, and the run ends here. That
  outcome is a defect in this project's redaction, and a bug report for it is
  worth more than any other;
* **a play that succeeded and left nothing saying what it did.** This is the
  arm to read carefully, because the alternative to it used to be a `0`.

  Step 10 decides between `0` and `20` from one fact -- does this box need a
  reboot before it can be verified -- and on a successful install the answer
  is *yes*. It reads that fact from `$RUNDIR/ansible-report.json`, which
  `roles/report` writes inside the play's `always:` with `failed_when: false`,
  deliberately: a report that cannot be written must not replace the real
  diagnosis of whatever went wrong with a complaint about itself. The cost is
  that the file can be missing, or truncated, or valid JSON with the key
  absent, and **nothing anywhere says so**.

  So the run answers from the next artefact down, and says which one it used:

  1. **the report**, when it is readable and carries `reboot_required`. The
     ordinary path, and the only one that can produce `0`;
  2. **the `verify-pending` marker** under `tpot_state_dir`, when the report
     is not readable. `roles/finalize` touches that file as its last act and
     the post-boot unit deletes it after a *successful* verification, so its
     presence means "installed, not yet verified" and the run returns `20`.
     It warns on the transcript and records in `result.json`'s `warnings`
     that the decision came from the marker rather than the report -- the
     artefact says which source answered, so a `20` read a month later is not
     ambiguous;
  3. **neither** -- `40`. Nothing on the box says how far the run got, so
     there is no answer to give, and `0` is not available: it is a claim, and
     no artefact supports it. `result.json` carries the reason in `errors`,
     and its `reboot.required` reads `false` only because the document has no
     third value. The banner does not claim the box was installed and
     verified; it prints the part-finished text instead, which tells you to
     check administrative SSH, TCP/22 and docker before you log out.

  A run that reaches `40` this way has probably changed the box -- the play
  succeeded -- so treat it as a machine to inspect. `--verify-only` is the
  cheapest next step, and it will say what is actually there.

* **a play that is not on disk.** Step 9 looks for `site.yml` or `verify.yml`
  before running it, and when the file is absent it logs what is missing, sets
  the outcome to `internal_error` and returns `40` rather than reporting a
  success it cannot have had. Both files are present in this tree, so that arm
  cannot fire here and never has. It stays as the *last* guard rather than the
  first: preflight's seventeen-file manifest is the other statement of the same
  rule, and the thing that must never happen -- a build with no play reporting
  success -- is refused by both. A `40` from this build is therefore one of the
  three causes above, and worth an issue.

**The rule the third arm exists to keep: a run that cannot establish whether a
reboot is required never reports `0`.** `0` is the only code that asserts the
honeypot works, and an assertion with no evidence behind it is worse than a
refusal, because a caller stops looking. `tests/bats/install-report.bats`
holds all three answers -- report, marker, neither -- against fabricated run
directories, so the fallback stays a property rather than a memory.

For the first three, please file an issue with the transcript attached. It is
redacted by construction and mode `0600`; read it before you attach it anyway.

## How a failure inside Ansible becomes one of these codes

**The play writes the code and the shell reads it, and the mechanism has now
been exercised by real failures on real hosts** -- two of them on 2026-09-05,
both landing on `16`. A `--verify-only` run against a host that had not yet
rebooted failed in stage `verify`, and a `--check` run against a box with no
T-Pot on it failed in stage `finalize`. Each wrote its stage into
`$RUNDIR/failure-class`, and `install.sh` read it back and returned the code
the table below gives for that stage. What is still unexercised is most of the
*table*: `os_prep`, `user`, `upstream` and `driver` have never failed on a
host, so the rows mapping them to `13`, `40`, `14` and `15` remain the
contract rather than a report.

`ansible-playbook` has a coarse exit status of its own, so the play does the
mapping and the shell reads the answer rather than guessing it. Each role's
first task records which stage it is in, the play's single `rescue:` runs
`roles/report`, which writes `<code> <stage>` to `$RUNDIR/failure-class`, and
`install.sh` reads that file.

The map the machine acts on is `roles/report/vars/main.yml`; the table below
is the copy a reader acts on; `tests/check-stage-map.sh` is a build gate that
holds the two together in both directions and fails when a role claims a stage
no row covers. A stage the map does not know becomes `40` deliberately -- "the
play failed somewhere this installer has no name for" is a defect here, and
`40` is what says so.

| Stage | Code | Why that code |
|---|---|---|
| `init` | 40 `EX_INTERNAL` | the play failed before any role had claimed a stage. The true answer rather than a gap: it broke before it got far enough to have a better one |
| `preflight` | 11 `EX_PREFLIGHT` | the same conditions as stage A/B, re-asserted where `--check` can see them -- plus the IoC refusal, which is this role's first check and runs before anything is touched |
| `os_prep` | 13 `EX_DEPS` | everything it does is package and system preparation |
| `user` | 40 `EX_INTERNAL` | an account this project fully controls did not reach the state it announced; that is a defect here or a broken box, and either way the transcript is required |
| `upstream` | 14 `EX_UPSTREAM` | fetch or checksum |
| `driver` | 15 `EX_DRIVER` | upstream's installer itself |
| `env` | 15 `EX_DRIVER` | T-Pot's `.env` is missing or unwritable, which means the install did not finish |
| `verify` | 16 `EX_VERIFY` | installed, assertion failed |
| `finalize` | 16 `EX_VERIFY` | T-Pot is installed but the run never reached a verified state |
| `ioc` | 10 `EX_USAGE` | `ioc_forwarding_enabled` was set true and forwarding is not implemented in this release. THE SECOND GATE ONLY: a full run is refused at `preflight` with 11 before the first mutation, and this arm is reached only when that stage was skipped by tag selection |

If the play fails and no failure class was written -- a syntax error, an
inventory that does not parse, `ansible-playbook` not found -- the code is
`40`. If the play succeeds, the file is ignored even when present.
