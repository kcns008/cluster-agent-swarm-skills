#!/bin/bash
# rbac-audit.sh - RBAC permissions audit for Kubernetes / OpenShift
# Usage: ./rbac-audit.sh [namespace]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

NAMESPACE=${1:-""}
CLI=$(detect_kube_cli)
require_bin jq
ensure_cluster_access "$CLI"

echo "=== RBAC AUDIT ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "CLI: $CLI" >&2
echo "" >&2

FINDINGS=()

add_finding() {
    local severity="$1"
    local category="$2"
    local message="$3"
    local resource="$4"
    FINDINGS+=("{\"severity\":\"$severity\",\"category\":\"$category\",\"message\":\"$message\",\"resource\":\"$resource\"}")
    echo "  [$severity] $message — $resource" >&2
}

# 1. ClusterRoles with wildcard permissions
echo "### ClusterRoles with Wildcard Permissions ###" >&2
WILDCARD_ROLES=$($CLI get clusterroles -o json 2>/dev/null | jq -r '
  .items[] |
  select(.rules[]? | (.apiGroups[]? == "*") or (.resources[]? == "*") or (.verbs[]? == "*")) |
  .metadata.name' 2>/dev/null | grep -v "^system:" | sort || echo "")

if [ -n "$WILDCARD_ROLES" ]; then
    COUNT=$(echo "$WILDCARD_ROLES" | wc -l | tr -d ' ')
    echo "  ⚠️  $COUNT custom ClusterRoles with wildcards" >&2
    while IFS= read -r role; do
        [ -n "$role" ] && add_finding "HIGH" "wildcard-role" "ClusterRole uses wildcard permissions" "clusterrole/$role"
    done <<< "$WILDCARD_ROLES"
else
    echo "  ✅ No custom ClusterRoles with wildcard permissions" >&2
fi

# 2. ClusterRoleBindings to cluster-admin
echo -e "\n### cluster-admin Bindings ###" >&2
ADMIN_BINDINGS=$($CLI get clusterrolebindings -o json 2>/dev/null | jq -r '
  .items[] |
  select(.roleRef.name == "cluster-admin") |
  "\(.metadata.name) → \(.subjects[]? | "\(.kind)/\(.name)")"' 2>/dev/null | grep -v "^system:" | sort || echo "")

if [ -n "$ADMIN_BINDINGS" ]; then
    echo "$ADMIN_BINDINGS" | while IFS= read -r binding; do
        echo "  🔑 $binding" >&2
    done
    COUNT=$(echo "$ADMIN_BINDINGS" | wc -l | tr -d ' ')
    add_finding "HIGH" "cluster-admin" "$COUNT subjects bound to cluster-admin" "clusterrolebinding/cluster-admin"
else
    echo "  ✅ No non-system cluster-admin bindings" >&2
fi

# 3. ServiceAccounts with secrets access
echo -e "\n### ServiceAccounts with Secrets Access ###" >&2
SECRETS_ACCESS=$($CLI get clusterroles -o json 2>/dev/null | jq -r '
  .items[] |
  select(.rules[]? | 
    select(
      (.resources[]? | test("secrets")) and
      (.verbs[]? | test("get|list|watch|create|update|patch|delete|\\*"))
    )
  ) | .metadata.name' 2>/dev/null | grep -v "^system:" | sort || echo "")

if [ -n "$SECRETS_ACCESS" ]; then
    echo "  ⚠️  ClusterRoles with secrets access:" >&2
    while IFS= read -r role; do
        [ -n "$role" ] && add_finding "HIGH" "secrets-access" "ClusterRole can access secrets" "clusterrole/$role"
        echo "    - $role" >&2
    done <<< "$SECRETS_ACCESS"
else
    echo "  ✅ No custom ClusterRoles with secrets access" >&2
fi

# 4. Default ServiceAccount usage
echo -e "\n### Pods Using Default ServiceAccount ###" >&2
if [ -n "$NAMESPACE" ]; then
    DEFAULT_SA_PODS=$($CLI get pods -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.items[] | select(.spec.serviceAccountName == "default" or .spec.serviceAccountName == null) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
else
    DEFAULT_SA_PODS=$($CLI get pods -A -o json 2>/dev/null | jq -r '.items[] | select(.spec.serviceAccountName == "default" or .spec.serviceAccountName == null) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | grep -v "^kube-\|^openshift-" | head -30 || echo "")
fi

if [ -n "$DEFAULT_SA_PODS" ]; then
    COUNT=$(echo "$DEFAULT_SA_PODS" | wc -l | tr -d ' ')
    echo "  ⚠️  $COUNT pods using default service account" >&2
    add_finding "MEDIUM" "default-sa" "$COUNT pods use the default ServiceAccount" "various"
else
    echo "  ✅ No user pods using default ServiceAccount" >&2
fi

# 5. RoleBindings with excessive permissions (namespace scope)
if [ -n "$NAMESPACE" ]; then
    echo -e "\n### RoleBindings in $NAMESPACE ###" >&2
    $CLI get rolebindings -n "$NAMESPACE" -o json 2>/dev/null | jq -r '
      .items[] | "\(.metadata.name): \(.roleRef.kind)/\(.roleRef.name) → \(.subjects[]? | "\(.kind)/\(.name)")"' 2>/dev/null | while IFS= read -r binding; do
        echo "  📋 $binding" >&2
    done
fi

# 6. Stale ClusterRoleBindings (bound to deleted subjects)
echo -e "\n### Orphaned Bindings Check ###" >&2
ORPHAN_COUNT=0
ORPHAN_BINDINGS=$($CLI get clusterrolebindings -o json 2>/dev/null | jq -r '
  .items[] | 
  select(.subjects[]? | .kind == "ServiceAccount") |
    "\(.metadata.name)|\(.subjects[]? | select(.kind == "ServiceAccount") | "\(.namespace)/\(.name)")"' 2>/dev/null | sort -u || echo "")

if [ -n "$ORPHAN_BINDINGS" ]; then
    while IFS='|' read -r binding sa; do
        [ -z "$binding" ] && continue
        SA_NS=$(echo "$sa" | cut -d'/' -f1)
        SA_NAME=$(echo "$sa" | cut -d'/' -f2)
        if ! $CLI get serviceaccount "$SA_NAME" -n "$SA_NS" &>/dev/null; then
            add_finding "LOW" "orphaned-binding" "Binding references non-existent SA" "crb/$binding → sa/$sa"
            ORPHAN_COUNT=$((ORPHAN_COUNT + 1))
        fi
    done <<< "$ORPHAN_BINDINGS"
fi
echo "  Orphaned bindings found: $ORPHAN_COUNT" >&2

# 7. Aggregate ClusterRoles
echo -e "\n### Aggregate ClusterRoles ###" >&2
AGG_ROLES=$($CLI get clusterroles -o json 2>/dev/null | jq -r '.items[] | select(.metadata.labels["rbac.authorization.k8s.io/aggregate-to-admin"] == "true" or .metadata.labels["rbac.authorization.k8s.io/aggregate-to-edit"] == "true") | .metadata.name' 2>/dev/null | grep -v "^system:" | sort || echo "")
if [ -n "$AGG_ROLES" ]; then
    echo "  ℹ️  Custom aggregate ClusterRoles found:" >&2
    while IFS= read -r role; do
        echo "    - $role" >&2
        add_finding "LOW" "aggregate-role" "Custom aggregate role detected" "clusterrole/$role"
    done <<< "$AGG_ROLES"
fi

# Summary
echo "" >&2
echo "========================================" >&2
TOTAL=${#FINDINGS[@]}
echo "RBAC AUDIT COMPLETE: $TOTAL findings" >&2
echo "========================================" >&2

# Output JSON
FINDINGS_JSON=$(printf '%s\n' "${FINDINGS[@]}" | jq -s '.' 2>/dev/null || echo "[]")
cat << EOF
{
  "audit_type": "rbac",
  "scope": "${NAMESPACE:-cluster-wide}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "total_findings": $TOTAL,
    "orphaned_bindings": $ORPHAN_COUNT,
  "findings": $FINDINGS_JSON
}
EOF
