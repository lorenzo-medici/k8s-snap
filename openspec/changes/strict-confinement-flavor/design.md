# Design: strict-confinement-flavor

## Delivery model (D1)

`build-scripts/patches/strict/apply` (invoked by `build-snap.yaml` when
`flavor: strict`) `git apply`s `0001-strict.patch`. The patch touches only
`snap/snapcraft.yaml`, adds the `connect-plug-*` hook symlinks, and removes
`k8s/pebble/`. Everything else lives on the classic branch behind
`k8s::common::is_strict`.

## snapcraft.yaml delta (the patch)

- `confinement: strict`, `assumes: [snapd2.62]`.
- `OPENSSL_MODULES` repointed to `/usr/lib/$CRAFT_ARCH_TRIPLET_BUILD_FOR/ossl-modules-3/`
  (base is rootfs); `EDITOR: $SNAP/bin/nano` (staged) for `kubectl edit`.
- Custom plugs: `home-read-all`, `docker-privileged`, `docker-unprivileged`,
  `k8s-kubeproxy` (kubernetes-support kubeproxy flavor), `cilium-module-load`
  (kernel-module-load: `iptable_raw`, `xt_socket`, `load: on-boot` — syntax
  verified against snapd 2.77.1 source), and system-files grants:
  `k8s-etc` (write `/etc/kubernetes`, `/etc/cni`), `k8s-etc-ro` (read same),
  `k8s-sysctl` (write `/etc/sysctl.d/1000-cilium.conf`), `k8s-audit-log`
  (write `/var/log/kubernetes`).
- Layouts into `$SNAP_COMMON`: `/var/lib/kubelet`, `/var/lib/cni`,
  `/var/lib/kube-proxy`, `/opt/cni/bin`, `/usr/libexec`, `/usr/local/lib`,
  `/var/log/pods`, `/var/log/containers`, and bind-file `/etc/nanorc`.
  `/etc`, `/run`, `/var/log` are host-visible (measured, plan §3.7) and are
  covered by grants instead; `/run` is not a legal layout target.
- Per-app plug sets: minimal for control-plane apps
  (network/network-bind/network-observe/system-observe + `k8s-etc-ro`),
  `k8s-audit-log` on kube-apiserver, heavy sets only where required
  (kubelet: docker-privileged + kubernetes-support; kube-proxy:
  k8s-kubeproxy flavor; containerd: docker-privileged + cilium-module-load).
  **Rule learned the hard way: at most one kubernetes-support plug per
  app/hook** — every flavor shares one Common snippet containing a named
  `systemd_run` hat, and duplicate hats fail AppArmor compilation.
- Hook plugs: install/configure/pre-refresh/post-refresh/remove per the
  plan; plus all 27 `connect-plug-*` hooks (symlinks to `./configure`)
  declared with `k8s-sysctl, network, network-bind, network-control` — the
  set the configure body needs.
- `k8sd` becomes `install-mode: disable` (health gate enables it).

## runc strict patches

Ported MicroK8s's `strict-patches/v1.4.2` (three AppArmor change-profile
patches, 2026-rebased); deleted the stale v1.1.x sets that cannot apply to
runc v1.4.3. Verified: `patches/v1.2.5` + `strict-patches/v1.4.2` apply
cleanly to runc v1.4.3 in build order, and the built snap's runc carries
them (visible in build logs). `print-patches-for.py` now applies series in
sorted filename order and matches the literal `confinement: strict` yaml
line (a raw substring test false-positives on comments/override-prime
scripts and silently enabled strict patches on classic builds).

## Build system

- D10: the LIEF `override-prime` blocks (etcd, containerd/ctr/shim) no-op
  under strict via the same anchored confinement test, falling back to
  `craftctl default`.
- runc/containerd `build.sh` no longer refresh/revert the builder's go snap
  (raced the pinned `go/1.26-fips/stable` build-snap).
- k8sd pinned to commit `08497029` (no 1.36 tag exists upstream);
  `build-component.sh` learned to fetch a full SHA (`git clone -b` cannot
  take one; GitHub allows reachable SHA fetches).
- k8sd default component patch: `buildServiceCommand` uses `snapctl` under
  strict (the `snap` CLI is AppArmor-denied inside a confined snap; verified
  on the built snap). Applies and compiles against the pinned SHA.
- `strict-patches/` documented in `build-scripts/AGENTS.md` and README.

## Verified on the built snap (LXD, snapd 2.77.1)

- Installs without `--classic`; `confinement: strict` in meta/snap.yaml.
- All 9 layouts mount inside the snap namespace; install hook creates the
  bind sources.
- Health gate: `blocked` with the derived missing-plug list until all 27
  plugs connect, then `okay` and `k8sd` `enabled active`.
- `snap run --shell k8s`: `snap` is AppArmor-denied, `snapctl` works.
- The systemd drop-in is not written; the base ships `apparmor_parser`.
