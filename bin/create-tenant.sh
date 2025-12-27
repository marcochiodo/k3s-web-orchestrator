#!/usr/bin/env bash
set -euo pipefail

# Example: Create a tenant namespace with isolated RBAC
# Usage: ./create-tenant.sh <tenant-name>
#
# This script demonstrates how to set up multi-tenant isolation in k3s.
# Each tenant gets:
# - Dedicated namespace
# - ServiceAccount with namespace-only permissions
# - Kubeconfig for CI/CD integration

# Detect installation state
if [ -d "/usr/share/kwo/bin" ] && [ -f "/usr/share/kwo/VERSION" ]; then
    KWO_INSTALLED=true
    METADATA_DIR="/var/lib/kwo/metadata"
    LOG_FILE="/var/log/kwo/tenant-operations.log"
else
    KWO_INSTALLED=false
    METADATA_DIR=""
    LOG_FILE=""
fi

TENANT="${1:-}"

if [ -z "$TENANT" ]; then
    echo "Usage: $0 <tenant-name>"
    echo ""
    echo "Example: $0 acme-corp"
    exit 1
fi

# Validate tenant name (DNS-compatible)
if ! echo "$TENANT" | grep -qE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
    echo "Error: Tenant name must be lowercase alphanumeric with hyphens"
    exit 1
fi

# Check root if installed system
if [ "$KWO_INSTALLED" = true ] && [ "$EUID" -ne 0 ]; then
    echo "Error: Must run as root (use sudo)"
    exit 4
fi

# Set output path based on installation state
if [ "$KWO_INSTALLED" = true ]; then
    KUBECONFIG_OUTPUT="/var/lib/kwo/kubeconfigs/${TENANT}-kubeconfig.yaml"
else
    KUBECONFIG_OUTPUT="${KWO_OUTPUT_DIR:-.}/${TENANT}-kubeconfig.yaml"
fi
SA_NAME="deployer"

echo "Creating tenant: $TENANT"
echo ""

# Check if tenant already exists
if kubectl get namespace "$TENANT" &>/dev/null; then
    echo "Error: Tenant '$TENANT' already exists"
    echo "Use 'kwo-delete-tenant $TENANT' to remove it first"
    exit 2
fi

# 1. Create namespace
echo "[1/5] Creating namespace..."
kubectl create namespace "$TENANT" --dry-run=client -o yaml | kubectl apply -f -

# 2. Create ServiceAccount
echo "[2/5] Creating ServiceAccount..."
kubectl -n "$TENANT" create serviceaccount "$SA_NAME" --dry-run=client -o yaml | kubectl apply -f -

# 3. Create Role (namespace-scoped permissions)
echo "[3/5] Creating Role with namespace-scoped permissions..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: tenant-deployer
  namespace: $TENANT
rules:
  # Core resources
  - apiGroups: [""]
    resources:
      - pods
      - pods/log
      - pods/portforward
      - services
      - endpoints
      - secrets
      - configmaps
      - persistentvolumeclaims
    verbs: ["*"]

  # Apps
  - apiGroups: ["apps"]
    resources:
      - deployments
      - statefulsets
      - daemonsets
      - replicasets
    verbs: ["*"]

  # Batch jobs
  - apiGroups: ["batch"]
    resources:
      - jobs
      - cronjobs
    verbs: ["*"]

  # Networking
  - apiGroups: ["networking.k8s.io"]
    resources:
      - ingresses
      - networkpolicies
    verbs: ["*"]

  # Autoscaling
  - apiGroups: ["autoscaling"]
    resources:
      - horizontalpodautoscalers
    verbs: ["*"]
EOF

# 4. Bind Role to ServiceAccount
echo "[4/5] Creating RoleBinding..."
kubectl -n "$TENANT" create rolebinding "${SA_NAME}-binding" \
  --role=tenant-deployer \
  --serviceaccount="${TENANT}:${SA_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 5. Generate kubeconfig
echo "[5/5] Generating kubeconfig..."

# Get cluster information
CLUSTER_NAME="k3s-web-orchestrator"

# Try to get API server from cluster configuration (saved by install.sh)
SERVER=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-server}' 2>/dev/null)

# Fallback to local kubeconfig if not available
if [ -z "$SERVER" ]; then
    echo "⚠ Warning: Could not read cluster configuration, using local server address"
    echo "  This kubeconfig may not work from external hosts"
    SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
fi

CA_DATA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

# Create a long-lived token (Kubernetes 1.24+)
cat <<EOF | kubectl apply -f - > /dev/null
apiVersion: v1
kind: Secret
metadata:
  name: ${SA_NAME}-token
  namespace: $TENANT
  annotations:
    kubernetes.io/service-account.name: $SA_NAME
type: kubernetes.io/service-account-token
EOF

# Wait for token to be populated
echo "Waiting for token generation..."
sleep 2

# Get the token
TOKEN=$(kubectl -n "$TENANT" get secret "${SA_NAME}-token" -o jsonpath='{.data.token}' | base64 -d)

if [ -z "$TOKEN" ]; then
    echo "Error: Failed to retrieve token"
    exit 1
fi

# Generate kubeconfig file
cat > "$KUBECONFIG_OUTPUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: $CLUSTER_NAME
  cluster:
    certificate-authority-data: $CA_DATA
    server: $SERVER
contexts:
- name: ${TENANT}@${CLUSTER_NAME}
  context:
    cluster: $CLUSTER_NAME
    namespace: $TENANT
    user: ${TENANT}-${SA_NAME}
current-context: ${TENANT}@${CLUSTER_NAME}
users:
- name: ${TENANT}-${SA_NAME}
  user:
    token: $TOKEN
EOF

chmod 600 "$KUBECONFIG_OUTPUT"

# Generate JSON version (compact, no newlines)
echo "Generating compact JSON version..."
KUBECONFIG_JSON="${KUBECONFIG_OUTPUT%.yaml}.json"
kubectl config view --kubeconfig="$KUBECONFIG_OUTPUT" --minify --raw -o json | jq -c '.' > "$KUBECONFIG_JSON"
chmod 600 "$KUBECONFIG_JSON"

# Test the kubeconfig
echo ""
echo "Testing kubeconfig..."
if kubectl --kubeconfig="$KUBECONFIG_OUTPUT" get pods &> /dev/null; then
    echo "✓ Kubeconfig is valid"
else
    echo "⚠ Warning: Kubeconfig validation failed (namespace may be empty)"
fi

# Create metadata file if installed
if [ "$KWO_INSTALLED" = true ]; then
    echo ""
    echo "Creating tenant metadata..."

    kwo_version=$(cat /usr/share/kwo/VERSION 2>/dev/null || echo "unknown")
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    created_by=$(whoami)

    cat > "$METADATA_DIR/${TENANT}.json" <<METAEOF
{
  "name": "$TENANT",
  "namespace": "$TENANT",
  "serviceAccount": "$SA_NAME",
  "createdAt": "$created_at",
  "createdBy": "$created_by",
  "kwoVersion": "$kwo_version",
  "kubeconfigPath": "$KUBECONFIG_OUTPUT",
  "apiServer": "$SERVER",
  "status": "active",
  "lastModified": "$created_at"
}
METAEOF

    chmod 644 "$METADATA_DIR/${TENANT}.json"

    # Log to operations log
    echo "[$created_at] CREATE tenant=$TENANT user=$created_by version=$kwo_version" >> "$LOG_FILE"
fi

echo ""
echo "========================================="
echo "  Tenant Created Successfully"
echo "========================================="
echo ""
echo "Tenant: $TENANT"
echo "Namespace: $TENANT"
echo "ServiceAccount: $SA_NAME"
echo "API Server: $SERVER"
echo "Kubeconfig (YAML): $KUBECONFIG_OUTPUT"
echo "Kubeconfig (JSON): $KUBECONFIG_JSON"
echo ""
echo "Next steps:"
echo ""
echo "1. Test the kubeconfig:"
echo "   export KUBECONFIG=$KUBECONFIG_OUTPUT"
echo "   kubectl get pods"
echo ""
echo "2. Use in CI/CD (GitHub Actions):"
echo "   # Option A: Use compact JSON directly"
echo "   cat $KUBECONFIG_JSON"
echo "   # Add the output as a secret: KUBECONFIG"
echo ""
echo "   # Option B: Use YAML with base64 encoding"
echo "   cat $KUBECONFIG_OUTPUT | base64 -w 0"
echo ""
echo "3. Deploy an application:"
echo "   # Edit examples/app.yaml to configure registry credentials (if needed)"
echo "   kubectl apply -f examples/app.yaml"
echo ""
echo "Permissions granted to this tenant:"
echo "  ✓ Full control over pods, deployments, services"
echo "  ✓ Create and manage secrets and configmaps"
echo "  ✓ Create ingresses (automatic TLS via Traefik)"
echo "  ✓ Create cronjobs and jobs"
echo "  ✗ Cannot access other namespaces"
echo "  ✗ Cannot modify cluster-level resources"
echo ""
