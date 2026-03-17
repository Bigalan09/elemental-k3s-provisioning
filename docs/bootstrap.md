# Bootstrap guide

## Prerequisites

- Rancher management cluster running (K3s or RKE2)
- Rancher OS Manager (Elemental Operator) installed
- `kubectl` configured for the management cluster
- Elemental bootable ISO or OCI image available
- SSH authorised keys prepared (not committed to this repository)

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

## Step 2: Create required secrets

Create the SSH authorised keys secret for each environment. The secret name must match the `sshKeySecretRef.name` in the corresponding `clusters/<env>/cluster-config.yaml`.

```bash
# Example for production
kubectl create secret generic production-ssh-authorized-keys \
  --namespace fleet-default \
  --from-file=ssh-authorized-keys=/path/to/authorized_keys
```

Create the registration token secret:

```bash
kubectl create secret generic production-registration-token \
  --namespace fleet-default \
  --from-literal=token="$(openssl rand -hex 32)"
```

If Tailscale is enabled for any node, create the auth key secret:

```bash
kubectl create secret generic tailscale-auth-key \
  --namespace fleet-default \
  --from-literal=authkey="tskey-auth-..."
```

## Step 3: Apply registration resources

Render the node configurations from this repository:

```bash
bash scripts/render.sh --env production
```

Apply the environment-level `MachineRegistration` to the management cluster:

```bash
kubectl apply -f clusters/production/machine-registration.yaml
```

Optionally apply rendered per-node registrations from `dist/`:

```bash
for dir in dist/production/*/; do
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

## Step 4: Boot Elemental media on target hardware

Boot each target machine from the Elemental ISO containing the registration URL. The node will register, install the OS, and reboot.

## Step 5: Register machines

Monitor node registration:

```bash
kubectl get machineinventory -n fleet-default -w
```

## Step 6: Assign K3s roles

Apply the rendered node role configs:

```bash
for dir in dist/production/*/; do
  kubectl apply -f "${dir}/node-role.yaml"
done
```

Rancher will then provision K3s on each registered node according to its assigned role.

## Step 7: Verify

Check that all nodes have joined the cluster:

```bash
kubectl get nodes --kubeconfig /path/to/provisioned-cluster-kubeconfig
```

Check cluster health:

```bash
kubectl get pods -A --kubeconfig /path/to/provisioned-cluster-kubeconfig
```

Verify node labels and taints match the definitions in this repository:

```bash
kubectl describe nodes --kubeconfig /path/to/provisioned-cluster-kubeconfig
```

## Secret management summary

All secret material is managed externally as Kubernetes Secrets. This repository never stores real secret values.

| Secret | Referenced by | How to create |
|--------|--------------|---------------|
| SSH authorised keys | `sshKeySecretRef` in cluster-config.yaml | `kubectl create secret generic <name> --from-file=...` |
| Registration token | `registrationTokenSecretRef` in cluster-config.yaml | `kubectl create secret generic <name> --from-literal=...` |
| Tailscale auth key | `tailscale.authKeySecretName` in node definitions | `kubectl create secret generic <name> --from-literal=...` |
