#!/bin/bash
# verify-binary.sh - Verify binary integrity with checksum
# Usage: ./verify-binary.sh <binary-path> <expected-sha256>

set -e

BINARY_PATH="$1"
EXPECTED_SHA256="$2"

usage() {
    echo "Usage: $0 <binary-path> <expected-sha256>"
    echo ""
    echo "Verifies a binary file against an expected SHA256 checksum."
    echo ""
    echo "Example:"
    echo "  $0 ./trivy a1b2c3d4e5f6..."
    exit 1
}

if [ -z "$BINARY_PATH" ] || [ -z "$EXPECTED_SHA256" ]; then
    usage
fi

if [ ! -f "$BINARY_PATH" ]; then
    echo "ERROR: Binary not found: $BINARY_PATH" >&2
    exit 1
fi

# Calculate actual checksum
if command -v sha256sum &> /dev/null; then
    ACTUAL_SHA256=$(sha256sum "$BINARY_PATH" | cut -d' ' -f1)
elif command -v shasum &> /dev/null; then
    ACTUAL_SHA256=$(shasum -a 256 "$BINARY_PATH" | cut -d' ' -f1)
else
    echo "ERROR: Neither sha256sum nor shasum found" >&2
    exit 1
fi

# Verify
if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
    echo "ERROR: Checksum verification failed!" >&2
    echo "  Expected: $EXPECTED_SHA256" >&2
    echo "  Actual:   $ACTUAL_SHA256" >&2
    exit 1
fi

echo "✅ Checksum verified: $BINARY_PATH"
exit 0
