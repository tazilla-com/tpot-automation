# Platform compatibility

## Summary

| Platform | Status | Basis |
|---|---|---|
| Debian 13 (`trixie`), x86_64 | **Tested** | installed 2026-09-05; pre-reboot checks 15/15, T-Pot running after reboot. See `tests/MATRIX-STATUS.md` |
| Ubuntu 26.04, x86_64 | **Tested** | installed and **verified** 2026-09-05: exit `0`, 25/25 checks. See `tests/MATRIX-STATUS.md` |
| Everything else | **Unsupported** | see the gate table below |

**The check counts in that table are what each run recorded, at the release it was made on.**
Verification declares **27 checks today** — 17 before the reboot and 10 after — and releases since
those runs have added some. A smaller number above is therefore a dated observation, not a check
that has gone missing; renumbering it would falsify the record it came from.

Compatibility is the intersection of two constraints:

1. **Upstream T-Pot's own distribution gate**, applied on the target host with no override flag.
   It runs after `getopts`, so no flag reaches it and none can relax it.
2. **This installer's package-manager requirement**, `apt-get`.

`tools/pin-upstream.sh` computes that intersection from upstream's `install.sh` at the pinned ref
and writes it to `roles/tpot_install/vars/upstream-<ref>.yml`. It is generated; do not edit it.

## Upstream's gate at the pinned ref

Read from `install.sh` at `fdafa483e1e0f36b0a7b0cbb6bae1031fe06fc37`. Upstream matches on the
`NAME` field of `/etc/os-release`, then compares the version as shown.

| `NAME` | Version required | Comparison | Upstream packages via | Result here |
|---|---|---|---|---|
| `Debian GNU/Linux` | 13 | major only | `apt` | **supported** |
| `Ubuntu` | 26.04 | exact | `apt` | **supported** |
| `AlmaLinux` | 10 | major only | `dnf` | excluded — no `apt-get` |
| `Fedora Linux` | 44 | major only | `dnf` | excluded — no `apt-get` |
| `Red Hat Enterprise Linux` | 10 | major only | `yum`, `dnf` | excluded — no `apt-get` |
| `Rocky Linux` | 10 | major only | `dnf` | excluded — no `apt-get` |
| `openSUSE Tumbleweed` | — | none (rolling) | `zypper` | excluded — no `apt-get` |
| `Raspbian GNU/Linux` | 13 | major only | `apt` | excluded — untested here |

The comparison is string inequality. There is no ordering and no "or newer": Ubuntu 25.10 and
Ubuntu 26.10 both fail the `26.04` test, and Debian 12 fails the `13` test.

Raspberry Pi OS is excluded by this project rather than by upstream: no install has ever been
made on it here, and it is not treated as Debian. Upstream's Raspbian path also looks broken at
this ref — its gate requires major 13 while `download.docker.com/linux/raspbian` publishes no
`trixie` suite (404, checked 2026-09-04).

## What "expected to work" means

The tested rows are Debian 13 and Ubuntu 26.04, both on x86_64, both Proxmox guests — Debian from
a stock cloud image, Ubuntu from a golden template built for the purpose.

**Any Debian 13 system is expected to work**, however it was provisioned — netinst, cloud image,
vendor image, or a container host — provided it meets the requirements in `README.md`. Nothing in
this installer is specific to a provisioning method. The version gate compares the major number
only, so 13.0 through 13.x all pass.

**Ubuntu 26.04 is tested**, and it is the platform carrying this project's only observed exit `0`:
installed, rebooted, verified, 25 of 25 checks, no override of any kind.

**One difference between the two is known and handled.** Ubuntu enables `ssh.socket` by default
and Debian does not. Under socket activation systemd owns the listening socket and `sshd_config`'s
`Port` is ignored, so upstream's port move — which edits `sshd_config` — does not move the
listener. Since 1.0.1 preflight detects this and refuses before changing anything, naming the
cause and the two commands that fix it; verification carries a second check that reads the kernel's
socket table rather than sshd's configuration.

**On a real Ubuntu 26.04 host that refusal fired exactly as designed**, and applying the remedy it
prints carried the install through to exit `20` and then to `0`. Until then it had only been proven
against a Debian host put into Ubuntu's shape by hand.

**`aarch64` is expected to work.** Preflight accepts `x86_64` and `aarch64` and rejects anything
else; upstream publishes multi-architecture images. No ARM host has been used here.

A platform moves from *expected* to *tested* by one route: a dated run in
`tests/MATRIX-STATUS.md`.

## Older releases

The automation this project replaces was used on Debian 11/12/13, Ubuntu 20.04/22.04/24.04 and
Linux Mint 20/21/22. **That list records where a different program ran. It is not a compatibility
claim by this project and was never verified here.**

Today's upstream refuses eight of those nine outright: its gate does not contain Linux Mint at
all, and its version test requires Debian major 13 or Ubuntu exactly 26.04. Replayed against the
fixtures in `tests/os-release/`, only Debian 13 passes.

Reaching an older release therefore requires pinning an **older upstream ref** whose gate accepted
it. `tpot_upstream_ref` accepts only a full 40-character commit sha — never a tag and never a
branch — so this means finding the commit at which upstream's gate named the release you want, and
running `tools/pin-upstream.sh` against it to recompute everything downstream.

It is untested, and there is a hard limit: an older ref may not carry the flag surface this
installer drives, in which case nothing here can install it at all. Verify with `--preflight-only`
before relying on it.

`--force-unsupported-os` relaxes **this installer's** preflight check. It cannot affect upstream's
gate, which runs on the target host and has no override.
