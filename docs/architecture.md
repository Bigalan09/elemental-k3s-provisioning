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

## Environments

The repository supports multiple environments (lab, staging, production), each with independent:

- Cluster configuration (`clusters/<env>/cluster-config.yaml`)
- MachineRegistration defaults (`clusters/<env>/machine-registration.yaml`)
- Node pool definitions (`clusters/<env>/node-pools.yaml`)
- Node inventory (`nodes/<env>/`)

Environments share the same templates but are rendered with their own configuration and node definitions.

## Hostname assignment

Each node's `hostname` field is the single source of truth, propagated to `MachineRegistration` metadata, inventory labels, cloud-init config, and the output path `dist/<env>/<hostname>/`.

## Nodes as code

Each file in `nodes/<env>/` models one node. Fields map to:

- Elemental registration metadata (hostname, labels)
- Cloud-init configuration (hostname)
- K3s role assignment (server or agent)
- Secret references (SSH keys, Tailscale auth keys)

Adding a node = creating one YAML file + running the render script.

## Secret management

No secret material is stored in this repository. SSH authorised keys and registration tokens are managed as Kubernetes Secrets in the management cluster. Node files reference these secrets by name.

| Secret type | How it is referenced |
|-------------|---------------------|
| SSH authorised keys | `sshKeySecretRef` in cluster-config.yaml or per-node override |
| Registration token | `registrationTokenSecretRef` in cluster-config.yaml |
| Tailscale auth key | `tailscale.authKeySecretName` in node definitions (when enabled) |

## Rendered artefacts

`scripts/render.sh` produces per node under `dist/<env>/<hostname>/`:

| File | Description |
|------|-------------|
| `machine-registration.yaml` | `MachineRegistration` CRD for the management cluster |
| `cloud-config.yaml` | Cloud-init config for first-boot |
| `node-role.yaml` | `NodeRoleConfig` CRD |
| `cluster-node.yaml` | `ClusterNode` CRD |
| `seed-image.yaml` | `SeedImage` CRD config inputs |
