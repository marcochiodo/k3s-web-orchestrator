#!/usr/bin/env bash
# Common functions for KWO scripts

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

require_root() {
    [ "$EUID" -eq 0 ] || { log_error "Must run as root (use sudo)"; exit 4; }
}

validate_tenant_name() {
    echo "$1" | grep -qE '^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
}

get_kwo_version() {
    [ -f "/usr/share/kwo/VERSION" ] && cat /usr/share/kwo/VERSION || echo "unknown"
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
