#!/usr/bin/env bash
set -euo pipefail

# Create an admin deployer with cluster-wide tenant permissions
# Usage: ./create-admin-deployer.sh <deployer-name>
#
# Admin deployers can deploy to ANY namespace but have the same limited
# permissions as regular tenants (no cluster-admin access).
# Perfect for development machines that need to deploy across multiple projects.

# Detect installation state
if [ -d "/usr/share/kwo/bin" ] && [ -f "/usr/share/kwo/VERSION" ]; then
    KWO_INSTALLED=true
    METADATA_DIR="/var/lib/kwo/metadata/admin-deployers"
    LOG_FILE="/var/log/kwo/tenant-operations.log"
else
    KWO_INSTALLED=false
    METADATA_DIR=""
    LOG_FILE=""
fi

DEPLOYER="${1:-}"

if [ -z "$DEPLOYER" ]; then
    echo "Usage: $0 <deployer-name>"
    echo ""
    echo "Example: $0 dev-machine"
    echo ""
    echo "Creates a ServiceAccount with tenant-level permissions across ALL namespaces."
    echo "Useful for developer workstations that need to deploy to multiple projects."
    exit 1
fi

# Validate deployer name (DNS-compatible)
if ! echo "$DEPLOYER" | grep -qE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; then
    echo "Error: Deployer name must be lowercase alphanumeric with hyphens"
    exit 1
fi

# Check root if installed system
if [ "$KWO_INSTALLED" = true ] && [ "$EUID" -ne 0 ]; then
    echo "Error: Must run as root (use sudo)"
    exit 4
fi

# Ensure metadata directory exists
if [ "$KWO_INSTALLED" = true ]; then
    mkdir -p "$METADATA_DIR"
    chmod 755 "$METADATA_DIR"
fi

# Set output path based on installation state
if [ "$KWO_INSTALLED" = true ]; then
    KUBECONFIG_OUTPUT="/var/lib/kwo/kubeconfigs/admin-deployer-${DEPLOYER}-kubeconfig.yaml"
else
    KUBECONFIG_OUTPUT="${KWO_OUTPUT_DIR:-.}/admin-deployer-${DEPLOYER}-kubeconfig.yaml"
fi

SA_NAME="admin-deployer-${DEPLOYER}"
NAMESPACE="kube-system"

echo "Creating admin deployer: $DEPLOYER"
echo ""
echo "⚠ This account will have tenant-level permissions across ALL namespaces"
echo ""

# Check if deployer already exists
if kubectl get serviceaccount "$SA_NAME" -n "$NAMESPACE" &>/dev/null; then
    echo "Error: Admin deployer '$DEPLOYER' already exists"
    echo "Use 'kwo-delete-admin-deployer $DEPLOYER' to remove it first"
    exit 2
fi

# 1. Create ServiceAccount in kube-system
echo "[1/4] Creating ServiceAccount in kube-system..."
kubectl -n "$NAMESPACE" create serviceaccount "$SA_NAME" --dry-run=client -o yaml | kubectl apply -f -

# 2. Create ClusterRole (same permissions as tenant, but cluster-wide)
echo "[2/4] Creating ClusterRole with tenant permissions..."
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: $SA_NAME
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

  # Namespace management
  - apiGroups: [""]
    resources:
      - namespaces
    verbs: ["get", "list", "watch", "create", "delete", "patch", "update"]
  
  # --- TRAEFIK CRDs (AGGIUNTO) ---
  - apiGroups: ["traefik.io"]
    resources:
      - middlewares
      - middlewaretcps
      - ingressroutes
      - traefikservices
      - tlsoptions
    verbs: ["*"]
EOF

# 3. Bind ClusterRole to ServiceAccount
echo "[3/4] Creating ClusterRoleBinding..."
kubectl create clusterrolebinding "${SA_NAME}-binding" \
  --clusterrole="$SA_NAME" \
  --serviceaccount="${NAMESPACE}:${SA_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 4. Generate kubeconfig
echo "[4/4] Generating kubeconfig..."

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
  namespace: $NAMESPACE
  annotations:
    kubernetes.io/service-account.name: $SA_NAME
type: kubernetes.io/service-account-token
EOF

# Wait for token to be populated
echo "Waiting for token generation..."
sleep 2

# Get the token
TOKEN=$(kubectl -n "$NAMESPACE" get secret "${SA_NAME}-token" -o jsonpath='{.data.token}' | base64 -d)

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
- name: admin-deployer-${DEPLOYER}@${CLUSTER_NAME}
  context:
    cluster: $CLUSTER_NAME
    user: $SA_NAME
current-context: admin-deployer-${DEPLOYER}@${CLUSTER_NAME}
users:
- name: $SA_NAME
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
if kubectl --kubeconfig="$KUBECONFIG_OUTPUT" get namespaces &> /dev/null; then
    echo "✓ Kubeconfig is valid"
else
    echo "⚠ Warning: Kubeconfig validation failed"
fi

# Create metadata file if installed
if [ "$KWO_INSTALLED" = true ]; then
    echo ""
    echo "Creating deployer metadata..."

    kwo_version=$(cat /usr/share/kwo/VERSION 2>/dev/null || echo "unknown")
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    created_by=$(whoami)

    cat > "$METADATA_DIR/${DEPLOYER}.json" <<METAEOF
{
  "name": "$DEPLOYER",
  "serviceAccount": "$SA_NAME",
  "namespace": "$NAMESPACE",
  "type": "admin-deployer",
  "createdAt": "$created_at",
  "createdBy": "$created_by",
  "kwoVersion": "$kwo_version",
  "kubeconfigPath": "$KUBECONFIG_OUTPUT",
  "apiServer": "$SERVER",
  "status": "active",
  "lastModified": "$created_at"
}
METAEOF

    chmod 644 "$METADATA_DIR/${DEPLOYER}.json"

    # Log to operations log
    echo "[$created_at] CREATE ADMIN-DEPLOYER deployer=$DEPLOYER user=$created_by version=$kwo_version" >> "$LOG_FILE"
fi

echo ""
echo "========================================="
echo "  Admin Deployer Created Successfully"
echo "========================================="
echo ""
echo "Deployer: $DEPLOYER"
echo "ServiceAccount: $SA_NAME"
echo "Namespace: $NAMESPACE (account location)"
echo "API Server: $SERVER"
echo "Kubeconfig (YAML): $KUBECONFIG_OUTPUT"
echo "Kubeconfig (JSON): $KUBECONFIG_JSON"
echo ""
echo "Next steps:"
echo ""
echo "1. Copy kubeconfig to your development machine:"
echo "   scp $KUBECONFIG_OUTPUT user@dev-machine:~/.kube/config"
echo ""
echo "2. Or use it locally:"
echo "   export KUBECONFIG=$KUBECONFIG_OUTPUT"
echo "   kubectl get namespaces"
echo ""
echo "3. Use compact JSON in CI/CD (e.g., GitHub Actions secrets):"
echo "   cat $KUBECONFIG_JSON"
echo ""
echo "4. Deploy to any namespace:"
echo "   kubectl apply -f app.yaml -n tenant-a"
echo "   kubectl apply -f app.yaml -n tenant-b"
echo ""
echo "Permissions granted:"
echo "  ✓ Deploy to ANY namespace"
echo "  ✓ Full control over pods, deployments, services (all namespaces)"
echo "  ✓ Create and manage secrets and configmaps"
echo "  ✓ Create ingresses (automatic TLS via Traefik)"
echo "  ✓ Create cronjobs and jobs"
echo "  ✓ List and view namespaces"
echo "  ✓ Create and delete namespaces"
echo "  ✓ Create Traefik Middlewares (redirects, auth, etc.)"
echo "  ✗ Cannot modify cluster-level resources (nodes, roles, etc.)"
echo "  ✗ NOT cluster-admin (safer than full access)"
echo ""