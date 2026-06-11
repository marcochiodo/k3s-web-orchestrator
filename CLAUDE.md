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
│  │  Tenant = isolated namespace holding workloads.           │  │
│  │  User   = ServiceAccount (kube-system) bound to a         │  │
│  │           kwo-<role> ClusterRole, global or per-namespace,│  │
│  │           with a kubeconfig for external access (CI/CD).  │  │
│  │                                                           │  │
│  │  Users deploy standard Kubernetes resources:              │  │
│  │  Deployments, Services, Ingresses, CronJobs, Secrets      │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  API Server: https://api.example.com:6443                       │
│  (or direct IP - configured during install)                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## Access Model: Tenants, Users, Roles

KWO separates **workloads** from **access**:

- **Tenant** = an isolated namespace. Created by `kwo-create-tenant <name>`, which also provisions a namespace-scoped `deployer` ServiceAccount + Role + kubeconfig (single-namespace CI use).
- **User** = an access principal. A ServiceAccount in `kube-system`, created interactively by `kwo-create-user`, bound to a **role** with a **scope**, and handed a kubeconfig.
- **Role** = a `ClusterRole` named `kwo-<role>`, defined in `src/roles/*.yaml` and applied during install. Add a role by dropping a new `ClusterRole` YAML in `src/roles/` and re-running `install.sh`.

### Scope

`kwo-create-user` prompts for username, role, and namespaces:

- **Global** (namespaces left empty) → `ClusterRoleBinding` to `kwo-<role>`. The user reaches all namespaces and (with `deployer`) can create/delete namespaces.
- **Namespace-scoped** (comma-separated list) → one `RoleBinding` to `kwo-<role>` per namespace. The user is confined to those namespaces.

The `ClusterRole` is shared and never deleted on `kwo-delete-user`; only the bindings + ServiceAccount are removed (archived first).

### The `deployer` role (`src/roles/deployer.yaml` → `kwo-deployer`)

**CAN:**
- Manage pods, deployments, statefulsets, daemonsets, replicasets, services, endpoints
- Manage secrets, configmaps, PVCs, cronjobs/jobs, HPAs
- Create Ingresses + Traefik CRDs (middlewares, ingressroutes, traefikservices, tlsoptions) — Traefik handles TLS automatically
- Create/delete namespaces (effective only at global scope)

**CANNOT:**
- Touch cluster-level RBAC, nodes, or other cluster resources
- Reach namespaces outside its grant (namespace-scoped users)

> Legacy: `kwo-create-tenant`/`kwo-update-tenant` predate the role-based user model (they bake a `tenant-deployer` Role + `deployer` SA into one namespace). They still work, but for granting access to people or pipelines prefer `kwo-create-user`.

---

## Deployment Flow

```
Developer                         GitHub Actions                    k3s Cluster
    │                                   │                               │
    │  git push                         │                               │
    │ ─────────────────────────────────>│                               │
    │                                   │                               │
    │                                   │  kubectl apply -f k8s/        │
    │                                   │  (using tenant/user kubeconfig)│
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
│   ├── create-tenant.sh          # Tenant (namespace) management
│   ├── delete-tenant.sh
│   ├── list-tenants.sh
│   ├── update-tenant.sh
│   ├── create-user.sh            # User (access principal) management
│   ├── delete-user.sh
│   ├── list-users.sh
│   ├── dns.sh                    # DNS provider management
│   ├── registry.sh               # Private registry management
│   ├── update-k3s.sh             # k3s maintenance
│   ├── cleanup-k3s.sh
│   ├── status.sh                 # Diagnostics
│   ├── check-tls.sh
│   ├── logs.sh
│   └── lib/
│       ├── common.sh             # Shared library
│       ├── dns-helpers.sh        # DNS management helpers
│       └── registry-helpers.sh   # Registry management helpers
├── src/
│   └── roles/                    # ClusterRoles applied as kwo-<role>
│       └── deployer.yaml
└── examples/
    ├── app.yaml                  # Example: deployment + service + ingress + cronjob
    ├── registry-usage.yaml       # Example: using the private registry
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
│   ├── create-user.sh
│   ├── delete-user.sh
│   ├── list-users.sh
│   ├── dns.sh
│   ├── registry.sh
│   ├── update-k3s.sh
│   ├── cleanup-k3s.sh
│   ├── status.sh
│   ├── check-tls.sh
│   ├── logs.sh
│   └── lib/
│       ├── common.sh
│       ├── dns-helpers.sh
│       └── registry-helpers.sh
├── roles/                        # ClusterRole YAMLs (copied from src/roles/)
│   └── deployer.yaml
└── VERSION                       # KWO version

/var/lib/kwo/                     # Persistent state
├── kubeconfigs/                  # Tenant + user kubeconfig files (700)
├── metadata/                     # Tenant metadata JSON (755)
│   └── users/                    # User metadata JSON
├── archive/                      # Deleted resource archives (700)
│   ├── <tenant>-*/               # Archived tenant data
│   ├── user-*/                   # Archived user bindings/kubeconfig
│   ├── dns-*/                    # Archived DNS provider credentials
│   └── registry-*/               # Archived registry credentials
└── install.log                   # Installation history (640)

/var/log/kwo/                     # Operation logs
├── tenant-operations.log         # Tenant + user create/delete/update (640)
└── diagnostics.log               # Diagnostic command output (640)

/usr/local/bin/                   # Command symlinks
├── kwo-create-tenant -> /usr/share/kwo/bin/create-tenant.sh
├── kwo-delete-tenant -> /usr/share/kwo/bin/delete-tenant.sh
├── kwo-list-tenants -> /usr/share/kwo/bin/list-tenants.sh
├── kwo-update-tenant -> /usr/share/kwo/bin/update-tenant.sh
├── kwo-create-user -> /usr/share/kwo/bin/create-user.sh
├── kwo-delete-user -> /usr/share/kwo/bin/delete-user.sh
├── kwo-list-users -> /usr/share/kwo/bin/list-users.sh
├── kwo-dns -> /usr/share/kwo/bin/dns.sh
├── kwo-registry -> /usr/share/kwo/bin/registry.sh
├── kwo-update-k3s -> /usr/share/kwo/bin/update-k3s.sh
├── kwo-cleanup-k3s -> /usr/share/kwo/bin/cleanup-k3s.sh
├── kwo-status -> /usr/share/kwo/bin/status.sh
├── kwo-check-tls -> /usr/share/kwo/bin/check-tls.sh
└── kwo-logs -> /usr/share/kwo/bin/logs.sh
```

---

## install.sh Responsibilities

1. Detect OS and install prerequisites (including htpasswd for registry)
2. Install k3s
3. Configure DNS providers for Let's Encrypt (optional)
4. Configure private Docker registry (optional; HTTP-01 by default, no DNS needed)
5. Configure Traefik with ACME (always an HTTP-01 resolver + any DNS-01 resolvers)
6. Store DNS and registry credentials as Kubernetes Secrets
7. Apply ClusterRoles from `src/roles/` (e.g. `kwo-deployer`)
8. Install scripts + command symlinks
9. Output instructions for creating the first tenant/user

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
- Automatic TLS via Traefik — HTTP-01 (`letsencrypt`) by default, or DNS-01 if DNS providers are configured
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
1. DNS providers configured (optional — registry works without them via HTTP-01)
2. Registry prompt appears (optional, can skip)
3. Select domain (e.g., `registry.example.com`)
4. Select certificate resolver (default: HTTP-01 `letsencrypt`; DNS-01 resolvers offered if configured)
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
# Default: HTTP-01 resolver 'letsencrypt' (no DNS provider needed)
sudo NON_INTERACTIVE=true \
     REGISTRY_DOMAIN="registry.example.com" \
     REGISTRY_USERNAME="docker" \
     ./install.sh

# Use a DNS-01 resolver instead (requires a configured DNS provider):
sudo NON_INTERACTIVE=true \
     REGISTRY_DOMAIN="registry.example.com" \
     REGISTRY_USERNAME="docker" \
     REGISTRY_CERT_RESOLVER="letsencrypt-cloudflare" \
     ./install.sh

# Skip registry entirely:
sudo REGISTRY_SKIP="true" ./install.sh
```

`REGISTRY_CERT_RESOLVER` defaults to `letsencrypt` (HTTP-01) when unset.

---

## Tenant Manifest Guidelines

Regole da rispettare in tutti i manifest k8s deployati su questo cluster.

### ⚠️ CRITICO — Probe (liveness / readiness)

> **`initialDelaySeconds` minimo assoluto: 300s (5 minuti). MAI valori inferiori.**

**Perché è critico:** probe aggressive con `initialDelaySeconds` bassi (3-15s) causano un loop distruttivo:
1. Il kubelet killa il container prima che l'app finisca lo startup
2. Il container riparte → stesso crash → loop infinito
3. Ogni restart spika CPU (Node.js/Python che si riavviano da zero)
4. k3s e containerd impazziscono a gestire i crash → consumano CPU loro stessi
5. Il load average esplode: su una macchina a 4 CPU si è raggiunto **load 21**

**Incidente reale su questo cluster (maggio 2026):** deployment con probe a 3-5s hanno causato centinaia di restart su più namespace contemporaneamente (webio: 236 restart, shynet: 1237 restart, strapi: 310 restart) mandando il server in crash con load average 12-21 su 4 CPU. Il server è rimasto degradato per mesi prima che il problema venisse identificato.

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: http
  initialDelaySeconds: 300   # MINIMO ASSOLUTO — mai meno di 300s
  periodSeconds: 30
  failureThreshold: 3

readinessProbe:
  httpGet:
    path: /healthz
    port: http
  initialDelaySeconds: 300   # MINIMO ASSOLUTO — mai meno di 300s
  periodSeconds: 30
  failureThreshold: 3
```

Per app con startup molto lento (es. Strapi production build): usare `initialDelaySeconds: 600`.

### Altre convenzioni

- **imagePullPolicy**: sempre `Always` (tag mutabili)
- **Service**: sempre `ClusterIP`
- **Strategy**: `Recreate` per app con DB embedded (SQLite, DuckDB) — single-writer obbligatorio
- **StorageClass**: `local-path` (k3s default), `accessModes: ReadWriteOnce`
- **Probe httpGet su Django/framework web**: aggiungere `httpHeaders: [{name: Host, value: "<domain>"}]` per evitare che le probe arrivino con l'IP del pod (rifiutato da ALLOWED_HOSTS)
- **drop_caches**: non aggiungere mai script che eseguono `echo 1 > /proc/sys/vm/drop_caches` — svuotare la page cache manualmente peggiora le prestazioni, il kernel gestisce la memoria da solo

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

## Development Guidelines

### README.md Must Stay in Sync

Any change that affects user-facing behavior **must** include a corresponding README.md update in the same task:

- New command or script → add to Command Reference
- New feature or option → document in the relevant section
- Changed behavior or defaults → update existing documentation
- New requirement or prerequisite → update Prerequisites

This is not optional. README.md is the user's only reference and must reflect the current state of the codebase at all times.

---

## License

GPL-3.0

---

## Credits

Technical support from Claude Code