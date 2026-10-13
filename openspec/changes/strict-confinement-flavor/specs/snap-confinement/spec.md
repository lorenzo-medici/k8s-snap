# Spec delta: snap-confinement

## ADDED Requirements

### Requirement: Flavor patch delivery

The strict flavor SHALL be produced by `build-scripts/patches/strict/apply`,
which applies `0001-strict.patch` to the classic tree at build time. The
patched tree SHALL validate with `snapcraft expand-extensions`, and the
unpatched tree SHALL remain a valid classic build.

#### Scenario: CI builds the strict flavor

- **Given** a checkout of the classic branch
- **When** `./build-scripts/patches/strict/apply` runs
- **Then** `snap/snapcraft.yaml` declares `confinement: strict` and the tree
  builds with `snapcraft --use-lxd`

### Requirement: Interface declarations

The strict snap SHALL declare the custom plugs `home-read-all`,
`docker-privileged`, `docker-unprivileged`, `k8s-kubeproxy`,
`cilium-module-load`, `k8s-etc`, `k8s-etc-ro`, `k8s-sysctl` and
`k8s-audit-log`, and every app and hook SHALL carry an explicit plug set.
No app or hook SHALL carry more than one plug of interface
`kubernetes-support` (the Common snippet's `systemd_run` hat would
duplicate and fail AppArmor compilation).

#### Scenario: snap installed on snapd 2.77.1

- **When** the strict snap is installed
- **Then** `snap connections k8s` lists every declared plug and every
  generated AppArmor profile compiles

### Requirement: Host-visible contract

`/etc/kubernetes`, `/etc/cni` and `/var/log/kubernetes` SHALL remain
host-visible through `system-files` grants (exact paths only; `/etc/cni`
granted so `MkdirAll(/etc/cni/net.d)` can create the parent). Base-owned
paths SHALL be relocated by layouts into `$SNAP_COMMON`: `/var/lib/kubelet`,
`/var/lib/cni`, `/var/lib/kube-proxy`, `/opt/cni/bin`, `/usr/libexec`,
`/usr/local/lib`, `/var/log/pods`, `/var/log/containers`, plus bind-file
`/etc/nanorc`. k8sd SHALL relocate `/etc/containerd`,
`/var/lib/containerd` and `/run/containerd` under `$SNAP_COMMON` itself.

#### Scenario: host tooling reads /etc/kubernetes

- **Given** a bootstrapped strict node
- **Then** `/etc/kubernetes/admin.conf` exists and is readable from an
  unconfined host process

### Requirement: Health-gated enablement

All daemons SHALL be `install-mode: disable`; the configure hook SHALL
enable k8sd only after every declared plug is connected.

#### Scenario: interfaces finish connecting

- **Given** a strict snap whose plugs were not all connected at install
- **When** the last plug connects
- **Then** k8sd is `enabled active` and health is `okay`

### Requirement: Confinement-aware ELF handling

The LIEF interpreter/RPATH retargeting SHALL be a no-op when
`snap/snapcraft.yaml` declares `confinement: strict` (anchored line match),
and the classic build SHALL keep the retargeting unchanged.

#### Scenario: strict build primes containerd

- **When** the containerd part primes under strict
- **Then** the LIEF script is not invoked and the binaries keep their
  original ELF interpreter

### Requirement: runc AppArmor patches

Strict builds SHALL apply the three AppArmor change-profile patches to runc
(immediate `aa_change_profile`, NNP after profile change, profile change as
late as possible), ported at `strict-patches/v1.4.2`, applied after
`patches/` in sorted filename order, and verified to apply to runc v1.4.3.

#### Scenario: strict patch resolution

- **When** `print-patches-for.py runc v1.4.3` runs in a strict tree
- **Then** it prints `patches/v1.2.5` followed by the three
  `strict-patches/v1.4.2` patches in numeric order

### Requirement: Reproducible components

Component `version` files SHALL pin tags or full commit SHAs; k8sd SHALL be
pinned to a SHA until an upstream 1.36 tag exists. Build scripts SHALL NOT
mutate the builder's installed snaps.

#### Scenario: clean build

- **When** a snap build runs on a shared builder
- **Then** the installed `go` snap revision is identical before and after
  the build

### Requirement: Confined service management

k8sd SHALL manage snap services with `snapctl` (not the `snap` CLI) under
strict confinement, carried as a default component patch until it lands
upstream.

#### Scenario: bootstrap starts services under strict

- **When** k8sd starts containerd under strict
- **Then** the command succeeds without the snapd-control interface
