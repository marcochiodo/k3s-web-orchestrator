#!/usr/bin/env bash
# Registry Management Helper Functions for KWO

set -euo pipefail

# Get registry configuration from kwo-config ConfigMap
# Returns: JSON with registry config
get_registry_config() {
    local enabled=$(kubectl get configmap kwo-config -n kube-system \
        -o jsonpath='{.data.registry-enabled}' 2>/dev/null || echo "false")

    if [ "$enabled" != "true" ]; then
        echo '{"enabled": false}'
        return 0
    fi

    local domain=$(kubectl get configmap kwo-config -n kube-system \
        -o jsonpath='{.data.registry-domain}' 2>/dev/null || echo "")
    local username=$(kubectl get configmap kwo-config -n kube-system \
        -o jsonpath='{.data.registry-username}' 2>/dev/null || echo "")
    local resolver=$(kubectl get configmap kwo-config -n kube-system \
        -o jsonpath='{.data.registry-certresolver}' 2>/dev/null || echo "")
    local created_at=$(kubectl get configmap kwo-config -n kube-system \
        -o jsonpath='{.data.registry-created-at}' 2>/dev/null || echo "")

    jq -n \
        --arg enabled "$enabled" \
        --arg domain "$domain" \
        --arg username "$username" \
        --arg resolver "$resolver" \
        --arg created_at "$created_at" \
        '{
            enabled: ($enabled == "true"),
            domain: $domain,
            username: $username,
            certResolver: $resolver,
            createdAt: $created_at
        }'
}

# Check if registry is deployed
# Returns: 0 if deployed, 1 if not
is_registry_deployed() {
    kubectl get deployment registry -n kube-system &>/dev/null
}

# Get registry credentials from secret
# Returns: JSON with username and password
get_registry_credentials() {
    if ! kubectl get secret registry-auth -n kube-system &>/dev/null; then
        echo '{"error": "Secret not found"}'
        return 1
    fi

    local username=$(kubectl get secret registry-auth -n kube-system \
        -o jsonpath='{.data.username}' 2>/dev/null | base64 -d)
    local password=$(kubectl get secret registry-auth -n kube-system \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d)

    jq -n \
        --arg username "$username" \
        --arg password "$password" \
        '{username: $username, password: $password}'
}

# Archive registry credentials
# Args: $1 - operation (rotate, update, delete)
archive_registry_credentials() {
    local operation="$1"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local archive_dir="/var/lib/kwo/archive/registry-${operation}-${timestamp}"

    mkdir -p "$archive_dir"
    chmod 700 "$archive_dir"

    # Save config
    get_registry_config > "$archive_dir/config.json"

    # Save credentials
    get_registry_credentials > "$archive_dir/credentials.json"
    chmod 600 "$archive_dir/credentials.json"

    # Save registries.yaml if exists
    if [ -f "/etc/rancher/k3s/registries.yaml" ]; then
        cp /etc/rancher/k3s/registries.yaml "$archive_dir/registries.yaml"
        chmod 600 "$archive_dir/registries.yaml"
    fi

    # Save registry secret
    if kubectl get secret registry-auth -n kube-system &>/dev/null; then
        kubectl get secret registry-auth -n kube-system -o yaml > "$archive_dir/registry-auth-secret.yaml"
        chmod 600 "$archive_dir/registry-auth-secret.yaml"
    fi

    log_info "Archived registry credentials to $archive_dir"
}

# Get registry pod status
# Returns: JSON with pod status
get_registry_status() {
    if ! is_registry_deployed; then
        echo '{"deployed": false}'
        return 0
    fi

    local pod_status=$(kubectl get pods -n kube-system -l app=registry \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Unknown")

    local pod_ready=$(kubectl get pods -n kube-system -l app=registry \
        -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

    local ingress_exists="false"
    kubectl get ingress registry -n kube-system &>/dev/null && ingress_exists="true"

    local service_exists="false"
    kubectl get service registry -n kube-system &>/dev/null && service_exists="true"

    jq -n \
        --arg deployed "true" \
        --arg status "$pod_status" \
        --arg ready "$pod_ready" \
        --arg ingress "$ingress_exists" \
        --arg service "$service_exists" \
        '{
            deployed: ($deployed == "true"),
            podStatus: $status,
            podReady: ($ready == "True"),
            ingressExists: ($ingress == "true"),
            serviceExists: ($service == "true")
        }'
}
