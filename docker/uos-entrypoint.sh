#!/bin/bash
# Entrypoint for UniFi OS Server runtime container.
# Based on lemker/unifi-os-server approach - runs systemd directly.
set -e

# -----------------------------------------------------------------------------
# Logging helpers with timestamps for better observability
# -----------------------------------------------------------------------------
log_info()  { echo "[$(date -Iseconds)] INFO:  $*"; }
log_warn()  { echo "[$(date -Iseconds)] WARN:  $*" >&2; }
log_error() { echo "[$(date -Iseconds)] ERROR: $*" >&2; }

# -----------------------------------------------------------------------------
# DRY helper for directory initialization
# -----------------------------------------------------------------------------
ensure_dir() {
    local dir="$1" owner="${2:-root}" perms="${3:-755}"
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        chown "$owner:$owner" "$dir" 2>/dev/null || true
        chmod "$perms" "$dir"
    fi
}

# -----------------------------------------------------------------------------
# Validate required environment variables (fail-fast)
# -----------------------------------------------------------------------------
if [ -z "${UOS_SERVER_VERSION:-}" ]; then
    log_error "UOS_SERVER_VERSION is not set"
    exit 1
fi

# -----------------------------------------------------------------------------
# Persist UOS_UUID env var
# UniFi OS expects a UUID with version nibble '5' at position 15 (0-indexed 14).
# This is cosmetic - UniFi does not cryptographically validate UUIDv5, it just
# checks the format. We generate a random UUID and set the version nibble to '5'.
# -----------------------------------------------------------------------------
if [ ! -f /data/uos_uuid ]; then
    if [ -n "${UOS_UUID+1}" ]; then
        log_info "Setting UOS_UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    else
        log_info "No UOS_UUID present, generating..."
        UUID=$(cat /proc/sys/kernel/random/uuid)
        # Set version nibble (position 14, 0-indexed) to '5' for UUIDv5 format
        UOS_UUID=$(echo "$UUID" | sed 's/./5/15')
        log_info "Setting UOS_UUID to $UOS_UUID"
        echo "$UOS_UUID" > /data/uos_uuid
    fi
fi

# Read version from env and write version string
log_info "Setting UOS_SERVER_VERSION to $UOS_SERVER_VERSION"
echo "UOSSERVER.0000000.$UOS_SERVER_VERSION.0000000.000000.0000" > /usr/lib/version

# Detect architecture and set firmware platform
ARCH="$(dpkg --print-architecture)"
if [ "$ARCH" == "amd64" ]; then
    FIRMWARE_PLATFORM=linux-x64
elif [ "$ARCH" == "arm64" ]; then
    FIRMWARE_PLATFORM=arm64
else
    log_error "FIRMWARE_PLATFORM not found for $ARCH"
    exit 1
fi

log_info "Setting FIRMWARE_PLATFORM to $FIRMWARE_PLATFORM"
echo "$FIRMWARE_PLATFORM" > /usr/lib/platform

# Create eth0 alias to tap0 (requires NET_ADMIN cap & macvlan kernel module loaded on host)
# This is OPTIONAL - some setups don't have tap0 or macvlan support.
if [ ! -d "/sys/devices/virtual/net/eth0" ] && [ -d "/sys/devices/virtual/net/tap0" ]; then
    if ip link add name eth0 link tap0 type macvlan 2>/dev/null; then
        ip link set eth0 up || log_warn "Failed to bring up eth0 macvlan alias"
    else
        log_warn "macvlan setup failed (tap0 exists but macvlan unavailable), continuing without eth0 alias"
    fi
fi

# Initialize service directories
ensure_dir "/var/log/nginx" "nginx" "755"
ensure_dir "/var/log/mongodb" "mongodb" "755"
ensure_dir "/var/log/rabbitmq" "rabbitmq" "755"
chown -R mongodb:mongodb "/var/lib/mongodb" 2>/dev/null || true

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
    log_info "Pre-seeding PostgreSQL databases..."
    
    local pg_data="/var/lib/postgresql/14/main"
    local pg_bin="/usr/lib/postgresql/14/bin"
    
    # Ensure data directory exists with correct permissions
    mkdir -p "$pg_data"
    chown -R postgres:postgres "$pg_data"
    chmod 700 "$pg_data"
    
    # Check for initialized cluster (PG_VERSION file), not just directory existence.
    # An empty mounted volume would pass directory check but fail to start.
    if [ ! -f "$pg_data/PG_VERSION" ]; then
        log_info "Initializing PostgreSQL cluster..."
        if ! runuser -u postgres -- "$pg_bin/initdb" -D "$pg_data" 2>/dev/null; then
            log_error "PostgreSQL initdb failed"
            return 1
        fi
    fi
    
    # Start PostgreSQL temporarily with shorter timeout (fail fast if broken)
    if ! runuser -u postgres -- "$pg_bin/pg_ctl" -D "$pg_data" \
         -l /var/log/postgresql/startup.log start -w -t 30 2>/dev/null; then
        log_warn "PostgreSQL temporary start failed, skipping pre-seed (services will bootstrap themselves)"
        return 0
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
        log_warn "PostgreSQL not accepting connections, skipping pre-seed"
        runuser -u postgres -- "$pg_bin/pg_ctl" -D "$pg_data" stop -m fast 2>/dev/null || true
        return 0
    fi
    
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
    
    for config in "${db_configs[@]}"; do
        local dbname="${config%%:*}"
        local owner="${config##*:}"
        
        # Create user if not exists (ignore errors)
        runuser -u postgres -- "$pg_bin/psql" -c "CREATE USER \"$owner\";" 2>/dev/null || true
        
        # Create database if not exists
        if ! runuser -u postgres -- "$pg_bin/psql" -lqt | cut -d \| -f 1 | grep -qw "$dbname"; then
            if runuser -u postgres -- "$pg_bin/createdb" -O "$owner" "$dbname" 2>/dev/null; then
                log_info "  Created database: $dbname (owner: $owner)"
            fi
        fi
        
        # Grant privileges (idempotent)
        runuser -u postgres -- "$pg_bin/psql" -c "GRANT ALL PRIVILEGES ON DATABASE \"$dbname\" TO \"$owner\";" 2>/dev/null || true
    done
    
    # Stop PostgreSQL - systemd will start it properly
    runuser -u postgres -- "$pg_bin/pg_ctl" -D "$pg_data" stop -m fast 2>/dev/null || true
    
    local elapsed=$((SECONDS - start_time))
    log_info "PostgreSQL pre-seeding complete (${elapsed}s)"
}

# Preseed marker is versioned to allow re-seeding on image upgrades.
# If new DBs are added to the list above, increment this version.
PRESEED_MARKER_VERSION="1"
PRESEED_MARKER="/data/.postgres_preseeded_v${PRESEED_MARKER_VERSION}"

if [ ! -f "$PRESEED_MARKER" ]; then
    preseed_postgres
    touch "$PRESEED_MARKER"
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

    log_info "Synology patches applied!"
fi

# Set UOS_SYSTEM_IP for device adoption
UNIFI_SYSTEM_PROPERTIES="/var/lib/unifi/system.properties"
if [ -n "${UOS_SYSTEM_IP+1}" ] && [ -n "$UOS_SYSTEM_IP" ]; then
    log_info "Setting UOS_SYSTEM_IP to $UOS_SYSTEM_IP"
    mkdir -p "$(dirname "$UNIFI_SYSTEM_PROPERTIES")"
    if [ ! -f "$UNIFI_SYSTEM_PROPERTIES" ]; then
        echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
    else
        if grep -q "^system_ip=.*" "$UNIFI_SYSTEM_PROPERTIES"; then
            sed -i 's/^system_ip=.*/system_ip='"$UOS_SYSTEM_IP"'/' "$UNIFI_SYSTEM_PROPERTIES"
        else
            echo "system_ip=$UOS_SYSTEM_IP" >> "$UNIFI_SYSTEM_PROPERTIES"
        fi
    fi
fi

# Start systemd
exec /sbin/init
