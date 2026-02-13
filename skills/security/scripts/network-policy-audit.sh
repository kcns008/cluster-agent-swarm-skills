#!/bin/bash
# network-policy-audit.sh - NetworkPolicy coverage and compliance audit
# Usage: ./network-policy-audit.sh [namespace]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

NAMESPACE=${1:-""}
CLI=$(detect_kube_cli)
require_bin jq
ensure_cluster_access "$CLI"

echo "=== NETWORK POLICY AUDIT ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "CLI: $CLI" >&2
echo "" >&2

FINDINGS=()

add_finding() {
    local severity="$1"
    local category="$2"
    local ns="$3"
    local message="$4"
    FINDINGS+=("{\"severity\":\"$severity\",\"category\":\"$category\",\"namespace\":\"$ns\",\"message\":\"$message\"}")
    echo "  [$severity] $ns: $message" >&2
}

# Determine namespaces to audit
if [ -n "$NAMESPACE" ]; then
    if ! $CLI get namespace "$NAMESPACE" >/dev/null 2>&1; then
        echo "ERROR: Namespace '$NAMESPACE' not found." >&2
        exit 1
    fi
    NAMESPACES="$NAMESPACE"
else
    NAMESPACES=$($CLI get namespaces --no-headers -o custom-columns=NAME:.metadata.name 2>/dev/null | grep -v "^kube-\|^openshift-\|^default$\|^calico-\|^tigera-" || echo "")
fi

echo "### Namespaces to audit ###" >&2
NS_COUNT=$(printf '%s\n' "$NAMESPACES" | grep -c . || true)
echo "  Auditing $NS_COUNT namespaces" >&2
echo "" >&2

TOTAL_NS=0
COVERED_NS=0
DENY_ALL=0
INGRESS_ONLY=0
EGRESS_ONLY=0
FULL_COVERAGE=0
NO_POLICY=0

echo "### NetworkPolicy Coverage ###" >&2
while IFS= read -r ns; do
    [ -z "$ns" ] && continue
    TOTAL_NS=$((TOTAL_NS + 1))
    
    # Get all NetworkPolicies in namespace
    NP_JSON=$($CLI get networkpolicies -n "$ns" -o json 2>/dev/null || echo '{"items":[]}')
    NP_COUNT=$(echo "$NP_JSON" | jq '.items | length')
    
    if [ "$NP_COUNT" -eq 0 ]; then
        add_finding "HIGH" "no-netpol" "$ns" "No NetworkPolicies defined"
        NO_POLICY=$((NO_POLICY + 1))
        continue
    fi
    
    COVERED_NS=$((COVERED_NS + 1))
    
    # Check for default deny
    HAS_DENY_INGRESS=$(echo "$NP_JSON" | jq '[.items[] | select(.spec.podSelector == {} or .spec.podSelector.matchLabels == null) | select(.spec.policyTypes[]? == "Ingress") | select(.spec.ingress == null or (.spec.ingress | length == 0))] | length')
    HAS_DENY_EGRESS=$(echo "$NP_JSON" | jq '[.items[] | select(.spec.podSelector == {} or .spec.podSelector.matchLabels == null) | select(.spec.policyTypes[]? == "Egress") | select(.spec.egress == null or (.spec.egress | length == 0))] | length')
    
    if [ "$HAS_DENY_INGRESS" -gt 0 ] && [ "$HAS_DENY_EGRESS" -gt 0 ]; then
        echo "  ✅ $ns: Default deny ALL (ingress + egress)" >&2
        DENY_ALL=$((DENY_ALL + 1))
        FULL_COVERAGE=$((FULL_COVERAGE + 1))
    elif [ "$HAS_DENY_INGRESS" -gt 0 ]; then
        echo "  ⚠️  $ns: Default deny INGRESS only (no egress deny)" >&2
        INGRESS_ONLY=$((INGRESS_ONLY + 1))
        add_finding "MEDIUM" "no-egress-deny" "$ns" "Has ingress deny but no egress deny"
    elif [ "$HAS_DENY_EGRESS" -gt 0 ]; then
        echo "  ⚠️  $ns: Default deny EGRESS only (no ingress deny)" >&2
        EGRESS_ONLY=$((EGRESS_ONLY + 1))
        add_finding "MEDIUM" "no-ingress-deny" "$ns" "Has egress deny but no ingress deny"
    else
        echo "  ⚠️  $ns: Has $NP_COUNT policies but no default deny" >&2
        add_finding "MEDIUM" "no-default-deny" "$ns" "Has policies but no default deny-all"
    fi
    
    # Check for overly permissive policies (allow-all)
    ALLOW_ALL=$(echo "$NP_JSON" | jq '[.items[] | .spec.ingress[]? | select((has("from") | not) or (.from == null) or ((.from | type) == "array" and (.from | length) == 0))] | length')
    if [ "$ALLOW_ALL" -gt 0 ]; then
        add_finding "HIGH" "allow-all-ingress" "$ns" "Policy allows ingress from all sources"
    fi
    
    ALLOW_ALL_EGRESS=$(echo "$NP_JSON" | jq '[.items[] | .spec.egress[]? | select((has("to") | not) or (.to == null) or ((.to | type) == "array" and (.to | length) == 0))] | length')
    if [ "$ALLOW_ALL_EGRESS" -gt 0 ]; then
        add_finding "MEDIUM" "allow-all-egress" "$ns" "Policy allows egress to all destinations"
    fi
    
    # Check for policies without port restrictions
    NO_PORT_POLICY=$(echo "$NP_JSON" | jq '[.items[] | select(.spec.ingress[]? | select(.ports == null) | select(.from != null))] | length')
    if [ "$NO_PORT_POLICY" -gt 0 ]; then
        add_finding "LOW" "no-port-restriction" "$ns" "Policy allows all ports on ingress"
    fi
    
done <<< "$NAMESPACES"

# Coverage percentage
if [ "$TOTAL_NS" -gt 0 ]; then
    COVERAGE_PCT=$(( (COVERED_NS * 100) / TOTAL_NS ))
else
    COVERAGE_PCT=0
fi

# Summary
echo "" >&2
echo "========================================" >&2
echo "NETWORK POLICY AUDIT SUMMARY" >&2
echo "========================================" >&2
echo "Total namespaces audited: $TOTAL_NS" >&2
echo "Namespaces with policies: $COVERED_NS ($COVERAGE_PCT%)" >&2
echo "Namespaces without policies: $NO_POLICY" >&2
echo "Default deny ALL: $DENY_ALL" >&2
echo "Full coverage: $FULL_COVERAGE" >&2
echo "Ingress-only deny: $INGRESS_ONLY" >&2
echo "Egress-only deny: $EGRESS_ONLY" >&2
echo "Total findings: ${#FINDINGS[@]}" >&2
echo "========================================" >&2

# Output JSON
FINDINGS_JSON=$(printf '%s\n' "${FINDINGS[@]}" | jq -s '.' 2>/dev/null || echo "[]")
cat << EOF
{
  "audit_type": "network-policy",
  "scope": "${NAMESPACE:-cluster-wide}",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "summary": {
    "total_namespaces": $TOTAL_NS,
    "covered_namespaces": $COVERED_NS,
    "coverage_percent": $COVERAGE_PCT,
    "no_policy": $NO_POLICY,
    "default_deny_all": $DENY_ALL,
    "ingress_only_deny": $INGRESS_ONLY,
    "egress_only_deny": $EGRESS_ONLY
  },
  "total_findings": ${#FINDINGS[@]},
  "findings": $FINDINGS_JSON
}
EOF

[ "$NO_POLICY" -gt 0 ] && exit 1
exit 0
