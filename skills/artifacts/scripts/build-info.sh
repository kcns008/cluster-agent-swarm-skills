#!/bin/bash
# build-info.sh - Collect and publish build metadata and provenance
# Usage: ./build-info.sh <app-name> <tag> <build-number> [--git-repo <url>]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

APP=${1:-""}
TAG=${2:-""}
BUILD_NUM=${3:-""}

if [ -z "$APP" ] || [ -z "$TAG" ]; then
    echo "Usage: $0 <app-name> <tag> [build-number] [--git-repo <url>]" >&2
    echo "" >&2
    echo "Collects build metadata and provenance information." >&2
    echo "Outputs JSON build info suitable for artifact management." >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 payment-service v3.2.0 42" >&2
    echo "  $0 payment-service v3.2.0 42 --git-repo https://github.com/org/repo" >&2
    exit 1
fi

shift 3 2>/dev/null || true

GIT_REPO=""
while [ $# -gt 0 ]; do
    case "$1" in
        --git-repo) GIT_REPO="$2"; shift 2 ;;
        *) shift ;;
    esac
done

echo "=== BUILD INFO ===" >&2
echo "Application: $APP" >&2
echo "Tag: $TAG" >&2
echo "Build: ${BUILD_NUM:-N/A}" >&2
echo "" >&2

# Gather git info from current directory
GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_AUTHOR=$(git log -1 --format='%an <%ae>' 2>/dev/null || echo "unknown")
GIT_MESSAGE=$(git log -1 --format='%s' 2>/dev/null || echo "unknown")
GIT_TIMESTAMP=$(git log -1 --format='%aI' 2>/dev/null || echo "unknown")
[ -z "$GIT_REPO" ] && GIT_REPO=$(git remote get-url origin 2>/dev/null || echo "unknown")

# Gather CI info from environment
CI_SYSTEM="unknown"
CI_JOB_URL=""
CI_PIPELINE_URL=""

if [ -n "$GITHUB_ACTIONS" ]; then
    CI_SYSTEM="github-actions"
    CI_JOB_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
    CI_PIPELINE_URL="$CI_JOB_URL"
elif [ -n "$GITLAB_CI" ]; then
    CI_SYSTEM="gitlab-ci"
    CI_JOB_URL="${CI_JOB_URL:-unknown}"
    CI_PIPELINE_URL="${CI_PIPELINE_URL:-unknown}"
elif [ -n "$JENKINS_URL" ]; then
    CI_SYSTEM="jenkins"
    CI_JOB_URL="${BUILD_URL:-unknown}"
    CI_PIPELINE_URL="${JOB_URL:-unknown}"
elif [ -n "$TEKTON_PIPELINE_RUN" ]; then
    CI_SYSTEM="tekton"
    CI_JOB_URL="$TEKTON_PIPELINE_RUN"
fi

# Gather image info
IMAGE_DIGEST="unknown"
IMAGE_SIZE="unknown"
if command -v crane &> /dev/null; then
    REGISTRIES=("${DEV_REGISTRY:-dev-registry.example.com}" "${STAGING_REGISTRY:-staging-registry.example.com}" "${PROD_REGISTRY:-prod-registry.example.com}")
    for REG in "${REGISTRIES[@]}"; do
        DIGEST=$(crane digest "${REG}/${APP}:${TAG}" 2>/dev/null || echo "")
        if [ -n "$DIGEST" ]; then
            IMAGE_DIGEST="$DIGEST"
            IMAGE_SIZE=$(crane manifest "${REG}/${APP}:${TAG}" 2>/dev/null | jq '[.layers[].size] | add' 2>/dev/null || echo "unknown")
            break
        fi
    done
fi

# Check for signature
SIGNED=false
if command -v cosign &> /dev/null; then
    for REG in "${REGISTRIES[@]}"; do
        cosign verify --key "${COSIGN_PUB_KEY:-cosign.pub}" "${REG}/${APP}:${TAG}" &>/dev/null && SIGNED=true && break
    done 2>/dev/null || true
fi

# Check for SBOM
HAS_SBOM=false
[ -f "sbom-${APP}-${TAG}.json" ] && HAS_SBOM=true

BUILD_TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "Git Commit: $GIT_COMMIT" >&2
echo "Git Branch: $GIT_BRANCH" >&2
echo "CI System: $CI_SYSTEM" >&2
echo "Image Digest: $IMAGE_DIGEST" >&2
echo "Signed: $SIGNED" >&2
echo "SBOM: $HAS_SBOM" >&2

# Output JSON
cat << EOF
{
  "build_info": {
    "application": "$APP",
    "tag": "$TAG",
    "build_number": "${BUILD_NUM:-null}",
    "timestamp": "$BUILD_TIMESTAMP"
  },
  "git": {
    "commit": "$GIT_COMMIT",
    "branch": "$GIT_BRANCH",
    "author": "$GIT_AUTHOR",
    "message": "$GIT_MESSAGE",
    "commit_timestamp": "$GIT_TIMESTAMP",
    "repository": "$GIT_REPO"
  },
  "ci": {
    "system": "$CI_SYSTEM",
    "job_url": "$CI_JOB_URL",
    "pipeline_url": "$CI_PIPELINE_URL"
  },
  "image": {
    "digest": "$IMAGE_DIGEST",
    "size_bytes": "$IMAGE_SIZE",
    "signed": $SIGNED,
    "has_sbom": $HAS_SBOM
  },
  "provenance": {
    "builder": "$CI_SYSTEM",
    "build_type": "container",
    "reproducible": false,
    "slsa_level": $([ "$SIGNED" == "true" ] && [ "$HAS_SBOM" == "true" ] && echo "2" || echo "1")
  }
}
EOF
