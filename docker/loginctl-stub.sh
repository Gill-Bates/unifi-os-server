#!/bin/sh
# Stub for loginctl to work without systemd running (for container builds)
# Handles enable-linger by creating the linger file directly

case "$1" in
    enable-linger)
        user="${2:-}"
        if [ -n "$user" ]; then
            mkdir -p /var/lib/systemd/linger
            touch "/var/lib/systemd/linger/$user"
            echo "Linger enabled for $user (stub)"
        fi
        exit 0
        ;;
    disable-linger)
        user="${2:-}"
        if [ -n "$user" ]; then
            rm -f "/var/lib/systemd/linger/$user"
            echo "Linger disabled for $user (stub)"
        fi
        exit 0
        ;;
    *)
        if [ -x /usr/bin/loginctl.real ]; then
            exec /usr/bin/loginctl.real "$@"
        fi
        exit 0
        ;;
esac
