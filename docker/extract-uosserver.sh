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

validate_installer_url() {
    local url="$1"
    local host

    # Reject empty, multiline, or whitespace-containing URLs
    case "$url" in
        ""|*$'\n'*|*$'\r'*|*" "*)
            error "Invalid UOS_INSTALLER_URL"
            ;;
    esac

    # Must start with https://
    [[ "$url" =~ ^https:// ]] || error "UOS_INSTALLER_URL must use https://"

    # Extract host from URL: strip scheme, then take everything before first /
    host="${url#https://}"
    host="${host%%/*}"
    host="${host%%:*}"  # Remove port if present

    # Validate host against allowlist (exact match or subdomain of ui.com)
    case "$host" in
        ui.com|dl.ui.com|fw-download.ubnt.com)
            ;;
        *.ui.com)
            # Verify it's actually a subdomain, not a suffix match
            [[ "$host" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.ui\.com$ ]] || \
                error "Unexpected installer URL host: $host"
            ;;
        *)
            error "Unexpected installer URL host: $host"
            ;;
    esac
}

# Check required env var
if [[ -z "$UOS_INSTALLER_URL" ]]; then
    error "UOS_INSTALLER_URL environment variable is required"
fi

validate_installer_url "$UOS_INSTALLER_URL"

# Check output directory is mounted
if [[ ! -d "$OUTPUT_DIR" ]]; then
    error "Output directory $OUTPUT_DIR is not mounted. Mount it with -v /host/path:/output"
fi

# Download installer if not present
if [[ ! -x "$INSTALLER_PATH" ]]; then
    log "Downloading installer from $UOS_INSTALLER_URL"
    curl --fail --silent --show-error --location \
        --connect-timeout 10 \
        --max-time 300 \
        --retry 3 \
        --retry-all-errors \
        -o "$INSTALLER_PATH" \
        "$UOS_INSTALLER_URL"
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
    error "Podman storage not found"
fi

log "Using podman storage: $STORAGE_BASE"

# IMAGE-AWARE MONITORING: Poll for uosserver image instead of waiting for podman to exit
# The installer may start a runtime container that hangs on systemd - we don't need to wait for it
log "Polling for uosserver image (image-aware monitoring)..."
IMAGE_FOUND=false
PREV_SIZE=0
STABLE_COUNT=0
MAX_WAIT=300  # 5 minutes max

for (( waited=0; waited < MAX_WAIT; waited+=5 )); do
    # Check if uosserver image exists
    IMAGE_NAME=$(podman --root "$STORAGE_BASE" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E '^(localhost/)?uosserver:' | head -1 || true)
    
    if [[ -n "$IMAGE_NAME" ]]; then
        # Image found! Now wait for storage to stabilize
        STORAGE_SIZE=$(du -sm "$STORAGE_BASE" 2>/dev/null | cut -f1 || echo "0")
        log "Found image: $IMAGE_NAME (storage: ${STORAGE_SIZE}MB)"
        
        if (( STORAGE_SIZE > 1000 && STORAGE_SIZE == PREV_SIZE )); then
            STABLE_COUNT=$((STABLE_COUNT + 1))
            if (( STABLE_COUNT >= 3 )); then
                log "Image found and storage stable at ${STORAGE_SIZE}MB"
                IMAGE_FOUND=true
                break
            fi
        else
            STABLE_COUNT=0
        fi
        PREV_SIZE=$STORAGE_SIZE
    else
        # Image not found yet - show progress
        if (( waited % 30 == 0 )); then
            log "Waiting for uosserver image... (${waited}s/${MAX_WAIT}s)"
            podman --root "$STORAGE_BASE" images 2>/dev/null || true
        fi
    fi
    
    sleep 5
done

if [[ "$IMAGE_FOUND" != "true" ]]; then
    log "ERROR: uosserver image not found after ${MAX_WAIT}s"
    log "Available images:"
    podman --root "$STORAGE_BASE" images 2>/dev/null || true
    log "Active podman processes:"
    ps aux | grep -E '[p]odman' || true
    log "Storage contents:"
    ls -la "$STORAGE_BASE/" 2>/dev/null || true
    error "Installer did not produce uosserver image"
fi

# Stop any running containers before export (installer may have started runtime)
log "Stopping any installer-started containers..."
podman --root "$STORAGE_BASE" ps -q 2>/dev/null | xargs -r podman --root "$STORAGE_BASE" stop -t 5 2>/dev/null || true
pkill -TERM -f 'podman.*run' 2>/dev/null || true
sleep 3

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

# Check specifically for missing repositories file (Docker requires it)
if ! echo "$ARCHIVE_FILES" | grep -q '^repositories$'; then
    log "WARNING: Archive missing repositories file - attempting repair"
    
    TEMP_EXTRACT=$(mktemp -d)
    
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
                
                # Repack to temporary file first (preserve original on failure)
                REPACKED_TAR="${OUTPUT_TAR}.repacked"
                if tar -cf "$REPACKED_TAR" -C "$TEMP_EXTRACT" .; then
                    mv -f "$REPACKED_TAR" "$OUTPUT_TAR"
                    TAR_SIZE_MB=$(stat -c%s "$OUTPUT_TAR" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
                    log "Repacked archive: ${TAR_SIZE_MB}MB"
                else
                    rm -f "$REPACKED_TAR"
                    log "WARNING: Repack failed, keeping original archive"
                fi
            fi
        fi
    fi

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
