# macOS setup guide

This guide documents everything needed on a MacBook to operate this repository and
provision the homelab K3s cluster.

## Prerequisites

- macOS 12 (Monterey) or later
- Apple Silicon (M1/M2/M3) or Intel Mac
- Homebrew installed (see below)
- Terminal access (Terminal.app, iTerm2, or similar)

## Install Homebrew

If Homebrew is not already installed:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, follow the instructions to add Homebrew to your `PATH`. On Apple
Silicon Macs this is typically:

```bash
echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile
eval "$(/opt/homebrew/bin/brew shellenv)"
```

Verify:

```bash
brew --version
```

## Required tools

| Tool | Purpose | Install command |
|------|---------|-----------------|
| `git` | Version control, clone this repo | Bundled with Xcode CLT or `brew install git` |
| `yq` (v4) | YAML processing for rendering templates | `brew install yq` |
| `shellcheck` | Shell script linting | `brew install shellcheck` |
| `yamllint` | YAML linting | `brew install yamllint` |
| `kubeconform` | Kubernetes manifest validation | `brew install kubeconform` |
| `kubectl` | Kubernetes cluster management | `brew install kubectl` |
| `helm` | Install Rancher and Elemental Operator | `brew install helm` |
| `jq` | JSON processing for debugging and scripting | `brew install jq` |
| `ansible` | Automated provisioning playbooks | `brew install ansible` |

### Install all tools at once

```bash
brew install git yq shellcheck yamllint kubeconform kubectl helm jq ansible
```

> **Note:** `yamllint` can also be installed via `pip install yamllint` if you prefer
> a Python-based installation. The Homebrew version is simpler on macOS.

### Verify tool installation

```bash
git --version
yq --version
shellcheck --version
yamllint --version
kubeconform -v
kubectl version --client
helm version --short
jq --version
ansible --version
```

All commands should return version information without errors.

## Optional tools

| Tool | Purpose | Install command |
|------|---------|-----------------|
| `gh` | GitHub CLI for repo management | `brew install gh` |
| `ssh` | Remote node access | Bundled with macOS |
| `balenaEtcher` | Write ISO images to USB | `brew install --cask balenaetcher` |

The GitHub CLI (`gh`) is useful for managing pull requests and workflow runs but is
not required for rendering or validation.

## Clone the repository

Using HTTPS:

```bash
git clone https://github.com/Bigalan09/elemental-k3s-provisioning.git
cd elemental-k3s-provisioning
```

Using SSH (if you have an SSH key configured with GitHub):

```bash
git clone git@github.com:Bigalan09/elemental-k3s-provisioning.git
cd elemental-k3s-provisioning
```

### GitHub authentication

If this is a private repository, you need authentication configured:

**SSH key method (recommended):**

```bash
# Generate a key if you don't have one
ssh-keygen -t ed25519 -C "your-email@example.com"

# Add to SSH agent
ssh-add ~/.ssh/id_ed25519

# Copy the public key and add it to GitHub → Settings → SSH and GPG keys
cat ~/.ssh/id_ed25519.pub
```

**GitHub CLI method:**

```bash
gh auth login
```

Follow the prompts to authenticate via browser.

**HTTPS with credential helper:**

```bash
# macOS Keychain credential helper (ships with Git on macOS)
git config --global credential.helper osxkeychain
```

Git will prompt for your GitHub username and a personal access token (not your password)
the first time you push or pull.

## Run local validation

From the repository root:

```bash
bash scripts/validate.sh
```

This runs:

1. `shellcheck` on all shell scripts in `scripts/`
2. `yamllint` on all YAML files in `templates/`, `clusters/`, and `nodes/`
3. `render.sh --all` to produce rendered artefacts in `dist/`
4. `yamllint` on all rendered artefacts
5. `kubeconform` on rendered Kubernetes manifests

A successful run ends with `Validation complete` and zero failures.

## Run local rendering

Render all lab nodes:

```bash
bash scripts/render.sh --env lab
```

Render a single node:

```bash
bash scripts/render.sh nodes/lab/mini-pc.yaml
```

Render everything:

```bash
bash scripts/render.sh --all
```

Rendered output appears in `dist/<environment>/<hostname>/`.

## USB media creation from macOS

Elemental installation media is a bootable ISO. To write it to a USB drive from macOS:

### Identify the USB drive

Insert the USB drive and run:

```bash
diskutil list
```

Find the USB drive (e.g., `/dev/disk4`). Be certain you have the correct device —
writing to the wrong disk will destroy data.

### Unmount the USB drive

```bash
diskutil unmountDisk /dev/disk4
```

### Write the ISO using dd

```bash
sudo dd if=elemental-installer.iso of=/dev/rdisk4 bs=4m status=progress
```

> **Note:** Use `/dev/rdisk4` (raw disk) instead of `/dev/disk4` for significantly
> faster writes on macOS. Replace `disk4` with your actual disk number.

After writing, eject:

```bash
diskutil eject /dev/disk4
```

### Alternative: balenaEtcher

If you prefer a GUI tool:

1. Open balenaEtcher
2. Select the Elemental ISO
3. Select the USB drive
4. Click Flash

### Verify the ISO before writing

If the ISO provider supplies checksums:

```bash
# SHA-256 verification
shasum -a 256 elemental-installer.iso
```

Compare the output with the expected checksum from the download source.

## Connect to nodes after provisioning

Once nodes are provisioned and running, connect via SSH:

```bash
ssh root@<node-ip>
```

The SSH keys used are those stored in the Kubernetes Secret referenced by
`sshKeySecretRef` in the cluster configuration. Ensure the private key
corresponding to the authorised public key is available on your MacBook:

```bash
ssh -i ~/.ssh/id_ed25519 root@<node-ip>
```

### Find node IPs

If nodes are on the same LAN as your MacBook:

```bash
# Use the provisioned cluster kubeconfig
kubectl get nodes -o wide --kubeconfig ~/.kube/lab-cluster.yaml
```

Or scan the local network:

```bash
# Find devices on your subnet (requires nmap: brew install nmap)
nmap -sn 192.168.1.0/24
```

### Configure kubectl for the provisioned cluster

After bootstrap, download the kubeconfig from Rancher or extract it from the
management cluster:

```bash
# Save the kubeconfig
kubectl get secret lab-kubeconfig -n fleet-default \
  -o jsonpath='{.data.value}' | base64 -d > ~/.kube/lab-cluster.yaml

# Test connectivity
kubectl get nodes --kubeconfig ~/.kube/lab-cluster.yaml
```

Or set it as your default context:

```bash
export KUBECONFIG=~/.kube/lab-cluster.yaml
kubectl get nodes
```
