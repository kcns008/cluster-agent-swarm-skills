#!/bin/bash
# image-scan.sh - Container image vulnerability scan using Trivy or Grype
# Usage: ./image-scan.sh <image> [--severity CRITICAL,HIGH] [--format table|json]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

IMAGE=${1:-""}
SEVERITY="CRITICAL,HIGH"
FORMAT="table"

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image> [severity] [format]" >&2
    echo "" >&2
    echo "Scans a container image for vulnerabilities using Trivy (preferred) or Grype." >&2
    echo "" >&2
    echo "Arguments:" >&2
    echo "  image      Full image reference (e.g., registry.example.com/app:v1.0)" >&2
    echo "  severity   Comma-separated severity filter (default: CRITICAL,HIGH)" >&2
    echo "  format     Output format: table, json, sarif (default: table)" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 nginx:1.25" >&2
    echo "  $0 registry.example.com/payment-service:v3.2 CRITICAL,HIGH,MEDIUM json" >&2
    exit 1
fi

require_bin jq

shift || true
POSITIONAL_INDEX=0
while [ $# -gt 0 ]; do
    case "$1" in
        --severity)
            [ -z "${2:-}" ] && { echo "ERROR: --severity requires a value" >&2; exit 1; }
            SEVERITY="$2"
            shift 2
            ;;
        --format)
            [ -z "${2:-}" ] && { echo "ERROR: --format requires a value" >&2; exit 1; }
            FORMAT="$2"
            shift 2
            ;;
        *)
            POSITIONAL_INDEX=$((POSITIONAL_INDEX + 1))
            if [ "$POSITIONAL_INDEX" -eq 1 ]; then
                SEVERITY="$1"
            elif [ "$POSITIONAL_INDEX" -eq 2 ]; then
                FORMAT="$1"
            else
                echo "ERROR: Unknown argument '$1'" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

case "$FORMAT" in
    table|json|sarif) ;;
    *)
        echo "ERROR: Unsupported format '$FORMAT'. Use: table, json, sarif" >&2
        exit 1
        ;;
esac

echo "=== IMAGE VULNERABILITY SCAN ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Image: $IMAGE" >&2
echo "Severity Filter: $SEVERITY" >&2
echo "Format: $FORMAT" >&2
echo "" >&2

SCAN_TOOL=""
SCAN_RESULT=""
EXIT_CODE=0

# Try Trivy first
if command -v trivy &> /dev/null; then
    SCAN_TOOL="trivy"
    echo "Using Trivy for scanning..." >&2
    
    case "$FORMAT" in
        json)
            SCAN_RESULT=$(trivy image \
                --severity "$SEVERITY" \
                --format json \
                --quiet \
                "$IMAGE" 2>/dev/null) || EXIT_CODE=$?
            ;;
        sarif)
            SCAN_RESULT=$(trivy image \
                --severity "$SEVERITY" \
                --format sarif \
                --quiet \
                "$IMAGE" 2>/dev/null) || EXIT_CODE=$?
            ;;
        *)
            trivy image \
                --severity "$SEVERITY" \
                "$IMAGE" >&2 || EXIT_CODE=$?
            
            # Also get JSON for structured output
            SCAN_RESULT=$(trivy image \
                --severity "$SEVERITY" \
                --format json \
                --quiet \
                "$IMAGE" 2>/dev/null) || true
            ;;
    esac

# Fall back to Grype
elif command -v grype &> /dev/null; then
    SCAN_TOOL="grype"
    echo "Using Grype for scanning..." >&2

    if [ "$FORMAT" == "sarif" ]; then
        echo "WARN: Grype does not support sarif output natively. Falling back to json." >&2
        FORMAT="json"
    fi
    
    case "$FORMAT" in
        json)
            SCAN_RESULT=$(grype "$IMAGE" \
                --only-fixed \
                -o json 2>/dev/null) || EXIT_CODE=$?
            ;;
        *)
            grype "$IMAGE" --only-fixed >&2 || EXIT_CODE=$?
            SCAN_RESULT=$(grype "$IMAGE" -o json 2>/dev/null) || true
            ;;
    esac
    
else
    echo "ERROR: Neither Trivy nor Grype found." >&2
    echo "Install Trivy: https://aquasecurity.github.io/trivy/latest/getting-started/installation/" >&2
    echo "Install Grype: https://github.com/anchore/grype#installation" >&2
    exit 2
fi

# Parse results
echo "" >&2
echo "========================================" >&2

if [ "$SCAN_TOOL" == "trivy" ] && [ -n "$SCAN_RESULT" ]; then
    CRITICAL_COUNT=$(echo "$SCAN_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' 2>/dev/null || echo "0")
    HIGH_COUNT=$(echo "$SCAN_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' 2>/dev/null || echo "0")
    MEDIUM_COUNT=$(echo "$SCAN_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length' 2>/dev/null || echo "0")
    LOW_COUNT=$(echo "$SCAN_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "LOW")] | length' 2>/dev/null || echo "0")
    TOTAL_VULNS=$(echo "$SCAN_RESULT" | jq '[.Results[]?.Vulnerabilities[]?] | length' 2>/dev/null || echo "0")
    
    echo "SCAN RESULTS ($SCAN_TOOL)" >&2
    echo "  Image: $IMAGE" >&2
    echo "  Critical: $CRITICAL_COUNT" >&2
    echo "  High:     $HIGH_COUNT" >&2
    echo "  Medium:   $MEDIUM_COUNT" >&2
    echo "  Low:      $LOW_COUNT" >&2
    echo "  Total:    $TOTAL_VULNS vulnerabilities" >&2
    
    # Output JSON
    cat << EOF
{
  "scan_tool": "$SCAN_TOOL",
  "image": "$IMAGE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "severity_filter": "$SEVERITY",
  "summary": {
    "critical": $CRITICAL_COUNT,
    "high": $HIGH_COUNT,
    "medium": $MEDIUM_COUNT,
    "low": $LOW_COUNT,
    "total": $TOTAL_VULNS
  },
  "pass": $([ "$CRITICAL_COUNT" -eq 0 ] && [ "$HIGH_COUNT" -eq 0 ] && echo "true" || echo "false")
}
EOF

elif [ "$FORMAT" == "json" ] && [ -n "$SCAN_RESULT" ]; then
    echo "$SCAN_RESULT"
else
    echo "SCAN COMPLETE ($SCAN_TOOL)" >&2
    cat << EOF
{
  "scan_tool": "$SCAN_TOOL",
  "image": "$IMAGE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "exit_code": $EXIT_CODE,
  "severity_filter": "$SEVERITY"
}
EOF
fi

echo "========================================" >&2

exit $EXIT_CODE
