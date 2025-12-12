#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-}"
[ -z "$DOMAIN" ] && { echo "Usage: $0 <domain>"; exit 1; }

echo "TLS Certificate Check: $DOMAIN"
echo "========================================"
echo ""

# Find ingress
ingress=$(kubectl get ingress -A -o json | jq -r ".items[] | select(.spec.rules[].host == \"$DOMAIN\") | \"\(.metadata.namespace)/\(.metadata.name)\"" 2>/dev/null | head -1)

if [ -n "$ingress" ]; then
    echo "Ingress: $ingress"
    resolver=$(kubectl get ingress -n "${ingress%/*}" "${ingress#*/}" -o jsonpath='{.metadata.annotations.traefik\.ingress\.kubernetes\.io/router\.tls\.certresolver}' 2>/dev/null)
    echo "Cert Resolver: ${resolver:-none}"
else
    echo "✗ No ingress found for domain $DOMAIN"
    exit 1
fi

# Check certificate via openssl
if timeout 5 bash -c "echo | openssl s_client -servername $DOMAIN -connect $DOMAIN:443 2>/dev/null | openssl x509 -noout -dates" &>/dev/null; then
    echo ""
    echo "Certificate Details:"
    echo | openssl s_client -servername $DOMAIN -connect $DOMAIN:443 2>/dev/null | openssl x509 -noout -dates -issuer
else
    echo ""
    echo "✗ Cannot retrieve certificate (domain may not be accessible)"
fi
