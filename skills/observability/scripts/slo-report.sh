#!/bin/bash
# slo-report.sh - Generate SLO compliance report
# Usage: ./slo-report.sh <service-name> [window] [target]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

SERVICE=${1:-""}
WINDOW=${2:-"30d"}
TARGET=${3:-"0.999"}

if [ -z "$SERVICE" ]; then
    echo "Usage: $0 <service-name> [window] [target]" >&2
    echo "" >&2
    echo "Generates an SLO compliance report for a service." >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  service-name  Service to report on" >&2
    echo "  window        Reporting window (default: 30d)" >&2
    echo "  target        SLO target (default: 0.999 = 99.9%)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 payment-service" >&2
    echo "  $0 payment-service 7d 0.995" >&2
    exit 1
fi

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

echo "=== SLO COMPLIANCE REPORT ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Service: $SERVICE" >&2
echo "Window: $WINDOW" >&2
echo "Target: $TARGET ($(echo "$TARGET * 100" | bc 2>/dev/null || echo "?")%)" >&2
echo "" >&2

# Discover Prometheus/Thanos endpoint
ENDPOINT="${THANOS_URL:-$PROMETHEUS_URL}"
AUTH_HEADER=""

if [ -z "$ENDPOINT" ]; then
    if [ "$CLI" == "oc" ]; then
        THANOS_HOST=$($CLI get route thanos-querier -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || echo "")
        if [ -n "$THANOS_HOST" ]; then
            ENDPOINT="https://$THANOS_HOST"
            TOKEN=$($CLI whoami -t 2>/dev/null || echo "")
            [ -n "$TOKEN" ] && AUTH_HEADER="-H 'Authorization: Bearer $TOKEN'"
        fi
    fi
fi

run_query() {
    local query="$1"
    if [ -n "$ENDPOINT" ]; then
        local result=$(eval curl -sk $AUTH_HEADER "${ENDPOINT}/api/v1/query" --data-urlencode "query=${query}" 2>/dev/null)
        echo "$result" | jq -r '.data.result[0].value[1] // "N/A"' 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

echo "### Availability SLI ###" >&2
# Availability = successful requests / total requests
AVAILABILITY_QUERY="1 - (sum(rate(http_requests_total{service=\"${SERVICE}\",status=~\"5..\"}[${WINDOW}])) / sum(rate(http_requests_total{service=\"${SERVICE}\"}[${WINDOW}])))"
AVAILABILITY=$(run_query "$AVAILABILITY_QUERY")
echo "  Current: $AVAILABILITY" >&2

echo -e "\n### Latency SLI ###" >&2
# Latency = requests under 300ms / total requests
LATENCY_QUERY="sum(rate(http_request_duration_seconds_bucket{service=\"${SERVICE}\",le=\"0.3\"}[${WINDOW}])) / sum(rate(http_request_duration_seconds_count{service=\"${SERVICE}\"}[${WINDOW}]))"
LATENCY_SLI=$(run_query "$LATENCY_QUERY")
echo "  Current (% under 300ms): $LATENCY_SLI" >&2

# P99 latency
P99_QUERY="histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{service=\"${SERVICE}\"}[${WINDOW}])) by (le))"
P99=$(run_query "$P99_QUERY")
echo "  P99 Latency: ${P99}s" >&2

# P95 latency
P95_QUERY="histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{service=\"${SERVICE}\"}[${WINDOW}])) by (le))"
P95=$(run_query "$P95_QUERY")
echo "  P95 Latency: ${P95}s" >&2

echo -e "\n### Error Budget ###" >&2
# Error budget = 1 - ((1 - availability) / (1 - target))
if [ "$AVAILABILITY" != "N/A" ]; then
    ERROR_BUDGET_QUERY="1 - ((1 - ($AVAILABILITY_QUERY)) / (1 - $TARGET))"
    ERROR_BUDGET=$(run_query "$ERROR_BUDGET_QUERY")
    echo "  Error Budget Remaining: $ERROR_BUDGET" >&2
    
    # Burn rate (1-hour window)
    BURN_RATE_QUERY="(1 - (sum(rate(http_requests_total{service=\"${SERVICE}\",status!~\"5..\"}[1h])) / sum(rate(http_requests_total{service=\"${SERVICE}\"}[1h])))) / (1 - $TARGET)"
    BURN_RATE=$(run_query "$BURN_RATE_QUERY")
    echo "  Current Burn Rate (1h): ${BURN_RATE}x" >&2
else
    ERROR_BUDGET="N/A"
    BURN_RATE="N/A"
fi

echo -e "\n### Request Volume ###" >&2
REQUEST_RATE_QUERY="sum(rate(http_requests_total{service=\"${SERVICE}\"}[${WINDOW}]))"
REQUEST_RATE=$(run_query "$REQUEST_RATE_QUERY")
echo "  Request Rate: ${REQUEST_RATE} req/s" >&2

ERROR_RATE_QUERY="sum(rate(http_requests_total{service=\"${SERVICE}\",status=~\"5..\"}[${WINDOW}]))"
ERROR_RATE=$(run_query "$ERROR_RATE_QUERY")
echo "  Error Rate: ${ERROR_RATE} err/s" >&2

echo -e "\n### Pod Health ###" >&2
# Get pod status from Kubernetes
PODS=$($CLI get pods -A -l "app=$SERVICE" -o json 2>/dev/null || $CLI get pods -A -l "app.kubernetes.io/name=$SERVICE" -o json 2>/dev/null || echo '{"items":[]}')
POD_TOTAL=$(echo "$PODS" | jq '.items | length')
POD_RUNNING=$(echo "$PODS" | jq '[.items[] | select(.status.phase == "Running")] | length')
POD_RESTARTS=$(echo "$PODS" | jq '[.items[].status.containerStatuses[]?.restartCount // 0] | add // 0')
echo "  Pods: $POD_RUNNING/$POD_TOTAL running" >&2
echo "  Total restarts: $POD_RESTARTS" >&2

# Determine compliance
COMPLIANT="unknown"
if [ "$AVAILABILITY" != "N/A" ]; then
    AV_FLOAT=$(echo "$AVAILABILITY" | awk '{printf "%.6f", $1}')
    TGT_FLOAT=$(echo "$TARGET" | awk '{printf "%.6f", $1}')
    if [ "$(echo "$AV_FLOAT >= $TGT_FLOAT" | bc -l 2>/dev/null)" == "1" ]; then
        COMPLIANT="true"
        echo -e "\n✅ SLO COMPLIANT" >&2
    else
        COMPLIANT="false"
        echo -e "\n❌ SLO BREACH" >&2
    fi
fi

# Summary
echo "" >&2
echo "========================================" >&2
echo "SLO REPORT SUMMARY" >&2
echo "  Service: $SERVICE" >&2
echo "  Window: $WINDOW" >&2
echo "  Target: $TARGET" >&2
echo "  Availability: $AVAILABILITY" >&2
echo "  Compliant: $COMPLIANT" >&2
echo "========================================" >&2

# Output JSON
cat << EOF
{
  "report_type": "slo-compliance",
  "service": "$SERVICE",
  "window": "$WINDOW",
  "target": $TARGET,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "slis": {
    "availability": "$AVAILABILITY",
    "latency_under_300ms": "$LATENCY_SLI",
    "p99_latency_seconds": "$P99",
    "p95_latency_seconds": "$P95"
  },
  "error_budget": {
    "remaining": "$ERROR_BUDGET",
    "burn_rate_1h": "$BURN_RATE"
  },
  "traffic": {
    "request_rate": "$REQUEST_RATE",
    "error_rate": "$ERROR_RATE"
  },
  "pods": {
    "total": $POD_TOTAL,
    "running": $POD_RUNNING,
    "restarts": $POD_RESTARTS
  },
  "compliant": $COMPLIANT
}
EOF

[ "$COMPLIANT" == "false" ] && exit 1
exit 0
