#!/bin/bash
# Runs inside the extractor container to:
# 1. Download and run the Ubiquiti installer (will fail at container start)
# 2. Export the extracted uosserver image to /output/uosserver.tar
set -e

INSTALLER_PATH="/opt/uos/installer/uos-installer"
OUTPUT_DIR="/output"
MIN_EXPORT_SIZE_MB=500
TEMP_EXTRACT=""

log() {
    printf '[extract] %s\n' "$*"
}

error() {
    printf '[extract] ERROR: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_EXTRACT" && -d "$TEMP_EXTRACT" ]]; then
        rm -rf "$TEMP_EXTRACT"
    fi
}

wait_for_storage_stable() {
    local storage_base="$1"
    local previous_size="${2:-0}"
    local stable_count=0
    local current_size=0

    for (( settle=0; settle < 20; settle+=2 )); do
        current_size=$(du -sm "$storage_base" 2>/dev/null | cut -f1 || echo "0")
        if (( current_size > 1000 && current_size == previous_size )); then
            stable_count=$((stable_count + 1))
            if (( stable_count >= 2 )); then
                log "Storage settled at ${current_size}MB after installer stop"
                return 0
            fi
        else
            stable_count=0
        fi
        previous_size=$current_size
        sleep 2
    done

    log "Storage did not fully settle after installer stop (last size: ${previous_size}MB)"
    return 1
}

trap cleanup EXIT

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
            # The case arm enforces the suffix; this regex keeps labels sane.
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
log "Installer started (PID: $INSTALLER_PID)"

# IMAGE-AWARE MONITORING: Poll for uosserver image WHILE installer runs
# The installer may try to start a runtime container that hangs on systemd - we don't need to wait for it
# Once we have the image, we can kill the installer and export.

# First, we need to find the storage path - poll for it to appear
log "Waiting for podman storage to be created..."
STORAGE_PATHS=(
    "/home/uosserver/.local/share/containers/storage"
    "/var/lib/containers/storage"
    "/root/.local/share/containers/storage"
)

STORAGE_BASE=""
for (( wait_storage=0; wait_storage < 120; wait_storage+=5 )); do
    for path in "${STORAGE_PATHS[@]}"; do
        if [[ -d "$path/overlay-images" ]]; then
            STORAGE_BASE="$path"
            break 2
        fi
    done
    
    # Also search dynamically
    STORAGE_BASE=$(find /home -name "overlay-images" -type d 2>/dev/null | head -1 | sed 's|/overlay-images$||' || true)
    [[ -n "$STORAGE_BASE" ]] && break
    
    # Check if installer is still running
    if ! kill -0 "$INSTALLER_PID" 2>/dev/null; then
        log "Installer exited before storage was found"
        break
    fi
    
    sleep 5
done

if [[ -z "$STORAGE_BASE" || ! -d "$STORAGE_BASE" ]]; then
    log "Podman storage locations searched:"
    for path in "${STORAGE_PATHS[@]}"; do
        ls -la "$path" 2>/dev/null || echo "  $path: not found"
    done
    log "Home directory contents:"
    ls -la /home/ 2>/dev/null || true
    # Wait for installer to finish and check exit code
    wait "$INSTALLER_PID" 2>/dev/null || true
    error "Podman storage not found"
fi

log "Using podman storage: $STORAGE_BASE"

# Now poll for the uosserver image while installer is still running
log "Polling for uosserver image (parallel to installer)..."
IMAGE_FOUND=false
PREV_SIZE=0
STABLE_COUNT=0
MAX_WAIT=300  # 5 minutes max
IMAGE_NAME=""

for (( waited=0; waited < MAX_WAIT; waited+=5 )); do
    # Check if uosserver image exists (matches all variants: uosserver:, localhost/uosserver:, docker.io/library/uosserver:)
    IMAGE_NAME=$(podman --root "$STORAGE_BASE" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E '(^|/)uosserver:' | head -1 || true)
    
    if [[ -n "$IMAGE_NAME" ]]; then
        # Image found! Now wait for storage to stabilize
        STORAGE_SIZE=$(du -sm "$STORAGE_BASE" 2>/dev/null | cut -f1 || echo "0")
        log "Found image: $IMAGE_NAME (storage: ${STORAGE_SIZE}MB)"
        
        if (( STORAGE_SIZE > 1000 && STORAGE_SIZE == PREV_SIZE )); then
            STABLE_COUNT=$((STABLE_COUNT + 1))
            if (( STABLE_COUNT >= 3 )); then
                log "Image found and storage stable at ${STORAGE_SIZE}MB"
                IMAGE_FOUND=true
                # Kill installer - we have what we need
                log "Terminating installer (image acquired)..."
                kill -TERM "$INSTALLER_PID" 2>/dev/null || true
                sleep 2
                kill -KILL "$INSTALLER_PID" 2>/dev/null || true
                wait_for_storage_stable "$STORAGE_BASE" "$STORAGE_SIZE" || true
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
    
    # Check if installer exited (maybe it crashed)
    if ! kill -0 "$INSTALLER_PID" 2>/dev/null; then
        log "Installer exited - checking if image was created..."
        # Final check for image
        IMAGE_NAME=$(podman --root "$STORAGE_BASE" images --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | grep -E '(^|/)uosserver:' | head -1 || true)
        if [[ -n "$IMAGE_NAME" ]]; then
            log "Found image after installer exit: $IMAGE_NAME"
            IMAGE_FOUND=true
        fi
        break
    fi
    
    sleep 5
done

# Clean up installer process
wait "$INSTALLER_PID" 2>/dev/null || true

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
    # Use simpler image name for docker-archive (some Docker versions are picky)
    SIMPLE_IMAGE_NAME="uosserver:extracted"
    if skopeo copy "oci-archive:$OCI_TAR" "docker-archive:$OUTPUT_TAR:$SIMPLE_IMAGE_NAME"; then
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

if (( TAR_SIZE_MB < MIN_EXPORT_SIZE_MB )); then
    log "ERROR: Exported image is too small (${TAR_SIZE_MB}MB, expected >=${MIN_EXPORT_SIZE_MB}MB)"
    log "Tar contents:"
    tar -tvf "$OUTPUT_TAR" 2>/dev/null | head -20 || true
    log "This usually means the image import was not complete."
    log "Storage directory size: $(du -sh "$STORAGE_BASE" 2>/dev/null || echo 'unknown')"
    error "Image export failed - incomplete image"
fi

# Verify docker-archive format has required structure
log "Verifying tar archive format..."
ARCHIVE_FILES=$(tar -tf "$OUTPUT_TAR" 2>/dev/null | head -20 || true)
echo "$ARCHIVE_FILES"

# Check specifically for missing repositories file (Docker requires it on some versions)
# Use full tar listing for this check, not just head -20
if ! tar -tf "$OUTPUT_TAR" 2>/dev/null | grep -q '^repositories$'; then
    log "WARNING: Archive missing repositories file - attempting repair"
    
    TEMP_EXTRACT=$(mktemp -d)
    
    log "Extracting archive for repair (this may take a minute on arm64)..."
    if ! tar -xf "$OUTPUT_TAR" -C "$TEMP_EXTRACT"; then
        log "ERROR: Failed to extract archive for repair"
        rm -rf "$TEMP_EXTRACT"
        TEMP_EXTRACT=""
        error "Archive extraction failed"
    fi
    
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
                printf '{"%s":{"%s":"%s"}}\n' "$REPO_NAME" "$TAG_NAME" "$LAYER_ID" > "$TEMP_EXTRACT/repositories"
                log "Created repositories file: $(cat "$TEMP_EXTRACT/repositories")"
                
                # Repack to temporary file first (preserve original on failure)
                REPACKED_TAR="${OUTPUT_TAR}.repacked"
                log "Repacking archive (this may take a minute on arm64)..."
                if tar -cf "$REPACKED_TAR" -C "$TEMP_EXTRACT" .; then
                    # Sync to ensure all writes are flushed before rename
                    sync
                    mv -f "$REPACKED_TAR" "$OUTPUT_TAR"
                    sync
                    TAR_SIZE_MB=$(stat -c%s "$OUTPUT_TAR" 2>/dev/null | awk '{printf "%.0f", $1/1024/1024}')
                    log "Repacked archive: ${TAR_SIZE_MB}MB"
                else
                    rm -f "$REPACKED_TAR"
                    log "ERROR: Repack failed, keeping original archive"
                fi
            else
                log "ERROR: Could not parse Config from manifest.json"
            fi
        else
            log "ERROR: Could not parse RepoTags from manifest.json"
        fi
    elif [[ ! -f "$TEMP_EXTRACT/manifest.json" ]]; then
        log "ERROR: Archive has no manifest.json - not a valid docker-archive!"
    fi

    rm -rf "$TEMP_EXTRACT"
    TEMP_EXTRACT=""
fi

# Final verification
log "Final archive verification:"
tar -tf "$OUTPUT_TAR" 2>/dev/null | grep -E '^(manifest\.json|repositories|[a-f0-9]+\.json|[a-f0-9]+/layer\.tar)' | head -10 || true

# Also save the image tag for the build script
echo "$IMAGE_NAME" > "${OUTPUT_DIR}/image-tag.txt"

log "Extraction complete!"
log "Image exported to: $OUTPUT_TAR"
log "Image tag: $IMAGE_NAME"
