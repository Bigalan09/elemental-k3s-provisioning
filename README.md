# elemental-k3s-provisioning

Private infrastructure repository for Elemental-based K3s node provisioning. Defines node inventory, cluster environments, renders registration manifests, and validates artefacts via CI.

## Repository structure

```
clusters/
  lab/                    # Lab environment cluster config
  staging/                # Staging environment cluster config
  production/             # Production environment cluster config
nodes/
  examples/               # Reference node definitions (not live inventory)
  lab/                    # Live lab node inventory
  staging/                # Live staging node inventory
  production/             # Live production node inventory
templates/                # Reusable rendering templates
scripts/                  # Render and validate scripts
dist/                     # Rendered artefacts (gitignored)
docs/                     # Architecture, bootstrap, and operational docs
```

## Roles

| Role | Description |
|------|-------------|
| `server` | Control-plane node. Runs the K3s server process. |
| `agent` | Worker node. Runs the K3s agent process and schedules workloads. |

## Node definition structure

Each file in `nodes/<environment>/` defines a single node:

```yaml
hostname: prod-server-01
role: server
installDevice: /dev/sda
environment: production
registrationGroup: production-registration

labels:
  node-type: control-plane

taints:
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule

# SSH keys are never stored in node files. Reference a Kubernetes Secret instead.
# Defaults to the environment-level sshKeySecretRef from cluster-config.yaml.
# sshKeySecretRef:
#   name: production-ssh-authorized-keys
#   namespace: fleet-default

tailscale:
  enabled: false
  # authKeySecretName: tailscale-auth-key
```

### Required fields

| Field | Description |
|-------|-------------|
| `hostname` | Unique node identifier. Propagated to all rendered artefacts. |
| `role` | `server` or `agent`. |
| `installDevice` | Block device path for OS installation (e.g. `/dev/sda`). |

### Optional fields

| Field | Description |
|-------|-------------|
| `environment` | Target environment name. Falls back to the parent directory name. |
| `registrationGroup` | Name of the MachineRegistration to associate with. |
| `labels` | Custom Kubernetes node labels. |
| `taints` | Kubernetes taints. |
| `sshKeySecretRef` | Per-node override for the SSH key secret. |
| `tailscale.enabled` | Whether Tailscale should be configured on the node. |
| `tailscale.authKeySecretName` | Name of the Kubernetes Secret holding the Tailscale auth key. |

## Hostname assignment

The `hostname` field in each node file is the single source of truth. It is propagated into all rendered artefacts (cloud-config, MachineRegistration, cluster node manifest) and determines the output directory `dist/<env>/<hostname>/`.

## Secret management

**No secret material is stored in this repository.**

SSH authorised keys are provided via Kubernetes Secrets referenced in each environment's `cluster-config.yaml` under `sshKeySecretRef`. Individual nodes may override this reference. See [docs/bootstrap.md](docs/bootstrap.md) for setup instructions.

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

Render all nodes in an environment:

```bash
bash scripts/render.sh --env production
```

Render all nodes across all environments:

```bash
bash scripts/render.sh --all
```

Rendered output is written to `dist/<environment>/<hostname>/`.

## GitHub Actions workflows

- **validate.yaml** — Runs on every push and PR. Installs tools, runs `scripts/validate.sh`, fails on any invalid shell script, YAML, or rendered artefact.
- **render-node-configs.yaml** — Manual trigger (`workflow_dispatch`). Accepts a target input: a file path, environment name, or `all`. Uploads `dist/` as a workflow artefact.

## External dependencies

The following must exist before using this repository:

| Dependency | Managed by |
|------------|------------|
| Rancher management cluster with Elemental Operator | External |
| Elemental bootable ISO or OCI image | External |
| Cluster registration token (Kubernetes Secret) | External |
| SSH authorised keys (Kubernetes Secret) | External |
| DNS and network configuration | External |
| Tailscale auth key (Kubernetes Secret, if used) | External |

## Scope

**Owns:** templates, node definitions, cluster environment configs, render/validate scripts, CI workflows.

**Does not own:** Rancher or Elemental Operator installation, the K3s cluster itself, secret material, OS image building, network or DNS configuration.
