#
# Copyright 2026 Canonical, Ltd.
#
import logging
from typing import List

import pytest
import yaml
from test_util import config, harness, snap, tags, util

LOG = logging.getLogger(__name__)


@pytest.mark.node_count(1)
@pytest.mark.no_setup()
@pytest.mark.skipif(
    not config.STRICT_INTERFACE_CHANNELS, reason="No strict channels configured"
)
@pytest.mark.tags(tags.WEEKLY)
def test_strict_interfaces(instances: List[harness.Instance], tmp_path):
    channels = config.STRICT_INTERFACE_CHANNELS
    cp = instances[0]
    current_channel = channels[0]

    if current_channel.lower() == "recent":
        if len(channels) != 3:
            pytest.fail(
                "'recent' requires the number of releases as second argument and the flavour as third argument"
            )
        _, num_channels, flavour = channels
        channels = snap.get_channels(int(num_channels), flavour, cp.arch, "edge", True)

    for channel in channels:
        # Install without connecting interfaces: the health gate must block
        # the snap until every declared plug is connected.
        util.setup_k8s_snap(cp, channel, connect_interfaces=False)

        # Log the current snap version on the node.
        out = cp.exec(["snap", "list", config.SNAP_NAME], capture_output=True)
        LOG.info(f"Current snap version: {out.stdout.decode().strip()}")

        # The configure hook reports blocked health while plugs are missing.
        LOG.info("Waiting for the snap to report blocked health")
        util.stubbornly(retries=20, delay_s=5).on(cp).until(
            lambda p: "health: blocked" in p.stdout.decode()
        ).exec(["snap", "info", "--verbose", config.SNAP_NAME])

        # Connect all declared interfaces (runs the host-side init script).
        cp.exec(["/snap/k8s/current/k8s/hack/init.sh"])

        check_snap_interfaces(cp, config.SNAP_NAME)

        # The last connection re-triggers configure, which enables k8sd and
        # reports okay health.
        LOG.info("Waiting for the snap to report okay health")
        util.stubbornly(retries=40, delay_s=5).on(cp).until(
            lambda p: "health: okay" in p.stdout.decode()
        ).exec(["snap", "info", "--verbose", config.SNAP_NAME])

        LOG.info("Waiting for k8sd to be enabled and active")
        util.stubbornly(retries=40, delay_s=5).on(cp).until(
            lambda p: " k8s.k8sd " in p.stdout.decode()
            and "enabled" in p.stdout.decode()
            and "active" in p.stdout.decode()
        ).exec(["snap", "services", config.SNAP_NAME])

        cp.exec(["snap", "remove", config.SNAP_NAME, "--purge"])


def declared_interfaces(cp) -> List[str]:
    """Derive the expected plug set from the snap's own metadata.

    This is the single source of truth: snapcraft.yaml's app/hook plug lists,
    as rendered into meta/snap.yaml by the build. `snapctl is-connected` fails
    with 'no such plug' for undeclared names, so a hardcoded list cannot
    distinguish 'not connected' from 'typo' -- deriving it can.
    """
    out = cp.exec(
        ["cat", f"/snap/{config.SNAP_NAME}/current/meta/snap.yaml"],
        capture_output=True,
    )
    doc = yaml.safe_load(out.stdout.decode())
    plugs = set()
    for section in ("apps", "hooks"):
        for _, spec in (doc.get(section) or {}).items():
            plugs.update(spec.get("plugs") or [])
    return sorted(plugs)


def check_snap_interfaces(cp, snap_name):
    """Check that every interface plug the snap declares is connected."""
    interfaces = declared_interfaces(cp)
    LOG.info("Checking %d declared interfaces: %s", len(interfaces), interfaces)
    if not interfaces:
        pytest.fail("No interface plugs declared in the snap's meta/snap.yaml")
    for interface in interfaces:
        cp.exec(
            [
                "snap",
                "run",
                "--shell",
                snap_name,
                "-c",
                f"snapctl is-connected {interface}",
            ],
        )
