---
myst:
  html_meta:
    description: "How to install Canonical Kubernetes from the k8s snap."
---

# How to install {{product}} from a snap

<!-- SPREAD SUITE: snap_clean -->

{{product}} is packaged as a [snap], available from the
snap store for all supported platforms.

## Prerequisites

This guide assumes the following:

- You are installing on Ubuntu 22.04 or later, **or** another OS which supports
  snap packages (see [snapd support])
- You have root or sudo access to the machine
- You have an internet connection
- The target machine has sufficient memory and disk space. To accommodate
  workloads, we recommend a system with ***at least*** 20G of disk space and
  8G of memory.

```{note}
If you cannot meet these requirements, please see the [Installing][] page for
alternative options.
```

The snap may conflict with other software such as Docker or containerd,
which is why we recommend using a clean, isolated environment when trying
out {{product}}. If using LXD, use virtual machines rather than containers
(see the [LXD installation guide][lxd-guide] for details).

See the [development env guide] if you'd rather install the snap directly
on your development machine.

## Check available channels (optional)

It is a good idea to check the available channels before installing the snap.
Run the command:

```
snap info k8s
```

...which will output a list of currently available channels. See the [channels
page] for an explanation of the different types of channel.

## Install the snap

The snap can be installed with the snap command:

<!-- SPREAD SKIP -->

```{literalinclude} ../../../_parts/install.md
:start-after: <!-- snap start -->
:end-before: <!-- snap end -->
```

<!-- SPREAD SKIP END -->

<!-- SPREAD
sudo snap install k8s --classic --channel=1.36-classic/stable
-->

### Install the strict flavor (optional)

The `k8s` snap is also available as a `strict` flavor, which runs under
strict confinement: every permission is granted explicitly through snapd
interfaces. Install it from the same track without `--classic`:

```
sudo snap install k8s --channel=1.36/stable
```

```{note}
The strict flavor is being introduced with the 1.36 tracks on the bare
channel scheme (`1.36/stable`); until then the published channels are
`1.xx-classic/<risk>`. See the [channels page] for details.
```

Under strict confinement the snap's services stay disabled until every
required interface is connected. Connect them with the shipped helper
script (it derives the set from the snap itself):

```
sudo /snap/k8s/current/k8s/hack/connect-interfaces.sh
```

Check that all interfaces are connected and that the snap reports healthy:

```
snap connections k8s
snap info --verbose k8s
```

The `health` field should show `okay` (until all plugs are connected it
shows `blocked` and names the missing ones). A few interfaces
(`docker-support`, the `system-files` grants, `home` with `read: all` and
`kernel-module-load`) are super-privileged and additionally require Snap
Store approval.

```{note}
The strict flavor is validated on LXD virtual machines. Other substrates
(Multipass, LXD containers, nested containers) are not yet validated for
strict confinement.
```

## Bootstrap the cluster

Installing the snap sets up all the parts required to run Kubernetes. The next
step is to `bootstrap` the cluster to activate the services:

```
sudo k8s bootstrap
```

This command will output a message confirming local cluster services have been
started.

```{note}
Additional configuration is possible by passing a YAML file. The various
options are described in the [bootstrap reference documentation][bootstrap].
```

## Confirm the cluster is ready

It is recommended to ensure that the cluster initializes properly and is
running with no issues. Run the command:

```
sudo k8s status --wait-ready --timeout 3m
```

This command will wait until the cluster indicates it is ready and then display
the current status. The command will time-out if the cluster does not reach a
ready state.

<!-- LINKS -->

[Installing]: ./index
[channels page]: ../../explanation/channels
[snap]: https://snapcraft.io/docs
[snapd support]: https://snapcraft.io/docs/installing-snapd
[bootstrap]: ../../reference/config-files/bootstrap-config
[development env guide]: ./dev-env.md
[lxd-guide]: ./lxd.md
