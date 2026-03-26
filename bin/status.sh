#!/usr/bin/env bash
set -euo pipefail

source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true

echo "K3S Web Orchestrator Status"
echo "============================"
echo ""
echo "KWO Version: $(get_kwo_version)"
echo "k3s Version: $(k3s --version 2>/dev/null | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' || echo 'unknown')"
echo "Cluster API: $(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-server}' 2>/dev/null || echo 'unknown')"
echo ""

# Disk usage
DISK_PCT=$(df / | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
DISK_AVAIL=$(df -h / | awk 'NR==2 {print $4}')
PREVIOUS_LINK="/var/lib/rancher/k3s/data/previous"
if [ "$DISK_PCT" -ge 85 ]; then
    echo "Disk Usage"
    echo "  Status:    CRITICAL (${DISK_PCT}% used, ${DISK_AVAIL} available)"
    [ -L "$PREVIOUS_LINK" ] && echo "  Old k3s:   $(du -sh "$(readlink -f "$PREVIOUS_LINK")" 2>/dev/null | awk '{print $1}') recoverable"
    echo "  Action:    sudo kwo-cleanup-k3s"
elif [ "$DISK_PCT" -ge 70 ]; then
    echo "Disk Usage"
    echo "  Status:    WARNING (${DISK_PCT}% used, ${DISK_AVAIL} available)"
    [ -L "$PREVIOUS_LINK" ] && echo "  Old k3s:   $(du -sh "$(readlink -f "$PREVIOUS_LINK")" 2>/dev/null | awk '{print $1}') recoverable — run: sudo kwo-cleanup-k3s"
else
    echo "Disk Usage:  ${DISK_PCT}% used (${DISK_AVAIL} available)"
fi
echo ""

# k3s service
echo "K3S Service"
if systemctl is-active --quiet k3s; then
    echo "  Status: active (running)"
    uptime=$(systemctl show k3s --property=ActiveEnterTimestamp --value)
    echo "  Since: $uptime"
else
    echo "  Status: inactive"
fi
echo ""

# Traefik
echo "Traefik Ingress"
traefik_status=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")
echo "  Status: $traefik_status"
[ "$traefik_status" = "Running" ] && kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
echo ""

# Certificate resolvers
echo "Certificate Resolvers"
providers=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.dns-providers}' 2>/dev/null || echo "")
for provider in $providers; do
    echo "  ✓ letsencrypt-${provider}"
done
echo ""

# Tenants
echo "Tenants"
active=$(find /var/lib/kwo/metadata/ -name "*.json" -exec grep -l '"status": "active"' {} \; 2>/dev/null | wc -l)
total=$(ls -1 /var/lib/kwo/metadata/*.json 2>/dev/null | wc -l)
echo "  Active: $active"
echo "  Total: $total"
