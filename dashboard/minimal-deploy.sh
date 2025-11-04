#!/bin/bash

set -euo pipefail

# Get script directory in a POSIX-compliant way
# This resolves symlinks and returns the absolute path
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
  echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
IMAGE_TAG="${IMAGE_TAG:-integration-test}"
KUBEFLOW_NAMESPACE="${KUBEFLOW_NAMESPACE:-kubeflow}"
TIMEOUT="${TIMEOUT:-300s}"

# Determine make command (prefer gmake, fall back to make)
if command -v gmake &> /dev/null; then
  MAKE="gmake"
elif command -v make &> /dev/null; then
  MAKE="make"
else
  log_error "Neither 'make' nor 'gmake' found. Please install one of them."
  exit 1
fi

# Global variables (set during setup)
BASE_DIR=""
OWNER=""
REPO=""
BRANCH=""

# Function to replace image tag for a specific image in manifests
# Usage: replace_image_tag <manifest_file> <image_name> [old_tag] [new_tag]
# Example: replace_image_tag manifests.yaml "ghcr.io/kubeflow/dashboard/profile-controller" "latest" "integration-test"
replace_image_tag() {
  local manifest_file="$1"
  local image_name="$2"
  local old_tag="${3:-latest}"
  local new_tag="${4:-${IMAGE_TAG}}"

  # Escape special characters for sed
  local escaped_image_name=$(echo "$image_name" | sed 's/[[\.*^$()+?{|]/\\&/g')

  if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS uses BSD sed - match the image name followed by :old_tag and replace with :new_tag
    sed -i '' "s|${escaped_image_name}:${old_tag}|${escaped_image_name}:${new_tag}|g" "$manifest_file"
  else
    # Linux uses GNU sed
    sed -i "s|${escaped_image_name}:${old_tag}|${escaped_image_name}:${new_tag}|g" "$manifest_file"
  fi
}

# Parse command line argument in format <owner>/<repo>/<branch> (defaults: kubeflow/dashboard/main)
# Examples:
#   kubeflow/dashboard/main  - explicit all
#   dashboard/main           - default owner (kubeflow)
#   main                     - default owner and repo (kubeflow/dashboard)
parse_input_ref() {
  local input_ref="${1:-main}"

  # Split input by '/' to parse components
  IFS='/' read -ra PARTS <<< "${input_ref}"
  local num_parts=${#PARTS[@]}

  if [ "${num_parts}" -eq 3 ]; then
    # Format: owner/repo/branch
    OWNER="${PARTS[0]}"
    REPO="${PARTS[1]}"
    BRANCH="${PARTS[2]}"
  elif [ "${num_parts}" -eq 2 ]; then
    # Format: repo/branch (default owner)
    OWNER="kubeflow"
    REPO="${PARTS[0]}"
    BRANCH="${PARTS[1]}"
  else
    # Format: branch (default owner and repo)
    OWNER="kubeflow"
    REPO="dashboard"
    BRANCH="${input_ref}"
  fi

  # Set defaults if not provided
  OWNER="${OWNER:-kubeflow}"
  REPO="${REPO:-dashboard}"
  BRANCH="${BRANCH:-main}"

  log_info "Repository: ${OWNER}/${REPO}"
  log_info "Branch/Commit: ${BRANCH}"
}

# Clone the repository
clone_repository() {
  local clone_dir
  clone_dir=$(mktemp -d)
  trap "rm -rf ${clone_dir}" EXIT

  log_info "Cloning ${OWNER}/${REPO} repository (shallow clone)..."
  # Try to clone with branch first (works for branch names)
  if git clone --depth 1 --branch "${BRANCH}" "https://github.com/${OWNER}/${REPO}.git" "${clone_dir}" 2>/dev/null; then
    log_info "Successfully cloned branch '${BRANCH}'"
  else
    # If branch clone failed, clone default branch and then checkout the specific ref
    log_info "Branch clone failed"
    exit 1
  fi

  BASE_DIR="${clone_dir}"
  log_info "Repository cloned to: ${BASE_DIR}"
}

# Patch Makefiles to disable docker-build-multi-arch
# Replaces 'docker-build-multi-arch' with 'docker-build-prevent-multi-arch'
# so grep checks fail and the script falls back to 'docker-build'
patch_makefiles() {
  log_info "Patching Makefiles to disable docker-build-multi-arch..."

  local components_dir="${BASE_DIR}/components"
  local makefile_count=0

  if [ ! -d "${components_dir}" ]; then
    log_warn "Components directory not found at ${components_dir}, skipping Makefile patching"
    return
  fi

  # Find all Makefiles in components/ directory
  while IFS= read -r -d '' makefile; do
    if grep -q "docker-build-multi-arch" "${makefile}" 2>/dev/null; then
      if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS uses BSD sed
        sed -i '' 's/docker-build-multi-arch/docker-build-prevent-multi-arch/g' "${makefile}"
      else
        # Linux uses GNU sed
        sed -i 's/docker-build-multi-arch/docker-build-prevent-multi-arch/g' "${makefile}"
      fi
      makefile_count=$((makefile_count + 1))
      log_info "Patched: ${makefile}"
    fi
  done < <(find "${components_dir}" -name "Makefile" -type f -print0 2>/dev/null)

  if [ "${makefile_count}" -eq 0 ]; then
    log_info "No Makefiles found with 'docker-build-multi-arch' target"
  else
    log_info "Patched ${makefile_count} Makefile(s) to use 'docker-build-prevent-multi-arch'"
  fi
}

# Step 1: Create kind cluster
setup_kind_cluster() {
  log_info "Creating kind cluster..."
  if ! command -v new-kind &> /dev/null; then
    log_error "new-kind command not found. Please ensure it's in your PATH."
    exit 1
  fi
  new-kind
}

# Step 2: Install cert-manager
install_cert_manager() {
  log_info "Installing cert-manager..."
  if [ -f "${BASE_DIR}/testing/gh-actions/install_cert_manager.sh" ]; then
    bash "${BASE_DIR}/testing/gh-actions/install_cert_manager.sh"
  else
    log_warn "cert-manager install script not found at ${BASE_DIR}/testing/gh-actions/install_cert_manager.sh"
    log_warn "Skipping cert-manager installation. Please install manually if needed."
  fi

  rm -f "${SCRIPT_DIR}/cert-manager.yaml"
}

# Step 3: Install Istio
install_istio() {
  log_info "Installing Istio..."
  if [ -f "${BASE_DIR}/testing/gh-actions/install_istio.sh" ]; then
    bash "${BASE_DIR}/testing/gh-actions/install_istio.sh"
  else
    log_warn "Istio install script not found at ${BASE_DIR}/testing/gh-actions/install_istio.sh"
    log_warn "Skipping Istio installation. Please install manually if needed."
  fi

  rm -rf "${SCRIPT_DIR}/istio_tmp"
}

# Step 4: Create kubeflow namespace
create_kubeflow_namespace() {
  log_info "Creating kubeflow namespace..."
  kubectl create namespace "${KUBEFLOW_NAMESPACE}" || kubectl get namespace "${KUBEFLOW_NAMESPACE}"
}

# Step 5: Build and deploy profile-controller
deploy_profile_controller() {
  log_info "Building and deploying profile-controller..."
  pushd "${BASE_DIR}" > /dev/null

  local PROFILE_IMG="ghcr.io/kubeflow/dashboard/profile-controller"
  local KFAM_IMG="ghcr.io/kubeflow/dashboard/access-management"

  ${MAKE} -C components/profile-controller docker-build IMG="${PROFILE_IMG}" TAG="${IMAGE_TAG}" ARCH="linux/arm64"
  ${MAKE} -C components/access-management docker-build IMG="${KFAM_IMG}" TAG="${IMAGE_TAG}" ARCH="linux/arm64"

  kind load docker-image "${PROFILE_IMG}:${IMAGE_TAG}"
  kind load docker-image "${KFAM_IMG}:${IMAGE_TAG}"

  local NEW_PROFILE_IMAGE="${PROFILE_IMG}:${IMAGE_TAG}"
  local NEW_KFAM_IMAGE="${KFAM_IMG}:${IMAGE_TAG}"

  # Escape "." in the image names, as it is a special character in sed
  local CURRENT_PROFILE_IMAGE_ESCAPED=$(echo "$PROFILE_IMG" | sed 's|\.|\\.|g')
  local NEW_PROFILE_IMAGE_ESCAPED=$(echo "$NEW_PROFILE_IMAGE" | sed 's|\.|\\.|g')
  local CURRENT_KFAM_IMAGE_ESCAPED=$(echo "$KFAM_IMG" | sed 's|\.|\\.|g')
  local NEW_KFAM_IMAGE_ESCAPED=$(echo "$NEW_KFAM_IMAGE" | sed 's|\.|\\.|g')

  echo "Deploying Profile Controller and KFAM to kubeflow namespace"
  kustomize build components/profile-controller/config/overlays/kubeflow \
      | sed "s|${CURRENT_PROFILE_IMAGE_ESCAPED}:[a-zA-Z0-9_.-]*|${NEW_PROFILE_IMAGE_ESCAPED}|g" \
      | sed "s|${CURRENT_KFAM_IMAGE_ESCAPED}:[a-zA-Z0-9_.-]*|${NEW_KFAM_IMAGE_ESCAPED}|g" \
      | kubectl apply -f -

  kubectl wait --for=condition=Available deployment -n "${KUBEFLOW_NAMESPACE}" profiles-deployment --timeout="${TIMEOUT}"
  kubectl wait pods -n "${KUBEFLOW_NAMESPACE}" -l kustomize.component=profiles --for=condition=Ready --timeout="${TIMEOUT}"

  #kubectl wait --for condition=established --timeout=60s crd/profiles.kubeflow.org
  popd > /dev/null
}

# Step 7: Build and deploy poddefaults-webhooks
deploy_poddefaults_webhooks() {
  log_info "Building and deploying poddefaults-webhooks..."
  pushd "${BASE_DIR}" > /dev/null

  "${BASE_DIR}/testing/shared/deploy_component.sh" components/poddefaults-webhooks "ghcr.io/kubeflow/dashboard/poddefaults-webhook" "${IMAGE_TAG}" "manifests" "overlays/cert-manager"

  # podman build --platform "linux/amd64" --tag "ghcr.io/kubeflow/dashboard/poddefaults-webhooks:${IMAGE_TAG}" .
  # kind load docker-image "ghcr.io/kubeflow/dashboard/poddefaults-webhooks:${IMAGE_TAG}"
  # kustomize build manifests/overlays/cert-manager > manifests.yaml
  # replace_image_tag manifests.yaml "ghcr.io/kubeflow/dashboard/poddefaults-webhooks"
  # kubectl apply -f manifests.yaml

  kubectl wait --for=condition=Ready pods -n "${KUBEFLOW_NAMESPACE}" -l app=poddefaults --timeout="${TIMEOUT}"
  kubectl wait --for=condition=Available deployment -n "${KUBEFLOW_NAMESPACE}" poddefaults-webhook-deployment --timeout="${TIMEOUT}"

  popd > /dev/null

}

# Step 8: Build and deploy centraldashboard
deploy_centraldashboard() {
  log_info "Building and deploying centraldashboard..."

  pushd "${BASE_DIR}" > /dev/null

  TAG="${IMAGE_TAG}" "${BASE_DIR}/testing/shared/install_centraldashboard.sh"

  popd > /dev/null
}

# Step 9: Build and deploy centraldashboard-angular
deploy_centraldashboard_angular() {
  log_info "Building and deploying centraldashboard-angular..."
  pushd "${BASE_DIR}" > /dev/null

  cd "${BASE_DIR}/components/centraldashboard-angular"
  export NG_CLI_ANALYTICS="ci"

  # Build common library if needed
  if [ -f "Makefile" ] && grep -q "build-common-lib" Makefile; then
    log_info "Building common library for centraldashboard-angular..."
    # Check if nvm is available and use the specified Node version
    if command -v nvm &> /dev/null || [ -s "$HOME/.nvm/nvm.sh" ]; then
      source "$HOME/.nvm/nvm.sh" 2>/dev/null || true
      nvm use v16.20.2 2>/dev/null || log_warn "nvm use v16.20.2 failed, continuing..."
    fi
    ${MAKE} build-common-lib || log_warn "${MAKE} build-common-lib failed, continuing..."
  fi

  cd "${BASE_DIR}"

  TAG="${IMAGE_TAG}" "${BASE_DIR}/testing/shared/install_centraldashboard_angular.sh"

  popd > /dev/null
}

# Main execution
main() {
  # Parse input and setup
  parse_input_ref "${1:-main}"
  clone_repository
  patch_makefiles

  # Setup cluster and prerequisites
  setup_kind_cluster
  install_cert_manager
  install_istio
  create_kubeflow_namespace

  # Deploy components
  deploy_profile_controller
  deploy_poddefaults_webhooks
  deploy_centraldashboard
  deploy_centraldashboard_angular

  log_info "All components deployed successfully!"
  log_info "Kubeflow dashboard setup complete in namespace: ${KUBEFLOW_NAMESPACE}"
}

# Execute main function
main "$@"
