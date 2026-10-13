# Spec delta: ci-cd

## ADDED Requirements

### Requirement: Strict flavor in CI matrix

The integration workflow SHALL build both the classic and strict flavors
per supported architecture, using the flavor-patch contract
(`build-scripts/patches/<flavor>/apply`).

#### Scenario: push to a release branch

- **When** `lint_and_integration.yaml` runs
- **Then** it produces `k8s-amd64.snap` and `k8s-strict-amd64.snap` (and the
  arm64 pair)

### Requirement: Flavor-gated strict interface testing

`TEST_STRICT_INTERFACE_CHANNELS` SHALL be set only for strict runs; a
classic run SHALL NOT carry it (the test now fails fast when the installed
snap declares no plugs).

#### Scenario: classic e2e run

- **When** e2e runs with `flavor: ""` (classic)
- **Then** `TEST_STRICT_INTERFACE_CHANNELS` is empty and the strict
  interface test is skipped

### Requirement: Consistent artifact naming

Test names and artifact paths SHALL include the flavor so classic and
strict runs do not collide.

#### Scenario: upload test artifacts

- **When** an e2e run finishes for flavor `strict`
- **Then** the uploaded artifact names contain `strict`
