# Spec delta: strict-runtime

## ADDED Requirements

### Requirement: Confinement-aware environment setup

The runtime library SHALL build `PATH`/`LD_LIBRARY_PATH` from the snap and
its base only under strict confinement, and SHALL NOT append host
`REAL_PATH`/`REAL_LD_LIBRARY_PATH` tails.

#### Scenario: strict snap starts a service

- **Given** a snap whose `meta/snap.yaml` declares `confinement: strict`
- **When** any wrapper sources `k8s/lib.sh`
- **Then** `PATH` contains only snap and base directories and no host paths

### Requirement: Privilege escalation wrapper

All root-requiring operations in library code and hooks SHALL go through
`k8s::util::run_with_sudo`, which executes directly under strict and through
`sudo --preserve-env` under classic.

#### Scenario: hook runs under strict

- **Given** a strict snap hook executing as root
- **When** it calls `k8s::util::run_with_sudo rm -f <path>`
- **Then** the command runs without requiring a staged `sudo` binary

### Requirement: Sysctl persistence via exact path

Cilium `rp_filter` tuning SHALL be applied by writing `/proc/sys` directly
and persisted at exactly `/etc/sysctl.d/1000-cilium.conf`; distro-owned
`/usr/lib/sysctl.d` files SHALL NOT be modified.

#### Scenario: configure hook on a strict snap

- **Given** the `k8s-sysctl` system-files plug is connected
- **When** the configure hook runs
- **Then** all `net.ipv4.conf.*.rp_filter` keys are 0 and the drop-in exists

### Requirement: Interface-gated teardown

Remove-hook cleanup steps SHALL be skipped with a log line when their
required interface (`network-control` for CNI, `docker-privileged` for
containerd state) is disconnected under strict.

#### Scenario: remove hook with network-control disconnected

- **When** `snap remove --purge` runs under strict without `network-control`
- **Then** CNI cleanup is skipped and the hook succeeds

### Requirement: Health gate

Under strict, the configure hook SHALL report `blocked` health naming the
missing plugs until every plug declared in `meta/snap.yaml` is connected,
and SHALL NOT enable k8sd before then. The required plug set SHALL be
derived from `meta/snap.yaml`, never hand-maintained.

#### Scenario: install without connecting interfaces

- **Then** `snap info --verbose k8s` shows `health: blocked` with the
  missing plug list and all services are `disabled inactive`

#### Scenario: last interface connects

- **Then** the connect-plug hook re-runs configure, k8sd is enabled and
  health flips to `okay`

### Requirement: containerd strict branch

The `aa-exec -p unconfined` re-exec SHALL be classic-only. Under strict the
wrapper SHALL set ulimits mirroring the classic systemd drop-in and write
`/proc/self/oom_score_adj`; the `cri-containerd.apparmor.d` profile load
SHALL remain unconditional.

#### Scenario: containerd starts under strict

- **Given** a strict snap with `docker-privileged` connected
- **When** the containerd service starts
- **Then** it does not invoke `aa-exec` and its `oom_score_adj` is -999

### Requirement: inspect script confinement branches

`k8s inspect` SHALL use `snapctl`/`journalctl` instead of `systemctl`/`snap`
under strict and SHALL skip collectors unreachable from a confined process
(host `snap` CLI, `ss`, `/var/crash`, `dmesg`, `lsmod`, `swapon`,
`/proc/mounts`, `/etc/environment`, registry-mirror units). The script
SHALL remain self-contained (no `lib.sh` dependency).

#### Scenario: inspect runs under strict

- **Given** a strict snap on a bootstrapped node
- **When** `k8s inspect` runs
- **Then** the report contains `snapctl`-derived service logs and no
  `systemctl`/`snap` CLI output, and completes without AppArmor denials

### Requirement: Host init script

`k8s/hack/init.sh` SHALL connect the snap's interfaces (strict only) and
assert host cgroup2/bpffs requirements, and SHALL only ever be invoked from
an unconfined host shell.

#### Scenario: init runs on a strict install

- **Given** a strict snap installed without connected interfaces
- **When** `k8s/hack/init.sh` runs as root on the host
- **Then** every declared plug is connected and the host assertions pass
