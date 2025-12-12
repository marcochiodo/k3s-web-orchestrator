#!/usr/bin/env bash
set -euo pipefail

source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true

echo "K3S Web Orchestrator Status"
echo "============================"
echo ""
echo "KWO Version: $(get_kwo_version)"
echo "Cluster API: $(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-server}' 2>/dev/null || echo 'unknown')"
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
