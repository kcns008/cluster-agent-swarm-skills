#!/bin/bash
# drift-detect.sh - Detect configuration drift across ArgoCD applications
# Usage: ./drift-detect.sh [app-name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

APP=${1:-""}

echo "=== CONFIGURATION DRIFT DETECTION ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "" >&2

DRIFTED_APPS=()
TOTAL_APPS=0
SYNCED_APPS=0
CLI=""

if [ -n "$APP" ]; then
    # Check specific app
    echo "### Checking: $APP ###" >&2
    if command -v argocd &> /dev/null; then
        SYNC_STATUS=$(argocd app get "$APP" -o json | jq -r '.status.sync.status')
        HEALTH_STATUS=$(argocd app get "$APP" -o json | jq -r '.status.health.status')
        
        if [ "$SYNC_STATUS" != "Synced" ]; then
            echo "⚠️  DRIFT DETECTED: $APP (Sync: $SYNC_STATUS, Health: $HEALTH_STATUS)" >&2
            argocd app diff "$APP" >&2 || true
            DRIFTED_APPS+=("$APP")
        else
            echo "✓ $APP is synced" >&2
            SYNCED_APPS=1
        fi
        TOTAL_APPS=1
    else
        CLI=$(detect_kube_cli)
        ensure_cluster_access "$CLI"
        SYNC_STATUS=$($CLI get application "$APP" -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null)
        HEALTH_STATUS=$($CLI get application "$APP" -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null)
        
        if [ "$SYNC_STATUS" != "Synced" ]; then
            echo "⚠️  DRIFT DETECTED: $APP (Sync: $SYNC_STATUS, Health: $HEALTH_STATUS)" >&2
            DRIFTED_APPS+=("$APP")
        else
            echo "✓ $APP is synced" >&2
            SYNCED_APPS=1
        fi
        TOTAL_APPS=1
    fi
else
    # Check all apps
    echo "### Checking All Applications ###" >&2
    
    if command -v argocd &> /dev/null; then
        APPS_JSON=$(argocd app list -o json 2>/dev/null)
        TOTAL_APPS=$(echo "$APPS_JSON" | jq 'length')
        
        echo "$APPS_JSON" | jq -r '.[] | "\(.metadata.name)\t\(.status.sync.status)\t\(.status.health.status)"' | while IFS=$'\t' read -r name sync health; do
            if [ "$sync" != "Synced" ]; then
                echo "⚠️  DRIFT: $name (Sync: $sync, Health: $health)" >&2
            fi
        done
        
        SYNCED_APPS=$(echo "$APPS_JSON" | jq '[.[] | select(.status.sync.status=="Synced")] | length')
        DRIFTED_COUNT=$((TOTAL_APPS - SYNCED_APPS))
        
        # Collect drifted app names
        DRIFTED_LIST=$(echo "$APPS_JSON" | jq -r '.[] | select(.status.sync.status != "Synced") | .metadata.name')
        if [ -n "$DRIFTED_LIST" ]; then
            while IFS= read -r app; do
                DRIFTED_APPS+=("$app")
            done <<< "$DRIFTED_LIST"
        fi
    else
        CLI=$(detect_kube_cli)
        ensure_cluster_access "$CLI"
        APPS=$($CLI get applications -n argocd -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.sync.status}{"\t"}{.status.health.status}{"\n"}{end}' 2>/dev/null)
        TOTAL_APPS=$(echo "$APPS" | grep -c "." || echo 0)
        
        while IFS=$'\t' read -r name sync health; do
            if [ -n "$name" ]; then
                if [ "$sync" != "Synced" ]; then
                    echo "⚠️  DRIFT: $name (Sync: $sync, Health: $health)" >&2
                    DRIFTED_APPS+=("$name")
                else
                    SYNCED_APPS=$((SYNCED_APPS + 1))
                fi
            fi
        done <<< "$APPS"
    fi
fi

DRIFTED_COUNT=${#DRIFTED_APPS[@]}

echo "" >&2
echo "========================================" >&2
echo "DRIFT DETECTION SUMMARY" >&2
echo "========================================" >&2
echo "Total apps: $TOTAL_APPS" >&2
echo "Synced: $SYNCED_APPS" >&2
echo "Drifted: $DRIFTED_COUNT" >&2

if [ "$DRIFTED_COUNT" -eq 0 ]; then
    echo "✅ No drift detected" >&2
else
    echo "⚠️  $DRIFTED_COUNT applications have drift" >&2
fi

# Output JSON
DRIFTED_JSON=$(printf '%s\n' "${DRIFTED_APPS[@]}" | jq -R . 2>/dev/null | jq -s . 2>/dev/null || echo "[]")
cat << EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "total_apps": $TOTAL_APPS,
  "synced_apps": $SYNCED_APPS,
  "drifted_apps": $DRIFTED_COUNT,
  "drifted_app_names": $DRIFTED_JSON,
  "drift_free": $([ "$DRIFTED_COUNT" -eq 0 ] && echo "true" || echo "false")
}
EOF
