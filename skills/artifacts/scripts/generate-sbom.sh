#!/bin/bash
# generate-sbom.sh - Generate Software Bill of Materials for a container image
# Usage: ./generate-sbom.sh <image:tag> [--format spdx-json|cyclonedx-json] [--output-dir .]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

IMAGE=${1:-""}
FORMAT="spdx-json"
OUTPUT_DIR="."

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image:tag> [--format spdx-json|cyclonedx-json] [--output-dir <path>]" >&2
    echo "" >&2
    echo "Generates an SBOM for a container image using Syft." >&2
    echo "" >&2
    echo "Formats: spdx-json (default), cyclonedx-json, syft-json, table" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 nginx:1.25" >&2
    echo "  $0 myregistry.com/app:v1.0 --format cyclonedx-json" >&2
    exit 1
fi

shift
while [ $# -gt 0 ]; do
    case "$1" in
        --format) FORMAT="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

APP=$(echo "$IMAGE" | sed 's|.*/||' | cut -d: -f1)
TAG=$(echo "$IMAGE" | cut -d: -f2)
[ "$TAG" == "$IMAGE" ] && TAG="latest"
SAFE_NAME=$(echo "${APP}-${TAG}" | tr '/:' '-')

echo "=== SBOM GENERATION ===" >&2
echo "Image: $IMAGE" >&2
echo "Format: $FORMAT" >&2
echo "" >&2

mkdir -p "$OUTPUT_DIR"

if ! command -v syft &> /dev/null; then
    echo "Install: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin" >&2
    blocked_error "syft not found."
fi

OUTPUT_FILE="${OUTPUT_DIR}/sbom-${SAFE_NAME}.json"
[ "$FORMAT" == "table" ] && OUTPUT_FILE="${OUTPUT_DIR}/sbom-${SAFE_NAME}.txt"

echo "Generating SBOM..." >&2
syft "$IMAGE" -o "$FORMAT" > "$OUTPUT_FILE" 2>/dev/null

# Parse results
PACKAGE_COUNT=0
if [ "$FORMAT" == "spdx-json" ]; then
    PACKAGE_COUNT=$(jq '.packages | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
    LICENSES=$(jq -r '[.packages[].licenseDeclared // "NOASSERTION"] | map(select(. != "NOASSERTION")) | sort | unique | join(", ")' "$OUTPUT_FILE" 2>/dev/null || echo "unknown")
elif [ "$FORMAT" == "cyclonedx-json" ]; then
    PACKAGE_COUNT=$(jq '.components | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
    LICENSES=$(jq -r '[.components[].licenses[]?.license?.id? // empty] | unique | join(", ")' "$OUTPUT_FILE" 2>/dev/null || echo "unknown")
elif [ "$FORMAT" == "syft-json" ]; then
    PACKAGE_COUNT=$(jq '.artifacts | length' "$OUTPUT_FILE" 2>/dev/null || echo 0)
    LICENSES="see file"
fi

FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')

echo "✅ SBOM generated: $OUTPUT_FILE" >&2
echo "  Packages: $PACKAGE_COUNT" >&2
echo "  Licenses: $LICENSES" >&2
echo "  File size: $FILE_SIZE bytes" >&2

# Optionally attach to image via Cosign
if command -v cosign &> /dev/null && [ "$FORMAT" != "table" ]; then
    echo "" >&2
    echo "  To attach SBOM to image:" >&2
    echo "  cosign attach sbom --sbom $OUTPUT_FILE $IMAGE" >&2
fi

cat << EOF
{
  "operation": "generate-sbom",
  "image": "$IMAGE",
  "format": "$FORMAT",
  "output_file": "$OUTPUT_FILE",
  "package_count": $PACKAGE_COUNT,
  "file_size_bytes": $FILE_SIZE,
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF
