# K3S Web Orchestrator (KWO)

A minimal k3s setup for deploying web services with automated SSL certificates and multi-tenant isolation.

## What is KWO?

KWO is **not** a wrapper, CLI tool, or abstraction layer. It's a documented installation process that sets up k3s with sensible defaults for hosting web applications. You interact with your cluster using standard `kubectl` commands.

**What KWO provides:**
- ✅ One-command k3s installation with Traefik configured for automatic Let's Encrypt
- ✅ Multi-tenant RBAC setup documentation
- ✅ Seamless integration with external container registries
- ✅ Copy-paste ready examples for common deployment patterns

**What KWO does NOT provide:**
- ❌ Custom CLI tools (use `kubectl`)
- ❌ Abstraction layers (write standard Kubernetes YAML)
- ❌ Built-in monitoring or logging (add your own)
- ❌ Multi-node cluster support (use managed Kubernetes for HA)

## Quick Start

### Prerequisites

- Fresh server running **Debian 12+**, **Ubuntu 22.04+**, or **Fedora 39+**
- Root access
- DNS provider account (Cloudflare, OVH, Route53, or DigitalOcean)
- Domain name with DNS managed by one of the supported providers

### Installation

1. Clone this repository:
```bash
git clone https://github.com/marcochiodo/k3s-web-orchestrator.git
cd k3s-web-orchestrator
```

2. Run the installation script as root:
```bash
sudo ./install.sh
```

The script will prompt you for:
- Let's Encrypt notification email
- DNS provider selection
- DNS provider credentials
- Optional API endpoint domain

3. Create your first tenant:
```bash
kwo-create-tenant mytenant
# Kubeconfig saved to: /var/lib/kwo/kubeconfigs/mytenant-kubeconfig.yaml
```

4. List tenants:
```bash
kwo-list-tenants
```

5. Check cluster status:
```bash
kwo-status
```

6. Deploy an application:
```bash
# Use the generated kubeconfig
export KUBECONFIG=/var/lib/kwo/kubeconfigs/mytenant-kubeconfig.yaml

# Deploy
kubectl apply -f examples/app.yaml
```

That's it! Your application is now running with automatic HTTPS.

## Command Reference

After installation, the following commands are available:

**Tenant Management:**
- `kwo-create-tenant <name>` - Create a new isolated tenant namespace
- `kwo-delete-tenant <name>` - Delete tenant (archives data by default)
- `kwo-list-tenants` - List all tenants with resource counts
- `kwo-update-tenant <name> --rotate-token` - Rotate ServiceAccount token

**DNS Provider Management:**
- `kwo-dns add <provider> [--suffix=<name>] [--non-interactive]` - Add DNS provider
- `kwo-dns remove <resolver-name> [--force]` - Remove DNS provider
- `kwo-dns list [--format=table|json]` - List all DNS providers
- `kwo-dns update <resolver-name> [--non-interactive]` - Update provider credentials
- `kwo-dns check [resolver-name]` - Verify DNS provider credentials

Supported providers: `cloudflare`, `ovh`, `route53`, `digitalocean`

**Examples:**
```bash
# Add Cloudflare provider (interactive)
sudo kwo-dns add cloudflare

# Add OVH provider with suffix for multi-account
sudo kwo-dns add ovh --suffix=production

# Add provider non-interactively (from environment variables)
CF_DNS_API_TOKEN="xyz" sudo kwo-dns add cloudflare --non-interactive

# List all providers
sudo kwo-dns list

# Check all providers
sudo kwo-dns check
```

**Diagnostics:**
- `kwo-status` - Show cluster health and status
- `kwo-check-tls <domain>` - Check certificate status for a domain
- `kwo-logs <component>` - View logs (traefik, k3s, tenant:name)

All commands require `sudo` for execution.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         k3s Cluster                             │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Traefik (kube-system)                                    │  │
│  │  - Automatic Let's Encrypt via DNS-01                     │  │
│  │  - HTTP → HTTPS redirect                                  │  │
│  │  - Routes traffic to tenant services                      │  │
│  └─────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│  ┌─────────────────────────┴─────────────────────────────────┐  │
│  │  Tenant Namespaces (Isolated)                             │  │
│  │                                                           │  │
│  │  mytenant/          acme-corp/         customer-x/        │  │
│  │  ├─ Deployments    ├─ Deployments    ├─ Deployments     │  │
│  │  ├─ Services       ├─ Services       ├─ Services        │  │
│  │  ├─ Ingresses      ├─ Ingresses      ├─ Ingresses       │  │
│  │  └─ CronJobs       └─ CronJobs       └─ CronJobs        │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

## Container Registry Integration

KWO integrates seamlessly with external container registries. During tenant creation, you can configure registry credentials that are:
- **Stored as Kubernetes Secrets** in the tenant namespace
- **Automatically used by pods** for pulling images (imagePullSecrets)
- **Extracted by CI/CD** for docker push operations

**Zero registry credentials in GitHub!** Only the kubeconfig is needed.

### Supported Registries

- **GitHub Container Registry (ghcr.io)** - Free for public repos
- **Docker Hub (docker.io)** - Free tier available
- **Private registries** - Any Docker Registry v2 compatible

### Setup During Tenant Creation

When running `create-tenant.sh`, you'll be prompted for registry credentials:

```bash
./bin/create-tenant.sh mytenant

# Prompts:
# Registry server (e.g., ghcr.io, docker.io): ghcr.io
# Registry username: myusername
# Registry password: ****
```

This creates a `registry-credentials` secret in the tenant namespace.

### Using the Registry in CI/CD

**No separate registry secrets needed!** CI/CD extracts credentials from Kubernetes:

```yaml
# .github/workflows/deploy.yml
- name: Login to container registry
  run: |
    # Extract from Kubernetes secret
    DOCKER_CONFIG=$(kubectl get secret registry-credentials \
      -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
    mkdir -p ~/.docker
    echo "$DOCKER_CONFIG" > ~/.docker/config.json

- name: Build and push
  run: |
    docker build -t ghcr.io/myuser/myapp:latest .
    docker push ghcr.io/myuser/myapp:latest
```

See `examples/github-actions/deploy.yml` for complete examples.

### Using Images with imagePullSecrets

Reference the secret in your deployments:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp
spec:
  template:
    spec:
      imagePullSecrets:
        - name: registry-credentials
      containers:
        - name: myapp
          image: ghcr.io/myuser/myapp:latest
```

### Manual Registry Setup

If you skipped registry setup during tenant creation:

```bash
export KUBECONFIG=./mytenant-kubeconfig.yaml

kubectl create secret docker-registry registry-credentials \
  --docker-server=ghcr.io \
  --docker-username=myusername \
  --docker-password=mytoken
```

## DNS Provider Setup

**KWO supports multiple DNS providers simultaneously.** You can configure credentials for Cloudflare, OVH, Route53, and/or DigitalOcean either during installation or later using the `kwo-dns` command. Each provider gets its own certificate resolver.

### When to Configure

- **During installation:** The installer will prompt you to configure DNS providers (you can skip and configure later)
- **After installation:** Use `kwo-dns add <provider>` to add providers at any time

### Why Multiple Providers?

If you manage domains across different DNS providers (e.g., `example.com` on Cloudflare and `another.org` on OVH), you need credentials for both to issue certificates.

For multi-account scenarios (e.g., multiple OVH accounts), use the `--suffix` flag:
```bash
sudo kwo-dns add ovh --suffix=client-a
sudo kwo-dns add ovh --suffix=client-b
```

When creating an Ingress, choose the resolver matching your domain's DNS provider:
```yaml
# For Cloudflare domain
traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt-cloudflare

# For OVH domain with suffix
traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt-ovh-client-a
```

### Adding Providers

Use `kwo-dns add` to add a DNS provider:
```bash
# Interactive mode
sudo kwo-dns add cloudflare

# Non-interactive mode (from environment variables)
CF_DNS_API_TOKEN="xyz" sudo kwo-dns add cloudflare --non-interactive

# With suffix for multi-account
sudo kwo-dns add ovh --suffix=production
```

### Cloudflare

1. Go to [Cloudflare Dashboard](https://dash.cloudflare.com/profile/api-tokens)
2. Create API Token with:
   - **Permissions:** `Zone → DNS → Edit`
   - **Zone Resources:** Include → All zones (or specific zone)
3. Use the token during installation

### OVH

1. Create API credentials at [OVH API](https://eu.api.ovh.com/createToken/)
2. Required rights: `GET/POST/PUT/DELETE` on `/domain/zone/*`
3. You'll need:
   - Application Key
   - Application Secret
   - Consumer Key
   - Endpoint (e.g., `ovh-eu`)

### AWS Route53

1. Create IAM user with policy:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["route53:ListHostedZones", "route53:GetChange"],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "route53:ChangeResourceRecordSets",
      "Resource": "arn:aws:route53:::hostedzone/*"
    }
  ]
}
```
2. Create access key for the user
3. Use Access Key ID, Secret Access Key, and region during installation

### DigitalOcean

1. Go to [API Tokens](https://cloud.digitalocean.com/account/api/tokens)
2. Generate new token with **Write** scope
3. Use the token during installation

## Tenant Management

### Creating a Tenant

Tenants are isolated namespaces with dedicated RBAC permissions:

```bash
./bin/create-tenant.sh <tenant-name>
```

This creates:
- Namespace
- ServiceAccount with namespace-scoped permissions
- Kubeconfig file for CI/CD

### Tenant Permissions

Each tenant can:
- ✅ Deploy applications (Deployments, StatefulSets)
- ✅ Create Services and Ingresses
- ✅ Manage Secrets and ConfigMaps
- ✅ Create CronJobs and Jobs
- ✅ View logs

Each tenant **cannot**:
- ❌ Access other namespaces
- ❌ View or modify cluster-level resources
- ❌ See other tenants' workloads

### Using the Tenant Kubeconfig

```bash
# Local development
export KUBECONFIG=./mytenant-kubeconfig.yaml
kubectl get pods

# CI/CD (GitHub Actions, GitLab CI, etc.)
# Encode as base64:
cat mytenant-kubeconfig.yaml | base64 -w 0
# Add as secret: KUBECONFIG
```

## Deployment Example

The `examples/app.yaml` file includes:
- **Deployment** with health checks and resource limits
- **Service** for internal routing
- **Ingress** with automatic TLS via Let's Encrypt
- **CronJob** for scheduled tasks

```bash
# Edit app.yaml to set your domain and image
kubectl apply -f examples/app.yaml

# Check status
kubectl get pods,svc,ingress
```

Traefik automatically:
1. Requests Let's Encrypt certificate via DNS-01
2. Configures HTTPS
3. Redirects HTTP to HTTPS

### CI/CD Integration

See `examples/github-actions/deploy.yml` for complete workflows.

**Setup:**
1. Generate tenant kubeconfig
2. Encode as base64: `cat mytenant-kubeconfig.yaml | base64 -w 0`
3. Add as GitHub secret: `KUBECONFIG`
4. Create `.github/workflows/deploy.yml` in your repository
5. Push to trigger deployment

## Common Operations

### View configured certificate resolvers

```bash
# See which DNS providers are configured
kubectl get helmchartconfig traefik -n kube-system -o yaml | grep certificatesresolvers

# View all available resolvers
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik | grep -i "certificate resolvers"
```

### View all resources in your namespace

```bash
kubectl get all
```

### Check application logs

```bash
kubectl logs deployment/myapp
kubectl logs deployment/myapp --follow
kubectl logs deployment/myapp --tail=100
```

### Scale a deployment

```bash
kubectl scale deployment/myapp --replicas=5
```

### Update an image

```bash
kubectl set image deployment/myapp myapp=nginx:1.25
kubectl rollout status deployment/myapp
```

### Rollback a deployment

```bash
kubectl rollout undo deployment/myapp
```

### Create a secret

```bash
kubectl create secret generic db-credentials \
  --from-literal=username=admin \
  --from-literal=password=secret123
```

### Port forwarding for debugging

```bash
kubectl port-forward deployment/myapp 8080:80
# Access at http://localhost:8080
```

### Execute commands in a pod

```bash
kubectl exec -it deployment/myapp -- /bin/sh
```

### View certificate status

```bash
kubectl describe ingress myapp
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
```

## Troubleshooting

### TLS certificate not issuing

**Problem:** Ingress created but certificate not issued

**Diagnosis:**
```bash
# Check Traefik logs for ACME errors
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik

# Verify DNS credentials
kubectl get secret dns-credentials -n kube-system

# Check ingress annotations
kubectl describe ingress myapp
```

**Solutions:**
- Verify DNS credentials are correct
- Ensure domain points to your server's IP
- Check DNS provider API rate limits
- Verify ingress has `certresolver: letsencrypt` annotation

### Pods not starting

**Problem:** Pods stuck in `Pending` or `CrashLoopBackOff`

**Diagnosis:**
```bash
kubectl get pods
kubectl describe pod <pod-name>
kubectl logs <pod-name>
```

**Common causes:**
- Insufficient resources (check node capacity)
- Image pull errors (check image name and registry access)
- Application errors (check logs)
- Missing secrets or configmaps

### Cannot connect to cluster

**Problem:** `kubectl` commands fail with connection errors

**Diagnosis:**
```bash
# Verify k3s is running
sudo systemctl status k3s

# Check kubeconfig
echo $KUBECONFIG
cat $KUBECONFIG

# Test with admin kubeconfig
sudo kubectl get nodes
```

**Solutions:**
- Verify kubeconfig path is correct
- Ensure server IP/domain is reachable
- Check firewall rules (port 6443)

### Ingress not routing traffic

**Problem:** Domain resolves but returns 404

**Diagnosis:**
```bash
# Verify ingress exists
kubectl get ingress

# Check Traefik routes
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik

# Verify service exists
kubectl get svc
```

**Solutions:**
- Ensure service name in ingress matches actual service
- Verify service selector matches pod labels
- Check pod is running: `kubectl get pods`

## Upgrading

### KWO

The installation script is **idempotent** and can be run multiple times safely:

```bash
cd k3s-web-orchestrator
git pull origin main
sudo ./install.sh
```

The installer will:
- Skip k3s installation if already present
- Update changed scripts with confirmation prompts
- Preserve tenant data in `/var/lib/kwo/`
- Update command symlinks

**Note:** KWO is in active development. Breaking changes may occur between versions.

### k3s

```bash
# Check current version
k3s --version

# Upgrade (as root)
curl -sfL https://get.k3s.io | sh -
sudo systemctl restart k3s
```

### Traefik

Traefik is managed by k3s and updates with k3s upgrades. To customize:

```bash
kubectl edit helmchartconfig traefik -n kube-system
```

## Uninstall

To completely remove k3s:

```bash
# As root
/usr/local/bin/k3s-uninstall.sh
```

This removes:
- k3s binary and services
- All Kubernetes resources
- Container images
- Network configuration

## Security Considerations

- **Tenant isolation:** Tenants cannot access other namespaces (enforced by RBAC)
- **TLS certificates:** Automatically managed by Let's Encrypt
- **Secrets:** Store sensitive data in Kubernetes Secrets (base64 encoded, not encrypted at rest by default)
- **Network policies:** Not configured by default (add if needed)
- **API server:** Exposed on port 6443 (configure firewall as needed)

## File Structure

```
kwo/
├── install.sh                    # Installation script
├── CLAUDE.md                     # Project specification
├── README.md                     # This file
├── LICENSE                       # GPL-3.0
├── bin/
│   ├── create-tenant.sh          # Tenant management scripts
│   ├── delete-tenant.sh
│   ├── list-tenants.sh
│   ├── update-tenant.sh
│   ├── status.sh                 # Diagnostic scripts
│   ├── check-dns.sh
│   ├── check-tls.sh
│   ├── logs.sh
│   └── lib/
│       └── common.sh             # Shared functions
└── examples/
    ├── app.yaml                  # Complete app example
    └── github-actions/
        └── deploy.yml            # CI/CD workflows
```

**After Installation (System Directories):**
```
/usr/share/kwo/                   # Installed scripts
/var/lib/kwo/                     # Tenant data and kubeconfigs
/var/log/kwo/                     # Operation logs
/usr/local/bin/kwo-*              # Command symlinks
```

## Philosophy

> If Kubernetes already does it, we don't wrap it.

KWO is intentionally minimal. The Kubernetes API is the interface. We provide:
1. A script to install k3s with working TLS
2. Documentation for multi-tenancy
3. Examples you copy and adapt

Everything else is standard Kubernetes. Use `kubectl` directly, write YAML manifests, integrate with any CI/CD system that speaks Kubernetes.

## Contributing

Contributions are welcome! Please:
1. Keep the minimalist philosophy
2. Don't add abstraction layers
3. Update CLAUDE.md if changing architecture
4. Test on Debian/Ubuntu and Fedora

## License

GPL-3.0 - See LICENSE file

## Credits

Created with assistance from Claude Code.

## Support

- **Issues:** [GitHub Issues](https://github.com/marcochiodo/k3s-web-orchestrator/issues)
- **Documentation:** This README and example files
- **Kubernetes docs:** https://kubernetes.io/docs/
- **k3s docs:** https://docs.k3s.io/
- **Traefik docs:** https://doc.traefik.io/traefik/
