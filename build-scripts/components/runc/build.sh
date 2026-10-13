#!/bin/bash

# The Go toolchain is pinned by the build-snaps entry in snap/snapcraft.yaml.
# Do not mutate the builder's installed go snap here (LP: build reproducibility).

VERSION="${2}"

export INSTALL="${1}/bin"
mkdir -p "${INSTALL}"

# Ensure `runc --version` prints the right commit hash from upstream
export COMMIT="$(git describe --long --always "${VERSION}")"

make BUILDTAGS="seccomp apparmor" EXTRA_LDFLAGS="-s -w" static
cp runc "${INSTALL}/runc"
