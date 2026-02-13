#!/bin/bash
# scan-image.sh - Container image vulnerability scan (thin wrapper)
# Usage: ./scan-image.sh <image:tag> [--severity CRITICAL,HIGH] [--exit-code]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

IMAGE=${1:-""}
SEVERITY="CRITICAL,HIGH"
EXIT_CODE_FLAG=false

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image:tag> [--severity CRITICAL,HIGH] [--exit-code]" >&2
    echo "" >&2
    echo "Scans a container image for vulnerabilities." >&2
    echo "Uses Trivy (preferred) or Grype." >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --severity    Comma-separated severity filter (default: CRITICAL,HIGH)" >&2
    echo "  --exit-code   Exit with code 1 if vulnerabilities found" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 nginx:1.25" >&2
    echo "  $0 myregistry.com/app:v1.0 --severity CRITICAL --exit-code" >&2
    exit 1
fi

# Parse remaining args
shift
while [ $# -gt 0 ]; do
    case "$1" in
        --severity) SEVERITY="$2"; shift 2 ;;
        --exit-code) EXIT_CODE_FLAG=true; shift ;;
        *) shift ;;
    esac
done

echo "=== IMAGE SCAN ===" >&2
echo "Image: $IMAGE" >&2
echo "Severity: $SEVERITY" >&2
echo "" >&2

if command -v trivy &> /dev/null; then
    TOOL="trivy"
    TRIVY_ARGS="image --severity $SEVERITY"
    [ "$EXIT_CODE_FLAG" == "true" ] && TRIVY_ARGS="$TRIVY_ARGS --exit-code 1"
    
    # Table output to stderr, JSON to stdout
    trivy image --severity "$SEVERITY" "$IMAGE" >&2 2>&1 || true
    echo "" >&2
    
    JSON_RESULT=$(trivy image --severity "$SEVERITY" --format json --quiet "$IMAGE" 2>/dev/null || echo "{}")
    
    CRITICAL=$(echo "$JSON_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo 0)
    HIGH=$(echo "$JSON_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo 0)
    MEDIUM=$(echo "$JSON_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length' 2>/dev/null || echo 0)
    LOW=$(echo "$JSON_RESULT" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="LOW")] | length' 2>/dev/null || echo 0)
    TOTAL=$((CRITICAL + HIGH + MEDIUM + LOW))
    
elif command -v grype &> /dev/null; then
    TOOL="grype"
    grype "$IMAGE" --only-fixed >&2 2>&1 || true
    echo "" >&2
    
    JSON_RESULT=$(grype "$IMAGE" -o json 2>/dev/null || echo "{}")
    CRITICAL=$(echo "$JSON_RESULT" | jq '[.matches[]? | select(.vulnerability.severity=="Critical")] | length' 2>/dev/null || echo 0)
    HIGH=$(echo "$JSON_RESULT" | jq '[.matches[]? | select(.vulnerability.severity=="High")] | length' 2>/dev/null || echo 0)
    MEDIUM=$(echo "$JSON_RESULT" | jq '[.matches[]? | select(.vulnerability.severity=="Medium")] | length' 2>/dev/null || echo 0)
    LOW=$(echo "$JSON_RESULT" | jq '[.matches[]? | select(.vulnerability.severity=="Low")] | length' 2>/dev/null || echo 0)
    TOTAL=$((CRITICAL + HIGH + MEDIUM + LOW))
else
    blocked_error "Neither trivy nor grype found"
fi

PASS=$([ "$CRITICAL" -eq 0 ] && [ "$HIGH" -eq 0 ] && echo "true" || echo "false")

echo "========================================" >&2
echo "SCAN SUMMARY ($TOOL)" >&2
echo "  Critical: $CRITICAL" >&2
echo "  High:     $HIGH" >&2
echo "  Medium:   $MEDIUM" >&2
echo "  Low:      $LOW" >&2
echo "  Pass:     $PASS" >&2
echo "========================================" >&2

cat << EOF
{
  "tool": "$TOOL",
  "image": "$IMAGE",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "summary": {"critical": $CRITICAL, "high": $HIGH, "medium": $MEDIUM, "low": $LOW, "total": $TOTAL},
  "pass": $PASS
}
EOF

if [ "$EXIT_CODE_FLAG" == "true" ] && [ "$PASS" == "false" ]; then
    exit 1
fi
