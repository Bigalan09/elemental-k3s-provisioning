# Architecture

## Management plane

A Rancher instance on a separate K3s or RKE2 cluster hosts:

- Rancher and Rancher OS Manager (Elemental Operator)
- Fleet (GitOps engine)
- `MachineRegistration` and `MachineInventory` CRDs

The management cluster handles node lifecycle only — it does not run provisioned-cluster workloads.

## Elemental registration flow

1. An Elemental ISO boots on target hardware.
2. The ISO contacts the management cluster using an embedded registration URL.
3. A `MachineInventory` resource is created.
4. Rancher OS Manager applies cloud-init config from the matching `MachineRegistration`.
5. The node installs the OS and reboots.

## K3s roles

**Server nodes** run the control plane (API server, scheduler, controller manager). Minimum three recommended for HA with embedded etcd. Identified by `role: server` and tainted `NoSchedule` by default.

**Agent nodes** run the K3s agent and accept workloads. Identified by `role: agent`.

## Hostname assignment

Each node's `hostname` field is the single source of truth, propagated to `MachineRegistration` metadata, inventory labels, cloud-init config, and the `dist/<hostname>/` output path.

## Nodes as code

Each file in `nodes/examples/` models one node. Fields map to:

- Elemental registration metadata (hostname, labels)
- Cloud-init configuration (SSH keys, hostname)
- K3s role assignment (server or agent)

Adding a node = creating one YAML file + running the render script.

## Rendered artefacts

`scripts/render.sh` produces per node under `dist/<hostname>/`:

| File | Description |
|------|-------------|
| `machine-registration.yaml` | `MachineRegistration` CRD for the management cluster |
| `cloud-config.yaml` | Cloud-init config for first-boot |
| `node-role.yaml` | `NodeRoleConfig` CRD |
| `cluster-node.yaml` | `ClusterNode` CRD |
