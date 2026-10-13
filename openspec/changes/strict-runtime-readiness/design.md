# Design: strict-runtime-readiness

## Environment (`k8s/lib.sh`)

- `k8s::common::setup_env` builds `PATH`/`LD_LIBRARY_PATH` from
  `$SNAP_CURRENT` and the base only under strict; the
  `REAL_PATH`/`REAL_LD_LIBRARY_PATH` host tails are classic-only. The check
  greps `$SNAP/meta/snap.yaml` directly because `is_strict()` itself calls
  `setup_env`.
- New `k8s::util::run_with_sudo`: no-op wrapper under strict (hooks/services
  already run as root; `sudo` is not staged), classic goes through
  `sudo --preserve-env=...` (MicroK8s `utils.sh:95-105` pattern). All bare
  `sudo` call sites converted.
- `k8s::util::apply_sysctl_tuning` (called from the configure hook, both
  flavors): applies `net.ipv4.conf.*.rp_filter=0` by writing `/proc/sys`
  directly (granted by `network-control`) and persists exactly
  `/etc/sysctl.d/1000-cilium.conf` (exact path; a `system-files` grant cannot
  cover globs, and k8sd picks its own filename dynamically from the highest
  existing order). Stops editing distro-owned `/usr/lib/sysctl.d`.
- Remove path: `k8s::remove::system_tuning` is exact-path-only under strict;
  `k8s::remove::kubelet_logs` drops its `is_strict` guard (the layout-backed
  log dirs live in `$SNAP_COMMON`); `k8s::remove::skip_if_disconnected` gates
  CNI/containerd teardown on `network-control`/`docker-privileged` so cleanup
  degrades instead of erroring (MicroK8s `remove.d` precedent).

## systemd drop-in

`k8s::containerd::ensure_systemd_defaults` is a no-op under strict (Delegate
comes from `docker-support`; ulimits/`OOMScoreAdjust` move into the
containerd wrapper; `TasksMax` has no strict equivalent). Classic bugs fixed
in passing: unit name now uses `${SNAP_INSTANCE_NAME}` (parallel installs)
and `systemctl daemon-reload` runs after copying the drop-in.

## containerd wrapper

`aa-exec -p unconfined` re-exec is classic-only. Under strict:
`ulimit -n/-u/-c` (mirroring the drop-in, best-effort with a 65536 fallback
for nofile) and `echo -999 > /proc/self/oom_score_adj` (granted by
`docker-support`). The `apparmor_parser -r` of the `cri-containerd.apparmor.d`
profile stays unconditional (the binary exists in the core22 base — verified
on this machine's core22/core24 snaps); the warning path is preserved.

## cri-containerd.apparmor.d profile

Added `signal (send,receive) peer=cri-containerd.apparmor.d//&unconfined,`
(MicroK8s `containerd-profile:46`), covering signalling across the
`//&unconfined` child transition; missing signal rules surface as pods stuck
deleting. The existing 5-peer list is broader than MicroK8s's and is kept.
The `deny mount,` rule was checked against kubelet's shared-propagation
remount: that remount runs in the kubelet wrapper under
`snap.k8s.kubelet`, outside this profile — no conflict.

## inspect.sh (`k8s/scripts/inspect.sh`)

Self-contained strict detection (grep of `meta/snap.yaml`) and
`SNAP_CURRENT`/`SNAP_COMMON` fallbacks — the script is also invoked by
absolute host path where the snap env is unset, so it must not source
`lib.sh`. Under strict: `snapctl services` instead of `systemctl`,
`journalctl -u snap.<svc>`, `journalctl -k` instead of `dmesg -H`; skips the
host `snap` CLI, `ss`, `swapon`, `lsmod`, `/proc/mounts`, `/etc/os-release`,
`/etc/environment`, registry-mirror units and the `/var/crash` harvest.

## hack scripts

- `network-requirements.sh`: the snapd AppArmor `sed` patches are deleted
  (LP#2047798, LP#2053271 Fix Committed), the rp_filter block moved into the
  snap (see above), and the bpffs mount became an assertion with an
  actionable message (snap-confine mounts `/sys/fs/bpf` for confined snaps;
  LP#2048506 is Won't Fix).
- `init.sh`: no longer a no-op — connects interfaces (strict only, detected
  from the installed snap's `meta/snap.yaml`) and runs the assertions. It
  runs on the host from an unconfined shell.
- `connect-interfaces.sh`: derives the plug set from `meta/snap.yaml` with
  the same awk extraction as `k8s::common::required_interfaces`, so the list
  can never drift from `snapcraft.yaml`; the `if` loop variable is renamed.

## Health gate (runtime half)

- `k8s::common::required_interfaces` derives the declared plug set from
  `meta/snap.yaml` (block and inline YAML list forms; verified against real
  snapd-generated metadata and a rendered mock of our strict snapcraft.yaml).
- `k8s::common::check_snap_interfaces` sets health `blocked` with the missing
  plug list and returns 1; the configure hook `exit 0`s in that case so every
  `connect-plug-*` event re-triggers it (the MicroK8s convergent state
  machine, with an explicit early-exit contract instead of a hidden
  `exit 0` inside the helper).
- Configure hook tail (strict): `snapctl start --enable
  "${SNAP_INSTANCE_NAME}.k8sd"` then `snapctl set-health okay`, in that
  order. Classic sets health `okay` unconditionally to clear stale blocked
  state (MicroK8s `configure:21-25`).
- Install hook creates the layout bind sources under strict.

## Housekeeping

- Dead code removed: `k8s/wrappers/commands/dqlite` and the pebble
  `k8s-dqlite` service (1.36 hard-fails upgrades that still carry dqlite
  state).
- `snap/hooks/pre-refresh` and `post-refresh` made executable — snapd
  silently skips non-executable hooks, so the 1.36 k8s-dqlite upgrade guard
  may never have fired (latent bug).
- `bash-utils` stages `findutils`, `gawk`, `grep`, `gzip`, `sed` so the tools
  `lib.sh`/`inspect.sh` need are guaranteed present inside the confined snap.
- Pebble supervision flavor kept for classic, excluded from the strict build
  (the exclusion lives in the flavor patch).
