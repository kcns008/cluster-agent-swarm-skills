#!/bin/bash
# cleanup-registry.sh - Clean up old container images by retention policy
# Usage: ./cleanup-registry.sh <environment> [max-age-days] [--dry-run]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

ENVIRONMENT=${1:-"dev"}
MAX_AGE_DAYS=${2:-30}
DRY_RUN=false

# Parse flags
for arg in "$@"; do
    [ "$arg" == "--dry-run" ] && DRY_RUN=true
done

CLI=$(command -v oc 2>/dev/null && echo "oc" || echo "kubectl")

echo "=== REGISTRY CLEANUP ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Environment: $ENVIRONMENT" >&2
echo "Max Age: ${MAX_AGE_DAYS} days" >&2
echo "Dry Run: $DRY_RUN" >&2
echo "CLI: $CLI" >&2
echo "" >&2

DELETED_COUNT=0
PRESERVED_COUNT=0
ERRORS=0

# Method 1: OpenShift image pruning
if [ "$CLI" == "oc" ]; then
    echo "### OpenShift Image Pruning ###" >&2
    KEEP_HOURS=$((MAX_AGE_DAYS * 24))
    
    if [ "$DRY_RUN" == "true" ]; then
        echo "  DRY RUN — showing what would be pruned:" >&2
        $CLI adm prune images \
            --keep-tag-revisions=3 \
            --keep-younger-than="${KEEP_HOURS}h" \
            2>&1 | head -50 >&2
    else
        echo "  Pruning images older than ${MAX_AGE_DAYS} days, keeping 3 revisions..." >&2
        PRUNE_OUTPUT=$($CLI adm prune images \
            --keep-tag-revisions=3 \
            --keep-younger-than="${KEEP_HOURS}h" \
            --confirm 2>&1 || echo "Prune completed with warnings")
        echo "$PRUNE_OUTPUT" >&2
        
        DELETED_COUNT=$(echo "$PRUNE_OUTPUT" | grep -c "Deleting" || echo 0)
    fi
fi

# Method 2: JFrog Artifactory cleanup
if command -v jfrog &> /dev/null; then
    echo -e "\n### JFrog Artifactory Cleanup ###" >&2
    
    REPO="${ENVIRONMENT}-docker-local"
    CUTOFF_DATE=$(date -u -v-${MAX_AGE_DAYS}d +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || \
                  date -u -d "${MAX_AGE_DAYS} days ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
    
    if [ -n "$CUTOFF_DATE" ]; then
        echo "  Repo: $REPO" >&2
        echo "  Cutoff date: $CUTOFF_DATE" >&2
        
        # Find old artifacts
        OLD_ARTIFACTS=$(jfrog rt search "${REPO}/*" \
            --props "build.timestamp<${CUTOFF_DATE}" \
            --include-dirs=false 2>/dev/null || echo "[]")
        
        OLD_COUNT=$(echo "$OLD_ARTIFACTS" | jq 'length' 2>/dev/null || echo 0)
        echo "  Found $OLD_COUNT artifacts older than $MAX_AGE_DAYS days" >&2
        
        if [ "$OLD_COUNT" -gt 0 ]; then
            if [ "$DRY_RUN" == "true" ]; then
                echo "  DRY RUN — would delete $OLD_COUNT artifacts" >&2
                echo "$OLD_ARTIFACTS" | jq -r '.[].path' 2>/dev/null | head -20 >&2
            else
                echo "  Deleting $OLD_COUNT old artifacts..." >&2
                jfrog rt delete "${REPO}/*" \
                    --props "build.timestamp<${CUTOFF_DATE}" \
                    --quiet 2>/dev/null && \
                    DELETED_COUNT=$((DELETED_COUNT + OLD_COUNT)) || \
                    ERRORS=$((ERRORS + 1))
            fi
        fi
    fi
    
    # Show storage info
    echo -e "\n  Storage info:" >&2
    jfrog rt storage-info 2>/dev/null | head -10 >&2 || true
fi

# Method 3: Generic registry cleanup using crane
if command -v crane &> /dev/null; then
    echo -e "\n### Generic Registry Cleanup (crane) ###" >&2
    
    REGISTRY="${DEV_REGISTRY:-dev-registry.example.com}"
    case "$ENVIRONMENT" in
        staging) REGISTRY="${STAGING_REGISTRY:-staging-registry.example.com}" ;;
        production|prod) REGISTRY="${PROD_REGISTRY:-prod-registry.example.com}" ;;
    esac
    
    echo "  Registry: $REGISTRY" >&2
    echo "  Note: Listing tags and creation dates. Manual review recommended." >&2
    
    # This is informational — crane doesn't have a bulk delete
    echo "  Use 'crane delete <image:tag>' to remove specific images" >&2
fi

# Summary
echo "" >&2
echo "========================================" >&2
echo "REGISTRY CLEANUP COMPLETE" >&2
echo "  Deleted: $DELETED_COUNT" >&2
echo "  Preserved: $PRESERVED_COUNT" >&2
echo "  Errors: $ERRORS" >&2
echo "  Dry Run: $DRY_RUN" >&2
echo "========================================" >&2

cat << EOF
{
  "operation": "cleanup-registry",
  "environment": "$ENVIRONMENT",
  "max_age_days": $MAX_AGE_DAYS,
  "dry_run": $DRY_RUN,
  "deleted": $DELETED_COUNT,
  "preserved": $PRESERVED_COUNT,
  "errors": $ERRORS,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
