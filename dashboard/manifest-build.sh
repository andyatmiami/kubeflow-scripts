#! /usr/bin/env bash

set -euo pipefail

# Default values
manifests_path=""
image_name=""
tag=""
overlay=""
apply_flag=false

# Function to show usage
show_usage() {
    echo "Usage: $0 --manifests-path <path> --image-name <name> --tag <tag> --overlay <overlay> [--apply]"
    echo ""
    echo "Parameters:"
    echo "  --manifests-path    Path to the manifests directory"
    echo "  --image-name        Name of the image to use"
    echo "  --tag              Tag for the image"
    echo "  --overlay          Overlay to apply"
    echo "  --apply            Apply the generated manifests to the cluster (default: build only)"
    echo ""
    echo "Examples:"
    echo "  # Build and output YAML (default behavior):"
    echo "  $0 --manifests-path ./manifests --image-name my-image --tag v1.0.0 --overlay overlays/kubeflow"
    echo ""
    echo "  # Build and apply to cluster:"
    echo "  $0 --manifests-path ./manifests --image-name my-image --tag v1.0.0 --overlay overlays/kubeflow --apply"
    exit 1
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --manifests-path)
            manifests_path="$2"
            shift 2
            ;;
        --image-name)
            image_name="$2"
            shift 2
            ;;
        --tag)
            tag="$2"
            shift 2
            ;;
        --overlay)
            overlay="$2"
            shift 2
            ;;
        --apply)
            apply_flag=true
            shift
            ;;
        --help|-h)
            show_usage
            ;;
        *)
            echo "Unknown option: $1"
            show_usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$manifests_path" || -z "$image_name" || -z "$tag" || -z "$overlay" ]]; then
    echo "Error: All parameters are required"
    show_usage
fi

build_kustomize_overlay() {
    # Determine which directory to use
    if [ -d "${manifests_path}" ]; then
        cd "${manifests_path}" || return 1
    elif [ -d "config" ]; then
        cd "config" || return 1
        overlay="overlays/kubeflow"
    else
        echo "Error: No suitable manifests directory found."
        return 1
    fi

    # Set up image environment variables
    export CURRENT_IMAGE="${image_name}"
    export PR_IMAGE="${image_name}:${tag}"
    export CURRENT_IMAGE_ESCAPED
    export PR_IMAGE_ESCAPED
    CURRENT_IMAGE_ESCAPED=$(echo "$CURRENT_IMAGE" | sed 's|\.|\\.|g')
    PR_IMAGE_ESCAPED=$(echo "$PR_IMAGE" | sed 's|\.|\\.|g')

    # Iterate through overlays
    for overlay_path in "${overlay}" "overlays/kserve" "overlays/cert-manager"; do
        if [ -d "$overlay_path" ]; then
            kustomize_cmd="kustomize build \"$overlay_path\""

            if [ "$overlay_path" = "overlays/cert-manager" ]; then
                eval "$kustomize_cmd" \
                  | sed "s|${CURRENT_IMAGE_ESCAPED}:[a-zA-Z0-9_.-]*|${PR_IMAGE_ESCAPED}|g" \
                  | sed 's/$(podDefaultsServiceName)/poddefaults-webhook-service/g' \
                  | sed 's/$(podDefaultsNamespace)/kubeflow/g' \
                  | sed "s|\$(CD_NAMESPACE)|${CD_NAMESPACE:-kubeflow}|g" \
                  | sed "s|\$(CD_CLUSTER_DOMAIN)|${CD_CLUSTER_DOMAIN:-cluster.local}|g" \
                  | sed "s|CD_NAMESPACE_PLACEHOLDER|${CD_NAMESPACE_PLACEHOLDER:-kubeflow}|g" \
                  | sed "s|CD_CLUSTER_DOMAIN_PLACEHOLDER|${CD_CLUSTER_DOMAIN_PLACEHOLDER:-cluster.local}|g"
            else
                eval "$kustomize_cmd" \
                  | sed "s|${CURRENT_IMAGE_ESCAPED}:[a-zA-Z0-9_.-]*|${PR_IMAGE_ESCAPED}|g" \
                  | sed "s|\$(CD_NAMESPACE)|${CD_NAMESPACE:-kubeflow}|g" \
                  | sed "s|\$(CD_CLUSTER_DOMAIN)|${CD_CLUSTER_DOMAIN:-cluster.local}|g" \
                  | sed "s|CD_NAMESPACE_PLACEHOLDER|${CD_NAMESPACE_PLACEHOLDER:-kubeflow}|g" \
                  | sed "s|CD_CLUSTER_DOMAIN_PLACEHOLDER|${CD_CLUSTER_DOMAIN_PLACEHOLDER:-cluster.local}|g"
            fi

            return 0
        fi
    done

    echo "No overlays found to build."
    return 1
}

apply_kustomize_overlay() {
    # Build the kustomize overlay and pipe to kubectl apply
    build_kustomize_overlay | kubectl apply -f -
}

# Call appropriate function based on apply flag
if [ "$apply_flag" = true ]; then
    apply_kustomize_overlay
else
    build_kustomize_overlay
fi
