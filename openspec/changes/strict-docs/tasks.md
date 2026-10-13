# Tasks: strict-docs

- [x] 44a. `certificates.md`, `kubectl.md`: host paths stay host-visible via `k8s-etc`; layout-relocated paths live under `/var/snap/k8s/common/`
- [x] 44b. `proxy.md`: systemd drop-in marked classic-only; strict replacement `$SNAP_COMMON/args/<service>-env` + `snap logs`
- [x] 44c. `bootstrap_config.md`: `containerd-base-dir` bootstrap/join-time only, unsupported under strict
- [x] 44d. `security.md`: strict flavor, health gate, super-privileged interfaces, docker-support Delegate=true
- [x] 44e. `troubleshooting.md`: `snap logs` and SNAP_COMMON locations
- [x] 44f. `install/snap.md`: strict install section (bare `1.36/stable` per D9, connect-interfaces.sh, `snap connections k8s`, health check) + substrate caveat
- [x] 45. `hardening.md`: `/var/log/kubernetes/audit.log` stays host-visible via the `k8s-audit-log` grant (D12 option A); doc-test paths keep working. The external kube-bench cfg update is out of repo (noted in the plan).
- [x] 46. `update-components.yaml` PR body reminds reviewers to check per-version patch dirs (incl. runc strict-patches) on version bumps. The docs README has no build/flavor matrix to extend (verified).
- [x] Repo `AGENTS.md`: D9 bare-track scheme (replacing `1.36-classic/stable`); flavor machinery pointer
- [x] `k8s/AGENTS.md`: pebble classic-only; `run_with_sudo`, `apply_sysctl_tuning`, health-gate functions in the bash library table

## Deliberate deviations

- Install docs keep `--channel=1.36-classic/stable` for the classic flow and
  older version references unchanged: the store currently only publishes
  `1.xx-classic` tracks (verified via the store API); the bare `1.36` track
  arrives with plan task 0b. The strict section documents the D9 scheme.
