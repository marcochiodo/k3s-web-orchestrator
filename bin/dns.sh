#!/usr/bin/env bash
# KWO DNS Provider Management
# Unified command for managing DNS providers for Let's Encrypt certificates

set -euo pipefail

# Determine if running from installation or git repo
if [ -f "/usr/share/kwo/bin/lib/common.sh" ]; then
    source /usr/share/kwo/bin/lib/common.sh
    source /usr/share/kwo/bin/lib/dns-helpers.sh
else
    # Running from git repo
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "$SCRIPT_DIR/lib/common.sh"
    source "$SCRIPT_DIR/lib/dns-helpers.sh"
fi

# ============================================================================
# USAGE
# ============================================================================

show_usage() {
    cat <<EOF
KWO DNS Provider Management

USAGE:
  kwo-dns add <provider> [--suffix=<name>] [--non-interactive]
  kwo-dns remove <resolver-name> [--force]
  kwo-dns list [--format=table|json]
  kwo-dns update <resolver-name> [--non-interactive]
  kwo-dns check [resolver-name]

PROVIDERS:
  cloudflare, ovh, route53, digitalocean

EXAMPLES:
  # Add provider interactively
  sudo kwo-dns add cloudflare

  # Add with suffix for multi-account
  sudo kwo-dns add ovh --suffix=production

  # Add non-interactively (from env vars)
  CF_DNS_API_TOKEN="xyz" sudo kwo-dns add cloudflare --non-interactive

  # Remove provider
  sudo kwo-dns remove letsencrypt-cloudflare

  # List all providers
  sudo kwo-dns list
  sudo kwo-dns list --format=json

  # Update credentials
  sudo kwo-dns update letsencrypt-cloudflare

  # Check credentials
  sudo kwo-dns check
  sudo kwo-dns check letsencrypt-cloudflare

NAMING:
  Without suffix: letsencrypt-{provider}
  With suffix:    letsencrypt-{provider}-{suffix}

EOF
}

# ============================================================================
# SUBCOMMAND: ADD
# ============================================================================

dns_add() {
    require_root

    local provider=""
    local suffix=""
    local non_interactive=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --suffix=*)
                suffix="${1#*=}"
                shift
                ;;
            --non-interactive)
                non_interactive=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -z "$provider" ]; then
                    provider="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate provider
    if [ -z "$provider" ]; then
        log_error "Provider required"
        show_usage
        exit 1
    fi

    if ! validate_provider_name "$provider"; then
        log_error "Invalid provider: $provider"
        log_error "Supported providers: $(get_supported_providers)"
        exit 1
    fi

    # Validate suffix if provided
    if [ -n "$suffix" ] && ! validate_suffix "$suffix"; then
        log_error "Invalid suffix format: $suffix"
        log_error "Must be lowercase alphanumeric + hyphens, no start/end hyphen"
        exit 3
    fi

    # Generate resolver name
    local resolver
    resolver=$(generate_resolver_name "$provider" "$suffix")

    # Check if resolver already exists
    if check_resolver_exists "$resolver"; then
        log_error "Resolver '$resolver' already exists"
        log_error "Use 'kwo-dns remove $resolver' first or choose a different suffix"
        exit 2
    fi

    # Check for duplicate provider without suffix
    if [ -z "$suffix" ]; then
        local base_resolver="letsencrypt-${provider}"
        # Check if any resolver starts with this pattern
        local existing
        existing=$(get_all_resolvers | jq -r "keys[] | select(startswith(\"$base_resolver-\"))" | head -n 1)

        if [ -n "$existing" ]; then
            log_error "Provider '$provider' already exists with suffix: $existing"
            log_error "Use --suffix= to add another instance or remove existing first"
            exit 2
        fi
    fi

    log_info "Adding DNS provider: $resolver"

    # Get credentials
    declare -A credentials

    if [ "$non_interactive" = true ]; then
        if ! read_dns_credentials_from_env "$provider" credentials; then
            exit 5
        fi
    else
        prompt_dns_credentials_interactive "$provider" credentials
    fi

    # Validate credentials are not empty
    local empty_found=false
    for key in "${!credentials[@]}"; do
        if [ -z "${credentials[$key]}" ]; then
            log_error "Credential $key cannot be empty"
            empty_found=true
        fi
    done

    if [ "$empty_found" = true ]; then
        exit 5
    fi

    # Add to Secret
    log_info "Updating dns-credentials Secret..."
    add_credentials_to_secret "$provider" credentials

    # Generate credentials JSON array for metadata
    local cred_keys
    cred_keys=$(get_provider_credentials "$provider")
    local creds_json="["
    local first=true

    for key in $cred_keys; do
        [ "$first" = false ] && creds_json+=","
        first=false
        creds_json+="\"$key\""
    done

    creds_json+="]"

    # Save metadata
    log_info "Saving metadata..."
    save_dns_metadata "$resolver" "$provider" "$suffix" "$creds_json"

    # Regenerate Traefik config
    regenerate_traefik_config

    # Restart Traefik
    restart_traefik

    echo ""
    log_info "✓ DNS provider '$resolver' added successfully"
    echo ""
    echo "To use this resolver in an Ingress, add:"
    echo "  metadata:"
    echo "    annotations:"
    echo "      cert-manager.io/cluster-issuer: $resolver"
    echo ""
}

# ============================================================================
# SUBCOMMAND: REMOVE
# ============================================================================

dns_remove() {
    require_root

    local resolver=""
    local force=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)
                force=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -z "$resolver" ]; then
                    resolver="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate resolver provided
    if [ -z "$resolver" ]; then
        log_error "Resolver name required"
        show_usage
        exit 1
    fi

    # Check resolver exists
    if ! check_resolver_exists "$resolver"; then
        log_error "Resolver '$resolver' not found"
        log_error "Use 'kwo-dns list' to see all resolvers"
        exit 1
    fi

    # Count providers
    local total_providers
    total_providers=$(count_providers)

    if [ "$total_providers" -eq 1 ]; then
        log_warn "⚠ WARNING: This is the last DNS provider!"
        log_warn "Automatic TLS certificates will stop working after removal"
        echo ""
    fi

    # Confirm deletion unless --force
    if [ "$force" = false ]; then
        read -p "Remove DNS provider '$resolver'? [y/N]: " -r confirm

        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            log_info "Cancelled"
            exit 0
        fi
    fi

    log_info "Removing DNS provider: $resolver"

    # Archive credentials
    archive_dns_credentials "$resolver" "remove"

    # Get credentials to remove from Secret
    local metadata
    metadata=$(get_resolver_metadata "$resolver")
    local cred_keys
    cred_keys=$(echo "$metadata" | jq -r '.credentials[]' | tr '\n' ' ')

    # Remove from Secret
    log_info "Updating dns-credentials Secret..."
    remove_credentials_from_secret "$cred_keys"

    # Remove metadata
    log_info "Removing metadata..."
    remove_dns_metadata "$resolver"

    # Regenerate Traefik config
    regenerate_traefik_config

    # Restart Traefik
    restart_traefik

    # Log to operations log
    if [ -f "/var/log/kwo/tenant-operations.log" ]; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] DNS_REMOVE resolver=$resolver by=$(whoami)" >> /var/log/kwo/tenant-operations.log
    fi

    echo ""
    log_info "✓ DNS provider '$resolver' removed successfully"
    echo ""
}

# ============================================================================
# SUBCOMMAND: LIST
# ============================================================================

dns_list() {
    local format="table"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format=*)
                format="${1#*=}"
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                log_error "Unexpected argument: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    # Validate format
    if [ "$format" != "table" ] && [ "$format" != "json" ]; then
        log_error "Invalid format: $format (must be table or json)"
        exit 1
    fi

    # Get all resolvers
    local metadata
    metadata=$(get_all_resolvers)

    local resolver_count
    resolver_count=$(echo "$metadata" | jq 'length')

    if [ "$resolver_count" -eq 0 ]; then
        if [ "$format" = "json" ]; then
            echo "[]"
        else
            echo "No DNS providers configured"
            echo ""
            echo "To add a DNS provider:"
            echo "  sudo kwo-dns add cloudflare"
            echo "  sudo kwo-dns add ovh --suffix=production"
        fi
        exit 0
    fi

    if [ "$format" = "json" ]; then
        # JSON output
        echo "$metadata" | jq '.'
    else
        # Table output
        echo "DNS Providers ($resolver_count):"
        echo ""
        printf "%-35s %-15s %-10s %-20s\n" "RESOLVER" "PROVIDER" "SUFFIX" "CREATED"
        printf "%-35s %-15s %-10s %-20s\n" "--------" "--------" "------" "-------"

        while IFS= read -r resolver; do
            [ -z "$resolver" ] && continue

            local provider suffix created_at status
            provider=$(echo "$metadata" | jq -r ".\"$resolver\".provider")
            suffix=$(echo "$metadata" | jq -r ".\"$resolver\".suffix")
            created_at=$(echo "$metadata" | jq -r ".\"$resolver\".createdAt")

            # Check credentials status
            local cred_keys
            cred_keys=$(echo "$metadata" | jq -r ".\"$resolver\".credentials[]" | tr '\n' ' ')

            if check_credentials_exist "$cred_keys"; then
                status="✓"
            else
                status="✗"
            fi

            printf "%s %-35s %-15s %-10s %-20s\n" \
                "$status" \
                "$resolver" \
                "$provider" \
                "${suffix:--}" \
                "${created_at:0:19}"
        done < <(echo "$metadata" | jq -r 'keys[]' | sort)

        echo ""
        echo "✓ = credentials present, ✗ = credentials missing"
    fi
}

# ============================================================================
# SUBCOMMAND: UPDATE
# ============================================================================

dns_update() {
    require_root

    local resolver=""
    local non_interactive=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                non_interactive=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
            *)
                if [ -z "$resolver" ]; then
                    resolver="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_usage
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # Validate resolver provided
    if [ -z "$resolver" ]; then
        log_error "Resolver name required"
        show_usage
        exit 1
    fi

    # Check resolver exists
    if ! check_resolver_exists "$resolver"; then
        log_error "Resolver '$resolver' not found"
        log_error "Use 'kwo-dns list' to see all resolvers"
        exit 1
    fi

    log_info "Updating credentials for: $resolver"

    # Archive old credentials
    archive_dns_credentials "$resolver" "update"

    # Get provider
    local metadata
    metadata=$(get_resolver_metadata "$resolver")
    local provider
    provider=$(echo "$metadata" | jq -r '.provider')

    # Get new credentials
    declare -A credentials

    if [ "$non_interactive" = true ]; then
        if ! read_dns_credentials_from_env "$provider" credentials; then
            exit 5
        fi
    else
        prompt_dns_credentials_interactive "$provider" credentials
    fi

    # Validate credentials are not empty
    local empty_found=false
    for key in "${!credentials[@]}"; do
        if [ -z "${credentials[$key]}" ]; then
            log_error "Credential $key cannot be empty"
            empty_found=true
        fi
    done

    if [ "$empty_found" = true ]; then
        exit 5
    fi

    # Update Secret
    log_info "Updating dns-credentials Secret..."
    update_credentials_in_secret credentials

    # Update metadata timestamp
    update_metadata_timestamp "$resolver"

    # Restart Traefik
    restart_traefik

    # Log to operations log
    if [ -f "/var/log/kwo/tenant-operations.log" ]; then
        echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] DNS_UPDATE resolver=$resolver by=$(whoami)" >> /var/log/kwo/tenant-operations.log
    fi

    echo ""
    log_info "✓ Credentials for '$resolver' updated successfully"
    echo ""
}

# ============================================================================
# SUBCOMMAND: CHECK
# ============================================================================

dns_check() {
    local resolver=""

    # Parse arguments
    if [ $# -gt 0 ]; then
        resolver="$1"
    fi

    if [ -n "$resolver" ]; then
        # Check specific resolver
        if ! check_resolver_exists "$resolver"; then
            log_error "Resolver '$resolver' not found"
            log_error "Use 'kwo-dns list' to see all resolvers"
            exit 1
        fi

        echo "Checking DNS provider: $resolver"
        echo ""

        local metadata
        metadata=$(get_resolver_metadata "$resolver")
        local provider
        provider=$(echo "$metadata" | jq -r '.provider')

        # Check credentials
        local result
        if result=$(check_dns_provider "$provider" "$resolver" 2>&1); then
            echo "$result"
            exit 0
        else
            echo "$result"
            exit 2
        fi
    else
        # Check all resolvers
        local all_metadata
        all_metadata=$(get_all_resolvers)

        local resolver_count
        resolver_count=$(echo "$all_metadata" | jq 'length')

        if [ "$resolver_count" -eq 0 ]; then
            echo "No DNS providers configured"
            exit 0
        fi

        echo "Checking $resolver_count DNS provider(s):"
        echo ""

        local any_failed=false

        while IFS= read -r res; do
            [ -z "$res" ] && continue

            local provider
            provider=$(echo "$all_metadata" | jq -r ".\"$res\".provider")

            printf "%-40s " "$res:"

            local result
            if result=$(check_dns_provider "$provider" "$res" 2>&1); then
                echo "$result"
            else
                echo "$result"
                any_failed=true
            fi
        done < <(echo "$all_metadata" | jq -r 'keys[]' | sort)

        if [ "$any_failed" = true ]; then
            exit 2
        else
            exit 0
        fi
    fi
}

# ============================================================================
# MAIN DISPATCHER
# ============================================================================

SUBCOMMAND="${1:-}"

if [ -z "$SUBCOMMAND" ]; then
    show_usage
    exit 1
fi

shift || true

case "$SUBCOMMAND" in
    add)
        dns_add "$@"
        ;;
    remove)
        dns_remove "$@"
        ;;
    list)
        dns_list "$@"
        ;;
    update)
        dns_update "$@"
        ;;
    check)
        dns_check "$@"
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
