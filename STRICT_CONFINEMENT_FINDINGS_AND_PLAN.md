# Strict confinement for k8s-snap (Canonical Kubernetes) — findings and plan

**Revision 5 addendum (2026-10-13): IMPLEMENTED.** All phases that are in-repo are implemented and
committed on `dev-1.36-strict` (49 commits since `b1f55ab0` on `release-1.36`), tracked as five validated OpenSpec changes
(`openspec/changes/`). **CI plumbing (Phase 4 tasks 41–43) is explicitly deferred** to a follow-up
branch (reverted: workflow flavor plumbing and the `strict.yaml` autoupdate generator); see the
`strict-ci-plumbing` OpenSpec change for the concrete to-do list, including the branch-management
consequence: once `build-scripts/patches/strict/` exists, `test_branches.py` requires
`autoupdate/release-1.36-strict` branches and the `k8s-snap-1.36-strict` Launchpad recipe. Runtime validation on a built snap (LXD VM, snapd 2.77.1) confirmed: strict
build, install without `--classic`, all 27 plugs connect, health gate `blocked → okay`, k8sd
enabled+active, bootstrap succeeds, node registers, all core services active. Validation surfaced
and fixed eight plan-blind bugs, all committed: (1) `k8s-kubelet` + default `kubernetes-support`
duplicate the `systemd_run` hat — at most one kubernetes-support plug per app; (2) connect-plug
hooks need their own plug declarations; (3) k8sd's `snap` CLI is AppArmor-denied under strict —
component patch to `snapctl`; (4) `k8s-etc` must grant `/etc/cni` itself (MkdirAll parent); (5)
kubelet's `make-rshared` must target the layout mount point; (6) all parts must be `no-patchelf`
under strict; (7) cilium's `nsenter` init containers need the host-visible `$SNAP_COMMON` spelling
of the CNI bin dir — second k8sd component patch (adds `SnapCommonDir()`); (8) the `confinement:
strict` raw substring test false-positives on comments — anchored. k8sd companion items for 0c:
`snapctl` service management, `SnapCommonDir()` + cilium `binPath`, `systemctl`-free args
reconcile, snapd-socket-free revision lookup, skip LXD/microk8s probes when denied. See the git
log and `openspec/changes/*/tasks.md` for the full record.

Session record: full investigation of `k8s-snap` (classic) against `microk8s` (strict), the external
facts verified, the decisions taken, and the resulting implementation plan.

- Target repo: `/home/lorenzo.medici@canonical.com/CanonicalK8s/k8s-snap`, branch `release-1.36` (HEAD `b1f55ab0`)
- Reference repo: `/home/lorenzo.medici@canonical.com/CanonicalK8s/microk8s`, branch `1.36` (strictly confined)
- Related external repo (not checked out): `github.com/canonical/k8sd@release-1.36` — the Go backend,
  cloned at build time by `build-scripts/build-component.sh:30` (branch `release-1.36`, not a tag)

**Revision 4 (2026-10-12).** Revision 2 re-verified both repos and replaced Parts 4–9; revision 3 added
the omitted findings and measured the namespace behaviour; **revision 4 verifies the external facts in
Part 3** against snapd 2.77.1 source, the Launchpad API and this machine's running snaps. Material
corrections are applied inline and listed in the **Errata** appendix. Headline state:

1. **`layout:` is a relocation, not a redirect.** Visible only inside the snap's mount namespace, so the
   original D2 silently removed `/etc/kubernetes` and friends from the host, breaking a CI gate, a
   published compliance claim and seven test call sites (§5.2).
2. **The namespace question is measured** (§3.7): `/etc`, `/run`, `/var/log`, `/var/snap`, `/home`,
   `/root`, `/mnt` inside a strict `core22` snap **are** the host's; `/var/lib`, `/opt`, `/usr/*`, `/srv`
   are base-owned. `/sys/fs/bpf` and `/sys/fs/cgroup` are already mounted; `/var/crash` is denied.
3. **Part 3 is now verified, not assumed**: `layoutRejectionList` and the allowed top-level directories
   (§3.1), `docker-support`'s snippets and its `Delegate=true` service injection (§3.2), all four
   Launchpad statuses (§3.3), and `system-files` rule generation (§3.9).
4. **`system-files` would work, but the precedent points the other way.** A `write:` grant emits
   `"<path>{,/,/**}" rwkl`, so creation is permitted (§3.9), and `canonical-livepatch` writes host `/etc`
   in production. But the **`docker` snap — strict, privileged `docker-support`, containerd and runc**
   — uses no `system-files` at all and relocates by daemon flags (§3.8). D12 is therefore a product
   decision between two viable options, not a technical unknown (§5.2).
5. **Both `docker-support` and `system-files` are `allow-installation: false`**, so the store must approve
   *installation*, not just auto-connection — a stronger gate than earlier drafts stated (0a).
6. **Phase ordering was circular** (store declaration → plug slimming → working strict build → Phase 2/3).
   Replaced by **Phase S** first.
7. **Missing blockers added**: ELF/patchelf retargeting (D10), unsorted patch iteration, no denial
   detection in tests, silent-no-op CI, vacuous `test_cleanup`, `/var/log/kubernetes`, `k8s/pebble`, and
   the loss of the systemd drop-in as the user-facing **proxy surface** — whose in-tree replacement is
   `$SNAP_COMMON/args/<service>-env` (tasks 4a, 45a).
8. **D9 decided by the requester: bare track `1.36/stable`.** D10 and D11 are **proposals**.

**Verification status.** Parts 1, 2 and 4–9 were verified line-by-line against the two checked-out repos.
§3.1–§3.3 and §3.9 are verified from snapd **2.77.1** source and the Launchpad API; §3.7 and §3.8 are
measured on this machine (Ubuntu 24.04.5, snapd 2.77.1). **§3.4 is partially verified**: a forked child of
a confined snap provably inherits the snap's mount namespace, but the `containerd-shim` case needs a real
strict build (S3) — this is the largest remaining unknown. §1.5 is **unverified** (`git` is denied here,
so only the existence of the three remote refs could be checked). Items still marked ⚠ are
`kernel-module-load`'s attribute syntax, `kubernetes-support`'s `autobind-unix` flavor, `apparmor_parser`
availability in the base, the exact snapd release for `assumes:`, and Ubuntu Core behaviour.

---

# Part 1 — k8s-snap as it is today

## 1.1 Snap recipe

`snap/snapcraft.yaml` (309 lines):

- `name: k8s`, `confinement: classic` (`:10`), `base: core22` (`:14`), `grade: stable`
- `architectures`: amd64, arm64, ppc64el, s390x (key on `:23`, `build-on` entries `:24-27`)
- `environment` (`:15-21`): `REAL_PATH: $PATH`, `REAL_LD_LIBRARY_PATH: $LD_LIBRARY_PATH`,
  `CRAFT_ARCH_TRIPLET_BUILD_FOR`, and
  `OPENSSL_MODULES: /snap/core22/current/usr/lib/$CRAFT_ARCH_TRIPLET_BUILD_FOR/ossl-modules-3/`
- **No `plugs:`, `slots:`, `layout:`, `hooks:` or `system-usernames` stanzas anywhere**
- Parts: `build-deps`, `etcd`, `k8sd`, `cni`, `kubernetes`, `kubernetes-version`, `helm`, `libmnl`,
  `libnftnl`, `iptables`, `containerd`, `runc`, `bash-utils`, `k8s`, `bom`, `resources`
- Go toolchain `go/1.26-fips/stable` (`:33`); `etcd` and `containerd` (plus `ctr` and
  `containerd-shim-runc-v2`) are post-processed by `build-scripts/hack/patch-elf-with-lief.sh` on
  amd64/arm64 (`override-prime` at `:71-83`, `:161-175`), which rewrites the ELF interpreter and RPATH to
  `/snap/core22/current/...` (`patch-elf-with-lief.sh:22-29`; `BASE: core22` hardcoded at `:67` and
  `:159`). Correct for classic, **wrong layer for strict** — blocker 23. `build-attributes:
  [enable-patchelf]` is set on 13 parts (`:34,70,87,95,102,112,121,129,139,160,180,186,227`)
- Apps (10): `k8s` (CLI), `containerd`, `etcd`, `k8sd`, `kubelet`, `kube-apiserver`,
  `kube-controller-manager`, `kube-proxy`, `kube-scheduler`, `k8s-apiserver-proxy`.
  `k8s` is a **command, not a daemon**, and carries **no `install-mode` key at all** (`:258-259` is
  exactly `k8s:` / `command: k8s/wrappers/commands/k8s`). Of the 9 daemons, 8 are
  `install-mode: disable` and **`k8sd` is `install-mode: enable`** (`:277`). Only a daemon can be
  `snapctl start --enable`d — a constraint on Phase 2 task 23
- `k8s-dqlite` is gone in 1.36: `snap/hooks/post-refresh:10-14` hard-fails the refresh if
  `$SNAP_COMMON/var/lib/k8s-dqlite` is non-empty ("no longer supported in version 1.36").
  `k8s/pebble/000-k8s.yaml:13-17` still references a non-existent `k8s-dqlite` wrapper (dead code).

## 1.2 Runtime payload (`k8s/`, copied verbatim to `$SNAP/k8s/`)

| Path | Purpose |
|---|---|
| `lib.sh` | shared bash library, `k8s::<category>::<name>` namespacing; sourced by every wrapper and hook |
| `wrappers/commands/k8s` | the `k8s` CLI app → `k8s::common::execute k8s` (`lib.sh:219-261`; the args/env-file-reading portion is `:227-247`) |
| `wrappers/commands/dqlite` | **dead code** — calls a `k8s::cmd::dqlite` that no longer exists and is not declared as an app |
| `wrappers/services/*` | containerd, etcd, k8sd, kubelet, kube-apiserver, kube-controller-manager, kube-proxy, kube-scheduler, k8s-apiserver-proxy |
| `args/k8sd` | `--state-dir=${SNAP_COMMON}/var/lib/k8sd/state` (the only default arg file in-tree) |
| `hack/init.sh` | `# no-op for classic confinement` — the designated strict hook point |
| `hack/connect-interfaces.sh` | `snap connect 'k8s:<iface>'` for 18 interfaces |
| `hack/network-requirements.sh` | host preflight: cgroup2/bpf mounts, rp_filter rewrite, snapd AppArmor profile patching |
| `scripts/inspect.sh` | diagnostics collector (`k8s inspect`) |
| `profiles/containerd` | the `cri-containerd.apparmor.d` profile loaded at containerd start |
| `systemd/containerd-defaults.conf` | drop-in copied into `/etc/systemd/system/snap.k8s.containerd.service.d/` |
| `pebble/` | alternative supervision flavor; hardcodes `/snap/k8s/current` and a host `PATH` |
| `manifests/charts/` | bundled Helm charts: cilium, coredns, metallb, metrics-server, rawfile-csi, contour, gateway-api, tigera |
| `resources/configurations/` | audit policy, pod-security-admission configs, DISA-STIG arg templates |

Hooks: `snap/hooks/{install,configure,pre-refresh,post-refresh,remove}` — no `connect-plug-*` hooks.
**`snap/hooks/pre-refresh` and `snap/hooks/post-refresh` are mode `-rw-rw-r--` (NOT executable)** while
`install`, `configure` and `remove` are `-rwxrwxr-x`. snapd silently does not run a non-executable hook,
so the 1.36 k8s-dqlite upgrade guard in `post-refresh:10-14` may never have fired. Latent bug,
independent of strict — Phase 1 task 13.

- `install`: `k8s::common::resources` (copies `$SNAP/etc/configurations` → `$SNAP_COMMON/etc/`),
  `k8s x-snapd-config disable`, `k8s::init::k8sd` (seeds `$SNAP_COMMON/args/k8sd`)
- `configure`: `k8s x-snapd-config reconcile`, `k8s::containerd::ensure_systemd_defaults`,
  `k8s::apiserver::sanitize_feature_gates`, `k8s::common::move_resources`
- `pre-refresh`: `k8s x-snapd-config disable`
- `post-refresh`: k8s-dqlite guard, then `touch $SNAP_COMMON/lock/post-refresh`
- `remove`: `x-cleanup containers` → `x-cleanup network` → `x-cleanup containerd` →
  `system_tuning` → `kubelet_logs` → `resources`

## 1.3 Complete inventory of classic-only behaviour

| # | Blocker | Location |
|---|---|---|
| 1 | `exec aa-exec -p unconfined -- "$0" "$@"` — deliberately escapes AppArmor | `k8s/wrappers/services/containerd:25-27` (the `exec` is on `:26`; `:25,:27` are the enclosing `if` guard) |
| 2 | `apparmor_parser -r` loads a profile into the host kernel | `k8s/wrappers/services/containerd:11`; `k8s/hack/network-requirements.sh:37,41` |
| 3 | Host `PATH`/`LD_LIBRARY_PATH` fallback via `REAL_PATH`/`REAL_LD_LIBRARY_PATH` | `snap/snapcraft.yaml:16-17`; `k8s/lib.sh:15-16` |
| 4 | Writes `/etc/systemd/system/snap.k8s.containerd.service.d/` from the configure hook | `k8s/lib.sh:293-299`; `snap/hooks/configure:9` |
| 5a | **Removes** k8sd-written sysctl drop-ins: `find /etc/sysctl.d/ -maxdepth 1 -type f -regextype posix-extended -regex '.*/[0-9]+-k8s\.conf'` → `xargs sudo rm -f` → `sudo sysctl --system`. **Nothing in k8s-snap writes those files** — the writer is the external **k8sd** Go repo | `k8s/lib.sh:98-107` |
| 5b | Writes a *differently named* file and edits distro-owned dirs: `sed -i -e '/net.ipv4.conf.*.rp_filter/d' $(grep -ril '\.rp_filter' /etc/sysctl.d/ /usr/lib/sysctl.d/)` (`:30`), `sysctl -a \| grep '\.rp_filter' \| awk '{print $1" = 0"}' \| tee -a /etc/sysctl.d/1000-cilium.conf` (`:31`), `sysctl --system` (`:32`) — note **distro-owned `/usr/lib/sysctl.d/`** is mutated | `k8s/hack/network-requirements.sh:30-32` |
| 6 | `mount -o remount --make-rshared` on `/var/lib/kubelet` | `k8s/lib.sh:278` |
| 7 | `modprobe --` of host kernel modules. The only literal `modprobe` invocation is in `k8s::util::load_kernel_modules`; `k8s/wrappers/services/kube-proxy:13` is not a `modprobe` — it is `k8s::util::load_kernel_modules nf_conntrack \` | `k8s/lib.sh:287` (called from `k8s/wrappers/services/kube-proxy:13`) |
| 8 | Unqualified host paths for kubeconfigs/PKI (`/etc/kubernetes/admin.conf`, `kubelet.conf`) | `k8s/lib.sh:140,177` |
| 9 | `sudo` from library/hooks | `k8s/lib.sh:104,105,112,119,123` — note `:112` is **unconditional** (blocker 16) |
| 10 | Host `systemctl` (`:82,168,171,183`), `journalctl` (`:179,188`) and `snap` CLI (`:141-144`: `snap version`/`list`/`services`/`logs`) | `k8s/scripts/inspect.sh` |
| 11 | `OPENSSL_MODULES` points into a foreign base snap | `snap/snapcraft.yaml:21` |
| 12 | Rewrites snapd's own AppArmor profiles with `sed` + reload | `k8s/hack/network-requirements.sh:35-41` |
| 13 | Hardcoded `/snap/k8s/current` and `/var/snap/k8s/common` instead of `$SNAP*` | `k8s/lib.sh:307,321,323`; `k8s/scripts/inspect.sh:87,103,153-156`; `k8s/pebble/pebble.service:6,11,15` |
| 14 | Host utilities resolved through `PATH`: `find`/`xargs` (`k8s/lib.sh:100,104`), `gzip` (`inspect.sh:245`), `grep` (`inspect.sh:60,82,112,183,215,342`), `awk` (`inspect.sh:183`), `sed`+`awk` (`k8s/lib.sh:323,368,371`; `network-requirements.sh:30,31`). **`sed` does not appear in `inspect.sh` at all.** `inspect.sh:209,213` are `iptables-legacy-save`/`ip6tables-legacy-save`, which are **not** host-only: `snapcraft.yaml:135-152` builds iptables 1.8.6 from source with `--prefix=/usr --exec-prefix=/ --disable-shared --enable-static` and does **not** disable the legacy backends (its `stage:` excludes three entries — `-usr` `:149`, `-lib/pkgconfig` `:150`, `-bin/iptables-xml` `:151` — none of which is a legacy backend), so `xtables-legacy-multi` plus the `ip{,6}tables-legacy{,-save,-restore}` symlinks are expected in `$SNAP/sbin`, which `k8s/lib.sh:15` puts on `PATH`. Both calls are already `\|\| true`-guarded | vs the `bash-utils` part (`snap/snapcraft.yaml:184-222`) |
| 15 | bpffs mount + cgroup2 assertion performed on the host | `k8s/hack/network-requirements.sh:10-15` (cgroup2 assertion), `:17-25` (bpffs mount) |
| 16 | `sudo rm -rf "$SNAP_COMMON/etc"` in `k8s::remove::resources` (`:110-114`) — the **only** `sudo` on the remove path with **no `is_strict` guard**. `sudo` is **not staged** in the snap (`snapcraft.yaml:36` lists it under `build-packages` only), so it resolves from `$REAL_PATH`: it cannot work under strict nor on Ubuntu Core | `k8s/lib.sh:112` |
| 17 | `k8s::containerd::ensure_systemd_defaults` hardcodes the unit name `snap.k8s.containerd`, breaking parallel instances where `SNAP_INSTANCE_NAME != k8s`; contrast `k8s/wrappers/services/k8sd:6`, which correctly uses `@snap.${SNAP_INSTANCE_NAME}.k8sd` | `k8s/lib.sh:293` |
| 18 | Host-wide core-dump coupling: `ulimit -c unlimited` + `export GOTRACEBACK="crash"` for **every** service; `inspect.sh` harvests `CORE_DUMP_DIR="/var/crash"`; tests set `snap set system system.coredump.enable=true` | `k8s/lib.sh:253-254`; `k8s/scripts/inspect.sh:36,193-201`; `tests/integration/tests/test_util/util.py:269` |
| 19 | Host-privileged collection in `inspect.sh` beyond `systemctl`/`journalctl`/`snap`: `dmesg -H` (`:133`), `lsmod` (`:130`), `swapon` (`:121`), `ss -plnt`/`ss -plntu` (`:210,214`), `cp /proc/mounts` (`:115`), `cp /etc/os-release` (`:127`), `grep ... /etc/environment` (`:215`), report written to `$(pwd)/inspection-report` (`:29`) | `k8s/scripts/inspect.sh` |
| 20 | Invokes the **host `snap` CLI** as root (`bash -c "snap connect 'k8s:${if}'"`). A strictly confined process cannot run `snap`, so this script only works when executed from an unconfined host shell. **Nothing in-tree invokes it today**: `tests/.../test_util/util.py:317` invokes `/snap/k8s/current/k8s/hack/init.sh` (by absolute host path), and `init.sh` is a 3-line no-op, so `connect_interfaces=True` currently connects nothing. The loop variable is literally named `if` | `k8s/hack/connect-interfaces.sh:31-33` |
| 21 | Host-visible hostname/network state: `k8s::cmd::hostname` → `hostname`; `k8s::util::default_interface` → `ip route show default` | `k8s/lib.sh:156,162` |
| 22 | **Build-time** host mutation: `snap list go`, `snap refresh go --channel=${maj_min}-fips/stable`, `snap revert go` — mutates the builder's installed snaps, in **both** runc and containerd, racing against the `go` build-snap pinned at `snapcraft.yaml:33` | `build-scripts/components/runc/build.sh:4,10,27`; `build-scripts/components/containerd/build.sh:4,10,36` |
| 23 | **Build-time ELF retargeting to a foreign base mount**: `patch-elf-with-lief.sh` sets `--set-interpreter /snap/$BASE/current/lib64/ld-linux-x86-64.so.2` (aarch64: `/snap/$BASE/current/lib/ld-linux-aarch64.so.1`) and `--set-rpath /snap/$BASE/current/lib/<triplet>/` on `etcd`, `containerd`, `ctr` and `containerd-shim-runc-v2`. Right under classic (the process runs in the host rootfs); under strict `snap-confine` makes the base the rootfs at `/`, so the unpatched interpreter is already correct and the rewrite relies on `/snap/core22/current` being visible to a confined process — fragile and not something snapd promises. MicroK8s (strict, core22) carries no LIEF patching and uses `no-patchelf` on its native parts. `BASE: core22` is hardcoded at `snapcraft.yaml:67` and `:159` with the comment "This field must match the base field above" | `build-scripts/hack/patch-elf-with-lief.sh:22-29`; `snap/snapcraft.yaml:67,71-83,159,161-175` |
| 24 | `/var/log/kubernetes/audit.log` — written by kube-apiserver inside the snap (`k8s/resources/configurations/disa-stig/bootstrap.yaml:18`, `control-plane.yaml:3`) and asserted from the **host** by a CI-run doc test (`docs/canonicalk8s/snap/howto/security/hardening.md:150,159,170`) | see D12 |
| 25 | `k8s/pebble/*` is a parallel supervision flavor that installs a host systemd unit and hardcodes `/snap/k8s/current`, `SNAP_REVISION=current`, `SNAP_COMMON=/var/snap/k8s/common` and `REAL_PATH` (`pebble.service:6,11-15`; `K8SD_RUNTIME_ENVIRONMENT=pebble` at `:16`) — not snapd-managed, so it cannot work strict | `k8s/pebble/` |

`inspect.sh` has **two invocation paths with different `PATH` resolution**:
`tests/integration/tests/conftest.py:54` runs it by absolute host path
`/snap/k8s/current/k8s/scripts/inspect.sh`, which does **not** source `lib.sh` and therefore resolves
against the host `PATH`; `k8s inspect` goes through the snap and resolves snap-internal binaries.
Phase 1 task 9 must handle both.

Host paths referenced. **Whether a layout can redirect them is not the right question** — a layout is a
relocation visible only inside the snap's mount namespace and hides the path from the host (see D12).
Referenced: `/etc/kubernetes`, `/etc/cni/net.d`, `/opt/cni/bin`, `/etc/containerd`, `/var/lib/containerd`,
`/var/lib/kubelet`, `/var/log/pods`, `/var/log/containers`, `/var/log/kubernetes`, `/var/lib/cni`,
`/usr/libexec`. **Not valid layout targets** (snapd's `layoutRejectionList`, verified — §3.1): `/run/containerd`,
`/proc`, `/sys`, `/var/lib/snapd`; `/etc/systemd/system` and `/etc/sysctl.d` are writable only through
`system-files` (or not at all).

## 1.4 Dormant strict scaffolding already in-tree

- `k8s::common::is_strict()` — greps `confinement: strict` in `${SNAP}/meta/snap.yaml` (`k8s/lib.sh:36-44`)
- `! is_strict` guards already present: `k8s::remove::system_tuning` (`:98`),
  `k8s::remove::kubelet_logs` (`:117`)
- `k8s::kubelet::ensure_shared_root_dir` exists and is called under strict only
  (`k8s/lib.sh:273-280`; `k8s/wrappers/services/kubelet:7`)
- `k8s/hack/connect-interfaces.sh:10-29` lists 18 interfaces. **None of the 18 is defined**, because
  `snapcraft.yaml` has **no `plugs:` stanza at all** — so `snap connect k8s:<iface>` would currently
  fail for *every* entry, not just the exotic ones. `cilium-module-load` is additionally not a snapd
  interface name: it is a custom **plug name** that must be declared with
  `interface: kernel-module-load`
- `build-scripts/print-patches-for.py:13-14,82-84` — `STRICT` detection and `strict-patches/`
  resolution (`:82` `patch_dirs = ["patches"]` is part of the resolution, not preamble).
  `STRICT` is a **raw substring test** — `"confinement: strict" in snapcraft.yaml` — so a manual
  `snapcraft` build with `confinement: classic` silently gets no strict patches. Patches are applied by
  `build-component.sh:42-44` with `git am`, `patches/` first then `strict-patches/`. **Latent defect:**
  `:104` iterates `(patches_dir / patch_version).iterdir()` **unsorted**; harmless for every existing
  single-file `patches/` dir, but the three runc strict patches are an order-dependent series (`0002` and
  `0003` both reorder the NNP/profile operations) — Phase S task S1 fixes it with `sorted(...)`
- `build-scripts/components/runc/strict-patches/{v1.1.5,v1.1.12,v1.1.13}` — 3 AppArmor patches each;
  **stale**: runc `version` is `v1.4.3`. Verified algorithm outcome
  (`find_suitable_patch_version`, `:47-72`; candidates are walked in reverse lexicographic order and the
  newest one `<=` the target wins): the non-strict pass selects `patches/v1.2.5`, and under
  `STRICT` the stale dirs would **additionally** select `strict-patches/v1.1.13`, which **cannot apply**:
  its `0002` hunk context (`@@ -57,12 +57,6 @@ func (l *linuxSetnsInit) Init()`) predates the pidfd and
  `Umask` blocks that exist in runc 1.4 (MicroK8s's `v1.4.2` `0002` is `@@ -64,11 +64,6 @@` with that
  context). `git am` hard-fails. This confirms the Phase 3 premise
- **Patch directories elsewhere.** `runc` is the only component with a `strict-patches/` directory, but it
  is **not** the only one with `patches/`: `kubernetes/patches/{default,v1.31.0,v1.32.0,v1.34.0}`,
  `containerd/patches/{default,v2.1.3,v2.3.3}` (one side-load-images patch each),
  `cni/patches/default`, and `runc/patches/{v1.1.12,v1.2.5}`. The non-strict resolution path is therefore
  exercised on every build; only its `STRICT` branch is unproven
- `tests/integration/tests/test_strict_interfaces.py` — `@pytest.mark.xfail(run=False)` (`:13`), and
  **logically broken even if un-xfailed**: `:34` calls `setup_k8s_snap(cp, channel,
  connect_interfaces=False)` so `init.sh` never runs, yet `:67-77` assert `snapctl is-connected <iface>`
  for all 18 plugs, including non-auto-connect ones. Its list (`:47-66`) is byte-identical to
  `connect-interfaces.sh:10-29`. It is also triply suppressed (`xfail(run=False)` + `skipif` +
  `tags.WEEKLY`) and `e2e-tests.yaml:286` sets `TEST_STRICT_INTERFACE_CHANNELS: "recent 6 strict"` on
  every run, so CI reports a green `xfailed` for the one test meant to guard the interface list
- `tests/integration/tests/test_util/config.py:40` (`TEST_FLAVOR`), `:196-198`
  (`TEST_STRICT_INTERFACE_CHANNELS`; `:194-195` are comments)
- CI flavor plumbing: `.github/workflows/build-snap.yaml:13-14,38-43,59-67` (expects
  `./build-scripts/patches/<flavor>/apply`), `lint_and_integration.yaml:9,11,26-27,30` (matrix pinned to
  `patch: [""]` with the comment "right now we only support the classic flavor"),
  `e2e-tests.yaml:32-33,281,286`. `sbom.yaml:9,11` are **not** flavor plumbing — that workflow has no
  `inputs:` block at all; those lines are `on: push: branches:` filters for `autoupdate/strict` and
  `autoupdate/release-[0-9]+.[0-9]+-strict`. **Passing `flavor: strict` today fails at
  `build-snap.yaml:43`**: `build-scripts/patches/` does not exist
- `k8sd` is cloned by `build-scripts/build-component.sh:30` (not by `k8sd/build.sh`) from
  `components/k8sd/repository`, at `components/k8sd/version` = the **branch** `release-1.36` — uniquely
  among components, all of which pin tags (`cni v1.9.1`, `containerd v2.3.3`, `etcd v3.6.13`,
  `helm v4.2.4`, `kubernetes v1.36.4`, `pebble v1.11.0`, `runc v1.4.3`). A strict build is therefore not
  reproducible while k8sd changes land
- `build-scripts/AGENTS.md` and `build-scripts/README.md` document only per-version `patches/`, never
  `strict-patches/` (MicroK8s's `components/README.md:25,31,34` does document it)
- `.github/ISSUE_TEMPLATE/create_release_branch.md:44,109-115,126,135-136` still requires creating
  `autoupdate/release-1.xx-strict` (`:109-110`), the `k8s-snap-1.xx-strict` Launchpad recipe (`:115`), and
  references `.github/workflows/strict.yaml` / `strict-integration.yaml` (`:126,135-136`) — **neither
  workflow exists**
- `AGENTS.md:4` — "a single classic/strict snap package"; `:46` — *"Channel format:
  `{major}.{minor}-{flavor}/{risk}`, e.g. `1.36-classic/stable`"*; `:47` — "Flavors: `classic`
  (default), `strict`". Both lines contradict D9 (bare track) and are amended in Phase 4 task 34
- `build-scripts/patches/` **does not exist** on `release-1.36`, so `build-snap.yaml:43` would fail for
  any non-empty flavor

## 1.5 The orphaned strict branches

> **UNVERIFIED — `git` is denied in this environment.** The only part of this section that could be
> confirmed is the *existence* of the three refs at the SHAs below, read from `.git/packed-refs`; none
> of them exists as a local head (`.git/refs/heads` holds only `release-1.36`). Everything else here —
> the patch's contents, its `core20` base, the author, the 2024-05-10 date, the 7-item change list and
> the **per-app plug table** — is unverified. Run
> `git show origin/strict/main:build-scripts/patches/strict/0001-Strict-patch.patch` manually before
> relying on any of it. Phase 2 task 21 builds on "the validated 2024 sets" and therefore inherits
> this uncertainty.

```
9dfb409c  refs/remotes/origin/strict/main                        (flavor generator)
79a2490d  refs/remotes/origin/autoupdate/release-1.32-strict     (applied result, 2024-05-10)
9e539a90  refs/remotes/origin/autoupdate/release-1.33-strict     (applied result, 2024-05-10)
```

`origin/strict/main` carries `build-scripts/patches/strict/apply` (a `git am` wrapper) plus
`0001-Strict-patch.patch` by Angelos Kolaitis, dated **2024-05-10**, on `base: core20`, still with
`k8s-dqlite`. Its contents (the previous blueprint):

1. `confinement: classic` → `strict`
2. `k8s/hack/init.sh`: no-op → calls `connect-interfaces.sh` + `network-requirements.sh`
3. `k8s/wrappers/services/containerd`: **deletes** the `aa-exec -p unconfined` re-exec block
4. Per-app `plugs:` for every app
5. `layout:` for `/etc/kubernetes`, `/etc/cni/net.d`, `/opt/cni/bin`, `/var/lib/kubelet`,
   `/var/log/pods`, `/var/log/containers`, `/var/lib/cni`, `/var/lib/calico`, `/usr/local`,
   `/usr/libexec`, `/var/lib/kube-proxy`, `/etc/service/enabled`, `bind-file: /etc/nanorc`
6. Top-level `plugs:`: `home-read-all`, `docker-privileged`, `docker-unprivileged`, `cilium-module-load`
   (`kernel-module-load`, `iptable_raw` + `xt_socket`, `load: on-boot`)
7. `hooks: remove: plugs: [network, network-bind, process-control, network-control, firewall-control]`

Its per-app plug sets (**unverified**, per the banner above):

| App | Plugs |
|---|---|
| `k8s` | firewall-control, home-read-all, home, kernel-module-observe, kubernetes-support, login-session-observe, log-observe, mount-observe, network, network-control, network-observe, opengl, system-observe |
| `containerd` | network-bind, docker-privileged, firewall-control, network-control, mount-observe, kubernetes-support, cilium-module-load, opengl, cifs-mount, fuse-support, kernel-crypto-api |
| `k8s-dqlite` | network-bind |
| `k8sd` | network, network-bind, mount-observe, kubernetes-support — with `# FIXME: we keep 'kubernetes-support' because 'mount-observe' is not sufficient for some reason, investigate` |
| `kubelet`, `kube-apiserver`, `kube-controller-manager`, `kube-proxy`, `kube-scheduler` | identical heavy set: docker-privileged, firewall-control, hardware-observe, kubernetes-support, mount-observe, network-bind, network-observe, network-control, process-control, system-observe, opengl, kernel-module-observe |
| `k8s-apiserver-proxy` | network-bind |

**Cross-check against MicroK8s's verified plug sets** (§2.3): MicroK8s's `daemon-containerd` set is
`network-bind, docker-privileged, firewall-control, network-control, mount-observe, kubernetes-support,
opengl, cifs-mount, fuse-support, kernel-crypto-api` — **no `cilium-module-load`** and no
`kernel-module-observe`, so the `containerd` row above does not match MicroK8s on that point and is a
further reason to treat the whole table as unverified.

**Gaps it never addressed** (still open, now covered by this plan): `/etc/systemd/system`,
`/etc/sysctl.d`, `OPENSSL_MODULES`, the ELF interpreter/RPATH retargeting (blocker 23), the host
`apparmor_parser`/`systemctl`/`journalctl`/`snap`/`sudo` calls, and `/etc/containerd` +
`/var/lib/containerd`.

## 1.6 Already-strict-ready pieces

`k8s/profiles/containerd` is **mostly** written for strict already: besides the standard
containerd/docker default-container rules it carries, at `:36-42` (written out individually, no brace
expansion)

```
ptrace (trace,read) peer=cri-containerd.apparmor.d,          # :36

signal (receive) peer=snap.k8s.containerd,                   # :38
signal (receive) peer=snap.k8s.kubelet,                      # :39
signal (receive) peer=snap.k8s.k8sd,                         # :40
signal (receive) peer=snap.k8s.k8s,                          # :41
signal (receive) peer=snap.k8s.hook.remove,                  # :42
```

i.e. pod containers can be signalled by the snap's own confined daemon profiles. That 5-peer list is
actually **broader** than MicroK8s's, which names only two
(`microk8s-resources/containerd-profile:44-45`: `snap.microk8s.daemon-kubelite`,
`snap.microk8s.daemon-containerd`; its `ptrace` rule is at `:42`).

**But MicroK8s carries a third rule that k8s-snap does not have at all** (`:46`):

```
signal (send,receive) peer=cri-containerd.apparmor.d//&unconfined,
```

which covers signalling across the transition into the `//&unconfined` child profile. So this section's
previous conclusion of "no change required" is **wrong**: a line-by-line diff of
`k8s/profiles/containerd` against `microk8s-resources/containerd-profile`, and the addition of the
`//&unconfined` peer rule, is a required Phase 1 task (14). Pod deletion is the documented failure
mode for missing signal rules (validation step 8). The profile also contains `deny mount,` at `:24`,
which must be checked against kubelet's shared-propagation remount (`k8s/lib.sh:278`).

Also already strict-aware: `k8s/lib.sh:133` defaults `CONTAINERD_ADDRESS` to
`$SNAP_COMMON/run/containerd.sock`; `k8s/wrappers/services/k8sd:6` uses the abstract socket
`@snap.$SNAP_INSTANCE_NAME.k8sd` (permitted by snapd by default).

---

# Part 2 — MicroK8s as the strict blueprint

`microk8s/snap/snapcraft.yaml`: `confinement: strict` (`:12`), `base: core22` (`:13`),
`assumes: [snapd2.52]` (`:14`).

MicroK8s puts **both** `layout:` (`:611-635`) and `system-usernames:` (`:609-610`) under
`passthrough:` (`:608`). There is no comment or document anywhere in the tree explaining why; it is
legacy from the core18 / snapcraft-2.x era, unnecessary on core22, and it **bypasses snapcraft schema
validation**. **Do not copy this pattern** — use top-level `layout:` and `system-usernames:`. Phase 2
task 19 uses a top-level `layout:`.

## 2.1 The central structural idea

**Every** daemon is `install-mode: disable` (`:358,364,377,393,411,421,430,439`). Nothing starts at
install. `check_snap_interfaces()` (`microk8s-resources/actions/common/utils.sh:1241-1285`) hard-codes
23 required interfaces; if any is missing it calls
`snapctl set-health blocked "You must connect ${missing[*]} before proceeding"` and `exit 0` (`:1280-1284`).
Only `enable_snap()` (`utils.sh:1287-1290`) turns the snap on, and it does two things **in this order**:
`snapctl start --enable ${SNAP_NAME}` (`:1288`; not a literal snap name) and then
`snapctl set-health okay` (`:1289`) — which is what actually clears the blocked state. (An earlier draft
had these reversed.) The `configure` hook reaches that line
only when the interface set is complete (`snap/hooks/configure:16-25,570-573`).

The comment names the problem being solved (`utils.sh:1242-1243`):
> *"Check whether all of the required interfaces are connected before proceeding. This is to address
> https://forum.snapcraft.io/t/mimic-sequence-of-hook-calls-with-auto-connected-interfaces/19618"*

There are **28 `connect-plug-*` hooks and 2 `disconnect-plug-*` hooks**, and **26 of the 28** connect
hooks are **symlinks to `./configure`**, so snapd's non-deterministic connection order becomes a
convergent state machine: whichever plug lands last brings the cluster up. Only four are real scripts:
`connect-plug-network-control` (12 lines — deletes stale `cni0`/`cilium_vxlan` links, then delegates to
`${SNAP}/meta/hooks/configure`), `disconnect-plug-network-control` (10 lines),
`connect-plug-configuration` (6 lines) and `disconnect-plug-configuration` (3 lines, a no-op).

Two traps for the port: `connect-plug-docker-support` exists as a symlink but **no plug of that name is
declared** (only `docker-privileged` / `docker-unprivileged`), so it is a **dead hook** that never
fires; and there is **no `connect-plug-docker-unprivileged`**, so connecting that plug does not
re-trigger `configure`. snapd names these hooks after the **plug name**, not the interface — Phase 2
task 23 must declare one hook per *plug name*. The `install` hook handles the race from the other side:
`if is_strict && snapctl is-connected k8s-kubelet; then snapctl restart microk8s.daemon-containerd; fi`
(`snap/hooks/install:118-121`).

`microk8s-resources/connect-all-interfaces.sh` connects **23** plugs manually — the array is `:10-32`,
the `snap connect` loop at `:34` — exactly the same 23 that `check_snap_interfaces` requires. Needed
because `docker-support` (privileged), `personal-files` and `kubernetes-support` are super-privileged
and only auto-connect via a store-granted snap declaration. CI does exactly this
(`.github/workflows/build-snap.yml:76,103,143`, `tests/libs/airgap.sh:65,164`), and so do
`tests/libs/addons.sh:14`, `tests/test-cluster.py:163,232`, `tests/test-upgrade.py:142` and
`docs/build.md:89,92`; the script is also shipped **into** the snap (`snapcraft.yaml:256`).

## 2.2 Layouts (`passthrough.layout`, `:611-635`) and why each exists

Twelve layouts. The directly reusable set is the **six `$SNAP_COMMON` binds**: `usr/libexec`,
`usr/local/lib`, `var/lib/cni`, `var/log/pods`, `var/log/containers`, `var/lib/kubelet`. The remainder:
four `$SNAP_DATA` binds (`var/lib/calico`, `kube-proxy`, `args/cni-network`, `opt/cni/bin`), one further
`$SNAP_COMMON` bind for the historical `/etc/service/enabled`, and one `bind-file` for `/etc/nanorc`.
(See the `passthrough:` warning in the Part 2 preamble.)

**Layouts are MicroK8s's chosen answer to a different product constraint.** MicroK8s relocates *all*
state into `$SNAP_COMMON`/`$SNAP_DATA` and documents `/var/snap/microk8s/...` as the real locations; its
audit and diagnostics tooling is written against that. Canonical Kubernetes instead publishes
`/etc/kubernetes/*` as host paths (`certificates.md:55-68`, `kubectl.md:41-44`), audits them with a
CI-gated host `kube-bench`, and has host-side tests/doc-tests on them (D12). Porting MicroK8s's layout
table unchanged would therefore silently break contracts MicroK8s never had.

| Layout | Target | Reason |
|---|---|---|
| `/usr/libexec` | `$SNAP_COMMON/usr/libexec` | kubelet's **default `--volume-plugin-dir`** is `/usr/libexec/kubernetes/kubelet-plugins/volume/exec/`; MicroK8s never passes the flag (`default-args/kubelet:1-14`), so the default must be writable. Flexvolume consumers: `tests/unit/yamls/calico-new.yaml:4346`, `cni.yaml:4055` |
| `/usr/local/lib` | `$SNAP_COMMON/usr/local/lib` | escape hatch for runtime-installed libs (GPU/NVIDIA, CSI helpers). No in-tree consumer on 1.36 |
| `/var/lib/cni` | `$SNAP_COMMON/var/lib/cni` | CNI plugin state; host-local IPAM allocations in `/var/lib/cni/networks`; flannel `dataDir` (`default-args/flannel-template.conflist:9`) |
| `/var/log/pods` | `$SNAP_COMMON/var/log/pods` | CRI pod log dir; `kubectl logs` and log shippers. `--log-dir` is actively stripped from kubelet args (`snap/hooks/configure:557-562`) |
| `/var/log/containers` | `$SNAP_COMMON/var/log/containers` | the `<pod>_<ns>_<container>-<id>.log` symlink farm kubelet creates |
| `/var/lib/kubelet` | `$SNAP_COMMON/var/lib/kubelet` | matches `--root-dir` (`default-args/kubelet:5`); comment: *"so that most kubelet device plugins work out of the box"* (`snap/hooks/install:34-37`) — device-plugin/CSI sockets live under `plugins*` |
| `/var/lib/calico` | `$SNAP_DATA/var/lib/calico` | the Calico CNI **plugin binary runs inside the snap namespace** and reads `nodename_file`/MTU from here |
| `/var/lib/kube-proxy` | `$SNAP_DATA/kube-proxy` | kubeadm-convention state dir; no in-tree writer, defensive |
| `/etc/service/enabled` | `$SNAP_COMMON/etc/service/enabled` | runit convention used by `calico/node` images; no in-tree consumer, historical |
| `/etc/nanorc` (`bind-file`) | `$SNAP_COMMON/etc/nanorc` | `nano` is staged and, **only under strict**, forced as the editor so `kubectl edit` works (`microk8s-kubectl.wrapper:26-29`) |
| `/etc/cni/net.d` | `$SNAP_DATA/args/cni-network` | containerd `conf_dir` (`containerd-template.toml:73`); Calico `CNI_NET_DIR` |
| `/opt/cni/bin` | `$SNAP_DATA/opt/cni/bin` | containerd `bin_dir` (`:70`). `$SNAP_DATA` not `$SNAP` because Calico's `install-cni` **writes** binaries into it and `$SNAP` is read-only |

Reusable detail: every path that escapes into a manifest or kubeconfig is rewritten revision→`current`
via `SNAP_DATA_CURRENT=$(echo "$SNAP_DATA" | sed -e "s,${SNAP_REVISION},current,")`
(`install:32`, `configure:39`), with a retro-fix for old kubeconfigs at `configure:548-555`.

MicroK8s additionally attempts **host symlinks** for `/var/lib/kubelet`, `/var/lib/calico`,
`/etc/cni/net.d`, `/opt/cni/bin` (`install:34-56`, `configure:34-58`). Under strict these are
effectively inert, because the layout already makes `[ -e /opt/cni/bin ]` true inside the hook's mount
namespace — they are classic-era leftovers.

## 2.3 Interfaces

Custom plug definitions (`:637-670`):

| Plug | Definition | Capability |
|---|---|---|
| `home-read-all` | `home`, `read: all` | read **all** users' homes — needed so `kubectl apply -f ~/x.yaml` works under `sudo` |
| `docker-privileged` | `docker-support`, `privileged-containers: true` | privileged containers: full cgroup/devices/mount/`change_profile`. Given to `daemon-containerd` + `daemon-kubelite` |
| `docker-unprivileged` | `docker-support`, `privileged-containers: false` | same base profile without escalation, for the **client** apps `microk8s` and `kubectl` — a deliberate privilege split |
| `k8s-kubelet` | `kubernetes-support`, `flavor: kubelet` | mount/umount, cgroup writes, `/proc/sys` writes, module load, `mac_admin` + `/sys/kernel/security/apparmor/.replace`, `change_profile` |
| `k8s-kubeproxy` | `kubernetes-support`, `flavor: kubeproxy` | conntrack/netfilter sysctls, iptables/ipvs |
| `k8s-journald` | `kubernetes-support`, `flavor: autobind-unix` | autobind (unnamed) `AF_UNIX` sockets — Go journald client and dqlite |
| `dot-kube` | `personal-files`, `write: [$HOME/.kube]` | user kubeconfig dir |
| `dot-config-helm` | `personal-files`, `write: [$HOME/.config/helm]` | helm config/cache |
| `configuration` | `content: configuration`, `target: $SNAP/content-interface` | inbound launcher config + sideload images |
| `ceph-conf` | `content` (name-defaulted), `target: $SNAP/microceph` | MicroCeph conf+keyring for RBD/CephFS |

Required set enforced by `check_snap_interfaces` (23): account-control, docker-privileged, dot-kube,
dot-config-helm, firewall-control, hardware-observe, home, home-read-all, k8s-journald, k8s-kubelet,
k8s-kubeproxy, kernel-module-observe, kubernetes-support, log-observe, login-session-observe,
mount-observe, network, network-bind, network-control, network-observe, opengl, process-control,
system-observe. **Gap in the gate:** seven plugs MicroK8s declares are *never* checked —
`docker-unprivileged`, `cifs-mount`, `fuse-support`, `kernel-crypto-api`, `kernel-module-control`,
`configuration`, `ceph-conf` — so `set-health okay` is reported while `daemon-containerd` still lacks
`cifs-mount`/`fuse-support`/`kernel-crypto-api`. MicroK8s keeps three hand-maintained copies of this list
(`snapcraft.yaml` plugs, `utils.sh:1244-1268`, `connect-all-interfaces.sh:10-32`) and they already
disagree. (`kernel-module-control` is used by `daemon-apiserver-kicker` at `:413` **and** by the hooks
`connect-plug-network-control` (`:705`) and `disconnect-plug-network-control` (`:710`); it is
deliberately *not* in that list nor in `connect-all-interfaces.sh`.)

**Verified per-app plug sets** (`snapcraft.yaml`):

| App | Plugs |
|---|---|
| `daemon-containerd` (`:369-388`) | network-bind, docker-privileged, firewall-control, network-control, mount-observe, kubernetes-support, opengl, cifs-mount, fuse-support, kernel-crypto-api |
| `daemon-kubelite` (`:389-407`) | dot-kube, docker-privileged, firewall-control, hardware-observe, kubernetes-support, mount-observe, network-bind, network-observe, network-control, process-control, system-observe, opengl, kernel-module-observe |
| `microk8s` (`:334-354`) | account-control, docker-unprivileged, dot-config-helm, dot-kube, firewall-control, home-read-all, home, kernel-module-observe, kubernetes-support, login-session-observe, log-observe, mount-observe, network, network-control, network-observe, opengl, system-observe |
| `kubectl` / `ctr` (`:446-461`, `:496-508`) | docker-unprivileged, dot-kube, network, home-read-all, firewall-control, network-bind, k8s-kubelet, hardware-observe, mount-observe, network-control, process-control, system-observe — note the **client** apps hold `k8s-kubelet` |
| `daemon-k8s-dqlite` | uniquely holds `k8s-journald` |
| `daemon-apiserver-proxy` | uniquely holds `k8s-kubeproxy` |

Notable capability mappings: `firewall-control` → iptables/nft (`run-kubelite-with-args:88-96`);
`network-control` → netns + `ip link`; `mount-observe` → `/proc/self/mountinfo`;
`account-control` → `groupadd`/`usermod` (`configure:295-301`); `log-observe` + `login-session-observe`
→ `journalctl`; `opengl` → `/dev/nvidia*`; `cifs-mount`, `fuse-support` → volume types;
`kernel-crypto-api` → `AF_ALG` for encrypted volumes.

## 2.4 kubelet under strict

`microk8s-resources/default-args/kubelet` (14 lines):

```
--kubeconfig=${SNAP_DATA}/credentials/kubelet.config
--cert-dir=${SNAP_DATA}/certs
--client-ca-file=${SNAP_DATA}/certs/ca.crt
--anonymous-auth=false
--root-dir=${SNAP_COMMON}/var/lib/kubelet
--fail-swap-on=false
--eviction-hard="memory.available<100Mi,nodefs.available<1Gi,imagefs.available<1Gi"
--container-runtime-endpoint=${SNAP_COMMON}/run/containerd.sock
--containerd=${SNAP_COMMON}/run/containerd.sock
--node-labels=...
--authentication-token-webhook=true
--read-only-port=0
--tls-cipher-suites=...
--serialize-image-pulls=false
```

- `--root-dir` in `$SNAP_COMMON` (not `$SNAP_DATA`) so a refresh does not move pod volumes
- **`--cgroup-driver` is never set** anywhere in the tree, and `containerd-template.toml` never sets
  `SystemdCgroup` — both sides stay on **cgroupfs**, consistently, avoiding the need for a
  systemd-delegated slice
- Hybrid-cgroup fallback (`run-kubelite-with-args:160-169`): if cpu and memory controllers are in
  different hierarchies and `/sys/fs/cgroup/systemd/system.slice` exists, inject
  `--runtime-cgroups=/systemd/system.slice --kubelet-cgroups=/systemd/system.slice`.
  `--cgroup-root` is never set
- The `Delegate=yes` drop-in is written **only when `! is_strict`** (`run-kubelite-with-args:128-140`),
  cleaned up at `snap/hooks/remove:60-67`
- `resolv.conf`: `scripts/find-resolv-conf.py` walks `["/etc/resolv.conf", "/run/systemd/resolve/resolv.conf"]`
  and returns the first whose nameservers are all non-loopback, avoiding the `127.0.0.53` loop in pods
- Hostname: node identity from the lowercased hostname when minting the
  kubelet cert/kubeconfig (`utils.sh:606-607,616-621`); SANs include the hostname plus every non-CNI
  node IP (`get_ips()` `:569-588` filters `vxlan.calico flannel.1 cni0 ovn0`). `--hostname-override` is
  **not** in the default args, but it is not absent from the tree: `scripts/inspect.sh:338` warns when the
  hostname has capitals/underscores and no override is set, and `scripts/wrappers/join.py:327,343,470,474-475`
  clears/strips it on join
- Args are sanitised on every start (`sanitise_args_kubelet()` `utils.sh:269-308`): strips removed klog
  flags and all dockershim flags. Skippable via `$SNAP_DATA/var/lock/no-arg-sanitisation`
- **kubelite**: `0000-Kubelite-integration.patch` merges apiserver/controller-manager/scheduler/proxy/
  kubelet into one `cmd/kubelite` binary — one confined process, one profile, one plug set. Canonical
  Kubernetes keeps them separate, so it needs per-service plug sets instead

## 2.5 containerd under strict

`default-args/containerd`:

```
--config  ${SNAP_DATA}/args/containerd.toml
--root    ${SNAP_COMMON}/var/lib/containerd
--state   ${SNAP_COMMON}/run/containerd
--address ${SNAP_COMMON}/run/containerd.sock
```

All state in `$SNAP_COMMON` (revision-independent). `containerd-template.toml` is rendered at start
(`run-containerd-with-args:57-58`): `oom_score = 0`, `grpc uid/gid = 0`, metrics on `127.0.0.1:1338`,
`cgroup path = ""`, `stream_server_address = "127.0.0.1"` with port `0`,
`sandbox_image = registry.k8s.io/pause:3.10`, `cni.bin_dir = $SNAP_DATA/opt/cni/bin`,
`cni.conf_dir = $SNAP_DATA/args/cni-network`, `registry.config_path = $SNAP_DATA/args/certs.d`.

- `snapshotter` chosen at runtime by `snapshotter()` (`utils.sh:434-443`): `stat -f -c %T $SNAP_COMMON`
  → `native` on ZFS, else `overlayfs`
- `runtime_type` defaults to `io.containerd.runc.v1` (`run-containerd-with-args:50`) and is
  **upgraded** to `v2` at `:53-55` when cgroup2 is detected — so `v2` iff cgroup2, else `v1`
  (`:49-55`). The detection is `mount -t cgroup2 | grep -q 'type cgroup2'`, which is fragile and
  **silently falls back to the deprecated v1 shim** on any parsing surprise
- **The critical refresh trick** (`:22-29`): `PATH` is built from
  `SNAP_CURRENT=$(echo "${SNAP}" | sed -e "s,${SNAP_REVISION},current,")` because *"containerd-shims
  need to call runc. They inherit their PATH from containerd. As the snap refreshes runc changes
  location … containerd-shims need to look for runc in `/snap/microk8s/current/usr/bin/runc`"*
- `default-args/containerd-env` is sourced with `set -a`: proxy vars, a commented-out `# KATA_PATH=`
  (`:26`), and `ulimit -n 65536 || true` (`:29`) / `ulimit -l 16384 || true` (`:34`) — *"this get
  inherited to the running containers"*
- First-boot cleanup of stale `$SNAP_COMMON/run/containerd` uses a `/tmp` sentinel under strict
  (`is_first_boot_on_strict()` `utils.sh:1300-1314`). The stated reason is only that **`/tmp` is
  cleared at every boot** (comment `:1303-1306`), making the sentinel's absence a boot marker; there is
  no claim anywhere that `/proc/stat` btime is unreadable — the classic `is_first_boot()`
  (`utils.sh:1024-1053`) reads it successfully at `:1041`
  (`boot_time=$($SNAP/bin/grep btime /proc/stat | ...)`) with a `date -r /proc/1` fallback. (The
  sentinel filename carries a typo: `/tmp/.containerd-first-book-check`.)
- seccomp/apparmor come from the build: runc `make BUILDTAGS="seccomp apparmor" … static`
  (`build-scripts/components/runc/build.sh:11`), containerd `STATIC=1`, both parts
  `build-attributes: [no-patchelf]` — i.e. MicroK8s runs **no ELF interpreter/RPATH rewriting at all** on
  its native parts (also `iptables :126`), which is the precedent for k8s-snap's D10 (blocker 23)

## 2.6 CNI under strict

Four coordinated mechanisms: (1) the two layouts; (2) host symlinks (inert under strict); (3) a
`$SNAP` → `$SNAP_DATA` symlink farm (`snap/hooks/configure:325-332`) — *"as only one cni bin dir can be
used we will use the one in SNAP_DATA but have links to the real CNI plugins we distribute in SNAP"* —
because Calico's `install-cni` drops binaries into it; (4) config generation via
`scripts/generate-cni.sh`. CNI binaries are built as **one multiplexed static binary with 16 symlinks**
(`build-scripts/components/cni/build.sh:19-21`: `dhcp host-local static bridge host-device ipvlan
loopback macvlan ptp vlan bandwidth firewall portmap sbr tuning vrf`).

Teardown is **gated on the interface still being connected**
(`default-hooks/remove.d/10-cni-link:5`, `10-cni-link-cilium:5`, `20-cni-netns:5`):

```bash
if ! is_strict || (is_strict && snapctl is-connected network-control)
```

## 2.7 AppArmor

`microk8s-resources/containerd-profile` is the standard default-container profile plus
`ptrace (trace,read) peer=cri-containerd.apparmor.d,` (`:42`), two `signal (receive)` peers (`:44-45`)
and — the rule k8s-snap lacks — `signal (send,receive) peer=cri-containerd.apparmor.d//&unconfined,`
(`:46`). See §1.6.

Loading (`run-containerd-with-args:31-44`; the strict `apparmor_parser -r` is at `:33`, the classic
`else` runs `:34-44`):

```bash
if is_strict; then
  apparmor_parser -r $SNAP/containerd-profile        # straight into the kernel, every start
else
  cp ${SNAP}/containerd-profile /etc/apparmor.d/cri-containerd.apparmor.d
  service apparmor reload
fi
```

The write to `/sys/kernel/security/apparmor/.replace` plus `capability mac_admin` is granted by
`kubernetes-support`/privileged `docker-support` — which is why `daemon-containerd` plugs both. The
`aa-exec -p unconfined` re-exec is explicitly `if ! is_strict` (`:9-20`).

**The hardest strict problem — runc patches.** `build-scripts/print-patches-for.py:13,74-104` applies
`strict-patches/` only for strict builds. MicroK8s pins runc via
**`build-scripts/components/runc/version.sh`** — a *script* that `echo "v1.4.2"`, not a plain `version`
file (k8s-snap uses a plain `version` file containing `v1.4.3`). Three patches per runc version
(`strict-patches/{v1.1.12,v1.1.15,v1.2.6,v1.3.0,v1.3.3,v1.4.2}`):

1. `0001-apparmor-change-profile-immediately-not-on-exec.patch` — replace `aa_change_onexec`
   (`/proc/self/attr/exec` ← `exec <profile>`) with `aa_change_profile`
   (`/proc/self/attr/current` ← `changeprofile <profile>`); the on-exec transition from a snap profile
   is denied, the immediate change is permitted
2. `0002-setns_init_linux-set-the-NNP-flag-after-changing-the.patch` — *"With the current version of the
   AppArmor kernel module, it's not possible to switch the AppArmor profile if the NoNewPrivileges flag
   is set. So, we invert the order of the two operations."*
3. `0003-standard_init_linux-change-AppArmor-profile-as-late-.patch` — apply the profile **after**
   `finalizeNamespace`: with the immediate profile change, relabelling before `setuid(2)` leaves the Go
   runtime's sibling threads under the old profile, and glibc's NPTL setxid broadcast (`SIGRTMIN+1`)
   then crosses two profiles and is denied by AppArmor 4.x, *"breaking container creation for pods with
   `allowPrivilegeEscalation: false` (NoNewPrivileges)"*

The `v1.4.2` set is dated **2026-05-06 (0001, 0002) / 2026-06-18 (0003)** (authors Angelos Kolaitis,
Alberto Mardegan) and
is directly portable to k8s-snap's runc `v1.4.3`. Diffed against k8s-snap's `v1.1.13` set: same three
patches, rebased, with expanded rationale. (The `v1.3.0` directory's third file uses the untruncated name
`0003-standard_init_linux-change-AppArmor-profile-as-late-as-possible.patch`.) The patches are applied
with `git am` in **unsorted** directory order (see §1.4), which is a hazard for this order-dependent
series in both repos.

Also: `microk8s-enable.wrapper:9-13` / `microk8s-disable.wrapper:9-14` do `cd "$SNAP"` *"to avoid
AppArmor denial in strict mode when running under sudo without -H"*.

## 2.8 Kernel modules, sysctls, procfs

All in `run-kubelite-with-args`, unconditional, relying on
`kernel-module-observe`/`kubernetes-support`/`network-control`:

| What | Lines | Mechanism |
|---|---|---|
| `nf_conntrack` | `:207-218` | `/sbin/modprobe nf_conntrack \|\| modprobe nf_conntrack` if `/proc/sys/net/netfilter/nf_conntrack_max` missing |
| `br_netfilter` | `:228-239` | same dual attempt — *"Attempt to use modprobe from the host, otherwise fallback to the one provided with the snap"* (canonical/microk8s#3085) |
| `bridge-nf-call-iptables` | `:241-245` | direct `echo 1 > /proc/sys/...`, **not** `sysctl` |
| IPv4/IPv6 forwarding | `:181-193` (`:179-180` are a section header) | direct `/proc/sys/net/$ipv/conf/all/forwarding` |
| conntrack in LXC | `:220-226` | if `/proc/1/environ` contains `lxc`, set `--conntrack-max-per-core=0` instead (canonical/microk8s#1438) |
| pod FORWARD rules | `:77-97` | `iptables -t filter -A FORWARD -s/-d $pod_cidr -j ACCEPT`; removed at `snap/hooks/remove:37-53` |

`increase_sysctl_parameter()` (`utils.sh:1354-1386`) — which writes `/etc/sysctl.d/10-microk8s.conf` and
runs `sysctl --system` for `fs.aio-max-nr` and the inotify limits — is wrapped in `if ! is_strict`
(`:1362`). **On strict these dqlite tunables are simply not applied**, and `inspect.sh:121` documents
why: *"Returns sysctl: permission denied on key 'fs.aio-max-nr' on strict"*.

## 2.9 Diagnostics under strict (`microk8s/scripts/inspect.sh`)

| Classic | Strict |
|---|---|
| `systemctl status <svc>` | `snapctl services <svc>` (`:26-30`) |
| `journalctl -u <svc>` | `journalctl -u snap.<svc>` (`:25`) |
| `dmesg`, `aa-status`, `/etc/apparmor.d/containerd` | `journalctl -k` (`:56`) |
| `ss -pln` | skipped (`:84-87`) |
| `snap version`, `snap list`, `systemd-detect-virt`, `lsb_release`, `sysctl` | all skipped (`:109-129`) |
| `suggest_fixes` service status | `snapctl services` (`:194-205`) |
| UFW advice | skipped (`:222`) |
| fedora / debian9 / LXC environment checks | skipped (`:290`, `:310`, `:324`) |
| aio / inotify limit warnings | skipped (`:368+`) |
| systemd unit names prefixed `snap.` | bare `microk8s.daemon-*` for `snapctl` (`:502-512`) |

The service-name prefixing block (`:502-512`) is the piece most easily missed on a port: classic
prepends `snap.` to build a systemd unit name, strict passes the bare app name to `snapctl`.

## 2.10 Certificates, kubeconfigs, group access

Everything under `$SNAP_DATA`, group-readable. The strict-friendly choice: `create_kubeconfig_x509`
(`utils.sh:646-681`) **embeds base64 cert/key data** rather than referencing file paths, so a consumer
needs read access to exactly one file. `openssl` always goes through `openssl.wrapper`, which pins
`OPENSSL_CONF="${SNAP}/etc/ssl/openssl.cnf"` (`:9`) because the host's config is unreachable.
`git` is re-homed via `git.wrapper:7-13` (`GIT_EXEC_PATH`, `GIT_TEMPLATE_DIR`, `GIT_CONFIG_NOSYSTEM=1`,
`HOME=$SNAP_DATA/args/git`).

Access control is **group-based, not user-based**: `system-usernames: snap_microk8s: shared` (`:609-610`)
exists only so snapd creates the *group*; no daemon runs as that user (containerd is explicitly
`uid = 0 / gid = 0`). `get_microk8s_group()` returns `snap_microk8s` under strict, `microk8s` under
classic (`utils.sh:3-10`); CIS mode returns `root` (`:12-19`). Ownership is re-applied continuously,
including to the CRI socket, by the apiserver-kicker loop (`apiservice-kicker:21,35-42`). Strict also
requires root for mutating CLI verbs via `exit_if_not_root()` (`utils.sh:1292-1298`).

## 2.11 Content interfaces

- **Slot `microk8s`** (`:672-678`): exports `$SNAP_DATA/credentials` read-only to any snap plugging
  `content: microk8s` — the sanctioned way for a companion snap to get kubeconfigs without the group or
  `personal-files`. Works precisely because kubeconfigs embed cert data
- **Plug `configuration`** (`:664-667`): inbound launcher config + sideload image tarballs;
  `connect-plug-configuration:5-6` copies them into `$SNAP_COMMON/etc/{launcher,sideload}`;
  `disconnect-plug-configuration` is intentionally a no-op
- **Plug `ceph-conf`** (`:668-670`): no `content:` attribute, so it defaults to the plug name and matches
  MicroCeph's slot; client support bundled via `python3-rados`/`python3-rbd` and the ceph lib dir on
  `LD_LIBRARY_PATH` (`utils.sh:1391`)

## 2.12 Documented strict limitations in MicroK8s

- Addon metadata carries a `confinement:` list; addons not declaring `strict` are **hidden**
  (`scripts/wrappers/common/utils.py:287-306`)
- Calico interfaces are **not** removed on `snap remove` (`tests/test-cluster.py:382-385`) — the remove
  hooks require `network-control` to still be connected
- Multi-version clustering unsupported on strict + LXC (`tests/test-cluster.py:760-763`)
- Upgrade floor is higher on strict: start channel 25 vs 24 (`tests/test-upgrade-path.py:30-32`)
- sysctl tuning (aio/inotify) unavailable → dqlite may be unresponsive on low-`fs.aio-max-nr` hosts
- systemd drop-ins impossible: the cgroup `Delegate=yes` fix and CIS unit hardening are classic-only
- UFW auto-configuration is classic-only (`run-kubelite-with-args:110-126`)
- CA bundle differs: strict uses snap-internal libs/`curl`; classic pins
  `/snap/core22/current/etc/ssl/certs/ca-certificates.crt` (`utils.sh:1208-1218`)

**MicroK8s uses neither `system-files` nor `kernel-module-load` anywhere.** A repo-wide search finds
zero occurrences of either. It reaches host paths via `layout:` binds plus best-effort host symlink
farms, writes `/proc/sys` **directly** rather than through `sysctl`, and does a best-effort dual
`modprobe` (`/sbin/modprobe <mod> || modprobe <mod>`, `run-kubelite-with-args:211,233`) relying on
`kubernetes-support` / `network-control`, printing a warning on failure. The only module interfaces it
plugs are `kernel-module-observe` and `kernel-module-control`. **Consequence:** the
`rp_filter`-via-`system-files` and `cilium-module-load` designs in this plan have **no MicroK8s
precedent** — they are novel, not ports (see D5 and Phase 2 task 20).

Warning signs in the MicroK8s implementation that a port must handle deliberately:

- `check_snap_interfaces` calls `exit 0` from **inside a function** (`utils.sh:1283`), terminating the
  *calling hook* successfully. This is correct only because every entry point is `configure`, and is
  very easy to break when copied — Phase 2 task 23 must preserve the property on purpose
- `is_strict()` greps `meta/snap.yaml` as **text** (`utils.sh:1231-1239`) while the Python equivalent
  parses YAML properly (`scripts/wrappers/common/cluster/utils.py:26-30`)
- `disconnect-plug-configuration` is a no-op, so content copied in by `connect-plug-configuration` is
  never cleaned up
- `inspect.sh:222` is a **dead test** in *both* confinements: the line is
  `if ! is_strict && [ /snap/core22/current/usr/bin/which ufw &> /dev/null ]`; after the redirection is
  stripped, `[` receives two non-operator arguments, bash emits "unary operator expected" (swallowed by
  `&>/dev/null`) and returns **2 → false**, so the whole UFW suggestion block (`:222-244`) is
  unreachable. (An earlier draft said "always true" — the opposite.)
- The `check_snap_interfaces` required list omits seven declared plugs and is one of three hand-maintained
  copies that already disagree (see §2.3)

## 2.13 Techniques worth lifting wholesale

1. `install-mode: disable` + `check_snap_interfaces` + `set-health blocked` + `connect-plug-* → ./configure`
   + `enable_snap()` — order-independent, self-healing bring-up
2. `is_strict()` by reading `$SNAP/meta/snap.yaml` — one codebase, two confinements
3. `use_snap_env()` (`utils.sh:1388-1413`) — rebuilds `PATH`/`LD_LIBRARY_PATH`/`PYTHONPATH`, probes for a
   usable locale (*"we cannot list system locales from snap"*), sets `XDG_RUNTIME_DIR=$SNAP_COMMON/run`
4. Absolute `$SNAP/...` paths for every coreutil — never trust host binaries
5. `$SNAP_COMMON` for refresh-surviving data vs `$SNAP_DATA` for per-revision config, with
   revision→`current` rewriting wherever a path escapes the snap
6. Build-time strict adaptation: `strict-patches/` only for strict builds; static runc/containerd
7. Group-based access control via a `system-usernames`-created group, re-applied continuously
8. Interface-gated teardown (`snapctl is-connected` in remove hooks) so cleanup degrades instead of erroring
9. **One `sudo` wrapper, not scattered `sudo` calls** — `run_with_sudo()` (`utils.sh:95-105`):
   `if (is_strict); then "$@"; else sudo --preserve-env="$(list_env_vars)" "$@"; fi`. Every privileged
   helper funnels through it. Contrast the previous draft's plan to delete `sudo` outright: that is fine for
   strict, but it also drops the `--preserve-env` behaviour on the **classic** path. Phase 1 task 2 therefore
   adopts this wrapper instead of deleting `sudo`.
10. **`snapctl` replaces the `snap` CLI entirely** — a confined process cannot invoke `snap`.
    `microk8s-stop.wrapper:43-47` switches `prefix_cmd` from `run_with_sudo snap` to `snapctl` under
    strict; same pattern at `microk8s-start.wrapper:50`, `utils.sh:405-407,519`,
    `scripts/wrappers/common/cluster/utils.py:383`, `scripts/wrappers/refresh_certs.py:82`

---

# Part 3 — External facts (verification status marked per section)

> **Status.** §3.1, §3.2, §3.3, §3.7, §3.8 and §3.9 are now **verified** — from snapd 2.77.1 source
> (`raw.githubusercontent.com/snapcore/snapd/2.77.1/...`), the Launchpad API, and direct measurement on
> this machine. §3.4 is **partially verified** (the fork-inheritance mechanism is confirmed; the
> containerd-shim case is not). §3.5 and §3.6 are in-tree facts verified against the repos.
> Remaining ⚠ items are marked individually.

## 3.1 snapd layout rules (`snap/validate.go`) — **VERIFIED**

> Verified against `snapcore/snapd` tag **2.77.1**, `snap/validate.go` (1556 lines).

`layoutRejectionList` (`:1072-1134`) — **cannot** be layout targets, and neither can anything underneath
them (enforced at `:1160-1165` via `mountedTree(path).IsOffLimits(mountPoint)` → error
`layout %q in an off-limits area`). All 16 entries, with snapd's own stated reasons:

| Entry | snapd's reason (abridged from the source comments) |
|---|---|
| `/dev` | essential device nodes |
| `/proc` | process metadata and kernel parameters |
| `/sys` | exposes kernel internals |
| `/media` | mounted with bi-directional mount event sharing |
| `/run`, `/var/run` | *"Providing view of the true /run allows snap applications to be integrated with the rest of the system"* |
| `/tmp` | contains a private, per-snap view of `/tmp` |
| `/var/lib/snapd` | essential snapd state, consulted from inside the mount namespace |
| `/lib/firmware`, `/usr/lib/firmware` | kernel searches the process's mount ns for firmware → attack vector |
| `/lib/modules`, `/usr/lib/modules` | modules must not be tamperable |
| `/var/snap` | would break `$SNAP_DATA`/`$SNAP_COMMON` content-interface connections |
| `/home` | contains `$SNAP_USER_DATA`/`$SNAP_USER_COMMON` |
| `/boot` | no known reason to allow |
| `/lost+found` | confusing, no valid reason |

Allowed top-level directories, verified verbatim at `:612-619` — a layout may not *create* a new one
(*"this list was produced by taking all of the top level directories in the core snap and removing the
explicitly denied top-level directories"*; error: `layout %q defines a new top-level directory %q`):

```
bin  etc  lib  lib64  meta  mnt  opt  root  sbin  snap  srv  usr  var  writable
```

Bind sources must start with `$SNAP`, `$SNAP_DATA` or `$SNAP_COMMON`; `user`/`group` may only be `root`.

**Consequences for this plan.** `/etc/kubernetes`, `/etc/cni/net.d`, `/etc/containerd`, `/opt/cni/bin`,
`/var/lib/containerd`, `/var/lib/kubelet`, `/var/lib/cni`, `/var/log/pods`, `/var/log/containers`,
`/var/log/kubernetes`, `/usr/libexec`, `/usr/local/lib` are all **legal** layout targets — and
`/etc/<dir>` layouts are not merely legal but used in production (§3.8). **`/run/containerd` is not a
legal target**, confirming D3. *Legal* is still not *appropriate*: a layout hides the path from the host
(§3.4, §3.7), so for any path a host-side consumer reads, the question remains whether a grant is better
(§5.2).

## 3.2 `docker-support` (`interfaces/builtin/docker_support.go`) — **VERIFIED**

> Verified against snapd **2.77.1**, `interfaces/builtin/docker_support.go` (892 lines).

- `dockerSupportServiceSnippet = interfaces.PlugServicesServiceSectionSnippet("Delegate=true")` (`:736`),
  wired in at `:888` → **snapd injects `Delegate=true` into the service unit when the plug is connected**.
  This is the D6 mechanism, now confirmed
- `KModConnectedPlug` auto-loads the `overlay` module (`:742-744`); `controlsDeviceCgroup: true` (`:887`)
- Base (unprivileged) AppArmor snippet grants, among much else:
  `/{,var/}run/containerd/{,s/,runc/,runc/k8s.io/,runc/k8s.io/*/} rw`,
  `/{,var/}run/containerd/runc/k8s.io/*/** rwk`,
  `/{,var/}run/containerd/io.containerd*/*/** rwk`, `/{,var/}run/containerd/s/** rwk`,
  `@{PROC}/[0-9]*/oom_score_adj w`, `@{PROC}/[0-9]*/attr/{,apparmor/}exec w`,
  `/sys/kernel/security/apparmor/.replace rw`, `/{,usr/}sbin/apparmor_parser ixr`,
  `change_profile … -> cri-containerd.apparmor.d`, `signal (send) peer=cri-containerd.apparmor.d`,
  `mount`, `umount`, `pivot_root`, `capability`, `/run/secrets/kubernetes.io/{,**} rk`,
  `/run/flannel/{,**} rk`, plus cgroup writes for `kubepods`. **This is what makes blocker 2
  (`apparmor_parser -r`) and the containerd profile load legal under strict**
- Privileged variant (`privileged-containers: true`) additionally grants `/dev/** mrwkl` and
  `@{PROC}/** mrwkl` (`:707-708`), `signal (send) peer=unconfined` + `ptrace (read, trace) peer=unconfined`
  (`:703-704`), and `@unrestricted` seccomp (`:733`)
- **Correction to the earlier draft.** `/** rwlix` and `change_profile unsafe /**` are **not literal
  rules**. In the source they are commented out (`:694`, `:718`) and emitted through
  `###EXCL{<> rwlix,:…}###` / `###EXCL{change_profile unsafe <>,:…}###` markers, expanded by
  `apparmor_sandbox.InsertAAREExclusionPatterns` in `AppArmorConnectedPlug` (`:750-815`). The generated
  rules cover everything **except** `/snap/{snapd,core}/*/usr/lib/snapd/snap-confine`, to avoid
  exec-transition conflicts with devmode snaps. Effect ≈ `/** rwlix`, but if a denial ever names a
  snap-confine path, this exclusion is why. The connect call also sets `SetSuppressHomeIx()`
  (LP #1797786) and `SetSuppressPycacheDeny()`
- **`baseDeclarationPlugs` is `allow-installation: false` *and* `deny-auto-connection: true`**
  (`:37-41`). This is **stronger than the earlier draft stated**: the store must approve the snap not
  only to auto-connect `docker-support` but **to be installed with the plug declared at all**.
  `--dangerous` local installs bypass assertions and are unaffected, so CI and development still work —
  but a store upload without a declaration fails outright. Same for `system-files` (§3.9). Phase 0 task
  0a must request *installation* permission, not just auto-connection

## 3.3 The four Launchpad bugs behind `network-requirements.sh` — **VERIFIED**

> Titles and statuses re-fetched from the Launchpad API (`api.launchpad.net/devel/bugs/<id>/bug_tasks`)
> on 2026-10-12. All four match what the earlier draft claimed. Importance is `Undecided` on all four.

| Bug | Title | Status | Consequence |
|---|---|---|---|
| [#2047798](https://bugs.launchpad.net/snapd/+bug/2047798) | Denial for `file_lock` on `/run/netns` with `network-control` | **Fix Committed** — snapd PR #13500, landed 2024-01-22, verified by Berkay Tekin Öz on snapd 2.61.1 (*"the issue seems to be resolved, we don't face the denial anymore"*) | Delete the `snap.k8s.containerd` sed patch; require snapd ≥ 2.62 |
| [#2053271](https://bugs.launchpad.net/snapd/+bug/2053271) | Denial for `/proc/$pid/task/$task/mountinfo` with `mount-observe` | **Fix Committed** — snapd PR #13601, *"will be fixed for 2.62"*. `mount-observe` extended upstream | Delete the `snap.k8s.k8sd` sed patch |
| [#2048506](https://bugs.launchpad.net/snapd/+bug/2048506) | Mounting bpf and cgroup2 under strict | **Won't Fix** — snapd: *"snap-confine itself will mount the latter if the snap has access to anything under /dev/* via interfaces"*; K8s team: *"Since snap-confine seems to mount these for us we don't need anything extra"* | Replace the manual `mount -t bpf` with an assertion |
| [#2048507](https://bugs.launchpad.net/snapd/+bug/2048507) | Changing `net.ipv4.conf.*.rp_filter` under strict | **Won't Fix** — snapd: *"The recommended workaround for now is to use system-files."*; K8s team: *"We will utilize the system-files interface"* — **never implemented** | Declare a `system-files` plug and do it inside the snap |

## 3.4 Pod namespace semantics — **PARTIALLY VERIFIED**

> **Verified mechanism.** Measured on this machine (snapd 2.77.1, strict `core22` snap): a plain forked
> child of a confined snap process **inherits the snap's mount namespace**. The confined parent shell and
> its background child both reported `mnt:[4026532931]`, against the host's `mnt:[4026531832]`, and the
> child saw the same `/etc` inode as the parent (`28573697/64513`). Mount namespaces are inherited at
> `fork(2)` and change only on explicit `setns`/`unshare`, so reparenting to PID 1 does not move a
> process out of the namespace.
>
> **Still unverified:** that `containerd-shim` specifically stays there. It double-forks and is reparented,
> and an attempt to measure a fully detached (`setsid`) child failed here because the child was reaped
> when `snap run` exited. The shim case needs a real strict k8s build — **Phase S task S3**.

`containerd-shim` is a child of the confined `containerd`, so on the verified mechanism above it inherits
the **snap's** mount namespace. Pod `hostPath` mounts would therefore resolve against the snap's layout
view, not the host's. Layouts would be sufficient for CNI/CSI/log paths; host symlinks unnecessary.
Conversely, snapd builds layouts as per-snap writable mimics over the read-only base — the **host** never
sees them.

**Two consequences.** (1) *The same property that makes layouts work for pods makes them hostile to the
host*: a user pod mounting `hostPath: /etc/kubernetes` (or any layout-shadowed path) silently receives
`$SNAP_COMMON/...`, and the host cannot see the path at all. (2) Under strict `/` is the base snap and
snapd makes a fixed set of host trees visible — **measured, see §3.7**. Host-visible: `/etc`, `/run`,
`/var/log`, `/var/snap`, `/home`, `/root`, `/mnt` (and `/tmp` as a private per-snap instance).
Base-owned: `/var/lib`, `/opt`, `/usr/*`, `/srv`. Where a host path is reachable, a grant keeps it
host-visible and no layout is needed; where it is not, a layout is the only option (or
`/var/lib/snapd/hostfs/...` for read-only diagnostics).

## 3.5 Channel-naming contradiction found in-tree

| Source | Strict channel shape |
|---|---|
| `.github/ISSUE_TEMPLATE/create_release_branch.md:44` | **bare track** — the store request already reads *"Could we please have a track \"1.xx-classic\" and \"1.xx\" for the respective K8s snap release?"*, i.e. the bare `1.xx` track **is** the strict track in the current release process |
| `tests/.../test_util/snap.py:40-45` | bare track `1.36/stable` (regex has no suffix for strict) |
| `tests/.../test_util/util.py:879-881` | `_get_flavor()` maps `"strict"` → `""` → bare track |
| `tests/.../test_util/util.py:840` | channel **branch** `latest/edge/strict` |
| `AGENTS.md:46` | `Channel format: {major}.{minor}-{flavor}/{risk}, e.g. 1.36-classic/stable` |
| `AGENTS.md:47` | `1.36-strict` |
| `.github/workflows/e2e-tests.yaml:151` | regex `^([0-9]+)\.([0-9]+)(-classic)?(/.*)?$` — it **already matches** the bare-track form `1.36/stable` and resolves `REF` correctly. It does **not** reject `1.36-strict`: it silently fails to match and falls back to `REF="main"` (pre-seeded at `:148`), collecting tests from the wrong branch — a quieter and worse failure than "rejects" suggests |
| `docs/canonicalk8s/reuse/substitutions.yaml:3` | `channel: '1.36/stable'` — **already a bare track**; validated by nothing (`test_k8s_version` reads only its `version` key) |

Four in-tree mechanisms (`snap.py`, `util.py`, the e2e regex, `substitutions.yaml`) **plus the release
checklist** are already internally consistent with **bare-track strict**. Only `AGENTS.md:46-47` and
MicroK8s convention (`tests/test-upgrade-path.py:60-61,67-68,79-81`, which uses `1.xx-strict`) point
the other way. **D9 is decided: bare track — see §5.1.**

Note one hazard that remains under the bare track: `util.py` has **three spellings** of the
`latest/edge` channel — `util.py:840` → `latest/edge/strict`, `snap.py:106,123` → the unmapped
`latest/edge/strict`, and `util.py:1037` → `f"latest/edge/{_get_flavor()}"` which yields the invalid
literal `"latest/edge/"` under strict.

## 3.6 Other verified facts

- runc: k8s-snap `v1.4.3`, normal patches `patches/{v1.1.12,v1.2.5}` (static-PIE on arm64);
  MicroK8s strict patches available for `v1.4.2` → selected for `v1.4.3` by the resolution algorithm
- containerd: k8s-snap `v2.3.3`, MicroK8s `v2.2.3`; **MicroK8s has no containerd strict patches**, so
  none are needed
- **`runc` is the only component with `strict-patches/`** in MicroK8s
  (`ls -d build-scripts/components/*/strict-patches` → `runc` only). The same is true in k8s-snap. It is
  **not** the only component with a `patches/` directory in either tree: k8s-snap has
  `kubernetes/patches`, `containerd/patches`, `cni/patches` and `runc/patches`; MicroK8s also applies
  `containerd/patches/v2.1.6/0001-microk8s-sideload-images-plugin.patch` to its v2.2.3 build and
  `runc/patches/default/0001-Disable-static-PIE-on-arm64.patch` unconditionally. The accurate statement is
  that containerd has no *strict-specific* patches
- `containerd-base-dir` is a **bootstrap/join-time** option only (CLI flag or config file, stored in
  the cluster DB): `docs/canonicalk8s/_parts/bootstrap_config.md:554`,
  `_parts/{control_plane,worker}_join_config.md`, `_parts/commands/k8s_{bootstrap,join-cluster}.md`.
  There is no snap-level default the snap can inject
- `k8sd`'s only in-snap configuration surface is `k8s/args/k8sd` (`--state-dir`) plus
  `${SNAP_COMMON}/args/<service>` and `args/{snap-env,<service>-env}` consumed by
  `k8s::common::execute` (`k8s/lib.sh:219-261`; the args/env-file-reading portion is `:227-247`; the doc
  comment at `:216-217` says `$SNAP_DATA` but the code reads `${SNAP_COMMON}`). Kubelet flags such as
  `--root-dir` appear nowhere in code (only in a sample `ps` output at `docs/.../epa.md:702`) because the
  external k8sd backend generates them
- `k8s/lib.sh:69-70` reads `/proc/sys/crypto/fips_enabled` and `wrappers/services/kube-proxy:10` reads
  `/proc/sys/net/netfilter/nf_conntrack_max`; both are procfs reads, expected to be fine under strict
- The snap's store default channel is currently `1.32-classic/stable`; strict channels could not be
  enumerated without the `Snap-Device-Series` header

## 3.7 Namespace facts **measured empirically** (not ⚠)

Measured on **2026-10-12** on this workstation: Ubuntu 24.04.5 LTS, **snapd 2.77.1**, probe snap
`bitwarden` (`confinement: strict`, `base: core22` — the same base as k8s-snap), via
`snap run --shell bitwarden`. Identity is `inode/device`; "HOST" means the inode matched the host's
exactly, "BASE" means it matched `/snap/core22/current/<path>`.

| Path | In-snap identity | Consequence for this plan |
|---|---|---|
| `/etc` | **HOST** (`28573697/64513`) — host-only entries `apt`, `apport`, `bluetooth`, `alternatives`, `anacrontab`, `avahi` are all visible; individual base files are overlaid on top (`/etc/os-release` reports `ID=ubuntu-core VERSION_ID="22"`) | `/etc/kubernetes`, `/etc/cni/net.d`, `/etc/containerd`, `/etc/sysctl.d` are **real host paths inside the snap**. A `system-files` grant keeps them host-visible; **a layout would hide them** |
| `/run` | **HOST** (`1/28`) | `/run/containerd` is host-visible — D3 holds |
| `/var/log` | **HOST** (`46923785/64513`) | `/var/log/kubernetes/audit.log` can stay host-visible with a grant (blocker 24); `/var/log/pods` + `/var/log/containers` are host paths, so layouts for them are a **choice**, not a necessity |
| `/var/snap` | **HOST** (`46923789/64513`) | `$SNAP_COMMON`/`$SNAP_DATA` as expected |
| `/home`, `/root` | **HOST** (`58982401/64513`, `34078721/64513`) | `home` / `home-read-all` behave as assumed |
| `/mnt` | **HOST** (`45350913/64513`) | — |
| `/tmp` | **HOST device, different inode** (`31719606` vs host `31719425`) → snapd gives the snap a **private** `/tmp` | MicroK8s's `/tmp` first-boot sentinel (§2.5) is per-snap, not the host's `/tmp` |
| `/sys/fs/bpf` | **HOST** (`1/34`) — already mounted | Supports LP #2048506's resolution: turn the manual `mount -t bpf` into an assertion (task 8) |
| `/sys/fs/cgroup` | **HOST** (`1/32`) | cgroup2 present without snap action |
| `/var/lib` | **BASE** (`14124/1827`; host is `46923783/64513`) | `/var/lib/kubelet`, `/var/lib/containerd`, `/var/lib/cni`, `/var/lib/kube-proxy` **must** be layouts (or reached via `hostfs`, below) |
| `/opt` | **BASE** (`789/1827`) | `/opt/cni/bin` must be a layout |
| `/usr/libexec` | **BASE** (`8624/1827`) | must be a layout |
| `/srv` | **BASE** (`819/1827`) | — |
| `/var/crash` | **absent / denied** in-snap (present on host) | Confirms blocker 18: the `/var/crash` harvest cannot work under strict |

**Two production precedents found on this machine, both strictly confined:**

1. **`system-files` can write to host `/etc`.** `canonical-livepatch` declares
   `etc-update-motd-d: {interface: system-files, write: [/etc/update-motd.d/99-livepatch-kernel-upgrade-required]}`,
   the plug is connected, and the file exists on the host
   (`-rwxr-xr-x 1 root root 275 … /etc/update-motd.d/99-livepatch-kernel-upgrade-required`).
   `firefox` likewise reads `/etc/firefox` via `system-files`. This is the mechanism D12's default relies on.
2. **Host paths that are *not* bind-mounted are reached via `/var/lib/snapd/hostfs/`.**
   `canonical-livepatch` uses `read: [/var/lib/snapd/hostfs/var/lib/dpkg]` and
   `firefox` uses `read: [/var/lib/snapd/hostfs/usr/share/hunspell]`. Measured: in-snap
   `/var/lib/snapd/hostfs/var/lib` has inode `46923783/64513` = **the host's `/var/lib`**. So the host's
   `/var/lib` *is* reachable, but only under that prefix — which is unusable for `kubelet --root-dir`,
   because the path escapes into pod specs and CSI sockets, but is worth knowing for diagnostics.

**What this does and does not settle.** It settles the host-vs-base question for every path in the plan,
and therefore most of D12. It does **not** settle: (a) whether a `system-files` grant permits *creating*
`/etc/kubernetes` — livepatch's grant is a single pre-existing file; (b) Ubuntu Core, where `/etc` is a
writable overlay and was not measured; (c) pod `hostPath` semantics (§3.4), which is independent; (d) the
`layoutRejectionList` of §3.1, still unread; (e) whether store review will grant `system-files` on
`/etc/kubernetes`. Phase S task S2 is narrowed to exactly (a)–(c).

Caveat on method: the probe snap's own plug set shapes AppArmor results. `stat`/existence tests succeeded
throughout, but `ls /etc/sysctl.d` was denied — absence of *listing* is not absence of the path.

## 3.8 The `docker` snap: a production strict precedent for this exact workload — **VERIFIED**

Found running on this machine: **`docker` 29.8.0, `confinement: strict`, `base: core24`**, with
`docker-support` declared twice — `support` (plain) and `privileged` (`privileged-containers: true`) — and
containerd plus runc inside it. This is the closest production analogue to what k8s-snap is attempting,
and it demonstrates the architecture works. What it actually does (read from
`/snap/docker/current/meta/snap.yaml` and the running process arguments):

| Aspect | What the docker snap does |
|---|---|
| State relocation | **By daemon flags, not layouts**: `dockerd --data-root=/var/snap/docker/common/var-lib-docker --exec-root=/run/snap.docker --config-file=/var/snap/docker/<rev>/config/daemon.json`; `containerd --config /run/snap.docker/containerd/containerd.toml`. `/var/lib/docker` **does not exist on the host at all** |
| Layouts | Only three, and one *is* over `/etc`: `/etc/docker` → `bind: $SNAP_DATA/etc/docker`; `/etc/gitconfig` → `bind-file:`; `/usr/libexec/docker/cli-plugins` → **`symlink:`** `$SNAP/usr/libexec/docker/cli-plugins` |
| `system-files` | **none** |
| `system-usernames` | none |
| Hooks | none |
| `dockerd` plug set | `removable-media, firewall-control, home, log-observe, network-bind, network-control, privileged, support, gpu-2404, graphics-core22` |
| `docker` (CLI) plug set | `docker-cli, network, home, removable-media` — the same client/daemon privilege split MicroK8s uses |
| Runtime dir convention | `/run/snap.docker` exists on the host (`drwxr-xr-x root root`), consistent with §3.7's `/run` = HOST finding |

**Four conclusions for this plan.**

1. **Layouts over `/etc/<dir>` are legal and shipped in production** (`/etc/docker`), independently
   confirming §3.1. Docker accepted that `/etc/docker` is not host-visible; we cannot, for
   `/etc/kubernetes`, without the doc/audit work in task 45 (§5.2).
2. **The mainstream pattern for container runtimes under strict is relocate-by-flag, not
   grant-for-host-visibility.** No `system-files` anywhere. This is a genuine counterweight to §5.2's
   recommended split and is reflected in the rebalanced D12.
3. **Docker can relocate because it owns its flags.** k8s-snap cannot do the same for `/etc/kubernetes`
   because the external k8sd generates those paths — which is precisely why 0c(ii) exists. The docker
   snap is the argument *for* doing the k8sd base-dir work rather than reaching for `system-files`.
4. **Privileged `docker-support` carries most of the weight, so plug sets can be small.** `dockerd` runs a
   full container runtime with privileged containers using **ten** plugs and **none** of
   `mount-observe`, `system-observe`, `process-control`, `kernel-module-observe`, `hardware-observe` or
   `kubernetes-support`. The 2024 patch's "identical heavy set" for five k8s services (§1.5) looks
   substantially over-provisioned; task 21's slimming should use this as the reference point.
   Caveat: docker is not Kubernetes — kubelet legitimately needs `kubernetes-support` for the kubelet
   flavor's mount/cgroup/`/proc/sys` rules — but it bounds the plausible minimum.

## 3.9 `system-files` semantics — **VERIFIED from source**

> `interfaces/builtin/system_files.go` and `interfaces/builtin/common_files.go`, snapd **2.77.1**.

Rule generation (`common_files.go`): `formatPath` runs `filepath.Clean(p)` then appends the literal
suffix `{,/,/**}`; `filesRead.String()` is `"rk"` (read + lock) and `filesWrite.String()` is `"rwkl"`
(read, write, lock, link). `AppArmorConnectedPlug` emits one line per declared path. So:

```
write: [/etc/kubernetes]   →   "/etc/kubernetes{,/,/**}" rwkl,
read:  [/etc/kubernetes]   →   "/etc/kubernetes{,/,/**}" rk,
```

**Therefore creation is permitted.** The generated rule covers the path itself, the path as a directory,
and everything beneath it, with `w`. Combined with §3.7's finding that in-snap `/etc` *is* the host's
`/etc`, a `system-files` `write:` grant is sufficient at the AppArmor-policy level for the snap to create
and populate `/etc/kubernetes` on the host. This largely answers what S2(a) was going to measure; what
remains is an end-to-end confirmation plus Ubuntu Core.

**Production precedent on this machine:** `canonical-livepatch` (strict) declares
`etc-update-motd-d: {interface: system-files, write: [/etc/update-motd.d/99-livepatch-kernel-upgrade-required]}`,
the plug is connected, and the file exists on the host
(`-rwxr-xr-x 1 root root 275 … /etc/update-motd.d/99-livepatch-kernel-upgrade-required`).
`firefox` reads `/etc/firefox` the same way.

**Validation constraints** (`validateSinglePath` + `validateSinglePathSystem`) — a declared path:
must start with `/`; may **not** contain `$HOME`; may not end with `/` or `@`; may not contain `~`; must
already be `filepath.Clean`; and must pass `apparmor_sandbox.ValidateNoAppArmorRegexp`, which **rejects
AppArmor regexp characters**. This confirms the plan's "exact paths, not globs" requirement — a plug
cannot declare `/etc/sysctl.d/*-k8s.conf`, so task 7's filename reconciliation with k8sd is mandatory,
not cosmetic. `BeforePreparePlug` also requires at least one valid `read` or `write` attribute.

**Store gate:** `systemFilesBaseDeclarationPlugs` is `allow-installation: false` +
`deny-auto-connection: true`. As with `docker-support` (§3.2), the store must approve **installation**,
not merely auto-connection. No snap on this machine uses `system-files` for anything as broad as
`/etc/kubernetes`; the examples are single files and small directories. Treat the review risk for a
`/etc/kubernetes` grant as **material**, and raise it early (0a).

---

# Part 4 — Gap analysis: blocker → strict resolution

| Blocker (§1.3) | Resolution |
|---|---|
| 1 `aa-exec -p unconfined` | guard with `! is_strict` (MicroK8s precedent, `run-containerd-with-args:10`) — Phase 1 task 5 |
| 2 `apparmor_parser -r` | **keep** — permitted by `kubernetes-support` + privileged `docker-support` (`.replace` + `mac_admin`); verify the binary is reachable from the base ⚠ (S4) |
| 3 host `PATH` fallback | drop the `REAL_*` tails under strict, **but only after S4 confirms what the base provides** — `findutils`, `grep`, `sed`, `gawk`, `gzip` are staged nowhere in the snap today; stage what is missing (task 10) |
| 4 `/etc/systemd/system` drop-in | skip under strict; `Delegate=true` from `docker-support`; rlimits + `oom_score_adj` in the wrapper; `TasksMax` → porting requirement (tasks 4, 5) |
| 5a `/etc/sysctl.d/[0-9]+-k8s.conf` removal | files are written by the external **k8sd**, so a `system-files` plug must declare the *exact* paths and the removal regex must stay in sync. **Requires a companion k8sd change** — Phase 0 task 0c, Phase 1 tasks 3 and 7 |
| 5b `/etc/sysctl.d/1000-cilium.conf` + distro-file edits | write `/proc/sys` directly (MicroK8s approach), persist the one file through `system-files`, **stop editing `/usr/lib/sysctl.d/`** — task 7 |
| 6 `--make-rshared` on `/var/lib/kubelet` | already implemented and strict-gated (`k8s/lib.sh:273-280`) |
| 7 `modprobe` | `kernel-module-observe` + `cilium-module-load` (`kernel-module-load` ⚠ — syntax unverified); `docker-support` auto-loads `overlay` (**verified**, §3.2 `KModConnectedPlug`) |
| 8 `/etc/kubernetes` | **decided by S6 (D12)** — *not* a layout by default: a layout hides it from the host and breaks a CI gate, a published path contract and seven test call sites |
| 9 `sudo` | funnel through a `run_with_sudo` wrapper (strict: run directly; classic: `sudo --preserve-env`); do not delete — task 2 |
| 10 `systemctl`/`journalctl`/`snap` | `snapctl services` + `journalctl -u snap.k8s.*` via `log-observe`; skip the rest — task 9 |
| 11 `OPENSSL_MODULES` | repoint to `/usr/lib/<triplet>/ossl-modules-3/` (S1) |
| 12 snapd AppArmor sed | delete — both bugs **Fix Committed** (verified, §3.3) — task 8 |
| 13 hardcoded `/snap/k8s/current`, `/var/snap/k8s/common` | use `$SNAP_CURRENT` / `$SNAP_COMMON` — task 6 |
| 14 host utilities | stage whatever the base lacks in `bash-utils` (S4 → task 10); `ip{,6}tables-legacy*` are already built by our own iptables part |
| 15 bpffs/cgroup2 mount | assertion only — `/sys/fs/bpf` and `/sys/fs/cgroup` **measured present** inside a strict snap (§3.7) — task 8 |
| 16 unguarded `sudo rm -rf "$SNAP_COMMON/etc"` | wrapper (task 2); hooks already run as root |
| 17 hardcoded `snap.k8s.containerd` unit name | use `snap.${SNAP_INSTANCE_NAME}.containerd`; moot under strict once task 4 skips the drop-in, but fix it for classic parallel instances |
| 18 host-wide core dumps (`/var/crash`, `GOTRACEBACK=crash`) | `/var/crash` is not granted by any plug — collect from `$SNAP_COMMON` under strict, or drop the harvest (task 9) |
| 19 extra `inspect.sh` host collection | skip under strict per §2.9 (task 9) |
| 20 `connect-interfaces.sh` runs the host `snap` CLI | unavoidable — keep it an **out-of-snap** script, invoked by `init.sh` from a host shell; never from a hook (task 25) |
| 21 `hostname` / `ip route show default` | `hostname` is staged (`bash-utils`); `ip route` needs `network-observe` |
| 22 build-time `snap refresh go` (runc **and** containerd) | stop mutating the builder (task 29) |
| 23 ELF interpreter/RPATH retargeting | LIEF pass becomes a no-op under strict, decided at build time (D10; S1, task 18) |
| 24 `/var/log/kubernetes/audit.log` | covered by S6/D12 — a CI-run doc test asserts it from the host (task 15) |
| 25 `k8s/pebble` | exclude from the strict build or drop (task 16) |
| `/run/containerd` (not layout-able — §3.1) | granted by `docker-support`'s base AppArmor snippet (**verified**, §3.2); `/run` is host-visible (§3.7) |
| `/etc/containerd`, `/var/lib/containerd` | **decided by S6** — `/etc/containerd` is a host-visible `/etc` path with host consumers (`test_cleanup.py`, `dev-env.md`, `offline.md`); `/var/lib/containerd` is base-owned |

> ⚠ Items still marked ⚠ depend on snapd behaviour that remains unverified. Most of Part 3 is now
> verified from snapd 2.77.1 source, the Launchpad API, and direct measurement — see the Part 3 banner.

---

# Part 5 — Decisions

| # | Decision | Status |
|---|---|---|
| D1 | Deliver via the **flavor-patch** model: `build-scripts/patches/strict/{apply,0001-strict.patch}`. The patch touches `snap/snapcraft.yaml`, `k8s/hack/init.sh` and the new `connect-plug-*` symlinks; every runtime difference lives on the classic branch behind `is_strict()`, and the one build-time difference (ELF patching) is gated by D10 | Unchanged. Rationale: CI (`build-snap.yaml:38-43`), channel naming, `autoupdate/*-strict` branches and `print-patches-for.py` already assume it; a minimal patch is what the 2024 attempt got wrong |
| D2 | **Rescoped.** No k8sd code changes for **path** redirection *if and only if* Phase S shows host paths stay reachable under grants. The sysctl write (`/etc/sysctl.d/[0-9]+-k8s.conf`, written by k8sd, only *removed* by `k8s/lib.sh:98-107`) requires a k8sd companion change regardless. Verified: `--root-dir`, `--volume-plugin-dir`, `--cgroup-driver` appear nowhere in k8s-snap code; `k8s/args/` contains only `k8sd`; kubelet args come from the external k8sd | Conditional on S6 |
| D3 | `/run/containerd` needs no layout: `/run` is **not a legal layout target** (§3.1) and is host-visible (§3.7), with access granted by `docker-support`'s base snippet (§3.2). `containerd-base-dir` stays optional — see D11 | **Verified** |
| D4 | Store auto-connect declaration **and** the MicroK8s health gate (`install-mode: disable` + `connect-plug-*` → `configure` + `set-health blocked`), because super-privileged plugs never auto-connect for `--dangerous`/local installs, which is how CI and developers install | Unchanged |
| D5 | Drop both snapd AppArmor `sed` workarounds (both bugs Fix Committed, §3.3); bpffs becomes an assertion (both mounts measured present, §3.7); `rp_filter` moves inside the snap. **No MicroK8s precedent** for `system-files` or `kernel-module-load` (zero occurrences repo-wide, verified), but `system-files` semantics are now **verified from source** (§3.9) and in production use on this machine. `kernel-module-load`'s attribute syntax remains unvalidated ⚠ (S4); MicroK8s's direct `/proc/sys` write + best-effort dual `modprobe` is the fallback | Partly verified |
| D6 | No systemd drop-in under strict: `Delegate=true` from `docker-support` (**verified** — `dockerSupportServiceSnippet`, §3.2), rlimits + `oom_score_adj` in the containerd wrapper, `TasksMax` logged as a porting requirement. The user-facing proxy surface moves to `$SNAP_COMMON/args/containerd-env` (task 4a) | Confirmed |
| D7 | Root-only CLI, as classic. No `system-usernames`, no `personal-files`. `k8s config` already emits a kubeconfig to **stdout** (`docs/.../_parts/commands/k8s_config.md:3-7`; every consumer redirects it), which is the host-safe credential path | Unchanged, now evidenced |
| D8 | Full default feature set; Ubuntu Core included in validation; FIPS, GPU operator and non-root CLI out of scope | Unchanged |
| D9 | **Channel naming: bare track `1.36/stable`** | **DECIDED** — §5.1 |
| D10 | **New, PROPOSED (not yet confirmed by the requester).** The LIEF ELF patching stays, but becomes a **no-op under strict**, decided at build time by reading `confinement:` from `snap/snapcraft.yaml` — the same test `print-patches-for.py:14` already uses. Keeps D1's patch minimal | Proposed; S1 measures both ways |
| D11 | **New, PROPOSED (not yet confirmed by the requester).** `containerd-base-dir` under strict must **fail fast with an actionable error** when the requested directory is unreachable from the confined snap, rather than being silently denied by AppArmor. Whether any non-default value is supportable depends on S2 | Proposed; conditional on S2 |
| D12 | **New.** Host-path strategy. §3.7 now answers the measurable part; the remaining judgement is confirmed in **S6** — see §5.2 | **Largely measured; final call in Phase S** |

## 5.1 D9 — bare track (decided)

Four in-tree mechanisms plus the release runbook already implement it, so it costs **zero code changes**:
`create_release_branch.md:44` (verbatim: *"Could we please have a track "1.xx-classic" and "1.xx" for the
respective K8s snap release?"*), `snap.py:40-41`, `util.py:879-881,945`, `e2e-tests.yaml:151`, and
`substitutions.yaml:3`. Against it: `AGENTS.md:46-47` only, plus MicroK8s's `1.xx-strict` convention.
Amend `AGENTS.md:46-47` (Phase 4 task 34). **Accepted downside, to be documented prominently:**
`snap install k8s --channel=1.36` yields strict for users who merely omit `-classic`.

The alternative (`1.36-strict`) would have required changing `snap.py:40-45`, `util.py:879-881,945`, the
`e2e-tests.yaml:151` regex (whose failure mode is silent — `REF` falls back to `main`),
`substitutions.yaml:3` and `create_release_branch.md:44`.

## 5.2 D12 — host-path strategy

**The mechanics are now settled by measurement and source reading, and they cut both ways.**

*What makes host visibility possible:* `/etc`, `/run` and `/var/log` inside a strict core22 snap **are**
the host's (§3.7); a `system-files` `write:` grant generates `"<path>{,/,/**}" rwkl` and therefore permits
creating and populating the directory (§3.9); and a strict snap writing to host `/etc` via that grant is
shipping in production (`canonical-livepatch`). `/var/lib`, `/opt` and `/usr/*` are base-owned and need
layouts regardless.

*What argues against leaning on it:* the production strict snap that most resembles us — **`docker`, with
containerd, runc and privileged `docker-support`** — uses **no `system-files` at all** (§3.8). It
relocates state with daemon flags and accepts a `/etc/docker` layout, so `/var/lib/docker` does not exist
on the host. And `system-files` is gated by `allow-installation: false`, so the store must approve
installation itself; nothing on this machine uses it for a tree as broad as `/etc/kubernetes`.

So this is not a technical question any more — it is a **product question**: do we keep the published
host-path contract, or do we follow the mainstream pattern and republish the paths?

| Option | Mechanism | Cost |
|---|---|---|
| **A — keep the contract** | `system-files` `write:` for `/etc/kubernetes`, `/etc/cni/net.d`, `/etc/containerd`, the exact sysctl filenames, `/var/log/kubernetes`; layouts only for `/var/lib/*`, `/opt/cni/bin`, `/usr/libexec`, `/usr/local/lib` | Material store-review risk on a broad `/etc/kubernetes` grant (§3.9); diverges from the docker/MicroK8s pattern; still needs task 45 for the `/var/lib` relocations |
| **B — follow the precedent** | k8sd gains base-dir options (0c(ii)); everything moves under `$SNAP_COMMON`/`$SNAP_DATA`; layouts where a fixed path is unavoidable | Full task 45: rewrite `cis-audit.md`, `disa-stig-audit.md`, `certificates.md`, `kubectl.md` **and the external kube-bench `ck8s` config**; breaks the CI gate until done; k8sd work is on another release train |

**Recommendation: A for `/etc/**` and `/var/log/kubernetes`, B for everything base-owned** — i.e. keep
the compliance-visible paths where they are, relocate what must move anyway, and open the store
conversation early (0a) so the review risk surfaces before the work is sunk. If the store refuses, fall
back to B wholesale; S6 is the decision point and 0c(ii) must be raised in parallel either way so B
remains available.

Either way, `/var/lib/kubelet`, `/var/lib/containerd`, `/var/lib/cni`, `/var/lib/kube-proxy`,
`/opt/cni/bin`, `/usr/libexec` and `/usr/local/lib` are base-owned and **must** relocate, so the
doc/test/audit work for *those* paths is unconditional.

| Paths | Mechanism | Host-visible? |
|---|---|---|
| `/etc/kubernetes`, `/etc/cni/net.d`, `/etc/containerd`, `/etc/sysctl.d/<exact files>`, `/var/log/kubernetes` | `system-files` (option A) or relocation (option B) | A: **yes**; B: no |
| `/run/containerd` | `docker-support` base snippet (§3.2) — and `/run` is not a legal layout target (§3.1) | **yes** |
| `/var/lib/kubelet`, `/var/lib/containerd`, `/var/lib/cni`, `/var/lib/kube-proxy`, `/opt/cni/bin`, `/usr/libexec`, `/usr/local/lib` | `layout:` → `$SNAP_COMMON/...` | **no** — unconditional doc/test/audit work |
| `/var/log/pods`, `/var/log/containers` | host tree — prefer **no layout** so `kubectl logs` tooling and log shippers keep working | caller's choice |
| `/etc/nanorc` | `bind-file` layout | no |

This is why the choice matters: host-side consumers a layout over `/etc/kubernetes` (etc.) would break:

| Consumer | Evidence |
|---|---|
| **CI gate** — host `kube-bench`, asserted `0 checks FAIL` | `docs/tools/scenarios.yaml:2-6` → `snap/howto/security/cis-assessment.md:148-150` |
| Compliance reference pages: hundreds of host `stat`/`find` on `/etc/kubernetes/**` | `snap/reference/cis-audit.md:356-577,2182-2331`; `snap/reference/disa-stig-audit.md:1152-3633` |
| Published host path contract | `snap/reference/certificates.md:33-42,55-68`; `snap/tutorial/kubectl.md:41-44,54-59` |
| Unconfined host `helm` given a host kubeconfig (5 sites) | `tests/integration/tests/test_version_upgrades.py:345-347,391-393,438-440,522-524,579-581` |
| Unconfined host `curl` given host etcd PKI (2 sites) | `tests/integration/tests/test_util/util.py:1747-1751`; `test_clustering.py:167-171` |
| Dual-path cert-dir probe (already anticipates relocation) | `test_clustering.py:819-828` (falls back to `/var/snap/k8s/common/etc/kubernetes/pki/`) |
| CI-run doc test, host `ctr --address /run/containerd/containerd.sock` | `snap/howto/image-management.md:49,67-73` |
| CI-run doc test, host `rm /etc/cni/net.d/*.conflist` | `snap/howto/networking/alternative-cni.md:48,145` |
| CI-run doc test, host `test -f /var/log/kubernetes/audit.log` | `snap/howto/security/hardening.md:150,159,170` |
| CI-asserted host `stat` on `/etc/systemd/system/snap.k8s.kubelet.service` | `snap/howto/security/hardening.md:382-391` |
| **CI-run doc test + test writing the containerd systemd drop-in** — `trap 'sudo rm -rf /etc/systemd/system/snap.k8s.containerd.service.d; sudo systemctl daemon-reload' EXIT` (`proxy.md:13`), `sudo mkdir -p` (`:26`), `sudo tee …/http-proxy.conf` (`:39`); `offline.md:144` documents the same file; `test_airgapped.py:63,65` writes it | `proxy.md:9` declares `SPREAD SUITE: snap_bootstrapped`, so this executes in CI |
| Host `etcdctl` / `openssl` on `/etc/kubernetes/pki/**` | `snap/howto/restore-quorum.md:93-102`; `security/refresh-certs.md:50`; `security/intermediate-ca.md:64-68` |
| Host `mount` output greps | `tests/integration/tests/test_util/util.py:385-390` |
| Host assertions on containerd/CNI paths | `test_cleanup.py:14-21,47-48,89-91,155-165`; `dev-env.md:29-30`; `offline.md:277-315` |
| Pod `hostPath` identity between host and pod | `tests/integration/templates/multus-cni-setup.yaml:175-176,185,190,227,248,254` |

Already host-safe, and the model to copy: `k8s config` (stdout), `k8s kubectl` (`k8s/lib.sh:140`, runs
in-namespace), `inspect.sh` (touches no credential path — it goes through the `k8s` app), the k8sd
unix-socket CAPI contract (`test_smoke.py:65-111`), and the charm's `get-kubeconfig` action. The CAPI and
charm credential paths documented in this repo are stdout/API-mediated, **not** `admin.conf`.

---

# Part 6 — Implementation plan

## Phase S — strict spike (gates everything else)

Goal: a `--dangerous`-installable strict snap on an AppArmor-enforcing host, plus two measured artefacts —
a **host-visibility matrix** and a **per-app denial inventory** — that resolve D2, D3, D11, D12 and size
the store request.

**S1. Make a strict build possible.** Nothing in-tree can produce one today.
- Create `build-scripts/patches/strict/apply` (a `git am` wrapper, modelled on `origin/strict/main`) and
  `0001-strict.patch`. `build-snap.yaml:38-43` invokes `./build-scripts/patches/"$INPUT_FLAVOR"/apply`;
  `build-scripts/patches/` does not exist, so the whole flavor mechanism is dead code.
- Flip `snap/snapcraft.yaml:10` to `confinement: strict`. `print-patches-for.py:14` keys off that literal
  text, so without it a manual `snapcraft` build silently produces a classic snap with no strict patches.
- Port `microk8s/build-scripts/components/runc/strict-patches/v1.4.2/` (3 patches, 2026-rebased) into
  `k8s-snap/build-scripts/components/runc/strict-patches/v1.4.2/`; delete the stale
  `{v1.1.5,v1.1.12,v1.1.13}`. With runc at `v1.4.3` the resolution algorithm selects `v1.1.13`, whose `0002`
  patch cannot apply (§1.4).
- **Fix `print-patches-for.py:104`**: use `sorted(...)` on the `iterdir()` — the three runc strict patches
  are an order-dependent series.
- Verify `./build-scripts/print-patches-for.py runc "$(cat build-scripts/components/runc/version)"` prints
  exactly `patches/v1.2.5` + `strict-patches/v1.4.2` (before the change it prints
  `patches/v1.2.5` + `strict-patches/v1.1.13`).
- **D10**: gate the LIEF `override-prime` blocks (`snapcraft.yaml:71-83` etcd; `:161-175` containerd, `ctr`,
  `containerd-shim-runc-v2`) so they are no-ops under strict. Build both ways and record which runs.
- Repoint `OPENSSL_MODULES` (`snapcraft.yaml:21`) to `/usr/lib/$CRAFT_ARCH_TRIPLET_BUILD_FOR/ossl-modules-3/`.
  Every Go component builds with `GOEXPERIMENT=opensslcrypto`, so a wrong value is a silent
  crypto-backend failure.
- Spike only: give every app a maximal plug set, add **no** layouts, and connect everything with
  `snap connect` from a host shell.

**S2. Close the gaps the measurements left open.** The host-vs-base identity of every path in this plan
has **already been measured** (§3.7), `system-files` rule generation has been **read from source** (§3.9),
and `layoutRejectionList` is **confirmed** (§3.1) — do not re-derive any of it. What remains:
- **(a) End-to-end create under a grant.** §3.9 shows the AppArmor rule permits creation, and
  `canonical-livepatch` proves host-`/etc` writes work for a pre-existing file. Confirm the full path:
  a connected `system-files` `write:` plug lets the confined snap **create** `/etc/kubernetes/`,
  `/etc/cni/net.d/`, `/etc/containerd/` and `/var/log/kubernetes/` when absent, with correct ownership,
  visible on the host. Include the exact sysctl filenames from task 7 — §3.9 proves globs are rejected.
- **(b) Ubuntu Core.** `/etc` is a writable overlay there and was not measured; repeat the §3.7 probe on
  a Core VM.
- **(c) `docker-support`'s effective filesystem grant.** §3.2 confirms the rule exists but is emitted via
  AARE exclusion patterns. Confirm it really removes the need for per-path grants on `containerd`,
  `kubelet` and `kube-proxy`, and watch for denials naming `/snap/{snapd,core}/*/usr/lib/snapd/snap-confine`.
- **(d) Store appetite** for a `/etc/kubernetes` `system-files` grant — not a measurement but a
  conversation; it decides between options A and B in §5.2 and belongs in 0a.
Method that worked for §3.7: `snap run --shell <snap> -c '…'` comparing `stat -c %i/%d` against the host
and against `/snap/core22/current/<path>`.

**S3. Pod namespace semantics.** §3.4 (containerd-shim inherits the snap's mount namespace) is unverified
and load-bearing. Run a pod mounting `hostPath` for `/etc/kubernetes`, `/var/lib/kubelet`, `/opt/cni/bin`
and a control path such as `/srv/spike`; diff each against the host and against `$SNAP_COMMON`. The result
determines whether the 8 opaque bundled Helm charts and `multus-cni-setup.yaml` can work with layouts at all.

**S4. Base/runtime assumptions.** Record each result; any failure becomes a porting requirement.
- `apparmor_parser` reachable from the base — else stage the apparmor userspace in `bash-utils`
- `/sys/fs/bpf` and cgroup2 provided by `snap-confine` once a `/dev`-granting plug is connected
- `journalctl` via `log-observe`; `snapctl services` as the `systemctl` replacement
- whether a service can raise `pids.max` on its own cgroup (the `TasksMax` question)
- which of `find`, `xargs`, `grep`, `sed`, `awk`, `gzip`, `hostname`, `findmnt`, `mount`, `modprobe` the
  base provides. `bash-utils` (`snapcraft.yaml:184-222`) is the **only** part with `stage-packages`
- that the `system-files` and `kernel-module-load` attribute syntaxes validate against snapd

**S5. Denial inventory on enforcing AppArmor.** Must be a VM or bare metal: `tests/integration/
lxd-profile.yaml:5,9-10` sets `lxc.apparmor.profile=unconfined`, `security.nesting` and
`security.privileged`, and `harness/lxd.py:119-122` always applies that base profile in addition to any
network overlay, so no existing substrate can see a denial. Record `aa-status` as proof. Run bootstrap →
`status --wait-ready` → pod create/exec/logs/delete under `snappy-debug`, and produce a per-app denial
list. This is the input to plug slimming for `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`.

**S6. Decide and publish D2/D3/D11/D12.** §3.7 already fixes the mechanics; this task confirms the split
recommended in §5.2 against S2(a)–(c) and S5, then records it. Decision rule per path:
- reachable + writable/creatable with a grant → **no layout**, keep host-visible, add the exact path to the
  `system-files` `write:` list
- not reachable → **layout + relocation**, and register the dependent doc/test/audit updates from §5.2
Deliverables: the final `layout:` list, the final `system-files` list, the per-app plug sets, the list of
host-side consumers that must change, and whether any non-default `containerd-base-dir` is supportable.
Only then finalise 0a.

**If S2(a) fails** — i.e. `system-files` cannot create the directories — the fallback is relocation into
`$SNAP_COMMON` plus task 45's full doc/audit rewrite, and the k8sd base-dir work in 0c(ii) becomes
mandatory rather than conditional.

## Phase 0 — long-lead items

**0a. Store snap-declaration.** Open the conversation immediately; submit the final list after S6.
**Both `docker-support` and `system-files` are `allow-installation: false` as well as
`deny-auto-connection: true`** (§3.2, §3.9), so the store must approve the snap **to be installed with
those plugs declared at all**, not merely to auto-connect them. `--dangerous` bypasses assertions, so CI
and development are unaffected, but a store upload without a declaration fails outright. Covers
`docker-support` (privileged + unprivileged), `kubernetes-support` (plain + `kubelet` + `kubeproxy`),
`home` with `read: all`, `system-files`, `kernel-module-load`. Check whether a declaration already exists
from the 1.32/1.33-strict era. Slim the three control-plane apps using S5's inventory **before**
submitting — §3.8 shows a full container runtime with privileged containers ships with ten plugs, so the
2024 heavy set is a weak starting point. **Raise the `/etc/kubernetes` `system-files` grant explicitly and
early**: it is the deciding input for §5.2's option A versus B, and no precedent on record asks for a tree
that broad.

**0b. Register the bare `1.36` track** (D9 decided). Confirm whether `1.32`/`1.33` strict used the bare
track, for the upgrade-path tests.

**0c. k8sd companion issues** — a second long-lead item on a separate release train: (i) host sysctl
files: either stop writing `/etc/sysctl.d/[0-9]+-k8s.conf` or write one fixed filename the snap can declare
in `system-files` and keep `k8s::remove::system_tuning`'s removal in sync with; (ii) whatever base-dir/flag
changes S6 implies; (iii) make the chart-values contract for CNI and containerd-socket paths explicit, since
the 8 bundled `.tgz` charts cannot be inspected or patched in-tree.

## Phase 1 — classic-branch runtime changes (`is_strict`-guarded, no-ops for classic)

1. **`k8s::common::setup_env` (`k8s/lib.sh:7-32`)** — under strict build `PATH`/`LD_LIBRARY_PATH` from
   `$SNAP_CURRENT` and the base only, dropping the `$REAL_PATH`/`$REAL_LD_LIBRARY_PATH` tails (`:15-16`).
   Keep the locale probe (`:23-29`). **Gated on S4**: do not drop the tail before confirming the base
   provides `grep`/`sed`/`awk`/`find`/`xargs`/`gzip`, or `inspect.sh` and `sanitize_feature_gates` fail in
   ways that look like AppArmor denials.
2. **Funnel `sudo` through one wrapper, do not delete it.** Occurrences: `k8s/lib.sh:104,105,112,119,123`;
   `:112` is unconditional and `sudo` is not staged (`snapcraft.yaml:36` is `build-packages` only), so it
   cannot work under strict nor on Ubuntu Core. Adopt MicroK8s's `run_with_sudo()` (`utils.sh:95-105`).
   Deleting `sudo` outright would drop `--preserve-env` on the classic path.
3. **`/etc/sysctl.d` cleanup** (`k8s/lib.sh:97-108`, `:116-126`) — remove the `! is_strict` guards once
   task 7 lands so strict cleans up after itself. Under strict the cleanup is **exact-path only** (the
   `find … -regex '.*/[0-9]+-k8s\.conf'` at `:100` cannot be used); keep the classic regex path as-is.
4. **`k8s::containerd::ensure_systemd_defaults` (`k8s/lib.sh:290-300`)** — wrap in `! is_strict`, and fix two
   pre-existing classic bugs: no `systemctl daemon-reload` anywhere in the repo, so the drop-in only takes
   effect at the next reload; and `:293` hardcodes `snap.k8s.containerd`, breaking parallel instances — use
   `snap.${SNAP_INSTANCE_NAME}.containerd`, as `k8s/wrappers/services/k8sd:6` already does.
   The drop-in it installs (`k8s/systemd/containerd-defaults.conf`, 11 lines) is
   `Delegate=yes`, `LimitNPROC=infinity`, `LimitCORE=infinity`, `LimitNOFILE=infinity`,
   `TasksMax=infinity`, `OOMScoreAdjust=-999`. Strict must reproduce each: `Delegate` comes from
   `docker-support` (verified, §3.2), the three `Limit*` become `ulimit` calls and `OOMScoreAdjust` an
   `/proc/self/oom_score_adj` write (task 5), and **`TasksMax=infinity` has no strict equivalent** — it is
   the Part 7 porting requirement, measured in S4.
4a. **Replace the drop-in as the *user-facing* configuration surface.** The systemd drop-in directory is
   not only written by us, it is the documented way users set containerd's proxy
   (`snap/howto/networking/proxy.md:26,36,39` — a **CI-executed** doc test, `SPREAD SUITE:
   snap_bootstrapped` at `:9`, with `trap 'sudo rm -rf /etc/systemd/system/snap.k8s.containerd.service.d;
   sudo systemctl daemon-reload' EXIT` at `:13`), referenced by
   `snap/howto/install/offline.md:144`, and written by `tests/integration/tests/test_airgapped.py:63,65`.
   Under strict that mechanism disappears. **The replacement already exists in-tree and needs no new
   code**: `k8s::common::execute` loads `${SNAP_COMMON}/args/snap-env` (`lib.sh:237-240`) and
   `${SNAP_COMMON}/args/${service_name}-env` (`:244-247`), validates them (`:250`), and applies them with
   `exec env -S` (`:257`) — service-specific overriding global. So the strict proxy surface is
   `$SNAP_COMMON/args/containerd-env`, which is exactly MicroK8s's `default-args/containerd-env` pattern
   (§2.5). Document it (task 44), make `proxy.md` and `offline.md` flavor-aware (task 45a), and make
   `test_airgapped.py` use it under strict (task 39). Note `lib.sh:217`'s comment says `$SNAP_DATA/args/...`
   while the code reads `${SNAP_COMMON}/args/...`; fix the comment while here.
5. **`k8s/wrappers/services/containerd`** — put the `aa-exec -p unconfined` re-exec (`:26`, guard `:25-27`)
   behind `! is_strict` rather than deleting it. For strict add `ulimit -n`/`-u`/`-c` mirroring the drop-in
   (MicroK8s `default-args/containerd-env:29,34`) and `echo -999 > /proc/self/oom_score_adj`. Keep the
   `apparmor_parser -r` call at `:11` and its warning.
6. **Hardcoded paths → `$SNAP_COMMON`/`$SNAP_CURRENT`** — `k8s/lib.sh:307`, `:321,:323`;
   `k8s/scripts/inspect.sh:87,103,153-156`; `k8s/pebble/pebble.service:6,11-15`.
7. **New `k8s::util::apply_sysctl_tuning`**, called from `snap/hooks/configure` — apply
   `net.ipv4.conf.*.rp_filter = 0` by writing `/proc/sys/...` directly (MicroK8s `run-kubelite-with-args:
   241-245`) and persist through `system-files`. Reconcile the filename first: `network-requirements.sh:31`
   writes `/etc/sysctl.d/1000-cilium.conf`, while k8sd writes `/etc/sysctl.d/[0-9]+-k8s.conf` which
   `lib.sh:100` only removes. Stop editing distro-owned `/usr/lib/sysctl.d/` (`:30`) — a `1000-` prefix
   already sorts last. Depends on 0c(i) and S6.
8. **`k8s/hack/network-requirements.sh`** — delete the two `sed` + `apparmor_parser` blocks (`:34-41`, obsolete
   per LP #2047798/#2053271, both **Fix Committed** — verified §3.3) and the `rp_filter` block (`:27-32`, now task 7); turn the bpffs mount
   (`:17-25`) into an assertion with an actionable message; keep the cgroup2 assertion (`:10-15`).
   **Nothing in-tree invokes this script today** — review it as new code, not working code.
9. **`k8s/scripts/inspect.sh` strict branches** per §2.9. `systemctl` is at `82,168,171,183`; `:141-144` are
   `snap` commands; `:179,:188` are `journalctl`. Use `journalctl -k` instead of `dmesg -H` (`:133`), and
   skip `lsmod` (`:130`), `swapon` (`:121`), `ss -plnt`/`-plntu` (`:210,214`), `cp /proc/mounts` (`:115`),
   `cp /etc/os-release` (`:127`), `grep … /etc/environment` (`:215`) and the `/var/crash` harvest
   (`:36,193-202`). Port MicroK8s's service-name prefixing split (`scripts/inspect.sh:502-512`).
   **Do not** skip `iptables-legacy-save`/`ip6tables-legacy-save` (`:209,213`) — our iptables part builds
   the legacy backends and both calls are `|| true`-guarded. **The strict branch must not depend on
   `lib.sh` having been sourced**: `inspect.sh` does not source it, and `conftest.py:51-63` runs it by
   absolute host path.
10. **`bash-utils` staging** per S4. The part has no `prime:` block so everything it stages also primes;
    `nano` already ships (`:202`), so the only open question is whether `/usr/share/nano` is needed given
    `-usr/share` at `:222`.
11. **`k8s/hack/connect-interfaces.sh:10-33`** — regenerate from the final **plug-name** set (not interface
    names; ideally generated from `snapcraft.yaml`, see task 23). All 18 current entries name plugs that do
    not exist. Keep it a **host-shell** script: `:32` runs `bash -c "snap connect 'k8s:${if}'"` and a
    confined process cannot invoke `snap`. Rename the loop variable, which is literally `if`.
12. **Delete dead code** — `k8s/wrappers/commands/dqlite` (calls a nonexistent `k8s::cmd::dqlite`, not
    declared as an app) and the `k8s-dqlite` service in `k8s/pebble/000-k8s.yaml:13-17`.
13. **`chmod +x snap/hooks/pre-refresh snap/hooks/post-refresh`** — both are `-rw-rw-r--` while `install`,
    `configure` and `remove` are `-rwxrwxr-x`. snapd silently does not run a non-executable hook, so the
    1.36 k8s-dqlite guard at `post-refresh:10-14` has probably never fired. Pre-existing bug; add a CI check
    for hook permissions.
14. **`k8s/profiles/containerd`** — add the missing
    `signal (send,receive) peer=cri-containerd.apparmor.d//&unconfined,` rule (MicroK8s
    `containerd-profile:46`). Keep k8s-snap's broader 5-peer `signal (receive)` list (`:38-42`). Pod
    **deletion** is the documented failure mode. Also check `:24 deny mount,` against kubelet's
    shared-propagation remount (`lib.sh:278`).
15. **`/var/log/kubernetes/audit.log`** — produced inside the snap (`disa-stig/bootstrap.yaml:18`,
    `control-plane.yaml:3`) and asserted from the **host** by a CI-run doc test (`hardening.md:150`). Must
    be covered explicitly by S6's outcome.
16. **Decide the `k8s/pebble` flavor's fate** — it installs a host systemd unit and hardcodes host paths, so
    it cannot work strict. Exclude it from the strict build or drop it; keep it in sync with any wrapper
    change above or the two supervision flavors diverge silently.

## Phase 2 — the strict flavor patch

17. **Scaffolding** — `build-scripts/patches/strict/{apply,0001-strict.patch}`; confirm the
    `build-snap.yaml:43` contract.
18. **Header** — `confinement: strict`; `assumes: [snapd2.62]` (both denial bugs are Fix Committed per §3.3; the precise landing release is from bug comments, so confirm before pinning ⚠);
    the `OPENSSL_MODULES` repoint and the D10 ELF gate from S1 (both build-time).
19. **`layout:` — top-level, not under `passthrough:`.** MicroK8s nests both `layout:` and
    `system-usernames:` under `passthrough:` (`snapcraft.yaml:608-635`) with no explanation; it is core18
    legacy that bypasses schema validation. **The list comes from S6, not from MicroK8s's table.** Expected
    base-owned candidates: `/var/lib/kubelet`, `/var/lib/containerd`, `/var/lib/cni`, `/var/lib/kube-proxy`,
    `/opt/cni/bin`, `/usr/libexec` (kubelet's default `--volume-plugin-dir`), `/usr/local/lib`,
    `/var/log/pods`, `/var/log/containers`, and `bind-file: /etc/nanorc`. Omit `/var/lib/calico` (we use
    Cilium) and `/etc/service/enabled` (no consumer). Set `EDITOR=$SNAP/bin/nano` under strict so
    `kubectl edit` works (`microk8s-kubectl.wrapper:26-29`).
20. **Top-level `plugs:`** — `home-read-all` (`home`, `read: all`), `docker-privileged`
    (`docker-support`, `privileged-containers: true`), `docker-unprivileged` (`false`), `k8s-kubelet`
    (`kubernetes-support`, `flavor: kubelet`), `k8s-kubeproxy` (`flavor: kubeproxy`), `cilium-module-load`
    (`kernel-module-load`, `iptable_raw` + `xt_socket`, `load: on-boot`), and `k8s-sysctl`/`k8s-etc`
    (`system-files`, `write:` list from S6 — exact paths only). Cilium Ingress returns
    `503 Service Unavailable` without `iptable_raw`/`xt_socket` (cilium/cilium#25021). `cilium-module-load`
    is a **plug name**, not an interface name, and has never been defined. Treat both attribute syntaxes
    as unverified until S4 passes.
21. **Per-app `plugs:`.** The 2024 per-app table in §1.5 is **unverified** (`git` was denied); run
    `git show origin/strict/main:build-scripts/patches/strict/0001-Strict-patch.patch` before using it as
    a baseline, and cross-check against MicroK8s's verified sets (§2.3). Deltas we need:

    | App | Plugs |
    |---|---|
    | `k8s` | firewall-control, home, home-read-all, kernel-module-observe, kubernetes-support, log-observe, login-session-observe, mount-observe, network, network-bind, network-control, network-observe, opengl, process-control, system-observe — consider splitting privileges like MicroK8s's client apps (`docker-unprivileged`, `k8s-kubelet`) |
    | `containerd` | network-bind, docker-privileged, firewall-control, network-control, mount-observe, kubernetes-support, opengl, cifs-mount, fuse-support, kernel-crypto-api — **plus `cilium-module-load`** only if S4 shows it is needed (MicroK8s's containerd does not carry it) |
    | `etcd` (**new**, replaces `k8s-dqlite`) | network, network-bind |
    | `k8sd` | network, network-bind, mount-observe, kubernetes-support, **docker-unprivileged**, **k8s-sysctl**, firewall-control, network-control, process-control, system-observe |
    | `kubelet` | docker-privileged, firewall-control, hardware-observe, kubernetes-support, mount-observe, network-bind, network-observe, network-control, process-control, system-observe, opengl, kernel-module-observe, **k8s-kubelet** |
    | `kube-apiserver`, `kube-controller-manager`, `kube-scheduler` | **slim from S5's denial inventory before 0a is submitted**: start from `network`, `network-bind`, `network-observe`, `system-observe` and add only what `snappy-debug` shows |
    | `kube-proxy` | the kubelet heavy set with **`k8s-kubeproxy`** added and `kernel-module-observe` retained (`wrappers/services/kube-proxy:13` → `load_kernel_modules nf_conntrack` → `modprobe` at `lib.sh:287`) |
    | `k8s-apiserver-proxy` | network, network-bind, network-observe, network-control |

    Change `k8sd` from `install-mode: enable` to `disable` (`snapcraft.yaml:277`) per D4. Resolving the
    2024 `# FIXME: we keep 'kubernetes-support' because 'mount-observe' is not sufficient` on `k8sd`
    remains a follow-up.
22. **`hooks:` with plugs** — all five hooks need declarations (there is no `hooks:` stanza today).
    `install`: `network, network-bind, network-control, firewall-control, kubernetes-support` (it runs
    `k8s::common::resources`, `k8s x-snapd-config disable` and `k8s::init::k8sd`); `configure`: the same
    plus `k8s-sysctl`; `remove`: plus `process-control, mount-observe, k8s-kubelet, k8s-sysctl`;
    `pre-refresh`/`post-refresh`: `network, network-bind`.
23. **Health gate** (D4), porting `microk8s/actions/common/utils.sh:1241-1290`, with four corrections:
    - **Order**: MicroK8s does `snapctl start --enable ${SNAP_NAME}` (`:1288`) **then**
      `snapctl set-health okay` (`:1289`). Match the working order.
    - **Derive the required set from the declared plugs**, do not hand-maintain it. MicroK8s keeps three
      hand-written copies that already disagree, and its gate omits seven declared plugs (§2.3). We would
      have **five** lists to keep in sync (`snapcraft.yaml` plugs, the required set, `connect-interfaces.sh`,
      the `connect-plug-*` hook set, `test_strict_interfaces.py`) — generate them from one source and add
      a CI check.
    - `snapctl start --enable "${SNAP_INSTANCE_NAME}.k8sd"`, never a literal `k8s.k8sd`. **Only daemons can
      be `--enable`d**: `k8s` is a command with no `install-mode` key (`snapcraft.yaml:258-259`) and must
      never appear in the list.
    - One `connect-plug-<plug>` hook per **plug name** (snapd names them after the plug, not the
      interface), each a symlink to `./configure`. MicroK8s ships a dead `connect-plug-docker-support` for
      a plug it never declares and is missing `connect-plug-docker-unprivileged` — do not reproduce either.
      The `exit 0` issued from inside `check_snap_interfaces` (`utils.sh:1283`) terminates the calling hook
      successfully; if copied, make it deliberate and documented, and only while every caller is
      `configure`. Make the function idempotent (it runs once per connection event). On classic,
      `configure` calls `snapctl set-health okay` to clear stale blocked state (MicroK8s `configure:21-25`).
24. **Interface-gated teardown** in `snap/hooks/remove`, mirroring `microk8s/default-hooks/remove.d/*:5`
    (`! is_strict || snapctl is-connected network-control`), so cleanup degrades instead of erroring.
    MicroK8s's "Calico interfaces not removed on strict" bug is the failure mode to avoid.
25. **`k8s/hack/init.sh`** — replace the no-op with calls to `connect-interfaces.sh` and
    `network-requirements.sh`. `tests/.../test_util/util.py:317` already invokes
    `/snap/k8s/current/k8s/hack/init.sh` by absolute host path, so this is what makes
    `connect_interfaces=True` mean anything. **Hard constraint**: `connect-interfaces.sh` runs the host
    `snap` CLI, so it must never move into `configure` or any confined app; the in-snap half of the
    contract is the health gate (task 23), not a replacement.
26. **D11** — `containerd-base-dir`: fail fast with an actionable error under strict when the requested
    directory is unreachable. It is a bootstrap/join-time option only (`docs/.../bootstrap_config.md:554`),
    so a silent AppArmor denial would surface as a broken join. `test_cleanup.py:154` covers the flag.

## Phase 3 — build system

27. Delete the stale runc `strict-patches/{v1.1.5,v1.1.12,v1.1.13}` and re-verify resolution once the flavor
    patch is real rather than a hand edit (folded into S1).
28. **No containerd strict patches are needed** (MicroK8s has none). Only `strict-patches/` is runc-exclusive;
    the non-strict `print-patches-for.py` path is exercised on every build, so only its `STRICT` branch is
    unproven. If pod deletion or shim management misbehaves, containerd is the first place to look.
29. **Stop mutating the builder's snaps** — `snap list go` / `snap refresh go --channel=…-fips/stable` /
    `snap revert go` appear in **both** `components/runc/build.sh:4,10,27` **and**
    `components/containerd/build.sh:4,10,36`, racing against `snapcraft.yaml:33`'s pinned `go` build-snap.
30. **Pin k8sd to a tag for the duration of this work** — `components/k8sd/version` is the **branch**
    `release-1.36` (cloned by `build-component.sh:30`), uniquely among components.
31. **Document `strict-patches/`** in `build-scripts/AGENTS.md` and `build-scripts/README.md`. Model:
    `microk8s/build-scripts/components/README.md:25,31,34`.

## Phase 4 — tests and CI

32. **Rewrite `tests/integration/tests/test_strict_interfaces.py`**, do not merely un-`xfail` it. `:34` calls
    `setup_k8s_snap(cp, channel, connect_interfaces=False)` and `:67-77` then asserts all 18 plugs are
    connected, so it fails on a *correct* strict snap. Derive the expected list from `snapcraft.yaml`.
    `snapctl is-connected <unknown-plug>` fails with "no such plug", which the current assertion cannot
    distinguish from "not connected". Also drop the `TEST_STRICT_INTERFACE_CHANNELS` green-`xfailed`
    placebo at `e2e-tests.yaml:286` once it is real.
33. `test_util/util.py:290` — make `--classic` conditional on `config.FLAVOR != "strict"`. The comment at
    `:360-361` only covers the `refresh` path; `:290` (install) and `:303` (`--dangerous`) are
    unconditional, as are `test_version_upgrades.py:130,324,504,508`.
34. **Channel naming (D9 = bare track)** — no changes needed to `test_util/snap.py:40-45`,
    `test_util/util.py:879-881,945`, the `e2e-tests.yaml:151` regex, or `substitutions.yaml:3`. Amend
    **`AGENTS.md:46-47`** only.
35. **Fix `test_version_upgrades.py:76`** — `channels[i].split("-")[0].split(".")` then `int(...[1])` raises
    `ValueError` on a bare track (`"1.32/stable"` → `int("32/stable")`). Reachable whenever `config.SNAP`
    is set, which CI always does (`e2e-tests.yaml:277,283-285`). Split the risk/branch off the track before
    parsing. There is no "downgrade twin" with this bug: `split("-")` occurs exactly once in the file;
    `:197-206` is only the discovery call.
36. **Unify the `latest/edge` spelling** (§3.5): `util.py:1037` yields the invalid literal `"latest/edge/"`
    under strict; `util.py:840` and `snap.py:106,123` yield `latest/edge/strict`.
37. **`test_cleanup.py`** — if S6 relocates paths, the assertions become **vacuously true**:
    `_assert_paths_not_exist(["/etc/containerd", "/run/containerd", "/var/lib/containerd", "/opt/cni/bin"])`
    passes trivially when those host paths no longer exist. Add positive assertions on the real
    post-strict locations, and add `/etc/cni/net.d`, which is asserted nowhere in the tree. Also
    `util.py:385-390` greps host `mount` output for `/var/lib/kubelet/pods` and
    `/run/containerd/io.containerd`; under relocation the predicate is satisfied immediately, masking
    leaked mounts. Rename `CONTAINERD_SOCKET_DIRECTORY_CLASSIC` (`:14`) accordingly.
38. **Re-enable the CNI netns cleanup assertion** at `util.py:392-409`
    (`# NOTE(neoaggelos): Temporarily disable this as it fails on strict`).
39. **Confinement-bypassing test call sites** — decide per S6 and make flavor-aware at minimum: the five
    `/snap/k8s/current/bin/helm --kubeconfig /etc/kubernetes/admin.conf` sites
    (`test_version_upgrades.py:345,391,438,522,579`), the two host `curl` sites against
    `/etc/kubernetes/pki/etcd/*`, and `conftest.py:54` (`inspect.sh` by host path). Executing a
    snap-internal binary from `/snap/.../bin/` runs it **unconfined**, so these tests keep passing while the
    equivalent in-snap operation is denied — a systematic false negative. Also switch
    `test_airgapped.py:63,65` from the systemd drop-in to `$SNAP_COMMON/args/containerd-env` under strict
    (task 4a).
40. **Add denial detection to CI.** Nothing in `tests/` checks `dmesg | grep DENIED`, `aa-status`,
    `/var/log/audit` or `snappy-debug`, so a strict regression cannot be detected at all. Add a post-test
    denial sweep, and run the strict integration job on an AppArmor-enforcing substrate (task 43).
41. **CI plumbing.**
    - Adding `strict` to `lint_and_integration.yaml:27` does **not** break artifact download — the
      `test-integration` job has its own matrix (`:135-138`) without `matrix.patch`, so `:145`/`:195`
      still resolve to `k8s-${{ matrix.arch }}.snap`. The strict snap is built and **never consumed**: a
      green run that tests nothing. Thread the flavor into the downstream matrices.
    - `:155` reads `needs.build-snap.outputs.snap-artifact` from a matrixed job — already a race at two
      arches, worse with a flavor dimension. Pass the artifact per-leg.
    - Wire the flavor through `build-snap.yaml` (input `:13-15`, naming `env:` `:59-67`) and
      `e2e-tests.yaml:32-35,281,286`.
    - **`trivy.yaml:31-35`** hardcodes five classic channels and is the only scheduled caller of
      `security-scan.yaml` — strict would ship CVE-unscanned.
    - `nightly-test.yaml` channels are at `:27-32` (all `/edge`) and `:78-79`; `weekly-test.yaml` at
      `:23,41,62-67` (this is where `1.35-classic/stable`/`1.36-classic/stable` live). `nightly-test.yaml:35,49,57`,
      `weekly-test.yaml:24,43,69` and `compare-performance.yaml:60,72` pass no `flavor`;
      `compare-performance.yaml` has no `flavor` input at all. `security-scan.yaml` and
      `charm-e2e-tests.yaml` need no change themselves — only their callers do (`charm-e2e-tests.yaml`'s
      `--classic` at `:99-101` is for `charmcraft`/`juju`, unrelated). `sbom.yaml` needs nothing.
    - `lint_and_integration.yaml:9,11` and `sbom.yaml:9,11` already listen on `autoupdate/strict` and
      `autoupdate/release-X.Y-strict`. If flavors are generated in-tree via
      `build-scripts/patches/strict/apply`, these filters can be deleted rather than made to work.
    - Either create the `strict.yaml` / `strict-integration.yaml` workflows the release checklist links
      (`create_release_branch.md:126,135-136`) or update the checklist (`:109-110`, `:115`).
42. **Branch/recipe setup and its broken guard.**
    - **Fix the three inverted assertions** in `tests/branch_management/tests/test_branches.py` — `:59-62`
      (two) and `:79-80` use `if missing := [...]: assert missing`, which can never fail. Pre-existing bug;
      fix **before** relying on this suite as a drift guard.
    - `_branch_flavours` (`:34-42`) runs `git ls-tree --full-tree -r --name-only origin/<branch>
      build-scripts/patches` (`:37`), so it needs a **fetched remote** — it is not a working-tree read —
      and `build-scripts/patches` does not exist, so it returns `[]`: the suite is doubly dead.
      `_confirm_branch_exists` (`:48`) additionally hits the network with `git ls-remote --heads`.
    - Reconcile the Launchpad path divergence: `test_branches.py:67` probes
      `https://launchpad.net/~containers/k8s/+snap/...` while `create_release_branch.md:141-142` points at
      `~cdk8s` and `launchpad.net/k8s/+snaps`; `K8S_LP_REPO` (`:17`) has a **leading space**; and
      `_confirm_recipe_exist` (`:66-69`) only checks `status_code == 200`.
    - Then create `autoupdate/release-1.36-strict` and the `k8s-snap-1.36-strict` recipe. This suite asserts
      branch names and recipe URLs, never channel names, so it is indifferent to D9.
43. **Substrates.** Add (a) an AppArmor-**enforcing** substrate — every `lxd*.yaml` profile is effectively
    unconfined because `harness/lxd.py:119-122` always applies `lxd-profile.yaml` (`:5,9-10`) (the five
    sibling `lxd-*-profile.yaml` files are network-only overlays), and the AlmaLinux variant uses
    `lxc.selinux.context=unconfined_t`; and (b) an Ubuntu Core path. Core support today is **six README
    lines** (`tests/integration/README.md:151-156`, `TEST_MULTIPASS_IMAGE=core22`): `harness/multipass.py`
    only forwards the image name, `harness/lxd.py` has nothing, `tests/integration/lxd/setup-image.sh:101`
    symlinks `/snap` only in the `almalinux)` arm (`:90-105`), and `util.setup_k8s_snap`'s default
    `tmp_path=Path("/home/ubuntu")` does not exist on Core. This is new harness work, and it needs explicit
    `snap connect` after install because there is no gadget snap.

## Phase 5 — documentation

44. **Base set** (all under `docs/canonicalk8s/` unless noted). No page mentions strict confinement today.
    - `snap/explanation/security.md:25-29` — rewrite the whole sentence, not `:26-29`. `:31` is
      `<!-- First charm end here -->`, so this block is published on **three** pages (`snap/`, `charm/`,
      `capi/explanation/security.md`).
    - `snap/explanation/channels.md` — the primary tracks/risks page and where D9 becomes user-visible.
      Internally inconsistent today: `:20-21` describes the bare `1.32` track while `:53` and `:79` quote
      `1.32-classic/stable`, and the guidance at `:83-95` uses bare tracks.
    - `_parts/install.md:2,5,8`; `snap/howto/install/snap.md:65`;
      `snap/howto/install/custom-bootstrap-config.md:12`; `snap/howto/install/dev-env.md:12`;
      `snap/howto/install/offline.md:248` (+ the containerd path note at `:277`);
      `snap/howto/upgrades.md:37,57,103` (`:32` is prose; there is no separate `howto/upgrades.md`);
      `snap/tutorial/getting-started.md:47`; `snap/howto/troubleshooting.md:272` (`:284` has no classic
      channel).
    - Also: `docs/spread.yaml:96` (**CI-executing**, `prepare-each` for the whole `snap_bootstrapped`
      suite); `README.md:56` (repo front page, different flag order — a naive `sed` misses it);
      `releases/snap/upgrading.md:27,88,108,128`; the CAPI channel contract
      (`capi/explanation/in-place-upgrades.md:74,84`, `capi/howto/custom-ck8s.md:42,69,76`,
      `capi/reference/configs.md:359`, `capi/howto/in-place-upgrades.md:55`);
      `_templates/template-tutorial:46`; `assets/how-to-epa-maas-cloud-init:86`;
      `releases/{charm/1.32.md:166,snap/1.32.md:425}`.
    - Content to add: install without `--classic`, the plugs that must be connected, the known limitations
      (§Part 7), the bare-track caveat (D9), the `$SNAP_COMMON/args/<service>-env` proxy surface that
      replaces the systemd drop-in under strict (task 4a), and a strict section in
      `snap/howto/install/offline.md`.
45. **Conditional on S6 relocating any path** — republish the host-path contract:
    `snap/reference/certificates.md:33-42,55-68`, `snap/tutorial/kubectl.md:41-44,54-59`,
    `snap/reference/cis-audit.md`, `snap/reference/disa-stig-audit.md`,
    `snap/howto/image-management.md:34,49,72-86`, `snap/howto/networking/alternative-cni.md:48,51,145`,
    `snap/howto/security/hardening.md:150,382-391`, `snap/howto/restore-quorum.md:93-102`,
    `snap/howto/security/{refresh-certs.md:50,intermediate-ca.md:64-68,cis-assessment.md:70-81}`,
    `snap/howto/epa.md:702` — **plus the external kube-bench `ck8s` config repo**, which is what the CI gate
    actually runs. Treat this as the main cost of a layout-based outcome.
45a. **Unconditional, because the systemd drop-in cannot work under strict regardless of D12** (task 4a):
    rewrite `snap/howto/networking/proxy.md` (`:13,26,36,39`, a CI-executed doc test) and
    `snap/howto/install/offline.md:144` to present `$SNAP_COMMON/args/containerd-env` as the strict proxy
    surface, keeping the drop-in instructions for classic.
46. **CI interaction note.** `test_k8s_version_in_files` (`tests/branch_management/tests/test_branches.py:173,
    180-186,199-215`) checks only `README.md` and `docs/canonicalk8s/_parts/install.md` with
    `channel[ =](\d+\.\d+)`; it is **not** inverted, so it does fail. `reuse/substitutions.yaml` is checked
    by a different test (`test_k8s_version`, `:159-166`) and only for its `version` key — its
    `channel: '1.36/stable'` at `:3` is validated by nothing. It also has a live `pytest.skip` for any line
    containing `"juju"` (`:202-209`), which covers `install.md:11,14,17,22,32`.

---

# Part 7 — Porting requirements and open items

- **`TasksMax`** — `k8s/systemd/containerd-defaults.conf` sets `TasksMax=infinity` on classic; no snapd
  mechanism sets it and the service likely cannot raise `pids.max` on its own cgroup. The default
  `DefaultTasksMax=15%` of kernel pid max (~4900 tasks) caps pod density. Request a snapd service snippet
  (precedent: `docker-support` contributing `Delegate=true`, verified §3.2), or document a host-level `DefaultTasksMax`
  change. Measured in S4. **This is the one line of the classic drop-in with no strict equivalent** — the
  other five (`Delegate`, three `Limit*`, `OOMScoreAdjust`) are covered by task 5.
- **Proxy configuration surface changes under strict** — the documented systemd drop-in is replaced by
  `$SNAP_COMMON/args/containerd-env` (tasks 4a, 39, 45a). This is a user-visible behaviour change
  independent of D12.
- **Per-service plug slimming** — for `kube-apiserver`, `kube-controller-manager` and `kube-scheduler` this
  is **not** a follow-up: because `docker-support` needs a store snap-declaration, carrying plugs those
  three do not need enlarges and slows the request, so task 21 slims them from S5's inventory **before** 0a.
  Remaining follow-ups: trimming `kubelet` and `kube-proxy`, and resolving the 2024 `# FIXME: we keep
  'kubernetes-support' because 'mount-observe' is not sufficient` on `k8sd`.
- **`kubernetes-support` `autobind-unix` flavor** ⚠ — MicroK8s needs it for dqlite/journald autobind
  sockets. `k8sd` uses `@snap.$SNAP_INSTANCE_NAME.k8sd`, permitted by snapd by default. Add a `k8s-journald`
  equivalent only if S5 shows denials.
- **`apparmor_parser` availability in the base** ⚠ — if S4 fails, stage the apparmor userspace and accept
  the size cost.
- **Ubuntu Core interface connection** — real deployments should declare connections in a gadget snap;
  tests must do it manually. Document both.
- **`etcd` under strict** — 1.36 replaced `k8s-dqlite` with embedded etcd; it was never exercised under
  strict (the 2024 patch predates it). Watch for file-locking and `fs.aio-max-nr`-style tunables MicroK8s
  had to skip for dqlite (`increase_sysctl_parameter` is wrapped in `! is_strict` at `utils.sh:1362`).
- **Strict upgrade path** — under D9 there *is* a bare-track `1.32`/`1.33` lineage to refresh from (0b
  confirms), so `snap refresh` from the old strict lineage and from classic must be either tested or
  explicitly declared unsupported. Depends on task 35.
- **Documented MicroK8s strict limitations that apply to us** (§2.12): Calico/CNI interfaces not removed on
  `snap remove` unless `network-control` is still connected; systemd drop-ins impossible; UFW
  auto-configuration classic-only; sysctl tuning unavailable beyond what `system-files` is granted.
- **Pebble flavor** — task 16.
- **External repos** — the kube-bench `ck8s` config (task 45) and k8sd (0c) are outside this repo.

---

# Part 8 — Validation plan

1. `snapcraft --use-lxd` on the patched tree (amd64); `review-tools` clean except the expected
   super-privileged interface warnings.
2. Install `--dangerous`: health reports **blocked**, nothing starts, the message names the missing plugs.
   Run `k8s/hack/connect-interfaces.sh`; health flips to **okay** and `k8sd` starts on its own. Repeat
   connecting plugs in a different order.
3. `k8s bootstrap` → `k8s status --wait-ready` under `snappy-debug`, on an **AppArmor-enforcing** host
   with `aa-status` recorded as proof. Zero denials is the bar; denials measured in an unconfined LXD
   container are not evidence.
4. **Host-visibility regression** — re-run S2's matrix and assert it matches the committed expectation.
   This guards against a layout silently swallowing a host path later.
5. **Pod `hostPath` semantics** — re-run S3 and assert the documented answer, including a user pod mounting
   a layout-shadowed path.
6. Full integration suite with `TEST_FLAVOR=strict`: `test_strict_interfaces.py`, `test_cleanup.py`,
   `test_clustering.py`, `test_version_upgrades.py`, plus the default-feature tests.
7. Feature checks: Cilium networking **and ingress** (exercises `cilium-module-load` and the `rp_filter`
   path), CoreDNS, MetalLB, local-storage/`rawfile-csi` (exercises `/var/lib/kubelet` propagation and
   `/usr/libexec`), metrics-server, gateway, and `multus-cni-setup.yaml` (host/pod CNI path identity).
8. Pod lifecycle edge cases: `allowPrivilegeEscalation: false` (runc strict patch 3), `kubectl exec`
   (needs `XDG_RUNTIME_DIR`, `wrappers/services/containerd:8`), `kubectl logs`, `kubectl edit`
   (`/etc/nanorc` + `EDITOR`), and pod **deletion** (the `signal (receive) peer=snap.k8s.*` rules plus the
   `//&unconfined` rule from task 14).
9. Multi-node: `k8s join-cluster` for control-plane and worker roles; `k8s remove-node`.
10. `snap refresh` between two strict revisions — containerd-shims must still find runc (the
    `current`-vs-revision trap, MicroK8s `run-containerd-with-args:22-29`) and `post-refresh` must run
    (task 13). Also exercise the bare-track lineage from `1.32`/`1.33` if 0b confirms it exists.
11. `snap remove --purge`: no residue under the containerd/CNI paths S6 settles on, under `/var/snap/k8s`,
    or in the sysctl drop-ins declared in `system-files` (`1000-cilium.conf` and/or the k8sd-written
    `[0-9]+-k8s.conf`); CNI links and netns gone.
12. **CIS/DISA-STIG scenario on strict** — run `docs/tools/scenarios.yaml`'s `cis` scenario against a
    strict install. If it fails, task 45 is not optional.
13. `k8s inspect` usable with no denials, **both** ways: via `k8s inspect` (snap-internal `PATH`) and by
    absolute host path as `conftest.py:51-63` does.
14. **Non-root CLI fails gracefully** — D7 asserts a root-only CLI but nothing tests it. Run every `k8s`
    subcommand as an unprivileged user and confirm a clear permission error, not a traceback, a partial
    action or an AppArmor denial. Precedent: MicroK8s `exit_if_not_root()` (`utils.sh:1292-1298`).
15. Repeat 2–11 on an Ubuntu Core VM.

---

# Part 9 — Risks

| Risk | Mitigation |
|---|---|
| **Layouts hide host paths and break a CI-gated compliance claim** (D12) | §3.7 measured the mechanics and §5.2 gives the recommended split; S2(a) confirms create/write semantics; validation steps 4, 5 and 12 are the regression guards; task 45 is the cost if relocation wins |
| **`system-files` cannot *create* `/etc/kubernetes`** — **largely retired**: §3.9 shows `write:` emits `"<path>{,/,/**}" rwkl`, which permits creation, and §3.7 shows in-snap `/etc` is the host's | S2(a) now only confirms it end-to-end; if it fails, relocation + task 45 + mandatory k8sd base-dir work (0c(ii)) |
| **Store review may refuse `system-files` on `/etc/kubernetes`** — now the *primary* risk on option A. `allow-installation: false` means the store gates installation itself (§3.9), and no precedent on this machine asks for a tree that broad; the closest strict analogue (`docker`, §3.8) uses none | Raise explicitly and early in 0a with the compliance-contract justification; §5.2 option B (relocation) is the costed fallback, and 0c(ii) keeps it available |
| **`containerd-shim` namespace unverified** — the remaining load-bearing unknown. §3.4 verifies that a forked child inherits the snap's mount namespace, but not the shim's detached/reparented case. The bundled Helm charts (8 `.tgz`: cilium 1.19.4, metallb, coredns, metrics-server, rawfile-csi, contour, gateway-api, tigera-operator) cannot be inspected or patched in-tree; CNI/socket paths come from **k8sd's chart values**. The three editable chart sources (`ck-loadbalancer`, `ck-gateway-cilium`, `ck-ingress-tls`) contain no host-path references | S3 + validation steps 5 and 7 (multus); keep the k8sd chart-values contract explicit in 0c(iii); a one-off unpack-and-grep audit of the `.tgz` files is cheap insurance |
| **Plug sets may be over-provisioned** — the 2024 patch gave five k8s services an identical heavy set; `dockerd` runs privileged containers with ten plugs and none of `mount-observe`, `system-observe`, `process-control`, `kernel-module-observe`, `hardware-observe` or `kubernetes-support` (§3.8) | Task 21 slims from S5's denial inventory using §3.8 as the reference floor, before 0a is submitted |
| **`docker-support` grants are emitted via AARE exclusion patterns**, not literal `/** rwlix` (§3.2), excluding `/snap/{snapd,core}/*/usr/lib/snapd/snap-confine` | Harmless in normal operation; if a denial names a snap-confine path, this is why — note it in the S5 denial triage |
| **ELF interpreter/RPATH pinned to `/snap/core22/current`** for etcd, containerd, `ctr`, `containerd-shim-runc-v2` | D10 gates the LIEF pass on confinement; S1 builds both ways. MicroK8s (strict on core22, no LIEF) is the precedent |
| Store declaration lead time blocks auto-connect, and its content depends on S6/S5 | Open the conversation at 0a immediately but submit after S6; the health gate keeps `--dangerous` and CI installs working meanwhile |
| **k8sd companion change required** (sysctl, possibly base-dirs) — strict is not deliverable from k8s-snap alone | 0c raises it in parallel with 0a; it is the second long-lead item |
| Novel, unvalidated interface designs — `system-files` and `kernel-module-load` have **zero** MicroK8s precedent | S4 validates both attribute syntaxes; MicroK8s's direct `/proc/sys` write + best-effort dual `modprobe` is the documented fallback |
| Strict validated where AppArmor does not mediate | Validation step 3 + task 43(a); `aa-status` recorded |
| **Strict CI goes vacuously green** — artifact never consumed, `test_cleanup` trivially true, `test_strict_interfaces` xfailed and broken, no denial detection, tests running snap binaries unconfined | Tasks 32, 37, 39, 40, 41 together; treat "green with no strict evidence" as a failure mode in its own right |
| runc `v1.4.2` patches do not apply to `v1.4.3` | Same three patches, 2026-rebased by MicroK8s against a 2026 runc; S1 verifies resolution and the `sorted()` fix removes the ordering hazard |
| Flavor-patch rot — what killed the 2024 attempt (`origin/strict/main` frozen at `core20` with `k8s-dqlite`) | D1 + D10 keep the patch small; **task 42's inverted assertions must be fixed first** or the drift guard is fiction |
| `TasksMax` caps pod density | S4 measures it; request a snapd service snippet or document a host change |
| Embedded etcd never exercised under strict | Explicit validation item; watch for aio/inotify-style tunables |
| `nano`/`/usr/share` exclusion (`snapcraft.yaml:222` strips `-usr/share`) — **low**: `nano` is staged (`:202`) and `bash-utils` has no `prime:` block, so the binary ships; only syntax files are missing | Task 10 decides whether `/usr/share/nano` is needed; if not, the `/etc/nanorc` layout plus `EDITOR` is sufficient |
| Ubuntu Core has no `sudo`, no host userspace, no writable unit dirs | Phase 1 tasks 1, 2 and 4 remove those dependencies |
| Bare track means `snap install k8s --channel=1.36` silently yields strict | Document prominently in `channels.md` (task 44) and release notes |
| k8sd tracks a branch, not a tag — strict bring-up is non-reproducible | Task 30 |
| Pre-existing latent bugs surfaced by this work (non-executable hooks, unsorted patch iteration, inverted branch-management assertions, `latest/edge/` spelling, `ValueError` on bare-track ordering) | Tasks 13, S1, 42, 36, 35 — each fixable and valuable independent of strict |

---

# Appendix — Errata against earlier revisions of this document

Material corrections applied in this revision. Where a correction changed text in Parts 1–3 it is already
applied inline; this table is the audit trail.

| Revision-1 location | Correction |
|---|---|
| D2 / Part 4 blocker 8 | `layout:` is a **relocation visible only inside the snap**, not a redirect; D2 would have hidden `/etc/kubernetes` etc. from the host — see §5.2 |
| Part 6 ordering | Phase 0 task 1 (store declaration) depended on task 20's slimming, which needed a working strict build — circular. Replaced by Phase S |
| §3.6, Phase 2 bullet, Phase 3 | "No component in either tree has a `patches/` dir other than runc" is **false** — only `strict-patches/` is runc-exclusive; the non-strict resolution path runs on every build |
| §2.1, task 22 | `enable_snap()` is `start --enable` (`:1288`) **then** `set-health okay` (`:1289`) — order was reversed |
| §1.3 blocker 20, task 24 | **Nothing in-tree invokes `connect-interfaces.sh`.** `util.py:317` invokes `hack/init.sh`, a 3-line no-op. The fix was right; the premise conflated the two scripts |
| §1.3 blocker 22 | `containerd/build.sh:4,10,36` mutates the builder's `go` snap identically to runc |
| §3.6 / D2 | k8sd is cloned by `build-component.sh:30`, not `k8sd/build.sh`; `components/k8sd/version` is the **branch** `release-1.36` |
| §2.3 | `kernel-module-control` is also on `connect-plug-network-control` (`:705`) and `disconnect-plug-network-control` (`:710`); the `check_snap_interfaces` list omits seven declared plugs |
| §2.4 | `--hostname-override` **does** appear in MicroK8s (`inspect.sh:338`, `join.py:327,343,470,474-475`) |
| §2.5, task 8, D6 | MicroK8s `containerd-env` ulimits are at `:29` and `:34`, not `:33`/`:38` |
| §2.7 | The strict `apparmor_parser -r` is at `run-containerd-with-args:33`; `:34-44` is the classic `else` |
| §2.12 | `microk8s/scripts/inspect.sh:222` is dead in the **opposite** direction — `[` returns 2, so the UFW block is unreachable in both confinements |
| §1.5 | MicroK8s's real `daemon-containerd` set has **no** `cilium-module-load`; `kubectl`/`ctr` carry `k8s-kubelet` + `docker-unprivileged`. Treat the 2024 per-app table as unverified |
| §1.3 blocker 10 | `inspect.sh` `systemctl` is at `82,168,171,183`; `:141-144` are `snap` commands; `:179,:188` are `journalctl` |
| §1.3 blocker 14 | The iptables part's `stage:` excludes three entries, not one; the `$SNAP/sbin` legacy-binary conclusion still holds |
| Part 3 title | "External facts verified in this session" was wrong — Part 3 is **unverified** except §3.5 |
| Task 32a | There is no "downgrade twin" of the `int()` bug — `split("-")` occurs once, at `test_version_upgrades.py:76` |
| Task 34 | Adding `strict` to the matrix is a **silent no-op**, not an artifact-download break (task 41); `trivy.yaml:31-35` was also missing |
| Task 29 | `test_strict_interfaces.py` is logically broken, not merely xfailed (task 32) |
| Task 37 | `upgrades.md:32` is prose; `howto/upgrades.md:37` is the same file; `troubleshooting.md:284` has no classic channel; ~20 locations were missing (task 44) |
| Task 12 CI note | `substitutions.yaml` is checked by `test_k8s_version`, not `test_k8s_version_in_files` (task 46) |
| Task 5 / §2.13 item 9 | Deleting `sudo` outright drops `--preserve-env` on the classic path; use a `run_with_sudo` wrapper (task 2) |
| Task 36 | The five sibling `lxd-*-profile.yaml` files do not themselves set AppArmor unconfined; `harness/lxd.py:119-122` always applies the base profile, so the conclusion stands. `setup-image.sh` is at `tests/integration/lxd/`, not under `test_util/harness/` |
| Task 35 | The inverted assertions are three: `test_branches.py:60`, `:62`, `:80` (two of them inside `:59-62`) |
| Missing entirely | ELF/patchelf retargeting (blocker 23, D10), unsorted patch iteration (`print-patches-for.py:104`), no denial detection in tests, tests running snap binaries unconfined, `/var/log/kubernetes/audit.log`, `k8s/pebble`, `containerd-base-dir` behaviour under strict (D11), vacuous `test_cleanup` |
| Missing (added in revision 3) | Host consumers of `/etc/systemd/system/snap.k8s.containerd.service.d/` (`proxy.md:13,26,36,39` — CI-executed, `offline.md:144`, `test_airgapped.py:63,65`); the **replacement proxy surface** `$SNAP_COMMON/args/<service>-env` (`lib.sh:237-247`), tasks 4a/45a; the explicit line-by-line fate of `k8s/systemd/containerd-defaults.conf`; `_branch_flavours` needing a fetched remote |
| D10, D11 mislabelled | Both were marked **DECIDED** in revision 2, but only D9 was decided by the requester. Now marked **PROPOSED** |
| §3.4, §5.2 host-tree list | Revision 2 listed the host-visible trees from memory and included `/srv`, which is **base-owned**; it also omitted `/var/snap` and `/mnt` (both host) and the private-`/tmp` behaviour. Superseded by the measured §3.7 |
| Part 3 framing | Revision 2 treated the host-vs-base question as unverifiable here. It was verifiable: §3.7 measures it with snapd 2.77.1 and a strict core22 snap |
| §3.2 privileged `docker-support` | Revision 2 listed `/** rwlix` and `change_profile unsafe /**` as literal AppArmor rules. **They are not**: both are commented out in the source and emitted via `###EXCL{…}###` / `InsertAAREExclusionPatterns`, excluding `/snap/{snapd,core}/*/usr/lib/snapd/snap-confine` (§3.2) |
| §3.2, §3.9 store gate | Revision 2 said `docker-support` "requires a store snap-declaration" for auto-connect. It is stronger: `allow-installation: false` means the store gates **installation** with the plug declared, for both `docker-support` and `system-files` (0a) |
| §5.2 recommendation | Revision 3 recommended `system-files` for `/etc/**` as the default without knowing that the closest production analogue (`docker`, strict, privileged `docker-support`, containerd + runc) uses **no `system-files`** and relocates by daemon flags (§3.8). D12 is rebalanced into two costed options |
| §3.4 | Revision 3 called the pod-namespace claim wholly unverified. The fork-inheritance half is now **measured**; only the `containerd-shim` detached/reparented case is open |
| S2 scope | Revision 3's S2(a)–(c) were written before §3.1/§3.9 were read from source; (a) is largely answered at the policy level and the layout-legality sub-question is answered outright |

**Not an erratum:** §2.2's `/var/lib/kube-proxy` → `$SNAP_DATA/kube-proxy` row is correct as written.

# Open decisions

1. **D12 host-path strategy — now a product decision, not a technical unknown.** §5.2 presents two costed
   options: **A** keep the published host-path contract via `system-files` (mechanically verified, §3.9,
   but with material store-review risk), or **B** follow the `docker`/MicroK8s precedent and relocate,
   paying for task 45 and the external kube-bench config. Recommendation on record: A for `/etc/**` and
   `/var/log/kubernetes`, B for base-owned paths. **Needs a decision from the requester**; 0c(ii) must be
   raised in parallel so B stays available.
2. **D10 (ELF patching gated on confinement)** and **D11 (`containerd-base-dir` fails fast)** are my
   proposals and have **not** been confirmed by the requester.
3. **D11 scope** — whether any non-default `containerd-base-dir` is supportable, only "reachable" values,
   or none. Depends on S2.
4. **Whether the `k8s/pebble` flavor survives** (task 16).
5. **Ownership of the external kube-bench `ck8s` config** if task 45 is triggered — out of this repo.
6. **Store appetite for `system-files` on `/etc/kubernetes`** — raise early in 0a; it decides between
   §5.2's options A and B, and `allow-installation: false` makes it a gate on uploading at all.

# Still unverified (and why)

| Item | Why it could not be verified here | Resolved by |
|---|---|---|
| `containerd-shim` stays in the snap's mount namespace (§3.4) | needs a strict k8s build and a running pod; the detached-child probe was reaped when `snap run` exited | S3 |
| Pod `hostPath` resolution for user pods | same | S3 + validation step 5 |
| `kernel-module-load` attribute syntax (`cilium-module-load`) | no snap on this machine uses it; no MicroK8s precedent | S4 |
| `kubernetes-support` `autobind-unix` flavor necessity | needs k8sd/etcd running under strict | S5 |
| `apparmor_parser` reachable from the core22 base | not probed; §3.2 confirms the AppArmor *rule* exists, which is a different question | S4 |
| Exact snapd release for `assumes:` | the "2.62" figure comes from bug comments, not a release artefact; statuses themselves are verified | task 18 |
| Ubuntu Core namespace behaviour | `/etc` is a writable overlay there; no Core VM available here | S2(b) |
| Store appetite for the `system-files` grant | a conversation, not a measurement | 0a |
| §1.5's 2024 per-app plug table | `git` is denied in this environment | `git show origin/strict/main:…` before task 21 |
| `TasksMax` / `pids.max` raisability | needs a confined service to attempt it | S4 |
