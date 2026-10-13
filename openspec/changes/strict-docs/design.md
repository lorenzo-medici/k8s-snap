# Design: strict-docs

## Structure

Each touched page gets a clearly-marked strict subsection or caveat rather
than a rewrite: the classic flow remains the default flavor's contract.

## Content map

- **Install**: `snap install k8s --channel 1.36/stable` (mirroring the
  classic channel syntax), then `sudo
  /snap/k8s/current/k8s/hack/connect-interfaces.sh`, verify with
  `snap connections k8s` and `snap info --verbose k8s` (health: okay), then
  bootstrap as usual.
- **Networking/proxy**: strict users edit
  `/var/snap/k8s/common/args/<service>-env` and restart the service; debug
  with `snap logs -n=all k8s.<service>`.
- **Security**: the interface model — health gate, super-privileged
  interfaces (docker-support privileged, system-files, home read:all,
  kernel-module-load) that need store approval (plan task 0a), and
  docker-support's `Delegate=true` replacing the systemd drop-in.
- **Hardening**: the DISA-STIG audit log stays at
  `/var/log/kubernetes/audit.log` under strict via the `k8s-audit-log`
  system-files plug; note it must be connected.
