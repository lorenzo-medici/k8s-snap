#!/usr/bin/env bash

# Connect every interface plug the k8s snap declares. The plug set is derived
# from the snap's own metadata, so this script never drifts from snapcraft.yaml.
# Keep the awk extraction in sync with k8s::common::required_interfaces
# (k8s/lib.sh) and the strict-interface tests.
#
# Must run on the host as root from an unconfined shell: a strictly confined
# process cannot invoke the 'snap' CLI.

set -ue

if [ "$EUID" -ne 0 ]
then echo "Please run this script as root."
  exit 1
fi

SNAP_YAML="/snap/k8s/current/meta/snap.yaml"

INTERFACES=$(awk '
  /^    plugs:$/ { in_plugs=1; next }
  in_plugs && /^    - / { sub(/^    - /, ""); print; next }
  /^    plugs: \[/ { gsub(/[\[\]]/, ""); split($0, a, ": "); n=split(a[2], b, ","); for (i=1; i<=n; i++) { gsub(/ /, "", b[i]); print b[i] }; next }
  { in_plugs=0 }
' "$SNAP_YAML" | sort -u)

if [ -z "$INTERFACES" ]; then
  echo "No interface plugs found in $SNAP_YAML"
  exit 0
fi

for iface in $INTERFACES; do
  snap connect "k8s:${iface}"
done
