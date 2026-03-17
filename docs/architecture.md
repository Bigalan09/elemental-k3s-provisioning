# Architecture

This document explains the architecture of the Elemental K3s provisioning system and how the components of this repository relate to each other.

## Management plane concept

The management plane is a Rancher instance running on a separate K3s or RKE2 cluster. It hosts:

- Rancher itself
- Rancher OS Manager (the Elemental Operator)
- Fleet (GitOps engine used by Rancher)
- The `MachineRegistration` and `MachineInventory` CRDs that model provisioned nodes

The management cluster does not run workloads for the provisioned K3s cluster. It is responsible solely for lifecycle management of nodes and clusters.

## Elemental registration flow

1. An Elemental ISO is booted on target hardware.
2. The ISO contains a registration URL pointing to the management cluster.
3. The booted node contacts the management cluster and creates a `MachineInventory` resource.
4. Rancher OS Manager processes the inventory and applies the cloud-init config from the matching `MachineRegistration`.
5. The node installs the Elemental managed OS to the configured device and reboots.
6. After reboot, the node is available for K3s provisioning.

## K3s server and agent responsibilities

### Server nodes

Server nodes run the K3s control plane processes including the API server, scheduler, and controller manager. In a highly available setup, a minimum of three server nodes is recommended with an embedded etcd datastore.

Server nodes in this repository are identified by `role: server` in the node definition file. They receive a `NoSchedule` taint by default to prevent general workloads from being scheduled onto them.

### Agent nodes

Agent nodes run the K3s agent process and accept scheduled workloads. They join the cluster by contacting the K3s server endpoint and presenting the cluster token.

Agent nodes are identified by `role: agent` in the node definition file.

## Hostname assignment

Each node has an explicit `hostname` field in its definition file under `nodes/examples/`. This hostname is the single source of truth and is propagated during rendering to:

- The `metadata.name` of the `MachineRegistration` resource
- The `machineInventoryLabels["elemental.cattle.io/hostname"]` label
- The cloud-init `hostname` field in the rendered cloud-config
- The output directory path `dist/<hostname>/`

This deterministic mapping means that any rendered artefact can be traced back to its source node definition file by hostname alone.

## Nodes as code

Each file in `nodes/examples/` models a single physical or virtual node. The fields in each file map directly to:

- Elemental registration metadata (hostname, labels)
- Cloud-init configuration (SSH keys, hostname)
- K3s role assignment (server or agent)
- Optional network configuration (Tailscale)

This design means that adding a new node to the cluster involves creating one YAML file and running the render script.

## Artefacts produced by this repository

The `scripts/render.sh` script produces the following files for each node under `dist/<hostname>/`:

| File | Description |
|------|-------------|
| `machine-registration.yaml` | `MachineRegistration` CRD applied to the management cluster |
| `cloud-config.yaml` | Cloud-init config for first-boot node configuration |
| `node-role.yaml` | Role assignment config (`NodeRoleConfig` CRD) |
| `cluster-node.yaml` | Cluster node metadata record (`ClusterNode` CRD) |

These artefacts are rendered from templates in `templates/` and can be applied to the management cluster or baked into the Elemental ISO build pipeline.
