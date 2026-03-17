# Architecture

## Overview

This homelab uses Rancher Elemental to provision a single K3s cluster on four
bare-metal machines managed from a MacBook. The architecture prioritises simplicity
and recoverability over high availability.

## Components

### Management plane

The management plane handles node lifecycle, OS provisioning, and cluster orchestration.
In this homelab, the management plane runs **inside the target cluster itself** after
bootstrap (see the Rancher placement section below for the full rationale).

The management plane consists of:

- **Rancher** — web UI and API for cluster management
- **Rancher OS Manager (Elemental Operator)** — watches `MachineRegistration` and
  `MachineInventory` CRDs to orchestrate OS installation and node lifecycle
- **Fleet** — GitOps engine bundled with Rancher

### Workload cluster

The workload cluster is the K3s cluster running on the four homelab machines:

- **1 server node** (`mini-pc`) — runs the K3s control plane, embedded etcd, and
  (post-bootstrap) Rancher and the Elemental Operator
- **3 agent nodes** (`zimablade`, `zimaboard-1`, `zimaboard-2`) — run workloads

### Elemental

Elemental is the OS provisioning system. It provides:

- A bootable ISO that registers bare-metal machines with a management cluster
- Cloud-init integration for first-boot configuration
- Immutable OS management with atomic upgrades
- `MachineRegistration` and `MachineInventory` CRDs for declarative node lifecycle

### OS Manager (Elemental Operator)

The Elemental Operator runs in the management plane (on the cluster after bootstrap)
and:

- Processes `MachineRegistration` resources to generate registration URLs
- Creates `MachineInventory` entries when nodes register
- Applies cloud-init configuration from the matching registration
- Triggers OS installation and reboot

### K3s

K3s is the lightweight Kubernetes distribution running on all four machines:

- **Server nodes** run the API server, scheduler, controller manager, and embedded
  etcd. In this homelab there is one server (`mini-pc`).
- **Agent nodes** run the kubelet and kube-proxy to schedule and run workloads.
  The three Zima devices are agents.

### This repository

This repository is the **source of truth** for node definitions and cluster
configuration. It:

- Defines each node as a YAML file in `nodes/lab/`
- Provides rendering templates in `templates/`
- Contains a render script (`scripts/render.sh`) that produces per-node Kubernetes
  manifests and cloud-init configs in `dist/`
- Contains a validation script (`scripts/validate.sh`) that checks all shell scripts,
  YAML files, and rendered artefacts
- Runs CI via GitHub Actions on every push and PR

## Environments

The repository supports multiple environments (lab, staging, production), each with
independent:

- Cluster configuration (`clusters/<env>/cluster-config.yaml`)
- MachineRegistration defaults (`clusters/<env>/machine-registration.yaml`)
- Node pool definitions (`clusters/<env>/node-pools.yaml`)
- Node inventory (`nodes/<env>/`)

The homelab uses the `lab` environment. Staging and production environments are
available for future use.

## Hostname assignment

Each node's `hostname` field is the single source of truth. It is propagated into:

- `MachineRegistration` metadata and labels
- `MachineInventory` labels
- Cloud-init configuration (sets the OS hostname)
- The output path `dist/<env>/<hostname>/`

## Where node roles are declared

Node roles (`server` or `agent`) are declared in the node definition files under
`nodes/lab/`. The `role` field maps to:

- The `elemental.cattle.io/role` label on `MachineRegistration` and `MachineInventory`
- The `spec.role` field in the rendered `NodeRoleConfig`
- The K3s installation mode (server or agent) applied during provisioning

## Where orchestration and lifecycle management happen

| Function | Where it lives |
|----------|----------------|
| Node definitions (source of truth) | This repository (`nodes/lab/`) |
| Rendering and validation | MacBook (local) or GitHub Actions (CI) |
| Rancher UI and API | On the cluster (`mini-pc`) after bootstrap |
| Elemental Operator | On the cluster (`mini-pc`) after bootstrap |
| Fleet GitOps | On the cluster (bundled with Rancher) |
| K3s control plane | On the cluster (`mini-pc`) |
| K3s agent | On each worker node |
| Secret management | Kubernetes Secrets in the cluster |
| Tailscale operator | On the cluster (exposes services to the tailnet) |
| OS image building | External (not managed by this repo) |
| DNS and networking | Home network (router, DHCP) or Tailscale MagicDNS |

## What lives where

### On the MacBook

- This Git repository (cloned)
- CLI tools: `yq`, `kubectl`, `helm`, `shellcheck`, `yamllint`, `kubeconform`, `jq`
- `kubeconfig` files for connecting to the cluster
- SSH keys for node access
- USB image writing (during bootstrap)

### In GitHub

- This repository (remote)
- CI workflows (validate on push/PR, render on dispatch)
- Git history as an audit trail for infrastructure changes

### On cluster nodes

- Elemental OS (immutable, installed from ISO)
- K3s server (on `mini-pc`) or K3s agent (on workers)
- Rancher and Elemental Operator pods (on `mini-pc`, after bootstrap)
- Workload pods (scheduled by Kubernetes, primarily on workers)

## Rendered artefacts

`scripts/render.sh` produces per-node output under `dist/<env>/<hostname>/`:

| File | Description |
|------|-------------|
| `machine-registration.yaml` | `MachineRegistration` CRD for the management cluster |
| `cloud-config.yaml` | Cloud-init config for first-boot |
| `node-role.yaml` | `NodeRoleConfig` CRD |
| `cluster-node.yaml` | `ClusterNode` CRD |
| `seed-image.yaml` | `SeedImage` CRD config inputs |

## Secret management

No secret material is stored in this repository. All secrets are managed as Kubernetes
Secrets in the cluster.

| Secret type | How it is referenced |
|-------------|---------------------|
| SSH authorised keys | `sshKeySecretRef` in cluster-config.yaml or per-node override |
| Registration token | `registrationTokenSecretRef` in cluster-config.yaml |
| Tailscale OAuth credentials | Kubernetes Secret in `tailscale-system` namespace |
| Tailscale auth key | `tailscale.authKeySecretName` in node definitions (when enabled) |

## Tailscale tailnet access

The cluster is accessible from anywhere on your Tailscale tailnet via the Tailscale
Kubernetes operator. The operator runs inside the cluster and creates proxy pods that
act as Tailscale nodes, exposing cluster services with MagicDNS hostnames.

**What is exposed:**

| Service | Tailnet hostname | How |
|---------|-----------------|-----|
| Rancher UI | `rancher-lab.<tailnet>.ts.net` | `Ingress` with `ingressClassName: tailscale` |
| K3s API server | `k3s-api-lab.<tailnet>.ts.net` | `Service` with `loadBalancerClass: tailscale` |

This means you can run `kubectl` and access the Rancher UI from your MacBook on any
network — not just the home LAN. Nothing is exposed to the public internet.

The ingress resources live in `clusters/lab/tailscale/` and the full setup guide is
in [docs/tailscale.md](tailscale.md).

---

## Where should Rancher run in this homelab?

This is the most important architecture decision for a small homelab. There are three
realistic options.

### Option A: Rancher on a separate management machine

**How it works:** Run a dedicated K3s or RKE2 instance on a separate device (e.g., a
Raspberry Pi, NUC, or VM on the MacBook). Install Rancher and Elemental Operator there.
Use it to provision and manage the target cluster.

**Pros:**

- Clean separation between management and workload
- The management plane survives if the target cluster has problems
- Standard production pattern

**Cons:**

- Requires a fifth machine or a VM that is always running
- More hardware, more power, more maintenance
- Overkill for a four-node homelab

**Verdict:** Not recommended for this homelab unless you already have a spare device.

### Option B: Rancher temporarily outside, then connected later

**How it works:** Run a temporary K3s instance (e.g., on the MacBook in Docker via
`k3d`, or directly on the mini PC before the final OS install). Install Rancher and
Elemental Operator. Use it to bootstrap the target cluster. After bootstrap, either
tear down the temporary instance or keep it running.

**Pros:**

- No extra permanent hardware needed
- Clean initial bootstrap flow
- The temporary instance can be recreated from scratch if needed

**Cons:**

- Extra complexity during bootstrap
- If the temporary instance is on the MacBook, it must be running during node registration
- If the temporary instance is torn down, Rancher management is lost unless it is
  reinstalled on the target cluster

**Verdict:** Viable but adds unnecessary steps. For a homelab that will be managed
long-term, you end up installing Rancher on the target cluster anyway.

### Option C: Rancher inside the target cluster itself

**How it works:** Bootstrap K3s on the mini PC first (manually or with a minimal
Elemental flow). Install Rancher and Elemental Operator on the cluster. Then use
Rancher to register and provision the remaining worker nodes.

**Pros:**

- Simplest setup — no extra machines, no temporary instances
- Rancher and the cluster lifecycle are in one place
- Matches the long-term desired state from day one
- Easy to back up (one cluster, one etcd)

**Cons:**

- Rancher manages the same cluster it runs on (self-referential)
- If the control plane (`mini-pc`) fails, both the cluster and Rancher are unavailable
- Upgrading Rancher requires care to avoid disrupting the cluster

**Tradeoff note:** The self-management concern is real in production but acceptable in
a homelab. You can always reinstall Rancher from the Helm chart if something goes wrong.
The cluster state (node definitions, configs) is in this Git repository, so recovery is
straightforward.

### Recommended approach for this homelab

**Option C: Run Rancher on the target cluster.**

The bootstrap sequence is:

1. Install K3s server on the mini PC (single node)
2. Install Rancher and Elemental Operator via Helm
3. Render and apply registration resources from this repo
4. Boot the three worker machines from the Elemental ISO
5. Workers register, install, and join the cluster

This gives you a fully functional four-node cluster with Rancher running on the control
plane. The mini PC handles both K3s server duties and Rancher. With 8–16 GB of RAM and
a modern multi-core CPU, the mini PC has sufficient capacity for this combined role.

See [docs/bootstrap.md](docs/bootstrap.md) for the complete step-by-step guide.

## What is practical for a homelab versus production

| Concern | Homelab (this setup) | Production |
|---------|---------------------|------------|
| Control plane HA | Single node (acceptable) | 3+ server nodes with external etcd |
| Rancher placement | On the same cluster | Separate management cluster |
| TPM | Emulated (`emulateTPM: true`) | Hardware TPM required |
| Certificate management | Self-signed or Let's Encrypt | Proper PKI |
| Backup strategy | Manual etcd snapshots | Automated off-site backups |
| Network segmentation | Flat home network | VLANs, firewalls, DMZ |
| Node count | 4 (minimum viable) | Tens to hundreds |
| GitOps | This repo + manual apply | Fleet or ArgoCD with automated sync |
