# Spec delta: test-infrastructure

## ADDED Requirements

### Requirement: Flavor-aware installation

Test helpers SHALL pass `--classic` to `snap install`/`snap refresh` only
for classic builds, and SHALL run `k8s/hack/init.sh` to connect interfaces
when `connect_interfaces=True`.

#### Scenario: install strict snap by path

- **Given** `TEST_FLAVOR=strict` and a local snap file
- **When** `setup_k8s_snap` runs
- **Then** the install command omits `--classic`

### Requirement: Derived interface assertions

The strict interface test SHALL derive the expected plug set from the
installed snap's `meta/snap.yaml` and SHALL assert the health-gate
transition: blocked after install without connections, okay with k8sd
enabled+active after connecting all plugs. It SHALL NOT be marked xfail.

#### Scenario: strict channel under test

- **Given** a strict snap installed without connected interfaces
- **Then** the test observes `health: blocked`, connects interfaces via the
  shipped init script, and observes `health: okay`

### Requirement: D9 channel mapping

Channel helpers SHALL map both flavors to the bare versioned track
(`1.36/<risk>`) and SHALL map `latest` to `latest/edge` for classic and
`latest/edge/strict` for strict.

#### Scenario: resolve previous track

- **Given** `TEST_FLAVOR=strict`
- **When** `previous_track` resolves a versioned track
- **Then** the result has no flavor suffix (e.g. `1.35`)

### Requirement: Strict-aware cleanup assertions

Cleanup tests SHALL assert on the `$SNAP_COMMON` relocation paths under
strict (the in-snap host paths never exist on the host, so asserting them
would be vacuous), and SHALL skip custom `containerd-base-dir` scenarios
under strict.

#### Scenario: snap removed under strict

- **When** `snap remove --purge k8s` completes
- **Then** `/var/snap/k8s/common/{etc,run,var/lib}/containerd` and
  `/var/snap/k8s/common/opt/cni/bin` do not exist

### Requirement: Denial fail-fast

Under strict, the bootstrap readiness path SHALL fail the test with the
kernel-log AppArmor denial lines when any `apparmor="DENIED"` entries exist
(excluding `operation="not mount"` probe noise), instead of surfacing them
as unrelated timeouts.

#### Scenario: denial during bootstrap

- **Given** a strict node whose kubelet hits an AppArmor denial
- **When** `wait_until_k8s_ready` completes
- **Then** the test fails with the denial lines in the message

### Requirement: Confined inspect invocation

Under strict, the inspection report fixture SHALL invoke `k8s inspect`
through the confined app (writing under a home-plug path); classic SHALL
keep the host-path invocation.

#### Scenario: report generated under strict

- **When** the inspection fixture runs with `TEST_FLAVOR=strict`
- **Then** the report tarball is produced at
  `/home/ubuntu/inspection-report.tar.gz` by the confined app
