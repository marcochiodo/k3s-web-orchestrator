#!/usr/bin/env bash
# KWO Registry Management
# Command for managing the private Docker registry

set -euo pipefail

# Determine if running from installation or git repo
if [ -f "/usr/share/kwo/bin/lib/common.sh" ]; then
    source /usr/share/kwo/bin/lib/common.sh
    source /usr/share/kwo/bin/lib/registry-helpers.sh
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/lib/common.sh"
    source "$SCRIPT_DIR/lib/registry-helpers.sh"
fi

# Usage
show_usage() {
    cat <<EOF
KWO Registry Management

USAGE:
  kwo-registry status
  kwo-registry rotate-credentials [--non-interactive]
  kwo-registry get-credentials

EXAMPLES:
  # Check registry status
  sudo kwo-registry status

  # Rotate credentials
  sudo kwo-registry rotate-credentials

  # Get current credentials
  sudo kwo-registry get-credentials

EOF
}

# Subcommand: status
registry_status() {
    local config=$(get_registry_config)
    local enabled=$(echo "$config" | jq -r '.enabled')

    if [ "$enabled" != "true" ]; then
        echo "Registry: Not configured"
        echo ""
        echo "To configure registry:"
        echo "  sudo ./install.sh  # Re-run installer and configure registry"
        exit 0
    fi

    local domain=$(echo "$config" | jq -r '.domain')
    local username=$(echo "$config" | jq -r '.username')
    local resolver=$(echo "$config" | jq -r '.certResolver')
    local created_at=$(echo "$config" | jq -r '.createdAt')

    echo "Registry Configuration:"
    echo "  Domain: $domain"
    echo "  Username: $username"
    echo "  Cert Resolver: $resolver"
    echo "  Created: ${created_at:0:19}"
    echo ""

    # Get deployment status
    local status=$(get_registry_status)
    local deployed=$(echo "$status" | jq -r '.deployed')

    if [ "$deployed" != "true" ]; then
        echo "Status: Not deployed"
        exit 0
    fi

    local pod_status=$(echo "$status" | jq -r '.podStatus')
    local pod_ready=$(echo "$status" | jq -r '.podReady')
    local ingress_exists=$(echo "$status" | jq -r '.ingressExists')
    local service_exists=$(echo "$status" | jq -r '.serviceExists')

    echo "Deployment Status:"
    echo "  Pod Status: $pod_status"
    echo "  Pod Ready: $pod_ready"
    echo "  Service: $service_exists"
    echo "  Ingress: $ingress_exists"
    echo ""

    # Check storage
    local pvc_size=$(kubectl get pvc registry-storage -n kube-system \
        -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null || echo "Unknown")
    local pvc_status=$(kubectl get pvc registry-storage -n kube-system \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

    echo "Storage:"
    echo "  Size: $pvc_size"
    echo "  Status: $pvc_status"
    echo ""

    # Test endpoint (only if pod is ready)
    if [ "$pod_ready" = "true" ]; then
        echo "Testing registry endpoint..."
        local creds=$(get_registry_credentials)
        local cred_username=$(echo "$creds" | jq -r '.username')
        local cred_password=$(echo "$creds" | jq -r '.password')

        local response=$(curl -s -o /dev/null -w "%{http_code}" \
            -u "$cred_username:$cred_password" \
            "https://$domain/v2/" 2>/dev/null || echo "000")

        if [ "$response" = "200" ]; then
            echo "  ✓ Registry is accessible (HTTP $response)"
        else
            echo "  ✗ Registry not accessible (HTTP $response)"
            echo "  Note: Certificate may not be ready yet. Check Traefik logs."
        fi
    else
        echo "Testing registry endpoint:"
        echo "  ⊘ Skipped (pod not ready)"
    fi
    echo ""
}

# Subcommand: rotate-credentials
registry_rotate_credentials() {
    require_root

    local config=$(get_registry_config)
    local enabled=$(echo "$config" | jq -r '.enabled')

    if [ "$enabled" != "true" ]; then
        log_error "Registry not configured"
        exit 1
    fi

    local domain=$(echo "$config" | jq -r '.domain')
    local username=$(echo "$config" | jq -r '.username')

    echo "Registry: https://$domain"
    echo "Username: $username"
    echo ""
    log_warn "This will generate a new password and restart k3s"
    echo ""

    read -p "Continue? [y/N]: " confirm

    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Cancelled"
        exit 0
    fi

    # Archive old credentials
    archive_registry_credentials "rotate"

    # Generate new password
    log_info "Generating new password..."
    local new_password=$(generate_password)
    local new_htpasswd=$(hash_password_bcrypt "$username" "$new_password")

    # Update secret
    log_info "Updating registry-auth secret..."
    kubectl create secret generic registry-auth -n kube-system \
        --from-literal=htpasswd="$new_htpasswd" \
        --from-literal=username="$username" \
        --from-literal=password="$new_password" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # Update registries.yaml
    log_info "Updating /etc/rancher/k3s/registries.yaml..."
    cat > /etc/rancher/k3s/registries.yaml <<EOF
# KWO Private Registry Configuration
# Auto-generated by kwo-registry
# Last updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

configs:
  "$domain":
    auth:
      username: $username
      password: $new_password
    tls:
      insecure_skip_verify: false
EOF

    chmod 600 /etc/rancher/k3s/registries.yaml

    # Restart registry pod to reload htpasswd
    log_info "Restarting registry pod..."
    kubectl delete pod -n kube-system -l app=registry --wait=false >/dev/null 2>&1 || true

    # Restart k3s
    log_info "Restarting k3s..."
    systemctl restart k3s

    sleep 5

    echo ""
    log_info "✓ Credentials rotated successfully"
    echo ""
    echo "New password: $new_password"
    echo ""
    log_warn "IMPORTANT: Update your CI/CD secrets with the new password"
    echo ""
}

# Subcommand: get-credentials
registry_get_credentials() {
    require_root

    local config=$(get_registry_config)
    local enabled=$(echo "$config" | jq -r '.enabled')

    if [ "$enabled" != "true" ]; then
        log_error "Registry not configured"
        exit 1
    fi

    local domain=$(echo "$config" | jq -r '.domain')
    local creds=$(get_registry_credentials)
    local username=$(echo "$creds" | jq -r '.username')
    local password=$(echo "$creds" | jq -r '.password')

    echo "Registry: https://$domain"
    echo "Username: $username"
    echo "Password: $password"
    echo ""
    echo "Docker login command:"
    echo "  echo \"$password\" | docker login $domain -u $username --password-stdin"
    echo ""
}

# Main dispatcher
SUBCOMMAND="${1:-}"

if [ -z "$SUBCOMMAND" ]; then
    show_usage
    exit 1
fi

shift || true

case "$SUBCOMMAND" in
    status)
        registry_status "$@"
        ;;
    rotate-credentials)
        registry_rotate_credentials "$@"
        ;;
    get-credentials)
        registry_get_credentials "$@"
        ;;
    -h|--help|help)
        show_usage
        exit 0
        ;;
    *)
        log_error "Unknown subcommand: $SUBCOMMAND"
        echo ""
        show_usage
        exit 1
        ;;
esac
