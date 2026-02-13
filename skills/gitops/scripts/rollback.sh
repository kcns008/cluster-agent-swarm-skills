#!/bin/bash
# rollback.sh - Safe deployment rollback
# Usage: ./rollback.sh <app-name> [revision]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

APP=${1:-""}
REVISION=${2:-""}

if [ -z "$APP" ]; then
    echo "Usage: $0 <app-name> [revision]" >&2
    echo "" >&2
    echo "Rolls back an application to a previous revision." >&2
    echo "If no revision specified, rolls back to the last successful sync." >&2
    exit 1
fi

echo "=== DEPLOYMENT ROLLBACK: $APP ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "" >&2

# Check current status
echo "### Current Application Status ###" >&2
if command -v argocd &> /dev/null; then
    argocd app get "$APP" >&2
    
    # Show history
    echo -e "\n### Deployment History ###" >&2
    argocd app history "$APP" >&2
    
    CURRENT_REV=$(argocd app get "$APP" -o json | jq -r '.status.sync.revision' 2>/dev/null || echo "unknown")
    CURRENT_STATUS=$(argocd app get "$APP" -o json | jq -r '.status.sync.status' 2>/dev/null || echo "unknown")
    CURRENT_HEALTH=$(argocd app get "$APP" -o json | jq -r '.status.health.status' 2>/dev/null || echo "unknown")
    
    echo "" >&2
    echo "Current revision: $CURRENT_REV" >&2
    echo "Sync status: $CURRENT_STATUS" >&2
    echo "Health: $CURRENT_HEALTH" >&2
    
    # Perform rollback
    echo -e "\n### Performing Rollback ###" >&2
    if [ -n "$REVISION" ]; then
        echo "Rolling back to revision: $REVISION" >&2
        argocd app rollback "$APP" "$REVISION" >&2
    else
        # Rollback to previous
        PREV_REVISION=$(argocd app history "$APP" -o json | jq -r '.[-2].id // empty' 2>/dev/null)
        if [ -n "$PREV_REVISION" ]; then
            echo "Rolling back to previous revision: $PREV_REVISION" >&2
            argocd app rollback "$APP" "$PREV_REVISION" >&2
        else
            echo "Error: Could not determine previous revision" >&2
            exit 1
        fi
        REVISION=${PREV_REVISION:-"previous"}
    fi
    
    # Wait for health
    echo -e "\n### Waiting for Health ###" >&2
    argocd app wait "$APP" --health --timeout 300 >&2
    
    NEW_STATUS=$(argocd app get "$APP" -o json | jq -r '.status.sync.status' 2>/dev/null || echo "unknown")
    NEW_HEALTH=$(argocd app get "$APP" -o json | jq -r '.status.health.status' 2>/dev/null || echo "unknown")
    NEW_REV=$(argocd app get "$APP" -o json | jq -r '.status.sync.revision' 2>/dev/null || echo "unknown")
    
else
    echo "argocd CLI not available. Using kubectl for rollback." >&2
    CLI=$(detect_kube_cli)
    ensure_cluster_access "$CLI"
    
    # Try Kubernetes Deployment rollback
    NAMESPACE=$($CLI get applications "$APP" -n argocd -o jsonpath='{.spec.destination.namespace}' 2>/dev/null || echo "default")
    
    echo "Namespace: $NAMESPACE" >&2
    
    if $CLI get deployment "$APP" -n "$NAMESPACE" &>/dev/null; then
        echo "Rolling back Deployment..." >&2
        if [ -n "$REVISION" ]; then
            $CLI rollout undo deployment/"$APP" -n "$NAMESPACE" --to-revision="$REVISION" >&2
        else
            $CLI rollout undo deployment/"$APP" -n "$NAMESPACE" >&2
        fi
        $CLI rollout status deployment/"$APP" -n "$NAMESPACE" --timeout=300s >&2
    fi
    
    NEW_STATUS="unknown"
    NEW_HEALTH="unknown"
    NEW_REV="${REVISION:-previous}"
    CURRENT_REV="unknown"
fi

echo "" >&2
echo "========================================" >&2
echo "ROLLBACK COMPLETE" >&2
echo "========================================" >&2

# Output JSON
cat << EOF
{
  "application": "$APP",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "previous_revision": "$CURRENT_REV",
  "rollback_to_revision": "$REVISION",
  "new_sync_status": "$NEW_STATUS",
  "new_health_status": "$NEW_HEALTH",
  "success": true
}
EOF
