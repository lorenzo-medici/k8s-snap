# Tasks: strict-test-harness

- [x] 32. Rewrite `test_strict_interfaces.py`: un-xfail, derive plug set from meta/snap.yaml, assert blocked→okay health transition and k8sd enabled+active (`142879a5`)
- [x] 33. Flavor-gate `--classic` in `setup_k8s_snap`/`snap_refresh` (`a26aedcc`)
- [x] 34/35. D9 bare-track mapping in `test_util/util.py` and `test_util/snap.py`; `latest/edge` branch mapping (`a26aedcc`)
- [x] 36. `$SNAP_COMMON` mount greps; gated CNI netns wait (`a26aedcc`)
- [x] 37. Strict cleanup paths in `test_cleanup.py`; skip containerd-base-dir tests under strict (`e0262734`)
- [x] 38. `assert_no_apparmor_denials` on the readiness path under strict (`a26aedcc`)
- [x] 39. `conftest` inspect via confined `k8s inspect` under strict (`e0262734`)
- [x] 40. Skip `setup_core_dumps` under strict; docstring note (`a26aedcc`, `e0262734`)
- [x] 35 cont. `test_version_upgrades.py` flavor gates + `config.SNAP_NAME` helm paths (`199c1b9b`)

## Verification

- [x] `python3 -m py_compile` on all touched files
- [x] pytest collection passes (9 tests in the three touched test files, in an isolated venv)
