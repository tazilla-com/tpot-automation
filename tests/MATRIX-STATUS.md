# Matrix status

Dated record of which (upstream ref × platform) pairs have been installed on real hardware.

**A platform may be called *tested* only if it has a row here.** `support-matrix.yml` says what
this installer *can* drive, which is a claim about code; this file says what it *has* driven.
`docs/compatibility.md` explains the difference and how the supported list is derived.

---

## `fdafa483e1e0f36b0a7b0cbb6bae1031fe06fc37` × `debian:13`

| | |
|---|---|
| Date | 2026-09-05 |
| Result | **Pass** — exit `20` `EX_REBOOT`, then rebooted and T-Pot started |
| Run id | `20260905T084900Z` |
| Installer | tpot-automation 0.1.0 |
| Edition | `h` (hive), the default. `TPOT_TYPE=HIVE` in T-Pot's `.env` afterwards |
| Duration | 278 s, of which 210 s was upstream's own installer |
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
| Pre-reboot verification | 14 of 14 checks passed |
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

* **Exit `0` was not observed.** The post-boot verification unit fired and wrote
  `/var/lib/tpot-automation/result.json` on the host; that file cannot be read from the network
  this run was driven from. The two-invocation contract's second half is therefore unconfirmed.
* **Container count was not compared against `min_containers` (39).** Veth interfaces are a proxy:
  a host-network container has none and a two-network container has two.
* **The dashboard was not opened.** TCP/64297 is unreachable from here.
* **Resource headroom is unmeasured.** The host sits at its memory ceiling with ballooning
  disabled, which cannot distinguish real pressure from a guest that has touched every page. The
  hive edition's heavier images are pulled at first boot, after the last measurement taken.
* **No other platform.** `ubuntu:26.04` is supported by derivation from the same pin and has never
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

## Everything else

**Untested.** Every other platform, at every ref. See `docs/compatibility.md`.
