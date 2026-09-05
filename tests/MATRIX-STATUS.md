# MATRIX-STATUS — which (upstream ref × distribution) pairs have been installed, and when

**This file is the only thing in this repository entitled to use the word *tested*.**

`support-matrix.yml` says which releases this installer *can* drive. That is a claim about code.
This file says which ones it *has* driven, on a real machine, on a stated date, to a stated
outcome. D-07 keeps those two apart deliberately, because the first is cheap to assert and the
second is not.

A row here is evidence or it is nothing. Each one names the run that produced it, what that run
proved, and — the part that matters more — **what it did not**.

---

## fdafa483e1e0f36b0a7b0cbb6bae1031fe06fc37 × debian 13

| | |
|---|---|
| **Date** | 2026-09-05 |
| **Outcome** | **installed**, exit 20 `EX_REBOOT`, then rebooted and T-Pot came up |
| **Run id** | `20260905T074339Z` (install), `20260905T080402Z` (a pre-reboot `--verify-only`) |
| **Installer** | tpot-automation 0.1.0 at commit `9e15a30`, plus the two fixes this run forced (below) |
| **Edition** | `h` (hive) — the default. `TPOT_TYPE=HIVE` in T-Pot's own `.env` afterwards |
| **Host** | Proxmox VM, 4 cores, 8192 MB assigned (7880 MiB seen), 80 GB disk, no swap |
| **OS** | Debian GNU/Linux 13 (trixie), `6.12.107+deb13-cloud-amd64`, x86_64, stock cloud image |
| **Upstream** | fetched entrypoint sha256 `0e0b893b…da50`, **verified**; payload ref consistent |
| **Duration** | 276 s total; 210 s of that was upstream's own installer |

### What this run proves

* **The unattended path works end to end on a stock cloud image.** No terminal, stdin `/dev/null`,
  every input from a root-owned answer file and a root-owned password file. Nothing was typed.
* **No credential ever reached a command line** (D-08). Upstream was driven as
  `-s -t s -b <ref> -r <repo>` — the sensor type, which is the one code path that never asks for
  one — and the dashboard credential was written into T-Pot's `.env` afterwards, from a file.
  `result.json` records the exact argv.
* **The edition swap is real.** Upstream installed the *sensor* compose; the run replaced it with
  the *hive* one, and `TPOT_TYPE=HIVE` is what the box ended up with.
* **Telemetry is off** (D-09): no `ewsposter` service in the live compose file. Note that
  upstream's own install still *pulls* the ewsposter image — D-09 removes the service, not the
  image, and the image sits unused on disk.
* **Administrative SSH moved to 64295** and TCP/22 was left free until the reboot.
* **All 14 pre-reboot verification checks passed.** Account, shadow entry, sshd config validity,
  admin port, absence of extra listeners, `.env` present, `WEB_USER` written, upstream's own
  `ls`/`WEB_USER` left untouched, compose present, telemetry absent, container floor, docker
  daemon, `tpot.service` enabled, `vm.max_map_count` effective.
* **`--verify-only` refuses a box that has not rebooted.** Run before the reboot it exited 16
  `EX_VERIFY`: `listen_admin_ssh` passed, `listen_dashboard` and `listen_elasticsearch` failed
  with *"nothing listens … after 30 attempts"*. It did not report success for a T-Pot that was
  not running, which is the property the two-invocation contract rests on.
* **After the reboot, T-Pot runs.** Verified from outside the box, because by then nothing could
  get into it (see below):
  * TCP/22 answers `SSH-2.0-OpenSSH_8.8`, serves the login banner **"Fedora release 36 (Thirty
    Six)"** on a Debian 13 host, and offers `password` authentication that the real sshd has
    disabled. The real sshd is OpenSSH 10.0p2. **That is the honeypot, not the host.**
  * The guest agent reports 24 docker bridges and 34 veth pairs where a clean boot has none.

### What this run does NOT prove

* **The post-reboot verification records were never read.** The `finalize` unit was armed and
  fired on the reboot, and it writes `/var/lib/tpot-automation/result.json` on the box — but this
  platform cannot reach it. The orchestrator→project firewall allows `--dport 22` exactly;
  after the install that port is the honeypot, the real sshd is on 64295 behind a drop, the
  project token holds neither `VM.Console` nor `VM.GuestAgent.FileRead`, and guest→orchestrator
  is blocked in the other direction too. All four were measured, not assumed. So **exit 0 has
  never been observed from this product** — only the 20 that precedes it, and independent
  evidence that the thing 0 would be asserting is true.
* **The container count was never checked against `min_containers` (39 for `h`).** 34 veth pairs
  is a proxy, not a count: a container on the host network has no veth and one with two networks
  has two.
* **The dashboard was never opened.** 64297 is behind the same drop.
* **8192 MB is not a pass.** It is 7880 MiB measured, below this product's own 8192 MiB floor, and
  the run used `--force-low-resources`. `result.json` records `forced`. **Nothing here says
  T-Pot is comfortable in 8 GB** — only that it installed and started. The hive edition's heavier
  images are pulled at *first boot*, not during the install, so peak pressure came after the last
  measurement anyone took.
* **Nothing about any other distribution.** `ubuntu 26.04` is in the supported tier by derivation
  from the same pin and has never been run.

### Two defects this run had to fix before it could run at all

Both are in `git log` with their evidence; they are named here because a reader comparing this
row against an older checkout will not otherwise understand why it would not reproduce.

1. **`reachability_apt` refused to install on a stock Debian 13 cloud image.** That image
   configures no apt URL, only `mirror+file:///etc/apt/mirrors/debian.list`, which the check
   skipped as local; the check is HARD, so a hard inconclusive became `EX_PREFLIGHT` — exit 11
   with no `FAIL` row anywhere to explain it. Fixed by following the indirection (commit
   `77fad44`).
2. **`--check` could not complete on a box with no T-Pot on it.** `finalize` enables a unit whose
   file check mode never wrote. Fixed by gating the enable on check mode (commit `9e15a30`).

### How to reproduce

```bash
# on the target, as root, from a checkout of this repository
./install.sh -y \
    -c /root/answers.yml \                 # pins tpot_upstream_ref, _url, _checksum
    --web-password-file /root/web-password \
    --force-low-resources                  # only because 8192 MB < the 8192 MiB floor
```

Run it under a **pre-opened** SSH ControlMaster if the box is remote and its administrative port
is firewalled: upstream moves sshd to 64295 mid-run, and an established connection survives that
while a new one cannot be made. Detach the run (`setsid`) so a dropped session does not kill it.

---

## Everything else

**Untested.** Every other cell of `support-matrix.yml`, in both tiers, at every ref. The legacy
tier in particular is documented and explicitly not claimed (D-07); today's upstream refuses most
of it outright.
