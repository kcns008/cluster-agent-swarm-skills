#!/bin/bash
# alert-triage.sh - Triage currently firing alerts
# Usage: ./alert-triage.sh [--severity critical|warning|info] [--namespace <ns>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

SEVERITY_FILTER=${1:-""}
NAMESPACE_FILTER=${2:-""}
CLI=$(command -v oc 2>/dev/null && echo "oc" || echo "kubectl")

# Parse flags
[[ "$SEVERITY_FILTER" == "--severity" ]] && SEVERITY_FILTER="$2" && NAMESPACE_FILTER="${3:-}"
[[ "$NAMESPACE_FILTER" == "--namespace" ]] && NAMESPACE_FILTER="${4:-}"

echo "=== ALERT TRIAGE ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "CLI: $CLI" >&2
[ -n "$SEVERITY_FILTER" ] && echo "Severity Filter: $SEVERITY_FILTER" >&2
[ -n "$NAMESPACE_FILTER" ] && echo "Namespace Filter: $NAMESPACE_FILTER" >&2
echo "" >&2

ALERTS_JSON="[]"

# Method 1: Try Prometheus Alertmanager API
ALERTMANAGER_URL="${ALERTMANAGER_URL:-""}"

# Try to discover Alertmanager URL
if [ -z "$ALERTMANAGER_URL" ]; then
    if [ "$CLI" == "oc" ]; then
        ALERTMANAGER_URL="https://$($CLI get route alertmanager-main -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || echo "")"
        TOKEN=$($CLI whoami -t 2>/dev/null || echo "")
    fi
fi

if [ -n "$ALERTMANAGER_URL" ] && [ "$ALERTMANAGER_URL" != "https://" ]; then
    echo "### Querying Alertmanager: $ALERTMANAGER_URL ###" >&2
    
    AUTH_HEADER=""
    [ -n "$TOKEN" ] && AUTH_HEADER="-H \"Authorization: Bearer $TOKEN\""
    
    ALERTS_RAW=$(curl -sk $AUTH_HEADER "${ALERTMANAGER_URL}/api/v2/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null || echo "[]")
    
    if [ "$ALERTS_RAW" != "[]" ] && echo "$ALERTS_RAW" | jq '.' &>/dev/null; then
        ALERTS_JSON="$ALERTS_RAW"
    fi
fi

# Method 2: Try Prometheus API directly
PROMETHEUS_URL="${PROMETHEUS_URL:-""}"

if [ "$ALERTS_JSON" == "[]" ]; then
    if [ -z "$PROMETHEUS_URL" ]; then
        if [ "$CLI" == "oc" ]; then
            PROMETHEUS_URL="https://$($CLI get route prometheus-k8s -n openshift-monitoring -o jsonpath='{.spec.host}' 2>/dev/null || echo "")"
            TOKEN=$($CLI whoami -t 2>/dev/null || echo "")
        fi
    fi
    
    if [ -n "$PROMETHEUS_URL" ] && [ "$PROMETHEUS_URL" != "https://" ]; then
        echo "### Querying Prometheus: $PROMETHEUS_URL ###" >&2
        AUTH_HEADER=""
        [ -n "$TOKEN" ] && AUTH_HEADER="-H \"Authorization: Bearer $TOKEN\""
        
        ALERTS_RAW=$(curl -sk $AUTH_HEADER "${PROMETHEUS_URL}/api/v1/alerts" 2>/dev/null || echo "")
        if [ -n "$ALERTS_RAW" ]; then
            ALERTS_JSON=$(echo "$ALERTS_RAW" | jq '.data.alerts // []' 2>/dev/null || echo "[]")
        fi
    fi
fi

# Method 3: Check PrometheusRule resources for defined alerts
echo "### Checking PrometheusRule Resources ###" >&2
PROM_RULES=$($CLI get prometheusrules -A -o json 2>/dev/null || echo '{"items":[]}')
RULE_COUNT=$(echo "$PROM_RULES" | jq '.items | length')
echo "  Found $RULE_COUNT PrometheusRule resources" >&2

# Method 4: Check recent warning events as proxy for alerts
echo -e "\n### Recent Warning Events ###" >&2
EVENTS=$($CLI get events -A --field-selector type=Warning --sort-by='.lastTimestamp' -o json 2>/dev/null || echo '{"items":[]}')
EVENT_COUNT=$(echo "$EVENTS" | jq '.items | length')

# Deduplicate events by reason
echo "$EVENTS" | jq -r '.items[-20:] | .[] | "  ⚠️  [\(.involvedObject.namespace // "cluster")/\(.involvedObject.name)] \(.reason): \(.message)"' 2>/dev/null >&2 || true
echo "  Total warning events: $EVENT_COUNT" >&2

# Parse alerts
echo -e "\n### Currently Firing Alerts ###" >&2

CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0
TOTAL_ALERTS=0

PARSED_ALERTS="[]"

if [ "$ALERTS_JSON" != "[]" ]; then
    # Apply filters
    FILTER="."
    [ -n "$SEVERITY_FILTER" ] && FILTER="$FILTER | select(.labels.severity == \"$SEVERITY_FILTER\")"
    [ -n "$NAMESPACE_FILTER" ] && FILTER="$FILTER | select(.labels.namespace == \"$NAMESPACE_FILTER\")"
    
    PARSED_ALERTS=$(echo "$ALERTS_JSON" | jq "[.[] | $FILTER | {
        alertname: (.labels.alertname // \"unknown\"),
        severity: (.labels.severity // \"unknown\"),
        namespace: (.labels.namespace // \"cluster\"),
        service: (.labels.service // .labels.job // \"unknown\"),
        summary: (.annotations.summary // .annotations.description // \"No description\"),
        starts_at: (.startsAt // .activeAt // \"unknown\"),
        state: (.state // \"firing\")
    }]" 2>/dev/null || echo "[]")
    
    TOTAL_ALERTS=$(echo "$PARSED_ALERTS" | jq 'length')
    CRITICAL_COUNT=$(echo "$PARSED_ALERTS" | jq '[.[] | select(.severity == "critical")] | length')
    WARNING_COUNT=$(echo "$PARSED_ALERTS" | jq '[.[] | select(.severity == "warning")] | length')
    INFO_COUNT=$(echo "$PARSED_ALERTS" | jq '[.[] | select(.severity == "info" or .severity == "none")] | length')
    
    # Display alerts grouped by severity
    if [ "$CRITICAL_COUNT" -gt 0 ]; then
        echo "🔴 CRITICAL ($CRITICAL_COUNT):" >&2
        echo "$PARSED_ALERTS" | jq -r '.[] | select(.severity == "critical") | "  [\(.namespace)] \(.alertname): \(.summary)"' >&2
    fi
    
    if [ "$WARNING_COUNT" -gt 0 ]; then
        echo "🟡 WARNING ($WARNING_COUNT):" >&2
        echo "$PARSED_ALERTS" | jq -r '.[] | select(.severity == "warning") | "  [\(.namespace)] \(.alertname): \(.summary)"' >&2
    fi
    
    if [ "$INFO_COUNT" -gt 0 ]; then
        echo "🔵 INFO ($INFO_COUNT):" >&2
        echo "$PARSED_ALERTS" | jq -r '.[] | select(.severity == "info" or .severity == "none") | "  [\(.namespace)] \(.alertname): \(.summary)"' >&2
    fi
else
    echo "  No active alerts found (or unable to connect to Alertmanager/Prometheus)" >&2
fi

# Summary
echo "" >&2
echo "========================================" >&2
echo "ALERT TRIAGE SUMMARY" >&2
echo "  🔴 Critical: $CRITICAL_COUNT" >&2
echo "  🟡 Warning:  $WARNING_COUNT" >&2
echo "  🔵 Info:     $INFO_COUNT" >&2
echo "  Total:       $TOTAL_ALERTS alerts" >&2
echo "  Events:      $EVENT_COUNT warnings" >&2
echo "========================================" >&2

# Output JSON
cat << EOF
{
  "triage_type": "alert",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "summary": {
    "critical": $CRITICAL_COUNT,
    "warning": $WARNING_COUNT,
    "info": $INFO_COUNT,
    "total_alerts": $TOTAL_ALERTS,
    "warning_events": $EVENT_COUNT
  },
  "alerts": $PARSED_ALERTS
}
EOF

[ "$CRITICAL_COUNT" -gt 0 ] && exit 2
[ "$WARNING_COUNT" -gt 0 ] && exit 1
exit 0
