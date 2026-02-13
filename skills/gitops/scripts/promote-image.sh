#!/bin/bash
# promote-image.sh - Promote image tag across environments via GitOps
# Usage: ./promote-image.sh <app-name> <image-tag> <target-env>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../../../shared/lib/preflight.sh"

require_bin jq

APP=${1:-""}
TAG=${2:-""}
ENV=${3:-""}

if [ -z "$APP" ] || [ -z "$TAG" ] || [ -z "$ENV" ]; then
    echo "Usage: $0 <app-name> <image-tag> <target-env>" >&2
    echo "" >&2
    echo "Promotes an image tag to a target environment by updating GitOps manifests." >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 payment-service v3.2.0 staging" >&2
    echo "  $0 payment-service v3.2.0 production" >&2
    echo "" >&2
    echo "Environments: dev, staging, production" >&2
    exit 1
fi

echo "=== IMAGE PROMOTION ===" >&2
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2
echo "Application: $APP" >&2
echo "Image Tag: $TAG" >&2
echo "Target Environment: $ENV" >&2
echo "" >&2

# Validate environment
case "$ENV" in
    dev|staging|production|prod) ;;
    *)
        echo "Error: Invalid environment '$ENV'. Use: dev, staging, production" >&2
        exit 1
        ;;
esac

# Normalize prod → production
[ "$ENV" == "prod" ] && ENV="production"

# Check if ArgoCD can tell us the current version
echo "### Current Deployment Info ###" >&2
ARGOCD_APP="${APP}-${ENV}"
if command -v argocd &> /dev/null; then
    CURRENT_IMAGES=$(argocd app get "$ARGOCD_APP" -o json 2>/dev/null | jq -r '.status.summary.images[]?' 2>/dev/null || echo "unknown")
    echo "Current images: $CURRENT_IMAGES" >&2
else
    echo "ArgoCD CLI not available, checking via kubectl..." >&2
    CLI=$(detect_kube_cli)
    ensure_cluster_access "$CLI"
    CURRENT_IMAGES=$($CLI get application "$ARGOCD_APP" -n argocd -o jsonpath='{.status.summary.images}' 2>/dev/null || echo "unknown")
    echo "Current images: $CURRENT_IMAGES" >&2
fi

# Strategy: Update the image tag in the GitOps repo
# This works with both Kustomize and Helm-based repos
echo -e "\n### Promotion Strategy ###" >&2

# Check for Kustomize overlays
KUSTOMIZE_PATH="overlays/${ENV}"
HELM_VALUES="values-${ENV}.yaml"

PROMOTION_METHOD="unknown"

if [ -d "$KUSTOMIZE_PATH" ]; then
    echo "Detected Kustomize overlay at $KUSTOMIZE_PATH" >&2
    PROMOTION_METHOD="kustomize"
    
    # Update kustomization.yaml with new image tag
    cd "$KUSTOMIZE_PATH"
    kustomize edit set image "${APP}=*:${TAG}" 2>/dev/null || \
        echo "Note: Run 'kustomize edit set image ${APP}=REGISTRY/${APP}:${TAG}' in $KUSTOMIZE_PATH" >&2
    cd - > /dev/null
    
elif [ -f "$HELM_VALUES" ]; then
    echo "Detected Helm values at $HELM_VALUES" >&2
    PROMOTION_METHOD="helm"
    
    # Update image tag in values file
    if command -v yq &> /dev/null; then
        yq -i ".image.tag = \"${TAG}\"" "$HELM_VALUES"
        echo "Updated image.tag to $TAG in $HELM_VALUES" >&2
    else
        echo "Note: Manually update image.tag to '$TAG' in $HELM_VALUES" >&2
        echo "Or install yq for automatic updates." >&2
    fi
    
else
    echo "No Kustomize overlay or Helm values file found locally." >&2
    echo "Provide the update method for your GitOps repository:" >&2
    echo "" >&2
    echo "  Kustomize: cd overlays/${ENV} && kustomize edit set image ${APP}=REGISTRY/${APP}:${TAG}" >&2
    echo "  Helm: Update image.tag in values-${ENV}.yaml to ${TAG}" >&2
    echo "  ArgoCD: argocd app set ${ARGOCD_APP} --helm-set image.tag=${TAG}" >&2
    PROMOTION_METHOD="manual"
fi

# If ArgoCD is available, we can also set the parameter directly
if command -v argocd &> /dev/null && [ "$PROMOTION_METHOD" == "manual" ]; then
    echo -e "\n### Direct ArgoCD Parameter Update ###" >&2
    echo "Setting image.tag=$TAG on ArgoCD application $ARGOCD_APP..." >&2
    argocd app set "$ARGOCD_APP" --helm-set "image.tag=${TAG}" 2>/dev/null && \
        PROMOTION_METHOD="argocd-param" || \
        echo "Could not set ArgoCD parameter directly" >&2
fi

echo "" >&2
echo "========================================" >&2
echo "IMAGE PROMOTION INITIATED" >&2
echo "========================================" >&2
echo "Method: $PROMOTION_METHOD" >&2
echo "Next: ArgoCD will detect the change and sync automatically (if auto-sync enabled)" >&2
echo "Or run: argocd app sync ${ARGOCD_APP}" >&2

# Output JSON
cat << EOF
{
  "application": "$APP",
  "image_tag": "$TAG",
  "target_environment": "$ENV",
  "promotion_method": "$PROMOTION_METHOD",
  "argocd_app": "$ARGOCD_APP",
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "previous_images": "$CURRENT_IMAGES"
}
EOF
