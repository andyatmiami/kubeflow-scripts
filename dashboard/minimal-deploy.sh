#!/bin/bash

set -euo pipefail

# Get script directory in a POSIX-compliant way
# This resolves symlinks and returns the absolute path
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
SETUP_KIND="${SCRIPT_DIR}/../setup/setup-kind"
MANIFEST_BUILD="${SCRIPT_DIR}/manifest-build.sh"

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
SOURCE_MODE="" # "remote" or "local"

usage() {
  echo "Usage: $(basename "$0") [--remote-ref <owner>/<repo>/<branch>] [--directory <path>]"
  echo ""
  echo "Options:"
  echo "  --remote-ref <owner>/<repo>/<branch>   Clone a remote GitHub repository (branch may contain slashes)"
  echo "  --directory <path>                      Copy a local checkout into a temp directory and use it"
  echo ""
  echo "If no option is specified, defaults to --remote-ref kubeflow/dashboard/main"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0") --remote-ref kubeflow/dashboard/main"
  echo "  $(basename "$0") --remote-ref alokdangre/dashboard/refactor/centraldashboard-manifests"
  echo "  $(basename "$0") --directory /path/to/local/dashboard"
}

parse_args() {
  local remote_ref=""
  local directory=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --remote-ref)
        if [ -n "${directory}" ]; then
          log_error "Cannot specify both --remote-ref and --directory"
          exit 1
        fi
        remote_ref="${2:-}"
        if [ -z "${remote_ref}" ]; then
          log_error "--remote-ref requires a value"
          usage
          exit 1
        fi
        shift 2
        ;;
      --directory)
        if [ -n "${remote_ref}" ]; then
          log_error "Cannot specify both --remote-ref and --directory"
          exit 1
        fi
        directory="${2:-}"
        if [ -z "${directory}" ]; then
          log_error "--directory requires a value"
          usage
          exit 1
        fi
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log_error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [ -n "${directory}" ]; then
    SOURCE_MODE="local"
    setup_local_directory "${directory}"
  else
    SOURCE_MODE="remote"
    setup_remote_clone "${remote_ref:-kubeflow/dashboard/main}"
  fi
}

# Copy a local directory into a temp directory to avoid modifying the source
setup_local_directory() {
  local dir="$1"

  # Resolve to absolute path
  if [[ "${dir}" != /* ]]; then
    dir="$(cd "${dir}" 2>/dev/null && pwd -P)" || {
      log_error "Directory does not exist: $1"
      exit 1
    }
  fi

  if [ ! -d "${dir}" ]; then
    log_error "Directory does not exist: ${dir}"
    exit 1
  fi

  local temp_dir
  temp_dir=$(mktemp -d)
  trap "rm -rf ${temp_dir}" EXIT

  log_info "Copying local directory into temp directory..."
  cp -a "${dir}/." "${temp_dir}/"

  BASE_DIR="${temp_dir}"
  log_info "Using local directory: ${dir} (copied to ${BASE_DIR})"
}

# Clone a remote repository
setup_remote_clone() {
  local input_ref="$1"

  # Parse owner, repo, and branch (branch may contain slashes)
  IFS='/' read -ra PARTS <<< "${input_ref}"
  local num_parts=${#PARTS[@]}

  if [ "${num_parts}" -lt 3 ]; then
    log_error "Remote URL must be in format: <owner>/<repo>/<branch>"
    log_error "Example: kubeflow/dashboard/main"
    exit 1
  fi

  local owner="${PARTS[0]}"
  local repo="${PARTS[1]}"
  local branch="${input_ref#${PARTS[0]}/${PARTS[1]}/}"

  log_info "Repository: ${owner}/${repo}"
  log_info "Branch: ${branch}"

  local clone_dir
  clone_dir=$(mktemp -d)
  trap "rm -rf ${clone_dir}" EXIT

  log_info "Cloning ${owner}/${repo} repository (shallow clone)..."
  if git clone --depth 1 --branch "${branch}" "https://github.com/${owner}/${repo}.git" "${clone_dir}" 2>/dev/null; then
    log_info "Successfully cloned branch '${branch}'"
  else
    log_error "Failed to clone branch '${branch}' from ${owner}/${repo}"
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

# Build a docker image and load it into kind
# Usage: build_and_load <component_dir> <image_name>
build_and_load() {
  local component_dir="$1"
  local image_name="$2"

  log_info "Building image: ${image_name}:${IMAGE_TAG}"
  ${MAKE} -C "${BASE_DIR}/components/${component_dir}" docker-build IMG="${image_name}" TAG="${IMAGE_TAG}" ARCH="linux/arm64"

  log_info "Loading image into kind: ${image_name}:${IMAGE_TAG}"
  kind load docker-image "${image_name}:${IMAGE_TAG}"
}

# Deploy profile-controller and access-management
# Note: profile-controller's overlay references both images, so we can't use
# manifest-build.sh directly (it only handles one image substitution at a time).
deploy_profile_controller() {
  log_info "Building and deploying profile-controller..."

  local PROFILE_IMG="ghcr.io/kubeflow/dashboard/profile-controller"
  local KFAM_IMG="ghcr.io/kubeflow/dashboard/access-management"

  build_and_load "profile-controller" "${PROFILE_IMG}"
  build_and_load "access-management" "${KFAM_IMG}"

  local PROFILE_IMG_ESCAPED=$(echo "$PROFILE_IMG" | sed 's|\.|\\.|g')
  local KFAM_IMG_ESCAPED=$(echo "$KFAM_IMG" | sed 's|\.|\\.|g')

  log_info "Deploying profile-controller and access-management"
  kustomize build "${BASE_DIR}/components/profile-controller/config/overlays/kubeflow" \
      | sed "s|${PROFILE_IMG_ESCAPED}:[a-zA-Z0-9_.-]*|${PROFILE_IMG}:${IMAGE_TAG}|g" \
      | sed "s|${KFAM_IMG_ESCAPED}:[a-zA-Z0-9_.-]*|${KFAM_IMG}:${IMAGE_TAG}|g" \
      | kubectl apply -f -

  kubectl wait --for=condition=Available deployment -n "${KUBEFLOW_NAMESPACE}" profiles-deployment --timeout="${TIMEOUT}"
  kubectl wait pods -n "${KUBEFLOW_NAMESPACE}" -l kustomize.component=profiles --for=condition=Ready --timeout="${TIMEOUT}"
}

# Deploy a component using manifest-build.sh
# Usage: deploy_component <component_dir> <image_name> <manifests_path> <overlay>
deploy_component() {
  local component_dir="$1"
  local image_name="$2"
  local manifests_path="$3"
  local overlay="$4"

  build_and_load "${component_dir}" "${image_name}"

  log_info "Deploying ${component_dir} manifests"
  pushd "${BASE_DIR}/components/${component_dir}" > /dev/null
  "${MANIFEST_BUILD}" \
    --manifests-path "${manifests_path}" \
    --image-name "${image_name}" \
    --tag "${IMAGE_TAG}" \
    --overlay "${overlay}" \
    --apply
  popd > /dev/null
}

deploy_poddefaults_webhooks() {
  deploy_component "poddefaults-webhooks" "ghcr.io/kubeflow/dashboard/poddefaults-webhook" "manifests" "overlays/cert-manager"

  kubectl wait --for=condition=Ready pods -n "${KUBEFLOW_NAMESPACE}" -l app=poddefaults --timeout="${TIMEOUT}"
  kubectl wait --for=condition=Available deployment -n "${KUBEFLOW_NAMESPACE}" poddefaults-webhook-deployment --timeout="${TIMEOUT}"
}

deploy_centraldashboard() {
  deploy_component "centraldashboard" "ghcr.io/kubeflow/dashboard/dashboard" "manifests/kustomize" "overlays/istio"
}

deploy_centraldashboard_angular() {
  deploy_component "centraldashboard-angular" "ghcr.io/kubeflow/dashboard/dashboard-angular" "manifests" "overlays/istio"
}

# Create an example Profile for testing
create_example_profile() {
  log_info "Creating example Profile..."
  kubectl apply -f - <<'EOF'
apiVersion: kubeflow.org/v1
kind: Profile
metadata:
  name: kubeflow-user-example-com
spec:
  owner:
    kind: User
    name: user@example.com
EOF

  log_info "Waiting for profile namespace to be active..."
  kubectl wait "namespaces/kubeflow-user-example-com" \
    --for=jsonpath='{.status.phase}'=Active \
    --timeout="${TIMEOUT}"
  log_info "Profile namespace is active"
}

# Main execution
main() {
  # Parse arguments and setup source directory
  parse_args "$@"
  patch_makefiles

  # Setup cluster with Kubeflow core infrastructure
  log_info "Setting up kind cluster with Kubeflow core..."
  "${SETUP_KIND}" --core

  # Deploy components
  deploy_profile_controller
  create_example_profile
  deploy_poddefaults_webhooks
  deploy_centraldashboard
  deploy_centraldashboard_angular

  log_info "All components deployed successfully!"
  log_info "Kubeflow dashboard setup complete in namespace: ${KUBEFLOW_NAMESPACE}"
  log_info ""
  log_info "To access the dashboard:"
  log_info "  kubectl -n istio-system port-forward svc/istio-ingressgateway 9090:80"
  log_info "  Then open http://localhost:9090"
}

# Execute main function
main "$@"
