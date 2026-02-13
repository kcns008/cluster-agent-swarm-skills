#!/bin/bash
# debug-pod.sh - Automated pod issue diagnosis
# Usage: ./debug-pod.sh <namespace> [pod-name]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

NAMESPACE=${1:-""}
POD_NAME=${2:-""}

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace> [pod-name]" >&2
    echo "" >&2
    echo "Automatically diagnoses common pod issues." >&2
    echo "If no pod specified, checks all non-Running pods in namespace." >&2
    echo "" >&2
    echo "Detects: CrashLoopBackOff, OOMKilled, ImagePullBackOff," >&2
    echo "         Pending, CreateContainerConfigError, Evicted" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 production" >&2
    echo "  $0 production payment-service-7b4f9c8d6-x2k9p" >&2
    exit 1
fi

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

echo "=== POD DIAGNOSTIC ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Namespace: $NAMESPACE" >&2
[ -n "$POD_NAME" ] && echo "Pod: $POD_NAME" >&2
echo "CLI: $CLI" >&2
echo "" >&2

FINDINGS=()

add_finding() {
    local pod="$1" severity="$2" issue="$3" detail="$4" recommendation="$5"
    FINDINGS+=("{\"pod\":\"$pod\",\"severity\":\"$severity\",\"issue\":\"$issue\",\"detail\":\"$detail\",\"recommendation\":\"$recommendation\"}")
    echo "  [$severity] $issue" >&2
    echo "    Detail: $detail" >&2
    echo "    Fix: $recommendation" >&2
}

diagnose_pod() {
    local POD="$1"
    local POD_JSON=$($CLI get pod "$POD" -n "$NAMESPACE" -o json 2>/dev/null || echo "")
    
    if [ -z "$POD_JSON" ]; then
        echo "  ⚠️  Pod not found: $POD" >&2
        return
    fi
    
    local PHASE=$(echo "$POD_JSON" | jq -r '.status.phase')
    local CONDITIONS=$(echo "$POD_JSON" | jq -r '.status.conditions // []')
    
    echo "--- Pod: $POD (Phase: $PHASE) ---" >&2
    
    # Get container statuses
    local CONTAINER_STATUSES=$(echo "$POD_JSON" | jq -r '.status.containerStatuses // []')
    local INIT_STATUSES=$(echo "$POD_JSON" | jq -r '.status.initContainerStatuses // []')
    
    # Check each container
    echo "$CONTAINER_STATUSES" | jq -c '.[]?' 2>/dev/null | while IFS= read -r cs; do
        local CNAME=$(echo "$cs" | jq -r '.name')
        local READY=$(echo "$cs" | jq -r '.ready')
        local RESTARTS=$(echo "$cs" | jq -r '.restartCount')
        local STATE_KEY=$(echo "$cs" | jq -r '.state | keys[0]')
        local LAST_STATE_KEY=$(echo "$cs" | jq -r '.lastState | keys[0] // "none"')
        
        echo "  Container: $CNAME (ready=$READY, restarts=$RESTARTS, state=$STATE_KEY)" >&2
        
        # CrashLoopBackOff
        if [ "$STATE_KEY" == "waiting" ]; then
            local REASON=$(echo "$cs" | jq -r '.state.waiting.reason // "unknown"')
            
            if [ "$REASON" == "CrashLoopBackOff" ]; then
                local EXIT_CODE=$(echo "$cs" | jq -r '.lastState.terminated.exitCode // "unknown"')
                local TERM_REASON=$(echo "$cs" | jq -r '.lastState.terminated.reason // "unknown"')
                
                if [ "$EXIT_CODE" == "137" ] || [ "$TERM_REASON" == "OOMKilled" ]; then
                    local MEM_LIMIT=$(echo "$POD_JSON" | jq -r ".spec.containers[] | select(.name==\"$CNAME\") | .resources.limits.memory // \"not set\"")
                    add_finding "$POD" "CRITICAL" "OOMKilled" \
                        "Container $CNAME killed (exit 137). Memory limit: $MEM_LIMIT" \
                        "Increase memory limit: kubectl set resources deployment/DEPLOY -n $NAMESPACE --limits=memory=HIGHER_VALUE"
                else
                    add_finding "$POD" "HIGH" "CrashLoopBackOff" \
                        "Container $CNAME crashing (exit code: $EXIT_CODE, reason: $TERM_REASON)" \
                        "Check logs: kubectl logs $POD -n $NAMESPACE -c $CNAME --previous"
                fi
                
                # Show last logs
                echo "    Last crash logs:" >&2
                $CLI logs "$POD" -n "$NAMESPACE" -c "$CNAME" --previous --tail=10 2>/dev/null | sed 's/^/      /' >&2 || true
                
            elif [ "$REASON" == "ImagePullBackOff" ] || [ "$REASON" == "ErrImagePull" ]; then
                local IMAGE=$(echo "$POD_JSON" | jq -r ".spec.containers[] | select(.name==\"$CNAME\") | .image")
                add_finding "$POD" "HIGH" "ImagePullBackOff" \
                    "Cannot pull image: $IMAGE" \
                    "Check: 1) Image exists 2) Pull secret exists 3) Registry credentials valid"
                
            elif [ "$REASON" == "CreateContainerConfigError" ]; then
                # Check for missing ConfigMaps/Secrets
                local EVENTS=$($CLI get events -n "$NAMESPACE" --field-selector "involvedObject.name=$POD" --sort-by='.lastTimestamp' 2>/dev/null | tail -5)
                add_finding "$POD" "HIGH" "CreateContainerConfigError" \
                    "Missing ConfigMap or Secret referenced by container $CNAME" \
                    "Check events: kubectl get events -n $NAMESPACE --field-selector involvedObject.name=$POD"
                echo "    Events:" >&2
                echo "$EVENTS" | sed 's/^/      /' >&2
            else
                add_finding "$POD" "MEDIUM" "Waiting ($REASON)" \
                    "Container $CNAME is waiting: $REASON" \
                    "Check events: kubectl describe pod $POD -n $NAMESPACE"
            fi
        fi
        
        # Running but not ready
        if [ "$STATE_KEY" == "running" ] && [ "$READY" == "false" ]; then
            add_finding "$POD" "MEDIUM" "NotReady" \
                "Container $CNAME is running but not ready (readiness probe failing)" \
                "Check readiness probe: kubectl describe pod $POD -n $NAMESPACE | grep -A5 Readiness"
        fi
        
        # High restart count
        if [ "$RESTARTS" -gt 5 ]; then
            add_finding "$POD" "MEDIUM" "HighRestarts" \
                "Container $CNAME has restarted $RESTARTS times" \
                "Investigate stability: kubectl logs $POD -n $NAMESPACE -c $CNAME --previous"
        fi
    done
    
    # Pending pod checks
    if [ "$PHASE" == "Pending" ]; then
        local EVENTS=$($CLI get events -n "$NAMESPACE" --field-selector "involvedObject.name=$POD" --sort-by='.lastTimestamp' -o json 2>/dev/null)
        
        # Check for insufficient resources
        local INSUFF=$(echo "$EVENTS" | jq -r '.items[] | select(.reason == "FailedScheduling") | .message' 2>/dev/null | head -1)
        if [ -n "$INSUFF" ]; then
            if echo "$INSUFF" | grep -qi "Insufficient cpu\|Insufficient memory"; then
                add_finding "$POD" "HIGH" "InsufficientResources" \
                    "$INSUFF" \
                    "Reduce resource requests or add cluster capacity"
            elif echo "$INSUFF" | grep -qi "node.*taint\|toleration"; then
                add_finding "$POD" "MEDIUM" "TaintMismatch" \
                    "$INSUFF" \
                    "Add tolerations to pod spec or remove taints from nodes"
            elif echo "$INSUFF" | grep -qi "persistentvolumeclaim\|pvc"; then
                add_finding "$POD" "HIGH" "PVCNotBound" \
                    "$INSUFF" \
                    "Check PVC status: kubectl get pvc -n $NAMESPACE"
            else
                add_finding "$POD" "HIGH" "FailedScheduling" \
                    "$INSUFF" \
                    "Check node capacity and scheduling constraints"
            fi
        else
            add_finding "$POD" "MEDIUM" "Pending" \
                "Pod is pending (no specific scheduling error found)" \
                "kubectl describe pod $POD -n $NAMESPACE"
        fi
    fi
    
    # Evicted
    if [ "$PHASE" == "Failed" ]; then
        local FAIL_REASON=$(echo "$POD_JSON" | jq -r '.status.reason // "unknown"')
        if [ "$FAIL_REASON" == "Evicted" ]; then
            local EVICT_MSG=$(echo "$POD_JSON" | jq -r '.status.message // "no message"')
            add_finding "$POD" "HIGH" "Evicted" \
                "$EVICT_MSG" \
                "Check node pressure: kubectl describe node \$(kubectl get pod $POD -n $NAMESPACE -o jsonpath='{.spec.nodeName}')"
        fi
    fi
    
    echo "" >&2
}

# Determine which pods to diagnose
if [ -n "$POD_NAME" ]; then
    diagnose_pod "$POD_NAME"
else
    echo "### Scanning all pods in $NAMESPACE ###" >&2
    # Get unhealthy pods first, then all pods
    PROBLEM_PODS=$($CLI get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -v "Running\|Completed\|Succeeded" | awk '{print $1}' || echo "")
    
    if [ -n "$PROBLEM_PODS" ]; then
        PROBLEM_COUNT=$(echo "$PROBLEM_PODS" | wc -l | tr -d ' ')
        echo "Found $PROBLEM_COUNT problematic pod(s)" >&2
        echo "" >&2
        
        while IFS= read -r pod; do
            [ -n "$pod" ] && diagnose_pod "$pod"
        done <<< "$PROBLEM_PODS"
    else
        echo "✅ All pods in $NAMESPACE are Running/Completed" >&2
        
        # Still check for high restart counts
        HIGH_RESTART_PODS=$($CLI get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.status.containerStatuses[]?.restartCount > 5) | .metadata.name' 2>/dev/null || echo "")
        if [ -n "$HIGH_RESTART_PODS" ]; then
            echo "⚠️  Pods with high restart counts:" >&2
            while IFS= read -r pod; do
                [ -n "$pod" ] && diagnose_pod "$pod"
            done <<< "$HIGH_RESTART_PODS"
        fi
    fi
fi

# Resource usage overview
echo "### Resource Usage Overview ###" >&2
$CLI top pods -n "$NAMESPACE" 2>/dev/null | head -20 >&2 || echo "  (metrics-server not available)" >&2

# Summary
TOTAL=${#FINDINGS[@]}
echo "" >&2
echo "========================================" >&2
echo "DIAGNOSTIC COMPLETE: $TOTAL findings" >&2
echo "========================================" >&2

# Output JSON
FINDINGS_JSON=$(printf '%s\n' "${FINDINGS[@]}" | jq -s '.' 2>/dev/null || echo "[]")
cat << EOF
{
  "diagnostic_type": "pod-debug",
  "namespace": "$NAMESPACE",
  "pod": "${POD_NAME:-all}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "total_findings": $TOTAL,
  "findings": $FINDINGS_JSON
}
EOF

[ "$TOTAL" -gt 0 ] && exit 1
exit 0
