# OpenPERouter — SRv6 Full Config Deployment (Grout datapath, bare-metal lab)

The [`srv6fullconfig`](../srv6fullconfig/) deployment running on the
bare-metal lab with the **Grout DPDK datapath**: Grout drives the SR-IOV
VFs of the Mellanox `eno12399np0` PF instead of the kernel. The ISIS +
SRv6 underlay, the EVPN/VXLAN overlay and the controller-derived per-node
addressing are unchanged from the kernel datapath; see the
[srv6fullconfig README](../srv6fullconfig/README.md) for the deployment
mechanics (node index and node type derivation, `agent-config.yaml`
structure, MTU sizing, OpenPERouter configuration reference) and
[TOPOLOGY.md](TOPOLOGY.md) for this lab's addressing and peering details.

The Grout datapath is **hardcoded** in the build scripts: FRR runs with
`dplane_grout`, the controller with `--datapath=grout
--grout-socket=/run/grout/grout.sock`, and the Grout Butane files are
always compiled.

## Hardware

| Item | Value |
|------|--------|
| CPU | AMD EPYC 9654P, 1 socket, 192 logical CPUs (NUMA node 0 only) |
| PF | `eno12399np0` (`numa_node` 0), 16 SR-IOV VFs |
| VF 0 | `eno12399v0` — underlay VF (ISIS / SRv6 to the TOR), driven by Grout |
| VF 1 | `eno12399v1` — trunk VF, bound by Grout (`pfName: eno12399np0`, `vfIndex: 1`) |
| VF 2 | `eno12399v2` — host / OpenShift machine network, VLAN 42 |
| IOMMU | **AMD** — `amd_iommu=on`, not `intel_iommu=on` |

The VFs rely on systemd **onboard** naming (`eno12399v0` / `v1` / `v2`). 
The underlay on VF 0 stays **untagged** like the kernel PF.

VLAN **42** on the host VF is an on-node convention: the VF's `vlan-id` in
`agent-config.yaml` must match the L2VNI's `trunk.vlan.tag` in the
OpenPERouter configuration (see below).

### Requirements

- **SR-IOV NIC**: each node needs a NIC with at least 3 VFs, configured in
  [`agent-config.yaml`](configimage/agent-config.yaml):
  - an **underlay VF** (`eno12399v0`), driven by Grout to communicate with
    the fabric
  - a **trunk VF** (`eno12399v1`), with `spoof-check: false` and
    `trust: true`, bound by Grout in the `perouter` namespace
  - a **host VF** (`eno12399v2`), administratively set on VLAN 42, which
    carries the node IP addresses
- **Matching VLAN**: the host VF `vlan-id` must equal
  `l2vnis[].trunk.vlan.tag` in the OpenPERouter configuration file.


## Differences from the kernel datapath

- **No `br0`**: `agent-config.yaml` has no `br0` and `dummy0`. The node IP
  addresses go directly on the host VF (`eno12399v2`), and the default
  routes use it as `next-hop-interface`.
- **`l2trunks` + `trunk` instead of `hostMaster`**: the L2VNI connects to
  the host through the trunk VF rather than through a veth to `br0`. The
  trunk VF is identified by PF name and VF index; `trunk.vlan.tag` must
  match the host VF `vlan-id` in `agent-config.yaml` — an on-node
  convention, 42 here:

  ```yaml
  l2trunks:
    - name: trunk
      type: SRIOV
      sriov:
        pfName: eno12399np0
        vfIndex: 1   # eno12399v1
  l2vnis:
    - vni: 210
      ...
      trunk:
        name: trunk
        vlan:
          tag: 42   # The same as the host VF vlan-id in agent-config.yaml
  ```

- **Dataplane containers**: a [`grout.container`](extras/quadlets/grout.container)
  quadlet runs the Grout dataplane in the router pod, and
  [grout-reservation static pods](extras/config/pod-grout-reservation-master.yaml)
  reserve isolated CPUs and 1 GiB hugepages for it.
- **IOMMU/VFIO and hugepages**: `intel_iommu=on`, `iommu=pt`, `vfio-pci`
  loaded at boot; 8 × 1 GiB hugepages are reserved at install time and the
  performance profiles raise this to 24 × 1 GiB.
- **MTU**: underlay 1800 (the Grout container runs with
  `GROUT_MAX_MTU=2048`), host VF 1430, cluster network 1330 — see
  [TOPOLOGY.md](TOPOLOGY.md). The `if-mtu*.bu` MachineConfigs pin `br0`'s
  MTU for the kernel datapath and have no effect here.

## Building

- **Appliance ISO**: [`appliance/generate_appliance.sh`](appliance/generate_appliance.sh) `<pull_secret_file>`
- **Config-image ISO**: [`configimage/generate_config_image.sh`](configimage/generate_config_image.sh) `<pull_secret_file>`

Both builds require the Python `yq` (see the [repository README](../README.md)).

Set `OPENPEROUTER_IMAGE` for both ISO builds to use a different image in the
appliance config, the quadlets and the Grout CPU reservation pods. It
defaults to the experimental
`quay.io/apanatto/openperouter-operator:grout-dev-202611`.

## CPU and hugepage reservations

The performance profiles
([`performance-profile-master.yaml`](configimage/performance-profile-master.yaml),
[`performance-profile-worker.yaml`](configimage/performance-profile-worker.yaml))
reserve CPUs `0-15` for housekeeping and isolate `16-47`, allocate 24 × 1 GiB
hugepages on NUMA node 0, and set `amd_iommu=on` / `iommu=pt`.

At boot, `grout.slice` initially allows CPUs `0-6`. The grout-reservation
static pods (`extras/config/pod-grout-reservation-*.yaml`) then pin Grout's
control CPUs to the systemd CPU affinity (the reserved set) and its datapath
CPUs to the isolated set, and re-apply the affinity whenever Grout restarts.

## Layout

```text
srv6fullconfig-grout/
  README.md
  TOPOLOGY.md
  appliance/
    generate_appliance.sh        # grout image + first-boot kargs
    patch_appliance.sh
  configimage/
    agent-config.yaml            # SR-IOV VF layout, host VF VLAN 42
    install-config.yaml.base
    generate_config_image.sh
    generate_machineconfigs.sh   # compiles every .bu, incl. the Grout ones
    openperouter-master.bu       # host stack (quadlets, templates)
    openperouter-worker.bu
    openperouter-master-grout.bu # grout.container, reservation pod, grout.slice, vfio-pci
    openperouter-worker-grout.bu
    grout-kargs-master.bu        # install-time kargs: amd_iommu=on, 8 x 1G hugepages
    grout-kargs-worker.bu
    performance-profile-master.yaml
    performance-profile-worker.yaml
  extras/
    common/prepare-extras.sh     # build-time datapath and image selection
    config/
      openpe_master.yaml         # Grout shape (l2trunks) + lab peers
      openpe_worker.yaml
      pod-grout-reservation-master.yaml
      pod-grout-reservation-worker.yaml
    quadlets/
      grout.container            # Grout DPDK dataplane container
```
