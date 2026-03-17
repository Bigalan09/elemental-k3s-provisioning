# Tailscale ingress

This guide explains how to make the homelab K3s cluster accessible via your
Tailscale tailnet using the Tailscale Kubernetes operator. After setup, you can
reach the K3s API server and Rancher UI from any device on your tailnet without
port forwarding, dynamic DNS, or exposing services to the public internet.

## Why Tailscale for a homelab

In a homelab the cluster typically sits behind a consumer router with a dynamic
IP. Tailscale solves several problems at once:

- **Remote kubectl access.** Run `kubectl` from your MacBook on any network —
  coffee shop, office, or mobile hotspot — as if you were on the LAN.
- **Secure Rancher access.** Reach the Rancher UI over a WireGuard tunnel without
  opening ports on your router.
- **No DNS hacks.** Tailscale provides MagicDNS names (`*.ts.net`) that resolve
  automatically on every tailnet device.
- **Zero public exposure.** Nothing is exposed to the internet.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Tailscale Tailnet                      │
│                                                          │
│  ┌──────────┐        ┌──────────────────────────────┐   │
│  │ MacBook  │──ts──▶ │  K3s cluster (lab)            │   │
│  │          │        │                               │   │
│  │ kubectl  │──────▶ │  k3s-api-lab.ts.net:443       │   │
│  │ browser  │──────▶ │  rancher-lab.ts.net:443       │   │
│  └──────────┘        │                               │   │
│                      │  Tailscale operator creates    │   │
│                      │  tailnet nodes for each        │   │
│                      │  exposed Service / Ingress     │   │
│                      └──────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

The Tailscale Kubernetes operator runs inside the cluster and:

1. Watches for `Ingress` resources with `ingressClassName: tailscale`
2. Watches for `Service` resources with `loadBalancerClass: tailscale`
3. Creates a Tailscale node (a proxy pod) for each matched resource
4. Advertises that node on your tailnet with a MagicDNS hostname

## Prerequisites

- The K3s cluster is running and healthy (see [bootstrap.md](bootstrap.md))
- A Tailscale account at [login.tailscale.com](https://login.tailscale.com)
- Tailscale installed on your MacBook (`brew install tailscale` or the macOS app)
- Your MacBook is connected to your tailnet

## Step 1: Create a Tailscale OAuth client

The operator authenticates to your tailnet using an OAuth client, not an auth key.

1. Go to [Tailscale Admin → Settings → OAuth clients](https://login.tailscale.com/admin/settings/oauth)
2. Click **Generate OAuth client**
3. Grant the following scopes:
   - `devices:read`
   - `devices:write`
   - `dns:read`
4. Copy the **client ID** and **client secret**

## Step 2: Create ACL tags (recommended)

In your Tailscale ACL policy ([login.tailscale.com/admin/acls](https://login.tailscale.com/admin/acls)),
add tags for Kubernetes-managed nodes:

```json
{
  "tagOwners": {
    "tag:k8s": ["autogroup:admin"],
    "tag:k8s-api": ["autogroup:admin"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:k8s:*", "tag:k8s-api:443"]
    }
  ]
}
```

This allows any member of your tailnet to reach Kubernetes-managed services, and
restricts the API server proxy to port 443 only.

Adjust the ACLs to match your security requirements.

## Step 3: Create the operator OAuth secret

On your MacBook, using the lab cluster kubeconfig:

```bash
export KUBECONFIG=~/.kube/lab-cluster.yaml

kubectl create namespace tailscale-system

kubectl create secret generic operator-oauth \
  --namespace tailscale-system \
  --from-literal=client_id="<your-oauth-client-id>" \
  --from-literal=client_secret="<your-oauth-client-secret>"
```

> **Security note:** The OAuth secret is stored in the cluster only, never in this
> repository.

## Step 4: Install the Tailscale Kubernetes operator

```bash
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update

helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale-system \
  --create-namespace \
  --set-string oauth.clientId="<your-oauth-client-id>" \
  --set-string oauth.clientSecret="<your-oauth-client-secret>" \
  --set-string apiServerProxyConfig.mode="true" \
  --wait
```

Alternatively, use the values file from this repo:

```bash
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale-system \
  --create-namespace \
  --values clusters/lab/tailscale/operator-values.yaml \
  --set-string oauth.clientId="<your-oauth-client-id>" \
  --set-string oauth.clientSecret="<your-oauth-client-secret>" \
  --wait
```

Verify the operator is running:

```bash
kubectl get pods -n tailscale-system
```

Expected output:

```
NAME                                  READY   STATUS    RESTARTS   AGE
tailscale-operator-...                1/1     Running   0          30s
```

Check your Tailscale admin console — you should see a new machine named
`ts-operator-lab` appear in your tailnet.

## Step 5: Expose the Rancher UI on the tailnet

Apply the Rancher ingress resource:

```bash
kubectl apply -f clusters/lab/tailscale/ingress-rancher.yaml
```

This creates a Tailscale Ingress that exposes Rancher on your tailnet.

Verify the ingress:

```bash
kubectl get ingress -n cattle-system
```

Expected output:

```
NAME                 CLASS       HOSTS         ADDRESS   PORTS     AGE
rancher-tailscale    tailscale   rancher-lab             80, 443   30s
```

After a moment, the operator creates a proxy pod and registers a tailnet node.
Check for the new device in your Tailscale admin console or:

```bash
tailscale status
```

Access Rancher from your MacBook:

```
https://rancher-lab.<tailnet-name>.ts.net
```

Replace `<tailnet-name>` with your actual tailnet name (visible in the Tailscale
admin console).

## Step 6: Expose the K3s API server on the tailnet

Apply the API server proxy:

```bash
kubectl apply -f clusters/lab/tailscale/apiserver-proxy.yaml
```

This creates a LoadBalancer Service with `loadBalancerClass: tailscale` that
proxies traffic to the K3s API server.

Verify the service:

```bash
kubectl get svc k3s-api-tailscale-lb -n default
```

Wait for the `EXTERNAL-IP` to be assigned (it will show a tailnet IP):

```
NAME                    TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)         AGE
k3s-api-tailscale-lb    LoadBalancer   10.43.x.x      100.x.x.x       443:xxxxx/TCP   30s
```

## Step 7: Configure kubectl for tailnet access

Once the API server is exposed on the tailnet, configure a new kubectl context:

```bash
# Get the tailnet FQDN (e.g., k3s-api-lab.<tailnet-name>.ts.net)
TAILNET_API="k3s-api-lab.<tailnet-name>.ts.net"

# Add a new cluster entry
kubectl config set-cluster lab-tailscale \
  --server="https://${TAILNET_API}:443" \
  --insecure-skip-tls-verify=true

# Add a new context using your existing credentials
kubectl config set-context lab-tailscale \
  --cluster=lab-tailscale \
  --user=lab-admin

# Switch to the tailnet context
kubectl config use-context lab-tailscale

# Test
kubectl get nodes
```

> **Note on TLS:** The Tailscale proxy terminates TLS with a tailnet certificate.
> You may need `--insecure-skip-tls-verify` initially because the proxy certificate
> does not match the original K3s API server certificate. For production use,
> configure the Tailscale operator to use your tailnet's HTTPS certificates.

### Using a dedicated kubeconfig file

To keep your tailnet config separate:

```bash
cat > ~/.kube/lab-tailscale.yaml << EOF
apiVersion: v1
kind: Config
clusters:
  - name: lab-tailscale
    cluster:
      server: https://k3s-api-lab.<tailnet-name>.ts.net:443
      insecure-skip-tls-verify: true
contexts:
  - name: lab-tailscale
    context:
      cluster: lab-tailscale
      user: lab-admin
current-context: lab-tailscale
users:
  - name: lab-admin
    user:
      # Copy the token or client-certificate-data from your existing kubeconfig
      token: "<your-token>"
EOF

kubectl get nodes --kubeconfig ~/.kube/lab-tailscale.yaml
```

## Verifying tailnet connectivity

### From your MacBook

```bash
# Check that Tailscale is running
tailscale status

# Ping the API server proxy
tailscale ping k3s-api-lab

# Ping the Rancher proxy
tailscale ping rancher-lab

# Verify kubectl works
kubectl get nodes --kubeconfig ~/.kube/lab-tailscale.yaml

# Open Rancher in a browser
open "https://rancher-lab.<tailnet-name>.ts.net"
```

### In the cluster

```bash
# Check operator pods
kubectl get pods -n tailscale-system

# Check proxy pods (one per exposed service/ingress)
kubectl get pods -n tailscale-system -l app=tailscale

# Check ingress status
kubectl get ingress -A

# Check tailscale services
kubectl get svc -A -l tailscale.com/managed=true
```

## What gets exposed

| Resource | Tailnet hostname | Port | Target |
|----------|-----------------|------|--------|
| Rancher UI | `rancher-lab.<tailnet>.ts.net` | 443 | Rancher service in `cattle-system` |
| K3s API server | `k3s-api-lab.<tailnet>.ts.net` | 443 → 6443 | Kubernetes API server |

Only devices on your tailnet can reach these endpoints. Nothing is exposed to the
public internet unless you explicitly enable Tailscale Funnel (which is disabled in
our ingress resources).

## Adding more services

To expose additional services on the tailnet, create an Ingress resource:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-service-tailscale
  namespace: <service-namespace>
  annotations:
    tailscale.com/funnel: "false"
spec:
  ingressClassName: tailscale
  defaultBackend:
    service:
      name: <service-name>
      port:
        number: <service-port>
  tls:
    - hosts:
        - <desired-tailnet-hostname>
```

Or a LoadBalancer service:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-service-tailscale
  namespace: <service-namespace>
  annotations:
    tailscale.com/hostname: "<desired-tailnet-hostname>"
spec:
  type: LoadBalancer
  loadBalancerClass: tailscale
  selector:
    <pod-selector>
  ports:
    - port: <external-port>
      targetPort: <container-port>
```

## Troubleshooting

### Operator pod not starting

```bash
kubectl describe pod -n tailscale-system -l app=tailscale-operator
kubectl logs -n tailscale-system -l app=tailscale-operator --tail=50
```

Common causes:
- OAuth secret not created or wrong credentials
- Missing ACL tags in Tailscale policy
- Network connectivity issues (cluster cannot reach `controlplane.tailscale.com`)

### Device not appearing in tailnet

Check the operator logs:

```bash
kubectl logs -n tailscale-system -l app=tailscale-operator --tail=100 | grep -i error
```

Verify the OAuth client has the required scopes (devices:read, devices:write).

### Ingress not getting an address

```bash
kubectl describe ingress rancher-tailscale -n cattle-system
```

Look for events indicating why the Tailscale proxy pod was not created.

### kubectl works on LAN but not via tailnet

- Verify `tailscale status` shows you are connected
- Verify the `k3s-api-lab` device is online in the Tailscale admin console
- Check that your ACLs allow traffic from your MacBook to `tag:k8s-api`
- Try `tailscale ping k3s-api-lab` to test connectivity

### Certificate errors

The Tailscale proxy uses tailnet TLS certificates. If kubectl complains about
certificate validation, use `--insecure-skip-tls-verify` or configure the
cluster entry with the correct CA.

## Security considerations

- **OAuth credentials** are stored as Kubernetes Secrets only, never in this repo.
- **ACL tags** control which tailnet devices can reach cluster services.
- **Funnel is disabled** on all ingress resources to prevent public internet exposure.
- **API server access** should be restricted via Tailscale ACLs to trusted devices.
- The Tailscale operator runs with permissions to create and manage proxy pods.
  Review the operator RBAC if you have concerns about least-privilege.
