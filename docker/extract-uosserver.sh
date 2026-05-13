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
"$INSTALLER_PATH" --non-interactive --force-install &
INSTALLER_PID=$!

# Wait for installer process to complete
log "Waiting for installer process (PID: $INSTALLER_PID) to complete..."
wait $INSTALLER_PID || true
log "Installer process finished"

# Wait for any remaining podman processes (installer may spawn background jobs)
log "Waiting for background podman processes..."
for i in {1..30}; do
    PODMAN_PROCS=$(pgrep -c podman 2>/dev/null || echo "0")
    if (( PODMAN_PROCS == 0 )); then
        log "No more podman processes running"
        break
    fi
    log "Still $PODMAN_PROCS podman process(es) running, waiting... (${i}/30)"
    sleep 5
done

# Additional settle time
log "Waiting for filesystem to settle..."
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
MAX_WAIT=300
WAITED=0
PREV_SIZE=0
STABLE_COUNT=0
while (( WAITED < MAX_WAIT )); do
    # Check total size of storage directory
    STORAGE_SIZE=$(du -sm "$STORAGE_BASE" 2>/dev/null | cut -f1 || echo "0")
    
    if (( STORAGE_SIZE > 1000 )); then
        log "Storage size: ${STORAGE_SIZE}MB"
        if (( STORAGE_SIZE == PREV_SIZE )); then
            STABLE_COUNT=$((STABLE_COUNT + 1))
            if (( STABLE_COUNT >= 3 )); then
                log "Storage size stable at ${STORAGE_SIZE}MB for 15s"
                break
            fi
        else
            STABLE_COUNT=0
        fi
        PREV_SIZE=$STORAGE_SIZE
    else
        log "Storage size: ${STORAGE_SIZE}MB (waiting for >1000MB)..."
    fi
    
    sleep 5
    WAITED=$((WAITED + 5))
done

if (( STORAGE_SIZE < 1000 )); then
    log "WARNING: Storage size only ${STORAGE_SIZE}MB after ${MAX_WAIT}s wait"
fi

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
# Strategy: Try multiple methods since podman save --format docker-archive
# can produce incompatible archives on some architectures
OUTPUT_TAR="${OUTPUT_DIR}/uosserver.tar"
OCI_TAR="${OUTPUT_DIR}/uosserver-oci.tar"
log "Exporting image to $OUTPUT_TAR (this may take a while)..."

# Method 1: Save as OCI, convert to docker-archive with skopeo
# This is the most reliable method for cross-platform Docker compatibility
log "Saving image as OCI format first..."
if podman --root "$STORAGE_BASE" save --format oci-archive -o "$OCI_TAR" "$IMAGE_NAME"; then
    log "OCI archive created, converting to docker-archive with skopeo..."
    if skopeo copy "oci-archive:$OCI_TAR" "docker-archive:$OUTPUT_TAR:$IMAGE_NAME"; then
        log "skopeo conversion succeeded"
        rm -f "$OCI_TAR"
    else
        log "skopeo conversion failed, falling back to podman save"
        rm -f "$OCI_TAR"
        podman --root "$STORAGE_BASE" save --format docker-archive -o "$OUTPUT_TAR" "$IMAGE_NAME"
    fi
else
    # Method 2: Direct podman save as docker-archive (may fail on arm64)
    log "OCI save failed, trying direct docker-archive..."
    podman --root "$STORAGE_BASE" save --format docker-archive -o "$OUTPUT_TAR" "$IMAGE_NAME"
fi

# Verify the export
TAR_SIZE=$(stat -c%s "$OUTPUT_TAR" 2>/dev/null || echo "0")
TAR_SIZE_MB=$((TAR_SIZE / 1024 / 1024))
log "Exported tar size: ${TAR_SIZE_MB}MB"

if (( TAR_SIZE_MB < 500 )); then
    log "ERROR: Exported image is too small (${TAR_SIZE_MB}MB, expected >1500MB)"
    log "Tar contents:"
    tar -tvf "$OUTPUT_TAR" 2>/dev/null | head -20 || true
    log "This usually means the image import was not complete."
    log "Storage directory size: $(du -sh "$STORAGE_BASE" 2>/dev/null || echo 'unknown')"
    error "Image export failed - incomplete image"
fi

# Verify docker-archive format has required structure
log "Verifying tar archive format..."
ARCHIVE_FILES=$(tar -tf "$OUTPUT_TAR" 2>/dev/null | head -20)
echo "$ARCHIVE_FILES"

if ! echo "$ARCHIVE_FILES" | grep -qE '^(manifest\.json|repositories)$'; then
    log "WARNING: Archive missing manifest.json/repositories - attempting repair"
    
    TEMP_EXTRACT=$(mktemp -d)
    trap "rm -rf '$TEMP_EXTRACT'" EXIT
    
    tar -xf "$OUTPUT_TAR" -C "$TEMP_EXTRACT"
    log "Extracted archive contents:"
    ls -la "$TEMP_EXTRACT"
    
    # If we have manifest.json but no repositories, Docker should still work
    # But some older Docker versions need repositories, so create it
    if [[ -f "$TEMP_EXTRACT/manifest.json" ]] && [[ ! -f "$TEMP_EXTRACT/repositories" ]]; then
        log "Creating repositories file from manifest.json for compatibility"
        REPO_TAG=$(jq -r '.[0].RepoTags[0] // empty' "$TEMP_EXTRACT/manifest.json" 2>/dev/null || true)
        if [[ -n "$REPO_TAG" ]]; then
            REPO_NAME="${REPO_TAG%%:*}"
            TAG_NAME="${REPO_TAG##*:}"
            CONFIG_FILE=$(jq -r '.[0].Config // empty' "$TEMP_EXTRACT/manifest.json" 2>/dev/null || true)
            if [[ -n "$CONFIG_FILE" ]]; then
                LAYER_ID="${CONFIG_FILE%.json}"
                LAYER_ID="${LAYER_ID#sha256:}"
                printf '{\"%s\":{\"%s\":\"%s\"}}\n' "$REPO_NAME" "$TAG_NAME" "$LAYER_ID" > "$TEMP_EXTRACT/repositories"
                log "Created repositories file"
                
                # Repack
                rm -f "$OUTPUT_TAR"
                tar -cf "$OUTPUT_TAR" -C "$TEMP_EXTRACT" .
                TAR_SIZE_MB=$(stat -c%s "$OUTPUT_TAR" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
                log "Repacked archive: ${TAR_SIZE_MB}MB"
            fi
        fi
    fi
    
    trap - EXIT
    rm -rf "$TEMP_EXTRACT"
fi

# Final verification
log "Final archive verification:"
tar -tf "$OUTPUT_TAR" | grep -E '^(manifest\.json|repositories|[a-f0-9]+\.json|[a-f0-9]+/layer\.tar)' | head -10

# Also save the image tag for the build script
echo "$IMAGE_NAME" > "${OUTPUT_DIR}/image-tag.txt"

log "Extraction complete!"
log "Image exported to: $OUTPUT_TAR"
log "Image tag: $IMAGE_NAME"
