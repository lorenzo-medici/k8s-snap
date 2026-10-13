# Spec delta: documentation

## ADDED Requirements

### Requirement: Strict install documentation

The install documentation SHALL describe the strict flavor end to end:
bare-track install command, running the shipped `connect-interfaces.sh`,
verifying `snap connections k8s` and `snap info --verbose k8s` health.

#### Scenario: user installs the strict flavor

- **Given** the published install docs
- **When** a user follows the strict section
- **Then** they reach a healthy snap without knowing the plug list in
  advance

### Requirement: Path contract documentation

User-facing docs SHALL state which paths stay host-visible under strict
(`/etc/kubernetes`, `/etc/cni`, `/var/log/kubernetes` via system-files) and
which are relocated under `/var/snap/k8s/common/` (layouts and k8sd's
containerd relocation).

#### Scenario: user looks for kubelet state under strict

- **Then** the docs point to `/var/snap/k8s/common/var/lib/kubelet` instead
  of `/var/lib/kubelet`

### Requirement: Proxy surface documentation

Proxy configuration docs SHALL mark the systemd drop-in as classic-only and
document `$SNAP_COMMON/args/<service>-env` plus `snap logs` as the strict
surface.

#### Scenario: strict user configures a proxy

- **Then** the docs direct them to
  `/var/snap/k8s/common/args/containerd-env` and a service restart, not to
  `/etc/systemd/system/`

### Requirement: Known limitations

Docs SHALL state that custom `containerd-base-dir` is unsupported under
strict and that `/var/crash` core-dump collection is unavailable there.

#### Scenario: strict user reads bootstrap config reference

- **Then** the `containerd-base-dir` entry carries the strict limitation
