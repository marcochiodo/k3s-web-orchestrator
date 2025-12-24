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

METADATA_DIR="/var/lib/kwo/metadata/admin-deployers"

# Read metadata
declare -A deployers
deployer_count=0

# Check if directory exists
if [ ! -d "$METADATA_DIR" ]; then
    if [ "$FORMAT" = "table" ]; then
        echo "No admin deployers found"
    else
        echo "[]"
    fi
    exit 0
fi

for meta in "$METADATA_DIR"/*.json; do
    [ -f "$meta" ] || continue
    name=$(basename "$meta" .json)

    # Simple JSON parsing
    created=$(grep '"createdAt"' "$meta" | sed 's/.*: "\(.*\)".*/\1/' | cut -d'T' -f1)
    status=$(grep '"status"' "$meta" | sed 's/.*: "\(.*\)".*/\1/')
    sa_name=$(grep '"serviceAccount"' "$meta" | sed 's/.*: "\(.*\)".*/\1/')
    created_by=$(grep '"createdBy"' "$meta" | sed 's/.*: "\(.*\)".*/\1/')

    [ "$STATUS_FILTER" != "all" ] && [ "$status" != "$STATUS_FILTER" ] && continue

    # Check if ServiceAccount still exists
    if kubectl get serviceaccount "$sa_name" -n kube-system &>/dev/null; then
        k8s_status="active"
    else
        k8s_status="missing"
    fi

    deployers["$name"]="$created|$status|$sa_name|$k8s_status|$created_by"
    deployer_count=$((deployer_count + 1))
done

# Check if we have any deployers
if [ $deployer_count -eq 0 ]; then
    if [ "$FORMAT" = "table" ]; then
        echo "No admin deployers found"
        echo ""
        echo "Create one with: kwo-create-admin-deployer <name>"
    else
        echo "[]"
    fi
    exit 0
fi

# Output
if [ "$FORMAT" = "table" ]; then
    printf "%-20s %-12s %-8s %-30s %-10s %-15s\n" "NAME" "CREATED" "STATUS" "SERVICE ACCOUNT" "K8S STATUS" "CREATED BY"
    for name in "${!deployers[@]}"; do
        IFS='|' read -r created status sa_name k8s_status created_by <<< "${deployers[$name]}"
        printf "%-20s %-12s %-8s %-30s %-10s %-15s\n" "$name" "$created" "$status" "$sa_name" "$k8s_status" "$created_by"
    done
elif [ "$FORMAT" = "json" ]; then
    echo "["
    first=true
    for name in "${!deployers[@]}"; do
        IFS='|' read -r created status sa_name k8s_status created_by <<< "${deployers[$name]}"
        [ "$first" = false ] && echo ","
        echo "  {\"name\": \"$name\", \"created\": \"$created\", \"status\": \"$status\", \"serviceAccount\": \"$sa_name\", \"k8sStatus\": \"$k8s_status\", \"createdBy\": \"$created_by\"}"
        first=false
    done
    echo "]"
fi

# Summary
if [ "$FORMAT" = "table" ]; then
    echo ""
    echo "Total: $deployer_count admin deployer(s)"
    echo ""
    echo "Admin deployers have cluster-wide tenant permissions (can deploy to any namespace)."
    echo "Use 'kwo-create-admin-deployer <name>' to create a new one."
fi
