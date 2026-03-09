#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SESSION_FILE="$REPO_ROOT/working/SESSION.md"

usage() {
    echo "Usage: $0 <environment> [context-name]"
    echo ""
    echo "Sets up cluster session context for the agent."
    echo ""
    echo "Arguments:"
    echo "  environment   dev | qa | staging | prod"
    echo "  context-name  Optional kubectl context name (uses current if not specified)"
    echo ""
    echo "Examples:"
    echo "  $0 prod              # Set up prod environment with current context"
    echo "  $0 dev my-cluster    # Set up dev environment with specific context"
    exit 1
}

if [[ $# -lt 1 ]]; then
    usage
fi

ENVIRONMENT="$1"
CONTEXT_NAME="${2:-}"

VALID_ENVS=("dev" "qa" "staging" "prod")
if [[ ! " ${VALID_ENVS[*]} " =~ " ${ENVIRONMENT} " ]]; then
    echo "Error: Invalid environment. Must be one of: ${VALID_ENVS[*]}" >&2
    exit 1
fi

detect_cli() {
    if command -v oc &> /dev/null; then
        echo "oc"
    elif command -v kubectl &> /dev/null; then
        echo "kubectl"
    else
        echo ""
    fi
}

get_cluster_version() {
    local cli="$1"
    local version_info="{}"
    
    if [[ "$cli" == "oc" ]]; then
        version_info=$(oc version --client 2>/dev/null | head -5 || echo "{}")
    elif [[ "$cli" == "kubectl" ]]; then
        version_info=$(kubectl version --client 2>/dev/null || echo "{}")
    fi
    
    echo "$version_info"
}

get_cluster_info() {
    local cli="$1"
    local context="$2"
    
    local cluster_version=""
    local kubernetes_version=""
    local platform=""
    
    if [[ "$cli" == "oc" ]]; then
        platform="OpenShift"
        cluster_version=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo "unknown")
        kubernetes_version=$(oc version -o json 2>/dev/null | jq -r '.kubernetes // "unknown"' || echo "unknown")
    elif [[ "$cli" == "kubectl" ]]; then
        platform="Kubernetes"
        kubernetes_version=$(kubectl version -o json 2>/dev/null | jq -r '.clientVersion.gitVersion // "unknown"' || echo "unknown")
        
        local context_cluster
        context_cluster=$(kubectl config view -o jsonpath="{.contexts[?(@.name == \"$context\"})].context.cluster}" 2>/dev/null || echo "")
        
        if [[ "$context_cluster" == *"eks"* ]] || [[ "$context_cluster" == *"amazonaws"* ]]; then
            platform="EKS"
        elif [[ "$context_cluster" == *"gke"* ]] || [[ "$context_cluster" == *"googlecontainers"* ]]; then
            platform="GKE"
        elif [[ "$context_cluster" == *"azmk8s"* ]] || [[ "$context_cluster" == *"azurek8s"* ]]; then
            platform="AKS"
        elif [[ "$context_cluster" == *"rosa"* ]]; then
            platform="ROSA"
        elif [[ "$context_cluster" == *"aro"* ]]; then
            platform="ARO"
        fi
    fi
    
    echo "$platform|$kubernetes_version|$cluster_version"
}

get_component_versions() {
    local cli="$1"
    local components=""
    
    local namespaces=("argocd" "flux-system" "openshift-gitops" "monitoring" "observability" "ingress-nginx" "nginx-ingress" "cert-manager" "vault" "istio-system" "service-mesh")
    
    for ns in "${namespaces[@]}"; do
        if $cli get namespace "$ns" &> /dev/null; then
            local deploy
            deploy=$($cli get deployments -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.spec.replicas}{"\n"}{end}' 2>/dev/null || echo "")
            
            if [[ -n "$deploy" ]]; then
                local operator_name="$ns"
                [[ "$ns" == "openshift-gitops" ]] && operator_name="ArgoCD"
                [[ "$ns" == "flux-system" ]] && operator_name="Flux"
                [[ "$ns" == "monitoring" ]] && operator_name="Prometheus"
                
                components+="$operator_name|$ns|installed|"
            fi
        fi
    done
    
    echo "$components"
}

setup_session() {
    local cli
    cli=$(detect_cli)
    
    if [[ -z "$cli" ]]; then
        echo "Error: Neither kubectl nor oc found" >&2
        exit 1
    fi
    
    echo "Detected CLI: $cli"
    
    if [[ -n "$CONTEXT_NAME" ]]; then
        kubectl config use-context "$CONTEXT_NAME" 2>/dev/null || {
            echo "Error: Context $CONTEXT_NAME not found" >&2
            exit 1
        }
    else
        CONTEXT_NAME=$(kubectl config current-context 2>/dev/null || echo "unknown")
    fi
    
    echo "Using context: $CONTEXT_NAME"
    
    if ! $cli cluster-info &> /dev/null; then
        echo "Error: Cannot connect to cluster" >&2
        exit 1
    fi
    
    echo "Connected to cluster"
    
    local cluster_info
    cluster_info=$(get_cluster_info "$cli" "$CONTEXT_NAME")
    local platform
    local k8s_version
    local cluster_version
    IFS='|' read -r platform k8s_version cluster_version <<< "$cluster_info"
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    cat > "$SESSION_FILE" << EOF
# Cluster Session Context

> This file tracks the current agent's working context including environment, cluster details, and permissions.

---

## Current Session

### Agent
- **Name**: 
- **Session Started**: $timestamp
- **Task**: 

### Environment Context
- **Environment**: $ENVIRONMENT
- **Cluster Name**: $CONTEXT_NAME
- **Cluster Type**: $platform
- **Cluster Version**: ${cluster_version:-N/A}
- **Kubernetes Version**: $k8s_version
- **Context Name**: $CONTEXT_NAME
- **Namespace**: 

### Cluster Information (Populated on First Run)

#### Cluster Details
| Component | Version |
|-----------|---------|
| Platform | $platform |
| Kubernetes API | $k8s_version |
| etcd | |
| Controller Manager | |
| Scheduler | |
| Kubelet | |
| Kube-proxy | |

#### Key Components
| Component | Version | Namespace | Status |
|-----------|---------|-----------|--------|
EOF

    local components
    components=$(get_component_versions "$cli")
    
    if [[ -n "$components" ]]; then
        while IFS='|' read -r comp ns status; do
            [[ -z "$comp" ]] && continue
            echo "| $comp | | $ns | $status |" >> "$SESSION_FILE"
        done <<< "$components"
    fi

    local permission_level="READ_ONLY"
    if [[ "$ENVIRONMENT" == "dev" ]]; then
        permission_level="DEV_SANDBOX"
    elif [[ "$ENVIRONMENT" == "qa" ]]; then
        permission_level="RESTRICTED"
    elif [[ "$ENVIRONMENT" == "staging" ]]; then
        permission_level="RESTRICTED"
    elif [[ "$ENVIRONMENT" == "prod" ]]; then
        permission_level="PROD_RESTRICTED"
    fi

    cat >> "$SESSION_FILE" << EOF

### Permission Context
- **Permission Level**: $permission_level
- **Can Delete**: NO
- **Can Modify Prod**: NO (requires human approval)
- **Can Create RBAC**: NO (requires human approval)
- **Requires Approval**: YES

### Change Constraints by Environment

| Environment | Delete | Modify Prod | RBAC | Scale | Secrets |
|-------------|-------|------------|------|-------|---------|
| **dev** | Approval | Approval | Approval | Auto | Approval |
| **qa** | Approval | Approval | Approval | Approval | Approval |
| **staging** | Approval | Approval | Approval | Approval | Approval |
| **prod** | NEVER | NEVER | NEVER | NEVER | NEVER |

---

## Session Activity Log

| Timestamp | Action | Details |
|-----------|--------|---------|
| $timestamp | Session started | Environment: $ENVIRONMENT, Platform: $platform |

---

*This file is updated at session start and whenever context changes.*
EOF

    echo ""
    echo "========================================"
    echo "Session Context Created"
    echo "========================================"
    echo "Environment: $ENVIRONMENT"
    echo "Platform: $platform"
    echo "Kubernetes: $k8s_version"
    echo "Cluster Version: ${cluster_version:-N/A}"
    echo "Context: $CONTEXT_NAME"
    echo "Permission Level: $permission_level"
    echo ""
    echo "Session file: $SESSION_FILE"
    echo ""
    
    case $ENVIRONMENT in
        prod)
            echo "⚠️  PROD ENVIRONMENT - All changes require human approval"
            echo "⚠️  NO deletions allowed without explicit approval"
            ;;
        staging|qa)
            echo "🔒 RESTRICTED ENVIRONMENT - Most changes require approval"
            ;;
        dev)
            echo "🛠️  DEV ENVIRONMENT - Some self-service actions allowed"
            ;;
    esac
}

main() {
    setup_session
}

main
