#!/usr/bin/env bash
# Build UniFi OS Server images by extracting the inner uosserver image from the Ubiquiti installer.
#
# This follows the lemker/unifi-os-server approach:
# 1. Run the installer (it fails at container start, but extracts the uosserver image)
# 2. Copy the extracted image from podman storage
# 3. Build a runtime image that runs systemd directly (no nested podman)
#
# Architecture:
#   Docker Host
#   └── Extractor Container (outer)
#       └── Podman
#           └── uosserver Container (inner)
#
# The installer runs in the outer container, imports the uosserver image into podman,
# then tries to start the inner container. The inner container fails (no systemd in build),
# but the image is extracted to /output/uosserver.tar.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-giiibates/unifi-os-server}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
PUSH="${PUSH:-true}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
VERSION="${VERSION:-}"
BUILD_ARTIFACTS_DIR="${BUILD_ARTIFACTS_DIR:-${REPO_ROOT}/build-artifacts}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf '[build] This script must be executed, not sourced. Use ./build.sh or bash ./build.sh.\n' >&2
    return 1 2>/dev/null || exit 1
fi

amd64_url=""
declare -a requested_platforms=()
declare -a arch_image_tags=()
declare -a cleanup_containers=()

#######################################
# LOGGING
#######################################

log() {
    printf '%s %b[build]%b %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GREEN}" "${NC}" "$*"
}

warn() {
    printf '%s %b[warn]%b %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${YELLOW}" "${NC}" "$*"
}

error() {
    printf '%s %b[error]%b %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RED}" "${NC}" "$*" >&2
}

diag() {
    printf '%s %b[diag]%b %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BLUE}" "${NC}" "$*"
}

fatal() {
    error "$@"
    exit 1
}

#######################################
# CONTAINER STATE MODEL
#######################################

# Container states we care about:
#   running   - container is running
#   exited    - container exited (check exit code)
#   dead      - container is dead (docker daemon issue)
#   removing  - container is being removed
#   paused    - container is paused
#   created   - container created but not started
#   restarting - container is restarting
#   <missing> - container does not exist

get_container_state() {
    local container_name="$1"
    local state
    state=$(docker inspect --format '{{.State.Status}}' "$container_name" 2>/dev/null) || {
        printf 'missing\n'
        return
    }
    printf '%s\n' "$state"
}

get_container_exit_code() {
    local container_name="$1"
    docker inspect --format '{{.State.ExitCode}}' "$container_name" 2>/dev/null || printf '255\n'
}

get_container_oom_killed() {
    local container_name="$1"
    docker inspect --format '{{.State.OOMKilled}}' "$container_name" 2>/dev/null || printf 'false\n'
}

get_container_error() {
    local container_name="$1"
    docker inspect --format '{{.State.Error}}' "$container_name" 2>/dev/null || printf '\n'
}

get_container_started_at() {
    local container_name="$1"
    docker inspect --format '{{.State.StartedAt}}' "$container_name" 2>/dev/null || printf '\n'
}

get_container_finished_at() {
    local container_name="$1"
    docker inspect --format '{{.State.FinishedAt}}' "$container_name" 2>/dev/null || printf '\n'
}

container_exists() {
    local container_name="$1"
    docker inspect "$container_name" >/dev/null 2>&1
}

# Print full container state for diagnostics
print_container_state() {
    local container_name="$1"
    local prefix="${2:-}"

    if ! container_exists "$container_name"; then
        diag "${prefix}Container '$container_name': does not exist"
        return 1
    fi

    local state exit_code oom_killed error_msg started finished
    state=$(get_container_state "$container_name")
    exit_code=$(get_container_exit_code "$container_name")
    oom_killed=$(get_container_oom_killed "$container_name")
    error_msg=$(get_container_error "$container_name")
    started=$(get_container_started_at "$container_name")
    finished=$(get_container_finished_at "$container_name")

    diag "${prefix}Container '$container_name':"
    diag "${prefix}  state:      $state"
    diag "${prefix}  exit_code:  $exit_code"
    diag "${prefix}  oom_killed: $oom_killed"
    diag "${prefix}  started:    $started"
    diag "${prefix}  finished:   $finished"
    [[ -z "$error_msg" ]] || diag "${prefix}  error:      $error_msg"
}

#######################################
# FAILURE PRESERVATION
#######################################

# Always preserve failure artifacts - this is critical for debugging
preserve_failure() {
    local container_name="$1"
    local arch="$2"
    local phase="$3"
    local reason="$4"

    mkdir -p "$BUILD_ARTIFACTS_DIR"
    local timestamp
    timestamp=$(date -u +%Y%m%d-%H%M%S)
    local prefix="${BUILD_ARTIFACTS_DIR}/failure-${arch}-${phase}-${timestamp}"

    warn "=== FAILURE PRESERVATION ==="
    warn "Phase: $phase"
    warn "Reason: $reason"
    warn "Artifacts: ${prefix}*"

    # Save reason
    {
        echo "Phase: $phase"
        echo "Reason: $reason"
        echo "Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "Container: $container_name"
        echo "Architecture: $arch"
        echo "Version: ${VERSION:-unknown}"
    } > "${prefix}-reason.txt"

    # Check if container still exists
    if ! container_exists "$container_name"; then
        warn "Container '$container_name' no longer exists - limited diagnostics available"
        echo "Container did not exist at time of failure preservation" >> "${prefix}-reason.txt"
        return
    fi

    # Save container state
    print_container_state "$container_name" "  " >> "${prefix}-reason.txt"

    # Save full inspect
    diag "Saving docker inspect..."
    docker inspect "$container_name" > "${prefix}-inspect.json" 2>&1 || true

    # Save logs (full, not truncated)
    diag "Saving container logs..."
    docker logs "$container_name" > "${prefix}-stdout.log" 2> "${prefix}-stderr.log" || true

    # Save filesystem if container exists
    local state
    state=$(get_container_state "$container_name")
    if [[ "$state" == "exited" || "$state" == "dead" || "$state" == "running" ]]; then
        diag "Exporting container filesystem (may take a moment)..."
        docker export "$container_name" > "${prefix}-filesystem.tar" 2>/dev/null || true
    fi

    # Try to get inner podman state if possible
    if [[ "$state" == "running" ]]; then
        diag "Capturing inner podman state..."
        docker exec "$container_name" podman ps -a > "${prefix}-podman-ps.txt" 2>&1 || true
        docker exec "$container_name" podman images > "${prefix}-podman-images.txt" 2>&1 || true
        docker exec "$container_name" podman logs uosserver > "${prefix}-podman-uosserver.log" 2>&1 || true
    fi

    warn "Failure artifacts saved to: ${prefix}*"
}

#######################################
# CLEANUP
#######################################

cleanup() {
    local exit_code="${1:-$?}"
    trap - EXIT ERR

    if (( ${#cleanup_containers[@]} > 0 )); then
        log "Cleaning up ${#cleanup_containers[@]} container(s)..."
        for container_name in "${cleanup_containers[@]}"; do
            [[ -n "$container_name" ]] || continue
            if container_exists "$container_name"; then
                docker rm -f "$container_name" >/dev/null 2>&1 || true
            fi
        done
    fi

    exit "$exit_code"
}

trap 'cleanup $?' EXIT

#######################################
# UTILITIES
#######################################

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || fatal "Missing required command: $1"
}

extract_version_from_url() {
    local url="$1"
    local version
    version="$(sed -E 's|.*-([0-9]+\.[0-9]+\.[0-9]+)-.*|\1|' <<<"$url")"
    [[ -n "$version" && "$version" != "$url" ]] || fatal "Could not derive version from URL: $url"
    printf '%s\n' "$version"
}

host_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'amd64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        *) printf 'unknown\n' ;;
    esac
}

validate_requested_platforms() {
    local native_arch
    native_arch="$(host_arch)"

    [[ "$native_arch" == "amd64" ]] || error "This project currently supports only linux/amd64 release builds."

    for platform in "${requested_platforms[@]}"; do
        local requested_arch="${platform#linux/}"
        [[ "$requested_arch" == "amd64" ]] || error "Unsupported platform: ${platform}. This project is currently amd64-only."
    done
}

load_config() {
    amd64_url="${UNIFI_OS_URL_X64:-}"
    [[ -n "$amd64_url" ]] || error "UNIFI_OS_URL_X64 is required"

    if [[ -z "$VERSION" ]]; then
        VERSION="$(extract_version_from_url "$amd64_url")"
    fi

    IFS=',' read -r -a requested_platforms <<<"$PLATFORMS"
}

installer_url_for_arch() {
    local arch="$1"
    case "$arch" in
        amd64) printf '%s\n' "$amd64_url" ;;
        *) error "Unsupported architecture: $arch" ;;
    esac
}

# --- Phase 1: Build extractor image ---
build_extractor_image() {
    local arch="$1"
    local installer_url="$2"
    local extractor_tag="uos-extractor:${VERSION}-${arch}"

    log "Building extractor image for linux/${arch}"
    docker build \
        --platform "linux/${arch}" \
        --file "${REPO_ROOT}/docker/Dockerfile.extractor" \
        --tag "$extractor_tag" \
        --build-arg "UOS_INSTALLER_URL=${installer_url}" \
        "$REPO_ROOT" >&2

    printf '%s' "$extractor_tag"
}

# --- Phase 2: Run extractor to get uosserver image ---
run_extraction() {
    local arch="$1"
    local extractor_tag="$2"
    local container_name="uos-extract-${arch}-$$"
    local output_dir="${REPO_ROOT}/build-artifacts/extract-${arch}"

    mkdir -p "$output_dir"

    log "Running extractor container to download and extract uosserver image..."

    # Run extractor in privileged container with cgroups (needed for installer)
    docker run \
        --rm \
        --platform "linux/${arch}" \
        --name "$container_name" \
        --privileged \
        --cgroupns=host \
        --tmpfs /run:exec \
        --tmpfs /run/lock \
        --tmpfs /tmp:exec \
        --tmpfs /var/tmp:exec \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "${output_dir}:/output" \
        "$extractor_tag"

    # Check if extraction succeeded
    if [[ ! -f "${output_dir}/uosserver.tar" ]]; then
        save_failure_artifacts "$container_name" "$arch" "Extraction failed - no uosserver.tar"
        error "Extraction failed: ${output_dir}/uosserver.tar not found"
    fi

    local image_tag
    image_tag=$(cat "${output_dir}/image-tag.txt" 2>/dev/null || echo "uosserver:unknown")

    log "Extraction complete. Image tag: $image_tag"
    printf '%s\n' "${output_dir}/uosserver.tar"
}

# --- Phase 3: Load extracted image into Docker ---
load_extracted_image() {
    local arch="$1"
    local tar_path="$2"
    local target_tag="uosserver:${VERSION}-${arch}"

    log "Loading extracted image into Docker..."

    # Load the image
    docker load -i "$tar_path"

    # Find what was loaded and tag it with our target name
    local loaded_repo
    loaded_repo=$(docker load -i "$tar_path" 2>&1 | grep -oP 'Loaded image: \K[^:]+' | head -1 || true)

    if [[ -n "$loaded_repo" ]]; then
        local loaded_tag
        loaded_tag=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep "^${loaded_repo}:" | head -1 || true)
        if [[ -n "$loaded_tag" && "$loaded_tag" != "$target_tag" ]]; then
            docker tag "$loaded_tag" "$target_tag"
        fi
    fi

    # Verify the image exists
    if ! docker image inspect "$target_tag" >/dev/null 2>&1; then
        # Try to find any uosserver image and tag it
        local any_uosserver
        any_uosserver=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E '^(localhost/)?uosserver:' | head -1 || true)
        if [[ -n "$any_uosserver" ]]; then
            docker tag "$any_uosserver" "$target_tag"
        else
            error "Failed to load uosserver image"
        fi
    fi

    log "Loaded and tagged as: $target_tag"
    printf '%s\n' "$target_tag"
}

# --- Phase 3: Build runtime image ---
build_runtime_image() {
    local arch="$1"
    local uosserver_tag="$2"
    local final_tag="${IMAGE_NAME}:${VERSION}-${arch}"

    log "Building runtime image for linux/${arch}"

    docker build \
        --platform "linux/${arch}" \
        --file "${REPO_ROOT}/docker/Dockerfile.runtime" \
        --tag "$final_tag" \
        --build-arg "UOSSERVER_IMAGE=${uosserver_tag}" \
        --build-arg "APP_VERSION=${VERSION}" \
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        "$REPO_ROOT"

    arch_image_tags+=("$final_tag")
    printf '%s\n' "$final_tag"
}

# --- Phase 4: Validate runtime image (Finding B1) ---
validate_runtime_image() {
    local arch="$1"
    local image_tag="$2"
    local validate_container="uos-validate-${arch}-$$"

    log "Validating runtime image ${image_tag}"

    # Start the container with required settings (same as docker-compose)
    docker run -d \
        --name "$validate_container" \
        --platform "linux/${arch}" \
        --cgroupns=host \
        --cap-add NET_RAW \
        --cap-add NET_ADMIN \
        --tmpfs /run:exec \
        --tmpfs /run/lock \
        --tmpfs /tmp:exec \
        --tmpfs /var/lib/journal \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        "$image_tag" >/dev/null

    cleanup_containers+=("$validate_container")

    # Wait for systemd to start (give it 30 seconds)
    log "Waiting for systemd to initialize..."
    local deadline=$((SECONDS + 30))
    local systemd_ready=false

    while (( SECONDS < deadline )); do
        if docker exec "$validate_container" systemctl is-system-running --wait 2>/dev/null | grep -qE 'running|degraded'; then
            systemd_ready=true
            break
        fi
        sleep 2
    done

    if [[ "$systemd_ready" != "true" ]]; then
        warn "Systemd did not reach running state within 30s (may be normal during build)"
    fi

    # Check for key processes/services
    log "Checking container state..."
    docker exec "$validate_container" ps aux 2>/dev/null | head -20 || true

    # Stop and remove validation container
    docker stop -t 10 "$validate_container" >/dev/null 2>&1 || true
    docker rm -f "$validate_container" >/dev/null 2>&1 || true

    log "Validation complete for ${image_tag}"
}

# --- Main build flow for one architecture ---
build_arch_image() {
    local arch="$1"
    local installer_url="$2"
    local extractor_tag="uos-extractor:${VERSION}-${arch}"
    local output_dir="${REPO_ROOT}/build-artifacts/extract-${arch}"
    local uosserver_tag="uosserver:${VERSION}-${arch}"
    local final_tag="${IMAGE_NAME}:${VERSION}-${arch}"

    log "=== Building for linux/${arch} ==="

    # Phase 1: Build extractor base image
    log "Building extractor image for linux/${arch}"
    docker build \
        --platform "linux/${arch}" \
        --file "${REPO_ROOT}/docker/Dockerfile.extractor" \
        --tag "$extractor_tag" \
        --build-arg "UOS_INSTALLER_URL=${installer_url}" \
        "$REPO_ROOT"

    # Phase 2: Run extractor to download installer and extract uosserver image
    mkdir -p "$output_dir"
    log "Running extractor container to download and extract uosserver image..."

    docker run \
        --rm \
        --platform "linux/${arch}" \
        --privileged \
        --cgroupns=host \
        --tmpfs /run:exec \
        --tmpfs /run/lock \
        --tmpfs /tmp:exec \
        --tmpfs /var/tmp:exec \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -v "${output_dir}:/output" \
        "$extractor_tag"

    # Check if extraction succeeded
    if [[ ! -f "${output_dir}/uosserver.tar" ]]; then
        error "Extraction failed: ${output_dir}/uosserver.tar not found"
    fi

    log "Extraction complete."

    # Phase 3: Load extracted image into Docker
    log "Loading extracted image into Docker..."
    docker load -i "${output_dir}/uosserver.tar"

    # Tag the loaded image
    local loaded_image
    loaded_image=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E '^(localhost/)?uosserver:' | head -1 || true)
    if [[ -n "$loaded_image" && "$loaded_image" != "$uosserver_tag" ]]; then
        docker tag "$loaded_image" "$uosserver_tag"
    fi

    log "Loaded and tagged as: $uosserver_tag"

    # Phase 4: Build runtime image
    log "Building runtime image for linux/${arch}"
    docker build \
        --platform "linux/${arch}" \
        --file "${REPO_ROOT}/docker/Dockerfile.runtime" \
        --tag "$final_tag" \
        --build-arg "UOSSERVER_IMAGE=${uosserver_tag}" \
        --build-arg "APP_VERSION=${VERSION}" \
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        "$REPO_ROOT"

    arch_image_tags+=("$final_tag")

    # Phase 5: Validate (optional)
    if [[ "${SKIP_VALIDATION:-false}" != "true" ]]; then
        validate_runtime_image "$arch" "$final_tag"
    fi

    # Push if requested
    if [[ "$PUSH" == "true" ]]; then
        log "Pushing ${final_tag}"
        docker push "$final_tag"
    fi

    # Cleanup: remove extractor image and tar (large, not needed anymore)
    docker rmi "$extractor_tag" >/dev/null 2>&1 || true
    rm -rf "${output_dir}" 2>/dev/null || true

    log "=== Completed linux/${arch} ==="
}

# --- Publish manifests (fixed logic for multi-arch, Finding 4.3) ---
publish_manifests() {
    if [[ "$PUSH" != "true" ]]; then
        warn "PUSH=false, skipping remote publish step"
        return
    fi

    if (( ${#arch_image_tags[@]} == 0 )); then
        warn "No images were built; skipping publish step"
        return
    fi

    if (( ${#arch_image_tags[@]} == 1 )); then
        log "Publishing single-arch tags ${IMAGE_NAME}:${VERSION} and ${IMAGE_NAME}:latest"
        docker tag "${arch_image_tags[0]}" "${IMAGE_NAME}:${VERSION}"
        docker tag "${arch_image_tags[0]}" "${IMAGE_NAME}:latest"
        docker push "${IMAGE_NAME}:${VERSION}"
        docker push "${IMAGE_NAME}:latest"
        return
    fi

    # Multi-arch: create and push manifest
    log "Creating multi-arch manifest for ${#arch_image_tags[@]} images"
    docker manifest create "${IMAGE_NAME}:${VERSION}" "${arch_image_tags[@]}" --amend || true
    docker manifest create "${IMAGE_NAME}:latest" "${arch_image_tags[@]}" --amend || true
    docker manifest push "${IMAGE_NAME}:${VERSION}"
    docker manifest push "${IMAGE_NAME}:latest"
}

main() {
    require_cmd docker
    require_cmd grep
    require_cmd sed
    require_cmd jq

    load_config
    validate_requested_platforms

    log "=== UniFi OS Server Build (lemker-style extraction) ==="
    log "Version: ${VERSION}"
    log "Platforms: ${PLATFORMS}"
    log "Push: ${PUSH}"

    for platform in "${requested_platforms[@]}"; do
        local arch="${platform#linux/}"
        local installer_url
        installer_url="$(installer_url_for_arch "$arch")"
        build_arch_image "$arch" "$installer_url"
    done

    publish_manifests

    log "=== Build complete ==="
    if [[ "$PUSH" == "true" ]]; then
        log "Pushed: ${IMAGE_NAME}:${VERSION}"
        log "Pushed: ${IMAGE_NAME}:latest"
    else
        log "Local images: ${arch_image_tags[*]}"
    fi

    # Print image size comparison
    log "Final image size:"
    docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" | grep -E "^${IMAGE_NAME}:${VERSION}" || true
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    cat <<EOF
Build UniFi OS Server by extracting the inner uosserver image from the Ubiquiti installer.

This produces a ~800MB image (vs ~1.6GB with the installer-in-image approach).

Usage:
    ./build.sh

Environment variables:
    UNIFI_OS_URL_X64       amd64 installer URL (required)
    IMAGE_NAME             Target image name (default: giiibates/unifi-os-server)
    VERSION                Override version tag; otherwise derived from URL
    PLATFORMS              Target platforms (default: linux/amd64)
    PUSH                   Push images (default: true)
    SKIP_VALIDATION        Skip runtime validation (default: false)
    KEEP_FAILED_ARTIFACTS  Keep containers/logs on failure (default: false)
    BUILD_ARTIFACTS_DIR    Directory for failure artifacts (default: ./build-artifacts)

The build process:
    1. Builds an extractor image that runs the Ubiquiti installer
    2. Extracts the inner uosserver OCI image from podman storage
    3. Builds a runtime image that runs systemd directly (no nested podman)
    4. Validates the runtime image starts correctly
    5. Pushes to registry if PUSH=true
EOF
    exit 0
fi

main "$@"
