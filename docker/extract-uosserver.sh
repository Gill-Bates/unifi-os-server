#!/bin/bash
# Runs inside the extractor container to:
# 1. Download and run the Ubiquiti installer (will fail at container start)
# 2. Export the extracted uosserver image to /output/uosserver.tar
set -e

INSTALLER_PATH="/opt/uos/installer/uos-installer"
OUTPUT_DIR="/output"

log() {
    printf '[extract] %s\n' "$*"
}

error() {
    printf '[extract] ERROR: %s\n' "$*" >&2
    exit 1
}

# Check required env var
if [[ -z "$UOS_INSTALLER_URL" ]]; then
    error "UOS_INSTALLER_URL environment variable is required"
fi

# Check output directory is mounted
if [[ ! -d "$OUTPUT_DIR" ]]; then
    error "Output directory $OUTPUT_DIR is not mounted. Mount it with -v /host/path:/output"
fi

# Download installer if not present
if [[ ! -x "$INSTALLER_PATH" ]]; then
    log "Downloading installer from $UOS_INSTALLER_URL"
    curl -fsSL -o "$INSTALLER_PATH" "$UOS_INSTALLER_URL"
    chmod +x "$INSTALLER_PATH"
fi

# Run installer (will fail at container start, but image is extracted)
log "Running installer (expect it to fail at container startup)..."
"$INSTALLER_PATH" --non-interactive --force-install || true

# Find the uosserver image in podman storage
STORAGE_BASE="/home/uosserver/.local/share/containers/storage"

log "Checking podman storage for extracted image..."

if [[ ! -d "$STORAGE_BASE/overlay-images" ]]; then
    error "Podman storage not found at $STORAGE_BASE"
fi

# Get the image name from podman
IMAGE_NAME=$(podman --root "$STORAGE_BASE" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E '^(localhost/)?uosserver:' | head -1 || true)

if [[ -z "$IMAGE_NAME" ]]; then
    # Try without repository prefix
    IMAGE_NAME=$(podman --root "$STORAGE_BASE" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1 || true)
fi

if [[ -z "$IMAGE_NAME" ]]; then
    log "Available images in storage:"
    podman --root "$STORAGE_BASE" images 2>/dev/null || true
    error "No uosserver image found in podman storage"
fi

log "Found image: $IMAGE_NAME"

# Export the image
OUTPUT_TAR="${OUTPUT_DIR}/uosserver.tar"
log "Exporting image to $OUTPUT_TAR"
podman --root "$STORAGE_BASE" save -o "$OUTPUT_TAR" "$IMAGE_NAME"

# Also save the image tag for the build script
echo "$IMAGE_NAME" > "${OUTPUT_DIR}/image-tag.txt"

log "Extraction complete!"
log "Image exported to: $OUTPUT_TAR"
log "Image tag: $IMAGE_NAME"
