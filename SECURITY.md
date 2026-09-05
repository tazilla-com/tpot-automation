# Security policy

## Supported versions

This project is pre-1.0 and has not had a public release. Only the most recent
tag is supported; there are no backports to earlier tags.

| Version | Supported |
|---|---|
| 0.1.x | yes, as the current development line |
| anything earlier | no |

## The state of this build, before anything below is read

**This tree has installed T-Pot once, and this document does not overstate
what that established.** On 2026-09-05 it installed and started T-Pot on a
Debian 13 host: exit `20`, all fourteen pre-reboot verification checks passing,
and the honeypot answering on TCP/22 after the reboot. `tests/MATRIX-STATUS.md`
is the dated record and lists what that run did *not* establish.

**Two platforms, one edition.** Debian 13 and Ubuntu 26.04 have each been installed at the
pinned ref, and the Ubuntu run was carried through the reboot to **exit `0`** with all twenty-five
verification checks passing. What remains unexercised is every other edition, the `set` account
password policy, and every `--force-*` override. What has been executed besides that single install,
all of it unprivileged on a development box: the tree's own gate
suite, `install.sh` itself in every mode it offers, and the roles far enough to
establish that their expressions evaluate and their modules behave as written.
Measured on 2026-09-04, `./install.sh`, `--preflight-only` and `--verify-only`
each stop inside preflight with exit `11` on the `root` check, before anything
on a machine could change.

So this document has two kinds of statement in it, and the difference is no
longer "written" versus "unwritten" -- it is what has been *exercised*:

* **rules the code enforces and this project has run** -- the argument parser,
  the secret channel, the transcript redactor, `result.json`, and the gates
  that fail the build when one of them is broken. These can be checked by
  reading the tree, and running it produces them;
* **rules the code enforces and one install has exercised** -- the account,
  upstream's own files, the compose edit and the credential write were all
  performed on 2026-09-05 and verified on that host; the post-boot unit fired
  but its record has never been read back. These are written as
  descriptions of what the code does, because that is what they are, and every
  one of them is unverified against a running host.

A reader auditing this project should treat the second kind as code review
rather than as evidence. `CHANGELOG.md` lists what is built and what is not.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through this repository's GitHub security advisories --
the *Security* tab, then *Report a vulnerability*. If that is unavailable to
you, contact the maintainer address published in the repository metadata and
say only that you have a security report; details can follow on a channel we
agree.

Useful things to include, in rough order of value:

* what an attacker gains, and what access they need to start;
* the exact version (`install.sh --version`) and the pinned upstream ref;
* the distribution and version the run was on;
* a redacted transcript excerpt, or the `result.json` for the run
  (`result.json` never contains a credential -- see below);
* a minimal reproduction if you have one.

This is a small project. A human acknowledgement usually arrives within a few
days rather than within hours, and there is no fixed remediation deadline. We
will say what we intend to do and when, and we will credit you in the
changelog unless you ask us not to.

**A vulnerability in T-Pot itself is not ours.** This tool installs upstream
T-Pot; bugs in T-Pot, in its honeypot containers or in its dashboard belong to
<https://github.com/telekom-security/tpotce>. Report those there. Bugs in how
*this* installer configures, invokes or verifies it belong here.

## What this tool does with credentials

The product takes exactly one required secret -- the dashboard password --
and optionally an OS account password and an IoC endpoint credential. The
handling rules are structural, not advisory:

* **No secret is ever a command-line argument value.** Not in this project's
  code, and not in upstream's either: see the next section, which is the part
  of this document worth reading twice. The process argument list is
  world-readable in `/proc` on Linux for the whole lifetime of a process, and
  an install takes 30 to 90 minutes. There is no dashboard-password flag that
  takes a value; there is `--web-password-file`, which takes a path. `--set`
  is refused for secret keys. `tests/check-argv-hygiene.sh` fails the tree if
  such a flag is ever added. *Enforced today.*
* **Secrets travel on file descriptors, not in arguments.** A supplied value
  goes: answer file, environment or password file, into the merged
  configuration document written mode 0600 in a 0700 directory on `/run`
  (tmpfs, asserted to be tmpfs); and into `ansible-playbook` as `-e @<path>`
  -- a path on the command line, never a value. *Enforced today, and every run
  this project has made has produced it.* From there it reaches
  `htpasswd -n -i`, which reads the password from standard input, and then
  T-Pot's own `.env`. `roles/tpot_install` builds that hasher's argument
  vector in `vars/`, where no answer file can reach it, and asserts five
  things about the vector immediately before running it: that it is a list,
  that `-i` is in it, that `-b` is not, that it is exactly four elements long,
  and -- the one that survives somebody rewriting the other four -- that no
  element of it equals the password. The comparison runs under `no_log`; the
  assertion speaks only about a boolean. *That half is written and reviewed;
  no run has ever reached it.*
* **Nothing this run creates survives it.** The run directory is shredded and
  removed by an exit trap that fires on success, failure and interruption
  alike. No `.bak` file is written, because no file in the tree is ever edited
  with a value in it. *Enforced today.*
* **The transcript is filtered and then proved clean.** Every line written to
  the log passes through an in-process redactor first. After the run, the
  finished transcript is searched for each supplied secret; a hit truncates
  the log, records `"outcome": "credential_leaked_to_log"` and exits 40. The
  transcript is mode 0600 in a 0750 directory. *Enforced today.*
* **`result.json` cannot contain a credential.** It is built from a document
  from which every secret-typed key has already been removed, rather than by
  filtering a document that contains them. *Enforced today.*
* **Nothing prints the environment.** No bare `export`, `env`, `printenv` or
  `set` -- the forms that dump every variable -- appears anywhere in the tree;
  where a load must be shown to have worked, the check tests that the variable
  is non-empty and prints nothing else. This one is held by review and not yet
  by a gate of its own.
* **Ansible's `environment:` keyword is never used for a secret.** ansible-core
  resolves that keyword into a string prepended to the module command line, so
  those values would be argv-visible on the target for the lifetime of the
  task. The play uses it in exactly two places -- `roles/os_prep`, for apt's
  non-interactive frontend, and `roles/tpot_install`, for the `PATH`, `HOME`
  and locale upstream's installer is given -- and neither carries a
  credential.
* **The report the play hands back cannot carry the dashboard password.**
  This document invites you to attach `result.json` to a vulnerability report,
  and that document is built from the play's own report, so `roles/report`
  checks the assembled document against the supplied password under `no_log`
  and **refuses to write it** if it matches. Nothing is supposed to put a
  credential there -- no role writes one into any accumulator -- which is
  exactly why the check is worth its one task: it fires only when something
  has gone wrong in a way review did not catch. The failure message names the
  problem and not the value.
* **The file the post-boot verification reads carries no secret either.**
  `roles/finalize` writes `{{ tpot_state_dir }}/verify-config.json`,
  root-owned mode `0600`, so that the unattended verification on the next boot
  checks the box that was actually installed rather than a default one. It is
  built from the merged **public** document -- `lib/config.py` produces that
  by *removing* every secret-typed key rather than by blanking it -- and then
  filtered to drop the three keys `lib/varschema.json` marks
  `config_file: false` (`tpot_state_dir`, `tpot_log_dir`, `tpot_runtime_dir`),
  which an answer file may not carry. It is checked twice before it is
  written: once by name, against the schema's own list of secret-typed keys,
  and once by value, against every credential the run holds. Either check
  failing refuses the write, leaves post-boot verification unarmed, and says
  so -- because a file read by a systemd unit on every boot until it disarms
  is the wrong place to discover a leak later.

## How the dashboard password stays off upstream's command line

**This is implemented in `roles/tpot_install` and has been run against a real
host once**, on 2026-09-05: `result.json` from that run records the argv upstream
received, and it carries no credential flag. What follows is what the code does,
and why. The
invocation rule it depends on is also enforced by a build gate that fails the
tree on any line -- code or documentation -- claiming this project hands
upstream a credential.

Upstream T-Pot's own installer accepts a dashboard username and password only
as command-line arguments. **This tool does not take that path and passes
neither of them.**

Upstream's install *type* decides exactly two things: which compose file
becomes `docker-compose.yml`, and whether upstream asks for a web credential.
The sensor type asks for none, runs fully unattended, and runs the identical
playbook. So:

1. upstream is invoked as an unattended **sensor** install, receiving no
   username and no password;
2. this tool then copies the compose file for the edition you actually asked
   for over `~/tpotce/docker-compose.yml` -- the same operation upstream
   documents for its own users;
3. and this tool writes the dashboard credential into `~/tpotce/.env` itself,
   in upstream's own format: `base64` of one `user:hash` line produced by
   `htpasswd -n -i`, which reads the password from standard input. No hash
   algorithm is selected, because upstream selects none either and byte
   compatibility with what upstream would have written is the point.

The result the code is written for is that the password exists in a run as a
file descriptor, a 0600 file on tmpfs, and a hash -- never an argument to
anything, in this project's process tree or upstream's.

**One honest limit on the gate that guards this.**
`tests/check-argv-hygiene.sh` reads *logical lines*: it needs the command word
and the flag together to recognise a forbidden invocation. An Ansible `argv:`
list puts every token on a line of its own, so the gate cannot see it.
Measured on 2026-09-04 against a throwaway tree: a task hashing the password
with `-b`, the password appended as the last element of an `argv:` list, is
reported clean by that gate. That is why the run-time assertion above exists
and why it checks the vector rather than trusting the build to have caught it.
Fixing the gate to parse YAML task vectors is unwritten work, and it is
recorded here rather than left to be rediscovered.

### What upstream's own credential path costs, for anyone who takes it

Stated because someone will drive upstream by hand, and because it is the
reason this project does not:

* **The password is in the process argument list**, world-readable through
  `/proc/<pid>/cmdline` to any local user for the whole run.
* **It is also in the process environment.** Upstream exports the value, so it
  is readable in `/proc/<pid>/environ` for the run and is inherited by every
  child process upstream starts.
* **And it lands in a child's argument list too**, because upstream hashes it
  by invoking `htpasswd` with the password as an argument. Avoiding the parent
  exposure alone would not avoid this one.
* **There is no environment path in.** Upstream clears its username and
  password variables *before* it parses its arguments, so exporting them
  beforehand does not work; a value pre-set in the environment is discarded.
  Two other upstream settings -- its repository URL and its branch -- *are*
  read from the environment, which is what makes the asymmetry easy to
  misread.
* **The credentialed path is not only an unattended one.** Upstream demands
  those two arguments for its credentialed install types whether or not it was
  told to run unattended, so "I will just run it interactively" does not avoid
  them.
* **Supplying the password as an argument also skips two checks** that exist
  only on upstream's interactive branch: a `cracklib` password-strength test,
  and a sanitiser that strips the username to alphanumerics, underscore, dot
  and hyphen. Passing the value never runs either.

Because this project takes the sensor path, both of those checks become its
own responsibility, and the two have landed differently:

* **the username constraint is enforced today.** The variable schema accepts
  only letters, digits, dot, underscore and hyphen for the dashboard username.
  The constraint is real, not cosmetic: a colon in the username breaks the
  `user:hash` record that gets encoded into `.env`;
* **password strength is not checked at all, by us or by upstream.** Upstream's
  `cracklib` test lives only on the branch this project never takes, and no
  equivalent has been written here -- so a one-character dashboard password is
  accepted today. The password is required and must be non-empty; that is the
  whole of it. If you are deploying this, choose the password as though nothing
  is checking it, because nothing is.

### Two more things this project owns as a result

* **Upstream's own write into `.env` fails silently, so ours must not.**
  Upstream patches the `WEB_USER=` line with `sed -i`. On a file that has no
  such line that command exits 0, changes nothing and reports nothing --
  verified by execution against a copy of it. The outcome would be a T-Pot
  whose dashboard has no login and an installer that reported success. So the
  write in `roles/tpot_install` counts the `WEB_USER=` lines in the file
  first, refuses to proceed when there is not exactly one, and then replaces
  that line rather than appending a second -- two `WEB_USER` lines in that
  file is its own failure mode. It checks the file rather than trusting the
  edit.
* **`LS_WEB_USER` is never written.** That key is upstream-managed state for
  sensor-to-hive authentication, and putting a dashboard credential into it
  would break a distributed deployment.

### If you deviate from this invocation, the exposure comes back

Driving upstream by hand with its password argument, or adding one through
`tpot_upstream_extra_flags`, puts the password on a command line for the whole
install and there is nothing this project can do about it from the outside.
`result.json` records the flags upstream was actually given, with any password
value replaced by `***` **and a warning saying a credential reached a command
line** -- because on this project's own path that can never happen, so seeing
it means something drove upstream a different way. *That masking and warning
are enforced today, in `lib/result.sh`.*

## Known limitation: passwordless sudo for the install account

Upstream's unattended mode **requires** passwordless `sudo` for the account
that runs it. It tests this with `sudo -n -k true`, which deliberately ignores
any cached authentication, so only a NOPASSWD rule satisfies it; it makes that
test three times, and under unattended mode it aborts the install before
changing anything when the test fails. `roles/tpot_user` grants exactly that,
deliberately, in a dedicated file under `/etc/sudoers.d/`, and this document
states it rather than leaving it to be discovered.

The grant is unconditional and is **not** derived from whether the account has
a password. Giving the account a login password
(`tpot_os_user_password_policy: set`) does not make `sudo` prompt; it only adds
an interactive login, and it widens the box's credential surface by one
password. The default is `locked`: the account is created with no usable
password at all, the role then reads the shadow record back and asserts the
field is the shape the policy promised, so the grant is its only route to
privilege and interactive login to it is impossible. Nothing in this project
needs the account's password -- the mechanism that once did was the
screen-scraping driver, and that is deleted.

One related trap, on Debian systems with no `sudo` installed at all: upstream
installs it for you using `su`, which asks for the root password on a
terminal and has no unattended bypass. So `sudo` is in `roles/os_prep`'s base
package list, installed in the same apt transaction as everything else this
run needs, and `roles/tpot_user` writes the NOPASSWD rule after it -- both
before upstream is invoked, because otherwise an unattended install stops
there and waits for a human who is not present.

## What the installed box becomes

**A finished T-Pot host is deliberately attackable.** These properties are
what a completed install produces; no install has been completed by this code,
so read them as what upstream's own playbook does and what this tool's own
code reports about it -- neither observed on a running host.

Most of them are named in the closing notice `install.sh` prints before it
exits -- the port move, the honeypot on 22, the absence of firewall rules,
what upstream changed, and whether the community submission is on. The two
that are not are the image pull policy, which `result.json` carries as
`upstream.pins_payload`, and the outbound access, which is written down here
and nowhere else.

* **Administrative SSH moves to port 64295, and TCP/22 becomes a honeypot.**
  Which honeypot depends on the edition -- Cowrie on the standard/hive
  edition, Endlessh on the tarpit edition, Beelzebub on the LLM edition, and
  for the remaining editions upstream does not say. Whatever answers there, it
  is not a shell on your machine, and everything typed into it is recorded as
  attacker activity. The closing notice names the honeypot only where upstream
  documents which one it is.
* **This installer adds no firewall rules of its own.** The honeypot ports
  must be reachable for the product to work at all; which of the remaining
  ports should be closed is a site decision. `docs/firewall.md` carries that
  position in full, with a worked example ruleset -- which nobody here has
  loaded on a host running T-Pot.
  The closing notice and the preflight report both name which administrative
  ports will be world-reachable -- the part that matters before you walk away
  -- and neither has ever been printed. The exposure line is a preflight stage
  B check, every run this project has made was unprivileged, so stage A fails
  on the `root` check and stage B is never reached; the notice belongs to the
  end of an install that has never completed.
* **That is not the same as the host's filtering being untouched.** Upstream's
  playbook sets the firewalld public zone target to `ACCEPT` and puts SELinux
  into monitor (permissive) mode on Red Hat family distributions. On those, a
  firewall that was filtering before the install is not filtering after it.
* **The install account is added to the `docker` group.** On a box with a
  Docker daemon that is equivalent to root, so the account's passwordless
  sudo grant is not the only privileged path it has.
* **Upstream disables the systemd DNS stub listener, installs Docker from
  Docker's own repository, and removes packages it considers conflicting.**
* **Upstream installs a root cron job that reboots the host every night, at a
  time it randomises per install** (hour from `range(0, 5)`, minute from
  `range(0, 60)`), stopping T-Pot and pruning containers, images and volumes
  first. It goes into ROOT's crontab, not `/etc/cron.d`.
* **T-Pot re-pulls its container images every time it starts**, because its
  own pull policy defaults to `always`. Pinning an upstream ref pins the
  recipe and never the images, so the software running on a verified box
  changes after it was verified -- and it changes again on every one of those
  daily reboots. `result.json` reports this as `upstream.pins_payload: false`.
* **Outbound network access is required and is not restricted by this tool.**
  Upstream describes an install as needing a working, non-proxied internet
  connection, and the running host talks outward on 80 and 443 to its
  distribution's mirrors, GitHub, Docker Hub and -- unless turned off, see
  below -- upstream's community dashboard.
* **Upstream submits captured attack data to a public community dashboard by
  default.** This installer's default is off, `tpot_upstream_telemetry: "off"`.
  It is a compose-file edit and not a setting: there is no upstream `.env` key
  and no upstream flag for it, so turning it off means removing the submitting
  service block from upstream's `docker-compose.yml`. `roles/tpot_install`
  does that structurally -- it parses the compose document, drops the service
  and the network that exists only for it, writes the result back, and then
  **asserts both are absent from the file it wrote** rather than that the edit
  was attempted. A run left with telemetry on records a warning saying so.
  Set the value to `"on"` to leave upstream's own default in place. Note that
  the edit lives inside upstream's git checkout, and upstream's own update
  script overwrites local changes there, so it does not survive an upstream
  update.

None of these is a vulnerability in this tool.
