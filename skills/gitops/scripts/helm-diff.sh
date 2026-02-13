#!/bin/bash
# helm-diff.sh - Show diff of Helm release before upgrade
# Usage: ./helm-diff.sh <release-name> <chart> <namespace> [values-file]

set -e

RELEASE=${1:-""}
CHART=${2:-""}
NAMESPACE=${3:-"default"}
VALUES=${4:-"values.yaml"}

if [ -z "$RELEASE" ] || [ -z "$CHART" ]; then
    echo "Usage: $0 <release-name> <chart> <namespace> [values-file]" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 myapp bitnami/nginx production" >&2
    echo "  $0 myapp ./charts/myapp production values-prod.yaml" >&2
    echo "" >&2
    echo "Current releases:" >&2
    helm list -A --short 2>/dev/null
    exit 1
fi

echo "=== HELM DIFF: $RELEASE ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Chart: $CHART" >&2
echo "Namespace: $NAMESPACE" >&2
echo "Values: $VALUES" >&2
echo "" >&2

# Check if helm-diff plugin is available
if helm plugin list 2>/dev/null | grep -q "diff"; then
    echo "### Using helm-diff plugin ###" >&2
    DIFF_OPTS="--namespace $NAMESPACE"
    if [ -f "$VALUES" ]; then
        DIFF_OPTS="$DIFF_OPTS -f $VALUES"
    fi
    
    DIFF_OUTPUT=$(helm diff upgrade "$RELEASE" "$CHART" $DIFF_OPTS 2>&1)
    CHANGES=$(echo "$DIFF_OUTPUT" | grep -c "^[-+]" || echo 0)
    
    echo "$DIFF_OUTPUT" >&2
else
    echo "### helm-diff plugin not installed, using template comparison ###" >&2
    
    # Get current release manifest
    CURRENT=$(helm get manifest "$RELEASE" --namespace "$NAMESPACE" 2>/dev/null || echo "")
    
    # Template the new version
    TEMPLATE_OPTS="--namespace $NAMESPACE"
    if [ -f "$VALUES" ]; then
        TEMPLATE_OPTS="$TEMPLATE_OPTS -f $VALUES"
    fi
    NEW=$(helm template "$RELEASE" "$CHART" $TEMPLATE_OPTS 2>/dev/null || echo "")
    
    if [ -z "$CURRENT" ]; then
        echo "No existing release found. This would be a fresh install." >&2
        CHANGES=0
    else
        DIFF_OUTPUT=$(diff <(echo "$CURRENT") <(echo "$NEW") 2>&1 || true)
        CHANGES=$(echo "$DIFF_OUTPUT" | grep -c "^[<>]" || echo 0)
        echo "$DIFF_OUTPUT" >&2
    fi
fi

# Current release info
echo -e "\n### Current Release Info ###" >&2
helm status "$RELEASE" --namespace "$NAMESPACE" 2>/dev/null | head -15 >&2 || echo "Release not found (new install)" >&2

echo "" >&2
echo "========================================" >&2
echo "HELM DIFF COMPLETE" >&2
echo "========================================" >&2
echo "Changes detected: $CHANGES lines" >&2

# Output JSON
cat << EOF
{
  "release": "$RELEASE",
  "chart": "$CHART",
  "namespace": "$NAMESPACE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "changes_detected": $CHANGES,
  "has_changes": $([ "$CHANGES" -gt 0 ] && echo "true" || echo "false")
}
EOF
