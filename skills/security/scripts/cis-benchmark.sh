#!/bin/bash
# cis-benchmark.sh - CIS Kubernetes/OpenShift benchmark compliance check
# Usage: ./cis-benchmark.sh [--targets master,node,etcd,policies] [--benchmark cis-1.8]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

TARGETS=${1:-"master,node,etcd,policies"}
BENCHMARK=${2:-""}
CLI=$(command -v oc 2>/dev/null && echo "oc" || echo "kubectl")

# Handle flag-style arguments
[[ "$TARGETS" == "--targets" ]] && TARGETS="${2:-master,node,etcd,policies}" && BENCHMARK="${3:-}"
[[ "$BENCHMARK" == "--benchmark" ]] && BENCHMARK="${3:-}"

echo "=== CIS BENCHMARK COMPLIANCE CHECK ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "CLI: $CLI" >&2
echo "Targets: $TARGETS" >&2
echo "" >&2

# Detect platform
PLATFORM="kubernetes"
if [ "$CLI" == "oc" ]; then
    OCP_VERSION=$($CLI version -o json 2>/dev/null | jq -r '.openshiftVersion // "unknown"' 2>/dev/null || echo "unknown")
    if [ "$OCP_VERSION" != "unknown" ]; then
        PLATFORM="openshift"
        echo "Platform: OpenShift $OCP_VERSION" >&2
    fi
else
    K8S_VERSION=$($CLI version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || echo "unknown")
    echo "Platform: Kubernetes $K8S_VERSION" >&2
fi

echo "" >&2

# Method 1: Use kube-bench if available
if command -v kube-bench &> /dev/null; then
    echo "### Running kube-bench ###" >&2
    
    KUBE_BENCH_ARGS="run --targets $TARGETS"
    [ -n "$BENCHMARK" ] && KUBE_BENCH_ARGS="$KUBE_BENCH_ARGS --benchmark $BENCHMARK"
    
    # JSON output for parsing
    RESULT=$(kube-bench $KUBE_BENCH_ARGS --json 2>/dev/null || echo "")
    
    if [ -n "$RESULT" ]; then
        PASS=$(echo "$RESULT" | jq '[.Controls[]?.tests[]?.results[]? | select(.status == "PASS")] | length' 2>/dev/null || echo "0")
        FAIL=$(echo "$RESULT" | jq '[.Controls[]?.tests[]?.results[]? | select(.status == "FAIL")] | length' 2>/dev/null || echo "0")
        WARN=$(echo "$RESULT" | jq '[.Controls[]?.tests[]?.results[]? | select(.status == "WARN")] | length' 2>/dev/null || echo "0")
        INFO=$(echo "$RESULT" | jq '[.Controls[]?.tests[]?.results[]? | select(.status == "INFO")] | length' 2>/dev/null || echo "0")
        TOTAL=$((PASS + FAIL + WARN + INFO))
        
        echo "Results:" >&2
        echo "  ✅ PASS: $PASS" >&2
        echo "  ❌ FAIL: $FAIL" >&2
        echo "  ⚠️  WARN: $WARN" >&2
        echo "  ℹ️  INFO: $INFO" >&2
        echo "  Total: $TOTAL checks" >&2
        
        if [ "$FAIL" -gt 0 ]; then
            echo -e "\n### Failed Checks ###" >&2
            echo "$RESULT" | jq -r '.Controls[]?.tests[]?.results[]? | select(.status == "FAIL") | "  ❌ [\(.test_number)] \(.test_desc)"' 2>/dev/null >&2
        fi
        
        cat << EOF
{
  "method": "kube-bench",
  "platform": "$PLATFORM",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "targets": "$TARGETS",
  "summary": {
    "pass": $PASS,
    "fail": $FAIL,
    "warn": $WARN,
    "info": $INFO,
    "total": $TOTAL,
    "score_percent": $([ "$TOTAL" -gt 0 ] && echo "$((PASS * 100 / TOTAL))" || echo "0")
  }
}
EOF
        [ "$FAIL" -gt 0 ] && exit 1
        exit 0
    fi
fi

# Method 2: Run kube-bench as a Job in the cluster
echo "kube-bench not found locally. Running as Kubernetes Job..." >&2
echo "" >&2

JOB_NAME="cis-benchmark-$(date +%s)"

# Check if kube-bench job already exists
$CLI get job "$JOB_NAME" -n default &>/dev/null && $CLI delete job "$JOB_NAME" -n default &>/dev/null

cat << JOBEOF | $CLI apply -f - >&2 2>&1
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: default
spec:
  ttlSecondsAfterFinished: 300
  template:
    spec:
      hostPID: true
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:latest
          command: ["kube-bench", "run", "--targets", "${TARGETS}", "--json"]
          volumeMounts:
            - name: var-lib-etcd
              mountPath: /var/lib/etcd
              readOnly: true
            - name: etc-kubernetes
              mountPath: /etc/kubernetes
              readOnly: true
            - name: etc-systemd
              mountPath: /etc/systemd
              readOnly: true
      restartPolicy: Never
      volumes:
        - name: var-lib-etcd
          hostPath:
            path: /var/lib/etcd
        - name: etc-kubernetes
          hostPath:
            path: /etc/kubernetes
        - name: etc-systemd
          hostPath:
            path: /etc/systemd
JOBEOF

echo "Job $JOB_NAME created. Waiting for completion..." >&2
$CLI wait --for=condition=complete job/"$JOB_NAME" -n default --timeout=120s >&2 2>&1 || true

# Get results
POD=$($CLI get pods -n default -l job-name="$JOB_NAME" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
if [ -n "$POD" ]; then
    RESULT=$($CLI logs "$POD" -n default 2>/dev/null || echo "")
    if [ -n "$RESULT" ]; then
        PASS=$(echo "$RESULT" | jq '[.Controls[]?.tests[]?.results[]? | select(.status == "PASS")] | length' 2>/dev/null || echo "0")
        FAIL=$(echo "$RESULT" | jq '[.Controls[]?.tests[]?.results[]? | select(.status == "FAIL")] | length' 2>/dev/null || echo "0")
        WARN=$(echo "$RESULT" | jq '[.Controls[]?.tests[]?.results[]? | select(.status == "WARN")] | length' 2>/dev/null || echo "0")
        TOTAL=$((PASS + FAIL + WARN))
        
        echo "Results:" >&2
        echo "  ✅ PASS: $PASS" >&2
        echo "  ❌ FAIL: $FAIL" >&2
        echo "  ⚠️  WARN: $WARN" >&2
        
        cat << EOF
{
  "method": "kube-bench-job",
  "platform": "$PLATFORM",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "targets": "$TARGETS",
  "job_name": "$JOB_NAME",
  "summary": {
    "pass": $PASS,
    "fail": $FAIL,
    "warn": $WARN,
    "total": $TOTAL
  }
}
EOF
    fi
fi

# Cleanup
$CLI delete job "$JOB_NAME" -n default &>/dev/null || true

echo "" >&2
echo "========================================" >&2
echo "CIS BENCHMARK CHECK COMPLETE" >&2
echo "========================================" >&2
