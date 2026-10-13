# Proposal: strict-ci-plumbing

## What

Plumb the strict flavor through CI: build the strict snap in the matrix,
gate the strict-interface test variable on the flavor, replicate flavor
plumbing in the remaining workflows, generate `autoupdate/*-strict`
branches for Launchpad, and fix branch-management references.

## Status: DEFERRED

Deferred per requester decision (2026-10-13): CI enablement lands on a
follow-up branch once reviewed. The work was implemented and then reverted
(`d6f6ba97`, `6d6d23ad`, `be81e316`) so this branch carries only the snap,
runtime, build, test and docs changes. The design below is the concrete
to-do list for that follow-up.

## Why (original motivation)

Phase 4 of the plan (tasks 41-43). `lint_and_integration.yaml` was pinned
to `patch: [""]`, `e2e-tests.yaml` set `TEST_STRICT_INTERFACE_CHANNELS`
unconditionally (a placebo now that the test is real and fails fast against
classic snaps), and `create_release_branch.md` referenced workflows that
did not exist.

## The deferred work, concretely

1. `lint_and_integration.yaml`: matrix `patch: ["", "strict"]` per arch;
   drop the stale comment. (build-snap.yaml already works via
   `build-scripts/patches/strict/apply`.)
2. `e2e-tests.yaml`: include the flavor in test/artifact names; set
   `TEST_STRICT_INTERFACE_CHANNELS` only when `flavor == 'strict'`.
3. `nightly-test.yaml`, `weekly-test.yaml`, `compare-performance.yaml`:
   `flavor` input + pass-through to e2e-tests. `trivy.yaml` unchanged
   (scans published channels; the strict snap is not published yet).
4. `.github/workflows/strict.yaml` (new): apply the flavor patch per
   maintained branch and force-push `autoupdate/<branch>-strict` so
   Launchpad recipes have a pre-patched tree.
5. `.github/ISSUE_TEMPLATE/create_release_branch.md`: drop references to
   non-existent workflows; point at strict.yaml + the matrix.
6. `update-components.yaml` PR body: remind reviewers to check per-version
   patch dirs (incl. runc `strict-patches/`) on version bumps.

## Consequence to handle when landing

Once `build-scripts/patches/strict/` exists on a branch,
`tests/branch_management/tests/test_branches.py` (via `_branch_flavours`)
requires `autoupdate/<branch>-strict` in GitHub and Launchpad and the
`k8s-snap-<track>-strict` recipe. Land item 4 (and the recipes) together
with the `patches/strict/` directory, or `test-branches` fails.
