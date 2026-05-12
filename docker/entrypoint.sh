#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${UOS_INSTALLER_URL:-}" ]]; then
    # Explicit URL override takes precedence
    installer_url="${UOS_INSTALLER_URL}"
elif [[ -n "${UOS_INSTALLER_URL_AMD64:-}" ]]; then
    installer_url="${UOS_INSTALLER_URL_AMD64}"
else
    installer_url=""
fi

installer_path="${UOS_INSTALLER_PATH:-/opt/uos/installer/uos-installer}"
installer_checksum="${UOS_INSTALLER_CHECKSUM:-}"
installer_lock_path="${UOS_INSTALLER_LOCK_PATH:-/var/lock/uos-installer.lock}"
install_on_boot="${UOS_INSTALL_ON_BOOT:-1}"
force_install="${UOS_FORCE_INSTALL:-1}"
network_mode="${UOS_NETWORK_MODE:-pasta}"
web_port="${UOS_WEB_PORT:-8443}"
data_dir="${UOS_DATA_DIR:-/var/lib/uosserver}"
config_dir="${UOS_CONFIG_DIR:-/etc/uosserver}"
uos_home="${UOS_HOME:-/home/uosserver}"
uos_uid="${UOS_UID:-$(id -u uosserver 2>/dev/null || echo 1000)}"
run_dir="/run/user/${uos_uid}"
uos_system_ip="${UOS_SYSTEM_IP:-}"
hardware_platform="${HARDWARE_PLATFORM:-}"
container_driver="${UOS_CONTAINER_DRIVER:-vfs}"

log() {
    printf '[entrypoint] %s\n' "$*"
}

print_banner() {
    cat <<'EOF'
             _  __ _    ___  ____                                 
 _   _ _ __ (_)/ _(_)  / _ \/ ___|   ___  ___ _ ____   _____ _ __ 
| | | | '_ \| | |_| | | | | \___ \  / __|/ _ \ '__\ \ / / _ \ '__|
| |_| | | | | |  _| | | |_| |___) | \__ \  __/ |   \ V /  __/ |   
 \__,_|_| |_|_|_| |_|  \___/|____/  |___/\___|_|    \_/ \___|_|   
 
EOF
}

is_true() {
    case "${1,,}" in
        1|true|yes|on)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "missing required command: $1"
        exit 1
    }
}

has_uos_installation() {
    [[ -x /usr/local/bin/uosserver || -x /var/lib/uosserver/bin/uosserver-service ]]
}

ensure_layout() {
    local -a owned_paths

    mkdir -p \
        "$(dirname "$installer_path")" \
        "$(dirname "$installer_lock_path")" \
        "$data_dir" \
        "$config_dir" \
        /etc/containers \
        /var/lib/containers/storage \
        /var/log/uosserver \
        "$uos_home" \
        "$uos_home/.config/containers" \
        "$uos_home/.local/share/containers/storage" \
        "$run_dir"

    owned_paths=(
        "$uos_home"
        "$run_dir"
        "$data_dir"
        "$config_dir"
        /var/log/uosserver
    )

    if [[ $EUID -eq 0 ]]; then
        chown -R "$uos_uid:$uos_uid" "${owned_paths[@]}"
    fi

    if [[ $EUID -eq 0 || -O "$run_dir" ]]; then
        chmod 700 "$run_dir"
    fi

    export XDG_RUNTIME_DIR="$run_dir"

    if [[ ! -f /etc/containers/storage.conf ]]; then
        cat > /etc/containers/storage.conf <<'EOF'
[storage]
# vfs is slower and larger than overlay, but works reliably in nested/containerized Podman setups.
driver = "__UOS_CONTAINER_DRIVER__"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"

[storage.options]
mount_program = ""
EOF
        sed -i "s/__UOS_CONTAINER_DRIVER__/${container_driver}/" /etc/containers/storage.conf
    fi

    if [[ ! -f /etc/containers/containers.conf ]]; then
        cat > /etc/containers/containers.conf <<'EOF'
[engine]
cgroup_manager = "cgroupfs"
events_logger = "file"
EOF
    fi
}

# Configure UOS_SYSTEM_IP for device adoption (from lemker/unifi-os-server)
configure_system_ip() {
    local props_file="/var/lib/unifi/system.properties"

    if [[ -z "$uos_system_ip" ]]; then
        return
    fi

    log "configuring UOS_SYSTEM_IP=$uos_system_ip"
    mkdir -p "$(dirname "$props_file")"

    if [[ ! -f "$props_file" ]]; then
        echo "system_ip=$uos_system_ip" >> "$props_file"
    elif grep -q "^system_ip=" "$props_file"; then
        sed -i "s/^system_ip=.*/system_ip=$uos_system_ip/" "$props_file"
    else
        echo "system_ip=$uos_system_ip" >> "$props_file"
    fi
}

# Apply Synology-specific patches (from lemker/unifi-os-server)
apply_synology_patches() {
    local sys_vendor="/sys/class/dmi/id/sys_vendor"

    if [[ -f "$sys_vendor" ]] && grep -qi "synology" "$sys_vendor"; then
        log "Synology hardware detected, applying patches..."
    elif [[ "$hardware_platform" == "synology" ]]; then
        log "HARDWARE_PLATFORM=synology, applying patches..."
    else
        return 0
    fi

    # PostgreSQL PIDFile override
    mkdir -p /etc/systemd/system/postgresql@14-main.service.d
    cat > /etc/systemd/system/postgresql@14-main.service.d/override.conf <<'EOF'
[Service]
PIDFile=
EOF

    # RabbitMQ type override
    mkdir -p /etc/systemd/system/rabbitmq-server.service.d
    cat > /etc/systemd/system/rabbitmq-server.service.d/override.conf <<'EOF'
[Service]
Type=simple
EOF

    # ulp-go type override
    mkdir -p /etc/systemd/system/ulp-go.service.d
    cat > /etc/systemd/system/ulp-go.service.d/override.conf <<'EOF'
[Service]
Type=simple
EOF

    log "Synology patches applied"
}

ensure_installer() {
    if [[ -x "$installer_path" ]]; then
        return
    fi

    require_cmd curl

    if [[ -z "$installer_url" ]]; then
        log "UOS_INSTALLER_URL is empty; cannot fetch installer"
        exit 1
    fi

    local tmp_path
    tmp_path="$(mktemp "${installer_path}.XXXXXX.tmp")"
    trap 'rm -f "$tmp_path"' RETURN

    log "downloading installer from $installer_url"
    curl \
        --fail \
        --show-error \
        --silent \
        --location \
        --retry 5 \
        --retry-all-errors \
        --connect-timeout 10 \
        --max-time 1200 \
        --proto '=https' \
        --tlsv1.2 \
        "$installer_url" \
        -o "$tmp_path"

    if [[ -n "$installer_checksum" ]]; then
        require_cmd sha256sum
        printf '%s  %s\n' "$installer_checksum" "$tmp_path" | sha256sum -c -
    fi

    mv "$tmp_path" "$installer_path"
    chmod +x "$installer_path"
    trap - RETURN
}

run_installer() {
    local args=("--non-interactive")

    if is_true "$force_install"; then
        args+=("--force-install")
    fi

    if [[ -n "$network_mode" ]]; then
        args+=("--network-mode" "$network_mode")
    fi

    if [[ -n "$web_port" ]]; then
        args+=("--web-port" "$web_port")
    fi

    log "running installer"
    "$installer_path" "${args[@]}"
}

start_uos() {
    local bin

    for bin in \
        /usr/local/bin/uosserver \
        /var/lib/uosserver/bin/uosserver-service
    do
        if [[ -x "$bin" ]]; then
            log "starting $bin"
            exec "$bin" "$@"
        fi
    done

    log "UOS binaries were not found after installation"
    log "Run this container with --privileged and persistent volumes; the upstream installer expects a host-like environment"
    exit 1
}

main() {
    local should_install

    require_cmd mktemp
    require_cmd flock
    print_banner
    ensure_layout
    configure_system_ip
    apply_synology_patches

    if is_true "$install_on_boot"; then
        should_install=0

        exec {lock_fd}>"$installer_lock_path"
        flock "$lock_fd"

        ensure_installer

        if ! has_uos_installation; then
            should_install=1
        elif is_true "$force_install"; then
            should_install=1
        fi

        if [[ "$should_install" == "1" ]]; then
            run_installer
            # Cleanup: Remove installer binary to save disk space (~500MB)
            if [[ -f "$installer_path" ]]; then
                log "removing installer binary to save disk space"
                rm -f "$installer_path"
            fi
        else
            log "existing UOS installation detected; skipping installer"
        fi
    else
        log "UOS_INSTALL_ON_BOOT=$install_on_boot; skipping installer"
    fi

    if [[ $# -gt 0 ]]; then
        log "executing custom command: $*"
        exec "$@"
    fi

    start_uos
}

main "$@"