#!/usr/bin/env bash
# Build fully installed UniFi OS Server images from environment-provided installer URLs.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
IMAGE_NAME="${IMAGE_NAME:-giiibates/unifi-os-server}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
PUSH="${PUSH:-true}"
BUILDER_NAME="${BUILDER_NAME:-uos-preinstall-builder}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-1800}"
POLL_INTERVAL_SECONDS="${POLL_INTERVAL_SECONDS:-15}"
BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
VERSION="${VERSION:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf '[build] This script must be executed, not sourced. Use ./build.sh or bash ./build.sh.\n' >&2
    return 1 2>/dev/null || exit 1
fi

amd64_url=""
declare -a requested_platforms=()
declare -a arch_image_tags=()
declare -a cleanup_containers=()

host_arch() {
    case "$(uname -m)" in
        x86_64|amd64)
            printf 'amd64\n'
            ;;
        *)
            printf 'unknown\n'
            ;;
    esac
}

validate_requested_platforms() {
    local native_arch
    local platform
    local requested_arch

    native_arch="$(host_arch)"

    [[ "$native_arch" == "amd64" ]] || error "This project currently supports only linux/amd64 release builds. Run the build on a native amd64 host or runner."

    for platform in "${requested_platforms[@]}"; do
        requested_arch="${platform#linux/}"
        [[ "$requested_arch" == "amd64" ]] || error "Unsupported platform: ${platform}. This project is currently amd64-only."
    done
}

log() {
    echo -e "${GREEN}[build]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[warn]${NC} $*"
}

error() {
    echo -e "${RED}[error]${NC} $*" >&2
    exit 1
}

cleanup() {
    local exit_code="$1"

    trap - EXIT

    for container_name in "${cleanup_containers[@]}"; do
        [[ -n "$container_name" ]] || continue
        docker rm -f "$container_name" >/dev/null 2>&1 || true
    done

    exit "$exit_code"
}

trap 'cleanup $?' EXIT

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || error "Missing required command: $1"
}

extract_version_from_url() {
    local url="$1"
    local version

    version="$(sed -E 's|.*-([0-9]+\.[0-9]+\.[0-9]+)-.*|\1|' <<<"$url")"
    [[ -n "$version" && "$version" != "$url" ]] || error "Could not derive version from URL: $url"
    printf '%s\n' "$version"
}

format_duration() {
    local total_seconds="$1"
    local hours minutes seconds

    (( total_seconds >= 0 )) || total_seconds=0

    hours=$((total_seconds / 3600))
    minutes=$(((total_seconds % 3600) / 60))
    seconds=$((total_seconds % 60))

    if (( hours > 0 )); then
        printf '%dh %02dm %02ds' "$hours" "$minutes" "$seconds"
    elif (( minutes > 0 )); then
        printf '%dm %02ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

truncate_progress_line() {
    local line="$1"
    local max_length=160

    line="${line//$'\r'/}"
    if (( ${#line} > max_length )); then
        printf '%s...' "${line:0:max_length}"
        return
    fi

    printf '%s' "$line"
}

load_config() {
    amd64_url="${UNIFI_OS_URL_X64:-}"

    [[ -n "$amd64_url" ]] || error "UNIFI_OS_URL_X64 is required"

    if [[ -z "$VERSION" ]]; then
        VERSION="$(extract_version_from_url "$amd64_url")"
    fi

    IFS=',' read -r -a requested_platforms <<<"$PLATFORMS"
}

check_buildx() {
    docker buildx version >/dev/null 2>&1 || error "Docker Buildx is required"
}

setup_binfmt() {
    return 0
}

setup_builder() {
    if docker buildx inspect "$BUILDER_NAME" >/dev/null 2>&1; then
        log "Using existing buildx builder: $BUILDER_NAME"
        docker buildx use "$BUILDER_NAME" >/dev/null
    else
        log "Creating buildx builder: $BUILDER_NAME"
        docker buildx create \
            --name "$BUILDER_NAME" \
            --driver docker-container \
            --use >/dev/null
    fi

    docker buildx inspect --bootstrap >/dev/null
}

installer_url_for_arch() {
    local arch="$1"

    case "$arch" in
        amd64)
            printf '%s\n' "$amd64_url"
            ;;
        *)
            error "Unsupported architecture: $arch"
            ;;
    esac
}

build_base_image() {
    local arch="$1"
    local base_tag="$2"

    log "Building base image for linux/${arch}"
    docker buildx build \
        --builder "$BUILDER_NAME" \
        --platform "linux/${arch}" \
        --file "${REPO_ROOT}/docker/Dockerfile" \
        --load \
        --tag "$base_tag" \
        --build-arg "APP_VERSION=${VERSION}" \
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        --build-arg "UOS_INSTALLER_URL_AMD64=${amd64_url}" \
        "$REPO_ROOT"
}

wait_for_installation() {
    local container_name="$1"
    local arch="$2"
    local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
    local started_at="$SECONDS"
    local elapsed_seconds remaining_seconds
    local latest_log_line=""
    local last_reported_log_line=""

    while (( SECONDS < deadline )); do
        if ! docker ps --format '{{.Names}}' | grep -Fxq "$container_name"; then
            docker logs "$container_name" | tail -n 200 >&2 || true
            error "Install container for ${arch} exited before installation completed"
        fi

        if docker exec "$container_name" sh -c 'test -f /run/uos-installer.done' >/dev/null 2>&1; then
            log "Installation finished for linux/${arch}"
            return 0
        fi

        elapsed_seconds=$((SECONDS - started_at))
        remaining_seconds=$((deadline - SECONDS))
        latest_log_line="$(docker logs "$container_name" 2>&1 | tail -n 1 || true)"
        latest_log_line="$(truncate_progress_line "$latest_log_line")"

        if [[ -n "$latest_log_line" && "$latest_log_line" != "$last_reported_log_line" ]]; then
            log "Installer progress on linux/${arch}: elapsed $(format_duration "$elapsed_seconds"), remaining $(format_duration "$remaining_seconds"), latest output: ${latest_log_line}"
            last_reported_log_line="$latest_log_line"
        else
            log "Installer progress on linux/${arch}: elapsed $(format_duration "$elapsed_seconds"), remaining $(format_duration "$remaining_seconds"), no new installer output yet"
        fi

        sleep "$POLL_INTERVAL_SECONDS"
    done

    docker logs "$container_name" | tail -n 200 >&2 || true
    error "Timed out waiting for installer on linux/${arch}"
}

install_arch_image() {
    local arch="$1"
    local installer_url="$2"
    local base_tag="${IMAGE_NAME}:base-${VERSION}-${arch}"
    local final_tag="${IMAGE_NAME}:${VERSION}-${arch}"
    local container_name="uos-preinstall-${arch}-$$"
    build_base_image "$arch" "$base_tag"

    log "Running privileged install container for linux/${arch}"
    docker run -d \
        --platform "linux/${arch}" \
        --name "$container_name" \
        --privileged \
        --cgroupns=host \
        --tmpfs /run:exec \
        --tmpfs /run/lock \
        --tmpfs /tmp:exec \
        --tmpfs /var/tmp:exec \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
        -e UOS_INSTALLER_URL="$installer_url" \
        -e UOS_INSTALL_ON_BOOT=1 \
        -e UOS_FORCE_INSTALL=1 \
        "$base_tag" >/dev/null

    cleanup_containers+=("$container_name")

    wait_for_installation "$container_name" "$arch"

    log "Stopping install container for linux/${arch}"
    docker stop -t 120 "$container_name" >/dev/null

    log "Committing installed image ${final_tag}"
    docker commit \
        --change 'ENV UOS_INSTALL_ON_BOOT=0' \
        --change 'ENV UOS_FORCE_INSTALL=0' \
        --change "LABEL org.opencontainers.image.version=${VERSION}" \
        --change "LABEL org.opencontainers.image.created=${BUILD_DATE}" \
        "$container_name" \
        "$final_tag" >/dev/null

    arch_image_tags+=("$final_tag")

    if [[ "$PUSH" == "true" ]]; then
        log "Pushing ${final_tag}"
        docker push "$final_tag"
    fi

    docker rm "$container_name" >/dev/null
}

publish_manifests() {
    if [[ "$PUSH" != "true" ]]; then
        warn "PUSH=false, skipping remote publish step"
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

    warn "No image was built; skipping publish step"
}

main() {
    local platform
    local arch
    local installer_url

    require_cmd docker
    require_cmd grep
    require_cmd sed

    load_config
    validate_requested_platforms

    log "Using installer URL from UNIFI_OS_URL_X64"
    log "Version: ${VERSION}"
    log "Platforms: ${PLATFORMS}"
    log "Push: ${PUSH}"

    check_buildx
    setup_binfmt
    setup_builder

    for platform in "${requested_platforms[@]}"; do
        arch="${platform#linux/}"
        installer_url="$(installer_url_for_arch "$arch")"
        install_arch_image "$arch" "$installer_url"
    done

    publish_manifests

    log "Build complete"
    if [[ "$PUSH" == "true" ]]; then
        log "Pushed runtime image: ${IMAGE_NAME}:${VERSION}"
        log "Pushed runtime image: ${IMAGE_NAME}:latest"
    else
        log "Local architecture images: ${arch_image_tags[*]}"
    fi
}

if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    cat <<EOF
Builds a fully installed UniFi OS Server image from installer URLs provided via environment variables.

Usage:
        ./build.sh

Environment variables:
    UNIFI_OS_URL_X64      amd64 installer URL (required)
    UNIFI_OS_URL_ARM64    Reserved for a future arm64 build path
  IMAGE_NAME             Target image name (default: giiibates/unifi-os-server)
  VERSION                Override version tag; otherwise derived from amd64 URL
  PLATFORMS              Comma-separated target platforms (default: linux/amd64)
  PUSH                   Push image tags (default: true)
  WAIT_TIMEOUT_SECONDS   Installer timeout per arch (default: 1800)

The script builds a base image, runs the installer in a privileged container,
commits the installed result, and publishes tags for the built architecture.

The active release path is currently limited to linux/amd64 on a native amd64 runner.
EOF
    exit 0
fi

main "$@"
