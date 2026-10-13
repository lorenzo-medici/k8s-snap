# Proposal: strict-docs

## What

Document the strict flavor: host-visible contract under confinement,
interface connection flow, proxy-surface change, install instructions, and
the hardening/audit-log caveat.

## Why

Phase 5 of the plan (tasks 44-46). Canonical Kubernetes publishes
`/etc/kubernetes/*` host paths, a systemd drop-in proxy surface and
journalctl-based debugging that all change shape under strict, and users
need the connect-interfaces flow before the snap becomes healthy.

## Key facts to document

- D9: bare track `1.36/stable` for both flavors; classic is default.
- Health gate: snap is `blocked` until all plugs connect
  (`/snap/k8s/current/k8s/hack/connect-interfaces.sh`, `snap connections k8s`,
  `snap info --verbose k8s`).
- D12: `/etc/kubernetes`, `/etc/cni`, `/var/log/kubernetes` stay host-visible
  via system-files (`k8s-etc`/`k8s-etc-ro`/`k8s-audit-log`); layouts relocate
  `/var/lib/kubelet`, `/var/lib/cni`, `/var/lib/kube-proxy`, `/opt/cni/bin`,
  `/usr/libexec`, `/usr/local/lib`, `/var/log/pods`, `/var/log/containers`
  into `/var/snap/k8s/common/`; containerd dirs move under `$SNAP_COMMON`.
- D14: proxy configuration moves from the systemd drop-in (classic) to
  `$SNAP_COMMON/args/<service>-env` (strict); debugging via
  `snap logs -n=all k8s.<svc>`.
- `containerd-base-dir` is bootstrap/join-time only and unsupported under
  strict; `/var/crash` is unreachable (no core-dump harvest in `k8s inspect`).

## Implementation status

In progress (delegated implementation; this file will be updated when the
doc edits land).
