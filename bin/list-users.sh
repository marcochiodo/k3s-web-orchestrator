#!/usr/bin/env bash
set -euo pipefail

# List all users created with kwo-create-user
# Usage: ./list-users.sh [--format=table|json] [--role=<role-type>] [--scope=cluster-wide|namespace-scoped]

FORMAT="table"
FILTER_ROLE=""
FILTER_SCOPE=""

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --format=*) FORMAT="${arg#*=}" ;;
        --role=*) FILTER_ROLE="${arg#*=}" ;;
        --scope=*) FILTER_SCOPE="${arg#*=}" ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --format=table|json    Output format (default: table)"
            echo "  --role=<role-type>     Filter by role type"
            echo "  --scope=<scope>        Filter by scope (cluster-wide|namespace-scoped)"
            echo "  --help                 Show this help"
            exit 0
            ;;
    esac
done

METADATA_DIR="/var/lib/kwo/metadata/users"

if [ ! -d "$METADATA_DIR" ]; then
    echo "No users found (metadata directory does not exist)"
    exit 0
fi

# Collect users
declare -a users=()
for metadata_file in "$METADATA_DIR"/*.json; do
    [ -f "$metadata_file" ] || continue
    
    name=$(jq -r '.name' "$metadata_file" 2>/dev/null || echo "")
    role_type=$(jq -r '.roleType' "$metadata_file" 2>/dev/null || echo "")
    scope=$(jq -r '.scope' "$metadata_file" 2>/dev/null || echo "")
    namespaces=$(jq -r '.namespaces | join(",")' "$metadata_file" 2>/dev/null || echo "")
    created_at=$(jq -r '.createdAt' "$metadata_file" 2>/dev/null || echo "")
    kubeconfig_path=$(jq -r '.kubeconfigPath' "$metadata_file" 2>/dev/null || echo "")
    
    # Apply filters
    if [ -n "$FILTER_ROLE" ] && [ "$role_type" != "$FILTER_ROLE" ]; then
        continue
    fi
    
    if [ -n "$FILTER_SCOPE" ] && [ "$scope" != "$FILTER_SCOPE" ]; then
        continue
    fi
    
    # Format namespaces display
    if [ -z "$namespaces" ]; then
        namespaces="all"
    fi
    
    users+=("$name|$role_type|$scope|$namespaces|$created_at|$kubeconfig_path")
done

# Check if any users found
if [ ${#users[@]} -eq 0 ]; then
    if [ -n "$FILTER_ROLE" ] || [ -n "$FILTER_SCOPE" ]; then
        echo "No users found matching filters"
    else
        echo "No users found"
    fi
    exit 0
fi

# Output
if [ "$FORMAT" = "json" ]; then
    # JSON output
    echo "["
    first=true
    for user_data in "${users[@]}"; do
        IFS='|' read -r name role_type scope namespaces created_at kubeconfig_path <<< "$user_data"
        
        [ "$first" = false ] && echo ","
        first=false
        
        # Build namespaces array
        namespaces_json="[]"
        if [ "$namespaces" != "all" ]; then
            namespaces_json="[\"$(echo "$namespaces" | sed 's/,/","/g')\"]"
        fi
        
        cat <<EOF
  {
    "name": "$name",
    "roleType": "$role_type",
    "scope": "$scope",
    "namespaces": $namespaces_json,
    "createdAt": "$created_at",
    "kubeconfigPath": "$kubeconfig_path"
  }
EOF
    done
    echo ""
    echo "]"
else
    # Table output
    printf "%-15s %-12s %-18s %-25s %-22s\n" "NAME" "ROLE" "SCOPE" "NAMESPACES" "CREATED AT"
    printf "%-15s %-12s %-18s %-25s %-22s\n" "----" "----" "-----" "----------" "----------"
    
    for user_data in "${users[@]}"; do
        IFS='|' read -r name role_type scope namespaces created_at kubeconfig_path <<< "$user_data"
        
        # Truncate long namespace lists
        if [ "${#namespaces}" -gt 25 ]; then
            namespaces="${namespaces:0:22}..."
        fi
        
        printf "%-15s %-12s %-18s %-25s %-22s\n" "$name" "$role_type" "$scope" "$namespaces" "$created_at"
    done
    
    echo ""
    echo "Total: ${#users[@]} user(s)"
fi
