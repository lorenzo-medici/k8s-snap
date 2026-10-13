# Tasks: strict-ci-plumbing

- [x] 41a. `build-snap.yaml` contract satisfied — `build-scripts/patches/strict/apply` exists (no workflow change needed)
- [ ] 41b. `lint_and_integration.yaml`: extend matrix with the strict entry; drop the stale comment
- [ ] 41c. `e2e-tests.yaml`: plumb flavor through test-name/artifact paths; gate `TEST_STRICT_INTERFACE_CHANNELS` on `flavor == 'strict'` (the placebo variable currently set on every run)
- [ ] 41d. `trivy.yaml`, `nightly-test.yaml`: replicate flavor plumbing
- [ ] 41e. `weekly-test.yaml`, `compare-performance.yaml`: plumb flavor if they invoke build-snap/e2e
- [ ] 42a. `tests/branch_management/tests/test_branches.py`: strict-autoupdate branch assertions
- [ ] 42b. `.github/ISSUE_TEMPLATE/create_release_branch.md`: point at workflows that exist
- [ ] 43. Substrate documentation: charm-e2e-tests.md and multipass.md must not claim Multipass/LXD-VM support until the substrate matrix passes there

## Verification

- [ ] yaml validation of every touched workflow
- [ ] `py_compile` of test_branches.py
