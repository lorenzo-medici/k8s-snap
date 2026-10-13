#!/usr/bin/env bash

# Host-side initialization for the k8s snap. Invoked from an unconfined shell
# (integration tests, docs). Never call this from a hook or a confined app:
# connect-interfaces.sh runs the host 'snap' CLI.

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if grep -q 'confinement: strict' /snap/k8s/current/meta/snap.yaml 2>/dev/null; then
  "$DIR/connect-interfaces.sh"
fi

"$DIR/network-requirements.sh"
