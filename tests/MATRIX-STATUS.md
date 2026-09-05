# Matrix status

Dated record of which (upstream ref × platform) pairs have been installed on real hardware.

**Exit `0` was first observed on 2026-09-05**, on the Ubuntu row below: installed, rebooted,
verified, 25 of 25 checks passing. Until that day this product had never produced its own success
code, because the network its runs were driven from could not reach the administrative port after
an install. That was a platform limit, not a product one, and it is fixed.

**A platform may be called *tested* only if it has a row here.** `support-matrix.yml` says what
this installer *can* drive, which is a claim about code; this file says what it *has* driven.
`docs/compatibility.md` explains the difference and how the supported list is derived.

---

## `fdafa483e1e0f36b0a7b0cbb6bae1031fe06fc37` × `debian:13`

| | |
|---|---|
| Date | 2026-09-05 |
| Result | **Pass** — exit `20` `EX_REBOOT`, then rebooted and T-Pot started |
| Run id | `20260905T104928Z` |
| Installer | tpot-automation 1.0.1 |
| Edition | `h` (hive), the default. `TPOT_TYPE=HIVE` in T-Pot's `.env` afterwards |
| Duration | 268 s, of which 217 s was upstream's own installer |
| Host | Proxmox VM: 4 cores, 9216 MB assigned (8876 MiB `MemTotal`), 80 GB disk, no swap |
| OS | Debian GNU/Linux 13 (trixie), `6.12.107+deb13-cloud-amd64`, x86_64, stock cloud image |
| Upstream | entrypoint sha256 `0e0b893b…da50` verified; payload ref consistent |
| Overrides | **none.** No `--force-*` flag. `result.json` records `forced: false` |

### Verified

| Check | Evidence |
|---|---|
| Unattended, no terminal | stdin `/dev/null`, all input from a root-owned answer file and password file |
| No credential on any command line | `result.json` records the argv: `-s -t s -b <ref> -r <repo>` |
| Edition applied after the sensor install | upstream installed the sensor compose; `TPOT_TYPE=HIVE` afterwards |
| Telemetry disabled | no `ewsposter` service in the live compose file |
| Administrative SSH moved | `sshd -T` reports port 64295; TCP/22 free until the reboot |
| Pre-reboot verification | 15 of 15 checks passed |
| `--verify-only` refuses an unrebooted host | exit `16` `EX_VERIFY`; `listen_admin_ssh` passed, the two container listeners failed |
| Post-reboot: T-Pot running | see below |

Post-reboot state was established from outside the host, because after the install this network
cannot reach it:

* TCP/22 answers as an SSH server whose advertised version differs from the host's real `sshd`
  (OpenSSH 10.0p2), presents a fabricated login banner, and offers password authentication that
  the real `sshd` has disabled. Two connections drew two different personas, which is the
  honeypot's behaviour and not `sshd`'s.
* The guest agent reports 24 Docker bridges and 31 veth interfaces where a clean boot has none.

### Not verified

* **Exit `0` was not observed on THIS run.** The post-boot verification unit fired and wrote
  `/var/lib/tpot-automation/result.json` on the host, and that file could not be read from the
  network the run was driven from — the administrative pinhole was still `--dport 22` only. The
  Ubuntu row below was made after that was widened and does carry exit `0`; this row is left as it
  stood, because re-running it is what would change it, not editing it.
* **Container count was not compared against `min_containers` (39).** Veth interfaces are a proxy:
  a host-network container has none and a two-network container has two.
* **The dashboard was not opened.** TCP/64297 is unreachable from here.
* **Resource headroom is unmeasured.** The host sits at its memory ceiling with ballooning
  disabled, which cannot distinguish real pressure from a guest that has touched every page. The
  hive edition's heavier images are pulled at first boot, after the last measurement taken.
* **No other platform, at the time.** `ubuntu:26.04` has since been run — see the row below — and had never
  been run.

### Reproducing

```sh
./install.sh -y --config /root/answers.yml --web-password-file /root/web-password
```

The answer file pins `tpot_upstream_ref`, `tpot_upstream_url` and `tpot_upstream_checksum`. See
`README.md` for the full sequence and for driving the install over SSH.

### Prior run, same day

An earlier run at 07:43 on the same host used `--force-low-resources`, because the guest had 8192
MB assigned and `MemTotal` is always lower than that. It reached the same outcome. The host was
rolled back and re-provisioned with 9216 MB so the run above could be made without an override;
that run supersedes it.

Two defects were found and fixed between the two runs, both of which prevented the installer from
working on a stock Debian 13 cloud image:

* `reachability_apt` treated `mirror+file:///etc/apt/mirrors/debian.list` — the only apt source a
  Debian cloud image configures — as unreachable, and the check is hard, so preflight refused with
  exit `11` and no failing row to explain it.
* `--check` could not complete on a host with no T-Pot on it: `finalize` enabled a unit whose file
  check mode had not written.

---

## `fdafa483e1e0f36b0a7b0cbb6bae1031fe06fc37` × `ubuntu:26.04`

| | |
|---|---|
| Date | 2026-09-05 |
| Result | **Pass** — exit `20`, rebooted, then exit `0` `EX_OK` |
| Run ids | `20260905T170636Z` (install), `20260905T171403Z` (verify) |
| Installer | tpot-automation 1.0.5 |
| Edition | `h` (hive), the default |
| Host | Proxmox VM from template `9201 ubuntu2604-golden`: 4 cores, 9216 MB assigned (8864 MiB `MemTotal`), 80 GB, no swap |
| OS | Ubuntu 26.04.1 LTS, `7.0.0-31-generic`, x86_64 |
| Overrides | **none.** No `--force-*` flag. `result.json` records `forced: false` |

### This is the row that carries exit `0`

**25 of 25 verification checks passed** — 15 pre-reboot, 10 post-reboot — and the second invocation
returned `0` `EX_OK`, outcome `ok`, with `post_boot_verify_armed: false` because the unit had
disarmed itself. The post-reboot half, in full:

| Check | Evidence |
|---|---|
| `listen_admin_ssh` | listening on tcp/64295 |
| `listen_dashboard` | listening on tcp/64297 |
| `listen_elasticsearch` | listening on tcp/64298 |
| `elasticsearch_loopback_only` | bound on 127.0.0.1 |
| `honeypot_ssh_not_sshd` | no sshd process is listening on tcp/22 |
| `honeypot_ssh_published` | 2 listener(s) on tcp/22 |
| `honeypot_ssh_container` | expected cowrie, found cowrie |
| `containers_running` | 39 running, at least 39 expected |
| `containers_stable` | none restarting, none exited |
| `tpot_service_active` | `systemctl is-active tpot.service` says "active" |

### What this run also established

* **The socket-activation refusal is right, on the platform it was written for.** Ubuntu ships
  `ssh.socket` enabled and `ssh.service` disabled, and the template deliberately preserves that.
  Preflight refused at exit `11` — `22 held by sshd/systemd for ssh.socket … Disable ssh.socket and
  enable the ssh service` — and changed nothing. Applying exactly that remedy made the install
  proceed. Until this run the behaviour had only been reproduced on a Debian host put into Ubuntu's
  shape by hand.
* **The two container counts agree.** The floor verification used came from "the 39 service
  block(s) in the installed compose file", and `min_containers[h]` in the pinned ref's data file is
  39. The 1.0.3 correction — that these are the same quantity — is now measured rather than argued.
* **The post-boot unit fires on its own and can lose a race.** It ran unattended, found 36 of 39
  containers up while T-Pot was still starting, and recorded exit `16` rather than reporting
  success. That is the design working: it did not call an incomplete T-Pot verified. A second
  invocation once the containers had settled returned `0`.

### Not verified

* **The dashboard was not logged into.** Its listener answered and nginx responded through the
  administrative pinhole, but no credential was exercised against it.
* **One edition, one account policy.** `h` with the default account; the other five editions and
  the `set` password policy remain unexercised.
* **No `--force-*` path was taken**, so the override arms remain untested on this platform.

---

## Everything else

**Untested.** Every other platform, at every ref. See `docs/compatibility.md`.
