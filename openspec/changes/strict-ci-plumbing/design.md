# Design: strict-ci-plumbing

## Matrix

`lint_and_integration.yaml` builds `patch: ["", "strict"]` across
`arch: [amd64, arm64]`; `build-snap.yaml` already invokes
`build-scripts/patches/<flavor>/apply` when `flavor != ""` and names the
artifact `k8s-<flavor>-<arch>.snap`, so no change is needed there.

## Flavor-gated strict-interface variable

`TEST_STRICT_INTERFACE_CHANNELS` moves from an unconditional env entry to a
strict-only value (the test derives expectations from the installed snap's
metadata and fails fast against a classic snap, which declares no plugs).

## Branch management

`create_release_branch.md` keeps requiring `autoupdate/release-1.xx-strict`
branches but references `lint_and_integration.yaml` (matrix) and
`e2e-tests.yaml` (flavor input) instead of the non-existent
`strict.yaml`/`strict-integration.yaml`. `test_branches.py` gains the
strict-autoupdate assertions.
