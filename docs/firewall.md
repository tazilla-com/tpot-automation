# Firewall and exposure

Two messages the installer prints point here: the exposure line in its
preflight report, and the closing notice after an install. This is what they
point at.

**Both have been printed on real hosts**, on the two platforms dated in
`tests/MATRIX-STATUS.md`: the exposure line is a preflight stage B check, which
those runs reached, and the closing notice is what an install ends with. On this
project's own development box neither appears — it is unprivileged, so stage A
refuses at the `root` check and nothing after it runs.

**Read the short version first, because it is the whole of this project's
position:** this installer adds no firewall rules, upstream T-Pot's own
playbook does change your host's filtering on some distributions, and nobody
has written down which ports a T-Pot must leave open — so we do not ship a
default that would guess. The rest of this page is that sentence with its
evidence, plus a worked example you apply yourself.

## What here was read, what was observed, and what was not

Every claim below about **upstream** is read from upstream's own source and
documentation and recorded in `notes/upstream-facts.md` — a project record kept
outside this repository, which does not ship with it and which a clone of this
repository therefore does not contain. Where this page cites that record it is
naming where the reading was done, not a file you can open here; upstream's own
source at the ref you pin is where any of it can be re-checked. Every claim about
**this installer** is read from this tree, and some of it was measured by
running the tree's own gates and `install.sh --preflight-only` on a developer
box.

The port layout on this page was observed on an installed honeypot once, on
2026-09-05 (`tests/MATRIX-STATUS.md`): administrative SSH answered on tcp/64295,
the dashboard on tcp/64297, Elasticsearch on tcp/64298 bound to 127.0.0.1, and
tcp/22 answered as a honeypot rather than as the host's `sshd`. **The example
ruleset at the end was not observed**: no filtering of any kind has been applied
by this project to a host running T-Pot. Treat it as a starting point you verify,
not as a tested recipe.

## What this installer configures: nothing

`tpot_firewall_mode` is the only setting in this area and `none` is the only
value it accepts. That is not a placeholder for "the default is off" — the
enum has exactly one member. From `lib/varschema.json`, abbreviated to the
fields that matter here:

```json
{ "name": "tpot_firewall_mode", "type": "enum", "choices": ["none"], "default": "none" }
```

Any other value is rejected. Measured on this tree:

```
$ python3 lib/config.py merge --schema lib/varschema.json ... --set tpot_firewall_mode=ufw
config: tpot_firewall_mode: wanted one of none (from --set)
$ echo $?
10
```

(`...` stands for the merge's other required arguments — `--repo-dir`,
`--out`, `--public-out`, `--sources-out`. They make no difference to the
result above.)

Two honest details about that refusal:

* **The message does not name this file.** It is the generic enum error from
  the configuration merge, so it tells you the value is wrong and not where to
  read about it. If that is worth fixing it is a change to `lib/varschema.json`
  and `lib/config.py`, neither of which is in this document's scope.
* **On a box that cannot install anyway you will not reach it.** Preflight
  stage A runs before the configuration merge, so on a host that is not root
  the run stops at `11` (`EX_PREFLIGHT`) and the value is never validated —
  which is what happens on this project's own development box, every time. On
  a host that gets as far as the merge, a bad value is `10` (`EX_USAGE`).

So: no rules are added, none are removed, and no packet filter is installed,
configured or enabled by anything in this tree.

## What upstream changes, which is not nothing

This is the part people get wrong, because "the installer configures no
firewall" reads as "your host's filtering was left alone", and on some
distributions that is false.

Upstream T-Pot's playbook, from its own documented list of what it does to the
box (project record, kept outside this repository: `notes/upstream-facts.md`,
*What the playbook actually does to the box*):

* moves administrative `sshd` to **tcp/64295** and disables the DNS stub
  listener;
* **on the Red Hat family, sets the `firewalld` public zone target to `ACCEPT`
  and puts SELinux into Monitor Mode** (permissive). A firewalld that was
  filtering that host before the install is not filtering it after, and SELinux
  is logging instead of enforcing;
* adds Docker's repository, installs Docker, and puts the install account in
  the `docker` group — which is equivalent to root on that machine;
* removes packages it considers conflicting, installs shell aliases, and
  enables `tpot.service`;
* installs a root cron job that reboots the host every night at a time it
  randomises per install, stopping T-Pot and pruning containers, images and
  volumes first.

The firewalld and SELinux steps are scoped to the Red Hat family in this
project's record. **That is where the scoping stops being verified**: nothing
read here says what upstream's playbook does on a Debian-family host that has
`firewalld` or SELinux installed anyway, and no one has checked. So on Debian,
Ubuntu or Mint, read "probably not those two steps" rather than "confirmed
untouched" — and note that `sshd` still moves, Docker is still installed, and
Docker manages filtering rules of its own for whatever it publishes.

**There is no flag that turns the firewalld and SELinux steps off.** They are
part of upstream's playbook, this project drives that playbook rather than
forking it, and a host on the Red Hat family gets them.

## The ports

| Port | What it is | Who serves it |
|---|---|---|
| **tcp/64295** | administrative SSH, after the install | the host's own `sshd` |
| **tcp/64297** | the dashboard, HTTPS with a self-signed certificate | T-Pot |
| **tcp/64298** | Elasticsearch — **binds to loopback only** | T-Pot |
| **tcp/64294** | sensor-to-hive data transmission | T-Pot, on a hive |
| **tcp/22** | **no longer administrative SSH: it becomes a honeypot** | T-Pot |

`tcp/22` is the one that catches people out. After the install it accepts the
connection and answers as though it were a real system, and everything typed
there is recorded as attacker activity. Which honeypot answers depends on the
install type, so neither this page nor the installer's closing notice names it;
run `dps` on the host to see what is actually running.

`tcp/64294` matters only in a distributed deployment. On a standalone box
nothing should be reaching it.

Those five are the whole of what the material available to this project
enumerates. Which brings us to the problem.

## The hard part: nobody has written down the honeypot ports

**The material this project has does not enumerate the honeypot ports.** It
names the administrative and inter-node ports in the table above, and it names
the honeypot *images* — thirty of them across all editions, a subset of which
runs depending on the compose file for your install type — but no document
available here lists the ports those images bind, per edition, per release.

That is a problem specific to this kind of software:

* **A honeypot has to be reachable from the internet or it is not a honeypot.**
  The exposed surface is the product, not an oversight.
* **A firewall that guesses wrong fails silently.** Block a port some honeypot
  was listening on and nothing breaks: the box stays up, the dashboard still
  loads, `tpot.service` is still healthy, containers are still running. It just
  stops catching anything on that port, and there is no error anywhere, ever.
  You would find out by noticing an absence in data you have never seen before.
* **The set is not stable.** It depends on the install type, the compose file
  at whichever upstream ref is pinned, and whatever upstream changes next.

A default firewall would therefore have to be derived from the compose file of
the exact ref being installed, and verified against a running box. Neither
exists here. **So this installer ships no default, and says so rather than
shipping a plausible one.** A plausible-looking default that quietly costs you
part of your capture is worse than no default at all, because you will trust
it.

If you want a filter in front of an internet-facing honeypot, derive the open
set from your own installed box — `dps` on the host lists the containers, and
`ss -ltnp` / `ss -lunp` lists what is actually bound — and write your rules
from that, not from this page.

## A worked example, which nobody here has run

**This has never been applied to a real T-Pot by this project.** Read it, adapt
it, and test it from an address that is *not* in the allowlist before you rely
on it. It is `nftables`; translate it if your host uses something else.

The shape is the only part worth copying: **default accept, with the
administrative ports restricted, and the honeypot surface untouched.** A
default-deny ruleset with an allowlist of honeypot ports is the design that
fails silently, for the reason above.

```nft
#!/usr/sbin/nft -f
# EXAMPLE ONLY -- never applied to a running T-Pot by this project.
# Restricts the administrative surface to known sources and leaves every
# other port alone, because every other port is the product.

table inet tpot_admin
delete table inet tpot_admin

table inet tpot_admin {
  set admin_v4 {
    type ipv4_addr
    flags interval
    elements = { 198.51.100.10, 203.0.113.0/24 }   # YOUR addresses. These are documentation ranges.
  }

  set admin_v6 {
    type ipv6_addr
    flags interval
    elements = { 2001:db8:1::/64 }                 # YOUR addresses.
  }

  chain input {
    # ACCEPT is the policy on purpose: anything this chain does not name
    # explicitly stays reachable, and that is the honeypot.
    type filter hook input priority filter; policy accept;

    iif "lo" accept

    # The administrative ports, from your addresses only.
    tcp dport { 64294, 64295, 64297, 64298 } ip  saddr @admin_v4 accept
    tcp dport { 64294, 64295, 64297, 64298 } ip6 saddr @admin_v6 accept
    tcp dport { 64294, 64295, 64297, 64298 } drop
  }
}
```

Load it with `nft -f <file>`, and make it survive a reboot the way your
distribution does that — which matters here, because upstream's playbook
reboots the host every night.

### Four things to check before you trust it

1. **Prove the lockout from a second session, before you close the first.**
   Keep your existing SSH session on tcp/64295 open. From an address that is
   *not* in `admin_v4`, confirm a new connection is refused; from an address
   that *is*, confirm one still succeeds. Only then log out. Getting this
   wrong on a remote box costs you the box.
2. **Confirm the drop actually reaches the dashboard port.** Administrative
   `sshd` on 64295 is a process on the host, so a `filter`/`input` chain
   governs it. The dashboard and Elasticsearch are served by containers, and
   whether those are host-networked or published through Docker's NAT decides
   whether an `input` hook ever sees that traffic at all — published container
   ports are DNATed and traverse `forward`, not `input`. On the one host where
   this was looked at (Ubuntu 26.04, 2026-09-05) both ports had a host-level
   listening socket, which is what Docker's userland proxy provides; that is one
   box at one ref, and it does not by itself say where a packet arriving from
   another machine is filtered. **Verify from outside** rather than assuming the
   `drop` line above did anything for 64297.
   If it did not, the rule you need belongs in the `forward` hook or in
   Docker's own chain, and getting that wrong breaks container networking in
   ways that are much louder than a missed honeypot port.
3. **No connection tracking on purpose.** There is no `ct state established`
   rule here. It is not needed — nothing in this table drops anything except
   four fixed destination ports, and Linux's default ephemeral source-port
   range (`net.ipv4.ip_local_port_range`, 32768-60999) sits below them, so
   reply traffic to connections *you* originate is not matched. Check that
   sysctl if your host has been tuned. It is also actively unwanted: a box whose job is to attract
   tens of thousands of unsolicited connections is a box whose conntrack table
   you do not want to fill. If you add `ct state` rules, size the table.
4. **On the Red Hat family, decide what you are doing about `firewalld`.**
   Upstream set its public zone to `ACCEPT` during the install. Running an
   `nftables` table of your own alongside it works, but you now have two things
   filtering and one of them was configured by somebody else's playbook. Say in
   your own runbook which one is authoritative.

Elasticsearch on tcp/64298 binds to loopback in upstream's configuration, so it
should not be remotely reachable in the first place. The rule above is a second
line, not the first one. If 64298 answers from another host, something is
already wrong.

## An open question, not answered here

**Whether this installer should configure a firewall by default is undecided.**
It is a question for the operator and it has not been put to them in a form
they have answered.

It is written down here so the current behaviour is not mistaken for a
settled position: `tpot_firewall_mode` accepts only `none` *today*, and the
enum has one member because there is one implemented behaviour, not because
anybody has ruled that a second one would be wrong. The three candidate
answers all have real costs — no default (what happens now, and it leaves a
stranger's box wide open), a restrictive default (which silently breaks
capture, per the section above), and a required decision at install time
(which puts a question in front of a tool whose whole selling point is that it
needs almost no input, and which this project's own build gates forbid asking
interactively).

Nothing here should be read as an answer. When one is decided, this section is
replaced by it and the change is recorded in `CHANGELOG.md`.

## See also

* `docs/exit-codes.md` — what `install.sh` returns and what to do about each
  code.
* `README.md` — the *Firewall* section, which is the short form of this page,
  and the closing notice reproduced in *What it does to the host*, which is the
  text you actually see at the end of a run.
