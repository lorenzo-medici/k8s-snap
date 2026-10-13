# Tasks: strict-docs

- [ ] 44a. `certificates.md`, `kubectl.md`: host paths stay host-visible via `k8s-etc` system-files; layout-relocated paths live under `/var/snap/k8s/common/`
- [ ] 44b. `proxy.md`: systemd drop-in marked classic-only; strict replacement `$SNAP_COMMON/args/<service>-env` + `snap logs`
- [ ] 44c. `bootstrap_config.md`: `containerd-base-dir` bootstrap/join-time only, unsupported under strict
- [ ] 44d. `security.md`: strict flavor, interface model, store-approved super-privileged interfaces
- [ ] 44e. `troubleshooting.md`: `snap logs` and SNAP_COMMON locations
- [ ] 44f. `install.md`: strict install block (install, connect-interfaces.sh, `snap connections k8s`, health check)
- [ ] 45. `hardening.md`: `/var/log/kubernetes/audit.log` stays host-visible via the `k8s-audit-log` grant (D12 option A); the CI/doc-test paths keep working
- [ ] 46. Docs README build matrix + autoupdate PR template strict mention
- [ ] Repo `AGENTS.md`: D9 channel scheme (bare track) and strict flavor machinery pointers
- [ ] `k8s/AGENTS.md`: pebble classic-only; `run_with_sudo` / health-gate functions in the bash library table
