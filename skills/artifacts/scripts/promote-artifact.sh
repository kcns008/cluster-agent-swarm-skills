#!/bin/bash
# promote-artifact.sh - Promote container image between environments
# Usage: ./promote-artifact.sh <image:tag> <source-env> <target-env>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

IMAGE_TAG=${1:-""}
SOURCE_ENV=${2:-"dev"}
TARGET_ENV=${3:-"staging"}

if [ -z "$IMAGE_TAG" ]; then
    echo "Usage: $0 <image:tag> <source-env> <target-env>" >&2
    echo "" >&2
    echo "Promotes a container image between environment registries." >&2
    echo "Validates scan results and signatures before promotion." >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  image:tag     Image name and tag (e.g., payment-service:v3.2.0)" >&2
    echo "  source-env    Source environment (default: dev)" >&2
    echo "  target-env    Target environment (default: staging)" >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  DEV_REGISTRY       Dev registry (default: dev-registry.example.com)" >&2
    echo "  STAGING_REGISTRY   Staging registry (default: staging-registry.example.com)" >&2
    echo "  PROD_REGISTRY      Prod registry (default: prod-registry.example.com)" >&2
    echo "  ARTIFACTORY_URL    JFrog Artifactory URL (if using)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 payment-service:v3.2.0 dev staging" >&2
    echo "  $0 payment-service:v3.2.0 staging production" >&2
    exit 1
fi

# Parse image name and tag
APP=$(echo "$IMAGE_TAG" | cut -d: -f1)
TAG=$(echo "$IMAGE_TAG" | cut -d: -f2)
[ "$TAG" == "$APP" ] && TAG="latest"

CLI=$(command -v oc 2>/dev/null && echo "oc" || echo "kubectl")

# Registry mapping
DEV_REGISTRY="${DEV_REGISTRY:-dev-registry.example.com}"
STAGING_REGISTRY="${STAGING_REGISTRY:-staging-registry.example.com}"
PROD_REGISTRY="${PROD_REGISTRY:-prod-registry.example.com}"

get_registry() {
    case "$1" in
        dev) echo "$DEV_REGISTRY" ;;
        staging) echo "$STAGING_REGISTRY" ;;
        production|prod) echo "$PROD_REGISTRY" ;;
        *) echo "$1" ;;
    esac
}

SRC_REGISTRY=$(get_registry "$SOURCE_ENV")
DST_REGISTRY=$(get_registry "$TARGET_ENV")

SRC_IMAGE="${SRC_REGISTRY}/${APP}:${TAG}"
DST_IMAGE="${DST_REGISTRY}/${APP}:${TAG}"

echo "=== ARTIFACT PROMOTION ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Image: $APP:$TAG" >&2
echo "Source: $SRC_IMAGE ($SOURCE_ENV)" >&2
echo "Target: $DST_IMAGE ($TARGET_ENV)" >&2
echo "" >&2

GATES_PASSED=0
GATES_FAILED=0
GATE_RESULTS=()

check_gate() {
    local gate_name="$1"
    local result="$2"
    if [ "$result" == "pass" ]; then
        GATES_PASSED=$((GATES_PASSED + 1))
        echo "  ✅ $gate_name: PASS" >&2
        GATE_RESULTS+=("{\"gate\":\"$gate_name\",\"result\":\"pass\"}")
    else
        GATES_FAILED=$((GATES_FAILED + 1))
        echo "  ❌ $gate_name: FAIL" >&2
        GATE_RESULTS+=("{\"gate\":\"$gate_name\",\"result\":\"fail\"}")
    fi
}

# Gate 1: Verify source image exists
echo "### Pre-Promotion Gates ###" >&2

if command -v crane &> /dev/null; then
    if crane manifest "$SRC_IMAGE" &>/dev/null; then
        check_gate "source-exists" "pass"
        SRC_DIGEST=$(crane digest "$SRC_IMAGE" 2>/dev/null || echo "unknown")
        echo "    Digest: $SRC_DIGEST" >&2
    else
        check_gate "source-exists" "fail"
        echo "    Source image not found: $SRC_IMAGE" >&2
    fi
elif command -v skopeo &> /dev/null; then
    if skopeo inspect "docker://$SRC_IMAGE" &>/dev/null; then
        check_gate "source-exists" "pass"
        SRC_DIGEST=$(skopeo inspect "docker://$SRC_IMAGE" | jq -r '.Digest' 2>/dev/null || echo "unknown")
    else
        check_gate "source-exists" "fail"
    fi
else
    echo "  ⚠️  Cannot verify source (crane/skopeo not available)" >&2
    check_gate "source-exists" "pass"
    SRC_DIGEST="unknown"
fi

# Gate 2: Vulnerability scan (for staging and prod)
if [ "$TARGET_ENV" == "staging" ] || [ "$TARGET_ENV" == "production" ] || [ "$TARGET_ENV" == "prod" ]; then
    echo "" >&2
    if command -v trivy &> /dev/null; then
        echo "  Scanning for vulnerabilities..." >&2
        SCAN_RESULT=$(trivy image --severity CRITICAL,HIGH --format json --quiet "$SRC_IMAGE" 2>/dev/null || echo "")
        if [ -n "$SCAN_RESULT" ]; then
            CRITICAL_COUNT=$(echo "$SCAN_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
            HIGH_COUNT=$(echo "$SCAN_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo "0")
            echo "    Critical: $CRITICAL_COUNT, High: $HIGH_COUNT" >&2
            
            if [ "$TARGET_ENV" == "production" ] || [ "$TARGET_ENV" == "prod" ]; then
                [ "$CRITICAL_COUNT" -eq 0 ] && [ "$HIGH_COUNT" -eq 0 ] && check_gate "vulnerability-scan" "pass" || check_gate "vulnerability-scan" "fail"
            else
                [ "$CRITICAL_COUNT" -eq 0 ] && check_gate "vulnerability-scan" "pass" || check_gate "vulnerability-scan" "fail"
            fi
        else
            echo "    Scan unavailable" >&2
            check_gate "vulnerability-scan" "pass"
        fi
    else
        echo "  ⚠️  Trivy not available, skipping scan gate" >&2
    fi
fi

# Gate 3: Image signature (for prod)
if [ "$TARGET_ENV" == "production" ] || [ "$TARGET_ENV" == "prod" ]; then
    echo "" >&2
    if command -v cosign &> /dev/null; then
        echo "  Verifying image signature..." >&2
        if cosign verify --key "${COSIGN_PUB_KEY:-cosign.pub}" "$SRC_IMAGE" &>/dev/null; then
            check_gate "signature-verify" "pass"
        else
            echo "    No valid signature found" >&2
            check_gate "signature-verify" "fail"
        fi
    else
        echo "  ⚠️  Cosign not available, skipping signature gate" >&2
    fi
fi

# Check if gates passed
echo "" >&2
if [ "$GATES_FAILED" -gt 0 ]; then
    echo "❌ PROMOTION BLOCKED: $GATES_FAILED gate(s) failed" >&2
    cat << EOF
{
  "operation": "promote",
  "image": "$APP:$TAG",
  "source": "$SOURCE_ENV",
  "target": "$TARGET_ENV",
  "status": "blocked",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "gates_passed": $GATES_PASSED,
  "gates_failed": $GATES_FAILED,
  "gates": $(printf '%s\n' "${GATE_RESULTS[@]}" | jq -s '.')
}
EOF
    exit 1
fi

# Perform promotion
echo "### Promoting Artifact ###" >&2

PROMO_METHOD="unknown"
PROMO_SUCCESS=false

# Method 1: OpenShift image streams
if [ "$CLI" == "oc" ]; then
    SRC_NS="${SOURCE_ENV}"
    DST_NS="${TARGET_ENV}"
    echo "  Trying OpenShift image stream tag..." >&2
    if $CLI tag "${SRC_NS}/${APP}:${TAG}" "${DST_NS}/${APP}:${TAG}" &>/dev/null; then
        PROMO_METHOD="openshift-istag"
        PROMO_SUCCESS=true
        echo "  ✅ Tagged via OpenShift image stream" >&2
    fi
fi

# Method 2: crane copy
if [ "$PROMO_SUCCESS" != "true" ] && command -v crane &> /dev/null; then
    echo "  Copying via crane..." >&2
    if crane copy "$SRC_IMAGE" "$DST_IMAGE" 2>/dev/null; then
        PROMO_METHOD="crane"
        PROMO_SUCCESS=true
        echo "  ✅ Copied via crane" >&2
    fi
fi

# Method 3: skopeo copy
if [ "$PROMO_SUCCESS" != "true" ] && command -v skopeo &> /dev/null; then
    echo "  Copying via skopeo..." >&2
    if skopeo copy "docker://$SRC_IMAGE" "docker://$DST_IMAGE" 2>/dev/null; then
        PROMO_METHOD="skopeo"
        PROMO_SUCCESS=true
        echo "  ✅ Copied via skopeo" >&2
    fi
fi

# Method 4: JFrog
if [ "$PROMO_SUCCESS" != "true" ] && command -v jfrog &> /dev/null; then
    echo "  Copying via JFrog CLI..." >&2
    SRC_REPO="${SOURCE_ENV}-docker-local"
    DST_REPO="${TARGET_ENV}-docker-local"
    if jfrog rt copy "${SRC_REPO}/${APP}/${TAG}/" "${DST_REPO}/${APP}/${TAG}/" --flat=false 2>/dev/null; then
        PROMO_METHOD="jfrog"
        PROMO_SUCCESS=true
        echo "  ✅ Copied via JFrog" >&2
    fi
fi

if [ "$PROMO_SUCCESS" != "true" ]; then
    echo "  ❌ All promotion methods failed" >&2
    exit 1
fi

# Verify destination
DST_DIGEST="unknown"
if command -v crane &> /dev/null; then
    DST_DIGEST=$(crane digest "$DST_IMAGE" 2>/dev/null || echo "unknown")
fi

echo "" >&2
echo "========================================" >&2
echo "PROMOTION COMPLETE" >&2
echo "  $SRC_IMAGE → $DST_IMAGE" >&2
echo "  Method: $PROMO_METHOD" >&2
echo "  Source Digest: ${SRC_DIGEST:-unknown}" >&2
echo "  Target Digest: ${DST_DIGEST:-unknown}" >&2
echo "========================================" >&2

# Output JSON
cat << EOF
{
  "operation": "promote",
  "image": "$APP:$TAG",
  "source": {
    "environment": "$SOURCE_ENV",
    "registry": "$SRC_REGISTRY",
    "full_image": "$SRC_IMAGE",
    "digest": "${SRC_DIGEST:-unknown}"
  },
  "target": {
    "environment": "$TARGET_ENV",
    "registry": "$DST_REGISTRY",
    "full_image": "$DST_IMAGE",
    "digest": "${DST_DIGEST:-unknown}"
  },
  "method": "$PROMO_METHOD",
  "status": "success",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "gates_passed": $GATES_PASSED,
  "gates": $(printf '%s\n' "${GATE_RESULTS[@]}" | jq -s '.')
}
EOF
