#!/bin/sh
# Stub for systemctl to work without systemd running (for container builds).
# The upstream installer only needs service-management commands to succeed
# while it lays down unit files in the image filesystem.
LOG_FILE="/var/log/systemctl-stub.log"

# Debug logging
echo "[systemctl-stub] Called with: $*" >> "$LOG_FILE" 2>/dev/null || true

command="${1:-}"
shift || true

case "$command" in
    daemon-reload|daemon-reexec|reset-failed)
        exit 0
        ;;
    enable|disable|reenable|preset|mask|unmask|start|stop|restart|try-restart|reload)
        exit 0
        ;;
    is-enabled)
        printf 'enabled\n'
        exit 0
        ;;
    is-active)
        # Mirror real systemctl semantics: inactive services return non-zero.
        # If the installer ever needs a unit to appear active during extraction,
        # add that unit explicitly with a documented rationale rather than
        # blanket-faking success for every is-active probe.
        printf 'inactive\n'
        exit 3
        ;;
    is-system-running)
        # Return "running" to satisfy installer's systemd-ready check
        echo "[systemctl-stub] is-system-running called, returning 'running'" >> "$LOG_FILE" 2>/dev/null || true
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
        # Fail on unknown commands rather than silently returning success.
        # If a new installer verb breaks the build, add it explicitly above with
        # a documented rationale — do not widen this catch-all back to exit 0.
        echo "[systemctl-stub] UNSUPPORTED command (exit 1): $command $*" >> "$LOG_FILE" 2>/dev/null || true
        exit 1
        ;;
esac
