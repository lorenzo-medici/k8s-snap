# Proposal: strict-runtime-readiness

## What

Make the classic-branch runtime payload (`k8s/lib.sh`, service wrappers, snap
hooks, `inspect.sh`, hack scripts) safe to run under strict confinement, with
every behavioral difference gated on `k8s::common::is_strict` so the classic
snap is byte-for-byte behaviorally unchanged.

## Why

This is Phase 1 of the strict confinement plan
(`STRICT_CONFINEMENT_FINDINGS_AND_PLAN.md`). The classic snap deliberately
escapes confinement today: `aa-exec -p unconfined`, host `sudo`, `systemctl`,
host sysctl/systemd writes, hardcoded `/snap/k8s/current` paths and
`REAL_PATH`/`REAL_LD_LIBRARY_PATH` fallbacks. None of that can work under
strict. The MicroK8s blueprint shows each piece needs an `is_strict` branch.

## Non-goals

- No `snapcraft.yaml` confinement flip, plugs or layouts (that is
  `strict-confinement-flavor`).
- No test/CI changes (that is `strict-test-harness` / `strict-ci-plumbing`).
- No k8sd (external Go repo) changes beyond what ships as a component patch
  (tracked in `strict-confinement-flavor`).

## Key decisions (from the plan)

- D1: runtime differences live on the classic branch behind `is_strict()`;
  the strict delta is a build-time flavor patch.
- D10: LIEF ELF retargeting stays for classic only (implemented in
  `strict-confinement-flavor`).
- D14: the systemd drop-in proxy surface is classic-only; strict uses
  `$SNAP_COMMON/args/<service>-env`.
- The sysctl drop-in the snap persists is exactly
  `/etc/sysctl.d/1000-cilium.conf` (exact path, system-files compatible);
  k8sd writes no sysctl file under strict (verified in k8sd release-1.36:
  `pkg/k8sd/app/hooks_bootstrap.go` skips system tuning when strict).

## Implementation status

Implemented and committed on `release-1.36` (commits `d669da75`,
`9981cdeb`, `7c82ebb2`, `c5bbc47b`, `25fcc231`, `7eb2dff1`).
