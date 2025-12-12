#!/usr/bin/env bash
set -euo pipefail

source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true

TENANT="${1:-}"
ROTATE_TOKEN=false

for arg in "$@"; do
    [ "$arg" = "--rotate-token" ] && ROTATE_TOKEN=true
done

require_root
[ -z "$TENANT" ] && { echo "Usage: $0 <tenant-name> --rotate-token"; exit 1; }
[ "$ROTATE_TOKEN" = false ] && { log_error "Must specify --rotate-token"; exit 1; }

kubectl get namespace "$TENANT" &>/dev/null || { log_error "Tenant not found"; exit 2; }

# Archive old kubeconfig
timestamp=$(date +"%Y%m%d-%H%M%S")
archive_dir="/var/lib/kwo/archive/${TENANT}-token-rotation-${timestamp}"
mkdir -p "$archive_dir"
cp "/var/lib/kwo/kubeconfigs/${TENANT}-kubeconfig.yaml" "$archive_dir/" 2>/dev/null || true

# Rotate token
kubectl delete secret -n "$TENANT" deployer-token --ignore-not-found=true
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: deployer-token
  namespace: $TENANT
  annotations:
    kubernetes.io/service-account.name: deployer
type: kubernetes.io/service-account-token
EOF

sleep 2
TOKEN=$(kubectl -n "$TENANT" get secret deployer-token -o jsonpath='{.data.token}' | base64 -d)
[ -z "$TOKEN" ] && { log_error "Token generation failed"; exit 3; }

# Regenerate kubeconfig (copia logica da create-tenant.sh)
SERVER=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-server}' 2>/dev/null || kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_DATA=$(kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

cat > "/var/lib/kwo/kubeconfigs/${TENANT}-kubeconfig.yaml" <<EOF
apiVersion: v1
kind: Config
clusters:
- name: k3s-web-orchestrator
  cluster:
    certificate-authority-data: $CA_DATA
    server: $SERVER
contexts:
- name: ${TENANT}@k3s-web-orchestrator
  context:
    cluster: k3s-web-orchestrator
    namespace: $TENANT
    user: ${TENANT}-deployer
current-context: ${TENANT}@k3s-web-orchestrator
users:
- name: ${TENANT}-deployer
  user:
    token: $TOKEN
EOF

chmod 600 "/var/lib/kwo/kubeconfigs/${TENANT}-kubeconfig.yaml"

# Update metadata
sed -i "s/\"lastModified\".*/\"lastModified\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"/" "/var/lib/kwo/metadata/${TENANT}.json"

log_info "Token rotated for tenant '$TENANT'"
log_info "Old kubeconfig archived to $archive_dir"
