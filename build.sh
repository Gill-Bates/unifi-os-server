#!/usr/bin/env bash
# Multi-architecture build script for unifi-os-server
# Builds and pushes images for linux/amd64 and linux/arm64
set -euo pipefail

# Configuration
IMAGE_NAME="${IMAGE_NAME:-giiibates/unifi-os-server}"
VERSION="${VERSION:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-true}"
BUILDER_NAME="multiarch-builder"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[build]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[warn]${NC} $*"
}

error() {
    echo -e "${RED}[error]${NC} $*"
    exit 1
}

# Ensure docker buildx is available
check_buildx() {
    if ! docker buildx version &>/dev/null; then
        error "Docker Buildx is required. Please install Docker Desktop or enable Buildx."
    fi
    log "Docker Buildx is available"
}

# Create or use existing builder
setup_builder() {
    if docker buildx inspect "$BUILDER_NAME" &>/dev/null; then
        log "Using existing builder: $BUILDER_NAME"
    else
        log "Creating new builder: $BUILDER_NAME"
        docker buildx create \
            --name "$BUILDER_NAME" \
            --driver docker-container \
            --bootstrap \
            --use
    fi
    docker buildx use "$BUILDER_NAME"
}

# Build and optionally push
build_image() {
    local build_args=(
        --platform "$PLATFORMS"
        --tag "${IMAGE_NAME}:${VERSION}"
        --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        --build-arg "APP_VERSION=${VERSION}"
    )

    # Add latest tag if version is not 'latest'
    if [[ "$VERSION" != "latest" ]]; then
        build_args+=(--tag "${IMAGE_NAME}:latest")
    fi

    if [[ "$PUSH" == "true" ]]; then
        build_args+=(--push)
        log "Building and pushing ${IMAGE_NAME}:${VERSION} for ${PLATFORMS}"
    else
        build_args+=(--load)
        warn "Building locally (not pushing). Note: --load only works with single platform."
        PLATFORMS="linux/$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')"
        build_args=(
            --platform "$PLATFORMS"
            --tag "${IMAGE_NAME}:${VERSION}"
            --build-arg "BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            --build-arg "APP_VERSION=${VERSION}"
            --load
        )
    fi

    docker buildx build "${build_args[@]}" .
}

# Main
main() {
    log "Starting multi-architecture build"
    log "Image: ${IMAGE_NAME}:${VERSION}"
    log "Platforms: ${PLATFORMS}"
    log "Push: ${PUSH}"

    check_buildx
    setup_builder
    build_image

    log "Build complete!"
    
    if [[ "$PUSH" == "true" ]]; then
        log "Image pushed to Docker Hub: ${IMAGE_NAME}:${VERSION}"
        echo ""
        echo "Pull with:"
        echo "  docker pull ${IMAGE_NAME}:${VERSION}"
    fi
}

# Show help
if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
    cat <<EOF
Multi-architecture Docker build script

Usage: ./build.sh [OPTIONS]

Environment Variables:
  IMAGE_NAME    Docker image name (default: giiibates/unifi-os-server)
  VERSION       Image tag/version (default: latest)
  PLATFORMS     Target platforms (default: linux/amd64,linux/arm64)
  PUSH          Push to registry (default: true)

Examples:
  # Build and push with default settings
  ./build.sh

  # Build specific version
  VERSION=1.0.0 ./build.sh

  # Build locally without pushing
  PUSH=false ./build.sh

  # Build only for amd64
  PLATFORMS=linux/amd64 ./build.sh

EOF
    exit 0
fi

main "$@"
