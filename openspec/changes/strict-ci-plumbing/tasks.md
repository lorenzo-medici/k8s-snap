# Tasks: strict-ci-plumbing

Status: **DEFERRED** (2026-10-13) — to land on a follow-up branch.

- [ ] 41a. `build-snap.yaml` — no change needed (contract already satisfied by `build-scripts/patches/strict/apply`)
- [ ] 41b. `lint_and_integration.yaml`: matrix `patch: ["", "strict"]` per arch; drop stale comment
- [ ] 41c. `e2e-tests.yaml`: flavor in test/artifact names; strict-only `TEST_STRICT_INTERFACE_CHANNELS`
- [ ] 41d. `nightly-test.yaml`: flavor input + pass-through; `trivy.yaml` unchanged
- [ ] 41e. `weekly-test.yaml`, `compare-performance.yaml`: flavor pass-through
- [ ] 42a. `.github/workflows/strict.yaml`: generate `autoupdate/<branch>-strict` (fetch before force-with-lease)
- [ ] 42b. `create_release_branch.md`: drop non-existent workflow references
- [ ] 42c. `update-components.yaml` PR body: per-version patch-dir reminder
- [ ] 43. Substrate matrix: extend CI validation to Multipass / LXD-VM substrates before claiming support
- [ ] Land together with the LP recipes (`k8s-snap-<track>-strict`) and bare track registration (plan task 0b), since `test_branches.py` requires the autoupdate branches once `build-scripts/patches/strict/` exists

All items were implemented and validated (yaml parses), then reverted per the deferral: see reverted commits `d6f6ba97`, `6d6d23ad`, `be81e316`.
