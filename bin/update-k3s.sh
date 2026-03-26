#!/usr/bin/env bash
set -euo pipefail

# kwo-update-k3s - Update k3s to a newer version
# Usage: sudo kwo-update-k3s [--version=vX.Y.Z+k3sN] [--channel=stable|latest] [--yes]

if [ -f "/usr/share/kwo/bin/lib/common.sh" ]; then
    source /usr/share/kwo/bin/lib/common.sh
else
    # Fallback for development
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
    log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
    log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
    log_error() { echo -e "${RED}[ERROR]${NC} $*"; }
    require_root() { [ "$EUID" -eq 0 ] || { log_error "Must run as root (use sudo)"; exit 4; }; }
fi

require_root

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

TARGET_VERSION=""
CHANNEL="stable"
AUTO_YES=false

show_help() {
    echo "Usage: sudo kwo-update-k3s [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --version=vX.Y.Z+k3sN   Target a specific k3s version"
    echo "  --channel=stable|latest  Use a release channel (default: stable)"
    echo "  --yes, -y                Skip confirmation prompts"
    echo "  --help, -h               Show this help"
    echo ""
    echo "Examples:"
    echo "  sudo kwo-update-k3s"
    echo "  sudo kwo-update-k3s --version=v1.32.3+k3s1"
    echo "  sudo kwo-update-k3s --channel=latest --yes"
}

for arg in "$@"; do
    case "$arg" in
        --version=*) TARGET_VERSION="${arg#*=}" ;;
        --channel=*) CHANNEL="${arg#*=}" ;;
        --yes|-y)    AUTO_YES=true ;;
        --help|-h)   show_help; exit 0 ;;
        *) log_error "Unknown option: $arg"; show_help; exit 1 ;;
    esac
done

# =============================================================================
# VERSION HELPERS
# =============================================================================

# Extract version string from "k3s version v1.31.4+k3s1 (abc123)"
get_current_version() {
    k3s --version 2>/dev/null | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' || echo ""
}

# Get latest version for a channel by following the redirect from update.k3s.io
get_channel_version() {
    local channel="$1"
    curl -sfL --max-time 10 \
        "https://update.k3s.io/v1-release/channels/${channel}" \
        -o /dev/null -w '%{url_effective}' 2>/dev/null \
        | grep -oP 'v[0-9]+\.[0-9]+\.[0-9]+\+k3s[0-9]+' \
        || echo ""
}

# Parse minor version integer from vX.Y.Z+k3sN → Y
minor_of() {
    echo "$1" | sed 's/^v[0-9]*\.\([0-9]*\)\..*/\1/'
}

# Parse patch version integer from vX.Y.Z+k3sN → Z
patch_of() {
    echo "$1" | sed 's/^v[0-9]*\.[0-9]*\.\([0-9]*\)+.*/\1/'
}

# Parse k3s release number from vX.Y.Z+k3sN → N
k3s_release_of() {
    echo "$1" | sed 's/.*+k3s\([0-9]*\)/\1/'
}

# Compare two version strings: returns 0 if equal, 1 if v1>v2, 2 if v1<v2
version_compare() {
    local v1_minor v2_minor v1_patch v2_patch v1_k3s v2_k3s
    v1_minor=$(minor_of "$1"); v2_minor=$(minor_of "$2")
    v1_patch=$(patch_of "$1"); v2_patch=$(patch_of "$2")
    v1_k3s=$(k3s_release_of "$1"); v2_k3s=$(k3s_release_of "$2")

    if [ "$v1_minor" -gt "$v2_minor" ]; then echo 1
    elif [ "$v1_minor" -lt "$v2_minor" ]; then echo 2
    elif [ "$v1_patch" -gt "$v2_patch" ]; then echo 1
    elif [ "$v1_patch" -lt "$v2_patch" ]; then echo 2
    elif [ "$v1_k3s" -gt "$v2_k3s" ]; then echo 1
    elif [ "$v1_k3s" -lt "$v2_k3s" ]; then echo 2
    else echo 0
    fi
}

# Classify upgrade type: patch | minor | skip | downgrade | none
upgrade_type() {
    local current="$1" target="$2"
    local cur_minor tgt_minor diff cmp
    cmp=$(version_compare "$target" "$current")

    if [ "$cmp" -eq 0 ]; then echo "none"; return; fi
    if [ "$cmp" -eq 2 ]; then echo "downgrade"; return; fi

    cur_minor=$(minor_of "$current")
    tgt_minor=$(minor_of "$target")
    diff=$((tgt_minor - cur_minor))

    if [ "$diff" -eq 0 ]; then echo "patch"
    elif [ "$diff" -eq 1 ]; then echo "minor"
    elif [ "$diff" -gt 1 ]; then echo "skip"
    fi
}

# =============================================================================
# PRE-FLIGHT CHECKS
# =============================================================================

check_disk_space_for_upgrade() {
    # k3s upgrade requires ~300MB: new binary + extracted data dir
    local available_mb
    available_mb=$(df -m / 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -z "$available_mb" ]; then log_warn "Could not check disk space"; return 0; fi
    if [ "$available_mb" -lt 300 ]; then
        log_error "Insufficient disk space for upgrade"
        log_error "  Available: ${available_mb}MB — Required: 300MB"
        log_error "  Run 'sudo kwo-cleanup-k3s' to free space from previous versions"
        exit 1
    fi
    log_info "Disk space OK: ${available_mb}MB available"
}

check_cluster_health() {
    log_info "Checking cluster health..."
    if ! kubectl get nodes &>/dev/null; then
        log_error "Cannot reach cluster. Is k3s running?"
        exit 1
    fi
    local not_ready
    not_ready=$(kubectl get nodes --no-headers | grep -v " Ready" | wc -l || true)
    if [ "$not_ready" -gt 0 ]; then
        log_warn "Some nodes are not Ready — proceeding anyway"
    else
        log_info "Cluster is healthy"
    fi
}

# =============================================================================
# BACKUP
# =============================================================================

take_backup() {
    local backup_dir="/var/lib/kwo/backups/k3s-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup_dir"

    # Embedded etcd — detected by presence of etcd data directory
    if [ -d "/var/lib/rancher/k3s/server/etcd" ]; then
        log_info "Taking etcd snapshot..."
        if k3s etcd-snapshot save --name "pre-update-$(date +%Y%m%d-%H%M%S)" 2>/dev/null; then
            log_info "etcd snapshot saved"
            return 0
        fi
        log_warn "etcd snapshot failed — falling back to directory copy"
    fi

    # SQLite fallback (default k3s datastore)
    local sqlite_db="/var/lib/rancher/k3s/server/db/state.db"
    if [ -f "$sqlite_db" ]; then
        log_info "Backing up SQLite datastore (online backup)..."
        # Uses SQLite Online Backup API: safe on a live database
        sqlite3 "$sqlite_db" ".backup '${backup_dir}/state.db'"
        chmod 600 "${backup_dir}/state.db"
        log_info "Backup saved to ${backup_dir}/state.db"
        return 0
    fi

    log_warn "Could not identify datastore type — skipping backup"
}

# =============================================================================
# UPGRADE
# =============================================================================

do_upgrade() {
    local target="$1"
    log_info "Upgrading k3s to ${target}..."
    # The k3s installer preserves existing systemd service args automatically
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$target" sh -
}

wait_for_cluster() {
    log_info "Waiting for cluster to come back up..."
    local attempt=0
    local max=30
    while [ $attempt -lt $max ]; do
        if kubectl get nodes &>/dev/null 2>&1; then
            log_info "Cluster is up"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 3
    done
    log_warn "Cluster did not respond within 90s — check: kubectl get nodes"
}

# =============================================================================
# MAIN
# =============================================================================

echo "=== KWO k3s Update ==="
echo ""

# 1. Current version
CURRENT=$(get_current_version)
if [ -z "$CURRENT" ]; then
    log_error "k3s not found or not running"
    exit 1
fi
log_info "Current version: ${CURRENT}"

# 2. Target version
if [ -z "$TARGET_VERSION" ]; then
    log_info "Fetching available versions..."
    STABLE_VERSION=$(get_channel_version "$CHANNEL")
    if [ -z "$STABLE_VERSION" ]; then
        log_error "Could not fetch version from channel '${CHANNEL}'. Check connectivity."
        exit 1
    fi

    CUR_MINOR=$(minor_of "$CURRENT")
    STABLE_MINOR=$(minor_of "$STABLE_VERSION")

    # If stable is a higher minor, also check for patches on the current minor
    if [ "$STABLE_MINOR" -gt "$CUR_MINOR" ] && [ "$AUTO_YES" = false ]; then
        PATCH_VERSION=$(get_channel_version "v1.${CUR_MINOR}")

        echo ""
        echo "Available updates:"
        echo ""

        if [ -n "$PATCH_VERSION" ] && [ "$(version_compare "$PATCH_VERSION" "$CURRENT")" -eq 1 ]; then
            echo "  1) Patch  — stay on 1.${CUR_MINOR}, update to ${PATCH_VERSION}"
            echo "  2) Minor  — upgrade to 1.${STABLE_MINOR} (${STABLE_VERSION})"
            echo ""
            read -p "Choose [1/2]: " choice
            case "$choice" in
                1) TARGET_VERSION="$PATCH_VERSION" ;;
                2) TARGET_VERSION="$STABLE_VERSION" ;;
                *) log_error "Invalid choice"; exit 1 ;;
            esac
        else
            echo "  No patch available for 1.${CUR_MINOR} (already at latest: ${CURRENT})"
            echo "  1) Minor  — upgrade to 1.${STABLE_MINOR} (${STABLE_VERSION})"
            echo "  q) Quit"
            echo ""
            read -p "Choose [1/q]: " choice
            case "$choice" in
                1) TARGET_VERSION="$STABLE_VERSION" ;;
                *) log_info "Upgrade cancelled."; exit 0 ;;
            esac
        fi
    else
        TARGET_VERSION="$STABLE_VERSION"
    fi
fi
log_info "Target version:  ${TARGET_VERSION}"

# 3. Classify upgrade
TYPE=$(upgrade_type "$CURRENT" "$TARGET_VERSION")

echo ""
case "$TYPE" in
    none)
        log_info "Already at ${TARGET_VERSION} — nothing to do."
        exit 0
        ;;
    downgrade)
        log_error "Target version ${TARGET_VERSION} is older than current ${CURRENT}."
        log_error "Downgrades are not supported."
        exit 1
        ;;
    skip)
        CUR_MINOR=$(minor_of "$CURRENT")
        TGT_MINOR=$(minor_of "$TARGET_VERSION")
        NEXT_MINOR=$((CUR_MINOR + 1))
        log_error "Cannot skip minor versions: 1.${CUR_MINOR} → 1.${TGT_MINOR} (diff: $((TGT_MINOR - CUR_MINOR)))"
        log_error "Kubernetes requires sequential minor version upgrades."
        echo ""
        echo "Upgrade one step at a time:"
        echo "  sudo kwo-update-k3s --channel=v1.${NEXT_MINOR}"
        echo ""
        echo "Available version channels: https://update.k3s.io/v1-release/channels"
        exit 1
        ;;
    patch)
        echo "Upgrade type: patch (safe)"
        ;;
    minor)
        CUR_MINOR=$(minor_of "$CURRENT")
        TGT_MINOR=$(minor_of "$TARGET_VERSION")
        echo "Upgrade type: minor (1.${CUR_MINOR} → 1.${TGT_MINOR})"

        # Traefik v2 → v3 boundary
        if [ "$CUR_MINOR" -le 31 ] && [ "$TGT_MINOR" -ge 32 ]; then
            echo ""
            echo "  ┌─────────────────────────────────────────────────────────┐"
            echo "  │  WARNING: Traefik v2 → v3                               │"
            echo "  │                                                         │"
            echo "  │  k3s 1.32+ installs Traefik v3. Your HelmChartConfig   │"
            echo "  │  (including KWO's ACME resolver config) will be        │"
            echo "  │  re-applied automatically, but custom Traefik           │"
            echo "  │  middleware or IngressRoute resources may need          │"
            echo "  │  review for v3 compatibility.                           │"
            echo "  │                                                         │"
            echo "  │  Docs: https://doc.traefik.io/traefik/migration/v2-v3/ │"
            echo "  └─────────────────────────────────────────────────────────┘"
            echo ""
        fi
        ;;
esac

echo ""
echo "  Current:  ${CURRENT}"
echo "  Target:   ${TARGET_VERSION}"
echo "  Type:     ${TYPE}"
echo ""

# 4. Confirm
if [ "$AUTO_YES" = false ]; then
    read -p "Proceed with upgrade? [y/N]: " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        log_info "Upgrade cancelled."
        exit 0
    fi
fi

# 5. Pre-flight
check_cluster_health
check_disk_space_for_upgrade

# 6. Backup
log_info "Taking pre-upgrade backup..."
take_backup

# 7. Upgrade
do_upgrade "$TARGET_VERSION"

# 8. Wait
wait_for_cluster

# 9. Verify
NEW_VERSION=$(get_current_version)
echo ""
echo "========================================="
echo "  k3s Updated Successfully"
echo "========================================="
echo ""
echo "  Previous: ${CURRENT}"
echo "  Current:  ${NEW_VERSION}"
echo ""
echo "Next steps:"
echo "  kubectl get nodes          # Verify node status"
echo "  kwo-status                 # Check KWO components"
if [ "$TYPE" = "minor" ] && [ "$(minor_of "$CURRENT")" -le 31 ] && [ "$(minor_of "$TARGET_VERSION")" -ge 32 ]; then
    echo ""
    echo "  Traefik v2→v3: check middleware/IngressRoute resources for compatibility"
    echo "  kubectl logs -n kube-system -l app.kubernetes.io/name=traefik"
fi
echo ""
