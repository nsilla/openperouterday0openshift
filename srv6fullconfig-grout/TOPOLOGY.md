# OpenPERouter Network Topology — ISIS + SRv6 (Grout, bare-metal lab)

## Overview

An ISIS + SRv6 fabric running on top of an OpenShift cluster (3 masters,
optional workers), with a TOR router peering externally. The dataplane is
**Grout (DPDK)**, driving SR-IOV VFs of the `eno12399np0` PF.

- **Underlay**: ISIS Level-1 (IPv6-only), single area `49.0001`, on the
  underlay VF `eno12399v0`
- **L3VPN** (north-south): BGP IPv4/IPv6 VPN with SRv6 encapsulation between all nodes and the TOR
- **L2VPN** (east-west): BGP EVPN with VXLAN (VNI 210) between all cluster nodes, reflected by all 3 masters
- **AS**: 65500 (all iBGP)

```
                        ┌──────────────────────────────┐
                        │        TOR / RemotePE        │
                        │   Router ID: 10.0.0.20       │
                        │   Loopback:  fc00:0:20::1    │
                        │   SRv6 pfx:  fd00:20::/48    │
                        └──────────┬───────────────────┘
                                   │ ISIS L1 (IPv6-only)
                                   │ eno12399v0 (per-node subnets
                                   │             192.168.135-138.x/25
                                   │             2600:52:7:135-138::/64)
                  ┌────────────────┼────────────────┐
                  │                │                │
      ┌────────────────┐   ┌────────────────┐   ┌────────────────┐
      │  master-0      │   │  master-1      │   │  master-2      │
      │----------------│   │----------------│   │----------------│
      │  EVPN RR       │   │  EVPN RR       │   │  EVPN RR       │
      │  SRv6:         │   │  SRv6:         │   │  SRv6:         │
      │   fd00:2:2::/48│   │   fd00:2:3::/48│   │   fd00:2:4::/48│
      │----------------│   │----------------│   │----------------│
      │Host Netns:     │   │Host Netns:     │   │Host Netns:     │
      │  eno12399v2    │   │  eno12399v2    │   │  eno12399v2    │
      │  (br-ex):      │   │  (br-ex):      │   │  (br-ex):      │
      │  .110.2        │   │  .110.3        │   │  .110.4        │
      │----------------|   │----------------|   │----------------|
      │perouter Netns: │   │perouter Netns: │   │perouter Netns: │
      │  lo:  fd00::2  │   │  lo:  fd00::3  │   │  lo:  fd00::4  │
      │  eno12399v0:   │   │  eno12399v0:   │   │  eno12399v0:   │
      │  .135.21       │   │  .136.22       │   │  .137.23       │
      │  135::21       │   │  136::22       │   │  137::23       │
      │                │   │                │   │                │
      │  VRF red:      │   │  VRF red:      │   │  VRF red:      │
      │   br-pe-210    │   │   br-pe-210    │   │   br-pe-210    │
      │   .110.1/24    │   │   .110.1/24    │   │   .110.1/24    │
      │   VNI 210      │   │   VNI 210      │   │   VNI 210      │
      └────────────────┘   └────────────────┘   └────────────────┘
            ▲                   ▲                   ▲
            └─── EVPN RR mesh ──┴─── EVPN RR mesh ──┘

      ┌────────────────┐
      │  worker-N      │   ... (optional; not deployed in the current lab)
      │----------------│
      │  EVPN Client   │
      └────────────────┘
```

## SR-IOV VF layout (per node)

| VF | Name | Purpose | MTU | VLAN |
|----|------|---------|-----|------|
| PF | `eno12399np0` | Mellanox physical function, 16 VFs | 1800 | — |
| 0 | `eno12399v0` | Underlay (ISIS / SRv6 to TOR), driven by Grout | 1800 | untagged |
| 1 | `eno12399v1` | Trunk VF, bound by Grout (`l2trunks` SRIOV, `vfIndex: 1`) | — | trunk for VNI 210 |
| 2 | `eno12399v2` | Host / OpenShift machine network | 1430 | 42 |

## Addressing Scheme

Bridge, loopback, router ID, and SRv6 locator addresses are derived from the node
index — the host position within the `192.0.2.0/24` subnet on the `nodeidx` dummy
interface (e.g. `192.0.2.2` → index 2). For these, the node address is simply the
subnet base + node index.

The `eno12399v0` addresses (ISIS underlay interface) are assigned statically in the agent-config and do not
follow the node index scheme. Each node sits on its own underlay subnet
towards the TOR.

Node types are derived from the node's hostname (if it starts with `master` or `control-plane`,
the node is of type `master`).

| Node | Index | Underlay eno12399v0 IPv4 | Underlay eno12399v0 IPv6 | Host eno12399v2 (br-ex) IPv4 | Host eno12399v2 (br-ex) IPv6 |
|---|---|---|---|---|---|
| master-0 (RR) | 2 | 192.168.135.21/25 | 2600:52:7:135::21/64 | 192.168.110.2 | fd00:110::2 |
| master-1 (RR) | 3 | 192.168.136.22/25 | 2600:52:7:136::22/64 | 192.168.110.3 | fd00:110::3 |
| master-2 (RR) | 4 | 192.168.137.23/25 | 2600:52:7:137::23/64 | 192.168.110.4 | fd00:110::4 |
| worker-0 ¹ | 5 | 192.168.138.24/25 | 2600:52:7:138::24/64 | 192.168.110.5 | fd00:110::5 |

> ¹ The worker-0 entry is commented out in `agent-config.yaml` and the
> cluster is installed with `compute.replicas: 0`; the values are kept for
> future worker deployments.

Cluster VIPs (on the machine network `192.168.110.0/24` / `fd00:110::/64`):

| VIP | IPv4 | IPv6 |
|---|---|---|
| API | 192.168.110.10 | fd00:110::10 |
| Ingress | 192.168.110.11 | fd00:110::11 |

### Address derivation formula

Given node index `N` (e.g. `2`, `3`, `4`):

| Address | Formula |
|---|---|
| Host VF IPv4 | `192.168.110.{N}` |
| Host VF IPv6 | `fd00:110::{N}` |
| Loopback IPv6 | `fd00::{N}` |
| SRv6 Locator | `fd00:2:{N}::/48` |
| ISIS NET | `49.0001.0000.0000.{N}.00` |

### Controller-derived addressing (from underlay resource)

The OpenPERouter controller derives per-node router ID, loopback, and SRv6 locator from these ranges:

| Parameter | Range | Description |
|---|---|---|
| `routerIDCIDR` | `10.0.0.0/24` | Per-node router ID |
| `tunnelEndpoint.cidrs` | `fd00::/64` | Per-node loopback IPv6 (VTEP source) |
| `srv6.locator.basePrefix` | `fd00:2::/48` | SRv6 locator base (uSID f3216) |

Concrete per-node values:

| Node | Router ID | Tunnel Endpoint | SRv6 Locator |
|---|---|---|---|
| master-0 | 10.0.0.2 | fd00::2 | fd00:2:2::/48 |
| master-1 | 10.0.0.3 | fd00::3 | fd00:2:3::/48 |
| master-2 | 10.0.0.4 | fd00::4 | fd00:2:4::/48 |
| worker-0 | 10.0.0.5 | fd00::5 | fd00:2:5::/48 |

### TOR addressing (external, manually configured)

The TOR is configured outside this repository; its values are carried over
from the kernel-datapath deployment of the same lab.

| Parameter | Value |
|---|---|
| Router ID | 10.0.0.20 |
| Loopback IPv6 | fc00:0:20::1 |
| SRv6 prefix | fd00:20::/48 |
| uN (node SID) | fd00:20:: |
| uDT46 (VRF decap) | fd00:20:0:1:: |

## BGP Peering (AS 65500, all iBGP)

### L3VPN sessions (ipv4 vpn + ipv6 vpn)

Cluster nodes peer with the TOR at `fc00:0:20::1` for north-south L3VPN over SRv6,
using `update-source fd00::{N}` (tunnel endpoint) and `capability extended-nexthop`.
The TOR peers back to each node at `fd00::{N}`.

| From | To | AFIs |
|---|---|---|
| each node | TOR (fc00:0:20::1) | ipv4 vpn, ipv6 vpn |
| TOR | fd00::{N} per node | ipv4 vpn, ipv6 vpn |

### EVPN sessions (l2vpn evpn)

All 3 masters are EVPN route reflectors. EVPN peers over the underlay VF
(`eno12399v0`) IPv6 addresses, which all fall inside `2600:52:7::/48`, not
over loopback. The TOR does not participate in EVPN.

**Masters** (each master runs this config):
- `listenRange: 2600:52:7::/48` — accepts RR clients (workers) with `routeReflectorClient`
- Explicit peers with `2600:52:7:135::21`, `2600:52:7:136::22`, `2600:52:7:137::23` — RR-to-RR mesh (plain iBGP, no route-reflector-client)

**Workers** (each worker runs this config):
- Explicit peers with `2600:52:7:135::21`, `2600:52:7:136::22`, `2600:52:7:137::23` — all 3 masters

| From | To | Role |
|---|---|---|
| master (RR) | listenRange 2600:52:7::/48 | route-reflector-client |
| master (RR) | master-0 (2600:52:7:135::21) | RR-to-RR iBGP |
| master (RR) | master-1 (2600:52:7:136::22) | RR-to-RR iBGP |
| master (RR) | master-2 (2600:52:7:137::23) | RR-to-RR iBGP |
| worker | master-0 (2600:52:7:135::21) | client (via listenRange) |
| worker | master-1 (2600:52:7:136::22) | client (via listenRange) |
| worker | master-2 (2600:52:7:137::23) | client (via listenRange) |

## SRv6

Locator format: uSID f3216 (block `32 bits`, node `16 bits`, function `16 bits`).
Encapsulation behavior: `H.Encaps.Red`.

Per-node SRv6 SIDs are derived by the controller from `basePrefix: fd00:2::/48`.

**TOR SIDs** (manually configured):

| SID | Value |
|---|---|
| uN (node SID) | fd00:20:: |
| uDT46 (VRF decap) | fd00:20:0:1:: |

## L2VPN / EVPN (VNI 210)

All cluster nodes (masters and workers) share an L2 segment via VXLAN bridge `br-pe-210`:
- Gateway IP: `192.168.110.1/24` + `fd00:110::1/64` (anycast on all nodes)
- VNI: 210
- RT: 65500:210

The L2VNI reaches the host through the SR-IOV trunk VF (`eno12399v1`,
VLAN 42 towards the host VF `eno12399v2`), instead of the kernel
datapath's veth pair to `br0`.

EVPN type-2 (MAC/IP) and type-3 (BUM/VTEP) routes are exchanged between
all cluster nodes via all 3 masters as route reflectors. The TOR does **not**
participate in EVPN L2 — north-south traffic only via L3VPN.

## L3VPN Routes (VRF red)

### What each cluster node sees

| Prefix | Source | Via |
|---|---|---|
| 192.168.110.0/24 | Local br-pe-210 (L2 gateway) | Connected |

### What the TOR sees

| Prefix | Source | Via |
|---|---|---|
| 192.168.110.{2-4}/32 | Cluster node host VF IPs | SRv6 (per-node uDT46) |

## MTUs

| Segment | MTU |
|---|---|
| PF `eno12399np0` / underlay VF `eno12399v0` | 1800 |
| Host VF `eno12399v2` (machine network) | 1430 (1500 - 70 VXLAN-over-IPv6 overhead) |
| Cluster network (OVN-Kubernetes) | 1330 (1500 - 170 double encapsulation overhead) |
| Grout container (`GROUT_MAX_MTU`) | 2048 |

## ISIS Underlay

- Area: `49.0001`
- Level: L1 only
- IPv6-only: only `ipv6 router isis` on interfaces (no IPv4 ISIS)
- Interface: `eno12399v0` on cluster nodes, dedicated interface on the TOR
- Each node sits on its own subnet towards the TOR:
  `192.168.135.0/25` - `192.168.138.0/25` (IPv4) and
  `2600:52:7:135::/64` - `2600:52:7:138::/64` (IPv6)
- MTU: 1800
