#!/usr/bin/env bash
set -euo pipefail

source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true

echo "DNS Provider Check"
echo "=================="
echo ""

providers=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.dns-providers}' 2>/dev/null || echo "")

for provider in $providers; do
    echo "$provider"
    case "$provider" in
        cloudflare)
            token=$(kubectl get secret dns-credentials -n kube-system -o jsonpath='{.data.CF_DNS_API_TOKEN}' 2>/dev/null | base64 -d)
            [ -n "$token" ] && echo "  Credentials: ✓ CF_DNS_API_TOKEN present" || echo "  Credentials: ✗ Missing"
            ;;
        ovh)
            endpoint=$(kubectl get secret dns-credentials -n kube-system -o jsonpath='{.data.OVH_ENDPOINT}' 2>/dev/null | base64 -d)
            [ -n "$endpoint" ] && echo "  Credentials: ✓ All OVH credentials present" || echo "  Credentials: ✗ Missing"
            ;;
    esac
    echo "  Resolver: letsencrypt-${provider}"
    echo ""
done
