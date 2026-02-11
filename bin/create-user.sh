#!/usr/bin/env bash
set -euo pipefail

# Create a user with role-based permissions
# Usage: ./create-user.sh (interactive, no parameters)

# Detect installation state
if [ -d "/usr/share/kwo/bin" ] && [ -f "/usr/share/kwo/VERSION" ]; then
    KWO_INSTALLED=true
    source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true
    METADATA_DIR="/var/lib/kwo/metadata/users"
    LOG_FILE="/var/log/kwo/tenant-operations.log"
    ROLES_DIR="/usr/share/kwo/roles"
else
    KWO_INSTALLED=false
    METADATA_DIR=""
    LOG_FILE=""
    ROLES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../src/roles" && pwd)"
fi

# Check root if installed system
if [ "$KWO_INSTALLED" = true ] && [ "$EUID" -ne 0 ]; then
    echo "Error: Must run as root (use sudo)"
    exit 4
fi

echo "=== KWO User Creation ==="
echo ""

# 1. CHIEDE NOME UTENTE
read -p "Enter username: " USERNAME
while [ -z "$USERNAME" ] || ! echo "$USERNAME" | grep -qE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'; do
    echo "Error: Username must be lowercase alphanumeric with hyphens"
    read -p "Enter username: " USERNAME
done

# Verifica utente non esista già
if [ "$KWO_INSTALLED" = true ] && [ -f "$METADATA_DIR/${USERNAME}.json" ]; then
    echo "Error: User '$USERNAME' already exists"
    exit 2
fi

# 2. CHIEDE TIPO DI RUOLO (lista dinamica da src/roles/)
echo ""
echo "Available roles:"
declare -A role_map
role_num=1

if [ ! -d "$ROLES_DIR" ]; then
    echo "Error: Roles directory not found at $ROLES_DIR"
    exit 3
fi

for role_file in "$ROLES_DIR"/*.yaml; do
    [ -f "$role_file" ] || continue
    role_name=$(basename "$role_file" .yaml)
    echo "  $role_num) $role_name"
    role_map[$role_num]="$role_name"
    role_num=$((role_num + 1))
done

if [ ${#role_map[@]} -eq 0 ]; then
    echo "Error: No roles found in $ROLES_DIR"
    exit 3
fi

read -p "Select role [1-$((role_num-1))]: " role_choice
while [ -z "${role_map[$role_choice]:-}" ]; do
    echo "Error: Invalid choice"
    read -p "Select role [1-$((role_num-1))]: " role_choice
done

ROLE_TYPE="${role_map[$role_choice]}"
echo "Selected role: $ROLE_TYPE"

# Verifica che il ClusterRole esista
if ! kubectl get clusterrole "kwo-${ROLE_TYPE}" &>/dev/null; then
    echo "Error: ClusterRole 'kwo-${ROLE_TYPE}' not found"
    echo "Run 'sudo ./install.sh' to apply cluster roles"
    exit 3
fi

# 3. LISTA NAMESPACE E CHIEDE LIMITAZIONE
echo ""
echo "Available namespaces:"
kubectl get namespaces -o custom-columns=NAME:.metadata.name --no-headers | grep -v '^kube-'
echo ""
echo "Enter namespaces to grant access (comma-separated)"
echo "Leave EMPTY for GLOBAL access (all namespaces)"
read -p "Namespaces [global]: " NAMESPACES

# Valida namespace se specificati
if [ -n "$NAMESPACES" ]; then
    for ns in ${NAMESPACES//,/ }; do
        if ! kubectl get namespace "$ns" &>/dev/null; then
            echo "Error: Namespace '$ns' does not exist"
            exit 3
        fi
    done
    SCOPE="namespace-scoped"
    echo "Scope: limited to $NAMESPACES"
else
    SCOPE="cluster-wide"
    echo "Scope: global (all namespaces)"
fi

# Set output path based on installation state
if [ "$KWO_INSTALLED" = true ]; then
    KUBECONFIG_OUTPUT="/var/lib/kwo/kubeconfigs/user-${USERNAME}-kubeconfig.yaml"
else
    KUBECONFIG_OUTPUT="${KWO_OUTPUT_DIR:-.}/user-${USERNAME}-kubeconfig.yaml"
fi

SA_NAME="user-${USERNAME}"
NAMESPACE="kube-system"

echo ""
echo "Creating user: $USERNAME"
echo "  Role: $ROLE_TYPE"
echo "  Scope: $SCOPE"
if [ -n "$NAMESPACES" ]; then
    echo "  Namespaces: $NAMESPACES"
fi
echo ""

# 4. CREA SERVICEACCOUNT
echo "[1/4] Creating ServiceAccount..."
kubectl -n "$NAMESPACE" create serviceaccount "$SA_NAME" --dry-run=client -o yaml | kubectl apply -f -

# 5. CREA BINDING
if [ -z "$NAMESPACES" ]; then
    # GLOBALE → ClusterRoleBinding
    echo "[2/4] Creating ClusterRoleBinding (global access)..."
    kubectl create clusterrolebinding "${SA_NAME}-binding" \
        --clusterrole="kwo-${ROLE_TYPE}" \
        --serviceaccount="${NAMESPACE}:${SA_NAME}" \
        --dry-run=client -o yaml | kubectl apply -f -
else
    # LIMITATO → RoleBinding per ogni namespace
    echo "[2/4] Creating RoleBindings for: $NAMESPACES"
    for ns in ${NAMESPACES//,/ }; do
        kubectl create rolebinding "${SA_NAME}-binding" \
            --clusterrole="kwo-${ROLE_TYPE}" \
            --serviceaccount="${NAMESPACE}:${SA_NAME}" \
            --namespace="$ns" \
            --dry-run=client -o yaml | kubectl apply -f -
    done
fi

# 6. GENERA TOKEN E KUBECONFIG
echo "[3/4] Generating kubeconfig..."

# Get cluster information
CLUSTER_NAME="k3s-web-orchestrator"

# Try to get API server from cluster configuration
SERVER=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-server}' 2>/dev/null)

# Fallback to local kubeconfig if not available
if [ -z "$SERVER" ]; then
    echo "⚠ Warning: Could not read cluster configuration, using local server address"
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

# Set default namespace for context (first namespace if limited, none if global)
DEFAULT_NS=""
if [ -n "$NAMESPACES" ]; then
    DEFAULT_NS=$(echo "$NAMESPACES" | cut -d',' -f1)
fi

# Generate kubeconfig file
if [ -n "$DEFAULT_NS" ]; then
    cat > "$KUBECONFIG_OUTPUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: $CLUSTER_NAME
  cluster:
    certificate-authority-data: $CA_DATA
    server: $SERVER
contexts:
- name: ${USERNAME}@${CLUSTER_NAME}
  context:
    cluster: $CLUSTER_NAME
    user: $SA_NAME
    namespace: $DEFAULT_NS
current-context: ${USERNAME}@${CLUSTER_NAME}
users:
- name: $SA_NAME
  user:
    token: $TOKEN
EOF
else
    cat > "$KUBECONFIG_OUTPUT" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: $CLUSTER_NAME
  cluster:
    certificate-authority-data: $CA_DATA
    server: $SERVER
contexts:
- name: ${USERNAME}@${CLUSTER_NAME}
  context:
    cluster: $CLUSTER_NAME
    user: $SA_NAME
current-context: ${USERNAME}@${CLUSTER_NAME}
users:
- name: $SA_NAME
  user:
    token: $TOKEN
EOF
fi

chmod 600 "$KUBECONFIG_OUTPUT"

# Generate JSON version (compact, no newlines)
echo "Generating compact JSON version..."
KUBECONFIG_JSON="${KUBECONFIG_OUTPUT%.yaml}.json"
kubectl config view --kubeconfig="$KUBECONFIG_OUTPUT" --minify --raw -o json | jq -c '.' > "$KUBECONFIG_JSON"
chmod 600 "$KUBECONFIG_JSON"

# Test the kubeconfig
echo ""
echo "Testing kubeconfig..."
if [ -z "$NAMESPACES" ]; then
    if kubectl --kubeconfig="$KUBECONFIG_OUTPUT" get namespaces &> /dev/null; then
        echo "✓ Kubeconfig is valid (global access)"
    else
        echo "⚠ Warning: Kubeconfig validation failed"
    fi
else
    first_ns=$(echo "$NAMESPACES" | cut -d',' -f1)
    if kubectl --kubeconfig="$KUBECONFIG_OUTPUT" get pods -n "$first_ns" &> /dev/null; then
        echo "✓ Kubeconfig is valid (namespace access)"
    else
        echo "⚠ Warning: Kubeconfig validation failed"
    fi
fi

# 7. SALVA METADATA
if [ "$KWO_INSTALLED" = true ]; then
    echo "[4/4] Saving metadata..."
    
    kwo_version=$(cat /usr/share/kwo/VERSION 2>/dev/null || echo "unknown")
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    created_by=$(whoami)
    
    # Build namespaces JSON array
    namespaces_json="[]"
    if [ -n "$NAMESPACES" ]; then
        namespaces_json="[\"$(echo "$NAMESPACES" | sed 's/,/","/g')\"]"
    fi
    
    cat > "$METADATA_DIR/${USERNAME}.json" <<METAEOF
{
  "name": "$USERNAME",
  "serviceAccount": "$SA_NAME",
  "namespace": "$NAMESPACE",
  "roleType": "$ROLE_TYPE",
  "scope": "$SCOPE",
  "namespaces": $namespaces_json,
  "createdAt": "$created_at",
  "createdBy": "$created_by",
  "kwoVersion": "$kwo_version",
  "kubeconfigPath": "$KUBECONFIG_OUTPUT",
  "apiServer": "$SERVER",
  "status": "active",
  "lastModified": "$created_at"
}
METAEOF
    
    chmod 644 "$METADATA_DIR/${USERNAME}.json"
    
    # Log to operations log
    echo "[$created_at] CREATE USER user=$USERNAME role=$ROLE_TYPE scope=$SCOPE namespaces=$NAMESPACES created_by=$created_by version=$kwo_version" >> "$LOG_FILE"
fi

echo ""
echo "========================================="
echo "  User Created Successfully"
echo "========================================="
echo ""
echo "User: $USERNAME"
echo "Role: $ROLE_TYPE"
echo "Scope: $SCOPE"
if [ -n "$NAMESPACES" ]; then
    echo "Namespaces: $NAMESPACES"
else
    echo "Namespaces: all (global access)"
fi
echo "ServiceAccount: $SA_NAME"
echo "API Server: $SERVER"
echo "Kubeconfig (YAML): $KUBECONFIG_OUTPUT"
echo "Kubeconfig (JSON): $KUBECONFIG_JSON"
echo ""
echo "Next steps:"
echo ""
echo "1. Copy kubeconfig to your workstation:"
echo "   scp $KUBECONFIG_OUTPUT user@workstation:~/.kube/config"
echo ""
echo "2. Or test it locally:"
echo "   export KUBECONFIG=$KUBECONFIG_OUTPUT"
if [ -z "$NAMESPACES" ]; then
    echo "   kubectl get pods --all-namespaces"
else
    echo "   kubectl get pods -n $(echo "$NAMESPACES" | cut -d',' -f1)"
fi
echo ""
echo "3. Use compact JSON in CI/CD:"
echo "   cat $KUBECONFIG_JSON"
echo ""
