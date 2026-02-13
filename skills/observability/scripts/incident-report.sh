#!/bin/bash
# incident-report.sh - Generate post-incident review document
# Usage: ./incident-report.sh <title> <severity> <namespace> <service> [--output-dir /path]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

TITLE=${1:-""}
SEVERITY=${2:-"P2"}
NAMESPACE=${3:-""}
SERVICE=${4:-""}
OUTPUT_DIR=${5:-"."}

if [ -z "$TITLE" ]; then
    echo "Usage: $0 <title> <severity> <namespace> <service> [--output-dir <path>]" >&2
    echo "" >&2
    echo "Generates a post-incident review document with automated data collection." >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  title       Incident title (e.g., 'Payment API Outage')" >&2
    echo "  severity    P1, P2, P3, or P4" >&2
    echo "  namespace   Kubernetes namespace" >&2
    echo "  service     Affected service name" >&2
    echo "  --output-dir  Directory for output file (default: current)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 'Payment API Outage' P1 production payment-service" >&2
    echo "  $0 'High Latency on Search' P2 production search-service --output-dir ./incidents" >&2
    exit 1
fi

[[ "$OUTPUT_DIR" == "--output-dir" ]] && OUTPUT_DIR="${6:-.}"

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"
INCIDENT_DATE=$(date -u +"%Y-%m-%d")
INCIDENT_TIME=$(date -u +"%H:%M:%S")
SAFE_TITLE=$(echo "$TITLE" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
OUTPUT_FILE="${OUTPUT_DIR}/incident-${INCIDENT_DATE}-${SAFE_TITLE}.md"

echo "=== INCIDENT REPORT GENERATOR ===" >&2
echo "Title: $TITLE" >&2
echo "Severity: $SEVERITY" >&2
echo "Namespace: $NAMESPACE" >&2
echo "Service: $SERVICE" >&2
echo "Output: $OUTPUT_FILE" >&2
echo "" >&2

# Gather automated data
echo "### Gathering Cluster Data ###" >&2

# Pod status
echo "  Collecting pod status..." >&2
POD_STATUS=$($CLI get pods -n "$NAMESPACE" -l "app=$SERVICE" -o wide 2>/dev/null || \
             $CLI get pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$SERVICE" -o wide 2>/dev/null || \
             echo "Unable to fetch pod status")

# Recent events
echo "  Collecting recent events..." >&2
EVENTS=$($CLI get events -n "$NAMESPACE" --sort-by='.lastTimestamp' --field-selector type=Warning 2>/dev/null | tail -20 || echo "Unable to fetch events")

# Deployment info
echo "  Collecting deployment info..." >&2
DEPLOYMENT=$($CLI get deployment "$SERVICE" -n "$NAMESPACE" -o json 2>/dev/null || echo "")
CURRENT_IMAGE=""
REPLICAS=""
if [ -n "$DEPLOYMENT" ]; then
    CURRENT_IMAGE=$(echo "$DEPLOYMENT" | jq -r '.spec.template.spec.containers[0].image // "unknown"' 2>/dev/null)
    REPLICAS=$(echo "$DEPLOYMENT" | jq -r '"\(.status.readyReplicas // 0)/\(.status.replicas // 0)"' 2>/dev/null)
fi

# Recent rollout history
echo "  Collecting rollout history..." >&2
ROLLOUT_HISTORY=$($CLI rollout history deployment/"$SERVICE" -n "$NAMESPACE" 2>/dev/null | tail -10 || echo "Unable to fetch rollout history")

# Node status
echo "  Collecting node status..." >&2
NODE_STATUS=$($CLI get nodes --no-headers -o custom-columns='NAME:.metadata.name,STATUS:.status.conditions[?(@.type=="Ready")].status,VERSION:.status.nodeInfo.kubeletVersion' 2>/dev/null | head -10 || echo "Unable to fetch node status")

# Resource usage
echo "  Collecting resource usage..." >&2
TOP_PODS=$($CLI top pods -n "$NAMESPACE" -l "app=$SERVICE" 2>/dev/null || \
           $CLI top pods -n "$NAMESPACE" -l "app.kubernetes.io/name=$SERVICE" 2>/dev/null || \
           echo "Unable to fetch resource usage (metrics-server may not be available)")

# ArgoCD app status
echo "  Collecting ArgoCD status..." >&2
ARGO_STATUS=""
if command -v argocd &> /dev/null; then
    ARGO_STATUS=$(argocd app get "${SERVICE}" -o json 2>/dev/null | jq '{health: .status.health.status, sync: .status.sync.status, revision: .status.sync.revision}' 2>/dev/null || echo "N/A")
fi

echo "" >&2
echo "### Generating Report ###" >&2

# Create output directory
mkdir -p "$OUTPUT_DIR"

# Generate the report
cat > "$OUTPUT_FILE" << 'HEADER'
# Post-Incident Review
HEADER

cat >> "$OUTPUT_FILE" << EOF

## Incident: ${TITLE}

| Field | Value |
|-------|-------|
| **Date** | ${INCIDENT_DATE} |
| **Time (UTC)** | ${INCIDENT_TIME} |
| **Severity** | ${SEVERITY} |
| **Service** | ${SERVICE} |
| **Namespace** | ${NAMESPACE} |
| **Current Image** | ${CURRENT_IMAGE:-unknown} |
| **Replicas** | ${REPLICAS:-unknown} |
| **Status** | UNDER REVIEW |

---

## Timeline

| Time (UTC) | Event |
|-----------|-------|
| ${INCIDENT_TIME} | Incident report generated |
| | *[Add detection time]* |
| | *[Add investigation start]* |
| | *[Add root cause identified]* |
| | *[Add fix applied]* |
| | *[Add service recovered]* |

---

## Impact

*[Describe the user-facing impact]*

- Users affected: *[number/percentage]*
- Duration: *[from - to]*
- Data loss: *[yes/no]*
- Revenue impact: *[if applicable]*

---

## Root Cause

*[Describe the root cause once identified]*

## Contributing Factors

- *[Factor 1]*
- *[Factor 2]*

---

## Automated Data Collection

### Pod Status at Report Time

\`\`\`
${POD_STATUS}
\`\`\`

### Resource Usage

\`\`\`
${TOP_PODS}
\`\`\`

### Recent Warning Events

\`\`\`
${EVENTS}
\`\`\`

### Rollout History

\`\`\`
${ROLLOUT_HISTORY}
\`\`\`

### Node Status

\`\`\`
${NODE_STATUS}
\`\`\`

### ArgoCD Status

\`\`\`
${ARGO_STATUS:-N/A}
\`\`\`

---

## Detection

- **How was this detected?** *[alert / user report / monitoring]*
- **MTTD (Mean Time to Detection):** *[minutes]*
- **Alert that fired:** *[alert name]*

## Resolution

- **What fixed it?** *[describe fix]*
- **MTTR (Mean Time to Resolution):** *[minutes]*
- **Rollback required?** *[yes/no]*

---

## Action Items

| # | Action | Owner | Due Date | Priority | Status |
|---|--------|-------|----------|----------|--------|
| 1 | *[Action item]* | *[Owner]* | *[Date]* | High | Open |
| 2 | *[Action item]* | *[Owner]* | *[Date]* | Medium | Open |
| 3 | *[Action item]* | *[Owner]* | *[Date]* | Low | Open |

---

## Lessons Learned

### What went well?
- *[e.g., Alert fired promptly]*
- *[e.g., Rollback was quick]*

### What could be improved?
- *[e.g., Need better monitoring for X]*
- *[e.g., Runbook was missing steps]*

### What was lucky?
- *[e.g., Happened during business hours]*

---

## Appendix

### Relevant Metrics Queries

\`\`\`promql
# Error rate during incident
rate(http_requests_total{service="${SERVICE}", status=~"5.."}[5m])

# Latency during incident  
histogram_quantile(0.99, rate(http_request_duration_seconds_bucket{service="${SERVICE}"}[5m]))

# Pod restarts
increase(kube_pod_container_status_restarts_total{namespace="${NAMESPACE}"}[1h])
\`\`\`

### Relevant Log Queries

\`\`\`logql
{namespace="${NAMESPACE}", app="${SERVICE}"} |= "error"
{namespace="${NAMESPACE}", app="${SERVICE}"} | json | level="error"
\`\`\`

---

*Report generated by Pulse (Observability Agent) at ${INCIDENT_DATE}T${INCIDENT_TIME}Z*
*Review and complete all sections marked with [brackets]*
EOF

echo "✅ Report generated: $OUTPUT_FILE" >&2
echo "" >&2
echo "========================================" >&2
echo "INCIDENT REPORT CREATED" >&2
echo "  File: $OUTPUT_FILE" >&2
echo "  Next: Fill in timeline, root cause, and action items" >&2
echo "========================================" >&2

# Output JSON
cat << EOF
{
  "report_type": "incident",
  "title": "$TITLE",
  "severity": "$SEVERITY",
  "service": "$SERVICE",
  "namespace": "$NAMESPACE",
  "output_file": "$OUTPUT_FILE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "automated_data": {
    "pod_status": true,
    "events": true,
    "rollout_history": true,
    "resource_usage": true,
    "node_status": true,
    "argocd_status": $([ -n "$ARGO_STATUS" ] && echo "true" || echo "false")
  }
}
EOF
