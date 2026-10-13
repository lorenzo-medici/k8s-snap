#!/usr/bin/env bash

# Assert host network requirements for the k8s snap.
#
# This script runs on the host from an unconfined shell (via k8s/hack/init.sh).
# The rp_filter tuning it used to apply is now done by the snap itself in the
# configure hook (k8s::util::apply_sysctl_tuning), and the snapd AppArmor
# profile patches were dropped: LP#2047798 and LP#2053271 are Fix Committed.

set -u

if [ "$EUID" -ne 0 ]
then echo "Please run this script as root."
  exit 1
fi

# Require cgroup2 to be mounted
cgroup_hostroot="$(mount -t cgroup2 | head -1 | cut -d' ' -f3)"
if [ -z "$cgroup_hostroot" ]; then
  echo "cgroup2 mount not found, fail"
  exit 1
fi

# Require bpf to be mounted.
# snap-confine mounts /sys/fs/bpf for confined snaps that have access to
# /dev via interfaces (LP#2048506 is Won't Fix), so mounting it here is no
# longer necessary. Assert it instead and fail with an actionable message.
bpf_root="$(mount -t bpf | head -1 | cut -d' ' -f3)"
if [ -z "$bpf_root" ]; then
  echo "/sys/fs/bpf is not mounted."
  echo "Cilium requires a mounted bpffs. Mount it with:"
  echo "    mount -t bpf -o rw,nosuid,nodev,noexec,relatime,mode=700 bpf /sys/fs/bpf"
  exit 1
fi
