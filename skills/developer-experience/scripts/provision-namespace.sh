#!/bin/bash
# provision-namespace.sh - Create namespace with full platform guardrails
# Usage: ./provision-namespace.sh <namespace> <environment> [options]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

NAMESPACE=${1:-""}
ENVIRONMENT=${2:-"dev"}
CPU_REQUEST="2"
CPU_LIMIT="4"
MEM_REQUEST="4Gi"
MEM_LIMIT="8Gi"
TEAM=""

if [ -z "$NAMESPACE" ]; then
    echo "Usage: $0 <namespace> <environment> [options]" >&2
    echo "" >&2
    echo "Creates a namespace with ResourceQuota, LimitRange, NetworkPolicy, and RBAC." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --cpu <N>       CPU limit (default: 4)" >&2
    echo "  --memory <N>Gi  Memory limit (default: 8Gi)" >&2
    echo "  --team <name>   Team name for labels and RBAC" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 payments-dev dev --cpu 4 --memory 16Gi --team payments" >&2
    echo "  $0 search-staging staging --team search" >&2
    exit 1
fi

shift 2 2>/dev/null || true
while [ $# -gt 0 ]; do
    case "$1" in
        --cpu) CPU_LIMIT="$2"; CPU_REQUEST=$(echo "$2 / 2" | bc 2>/dev/null || echo "2"); shift 2 ;;
        --memory) MEM_LIMIT="$2"; MEM_REQUEST=$(echo "${2%Gi}" | awk '{printf "%dGi", $1/2}' 2>/dev/null || echo "4Gi"); shift 2 ;;
        --team) TEAM="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$TEAM" ] && TEAM=$(echo "$NAMESPACE" | sed 's/-dev$//;s/-staging$//;s/-prod$//;s/-production$//')

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

echo "=== NAMESPACE PROVISIONING ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Namespace: $NAMESPACE" >&2
echo "Environment: $ENVIRONMENT" >&2
echo "Team: $TEAM" >&2
echo "CPU: $CPU_REQUEST (request) / $CPU_LIMIT (limit)" >&2
echo "Memory: $MEM_REQUEST (request) / $MEM_LIMIT (limit)" >&2
echo "CLI: $CLI" >&2
echo "" >&2

CREATED=()
ERRORS=()

# 1. Create Namespace
echo "### Step 1: Create Namespace ###" >&2
if [ "$CLI" == "oc" ]; then
    $CLI new-project "$NAMESPACE" \
        --display-name="${TEAM} ${ENVIRONMENT}" \
        --description="Managed by Desk agent for team ${TEAM}" 2>/dev/null || \
    $CLI create namespace "$NAMESPACE" 2>/dev/null || \
    echo "  Namespace may already exist" >&2
else
    $CLI create namespace "$NAMESPACE" 2>/dev/null || echo "  Namespace may already exist" >&2
fi

# Apply labels
$CLI label namespace "$NAMESPACE" \
    team="$TEAM" \
    environment="$ENVIRONMENT" \
    managed-by="desk-agent" \
    pod-security.kubernetes.io/enforce="restricted" \
    pod-security.kubernetes.io/warn="restricted" \
    --overwrite >&2 2>&1 && CREATED+=("namespace/$NAMESPACE") || ERRORS+=("namespace labeling")

echo "  ✅ Namespace created/updated" >&2

# 2. ResourceQuota
echo -e "\n### Step 2: ResourceQuota ###" >&2
cat << QUOTA | $CLI apply -f - >&2 2>&1 && CREATED+=("resourcequota") || ERRORS+=("resourcequota")
apiVersion: v1
kind: ResourceQuota
metadata:
  name: ${TEAM}-quota
  namespace: ${NAMESPACE}
spec:
  hard:
    requests.cpu: "${CPU_REQUEST}"
    requests.memory: "${MEM_REQUEST}"
    limits.cpu: "${CPU_LIMIT}"
    limits.memory: "${MEM_LIMIT}"
    persistentvolumeclaims: "10"
    pods: "50"
    services: "20"
    secrets: "50"
    configmaps: "50"
QUOTA
echo "  ✅ ResourceQuota applied" >&2

# 3. LimitRange
echo -e "\n### Step 3: LimitRange ###" >&2
cat << LIMITS | $CLI apply -f - >&2 2>&1 && CREATED+=("limitrange") || ERRORS+=("limitrange")
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: ${NAMESPACE}
spec:
  limits:
    - type: Container
      default:
        cpu: 200m
        memory: 256Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      max:
        cpu: "2"
        memory: 4Gi
      min:
        cpu: 50m
        memory: 64Mi
    - type: PersistentVolumeClaim
      max:
        storage: 50Gi
      min:
        storage: 1Gi
LIMITS
echo "  ✅ LimitRange applied" >&2

# 4. NetworkPolicy (default deny)
echo -e "\n### Step 4: NetworkPolicy (Default Deny) ###" >&2
cat << NETPOL | $CLI apply -f - >&2 2>&1 && CREATED+=("networkpolicy/default-deny") || ERRORS+=("networkpolicy-deny")
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
NETPOL

# Allow DNS egress
cat << DNS | $CLI apply -f - >&2 2>&1 && CREATED+=("networkpolicy/allow-dns") || ERRORS+=("networkpolicy-dns")
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to: []
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
DNS

# Allow intra-namespace traffic
cat << INTRA | $CLI apply -f - >&2 2>&1 && CREATED+=("networkpolicy/allow-same-namespace") || ERRORS+=("networkpolicy-intra")
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-namespace
  namespace: ${NAMESPACE}
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
INTRA
echo "  ✅ NetworkPolicies applied (default-deny + DNS + intra-namespace)" >&2

# 5. ServiceAccount
echo -e "\n### Step 5: ServiceAccount ###" >&2
cat << SA | $CLI apply -f - >&2 2>&1 && CREATED+=("serviceaccount") || ERRORS+=("serviceaccount")
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${TEAM}-sa
  namespace: ${NAMESPACE}
automountServiceAccountToken: false
SA
echo "  ✅ ServiceAccount created" >&2

# 6. RBAC
echo -e "\n### Step 6: RBAC ###" >&2
cat << RBAC | $CLI apply -f - >&2 2>&1 && CREATED+=("rolebinding") || ERRORS+=("rolebinding")
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${TEAM}-edit
  namespace: ${NAMESPACE}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${TEAM}-developers
RBAC
echo "  ✅ RBAC RoleBinding created (group: ${TEAM}-developers → edit)" >&2

# Summary
echo "" >&2
echo "========================================" >&2
echo "NAMESPACE PROVISIONING COMPLETE" >&2
echo "  Created: ${#CREATED[@]} resources" >&2
echo "  Errors: ${#ERRORS[@]}" >&2
echo "========================================" >&2

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "  Errors in: ${ERRORS[*]}" >&2
fi

echo "" >&2
echo "Next steps:" >&2
echo "  1. Add team members to group '${TEAM}-developers'" >&2
echo "  2. Create registry pull secret if needed:" >&2
echo "     kubectl create secret docker-registry regcred \\" >&2
echo "       --docker-server=REGISTRY --docker-username=USER --docker-password=PASS \\" >&2
echo "       -n ${NAMESPACE}" >&2
echo "  3. Deploy applications using GitOps (ArgoCD)" >&2

# Output JSON
cat << EOF
{
  "operation": "provision-namespace",
  "namespace": "$NAMESPACE",
  "environment": "$ENVIRONMENT",
  "team": "$TEAM",
  "resources_created": $(printf '%s\n' "${CREATED[@]}" | jq -R . | jq -s .),
  "errors": $(printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s .),
  "quotas": {
    "cpu_request": "$CPU_REQUEST",
    "cpu_limit": "$CPU_LIMIT",
    "memory_request": "$MEM_REQUEST",
    "memory_limit": "$MEM_LIMIT"
  },
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "success": $([ ${#ERRORS[@]} -eq 0 ] && echo "true" || echo "false")
}
EOF
