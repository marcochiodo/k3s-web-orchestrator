#!/usr/bin/env bash
set -euo pipefail

# K3S Web Orchestrator (KWO) Installation Script
# Installs k3s with Traefik configured for automatic Let's Encrypt certificates via DNS-01

SCRIPT_VERSION="1.2.0"
K3S_VERSION="${K3S_VERSION:-}"  # Empty = latest stable
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Validate domain format (FQDN)
validate_domain() {
    local domain="$1"
    [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]
}

# Generate 32-char random password (base64-safe, alphanumeric only)
generate_password() {
    openssl rand -base64 32 | tr -d '/+=' | head -c 32
}

# Create htpasswd bcrypt hash
# Args: $1=username $2=password
# Returns: username:$2y$...
hash_password_bcrypt() {
    htpasswd -Bbn "$1" "$2"
}

# Detect OS
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        OS_VERSION=$VERSION_ID
    else
        log_error "Cannot detect OS. /etc/os-release not found."
        exit 1
    fi

    case "$OS" in
        debian|ubuntu)
            PKG_MANAGER="apt-get"
            ;;
        fedora)
            PKG_MANAGER="dnf"
            ;;
        *)
            log_error "Unsupported OS: $OS. Supported: debian, ubuntu, fedora"
            exit 1
            ;;
    esac

    log_info "Detected OS: $OS $OS_VERSION"
}

# Install prerequisites
install_prerequisites() {
    log_info "Installing prerequisites..."

    case "$PKG_MANAGER" in
        apt-get)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq curl iptables jq apache2-utils
            ;;
        dnf)
            dnf install -y -q curl iptables jq httpd-tools
            ;;
    esac

    # Verify htpasswd is available
    if ! command -v htpasswd &>/dev/null; then
        log_error "htpasswd command not found after installation"
        log_error "Package apache2-utils (Debian/Ubuntu) or httpd-tools (Fedora) may have failed to install"
        exit 1
    fi
}

# Configure system hostname
configure_hostname() {
    if [ -z "${API_DOMAIN:-}" ]; then
        log_warn "No API domain configured, skipping hostname setup"
        return 0
    fi

    # Check if k3s is already installed - prevent hostname changes
    if command -v k3s &> /dev/null; then
        local current_hostname=$(hostname)
        local k3s_node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

        if [ -n "$k3s_node_name" ] && [ "$k3s_node_name" != "$API_DOMAIN" ]; then
            log_error "CRITICAL: k3s is already installed with hostname: $k3s_node_name"
            log_error "Cannot change hostname to: $API_DOMAIN"
            log_error "Changing hostname on an existing k3s installation will cause:"
            log_error "  - Multiple nodes in the cluster"
            log_error "  - Persistent volume binding issues"
            log_error "  - Service disruption"
            echo ""
            log_error "To reconfigure hostname, you must first uninstall k3s:"
            echo "  sudo /usr/local/bin/k3s-uninstall.sh"
            echo "  sudo rm -rf /var/lib/rancher/k3s"
            echo "  Then run this installer again."
            echo ""
            exit 1
        fi

        log_info "k3s already installed with compatible hostname: $k3s_node_name"
        return 0
    fi

    log_info "Configuring system hostname to: $API_DOMAIN"
    hostnamectl set-hostname "$API_DOMAIN"

    # Verify hostname was set
    local current_hostname=$(hostname)
    if [ "$current_hostname" = "$API_DOMAIN" ]; then
        log_info "System hostname configured successfully"
    else
        log_warn "Failed to set hostname, continuing anyway..."
    fi
}

# Install k3s
install_k3s() {
    if command -v k3s &> /dev/null; then
        log_warn "k3s is already installed. Skipping installation."
        return 0
    fi

    log_info "Installing k3s..."

    local k3s_args="--write-kubeconfig-mode 644"

    # Add TLS SAN for API domain if configured
    if [ -n "${API_DOMAIN:-}" ]; then
        log_info "Adding TLS SAN for: $API_DOMAIN"
        k3s_args="$k3s_args --tls-san $API_DOMAIN"
    fi

    if [ -n "$K3S_VERSION" ]; then
        curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="${K3S_VERSION}" sh -s - $k3s_args
    else
        curl -sfL https://get.k3s.io | sh -s - $k3s_args
    fi

    log_info "k3s installed successfully"
}

# Wait for k3s to be ready
wait_for_k3s() {
    log_info "Waiting for k3s to be ready..."

    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if kubectl get nodes &> /dev/null; then
            log_info "k3s is ready"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    log_error "k3s failed to start within expected time"
    exit 1
}

# Prompt for configuration
prompt_config() {
    # Try to load existing configuration
    local existing_email=""
    local existing_domain=""

    if kubectl get configmap kwo-config -n kube-system &>/dev/null; then
        existing_email=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.acme-email}' 2>/dev/null || echo "")
        existing_domain=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-domain}' 2>/dev/null || echo "")
    fi

    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        log_info "Running in non-interactive mode"

        # Use existing email if available and not overridden
        if [ -n "$existing_email" ] && [ -z "${ACME_EMAIL:-}" ]; then
            ACME_EMAIL="$existing_email"
            log_info "Using existing ACME email: $ACME_EMAIL"
        else
            ACME_EMAIL="${ACME_EMAIL:?ACME_EMAIL environment variable is required - needed for Let\'s Encrypt}"
        fi

        # Use existing domain if available and not overridden
        if [ -n "$existing_domain" ] && [ -z "${API_DOMAIN:-}" ]; then
            API_DOMAIN="$existing_domain"
            log_info "Using existing API domain: $API_DOMAIN"
        else
            API_DOMAIN="${API_DOMAIN:-}"
        fi

        return 0
    fi

    echo ""
    echo "=== K3S Web Orchestrator Configuration ==="
    echo ""

    # Let's Encrypt email
    if [ -n "$existing_email" ]; then
        echo "Current Let's Encrypt email: $existing_email"
        read -p "Update email? [y/N]: " update_email

        if [ "$update_email" = "y" ] || [ "$update_email" = "Y" ]; then
            read -p "Enter new email for Let's Encrypt: " ACME_EMAIL
            while [ -z "$ACME_EMAIL" ]; do
                log_error "Email is required"
                read -p "Enter new email for Let's Encrypt: " ACME_EMAIL
            done
        else
            ACME_EMAIL="$existing_email"
            log_info "Keeping existing email"
        fi
    else
        echo "Let's Encrypt requires an email for certificate notifications."
        echo "This is required even if you skip DNS configuration now."
        read -p "Enter email for Let's Encrypt: " ACME_EMAIL
        while [ -z "$ACME_EMAIL" ]; do
            log_error "Email is required"
            read -p "Enter email for Let's Encrypt: " ACME_EMAIL
        done
    fi

    # API hostname (recommended for production)
    echo ""
    if [ -n "$existing_domain" ]; then
        # Check if k3s is installed - hostname cannot be changed
        if command -v k3s &> /dev/null; then
            echo "Current API hostname: $existing_domain (locked - k3s installed)"
            log_info "API hostname cannot be changed on existing k3s installation"
            API_DOMAIN="$existing_domain"
        else
            # k3s not installed, allow hostname change
            echo "Current API hostname: $existing_domain"
            read -p "Update hostname? [y/N]: " update_domain

            if [ "$update_domain" = "y" ] || [ "$update_domain" = "Y" ]; then
                read -p "Enter new API hostname: " API_DOMAIN
                while [ -z "$API_DOMAIN" ]; do
                    log_warn "API hostname is strongly recommended for production"
                    read -p "API hostname (or press Ctrl+C to exit): " API_DOMAIN
                done
            else
                API_DOMAIN="$existing_domain"
                log_info "Keeping existing API hostname"
            fi
        fi
    else
        echo "Enter the API server hostname (e.g., host1.example.com)"
        echo "This will be used for:"
        echo "  - System hostname"
        echo "  - Kubernetes API server TLS certificate"
        echo "  - Tenant kubeconfig files"
        read -p "API hostname: " API_DOMAIN
        while [ -z "$API_DOMAIN" ]; do
            log_warn "API hostname is strongly recommended for production"
            read -p "API hostname (or press Ctrl+C to exit): " API_DOMAIN
        done
    fi
}

# Prompt for DNS provider selection
prompt_dns_provider() {
    echo "" >&2
    echo "Select DNS provider:" >&2
    echo "1) Cloudflare" >&2
    echo "2) OVH" >&2
    echo "3) AWS Route53" >&2
    echo "4) DigitalOcean" >&2
    read -p "Enter choice [1-4]: " dns_choice

    case "$dns_choice" in
        1) echo "cloudflare" ;;
        2) echo "ovh" ;;
        3) echo "route53" ;;
        4) echo "digitalocean" ;;
        *)
            log_error "Invalid choice"
            return 1
            ;;
    esac
}

# Configure multiple DNS providers
configure_dns_providers() {
    declare -g -A DNS_CREDS
    declare -g -a DNS_PROVIDER_LIST
    declare -g DNS_CONFIGURED=false

    # Check for existing DNS providers
    local existing_providers=""
    if kubectl get configmap kwo-dns-providers -n kube-system &>/dev/null; then
        existing_providers=$(kubectl get configmap kwo-dns-providers -n kube-system \
            -o jsonpath='{.data.providers\.json}' 2>/dev/null | jq -r 'keys[]' 2>/dev/null || echo "")
    fi

    # Count existing providers
    local existing_count=0
    if [ -n "$existing_providers" ]; then
        existing_count=$(echo "$existing_providers" | wc -l)
    fi

    # If providers exist, load them into DNS_PROVIDER_LIST
    declare -g DNS_PROVIDERS_REUSED=false
    if [ "$existing_count" -gt 0 ]; then
        log_info "Found $existing_count existing DNS provider(s)"
        while IFS= read -r resolver; do
            # Extract provider name from resolver (e.g., "letsencrypt-cloudflare" -> "cloudflare")
            local provider=$(echo "$resolver" | sed 's/^letsencrypt-//' | sed 's/-.*$//')
            DNS_PROVIDER_LIST+=("$provider")
        done <<< "$existing_providers"
        DNS_CONFIGURED=true
        DNS_PROVIDERS_REUSED=true
    fi

    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        if [ "${DNS_SKIP:-false}" = "true" ]; then
            log_warn "Skipping DNS provider configuration (DNS_SKIP=true)"
            DNS_CONFIGURED=false
            return 0
        fi

        # If no existing providers, add from env var
        if [ "$existing_count" -eq 0 ]; then
            DNS_PROVIDER="${DNS_PROVIDER:?DNS_PROVIDER required}"
            DNS_PROVIDER_LIST=("$DNS_PROVIDER")
            DNS_CONFIGURED=true
        fi
        return 0
    fi

    # Interactive mode
    if [ "$existing_count" -gt 0 ]; then
        # Existing providers found - ask if add more
        echo ""
        echo "=== DNS Provider Configuration ==="
        echo ""
        echo "Existing DNS providers:"
        for provider in "${DNS_PROVIDER_LIST[@]}"; do
            echo "  - letsencrypt-${provider}"
        done
        echo ""
        read -p "Add another DNS provider? [y/N]: " add_more

        if [ "$add_more" != "y" ] && [ "$add_more" != "Y" ]; then
            log_info "Using existing DNS providers"
            DNS_PROVIDERS_REUSED=true
            return 0
        fi

        # Continue to add more providers
        local add_another="y"
        local provider_num=$((existing_count + 1))

        while [ "$add_another" = "y" ] || [ "$add_another" = "Y" ]; do
            log_info "Configuring DNS provider #${provider_num}..."
            local provider=$(prompt_dns_provider)
            if [ -z "$provider" ]; then
                continue
            fi
            if [[ " ${DNS_PROVIDER_LIST[@]} " =~ " ${provider} " ]]; then
                log_warn "Provider $provider already configured, skipping..."
                continue
            fi
            prompt_dns_credentials "$provider"
            DNS_PROVIDER_LIST+=("$provider")
            provider_num=$((provider_num + 1))
            echo ""
            read -p "Configure another DNS provider? (y/n): " add_another
        done

        log_info "Total ${#DNS_PROVIDER_LIST[@]} DNS provider(s) configured"
        return 0
    fi

    # No existing providers - show initial prompt
    echo ""
    echo "=== DNS Provider Configuration ==="
    echo ""
    echo "KWO requires at least one DNS provider to issue Let's Encrypt certificates."
    echo "You can configure DNS providers now or skip and configure them later."
    echo ""
    read -p "Configure DNS providers now? [Y/n]: " configure_dns_now

    if [ "$configure_dns_now" = "n" ] || [ "$configure_dns_now" = "N" ]; then
        log_warn "Skipping DNS provider configuration"
        log_warn "Automatic TLS certificates will NOT work until you configure at least one DNS provider."
        echo ""
        echo "To configure DNS providers after installation:"
        echo "  sudo kwo-dns add cloudflare"
        echo "  sudo kwo-dns add ovh --suffix=production"
        echo ""
        DNS_CONFIGURED=false
        return 0
    fi

    # Existing loop logic...
    local add_another="y"
    local provider_num=1

    while [ "$add_another" = "y" ] || [ "$add_another" = "Y" ]; do
        log_info "Configuring DNS provider #${provider_num}..."
        local provider=$(prompt_dns_provider)
        if [ -z "$provider" ]; then
            continue
        fi
        if [[ " ${DNS_PROVIDER_LIST[@]} " =~ " ${provider} " ]]; then
            log_warn "Provider $provider already configured, skipping..."
            continue
        fi
        prompt_dns_credentials "$provider"
        DNS_PROVIDER_LIST+=("$provider")
        provider_num=$((provider_num + 1))
        echo ""
        read -p "Configure another DNS provider? (y/n): " add_another
    done

    if [ ${#DNS_PROVIDER_LIST[@]} -eq 0 ]; then
        log_error "At least one DNS provider is required when not skipping"
        exit 1
    fi

    log_info "Configured ${#DNS_PROVIDER_LIST[@]} DNS provider(s): ${DNS_PROVIDER_LIST[*]}"
    DNS_CONFIGURED=true
}

# Prompt for DNS credentials based on provider
prompt_dns_credentials() {
    local provider="$1"

    echo ""
    echo "=== ${provider} Credentials ==="
    echo ""

    case "$provider" in
        cloudflare)
            echo "Cloudflare requires an API token with DNS edit permissions."
            echo "Create one at: https://dash.cloudflare.com/profile/api-tokens"
            echo ""
            local cf_token
            read -p "Cloudflare API Token: " cf_token
            while [ -z "$cf_token" ]; do
                log_error "API token is required"
                read -p "Cloudflare API Token: " cf_token
            done
            DNS_CREDS["${provider}_CF_DNS_API_TOKEN"]="$cf_token"
            ;;
        ovh)
            echo "OVH requires application credentials."
            echo "Create them at: https://eu.api.ovh.com/createToken/"
            echo ""
            local ovh_endpoint ovh_app_key ovh_app_secret ovh_consumer_key
            read -p "OVH Endpoint (e.g., ovh-eu): " ovh_endpoint
            read -p "OVH Application Key: " ovh_app_key
            read -p "OVH Application Secret: " ovh_app_secret
            read -p "OVH Consumer Key: " ovh_consumer_key
            DNS_CREDS["${provider}_OVH_ENDPOINT"]="$ovh_endpoint"
            DNS_CREDS["${provider}_OVH_APPLICATION_KEY"]="$ovh_app_key"
            DNS_CREDS["${provider}_OVH_APPLICATION_SECRET"]="$ovh_app_secret"
            DNS_CREDS["${provider}_OVH_CONSUMER_KEY"]="$ovh_consumer_key"
            ;;
        route53)
            echo "Route53 requires AWS credentials with DNS permissions."
            echo ""
            local aws_key_id aws_secret_key aws_region
            read -p "AWS Access Key ID: " aws_key_id
            read -p "AWS Secret Access Key: " aws_secret_key
            read -p "AWS Region (e.g., us-east-1): " aws_region
            DNS_CREDS["${provider}_AWS_ACCESS_KEY_ID"]="$aws_key_id"
            DNS_CREDS["${provider}_AWS_SECRET_ACCESS_KEY"]="$aws_secret_key"
            DNS_CREDS["${provider}_AWS_REGION"]="$aws_region"
            ;;
        digitalocean)
            echo "DigitalOcean requires a personal access token."
            echo "Create one at: https://cloud.digitalocean.com/account/api/tokens"
            echo ""
            local do_token
            read -p "DigitalOcean Auth Token: " do_token
            while [ -z "$do_token" ]; do
                log_error "Auth token is required"
                read -p "DigitalOcean Auth Token: " do_token
            done
            DNS_CREDS["${provider}_DO_AUTH_TOKEN"]="$do_token"
            ;;
    esac
}

# Create DNS credentials secret
create_dns_secret() {
    if [ "$DNS_CONFIGURED" = false ]; then
        log_info "Creating empty DNS credentials secret (DNS skipped)"
        kubectl create secret generic dns-credentials -n kube-system \
            --from-literal=placeholder=placeholder \
            --dry-run=client -o yaml | kubectl apply -f -
        return 0
    fi

    # Skip if reusing existing providers (secret already exists)
    if [ "${DNS_PROVIDERS_REUSED:-false}" = "true" ]; then
        log_info "Reusing existing DNS credentials secret"
        return 0
    fi

    log_info "Creating DNS credentials secret for ${#DNS_PROVIDER_LIST[@]} provider(s)..."

    local secret_args=""

    # Build secret arguments from all providers
    for provider in "${DNS_PROVIDER_LIST[@]}"; do
        case "$provider" in
            cloudflare)
                secret_args+=" --from-literal=CF_DNS_API_TOKEN=${DNS_CREDS[${provider}_CF_DNS_API_TOKEN]}"
                ;;
            ovh)
                secret_args+=" --from-literal=OVH_ENDPOINT=${DNS_CREDS[${provider}_OVH_ENDPOINT]}"
                secret_args+=" --from-literal=OVH_APPLICATION_KEY=${DNS_CREDS[${provider}_OVH_APPLICATION_KEY]}"
                secret_args+=" --from-literal=OVH_APPLICATION_SECRET=${DNS_CREDS[${provider}_OVH_APPLICATION_SECRET]}"
                secret_args+=" --from-literal=OVH_CONSUMER_KEY=${DNS_CREDS[${provider}_OVH_CONSUMER_KEY]}"
                ;;
            route53)
                secret_args+=" --from-literal=AWS_ACCESS_KEY_ID=${DNS_CREDS[${provider}_AWS_ACCESS_KEY_ID]}"
                secret_args+=" --from-literal=AWS_SECRET_ACCESS_KEY=${DNS_CREDS[${provider}_AWS_SECRET_ACCESS_KEY]}"
                secret_args+=" --from-literal=AWS_REGION=${DNS_CREDS[${provider}_AWS_REGION]}"
                ;;
            digitalocean)
                secret_args+=" --from-literal=DO_AUTH_TOKEN=${DNS_CREDS[${provider}_DO_AUTH_TOKEN]}"
                ;;
        esac
    done

    # Delete existing secret if present (idempotent)
    kubectl delete secret dns-credentials -n kube-system --ignore-not-found=true

    # Create new secret
    eval kubectl create secret generic dns-credentials -n kube-system $secret_args

    log_info "DNS credentials secret created"
}

# Generate Traefik HelmChartConfig
generate_traefik_config() {
    if [ "$DNS_CONFIGURED" = false ]; then
        log_info "Configuring Traefik without certificate resolvers"

        # Minimal config without cert resolvers
        cat <<EOF | kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    persistence:
      enabled: true
    ports:
      web:
        redirections:
          entryPoint:
            to: websecure
            scheme: https
            permanent: true
      websecure:
        tls:
          enabled: true
EOF
        log_info "Traefik HelmChartConfig applied (no DNS providers)"
        return 0
    fi

    log_info "Configuring Traefik with ${#DNS_PROVIDER_LIST[@]} cert resolver(s)..."

    local additional_args=""
    local env_vars=""

    # Generate cert resolver configuration for each provider
    for provider in "${DNS_PROVIDER_LIST[@]}"; do
        local resolver_name="letsencrypt-${provider}"

        # Add cert resolver arguments
        additional_args+="      - \"--certificatesresolvers.${resolver_name}.acme.email=${ACME_EMAIL}\""$'\n'
        additional_args+="      - \"--certificatesresolvers.${resolver_name}.acme.storage=/data/acme-${provider}.json\""$'\n'
        additional_args+="      - \"--certificatesresolvers.${resolver_name}.acme.dnschallenge=true\""$'\n'
        additional_args+="      - \"--certificatesresolvers.${resolver_name}.acme.dnschallenge.provider=${provider}\""$'\n'
        additional_args+="      - \"--certificatesresolvers.${resolver_name}.acme.dnschallenge.propagation.delayBeforeChecks=10\""$'\n'
        additional_args+="      - \"--certificatesresolvers.${resolver_name}.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53\""$'\n'

        # Add environment variables for credentials
        case "$provider" in
            cloudflare)
                env_vars+='      - name: CF_DNS_API_TOKEN
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: CF_DNS_API_TOKEN'$'\n'
                ;;
            ovh)
                env_vars+='      - name: OVH_ENDPOINT
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: OVH_ENDPOINT
      - name: OVH_APPLICATION_KEY
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: OVH_APPLICATION_KEY
      - name: OVH_APPLICATION_SECRET
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: OVH_APPLICATION_SECRET
      - name: OVH_CONSUMER_KEY
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: OVH_CONSUMER_KEY'$'\n'
                ;;
            route53)
                env_vars+='      - name: AWS_ACCESS_KEY_ID
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: AWS_ACCESS_KEY_ID
      - name: AWS_SECRET_ACCESS_KEY
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: AWS_SECRET_ACCESS_KEY
      - name: AWS_REGION
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: AWS_REGION'$'\n'
                ;;
            digitalocean)
                env_vars+='      - name: DO_AUTH_TOKEN
        valueFrom:
          secretKeyRef:
            name: dns-credentials
            key: DO_AUTH_TOKEN'$'\n'
                ;;
        esac
    done

    cat <<EOF | kubectl apply -f -
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    persistence:
      enabled: true
    additionalArguments:
${additional_args}
    env:
${env_vars}
    ports:
      web:
        redirections:
          entryPoint:
            to: websecure
            scheme: https
            permanent: true
      websecure:
        tls:
          enabled: true
EOF

    log_info "Traefik HelmChartConfig applied with resolvers: ${DNS_PROVIDER_LIST[*]}"
}

# Wait for Traefik to restart
wait_for_traefik() {
    log_info "Waiting for Traefik to restart with new configuration..."

    # Delete Traefik pod to force restart with new config
    kubectl delete pod -n kube-system -l app.kubernetes.io/name=traefik --ignore-not-found=true

    sleep 5

    local max_attempts=30
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if kubectl get pod -n kube-system -l app.kubernetes.io/name=traefik | grep -q "Running"; then
            log_info "Traefik is running with new configuration"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done

    log_warn "Traefik may still be starting. Check with: kubectl get pods -n kube-system"
}

# Save cluster configuration
save_cluster_config() {
    log_info "Saving cluster configuration..."

    local api_server="https://${API_DOMAIN}:6443"
    if [ -z "${API_DOMAIN:-}" ]; then
        local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
        api_server="https://${node_ip}:6443"
    fi

    local dns_providers_list="${DNS_PROVIDER_LIST[*]}"

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: kwo-config
  namespace: kube-system
data:
  api-server: "$api_server"
  api-domain: "${API_DOMAIN:-}"
  acme-email: "$ACME_EMAIL"
  dns-providers: "$dns_providers_list"
  dns-management-version: "v2"
  dns-configured: "$DNS_CONFIGURED"
EOF

    log_info "Cluster configuration saved to kube-system/kwo-config"

    # Save initial DNS metadata if configured
    if [ "$DNS_CONFIGURED" = true ]; then
        save_initial_dns_metadata
    fi
}

# Save initial DNS provider metadata
save_initial_dns_metadata() {
    log_info "Saving DNS provider metadata..."

    local metadata_json="{"
    local first=true

    for provider in "${DNS_PROVIDER_LIST[@]}"; do
        local resolver_name="letsencrypt-${provider}"
        local created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local kwo_version="1.2.0"

        local credentials_json=$(case "$provider" in
            cloudflare) echo '["CF_DNS_API_TOKEN"]' ;;
            ovh) echo '["OVH_ENDPOINT","OVH_APPLICATION_KEY","OVH_APPLICATION_SECRET","OVH_CONSUMER_KEY"]' ;;
            route53) echo '["AWS_ACCESS_KEY_ID","AWS_SECRET_ACCESS_KEY","AWS_REGION"]' ;;
            digitalocean) echo '["DO_AUTH_TOKEN"]' ;;
        esac)

        [ "$first" = false ] && metadata_json+=","
        first=false

        metadata_json+="\"$resolver_name\":{\"provider\":\"$provider\",\"suffix\":\"\",\"credentials\":$credentials_json,\"createdAt\":\"$created_at\",\"lastModified\":\"$created_at\",\"createdBy\":\"$(whoami)\",\"kwoVersion\":\"$kwo_version\"}"
    done

    metadata_json+="}"

    kubectl create configmap kwo-dns-providers -n kube-system \
        --from-literal=providers.json="$metadata_json" \
        --dry-run=client -o yaml | kubectl apply -f -

    log_info "DNS metadata saved to kube-system/kwo-dns-providers"
}

# Install KWO system files and commands
install_kwo_system() {
    log_info "Installing KWO system files..."

    local KWO_VERSION="1.2.0"
    local INSTALL_ROOT="/usr/share/kwo"
    local STATE_ROOT="/var/lib/kwo"
    local LOG_ROOT="/var/log/kwo"
    local BIN_DIR="/usr/local/bin"
    local REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # 1. Crea struttura directory
    mkdir -p "$INSTALL_ROOT/bin/lib" "$STATE_ROOT/kubeconfigs" \
             "$STATE_ROOT/metadata" "$STATE_ROOT/archive" "$LOG_ROOT"

    # 2. Imposta permessi base
    chown -R root:root "$INSTALL_ROOT" "$STATE_ROOT" "$LOG_ROOT"
    chmod 755 "$INSTALL_ROOT" "$STATE_ROOT" "$LOG_ROOT"
    chmod 700 "$STATE_ROOT/archive" "$STATE_ROOT/kubeconfigs"

    # 3. Installa/aggiorna script con checksum
    if [ -d "$REPO_DIR/bin" ]; then
        for script in "$REPO_DIR/bin"/*.sh; do
            [ -f "$script" ] && install_or_update_script "$script" "$INSTALL_ROOT/bin/$(basename "$script")"
        done
        # Install lib directory
        if [ -d "$REPO_DIR/bin/lib" ]; then
            for libscript in "$REPO_DIR/bin/lib"/*.sh; do
                [ -f "$libscript" ] && install_or_update_script "$libscript" "$INSTALL_ROOT/bin/lib/$(basename "$libscript")"
            done
        fi
    fi

    # 4. Scrivi versione
    echo "$KWO_VERSION" > "$INSTALL_ROOT/VERSION"

    # 5. Crea symlink comandi
    create_command_symlinks

    # 6. Inizializza log
    touch "$STATE_ROOT/install.log" "$LOG_ROOT/tenant-operations.log" "$LOG_ROOT/diagnostics.log"
    chmod 640 "$STATE_ROOT/install.log" "$LOG_ROOT/tenant-operations.log" "$LOG_ROOT/diagnostics.log"

    # 7. Log installazione
    echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] install version=$KWO_VERSION user=$(whoami)" >> "$STATE_ROOT/install.log"

    log_info "KWO system installation complete"
}

# Install or update a single script with checksum comparison
install_or_update_script() {
    local source="$1"
    local target="$2"
    local script_name=$(basename "$source")

    if [ -f "$target" ]; then
        local old_hash=$(sha256sum "$target" | cut -d' ' -f1)
        local new_hash=$(sha256sum "$source" | cut -d' ' -f1)

        if [ "$old_hash" != "$new_hash" ]; then
            log_warn "Script $script_name has changed"
            command -v diff &>/dev/null && diff -u "$target" "$source" || true

            local update="y"
            [ "${NON_INTERACTIVE:-false}" != "true" ] && read -p "Update $script_name? [y/N]: " update

            if [ "$update" = "y" ] || [ "$update" = "Y" ]; then
                cp "$source" "$target" && chmod 755 "$target"
                log_info "Updated $script_name"
            else
                log_warn "Skipped update of $script_name"
            fi
        fi
    else
        cp "$source" "$target" && chmod 755 "$target"
        log_info "Installed $script_name"
    fi
}

# Create command symlinks in /usr/local/bin
create_command_symlinks() {
    local BIN_DIR="/usr/local/bin"
    local INSTALL_ROOT="/usr/share/kwo"

    declare -A COMMANDS=(
        ["create-tenant.sh"]="kwo-create-tenant"
        ["delete-tenant.sh"]="kwo-delete-tenant"
        ["list-tenants.sh"]="kwo-list-tenants"
        ["update-tenant.sh"]="kwo-update-tenant"
        ["status.sh"]="kwo-status"
        ["dns.sh"]="kwo-dns"
        ["check-tls.sh"]="kwo-check-tls"
        ["logs.sh"]="kwo-logs"
        ["registry.sh"]="kwo-registry"
    )

    for script in "${!COMMANDS[@]}"; do
        local source="$INSTALL_ROOT/bin/$script"
        local link="$BIN_DIR/${COMMANDS[$script]}"
        [ -f "$source" ] && { rm -f "$link"; ln -s "$source" "$link"; log_info "Created command: ${COMMANDS[$script]}"; }
    done
}

# =============================================================================
# REGISTRY CONFIGURATION FUNCTIONS
# =============================================================================

# Select DNS provider for registry certificate resolver
# Returns: resolver name (e.g., "letsencrypt-cloudflare")
select_dns_provider_for_registry() {
    local existing_resolver="${1:-}"

    # Count providers from DNS_PROVIDER_LIST
    local dns_count=${#DNS_PROVIDER_LIST[@]}

    if [ "$dns_count" -eq 0 ]; then
        log_error "No DNS providers configured"
        return 1
    elif [ "$dns_count" -eq 1 ]; then
        # Auto-select single provider
        local resolver="letsencrypt-${DNS_PROVIDER_LIST[0]}"
        log_info "Auto-selected DNS provider: $resolver" >&2
        echo "$resolver"
        return 0
    else
        # Multiple providers - interactive selection
        echo ""
        echo "Multiple DNS providers available:"
        echo ""

        local i=1
        declare -A resolver_map

        for provider in "${DNS_PROVIDER_LIST[@]}"; do
            local resolver="letsencrypt-${provider}"
            echo "$i) $resolver"
            resolver_map[$i]="$resolver"
            i=$((i + 1))
        done

        echo ""

        if [ -n "$existing_resolver" ]; then
            echo "Current selection: $existing_resolver"
            read -p "Keep current selection? [Y/n]: " keep_current

            if [ "$keep_current" != "n" ] && [ "$keep_current" != "N" ]; then
                echo "$existing_resolver"
                return 0
            fi
        fi

        read -p "Select DNS provider [1-$((i-1))]: " choice

        while [ -z "${resolver_map[$choice]:-}" ]; do
            log_error "Invalid choice"
            read -p "Select DNS provider [1-$((i-1))]: " choice
        done

        echo "${resolver_map[$choice]}"
        return 0
    fi
}

# Deploy registry Kubernetes resources
deploy_registry_resources() {
    log_info "Deploying registry resources..."

    # 1. Create registry-auth Secret
    log_info "[1/5] Creating registry-auth Secret..."
    kubectl create secret generic registry-auth -n kube-system \
        --from-literal=htpasswd="$REGISTRY_HTPASSWD" \
        --from-literal=username="$REGISTRY_USERNAME" \
        --from-literal=password="$REGISTRY_PASSWORD" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    # 2. Create PersistentVolumeClaim
    log_info "[2/5] Creating registry PVC (50Gi)..."
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-storage
  namespace: kube-system
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
  storageClassName: local-path
EOF

    # Note: PVC will bind when the registry pod is created (WaitForFirstConsumer)

    # 3. Create Deployment
    log_info "[3/5] Creating registry Deployment..."
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: registry
  namespace: kube-system
  labels:
    app: registry
    managed-by: kwo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: registry
  template:
    metadata:
      labels:
        app: registry
    spec:
      containers:
        - name: registry
          image: registry:2
          ports:
            - name: http
              containerPort: 5000
          env:
            - name: REGISTRY_AUTH
              value: "htpasswd"
            - name: REGISTRY_AUTH_HTPASSWD_REALM
              value: "Registry Realm"
            - name: REGISTRY_AUTH_HTPASSWD_PATH
              value: "/auth/htpasswd"
            - name: REGISTRY_STORAGE_FILESYSTEM_ROOTDIRECTORY
              value: "/var/lib/registry"
          volumeMounts:
            - name: registry-storage
              mountPath: /var/lib/registry
            - name: auth
              mountPath: /auth
              readOnly: true
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "512Mi"
              cpu: "500m"
          livenessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
      volumes:
        - name: registry-storage
          persistentVolumeClaim:
            claimName: registry-storage
        - name: auth
          secret:
            secretName: registry-auth
            items:
              - key: htpasswd
                path: htpasswd
EOF

    # 4. Create Service
    log_info "[4/5] Creating registry Service..."
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Service
metadata:
  name: registry
  namespace: kube-system
  labels:
    app: registry
spec:
  type: ClusterIP
  selector:
    app: registry
  ports:
    - port: 5000
      targetPort: http
      protocol: TCP
      name: http
EOF

    # 5. Create Ingress
    log_info "[5/5] Creating registry Ingress with TLS..."

    # Debug: verify variables are set
    if [ -z "$REGISTRY_DOMAIN" ] || [ -z "$REGISTRY_CERT_RESOLVER" ]; then
        log_error "Missing required variables:"
        log_error "  REGISTRY_DOMAIN='$REGISTRY_DOMAIN'"
        log_error "  REGISTRY_CERT_RESOLVER='$REGISTRY_CERT_RESOLVER'"
        exit 1
    fi

    cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: registry
  namespace: kube-system
  labels:
    app: registry
    managed-by: kwo
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
    traefik.ingress.kubernetes.io/router.tls: "true"
    traefik.ingress.kubernetes.io/router.tls.certresolver: $REGISTRY_CERT_RESOLVER
spec:
  rules:
    - host: $REGISTRY_DOMAIN
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: registry
                port:
                  number: 5000
  tls:
    - hosts:
        - $REGISTRY_DOMAIN
EOF

    log_info "Registry resources deployed successfully"

    # Wait for registry pod to be ready
    log_info "Waiting for registry pod to be ready..."
    local max_wait=60
    local count=0
    while [ $count -lt $max_wait ]; do
        local pod_ready=$(kubectl get pods -n kube-system -l app=registry \
            -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")

        if [ "$pod_ready" = "True" ]; then
            log_info "Registry pod is ready"
            break
        fi

        sleep 2
        count=$((count + 1))
    done

    if [ $count -eq $max_wait ]; then
        log_warn "Registry pod did not become ready within expected time"
        log_warn "Check status with: kubectl get pods -n kube-system -l app=registry"
    fi
}

# Configure k3s to use private registry globally
configure_k3s_registry() {
    log_info "Configuring k3s registry integration..."

    local registries_file="/etc/rancher/k3s/registries.yaml"
    local registries_dir="/etc/rancher/k3s"

    # Create directory if it doesn't exist
    mkdir -p "$registries_dir"

    # Archive existing file if present
    if [ -f "$registries_file" ]; then
        local timestamp=$(date +%Y%m%d-%H%M%S)
        local archive_dir="/var/lib/kwo/archive"
        mkdir -p "$archive_dir"
        cp "$registries_file" "$archive_dir/registries-${timestamp}.yaml"
        chmod 600 "$archive_dir/registries-${timestamp}.yaml"
        log_info "Archived existing registries.yaml"
    fi

    # Write new registries.yaml
    cat > "$registries_file" <<EOF
# KWO Private Registry Configuration
# Auto-generated by KWO install.sh
# Last updated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

configs:
  "$REGISTRY_DOMAIN":
    auth:
      username: $REGISTRY_USERNAME
      password: $REGISTRY_PASSWORD
    tls:
      insecure_skip_verify: false
EOF

    chmod 600 "$registries_file"
    log_info "Written /etc/rancher/k3s/registries.yaml"

    # Restart k3s to apply changes
    log_info "Restarting k3s to apply registry configuration..."
    if ! systemctl restart k3s; then
        log_error "Failed to restart k3s"
        log_error "Check: systemctl status k3s"
        log_error "Config: /etc/rancher/k3s/registries.yaml"
        exit 1
    fi

    # Wait for k3s to be ready
    wait_for_k3s

    log_info "k3s restarted with registry configuration"
}

# Save registry configuration to kwo-config ConfigMap
save_registry_config() {
    log_info "Saving registry configuration to kwo-config..."

    local created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Update ConfigMap with registry fields
    kubectl patch configmap kwo-config -n kube-system --type=merge -p "{\"data\":{\"registry-enabled\":\"true\",\"registry-domain\":\"$REGISTRY_DOMAIN\",\"registry-username\":\"$REGISTRY_USERNAME\",\"registry-certresolver\":\"$REGISTRY_CERT_RESOLVER\",\"registry-created-at\":\"$created_at\"}}" >/dev/null

    log_info "Registry configuration saved"
}

# Print registry credentials and usage instructions
print_registry_credentials() {
    echo ""
    echo "========================================="
    echo "  Private Registry Configured"
    echo "========================================="
    echo ""
    echo "Registry URL: https://$REGISTRY_DOMAIN"
    echo "Username: $REGISTRY_USERNAME"
    echo "Password: $REGISTRY_PASSWORD"
    echo ""
    log_warn "IMPORTANT: Save these credentials securely!"
    echo ""
    echo "Usage:"
    echo ""
    echo "1. Login to registry from external machine:"
    echo "   docker login $REGISTRY_DOMAIN"
    echo "   # Enter username and password when prompted"
    echo ""
    echo "2. Push image:"
    echo "   docker tag myapp:latest $REGISTRY_DOMAIN/myapp:latest"
    echo "   docker push $REGISTRY_DOMAIN/myapp:latest"
    echo ""
    echo "3. Deploy in tenant (automatic pull, no imagePullSecrets needed):"
    echo "   kubectl apply -f - <<EOF"
    echo "   apiVersion: apps/v1"
    echo "   kind: Deployment"
    echo "   metadata:"
    echo "     name: myapp"
    echo "   spec:"
    echo "     template:"
    echo "       spec:"
    echo "         containers:"
    echo "           - name: myapp"
    echo "             image: $REGISTRY_DOMAIN/myapp:latest"
    echo "   EOF"
    echo ""
    echo "Configuration:"
    echo "  - Storage: 50Gi PVC (local-path)"
    echo "  - TLS: Automatic via $REGISTRY_CERT_RESOLVER"
    echo "  - Auth: htpasswd (bcrypt)"
    echo "  - k3s integration: /etc/rancher/k3s/registries.yaml"
    echo ""
    echo "Management commands:"
    echo "  kwo-registry status              # Check registry status"
    echo "  kwo-registry rotate-credentials  # Rotate password"
    echo "  kwo-registry get-credentials     # Display credentials"
    echo ""
}

# Configure private Docker registry
# Called after: configure_dns_providers
# Called before: generate_traefik_config
configure_registry() {
    # Check DNS provider count
    local dns_count=${#DNS_PROVIDER_LIST[@]}

    if [ "$dns_count" -eq 0 ]; then
        if [ "${NON_INTERACTIVE:-false}" = "true" ] && [ "${REGISTRY_SKIP:-false}" != "true" ]; then
            log_error "Cannot configure registry: No DNS providers configured"
            log_error "Registry requires DNS provider for automatic TLS certificates"
            exit 1
        fi
        log_warn "No DNS providers configured - skipping registry setup"
        log_warn "Configure DNS providers first with: sudo kwo-dns add <provider>"
        return 0
    fi

    # Check for existing configuration
    local existing_domain=""
    local existing_username=""
    local existing_resolver=""

    if kubectl get configmap kwo-config -n kube-system &>/dev/null; then
        existing_domain=$(kubectl get configmap kwo-config -n kube-system \
            -o jsonpath='{.data.registry-domain}' 2>/dev/null || echo "")
        existing_username=$(kubectl get configmap kwo-config -n kube-system \
            -o jsonpath='{.data.registry-username}' 2>/dev/null || echo "")
        existing_resolver=$(kubectl get configmap kwo-config -n kube-system \
            -o jsonpath='{.data.registry-certresolver}' 2>/dev/null || echo "")
    fi

    # Interactive mode
    if [ "${NON_INTERACTIVE:-false}" != "true" ]; then
        echo ""
        echo "=== Private Docker Registry Configuration ==="
        echo ""
        echo "KWO can deploy a private Docker registry for your tenants."
        echo "Features:"
        echo "  - Automatic TLS via Traefik"
        echo "  - htpasswd authentication"
        echo "  - Global k3s integration (all tenants can pull)"
        echo "  - 50Gi persistent storage"
        echo ""

        read -p "Configure private registry now? [Y/n]: " configure_registry_now

        if [ "$configure_registry_now" = "n" ] || [ "$configure_registry_now" = "N" ]; then
            log_info "Skipping registry configuration"
            return 0
        fi

        # Prompt for registry domain
        if [ -n "$existing_domain" ]; then
            echo ""
            echo "Current registry domain: $existing_domain"
            read -p "Update domain? [y/N]: " update_domain

            if [ "$update_domain" = "y" ] || [ "$update_domain" = "Y" ]; then
                read -p "Registry domain (e.g., registry.example.com): " REGISTRY_DOMAIN
                # Validate domain
                while ! validate_domain "$REGISTRY_DOMAIN"; do
                    log_error "Invalid domain format (must be valid FQDN)"
                    read -p "Registry domain: " REGISTRY_DOMAIN
                done
            else
                REGISTRY_DOMAIN="$existing_domain"
            fi
        else
            read -p "Registry domain (e.g., registry.example.com): " REGISTRY_DOMAIN
            # Validate domain
            while ! validate_domain "$REGISTRY_DOMAIN"; do
                log_error "Invalid domain format (must be valid FQDN)"
                read -p "Registry domain: " REGISTRY_DOMAIN
            done
        fi

        # Select DNS provider for cert resolver
        if [ -n "$existing_resolver" ]; then
            REGISTRY_CERT_RESOLVER=$(select_dns_provider_for_registry "$existing_resolver")
        else
            REGISTRY_CERT_RESOLVER=$(select_dns_provider_for_registry "")
        fi

        # Prompt for username
        if [ -n "$existing_username" ]; then
            echo ""
            echo "Current registry username: $existing_username"
            read -p "Update username? [y/N]: " update_username

            if [ "$update_username" = "y" ] || [ "$update_username" = "Y" ]; then
                read -p "Registry username [docker]: " REGISTRY_USERNAME
                REGISTRY_USERNAME="${REGISTRY_USERNAME:-docker}"
            else
                REGISTRY_USERNAME="$existing_username"
            fi
        else
            read -p "Registry username [docker]: " REGISTRY_USERNAME
            REGISTRY_USERNAME="${REGISTRY_USERNAME:-docker}"
        fi

        # Check for existing credentials
        if kubectl get secret registry-auth -n kube-system &>/dev/null; then
            echo ""
            log_warn "Registry credentials already exist"
            read -p "Regenerate password? [y/N]: " regenerate_password

            if [ "$regenerate_password" = "y" ] || [ "$regenerate_password" = "Y" ]; then
                REGENERATE_CREDS=true
            else
                REGENERATE_CREDS=false
            fi
        else
            REGENERATE_CREDS=true
        fi
    else
        # Non-interactive mode
        if [ "${REGISTRY_SKIP:-false}" = "true" ]; then
            log_info "Skipping registry configuration (REGISTRY_SKIP=true)"
            return 0
        fi

        REGISTRY_DOMAIN="${REGISTRY_DOMAIN:?REGISTRY_DOMAIN required in non-interactive mode}"
        REGISTRY_USERNAME="${REGISTRY_USERNAME:-docker}"

        # Auto-select DNS provider
        if [ "$dns_count" -eq 1 ]; then
            REGISTRY_CERT_RESOLVER="letsencrypt-${DNS_PROVIDER_LIST[0]}"
        else
            REGISTRY_CERT_RESOLVER="${REGISTRY_CERT_RESOLVER:?REGISTRY_CERT_RESOLVER required when multiple DNS providers exist}"
        fi

        # Validate domain
        if ! validate_domain "$REGISTRY_DOMAIN"; then
            log_error "Invalid REGISTRY_DOMAIN format: $REGISTRY_DOMAIN"
            exit 1
        fi

        REGENERATE_CREDS=true
    fi

    # Generate or retrieve credentials
    if [ "$REGENERATE_CREDS" = true ]; then
        log_info "Generating new registry credentials..."

        # Archive old credentials if they exist
        if kubectl get secret registry-auth -n kube-system &>/dev/null; then
            local timestamp=$(date +%Y%m%d-%H%M%S)
            local archive_dir="/var/lib/kwo/archive/registry-regenerate-${timestamp}"
            mkdir -p "$archive_dir"
            chmod 700 "$archive_dir"

            kubectl get secret registry-auth -n kube-system -o yaml > "$archive_dir/registry-auth-secret.yaml"
            [ -f /etc/rancher/k3s/registries.yaml ] && cp /etc/rancher/k3s/registries.yaml "$archive_dir/registries.yaml"
            chmod 600 "$archive_dir"/*

            log_info "Archived old credentials to $archive_dir"
        fi

        # Generate random password (32 chars, base64 safe)
        REGISTRY_PASSWORD=$(generate_password)

        # Create htpasswd hash (bcrypt)
        REGISTRY_HTPASSWD=$(hash_password_bcrypt "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD")

    else
        log_info "Reusing existing registry credentials..."

        # Extract existing password from secret
        REGISTRY_HTPASSWD=$(kubectl get secret registry-auth -n kube-system \
            -o jsonpath='{.data.htpasswd}' | base64 -d)

        REGISTRY_PASSWORD=$(kubectl get secret registry-auth -n kube-system \
            -o jsonpath='{.data.password}' | base64 -d)
    fi

    # Deploy registry resources
    deploy_registry_resources

    # Configure k3s registries.yaml
    configure_k3s_registry

    # Update kwo-config ConfigMap
    save_registry_config

    # Print credentials to user
    print_registry_credentials

    # Mark registry as configured
    REGISTRY_CONFIGURED=true
}

# Print next steps
print_next_steps() {
    local node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

    echo ""
    echo "========================================="
    echo "  K3S Web Orchestrator Setup Complete"
    echo "========================================="
    echo ""
    log_info "k3s is running with Traefik configured for automatic TLS"
    echo ""
    echo "Cluster Information:"
    echo "  - Node IP: $node_ip"
    if [ -n "${API_DOMAIN:-}" ]; then
        echo "  - API Server: https://${API_DOMAIN}:6443"
        echo "  - Hostname: $API_DOMAIN"
    else
        echo "  - API Server: https://${node_ip}:6443"
    fi
    echo "  - Kubeconfig: $KUBECONFIG"
    echo "  - ACME Email: $ACME_EMAIL"
    echo ""
    echo "Certificate Resolvers:"
    if [ "$DNS_CONFIGURED" = false ]; then
        echo "  ⚠ No DNS providers configured"
        echo "  Automatic TLS certificates will NOT work until you configure DNS providers"
        echo ""
        echo "  To configure DNS providers:"
        echo "    sudo kwo-dns add cloudflare"
        echo "    sudo kwo-dns add ovh --suffix=production"
        echo ""
    else
        echo "  (${#DNS_PROVIDER_LIST[@]} configured):"
        for provider in "${DNS_PROVIDER_LIST[@]}"; do
            echo "  - letsencrypt-${provider}"
        done
        echo ""
        echo "  To add more DNS providers:"
        echo "    sudo kwo-dns add <provider> [--suffix=<name>]"
        echo "    sudo kwo-dns list"
        echo ""
    fi
    echo "Next Steps:"
    echo ""
    echo "1. Create your first tenant:"
    echo "   kwo-create-tenant mytenant"
    echo "   # Kubeconfig will be in: /var/lib/kwo/kubeconfigs/mytenant-kubeconfig.yaml"
    echo ""
    echo "2. List tenants:"
    echo "   kwo-list-tenants"
    echo ""
    echo "3. Check cluster status:"
    echo "   kwo-status"
    echo ""
    echo "4. Deploy an application:"
    echo "   kubectl apply -f examples/app.yaml"
    if [ "$DNS_CONFIGURED" = false ]; then
        echo "   # Note: Configure DNS providers first for automatic TLS certificates"
    else
        echo "   # Edit the Ingress annotation to choose cert resolver:"
        if [ ${#DNS_PROVIDER_LIST[@]} -gt 1 ]; then
            echo "   # Available: ${DNS_PROVIDER_LIST[*]}"
            echo "   # traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt-${DNS_PROVIDER_LIST[0]}"
        else
            echo "   # traefik.ingress.kubernetes.io/router.tls.certresolver: letsencrypt-${DNS_PROVIDER_LIST[0]}"
        fi
    fi
    echo ""
    echo "3. View Traefik logs:"
    echo "   kubectl logs -n kube-system -l app.kubernetes.io/name=traefik"
    echo ""
    echo "Documentation: https://github.com/marcochiodo/k3s-web-orchestrator"
    echo ""
}

# Main installation flow
main() {
    log_info "Starting K3S Web Orchestrator installation (v${SCRIPT_VERSION})"

    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        log_error "Please run as root (use sudo)"
        exit 1
    fi

    detect_os
    install_prerequisites
    prompt_config
    configure_hostname
    install_k3s
    wait_for_k3s
    configure_dns_providers
    create_dns_secret
    configure_registry
    generate_traefik_config
    wait_for_traefik
    save_cluster_config
    install_kwo_system
    print_next_steps

    log_info "Installation complete!"
}

main "$@"
