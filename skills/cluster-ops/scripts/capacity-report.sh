#!/bin/bash
# capacity-report.sh - Cluster capacity and utilization report
# Usage: ./capacity-report.sh [--format json|text]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

FORMAT=${1:-"text"}

echo "=== CLUSTER CAPACITY REPORT ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "" >&2

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

# Node count and status
TOTAL_NODES=$($CLI get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
READY_NODES=$($CLI get nodes --no-headers 2>/dev/null | grep -c " Ready" || echo 0)

echo "### Node Summary ###" >&2
echo "Total nodes: $TOTAL_NODES" >&2
echo "Ready nodes: $READY_NODES" >&2
echo "" >&2

# Node resource usage
echo "### Node Resource Usage ###" >&2
$CLI top nodes 2>/dev/null >&2 || echo "metrics-server not available" >&2

# Total cluster capacity
echo -e "\n### Cluster Capacity ###" >&2
TOTAL_CPU=$($CLI get nodes -o json 2>/dev/null | jq '[.items[].status.capacity.cpu | gsub("[^0-9]";"") | tonumber] | add' 2>/dev/null || echo 0)
TOTAL_MEM_KI=$($CLI get nodes -o json 2>/dev/null | jq '[.items[].status.capacity.memory | gsub("Ki";"") | tonumber] | add' 2>/dev/null || echo 0)
TOTAL_MEM_GI=$((TOTAL_MEM_KI / 1048576))

ALLOC_CPU=$($CLI get nodes -o json 2>/dev/null | jq '[.items[].status.allocatable.cpu | gsub("[^0-9]";"") | tonumber] | add' 2>/dev/null || echo 0)
ALLOC_MEM_KI=$($CLI get nodes -o json 2>/dev/null | jq '[.items[].status.allocatable.memory | gsub("Ki";"") | tonumber] | add' 2>/dev/null || echo 0)
ALLOC_MEM_GI=$((ALLOC_MEM_KI / 1048576))

echo "Total CPU: ${TOTAL_CPU} cores" >&2
echo "Allocatable CPU: ${ALLOC_CPU} cores" >&2
echo "Total Memory: ${TOTAL_MEM_GI} Gi" >&2
echo "Allocatable Memory: ${ALLOC_MEM_GI} Gi" >&2

# Pod count
echo -e "\n### Pod Summary ###" >&2
TOTAL_PODS=$($CLI get pods -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
RUNNING_PODS=$($CLI get pods -A --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
MAX_PODS=$($CLI get nodes -o json 2>/dev/null | jq '[.items[].status.capacity.pods | tonumber] | add' 2>/dev/null || echo 0)

echo "Total pods: $TOTAL_PODS" >&2
echo "Running pods: $RUNNING_PODS" >&2
echo "Max pods (capacity): $MAX_PODS" >&2
if [ "$MAX_PODS" -gt 0 ]; then
    POD_UTIL=$((TOTAL_PODS * 100 / MAX_PODS))
    echo "Pod utilization: ${POD_UTIL}%" >&2
else
    POD_UTIL=0
fi

# Namespace breakdown
echo -e "\n### Top Namespaces by Pod Count ###" >&2
kubectl get pods -A --no-headers 2>/dev/null | awk '{print $1}' | sort | uniq -c | sort -rn | head -10 >&2

# Resource requests summary
echo -e "\n### Resource Requests Summary ###" >&2
kubectl get pods -A -o json 2>/dev/null | jq -r '
  [.items[] | select(.status.phase=="Running") | .spec.containers[].resources.requests // {} |
   {cpu: (.cpu // "0"), memory: (.memory // "0")}
  ] | length' 2>/dev/null | xargs -I{} echo "Pods with resource requests: {}" >&2

# Nodes approaching limits
echo -e "\n### High Utilization Nodes ###" >&2
kubectl top nodes --no-headers 2>/dev/null | awk '{
    cpu_pct = $3; mem_pct = $5;
    gsub(/%/, "", cpu_pct); gsub(/%/, "", mem_pct);
    if (cpu_pct+0 > 70 || mem_pct+0 > 70)
        print "⚠️  " $1 " CPU:" cpu_pct "% MEM:" mem_pct "%"
}' >&2 || echo "metrics-server not available" >&2

# OpenShift-specific
if command -v oc &> /dev/null && oc whoami &> /dev/null 2>&1; then
    echo -e "\n### OpenShift MachineSets ###" >&2
    oc get machinesets -n openshift-machine-api 2>/dev/null >&2 || true
    
    echo -e "\n### Machine Autoscalers ###" >&2
    oc get machineautoscaler -n openshift-machine-api 2>/dev/null >&2 || echo "No machine autoscalers configured" >&2
fi

echo "" >&2
echo "========================================" >&2
echo "CAPACITY REPORT COMPLETE" >&2
echo "========================================" >&2

# Output JSON
cat << EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "nodes": {
    "total": $TOTAL_NODES,
    "ready": $READY_NODES
  },
  "capacity": {
    "cpu_cores": $TOTAL_CPU,
    "allocatable_cpu_cores": $ALLOC_CPU,
    "memory_gi": $TOTAL_MEM_GI,
    "allocatable_memory_gi": $ALLOC_MEM_GI
  },
  "pods": {
    "total": $TOTAL_PODS,
    "running": $RUNNING_PODS,
    "max_capacity": $MAX_PODS,
    "utilization_pct": $POD_UTIL
  }
}
EOF
