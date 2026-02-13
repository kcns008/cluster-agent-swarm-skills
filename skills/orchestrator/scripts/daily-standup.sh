#!/bin/bash
# daily-standup.sh - Generate daily standup report for the platform agent swarm
# Usage: ./daily-standup.sh [--format json|markdown]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

FORMAT=${1:-"markdown"}
DATE=$(date -u +"%Y-%m-%d")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "=== GENERATING DAILY STANDUP ===" >&2
echo "Date: $DATE" >&2
echo "Format: $FORMAT" >&2
echo "" >&2

# Cluster Health Summary
echo "### Gathering Cluster Health..." >&2
CLUSTERS=""
if command -v oc &> /dev/null && oc whoami &> /dev/null 2>&1; then
    CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
    CLUSTER_STATUS=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || echo "unknown")
    NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
    CLUSTER_NAME=$(oc whoami --show-server 2>/dev/null | sed 's|https://api\.||;s|:.*||' || echo "unknown")
    CLUSTERS="$CLUSTER_NAME (OCP $CLUSTER_VERSION, $NODE_COUNT nodes, Available=$CLUSTER_STATUS)"
elif [ "$CLI" == "kubectl" ]; then
  SERVER_VERSION=$($CLI version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null || echo "unknown")
  NODE_COUNT=$($CLI get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
  CONTEXT=$($CLI config current-context 2>/dev/null || echo "unknown")
    CLUSTERS="$CONTEXT (K8s $SERVER_VERSION, $NODE_COUNT nodes)"
else
    CLUSTERS="No cluster connection available"
fi

# Pod Health
echo "### Gathering Pod Health..." >&2
UNHEALTHY_PODS=$($CLI get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers 2>/dev/null | wc -l | tr -d ' ')
CRASH_LOOPS=$($CLI get pods -A 2>/dev/null | grep -c "CrashLoopBackOff" || echo 0)
TOTAL_PODS=$($CLI get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')

# Node Health
echo "### Gathering Node Health..." >&2
TOTAL_NODES=$($CLI get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY_NODES=$($CLI get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)
NOT_READY_NODES=$((TOTAL_NODES - READY_NODES))

# Recent Events
echo "### Gathering Recent Events..." >&2
WARNING_EVENTS=$($CLI get events -A --field-selector=type=Warning --no-headers 2>/dev/null | wc -l | tr -d ' ')

# ArgoCD Applications (if available)
echo "### Checking ArgoCD..." >&2
ARGOCD_APPS=""
if command -v argocd &> /dev/null; then
    ARGOCD_TOTAL=$(argocd app list --output json 2>/dev/null | jq 'length' 2>/dev/null || echo 0)
    ARGOCD_SYNCED=$(argocd app list --output json 2>/dev/null | jq '[.[] | select(.status.sync.status=="Synced")] | length' 2>/dev/null || echo 0)
    ARGOCD_OUTOFSYNC=$(argocd app list --output json 2>/dev/null | jq '[.[] | select(.status.sync.status=="OutOfSync")] | length' 2>/dev/null || echo 0)
    ARGOCD_DEGRADED=$(argocd app list --output json 2>/dev/null | jq '[.[] | select(.status.health.status=="Degraded")] | length' 2>/dev/null || echo 0)
    ARGOCD_APPS="Total: $ARGOCD_TOTAL, Synced: $ARGOCD_SYNCED, OutOfSync: $ARGOCD_OUTOFSYNC, Degraded: $ARGOCD_DEGRADED"
else
    ARGOCD_APPS="ArgoCD CLI not available"
fi

if [ "$FORMAT" == "json" ]; then
cat << EOF
{
  "report": "daily-standup",
  "date": "$DATE",
  "timestamp": "$TIMESTAMP",
  "cluster_health": {
    "clusters": "$CLUSTERS",
    "total_nodes": $TOTAL_NODES,
    "ready_nodes": $READY_NODES,
    "not_ready_nodes": $NOT_READY_NODES
  },
  "pod_health": {
    "total_pods": $TOTAL_PODS,
    "unhealthy_pods": $UNHEALTHY_PODS,
    "crash_loops": $CRASH_LOOPS
  },
  "events": {
    "warning_count": $WARNING_EVENTS
  },
  "argocd": "$ARGOCD_APPS"
}
EOF
else
cat << EOF
📊 PLATFORM SWARM DAILY STANDUP — $DATE

## 🏥 Cluster Health
$CLUSTERS

**Nodes:** $READY_NODES/$TOTAL_NODES Ready $([ "$NOT_READY_NODES" -gt 0 ] && echo "⚠️ $NOT_READY_NODES NOT READY" || echo "✅")
**Pods:** $TOTAL_PODS total, $UNHEALTHY_PODS unhealthy, $CRASH_LOOPS CrashLoopBackOff
**Warning Events:** $WARNING_EVENTS

## 🚀 ArgoCD
$ARGOCD_APPS

## 📈 Summary
- Cluster: $([ "$NOT_READY_NODES" -eq 0 ] && echo "HEALTHY ✅" || echo "DEGRADED ⚠️")
- Pods: $([ "$UNHEALTHY_PODS" -eq 0 ] && echo "ALL HEALTHY ✅" || echo "$UNHEALTHY_PODS ISSUES ⚠️")
- CrashLoops: $([ "$CRASH_LOOPS" -eq 0 ] && echo "NONE ✅" || echo "$CRASH_LOOPS DETECTED 🔴")

---
Generated: $TIMESTAMP
EOF
fi
