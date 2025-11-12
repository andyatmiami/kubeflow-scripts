#!/usr/bin/env bash
#
# Build and deploy script for kubeflow-notebooks components
# Deploys controllers in order: notebook-controller, pvcviewer-controller, tensorboard-controller
# Deploys crud-web-apps in order: jupyter, tensorboards, volumes
#

set -euo pipefail

# Get the script directory (where this script is located)
script_dir="$(cd "$(dirname "$0")" && pwd)"

# Global variable for repository directory (set by setup_repository)
repo_dir=""

# Global variable to track cloned directories for cleanup
cloned_dirs=()

# Global component definitions (bash arrays)
controller_components=(
    "notebook-controller"
    "pvcviewer-controller"
    "tensorboard-controller"
)

crud_web_apps=(
    "jupyter"
    "tensorboards"
    "volumes"
)

# Global variables for selected components/apps (set by parse_arguments)
selected_components=()
selected_apps=()

# Colors for output (POSIX-compliant)
red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
nc='\033[0m' # No Color

# Detect if terminal supports colors
use_colors=true
if [ ! -t 1 ] || [ "${NO_COLOR:-}" = "1" ]; then
    use_colors=false
fi

# Function to print colored output
print_status() {
    if [ "$use_colors" = "true" ]; then
        printf "${green}[INFO]${nc} %s\n" "$1"
    else
        printf "[INFO] %s\n" "$1"
    fi
}

print_error() {
    if [ "$use_colors" = "true" ]; then
        printf "${red}[ERROR]${nc} %s\n" "$1" >&2
    else
        printf "[ERROR] %s\n" "$1" >&2
    fi
}

print_warning() {
    if [ "$use_colors" = "true" ]; then
        printf "${yellow}[WARN]${nc} %s\n" "$1" >&2
    else
        printf "[WARN] %s\n" "$1" >&2
    fi
}

# Function to safely remove directory (validates path)
safe_remove_dir() {
    local dir_path="$1"

    # Validate path is absolute and in /tmp or TMPDIR
    local tmp_base="${TMPDIR:-/tmp}"
    if [[ "$dir_path" != "$tmp_base"/* ]] && [[ "$dir_path" != "/tmp"/* ]]; then
        print_error "Refusing to remove directory outside of temp directory: $dir_path"
        return 1
    fi

    # Additional safety: ensure it's not root
    if [ -z "$dir_path" ] || [ "$dir_path" = "/" ]; then
        print_error "Refusing to remove root directory"
        return 1
    fi

    if [ -d "$dir_path" ]; then
        rm -rf "$dir_path"
    fi
}

# Function to get git tag from a specific directory
get_git_tag() {
    local git_dir="${1:-.}"

    if ! command -v git >/dev/null 2>&1; then
        echo "latest"
        return 0
    fi

    local original_dir
    original_dir="$(pwd)"

    if ! cd "$git_dir" 2>/dev/null; then
        print_warning "Cannot cd to $git_dir, using 'latest' tag"
        cd "$original_dir"
        echo "latest"
        return 0
    fi

    local tag
    if tag=$(git describe --tags --always --dirty 2>/dev/null); then
        cd "$original_dir"
        echo "$tag"
    else
        cd "$original_dir"
        echo "latest"
    fi
}

# Function to check if a string is a URL (more restrictive)
is_url() {
    local string="$1"
    # Check if it starts with http://, https://, or git@ (for SSH URLs)
    if [[ "$string" =~ ^(https?://|git@) ]]; then
        return 0
    fi
    return 1
}

# Function to validate Docker image name format
validate_image_name() {
    local img_name="$1"

    # Basic validation: should contain at least one / or :, or be a simple name
    # Docker image names: [registry/][namespace/]name[:tag]
    if [[ ! "$img_name" =~ ^[a-zA-Z0-9._/-]+(:[a-zA-Z0-9._-]+)?$ ]] && [[ ! "$img_name" =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]]; then
        print_error "Invalid Docker image name format: $img_name"
        return 1
    fi

    return 0
}

# Function to validate image tag
validate_image_tag() {
    local tag="$1"

    # Docker tags: alphanumeric, dots, dashes, underscores, max 128 chars
    if [[ ! "$tag" =~ ^[a-zA-Z0-9._-]{1,128}$ ]]; then
        print_error "Invalid Docker image tag format: $tag"
        return 1
    fi

    return 0
}

# Function to safely change directory with error checking
safe_cd() {
    local target_dir="$1"
    if ! cd "$target_dir"; then
        print_error "Failed to change directory to: $target_dir"
        return 1
    fi
    return 0
}

# Function to setup repository (clone or use local)
setup_repository() {
    local repo_arg="$1"
    local repo_path
    local tmp_base="${TMPDIR:-/tmp}"

    if [ -z "$repo_arg" ]; then
        # Default: clone kubeflow/notebooks notebooks-v1 branch
        repo_path="$tmp_base/kubeflow-notebooks-v1"
        print_status "No repository specified, cloning kubeflow/notebooks (notebooks-v1 branch) to $repo_path..."

        # Remove existing directory if it exists
        safe_remove_dir "$repo_path"

        # Clone the repository
        local clone_output
        if ! clone_output=$(git clone --depth 1 --branch notebooks-v1 https://github.com/kubeflow/notebooks.git "$repo_path" 2>&1); then
            print_error "Failed to clone kubeflow/notebooks repository"
            echo "$clone_output" >&2
            return 1
        else
            cloned_dirs+=("$repo_path")
            repo_dir="$repo_path"
            print_status "Repository cloned successfully to $repo_dir"
        fi

    elif is_url "$repo_arg"; then
        # Remote URL: clone to temp directory
        local repo_name
        repo_name=$(basename "$repo_arg" .git)
        # Sanitize repo name to prevent path injection
        repo_name=$(echo "$repo_name" | sed 's/[^a-zA-Z0-9._-]/-/g')
        repo_path="$tmp_base/$repo_name"

        print_status "Cloning repository from $repo_arg to $repo_path..."

        # Remove existing directory if it exists
        safe_remove_dir "$repo_path"

        # Clone the repository (try notebooks-v1 branch, fallback to default)
        local clone_output
        if ! clone_output=$(git clone --depth 1 --branch notebooks-v1 "$repo_arg" "$repo_path" 2>&1); then
            print_warning "Failed to clone notebooks-v1 branch, trying default branch..."
            if ! clone_output=$(git clone --depth 1 "$repo_arg" "$repo_path" 2>&1); then
                print_error "Failed to clone repository from $repo_arg"
                echo "$clone_output" >&2
                return 1
            else
                cloned_dirs+=("$repo_path")
                repo_dir="$repo_path"
                print_status "Repository cloned successfully to $repo_dir"
            fi
        else
            cloned_dirs+=("$repo_path")
            repo_dir="$repo_path"
            print_status "Repository cloned successfully to $repo_dir"
        fi

    else
        # Local filepath
        repo_path="$repo_arg"

        if [ ! -d "$repo_path" ]; then
            print_error "Local repository path does not exist: $repo_path"
            return 1
        fi

        # Resolve to absolute path
        if ! repo_path="$(cd "$repo_path" && pwd)"; then
            print_error "Failed to resolve absolute path for: $repo_arg"
            return 1
        fi

        repo_dir="$repo_path"
        print_status "Using local repository at $repo_dir"
    fi

    # Verify the repository has the expected structure
    if [ ! -d "$repo_dir/components" ]; then
        print_error "Repository does not appear to be kubeflow-notebooks-v1 (missing components directory)"
        return 1
    fi

    # Change to repository directory
    if ! safe_cd "$repo_dir"; then
        return 1
    fi
    return 0
}

# Function to check if a component is valid
is_valid_component() {
    local component="$1"
    local valid_component

    for valid_component in "${controller_components[@]}"; do
        if [ "$component" = "$valid_component" ]; then
            return 0
        fi
    done

    return 1
}

# Function to check if an app is valid
is_valid_app() {
    local app="$1"
    local valid_app

    for valid_app in "${crud_web_apps[@]}"; do
        if [ "$app" = "$valid_app" ]; then
            return 0
        fi
    done

    return 1
}

# Generic function to parse comma-separated list (extracted from duplicate code)
parse_list() {
    local list_arg="$1"
    local explicitly_set="$2"  # "true" if flag was explicitly provided, "false" otherwise
    local valid_items=("${@:3}")  # All remaining arguments are valid items
    local -a parsed_items=()
    local old_ifs
    local item

    # If not explicitly set, return all items
    if [ "$explicitly_set" != "true" ]; then
        echo "${valid_items[@]}"
        return 0
    fi

    # If explicitly set but empty, return empty (deploy nothing)
    if [ -z "$list_arg" ]; then
        echo ""
        return 0
    fi

    # Save and set IFS for comma splitting
    old_ifs="$IFS"
    IFS=','

    # Split by comma and process each item
    for item in $list_arg; do
        # Restore IFS for other operations
        IFS="$old_ifs"

        # Trim leading and trailing whitespace
        item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty items
        if [ -z "$item" ]; then
            IFS=','
            continue
        fi

        # Validate item exists in valid_items
        local is_valid=false
        local valid_item
        for valid_item in "${valid_items[@]}"; do
            if [ "$item" = "$valid_item" ]; then
                is_valid=true
                break
            fi
        done

        if [ "$is_valid" != "true" ]; then
            IFS="$old_ifs"
            print_error "Invalid item: '$item'"
            print_error "Valid items are: ${valid_items[*]}"
            return 1
        fi

        parsed_items+=("$item")
        IFS=','
    done

    # Restore IFS
    IFS="$old_ifs"

    # If explicitly set but resulted in no valid items, that's okay (deploy nothing)
    # Only error if we had non-empty input but all were invalid
    if [ ${#parsed_items[@]} -eq 0 ] && [ -n "$list_arg" ]; then
        # Check if there were any non-whitespace characters
        local trimmed_arg
        trimmed_arg=$(echo "$list_arg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [ -n "$trimmed_arg" ]; then
            print_error "No valid items specified"
            return 1
        fi
    fi

    # Output the validated items (space-separated)
    echo "${parsed_items[@]}"
    return 0
}

# Function to parse and validate components from command line
parse_components() {
    local components_arg="$1"
    local explicitly_set="$2"  # "true" if flag was explicitly provided, "false" otherwise
    local parsed_result

    if ! parsed_result=$(parse_list "$components_arg" "$explicitly_set" "${controller_components[@]}"); then
        return 1
    fi

    echo "$parsed_result"
    return 0
}

# Function to parse and validate apps from command line
parse_apps() {
    local apps_arg="$1"
    local explicitly_set="$2"  # "true" if flag was explicitly provided, "false" otherwise
    local parsed_result

    if ! parsed_result=$(parse_list "$apps_arg" "$explicitly_set" "${crud_web_apps[@]}"); then
        return 1
    fi

    echo "$parsed_result"
    return 0
}

# Function to parse command line arguments
parse_arguments() {
    local components_arg=""
    local apps_arg=""
    local repo_arg=""
    local components_set=false
    local apps_set=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --components)
                if [ $# -lt 2 ]; then
                    print_error "--components requires a value"
                    exit 1
                fi
                components_arg="$2"
                components_set=true
                shift 2
                ;;
            --components=*)
                components_arg="${1#*=}"
                components_set=true
                shift
                ;;
            --apps)
                if [ $# -lt 2 ]; then
                    print_error "--apps requires a value"
                    exit 1
                fi
                apps_arg="$2"
                apps_set=true
                shift 2
                ;;
            --apps=*)
                apps_arg="${1#*=}"
                apps_set=true
                shift
                ;;
            --repo)
                if [ $# -lt 2 ]; then
                    print_error "--repo requires a value"
                    exit 1
                fi
                repo_arg="$2"
                shift 2
                ;;
            --repo=*)
                repo_arg="${1#*=}"
                shift
                ;;
            --version)
                echo "build-and-deploy.sh version 1.0.0"
                exit 0
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --components=LIST    Comma-separated list of controller components to deploy"
                echo "                       Valid components: ${controller_components[*]}"
                echo "                       If not specified, all components are deployed"
                echo "                       If set to empty string (--components=\"\"), no components are deployed"
                echo "  --apps=LIST          Comma-separated list of crud-web-apps to deploy"
                echo "                       Valid apps: ${crud_web_apps[*]}"
                echo "                       If not specified, all apps are deployed"
                echo "                       If set to empty string (--apps=\"\"), no apps are deployed"
                echo "  --repo=REPO          Repository source to use"
                echo "                       If not specified, clones kubeflow/notebooks (notebooks-v1 branch)"
                echo "                       If a remote URL, clones it to temp directory"
                echo "                       If a local filepath, uses the code on disk"
                echo "  --version            Show version information"
                echo "  --help, -h           Show this help message"
                echo ""
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                print_error "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Parse and validate components
    local parsed_result
    if ! parsed_result=$(parse_components "$components_arg" "$components_set"); then
        exit 1
    fi

    # Set global array (bash arrays can't be exported, so we use a global variable)
    # Handle empty result (when explicitly set to empty string)
    if [ -z "$parsed_result" ]; then
        selected_components=()
    else
        read -ra selected_components <<< "$parsed_result"
    fi

    # Parse and validate apps
    if ! parsed_result=$(parse_apps "$apps_arg" "$apps_set"); then
        exit 1
    fi

    # Set global array for apps
    # Handle empty result (when explicitly set to empty string)
    if [ -z "$parsed_result" ]; then
        selected_apps=()
    else
        read -ra selected_apps <<< "$parsed_result"
    fi

    # Setup repository (clone or use local)
    if ! setup_repository "$repo_arg"; then
        exit 1
    fi
}

# Function to extract image name from Makefile
extract_image_from_makefile() {
    local makefile_path="$1"

    if [ ! -f "$makefile_path" ]; then
        print_error "Makefile not found: $makefile_path"
        return 1
    fi

    # Extract IMG variable from Makefile (handles both IMG ?= and IMG= patterns)
    # Use -E for extended regex and escape the ? properly
    local img_line
    img_line=$(grep -E '^IMG[[:space:]]*\??=' "$makefile_path" | head -1)
    if [ -z "$img_line" ]; then
        print_error "Could not find IMG variable in Makefile: $makefile_path"
        return 1
    fi

    # Extract image name (everything after = or ?=, trim whitespace)
    # Handle both IMG=value and IMG ?= value patterns
    # Remove everything up to and including the = (or ?=) and any following whitespace
    local img_name
    img_name=$(echo "$img_line" | sed -E 's/^IMG[[:space:]]*(\?[[:space:]]*)?=[[:space:]]*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

    # Validate image name
    if ! validate_image_name "$img_name"; then
        return 1
    fi

    echo "$img_name"
    return 0
}

# Function to update kustomization.yaml with new image tag
update_kustomization_yaml() {
    local kustomization_file="$1"
    local img_base="$2"
    local tag="$3"

    if [ ! -f "$kustomization_file" ]; then
        print_error "kustomization.yaml not found: $kustomization_file"
        return 1
    fi

    # Validate inputs
    if ! validate_image_name "$img_base"; then
        return 1
    fi

    if ! validate_image_tag "$tag"; then
        return 1
    fi

    # Update newTag in kustomization.yaml
    # Use more specific patterns to avoid matching comments
    if grep -q "^[[:space:]]*-[[:space:]]*name:" "$kustomization_file" && grep -q "newTag:" "$kustomization_file"; then
        # Update existing newTag (more specific pattern)
        if [ "$(uname)" = "Darwin" ]; then
            # macOS sed requires -i '' for in-place editing
            # Match newTag: followed by whitespace and value (not in comments)
            sed -i '' "s|^\([[:space:]]*newTag:\)[[:space:]]*.*|\1 $tag|" "$kustomization_file"
            # Also update newName to ensure it matches
            sed -i '' "s|^\([[:space:]]*newName:\)[[:space:]]*.*|\1 $img_base|" "$kustomization_file"
        else
            # Linux sed
            sed -i "s|^\([[:space:]]*newTag:\)[[:space:]]*.*|\1 $tag|" "$kustomization_file"
            sed -i "s|^\([[:space:]]*newName:\)[[:space:]]*.*|\1 $img_base|" "$kustomization_file"
        fi
    else
        # No newTag found, check if images section exists
        if ! grep -q "^[[:space:]]*images:" "$kustomization_file"; then
            print_warning "No images section found in kustomization.yaml, adding it"
            # Add images section at the end (POSIX-compliant)
            {
                echo "images:"
                echo "- name: $img_base"
                echo "  newName: $img_base"
                echo "  newTag: $tag"
            } >> "$kustomization_file"
        else
            # Images section exists but no newTag - add image entry after images: line
            # Use awk for POSIX-compliant multiline insertion
            # Only insert if we don't already have an entry for this image
            local img_base_escaped
            img_base_escaped=$(printf '%s\n' "$img_base" | sed 's/[[\.*^$()+?{|]/\\&/g')
            if grep -q "name:[[:space:]]*${img_base_escaped}" "$kustomization_file"; then
                # Update existing entry - find the image entry and update newTag/newName
                awk -v img="$img_base" -v tag="$tag" '
                    BEGIN { in_target_image = 0 }
                    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
                        # Check if this is our target image
                        if ($0 ~ img) {
                            in_target_image = 1
                            print
                            next
                        } else {
                            in_target_image = 0
                        }
                    }
                    in_target_image && /^[[:space:]]*newName:/ {
                        print "  newName: " img
                        next
                    }
                    in_target_image && /^[[:space:]]*newTag:/ {
                        print "  newTag: " tag
                        in_target_image = 0
                        next
                    }
                    { print }
                ' "$kustomization_file" > "$kustomization_file.tmp" && \
                mv "$kustomization_file.tmp" "$kustomization_file"
            else
                # Add new entry after images: line
                awk -v img="$img_base" -v tag="$tag" '
                    /^[[:space:]]*images:/ {
                        print
                        print "- name: " img
                        print "  newName: " img
                        print "  newTag: " tag
                        next
                    }
                    {print}
                ' "$kustomization_file" > "$kustomization_file.tmp" && \
                mv "$kustomization_file.tmp" "$kustomization_file"
            fi
        fi
    fi

    return 0
}

# Function to deploy crud-web-app component
deploy_crud_web_app() {
    local component="$1"
    local component_dir="components/crud-web-apps/$component"
    local base_manifest_dir="$component_dir/manifests/base"
    local istio_overlay_dir="$component_dir/manifests/overlays/istio"

    if [ ! -d "$component_dir" ]; then
        print_error "Component directory not found: $component_dir"
        return 1
    fi

    if [ ! -d "$base_manifest_dir" ]; then
        print_error "Base manifest directory not found: $base_manifest_dir"
        return 1
    fi

    if [ ! -d "$istio_overlay_dir" ]; then
        print_error "Istio overlay directory not found: $istio_overlay_dir"
        return 1
    fi

    print_status "Building and deploying $component..."

    local original_dir
    original_dir="$(pwd)"

    if ! safe_cd "$component_dir"; then
        return 1
    fi

    # Get the image name from Makefile
    local img
    if ! img=$(extract_image_from_makefile "Makefile"); then
        safe_cd "$repo_dir"
        return 1
    fi

    # Get tag from current directory (we're already in component_dir)
    local tag
    tag=$(get_git_tag ".")

    # Extract base image name (registry/repo/image without tag)
    local img_base
    img_base=$(echo "$img" | sed 's|:.*||')

    # Detect platform for building
    local platform
    platform=$(detect_platform)

    print_status "Building Docker image for $component (${img}:${tag}, platform: $platform)..."
    # Try to pass ARCH or PLATFORM to make (as seen in dashboard/minimal-deploy.sh)
    # First try with ARCH flag (common pattern in kubeflow Makefiles)
    if ! make docker-build ARCH="$platform" 2>/dev/null; then
        # If ARCH doesn't work, try PLATFORM
        if ! make docker-build PLATFORM="$platform" 2>/dev/null; then
            # Try with DOCKER_BUILD_ARGS if Makefile supports it
            if ! make docker-build DOCKER_BUILD_ARGS="--platform $platform" 2>/dev/null; then
                # Last resort: build normally (Docker/Podman should detect platform automatically)
                if ! make docker-build; then
                    print_error "Failed to build Docker image for $component"
                    safe_cd "$repo_dir"
                    return 1
                fi
            fi
        fi
    fi

    # Load image into kind instead of pushing to registry
    if ! load_image_to_kind "$img_base" "$tag"; then
        safe_cd "$repo_dir"
        return 1
    fi

    # Update kustomization.yaml in base with new image tag
    # (The istio overlay references base, so we update base)
    # Use relative path since we're already in component_dir
    if ! safe_cd "manifests/base"; then
        safe_cd "$repo_dir"
        return 1
    fi

    local kustomization_file="kustomization.yaml"

    # Update kustomization.yaml in base
    if ! update_kustomization_yaml "$kustomization_file" "$img_base" "$tag"; then
        safe_cd "$repo_dir"
        return 1
    fi

    # Deploy using kubectl kustomize from the istio overlay
    print_status "Deploying $component to cluster using istio overlay..."
    # Go back to component_dir first, then navigate to istio overlay
    if ! safe_cd "$repo_dir/$component_dir/manifests/overlays/istio"; then
        safe_cd "$repo_dir"
        return 1
    fi

    if kubectl kustomize . | kubectl apply -f -; then
        print_status "Successfully deployed $component"
    else
        print_error "Failed to deploy $component"
        safe_cd "$repo_dir"
        return 1
    fi

    safe_cd "$repo_dir"
    return 0
}

# Function to detect local platform architecture
detect_platform() {
    local arch
    arch=$(uname -m)

    case "$arch" in
        arm64|aarch64)
            echo "linux/arm64"
            ;;
        x86_64|amd64)
            echo "linux/amd64"
            ;;
        *)
            print_warning "Unknown architecture: $arch, defaulting to linux/amd64"
            echo "linux/amd64"
            ;;
    esac
}

# Function to load Docker image into kind cluster
load_image_to_kind() {
    local image_name="$1"
    local image_tag="$2"
    local full_image="${image_name}:${image_tag}"

    print_status "Loading Docker image into kind cluster: $full_image"

    if ! kind load docker-image "$full_image"; then
        print_error "Failed to load Docker image into kind cluster: $full_image"
        return 1
    fi
    print_status "Successfully loaded image into kind cluster: $full_image"

    return 0
}

# Function to check prerequisites
check_prerequisites() {
    print_status "Checking prerequisites..."

    if ! command -v kubectl >/dev/null 2>&1; then
        print_error "kubectl is not installed or not in PATH"
        return 1
    fi

    if ! command -v docker >/dev/null 2>&1; then
        print_error "docker is not installed or not in PATH"
        return 1
    fi

    if ! command -v make >/dev/null 2>&1; then
        print_error "make is not installed or not in PATH"
        return 1
    fi

    if ! command -v kind >/dev/null 2>&1; then
        print_error "kind is not installed or not in PATH (required for loading images)"
        return 1
    fi

    # git is needed for cloning repositories (if --repo is not a local path)
    if ! command -v git >/dev/null 2>&1; then
        print_error "git is not installed or not in PATH (required for repository cloning)"
        return 1
    fi

    if ! kubectl cluster-info >/dev/null 2>&1; then
        print_error "Cannot connect to Kubernetes cluster. Please check your kubeconfig."
        return 1
    fi

    print_status "Connected to Kubernetes cluster: $(kubectl config current-context 2>/dev/null || echo 'default')"

    return 0
}

# Function to deploy a single controller component
deploy_controller() {
    local component="$1"
    local component_dir="components/$component"
    local base_config_dir="$component_dir/config/base"
    local kubeflow_overlay_dir="$component_dir/config/overlays/kubeflow"

    if [ ! -d "$component_dir" ]; then
        print_error "Component directory not found: $component_dir"
        return 1
    fi

    print_status "Building and deploying $component..."

    local original_dir
    original_dir="$(pwd)"

    if ! safe_cd "$component_dir"; then
        return 1
    fi

    # Get image name and tag first (needed for building and loading)
    local img
    if ! img=$(extract_image_from_makefile "Makefile"); then
        safe_cd "$repo_dir"
        return 1
    fi

    # Get tag from current directory (we're already in component_dir)
    local tag
    tag=$(get_git_tag ".")

    local img_base
    img_base=$(echo "$img" | sed 's|:.*||')

    # Detect platform for building
    local platform
    platform=$(detect_platform)

    # Check if kubeflow overlay exists (use relative path since we're in component_dir)
    local kubeflow_overlay_rel="config/overlays/kubeflow"
    if [ -d "$kubeflow_overlay_rel" ]; then
        # When using overlay, we need to build/load images manually
        # (make deploy normally handles this, but we're bypassing it)
        print_status "Building Docker image for $component (platform: $platform)..."
        # Try to pass ARCH or PLATFORM to make (as seen in dashboard/minimal-deploy.sh)
        # First try with ARCH flag (common pattern in kubeflow Makefiles)
        if ! make docker-build ARCH="$platform" 2>/dev/null; then
            # If ARCH doesn't work, try PLATFORM
            if ! make docker-build PLATFORM="$platform" 2>/dev/null; then
                # Try with DOCKER_BUILD_ARGS if Makefile supports it
                if ! make docker-build DOCKER_BUILD_ARGS="--platform $platform" 2>/dev/null; then
                    # Last resort: build normally (Docker/Podman should detect platform automatically)
                    if ! make docker-build; then
                        print_error "Failed to build Docker image for $component"
                        safe_cd "$repo_dir"
                        return 1
                    fi
                fi
            fi
        fi

        # Load image into kind instead of pushing to registry
        if ! load_image_to_kind "$img_base" "$tag"; then
            safe_cd "$repo_dir"
            return 1
        fi

        print_status "Using kubeflow overlay for $component..."

        # Update base kustomization.yaml with image tag (overlay references base)
        # Use relative path since we're in component_dir
        local base_config_rel="config/base"
        if [ -d "$base_config_rel" ] && [ -f "$base_config_rel/kustomization.yaml" ]; then
            if ! update_kustomization_yaml "$base_config_rel/kustomization.yaml" "$img_base" "$tag"; then
                safe_cd "$repo_dir"
                return 1
            fi
        fi

        # Generate manifests and deploy from kubeflow overlay
        print_status "Generating manifests for $component..."
        if ! make manifests kustomize >/dev/null 2>&1; then
            print_warning "make manifests kustomize failed, continuing..."
        fi

        # Deploy using kubectl kustomize from the kubeflow overlay
        # Use relative path since we're already in component_dir
        print_status "Deploying $component to cluster using kubeflow overlay..."
        if kubectl kustomize "$kubeflow_overlay_rel" | kubectl apply -f -; then
            print_status "Successfully deployed $component"
        else
            print_error "Failed to deploy $component"
            safe_cd "$repo_dir"
            return 1
        fi
    else
        # No kubeflow overlay, use kustomize directly to avoid docker-push
        print_status "No kubeflow overlay found, using kustomize for deployment..."

        # Build image with platform support and load to kind before deploy
        print_status "Building Docker image for $component (platform: $platform)..."
        # Try to pass ARCH or PLATFORM to make (as seen in dashboard/minimal-deploy.sh)
        # First try with ARCH flag (common pattern in kubeflow Makefiles)
        if ! make docker-build ARCH="$platform" 2>/dev/null; then
            # If ARCH doesn't work, try PLATFORM
            if ! make docker-build PLATFORM="$platform" 2>/dev/null; then
                # Try with DOCKER_BUILD_ARGS if Makefile supports it
                if ! make docker-build DOCKER_BUILD_ARGS="--platform $platform" 2>/dev/null; then
                    # Last resort: build normally (Docker/Podman should detect platform automatically)
                    if ! make docker-build; then
                        print_error "Failed to build Docker image for $component"
                        safe_cd "$repo_dir"
                        return 1
                    fi
                fi
            fi
        fi

        # Load image into kind instead of pushing to registry
        if ! load_image_to_kind "$img_base" "$tag"; then
            safe_cd "$repo_dir"
            return 1
        fi

        # Update kustomization.yaml in base with image tag
        # Use relative path since we're already in component_dir
        local base_config_rel="config/base"
        if [ -d "$base_config_rel" ] && [ -f "$base_config_rel/kustomization.yaml" ]; then
            if ! update_kustomization_yaml "$base_config_rel/kustomization.yaml" "$img_base" "$tag"; then
                safe_cd "$repo_dir"
                return 1
            fi
        fi

        # Generate manifests (if needed)
        print_status "Generating manifests for $component..."
        if ! make manifests >/dev/null 2>&1; then
            print_warning "make manifests failed, continuing..."
        fi

        # Deploy using kubectl kustomize from base config (avoid make deploy which includes push)
        print_status "Deploying $component to cluster using kustomize..."
        if [ -d "$base_config_rel" ] && [ -f "$base_config_rel/kustomization.yaml" ]; then
            if kubectl kustomize "$base_config_rel" | kubectl apply -f -; then
                print_status "Successfully deployed $component"
            else
                print_error "Failed to deploy $component"
                safe_cd "$repo_dir"
                return 1
            fi
        else
            # Fallback: try make deploy without push (if Makefile supports it)
            print_warning "No base config found, attempting make deploy (may try to push)..."
            # Try to override docker-push to be a no-op
            if make docker-push SKIP_PUSH=true 2>/dev/null || \
               make deploy SKIP_PUSH=true 2>/dev/null || \
               DOCKER_PUSH_OVERRIDE=true make deploy 2>/dev/null; then
                print_status "Successfully deployed $component"
            else
                print_error "Failed to deploy $component"
                safe_cd "$repo_dir"
                return 1
            fi
        fi
    fi

    safe_cd "$repo_dir"
    return 0
}

# Function to deploy all controller components
deploy_controllers() {
    local components_to_deploy=("${selected_components[@]}")

    # Skip if no components selected
    if [ ${#components_to_deploy[@]} -eq 0 ]; then
        print_status "No controller components selected for deployment (skipping)"
        return 0
    fi

    print_status "Starting deployment of controller components..."
    print_status "Components to deploy: ${components_to_deploy[*]}"

    for component in "${components_to_deploy[@]}"; do
        if ! deploy_controller "$component"; then
            print_error "Failed to deploy controller: $component"
            return 1
        fi
    done

    print_status "All controller components have been successfully built and deployed!"
    return 0
}

# Function to deploy all crud-web-apps components
deploy_crud_web_apps() {
    local apps_to_deploy=("${selected_apps[@]}")

    # Skip if no apps selected
    if [ ${#apps_to_deploy[@]} -eq 0 ]; then
        print_status "No crud-web-apps selected for deployment (skipping)"
        return 0
    fi

    print_status "Starting deployment of crud-web-apps components..."
    print_status "Apps to deploy: ${apps_to_deploy[*]}"

    for app in "${apps_to_deploy[@]}"; do
        if ! deploy_crud_web_app "$app"; then
            print_error "Failed to deploy crud-web-app: $app"
            return 1
        fi
    done

    print_status "All crud-web-apps components have been successfully built and deployed!"
    return 0
}

# Cleanup function for trap
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        print_warning "Script exited with error code $exit_code"
    fi

    # Clean up cloned directories if they exist
    if [ ${#cloned_dirs[@]} -gt 0 ]; then
        for dir in "${cloned_dirs[@]}"; do
            if [ -d "$dir" ]; then
                safe_remove_dir "$dir"
            fi
        done
    fi
}

# Set up trap for cleanup on exit
trap cleanup EXIT

# Main function
main() {
    # Parse command line arguments
    parse_arguments "$@"

    if ! check_prerequisites; then
        exit 1
    fi

    if ! deploy_controllers; then
        exit 1
    fi

    if ! deploy_crud_web_apps; then
        exit 1
    fi

    print_status "All components (controllers and crud-web-apps) have been successfully built and deployed!"
    return 0
}

# Execute main function with all arguments
main "$@"
