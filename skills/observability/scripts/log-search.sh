#!/bin/bash
# log-search.sh - Search logs via Loki, OpenShift logging, or kubectl
# Usage: ./log-search.sh <namespace> <app-name> <search-pattern> [--since 30m]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

NAMESPACE=${1:-""}
APP=${2:-""}
PATTERN=${3:-""}
SINCE=${4:-"30m"}

if [ -z "$NAMESPACE" ] || [ -z "$APP" ]; then
    echo "Usage: $0 <namespace> <app-name> [search-pattern] [--since <duration>]" >&2
    echo "" >&2
    echo "Searches application logs using Loki (preferred), OpenShift logging, or kubectl." >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  namespace       Kubernetes namespace" >&2
    echo "  app-name        Application name (label selector)" >&2
    echo "  search-pattern  Text pattern or regex to search for (default: all)" >&2
    echo "  --since         Time window (default: 30m)" >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  LOKI_URL     Loki endpoint (auto-detected on OpenShift)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 production payment-service 'error|exception'" >&2
    echo "  $0 production payment-service 'timeout' --since 1h" >&2
    exit 1
fi

[[ "$SINCE" == "--since" ]] && SINCE="${5:-30m}"

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

echo "=== LOG SEARCH ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Namespace: $NAMESPACE" >&2
echo "Application: $APP" >&2
echo "Pattern: ${PATTERN:-all logs}" >&2
echo "Since: $SINCE" >&2
echo "CLI: $CLI" >&2
echo "" >&2

LOG_SOURCE="unknown"
LOG_LINES=()

# Method 1: Try Loki
LOKI_URL="${LOKI_URL:-""}"
if [ -z "$LOKI_URL" ] && [ "$CLI" == "oc" ]; then
    LOKI_HOST=$($CLI get route logging-loki -n openshift-logging -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
    [ -n "$LOKI_HOST" ] && LOKI_URL="https://$LOKI_HOST"
fi

if [ -n "$LOKI_URL" ]; then
    echo "### Querying Loki: $LOKI_URL ###" >&2
    LOG_SOURCE="loki"
    
    TOKEN=""
    [ "$CLI" == "oc" ] && TOKEN=$($CLI whoami -t 2>/dev/null || echo "")
    
    AUTH=""
    [ -n "$TOKEN" ] && AUTH="-H 'Authorization: Bearer $TOKEN'"
    
    # Build LogQL query
    if [ -n "$PATTERN" ]; then
        LOGQL="{namespace=\"$NAMESPACE\", app=\"$APP\"} |~ \"$PATTERN\""
    else
        LOGQL="{namespace=\"$NAMESPACE\", app=\"$APP\"}"
    fi
    
    # Calculate time range
    NOW=$(date -u +%s)
    case "$SINCE" in
        *h) START=$((NOW - ${SINCE%h} * 3600)) ;;
        *m) START=$((NOW - ${SINCE%m} * 60)) ;;
        *d) START=$((NOW - ${SINCE%d} * 86400)) ;;
        *) START=$((NOW - 1800)) ;;
    esac
    
    LOKI_RESULT=$(eval curl -sk $AUTH \
        "${LOKI_URL}/loki/api/v1/query_range" \
        --data-urlencode "query=${LOGQL}" \
        --data-urlencode "start=${START}000000000" \
        --data-urlencode "end=${NOW}000000000" \
        --data-urlencode "limit=500" 2>/dev/null || echo "")
    
    if [ -n "$LOKI_RESULT" ] && echo "$LOKI_RESULT" | jq '.status' &>/dev/null; then
        RESULT_COUNT=$(echo "$LOKI_RESULT" | jq '[.data.result[].values[]] | length' 2>/dev/null || echo "0")
        echo "  Found $RESULT_COUNT log entries" >&2
        
        # Display logs
        echo "" >&2
        echo "$LOKI_RESULT" | jq -r '.data.result[].values[][] | .[1]' 2>/dev/null | head -100 >&2
        
        # Output JSON
        echo "$LOKI_RESULT" | jq '{
            source: "loki",
            query: "'"$LOGQL"'",
            timestamp: "'"$(date -u +"%Y-%m-%dT%H:%M:%SZ")"'",
            result_count: (.data.result | map(.values | length) | add // 0),
            results: [.data.result[].values[][] | {timestamp: .[0], line: .[1]}][:100]
        }'
        exit 0
    else
        echo "  Loki query failed, falling back..." >&2
    fi
fi

# Method 2: kubectl logs
echo "### Querying via kubectl logs ###" >&2
LOG_SOURCE="kubectl"

# Find pods matching the app label
PODS=$($CLI get pods -n "$NAMESPACE" -l "app=$APP" --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase 2>/dev/null || \
       $CLI get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$APP" --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase 2>/dev/null || echo "")

if [ -z "$PODS" ]; then
    echo "  No pods found with label app=$APP or app.kubernetes.io/name=$APP in $NAMESPACE" >&2
    # Try broader search
    PODS=$($CLI get pods -n "$NAMESPACE" --no-headers -o custom-columns=NAME:.metadata.name,STATUS:.status.phase 2>/dev/null | grep "$APP" || echo "")
fi

if [ -z "$PODS" ]; then
    echo "  ERROR: No pods found matching '$APP' in namespace '$NAMESPACE'" >&2
    cat << EOF
{
  "source": "kubectl",
  "error": "No pods found matching '$APP' in namespace '$NAMESPACE'",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
    exit 1
fi

POD_COUNT=$(echo "$PODS" | wc -l | tr -d ' ')
echo "  Found $POD_COUNT pod(s)" >&2

# Collect logs from all pods
ALL_LOGS=""
TOTAL_LINES=0

while IFS= read -r line; do
    POD_NAME=$(echo "$line" | awk '{print $1}')
    [ -z "$POD_NAME" ] && continue
    
    echo "  Fetching logs from: $POD_NAME" >&2
    
    POD_LOGS=$($CLI logs "$POD_NAME" -n "$NAMESPACE" --since="$SINCE" --tail=500 2>/dev/null || echo "")
    
    if [ -n "$PATTERN" ] && [ -n "$POD_LOGS" ]; then
        FILTERED=$(echo "$POD_LOGS" | grep -iE "$PATTERN" || echo "")
        if [ -n "$FILTERED" ]; then
            LINE_COUNT=$(echo "$FILTERED" | wc -l | tr -d ' ')
            echo "    Matched $LINE_COUNT lines" >&2
            echo "$FILTERED" >&2
            ALL_LOGS="${ALL_LOGS}${FILTERED}\n"
            TOTAL_LINES=$((TOTAL_LINES + LINE_COUNT))
        else
            echo "    No matches for pattern '$PATTERN'" >&2
        fi
    elif [ -n "$POD_LOGS" ]; then
        LINE_COUNT=$(echo "$POD_LOGS" | wc -l | tr -d ' ')
        echo "    $LINE_COUNT lines (showing last 50)" >&2
        echo "$POD_LOGS" | tail -50 >&2
        ALL_LOGS="${ALL_LOGS}${POD_LOGS}\n"
        TOTAL_LINES=$((TOTAL_LINES + LINE_COUNT))
    fi
done <<< "$PODS"

# Summary
echo "" >&2
echo "========================================" >&2
echo "LOG SEARCH COMPLETE" >&2
echo "  Source: $LOG_SOURCE" >&2
echo "  Pods searched: $POD_COUNT" >&2
echo "  Total matching lines: $TOTAL_LINES" >&2
echo "========================================" >&2

# Output JSON
cat << EOF
{
  "source": "$LOG_SOURCE",
  "namespace": "$NAMESPACE",
  "application": "$APP",
  "search_pattern": "$PATTERN",
  "since": "$SINCE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "pods_searched": $POD_COUNT,
  "total_matching_lines": $TOTAL_LINES
}
EOF
