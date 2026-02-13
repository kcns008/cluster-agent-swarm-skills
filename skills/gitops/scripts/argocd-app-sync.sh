#!/bin/bash
# argocd-app-sync.sh - ArgoCD application sync helper
# Usage: ./argocd-app-sync.sh <app-name> [--prune] [--force]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

APP=${1:-""}
PRUNE=${2:-""}
FORCE=${3:-""}

if [ -z "$APP" ]; then
    echo "Usage: $0 <app-name> [--prune] [--force]" >&2
    echo "" >&2
    echo "Available applications:" >&2
    argocd app list --output name 2>/dev/null || kubectl get applications -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null
    exit 1
fi

echo "=== ARGOCD APPLICATION SYNC: $APP ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "" >&2

# Check if argocd CLI is available
if command -v argocd &> /dev/null; then
    USE_CLI=true
else
    USE_CLI=false
    echo "argocd CLI not found, using kubectl" >&2
    CLI=$(detect_kube_cli)
    ensure_cluster_access "$CLI"
fi

# Get current status
echo "### Current Status ###" >&2
if [ "$USE_CLI" = true ]; then
    argocd app get "$APP" --refresh >&2
else
    $CLI get application "$APP" -n argocd -o yaml | grep -A20 "status:" | head -25 >&2
fi

# Build sync options
SYNC_OPTS=""
if [ "$PRUNE" == "--prune" ]; then
    SYNC_OPTS="$SYNC_OPTS --prune"
    echo "Prune enabled: Will remove resources not defined in Git" >&2
fi
if [ "$FORCE" == "--force" ]; then
    SYNC_OPTS="$SYNC_OPTS --force"
    echo "Force enabled: Will replace resources that cannot be patched" >&2
fi

# Perform sync
echo -e "\n### Syncing Application ###" >&2
if [ "$USE_CLI" = true ]; then
    argocd app sync "$APP" $SYNC_OPTS >&2
else
    $CLI patch application "$APP" -n argocd --type=merge -p '{"operation":{"sync":{"revision":"HEAD"}}}' >&2
fi

# Wait for sync to complete
echo -e "\n### Waiting for Sync ###" >&2
if [ "$USE_CLI" = true ]; then
    argocd app wait "$APP" --health --timeout 300 >&2
else
    echo "Waiting for sync (check manually with kubectl)..." >&2
    sleep 10
fi

# Final status
echo -e "\n### Final Status ###" >&2
if [ "$USE_CLI" = true ]; then
    argocd app get "$APP" >&2
    STATUS=$(argocd app get "$APP" -o json | jq -r '.status.sync.status')
    HEALTH=$(argocd app get "$APP" -o json | jq -r '.status.health.status')
else
    $CLI get application "$APP" -n argocd -o yaml | grep -A20 "status:" | head -25 >&2
    STATUS=$($CLI get application "$APP" -n argocd -o jsonpath='{.status.sync.status}')
    HEALTH=$($CLI get application "$APP" -n argocd -o jsonpath='{.status.health.status}')
fi

echo "" >&2
echo "========================================" >&2
echo "SYNC COMPLETE" >&2
echo "========================================" >&2
echo "Sync Status: $STATUS" >&2
echo "Health Status: $HEALTH" >&2

# Output JSON
cat << EOF
{
  "application": "$APP",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "sync_status": "$STATUS",
  "health_status": "$HEALTH",
  "prune": $([ "$PRUNE" == "--prune" ] && echo "true" || echo "false"),
  "force": $([ "$FORCE" == "--force" ] && echo "true" || echo "false"),
  "success": $([ "$STATUS" == "Synced" ] && echo "true" || echo "false")
}
EOF
