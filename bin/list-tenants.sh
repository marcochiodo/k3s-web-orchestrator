#!/usr/bin/env bash
set -euo pipefail

source /usr/share/kwo/bin/lib/common.sh 2>/dev/null || true

FORMAT="table"
STATUS_FILTER="active"

# Parse args
for arg in "$@"; do
    case "$arg" in
        --format=*) FORMAT="${arg#*=}" ;;
        --status=*) STATUS_FILTER="${arg#*=}" ;;
    esac
done

# Read metadata
declare -A tenants
for meta in /var/lib/kwo/metadata/*.json; do
    [ -f "$meta" ] || continue
    name=$(basename "$meta" .json)

    # Simple JSON parsing
    created=$(grep '"createdAt"' "$meta" | sed 's/.*: "\(.*\)".*/\1/' | cut -d'T' -f1)
    status=$(grep '"status"' "$meta" | sed 's/.*: "\(.*\)".*/\1/')

    [ "$STATUS_FILTER" != "all" ] && [ "$status" != "$STATUS_FILTER" ] && continue

    # Enrich with k8s data
    if kubectl get namespace "$name" &>/dev/null; then
        pods=$(kubectl get pods -n "$name" --no-headers 2>/dev/null | wc -l)
        deployments=$(kubectl get deployments -n "$name" --no-headers 2>/dev/null | wc -l)
        services=$(kubectl get services -n "$name" --no-headers 2>/dev/null | wc -l)
        ingresses=$(kubectl get ingress -n "$name" --no-headers 2>/dev/null | wc -l)
    else
        pods="-"; deployments="-"; services="-"; ingresses="-"
    fi

    tenants["$name"]="$created|$status|$pods|$deployments|$services|$ingresses"
done

# Output
if [ "$FORMAT" = "table" ]; then
    printf "%-15s %-12s %-8s %-5s %-12s %-9s %-9s\n" "NAME" "CREATED" "STATUS" "PODS" "DEPLOYMENTS" "SERVICES" "INGRESSES"
    for name in "${!tenants[@]}"; do
        IFS='|' read -r created status pods deployments services ingresses <<< "${tenants[$name]}"
        printf "%-15s %-12s %-8s %-5s %-12s %-9s %-9s\n" "$name" "$created" "$status" "$pods" "$deployments" "$services" "$ingresses"
    done
elif [ "$FORMAT" = "json" ]; then
    echo "["
    first=true
    for name in "${!tenants[@]}"; do
        IFS='|' read -r created status pods deployments services ingresses <<< "${tenants[$name]}"
        [ "$first" = false ] && echo ","
        echo "  {\"name\": \"$name\", \"created\": \"$created\", \"status\": \"$status\", \"pods\": $pods, \"deployments\": $deployments}"
        first=false
    done
    echo "]"
fi
