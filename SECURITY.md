# Security policy

## Supported versions

This project is pre-1.0 and has not had a public release. Only the most recent
tag is supported; there are no backports to earlier tags.

| Version | Supported |
|---|---|
| 0.1.x | yes, as the current development line |
| anything earlier | no |

## The state of this build, before anything below is read

**This tree does not yet contain a working installer, and this document does
not pretend otherwise.** The entrypoint (`install.sh`), the libraries it
sources and the build gates are written. The Ansible play is not: `site.yml`,
`verify.yml` and the whole of `roles/` are a separate slice and are absent.
Everything that would change a real host lives there.

**Nothing has ever been installed by this code.** No virtual machine, no root,
no network, no T-Pot. Two things have been executed, both unprivileged on a
development box: the tree's own gate suite, and `install.sh` itself, run to its
refusal in every mode it offers and never past it. Every one of those runs
stopped inside preflight with exit `11`, before anything on a machine could
change.

So this document has two kinds of statement in it, and they are marked:

* **rules the code in this tree enforces today** -- the argument parser, the
  secret channel, the transcript redactor, `result.json`, and the gates that
  fail the build when one of them is broken. These are written in the present
  tense and can be checked by reading the tree;
* **rules for the part that has not landed** -- everything that touches
  upstream T-Pot's own files on a real host. These say *is specified to*, or
  *will*, and are a design commitment rather than a report.

A reader auditing this project should treat the second kind as unverified.
`CHANGELOG.md` lists exactly what is and is not built.

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
  -- a path on the command line, never a value. *Enforced today.* From there
  it is specified to reach `htpasswd -n -i`, which reads the password from
  standard input, and then T-Pot's own `.env`; that step lives in the role
  that has not landed. `htpasswd -b`, which takes the password as an
  argument, is forbidden and the gate checks for it.
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
  task. A rule for the play that has not landed.

## How the dashboard password stays off upstream's command line

**This is a design commitment about the part of the product that is not
built.** No run has ever been made. What follows is what the play is specified
to do, and why; the invocation rule it depends on is already enforced by a
gate that fails the build on any line -- code or documentation -- claiming
this project hands upstream a credential.

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

The intended result is that the password exists in a run as a file
descriptor, a 0600 file on tmpfs, and a hash -- never an argument to anything,
in this project's process tree or upstream's.

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
  whose dashboard has no login and an installer that reported success. The
  specified write therefore checks that the line is present and fails the run
  if it is not, rather than trusting the edit.
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
changing anything when the test fails. This tool is specified to grant exactly
that, deliberately, in a dedicated sudoers file, and states it here rather
than leaving it to be discovered.

The grant is unconditional and is **not** derived from whether the account has
a password. Giving the account a login password
(`tpot_os_user_password_policy: set`) does not make `sudo` prompt; it only adds
an interactive login, and it widens the box's credential surface by one
password. The default is `locked`: the account is specified to be created with
no usable password at all, so the grant is its only route to privilege and
interactive login to it is impossible. Nothing in this project needs the
account's password -- the mechanism that once did was the screen-scraping
driver, and that is deleted.

One related trap, on Debian systems with no `sudo` installed at all: upstream
installs it for you using `su`, which asks for the root password on a
terminal and has no unattended bypass. The role that prepares the account is
specified to ensure `sudo` and the NOPASSWD rule exist *before* upstream runs,
because otherwise an unattended install stops there and waits for a human who
is not present.

## What the installed box becomes

**A finished T-Pot host is deliberately attackable.** These properties are
what a completed install produces; no install has been completed by this code
yet, so read them as what upstream's own playbook does and what this tool is
specified to report.

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
  loaded on a host running T-Pot, because this project has never installed one.
  The closing notice and the preflight report are written to name which
  administrative ports will be world-reachable -- the part that matters before
  you walk away -- but neither has ever been printed: the exposure line is a
  preflight stage B check and every run of this build stops in stage A, and the
  notice belongs to the end of an install that has never completed.
* **That is not the same as the host's filtering being untouched.** Upstream's
  playbook sets the firewalld public zone target to `ACCEPT` and puts SELinux
  into monitor (permissive) mode on Red Hat family distributions. On those, a
  firewall that was filtering before the install is not filtering after it.
* **The install account is added to the `docker` group.** On a box with a
  Docker daemon that is equivalent to root, so the account's passwordless
  sudo grant is not the only privileged path it has.
* **Upstream disables the systemd DNS stub listener, installs Docker from
  Docker's own repository, and removes packages it considers conflicting.**
* **Upstream installs a root cron job that reboots the host every day at
  02:42**, stopping T-Pot and pruning containers, images and volumes first.
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
  service block from upstream's `docker-compose.yml`, and the specified
  implementation then asserts the block is actually gone rather than that the
  edit was attempted. **That removal is part of the role that has not landed.**
  Set the value to `"on"` to leave upstream's own default in place. Note that
  the edit lives inside upstream's git checkout, and upstream's own update
  script overwrites local changes there, so it does not survive an upstream
  update.

None of these is a vulnerability in this tool.
