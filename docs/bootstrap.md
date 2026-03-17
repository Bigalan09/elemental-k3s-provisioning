# Bootstrap guide

This document describes a realistic bootstrap flow for setting up Elemental based K3s node provisioning.

## Prerequisites

Before starting, ensure the following are in place:

- A Rancher management cluster is running (K3s or RKE2 recommended).
- Rancher OS Manager (Elemental Operator) is installed on the management cluster.
- `kubectl` is configured to access the management cluster.
- An Elemental bootable ISO or OCI image is available for target hardware.
- SSH public keys are available for injecting into node definitions.

## Step 1: Prepare the management environment

Install Rancher OS Manager on the management cluster using Helm:

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

## Step 2: Apply registration resources

Render the node configurations from this repository:

```bash
bash scripts/render.sh --all
```

Apply the production `MachineRegistration` to the management cluster:

```bash
kubectl apply -f clusters/production/machine-registration.yaml
```

Optionally apply rendered per-node registrations from `dist/`:

```bash
for dir in dist/*/; do
  kubectl apply -f "${dir}/machine-registration.yaml"
done
```

Verify the registration was created:

```bash
kubectl get machineregistration -n fleet-default
```

Retrieve the registration URL that will be embedded in the ISO:

```bash
kubectl get machineregistration production-registration \
  -n fleet-default \
  -o jsonpath='{.status.registrationURL}'
```

## Step 3: Boot Elemental media on target hardware

Download or build the Elemental ISO that contains the registration URL from step 2.

Boot each target machine from the ISO. The boot process:

1. Starts a minimal Linux environment
2. Reads the registration URL from the ISO configuration
3. Contacts the management cluster
4. Installs the Elemental managed OS to the configured device
5. Reboots into the installed OS

## Step 4: Register machines

After booting, each node registers itself with the management cluster by creating a `MachineInventory` resource. You can monitor registration:

```bash
kubectl get machineinventory -n fleet-default -w
```

Once a node appears in the inventory, it is ready for cluster provisioning.

## Step 5: Assign or apply K3s roles

Rancher creates a `RKE2Cluster` or `K3sCluster` resource that references the registered nodes. You can also use Fleet to apply GitOps-managed cluster provisioning configs.

Apply the rendered node role configs to assign K3s server or agent roles:

```bash
for dir in dist/*/; do
  kubectl apply -f "${dir}/node-role.yaml"
done
```

Rancher will then provision K3s on each registered node according to its assigned role.

For the initial server node, K3s starts with `--cluster-init` to initialise the etcd datastore. Subsequent server nodes join with `--server` pointing at the first server. Agent nodes join using the cluster endpoint and token.

## Step 6: Verify node and cluster state

Check that all nodes have joined the cluster:

```bash
kubectl get nodes --kubeconfig /path/to/provisioned-cluster-kubeconfig
```

Check cluster health:

```bash
kubectl get componentstatuses --kubeconfig /path/to/provisioned-cluster-kubeconfig
kubectl get pods -A --kubeconfig /path/to/provisioned-cluster-kubeconfig
```

Verify node labels and taints match the definitions in this repository:

```bash
kubectl describe nodes --kubeconfig /path/to/provisioned-cluster-kubeconfig
```

## Secret management

The following values must be provided externally and must not be stored in this repository:

| Secret | How to provide |
|--------|----------------|
| SSH public keys | Add to node definition files in `nodes/examples/` at provisioning time |
| Registration token | Create as a Kubernetes Secret in the management cluster |
| Tailscale auth keys | Create as Kubernetes Secrets referenced by `authKeySecretName` in node definitions |

Example of creating the registration token secret:

```bash
kubectl create secret generic registration-token \
  --namespace fleet-default \
  --from-literal=token="$(openssl rand -hex 32)"
```

Example of creating a Tailscale auth key secret:

```bash
kubectl create secret generic tailscale-agent-01-authkey \
  --namespace fleet-default \
  --from-literal=authkey="tskey-auth-PLACEHOLDER"
```
