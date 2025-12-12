# K3S Web Orchestrator (KWO)

A minimal k3s setup for deploying web services with automated SSL certificates and multi-tenant isolation.

---

## Philosophy

### What KWO Provides

1. **install.sh** - One command to set up a production-ready k3s with:
   - Traefik configured for automatic Let's Encrypt via DNS-01
   - API endpoint exposed on a configurable domain
   - Ready for multi-tenant usage

2. **Tenant provisioning** - Script or documented procedure to create:
   - Isolated namespace
   - Scoped ServiceAccount + RBAC
   - Kubeconfig for CI/CD

3. **Examples** - Copy-paste ready YAML for common patterns

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
│   ├── status.sh                 # Diagnostics
│   ├── check-tls.sh
│   ├── logs.sh
│   └── lib/
│       ├── common.sh             # Shared library
│       └── dns-helpers.sh        # DNS management helpers
└── examples/
    ├── deployment.yaml           # Example: basic deployment
    ├── ingress-tls.yaml          # Example: ingress with auto-TLS
    ├── cronjob.yaml              # Example: scheduled job
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
│   ├── status.sh
│   ├── check-tls.sh
│   ├── logs.sh
│   └── lib/
│       ├── common.sh
│       └── dns-helpers.sh
└── VERSION                       # KWO version

/var/lib/kwo/                     # Persistent state
├── kubeconfigs/                  # Tenant kubeconfig files (700)
├── metadata/                     # Tenant metadata JSON (755)
├── archive/                      # Deleted tenant archives (700)
│   ├── tenant-*/                 # Archived tenant data
│   └── dns-*/                    # Archived DNS provider credentials
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
├── kwo-status -> /usr/share/kwo/bin/status.sh
├── kwo-check-tls -> /usr/share/kwo/bin/check-tls.sh
└── kwo-logs -> /usr/share/kwo/bin/logs.sh
```

---

## install.sh Responsibilities

1. Detect OS and install prerequisites
2. Install k3s
3. Configure Traefik with ACME (DNS-01 challenge)
4. Store DNS provider credentials as Kubernetes Secret
5. Output instructions for creating first tenant

**Configuration during install:**
- Let's Encrypt email
- DNS provider (Cloudflare/OVH/Route53/DigitalOcean)
- DNS provider credentials
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