#!/bin/bash
# etcd-backup.sh - etcd snapshot backup and verification
# Usage: ./etcd-backup.sh [backup-directory]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

BACKUP_DIR=${1:-"/tmp/etcd-backup"}
TIMESTAMP=$(date -u +"%Y%m%d-%H%M%S")
BACKUP_FILE="etcd-snapshot-${TIMESTAMP}.db"

echo "=== ETCD BACKUP ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Backup directory: $BACKUP_DIR" >&2
echo "" >&2

mkdir -p "$BACKUP_DIR"

# Detect platform
PLATFORM="kubernetes"
if command -v oc &> /dev/null && oc whoami &> /dev/null 2>&1; then
    PLATFORM="openshift"
fi

echo "Platform: $PLATFORM" >&2

if [ "$PLATFORM" == "openshift" ]; then
    ensure_cluster_access "oc"

    echo "### OpenShift etcd Backup ###" >&2
    
    # Get a master node
    MASTER_NODE=$(oc get nodes -l node-role.kubernetes.io/master= --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    if [ -z "$MASTER_NODE" ]; then
        MASTER_NODE=$(oc get nodes -l node-role.kubernetes.io/control-plane= --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    fi
    
    if [ -z "$MASTER_NODE" ]; then
        echo "Error: No master/control-plane node found" >&2
        exit 1
    fi
    
    echo "Using master node: $MASTER_NODE" >&2
    
    # Check etcd health first
    echo -e "\n### etcd Health Check ###" >&2
    oc rsh -n openshift-etcd "etcd-${MASTER_NODE}" etcdctl endpoint health --cluster 2>&1 | tee /dev/stderr || true
    
    # Get etcd member list
    echo -e "\n### etcd Members ###" >&2
    oc rsh -n openshift-etcd "etcd-${MASTER_NODE}" etcdctl member list -w table 2>&1 | tee /dev/stderr || true
    
    # Take snapshot
    echo -e "\n### Taking Snapshot ###" >&2
    oc rsh -n openshift-etcd "etcd-${MASTER_NODE}" etcdctl snapshot save /tmp/etcd-snapshot.db 2>&1 | tee /dev/stderr
    
    # Copy snapshot locally
    oc cp "openshift-etcd/etcd-${MASTER_NODE}:/tmp/etcd-snapshot.db" "${BACKUP_DIR}/${BACKUP_FILE}" 2>&1 | tee /dev/stderr
    
    # Verify snapshot
    echo -e "\n### Verifying Snapshot ###" >&2
    if [ -f "${BACKUP_DIR}/${BACKUP_FILE}" ]; then
        BACKUP_SIZE=$(ls -la "${BACKUP_DIR}/${BACKUP_FILE}" | awk '{print $5}')
        echo "Backup file size: $BACKUP_SIZE bytes" >&2
        
        # Verify with etcdctl if available locally
        if command -v etcdctl &> /dev/null; then
            etcdctl snapshot status "${BACKUP_DIR}/${BACKUP_FILE}" -w table >&2
        fi
        BACKUP_STATUS="success"
    else
        echo "Error: Backup file not found" >&2
        BACKUP_STATUS="failed"
        BACKUP_SIZE=0
    fi
    
else
    require_bin kubectl
    ensure_cluster_access "kubectl"

    echo "### Kubernetes etcd Backup ###" >&2
    
    # Find etcd pod
    ETCD_POD=$(kubectl get pods -n kube-system -l component=etcd --no-headers 2>/dev/null | head -1 | awk '{print $1}')
    
    if [ -z "$ETCD_POD" ]; then
        echo "Error: etcd pod not found. etcd may be external or managed." >&2
        echo "For managed clusters (EKS, AKS, GKE), etcd backups are handled by the provider." >&2
        
        cat << EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "platform": "$PLATFORM",
  "status": "skipped",
  "reason": "etcd managed by cloud provider"
}
EOF
        exit 0
    fi
    
    echo "Using etcd pod: $ETCD_POD" >&2
    
    # Take snapshot
    echo -e "\n### Taking Snapshot ###" >&2
    kubectl exec -n kube-system "$ETCD_POD" -- etcdctl snapshot save /tmp/etcd-snapshot.db \
        --cacert /etc/kubernetes/pki/etcd/ca.crt \
        --cert /etc/kubernetes/pki/etcd/healthcheck-client.crt \
        --key /etc/kubernetes/pki/etcd/healthcheck-client.key 2>&1 | tee /dev/stderr
    
    # Copy snapshot locally
    kubectl cp "kube-system/${ETCD_POD}:/tmp/etcd-snapshot.db" "${BACKUP_DIR}/${BACKUP_FILE}" 2>&1 | tee /dev/stderr
    
    if [ -f "${BACKUP_DIR}/${BACKUP_FILE}" ]; then
        BACKUP_SIZE=$(ls -la "${BACKUP_DIR}/${BACKUP_FILE}" | awk '{print $5}')
        echo "Backup file size: $BACKUP_SIZE bytes" >&2
        BACKUP_STATUS="success"
    else
        echo "Error: Backup file not found" >&2
        BACKUP_STATUS="failed"
        BACKUP_SIZE=0
    fi
fi

echo "" >&2
echo "========================================" >&2
if [ "$BACKUP_STATUS" == "success" ]; then
    echo "✅ ETCD BACKUP COMPLETE" >&2
    echo "File: ${BACKUP_DIR}/${BACKUP_FILE}" >&2
else
    echo "❌ ETCD BACKUP FAILED" >&2
fi
echo "========================================" >&2

# Output JSON
cat << EOF
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "platform": "$PLATFORM",
  "status": "$BACKUP_STATUS",
  "backup_file": "${BACKUP_DIR}/${BACKUP_FILE}",
  "backup_size_bytes": ${BACKUP_SIZE:-0}
}
EOF
