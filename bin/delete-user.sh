#!/usr/bin/env bash
set -euo pipefail

source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true

USERNAME="${1:-}"
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

[ -z "$USERNAME" ] && { echo "Usage: $0 <username> [--force] [--no-archive]"; exit 1; }

SA_NAME="user-${USERNAME}"
NAMESPACE="kube-system"
METADATA_FILE="/var/lib/kwo/metadata/users/${USERNAME}.json"

# Check exists
if [ ! -f "$METADATA_FILE" ]; then
    log_error "User '$USERNAME' not found"
    exit 2
fi

# Read metadata
ROLE_TYPE=$(jq -r '.roleType' "$METADATA_FILE" 2>/dev/null || echo "")
SCOPE=$(jq -r '.scope' "$METADATA_FILE" 2>/dev/null || echo "")
NAMESPACES=$(jq -r '.namespaces | join(",")' "$METADATA_FILE" 2>/dev/null || echo "")

# Show info
log_info "User: $USERNAME"
log_info "Role: $ROLE_TYPE"
log_info "Scope: $SCOPE"
if [ -n "$NAMESPACES" ]; then
    log_info "Namespaces: $NAMESPACES"
fi
log_info "ServiceAccount: $SA_NAME"

# Confirm
if [ "$FORCE" = false ]; then
    read -p "Delete user '$USERNAME'? [y/N]: " confirm
    [ "$confirm" != "y" ] && { echo "Cancelled"; exit 3; }
fi

# Archive
if [ "$NO_ARCHIVE" = false ]; then
    timestamp=$(date +"%Y%m%d-%H%M%S")
    archive_dir="/var/lib/kwo/archive/user-${USERNAME}-${timestamp}"
    mkdir -p "$archive_dir/manifests"
    
    cp "/var/lib/kwo/kubeconfigs/user-${USERNAME}-kubeconfig.yaml" "$archive_dir/" 2>/dev/null || true
    cp "/var/lib/kwo/kubeconfigs/user-${USERNAME}-kubeconfig.json" "$archive_dir/" 2>/dev/null || true
    cp "$METADATA_FILE" "$archive_dir/" 2>/dev/null || true
    
    # Save binding configuration for reference
    if [ "$SCOPE" = "cluster-wide" ]; then
        kubectl get clusterrolebinding "${SA_NAME}-binding" -o yaml > "$archive_dir/manifests/clusterrolebinding.yaml" 2>/dev/null || true
    else
        for ns in ${NAMESPACES//,/ }; do
            kubectl get rolebinding "${SA_NAME}-binding" -n "$ns" -o yaml > "$archive_dir/manifests/rolebinding-${ns}.yaml" 2>/dev/null || true
        done
    fi
    
    kubectl get serviceaccount "$SA_NAME" -n "$NAMESPACE" -o yaml > "$archive_dir/manifests/serviceaccount.yaml" 2>/dev/null || true
    
    log_info "Archived to $archive_dir"
fi

# Delete bindings
if [ "$SCOPE" = "cluster-wide" ]; then
    log_info "Deleting ClusterRoleBinding..."
    kubectl delete clusterrolebinding "${SA_NAME}-binding" 2>/dev/null || true
else
    log_info "Deleting RoleBindings..."
    for ns in ${NAMESPACES//,/ }; do
        log_info "  - namespace: $ns"
        kubectl delete rolebinding "${SA_NAME}-binding" -n "$ns" 2>/dev/null || true
    done
fi

# NOTE: ClusterRole is NOT deleted (shared between users)
log_info "ClusterRole 'kwo-${ROLE_TYPE}' preserved (shared resource)"

# Delete ServiceAccount
log_info "Deleting ServiceAccount token..."
kubectl delete secret "${SA_NAME}-token" -n "$NAMESPACE" 2>/dev/null || true

log_info "Deleting ServiceAccount..."
kubectl delete serviceaccount "$SA_NAME" -n "$NAMESPACE" 2>/dev/null || true

# Delete files
rm -f "/var/lib/kwo/kubeconfigs/user-${USERNAME}-kubeconfig.yaml"
rm -f "/var/lib/kwo/kubeconfigs/user-${USERNAME}-kubeconfig.json"
rm -f "$METADATA_FILE"

# Log
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] DELETE USER user=$USERNAME role=$ROLE_TYPE scope=$SCOPE operator=$(whoami)" >> /var/log/kwo/tenant-operations.log

log_info "User '$USERNAME' deleted successfully"
