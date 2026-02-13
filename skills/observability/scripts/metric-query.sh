#!/bin/bash
# metric-query.sh - Execute PromQL queries against Prometheus/Thanos
# Usage: ./metric-query.sh <promql-query> [--range 1h] [--step 60]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

QUERY=${1:-""}
RANGE=${2:-""}
STEP=${3:-"60"}

if [ -z "$QUERY" ]; then
    echo "Usage: $0 <promql-query> [--range <duration>] [--step <seconds>]" >&2
    echo "" >&2
    echo "Executes a PromQL query against Prometheus or Thanos." >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  query     PromQL expression (quote complex queries)" >&2
    echo "  --range   Time range for range queries (e.g., 1h, 30m, 24h)" >&2
    echo "  --step    Step interval for range queries (default: 60s)" >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  PROMETHEUS_URL  Prometheus endpoint (auto-detected on OpenShift)" >&2
    echo "  THANOS_URL      Thanos querier endpoint (preferred if set)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 'up'" >&2
    echo "  $0 'rate(http_requests_total[5m])' --range 1h" >&2
    echo "  $0 'histogram_quantile(0.99, rate(http_request_duration_seconds_bucket[5m]))'" >&2
    exit 1
fi

# Parse flags
[[ "$RANGE" == "--range" ]] && RANGE="$3" && STEP="${4:-60}"
[[ "$STEP" == "--step" ]] && STEP="${5:-60}"

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

echo "=== METRIC QUERY ===" >&2
echo "Query: $QUERY" >&2
[ -n "$RANGE" ] && echo "Range: $RANGE" >&2
echo "" >&2

# Discover endpoint
ENDPOINT="${THANOS_URL:-$PROMETHEUS_URL}"
AUTH_HEADER=""

if [ -z "$ENDPOINT" ]; then
    if [ "$CLI" == "oc" ]; then
        # Try Thanos first (multi-cluster), then Prometheus
        THANOS_HOST=$($CLI get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [ -n "$THANOS_HOST" ]; then
            ENDPOINT="https://$THANOS_HOST"
        else
            PROM_HOST=$($CLI get route prometheus-k8s -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
            [ -n "$PROM_HOST" ] && ENDPOINT="https://$PROM_HOST"
        fi
        TOKEN=$($CLI whoami -t 2>/dev/null || echo "")
        [ -n "$TOKEN" ] && AUTH_HEADER="Authorization: Bearer $TOKEN"
    fi
fi

if [ -z "$ENDPOINT" ]; then
    # Try port-forward as fallback
    echo "No Prometheus endpoint found. Trying kubectl port-forward..." >&2
    
    PROM_SVC=$($CLI get svc -n monitoring -l app.kubernetes.io/name=prometheus --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1 || echo "")
    [ -z "$PROM_SVC" ] && PROM_SVC=$($CLI get svc -n openshift-monitoring -l app.kubernetes.io/name=prometheus --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | head -1 || echo "")
    
    if [ -z "$PROM_SVC" ]; then
        blocked_error "Cannot find Prometheus. Set PROMETHEUS_URL or THANOS_URL environment variable."
    fi
    
    echo "Found Prometheus service: $PROM_SVC" >&2
    echo "Note: Set PROMETHEUS_URL=http://localhost:9090 after port-forwarding" >&2
    exit 2
fi

echo "Endpoint: $ENDPOINT" >&2

# Execute query
CURL_OPTS="-sk"
[ -n "$AUTH_HEADER" ] && CURL_OPTS="$CURL_OPTS -H '$AUTH_HEADER'"

if [ -n "$RANGE" ]; then
    # Range query
    # Convert duration to seconds for start time calculation
    NOW=$(date -u +%s)
    case "$RANGE" in
        *h) SECONDS_AGO=$(( ${RANGE%h} * 3600 )) ;;
        *m) SECONDS_AGO=$(( ${RANGE%m} * 60 )) ;;
        *d) SECONDS_AGO=$(( ${RANGE%d} * 86400 )) ;;
        *s) SECONDS_AGO=${RANGE%s} ;;
        *) SECONDS_AGO=3600 ;;
    esac
    START=$((NOW - SECONDS_AGO))
    
    echo "Range: $(date -u -r $START +%Y-%m-%dT%H:%M:%SZ) → $(date -u -r $NOW +%Y-%m-%dT%H:%M:%SZ)" >&2
    echo "Step: ${STEP}s" >&2
    echo "" >&2
    
    RESULT=$(eval curl $CURL_OPTS \
        "${ENDPOINT}/api/v1/query_range" \
        --data-urlencode "query=${QUERY}" \
        --data-urlencode "start=${START}" \
        --data-urlencode "end=${NOW}" \
        --data-urlencode "step=${STEP}" 2>/dev/null)
else
    # Instant query
    RESULT=$(eval curl $CURL_OPTS \
        "${ENDPOINT}/api/v1/query" \
        --data-urlencode "query=${QUERY}" 2>/dev/null)
fi

# Check result
STATUS=$(echo "$RESULT" | jq -r '.status' 2>/dev/null || echo "error")

if [ "$STATUS" == "success" ]; then
    RESULT_TYPE=$(echo "$RESULT" | jq -r '.data.resultType' 2>/dev/null || echo "unknown")
    RESULT_COUNT=$(echo "$RESULT" | jq '.data.result | length' 2>/dev/null || echo "0")
    
    echo "Status: success" >&2
    echo "Type: $RESULT_TYPE" >&2
    echo "Results: $RESULT_COUNT series" >&2
    echo "" >&2
    
    # Display results in human-readable format on stderr
    case "$RESULT_TYPE" in
        vector)
            echo "### Current Values ###" >&2
            echo "$RESULT" | jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(", ")): \(.value[1])"' 2>/dev/null >&2
            ;;
        matrix)
            echo "### Series ###" >&2
            echo "$RESULT" | jq -r '.data.result[] | "\(.metric | to_entries | map("\(.key)=\(.value)") | join(", ")): \(.values | length) data points"' 2>/dev/null >&2
            ;;
        scalar)
            echo "### Value ###" >&2
            echo "$RESULT" | jq -r '.data.result[1]' 2>/dev/null >&2
            ;;
    esac
    
    # Output full JSON to stdout
    echo "$RESULT" | jq .
else
    ERROR=$(echo "$RESULT" | jq -r '.error // "Unknown error"' 2>/dev/null)
    echo "ERROR: Query failed — $ERROR" >&2
    echo "$RESULT" | jq . 2>/dev/null || echo "$RESULT"
    exit 1
fi
