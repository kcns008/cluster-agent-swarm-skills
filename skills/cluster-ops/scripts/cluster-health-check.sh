#!/bin/bash
# cluster-health-check.sh - Comprehensive cluster health assessment
# Usage: ./cluster-health-check.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

echo "=== KUBERNETES CLUSTER HEALTH ASSESSMENT ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "" >&2

SCORE=100
ISSUES=()

# 1. Node Health (Critical: -50 points per issue)
echo "### NODE HEALTH ###" >&2
UNHEALTHY_NODES=$($CLI get nodes --no-headers 2>/dev/null | grep -c -E "NotReady|Unknown" || echo 0)
if [ "$UNHEALTHY_NODES" -gt 0 ]; then
    SCORE=$((SCORE - 50))
    ISSUES+=("CRITICAL: $UNHEALTHY_NODES unhealthy nodes detected")
    $CLI get nodes | grep -E "NotReady|Unknown" >&2
else
    echo "✓ All nodes healthy" >&2
fi

# 2. Pod Issues (Warning: -20 points)
echo -e "\n### POD HEALTH ###" >&2
POD_ISSUES=$($CLI get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$POD_ISSUES" -gt 0 ]; then
    SCORE=$((SCORE - 20))
    ISSUES+=("WARN: $POD_ISSUES pods not in Running/Succeeded state")
    echo "Pods with issues:" >&2
    $CLI get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded >&2
else
    echo "✓ All pods running" >&2
fi

# 3. CrashLoopBackOff (Critical: -50 points)
echo -e "\n### CRASH LOOP DETECTION ###" >&2
CRASH_LOOPS=$($CLI get pods -A 2>/dev/null | grep -c "CrashLoopBackOff" || echo 0)
if [ "$CRASH_LOOPS" -gt 0 ]; then
    SCORE=$((SCORE - 50))
    ISSUES+=("CRITICAL: $CRASH_LOOPS pods in CrashLoopBackOff")
    $CLI get pods -A | grep "CrashLoopBackOff" >&2
else
    echo "✓ No CrashLoopBackOff detected" >&2
fi

# 4. Resource Pressure (Warning: -20 points per pressured node)
echo -e "\n### RESOURCE PRESSURE ###" >&2
PRESSURE_NODES=$($CLI get nodes -o json 2>/dev/null | jq -r '.items[] | select(.status.conditions[] | select((.type | contains("Pressure")) and .status == "True")) | .metadata.name' 2>/dev/null)
if [ -n "$PRESSURE_NODES" ]; then
    PRESSURE_COUNT=$(echo "$PRESSURE_NODES" | wc -l | tr -d ' ')
    SCORE=$((SCORE - 20 * PRESSURE_COUNT))
    ISSUES+=("WARN: $PRESSURE_COUNT nodes under resource pressure")
    echo "Nodes with pressure:" >&2
    echo "$PRESSURE_NODES" >&2
else
    echo "✓ No resource pressure detected" >&2
fi

# 5. Pending PVCs (Warning: -10 points)
echo -e "\n### STORAGE HEALTH ###" >&2
PENDING_PVC=$($CLI get pvc -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$PENDING_PVC" -gt 0 ]; then
    SCORE=$((SCORE - 10))
    ISSUES+=("WARN: $PENDING_PVC PVCs pending")
    $CLI get pvc -A --field-selector=status.phase=Pending >&2
else
    echo "✓ No pending PVCs" >&2
fi

# 6. Warning Events (Info: -5 points if >50)
echo -e "\n### CLUSTER EVENTS ###" >&2
WARNING_EVENTS=$($CLI get events -A --field-selector=type=Warning --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [ "$WARNING_EVENTS" -gt 50 ]; then
    SCORE=$((SCORE - 5))
    ISSUES+=("INFO: $WARNING_EVENTS warning events in cluster")
    echo "Recent warning events: $WARNING_EVENTS" >&2
else
    echo "✓ Warning events within normal range ($WARNING_EVENTS)" >&2
fi

# 7. OpenShift-specific checks
if command -v oc &> /dev/null && oc whoami &> /dev/null 2>&1; then
    echo -e "\n### OPENSHIFT CLUSTER OPERATORS ###" >&2
    DEGRADED=$(oc get clusteroperators --no-headers 2>/dev/null | grep -c -E "False.*True|False.*False" || echo 0)
    if [ "$DEGRADED" -gt 0 ]; then
        SCORE=$((SCORE - 50))
        ISSUES+=("CRITICAL: $DEGRADED cluster operators degraded/unavailable")
        oc get clusteroperators | grep -E "False.*True|False.*False" >&2
    else
        echo "✓ All cluster operators healthy" >&2
    fi

    echo -e "\n### OPENSHIFT CLUSTER VERSION ###" >&2
    oc get clusterversion >&2
fi

# Ensure score doesn't go below 0
[ $SCORE -lt 0 ] && SCORE=0

# Summary
echo "" >&2
echo "========================================" >&2
echo "CLUSTER HEALTH SCORE: $SCORE/100" >&2
echo "========================================" >&2

if [ $SCORE -ge 90 ]; then
    echo "Status: ✅ HEALTHY" >&2
elif [ $SCORE -ge 70 ]; then
    echo "Status: ⚠️  WARNING" >&2
elif [ $SCORE -ge 50 ]; then
    echo "Status: 🔶 DEGRADED" >&2
else
    echo "Status: 🔴 CRITICAL" >&2
fi

if [ ${#ISSUES[@]} -gt 0 ]; then
    echo "" >&2
    echo "Issues found:" >&2
    for issue in "${ISSUES[@]}"; do
        echo "  - $issue" >&2
    done
fi

# Output JSON
ISSUES_JSON=$(printf '%s\n' "${ISSUES[@]}" | jq -R . | jq -s .)
cat << EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "score": $SCORE,
  "status": "$([ $SCORE -ge 90 ] && echo "healthy" || ([ $SCORE -ge 70 ] && echo "warning" || ([ $SCORE -ge 50 ] && echo "degraded" || echo "critical")))",
  "checks": {
    "unhealthy_nodes": $UNHEALTHY_NODES,
    "pod_issues": $POD_ISSUES,
    "crash_loops": $CRASH_LOOPS,
    "pending_pvcs": $PENDING_PVC,
    "warning_events": $WARNING_EVENTS
  },
  "issues": $ISSUES_JSON
}
EOF
