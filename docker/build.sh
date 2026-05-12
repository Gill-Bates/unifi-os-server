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
# LOGGING (all to stderr to not pollute stdout for return values)
#######################################

log() {
    printf '%s %b[build]%b %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${GREEN}" "${NC}" "$*" >&2
}

warn() {
    printf '%s %b[warn]%b %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${YELLOW}" "${NC}" "$*" >&2
}

error() {
    printf '%s %b[error]%b %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${RED}" "${NC}" "$*" >&2
}

diag() {
    printf '%s %b[diag]%b %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${BLUE}" "${NC}" "$*" >&2
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

# Helper to remove container from cleanup array (Befund 3.4)
remove_from_cleanup() {
    local name="$1"
    local new_array=()
    for c in "${cleanup_containers[@]}"; do
        [[ "$c" != "$name" ]] && new_array+=("$c")
    done
    cleanup_containers=("${new_array[@]}")
}

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

    [[ "$native_arch" == "amd64" ]] || fatal "This project currently supports only linux/amd64 release builds."

    for platform in "${requested_platforms[@]}"; do
        local requested_arch="${platform#linux/}"
        [[ "$requested_arch" == "amd64" ]] || fatal "Unsupported platform: ${platform}. This project is currently amd64-only."
    done
}

load_config() {
    amd64_url="${UNIFI_OS_URL_X64:-}"
    [[ -n "$amd64_url" ]] || fatal "UNIFI_OS_URL_X64 is required"

    if [[ -z "$VERSION" ]]; then
        VERSION="$(extract_version_from_url "$amd64_url")"
    fi

    IFS=',' read -r -a requested_platforms <<<"$PLATFORMS"
}

installer_url_for_arch() {
    local arch="$1"
    case "$arch" in
        amd64) printf '%s\n' "$amd64_url" ;;
        *) fatal "Unsupported architecture: $arch" ;;
    esac
}

#######################################
# PHASE 1: BUILD EXTRACTOR IMAGE
#######################################

build_extractor_image() {
    local arch="$1"
    local installer_url="$2"
    local extractor_tag="uos-extractor:${VERSION}-${arch}"

    log "Phase 1: Building extractor image for linux/${arch}"
    
    if ! docker build \
        --platform "linux/${arch}" \
        --file "${REPO_ROOT}/docker/Dockerfile.extractor" \
        --tag "$extractor_tag" \
        --build-arg "UOS_INSTALLER_URL=${installer_url}" \
        "$REPO_ROOT" >&2; then
        fatal "Failed to build extractor image"
    fi

    printf '%s\n' "$extractor_tag"
}

#######################################
# PHASE 2: RUN EXTRACTION (STATE-AWARE)
#######################################

run_extraction() {
    local arch="$1"
    local extractor_tag="$2"
    local container_name="uos-extract-${arch}-$$"
    local output_dir="${REPO_ROOT}/build-artifacts/extract-${arch}"

    mkdir -p "$output_dir"
    cleanup_containers+=("$container_name")

    log "Phase 2: Running extractor container (state-aware monitoring)"
    log "  Container: $container_name"
    log "  Output: $output_dir"

    # Start container WITHOUT --rm so we can inspect it on failure
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
        -v "${output_dir}:/output" \
        "$extractor_tag" >&2

    # Monitor container state
    local timeout_seconds=1800  # 30 minutes max
    local poll_interval=5
    local elapsed=0
    local last_log_lines=""
    local current_state=""
    local success=false

    log "Monitoring extraction (timeout: ${timeout_seconds}s)..."

    while (( elapsed < timeout_seconds )); do
        current_state=$(get_container_state "$container_name")

        case "$current_state" in
            running)
                # Check if extraction completed
                if [[ -f "${output_dir}/uosserver.tar" ]]; then
                    log "Extraction artifact found while container running"
                    success=true
                    break
                fi

                # Show progress every 30 seconds
                if (( elapsed % 30 == 0 )); then
                    local new_logs
                    new_logs=$(docker logs --tail 5 "$container_name" 2>&1 || true)
                    if [[ "$new_logs" != "$last_log_lines" ]]; then
                        diag "Progress (${elapsed}s): $(echo "$new_logs" | tail -1 | head -c 100)"
                        last_log_lines="$new_logs"
                    fi
                fi
                ;;

            exited)
                local exit_code oom_killed
                exit_code=$(get_container_exit_code "$container_name")
                oom_killed=$(get_container_oom_killed "$container_name")

                if [[ "$oom_killed" == "true" ]]; then
                    error "Container was OOM killed!"
                    print_container_state "$container_name"
                    preserve_failure "$container_name" "$arch" "extraction" "OOM killed"
                    fatal "Extraction failed: container ran out of memory"
                fi

                if (( exit_code == 0 )); then
                    log "Container exited successfully (exit code 0)"
                    success=true
                else
                    warn "Container exited with code $exit_code"
                    # Check if we got the artifact despite non-zero exit
                    if [[ -f "${output_dir}/uosserver.tar" ]]; then
                        log "Extraction artifact found despite non-zero exit code (expected behavior)"
                        success=true
                    else
                        print_container_state "$container_name"
                        preserve_failure "$container_name" "$arch" "extraction" "Exited with code $exit_code, no artifact"
                        fatal "Extraction failed: container exited with code $exit_code and no uosserver.tar"
                    fi
                fi
                break
                ;;

            dead)
                error "Container is dead (docker daemon issue)"
                print_container_state "$container_name"
                preserve_failure "$container_name" "$arch" "extraction" "Container dead"
                fatal "Extraction failed: container entered dead state"
                ;;

            missing)
                error "Container disappeared unexpectedly"
                preserve_failure "$container_name" "$arch" "extraction" "Container missing"
                fatal "Extraction failed: container no longer exists"
                ;;

            *)
                diag "Container state: $current_state (waiting...)"
                ;;
        esac

        sleep "$poll_interval"
        elapsed=$((elapsed + poll_interval))
    done

    # Timeout check
    if [[ "$success" != "true" ]]; then
        error "Extraction timed out after ${timeout_seconds}s"
        print_container_state "$container_name"
        preserve_failure "$container_name" "$arch" "extraction" "Timeout after ${timeout_seconds}s"
        
        # Stop the container for cleanup
        docker stop -t 10 "$container_name" >/dev/null 2>&1 || true
        fatal "Extraction failed: timeout"
    fi

    # Validate artifact
    if [[ ! -f "${output_dir}/uosserver.tar" ]]; then
        error "Extraction completed but artifact missing"
        preserve_failure "$container_name" "$arch" "extraction" "No uosserver.tar after completion"
        fatal "Extraction failed: uosserver.tar not found"
    fi

    local tar_size
    tar_size=$(stat -c%s "${output_dir}/uosserver.tar" 2>/dev/null || echo "0")
    if (( tar_size < 100000000 )); then  # Less than 100MB is suspicious
        warn "Extracted image is suspiciously small: $((tar_size / 1024 / 1024))MB"
    fi

    log "Extraction successful: ${output_dir}/uosserver.tar ($((tar_size / 1024 / 1024))MB)"

    # Cleanup container and remove from cleanup array (Befund 3.4)
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    remove_from_cleanup "$container_name"

    printf '%s\n' "${output_dir}/uosserver.tar"
}

#######################################
# PHASE 3: LOAD EXTRACTED IMAGE
#######################################

load_extracted_image() {
    local arch="$1"
    local tar_path="$2"
    local target_tag="uosserver:${VERSION}-${arch}"

    log "Phase 3: Loading extracted image into Docker"

    # Load the image
    local load_output
    load_output=$(docker load -i "$tar_path" 2>&1)
    echo "$load_output" >&2

    # Find what was loaded
    local loaded_tag
    loaded_tag=$(echo "$load_output" | grep -oP 'Loaded image: \K.*' | head -1 || true)

    if [[ -z "$loaded_tag" ]]; then
        # Try to find any uosserver image
        loaded_tag=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -E '^(localhost/)?uosserver:' | head -1 || true)
    fi

    if [[ -z "$loaded_tag" ]]; then
        fatal "Failed to load image: no uosserver image found after docker load"
    fi

    # Tag with our target name
    if [[ "$loaded_tag" != "$target_tag" ]]; then
        docker tag "$loaded_tag" "$target_tag"
    fi

    # Verify
    if ! docker image inspect "$target_tag" >/dev/null 2>&1; then
        fatal "Image tagging failed: $target_tag does not exist"
    fi

    local image_size
    image_size=$(docker image inspect --format '{{.Size}}' "$target_tag" 2>/dev/null || echo "0")
    log "Loaded image: $target_tag ($((image_size / 1024 / 1024))MB)"

    printf '%s\n' "$target_tag"
}

#######################################
# PHASE 4: BUILD RUNTIME IMAGE
#######################################

build_runtime_image() {
    local arch="$1"
    local uosserver_tag="$2"
    local final_tag="${IMAGE_NAME}:${VERSION}-${arch}"

    log "Phase 4: Building runtime image for linux/${arch}"

    if ! docker build \
        --platform "linux/${arch}" \
        --file "${REPO_ROOT}/docker/Dockerfile.runtime" \
        --tag "$final_tag" \
        --build-arg "UOSSERVER_IMAGE=${uosserver_tag}" \
        --build-arg "APP_VERSION=${VERSION}" \
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        "$REPO_ROOT" >&2; then
        fatal "Failed to build runtime image"
    fi

    local image_size
    image_size=$(docker image inspect --format '{{.Size}}' "$final_tag" 2>/dev/null || echo "0")
    log "Built runtime image: $final_tag ($((image_size / 1024 / 1024))MB)"

    arch_image_tags+=("$final_tag")
    printf '%s\n' "$final_tag"
}

#######################################
# PHASE 5: VALIDATE RUNTIME IMAGE
#######################################

validate_runtime_image() {
    local arch="$1"
    local image_tag="$2"
    local container_name="uos-validate-${arch}-$$"
    local validation_result="passed"

    log "Phase 5: Validating runtime image"
    log "  Image: $image_tag"
    log "  Container: $container_name"

    cleanup_containers+=("$container_name")

    # Start container
    # Note: --privileged is NOT used for runtime. NET_RAW/NET_ADMIN are required for:
    # - NET_RAW: ICMP ping for network diagnostics
    # - NET_ADMIN: network interface configuration, iptables rules
    # These were determined by testing with --cap-drop ALL and incrementally adding.
    docker run -d \
        --name "$container_name" \
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

    # Wait for container to be running
    sleep 2

    local state
    state=$(get_container_state "$container_name")

    if [[ "$state" != "running" ]]; then
        error "Validation container failed to start"
        print_container_state "$container_name"
        preserve_failure "$container_name" "$arch" "validation" "Container not running: $state"
        fatal "Validation failed: container state is '$state'"
    fi

    # --- Check 1: Wait for systemd ---
    log "Check 1/4: Waiting for systemd..."
    local timeout=90
    local elapsed=0
    local systemd_state=""

    while (( elapsed < timeout )); do
        systemd_state=$(docker exec "$container_name" systemctl is-system-running 2>/dev/null || echo "unknown")
        
        case "$systemd_state" in
            running|degraded)
                log "  systemd ready: $systemd_state"
                break
                ;;
            starting|initializing)
                ;;
            *)
                state=$(get_container_state "$container_name")
                if [[ "$state" != "running" ]]; then
                    error "Container exited during validation"
                    print_container_state "$container_name"
                    preserve_failure "$container_name" "$arch" "validation" "Container exited: $state"
                    fatal "Validation failed: container exited"
                fi
                ;;
        esac

        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ "$systemd_state" != "running" && "$systemd_state" != "degraded" ]]; then
        warn "  systemd did not reach running state within ${timeout}s (state: $systemd_state)"
        validation_result="degraded"
    fi

    # --- Check 2: Verify critical services (Befund 3.1) ---
    log "Check 2/4: Verifying critical services..."
    local critical_services=("unifi-core" "nginx" "mongodb" "postgresql@14-main")
    local services_ok=true

    for svc in "${critical_services[@]}"; do
        if docker exec "$container_name" systemctl is-active "$svc" >/dev/null 2>&1; then
            log "  ✓ $svc is active"
        else
            warn "  ✗ $svc is not active"
            services_ok=false
        fi
    done

    if [[ "$services_ok" != "true" ]]; then
        validation_result="degraded"
    fi

    # --- Check 3: Verify listening ports (Befund 3.1) ---
    log "Check 3/4: Verifying listening ports..."
    local expected_ports=("443" "8443" "8080" "27017")
    local ports_ok=true

    for port in "${expected_ports[@]}"; do
        if docker exec "$container_name" ss -tlnp 2>/dev/null | grep -q ":${port} "; then
            log "  ✓ Port $port is listening"
        else
            warn "  ✗ Port $port is not listening"
            ports_ok=false
        fi
    done

    if [[ "$ports_ok" != "true" ]]; then
        validation_result="degraded"
    fi

    # --- Check 4: Restart test (Befund 3.5) ---
    log "Check 4/4: Restart test..."
    docker stop -t 30 "$container_name" >/dev/null 2>&1
    sleep 2
    docker start "$container_name" >/dev/null 2>&1
    sleep 10  # Give systemd time to reinitialize

    state=$(get_container_state "$container_name")
    if [[ "$state" != "running" ]]; then
        error "  Container failed to restart"
        preserve_failure "$container_name" "$arch" "validation" "Restart failed: $state"
        fatal "Validation failed: container did not survive restart"
    fi

    # Wait for systemd after restart
    elapsed=0
    while (( elapsed < 60 )); do
        systemd_state=$(docker exec "$container_name" systemctl is-system-running 2>/dev/null || echo "unknown")
        if [[ "$systemd_state" == "running" || "$systemd_state" == "degraded" ]]; then
            log "  ✓ Container survived restart (systemd: $systemd_state)"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ "$systemd_state" != "running" && "$systemd_state" != "degraded" ]]; then
        warn "  ✗ systemd not ready after restart"
        validation_result="degraded"
    fi

    # Show running services summary
    log "Running services after validation:"
    docker exec "$container_name" systemctl list-units --type=service --state=running 2>/dev/null | grep -E '^\s*\S+\.service' | head -15 >&2 || true

    # Cleanup validation container
    docker stop -t 10 "$container_name" >/dev/null 2>&1 || true
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    remove_from_cleanup "$container_name"

    log "Validation complete (result: $validation_result)"
    
    # Return validation result for provenance
    printf '%s\n' "$validation_result"
}

#######################################
# BUILD PROVENANCE (Befund 3.6)
#######################################

write_build_provenance() {
    local arch="$1"
    local installer_url="$2"
    local image_tag="$3"
    local validation_result="$4"

    mkdir -p "$BUILD_ARTIFACTS_DIR"
    local provenance_file="${BUILD_ARTIFACTS_DIR}/provenance-${VERSION}-${arch}.json"

    # Get image digest
    local image_digest
    image_digest=$(docker image inspect --format '{{index .RepoDigests 0}}' "$image_tag" 2>/dev/null || echo "local-only")

    # Get image size
    local image_size
    image_size=$(docker image inspect --format '{{.Size}}' "$image_tag" 2>/dev/null || echo "0")

    log "Writing build provenance to: $provenance_file"

    cat > "$provenance_file" <<EOF
{
  "version": "${VERSION}",
  "arch": "${arch}",
  "image_tag": "${image_tag}",
  "image_digest": "${image_digest}",
  "image_size_bytes": ${image_size},
  "built_at": "${BUILD_DATE}",
  "installer_url": "${installer_url}",
  "validation_result": "${validation_result}",
  "capabilities_required": ["NET_ADMIN", "NET_RAW"],
  "phases_completed": {
    "extraction": true,
    "load": true,
    "runtime_build": true,
    "validation": "${validation_result}"
  },
  "builder": {
    "script": "docker/build.sh",
    "hostname": "$(hostname 2>/dev/null || echo 'unknown')"
  }
}
EOF
}

#######################################
# MAIN BUILD FLOW
#######################################

build_arch_image() {
    local arch="$1"
    local installer_url="$2"

    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  Building for linux/${arch}"
    log "║  Version: ${VERSION}"
    log "╚══════════════════════════════════════════════════════════════╝"

    local extractor_tag uosserver_tar uosserver_tag final_tag
    local output_dir="${REPO_ROOT}/build-artifacts/extract-${arch}"

    # Phase 1: Build extractor
    extractor_tag=$(build_extractor_image "$arch" "$installer_url")

    # Phase 2: Run extraction
    uosserver_tar=$(run_extraction "$arch" "$extractor_tag")

    # Phase 3: Load image
    uosserver_tag=$(load_extracted_image "$arch" "$uosserver_tar")

    # Phase 4: Build runtime
    final_tag=$(build_runtime_image "$arch" "$uosserver_tag")

    # Phase 5: Validate (optional)
    local validation_result="skipped"
    if [[ "${SKIP_VALIDATION:-false}" != "true" ]]; then
        validation_result=$(validate_runtime_image "$arch" "$final_tag")
    else
        warn "Skipping validation (SKIP_VALIDATION=true)"
    fi

    # Push if requested
    if [[ "$PUSH" == "true" ]]; then
        log "Pushing ${final_tag}"
        docker push "$final_tag" >&2
    fi

    # Cleanup build artifacts
    log "Cleaning up build artifacts..."
    docker rmi "$extractor_tag" >/dev/null 2>&1 || true
    rm -rf "$output_dir" 2>/dev/null || true

    # Write build provenance (Befund 3.6)
    write_build_provenance "$arch" "$installer_url" "$final_tag" "$validation_result"

    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  Completed linux/${arch}"
    log "╚══════════════════════════════════════════════════════════════╝"
}

#######################################
# PUBLISH MANIFESTS
#######################################

publish_manifests() {
    if [[ "$PUSH" != "true" ]]; then
        warn "PUSH=false, skipping remote publish"
        return
    fi

    if (( ${#arch_image_tags[@]} == 0 )); then
        warn "No images were built; skipping publish"
        return
    fi

    if (( ${#arch_image_tags[@]} == 1 )); then
        log "Publishing single-arch tags"
        docker tag "${arch_image_tags[0]}" "${IMAGE_NAME}:${VERSION}"
        docker tag "${arch_image_tags[0]}" "${IMAGE_NAME}:latest"
        docker push "${IMAGE_NAME}:${VERSION}"
        docker push "${IMAGE_NAME}:latest"
        return
    fi

    log "Creating multi-arch manifest for ${#arch_image_tags[@]} images"
    docker manifest create "${IMAGE_NAME}:${VERSION}" "${arch_image_tags[@]}" --amend || true
    docker manifest create "${IMAGE_NAME}:latest" "${arch_image_tags[@]}" --amend || true
    docker manifest push "${IMAGE_NAME}:${VERSION}"
    docker manifest push "${IMAGE_NAME}:latest"
}

#######################################
# MAIN
#######################################

main() {
    require_cmd docker
    require_cmd grep
    require_cmd sed

    load_config
    validate_requested_platforms

    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  UniFi OS Server Build"
    log "║  Version: ${VERSION}"
    log "║  Platforms: ${PLATFORMS}"
    log "║  Push: ${PUSH}"
    log "║  Artifacts: ${BUILD_ARTIFACTS_DIR}"
    log "╚══════════════════════════════════════════════════════════════╝"

    for platform in "${requested_platforms[@]}"; do
        local arch="${platform#linux/}"
        local installer_url
        installer_url="$(installer_url_for_arch "$arch")"
        build_arch_image "$arch" "$installer_url"
    done

    publish_manifests

    log "╔══════════════════════════════════════════════════════════════╗"
    log "║  BUILD COMPLETE"
    log "╚══════════════════════════════════════════════════════════════╝"

    if [[ "$PUSH" == "true" ]]; then
        log "Pushed: ${IMAGE_NAME}:${VERSION}"
        log "Pushed: ${IMAGE_NAME}:latest"
    else
        log "Local images:"
        for tag in "${arch_image_tags[@]}"; do
            log "  - $tag"
        done
    fi

    # Final image sizes
    log "Image sizes:"
    docker images --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}" | grep -E "^  ${IMAGE_NAME}:" || true
}

print_help() {
    cat <<'EOF'
Build UniFi OS Server by extracting the inner uosserver image from the Ubiquiti installer.

Usage:
    ./build.sh

Environment variables:
    UNIFI_OS_URL_X64       amd64 installer URL (required)
    IMAGE_NAME             Target image name (default: giiibates/unifi-os-server)
    VERSION                Override version tag (derived from URL if not set)
    PLATFORMS              Target platforms (default: linux/amd64)
    PUSH                   Push images (default: true)
    SKIP_VALIDATION        Skip runtime validation (default: false)
    BUILD_ARTIFACTS_DIR    Directory for artifacts (default: ./build-artifacts)

Architecture:
    Docker Host
    └── Extractor Container (outer)
        └── Podman
            └── uosserver Container (inner)

Build phases:
    1. Build extractor image with Podman and tools
    2. Run extractor to download installer and extract uosserver image
    3. Load extracted image into Docker
    4. Build runtime image that runs systemd directly
    5. Validate runtime image starts correctly
    6. Push to registry if PUSH=true

Failure handling:
    On any failure, diagnostic artifacts are saved to BUILD_ARTIFACTS_DIR:
    - reason.txt: failure summary
    - inspect.json: docker inspect output
    - stdout.log/stderr.log: container logs
    - filesystem.tar: container filesystem export
    - podman-*.txt: inner podman state (if available)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_help
    exit 0
fi

main "$@"
