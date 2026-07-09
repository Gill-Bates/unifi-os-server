#!/bin/sh
# Stub for loginctl to work without systemd running (for container builds)
# Handles enable-linger by creating the linger file directly
set -eu

# assert_valid_user validates that $1 is a non-empty, safe username and exits
# on failure.  Covers the require_user check (empty string) as the first arm of
# the case.  Separate require_user was functionally redundant — merged here with
# a distinct message for the empty case to preserve diagnostic clarity.
assert_valid_user() {
    case "$1" in
        "")
            echo "loginctl stub: missing user argument" >&2
            exit 1
            ;;
        -*)
            # Leading dash would be interpreted as an option by downstream tools.
            echo "loginctl stub: invalid user (leading dash): $1" >&2
            exit 1
            ;;
        */*)
            # Forward slash — path traversal guard.
            echo "loginctl stub: invalid user (slash): $1" >&2
            exit 1
            ;;
        *..*)
            # Dotdot — redundant to the slash check above (traversal requires a
            # slash), but kept as explicit belt-and-suspenders for "." / ".."
            # edge cases: touch "/var/lib/systemd/linger/." silently touches the
            # directory, which is wrong even though it is not a security issue.
            echo "loginctl stub: invalid user (dotdot): $1" >&2
            exit 1
            ;;
        .)
            echo "loginctl stub: invalid user (.): $1" >&2
            exit 1
            ;;
        *[!A-Za-z0-9_.@-]*)
            echo "loginctl stub: invalid user (bad chars): $1" >&2
            exit 1
            ;;
    esac
}

# Strip known no-op global options that loginctl accepts before the verb so
# that "loginctl --no-pager enable-linger foo" reaches the correct case arm.
# If the installer ever prepends other global flags, add them here.
while [ $# -gt 0 ]; do
    case "$1" in
        --no-pager|--no-ask-password|--no-legend|-q|--quiet)
            shift
            ;;
        *)
            break
            ;;
    esac
done

case "${1:-}" in
    enable-linger)
        shift
        # Real loginctl accepts multiple users: enable-linger alice bob carol
        if [ $# -eq 0 ]; then
            echo "loginctl stub: enable-linger requires at least one user argument" >&2
            exit 1
        fi
        mkdir -p /var/lib/systemd/linger
        for user do
            assert_valid_user "$user"
            touch "/var/lib/systemd/linger/$user"
            # Silent on success — matches real loginctl behaviour.
            # Diagnostic goes to stderr so it does not appear on stdout.
            echo "loginctl stub: linger enabled for $user" >&2
        done
        exit 0
        ;;
    disable-linger)
        shift
        if [ $# -eq 0 ]; then
            echo "loginctl stub: disable-linger requires at least one user argument" >&2
            exit 1
        fi
        for user do
            assert_valid_user "$user"
            rm -f "/var/lib/systemd/linger/$user"
            echo "loginctl stub: linger disabled for $user" >&2
        done
        exit 0
        ;;
    user-status)
        shift
        if [ $# -eq 0 ]; then
            echo "loginctl stub: user-status requires a user argument" >&2
            exit 1
        fi
        assert_valid_user "$1"
        user="$1"
        # Fake a successful user-status to avoid the installer spinning.
        # id -u may fail if the user has not been created yet at this point in
        # the installer; fall back to UID 1000 as a plausible stand-in.
        # If the installer later cross-checks this UID against "id -u $user",
        # that check will see the real UID — the fake only prevents spinning here.
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
