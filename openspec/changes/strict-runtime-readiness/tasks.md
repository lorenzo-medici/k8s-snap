# Tasks: strict-runtime-readiness

All tasks implemented and committed. Commit references in parentheses.

## Environment and privilege

- [x] 1. `setup_env` strict branch: no `REAL_PATH`/`REAL_LD_LIBRARY_PATH` tails under strict (`d669da75`)
- [x] 2. `k8s::util::run_with_sudo` wrapper; all bare `sudo` call sites converted (`d669da75`)

## Host-state coupling

- [x] 3. `k8s::remove::system_tuning`: strict exact-path cleanup (`/etc/sysctl.d/1000-cilium.conf`); `kubelet_logs` guard dropped (`d669da75`)
- [x] 4. `ensure_systemd_defaults`: no-op under strict; `${SNAP_INSTANCE_NAME}` unit name; `systemctl daemon-reload` (`d669da75`)
- [x] 5. containerd wrapper: `aa-exec` classic-only; strict ulimits + `oom_score_adj` (`9981cdeb`)
- [x] 6. Hardcoded `/var/snap/k8s`, `/snap/k8s/current` replaced with `$SNAP_COMMON`/`$SNAP` (`d669da75`)
- [x] 7. `k8s::util::apply_sysctl_tuning`: `/proc/sys` writes + persist `/etc/sysctl.d/1000-cilium.conf`; called from configure hook (`d669da75`, `25fcc231`)
- [x] 8. `network-requirements.sh`: assertion-only (sed/apparmor patches and rp_filter block removed, bpffs assertion) (`7c82ebb2`)

## Diagnostics

- [x] 9. `inspect.sh`: self-contained strict branches (`snapctl services`, `journalctl -u snap.*`, `journalctl -k`; skip host-only collectors and `/var/crash`) (`c5bbc47b`)
- [x] 10. `bash-utils` stages `findutils`, `gawk`, `grep`, `gzip`, `sed` (`c271f3fe`)

## Interface plumbing

- [x] 11. `connect-interfaces.sh`: derived plug set from `meta/snap.yaml` (`7c82ebb2`)
- [x] 12. Dead code removed: dqlite wrapper, pebble k8s-dqlite service (`7eb2dff1`)
- [x] 13. `pre-refresh`/`post-refresh` hooks made executable (`25fcc231`)
- [x] 14. `cri-containerd.apparmor.d`: `//&unconfined` signal peer rule added (`9981cdeb`)
- [x] 15. Pebble flavor decision: keep for classic, exclude from strict build (`7eb2dff1` base; exclusion in flavor patch)
- [x] 16. Health gate runtime: `required_interfaces`, `check_snap_interfaces`, configure/install hook wiring, interface-gated remove (`d669da75`, `25fcc231`)

## Verification

- [x] `bash -n` clean on all edited shell files; shellcheck shows only pre-existing warning classes
- [x] awk derivation extracts exactly the 27 declared plugs from a rendered mock of the strict `meta/snap.yaml`
- [x] `apparmor_parser` confirmed present in the core22 base (no staging needed)
