#!/bin/bash
# route-task.sh - Route a task to the appropriate agent based on keywords
# Usage: ./route-task.sh <task-description>

set -e

DESCRIPTION=${1:-""}

if [ -z "$DESCRIPTION" ]; then
    echo "Usage: $0 <task-description>" >&2
    echo "" >&2
    echo "Routes a task to the appropriate agent based on content analysis." >&2
    echo "" >&2
    echo "Available agents:" >&2
    echo "  atlas  - Cluster Ops (nodes, upgrades, etcd, capacity)" >&2
    echo "  flow   - GitOps (ArgoCD, Helm, deploy, rollback)" >&2
    echo "  shield - Security (RBAC, policies, CVE, secrets, vault)" >&2
    echo "  pulse  - Observability (metrics, alerts, incidents, logs)" >&2
    echo "  cache  - Artifacts (registry, images, SBOM, promotion)" >&2
    echo "  desk   - Developer Experience (namespace, onboard, debug)" >&2
    exit 1
fi

echo "=== TASK ROUTING ===" >&2
echo "Input: $DESCRIPTION" >&2
echo "" >&2

# Lowercase the description for matching
DESC_LOWER=$(echo "$DESCRIPTION" | tr '[:upper:]' '[:lower:]')

# Route based on keyword matching
AGENT=""
CONFIDENCE="high"

# Cluster Ops patterns
if echo "$DESC_LOWER" | grep -qE "node|upgrade|cluster.*(health|version|scale)|etcd|drain|cordon|capacity|worker|master|control.plane|machine.?set|machine.?pool|autoscal|kubelet|oc adm"; then
    AGENT="atlas"
    ROLE="Cluster Ops"

# GitOps patterns
elif echo "$DESC_LOWER" | grep -qE "deploy|argocd|argo|helm|kustomize|rollback|sync|canary|blue.green|rolling|gitops|flux|app.?set|chart|overlay|manifest"; then
    AGENT="flow"
    ROLE="GitOps"

# Security patterns
elif echo "$DESC_LOWER" | grep -qE "security|rbac|role.?binding|network.?policy|vault|secret|cve|vuln|scan|policy|kyverno|opa|gatekeeper|compliance|cis|soc2|pci|pod.security|pss|psa|cosign|sigstore|falco|audit"; then
    AGENT="shield"
    ROLE="Security"

# Observability patterns
elif echo "$DESC_LOWER" | grep -qE "alert|metric|prometheus|grafana|dashboard|incident|p[12]|latency|error.rate|slo|sli|error.budget|log|loki|elastic|pagerduty|opsgenie|rca|post.?mortem|promql|thanos"; then
    AGENT="pulse"
    ROLE="Observability"

# Artifact patterns
elif echo "$DESC_LOWER" | grep -qE "image|registry|artifact|artifactory|jfrog|sbom|promote|promotion|trivy|grype|container.scan|build|pipeline|ci.?cd|retention|cleanup|tag"; then
    AGENT="cache"
    ROLE="Artifacts"

# Developer Experience patterns
elif echo "$DESC_LOWER" | grep -qE "namespace|onboard|provision|crashloop|oomkill|imagepull|debug|developer|backstage|template|scaffold|team|quota|resource.quota|limit.range"; then
    AGENT="desk"
    ROLE="Developer Experience"

# Multi-agent / coordination patterns
elif echo "$DESC_LOWER" | grep -qE "coordinate|standup|status|all.agents|swarm|team|workflow"; then
    AGENT="orchestrator"
    ROLE="Coordinator"

else
    AGENT="orchestrator"
    ROLE="Coordinator"
    CONFIDENCE="low"
    echo "WARNING: No clear keyword match. Routing to orchestrator for triage." >&2
fi

echo "Routed to: $AGENT ($ROLE)" >&2
echo "Confidence: $CONFIDENCE" >&2

# Output JSON
cat << EOF
{
  "task_description": "$DESCRIPTION",
  "routed_to": {
    "agent": "$AGENT",
    "role": "$ROLE",
    "session_key": "agent:platform:$AGENT"
  },
  "confidence": "$CONFIDENCE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
