# elemental-k3s-provisioning

This repository manages Elemental based node provisioning and configuration for a K3s cluster. It acts as a config as code control repository for defining, rendering, and validating Elemental registration resources, K3s role assignments, and per node configuration.

## Why this repository exists

Elemental provisioning is a distinct concern from image building or OS installation. This repository is dedicated solely to the declarative Elemental configuration model. It does not build Ubuntu ISOs, install NixOS, or act as a generic multi-OS image builder. It owns the registration templates, node definitions, rendered manifests, and GitHub Actions workflows that drive Elemental based node lifecycle management.

## How Elemental provisioning fits into K3s cluster management

Elemental is a toolkit from SUSE that enables declarative, operator-managed OS provisioning for edge and bare metal nodes. When combined with Rancher and the Rancher OS Manager (formerly Elemental Operator), nodes boot from an Elemental ISO, register themselves against a `MachineRegistration` resource in the management cluster, and are then lifecycle-managed as Kubernetes custom resources.

K3s is the lightweight Kubernetes distribution used for both the management plane and the provisioned clusters. Nodes provisioned via Elemental become K3s servers (control plane) or K3s agents (workers) depending on their role definition in this repository.

## Server and agent roles

This repository supports exactly two roles:

| Role | Description |
|------|-------------|
| `server` | Control plane node. Runs the K3s server process. |
| `agent` | Worker node. Runs the K3s agent process and schedules workloads. |

Role assignment is declared in each node definition file under `nodes/examples/` and is propagated into rendered cloud config and node role manifests.

## Node definition structure

Each file in `nodes/examples/` defines a single node. The supported fields are:

```yaml
hostname: server-01
role: server
installDevice: /dev/sda

labels:
  environment: production
  node-type: control-plane

taints:
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule

sshAuthorizedKeys:
  - "ssh-ed25519 AAAA... user@host"

tailscale:
  enabled: false
  authKeySecretName: ""
```

All fields except `tailscale` are required. The `tailscale` block is optional. When `tailscale.enabled` is `false`, the `authKeySecretName` field is ignored during rendering.

## Hostname assignment

Hostnames are declared explicitly in each node definition file. The `hostname` field is the single source of truth. During rendering, the hostname is propagated into:

- The cloud config `hostname` field
- The `MachineRegistration` metadata name and labels
- The cluster node manifest name and labels
- The output directory path under `dist/<hostname>/`

This ensures that rendered artefacts are deterministic and traceable back to a single node identity.

## Rendering configs locally

Install the required tools:

```bash
# yq v4
brew install yq        # macOS
sudo snap install yq   # Linux

# shellcheck
brew install shellcheck
sudo apt-get install shellcheck

# yamllint
pip install yamllint

# kubeconform
brew install kubeconform
```

Render a single node:

```bash
bash scripts/render.sh nodes/examples/server-01.yaml
```

Render all example nodes:

```bash
bash scripts/render.sh --all
```

Rendered output is written to `dist/<hostname>/`.

## GitHub Actions workflows

### validate.yaml

Triggered on every push and pull request. This workflow:

1. Installs required tools (yq, shellcheck, yamllint, kubeconform)
2. Runs `scripts/validate.sh`
3. Fails if any shell script, YAML file, or rendered artefact is invalid

### render-node-configs.yaml

Triggered manually via `workflow_dispatch`. Accepts an input:

- `node_file`: path to a single node definition file, or `all` to render all example nodes

After rendering, the `dist/` directory is uploaded as a workflow artefact.

## External systems

This repository does not provision or configure the following. They must already exist before using this repository:

- **Rancher management cluster**: A running Rancher instance with Rancher OS Manager (Elemental Operator) installed.
- **Elemental ISO**: A bootable Elemental ISO or OCI image built and available for target hardware.
- **Cluster registration token**: The `registrationToken` value referenced in `clusters/production/machine-registration.yaml` must be created as a Kubernetes secret in the management cluster.
- **SSH public keys**: These are provided externally and placed in node definition files. They must not be stored as secrets in this repository.
- **Tailscale auth keys**: Referenced by secret name only. The actual secret must exist in the target cluster namespace.

## What this repository owns

- Templates for Elemental registration, cloud config, node roles, and cluster nodes
- Node definition files for all provisioned nodes
- Cluster level configuration for the production environment
- Scripts for rendering and validating configuration artefacts
- GitHub Actions workflows for CI validation and on-demand rendering

## What this repository does not own

- The Elemental or Rancher OS Manager operator installation
- The K3s cluster itself
- Secrets and credentials
- OS image building
- Network or DNS configuration
