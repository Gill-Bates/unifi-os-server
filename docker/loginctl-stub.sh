#!/bin/sh
# Stub for loginctl to work without systemd running (for container builds)
# Handles enable-linger by creating the linger file directly

valid_user() {
    case "$1" in
        ""|*/*|*..*|*[!A-Za-z0-9_.@-]*)
            echo "Invalid user: $1" >&2
            exit 1
            ;;
    esac
}

require_user() {
    if [ -z "${1:-}" ]; then
        echo "loginctl stub: missing user argument" >&2
        exit 1
    fi
}

case "$1" in
    enable-linger)
        user="${2:-}"
        require_user "$user"
        valid_user "$user"
        mkdir -p /var/lib/systemd/linger
        touch "/var/lib/systemd/linger/$user"
        echo "Linger enabled for $user (stub)"
        exit 0
        ;;
    disable-linger)
        user="${2:-}"
        require_user "$user"
        valid_user "$user"
        rm -f "/var/lib/systemd/linger/$user"
        echo "Linger disabled for $user (stub)"
        exit 0
        ;;
    user-status)
        # Fake a successful user-status to avoid the installer spinning
        # Be lenient: if user doesn't exist yet, fake UID 1000
        user="${2:-}"
        require_user "$user"
        valid_user "$user"
        uid=$(id -u "$user" 2>/dev/null || echo "1000")
        printf '%s (%s)\n' "$user" "$uid"
        printf '           State: active\n'
        printf '            Unit: user-%s.slice\n' "$uid"
        exit 0
        ;;
    *)
        if [ -x /usr/bin/loginctl.real ]; then
            exec /usr/bin/loginctl.real "$@"
        fi
        echo "loginctl stub: unsupported command: ${1:-}" >&2
        exit 1
        ;;
esac
