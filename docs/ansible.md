# Ansible runbook

This guide explains how to use the Ansible playbooks in `ansible/` to automate the
homelab cluster bootstrap. The playbooks follow the same sequence as
[docs/bootstrap.md](bootstrap.md) but automate each step so you can provision the
cluster with a single command.

## Prerequisites

- A MacBook with the tools from [docs/macbook-setup.md](macbook-setup.md) installed
- Ansible installed on the MacBook
- SSH access to the mini PC (the control plane node)
- All four machines connected to the same LAN

### Install Ansible

```bash
brew install ansible
```

Verify:

```bash
ansible --version
```

### SSH access

Ensure you can SSH into the mini PC from your MacBook:

```bash
ssh root@<mini-pc-ip>
```

If the mini PC is running a fresh OS, you may need to copy your SSH key first:

```bash
ssh-copy-id root@<mini-pc-ip>
```

## Configuration

### 1. Update the inventory

Edit `ansible/inventory/hosts.yml` and set the actual IP addresses for each machine:

```yaml
all:
  children:
    control_plane:
      hosts:
        mini-pc:
          ansible_host: 192.168.1.100    # ← your mini PC's IP
          install_device: /dev/sda
          node_role: server

    workers:
      hosts:
        zimablade:
          ansible_host: 192.168.1.101    # ← your ZimaBlade's IP
          install_device: /dev/sda
          node_role: agent

        zimaboard-1:
          ansible_host: 192.168.1.102    # ← your ZimaBoard 1's IP
          install_device: /dev/sda
          node_role: agent

        zimaboard-2:
          ansible_host: 192.168.1.103    # ← your ZimaBoard 2's IP
          install_device: /dev/sda
          node_role: agent
```

### 2. Update global variables

Edit `ansible/group_vars/all.yml`:

```yaml
# K3s version
k3s_version: "v1.29.4+k3s1"

# Rancher hostname (add to /etc/hosts or configure DNS)
rancher_hostname: "rancher.lab.internal"

# Path to your SSH public key
ssh_public_key_path: "~/.ssh/id_ed25519.pub"

# Tailscale (optional — leave blank to skip)
tailscale_oauth_client_id: ""
tailscale_oauth_client_secret: ""
```

### 3. Add Rancher hostname to /etc/hosts

```bash
echo "192.168.1.100  rancher.lab.internal" | sudo tee -a /etc/hosts
```

Replace `192.168.1.100` with the mini PC's actual IP.

## Running the full bootstrap

From the repository root:

```bash
cd ansible
ansible-playbook site.yml
```

This runs all six stages in order:

1. **Bootstrap K3s** — installs K3s server on the mini PC
2. **Install Rancher** — installs cert-manager, Rancher, and Elemental Operator
3. **Create secrets** — creates SSH key and registration token secrets
4. **Render and apply** — renders node configs and applies to the cluster
5. **Install Tailscale** — installs the operator and ingress (skipped if not configured)
6. **Verify cluster** — checks all components are healthy

## Running individual stages

Each stage can be run independently:

```bash
cd ansible

# Stage 1: Bootstrap K3s on the mini PC
ansible-playbook playbooks/01-bootstrap-k3s.yml

# Stage 2: Install Rancher and Elemental Operator
ansible-playbook playbooks/02-install-rancher.yml

# Stage 3: Create Kubernetes secrets
ansible-playbook playbooks/03-create-secrets.yml

# Stage 4: Render and apply node configs
ansible-playbook playbooks/04-render-and-apply.yml

# Stage 5: Install Tailscale (requires OAuth credentials in group_vars)
ansible-playbook playbooks/05-install-tailscale.yml

# Stage 6: Verify everything
ansible-playbook playbooks/06-verify-cluster.yml
```

## What each playbook does

### 01-bootstrap-k3s.yml

- **Runs on:** mini PC (via SSH)
- Installs K3s server using the official install script
- Waits for K3s to become ready
- Copies the kubeconfig to your MacBook at `~/.kube/lab-cluster.yaml`
- Updates the kubeconfig server address from `127.0.0.1` to the mini PC's IP

### 02-install-rancher.yml

- **Runs on:** MacBook (localhost) using the kubeconfig from stage 1
- Installs cert-manager from the official manifests
- Adds the Rancher Helm repo and installs Rancher
- Adds the Rancher charts repo and installs the Elemental Operator CRDs and Operator
- Waits for all deployments to be ready

### 03-create-secrets.yml

- **Runs on:** MacBook (localhost)
- Creates the `lab-ssh-authorized-keys` secret from your SSH public key
- Generates a random registration token and creates the `lab-registration-token` secret
- Skips secrets that already exist (safe to re-run)

### 04-render-and-apply.yml

- **Runs on:** MacBook (localhost)
- Runs `scripts/render.sh --env lab` to produce artefacts in `dist/lab/`
- Applies the environment-level `MachineRegistration`
- Applies per-node `MachineRegistration`, `NodeRoleConfig`, and `ClusterNode` resources
- Displays the registration URL for embedding in the Elemental ISO

**After this stage:** Boot each worker machine from the Elemental ISO. The playbook
reminds you of this manual step.

### 05-install-tailscale.yml

- **Runs on:** MacBook (localhost)
- **Skipped** if `tailscale_oauth_client_id` is empty in `group_vars/all.yml`
- Installs the Tailscale Kubernetes operator via Helm
- Applies the Rancher ingress and API server proxy from `clusters/lab/tailscale/`
- Displays the created ingress and service resources

### 06-verify-cluster.yml

- **Runs on:** MacBook (localhost)
- Checks node status, labels, and readiness
- Checks kube-system, Rancher, and Elemental Operator pods
- Lists MachineRegistrations and MachineInventory
- Checks Tailscale resources (if installed)
- Prints a summary of the cluster state

## Manual steps

The Ansible runbook automates everything except:

1. **Booting worker machines from USB.** After stage 4, you still need to physically
   boot each worker from the Elemental ISO. This is inherently a manual step for
   bare-metal provisioning.

2. **Setting up the Tailscale OAuth client.** You need to create this in the Tailscale
   admin console and paste the credentials into `group_vars/all.yml`.

3. **Writing the Elemental ISO to USB.** See [docs/macbook-setup.md](macbook-setup.md)
   for the `dd` command.

## Re-running playbooks

All playbooks are designed to be **idempotent** — they check whether each resource
already exists before creating it. It is safe to re-run any playbook at any time.

## Customising

### Change the K3s version

Edit `k3s_version` in `ansible/group_vars/all.yml`.

### Change the Rancher hostname

Edit `rancher_hostname` in `ansible/group_vars/all.yml`. Remember to update
`/etc/hosts` on your MacBook.

### Add a new worker node

1. Add the node to `ansible/inventory/hosts.yml` under `workers`
2. Create a node definition in `nodes/lab/<hostname>.yaml`
3. Re-run stage 4:

   ```bash
   ansible-playbook playbooks/04-render-and-apply.yml
   ```

4. Boot the new machine from the Elemental ISO

### Enable Tailscale later

1. Create an OAuth client in the Tailscale admin console
2. Set `tailscale_oauth_client_id` and `tailscale_oauth_client_secret` in
   `group_vars/all.yml`
3. Run stage 5:

   ```bash
   ansible-playbook playbooks/05-install-tailscale.yml
   ```

## Troubleshooting

### Ansible cannot reach the mini PC

```bash
ansible -m ping control_plane
```

If this fails:
- Check the IP address in `inventory/hosts.yml`
- Ensure SSH access works: `ssh root@<mini-pc-ip>`
- Check that `ansible.cfg` has `host_key_checking = False`

### Playbook fails waiting for a deployment

Increase the timeout or check the deployment status manually:

```bash
kubectl get pods -A --kubeconfig ~/.kube/lab-cluster.yaml
kubectl describe deployment <name> -n <namespace> --kubeconfig ~/.kube/lab-cluster.yaml
```

### Helm errors about existing releases

The playbooks check for existing Helm releases before installing. If a release is in
a broken state, you may need to manually uninstall it:

```bash
helm uninstall <release-name> -n <namespace>
```

Then re-run the playbook.
