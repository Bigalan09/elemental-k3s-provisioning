# Troubleshooting

Common problems and solutions for this homelab Elemental K3s cluster.

## MacBook environment issues

### Missing required tools

**Symptom:** `scripts/validate.sh` fails immediately with `ERROR: Required tool 'yq' is not installed`.

**Fix:** Install all required tools:

```bash
brew install yq shellcheck yamllint kubeconform kubectl helm jq
```

See [macbook-setup.md](macbook-setup.md) for the complete tool list.

### Wrong yq version

**Symptom:** Rendering fails with unexpected yq errors such as `unknown flag` or
`invalid syntax`.

**Fix:** This repo requires `yq` v4 (Mike Farah's version). Check your version:

```bash
yq --version
```

If you have the Python-based `yq` (a `jq` wrapper), remove it and install the
correct one:

```bash
pip uninstall yq
brew install yq
```

### yamllint not found via Homebrew

**Symptom:** `brew install yamllint` fails or installs a different package.

**Fix:** yamllint is a Python package. If the Homebrew formula is unavailable:

```bash
pip install yamllint
```

Ensure the `yamllint` binary is on your `PATH`.

## Rendering failures

### Missing hostname field

**Symptom:** `render.sh` exits with `ERROR: Missing required field 'hostname'`.

**Fix:** Every node definition file must have a `hostname` field:

```yaml
hostname: zimaboard-1
role: agent
installDevice: /dev/sda
```

### Missing cluster config

**Symptom:** Rendering produces unexpected values or empty SSH secret references.

**Fix:** Ensure a `clusters/lab/cluster-config.yaml` exists with the correct
`sshKeySecretRef` and `registrationTokenSecretRef` fields. The render script
falls back to empty values if the cluster config is missing.

### yq template errors

**Symptom:** `yq` outputs `Error: no matches found` or similar template errors.

**Fix:** Check that the template files in `templates/` have not been modified from
the expected structure. The render script relies on specific field paths existing
in each template.

## Invalid YAML

### yamllint failures

**Symptom:** `validate.sh` reports `FAIL: yamllint: <file>`.

**Fix:** Run yamllint on the specific file to see the exact error:

```bash
yamllint --strict <file>
```

Common causes:

- Missing `---` document start marker (required by `.yamllint.yaml` config)
- Lines longer than 120 characters
- Incorrect indentation
- Trailing whitespace

### kubeconform failures

**Symptom:** `validate.sh` reports `FAIL: kubeconform: <file>`.

**Fix:** kubeconform validates Kubernetes manifests against schemas. Elemental CRDs
(MachineRegistration, NodeRoleConfig, etc.) use custom schemas that kubeconform may
not recognise. The validation script uses `-ignore-missing-schemas` to handle this.

If kubeconform fails on a known-good manifest:

```bash
kubeconform -strict -ignore-missing-schemas -summary <file>
```

Check for structural issues like wrong `apiVersion` or missing required fields.

## Registration failures

### Machine does not register

**Symptom:** You booted the Elemental ISO but no `MachineInventory` appears in the
management cluster.

**Checklist:**

1. **Is the registration URL correct?** Verify the URL embedded in the ISO matches
   the management cluster:

   ```bash
   kubectl get machineregistration lab-registration -n fleet-default \
     -o jsonpath='{.status.registrationURL}'
   ```

2. **Can the node reach the management cluster?** From the booted node's console:

   ```bash
   curl -k https://<rancher-url>/healthz
   ```

   If this times out, check networking (see networking section below).

3. **Is the Elemental Operator running?**

   ```bash
   kubectl get pods -n cattle-elemental-system
   ```

   All pods should be `Running`.

4. **Check the node's registration logs:**

   ```bash
   journalctl -u elemental-register -f
   ```

### MachineInventory stuck in a pending state

**Symptom:** `MachineInventory` exists but the node is not being provisioned.

**Fix:** Check the machine inventory status:

```bash
kubectl describe machineinventory <hostname> -n fleet-default
```

Look for events or conditions that indicate why provisioning has not started.
Common causes:

- No matching `MachineRegistration` selector
- Missing registration token secret
- Cluster resource not yet created

## Node does not appear in inventory

**Symptom:** The machine booted and registered but does not show in `kubectl get machineinventory`.

**Fix:**

1. Check the correct namespace:

   ```bash
   kubectl get machineinventory -A
   ```

2. Check if the registration was created in a different namespace.

3. Verify the `MachineRegistration` selector labels match the inventory labels set
   during registration.

## Node hostname is wrong

**Symptom:** The node registered with a hostname like `localhost` or a random name
instead of the expected hostname.

**Fix:** The hostname is set by the cloud-config rendered from this repo. Verify:

1. The node definition has the correct `hostname` field.
2. The rendered `cloud-config.yaml` in `dist/lab/<hostname>/` has the correct
   hostname.
3. The `MachineRegistration` has the hostname label set correctly.

If the node already registered with the wrong hostname, delete the
`MachineInventory`, fix the cloud-config, and re-register:

```bash
kubectl delete machineinventory <wrong-hostname> -n fleet-default
```

## Worker does not join cluster

**Symptom:** Worker node is provisioned but does not appear in `kubectl get nodes`.

**Checklist:**

1. **Is the K3s agent running?** SSH into the worker:

   ```bash
   ssh root@<worker-ip>
   systemctl status k3s-agent
   journalctl -u k3s-agent -f
   ```

2. **Can the worker reach the control plane?** From the worker:

   ```bash
   curl -k https://<mini-pc-ip>:6443/healthz
   ```

3. **Is the registration token correct?** The agent needs the correct token to
   join. Check the K3s agent configuration:

   ```bash
   cat /etc/rancher/k3s/config.yaml
   ```

4. **Are there firewall rules blocking traffic?** K3s requires:
   - TCP 6443 (API server)
   - TCP 10250 (kubelet)
   - UDP 8472 (VXLAN, if using flannel)
   - TCP 2379-2380 (etcd, server nodes only)

## Control plane does not become ready

**Symptom:** The mini-pc control plane node shows `NotReady` or the K3s server does
not start.

**Checklist:**

1. **Check K3s server status:**

   ```bash
   ssh root@<mini-pc-ip>
   systemctl status k3s
   journalctl -u k3s --no-pager -n 100
   ```

2. **Check etcd health:**

   ```bash
   k3s etcd-snapshot list
   ```

3. **Check disk space:** etcd can fail if the disk is full:

   ```bash
   df -h /var/lib/rancher/k3s
   ```

4. **Check memory:** The control plane needs sufficient RAM:

   ```bash
   free -h
   ```

   If the mini PC has less than 4 GB, the control plane may struggle under load.

## Rancher or OS Manager connectivity issues

### Rancher UI not accessible

**Symptom:** Cannot reach the Rancher UI from your MacBook.

**Checklist:**

1. **Is Rancher running?**

   ```bash
   kubectl get pods -n cattle-system --kubeconfig ~/.kube/lab-cluster.yaml
   ```

2. **What service type is Rancher using?**

   ```bash
   kubectl get svc -n cattle-system --kubeconfig ~/.kube/lab-cluster.yaml
   ```

3. **If using NodePort or LoadBalancer, is the correct IP/port accessible?**

4. **DNS resolution:** Ensure the Rancher hostname resolves to the control plane IP.
   For a homelab, add an entry to `/etc/hosts` on your MacBook:

   ```
   192.168.1.100  rancher.lab.internal
   ```

### Elemental Operator not running

**Symptom:** MachineRegistration resources are not processed.

**Fix:**

```bash
kubectl get pods -n cattle-elemental-system
kubectl describe pod -n cattle-elemental-system -l app=elemental-operator
kubectl logs -n cattle-elemental-system -l app=elemental-operator --tail=50
```

If the operator crashed, check for resource constraints or configuration issues.

## USB boot problems

### Machine does not boot from USB

**Checklist:**

1. **BIOS boot order:** Enter the BIOS and set USB as the first boot device.
2. **Secure Boot:** Disable Secure Boot if enabled.
3. **USB drive format:** The ISO must be written as a raw image, not copied as a file.
   Use `dd` or balenaEtcher (see [macbook-setup.md](macbook-setup.md)).
4. **USB port:** Try a different USB port. Some machines have USB ports that do not
   support booting.

### ISO written incorrectly from macOS

**Symptom:** Machine boots to a blank screen or GRUB error after writing the ISO.

**Fix:** Ensure you used the raw disk device and correct `dd` parameters:

```bash
sudo dd if=elemental-installer.iso of=/dev/rdisk4 bs=4m status=progress
```

Common mistakes:

- Using `/dev/disk4` instead of `/dev/rdisk4` (slow and sometimes incomplete)
- Wrong block size (use `bs=4m` on macOS, lowercase `m`)
- Writing to the wrong disk (always verify with `diskutil list`)

## Networking issues in a homelab

### Nodes cannot reach each other

**Checklist:**

1. **Same subnet?** All nodes should be on the same Layer 2 network for simplest
   setup.

2. **IP assignment:** Check that each node has an IP via DHCP or static configuration:

   ```bash
   ip addr show
   ```

3. **Router/switch issues:** Verify cables, switch ports, and that the router's DHCP
   pool has enough addresses.

4. **Firewall on the router:** Some consumer routers block inter-device traffic.
   Disable AP isolation or client isolation if enabled.

### Nodes cannot reach the internet

K3s needs internet access during initial setup to pull container images.

**Fix:**

1. Check DNS resolution:

   ```bash
   nslookup registry.suse.com
   ```

2. Check default gateway:

   ```bash
   ip route show default
   ```

3. If behind a proxy, configure the K3s service to use it.

### Pod networking issues

**Symptom:** Pods cannot communicate across nodes.

**Fix:** K3s uses flannel VXLAN by default. Check:

```bash
kubectl get pods -n kube-system -l app=flannel --kubeconfig ~/.kube/lab-cluster.yaml
```

If flannel pods are crashing, check node-to-node connectivity on UDP port 8472.

## What to inspect first on each layer

### MacBook (operator workstation)

1. Can you reach the management cluster? `kubectl cluster-info`
2. Are tools installed? `bash scripts/validate.sh`
3. Can you SSH to nodes? `ssh root@<node-ip>`

### Management cluster (Rancher / Elemental Operator)

1. Are Rancher pods healthy? `kubectl get pods -n cattle-system`
2. Is the Elemental Operator running? `kubectl get pods -n cattle-elemental-system`
3. Are MachineRegistrations created? `kubectl get machineregistration -n fleet-default`
4. Are MachineInventory entries present? `kubectl get machineinventory -n fleet-default`

### Target node (booting or registered)

1. Did the node boot from USB? Check console output.
2. Is the registration service running? `journalctl -u elemental-register`
3. Is the OS installed? `lsblk` to check if partitions were created.
4. Is the K3s service running? `systemctl status k3s` or `systemctl status k3s-agent`

### Provisioned cluster (K3s)

1. Are all nodes Ready? `kubectl get nodes`
2. Are system pods running? `kubectl get pods -n kube-system`
3. Is DNS working? `kubectl run -it --rm debug --image=busybox -- nslookup kubernetes`
4. Are workloads scheduling? `kubectl get pods -A`
