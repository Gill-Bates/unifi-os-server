#!/bin/bash
# Entrypoint for UniFi OS Server runtime container.
# Based on lemker/unifi-os-server approach - runs systemd directly.
# -E: ERR trap inherited by functions/subshells
# -e: exit on error
# -u: treat unset variables as errors (all optional vars use ${VAR:-} defaults)
# -o pipefail: pipe fails if any command in the pipe fails
set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Colors & Formatting
# -----------------------------------------------------------------------------
if [ -t 1 ] || [ "${FORCE_COLOR:-}" = "1" ]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_BLUE="\033[38;5;33m"
    C_CYAN="\033[38;5;45m"
    C_GREEN="\033[38;5;35m"
    C_YELLOW="\033[38;5;214m"
    C_RED="\033[38;5;196m"
    C_WHITE="\033[97m"
    C_GRAY="\033[38;5;244m"
else
    C_RESET="" C_BOLD="" C_DIM="" C_BLUE="" C_CYAN=""
    C_GREEN="" C_YELLOW="" C_RED="" C_WHITE="" C_GRAY=""
fi

# -----------------------------------------------------------------------------
# Banner
# -----------------------------------------------------------------------------
printf "${C_BLUE}${C_BOLD}"
cat << 'BANNER'
             _    ___ _                                                     
            (_)  / __|_)                                                    
 _   _ ____  _ _| |__ _     ___   ___     ___ _____  ____ _   _ _____  ____ 
| | | |  _ \| (_   __) |   / _ \ /___)   /___) ___ |/ ___) | | | ___ |/ ___)
| |_| | | | | | | |  | |  | |_| |___ |  |___ | ____| |    \ V /| ____| |    
|____/|_| |_|_| |_|  |_|   \___/(___/   (___/|_____)_|     \_/ |_____)_|    
BANNER
printf "${C_RESET}"
printf "  ${C_GRAY}────────────────────────────────────────────────────${C_RESET}\n"
printf "  ${C_DIM}UniFi OS Server${C_RESET}  ${C_CYAN}https://github.com/Gill-Bates/unifi-os-server${C_RESET}\n"
printf "  ${C_GRAY}────────────────────────────────────────────────────${C_RESET}\n\n"

# -----------------------------------------------------------------------------
# Logging helpers with timestamps for better observability
# -----------------------------------------------------------------------------
log_section() {
    echo ""
    printf "  ${C_BLUE}${C_BOLD}▶ %s${C_RESET}\n" "$*"
    printf "  ${C_GRAY}──────────────────────────────────────────────${C_RESET}\n"
}
log_info()    { printf "  ${C_WHITE}  %s${C_RESET}\n" "$*"; }
log_success() { printf "  ${C_GREEN}  ✔ %s${C_RESET}\n" "$*"; }
log_warn()    { printf "  ${C_YELLOW}  ⚠ %s${C_RESET}\n" "$*" >&2; }
log_error()   { printf "  ${C_RED}  ✖ %s${C_RESET}\n" "$*" >&2; }

# -----------------------------------------------------------------------------
# DRY helper for directory initialization
# -----------------------------------------------------------------------------
ensure_dir() {
    local dir="$1" owner="${2:-root}" perms="${3:-755}"
    mkdir -p "$dir"
    chown "$owner:$owner" "$dir" 2>/dev/null || true
    chmod "$perms" "$dir"
}

validate_uos_uuid() {
    local uuid="$1"

    if [ -z "$uuid" ] || printf '%s' "$uuid" | grep -Eq '[[:cntrl:]]'; then
        log_error "Invalid UOS_UUID"
        exit 1
    fi

    if ! printf '%s' "$uuid" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-5[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'; then
        log_error "Invalid UOS_UUID: $uuid"
        exit 1
    fi
}

write_uos_uuid() {
    local uuid="$1"
    validate_uos_uuid "$uuid"
    printf '%s\n' "$uuid" > /data/uos_uuid
}

validate_system_ip() {
    local system_ip="$1"

    if [ -z "$system_ip" ] || printf '%s' "$system_ip" | grep -Eq '[[:cntrl:]]'; then
        log_error "Invalid UOS_SYSTEM_IP"
        exit 1
    fi

    # Conservative allowlist for adoption targets. This blocks control chars
    # and shell-breaking input, but is not a full RFC-compliant host/IP parser.
    if ! printf '%s' "$system_ip" | grep -Eq '^([A-Za-z0-9.-]+|[0-9a-fA-F:]+)$'; then
        log_error "Invalid UOS_SYSTEM_IP: $system_ip"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Validate required environment variables (fail-fast)
# -----------------------------------------------------------------------------
if [ -z "${UOS_SERVER_VERSION:-}" ]; then
    log_error "UOS_SERVER_VERSION is not set"
    exit 1
fi

log_section "Configuration"

# -----------------------------------------------------------------------------
# Persist UOS_UUID env var
# UniFi OS expects a UUID with version nibble '5' at position 15 (0-indexed 14).
# This is cosmetic - UniFi does not cryptographically validate UUIDv5, it just
# checks the format. We generate a random UUID and set the version nibble to '5'.
# -----------------------------------------------------------------------------
if [ ! -f /data/uos_uuid ]; then
    if [ -n "${UOS_UUID:-}" ]; then
        write_uos_uuid "$UOS_UUID"
        log_success "UOS_UUID: $UOS_UUID"
    else
        UUID=$(cat /proc/sys/kernel/random/uuid)
        # Set version nibble (position 14, 0-indexed) to '5' for UUIDv5 format
        UOS_UUID="${UUID:0:14}5${UUID:15}"
        write_uos_uuid "$UOS_UUID"
        log_success "UOS_UUID: $UOS_UUID (generated)"
    fi
else
    log_success "UOS_UUID: $(cat /data/uos_uuid) (existing)"
fi

# Read version from env and write version string
echo "UOSSERVER.0000000.$UOS_SERVER_VERSION.0000000.000000.0000" > /usr/lib/version
log_success "Version: $UOS_SERVER_VERSION"

# Detect architecture and set firmware platform
ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" = "amd64" ]; then
    FIRMWARE_PLATFORM=linux-x64
elif [ "$ARCH" = "arm64" ]; then
    FIRMWARE_PLATFORM=arm64
else
    log_error "FIRMWARE_PLATFORM not found for $ARCH"
    exit 1
fi

echo "$FIRMWARE_PLATFORM" > /usr/lib/platform
log_success "Platform: $FIRMWARE_PLATFORM"

# Create eth0 alias to tap0 (requires NET_ADMIN cap & macvlan kernel module loaded on host)
# This is OPTIONAL - some setups don't have tap0 or macvlan support.
if [ ! -d "/sys/devices/virtual/net/eth0" ] && [ -d "/sys/devices/virtual/net/tap0" ]; then
    if ip link add name eth0 link tap0 type macvlan 2>/dev/null; then
        if ! ip link set eth0 up 2>/dev/null; then
            log_warn "eth0 macvlan alias up failed — removing half-configured interface"
            ip link del eth0 2>/dev/null || true
        fi
    else
        log_warn "macvlan setup failed (tap0 exists but macvlan unavailable), continuing without eth0 alias"
    fi
fi

# Initialize service directories
ensure_dir "/var/log/nginx" "nginx" "755"
ensure_dir "/var/log/mongodb" "mongodb" "755"
ensure_dir "/var/log/rabbitmq" "rabbitmq" "755"
if [ -d "/var/lib/mongodb" ] && [ "$(stat -c '%U:%G' /var/lib/mongodb 2>/dev/null || true)" != "mongodb:mongodb" ]; then
    chown -R mongodb:mongodb "/var/lib/mongodb" 2>/dev/null || true
fi

# Initialize unifi-core config dirs (required for unifi-core service to start)
if [ ! -d "/data/unifi-core/config/http" ]; then
    mkdir -p "/data/unifi-core/config/http"
    chown -R root:root /data/unifi-core/config
    chmod 755 /data/unifi-core/config
    chmod 755 /data/unifi-core/config/http
fi

# Several UniFi services can take multiple minutes to bootstrap on first boot.
# Raise their systemd start timeout so systemd does not kill them prematurely.
set_start_timeout_override() {
    local service_name="$1"
    mkdir -p "/etc/systemd/system/${service_name}.service.d"
    {
        echo "[Service]"
        echo "TimeoutStartSec=10min"
    } > "/etc/systemd/system/${service_name}.service.d/timeout.conf"
}

for service_name in unifi-core ulp-go unifi-credential-server uid-agent ucs-agent unifi-directory unifi; do
    set_start_timeout_override "$service_name"
done

# -----------------------------------------------------------------------------
# Pre-seed PostgreSQL databases and users BEFORE systemd starts services.
# The upstream pre-start.sh scripts are NOT idempotent - they fail hard if
# createdb/createuser encounters "already exists". This causes race conditions
# on first boot when multiple services start in parallel.
#
# Fix: Start PostgreSQL early, create all required DBs/users idempotently,
# then let systemd handle the services normally.
# -----------------------------------------------------------------------------
preseed_postgres() {
    local start_time=$SECONDS
    
    local pg_data="/var/lib/postgresql/14/main"
    local pg_bin="/usr/lib/postgresql/14/bin"
    local pg_log="/var/log/postgresql/preseed.log"
    local pg_run="/var/run/postgresql"
    
    # This function is called from an if-statement below, which suppresses bash
    # errexit for the function body. Keep setup steps explicitly checked so an
    # unexpected failure here does not silently fall through.
    mkdir -p /var/log/postgresql || return 1
    chown postgres:postgres /var/log/postgresql || return 1
    touch "$pg_log" || return 1
    chown postgres:postgres "$pg_log" || return 1
    chmod 640 "$pg_log" || return 1

    # pg_ctl on Debian expects the runtime socket/lock dir to exist and be writable.
    mkdir -p "$pg_run" || return 1
    chown postgres:postgres "$pg_run" || return 1
    chmod 775 "$pg_run" || return 1
    
    # Ensure data directory exists with correct permissions
    mkdir -p "$pg_data" || return 1
    chown -R postgres:postgres "$pg_data" || return 1
    chmod 700 "$pg_data" || return 1
    
    # Check for initialized cluster (PG_VERSION file), not just directory existence.
    # An empty mounted volume would pass directory check but fail to start.
    if [ ! -f "$pg_data/PG_VERSION" ]; then
        log_info "Initializing PostgreSQL cluster..."
        if ! runuser -u postgres -- "$pg_bin/initdb" -D "$pg_data" >> "$pg_log" 2>&1; then
            log_error "PostgreSQL initdb failed (see $pg_log)"
            return 1
        fi
        log_success "Cluster initialized"
    else
        log_success "Cluster exists"
    fi
    
    # Start PostgreSQL temporarily with shorter timeout (fail fast if broken)
    log_info "Starting PostgreSQL..."
    if ! runuser -u postgres -- "$pg_bin/pg_ctl" -D "$pg_data" \
         -l "$pg_log" start -w -t 30 >/dev/null 2>&1; then
        log_warn "PostgreSQL temporary start failed, will retry on next boot"
        log_warn "Likely causes: invalid pgdata, missing runtime dirs, or permission mismatch"
        log_warn "Last PostgreSQL preseed log lines:"
        tail -n 20 "$pg_log" 2>/dev/null | sed 's/^/       /' >&2 || true
        return 1
    fi
    
    # Wait for PostgreSQL to accept connections (quick sanity check)
    local retries=10
    while [ $retries -gt 0 ]; do
        if runuser -u postgres -- "$pg_bin/pg_isready" -q 2>/dev/null; then
            break
        fi
        sleep 1
        retries=$((retries - 1))
    done
    
    if [ $retries -eq 0 ]; then
        log_warn "PostgreSQL not accepting connections, will retry on next boot"
        runuser -u postgres -- "$pg_bin/pg_ctl" -D "$pg_data" stop -m fast >> "$pg_log" 2>&1 || true
        return 1
    fi
    log_success "PostgreSQL running"
    
    # -------------------------------------------------------------------------
    # Database and user configurations.
    # NOTE: This list is derived empirically from UniFi OS Server 5.0.x.
    # Future versions may add/remove services. If services fail with
    # "database does not exist", add them here and bump the preseed marker.
    # Format: "dbname:owner"
    # -------------------------------------------------------------------------
    local db_configs=(
        "ulp-go:ulp-go"
        "ulp-go-syslog:ulp-go"
        "uid:uid"
        "unifi-credential-server:unifi-credential-server"
        "ucs-user-assets:unifi-credential-server"
        "ucs-agent:ucs-agent"
        "unifi-directory:unifi-directory"
        "unifi-identity-update:unifi-identity-update"
    )
    
    log_info "Creating databases..."
    local created=0 existed=0 failed=0
    
    for config in "${db_configs[@]}"; do
        local dbname="${config%%:*}"
        local owner="${config##*:}"

        # db_configs is a static hardcoded array. Validate identifiers here so
        # that if the list is ever made dynamic this check catches unsafe input.
        if ! printf '%s' "${dbname}${owner}" | grep -Eq '^[a-zA-Z0-9_-]+$'; then
            log_error "Refusing unsafe db/owner identifier: $config"
            exit 1
        fi

        # Create user only if it does not exist; distinguish "already exists"
        # (expected) from a real error (cluster down, permission denied).
        if ! runuser -u postgres -- "$pg_bin/psql" -tAc \
             "SELECT 1 FROM pg_roles WHERE rolname='${owner}'" 2>"$pg_log" | grep -q 1; then
            if ! runuser -u postgres -- "$pg_bin/psql" -c "CREATE USER \"${owner}\";" >> "$pg_log" 2>&1; then
                log_error "CREATE USER ${owner} failed (see $pg_log)"
                failed=$((failed + 1))
                continue
            fi
        fi

        # Create database if not exists
        if ! runuser -u postgres -- "$pg_bin/psql" -lqt | cut -d \| -f 1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -Fxq "$dbname"; then
            if runuser -u postgres -- "$pg_bin/createdb" -O "$owner" "$dbname" >> "$pg_log" 2>&1; then
                created=$((created + 1))
            else
                log_error "Failed: $dbname"
                failed=$((failed + 1))
            fi
        else
            existed=$((existed + 1))
        fi

        # Grant privileges; failure here is not idempotent-safe to suppress.
        if ! runuser -u postgres -- "$pg_bin/psql" -c \
             "GRANT ALL PRIVILEGES ON DATABASE \"${dbname}\" TO \"${owner}\";" >> "$pg_log" 2>&1; then
            log_error "GRANT on ${dbname} to ${owner} failed (see $pg_log)"
            failed=$((failed + 1))
        fi
    done
    
    # Stop PostgreSQL - systemd will start it properly
    runuser -u postgres -- "$pg_bin/pg_ctl" -D "$pg_data" stop -m fast >> "$pg_log" 2>&1 || true
    
    local elapsed=$((SECONDS - start_time))
    
    if [ "$failed" -gt 0 ]; then
        log_error "Databases: $created new, $existed existing, $failed failed (${elapsed}s)"
        return 1
    fi
    
    log_success "Databases: $created new, $existed existing (${elapsed}s)"
}

# Preseed marker is versioned to allow re-seeding on image upgrades.
# If new DBs are added to the list above, increment this version.
# Marker lives in pg_data so it stays in sync with actual PostgreSQL state.
PRESEED_MARKER_VERSION="2"
PG_DATA="/var/lib/postgresql/14/main"
PRESEED_MARKER="${PG_DATA}/.uos_postgres_preseeded_v${PRESEED_MARKER_VERSION}"

# Ensure pg_data exists before checking marker (handles first boot with empty volume)
if ! mkdir -p "$PG_DATA" || ! chown postgres:postgres "$PG_DATA"; then
    log_error "Cannot prepare $PG_DATA — check volume mount and permissions"
    exit 1
fi

if [ ! -f "$PRESEED_MARKER" ]; then
    log_section "PostgreSQL Setup"
    if preseed_postgres; then
        touch "$PRESEED_MARKER"
        chown postgres:postgres "$PRESEED_MARKER"
    else
        log_warn "Pre-seeding incomplete; marker not written"
    fi
else
    log_section "PostgreSQL Setup"
    log_success "Already initialized (skipped)"
fi

# Apply Synology patches
SYS_VENDOR="/sys/class/dmi/id/sys_vendor"
if { [ -f "$SYS_VENDOR" ] && grep -qs "Synology" "$SYS_VENDOR"; } \
    || [ "${HARDWARE_PLATFORM:-}" = "synology" ]; then

    if [ -n "${HARDWARE_PLATFORM+1}" ]; then
        log_info "Setting HARDWARE_PLATFORM to $HARDWARE_PLATFORM"
    else
        log_info "Synology hardware found, applying patches..."
    fi

    # Set postgresql overrides
    mkdir -p /etc/systemd/system/postgresql@14-main.service.d
    {
        echo "[Service]"
        echo "PIDFile="
    } > /etc/systemd/system/postgresql@14-main.service.d/override.conf

    # Set rabbitmq overrides
    mkdir -p /etc/systemd/system/rabbitmq-server.service.d
    {
        echo "[Service]"
        echo "Type=simple"
    } > /etc/systemd/system/rabbitmq-server.service.d/override.conf

    # Set ulp-go overrides
    mkdir -p /etc/systemd/system/ulp-go.service.d
    {
        echo "[Service]"
        echo "Type=simple"
    } > /etc/systemd/system/ulp-go.service.d/override.conf

    log_success "Synology patches applied"
fi

# Set UOS_SYSTEM_IP for device adoption
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"
if [ -n "${UOS_SYSTEM_IP:-}" ]; then
    validate_system_ip "$UOS_SYSTEM_IP"
    mkdir -p "$(dirname "$UNIFI_SYSTEM_PROPERTIES")"
    if [ ! -f "$UNIFI_SYSTEM_PROPERTIES" ]; then
        printf 'system_ip=%s\n' "$UOS_SYSTEM_IP" > "$UNIFI_SYSTEM_PROPERTIES"
    else
        if grep -q "^system_ip=.*" "$UNIFI_SYSTEM_PROPERTIES"; then
            tmp_file=$(mktemp)
            grep -v '^system_ip=' "$UNIFI_SYSTEM_PROPERTIES" > "$tmp_file"
            printf 'system_ip=%s\n' "$UOS_SYSTEM_IP" >> "$tmp_file"
            install -m 0644 "$tmp_file" "$UNIFI_SYSTEM_PROPERTIES"
            rm -f "$tmp_file"
        else
            printf 'system_ip=%s\n' "$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
        fi
    fi
    log_success "System IP: $UOS_SYSTEM_IP"
fi

log_section "Starting Services"
log_info "Handing off to systemd..."
printf "\n  ${C_GRAY}──────────────────────────────────────────────${C_RESET}\n\n"

# Keep journal in RAM only — no on-disk journal needed in a container.
mkdir -p /etc/systemd/journald.conf.d
{
    echo "[Journal]"
    echo "Storage=volatile"
} > /etc/systemd/journald.conf.d/docker.conf

# Forward journal output to Docker logs.
#
# Why not TTYPath=/dev/stdout in journald.conf?
# When systemd starts journald as a service, it sets up journald's stdio
# independently (not inheriting PID 1's fds).  Opening /dev/stdout from
# inside journald reaches journald's own fd 1, not Docker's log pipe —
# so nothing appears in `docker logs`.
#
# Instead, start a journalctl follower HERE, before exec'ing into systemd.
# The subshell retains its own copy of fd 1 (= Docker's log pipe, inherited
# from this entrypoint process) and continues running as an orphan re-parented
# to systemd after exec.  systemd does not kill orphaned processes during
# normal operation; they are only cleaned up on container shutdown.
(
    # Wait for journald's socket — it becomes available a few seconds
    # after systemd starts journald.service.
    i=0
    while [ $i -lt 60 ] && [ ! -S /run/systemd/journal/socket ]; do
        sleep 1
        i=$((i + 1))
    done
    if [ ! -S /run/systemd/journal/socket ]; then
        printf '[journal-forwarder] journald socket not available after 60 s\n' >&2
        exit 0
    fi
    exec journalctl -f --output=short-iso-precise --no-hostname 2>/dev/null
) &

# Hand off to systemd (becomes PID 1).
exec /sbin/init
