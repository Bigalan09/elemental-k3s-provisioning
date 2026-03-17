# Bootstrap guide

End-to-end guide for bootstrapping the homelab K3s cluster from a MacBook.

This guide assumes you are starting from zero: no cluster, no Rancher, no OS on the
target hardware.

## The chicken-and-egg problem

Elemental requires a running Rancher instance with the Elemental Operator to register
and provision nodes. But we need a cluster to run Rancher on. This is the chicken-and-egg
problem.

**Solution for this homelab:** Bootstrap K3s manually on the mini PC first. Install
Rancher and the Elemental Operator on that single-node cluster. Then use Rancher to
register and provision the three worker nodes via Elemental. The mini PC acts as both
the initial bootstrap host and the permanent control plane.

See [docs/architecture.md](architecture.md) for the full rationale behind this design.

## Prerequisites

- A MacBook with tools installed (see [docs/macbook-setup.md](macbook-setup.md))
- This repository cloned locally
- The four target machines (mini PC, ZimaBlade, ZimaBoard 1, ZimaBoard 2)
- A USB drive (8 GB or larger) for the Elemental ISO
- All machines connected to the same LAN with DHCP
- Internet access on all machines (for pulling container images)
- An SSH key pair on the MacBook

## Step 1: Prepare the MacBook environment

Install all required tools:

```bash
brew install yq shellcheck yamllint kubeconform kubectl helm jq
```

Verify they work:

```bash
yq --version && kubectl version --client && helm version --short
```

Clone this repo if you have not already:

```bash
git clone git@github.com:Bigalan09/elemental-k3s-provisioning.git
cd elemental-k3s-provisioning
```

Run validation to confirm the repo is in a good state:

```bash
bash scripts/validate.sh
```

## Step 2: Install K3s on the mini PC

This is the manual bootstrap step that solves the chicken-and-egg problem. You are
installing K3s directly on the mini PC so it can host Rancher.

### Option A: Install from the Elemental ISO (recommended)

If you want the mini PC to run the same Elemental OS as the workers:

1. Download or build the Elemental ISO. For the initial bootstrap, use a generic ISO
   without a registration URL (or one configured for local registration).

2. Write the ISO to USB from your MacBook:

   ```bash
   diskutil list                    # identify the USB drive
   diskutil unmountDisk /dev/disk4  # replace disk4 with your USB device
   sudo dd if=elemental-installer.iso of=/dev/rdisk4 bs=4m status=progress
   diskutil eject /dev/disk4
   ```

3. Boot the mini PC from USB.

4. Once the OS is installed and the mini PC has rebooted, SSH in:

   ```bash
   ssh root@<mini-pc-ip>
   ```

5. Install K3s as a server:

   ```bash
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -
   ```

### Option B: Install K3s directly (without Elemental)

If you want to get started quickly and plan to re-provision the mini PC with Elemental
later:

1. Boot the mini PC with any Linux distribution (or its existing OS).

2. SSH in and install K3s:

   ```bash
   ssh root@<mini-pc-ip>
   curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server" sh -
   ```

### Verify K3s is running

On the mini PC:

```bash
k3s kubectl get nodes
```

You should see one node with status `Ready`.

### Copy the kubeconfig to your MacBook

```bash
# On the mini PC, the kubeconfig is at /etc/rancher/k3s/k3s.yaml
# Copy it to your MacBook and update the server address:
scp root@<mini-pc-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/lab-cluster.yaml

# Edit the server address from 127.0.0.1 to the mini PC's LAN IP:
sed -i '' "s/127.0.0.1/<mini-pc-ip>/g" ~/.kube/lab-cluster.yaml

# Verify from your MacBook:
kubectl get nodes --kubeconfig ~/.kube/lab-cluster.yaml
```

## Step 3: Install Rancher and Elemental Operator

From your MacBook, using the kubeconfig from step 2.

### Install cert-manager (required by Rancher)

```bash
export KUBECONFIG=~/.kube/lab-cluster.yaml

kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml

# Wait for cert-manager to be ready
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s
```

### Install Rancher

```bash
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

helm install rancher rancher-latest/rancher \
  --namespace cattle-system \
  --create-namespace \
  --set hostname=rancher.lab.internal \
  --set bootstrapPassword=admin \
  --set replicas=1
```

Wait for Rancher to be ready:

```bash
kubectl rollout status deployment rancher -n cattle-system --timeout=300s
```

> **Note:** `rancher.lab.internal` should resolve to the mini PC's IP. Add it to
> `/etc/hosts` on your MacBook:
>
> ```bash
> echo "<mini-pc-ip>  rancher.lab.internal" | sudo tee -a /etc/hosts
> ```

Access the Rancher UI at `https://rancher.lab.internal` and set a permanent password.

### Install the Elemental Operator

```bash
helm repo add rancher-charts https://charts.rancher.io
helm repo update

helm install --create-namespace -n cattle-elemental-system \
  elemental-operator-crds \
  rancher-charts/elemental-operator-crds

helm install --create-namespace -n cattle-elemental-system \
  elemental-operator \
  rancher-charts/elemental-operator
```

Verify the operator is running:

```bash
kubectl get pods -n cattle-elemental-system
```

All pods should show `Running`.

## Step 4: Create required secrets

Create the SSH authorised keys secret. This makes your MacBook's SSH public key
available to all provisioned nodes:

```bash
kubectl create secret generic lab-ssh-authorized-keys \
  --namespace fleet-default \
  --from-file=ssh-authorized-keys=~/.ssh/id_ed25519.pub
```

Create the registration token secret:

```bash
kubectl create secret generic lab-registration-token \
  --namespace fleet-default \
  --from-literal=token="$(openssl rand -hex 32)"
```

If Tailscale is enabled for any node:

```bash
kubectl create secret generic tailscale-auth-key \
  --namespace fleet-default \
  --from-literal=authkey="tskey-auth-..."
```

## Step 5: Render node artefacts

From your MacBook, in the repository root:

```bash
bash scripts/render.sh --env lab
```

This produces rendered manifests in `dist/lab/` for each node:

```
dist/lab/mini-pc/
dist/lab/zimablade/
dist/lab/zimaboard-1/
dist/lab/zimaboard-2/
```

Each directory contains:

- `machine-registration.yaml`
- `cloud-config.yaml`
- `node-role.yaml`
- `cluster-node.yaml`
- `seed-image.yaml`

## Step 6: Apply registration resources

Apply the environment-level MachineRegistration:

```bash
kubectl apply -f clusters/lab/machine-registration.yaml
```

Apply per-node registration and role manifests:

```bash
for dir in dist/lab/*/; do
  kubectl apply -f "${dir}/machine-registration.yaml"
  kubectl apply -f "${dir}/node-role.yaml"
  kubectl apply -f "${dir}/cluster-node.yaml"
done
```

Verify the registrations were created:

```bash
kubectl get machineregistration -n fleet-default
```

Retrieve the registration URL (you will embed this in the Elemental ISO):

```bash
kubectl get machineregistration lab-registration \
  -n fleet-default \
  -o jsonpath='{.status.registrationURL}'
```

## Step 7: Obtain and prepare the Elemental ISO

### Download the ISO

Get the Elemental ISO from the SUSE/Rancher release page or build it using the
Elemental toolkit. The ISO must contain or be configured with the registration URL
from step 6.

### Embed the registration URL

If you are building the ISO, include the registration URL in the ISO configuration.
If using a pre-built ISO, the registration URL can be provided via kernel command
line parameters during boot.

Consult the Elemental documentation for your specific ISO version.

### Write the ISO to USB

From your MacBook:

```bash
diskutil list                    # identify the USB drive
diskutil unmountDisk /dev/disk4  # replace disk4 with your USB device
sudo dd if=elemental-installer.iso of=/dev/rdisk4 bs=4m status=progress
diskutil eject /dev/disk4
```

## Step 8: Boot the worker machines

For each of the three worker machines (ZimaBlade, ZimaBoard 1, ZimaBoard 2):

1. Insert the USB drive.
2. Power on the machine.
3. Enter the BIOS (typically `DEL` or `F2`) and set USB as the first boot device.
4. Boot from USB.
5. The Elemental installer will:
   - Contact the management cluster using the registration URL
   - Register the machine as a `MachineInventory`
   - Install the OS to the configured device
   - Reboot

You can provision one machine at a time (reusing the same USB drive) or create
multiple USB drives to provision in parallel.

## Step 9: Monitor registration

Watch for machines to register:

```bash
kubectl get machineinventory -n fleet-default -w
```

You should see three entries appear as each worker boots and registers:

```
NAME           AGE
zimablade      1m
zimaboard-1   1m
zimaboard-2   2m
```

## Step 10: Assign K3s roles

The node role configs were already applied in step 6. Rancher and the Elemental
Operator will use these to determine that `mini-pc` runs as a K3s server and the
three Zima devices run as K3s agents.

If you need to re-apply:

```bash
for dir in dist/lab/*/; do
  kubectl apply -f "${dir}/node-role.yaml"
done
```

## Step 11: Verify the cluster

### Check all nodes

```bash
kubectl get nodes --kubeconfig ~/.kube/lab-cluster.yaml
```

Expected output:

```
NAME           STATUS   ROLES                  AGE   VERSION
mini-pc        Ready    control-plane,master   15m   v1.29.4+k3s1
zimablade      Ready    <none>                 5m    v1.29.4+k3s1
zimaboard-1   Ready    <none>                 5m    v1.29.4+k3s1
zimaboard-2   Ready    <none>                 4m    v1.29.4+k3s1
```

### Check node labels

```bash
kubectl get nodes --show-labels --kubeconfig ~/.kube/lab-cluster.yaml
```

Verify that `mini-pc` has `node-type=control-plane` and the workers have
`node-type=worker`.

### Check system pods

```bash
kubectl get pods -A --kubeconfig ~/.kube/lab-cluster.yaml
```

All pods in `kube-system`, `cattle-system`, and `cattle-elemental-system` should be
`Running` or `Completed`.

### Check cluster info

```bash
kubectl cluster-info --kubeconfig ~/.kube/lab-cluster.yaml
```

## Step 12: Post-bootstrap state

After completing this guide, you have:

| Component | State | Location |
|-----------|-------|----------|
| K3s server | Running | mini-pc |
| K3s agents | Running | zimablade, zimaboard-1, zimaboard-2 |
| Rancher | Running | mini-pc (cattle-system namespace) |
| Elemental Operator | Running | mini-pc (cattle-elemental-system namespace) |
| cert-manager | Running | mini-pc (cert-manager namespace) |
| Node definitions | In this repo | `nodes/lab/` |
| Rendered artefacts | In this repo | `dist/lab/` (gitignored) |
| kubeconfig | On your MacBook | `~/.kube/lab-cluster.yaml` |
| SSH access | Via key pair | MacBook → all nodes |

### What to do next

- **Commit your changes.** If you modified any node definitions, push them to the repo.
- **Set up backups.** Take an initial etcd snapshot on the mini PC:

  ```bash
  ssh root@<mini-pc-ip> k3s etcd-snapshot save --name post-bootstrap
  ```

- **Deploy workloads.** The cluster is ready to run applications.
- **Read the operations guide.** See [docs/operations.md](operations.md) for day-2
  tasks like adding nodes, rotating secrets, and checking health.

## Secret management summary

All secret material is managed externally as Kubernetes Secrets. This repository never
stores real secret values.

| Secret | Referenced by | How to create |
|--------|--------------|---------------|
| SSH authorised keys | `sshKeySecretRef` in cluster-config.yaml | `kubectl create secret generic <name> --from-file=...` |
| Registration token | `registrationTokenSecretRef` in cluster-config.yaml | `kubectl create secret generic <name> --from-literal=...` |
| Tailscale auth key | `tailscale.authKeySecretName` in node definitions | `kubectl create secret generic <name> --from-literal=...` |
