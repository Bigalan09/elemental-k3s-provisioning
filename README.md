# elemental-k3s-provisioning

Config-as-code for Elemental based K3s node provisioning. Defines nodes, renders registration manifests, and validates artefacts via CI.

## Roles

| Role | Description |
|------|-------------|
| `server` | Control plane node. Runs the K3s server process. |
| `agent` | Worker node. Runs the K3s agent process and schedules workloads. |

Role assignment is declared per node in `nodes/examples/` and propagated into rendered manifests.

## Node definition structure

Each file in `nodes/examples/` defines a single node:

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
```

## Hostname assignment

The `hostname` field in each node file is the single source of truth. It is propagated into all rendered artefacts (cloud config, `MachineRegistration`, cluster node manifest, and output directory `dist/<hostname>/`).

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

- **validate.yaml** — Runs on every push/PR. Installs tools, runs `scripts/validate.sh`, fails on any invalid shell script, YAML, or rendered artefact.
- **render-node-configs.yaml** — Manual trigger (`workflow_dispatch`). Accepts `node_file` input (single file or `all`). Uploads `dist/` as a workflow artefact.

## External systems

The following must exist before using this repository:

- **Rancher management cluster** with Rancher OS Manager (Elemental Operator) installed
- **Elemental ISO** built and available for target hardware
- **Cluster registration token** as a Kubernetes secret in the management cluster
- **SSH public keys** provided in node definition files (not stored as secrets)

## Scope

**Owns:** templates, node definitions, cluster config, render/validate scripts, CI workflows.

**Does not own:** Elemental/Rancher operator installation, the K3s cluster itself, secrets, OS image building, network/DNS configuration.
