# Proposal: strict-test-harness

## What

Make the integration test harness flavor-aware so the strict snap is tested
for real: derived interface assertions, flavor-gated `--classic`, D9
bare-track channel mapping, strict-aware cleanup and inspect paths, and
AppArmor-denial fail-fast.

## Why

Phase 4 of the plan (tasks 32-40). The existing strict test was
`xfail(run=False)` and logically broken (asserted connections with
`connect_interfaces=False`); CI set `TEST_STRICT_INTERFACE_CHANNELS` on every
run so CI reported a green `xfailed` placebo. Host-path assertions are
vacuous under strict because layouts hide paths from the host and k8sd
relocates containerd state into `$SNAP_COMMON`.

## Key decisions

- Single source of truth for the plug set: `meta/snap.yaml` (same derivation
  as `k8s::common::required_interfaces` and `connect-interfaces.sh`).
- D9: both flavors publish on the bare versioned track; `latest` keeps the
  flavor as a branch (`latest/edge`, `latest/edge/strict`).
- Under strict, run the inspection report through the confined
  `k8s inspect` app so the confined code path is exercised.

## Implementation status

Implemented and committed on `dev-1.36-strict`: `a26aedcc`, `142879a5`,
`e0262734`, `199c1b9b`. Test collection passes (9 tests across the three
touched files).
