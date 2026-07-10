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

# P1: Source-guard must be the very first executed logic — before set -euo pipefail
# and before any variable assignments — so that sourcing the script neither
# activates strict-mode in the caller's shell nor leaks variables into it.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    printf '[build] This script must be executed, not sourced. Use ./build.sh or bash ./build.sh.\n' >&2
    return 1 2>/dev/null || exit 1
fi

# Require Bash >= 4.4: empty-array expansion under set -u (${arr[@]}) is safe
# only from 4.4 onward. macOS ships Bash 3.2 — catch it here instead of dying
# cryptically mid-build.
if (( BASH_VERSINFO[0] < 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4 ) )); then
    printf '[build] Bash >= 4.4 required (found %s). On macOS: brew install bash\n' "$BASH_VERSION" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

load_dotenv_defaults() {
    local env_file="${REPO_ROOT}/.env"
    [[ -f "$env_file" ]] || return 0

    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        if ! [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            printf '%s\n' "[build] Invalid .env line: $line" >&2
            exit 1
        fi

        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"

        # Strip inline comments (value # comment → value).
        # Only strip when the comment marker is preceded by whitespace so that
        # URLs with fragment-like '#' characters are preserved.
        value="${value%%[[:space:]]#*}"

        # Trim leading and trailing whitespace from the value.
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"

        if [[ ${#value} -ge 2 ]]; then
            case "$value" in
                '"'*)
                    if [[ "${value: -1}" == '"' ]]; then
                        value="${value:1:${#value}-2}"
                    fi
                    ;;
                "'"*)
                    if [[ "${value: -1}" == "'" ]]; then
                        value="${value:1:${#value}-2}"
                    fi
                    ;;
            esac
        fi

        case "$key" in
            IMAGE_NAME|PLATFORMS|PUSH|PROMOTE_LATEST|DOWNLOAD_API_URL|UNIFI_OS_URL_X64|UNIFI_OS_URL_ARM64|VERSION|BUILD_ARTIFACTS_DIR|BUILD_DATE|PRESERVE_FAILURE_CONTAINERS|SKIP_VALIDATION|EXPORT_FAILURE_FILESYSTEM|ALLOW_DEGRADED_PUBLISH)
                [[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$value"
                ;;
            *)
                printf '%s\n' "[build] Unsupported .env key: $key" >&2
                exit 1
                ;;
        esac
    done < "$env_file"
}

load_dotenv_defaults

# Set defaults for anything still unset
IMAGE_NAME="${IMAGE_NAME:-giiibates/unifi-os-server}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
PUSH="${PUSH:-true}"
VERSION="${VERSION:-}"
PROMOTE_LATEST="${PROMOTE_LATEST:-auto}"
BUILD_ARTIFACTS_DIR="${BUILD_ARTIFACTS_DIR:-/tmp/uos-build-$$}"
DOWNLOAD_API_URL="${DOWNLOAD_API_URL:-https://download.svc.ui.com/v1/downloads/products/slugs/unifi-os-server}"
PRESERVE_FAILURE_CONTAINERS="${PRESERVE_FAILURE_CONTAINERS:-true}"
PINNED_BUILD_INPUT=false
if [[ -n "$VERSION" || -n "${UNIFI_OS_URL_X64:-}" || -n "${UNIFI_OS_URL_ARM64:-}" ]]; then
    PINNED_BUILD_INPUT=true
fi

# Minimum tar size for a valid uosserver image (MB).
# Real images are >1500MB; this threshold catches truncated/empty extractions.
MIN_TAR_SIZE_MB=500

# BUILD_DATE should be set externally when the caller wants to control it.
# Otherwise derive it from the current git commit for reproducible rebuilds,
# falling back to wall-clock time only when git metadata is unavailable.
if [[ -z "${BUILD_DATE:-}" ]]; then
    BUILD_DATE=$(git -C "$REPO_ROOT" log -1 --format=%cI 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Disable colors when stderr is not a TTY or when NO_COLOR is set (per no-color.org).
if [[ ! -t 2 || -n "${NO_COLOR:-}" ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

amd64_url=""
arm64_url=""
declare -a requested_platforms=()
declare -a arch_image_tags=()
declare -a arch_validation_results=()
declare -a cleanup_containers=()
HOST_ARCH=""
PUBLISHED_LATEST=false

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

# Format container state as plain text to stdout.
# Use this when the output must be captured or redirected to a file.
format_container_state() {
    local container_name="$1"
    local prefix="${2:-}"

    if ! container_exists "$container_name"; then
        printf '%sContainer '\''%s'\'': does not exist\n' "$prefix" "$container_name"
        return 0
    fi

    local state exit_code oom_killed error_msg started finished
    state=$(get_container_state "$container_name")
    exit_code=$(get_container_exit_code "$container_name")
    oom_killed=$(get_container_oom_killed "$container_name")
    error_msg=$(get_container_error "$container_name")
    started=$(get_container_started_at "$container_name")
    finished=$(get_container_finished_at "$container_name")

    printf '%sContainer '\''%s'\'':\n' "$prefix" "$container_name"
    printf '%s  state:      %s\n' "$prefix" "$state"
    printf '%s  exit_code:  %s\n' "$prefix" "$exit_code"
    printf '%s  oom_killed: %s\n' "$prefix" "$oom_killed"
    printf '%s  started:    %s\n' "$prefix" "$started"
    printf '%s  finished:   %s\n' "$prefix" "$finished"
    [[ -z "$error_msg" ]] || printf '%s  error:      %s\n' "$prefix" "$error_msg"
}

# Print full container state to stderr via diag() for live CI visibility.
# To capture state into a file use format_container_state instead.
print_container_state() {
    local container_name="$1"
    local prefix="${2:-}"
    # format_container_state writes to stdout; redirect into diag one line at a time
    # so that each line gets the standard [diag] timestamp prefix.
    while IFS= read -r line; do
        diag "$line"
    done < <(format_container_state "$container_name" "$prefix")
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

    # Save container state (stdout → file via format_container_state)
    format_container_state "$container_name" "  " >> "${prefix}-reason.txt"

    # Save full inspect
    diag "Saving docker inspect..."
    docker inspect "$container_name" > "${prefix}-inspect.json" 2>&1 || true

    # Save logs (full, not truncated)
    diag "Saving container logs..."
    docker logs "$container_name" > "${prefix}-stdout.log" 2> "${prefix}-stderr.log" || true

    # If both logs are empty, the container likely crashed before producing output.
    # Check the bind-mounted extract.log first — it's written before docker logging
    # initialises and therefore survives sub-100ms crashes.
    if [[ ! -s "${prefix}-stdout.log" && ! -s "${prefix}-stderr.log" ]]; then
        warn "Container logs are empty (container likely crashed before producing output)"

        # Try to recover the bind-mounted extract.log (survives any crash timing)
        local extract_log="${BUILD_ARTIFACTS_DIR}/extract-${arch}/extract.log"
        if [[ -s "$extract_log" ]]; then
            cp "$extract_log" "${prefix}-extract.log" 2>/dev/null || true
            warn "--- extract.log (last 50 lines) ---"
            tail -50 "${prefix}-extract.log" >&2 || true
            warn "--- end extract.log ---"
        else
            # Also try copying directly from the stopped container filesystem
            docker cp "${container_name}:/output/extract.log" "${prefix}-extract.log" >/dev/null 2>&1 || true
            if [[ -s "${prefix}-extract.log" ]]; then
                warn "--- extract.log from container (last 50 lines) ---"
                tail -50 "${prefix}-extract.log" >&2 || true
                warn "--- end extract.log ---"
            fi
        fi

        {
            echo "=== Container logs were empty ==="
            echo "This usually means the process crashed at startup (exec format error,"
            echo "missing interpreter, immediate set -euo pipefail failure, or cgroup/namespace issue)."
            echo ""
            echo "Exit code: $(get_container_exit_code "$container_name")"
            echo "Started at: $(get_container_started_at "$container_name")"
            echo "Finished at: $(get_container_finished_at "$container_name")"
            echo ""
            echo "=== Container state (JSON) ==="
            docker inspect --format '{{json .State}}' "$container_name" 2>/dev/null | jq . 2>/dev/null || true
        } > "${prefix}-crash-diagnostic.txt"
    fi

    # Save filesystem only if explicitly requested (can be multi-GB and slow)
    local state
    state=$(get_container_state "$container_name")
    if [[ "${EXPORT_FAILURE_FILESYSTEM:-false}" == "true" ]]; then
        if [[ "$state" == "exited" || "$state" == "dead" || "$state" == "running" ]]; then
            diag "Exporting container filesystem (EXPORT_FAILURE_FILESYSTEM=true)..."
            docker export "$container_name" > "${prefix}-filesystem.tar" 2>/dev/null || true
        fi
    else
        diag "Skipping filesystem export (set EXPORT_FAILURE_FILESYSTEM=true to enable)"
    fi

    # Extract stub logs even from stopped containers; /tmp may be tmpfs-backed.
    docker cp "$container_name:/var/log/systemctl-stub.log" "${prefix}-systemctl-stub.log" >/dev/null 2>&1 || \
        docker cp "$container_name:/tmp/systemctl-stub.log" "${prefix}-systemctl-stub.log" >/dev/null 2>&1 || true

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

    # On failure, preserve containers for debugging if PRESERVE_FAILURE_CONTAINERS=true
    if (( exit_code != 0 )) && [[ "$PRESERVE_FAILURE_CONTAINERS" == "true" ]]; then
        if (( ${#cleanup_containers[@]} > 0 )); then
            warn "Preserving ${#cleanup_containers[@]} container(s) for failure analysis"
            warn "Set PRESERVE_FAILURE_CONTAINERS=false to auto-remove on failure"
            for container_name in "${cleanup_containers[@]}"; do
                [[ -n "$container_name" ]] || continue
                if container_exists "$container_name"; then
                    diag "  Preserved: $container_name"
                fi
            done
            exit "$exit_code"
        fi
    fi

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

# Helper to remove container from cleanup array
# (Prevents successful containers from being deleted on later failures)
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
    version="$(sed -E 's|.*-([0-9]+(\.[0-9]+){2,3})-.*|\1|' <<<"$url")"
    [[ -n "$version" && "$version" != "$url" ]] || fatal "Could not derive version from URL: $url"
    printf '%s\n' "$version"
}

validate_version() {
    local version="$1"
    [[ "$version" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]] || fatal "Invalid version: $version"
}

validate_api_url() {
    local url="$1"
    [[ "$url" =~ ^https://[^[:space:]]+$ ]] || fatal "Invalid DOWNLOAD_API_URL: must be HTTPS without whitespace"
    case "$url" in
        https://download.svc.ui.com/*) ;;
        *) fatal "Invalid DOWNLOAD_API_URL host: $url" ;;
    esac
}

version_ge() {
    local candidate="$1"
    local baseline="$2"

    [[ "$(printf '%s\n%s\n' "$baseline" "$candidate" | sort -V | tail -n 1)" == "$candidate" ]]
}

docker_hub_repo_path() {
    local image="$IMAGE_NAME"
    local first_component="${image%%/*}"

    if [[ "$image" == docker.io/* ]]; then
        image="${image#docker.io/}"
    elif [[ "$image" == registry-1.docker.io/* ]]; then
        image="${image#registry-1.docker.io/}"
    elif [[ "$first_component" == *.* || "$first_component" == *:* || "$first_component" == "localhost" ]]; then
        return 1
    fi

    if [[ "$image" != */* ]]; then
        image="library/${image}"
    fi

    printf '%s\n' "$image"
}

fetch_docker_hub_token() {
    local repo="$1"
    local token

    token="$(
        curl -fsSL \
            --connect-timeout 10 \
            --max-time 20 \
            "https://auth.docker.io/token?service=registry.docker.io&scope=repository:${repo}:pull" \
            | jq -r '.token // empty'
    )" || return 1

    [[ -n "$token" ]] || return 1
    printf '%s\n' "$token"
}

fetch_registry_json() {
    local url="$1"
    local token="$2"
    local accept_header="${3:-application/json}"
    local response status body

    response="$(
        curl -sS -L -w '\n%{http_code}' \
            --connect-timeout 10 \
            --max-time 20 \
            -H "Authorization: Bearer ${token}" \
            -H "Accept: ${accept_header}" \
            "$url"
    )" || return 1

    status="$(tail -n 1 <<< "$response")"
    body="$(sed '$d' <<< "$response")"

    case "$status" in
        200)
            printf '%s\n' "$body"
            ;;
        404)
            return 2
            ;;
        *)
            warn "Registry request failed with HTTP ${status}: ${url}"
            return 1
            ;;
    esac
}

fetch_current_latest_version() {
    local repo token manifest child_digest child_manifest config_digest config version
    local accept_header='application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

    repo="$(docker_hub_repo_path)" || return 3
    token="$(fetch_docker_hub_token "$repo")" || return 1

    manifest="$(
        fetch_registry_json \
            "https://registry-1.docker.io/v2/${repo}/manifests/latest" \
            "$token" \
            "$accept_header"
    )" || return $?

    child_digest="$(jq -r '.manifests[]? | select(.platform.architecture == "amd64") | .digest' <<< "$manifest" | head -n 1)"
    if [[ -z "$child_digest" ]]; then
        child_digest="$(jq -r '.manifests[0]?.digest // empty' <<< "$manifest")"
    fi

    if [[ -n "$child_digest" ]]; then
        child_manifest="$(
            fetch_registry_json \
                "https://registry-1.docker.io/v2/${repo}/manifests/${child_digest}" \
                "$token" \
                "$accept_header"
        )" || return 1
    else
        child_manifest="$manifest"
    fi

    config_digest="$(jq -r '.config.digest // empty' <<< "$child_manifest")"
    [[ -n "$config_digest" ]] || return 1

    config="$(
        fetch_registry_json \
            "https://registry-1.docker.io/v2/${repo}/blobs/${config_digest}" \
            "$token"
    )" || return 1

    version="$(jq -r '.config.Labels["org.opencontainers.image.version"] // empty' <<< "$config")"
    [[ "$version" =~ ^[0-9]+(\.[0-9]+){2,3}$ ]] || return 1
    printf '%s\n' "$version"
}

resolve_promote_latest() {
    local promote current_latest status

    case "$PROMOTE_LATEST" in
        true)
            promote=true
            ;;
        false)
            promote=false
            ;;
        auto)
            if [[ "$PINNED_BUILD_INPUT" == "true" ]]; then
                promote=false
            else
                promote=true
            fi
            ;;
        *)
            fatal "Invalid PROMOTE_LATEST: $PROMOTE_LATEST (expected: auto, true, false)"
            ;;
    esac

    if [[ "$promote" == "true" ]]; then
        if current_latest="$(fetch_current_latest_version)"; then
            log "Current latest version: ${current_latest}"
            if ! version_ge "$VERSION" "$current_latest"; then
                warn "Refusing to move latest backward: built ${VERSION}, current latest ${current_latest}"
                promote=false
            fi
        else
            status=$?
            case "$status" in
                2)
                    log "No current latest manifest found; latest promotion is allowed"
                    ;;
                3)
                    fatal "Cannot verify latest version for non-Docker-Hub IMAGE_NAME (${IMAGE_NAME}); set PROMOTE_LATEST=false"
                    ;;
                *)
                    fatal "Current latest version could not be resolved; refusing latest promotion"
                    ;;
            esac
        fi
    fi

    printf '%s\n' "$promote"
}

validate_installer_url() {
    local url="$1"
    local label="$2"
    local host

    [[ "$url" =~ ^https://[^[:space:]]+$ ]] || fatal "Invalid $label URL: must be HTTPS without whitespace"

    host="${url#https://}"
    host="${host%%/*}"
    # Reject userinfo component (e.g. https://ui.com@evil.example/path)
    # which could bypass the allowlist via credential-in-URL tricks.
    [[ "$host" == *@* ]] && fatal "Invalid $label URL: userinfo not allowed"
    host="${host%%:*}"

    case "$host" in
        ui.com|dl.ui.com|fw-download.ubnt.com)
            ;;
        *.ui.com)
            [[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.ui\.com$ ]] || \
                fatal "Invalid $label URL host: $host"
            ;;
        *)
            fatal "Invalid $label URL host: $host"
            ;;
    esac
}

init_host_arch() {
    local uname_arch
    uname_arch="$(uname -m)"

    case "$uname_arch" in
        x86_64|amd64) HOST_ARCH="amd64" ;;
        aarch64|arm64) HOST_ARCH="arm64" ;;
        *) fatal "Unsupported host architecture: $uname_arch" ;;
    esac
}

# Check if a binfmt_misc entry is registered and enabled.
# Defined at top level so it is not re-declared on every can_emulate_arch call.
binfmt_enabled() {
    local entry="$1"
    [[ -f "$entry" ]] || return 1
    grep -q '^enabled$' "$entry"
}

# Check if QEMU/binfmt is available for cross-architecture builds
can_emulate_arch() {
    local target_arch="$1"
    
    # Native architecture always works
    [[ "$target_arch" == "$HOST_ARCH" ]] && return 0
    
    # Check binfmt_misc for the target architecture
    local binfmt_path="/proc/sys/fs/binfmt_misc"

    if [[ -d "$binfmt_path" ]]; then
        case "$target_arch" in
            arm64|aarch64)
                binfmt_enabled "$binfmt_path/qemu-aarch64" && return 0
                ;;
            amd64|x86_64)
                binfmt_enabled "$binfmt_path/qemu-x86_64" && return 0
                ;;
        esac
    fi
    
    return 1
}

init_host_arch

#######################################
# URL CONFIGURATION
#######################################

fetch_urls_from_api() {
    log "Fetching latest URLs from Ubiquiti API..."
    local response latest_row
    response=$(curl --fail --silent --show-error --location \
        --connect-timeout 10 \
        --max-time 30 \
        --retry 3 \
        --retry-all-errors \
        "$DOWNLOAD_API_URL") || {
        error "Failed to fetch from API (curl exit: $?)"
        return 1
    }

    if ! jq -e '.downloads | type == "array"' >/dev/null <<< "$response"; then
        fatal "Unexpected API response: downloads array missing"
    fi
    
    latest_row=$(
        jq -r '
          .downloads
          | map(select(.name | test("Linux.*(x64|arm64)"; "i")))
          | group_by(.version)
          | map({
              version: .[0].version,
              x64: (map(select(.name | test("Linux.*x64"; "i")))[0].file_url // ""),
              arm64: (map(select(.name | test("Linux.*arm64"; "i")))[0].file_url // "")
            })
          | map(select(.x64 != "" and .arm64 != ""))
          | .[]
          | [.version, .x64, .arm64]
          | @tsv
        ' <<< "$response" | sort -t $'\t' -k1,1V | tail -1
    )

    [[ -n "$latest_row" ]] || fatal "No complete amd64/arm64 Linux release found"

    IFS=$'\t' read -r VERSION amd64_url arm64_url <<< "$latest_row"

    validate_version "$VERSION"
    validate_installer_url "$amd64_url" "amd64"
    validate_installer_url "$arm64_url" "arm64"

    log "Found x64 URL: $amd64_url"
    log "Found arm64 URL: $arm64_url"
}

load_config() {
    # Use environment variables if set, otherwise fetch from API
    amd64_url="${UNIFI_OS_URL_X64:-}"
    arm64_url="${UNIFI_OS_URL_ARM64:-}"

    validate_api_url "$DOWNLOAD_API_URL"
    
    if [[ -z "$amd64_url" && -z "$arm64_url" ]]; then
        fetch_urls_from_api || fatal "Failed to fetch URLs from API"
    fi

    if [[ -z "$VERSION" ]]; then
        if [[ -n "$amd64_url" ]]; then
            VERSION="$(extract_version_from_url "$amd64_url")"
        elif [[ -n "$arm64_url" ]]; then
            VERSION="$(extract_version_from_url "$arm64_url")"
        fi
    fi

    if [[ -n "$amd64_url" && -n "$arm64_url" ]]; then
        local amd64_version arm64_version
        amd64_version="$(extract_version_from_url "$amd64_url")"
        arm64_version="$(extract_version_from_url "$arm64_url")"
        [[ "$amd64_version" == "$arm64_version" ]] || fatal "amd64 and arm64 installer URLs reference different versions: $amd64_version vs $arm64_version"
        if [[ -z "$VERSION" ]]; then
            VERSION="$amd64_version"
        elif [[ "$VERSION" != "$amd64_version" ]]; then
            fatal "VERSION does not match installer URLs: $VERSION vs $amd64_version"
        fi
    fi

    [[ -n "$VERSION" ]] || fatal "Could not determine version"
    validate_version "$VERSION"

    if [[ -n "$amd64_url" ]]; then
        validate_installer_url "$amd64_url" "amd64"
    fi

    if [[ -n "$arm64_url" ]]; then
        validate_installer_url "$arm64_url" "arm64"
    fi

    IFS=',' read -r -a requested_platforms <<<"$PLATFORMS"
    
    log "Version: $VERSION"
    log "Platforms: ${requested_platforms[*]}"
}

validate_requested_platforms() {
    for platform in "${requested_platforms[@]}"; do
        local requested_arch="${platform#linux/}"
        case "$requested_arch" in
            amd64)
                [[ -n "$amd64_url" ]] || fatal "amd64 URL not available"
                ;;
            arm64)
                [[ -n "$arm64_url" ]] || fatal "arm64 URL not available - set UNIFI_OS_URL_ARM64"
                ;;
            *)
                fatal "Unsupported platform: ${platform}. Supported: linux/amd64, linux/arm64"
                ;;
        esac
        
        # Check cross-architecture emulation
        if [[ "$requested_arch" != "$HOST_ARCH" ]]; then
            if ! can_emulate_arch "$requested_arch"; then
                fatal "Cannot build for $requested_arch on $HOST_ARCH host - QEMU not available.
Install QEMU with: docker run --privileged --rm tonistiigi/binfmt --install all"
            fi
            warn "Cross-architecture build: $requested_arch on $HOST_ARCH (using QEMU emulation)"
        fi
    done
}

installer_url_for_arch() {
    local arch="$1"
    case "$arch" in
        amd64) printf '%s\n' "$amd64_url" ;;
        arm64) printf '%s\n' "$arm64_url" ;;
        *) fatal "Unsupported architecture: $arch" ;;
    esac
}

#######################################
# PHASE 1: BUILD EXTRACTOR IMAGE
#######################################

build_extractor_image() {
    local arch="$1"
    local __out="$2"
    local extractor_image_tag="uos-extractor:${VERSION}-${arch}"

    log "Phase 1: Building extractor image for linux/${arch}"
    
    # Use DOCKER_DEFAULT_PLATFORM as additional safeguard for buildx
    if ! DOCKER_DEFAULT_PLATFORM="linux/${arch}" docker build \
        --platform "linux/${arch}" \
        --pull \
        --file "${REPO_ROOT}/docker/Dockerfile.extractor" \
        --tag "$extractor_image_tag" \
        "$REPO_ROOT" >&2; then
        fatal "Failed to build extractor image"
    fi

    printf -v "$__out" '%s' "$extractor_image_tag"
}

#######################################
# PHASE 2: RUN EXTRACTION (STATE-AWARE)
#######################################

run_extraction() {
    local arch="$1"
    local installer_url="$2"
    local extractor_tag="$3"
    local __out="$4"
    local container_name="uos-extract-${arch}-$$"
    local output_dir="${BUILD_ARTIFACTS_DIR}/extract-${arch}"

    mkdir -p "$output_dir"
    cleanup_containers+=("$container_name")

    log "Phase 2: Running extractor container (state-aware monitoring)"
    log "  Container: $container_name"
    log "  Output: $output_dir"

    # Start container WITHOUT --rm so we can inspect it on failure
    docker run -d \
        --platform "linux/${arch}" \
        --name "$container_name" \
        --env "UOS_INSTALLER_URL=${installer_url}" \
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
                # Check if extraction completed - file must exist AND be stable
                if [[ -f "${output_dir}/uosserver.tar" ]]; then
                    local current_size prev_size prev_size2
                    current_size=$(stat -c%s "${output_dir}/uosserver.tar" 2>/dev/null || echo "0")
                    
                    # Wait for file to stop growing (handles repair/repack phase).
                    # Count the sleeps toward elapsed to avoid timeout drift.
                    sleep 3; elapsed=$((elapsed + 3))
                    prev_size=$current_size
                    current_size=$(stat -c%s "${output_dir}/uosserver.tar" 2>/dev/null || echo "0")
                    
                    sleep 3; elapsed=$((elapsed + 3))
                    prev_size2=$current_size
                    current_size=$(stat -c%s "${output_dir}/uosserver.tar" 2>/dev/null || echo "0")
                    
                    if (( current_size == prev_size && current_size == prev_size2 && current_size > MIN_TAR_SIZE_MB * 1024 * 1024 )); then
                        # Prefer a sentinel file written by the extraction script
                        # over log-tail parsing: the sentinel is reliable even when
                        # the container logs more than a few lines after completion.
                        if [[ -f "${output_dir}/.extraction-done" ]]; then
                            log "Extraction artifact found while container running (size stable at $((current_size / 1024 / 1024))MB)"
                            success=true
                            break
                        else
                            diag "Tar stable but extraction sentinel not present yet"
                        fi
                    elif (( current_size > 0 )); then
                        diag "Tar file exists but still growing: $((current_size / 1024 / 1024))MB"
                    fi
                fi

                # Show progress every 30 seconds
                if (( elapsed % 30 == 0 )); then
                    local new_logs
                    new_logs=$(docker logs --tail 5 "$container_name" 2>&1 || true)
                    if [[ "$new_logs" != "$last_log_lines" ]]; then
                        diag "Progress (${elapsed}s): $(echo "$new_logs" | tail -1 | head -c 200)"
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
                        # Dump container logs directly to stderr for immediate CI visibility
                        # (preserve_failure saves them to files, but CI output is checked first)
                        warn "--- Container output (last 50 lines) ---"
                        docker logs --tail 50 "$container_name" >&2 2>&1 || true
                        warn "--- End container output ---"
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
    local tar_size_mb=$((tar_size / 1024 / 1024))
    
    if (( tar_size_mb < MIN_TAR_SIZE_MB )); then
        error "Extracted image is too small: ${tar_size_mb}MB (minimum: ${MIN_TAR_SIZE_MB}MB, typical: >1500MB)"
        error "This usually means the image import was not complete"
        preserve_failure "$container_name" "$arch" "extraction" "Image too small: ${tar_size_mb}MB"
        fatal "Extraction failed: incomplete image (${tar_size_mb}MB)"
    elif (( tar_size_mb < 1000 )); then
        warn "Extracted image is smaller than expected: ${tar_size_mb}MB (typical: >1500MB)"
    fi

    log "Extraction successful: ${output_dir}/uosserver.tar (${tar_size_mb}MB)"

    # Cleanup container and remove from cleanup array
    # (Container no longer needed for failure analysis)
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    remove_from_cleanup "$container_name"

    printf -v "$__out" '%s' "${output_dir}/uosserver.tar"
}

#######################################
# PHASE 3: LOAD EXTRACTED IMAGE
#######################################

load_extracted_image() {
    local arch="$1"
    local tar_path="$2"
    local __out="$3"
    local target_tag="uosserver:${VERSION}-${arch}"

    log "Phase 3: Loading extracted image into Docker"

    # Validate tar file before loading
    if [[ ! -f "$tar_path" ]]; then
        fatal "Tar file does not exist: $tar_path"
    fi
    
    local tar_size_mb
    tar_size_mb=$(($(stat -c%s "$tar_path") / 1024 / 1024))
    diag "Tar file size: ${tar_size_mb}MB"
    
    # Check tar format (docker-archive vs OCI)
    diag "Tar contents (top-level):"
    tar -tf "$tar_path" 2>/dev/null | grep -v '/' | head -10 || true
    
    # docker-archive format should have manifest.json
    if ! tar -tf "$tar_path" 2>/dev/null | grep -q '^manifest.json$'; then
        diag "Full tar listing:"
        tar -tf "$tar_path" 2>/dev/null | head -30 || true
        fatal "Tar is not in docker-archive format (missing manifest.json)"
    fi

    # Capture images before load to determine what's new
    local before_images
    before_images=$(docker images -q --no-trunc | sort -u) || fatal "Failed to list Docker images before load"

    # Load the image
    local load_output
    load_output=$(docker load -i "$tar_path" 2>&1) || {
        echo "$load_output" >&2
        diag "Tar structure for debugging:"
        tar -tvf "$tar_path" 2>/dev/null | head -20 || true
        fatal "docker load failed"
    }
    echo "$load_output" >&2

    # Find what was loaded - prefer image ID comparison over regex parsing
    local after_images new_image loaded_tag
    after_images=$(docker images -q --no-trunc | sort -u) || fatal "Failed to list Docker images after load"
    [[ -n "$after_images" ]] || fatal "No Docker images found after load"
    new_image=$(comm -13 <(echo "$before_images") <(echo "$after_images") | sed -n '1p')

    if [[ -n "$new_image" ]]; then
        # Found new image by ID comparison - most reliable method
        diag "Detected new image by ID: $new_image"
        docker tag "$new_image" "$target_tag" || \
            fatal "Failed to tag image $new_image as $target_tag"
    else
        # Fallback: parse docker load output.
        # Handles two message formats:
        #   "Loaded image: repo:tag"        — tagged tar (most common)
        #   "Loaded image ID: sha256:..."   — untagged tar (podman save without RepoTag)
        loaded_tag=$(echo "$load_output" | grep -oP 'Loaded image: \K.*' | head -1 || true)
        if [[ -z "$loaded_tag" ]]; then
            loaded_tag=$(echo "$load_output" | grep -oP 'Loaded image ID: \K.*' | head -1 || true)
        fi
        if [[ -n "$loaded_tag" ]]; then
            if [[ "$loaded_tag" != "$target_tag" ]]; then
                docker tag "$loaded_tag" "$target_tag" || \
                    fatal "Failed to tag $loaded_tag as $target_tag"
            fi
        else
            fatal "Failed to load image: could not identify loaded image"
        fi
    fi

    # Verify
    if ! docker image inspect "$target_tag" >/dev/null 2>&1; then
        fatal "Image tagging failed: $target_tag does not exist"
    fi

    local image_size
    image_size=$(docker image inspect --format '{{.Size}}' "$target_tag" 2>/dev/null || echo "0")
    log "Loaded image: $target_tag ($((image_size / 1024 / 1024))MB)"

    printf -v "$__out" '%s' "$target_tag"
}

#######################################
# PHASE 4: BUILD RUNTIME IMAGE
#######################################

build_runtime_image() {
    local arch="$1"
    local uosserver_tag="$2"
    local __out="$3"
    local runtime_image_tag="${IMAGE_NAME}:${VERSION}-${arch}"

    [[ -n "$uosserver_tag" ]] || fatal "UOSSERVER_IMAGE must be set"
    [[ -n "$VERSION" && "$VERSION" != "dev" ]] || fatal "APP_VERSION must be a real release version"

    log "Phase 4: Building runtime image for linux/${arch}"

    # Use 'docker buildx build --builder default' to use the standard Docker builder
    # instead of any buildx container-driver builder (which can't see local images).
    # Don't use --pull since uosserver is a locally loaded image, not from a registry.
    if ! DOCKER_DEFAULT_PLATFORM="linux/${arch}" docker buildx build \
        --builder default \
        --platform "linux/${arch}" \
        --load \
        --file "${REPO_ROOT}/docker/Dockerfile.runtime" \
        --tag "$runtime_image_tag" \
        --build-arg "UOSSERVER_IMAGE=${uosserver_tag}" \
        --build-arg "APP_VERSION=${VERSION}" \
        --build-arg "BUILD_DATE=${BUILD_DATE}" \
        "$REPO_ROOT" >&2; then
        fatal "Failed to build runtime image"
    fi

    local image_size
    image_size=$(docker image inspect --format '{{.Size}}' "$runtime_image_tag" 2>/dev/null || echo "0")
    log "Built runtime image: $runtime_image_tag ($((image_size / 1024 / 1024))MB)"

    arch_image_tags+=("$runtime_image_tag")
    printf -v "$__out" '%s' "$runtime_image_tag"
}

tag_local_aliases() {
    local source_tag="$1"

    # Generic aliases are only unambiguous for single-platform builds.
    if (( ${#requested_platforms[@]} != 1 )); then
        return 0
    fi

    local version_tag="${IMAGE_NAME}:${VERSION}"
    docker tag "$source_tag" "$version_tag" || fatal "Failed to tag $source_tag as $version_tag"

    # Only tag latest locally when resolve_promote_latest would allow it.
    # Avoids a stale local 'latest' tag misleading tooling on the same host
    # when the build intentionally skips latest promotion (e.g. pinned version).
    local promote_latest
    promote_latest="$(resolve_promote_latest)"
    if [[ "$promote_latest" == "true" ]]; then
        local latest_tag="${IMAGE_NAME}:latest"
        docker tag "$source_tag" "$latest_tag" || fatal "Failed to tag $source_tag as $latest_tag"
        log "Tagged local aliases: $version_tag, $latest_tag"
    else
        log "Tagged local alias: $version_tag (latest skipped — promote_latest=$promote_latest)"
    fi
}

#######################################
# PHASE 5: VALIDATE RUNTIME IMAGE
#######################################

validate_runtime_image() {
    local arch="$1"
    local image_tag="$2"
    local __out="$3"
    local container_name="uos-validate-${arch}-$$"
    local validation_state="passed"

    log "Phase 5: Validating runtime image"
    log "  Image: $image_tag"
    log "  Container: $container_name"

    cleanup_containers+=("$container_name")

    # Start container
    # Note: --privileged is NOT used for runtime.
    # NET_RAW/NET_ADMIN are the currently assumed minimal capabilities for ICMP,
    # network interface configuration, and iptables-related operations.
    # The verified hard startup requirement is the rw /sys/fs/cgroup mount.
    # A real capability-minimization regression test is still future work.
    docker run -d \
        --name "$container_name" \
        --platform "linux/${arch}" \
        --cgroupns=host \
        --cap-add NET_RAW \
        --cap-add NET_ADMIN \
        --tmpfs /run:exec \
        --tmpfs /run/lock \
        --tmpfs /tmp:exec \
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
    # Poll with exponential backoff: start at 2s, double each iteration up to a
    # 30s cap. This polls aggressively early (when systemd reaches 'running'
    # fastest) and backs off if the boot is slow (JVM start, first-boot DB init).
    # Hard ceiling: 300s (5 min) — enough for the heaviest first-boot scenario.
    log "Check 1/4: Waiting for systemd..."
    local systemd_timeout=300
    local elapsed=0
    local sleep_interval=2
    local sleep_max=30
    local systemd_state=""

    while (( elapsed < systemd_timeout )); do
        # systemctl is-system-running exits non-zero for any state other than
        # "running" (e.g. "starting" = exit 1, "degraded" = exit 1).
        # Using || echo "unknown" would silently replace the real state with
        # "unknown" whenever systemd has not fully started yet, causing the
        # loop to never match "starting|initializing" and always fall through
        # to the container-exit check. Capture stdout and stderr separately so
        # the real state word is always preserved.
        systemd_state=$(timeout 10 docker exec "$container_name" systemctl is-system-running 2>/dev/null; true)
        systemd_state="${systemd_state:-unknown}"

        case "$systemd_state" in
            running|degraded)
                log "  systemd ready: $systemd_state (${elapsed}s)"
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

        sleep "$sleep_interval"
        elapsed=$(( elapsed + sleep_interval ))
        # Double the interval, cap at sleep_max
        sleep_interval=$(( sleep_interval * 2 ))
        (( sleep_interval > sleep_max )) && sleep_interval=$sleep_max
    done

    if [[ "$systemd_state" != "running" && "$systemd_state" != "degraded" ]]; then
        warn "  systemd did not reach running state within ${systemd_timeout}s (state: $systemd_state)"
        validation_state="degraded"
    fi

    # --- Check 2: Verify critical services ---
    # These services are expected in a healthy UniFi OS installation.
    # postgresql is matched by glob to survive a major-version bump (PG 14 → 15/16).
    log "Check 2/4: Verifying critical services..."
    local services_ok=true

    # Fixed services
    local critical_services=("unifi-core" "nginx" "mongodb")
    for svc in "${critical_services[@]}"; do
        if docker exec "$container_name" systemctl is-active "$svc" >/dev/null 2>&1; then
            log "  ✓ $svc is active"
        else
            warn "  ✗ $svc is not active"
            services_ok=false
        fi
    done

    # PostgreSQL: match whichever major version is installed
    local pg_unit
    pg_unit=$(docker exec "$container_name" \
        systemctl list-units --type=service --state=active --no-legend 'postgresql@*' \
        2>/dev/null | awk '{print $1; exit}' || true)
    if [[ -n "$pg_unit" ]]; then
        log "  ✓ $pg_unit is active"
    else
        warn "  ✗ no active postgresql@* service found"
        services_ok=false
    fi

    if [[ "$services_ok" != "true" ]]; then
        preserve_failure "$container_name" "$arch" "validation" "Critical service check failed"
        fatal "Validation failed: one or more critical services are inactive"
    fi

    # --- Check 3: Verify listening ports ---
    # unifi-core (8443/8080) can lag behind systemd-ready by a minute or more
    # on first boot while the JVM initialises and waits for DB migrations.
    # Poll each port independently with exponential backoff so a fast start
    # (e.g. warm volume) exits quickly, while a slow start gets enough time.
    log "Check 3/4: Verifying listening ports..."
    local expected_ports=("443" "8443" "8080" "27017")
    local ports_ok=true
    local port_timeout=180  # per-port ceiling

    for port in "${expected_ports[@]}"; do
        local p_elapsed=0
        local p_interval=2
        local p_ready=false
        while (( p_elapsed < port_timeout )); do
            if docker exec "$container_name" ss -tlnp 2>/dev/null | grep -q ":${port} "; then
                log "  ✓ Port $port is listening (${p_elapsed}s)"
                p_ready=true
                break
            fi
            sleep "$p_interval"
            p_elapsed=$(( p_elapsed + p_interval ))
            p_interval=$(( p_interval * 2 ))
            (( p_interval > 30 )) && p_interval=30
        done
        if [[ "$p_ready" != "true" ]]; then
            warn "  ✗ Port $port is not listening (after ${port_timeout}s)"
            ports_ok=false
        fi
    done

    if [[ "$ports_ok" != "true" ]]; then
        preserve_failure "$container_name" "$arch" "validation" "Expected port check failed"
        fatal "Validation failed: one or more expected ports are not listening"
    fi

    # --- Check 4: Restart test ---
    # Verify container survives a stop/start cycle (proves persistent state)
    log "Check 4/4: Restart test..."
    if ! docker stop -t 30 "$container_name" >/dev/null 2>&1; then
        preserve_failure "$container_name" "$arch" "validation" "docker stop failed during restart test"
        fatal "Validation failed: could not stop container for restart test"
    fi
    sleep 2
    if ! docker start "$container_name" >/dev/null 2>&1; then
        preserve_failure "$container_name" "$arch" "validation" "docker start failed during restart test"
        fatal "Validation failed: could not restart container"
    fi
    sleep 10  # Give systemd time to reinitialize

    state=$(get_container_state "$container_name")
    if [[ "$state" != "running" ]]; then
        error "  Container failed to restart"
        preserve_failure "$container_name" "$arch" "validation" "Restart failed: $state"
        fatal "Validation failed: container did not survive restart"
    fi

    # Wait for systemd after restart. This is intentionally non-fatal:
    # complex systemd appliance containers can need a long recovery window after
    # docker stop/start, while the initial boot/service/port validation above is
    # the authoritative image health check.
    elapsed=0
    local restart_timeout=180
    systemd_state="unknown"

    while (( elapsed < restart_timeout )); do
        state=$(get_container_state "$container_name")
        if [[ "$state" != "running" ]]; then
            error "  Container exited after restart"
            print_container_state "$container_name"
            preserve_failure "$container_name" "$arch" "validation" "Container exited after restart: $state"
            fatal "Validation failed: container did not survive restart"
        fi

        systemd_state=$(timeout 10 docker exec "$container_name" systemctl is-system-running 2>/dev/null; true)
        systemd_state="${systemd_state:-unknown}"
        if [[ "$systemd_state" == "running" || "$systemd_state" == "degraded" ]]; then
            log "  ✓ Container survived restart (systemd: $systemd_state)"
            break
        fi

        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ "$systemd_state" != "running" && "$systemd_state" != "degraded" ]]; then
        warn "  ✗ systemd not ready after restart after ${restart_timeout}s (state: $systemd_state)"
        validation_state="degraded"
    fi

    # Show running services summary. Keep this bounded: if systemd/dbus is stuck
    # after restart, an unbounded `docker exec systemctl ...` can hang the CI job.
    log "Running services after validation:"
    if [[ "$systemd_state" == "running" || "$systemd_state" == "degraded" ]]; then
        timeout 20 docker exec "$container_name" \
            systemctl list-units --type=service --state=running 2>/dev/null \
            | grep -E '^\s*\S+\.service' \
            | head -15 >&2 \
            || warn "  Could not list running services after validation"
    else
        warn "  Skipping systemctl service summary because systemd is not ready after restart"
        print_container_state "$container_name" "  "
        timeout 10 docker logs --tail 120 "$container_name" >&2 || true
    fi

    # Cleanup validation container
    docker stop -t 10 "$container_name" >/dev/null 2>&1 || true
    docker rm -f "$container_name" >/dev/null 2>&1 || true
    remove_from_cleanup "$container_name"

    log "Validation complete (result: $validation_state)"
    
    # Return validation result for provenance
    printf -v "$__out" '%s' "$validation_state"
}

#######################################
# BUILD PROVENANCE
# Records build metadata for reproducibility and audit trails
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

    # Get hostname safely
    local build_hostname
    build_hostname=$(hostname 2>/dev/null || echo 'unknown')

    log "Writing build provenance to: $provenance_file"

    # Use jq for safe JSON generation (no escaping issues)
    jq -n \
        --arg version "$VERSION" \
        --arg arch "$arch" \
        --arg image_tag "$image_tag" \
        --arg image_digest "$image_digest" \
        --argjson image_size_bytes "$image_size" \
        --arg built_at "$BUILD_DATE" \
        --arg installer_url "$installer_url" \
        --arg validation_result "$validation_result" \
        --arg script "docker/build.sh" \
        --arg hostname "$build_hostname" \
        '{
            version: $version,
            arch: $arch,
            image_tag: $image_tag,
            image_digest: $image_digest,
            image_size_bytes: $image_size_bytes,
            built_at: $built_at,
            installer_url: $installer_url,
            validation_result: $validation_result,
            capabilities_required: ["NET_ADMIN", "NET_RAW"],
            runtime_mounts_required: ["/sys/fs/cgroup:rw"],
            cgroupns: "host",
            phases_completed: {
                extraction: true,
                load: true,
                runtime_build: true,
                validation: $validation_result
            },
            builder: {
                script: $script,
                hostname: $hostname
            }
        }' > "$provenance_file"
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
    local output_dir="${BUILD_ARTIFACTS_DIR}/extract-${arch}"

    # Phase 1: Build extractor
    build_extractor_image "$arch" extractor_tag

    # Phase 2: Run extraction
    run_extraction "$arch" "$installer_url" "$extractor_tag" uosserver_tar

    # Phase 3: Load image
    load_extracted_image "$arch" "$uosserver_tar" uosserver_tag

    # Phase 4: Build runtime
    build_runtime_image "$arch" "$uosserver_tag" final_tag

    tag_local_aliases "$final_tag"

    # Phase 5: Validate (optional)
    local validation_result="skipped"
    if [[ "${SKIP_VALIDATION:-false}" != "true" ]]; then
        validate_runtime_image "$arch" "$final_tag" validation_result
    else
        warn "Skipping validation (SKIP_VALIDATION=true)"
    fi
    arch_validation_results+=("$validation_result")

    # Push if requested — refuse degraded images unless explicitly overridden.
    if [[ "$PUSH" == "true" ]]; then
        if [[ "$validation_result" == "degraded" && "${ALLOW_DEGRADED_PUBLISH:-false}" != "true" ]]; then
            fatal "Refusing to push degraded image for ${arch}. Set ALLOW_DEGRADED_PUBLISH=true to override."
        fi
        if [[ "$validation_result" == "skipped" ]]; then
            warn "Publishing ${arch} image WITHOUT validation (SKIP_VALIDATION=true)"
        fi
        log "Pushing ${final_tag}"
        docker push "$final_tag" >&2
    fi

    # Cleanup build artifacts
    log "Cleaning up build artifacts..."
    docker rmi "$extractor_tag" >/dev/null 2>&1 || true
    rm -rf "$output_dir" 2>/dev/null || true

    # Write build provenance for reproducibility tracking
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

    if (( ${#arch_validation_results[@]} != ${#arch_image_tags[@]} )); then
        fatal "Validation result tracking mismatch: ${#arch_validation_results[@]} result(s) for ${#arch_image_tags[@]} image(s)"
    fi

    local validation_result
    for validation_result in "${arch_validation_results[@]}"; do
        if [[ "$validation_result" == "degraded" && "${ALLOW_DEGRADED_PUBLISH:-false}" != "true" ]]; then
            fatal "Refusing to publish manifests: a build is degraded"
        fi
        if [[ "$validation_result" == "skipped" ]]; then
            warn "Publishing manifest for image built WITHOUT validation (SKIP_VALIDATION=true)"
        fi
    done

    local promote_latest
    promote_latest="$(resolve_promote_latest)"
    log "Promote latest: ${promote_latest}"

    if (( ${#arch_image_tags[@]} == 1 )); then
        local version_tag="${IMAGE_NAME}:${VERSION}"
        local latest_tag="${IMAGE_NAME}:latest"

        log "Publishing single-arch tags"
        docker tag "${arch_image_tags[0]}" "$version_tag"
        docker push "$version_tag"

        if [[ "$promote_latest" == "true" ]]; then
            docker tag "${arch_image_tags[0]}" "$latest_tag"
            docker push "$latest_tag"
            PUBLISHED_LATEST=true
        else
            log "Skipped latest tag promotion"
        fi
        return
    fi

    log "Creating multi-arch manifest for ${#arch_image_tags[@]} images"
    docker manifest rm "${IMAGE_NAME}:${VERSION}" >/dev/null 2>&1 || true
    if [[ "$promote_latest" == "true" ]]; then
        docker manifest rm "${IMAGE_NAME}:latest" >/dev/null 2>&1 || true
    fi
    # Push versioned manifest first; only update latest after it succeeds.
    docker manifest create "${IMAGE_NAME}:${VERSION}" "${arch_image_tags[@]}"
    docker manifest push "${IMAGE_NAME}:${VERSION}" || fatal "Versioned manifest push failed"
    if [[ "$promote_latest" == "true" ]]; then
        docker manifest create "${IMAGE_NAME}:latest" "${arch_image_tags[@]}"
        docker manifest push "${IMAGE_NAME}:latest" || fatal "latest manifest push failed"
        PUBLISHED_LATEST=true
    else
        log "Skipped latest manifest promotion"
    fi
    # Note: arch-specific remote tag cleanup (${VERSION}-amd64 etc.) requires
    # the Docker Hub API and is handled exclusively by the CI create-manifest job.
    # build.sh has no Hub credentials and cannot delete remote tags directly.
}

#######################################
# MAIN
#######################################

main() {
    require_cmd docker
    require_cmd curl
    require_cmd grep
    require_cmd sed
    require_cmd jq
    require_cmd timeout

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
        if [[ "$PUBLISHED_LATEST" == "true" ]]; then
            log "Pushed: ${IMAGE_NAME}:latest"
        else
            log "Skipped: ${IMAGE_NAME}:latest"
        fi
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
    UNIFI_OS_URL_X64           amd64 installer URL (auto-fetched from ui.com if not set)
    UNIFI_OS_URL_ARM64         arm64 installer URL (auto-fetched from ui.com if not set)
    IMAGE_NAME                 Target image name (default: giiibates/unifi-os-server)
    VERSION                    Override version tag (derived from URL if not set)
    PLATFORMS                  Target platforms (default: linux/amd64,linux/arm64)
    PUSH                       Push images (default: true)
    PROMOTE_LATEST             Promote latest tag: auto, true, false (default: auto)
    SKIP_VALIDATION            Skip runtime validation (default: false)
    ALLOW_DEGRADED_PUBLISH     Push image even when validation result is degraded (default: false)
    BUILD_ARTIFACTS_DIR        Directory for artifacts (default: /tmp/uos-build-PID)
    BUILD_DATE                 ISO8601 timestamp for reproducible builds (default: current git commit time, else current time)
    PRESERVE_FAILURE_CONTAINERS  Keep containers on failure for debugging (default: true)
    EXPORT_FAILURE_FILESYSTEM  Export container filesystem on failure (default: false, can be multi-GB)
    DOWNLOAD_API_URL           Ubiquiti download API endpoint (default: https://download.svc.ui.com/v1/downloads/products/slugs/unifi-os-server)

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
    - filesystem.tar: container filesystem export (only if EXPORT_FAILURE_FILESYSTEM=true)
    - podman-*.txt: inner podman state (if available)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    print_help
    exit 0
fi

main "$@"
