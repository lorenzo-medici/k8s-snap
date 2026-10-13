# AGENTS.md - k8s-snap

Canonical Kubernetes snap. Bundles upstream Kubernetes, etcd, containerd, runc, CNI plugins,
helm, and k8sd into a single classic/strict snap package.

Before working in a subfolder, read its `AGENTS.md`:

| Folder | AGENTS.md | What it covers |
|--------|-----------|----------------|
| `build-scripts/` | [build-scripts/AGENTS.md](build-scripts/AGENTS.md) | component structure, patching algorithm |
| `k8s/` | [k8s/AGENTS.md](k8s/AGENTS.md) | bash library conventions, runtime paths, services |
| `tests/integration/` | [tests/integration/AGENTS.md](tests/integration/AGENTS.md) | test harness, tagging, utilities, linting |
| `docs/` | [docs/AGENTS.md](docs/AGENTS.md) | design proposals, Spread tests, docs build |

## Repository Layout

```
snap/snapcraft.yaml              snap definition; parts reference build-scripts/components/*
build-scripts/                   component build scripts (see build-scripts/AGENTS.md)
k8s/                             snap runtime: lib.sh, wrappers, manifests (see k8s/AGENTS.md)
ci/                              CI automation Python (GitHub Actions, tox, Mattermost)
tests/integration/               pytest integration tests (see tests/integration/AGENTS.md)
docs/                            MkDocs user docs and proposals (see docs/AGENTS.md)
```

## Multi-Repo Dependencies

The snap coordinates three repos:

| Repo | Purpose |
|------|---------|
| `github.com/canonical/k8s-snap` | this repo — snap shell, build scripts, integration tests |
| `github.com/canonical/k8sd` | Kubernetes daemon (Go backend) |
| `github.com/canonical/k8s-snap-api` | shared Go API types between k8sd and snap clients |

API changes require PRs in all three. During development, add a `replace` directive in
`k8sd/go.mod` pointing to a local k8s-snap-api checkout; remove it before merging.

## Snap Build

Built with `snapcraft --use-lxd`. Architectures: `amd64`, `arm64`, `ppc64el`, `s390x` (see `snap/snapcraft.yaml` for snap base and other build metadata).
Uses `go/<version>-fips/stable` for all Go component builds. FIPS mode is a first-class concern.

## Snap Channels

Channel format (since 1.36, D9): bare `{major}.{minor}/{risk}`, e.g. `1.36/stable` — both
flavors publish on the same track; `classic` is the default flavor. Earlier tracks were
flavor-suffixed (`1.35-classic/stable`, `1.35-strict/stable`).
Flavors: `classic` (default), `strict`. Risk levels (ascending): `stable`, `candidate`, `beta`, `edge`.

## Flavors

The strict flavor is a build-time transformation of this tree:
`build-scripts/patches/strict/apply` applies `0001-strict.patch` (confinement, plugs,
layouts, hook plugs) before `snapcraft --use-lxd` runs. All runtime differences live on
the classic branch behind `k8s::common::is_strict` ([k8s/lib.sh](k8s/lib.sh)).
