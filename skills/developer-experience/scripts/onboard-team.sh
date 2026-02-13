#!/bin/bash
# onboard-team.sh - Team onboarding automation
# Usage: ./onboard-team.sh <team-name> [options]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

TEAM=${1:-""}
MEMBERS=""
NAMESPACES=""

if [ -z "$TEAM" ]; then
    echo "Usage: $0 <team-name> [options]" >&2
    echo "" >&2
    echo "Automates team onboarding: namespaces, RBAC, documentation." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --members <email1,email2,...>     Team member emails" >&2
    echo "  --namespaces <ns1,ns2,...>        Namespaces to provision" >&2
    echo "" >&2
    echo "If no namespaces specified, creates: <team>-dev, <team>-staging" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 payments --members alice@example.com,bob@example.com" >&2
    echo "  $0 search --namespaces search-dev,search-staging,search-prod" >&2
    exit 1
fi

shift
while [ $# -gt 0 ]; do
    case "$1" in
        --members) MEMBERS="$2"; shift 2 ;;
        --namespaces) NAMESPACES="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[ -z "$NAMESPACES" ] && NAMESPACES="${TEAM}-dev,${TEAM}-staging"
IFS=',' read -ra NS_ARRAY <<< "$NAMESPACES"
IFS=',' read -ra MEMBER_ARRAY <<< "$MEMBERS"

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

echo "=== TEAM ONBOARDING ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Team: $TEAM" >&2
echo "Members: ${#MEMBER_ARRAY[@]}" >&2
echo "Namespaces: ${NS_ARRAY[*]}" >&2
echo "CLI: $CLI" >&2
echo "" >&2

RESULTS=()
ERRORS=()

# 1. Provision Namespaces
echo "### Step 1: Provision Namespaces ###" >&2
for NS in "${NS_ARRAY[@]}"; do
    # Determine environment from namespace name
    ENV="dev"
    echo "$NS" | grep -qi "staging" && ENV="staging"
    echo "$NS" | grep -qi "prod" && ENV="production"
    echo "$NS" | grep -qi "test" && ENV="test"
    
    echo "  Provisioning: $NS (env: $ENV)" >&2
    
    if [ -f "${SCRIPT_DIR}/provision-namespace.sh" ]; then
        bash "${SCRIPT_DIR}/provision-namespace.sh" "$NS" "$ENV" --team "$TEAM" >/dev/null 2>&1 && {
            RESULTS+=("namespace/$NS")
            echo "    ✅ Namespace $NS provisioned" >&2
        } || {
            ERRORS+=("namespace/$NS")
            echo "    ❌ Failed to provision $NS" >&2
        }
    else
        # Fallback: create manually
        $CLI create namespace "$NS" 2>/dev/null || true
        $CLI label namespace "$NS" team="$TEAM" environment="$ENV" managed-by="desk-agent" --overwrite 2>/dev/null
        RESULTS+=("namespace/$NS")
        echo "    ✅ Namespace $NS created (basic)" >&2
    fi
done

# 2. Create RBAC for Members
echo -e "\n### Step 2: RBAC for Team Members ###" >&2
for MEMBER in "${MEMBER_ARRAY[@]}"; do
    [ -z "$MEMBER" ] && continue
    for NS in "${NS_ARRAY[@]}"; do
        # Create RoleBinding for each member in each namespace
        BINDING_NAME="${TEAM}-$(echo "$MEMBER" | sed 's/@.*//;s/\./-/g')-edit"
        cat << RBAC | $CLI apply -f - >/dev/null 2>&1 && {
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${BINDING_NAME}
  namespace: ${NS}
  labels:
    team: ${TEAM}
    managed-by: desk-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: ${MEMBER}
RBAC
            RESULTS+=("rolebinding/${BINDING_NAME}@${NS}")
            echo "    ✅ $MEMBER → edit in $NS" >&2
        } || {
            ERRORS+=("rolebinding/${BINDING_NAME}@${NS}")
            echo "    ❌ Failed: $MEMBER in $NS" >&2
        }
    done
done

# 3. Create team group binding
echo -e "\n### Step 3: Team Group Binding ###" >&2
for NS in "${NS_ARRAY[@]}"; do
    cat << GROUP_RBAC | $CLI apply -f - >/dev/null 2>&1 && {
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${TEAM}-group-view
  namespace: ${NS}
  labels:
    team: ${TEAM}
    managed-by: desk-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: Group
    name: ${TEAM}
GROUP_RBAC
        echo "    ✅ Group ${TEAM} → view in $NS" >&2
    } || echo "    ⚠️  Group binding in $NS (may already exist)" >&2
done

# 4. Generate Onboarding Documentation
echo -e "\n### Step 4: Generate Onboarding Documentation ###" >&2
ONBOARDING_DOC=$(cat << ONBOARD_DOC
# 🚀 Welcome to the Platform — Team ${TEAM}

**Generated:** $(date -u +"%Y-%m-%d")
**Team:** ${TEAM}
**Namespaces:** $(IFS=', '; echo "${NS_ARRAY[*]}")

---

## 🔑 Getting Access

### 1. Install kubectl / oc

\`\`\`bash
# macOS
brew install kubectl  # or: brew install openshift-cli

# Linux
curl -LO "https://dl.k8s.io/release/\$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl && sudo mv kubectl /usr/local/bin/
\`\`\`

### 2. Configure Cluster Access

\`\`\`bash
# Get your kubeconfig from the platform team or SSO portal
export KUBECONFIG=~/.kube/config

# Verify access
kubectl get namespaces | grep ${TEAM}
kubectl auth can-i list pods -n ${NS_ARRAY[0]}
\`\`\`

---

## 📦 Your Namespaces

| Namespace | Environment | Purpose |
|-----------|-------------|---------|
$(for NS in "${NS_ARRAY[@]}"; do
    ENV="dev"; echo "$NS" | grep -qi "staging" && ENV="staging"; echo "$NS" | grep -qi "prod" && ENV="production"
    echo "| ${NS} | ${ENV} | ${ENV^} workloads |"
done)

---

## 🚢 Deploying Your First Application

### Step 1: Create Your Deployment

\`\`\`bash
# Quick deployment
kubectl create deployment myapp --image=YOUR_IMAGE -n ${NS_ARRAY[0]}

# Production-grade deployment (use our generator)
bash scripts/generate-manifest.sh myapp \\
  --image registry.example.com/myapp:latest \\
  --port 8080 \\
  --namespace ${NS_ARRAY[0]} \\
  --output-dir ./manifests

kubectl apply -f ./manifests/
\`\`\`

### Step 2: Expose Your Service

\`\`\`bash
kubectl expose deployment myapp --port=8080 -n ${NS_ARRAY[0]}
\`\`\`

### Step 3: Check Status

\`\`\`bash
kubectl get pods -n ${NS_ARRAY[0]}
kubectl get svc -n ${NS_ARRAY[0]}
kubectl logs -l app=myapp -n ${NS_ARRAY[0]} --tail=100
\`\`\`

---

## 🔍 Debugging Common Issues

| Symptom | Command | Common Fix |
|---------|---------|------------|
| CrashLoopBackOff | \`kubectl logs POD --previous\` | Check app errors, increase memory |
| OOMKilled | \`kubectl describe pod POD\` | Increase memory limit |
| ImagePullBackOff | \`kubectl describe pod POD\` | Check pull secret, image name |
| Pending | \`kubectl describe pod POD\` | Check resource quota, node capacity |

**Quick diagnosis tool:**
\`\`\`bash
bash scripts/debug-pod.sh ${NS_ARRAY[0]} [pod-name]
\`\`\`

---

## 📊 Monitoring

- **Grafana Dashboard:** https://grafana.example.com/d/${TEAM}
- **Prometheus Metrics:** Available via ServiceMonitor
- **Alerts:** Configured in your namespace

---

## 📚 Platform Resources

| Resource | URL |
|----------|-----|
| Platform Docs | https://docs.example.com/platform |
| ArgoCD Dashboard | https://argocd.example.com |
| Grafana | https://grafana.example.com |
| Artifactory | https://artifactory.example.com |
| Support Channel | #platform-support (Slack) |

---

## 🆘 Getting Help

1. **Self-service:** Check the platform docs first
2. **Ask Desk Agent:** \`@Desk how do I...?\`
3. **Slack:** #platform-support
4. **Emergency:** #platform-incidents (P1/P2 only)

---

*Generated by Desk Agent — Developer Experience Specialist*
ONBOARD_DOC
)

if [ -n "$OUTPUT_DIR" ]; then
    mkdir -p "$OUTPUT_DIR"
    echo "$ONBOARDING_DOC" > "${OUTPUT_DIR}/ONBOARDING-${TEAM}.md"
    echo "  ✅ Onboarding doc: ${OUTPUT_DIR}/ONBOARDING-${TEAM}.md" >&2
else
    echo "$ONBOARDING_DOC" > "/tmp/ONBOARDING-${TEAM}.md"
    echo "  ✅ Onboarding doc: /tmp/ONBOARDING-${TEAM}.md" >&2
fi

# Summary
echo "" >&2
echo "========================================" >&2
echo "TEAM ONBOARDING COMPLETE" >&2
echo "  Team: $TEAM" >&2
echo "  Members: ${#MEMBER_ARRAY[@]}" >&2
echo "  Namespaces: ${#NS_ARRAY[@]}" >&2
echo "  Resources: ${#RESULTS[@]} created" >&2
echo "  Errors: ${#ERRORS[@]}" >&2
echo "========================================" >&2

if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "  Failed: ${ERRORS[*]}" >&2
fi

# Output JSON
cat << EOF
{
  "operation": "team-onboarding",
  "team": "$TEAM",
  "members": $(echo "$MEMBERS" | tr ',' '\n' | jq -R . | jq -s .),
  "namespaces": $(printf '%s\n' "${NS_ARRAY[@]}" | jq -R . | jq -s .),
  "resources_created": $(printf '%s\n' "${RESULTS[@]}" | jq -R . | jq -s .),
  "errors": $(printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s .),
  "onboarding_doc": "/tmp/ONBOARDING-${TEAM}.md",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "success": $([ ${#ERRORS[@]} -eq 0 ] && echo "true" || echo "false")
}
EOF
