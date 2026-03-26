#!/usr/bin/env bash
set -euo pipefail

# kwo-cleanup-k3s - Free disk space occupied by old k3s versions and unused images
# Usage: sudo kwo-cleanup-k3s

if [ -f "/usr/share/kwo/bin/lib/common.sh" ]; then
    source /usr/share/kwo/bin/lib/common.sh
else
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
    log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
    require_root() { [ "$EUID" -eq 0 ] || { log_error "Must run as root (use sudo)"; exit 4; }; }
fi

require_root

echo "=== KWO k3s Cleanup ==="
echo ""

DISK_BEFORE=$(df -m / | awk 'NR==2 {print $4}')
TOTAL_FREED=0

# 1. Previous k3s version data
# After an upgrade k3s keeps the old extracted binaries under data/previous (~230MB)
PREVIOUS_LINK="/var/lib/rancher/k3s/data/previous"
if [ -L "$PREVIOUS_LINK" ]; then
    PREVIOUS_DIR=$(readlink -f "$PREVIOUS_LINK")
    SIZE_MB=$(du -sm "$PREVIOUS_DIR" 2>/dev/null | awk '{print $1}' || echo 0)
    log_info "Found previous k3s version data: ${SIZE_MB}MB"
    rm -rf "$PREVIOUS_DIR"
    rm -f "$PREVIOUS_LINK"
    TOTAL_FREED=$((TOTAL_FREED + SIZE_MB))
    log_info "Removed previous k3s data: ${SIZE_MB}MB freed"
else
    log_info "No previous k3s version data found"
fi

# 2. Unused container images
log_info "Pruning unused container images..."
BEFORE_MB=$(du -sm /var/lib/rancher/k3s/agent/containerd/ 2>/dev/null | awk '{print $1}' || echo 0)
PRUNED=$(k3s crictl rmi --prune 2>&1 || true)
AFTER_MB=$(du -sm /var/lib/rancher/k3s/agent/containerd/ 2>/dev/null | awk '{print $1}' || echo 0)
IMG_FREED=$((BEFORE_MB - AFTER_MB))

if [ -n "$PRUNED" ]; then
    echo "$PRUNED" | while read -r line; do [ -n "$line" ] && log_info "  $line"; done
fi
if [ "$IMG_FREED" -gt 0 ]; then
    log_info "Container images pruned: ${IMG_FREED}MB freed"
    TOTAL_FREED=$((TOTAL_FREED + IMG_FREED))
else
    log_info "No unused container images found"
fi

# 3. Summary
DISK_AFTER=$(df -m / | awk 'NR==2 {print $4}')
echo ""
echo "========================================="
echo "  Cleanup Complete"
echo "========================================="
echo ""
echo "  Freed:     ${TOTAL_FREED}MB"
echo "  Available: ${DISK_BEFORE}MB → ${DISK_AFTER}MB"
echo ""

# Warn if disk is still low
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
if [ "$DISK_PCT" -ge 85 ]; then
    log_warn "Disk is still at ${DISK_PCT}% — consider expanding the root volume"
elif [ "$DISK_PCT" -ge 70 ]; then
    log_warn "Disk is at ${DISK_PCT}% — monitor usage before next upgrade"
else
    log_info "Disk usage is at ${DISK_PCT}% — healthy"
fi
