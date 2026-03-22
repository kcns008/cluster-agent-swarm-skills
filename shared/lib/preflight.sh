#!/bin/bash
# preflight.sh - Shared library for script preflight checks
# Source this file in other scripts: source "$(dirname "$0")/../../../shared/lib/preflight.sh"

set -e

# Detect available Kubernetes CLI (oc or kubectl)
detect_kube_cli() {
    if command -v oc &> /dev/null; then
        echo "oc"
    elif command -v kubectl &> /dev/null; then
        echo "kubectl"
    else
        echo "ERROR: Neither kubectl nor oc found" >&2
        echo "Install via your package manager:" >&2
        echo "  macOS: brew install kubectl  # or: brew install openshift-cli" >&2
        echo "  Ubuntu/Debian: sudo apt-get install kubectl" >&2
        echo "  RHEL/CentOS: sudo yum install kubectl" >&2
        exit 1
    fi
}

# Check if a binary exists, error if not
require_bin() {
    local bin="$1"
    if ! command -v "$bin" &> /dev/null; then
        echo "ERROR: Required binary not found: $bin" >&2
        echo "Install via your package manager:" >&2
        echo "  macOS: brew install $bin" >&2
        echo "  Ubuntu/Debian: sudo apt-get install $bin" >&2
        echo "  RHEL/CentOS: sudo yum install $bin" >&2
        echo "" >&2
        echo "See SECURITY.md for approved installation methods." >&2
        exit 1
    fi
}

# Check if a binary exists, warn but don't error
optional_bin() {
    local bin="$1"
    if ! command -v "$bin" &> /dev/null; then
        echo "WARNING: Optional binary not found: $bin" >&2
        return 1
    fi
    return 0
}

# Verify cluster access
ensure_cluster_access() {
    local cli="${1:-kubectl}"
    if ! $cli cluster-info &> /dev/null; then
        echo "ERROR: Cannot connect to cluster" >&2
        echo "Check your KUBECONFIG or run: $cli config current-context" >&2
        exit 1
    fi
}

# Block execution with error (for human approval required)
blocked_error() {
    local reason="$1"
    echo "BLOCKED: $reason" >&2
    echo "Human approval required. See AGENTS.md for approval process." >&2
    exit 2
}

# Log an action to stderr (JSON goes to stdout)
log_action() {
    local msg="$1"
    echo "$msg" >&2
}

# Output JSON result to stdout
output_json() {
    cat
}
