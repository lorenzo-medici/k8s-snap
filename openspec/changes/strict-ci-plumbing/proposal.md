# Proposal: strict-ci-plumbing

## What

Plumb the strict flavor through CI: build the strict snap in the matrix,
gate the strict-interface test variable on the flavor, replicate flavor
plumbing in the remaining workflows, and fix branch-management references
to workflows that actually exist.

## Why

Phase 4 of the plan (tasks 41-43). Today `lint_and_integration.yaml` is
pinned to `patch: [""]` ("right now we only support the classic flavor"),
`e2e-tests.yaml` sets `TEST_STRICT_INTERFACE_CHANNELS: "recent 6 strict"`
unconditionally (a placebo now that the test is real and fails against
classic snaps), and `.github/ISSUE_TEMPLATE/create_release_branch.md`
references `strict.yaml`/`strict-integration.yaml` workflows that do not
exist.

## Substrate note (task 43)

`kubelite`-style hybrid cgroup handling is untested on Multipass/LXD-VM;
docs for charm-e2e-tests and multipass installs must not claim support
until the substrate matrix passes on them.

## Implementation status

In progress (delegated implementation; this file will be updated when the
workflow edits land).
