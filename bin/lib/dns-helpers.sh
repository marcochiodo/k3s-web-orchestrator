#!/usr/bin/env bash
# DNS Management Helper Functions for KWO
# Shared library for DNS provider management

set -euo pipefail

# ============================================================================
# PROVIDER REGISTRY
# ============================================================================

# Get list of supported DNS providers
get_supported_providers() {
    echo "cloudflare ovh route53 digitalocean"
}

# Validate provider name
# Usage: validate_provider_name <provider>
# Returns: 0 if valid, 1 if invalid
validate_provider_name() {
    local provider="$1"
    local supported
    supported=$(get_supported_providers)

    if [[ " $supported " =~ " $provider " ]]; then
        return 0
    else
        return 1
    fi
}

# Get required credential environment variables for a provider
# Usage: get_provider_credentials <provider>
# Returns: space-separated list of env var names
get_provider_credentials() {
    local provider="$1"

    case "$provider" in
        cloudflare)
            echo "CF_DNS_API_TOKEN"
            ;;
        ovh)
            echo "OVH_ENDPOINT OVH_APPLICATION_KEY OVH_APPLICATION_SECRET OVH_CONSUMER_KEY"
            ;;
        route53)
            echo "AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_REGION"
            ;;
        digitalocean)
            echo "DO_AUTH_TOKEN"
            ;;
        *)
            log_error "Unknown provider: $provider"
            return 1
            ;;
    esac
}

# Get provider display name and documentation URL
# Usage: get_provider_info <provider>
# Returns: JSON with name and docs_url
get_provider_info() {
    local provider="$1"

    case "$provider" in
        cloudflare)
            echo '{"name":"Cloudflare","docs":"https://go-acme.github.io/lego/dns/cloudflare/"}'
            ;;
        ovh)
            echo '{"name":"OVH","docs":"https://go-acme.github.io/lego/dns/ovh/"}'
            ;;
        route53)
            echo '{"name":"AWS Route53","docs":"https://go-acme.github.io/lego/dns/route53/"}'
            ;;
        digitalocean)
            echo '{"name":"DigitalOcean","docs":"https://go-acme.github.io/lego/dns/digitalocean/"}'
            ;;
        *)
            echo '{"name":"Unknown","docs":""}'
            ;;
    esac
}

# ============================================================================
# RESOLVER NAMES
# ============================================================================

# Generate resolver name from provider and optional suffix
# Usage: generate_resolver_name <provider> [suffix]
# Returns: letsencrypt-{provider}[-{suffix}]
generate_resolver_name() {
    local provider="$1"
    local suffix="${2:-}"

    if [ -n "$suffix" ]; then
        echo "letsencrypt-${provider}-${suffix}"
    else
        echo "letsencrypt-${provider}"
    fi
}

# Extract provider name from resolver name
# Usage: extract_provider_from_resolver <resolver-name>
# Returns: provider name
extract_provider_from_resolver() {
    local resolver="$1"

    # Remove letsencrypt- prefix
    local rest="${resolver#letsencrypt-}"

    # Extract provider (first part before optional suffix)
    for provider in $(get_supported_providers); do
        if [[ "$rest" == "$provider" ]] || [[ "$rest" == "$provider-"* ]]; then
            echo "$provider"
            return 0
        fi
    done

    log_error "Cannot extract provider from resolver: $resolver"
    return 1
}

# Validate suffix format (lowercase alphanumeric + hyphens, no start/end hyphen)
# Usage: validate_suffix <suffix>
# Returns: 0 if valid, 1 if invalid
validate_suffix() {
    local suffix="$1"

    if [[ "$suffix" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        return 0
    else
        return 1
    fi
}

# Validate full resolver name format
# Usage: validate_resolver_name <resolver-name>
# Returns: 0 if valid, 1 if invalid
validate_resolver_name() {
    local resolver="$1"

    if [[ "$resolver" =~ ^letsencrypt-(cloudflare|ovh|route53|digitalocean)(-[a-z0-9]([a-z0-9-]*[a-z0-9])?)?$ ]]; then
        return 0
    else
        return 1
    fi
}

# ============================================================================
# METADATA MANAGEMENT
# ============================================================================

# Check if DNS metadata ConfigMap exists, create if not
ensure_dns_metadata_exists() {
    if ! kubectl get configmap kwo-dns-providers -n kube-system &>/dev/null; then
        log_info "Creating kwo-dns-providers ConfigMap"
        kubectl create configmap kwo-dns-providers -n kube-system \
            --from-literal=providers.json='{}' \
            --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    fi
}

# Check if a resolver exists
# Usage: check_resolver_exists <resolver-name>
# Returns: 0 if exists, 1 if not
check_resolver_exists() {
    local resolver="$1"

    ensure_dns_metadata_exists

    local metadata
    metadata=$(kubectl get configmap kwo-dns-providers -n kube-system -o jsonpath='{.data.providers\.json}' 2>/dev/null || echo '{}')

    if echo "$metadata" | jq -e "has(\"$resolver\")" >/dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Get metadata for a specific resolver
# Usage: get_resolver_metadata <resolver-name>
# Returns: JSON metadata object
get_resolver_metadata() {
    local resolver="$1"

    ensure_dns_metadata_exists

    local metadata
    metadata=$(kubectl get configmap kwo-dns-providers -n kube-system -o jsonpath='{.data.providers\.json}' 2>/dev/null || echo '{}')

    echo "$metadata" | jq -r ".\"$resolver\" // {}"
}

# Get all resolvers metadata
# Usage: get_all_resolvers
# Returns: JSON object with all resolvers
get_all_resolvers() {
    ensure_dns_metadata_exists

    kubectl get configmap kwo-dns-providers -n kube-system -o jsonpath='{.data.providers\.json}' 2>/dev/null || echo '{}'
}

# Count total number of DNS providers
# Usage: count_providers
# Returns: integer count
count_providers() {
    local metadata
    metadata=$(get_all_resolvers)

    echo "$metadata" | jq 'length'
}

# Save DNS metadata for a resolver
# Usage: save_dns_metadata <resolver-name> <provider> <suffix> <credentials-array-json>
save_dns_metadata() {
    local resolver="$1"
    local provider="$2"
    local suffix="$3"
    local credentials_json="$4"
    local created_at
    created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local created_by
    created_by=$(whoami)
    local kwo_version="1.2.0"

    ensure_dns_metadata_exists

    # Read current metadata
    local current_metadata
    current_metadata=$(get_all_resolvers)

    # Add new resolver
    local new_metadata
    new_metadata=$(echo "$current_metadata" | jq \
        --arg resolver "$resolver" \
        --arg provider "$provider" \
        --arg suffix "$suffix" \
        --argjson credentials "$credentials_json" \
        --arg created_at "$created_at" \
        --arg created_by "$created_by" \
        --arg kwo_version "$kwo_version" \
        '.[$resolver] = {
            "provider": $provider,
            "suffix": $suffix,
            "credentials": $credentials,
            "createdAt": $created_at,
            "lastModified": $created_at,
            "createdBy": $created_by,
            "kwoVersion": $kwo_version
        }')

    # Update ConfigMap
    kubectl create configmap kwo-dns-providers -n kube-system \
        --from-literal=providers.json="$new_metadata" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Remove DNS metadata for a resolver
# Usage: remove_dns_metadata <resolver-name>
remove_dns_metadata() {
    local resolver="$1"

    ensure_dns_metadata_exists

    # Read current metadata
    local current_metadata
    current_metadata=$(get_all_resolvers)

    # Remove resolver
    local new_metadata
    new_metadata=$(echo "$current_metadata" | jq "del(.\"$resolver\")")

    # Update ConfigMap
    kubectl create configmap kwo-dns-providers -n kube-system \
        --from-literal=providers.json="$new_metadata" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# Update lastModified timestamp for a resolver
# Usage: update_metadata_timestamp <resolver-name>
update_metadata_timestamp() {
    local resolver="$1"
    local modified_at
    modified_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    ensure_dns_metadata_exists

    # Read current metadata
    local current_metadata
    current_metadata=$(get_all_resolvers)

    # Update timestamp
    local new_metadata
    new_metadata=$(echo "$current_metadata" | jq \
        --arg resolver "$resolver" \
        --arg modified_at "$modified_at" \
        '.[$resolver].lastModified = $modified_at')

    # Update ConfigMap
    kubectl create configmap kwo-dns-providers -n kube-system \
        --from-literal=providers.json="$new_metadata" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# ============================================================================
# SECRET MANIPULATION
# ============================================================================

# Add credentials to dns-credentials Secret
# Usage: add_credentials_to_secret <provider> <associative-array-of-key-value-pairs>
# Example: declare -A creds=([CF_DNS_API_TOKEN]="xyz")
#          add_credentials_to_secret cloudflare creds
add_credentials_to_secret() {
    local provider="$1"
    shift
    local -n creds_ref=$1

    # Read current secret as JSON
    local secret_json
    secret_json=$(kubectl get secret dns-credentials -n kube-system -o json)

    # Add each credential (base64 encoded)
    for key in "${!creds_ref[@]}"; do
        local value="${creds_ref[$key]}"
        local encoded
        encoded=$(echo -n "$value" | base64 -w 0)
        secret_json=$(echo "$secret_json" | jq --arg k "$key" --arg v "$encoded" '.data[$k] = $v')
    done

    # Apply updated secret
    echo "$secret_json" | kubectl apply -f - >/dev/null
}

# Remove credentials from dns-credentials Secret
# Usage: remove_credentials_from_secret <space-separated-key-list>
remove_credentials_from_secret() {
    local keys="$1"

    # Read current secret as JSON
    local secret_json
    secret_json=$(kubectl get secret dns-credentials -n kube-system -o json)

    # Remove each key
    for key in $keys; do
        secret_json=$(echo "$secret_json" | jq "del(.data.\"$key\")")
    done

    # Apply updated secret
    echo "$secret_json" | kubectl apply -f - >/dev/null
}

# Update credentials in dns-credentials Secret
# Usage: update_credentials_in_secret <associative-array-of-key-value-pairs>
update_credentials_in_secret() {
    local -n creds_ref=$1

    # Read current secret as JSON
    local secret_json
    secret_json=$(kubectl get secret dns-credentials -n kube-system -o json)

    # Update each credential (base64 encoded)
    for key in "${!creds_ref[@]}"; do
        local value="${creds_ref[$key]}"
        local encoded
        encoded=$(echo -n "$value" | base64 -w 0)
        secret_json=$(echo "$secret_json" | jq --arg k "$key" --arg v "$encoded" '.data[$k] = $v')
    done

    # Apply updated secret
    echo "$secret_json" | kubectl apply -f - >/dev/null
}

# Check if credentials exist in Secret
# Usage: check_credentials_exist <space-separated-key-list>
# Returns: 0 if all exist, 1 if any missing
check_credentials_exist() {
    local keys="$1"

    local secret_json
    secret_json=$(kubectl get secret dns-credentials -n kube-system -o json 2>/dev/null)

    for key in $keys; do
        if ! echo "$secret_json" | jq -e ".data.\"$key\"" >/dev/null 2>&1; then
            return 1
        fi
    done

    return 0
}

# Get credential value from Secret
# Usage: get_credential_value <key>
# Returns: decoded value
get_credential_value() {
    local key="$1"

    kubectl get secret dns-credentials -n kube-system -o jsonpath="{.data.$key}" | base64 -d
}

# ============================================================================
# TRAEFIK CONFIGURATION
# ============================================================================

# Regenerate entire Traefik HelmChartConfig based on metadata
# Usage: regenerate_traefik_config
regenerate_traefik_config() {
    log_info "Regenerating Traefik configuration..."

    # Get ACME email from kwo-config
    local acme_email
    acme_email=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.acme-email}' 2>/dev/null || echo "")

    if [ -z "$acme_email" ]; then
        log_error "Cannot find ACME email in kwo-config ConfigMap"
        return 1
    fi

    # Get all resolvers
    local metadata
    metadata=$(get_all_resolvers)

    local resolver_count
    resolver_count=$(echo "$metadata" | jq 'length')

    if [ "$resolver_count" -eq 0 ]; then
        # No resolvers - create minimal config
        log_info "No DNS providers configured, creating minimal Traefik config"

        cat <<EOF | kubectl apply -f - >/dev/null
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
        return 0
    fi

    # Generate certificate resolvers configuration
    local cert_resolvers=""
    local first=true

    while IFS= read -r resolver; do
        [ -z "$resolver" ] && continue

        local provider
        provider=$(echo "$metadata" | jq -r ".\"$resolver\".provider")

        if [ "$first" = false ]; then
            cert_resolvers+=$'\n'
        fi
        first=false

        cert_resolvers+="    ${resolver}:"$'\n'
        cert_resolvers+="      email: ${acme_email}"$'\n'
        cert_resolvers+="      storage: /data/acme-${resolver}.json"$'\n'
        cert_resolvers+="      dnsChallenge:"$'\n'
        cert_resolvers+="        provider: ${provider}"$'\n'
        cert_resolvers+="        resolvers:"$'\n'
        cert_resolvers+="          - 1.1.1.1:53"$'\n'
        cert_resolvers+="          - 8.8.8.8:53"
    done < <(echo "$metadata" | jq -r 'keys[]')

    # Apply full config
    cat <<EOF | kubectl apply -f - >/dev/null
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
    env:
$(echo "$cert_resolvers" | sed 's/^/      /' | sed 's/^      $//')
    certificatesResolvers:
$(echo "$cert_resolvers" | sed 's/    /      /')
    envFrom:
      - secretRef:
          name: dns-credentials
EOF

    log_info "Traefik configuration updated with $resolver_count resolver(s)"
}

# Restart Traefik pod to apply configuration changes
# Usage: restart_traefik
restart_traefik() {
    log_info "Restarting Traefik..."

    kubectl rollout restart deployment traefik -n kube-system >/dev/null 2>&1 || true
    kubectl delete pod -n kube-system -l app.kubernetes.io/name=traefik >/dev/null 2>&1 || true

    sleep 2
    log_info "Traefik restarted"
}

# ============================================================================
# CREDENTIAL OPERATIONS
# ============================================================================

# Archive DNS credentials before deletion or update
# Usage: archive_dns_credentials <resolver-name> <operation>
archive_dns_credentials() {
    local resolver="$1"
    local operation="$2"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local archive_dir="/var/lib/kwo/archive/dns-${resolver}-${operation}-${timestamp}"

    mkdir -p "$archive_dir"
    chmod 700 "$archive_dir"

    # Save metadata
    get_resolver_metadata "$resolver" > "$archive_dir/metadata.json"

    # Save credentials
    local metadata
    metadata=$(get_resolver_metadata "$resolver")
    local credentials
    credentials=$(echo "$metadata" | jq -r '.credentials[]')

    local creds_json="{"
    local first=true

    for key in $credentials; do
        local value
        value=$(get_credential_value "$key" 2>/dev/null || echo "")

        if [ -n "$value" ]; then
            [ "$first" = false ] && creds_json+=","
            first=false

            # Escape value for JSON
            local escaped_value
            escaped_value=$(echo -n "$value" | jq -Rs .)
            creds_json+="\"$key\":$escaped_value"
        fi
    done

    creds_json+="}"

    echo "$creds_json" > "$archive_dir/credentials.json"
    chmod 600 "$archive_dir/credentials.json"

    log_info "Archived credentials to $archive_dir"
}

# Prompt user for DNS credentials interactively
# Usage: prompt_dns_credentials_interactive <provider> <associative-array-name>
# Example: declare -A creds
#          prompt_dns_credentials_interactive cloudflare creds
prompt_dns_credentials_interactive() {
    local provider="$1"
    local -n creds_ref=$2

    local credentials
    credentials=$(get_provider_credentials "$provider")

    echo ""
    log_info "Enter credentials for $provider:"

    for key in $credentials; do
        read -p "  $key: " -r value
        creds_ref["$key"]="$value"
    done
}

# Read DNS credentials from environment variables
# Usage: read_dns_credentials_from_env <provider> <associative-array-name>
# Returns: 0 if all found, 1 if any missing
read_dns_credentials_from_env() {
    local provider="$1"
    local -n creds_ref=$2

    local credentials
    credentials=$(get_provider_credentials "$provider")

    local missing=""

    for key in $credentials; do
        if [ -n "${!key:-}" ]; then
            creds_ref["$key"]="${!key}"
        else
            missing+=" $key"
        fi
    done

    if [ -n "$missing" ]; then
        log_error "Missing required environment variables:$missing"
        return 1
    fi

    return 0
}

# Test DNS provider API connectivity
# Usage: check_dns_provider <provider> <resolver-name>
# Returns: 0 if OK, 1 if failed
check_dns_provider() {
    local provider="$1"
    local resolver="$2"

    case "$provider" in
        cloudflare)
            # Test Cloudflare API token
            local token
            token=$(get_credential_value "CF_DNS_API_TOKEN" 2>/dev/null || echo "")

            if [ -z "$token" ]; then
                echo "✗ Missing CF_DNS_API_TOKEN"
                return 1
            fi

            local response
            response=$(curl -s -o /dev/null -w "%{http_code}" \
                -H "Authorization: Bearer $token" \
                "https://api.cloudflare.com/client/v4/user/tokens/verify")

            if [ "$response" = "200" ]; then
                echo "✓ Cloudflare API token valid"
                return 0
            else
                echo "✗ Cloudflare API token validation failed (HTTP $response)"
                return 1
            fi
            ;;
        *)
            # For other providers, just check if credentials exist
            local credentials
            credentials=$(get_provider_credentials "$provider")

            if check_credentials_exist "$credentials"; then
                echo "✓ Credentials present in Secret"
                return 0
            else
                echo "✗ Credentials missing in Secret"
                return 1
            fi
            ;;
    esac
}
