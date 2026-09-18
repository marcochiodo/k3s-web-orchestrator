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

# Split a comma-separated list into one item per line, trimmed, empty items dropped
split_csv() {
    echo "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' || true
}

# Prompt for a comma-separated list of FQDNs until every item is valid.
# Prints the normalized list (comma-separated, no spaces) on stdout.
# Args: $1=prompt $2=default (optional)
prompt_domain_list() {
    local prompt="$1" default="${2:-}" input list d ok
    while true; do
        if [ -n "$default" ]; then
            read -p "$prompt [$default]: " input
            input="${input:-$default}"
        else
            read -p "$prompt: " input
        fi
        list=$(split_csv "$input" | paste -sd,)
        ok=true
        [ -n "$list" ] || ok=false
        for d in $(split_csv "$list"); do
            validate_domain "$d" || { log_error "Invalid domain format: $d" >&2; ok=false; }
        done
        [ "$ok" = true ] && { echo "$list"; return 0; }
    done
}

# ---------------------------------------------------------------------------
# /etc/rancher/k3s/config.yaml helpers
# The file is written by KWO only with scalar keys ("node-name: x") and block
# lists ("tls-san:\n  - a\n  - b"); flow lists ([a, b]) are not handled.
# ---------------------------------------------------------------------------
K3S_CONFIG_FILE="/etc/rancher/k3s/config.yaml"

# Print the value(s) of a key, one per line (scalar or block list)
k3s_config_get() {
    local key="$1"
    [ -f "$K3S_CONFIG_FILE" ] || return 0
    awk -v key="$key" '
        $0 ~ "^"key":" { inblock=1; sub("^"key":[[:space:]]*", ""); if ($0 != "") print; next }
        inblock && /^[[:space:]]*-[[:space:]]*/ { sub(/^[[:space:]]*-[[:space:]]*/, ""); print; next }
        { inblock=0 }
    ' "$K3S_CONFIG_FILE"
}

# Replace (or add) a key: one value -> scalar, several -> block list
# Args: $1=key $2..=values
k3s_config_set() {
    local key="$1"; shift
    local tmp
    mkdir -p "$(dirname "$K3S_CONFIG_FILE")"
    touch "$K3S_CONFIG_FILE"
    tmp=$(mktemp)
    awk -v key="$key" '
        $0 ~ "^"key":" { inblock=1; next }
        inblock && /^[[:space:]]*-[[:space:]]*/ { next }
        { inblock=0; print }
    ' "$K3S_CONFIG_FILE" > "$tmp"
    if [ $# -eq 1 ]; then
        echo "$key: $1" >> "$tmp"
    else
        echo "$key:" >> "$tmp"
        local v; for v in "$@"; do echo "  - $v" >> "$tmp"; done
    fi
    cat "$tmp" > "$K3S_CONFIG_FILE"
    rm -f "$tmp"
}

# DNS names in the API server serving certificate, one per line
api_cert_dns_names() {
    echo | openssl s_client -connect 127.0.0.1:6443 2>/dev/null \
        | openssl x509 -noout -ext subjectAltName 2>/dev/null \
        | grep -o 'DNS:[^,[:space:]]*' | sed 's/^DNS://' || true
}

# Make the node identity survive a reboot and a k3s upgrade:
#   1. the cloud guest agent must stop rewriting /etc/hostname from instance
#      metadata (GCE and Azure do it at every boot);
#   2. k3s must not derive the node name from the hostname: node-name goes in
#      config.yaml, which kwo-update-k3s preserves (the systemd unit is not).
# Without (2) a hostname change registers a *new* node: the original goes
# NotReady and every local-path PV becomes unschedulable, because its
# nodeAffinity still points at the old name.
# Args: $1=node name to pin
pin_node_identity() {
    local node_name="$1"
    if [ -d /etc/cloud/cloud.cfg.d ]; then
        echo "preserve_hostname: true" > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
    fi
    if [ -f /etc/default/instance_configs.cfg ] || command -v google_metadata_script_runner &> /dev/null; then
        printf '[Instance]\nset_hostname = false\n' > /etc/default/instance_configs.cfg.template
    fi

    local pinned
    pinned=$(k3s_config_get node-name)
    if [ -z "$pinned" ]; then
        k3s_config_set node-name "$node_name"
        log_info "Pinned k3s node name to: $node_name"
    elif [ "$pinned" != "$node_name" ]; then
        log_warn "config.yaml pins node-name to '$pinned', not '$node_name' - leaving it alone"
    fi
}

# Check available disk space on a given path
# Args: $1=path $2=required_mb $3=context (e.g. "installation")
# Exits with error if space is insufficient
check_disk_space() {
    local path="$1"
    local required_mb="$2"
    local context="${3:-operation}"
    local available_mb
    available_mb=$(df -m "$path" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$available_mb" ]; then
        log_warn "Could not check disk space on $path"
        return 0
    fi
    if [ "$available_mb" -lt "$required_mb" ]; then
        log_error "Insufficient disk space for $context"
        log_error "  Path:      $path"
        log_error "  Available: ${available_mb}MB"
        log_error "  Required:  ${required_mb}MB"
        exit 1
    fi
    log_info "Disk space OK: ${available_mb}MB available on $path (need ${required_mb}MB)"
}
