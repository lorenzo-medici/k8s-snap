# Tasks: strict-ci-plumbing

- [x] 41a. `build-snap.yaml` contract satisfied — `build-scripts/patches/strict/apply` exists (no workflow change needed)
- [x] 41b. `lint_and_integration.yaml`: matrix `patch: ["", "strict"]`; stale comment dropped
- [x] 41c. `e2e-tests.yaml`: flavor plumbed into test-name/artifact paths; `TEST_STRICT_INTERFACE_CHANNELS` set only for strict runs
- [x] 41d. `nightly-test.yaml`: flavor dispatch input + pass-through; `trivy.yaml` deliberately unchanged (it scans published channels; the strict snap is not published yet)
- [x] 41e. `weekly-test.yaml` (3 call sites), `compare-performance.yaml` (both call sites): flavor pass-through
- [x] 42a. `tests/branch_management/tests/test_branches.py`: no change needed — `_branch_flavours` derives `strict` from `build-scripts/patches/strict/` automatically, so the autoupdate-branch and LP-recipe assertions now cover strict
- [x] 42b. `.github/workflows/strict.yaml` created: applies the flavor patch per maintained branch and pushes `autoupdate/<branch>-strict` for Launchpad recipes (required by 42a); issue template LINKS fixed (dropped references to non-existent workflows)
- [x] 43. Substrate documentation: `charm-e2e-tests.md` does not exist in this tree; the strict install docs carry the "validated on LXD VMs only" caveat instead of claiming Multipass/LXD-container support

## Verification

- [x] yaml validation passes on every touched workflow
- [x] `py_compile` of test_branches.py
