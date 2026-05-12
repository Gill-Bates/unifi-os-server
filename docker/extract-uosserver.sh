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

# Wait for installer to complete image import
# The installer runs podman in background, so we need to wait
log "Waiting for podman image import to complete..."
sleep 10

# Find the uosserver storage directory
# The installer creates a uosserver user and runs podman as that user
STORAGE_PATHS=(
    "/home/uosserver/.local/share/containers/storage"
    "/var/lib/containers/storage"
    "/root/.local/share/containers/storage"
)

STORAGE_BASE=""
for path in "${STORAGE_PATHS[@]}"; do
    if [[ -d "$path/overlay-images" ]]; then
        log "Found podman storage at: $path"
        STORAGE_BASE="$path"
        break
    fi
done

if [[ -z "$STORAGE_BASE" ]]; then
    log "Searching for podman storage..."
    STORAGE_BASE=$(find /home -name "overlay-images" -type d 2>/dev/null | head -1 | sed 's|/overlay-images$||' || true)
    if [[ -z "$STORAGE_BASE" ]]; then
        STORAGE_BASE=$(find /var/lib -name "overlay-images" -type d 2>/dev/null | head -1 | sed 's|/overlay-images$||' || true)
    fi
fi

if [[ -z "$STORAGE_BASE" || ! -d "$STORAGE_BASE" ]]; then
    log "Podman storage locations searched:"
    for path in "${STORAGE_PATHS[@]}"; do
        ls -la "$path" 2>/dev/null || echo "  $path: not found"
    done
    log "Home directory contents:"
    ls -la /home/ 2>/dev/null || true
    if [[ -d /home/uosserver ]]; then
        ls -la /home/uosserver/ 2>/dev/null || true
        ls -la /home/uosserver/.local/share/containers/ 2>/dev/null || true
    fi
    error "Podman storage not found"
fi

log "Using podman storage: $STORAGE_BASE"

# Wait for image to be fully written
# Check that overlay-images has content and isn't still being written
log "Waiting for image data to be complete..."
MAX_WAIT=120
WAITED=0
while (( WAITED < MAX_WAIT )); do
    # Count layers in storage
    LAYER_COUNT=$(find "$STORAGE_BASE/overlay" -maxdepth 1 -type d 2>/dev/null | wc -l)
    if (( LAYER_COUNT > 10 )); then
        log "Found $LAYER_COUNT layers, checking if stable..."
        sleep 5
        NEW_COUNT=$(find "$STORAGE_BASE/overlay" -maxdepth 1 -type d 2>/dev/null | wc -l)
        if (( NEW_COUNT == LAYER_COUNT )); then
            log "Layer count stable at $LAYER_COUNT"
            break
        fi
    fi
    sleep 5
    WAITED=$((WAITED + 5))
    log "Waiting for image import... (${WAITED}s)"
done

# Get the image name from podman
log "Listing images in storage..."
podman --root "$STORAGE_BASE" images 2>/dev/null || true

IMAGE_NAME=$(podman --root "$STORAGE_BASE" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E '^(localhost/)?uosserver:' | head -1 || true)

if [[ -z "$IMAGE_NAME" ]]; then
    # Try without repository prefix
    IMAGE_NAME=$(podman --root "$STORAGE_BASE" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -v '<none>' | head -1 || true)
fi

if [[ -z "$IMAGE_NAME" ]]; then
    log "Available images in storage:"
    podman --root "$STORAGE_BASE" images 2>/dev/null || true
    log "Storage directory contents:"
    ls -la "$STORAGE_BASE/" 2>/dev/null || true
    ls -la "$STORAGE_BASE/overlay-images/" 2>/dev/null || true
    error "No uosserver image found in podman storage"
fi

log "Found image: $IMAGE_NAME"

# Get image size to verify it's complete
IMAGE_SIZE=$(podman --root "$STORAGE_BASE" images --format "{{.Size}}" "$IMAGE_NAME" 2>/dev/null || echo "unknown")
log "Image size: $IMAGE_SIZE"

# Export the image in Docker-compatible format
OUTPUT_TAR="${OUTPUT_DIR}/uosserver.tar"
log "Exporting image to $OUTPUT_TAR (this may take a while)..."

# Use --format docker-archive for Docker compatibility
podman --root "$STORAGE_BASE" save --format docker-archive -o "$OUTPUT_TAR" "$IMAGE_NAME"

# Verify the export
TAR_SIZE=$(stat -c%s "$OUTPUT_TAR" 2>/dev/null || echo "0")
TAR_SIZE_MB=$((TAR_SIZE / 1024 / 1024))
log "Exported tar size: ${TAR_SIZE_MB}MB"

if (( TAR_SIZE_MB < 500 )); then
    log "WARNING: Exported image is suspiciously small (${TAR_SIZE_MB}MB, expected >1500MB)"
    log "Tar contents:"
    tar -tvf "$OUTPUT_TAR" 2>/dev/null | head -20 || true
fi

# Also save the image tag for the build script
echo "$IMAGE_NAME" > "${OUTPUT_DIR}/image-tag.txt"

log "Extraction complete!"
log "Image exported to: $OUTPUT_TAR"
log "Image tag: $IMAGE_NAME"
