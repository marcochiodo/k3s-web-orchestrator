#!/usr/bin/env bash
set -euo pipefail

COMPONENT="${1:-}"
FOLLOW=false
TAIL=""

for arg in "$@"; do
    case "$arg" in
        --follow) FOLLOW=true ;;
        --tail=*) TAIL="--tail=${arg#*=}" ;;
    esac
done

[ -z "$COMPONENT" ] && { echo "Usage: $0 <traefik|k3s|tenant:name> [--follow] [--tail=N]"; exit 1; }

case "$COMPONENT" in
    traefik)
        kubectl logs -n kube-system -l app.kubernetes.io/name=traefik $TAIL ${FOLLOW:+--follow}
        ;;
    k3s)
        journalctl -u k3s ${TAIL/--tail=/--lines=} ${FOLLOW:+-f} --no-pager
        ;;
    tenant:*)
        tenant="${COMPONENT#tenant:}"
        kubectl logs -n "$tenant" --all-containers=true $TAIL ${FOLLOW:+--follow}
        ;;
    *)
        echo "Unknown component: $COMPONENT"
        exit 1
        ;;
esac
