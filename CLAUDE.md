# K3S Web Orchestrator (KWO)

A minimal k3s setup for deploying web services with automated SSL certificates and multi-tenant isolation.

---

## Philosophy

### What KWO Provides

1. **install.sh** - One command to set up a production-ready k3s with:
   - Traefik configured for automatic Let's Encrypt via DNS-01
   - Private Docker registry with automatic TLS (optional)
   - API endpoint exposed on a configurable domain
   - Ready for multi-tenant usage

2. **Tenant provisioning** - Script or documented procedure to create:
   - Isolated namespace
   - Scoped ServiceAccount + RBAC
   - Kubeconfig for CI/CD

3. **Private registry** - Optional Docker registry with:
   - Automatic TLS certificates
   - htpasswd authentication
   - Global k3s integration (tenants can pull without imagePullSecrets)
   - Credential rotation

4. **Examples** - Copy-paste ready YAML for common patterns

### What KWO Does NOT Provide

- **No custom CLI tools** - Use `kubectl` directly
- **No abstraction layers** - Write standard Kubernetes YAML
- **No deployment wrappers** - `kubectl apply` is the deployment command
- **No monitoring stack** - Add it yourself if needed

### Core Principle

> If k3s/Kubernetes already does it, we don't wrap it.

The Kubernetes API is the interface. Tenants get a kubeconfig and use `kubectl` or any Kubernetes client library. GitHub Actions, GitLab CI, ArgoCD - they all speak Kubernetes natively.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         k3s Cluster                             │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Traefik (kube-system)                                    │  │
│  │  - Ports 80/443                                           │  │
│  │  - ACME/Lego for Let's Encrypt (DNS-01)                   │  │
│  │  - Wildcard or per-domain certificates                    │  │
│  └─────────────────────────┬─────────────────────────────────┘  │
│                            │                                    │
│  ┌─────────────────────────┴─────────────────────────────────┐  │
│  │  Tenant Namespaces                                        │  │
│  │                                                           │  │
│  │  Each tenant has:                                         │  │
│  │  - Dedicated namespace                                    │  │
│  │  - ServiceAccount with namespace-only permissions         │  │
│  │  - Kubeconfig for external access (CI/CD)                 │  │
│  │                                                           │  │
│  │  Tenants deploy standard Kubernetes resources:            │  │
│  │  Deployments, Services, Ingresses, CronJobs, Secrets      │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  API Server: https://api.example.com:6443                       │
│  (or direct IP - configured during install)                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Tenant Isolation (RBAC)

Each tenant gets a Role scoped to their namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-deployer
  namespace: {{ namespace }}
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io"]
    resources: 
      - deployments
      - services
      - secrets
      - configmaps
      - cronjobs
      - jobs
      - ingresses
      - pods
      - pods/log
    verbs: ["*"]
```

**What tenants CAN do:**
- Deploy applications
- Create Ingresses (Traefik handles TLS automatically)
- Manage secrets and configmaps
- Create CronJobs
- View logs

**What tenants CANNOT do:**
- Access other namespaces
- Modify cluster-level resources
- See other tenants' workloads

---

## Deployment Flow

```
Developer                         GitHub Actions                    k3s Cluster
    │                                   │                               │
    │  git push                         │                               │
    │ ─────────────────────────────────>│                               │
    │                                   │                               │
    │                                   │  kubectl apply -f k8s/        │
    │                                   │  (using tenant kubeconfig)    │
    │                                   │ ─────────────────────────────>│
    │                                   │                               │
    │                                   │        Applied                │
    │                                   │<───────────────────────────── │
    │                                   │                               │
```

No SSH. No custom APIs. Just Kubernetes.

---

## File Structure

```
kwo/
├── install.sh                    # Installation script
├── CLAUDE.md                     # This file
├── README.md                     # User documentation
├── LICENSE
├── bin/                          # Scripts installed to /usr/share/kwo/bin/
│   ├── create-tenant.sh          # Tenant management
│   ├── delete-tenant.sh
│   ├── list-tenants.sh
│   ├── update-tenant.sh
│   ├── dns.sh                    # DNS provider management
│   ├── registry.sh               # Registry management
│   ├── status.sh                 # Diagnostics
│   ├── check-tls.sh
│   ├── logs.sh
│   └── lib/
│       ├── common.sh             # Shared library
│       ├── dns-helpers.sh        # DNS management helpers
│       └── registry-helpers.sh   # Registry management helpers
└── examples/
    ├── deployment.yaml           # Example: basic deployment
    ├── ingress-tls.yaml          # Example: ingress with auto-TLS
    ├── cronjob.yaml              # Example: scheduled job
    ├── registry-usage.yaml       # Example: using private registry
    └── github-actions/
        └── deploy.yml            # Example: CI/CD workflow
```

**Installed System Structure (FHS Compliant):**
```
/usr/share/kwo/                   # Architecture-independent data
├── bin/                          # Source scripts (644)
│   ├── create-tenant.sh
│   ├── delete-tenant.sh
│   ├── list-tenants.sh
│   ├── update-tenant.sh
│   ├── dns.sh
│   ├── registry.sh
│   ├── status.sh
│   ├── check-tls.sh
│   ├── logs.sh
│   └── lib/
│       ├── common.sh
│       ├── dns-helpers.sh
│       └── registry-helpers.sh
└── VERSION                       # KWO version

/var/lib/kwo/                     # Persistent state
├── kubeconfigs/                  # Tenant kubeconfig files (700)
├── metadata/                     # Tenant metadata JSON (755)
├── archive/                      # Deleted tenant archives (700)
│   ├── tenant-*/                 # Archived tenant data
│   ├── dns-*/                    # Archived DNS provider credentials
│   └── registry-*/               # Archived registry credentials
└── install.log                   # Installation history (640)

/var/log/kwo/                     # Operation logs
├── tenant-operations.log         # Create/delete/update (640)
└── diagnostics.log               # Diagnostic command output (640)

/usr/local/bin/                   # Command symlinks
├── kwo-create-tenant -> /usr/share/kwo/bin/create-tenant.sh
├── kwo-delete-tenant -> /usr/share/kwo/bin/delete-tenant.sh
├── kwo-list-tenants -> /usr/share/kwo/bin/list-tenants.sh
├── kwo-update-tenant -> /usr/share/kwo/bin/update-tenant.sh
├── kwo-dns -> /usr/share/kwo/bin/dns.sh
├── kwo-registry -> /usr/share/kwo/bin/registry.sh
├── kwo-status -> /usr/share/kwo/bin/status.sh
├── kwo-check-tls -> /usr/share/kwo/bin/check-tls.sh
└── kwo-logs -> /usr/share/kwo/bin/logs.sh
```

---

## install.sh Responsibilities

1. Detect OS and install prerequisites (including htpasswd for registry)
2. Install k3s
3. Configure DNS providers for Let's Encrypt (optional)
4. Configure private Docker registry (optional)
5. Configure Traefik with ACME (DNS-01 challenge)
6. Store DNS and registry credentials as Kubernetes Secrets
7. Output instructions for creating first tenant

**Configuration during install:**
- Let's Encrypt email
- DNS provider (Cloudflare/OVH/Route53/DigitalOcean) - optional
- DNS provider credentials
- Registry domain and username - optional
- API endpoint domain (optional, can use IP)

---

## DNS Provider Management

**Configuration Options:**
- **During installation:** Optional prompt (can skip and configure later)
- **After installation:** Runtime management via `kwo-dns` command

**Supported Providers:**
1. Cloudflare (most common)
2. OVH
3. Route53
4. DigitalOcean

**Features:**
- Add/remove/update DNS providers at runtime
- Multiple providers simultaneously (e.g., Cloudflare + OVH)
- Multi-account support via suffixes (e.g., `letsencrypt-ovh-client-a`)
- ConfigMap-based metadata tracking
- Automatic Traefik configuration regeneration
- Credential validation and archival

**Storage:**
- Credentials: Kubernetes Secret `dns-credentials` (namespace: kube-system)
- Metadata: ConfigMap `kwo-dns-providers` (namespace: kube-system)
- Archive: `/var/lib/kwo/archive/dns-*` on delete/update

**Commands:**
```bash
kwo-dns add <provider> [--suffix=<name>] [--non-interactive]
kwo-dns remove <resolver-name> [--force]
kwo-dns list [--format=table|json]
kwo-dns update <resolver-name> [--non-interactive]
kwo-dns check [resolver-name]
```

---

## Private Docker Registry

**Configuration Options:**
- **During installation:** Optional prompt after DNS configuration
- **After installation:** Re-run `./install.sh` to configure or update

**Features:**
- Automatic TLS via Traefik (Let's Encrypt DNS-01)
- htpasswd authentication with bcrypt
- Global k3s integration (`/etc/rancher/k3s/registries.yaml`)
- All tenants can pull images automatically (no imagePullSecrets needed)
- Credential rotation
- 50Gi persistent storage (default)

**Architecture:**
```
External (docker push/pull)
    ↓ HTTPS (port 443, TLS via Traefik)
Traefik Ingress (kube-system)
    ↓ HTTP (internal)
Service: registry:5000 (ClusterIP)
    ↓
Deployment: registry:2 (kube-system)
    ↓
PVC: registry-storage (50Gi)
```

**Storage:**
- Images: PersistentVolumeClaim `registry-storage` (kube-system, 50Gi)
- Credentials: Secret `registry-auth` (kube-system)
  - htpasswd file (bcrypt hash)
  - plaintext username and password (for k3s registries.yaml)
- Configuration: ConfigMap `kwo-config` (kube-system)
  - registry-enabled, registry-domain, registry-username, registry-certresolver
- k3s config: `/etc/rancher/k3s/registries.yaml` (chmod 600)
- Archive: `/var/lib/kwo/archive/registry-*` on credential rotation

**Commands:**
```bash
kwo-registry status              # Show registry status and test endpoint
kwo-registry get-credentials     # Display current credentials
kwo-registry rotate-credentials  # Generate new password, update all configs
```

**Usage:**

1. **Push images from external machine:**
```bash
# Login (prompted for password)
docker login registry.example.com

# Tag and push
docker tag myapp:latest registry.example.com/myapp:latest
docker push registry.example.com/myapp:latest
```

2. **Deploy in tenant (automatic pull):**
```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      # NO imagePullSecrets needed!
      containers:
        - image: registry.example.com/myapp:latest
```

3. **Credential rotation:**
```bash
# Rotates password, updates Secret, registries.yaml, restarts k3s
sudo kwo-registry rotate-credentials
```

**Security:**
- TLS-only access (Traefik auto-redirects HTTP→HTTPS)
- bcrypt password hashing (htpasswd -B)
- 32-character random passwords
- Global k3s authentication (all tenants can pull)
- Push access only via direct credentials (tenants cannot push)
- Archived credentials (chmod 600) before rotation

**Installation Flow:**

During `./install.sh`:
1. DNS providers configured first (required for TLS)
2. Registry prompt appears (optional, can skip)
3. Select domain (e.g., `registry.example.com`)
4. Select DNS provider for certificate resolver
5. Choose username (default: `docker`)
6. Auto-generate random password
7. Deploy registry (PVC, Deployment, Service, Ingress)
8. Write `/etc/rancher/k3s/registries.yaml`
9. Restart k3s
10. Display credentials to user

Re-running `./install.sh`:
- Detects existing credentials
- Prompts: "Regenerate password? [y/N]"
- If yes: archives old, generates new, updates all configs
- If no: reuses existing credentials

**Non-Interactive Mode:**
```bash
sudo NON_INTERACTIVE=true \
     REGISTRY_DOMAIN="registry.example.com" \
     REGISTRY_USERNAME="docker" \
     REGISTRY_CERT_RESOLVER="letsencrypt-cloudflare" \
     ./install.sh

# Skip registry entirely:
sudo REGISTRY_SKIP="true" ./install.sh
```

---

## Non-Goals

- Abstraction over Kubernetes resources (tenants use standard kubectl/YAML)
- Custom deployment wrappers (use kubectl apply directly)
- Built-in monitoring/logging (add your own stack)
- Multi-node cluster support (use managed Kubernetes for HA)
- Helm chart management (k3s manages Traefik HelmChart)

---

## Target Environment

- **OS**: Debian 12+, Ubuntu 22.04+, Fedora 39+
- **k3s**: Latest stable
- **Single node only** - for HA, use managed Kubernetes

---

## License

GPL-3.0

---

## Credits

Technical support from Claude Code