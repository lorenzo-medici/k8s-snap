# Tasks: strict-confinement-flavor

## Build system (Phase S/3)

- [x] S1. Port runc `strict-patches/v1.4.2`; delete stale v1.1.x; sorted application; verify against runc v1.4.3 (`6f647013`)
- [x] S1. Anchor the `confinement: strict` test in `print-patches-for.py` (`6f647013`)
- [x] D10. Gate LIEF `override-prime` on confinement (`c271f3fe`)
- [x] 29. Stop mutating the builder's go snap in runc/containerd build.sh (`42e0c655`)
- [x] 30. Pin k8sd to `08497029`; `build-component.sh` fetches full SHAs (`b8654fbd`)
- [x] 31. Document `strict-patches/` in build-scripts AGENTS.md/README (`196868ba`)

## Flavor patch (Phase 2)

- [x] 17. Scaffolding `build-scripts/patches/strict/{apply,0001-strict.patch}` (`51c8e1e5`)
- [x] 18. Header: confinement strict, assumes snapd2.62, OPENSSL_MODULES, EDITOR (`51c8e1e5`)
- [x] 19. Layouts: 8 binds into `$SNAP_COMMON` + bind-file `/etc/nanorc` (`51c8e1e5`)
- [x] 20. Top-level plugs (docker-support, kubernetes-support flavor, home read:all, kernel-module-load, 4 system-files grants) (`51c8e1e5`)
- [x] 21. Per-app plug sets (`51c8e1e5`)
- [x] 22. Hook plug sets (`51c8e1e5`)
- [x] 23. Health gate: connect-plug symlinks for all declared plugs; k8sd install-mode disable (`51c8e1e5`)
- [x] 24. Interface-gated teardown (base tree, `d669da75`)
- [x] 25. init.sh connects interfaces + asserts requirements (`7c82ebb2`)
- [x] 26. D11 containerd-base-dir: documented as k8sd companion item (bootstrap/join-time option consumed by k8sd, not the snap)

## Validation-driven fixes (build + LXD smoke test)

- [x] Fix 1: drop `k8s-kubelet` — duplicate `systemd_run` hat with default flavor (`36927064`)
- [x] Fix 2: kube-proxy keeps only `k8s-kubeproxy` — one kubernetes-support plug per app (`bb3816c5`)
- [x] Fix 3: declare all 27 connect-plug hooks with their plug sets (`ca338469`)
- [x] Fix 4: k8sd component patch — `snapctl` for service management under strict (`76dcb78e`, compile fix `4de8c266`)
- [x] Fix 5: `k8s-etc` grants `/etc/cni` (MkdirAll parent), not only `/etc/cni/net.d` (`9dbf7523`)
- [x] Fix 6: k8sd snapctl patch compile fix — `Strict()` method, not `strict` field (`4de8c266`)
- [x] Fix 7: kubelet `make-rshared` targets the layout mount point; the two-arg remount form is denied (`b58e372d`)
- [x] Fix 8: all parts flipped to `no-patchelf` — snapcraft's patchelf retargets to `/snap/core22/current`, denied under strict (`5d893f9a`)
- [x] Fix 9: k8sd cilium patch — `cni.binPath` spelled host-visible under strict (nsenter init containers) 

## Verification

- [x] `apply` produces a schema-valid strict snapcraft.yaml (`snapcraft expand-extensions`)
- [x] Patch resolution: classic prints `patches/v1.2.5` only; strict adds `strict-patches/v1.4.2` in order
- [x] Strict snap builds (`snapcraft --use-lxd`) and installs without `--classic`
- [x] Health gate blocks with derived missing list; converges to `okay`; k8sd enabled+active
- [x] 9/9 layouts mounted in the snap namespace; systemd drop-in absent
- [x] k8sd patch applies and `go build ./pkg/snap/` passes
- [ ] Bootstrap + pod lifecycle (in progress — blocked on the `/etc/cni` rebuild)
- [ ] AppArmor denial sweep after bootstrap
