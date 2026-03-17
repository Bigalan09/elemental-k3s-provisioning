# Day-2 operations

This guide covers routine operations after the homelab cluster is bootstrapped and
healthy.

## Render updated configurations

After editing node definitions or cluster configs, re-render the artefacts:

```bash
# Render all lab nodes
bash scripts/render.sh --env lab

# Render a specific node
bash scripts/render.sh nodes/lab/mini-pc.yaml
```

Rendered output is written to `dist/lab/<hostname>/`. Review the changes before
applying them.

## Apply node definition changes

If you changed labels, taints, or other metadata for an existing node:

1. Edit the node definition file in `nodes/lab/`.
2. Re-render:

   ```bash
   bash scripts/render.sh nodes/lab/<hostname>.yaml
   ```

3. Apply the updated manifests to the management cluster:

   ```bash
   kubectl apply -f dist/lab/<hostname>/node-role.yaml
   kubectl apply -f dist/lab/<hostname>/cluster-node.yaml
   ```

4. Verify the changes took effect:

   ```bash
   kubectl describe node <hostname> --kubeconfig ~/.kube/lab-cluster.yaml
   ```

## Add a new worker node

To add a fifth machine to the cluster:

1. Create a new node definition file:

   ```bash
   cp nodes/lab/zimaboard-2.yaml nodes/lab/new-worker.yaml
   ```

2. Edit `nodes/lab/new-worker.yaml` and set the correct hostname, install device,
   and any labels:

   ```yaml
   hostname: new-worker
   role: agent
   installDevice: /dev/sda
   environment: lab
   registrationGroup: lab-registration
   labels:
     node-type: worker
   taints: []
   tailscale:
     enabled: false
   ```

3. Render the node artefacts:

   ```bash
   bash scripts/render.sh nodes/lab/new-worker.yaml
   ```

4. Apply the registration and role manifests to the management cluster:

   ```bash
   kubectl apply -f dist/lab/new-worker/machine-registration.yaml
   kubectl apply -f dist/lab/new-worker/node-role.yaml
   kubectl apply -f dist/lab/new-worker/cluster-node.yaml
   ```

5. Boot the new machine from the Elemental ISO with the lab registration URL.

6. Watch for the machine to register:

   ```bash
   kubectl get machineinventory -n fleet-default -w
   ```

7. Once registered and provisioned, verify the node joined:

   ```bash
   kubectl get nodes --kubeconfig ~/.kube/lab-cluster.yaml
   ```

## Replace a failed worker node

If a worker node fails and needs to be replaced with new hardware:

1. Remove the old machine inventory entry:

   ```bash
   kubectl delete machineinventory <old-hostname> -n fleet-default
   ```

2. If the node is still visible in the provisioned cluster, drain and remove it:

   ```bash
   kubectl drain <old-hostname> --ignore-daemonsets --delete-emptydir-data \
     --kubeconfig ~/.kube/lab-cluster.yaml
   kubectl delete node <old-hostname> --kubeconfig ~/.kube/lab-cluster.yaml
   ```

3. If the replacement hardware has the same hostname, re-render and re-apply:

   ```bash
   bash scripts/render.sh nodes/lab/<hostname>.yaml
   kubectl apply -f dist/lab/<hostname>/machine-registration.yaml
   ```

4. If the replacement has a different hostname, create a new node definition file
   (same process as adding a new worker above) and remove the old node definition.

5. Boot the replacement from the Elemental ISO and let it register.

## Rotate secret references

Secrets (SSH keys, registration tokens, Tailscale auth keys) are stored as Kubernetes
Secrets in the management cluster. This repo only stores references to those secrets.

To rotate an SSH key:

1. Generate a new SSH key pair on your MacBook:

   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/lab-key-new -C "lab-rotation"
   ```

2. Update the Kubernetes Secret in the management cluster:

   ```bash
   kubectl create secret generic lab-ssh-authorized-keys \
     --namespace fleet-default \
     --from-file=ssh-authorized-keys=~/.ssh/lab-key-new.pub \
     --dry-run=client -o yaml | kubectl apply -f -
   ```

3. Reboot or re-provision affected nodes for the new key to take effect.

The node definition files in this repo do not change because they reference the
secret by name, not by value.

To rotate a registration token:

```bash
kubectl create secret generic lab-registration-token \
  --namespace fleet-default \
  --from-literal=token="$(openssl rand -hex 32)" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Verify node roles

Check that each node has the correct role:

```bash
kubectl get nodes --show-labels --kubeconfig ~/.kube/lab-cluster.yaml
```

Expected output for this homelab:

| Hostname | Roles | Labels |
|----------|-------|--------|
| mini-pc | control-plane, master | `node-type=control-plane` |
| zimablade | worker | `node-type=worker` |
| zimaboard-1 | worker | `node-type=worker` |
| zimaboard-2 | worker | `node-type=worker` |

To check a specific node:

```bash
kubectl describe node mini-pc --kubeconfig ~/.kube/lab-cluster.yaml | head -30
```

## Check cluster health

### Node status

```bash
kubectl get nodes --kubeconfig ~/.kube/lab-cluster.yaml
```

All nodes should show `Ready`.

### System pods

```bash
kubectl get pods -A --kubeconfig ~/.kube/lab-cluster.yaml
```

All pods in `kube-system` should be `Running` or `Completed`.

### K3s service on a node

SSH into a node and check:

```bash
ssh root@<node-ip>
systemctl status k3s        # on the control plane
systemctl status k3s-agent   # on workers
```

### etcd health (control plane only)

```bash
ssh root@<mini-pc-ip>
k3s etcd-snapshot list
```

### Cluster info

```bash
kubectl cluster-info --kubeconfig ~/.kube/lab-cluster.yaml
```

## Keep the repo as the source of truth

This repository is the single source of truth for node definitions and cluster
configuration. Follow these practices:

1. **Never edit rendered artefacts in `dist/` directly.** Always edit the source
   files in `nodes/` or `clusters/` and re-render.

2. **Commit changes before applying.** Push node definition changes to the repo
   before applying them to the management cluster. This ensures the repo always
   reflects the desired state.

3. **Use the CI validation workflow.** Every push and PR triggers `validate.yaml`
   which runs shellcheck, yamllint, and kubeconform. Do not apply artefacts that
   fail validation.

4. **Review rendered diffs.** After rendering, use `git diff dist/` to inspect
   what changed before applying.

5. **Document manual overrides.** If you must make a change directly on a node
   or in the management cluster that is not reflected in this repo, add a comment
   to the relevant node file explaining the deviation and why.

## Backup and restore

### etcd snapshots

K3s automatically takes etcd snapshots. On the control plane node:

```bash
ssh root@<mini-pc-ip>

# List existing snapshots
k3s etcd-snapshot list

# Take a manual snapshot
k3s etcd-snapshot save --name manual-backup
```

Snapshots are stored in `/var/lib/rancher/k3s/server/db/snapshots/` by default.

### Restore from snapshot

If the control plane needs to be rebuilt:

```bash
# On the control plane node
k3s server --cluster-reset --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot-file>
```

This resets the cluster to the state in the snapshot. Workers will need to rejoin.

### Back up this repository

Since this is a private Git repository, your infrastructure definitions are versioned.
Ensure you push regularly and consider enabling GitHub's repository backup features or
cloning to a second remote.
