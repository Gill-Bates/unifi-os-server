#!/bin/sh
# Stub for systemctl to work without systemd running (for container builds).
# The upstream installer only needs service-management commands to succeed
# while it lays down unit files in the image filesystem.

command="${1:-}"
if [ -z "$command" ]; then
    echo "systemctl stub: missing command" >&2
    exit 1
fi
shift

unit_symlink_exists() {
    local unit_name="$1"
    find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -type l -name "$unit_name" 2>/dev/null | grep -q .
}

case "$command" in
    daemon-reload|daemon-reexec|reset-failed)
        exit 0
        ;;
    enable|disable|reenable|preset|mask|unmask)
        if [ -x /usr/bin/systemctl.real ]; then
            exec /usr/bin/systemctl.real "$command" "$@"
        fi
        echo "systemctl stub: unsupported state-changing command without systemctl.real: $command" >&2
        exit 1
        ;;
    start|stop|restart|try-restart|reload)
        exit 0
        ;;
    is-enabled)
        unit="${1:-}"
        if [ -z "$unit" ]; then
            echo "systemctl stub: missing unit" >&2
            exit 1
        fi

        if unit_symlink_exists "$unit"; then
            printf 'enabled\n'
            exit 0
        fi

        printf 'disabled\n'
        exit 1
        ;;
    is-active)
        # Return 0 (success/active) to prevent installer from waiting
        # for services that can't start in container environment
        printf 'inactive\n'
        exit 0
        ;;
    is-system-running)
        # Return "running" to satisfy installer's systemd-ready check
        printf 'running\n'
        exit 0
        ;;
    status|show|list-unit-files|list-units)
        exit 0
        ;;
    *)
        if [ -x /usr/bin/systemctl.real ]; then
            exec /usr/bin/systemctl.real "$command" "$@"
        fi
        echo "systemctl stub: unsupported command: $command" >&2
        exit 1
        ;;
esac
