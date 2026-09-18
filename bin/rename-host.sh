#!/usr/bin/env bash
# KWO Host Rename
# Change, on an existing installation and one step at a time:
#   1. the machine hostname
#   2. the API server hostnames (TLS SANs + default for new kubeconfigs)
#   3. the registry hostnames (one Ingress per host + registries.yaml)
# The Kubernetes node name is never touched: every local-path PV is bound to it.
# Old and new names can coexist, so a migration needs no downtime: run again
# without the old names once nothing references them anymore.

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

show_usage() {
    cat <<EOF
KWO Host Rename

USAGE:
  sudo kwo-rename-host

Interactive. Asks, one at a time, whether to change:
  1. the machine hostname (not the k8s node name, which is immutable)
  2. the API server hostnames (comma-separated, first = default for kubeconfigs)
  3. the registry hostnames (comma-separated, first = primary)

Each list replaces the previous one, so a migration is two runs: first with
old and new names together, later with the new names only.
EOF
}

case "${1:-}" in
    -h|--help|help) show_usage; exit 0 ;;
    "") ;;
    *) log_error "Unknown argument: $1"; echo ""; show_usage; exit 1 ;;
esac

require_root
command -v k3s &>/dev/null || { log_error "k3s is not installed"; exit 1; }
kubectl get configmap kwo-config -n kube-system &>/dev/null || { log_error "kwo-config not found: run install.sh first"; exit 1; }

KWO_LOG="/var/log/kwo/tenant-operations.log"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE_DIR="/var/lib/kwo/archive/rename-host-${TIMESTAMP}"

log_op() {
    [ -f "$KWO_LOG" ] && echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] RENAME_HOST $1 by=$(whoami)" >> "$KWO_LOG" || true
}

archive_file() {
    [ -f "$1" ] || return 0
    mkdir -p "$ARCHIVE_DIR"; chmod 700 "$ARCHIVE_DIR"
    cp "$1" "$ARCHIVE_DIR/"
    chmod 600 "$ARCHIVE_DIR/$(basename "$1")"
}

# Names in NEW_API_DOMAINS not covered by the live API certificate
api_cert_missing_names() {
    local d names missing=""
    names=$(api_cert_dns_names)
    for d in $(split_csv "$NEW_API_DOMAINS"); do
        echo "$names" | grep -qx "$d" || missing="$missing $d"
    done
    echo "$missing"
}

# Names in the live API certificate that are no longer in NEW_API_DOMAINS
# (k8s internal names excluded)
api_cert_stale_names() {
    local n stale=""
    for n in $(api_cert_dns_names | grep -v '^kubernetes\|^localhost$'); do
        split_csv "$NEW_API_DOMAINS" | grep -qx "$n" || stale="$stale $n"
    done
    echo "$stale"
}

confirm() {
    local answer
    read -p "$1 [y/N]: " answer
    [ "$answer" = "y" ] || [ "$answer" = "Y" ]
}

# ---------------------------------------------------------------------------
# Current state
# ---------------------------------------------------------------------------
NODE_NAME=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
HOSTNAME_NOW=$(hostname)
API_DOMAIN=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-domain}' 2>/dev/null || echo "")
API_DOMAINS=$(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-domains}' 2>/dev/null || echo "")
API_DOMAINS="${API_DOMAINS:-$API_DOMAIN}"
TLS_SAN_NOW=$(k3s_config_get tls-san | paste -sd, || true)
CERT_NAMES_NOW=$(api_cert_dns_names | grep -v '^kubernetes\|^localhost$' | paste -sd, || true)

REGISTRY_CONFIG=$(get_registry_config)
REGISTRY_ENABLED=$(echo "$REGISTRY_CONFIG" | jq -r '.enabled')
REGISTRY_DOMAINS=$(echo "$REGISTRY_CONFIG" | jq -r '.domains // [] | join(",")')
REGISTRY_RESOLVER=$(echo "$REGISTRY_CONFIG" | jq -r '.certResolver // ""')
REGISTRY_USERNAME=$(echo "$REGISTRY_CONFIG" | jq -r '.username // ""')

echo ""
echo "=== KWO Host Rename ==="
echo ""
echo "Current state:"
echo "  k8s node name:      $NODE_NAME (immutable)"
echo "  machine hostname:   $HOSTNAME_NOW"
echo "  API hostnames:      ${API_DOMAINS:-<none>}"
echo "  tls-san (config):   ${TLS_SAN_NOW:-<none>}"
echo "  API cert DNS names: ${CERT_NAMES_NOW:-<none>}"
if [ "$REGISTRY_ENABLED" = "true" ]; then
    echo "  registry hostnames: $REGISTRY_DOMAINS"
else
    echo "  registry:           not configured"
fi
echo ""

NEED_K3S_RESTART=false
NEW_API_DOMAINS=""
CHANGED=false

# ---------------------------------------------------------------------------
# Step 1: machine hostname
# ---------------------------------------------------------------------------
echo "--- Step 1/3: machine hostname ---"
if confirm "Update the machine hostname (not the k8s node name)?"; then
    NEW_HOSTNAME=$(prompt_domain_list "New hostname" "$HOSTNAME_NOW")

    # The node name must be pinned *before* the hostname changes, or k3s
    # registers a new node at the next restart (PVs would be orphaned)
    pin_node_identity "$NODE_NAME"

    if [ "$NEW_HOSTNAME" != "$HOSTNAME_NOW" ]; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        # Keep /etc/hosts consistent when it maps the old name (Debian's 127.0.1.1 line)
        if grep -qw "$HOSTNAME_NOW" /etc/hosts; then
            archive_file /etc/hosts
            sed -i "s/\b${HOSTNAME_NOW//./\\.}\b/${NEW_HOSTNAME}/g" /etc/hosts
            log_info "Updated /etc/hosts"
        fi
        log_info "Hostname set to: $NEW_HOSTNAME"
        log_op "hostname old=$HOSTNAME_NOW new=$NEW_HOSTNAME"
        CHANGED=true
    else
        log_info "Hostname unchanged"
    fi

    if [ -f /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg ]; then
        log_info "cloud-init: preserve_hostname enabled (provider metadata will not overwrite it)"
    fi
    if [ -f /etc/default/instance_configs.cfg.template ]; then
        log_info "GCE guest agent: set_hostname disabled"
    fi
    log_warn "If your provider's panel shows a server name, update it there too: the guards above only cover cloud-init and GCE"
else
    log_info "Skipping hostname"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 2: API server hostnames
# ---------------------------------------------------------------------------
echo "--- Step 2/3: API server hostnames ---"
if confirm "Update the API server hostnames?"; then
    echo "Enter the complete list: names left out stop being valid for the API certificate."
    NEW_API_DOMAINS=$(prompt_domain_list "API hostnames, comma-separated (first = default for new kubeconfigs)" "$API_DOMAINS")
    NEW_API_DOMAIN="${NEW_API_DOMAINS%%,*}"

    archive_file "$K3S_CONFIG_FILE"
    pin_node_identity "$NODE_NAME"
    k3s_config_set tls-san $(split_csv "$NEW_API_DOMAINS")
    log_info "tls-san set in $K3S_CONFIG_FILE: $NEW_API_DOMAINS"
    # Installs older than this script also pass --tls-san on the unit's
    # command line; k3s merges it with config.yaml, so that name stays in the
    # certificate until the unit is rewritten (kwo-update-k3s does it)
    unit_san=$(systemctl cat k3s 2>/dev/null | grep -A1 -- "'--tls-san'" | tail -1 | tr -d "' \\\\\\t" || true)
    if [ -n "$unit_san" ]; then
        log_warn "The k3s systemd unit still passes --tls-san $unit_san: it stays valid until the unit is rewritten (next kwo-update-k3s)"
    fi

    kubectl patch configmap kwo-config -n kube-system --type=merge \
        -p "{\"data\":{\"api-server\":\"https://${NEW_API_DOMAIN}:6443\",\"api-domain\":\"$NEW_API_DOMAIN\",\"api-domains\":\"$NEW_API_DOMAINS\"}}" >/dev/null
    log_info "kwo-config updated: api-domain=$NEW_API_DOMAIN"
    log_op "api-domains old=$API_DOMAINS new=$NEW_API_DOMAINS"

    # The serving certificate is cached (secret k3s-serving + dynamic-cert.json)
    # and k3s neither extends it with new SANs on restart nor drops removed
    # ones: clear the cache when the names differ, so the restart below
    # regenerates it from the tls-san list
    if [ -n "$(api_cert_missing_names)" ] || [ -n "$(api_cert_stale_names)" ]; then
        kubectl delete secret k3s-serving -n kube-system --ignore-not-found >/dev/null
        rm -f /var/lib/rancher/k3s/server/tls/dynamic-cert.json
        log_info "API certificate will be regenerated with the new names"
    fi

    NEED_K3S_RESTART=true
    CHANGED=true

    # Existing kubeconfigs keep working as long as their hostname stays in the
    # list; rewriting them is optional and only touches the local copies
    if [ "$NEW_API_DOMAIN" != "$API_DOMAIN" ] && ls /var/lib/kwo/kubeconfigs/*.yaml &>/dev/null; then
        echo ""
        echo "Kubeconfigs in /var/lib/kwo/kubeconfigs/ point to https://${API_DOMAIN}:6443."
        echo "Copies already handed out (CI secrets, laptops) are not affected either way."
        if confirm "Rewrite their server: field to https://${NEW_API_DOMAIN}:6443?"; then
            mkdir -p "$ARCHIVE_DIR/kubeconfigs"; chmod 700 "$ARCHIVE_DIR" "$ARCHIVE_DIR/kubeconfigs"
            count=0
            for kc in /var/lib/kwo/kubeconfigs/*.yaml; do
                grep -q "server: https://${API_DOMAIN}:6443" "$kc" || continue
                cp "$kc" "$ARCHIVE_DIR/kubeconfigs/"
                sed -i "s#server: https://${API_DOMAIN//./\\.}:6443#server: https://${NEW_API_DOMAIN}:6443#" "$kc"
                count=$((count + 1))
            done
            log_info "Rewrote $count kubeconfig(s), originals in $ARCHIVE_DIR/kubeconfigs/"
            log_op "kubeconfigs rewritten=$count"
        fi
    fi
else
    log_info "Skipping API hostnames"
fi
echo ""

# ---------------------------------------------------------------------------
# Step 3: registry hostnames
# ---------------------------------------------------------------------------
echo "--- Step 3/3: registry hostnames ---"
if [ "$REGISTRY_ENABLED" != "true" ]; then
    log_info "Registry not configured, nothing to do"
elif confirm "Update the registry hostnames?"; then
    echo "Enter the complete list: each name gets its own Ingress and certificate, names left out are removed."
    NEW_REGISTRY_DOMAINS=$(prompt_domain_list "Registry hostnames, comma-separated (first = primary)" "$REGISTRY_DOMAINS")
    NEW_REGISTRY_DOMAIN="${NEW_REGISTRY_DOMAINS%%,*}"

    archive_registry_credentials "rename"

    sync_registry_ingresses "$REGISTRY_RESOLVER" $(split_csv "$NEW_REGISTRY_DOMAINS")
    log_info "Registry Ingresses: $NEW_REGISTRY_DOMAINS"

    REGISTRY_PASSWORD=$(get_registry_credentials | jq -r '.password')
    write_registries_yaml "$REGISTRY_USERNAME" "$REGISTRY_PASSWORD" $(split_csv "$NEW_REGISTRY_DOMAINS")
    log_info "Written /etc/rancher/k3s/registries.yaml"

    kubectl patch configmap kwo-config -n kube-system --type=merge \
        -p "{\"data\":{\"registry-domain\":\"$NEW_REGISTRY_DOMAIN\",\"registry-domains\":\"$NEW_REGISTRY_DOMAINS\"}}" >/dev/null
    log_info "kwo-config updated: registry-domain=$NEW_REGISTRY_DOMAIN"
    log_op "registry-domains old=$REGISTRY_DOMAINS new=$NEW_REGISTRY_DOMAINS"

    NEED_K3S_RESTART=true
    CHANGED=true
else
    log_info "Skipping registry hostnames"
fi
echo ""

# ---------------------------------------------------------------------------
# Apply: one k3s restart for tls-san and registries.yaml
# ---------------------------------------------------------------------------
if [ "$NEED_K3S_RESTART" = true ]; then
    log_info "Restarting k3s (running pods are not affected)..."
    systemctl restart k3s
    attempt=0
    until kubectl get nodes &>/dev/null || [ $attempt -ge 30 ]; do attempt=$((attempt + 1)); sleep 2; done
    kubectl get nodes &>/dev/null || { log_error "k3s did not come back: check 'systemctl status k3s'"; exit 1; }

    if [ -n "$NEW_API_DOMAINS" ]; then
        attempt=0
        missing=$(api_cert_missing_names)
        while [ -n "$missing" ] && [ $attempt -lt 15 ]; do attempt=$((attempt + 1)); sleep 2; missing=$(api_cert_missing_names); done
        if [ -n "$missing" ]; then
            log_error "API certificate still missing:$missing - check 'journalctl -u k3s'"
            exit 1
        fi
        log_info "API certificate valid for: $(api_cert_dns_names | grep -v '^kubernetes\|^localhost$' | paste -sd,)"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$CHANGED" != true ]; then
    log_info "Nothing changed"
    exit 0
fi

echo ""
echo "========================================="
echo "  Host rename complete"
echo "========================================="
echo ""
echo "  k8s node name:      $NODE_NAME"
echo "  machine hostname:   $(hostname)"
echo "  API hostnames:      $(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.api-domains}')"
if [ "$REGISTRY_ENABLED" = "true" ]; then
    echo "  registry hostnames: $(kubectl get configmap kwo-config -n kube-system -o jsonpath='{.data.registry-domains}')"
fi
[ -d "$ARCHIVE_DIR" ] && echo "  archive:            $ARCHIVE_DIR"
echo ""
echo "Reminders:"
echo "  - Point every new hostname at this server in DNS (A record, or CNAME to an existing one)"
echo "  - New kubeconfigs (kwo-create-user, kwo-create-tenant) use the first API hostname"
echo "  - Update image references (<registry>/image:tag) in manifests and CI before dropping an old registry hostname"
echo "  - Re-run kwo-rename-host without the old names once nothing uses them"
echo ""
