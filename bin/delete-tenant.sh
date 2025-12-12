#!/usr/bin/env bash
set -euo pipefail

source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true

TENANT="${1:-}"
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

[ -z "$TENANT" ] && { echo "Usage: $0 <tenant-name> [--force] [--no-archive]"; exit 1; }

# Prevent system namespace deletion
[[ "$TENANT" =~ ^(kube-system|kube-public|default)$ ]] && { log_error "Cannot delete system namespace"; exit 1; }

# Check exists
kubectl get namespace "$TENANT" &>/dev/null || { log_error "Tenant '$TENANT' not found"; exit 2; }

# Show info
log_info "Tenant: $TENANT"
kubectl get all,ingress -n "$TENANT" 2>/dev/null | head -20

# Confirm
if [ "$FORCE" = false ]; then
    read -p "Delete tenant '$TENANT' and all resources? [y/N]: " confirm
    [ "$confirm" != "y" ] && { echo "Cancelled"; exit 3; }
fi

# Archive
if [ "$NO_ARCHIVE" = false ]; then
    timestamp=$(date +"%Y%m%d-%H%M%S")
    archive_dir="/var/lib/kwo/archive/${TENANT}-${timestamp}"
    mkdir -p "$archive_dir/manifests"

    cp "/var/lib/kwo/kubeconfigs/${TENANT}-kubeconfig.yaml" "$archive_dir/" 2>/dev/null || true
    cp "/var/lib/kwo/metadata/${TENANT}.json" "$archive_dir/" 2>/dev/null || true
    kubectl get all,ingress,secrets,configmaps -n "$TENANT" -o yaml > "$archive_dir/manifests/all.yaml" 2>/dev/null || true

    log_info "Archived to $archive_dir"
fi

# Delete
kubectl delete namespace "$TENANT"
rm -f "/var/lib/kwo/kubeconfigs/${TENANT}-kubeconfig.yaml"
rm -f "/var/lib/kwo/metadata/${TENANT}.json"

# Log
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] DELETE tenant=$TENANT user=$(whoami)" >> /var/log/kwo/tenant-operations.log

log_info "Tenant '$TENANT' deleted successfully"
