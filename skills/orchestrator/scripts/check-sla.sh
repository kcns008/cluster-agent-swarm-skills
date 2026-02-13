#!/bin/bash
# check-sla.sh - Check for SLA breaches across work items
# Usage: ./check-sla.sh [--format json|text]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

FORMAT=${1:-"text"}
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

echo "=== SLA COMPLIANCE CHECK ===" >&2
echo "Timestamp: $TIMESTAMP" >&2
echo "" >&2

# SLA definitions (in minutes)
P1_RESPONSE=5
P1_RESOLVE=60
P2_RESPONSE=15
P2_RESOLVE=240
P3_RESPONSE=60
P3_RESOLVE=1440
P4_RESPONSE=240
P4_RESOLVE=10080

echo "### SLA Targets ###" >&2
echo "P1: Response ${P1_RESPONSE}m, Resolve ${P1_RESOLVE}m" >&2
echo "P2: Response ${P2_RESPONSE}m, Resolve ${P2_RESOLVE}m" >&2
echo "P3: Response ${P3_RESPONSE}m, Resolve ${P3_RESOLVE}m" >&2
echo "P4: Response ${P4_RESPONSE}m, Resolve ${P4_RESOLVE}m" >&2

# Check for active incidents via pod labels or custom resources
echo "" >&2
echo "### Checking Active Issues ###" >&2

# Check for pods in bad state (proxy for P1/P2 issues)
CRASH_LOOPS=$($CLI get pods -A 2>/dev/null | grep -c "CrashLoopBackOff" || echo 0)
NOT_READY=$($CLI get nodes --no-headers 2>/dev/null | grep -c "NotReady" || echo 0)
PENDING_PODS=$($CLI get pods -A --field-selector=status.phase=Pending --no-headers 2>/dev/null | wc -l | tr -d ' ')

BREACHES=0
WARNINGS=0

if [ "$NOT_READY" -gt 0 ]; then
    BREACHES=$((BREACHES + 1))
    echo "🔴 P1 BREACH: $NOT_READY nodes NotReady - requires immediate response" >&2
fi

if [ "$CRASH_LOOPS" -gt 5 ]; then
    BREACHES=$((BREACHES + 1))
    echo "🔴 P2 BREACH: $CRASH_LOOPS pods in CrashLoopBackOff" >&2
elif [ "$CRASH_LOOPS" -gt 0 ]; then
    WARNINGS=$((WARNINGS + 1))
    echo "⚠️  P3 WARNING: $CRASH_LOOPS pods in CrashLoopBackOff" >&2
fi

if [ "$PENDING_PODS" -gt 10 ]; then
    WARNINGS=$((WARNINGS + 1))
    echo "⚠️  P3 WARNING: $PENDING_PODS pods stuck in Pending" >&2
fi

# OpenShift-specific checks
if command -v oc &> /dev/null && oc whoami &> /dev/null 2>&1; then
    DEGRADED_OPS=$(oc get clusteroperators --no-headers 2>/dev/null | grep -c -E "False.*True|False.*False" || echo 0)
    if [ "$DEGRADED_OPS" -gt 0 ]; then
        BREACHES=$((BREACHES + 1))
        echo "🔴 P1 BREACH: $DEGRADED_OPS cluster operators degraded" >&2
    fi
fi

echo "" >&2
echo "### Summary ###" >&2
echo "SLA Breaches: $BREACHES" >&2
echo "SLA Warnings: $WARNINGS" >&2

if [ "$FORMAT" == "json" ]; then
cat << EOF
{
  "timestamp": "$TIMESTAMP",
  "sla_check": {
    "breaches": $BREACHES,
    "warnings": $WARNINGS,
    "details": {
      "not_ready_nodes": $NOT_READY,
      "crash_loop_pods": $CRASH_LOOPS,
      "pending_pods": $PENDING_PODS
    },
    "compliant": $([ $BREACHES -eq 0 ] && echo "true" || echo "false")
  }
}
EOF
else
    echo "" >&2
    if [ "$BREACHES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
        echo "✅ All SLAs compliant" >&2
    elif [ "$BREACHES" -eq 0 ]; then
        echo "⚠️  SLA compliant with $WARNINGS warnings" >&2
    else
        echo "🔴 $BREACHES SLA BREACHES detected - immediate action required" >&2
    fi
fi
