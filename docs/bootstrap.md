# Bootstrap guide

## Prerequisites

- Rancher management cluster running (K3s or RKE2)
- Rancher OS Manager (Elemental Operator) installed
- `kubectl` configured for the management cluster
- Elemental bootable ISO or OCI image available
- SSH public keys ready for node definitions

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

Boot each target machine from the Elemental ISO containing the registration URL. The node will register, install the OS, and reboot.

## Step 4: Register machines

Monitor node registration:

```bash
kubectl get machineinventory -n fleet-default -w
```

## Step 5: Assign K3s roles

Apply the rendered node role configs:

```bash
for dir in dist/*/; do
  kubectl apply -f "${dir}/node-role.yaml"
done
```

Rancher will then provision K3s on each registered node according to its assigned role.

## Step 6: Verify

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

The following must be provided externally:

| Secret | How to provide |
|--------|----------------|
| SSH public keys | Add to node definition files in `nodes/examples/` |
| Registration token | Create as a Kubernetes Secret in the management cluster |

Example:

```bash
kubectl create secret generic registration-token \
  --namespace fleet-default \
  --from-literal=token="$(openssl rand -hex 32)"
```
