# Design: strict-test-harness

## test_strict_interfaces.py (task 32)

Dropped `xfail(run=False)`. Flow per channel: install with
`connect_interfaces=False` → assert `snap info --verbose` reports
`health: blocked` → run the shipped `k8s/hack/init.sh` → assert every plug
derived from `meta/snap.yaml` is connected (`snapctl is-connected` via
`snap run --shell`) → assert health flips to `okay` and k8sd becomes
`enabled active`. `snapctl is-connected` fails with "no such plug" for
undeclared names, so the expected set is parsed from `meta/snap.yaml`
(pyyaml union of app/hook plugs) instead of being hand-maintained.

## Flavor gates (tasks 33, 36, 39, 40)

- `setup_k8s_snap`/`snap_refresh`: `--classic` only when
  `config.FLAVOR != "strict"`.
- `remove_k8s_snap`: mount greps anchored on `$SNAP_COMMON` paths under
  strict (`/var/snap/k8s/common/var/lib/kubelet/pods`,
  `/var/snap/k8s/common/run/containerd`); the CNI netns wait is re-enabled
  but gated on `cni-*` entries actually existing.
- `conftest` inspection report: under strict, runs
  `cd /home/ubuntu && k8s inspect --all-namespaces` through the confined app
  (output under the home-plug-covered path); classic keeps the host-path
  invocation.
- `setup_core_dumps` skipped under strict (`/var/crash` unreachable);
  docstring notes the limitation.

## D9 channel mapping (task 35)

- `_get_flavor()` maps to an empty track suffix for both flavors
  (bare `1.36`); `_latest_edge_channel()` maps classic→`latest/edge`,
  strict→`latest/edge/strict`.
- `snap.py` collapses the strict/classic channel regex to the bare-track
  pattern and maps `latest` the same way.
- `test_version_upgrades.py`: `--classic` flavor-gated everywhere;
  `/snap/k8s/current/bin/helm` parameterized on `config.SNAP_NAME`.

## Cleanup tests (task 37)

`test_cleanup.py` asserts on the `$SNAP_COMMON` relocation paths under
strict (`/var/snap/k8s/common/etc/containerd`, `.../run/containerd`,
`.../var/lib/containerd`, `.../opt/cni/bin`) — snapd purges them on
`remove --purge`, which is the meaningful strict assertion (the in-snap
paths never exist on the host). The two custom `containerd-base-dir` tests
are skipped under strict (D11).

## Denial detection (task 38)

`wait_until_k8s_ready` calls `assert_no_apparmor_denials` under strict:
scans `journalctl -k` for `apparmor="DENIED"` (ignoring the
`operation="not mount"` mount-flag probe noise) and fails the test with the
denial lines instead of surfacing as an unrelated timeout.
