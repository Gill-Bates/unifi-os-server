#!/usr/bin/env bash
# Build fully installed UniFi OS Server images from the installer URLs in setup.conf.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SETUP_FILE="${SETUP_FILE:-${SCRIPT_DIR}/setup.conf}"
IMAGE_NAME="${IMAGE_NAME:-giiibates/unifi-os-server}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
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

amd64_url=""
arm64_url=""
declare -a requested_platforms=()
declare -a arch_image_tags=()
declare -a cleanup_containers=()

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

load_config() {
    local urls

    [[ -f "$SETUP_FILE" ]] || error "Config file not found: $SETUP_FILE"

    mapfile -t urls < <(grep -E '^https://fw-download\.ubnt\.com/data/unifi-os-server/' "$SETUP_FILE")

    (( ${#urls[@]} >= 1 )) || error "No UniFi OS installer URLs found in $SETUP_FILE"

    amd64_url="${urls[0]}"
    arm64_url="${urls[1]:-}"

    if [[ -z "$VERSION" ]]; then
        VERSION="$(extract_version_from_url "$amd64_url")"
    fi

    IFS=',' read -r -a requested_platforms <<<"$PLATFORMS"

    if [[ " $PLATFORMS " == *"linux/arm64"* ]] && [[ -z "$arm64_url" ]]; then
        error "PLATFORMS requires linux/arm64, but setup.conf does not contain a second installer URL"
    fi
}

check_buildx() {
    docker buildx version >/dev/null 2>&1 || error "Docker Buildx is required"
}

setup_binfmt() {
    if [[ "$PLATFORMS" == *"linux/arm64"* ]]; then
        log "Ensuring arm64 emulation is available"
        docker run --privileged --rm tonistiigi/binfmt --install arm64 >/dev/null
    fi
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
        arm64)
            printf '%s\n' "$arm64_url"
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
        --load \
        --tag "$base_tag" \
        --build-arg "APP_VERSION=${VERSION}" \
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        --build-arg "UOS_INSTALLER_URL_AMD64=${amd64_url}" \
        --build-arg "UOS_INSTALLER_URL_ARM64=${arm64_url}" \
        "$SCRIPT_DIR"
}

wait_for_installation() {
    local container_name="$1"
    local arch="$2"
    local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))

    while (( SECONDS < deadline )); do
        if ! docker ps --format '{{.Names}}' | grep -Fxq "$container_name"; then
            docker logs "$container_name" | tail -n 200 >&2 || true
            error "Install container for ${arch} exited before installation completed"
        fi

        if docker exec "$container_name" sh -c 'test -x /usr/local/bin/uosserver || test -x /var/lib/uosserver/bin/uosserver-service' >/dev/null 2>&1; then
            log "Installation finished for linux/${arch}"
            return 0
        fi

        log "Waiting for installer on linux/${arch}..."
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
        warn "PUSH=false, skipping remote multi-arch manifest creation"
        return
    fi

    log "Publishing multi-arch manifest ${IMAGE_NAME}:${VERSION}"
    docker buildx imagetools create -t "${IMAGE_NAME}:${VERSION}" "${arch_image_tags[@]}" >/dev/null

    log "Publishing multi-arch manifest ${IMAGE_NAME}:latest"
    docker buildx imagetools create -t "${IMAGE_NAME}:latest" "${arch_image_tags[@]}" >/dev/null
}

main() {
    local platform
    local arch
    local installer_url

    require_cmd docker
    require_cmd grep
    require_cmd sed

    load_config

    log "Using installer URLs from ${SETUP_FILE}"
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
Builds a fully installed UniFi OS Server image from the URLs in setup.conf.

Usage:
  ./build.sh

Environment variables:
  IMAGE_NAME             Target image name (default: giiibates/unifi-os-server)
  VERSION                Override version tag; otherwise derived from amd64 URL
  PLATFORMS              Comma-separated target platforms (default: linux/amd64,linux/arm64)
  PUSH                   Push arch images and manifest lists (default: true)
  SETUP_FILE             Path to URL config (default: ./setup.conf)
  WAIT_TIMEOUT_SECONDS   Installer timeout per arch (default: 1800)

The script builds a base image, runs the installer in a privileged container,
commits the installed result, and publishes a multi-arch manifest.
EOF
    exit 0
fi

main "$@"
