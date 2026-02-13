#!/bin/bash
# security-audit.sh - Comprehensive security posture audit
# Usage: ./security-audit.sh [namespace]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

NAMESPACE=${1:-""}
CLI=$(detect_kube_cli)
require_bin jq
ensure_cluster_access "$CLI"

if [ -n "$NAMESPACE" ]; then
    if ! $CLI get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "ERROR: Namespace '$NAMESPACE' not found." >&2
        exit 1
    fi
    NS_ARGS=(-n "$NAMESPACE")
    SCOPE="namespace: $NAMESPACE"
else
    NS_ARGS=(-A)
    SCOPE="cluster-wide"
fi

echo "=== SECURITY POSTURE AUDIT ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Scope: $SCOPE" >&2
echo "CLI: $CLI" >&2
echo "" >&2

FINDINGS=()

add_finding() {
    local severity="$1"
    local category="$2"
    local message="$3"
    local resource="$4"
    FINDINGS+=("{\"severity\":\"$severity\",\"category\":\"$category\",\"message\":\"$message\",\"resource\":\"$resource\"}")
    echo "[$severity] $category: $message — $resource" >&2
}

# 1. Privileged Containers
echo "### Checking Privileged Containers ###" >&2
PRIV_PODS=$($CLI get pods "${NS_ARGS[@]}" -o json 2>/dev/null | jq -r '.items[] | select(.spec.containers[]?.securityContext?.privileged == true) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
if [ -n "$PRIV_PODS" ]; then
    while IFS= read -r pod; do
        [ -n "$pod" ] && add_finding "CRITICAL" "privileged-container" "Container running in privileged mode" "$pod"
    done <<< "$PRIV_PODS"
else
    echo "  ✅ No privileged containers found" >&2
fi

# 2. Containers Running as Root
echo -e "\n### Checking Root Containers ###" >&2
ROOT_PODS=$($CLI get pods "${NS_ARGS[@]}" -o json 2>/dev/null | jq -r '
  .items[] | 
  select(
    (.spec.securityContext?.runAsNonRoot != true) and 
    (.spec.containers[]?.securityContext?.runAsNonRoot != true) and
    ((.spec.containers[]?.securityContext?.runAsUser // 0) == 0)
  ) | 
  "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null || echo "")
if [ -n "$ROOT_PODS" ]; then
    ROOT_COUNT=$(echo "$ROOT_PODS" | grep -c '.' || true)
    echo "  ⚠️  $ROOT_COUNT pods potentially running as root" >&2
    while IFS= read -r pod; do
        [ -n "$pod" ] && add_finding "HIGH" "root-container" "Container may run as root (UID 0)" "$pod"
    done <<< "$ROOT_PODS"
else
    echo "  ✅ All containers appear to run as non-root" >&2
fi

# 3. hostNetwork / hostPID / hostIPC
echo -e "\n### Checking Host Namespace Sharing ###" >&2
HOST_PODS=$($CLI get pods "${NS_ARGS[@]}" -o json 2>/dev/null | jq -r '.items[] | select(.spec.hostNetwork == true or .spec.hostPID == true or .spec.hostIPC == true) | "\(.metadata.namespace)/\(.metadata.name):\(if .spec.hostNetwork then "hostNetwork" else "" end)\(if .spec.hostPID then ",hostPID" else "" end)\(if .spec.hostIPC then ",hostIPC" else "" end)"' 2>/dev/null || echo "")
if [ -n "$HOST_PODS" ]; then
    while IFS= read -r entry; do
        [ -n "$entry" ] && add_finding "HIGH" "host-namespace" "Pod shares host namespace" "$entry"
    done <<< "$HOST_PODS"
else
    echo "  ✅ No pods sharing host namespaces" >&2
fi

# 4. Capabilities Granted
echo -e "\n### Checking Added Capabilities ###" >&2
CAP_PODS=$($CLI get pods "${NS_ARGS[@]}" -o json 2>/dev/null | jq -r '.items[] | . as $pod | .spec.containers[]? | select(.securityContext?.capabilities?.add? | length > 0) | "\($pod.metadata.namespace)/\($pod.metadata.name):\(.securityContext.capabilities.add | join(","))"' 2>/dev/null || echo "")
if [ -n "$CAP_PODS" ]; then
    while IFS= read -r entry; do
        [ -n "$entry" ] && add_finding "MEDIUM" "capabilities" "Container has added capabilities" "$entry"
    done <<< "$CAP_PODS"
else
    echo "  ✅ No extra capabilities granted" >&2
fi

# 5. Writable Root Filesystem
echo -e "\n### Checking Read-Only Root Filesystem ###" >&2
WRITABLE_PODS=$($CLI get pods "${NS_ARGS[@]}" -o json 2>/dev/null | jq -r '.items[] | . as $pod | .spec.containers[]? | select(.securityContext?.readOnlyRootFilesystem != true) | "\($pod.metadata.namespace)/\($pod.metadata.name)/\(.name)"' 2>/dev/null | head -20 || echo "")
if [ -n "$WRITABLE_PODS" ]; then
    WRITABLE_COUNT=$(echo "$WRITABLE_PODS" | grep -c '.' || true)
    echo "  ⚠️  $WRITABLE_COUNT containers with writable rootfs (showing first 20)" >&2
    while IFS= read -r entry; do
        [ -n "$entry" ] && add_finding "LOW" "writable-rootfs" "Container rootfs is writable" "$entry"
    done <<< "$WRITABLE_PODS"
else
    echo "  ✅ All containers have read-only root filesystem" >&2
fi

# 6. RBAC Wildcards (cluster-wide only)
if [ -z "$NAMESPACE" ]; then
    echo -e "\n### Checking RBAC Wildcards ###" >&2
    WILDCARD_ROLES=$($CLI get clusterroles -o json 2>/dev/null | jq -r '.items[] | select(.rules[]? | (.apiGroups[]? == "*") or (.resources[]? == "*") or (.verbs[]? == "*")) | .metadata.name' 2>/dev/null | grep -v "^system:" | head -20 || echo "")
    if [ -n "$WILDCARD_ROLES" ]; then
        while IFS= read -r role; do
            [ -n "$role" ] && add_finding "HIGH" "rbac-wildcard" "ClusterRole uses wildcard permissions" "clusterrole/$role"
        done <<< "$WILDCARD_ROLES"
    else
        echo "  ✅ No custom ClusterRoles with wildcard permissions" >&2
    fi
fi

# 7. Missing Network Policies
echo -e "\n### Checking NetworkPolicy Coverage ###" >&2
if [ -n "$NAMESPACE" ]; then
    ALL_NS="$NAMESPACE"
else
    ALL_NS=$($CLI get namespaces --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -v "^kube-\|^openshift-\|^default$\|^calico-\|^tigera-" || echo "")
fi
MISSING_NP=0
if [ -n "$ALL_NS" ]; then
    while IFS= read -r ns; do
        NP_COUNT=$($CLI get networkpolicies -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
        if [ "$NP_COUNT" -eq 0 ]; then
            add_finding "MEDIUM" "missing-netpol" "Namespace has no NetworkPolicies" "namespace/$ns"
            MISSING_NP=$((MISSING_NP + 1))
        fi
    done <<< "$ALL_NS"
    [ "$MISSING_NP" -eq 0 ] && echo "  ✅ All user namespaces have NetworkPolicies" >&2
fi

# 8. ServiceAccount Token Auto-mount
echo -e "\n### Checking ServiceAccount Token Auto-mount ###" >&2
AUTOMOUNT_SA=$($CLI get serviceaccounts "${NS_ARGS[@]}" -o json 2>/dev/null | jq -r '.items[] | select(.automountServiceAccountToken != false) | "\(.metadata.namespace)/\(.metadata.name)"' 2>/dev/null | grep -v "/default$" | head -20 || echo "")
if [ -n "$AUTOMOUNT_SA" ]; then
    SA_COUNT=$(echo "$AUTOMOUNT_SA" | grep -c '.' || true)
    echo "  ⚠️  $SA_COUNT service accounts with auto-mount enabled" >&2
    while IFS= read -r sa; do
        [ -n "$sa" ] && add_finding "LOW" "automount-token" "ServiceAccount auto-mount token enabled" "$sa"
    done <<< "$AUTOMOUNT_SA"
fi

# 9. Pod Security Admission Labels
echo -e "\n### Checking Pod Security Admission ###" >&2
NO_PSA=$($CLI get namespaces -o json 2>/dev/null | jq -r '.items[] | select(.metadata.labels["pod-security.kubernetes.io/enforce"] == null) | .metadata.name' 2>/dev/null | grep -v "^kube-\|^openshift-\|^default$" || echo "")
if [ -n "$NO_PSA" ]; then
    while IFS= read -r ns; do
        [ -n "$ns" ] && add_finding "MEDIUM" "missing-psa" "Namespace has no PSA enforcement" "namespace/$ns"
    done <<< "$NO_PSA"
else
    echo "  ✅ All namespaces have PSA enforcement" >&2
fi

# Summary
echo "" >&2
echo "========================================" >&2
CRITICAL=$(printf '%s\n' "${FINDINGS[@]}" | grep '"CRITICAL"' | wc -l | tr -d ' ')
HIGH=$(printf '%s\n' "${FINDINGS[@]}" | grep '"HIGH"' | wc -l | tr -d ' ')
MEDIUM=$(printf '%s\n' "${FINDINGS[@]}" | grep '"MEDIUM"' | wc -l | tr -d ' ')
LOW=$(printf '%s\n' "${FINDINGS[@]}" | grep '"LOW"' | wc -l | tr -d ' ')
TOTAL=${#FINDINGS[@]}

echo "SECURITY AUDIT SUMMARY" >&2
echo "  Critical: $CRITICAL" >&2
echo "  High:     $HIGH" >&2
echo "  Medium:   $MEDIUM" >&2
echo "  Low:      $LOW" >&2
echo "  Total:    $TOTAL findings" >&2
echo "========================================" >&2

# Output JSON
FINDINGS_JSON=$(printf '%s\n' "${FINDINGS[@]}" | jq -s '.' 2>/dev/null || echo "[]")
cat << EOF
{
  "audit_type": "security-posture",
  "scope": "$SCOPE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "summary": {
    "critical": $CRITICAL,
    "high": $HIGH,
    "medium": $MEDIUM,
    "low": $LOW,
    "total": $TOTAL
  },
  "findings": $FINDINGS_JSON
}
EOF

[ "$CRITICAL" -gt 0 ] && exit 2
[ "$HIGH" -gt 0 ] && exit 1
exit 0
