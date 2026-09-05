# Platform compatibility

## Summary

| Platform | Status | Basis |
|---|---|---|
| Debian 13 (`trixie`), x86_64 | **Tested** | installed and verified on 2026-09-05; see `tests/MATRIX-STATUS.md` |
| Ubuntu 26.04, x86_64 | **Supported, untested** | accepted by the pinned upstream ref's gate; `apt`-based; never run |
| Everything else | **Unsupported** | see the gate table below |

Compatibility is not a preference of this project. It is the intersection of two
constraints:

1. **Upstream T-Pot's own distribution gate**, applied on the target host before it reads any
   argument and with no override flag.
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

Raspberry Pi OS is excluded by this project rather than by upstream. Two reasons, in order: no
install has ever been made on it here, and the `ID_LIKE` match rule forbids folding it into
`debian`. Separately, upstream's Raspbian path looks broken at this ref — its gate requires major
13 while `download.docker.com/linux/raspbian` publishes no `trixie` suite (404, checked
2026-09-04).

## What "expected to work" means

The tested row is Debian 13 on x86_64, installed from a Proxmox cloud image.

**Any Debian 13 system is expected to work**, however it was provisioned — netinst, cloud image,
vendor image, or a container host — provided it meets the requirements in `README.md`. Nothing in
this installer is specific to a provisioning method. The version gate compares the major number
only, so 13.0 through 13.x all pass.

**Ubuntu 26.04 is expected to work** and has not been run. Upstream accepts it, it is `apt`-based,
and this installer's only distribution-specific dependencies are `apt-get` and `systemd`. That is
a reasoned expectation, not evidence. Treat the first Ubuntu install as a first install.

**`aarch64` is expected to work and has not been run.** Preflight accepts `x86_64` and `aarch64`;
upstream publishes multi-architecture images. No ARM host has been used here.

A platform moves from *expected* to *tested* by one route only: a dated run recorded in
`tests/MATRIX-STATUS.md`. No other artefact in this repository may call a platform tested.

## Older releases

An earlier, tenant-specific version of this automation was used on Debian 11/12/13, Ubuntu
20.04/22.04/24.04 and Linux Mint 20/21/22. **That list is a record of where its predecessor ran.
It is not a compatibility claim by this project, and it was never verified here.**

Today's upstream refuses eight of those nine outright: its gate does not contain Linux Mint at
all, and its version test requires Debian major 13 or Ubuntu exactly 26.04. Replayed against the
fixtures in `tests/os-release/`, only Debian 13 passes.

Reaching an older release therefore requires pinning an **older upstream ref** whose gate accepted
it. That is supported mechanically — `tpot_upstream_ref` takes any tag or full commit sha, and
`tools/pin-upstream.sh` recomputes everything downstream of it — but it is untested, and an older
ref may not carry the `-s -t -u -p -b -r` flag surface this installer drives. Verify with
`--preflight-only` before relying on it.

`--force-unsupported-os` relaxes **this installer's** preflight check. It cannot affect upstream's
gate, which runs on the target host and has no override.

## Architecture

`x86_64` and `aarch64`. Any other value fails preflight and names the two that work.
