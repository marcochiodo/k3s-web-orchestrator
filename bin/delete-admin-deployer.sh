#!/usr/bin/env bash
set -euo pipefail

source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true

DEPLOYER="${1:-}"
FORCE=false
NO_ARCHIVE=false

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --no-archive) NO_ARCHIVE=true ;;
    esac
done

require_root

[ -z "$DEPLOYER" ] && { echo "Usage: $0 <deployer-name> [--force] [--no-archive]"; exit 1; }

SA_NAME="admin-deployer-${DEPLOYER}"
NAMESPACE="kube-system"

# Check exists
kubectl get serviceaccount "$SA_NAME" -n "$NAMESPACE" &>/dev/null || { log_error "Admin deployer '$DEPLOYER' not found"; exit 2; }

# Show info
log_info "Admin Deployer: $DEPLOYER"
log_info "ServiceAccount: $SA_NAME"
log_info "ClusterRole: $SA_NAME"
log_info "ClusterRoleBinding: ${SA_NAME}-binding"

# Confirm
if [ "$FORCE" = false ]; then
    read -p "Delete admin deployer '$DEPLOYER'? [y/N]: " confirm
    [ "$confirm" != "y" ] && { echo "Cancelled"; exit 3; }
fi

# Archive
if [ "$NO_ARCHIVE" = false ]; then
    timestamp=$(date +"%Y%m%d-%H%M%S")
    archive_dir="/var/lib/kwo/archive/admin-deployer-${DEPLOYER}-${timestamp}"
    mkdir -p "$archive_dir/manifests"

    cp "/var/lib/kwo/kubeconfigs/admin-deployer-${DEPLOYER}-kubeconfig.yaml" "$archive_dir/" 2>/dev/null || true
    cp "/var/lib/kwo/metadata/admin-deployers/${DEPLOYER}.json" "$archive_dir/" 2>/dev/null || true

    # Save the RBAC configuration for reference
    kubectl get clusterrole "$SA_NAME" -o yaml > "$archive_dir/manifests/clusterrole.yaml" 2>/dev/null || true
    kubectl get clusterrolebinding "${SA_NAME}-binding" -o yaml > "$archive_dir/manifests/clusterrolebinding.yaml" 2>/dev/null || true
    kubectl get serviceaccount "$SA_NAME" -n "$NAMESPACE" -o yaml > "$archive_dir/manifests/serviceaccount.yaml" 2>/dev/null || true

    log_info "Archived to $archive_dir"
fi

# Delete
log_info "Deleting ClusterRoleBinding..."
kubectl delete clusterrolebinding "${SA_NAME}-binding" 2>/dev/null || true

log_info "Deleting ClusterRole..."
kubectl delete clusterrole "$SA_NAME" 2>/dev/null || true

log_info "Deleting ServiceAccount token..."
kubectl delete secret "${SA_NAME}-token" -n "$NAMESPACE" 2>/dev/null || true

log_info "Deleting ServiceAccount..."
kubectl delete serviceaccount "$SA_NAME" -n "$NAMESPACE" 2>/dev/null || true

# Delete files
rm -f "/var/lib/kwo/kubeconfigs/admin-deployer-${DEPLOYER}-kubeconfig.yaml"
rm -f "/var/lib/kwo/metadata/admin-deployers/${DEPLOYER}.json"

# Log
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] DELETE ADMIN-DEPLOYER deployer=$DEPLOYER user=$(whoami)" >> /var/log/kwo/tenant-operations.log

log_info "Admin deployer '$DEPLOYER' deleted successfully"
