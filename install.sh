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
            apt-get install -y -qq curl iptables jq
            ;;
        dnf)
            dnf install -y -q curl iptables jq
            ;;
    esac
}

# Configure system hostname
configure_hostname() {
    if [ -z "${API_DOMAIN:-}" ]; then
        log_warn "No API domain configured, skipping hostname setup"
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
    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        log_info "Running in non-interactive mode"
        ACME_EMAIL="${ACME_EMAIL:?ACME_EMAIL environment variable is required - needed for Let\'s Encrypt}"
        API_DOMAIN="${API_DOMAIN:-}"
        return 0
    fi

    echo ""
    echo "=== K3S Web Orchestrator Configuration ==="
    echo ""

    # Let's Encrypt email
    echo "Let's Encrypt requires an email for certificate notifications."
    echo "This is required even if you skip DNS configuration now."
    read -p "Enter email for Let's Encrypt: " ACME_EMAIL
    while [ -z "$ACME_EMAIL" ]; do
        log_error "Email is required"
        read -p "Enter email for Let's Encrypt: " ACME_EMAIL
    done

    # API hostname (recommended for production)
    echo ""
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

    if [ "${NON_INTERACTIVE:-false}" = "true" ]; then
        if [ "${DNS_SKIP:-false}" = "true" ]; then
            log_warn "Skipping DNS provider configuration (DNS_SKIP=true)"
            DNS_CONFIGURED=false
            return 0
        fi
        DNS_PROVIDER="${DNS_PROVIDER:?DNS_PROVIDER required}"
        DNS_PROVIDER_LIST=("$DNS_PROVIDER")
        DNS_CONFIGURED=true
        return 0
    fi

    # Interactive mode - ask if configure now
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
    )

    for script in "${!COMMANDS[@]}"; do
        local source="$INSTALL_ROOT/bin/$script"
        local link="$BIN_DIR/${COMMANDS[$script]}"
        [ -f "$source" ] && { rm -f "$link"; ln -s "$source" "$link"; log_info "Created command: ${COMMANDS[$script]}"; }
    done
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
    generate_traefik_config
    wait_for_traefik
    save_cluster_config
    install_kwo_system
    print_next_steps

    log_info "Installation complete!"
}

main "$@"
