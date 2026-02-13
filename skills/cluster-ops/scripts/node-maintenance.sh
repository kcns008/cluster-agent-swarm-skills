#!/bin/bash
# node-maintenance.sh - Safely drain and prepare node for maintenance
# Usage: ./node-maintenance.sh <node-name> [--force]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

NODE=${1:-""}
FORCE=${2:-""}

CLI=$(detect_kube_cli)
ensure_cluster_access "$CLI"

if [ -z "$NODE" ]; then
    echo "Usage: $0 <node-name> [--force]" >&2
    echo "" >&2
    echo "Available nodes:" >&2
    $CLI get nodes --no-headers | awk '{print "  " $1 " (" $2 ")"}'
    exit 1
fi

echo "=== NODE MAINTENANCE: $NODE ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "" >&2

# Verify node exists
if ! $CLI get node "$NODE" &>/dev/null; then
    echo "Error: Node '$NODE' not found" >&2
    exit 1
fi

# Show current status
echo "### Current Node Status ###" >&2
$CLI get node "$NODE" -o wide >&2

# Show pods on node
echo -e "\n### Pods on Node ###" >&2
POD_COUNT=$($CLI get pods -A --field-selector spec.nodeName="$NODE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Total pods: $POD_COUNT" >&2
$CLI get pods -A --field-selector spec.nodeName="$NODE" --no-headers | head -20 >&2
if [ "$POD_COUNT" -gt 20 ]; then
    echo "... and $((POD_COUNT - 20)) more" >&2
fi

# Check for PDBs that might block drain
echo -e "\n### PodDisruptionBudgets ###" >&2
PDB_COUNT=$($CLI get pdb -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Active PDBs: $PDB_COUNT" >&2
if [ "$PDB_COUNT" -gt 0 ]; then
    $CLI get pdb -A >&2
fi

# Step 1: Cordon
echo -e "\n### Step 1: Cordon Node ###" >&2
$CLI cordon "$NODE" >&2
echo "✓ Node cordoned (no new pods will be scheduled)" >&2

# Step 2: Drain
echo -e "\n### Step 2: Drain Node ###" >&2
DRAIN_OPTS="--ignore-daemonsets --delete-emptydir-data --grace-period=120 --timeout=600s"
if [ "$FORCE" == "--force" ]; then
    DRAIN_OPTS="$DRAIN_OPTS --force"
    echo "Force mode enabled" >&2
fi

if $CLI drain "$NODE" $DRAIN_OPTS 2>&1 | tee /dev/stderr; then
    echo "✓ Node drained successfully" >&2
    DRAIN_STATUS="success"
else
    echo "Warning: Drain completed with some issues" >&2
    DRAIN_STATUS="partial"
fi

# Step 3: Verify no pods remain (except daemonsets)
echo -e "\n### Step 3: Verification ###" >&2
REMAINING=$($CLI get pods -A --field-selector spec.nodeName="$NODE" --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Remaining pods on node: $REMAINING (should be daemonsets only)" >&2
$CLI get pods -A --field-selector spec.nodeName="$NODE" >&2

echo "" >&2
echo "========================================" >&2
echo "NODE MAINTENANCE READY" >&2
echo "========================================" >&2
echo "Node '$NODE' is now cordoned and drained." >&2
echo "" >&2
echo "Perform your maintenance tasks, then run:" >&2
echo "  $CLI uncordon $NODE" >&2
echo "" >&2

# Output JSON
cat << EOF
{
  "node": "$NODE",
  "action": "drain",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "drain_status": "$DRAIN_STATUS",
  "pods_before_drain": $POD_COUNT,
  "pods_remaining": $REMAINING,
  "pdb_count": $PDB_COUNT,
    "next_step": "$CLI uncordon $NODE"
}
EOF
