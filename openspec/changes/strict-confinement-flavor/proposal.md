# Proposal: strict-confinement-flavor

## What

Deliver the strict confinement flavor of the k8s snap via the flavor-patch
model: `build-scripts/patches/strict/{apply,0001-strict.patch}` transforms
the tree at build time (confinement, plugs, layouts, hook plugs), while all
runtime differences live on the classic branch behind `is_strict()`
(change `strict-runtime-readiness`). Also covers the build-system work that
makes a strict build possible and reproducible.

## Why

Phases S, 2 and 3 of the strict confinement plan. The 2024 orphaned strict
branches proved the direction but are stale (core20, k8s-dqlite, runc 1.1.x
patches that cannot apply to runc v1.4.3) and never addressed ELF
retargeting, sysctl/systemd writes, or the interface health gate.

## Non-goals

- Store snap-declaration approval (docker-support, system-files,
  kernel-module-load, home read:all) — external, plan task 0a.
- k8sd upstream fixes — the `snapctl` service-management fix ships as a
  default component patch here until it lands upstream (0c).
- CI/docs (changes `strict-ci-plumbing`, `strict-docs`).

## Key decisions

- D9: both flavors publish on the bare track (`1.36/stable`); classic is the
  default flavor.
- D10: LIEF ELF retargeting becomes a no-op under strict (base is rootfs).
- D12: `/etc/kubernetes`, `/etc/cni` and `/var/log/kubernetes` stay
  host-visible via `system-files`; base-owned paths relocate via layouts
  into `$SNAP_COMMON`; `/etc/containerd`, `/var/lib/containerd` and
  `/run/containerd` are relocated by k8sd itself under strict (verified in
  k8sd release-1.36 `pkg/snap/snap.go`).
- D4: health gate — daemons `install-mode: disable`, configure blocks until
  all plugs connect, then enables k8sd and reports okay.

## Validation findings incorporated

Build + install + connect smoke tests in an LXD container surfaced and fixed:

1. `k8s-kubelet` dropped — kubernetes-support's default and kubelet flavors
   both inject the same `profile systemd_run` hat; AppArmor rejects the
   duplicate (`kubernetes_support.go`).
2. kube-proxy keeps only the `k8s-kubeproxy` flavor — the hat lives in the
   Common snippet for every flavor, so at most one kubernetes-support plug
   per app/hook.
3. All 27 `connect-plug-*` hooks declared with
   `k8s-sysctl, network, network-bind, network-control` — a hook's profile
   comes from its own declarations, not the trigger interface (MicroK8s
   precedent); otherwise the configure body fails writing
   `/etc/sysctl.d/1000-cilium.conf`.
4. k8sd component patch — its `snap` CLI service management is
   AppArmor-denied under strict; switched to `snapctl` (verified working
   from an app context, including `--enable`/`--disable`).
5. `k8s-etc` grants `/etc/cni`, not only `/etc/cni/net.d` — k8sd's
   `MkdirAll` must create the parent, which is a write to `/etc/cni`.

## Implementation status

Implemented and committed on `release-1.36`: `6f647013`, `c271f3fe`,
`51c8e1e5`, `42e0c655`, `b8654fbd`, `196868ba`, `36927064`, `bb3816c5`,
`ca338469`, `9dbf7523`, plus the k8sd component patch commit.
