# Strict confinement for k8s-snap — implementation report

**Date:** 2026-10-13
**Branch:** `dev-1.36-strict` (49 commits since `b1f55ab0` on `release-1.36`)
**Plan document:** `STRICT_CONFINEMENT_FINDINGS_AND_PLAN.md` (rev. 4 + rev. 5 addendum)
**Tracked in OpenSpec:** `openspec/changes/` — 5 changes, all `openspec validate`-clean
**Audience:** k8s-snap engineering team — read, verify, validate, then modify or reuse.

---

## 1. Executive summary

The strict confinement flavor is **implemented and validated end-to-end** on real builds.
On an LXD VM (Ubuntu 24.04, snapd 2.77.1) with a snap built from this branch:

- `snap install --dangerous` (no `--classic`) → `confinement: strict`
- 27 interface plugs connect via the shipped `init.sh`
- the health gate holds the snap `blocked` until all plugs connect, then reports `okay`
  and enables k8sd (install-mode: disable until then)
- `k8s bootstrap` succeeds; `k8s status` reports **ready**; node `Ready` (v1.36.4)
- all core services active (containerd, etcd, k8sd, kube-apiserver,
  kube-controller-manager, kube-scheduler, kubelet); Cilium agent 1/1; all
  kube-system pods Running; test pod schedules/runs/`exec`s/deletes cleanly
- `k8s inspect` produces a full report
- **zero AppArmor denials in steady state**

Validation on built snaps surfaced **eleven real bugs the plan could not predict**;
all are fixed and committed (§5). Three fixes are k8sd-side and ship as component
patches until upstreamed (§7).

CI plumbing was implemented and then **deliberately reverted** at the requester's
instruction; the full to-do list is in §6.2.

---

## 2. Delivery model

One source tree, two flavors, decided at **build time**:

```
classic branch (this tree)                build-scripts/patches/strict/apply
├─ snap/snapcraft.yaml  (classic)         → applies 0001-strict.patch (git apply)
├─ k8s/lib.sh           (is_strict gates)    confinement, plugs, layouts, hook plugs,
├─ wrappers, hooks      (is_strict gates)    per-app plug sets, pebble exclusion,
└─ build-scripts/       (both flavors)       PATH/environment
```

- **D1 honored:** every runtime difference lives on the classic branch behind
  `k8s::common::is_strict()`; the strict delta is a generated patch
  (`build-scripts/patches/strict/0001-strict.patch`, 964 lines) applied by the
  `apply` wrapper that `.github/workflows/build-snap.yaml` already invokes when
  `flavor: strict` is passed.
- The patch regenerates deterministically: edit the strict scratch, amend the
  flavor commit, `git format-patch -1`. It has been regenerated ~10 times during
  validation; `git apply --check` is green on every revision.
- **D9 honored in test code:** bare track `1.36/<risk>` for both flavors;
  `latest/edge` / `latest/edge/strict` for the latest shortcut. The store itself
  still only has `1.xx-classic` tracks (task 0b is external).

Magnitude (excluding generated `.kilocode/` and OpenSpec text):

| Area | Files | +/- lines (approx) |
|---|---|---|
| runtime (`k8s/`) | 12 | +420 / −90 |
| packaging (`snap/`, patch, `build-scripts/`) | 16 | +1,300 / −520 (incl. new patch file +984, stale runc patches −415) |
| tests | 7 | +350 / −130 |
| docs + AGENTS | 12 | +170 / −15 |
| **repo total (92 files)** | | **+5,604 / −642** (incl. ~3,900 generated openspec/.kilocode) |

---

## 3. What changed, and why

### 3.1 Runtime (`k8s/`, hooks) — Phase 1

| Change | Why | Trade-offs |
|---|---|---|
| `setup_env` strict branch: PATH/LD_LIBRARY_PATH from snap+base only | Host tails (`REAL_PATH`) are invisible/irrelevant under strict and mask missing staged tools | None for classic (branch gated). Slight duplication of the path list |
| `k8s::util::run_with_sudo`; all bare `sudo` call sites converted | `sudo` is not staged and cannot work under strict (also fixes the unguarded `sudo` on the remove path — a latent Core bug) | Classic keeps sudo with env preservation (MicroK8s pattern) |
| `apply_sysctl_tuning` (new, called from configure hook) | rp_filter tuning was dead code in a host script; `/usr/lib/sysctl.d` edits were distro-owned-file mutation | Applies on every configure (idempotent). Writes exactly `/etc/sysctl.d/1000-cilium.conf` — the only declarable path for `system-files` |
| `ensure_systemd_defaults` no-op under strict + `SNAP_INSTANCE_NAME` fix + `daemon-reload` | Drop-ins impossible under strict; docker-support injects `Delegate=true`; also fixed the hardcoded unit name and missing reload (classic bugs) | `TasksMax` has **no strict equivalent** (documented gap) |
| containerd wrapper: `aa-exec` classic-only; strict ulimits + `oom_score_adj` | `aa-exec -p unconfined` is the antithesis of strict; the drop-in's resource limits had to move in-process | ulimit "infinity" → best-effort with 65536 fallback; oom write is `|| true` |
| `//&unconfined` signal peer rule in `cri-containerd.apparmor.d` | MicroK8s carries it; missing signal rules = pods stuck deleting | Verified: pod deletes cleanly |
| `inspect.sh` strict branches (self-contained) | `systemctl`/`snap`/`ss`/`/var/crash` unreachable under strict | Two code paths (host-invoked vs confined) preserved; core-dump harvest skipped under strict |
| Health gate: `required_interfaces` + `check_snap_interfaces` + configure/install wiring | snapd connects plugs in nondeterministic order; nothing must start before the full set lands | Derives the set from `meta/snap.yaml` — no hand-maintained list (MicroK8s's three disagreeing lists are the counterexample) |
| Interface-gated remove teardown | MicroK8s precedent: cleanup must degrade when a plug is disconnected | Skips silently; documented in code |
| `init.sh` connects interfaces (strict only) + assertions; `connect-interfaces.sh` derives the set from `meta/snap.yaml` | Host-side entry point for tests/docs; single source of truth | Host-only by design (a confined process can't run `snap`) |
| `network-requirements.sh`: assertion-only | LP#2047798/#2053271 Fix Committed (sed patches obsolete); bpffs is snap-confine-mounted (LP#2048506 Won't Fix) | Asserts instead of mutating; actionable error message |
| Executable `pre-refresh`/`post-refresh` hooks | snapd silently skips non-executable hooks — the 1.36 k8s-dqlite upgrade guard may never have fired (latent bug) | None |
| Dead code: dqlite wrapper, pebble k8s-dqlite | 1.36 hard-fails upgrades with dqlite state | Pebble kept for classic, excluded from strict via the patch |

### 3.2 Packaging & build (`snap/snapcraft.yaml`, `build-scripts/`) — Phases S/2/3

| Change | Why | Trade-offs |
|---|---|---|
| runc `strict-patches/v1.4.2` (from MicroK8s); stale v1.1.x deleted | The AppArmor change-profile series is the hardest strict problem; v1.1.x cannot apply to v1.4.3 | Verified applying to runc v1.4.3 in build order, and live: pods run under `cri-containerd.apparmor.d` |
| `print-patches-for.py`: sorted application + anchored `confinement: strict` match | Order-dependent series; raw substring matched comments and silently enabled strict patches on classic builds | Anchored line test is stricter than before |
| D10: LIEF override-prime gated on confinement | ELF retarget to `/snap/core22/current` is wrong under strict (base is rootfs) | Classic keeps LIEF on amd64/arm64 |
| **All parts `no-patchelf` in the strict patch** | snapcraft's own `enable-patchelf` does the same retargeting — denied under strict (MicroK8s's answer) | One more reason the flavor patch must own the delta |
| Plugs (10 custom) + per-app sets + hook sets | Least privilege where viable (control-plane apps slim), heavy sets only where required (kubelet, kube-proxy, containerd, CLI) | Super-privileged interfaces (docker-support, system-files, home read:all, kernel-module-load) need store approval (0a) |
| Layouts: 8 binds into `$SNAP_COMMON` + bind-file `/etc/nanorc` | Base-owned paths can't be granted; `/etc/containerd`, `/var/lib/containerd`, `/run/containerd` are relocated by k8sd itself under strict (verified in k8sd source) | Host can't see them (D12 trade-off, tested); install hook pre-creates sources |
| system-files grants: `/etc/kubernetes`, `/etc/cni`, `/etc/sysctl.d/1000-cilium.conf`, `/var/log/kubernetes` (+ read-only variant) | D12: the host-visible contract (kube-bench CI, cert docs, audit log) survives | Store must approve; exact paths only |
| Explicit PATH (no `/usr/sbin`, `/sbin`, `/usr/games`) + `apparmor_parser` absolute | kubectl plugin discovery lists every PATH dir; `/sbin`→`usr/sbin` merged-usr symlink made the denial appear as `/usr/sbin/` | Cosmetic fix; base tools still resolve |
| k8sd pinned to SHA `08497029` + `build-component.sh` SHA fetch | Only non-tagged component; builds weren't reproducible | Move to a tag when upstream publishes one |
| runc/containerd build.sh: stop mutating the builder's go snap | Raced the pinned `go/1.26-fips/stable` build-snap | Toolchain must be ≥ go.mod directive (holds) |
| k8sd component patches (3) — see §7 | k8sd-side strict blockers found in validation | Carried as default patches; drop when upstream lands |

### 3.3 Tests — Phase 4 (kept on this branch)

| Change | Why |
|---|---|
| `test_strict_interfaces.py` rewritten: un-xfail, derived plug set, blocked→okay health assertions, k8sd enabled+active | The old test was xfail'd *and* logically broken (asserted connections with `connect_interfaces=False`); CI reported a green xfailed placebo |
| Flavor-gated `--classic` everywhere | `snap install --classic` fails on strict snaps |
| D9 bare-track mapping (`_get_flavor` → `""`; `latest/edge` branch mapping; collapsed channel regex) | Channel scheme decision |
| `$SNAP_COMMON` cleanup assertions; skip containerd-base-dir tests under strict | Host-path assertions are vacuous under strict (layouts hide paths; k8sd relocates) |
| `assert_no_apparmor_denials` on the readiness path | Denials otherwise surface as unrelated timeouts (task 38) |
| Confined `k8s inspect` in conftest; skip core-dump setup under strict | Exercise the confined path; `/var/crash` unreachable |

All files compile; pytest collection passes (9 tests in the three touched files).

### 3.4 Docs — Phase 5 (kept)

Install flow (strict section), proxy (drop-in classic-only → `$SNAP_COMMON/args/<service>-env` + `snap logs`), security (health gate, super-privileged interfaces), hardening (audit log stays host-visible via grant), troubleshooting, certificates/kubectl path notes, bootstrap-config (`containerd-base-dir` limitation), AGENTS.md D9 channels, k8s/AGENTS.md pebble/library updates, substrate caveat (LXD VMs only).

Deliberate: classic install docs keep `1.36-classic/stable` — that's what the store actually publishes today.

---

## 4. Validation detail (what was tested, how)

### 4.1 Static / build-time

- Patch resolution: classic prints `patches/v1.2.5` only; strict adds the three
  `strict-patches/v1.4.2` in sorted order. The three patches were `git am`-verified
  against real runc v1.4.3 (and the full series applies in build order).
- `snapcraft expand-extensions` passes on both classic and strict trees.
- All 28→27 declared plugs derive correctly from a rendered mock of
  `meta/snap.yaml` (the health-gate derivation).
- k8sd patches compile-checked **inside the build instance** with the exact CGO
  flags and tags (`dqlite,libsqlite3,ms_tls13kdf`) — `go build ./cmd/main.go` RC=0.
- All edited bash passes `bash -n`; shellcheck shows only pre-existing warning
  classes; all touched Python compiles and collects under pytest.
- 9 full `snapcraft --use-lxd` builds were run during validation (the caching
  footgun — nil-plugin parts not re-detected — is documented in
  `build-scripts/AGENTS.md`).

### 4.2 Runtime (built snap, LXD VM, 4 vCPU/8 GiB)

| Check | Result |
|---|---|
| Install without `--classic`; `confinement: strict` in meta/snap.yaml | ✅ |
| All 27 plugs connect via `init.sh`; `snap connections k8s` complete | ✅ |
| Health gate: `blocked` with derived missing list → `okay`; k8sd `enabled active` | ✅ |
| 9/9 layouts mounted in the snap namespace; sources created by install hook | ✅ |
| systemd drop-in absent under strict | ✅ |
| `k8s bootstrap` | ✅ (after /etc/cni fix) |
| `k8s status --wait-ready` → `cluster status: ready` | ✅ (after /proc PID fallback) |
| Node `Ready` (v1.36.4); Cilium agent 1/1; all kube-system pods Running | ✅ |
| Pod lifecycle: schedule → Running → `kubectl exec` → clean delete | ✅ (signal rules incl. `//&unconfined`) |
| Pod profiles: coredns under `cri-containerd.apparmor.d (enforce)` | ✅ runc patches live |
| Steady-state AppArmor denials | **0** (after PATH fix; was 354/30min at first boot) |
| `k8s inspect` full report | ✅ |
| k8sd serves via `snapctl` (services started during bootstrap) | ✅ |

### 4.3 Environment caveats measured during validation

- **Substrate:** unprivileged LXD **containers** cannot run kubelet
  (`/dev/kmsg` denied by the kernel even when the device is mapped). LXD **VMs**
  work. Docs now say "validated on LXD VMs only".
- **Sizing:** 1 vCPU / 889 MiB wedges etcd/apiserver/dqlite into a timeout storm
  (leader-election failures masquerade as confinement bugs). Validation used
  4 vCPU / 8 GiB.

---

## 5. The eleven validation-found bugs (all fixed and committed)

These are the plan-blind items only a real build could surface — the reason to
treat any unbuilt strict tree as unverified:

1. **`k8s-kubelet` duplicate `systemd_run` hat.** kubernetes-support's default
   and kubelet flavors both inject the same named hat → AppArmor compile error on
   connect. Rule learned: **at most one kubernetes-support plug per app/hook.**
2. **kube-proxy had two such plugs** → keeps only the tailored `k8s-kubeproxy`
   flavor (least privilege, and it compiles).
3. **connect-plug hooks had no plugs.** A hook's profile comes from its own
   declarations, not the trigger interface; the configure body died writing
   `/etc/sysctl.d/1000-cilium.conf`. All 27 declared (MicroK8s does the same).
4. **k8sd's `snap` CLI is AppArmor-denied under strict** (present but unusable
   without snapd-control) → `StartServices/StopServices/RestartServices` failed;
   component patch switches `buildServiceCommand` to `snapctl` (verified working
   from an app context, incl. `--enable`/`--disable`). Plus a compile fix
   (`Strict()` method, not field) caught by the clean rebuild.
5. **`/etc/cni` parent grant.** k8sd `MkdirAll(/etc/cni/net.d)` writes to the
   parent path; `system-files` on `/etc/cni/net.d` doesn't cover it.
6. **kubelet `make-rshared` form.** Two-arg `remount --make-rshared SRC DST` is
   denied; single-arg on the layout mount point works and marks the peer group
   shared.
7. **snapcraft `enable-patchelf` retargets binaries** to `/snap/core22/current` —
   denied under strict; all parts flipped to `no-patchelf` (k8sd keeps working via
   its own `$ORIGIN/../lib` RPATH).
8. **cilium init containers `nsenter` to the host mount namespace**, where the
   `/opt/cni/bin` layout is invisible → chart's `cni.binPath` must be the
   host-visible `$SNAP_COMMON` spelling (k8sd patch adds `SnapCommonDir()`).
9. **`RunningServiceArgs` used `systemctl`** (denied) → `/proc` argv[0] fallback
   with a one-shot probe gate; fixes `k8s status` readiness **and** the args-drift
   controller.
10. **kubectl plugin-discovery dir-list denials** → explicit PATH without
    `/usr/sbin`, `/sbin`, `/usr/games` (`/sbin` is a merged-usr symlink; AppArmor
    resolves it to `/usr/sbin`).
11. **`confinement: strict` raw substring test** false-positived on comments and
    silently applied strict runc patches to classic builds → anchored.

---

## 6. Missing, deferred, or external

### 6.1 Deferred on this branch (reverted by request)

**CI plumbing** (`d6f6ba97`, `6d6d23ad`, `be81e316`); full list in
`openspec/changes/strict-ci-plumbing/`:

1. `lint_and_integration.yaml`: matrix `patch: ["", "strict"]`; drop stale comment.
2. `e2e-tests.yaml`: flavor in artifact/test names; `TEST_STRICT_INTERFACE_CHANNELS`
   strict-only.
3. `nightly-test.yaml`, `weekly-test.yaml`, `compare-performance.yaml`: flavor input
   pass-through. `trivy.yaml` unchanged (published channels only).
4. New `.github/workflows/strict.yaml`: push `autoupdate/<branch>-strict` (fetch
   before `--force-with-lease`).
5. `create_release_branch.md`: drop non-existent workflow refs; `update-components.yaml`
   PR body: per-version patch-dir reminder.
6. **Land order:** `test_branches.py` derives flavors from
   `build-scripts/patches/<flavor>` — once `patches/strict/` exists it requires the
   `autoupdate/*-strict` branches and the `k8s-snap-<track>-strict` LP recipe.
   Land (4), the LP recipes, and bare-track registration **together with** the
   `patches/strict/` directory, or `test-branches` fails.
7. Substrate matrix: validate Multipass/LXD-VM before claiming support.

### 6.2 External (not in this repo)

- **0a — Store snap-declaration** for `docker-support` (privileged), `system-files`
  (the four grants), `home` read:all, `kernel-module-load`. All are
  `allow-installation: false` + `deny-auto-connection: true` — the store gates
  *installation*, not just auto-connection.
- **0b — bare `1.36` track** registration; confirm whether 1.32/1.33 strict used it.
- **0c — k8sd upstream** (§7).
- **0d — `assumes: [snapd2.62]`** is pinned from bug-fix comments; confirm the exact
  landing release before publishing.
- kube-bench external cfg for the audit log path (plan task 45, external repo).
- `containerd-base-dir` fail-fast (D11): the option is parsed by k8sd's bootstrap —
  belongs upstream; the two custom-base-dir tests are skipped under strict meanwhile.
- `TasksMax` has no strict equivalent (docker-support gives Delegate but no task cap).

### 6.3 Known cosmetic noise (k8sd-side, logged for 0c)

- `/run/snapd.socket` connect denials (k8sd's revision lookup for node labels,
  LXD/microk8s detection probes) — non-fatal, degrades gracefully.
- `kube-proxy --cleanup` exit-1 log from k8sd when kube-proxy is disabled by design
  (kube-proxy-replacement is implied by the network feature).
- Cilium's `Unconfined` pod stays in the shim's `snap.k8s.containerd` profile; one
  harmless `file_lock` denial on `/run/cilium/deleteQueue/lockfile` (docker-support
  profile doesn't cover it; cilium works).

---

## 7. Upstream actions

### k8sd (`github.com/canonical/k8sd`, release-1.36 @ `08497029`)

Shipped here as `build-scripts/components/k8sd/patches/default/000{1,2,3}-*.patch`
(compile-verified against the pinned SHA):

1. **`snapctl` for service management under strict** (`pkg/snap/snap.go`
   `buildServiceCommand`): the `snap` CLI is AppArmor-denied inside a confined snap.
2. **`SnapCommonDir()` accessor + cilium `binPath`** (`pkg/snap/interface.go`,
   `pkg/snap/snap.go`, `pkg/snap/mock/mock.go`,
   `pkg/k8sd/features/cilium/network.go`): under strict, pod hostPath mounts resolve
   in the snap's namespace but cilium init containers nsenter to the host's; the
   chart's CNI bin dir must be spelled with the host-visible `$SNAP_COMMON` path.
3. **`RunningServiceArgs` /proc fallback** (`pkg/utils/services.go`): `systemctl` is
   denied under strict; scan `/proc` for the service argv[0]. One-shot probe gate.

Additionally, not patched here (recommend upstream follow-ups):

4. Replace snapd-socket calls (`Revision()` node-label lookup; LXD/microk8s probes)
   with `snapctl`-compatible or degradable paths under strict.
5. Skip `kube-proxy --cleanup` (or its error logging) when kube-proxy is disabled by
   design.
6. D11: fail fast when a custom `containerd-base-dir` is unreachable under strict.
7. `Refresh()` already errors under strict — keep and document.
8. Consider using `snapctl services` for service state where PIDs aren't needed.

### snapd / store

- Store snap-declaration (0a) and bare track (0b) as above.
- Documented interface facts worth keeping in snapd docs: the `systemd_run` hat is
  embedded in kubernetes-support's Common snippet (one plug per app); `system-files`
  `write:` emits `"<path>{,/,/**}" rwkl` (creation works, parent dirs are separate
  paths); `docker-support` injects `Delegate=true`.

---

## 8. How to verify this work

```bash
git clone <k8s-snap> -b dev-1.36-strict && cd k8s-snap
./build-scripts/patches/strict/apply          # flavor transformation
snapcraft --use-lxd                           # ~40 min cold, ~10 min warm
# in an LXD VM (containers won't run kubelet; 4 vCPU/8GiB minimum):
snap install --dangerous k8s_v1.36.4_amd64.snap
/snap/k8s/current/k8s/hack/init.sh            # connect all 27 interfaces
snap info --verbose k8s | grep -A2 health:    # blocked -> okay
snap services k8s                             # k8sd enabled active
k8s bootstrap && k8s status --wait-ready      # cluster status: ready
k8s kubectl run t --image=ghcr.io/canonical/cilium:1.19.4-ck0 \
  --restart=Never --command -- /usr/bin/bash -c "sleep 600"
journalctl -k | grep 'apparmor="DENIED"'      # steady state: none
```

---

## 9. File map (where things live)

- Flavor patch: `build-scripts/patches/strict/{apply,0001-strict.patch}`
- Runtime gates: `k8s/lib.sh`, `k8s/wrappers/services/containerd`, `snap/hooks/*`,
  `k8s/hack/*.sh`, `k8s/scripts/inspect.sh`, `k8s/profiles/containerd`
- runc patches: `build-scripts/components/runc/strict-patches/v1.4.2/`
- k8sd patches: `build-scripts/components/k8sd/patches/default/000{1,2,3}-*.patch`
- Build fixes: `build-scripts/{build-component.sh,print-patches-for.py}`,
  `build-scripts/components/{runc,containerd}/build.sh`, `snap/snapcraft.yaml`
- Tests: `tests/integration/tests/{test_strict_interfaces,test_cleanup,
  test_version_upgrades,conftest}.py`, `test_util/{util,snap}.py`
- OpenSpec: `openspec/changes/{strict-runtime-readiness,strict-confinement-flavor,
  strict-test-harness,strict-ci-plumbing,strict-docs}/`
