#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SESSION_FILE="$REPO_ROOT/working/SESSION.md"

usage() {
    echo "Usage: $0 [--json]"
    echo ""
    echo "Gathers comprehensive cluster information."
    echo "Updates SESSION.md with latest cluster details."
    echo ""
    echo "Options:"
    echo "  --json    Output JSON instead of markdown"
    exit 1
}

JSON_OUTPUT=false
if [[ "$1" == "--json" ]]; then
    JSON_OUTPUT=true
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

get_cluster_details() {
    local cli="$1"
    
    local platform="unknown"
    local cluster_version="unknown"
    local k8s_version="unknown"
    local api_server=""
    local etcd_version=""
    local controller_version=""
    local scheduler_version=""
    
    if [[ "$cli" == "oc" ]]; then
        platform="OpenShift"
        cluster_version=$(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo "unknown")
        api_server=$(oc get clusterversion -o jsonpath='{.items[0].status.versions[?(@.component == "kube-apiserver")].version}' 2>/dev/null || echo "unknown")
        etcd_version=$(oc get clusterversion -o jsonpath='{.items[0].status.versions[?(@.component == "etcd")].version}' 2>/dev/null || echo "unknown")
        controller_version=$(oc get clusterversion -o jsonpath='{.items[0].status.versions[?(@.component == "kube-controller-manager")].version}' 2>/dev/null || echo "unknown")
        scheduler_version=$(oc get clusterversion -o jsonpath='{.items[0].status.versions[?(@.component == "kube-scheduler")].version}' 2>/dev/null || echo "unknown")
        
        k8s_version=$(oc get clusterversion -o jsonpath='{.items[0].status.versions[?(@.component == "kubernetes")].version}' 2>/dev/null || echo "unknown")
        
    elif [[ "$cli" == "kubectl" ]]; then
        local context
        context=$(kubectl config current-context 2>/dev/null || echo "")
        
        if [[ "$context" == *"eks"* ]]; then
            platform="EKS"
            k8s_version=$(aws eks describe-cluster --name "$context" --query 'cluster.version' 2>/dev/null || echo "unknown")
        elif [[ "$context" == *"gke"* ]]; then
            platform="GKE"
        elif [[ "$context" == *"azmk8s"* ]]; then
            platform="AKS"
        elif [[ "$context" == *"rosa"* ]]; then
            platform="ROSA"
        elif [[ "$context" == *"aro"* ]]; then
            platform="ARO"
        else
            platform="Kubernetes"
        fi
        
        k8s_version=$(kubectl version -o json 2>/dev/null | jq -r '.serverVersion.gitVersion // "unknown"' 2>/dev/null || echo "unknown")
    fi
    
    echo "$platform|$cluster_version|$k8s_version|$api_server|$etcd_version|$controller_version|$scheduler_version"
}

get_operator_versions() {
    local cli="$1"
    local operators=""
    
    if [[ "$cli" == "oc" ]]; then
        local operator_namespaces=("openshift-operator-lifecycle-manager" "openshift-marketplace")
        
        for ns in "${operator_namespaces[@]}"; do
            if $cli get namespace "$ns" &> /dev/null; then
                local csvs
                csvs=$($cli get csv -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.version}{"\n"}{end}' 2>/dev/null || echo "")
                if [[ -n "$csvs" ]]; then
                    operators+="$csvs"$'\n'
                fi
            fi
        done
    fi
    
    echo "$operators"
}

get_component_info() {
    local cli="$1"
    local components=()
    
    local check_namespaces=("argocd" "openshift-gitops" "flux-system" "monitoring" "observability" "kube-system" "ingress-nginx" "nginx-ingress" "cert-manager" "vault" "istio-system" "service-mesh" "knative-serving" "tekton-pipelines")
    
    for ns in "${check_namespaces[@]}"; do
        if $cli get namespace "$ns" &> /dev/null 2>&1; then
            local deploy
            deploy=$($cli get deploy,statefulset -n "$ns" -o name 2>/dev/null || echo "")
            
            if [[ -n "$deploy" ]]; then
                local replicas
                replicas=$($cli get deploy,statefulset -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.spec.replicas}{"\n"}{end}' 2>/dev/null || echo "")
                
                local ready
                ready=$($cli get deploy,statefulset -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{":"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null || echo "")
                
                local version
                version=$($cli get deploy,statefulset -n "$ns" -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.version}{"\n"}{end}' 2>/dev/null || echo "")
                
                components+=("$ns|$deploy|$replicas|$ready")
            fi
        fi
    done
    
    for c in "${components[@]}"; do
        echo "$c"
    done
}

gather_and_update() {
    local cli
    cli=$(detect_cli)
    
    if [[ -z "$cli" ]]; then
        echo "Error: Neither kubectl nor oc found" >&2
        exit 1
    fi
    
    if ! $cli cluster-info &> /dev/null; then
        echo "Error: Cannot connect to cluster" >&2
        exit 1
    fi
    
    echo "Gathering cluster information using $cli..."
    
    local cluster_details
    cluster_details=$(get_cluster_details "$cli")
    local platform cluster_version k8s_version api_server etcd_version controller_version scheduler_version
    IFS='|' read -r platform cluster_version k8s_version api_server etcd_version controller_version scheduler_version <<< "$cluster_details"
    
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        local json_components="["
        local first=true
        
        while IFS='|' read -r ns deploy replicas ready; do
            [[ -z "$ns" ]] && continue
            if [[ "$first" == "true" ]]; then
                first=false
            else
                json_components+=","
            fi
            json_components+="{\"namespace\":\"$ns\",\"deployments\":\"$deploy\",\"replicas\":\"$replicas\",\"ready\":\"$ready\"}"
        done < <(get_component_info "$cli")
        
        json_components+="]"
        
        cat << EOF
{
  "timestamp": "$timestamp",
  "platform": "$platform",
  "cluster_version": "$cluster_version",
  "kubernetes_version": "$k8s_version",
  "components": $json_components
}
EOF
        return
    fi
    
    cat >> "$SESSION_FILE" << EOF

### Updated: $timestamp
| Component | Version |
|-----------|---------|
| Platform | $platform |
| Kubernetes API | $k8s_version |
| Cluster Version | ${cluster_version:-N/A} |
| API Server | ${api_server:-N/A} |
| etcd | ${etcd_version:-N/A} |
| Controller Manager | ${controller_version:-N/A} |
| Scheduler | ${scheduler_version:-N/A} |
EOF

    echo ""
    echo "========================================"
    echo "Cluster Information Gathered"
    echo "========================================"
    echo "Platform: $platform"
    echo "Cluster Version: $cluster_version"
    echo "Kubernetes: $k8s_version"
    echo "API Server: $api_server"
    echo "etcd: $etcd_version"
    echo ""
    echo "Session file updated: $SESSION_FILE"
}

main() {
    gather_and_update
}

main
