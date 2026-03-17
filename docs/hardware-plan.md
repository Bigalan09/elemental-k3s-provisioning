# Hardware plan

## Target hardware

| Device | CPU | RAM | Storage | NICs | Notes |
|--------|-----|-----|---------|------|-------|
| Mini PC | x86_64, multi-core (assumed 4+ cores) | 8–16 GB (assumed) | NVMe or SATA SSD | 1+ GbE | Most capable device in the lab |
| ZimaBlade | Intel Celeron N3350 (2C/2T) | 2–8 GB LPDDR4 | eMMC + SATA | 1 GbE | Compact single-board server |
| ZimaBoard 1 | Intel Celeron N3450 (4C/4T) | 8 GB LPDDR4 | eMMC + SATA | 2 GbE | SBC with PCIe, dual NIC |
| ZimaBoard 2 | Intel Celeron N3450 (4C/4T) | 8 GB LPDDR4 | eMMC + SATA | 2 GbE | SBC with PCIe, dual NIC |

> **Assumption:** Exact specs depend on the models purchased. The table above reflects the
> common configurations available for each device family. Adjust the node definitions
> if your hardware differs.

## Proposed role assignment

| Device | Hostname | Role | Justification |
|--------|----------|------|---------------|
| Mini PC | mini-pc | `server` (control plane) | Highest CPU, RAM, and storage. The K3s server process, etcd datastore, and API server benefit most from headroom. |
| ZimaBlade | zimablade | `agent` (worker) | Adequate for running workloads but too constrained for control plane duties. |
| ZimaBoard 1 | zimaboard-1 | `agent` (worker) | Good worker node. Dual NIC is useful for network-separated workloads. |
| ZimaBoard 2 | zimaboard-2 | `agent` (worker) | Identical to ZimaBoard 1. Provides additional worker capacity. |

## Why the mini PC is the control plane

The control plane runs:

- The K3s API server
- The embedded etcd datastore (single-node mode)
- The scheduler and controller manager
- CoreDNS
- Any Rancher or management components installed post-bootstrap

These components require:

- **CPU headroom** for API server request handling and etcd writes
- **RAM** for etcd in-memory state and controller caches
- **Fast storage** for etcd WAL and snapshot I/O
- **Reliable networking** for API server availability

The mini PC is the only device in this lab likely to have 8+ GB of RAM, a multi-core
processor, and NVMe or SATA SSD storage. This makes it the clear choice for the single
control plane node.

## Why the Zima devices should be workers

ZimaBlades and ZimaBoards are compact x86 single-board computers. They are well suited
to running containerised workloads but are constrained in ways that make them poor
control plane candidates:

- **ZimaBlade:** The Celeron N3350 is a dual-core part with limited single-thread
  performance. RAM is typically 2–8 GB. This is enough for K3s agent workloads but
  marginal for running the full control plane stack alongside workloads.

- **ZimaBoard:** The Celeron N3450 is a quad-core part with slightly better throughput.
  8 GB RAM and dual NICs make it a solid worker. It *could* serve as a control plane
  in a pinch, but the mini PC is a safer choice.

In a homelab with only four machines and a single control plane, putting the control
plane on the most powerful device and letting the Zima boards handle worker duties
gives the best balance of reliability and capacity.

## Caveats for Zima devices

### Boot device path

Zima devices typically expose their internal eMMC as `/dev/mmcblk0` and SATA drives
as `/dev/sda`. The `installDevice` field in each node definition must match the actual
block device where Elemental should install the OS.

Verify the correct device by booting the Elemental ISO and running:

```bash
lsblk
```

If you are installing to a SATA drive connected to the Zima's SATA port, use `/dev/sda`.
If installing to the eMMC, use `/dev/mmcblk0`.

### BIOS and boot order

Zima devices ship with a minimal BIOS. You may need to:

- Enter the BIOS (typically `DEL` or `F2` during POST)
- Set USB as the first boot device
- Disable Secure Boot if it is enabled (Elemental images are typically unsigned)

### TPM

Most Zima devices lack a hardware TPM. The lab `MachineRegistration` has `emulateTPM: true`
to work around this. This is acceptable in a homelab but would not be appropriate for
production.

### Networking

ZimaBoards have dual Gigabit NICs. By default K3s uses the first interface. If you want
K3s to bind to a specific interface, set `--node-ip` or `--bind-address` in the K3s
configuration. This is not necessary for a simple homelab but is worth noting.

ZimaBlade has a single GbE NIC which is sufficient for homelab use.

## Consequences of a single control plane

With one control plane node:

- **No high availability.** If the mini PC fails, the cluster API is unavailable.
  Existing workloads on workers continue running but cannot be rescheduled.
- **Simpler etcd.** Single-node etcd has no quorum concerns and no leader election
  overhead. Backups are straightforward.
- **Easier upgrades.** Only one node needs to be upgraded for control plane changes.
- **Recovery requires the control plane.** If the mini PC is lost, you must reinstall
  or restore from backup. Workers cannot self-heal without the API server.

For a homelab this is an acceptable tradeoff. The mini PC is the most reliable device
in the set and single control plane avoids the complexity of multi-node etcd.

If reliability becomes a concern later, one of the ZimaBoards could be promoted to
a second server node to provide etcd redundancy (requires 3 server nodes for quorum,
which would mean converting two of the three workers — leaving only one worker).
This is not recommended for a four-node homelab.

## Storage assumptions

| Device | Expected install device | Notes |
|--------|------------------------|-------|
| Mini PC | `/dev/sda` or `/dev/nvme0n1` | Depends on whether the primary drive is SATA or NVMe. Check with `lsblk`. |
| ZimaBlade | `/dev/sda` | SATA drive. If using eMMC, change to `/dev/mmcblk0`. |
| ZimaBoard 1 | `/dev/sda` | SATA drive. Same eMMC caveat as above. |
| ZimaBoard 2 | `/dev/sda` | SATA drive. Same eMMC caveat as above. |

The node definitions in `nodes/lab/` default to `/dev/sda`. Update the `installDevice`
field if your hardware differs.
