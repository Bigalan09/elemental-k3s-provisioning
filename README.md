# elemental-k3s-provisioning

Private infrastructure repository for provisioning a homelab K3s cluster using
Rancher Elemental. This repo defines node inventory, cluster configuration,
rendering templates, and validation — all managed from a MacBook.

## Homelab hardware

| Device | Hostname | Role | Notes |
|--------|----------|------|-------|
| Mini PC | `mini-pc` | Control plane (`server`) | Most capable device — runs K3s server, etcd, and management workloads |
| ZimaBlade | `zimablade` | Worker (`agent`) | Compact single-board server |
| ZimaBoard 1 | `zimaboard-1` | Worker (`agent`) | SBC with dual NIC |
| ZimaBoard 2 | `zimaboard-2` | Worker (`agent`) | SBC with dual NIC |

## Target topology

```
┌──────────────────────────────────────────────────┐
│                  Lab cluster                      │
│                                                   │
│  ┌─────────────┐   ┌──────────┐   ┌──────────┐  │
│  │  mini-pc    │   │zimablade │   │zimaboard │  │
│  │  (server)   │   │ (agent)  │   │1 (agent) │  │
│  │  K3s server │   │ K3s agent│   │K3s agent │  │
│  │  etcd       │   │          │   │          │  │
│  │  Rancher*   │   │          │   │          │  │
│  └─────────────┘   └──────────┘   └──────────┘  │
│                                    ┌──────────┐  │
│                                    │zimaboard │  │
│                                    │2 (agent) │  │
│                                    │K3s agent │  │
│                                    └──────────┘  │
└──────────────────────────────────────────────────┘

* Rancher is installed on the cluster after K3s bootstrap.
  See docs/architecture.md for the rationale.
```

**Single control plane, three workers.** High availability is not required for this
homelab. See [docs/hardware-plan.md](docs/hardware-plan.md) for the full hardware
analysis.

## End-to-end workflow summary

1. **Prepare the MacBook** — install tools (`yq`, `kubectl`, `helm`, etc.)
2. **Bootstrap a temporary K3s instance** — run a single-node K3s on the mini PC to host Rancher and Elemental Operator
3. **Install Rancher and Elemental Operator** — via Helm on the temporary instance
4. **Render node artefacts** — run `scripts/render.sh --env lab` from this repo
5. **Apply registration resources** — `kubectl apply` the rendered manifests
6. **Build or obtain Elemental ISO** — with the registration URL embedded
7. **Write ISO to USB** — from macOS using `dd` or balenaEtcher
8. **Boot each machine** — USB boot, Elemental registers and installs the OS
9. **Assign K3s roles** — apply the rendered node-role configs
10. **Verify the cluster** — `kubectl get nodes` shows all four machines

For the complete step-by-step guide, see [docs/bootstrap.md](docs/bootstrap.md).

## Documentation

| Document | Description |
|----------|-------------|
| [docs/hardware-plan.md](docs/hardware-plan.md) | Hardware roles, device analysis, and topology reasoning |
| [docs/macbook-setup.md](docs/macbook-setup.md) | macOS tool installation and environment setup |
| [docs/architecture.md](docs/architecture.md) | Management plane, Elemental flow, Rancher placement decision |
| [docs/bootstrap.md](docs/bootstrap.md) | End-to-end guide: MacBook to running cluster |
| [docs/operations.md](docs/operations.md) | Day-2 operations: updates, scaling, secrets, backups |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Common problems and resolution steps |

## Repository structure

```
clusters/
  lab/                    # Lab environment cluster config (the homelab)
  staging/                # Staging environment cluster config
  production/             # Production environment cluster config
nodes/
  examples/               # Reference node definitions (not live inventory)
  lab/                    # Live lab node inventory (mini-pc, zimablade, zimaboard-1, zimaboard-2)
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
hostname: mini-pc
role: server
installDevice: /dev/sda
environment: lab
registrationGroup: lab-registration

labels:
  node-type: control-plane

taints:
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule

tailscale:
  enabled: false
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

The `hostname` field in each node file is the single source of truth. It is propagated
into all rendered artefacts (cloud-config, MachineRegistration, cluster node manifest)
and determines the output directory `dist/<env>/<hostname>/`.

## Secret management

**No secret material is stored in this repository.**

SSH authorised keys are provided via Kubernetes Secrets referenced in each environment's
`cluster-config.yaml` under `sshKeySecretRef`. Individual nodes may override this
reference. See [docs/bootstrap.md](docs/bootstrap.md) for setup instructions.

## Rendering configs locally

Install the required tools (see [docs/macbook-setup.md](docs/macbook-setup.md) for details):

```bash
brew install yq shellcheck yamllint kubeconform kubectl helm jq
```

Render all lab nodes:

```bash
bash scripts/render.sh --env lab
```

Render a single node:

```bash
bash scripts/render.sh nodes/lab/mini-pc.yaml
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
| Rancher (installed post-bootstrap on the cluster) | Helm install documented in [docs/bootstrap.md](docs/bootstrap.md) |
| Elemental Operator (installed with Rancher) | Helm install documented in [docs/bootstrap.md](docs/bootstrap.md) |
| Elemental bootable ISO or OCI image | Downloaded or built externally |
| SSH authorised keys (Kubernetes Secret) | Created manually during bootstrap |
| Cluster registration token (Kubernetes Secret) | Created manually during bootstrap |
| DNS and network configuration | Home router / manual setup |
| Tailscale auth key (Kubernetes Secret, if used) | External |

## Scope

**Owns:** templates, node definitions, cluster environment configs, render/validate
scripts, CI workflows, and documentation for the full bootstrap process.

**Does not own:** Rancher or Elemental Operator installation (documented but executed
externally), the K3s cluster runtime itself, secret material, OS image building,
network or DNS configuration.
