#!/bin/bash
# =============================================================================
#  diagnostics — UniFi OS Server Diagnostic Tool
#
#  ⚠  COMMUNITY PROJECT — NOT affiliated with Ubiquiti Inc.
#     UniFi® and Ubiquiti® are registered trademarks of Ubiquiti Inc.
#     This tool is maintained by Gill-Bates:
#     https://github.com/Gill-Bates/unifi-os-server
#
#  Usage:
#     docker exec -it <container> diagnostics
#
#  Exit codes:
#     0  all checks passed
#     1  one or more failures or warnings
# =============================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# Colors — $'...' so they work as both format strings and %s arguments (F5)
# ---------------------------------------------------------------------------
R=$'\033[0m';     BOLD=$'\033[1m';  DIM=$'\033[2m'
BLUE=$'\033[38;5;33m';  CYAN=$'\033[38;5;45m';  GREEN=$'\033[38;5;35m'
YELLOW=$'\033[38;5;214m'; RED=$'\033[38;5;196m'; GRAY=$'\033[38;5;244m'
WHITE=$'\033[97m'

if [ ! -t 1 ] && [ "${FORCE_COLOR:-}" != "1" ]; then
    R="" BOLD="" DIM="" BLUE="" CYAN="" GREEN="" YELLOW="" RED="" GRAY="" WHITE=""
fi

# ---------------------------------------------------------------------------
# State counters & result buffer
# TABLE_ROWS entries: "STATUS|CATEGORY|LABEL|NOTE"
# DETAIL_LINES: per-row journal/hint output, flushed after table
# ---------------------------------------------------------------------------
ISSUES=0
WARNINGS=0
TABLE_ROWS=()
DETAIL_LINES=()

# ---------------------------------------------------------------------------
# Row collectors — do NOT print immediately
# ---------------------------------------------------------------------------
row_ok()   { TABLE_ROWS+=( "OK|${_CAT}|${1}|${2:-}" ); }
row_warn() { TABLE_ROWS+=( "WARN|${_CAT}|${1}|${2:-}" ); WARNINGS=$((WARNINGS+1)); }
row_fail() { TABLE_ROWS+=( "FAIL|${_CAT}|${1}|${2:-}" ); ISSUES=$((ISSUES+1)); }
row_info() { TABLE_ROWS+=( "INFO|${_CAT}|${1}|${2:-}" ); }

# Append a detail/hint line linked to the last table row index
detail_line() { DETAIL_LINES+=( "${#TABLE_ROWS[@]}|   ${1}" ); }
hint_line()   { DETAIL_LINES+=( "${#TABLE_ROWS[@]}|💡 ${1}" ); }
log_line()    { DETAIL_LINES+=( "${#TABLE_ROWS[@]}|   │ ${1}" ); }

# ---------------------------------------------------------------------------
# render_table — prints all collected rows as a formatted table, then flushes
# detail lines that belong to non-OK rows underneath.
# ---------------------------------------------------------------------------
render_table() {
    local section_title="$1"
    printf "\n%s%s▶ %s%s\n" "$BLUE" "$BOLD" "$section_title" "$R"

    # Calculate column widths
    local w_label=5 w_note=4
    local i
    for i in "${!TABLE_ROWS[@]}"; do
        local row="${TABLE_ROWS[$i]}"
        local lbl note
        IFS='|' read -r _ _ lbl note <<< "$row"
        [ ${#lbl}  -gt $w_label ] && w_label=${#lbl}
        [ ${#note} -gt $w_note  ] && w_note=${#note}
    done

    # Header
    printf "%s  %-3s  %-*s  %s%s\n" \
        "$GRAY" "   " "$w_label" "Check" "Info" "$R"
    printf "%s  %s%s\n" "$GRAY" \
        "$(printf '─%.0s' $(seq 1 $((w_label + w_note + 10))))" "$R"

    # Rows
    for i in "${!TABLE_ROWS[@]}"; do
        local row="${TABLE_ROWS[$i]}"
        local status cat lbl note icon color
        IFS='|' read -r status cat lbl note <<< "$row"
        case "$status" in
            OK)   icon="✔"; color="$GREEN"  ;;
            WARN) icon="⚠"; color="$YELLOW" ;;
            FAIL) icon="✖"; color="$RED"    ;;
            INFO) icon="·"; color="$GRAY"   ;;
        esac
        printf "  %s%s%s  %-*s  %s%s%s\n" \
            "$color" "$icon" "$R" \
            "$w_label" "$lbl" \
            "$DIM" "$note" "$R"

        # Print any detail lines that belong to this row index (1-based)
        local row_idx=$(( i + 1 ))
        local dl
        for dl in "${DETAIL_LINES[@]+"${DETAIL_LINES[@]}"}"; do
            local dl_idx dl_text
            IFS='|' read -r dl_idx dl_text <<< "$dl"
            if [ "$dl_idx" -eq "$row_idx" ]; then
                printf "  %s     %s%s\n" "$CYAN" "$dl_text" "$R"
            fi
        done
    done
    printf "%s  %s%s\n" "$GRAY" \
        "$(printf '─%.0s' $(seq 1 $((w_label + w_note + 10))))" "$R"

    # Reset buffers for next section
    TABLE_ROWS=()
    DETAIL_LINES=()
}

# ---------------------------------------------------------------------------
# analyze_journal <svc>
# Appends journal context + root-cause hints to DETAIL_LINES for the
# last row that was added to TABLE_ROWS.
# Pattern priority: SIGABRT > SIGSEGV > OOM > RabbitMQ > Perm > Port > DB > TLS
# Crash-loop counter always appended if elevated.
# ---------------------------------------------------------------------------
analyze_journal() {
    local svc="$1"
    local log
    log="$(journalctl -u "$svc" -n 40 --no-pager --output=short-iso 2>/dev/null || true)"
    [ -z "$log" ] && { detail_line "No journal data for ${svc}."; return; }

    detail_line "Last journal entries:"
    printf '%s\n' "$log" | tail -15 | while IFS= read -r line; do
        log_line "$line"
    done

    if   printf '%s\n' "$log" | grep -qE 'status=6/ABRT'; then
        hint_line "SIGABRT (status=6): assertion failure or corrupted heap."
        hint_line "Wipe service state dir and restart the container."
    elif printf '%s\n' "$log" | grep -qE 'status=11/SEGV'; then
        hint_line "SIGSEGV (status=11): null pointer or bad memory access."
        hint_line "Check for a newer upstream UniFi OS release."
    elif printf '%s\n' "$log" | grep -qiE \
            'oom-kill|oom_reaper|Out of memory: (Kill|Killed) process|A process of this unit has been killed by the OOM killer'; then
        hint_line "OOM kill: container has insufficient memory."
        hint_line "Run: docker stats  — then raise memory limit in docker-compose.yaml."
    elif printf '%s\n' "$log" | grep -qiE 'epmd|erlang|beam\.smp'; then
        hint_line "RabbitMQ/Erlang crash. Remove stale mnesia data:"
        hint_line "rm -rf /var/lib/rabbitmq/mnesia && systemctl restart rabbitmq-server"
    elif printf '%s\n' "$log" | grep -qiE 'permission denied|EACCES'; then
        hint_line "Permission denied. Check volume ownership:"
        hint_line "docker exec <container> ls -la /var/lib/ /data/"
    elif printf '%s\n' "$log" | grep -qiE 'bind\(\) failed|Address already in use|EADDRINUSE'; then
        hint_line "Port conflict — another process holds the socket."
        hint_line "Check: docker exec <container> ss -tlnp"
    elif printf '%s\n' "$log" | grep -qiE 'connection refused|could not connect to server|ECONNREFUSED'; then
        hint_line "Cannot reach database. Check:"
        hint_line "systemctl status ${PG_UNIT:-postgresql@14-main} mongodb"
    elif printf '%s\n' "$log" | grep -qiE 'certificate.*error|tls handshake|ssl.*error|x509'; then
        hint_line "TLS/certificate error. Check cert files in:"
        hint_line "/etc/rabbitmq/ssl/  and  /data/unifi-core/config/http/"
    fi

    local rc
    rc="$(printf '%s\n' "$log" | grep -oE 'restart counter is at [0-9]+' \
        | grep -oE '[0-9]+' | tail -1 || true)"
    if [ -n "$rc" ] && [ "$rc" -ge 5 ]; then
        hint_line "Crash loop: service has restarted ${rc} times."
        hint_line "Causes: missing config, port conflict, OOM, or corrupt data."
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
printf '%b' "${BLUE}${BOLD}"
cat << 'BANNER'
             _    ___ _                                                     
            (_)  / __|_)                                                    
 _   _ ____  _ _| |__ _     ___   ___     ___ _____  ____ _   _ _____  ____ 
| | | |  _ \| (_   __) |   / _ \ /___)   /___) ___ |/ ___) | | | ___ |/ ___)
| |_| | | | | | | |  | |  | |_| |___ |  |___ | ____| |    \ V /| ____| |    
|____/|_| |_|_| |_|  |_|   \___/(___/   (___/|_____)_|     \_/ |_____)_|    
BANNER
printf '%b' "${R}"
printf "  ${GRAY}────────────────────────────────────────────────────${R}\n"
printf "  ${DIM}Diagnostics${R}  ${CYAN}https://github.com/Gill-Bates/unifi-os-server${R}\n"
printf "  ${GRAY}────────────────────────────────────────────────────${R}\n"
printf '\n'
printf "  ${GRAY}⚠  Community project — NOT affiliated with Ubiquiti Inc.${R}\n"
printf "  ${GRAY}   UniFi® is a registered trademark of Ubiquiti Inc.${R}\n"
printf '\n'
printf "  ${GRAY}Timestamp : ${R}${CYAN}%s${R}\n" "$(date '+%Y-%m-%dT%H:%M:%S %Z')"
printf "  ${GRAY}Container : ${R}${WHITE}%s${R}\n" "$(hostname)"
printf "  ${GRAY}Image     : ${R}${WHITE}%s${R}\n" "${UOS_SERVER_VERSION:-unknown}"

# ===========================================================================
# 1. SYSTEM
# ===========================================================================
_CAT="System"

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    row_ok  "cgroup v2"         "active"
else
    row_warn "cgroup v2"        "not detected"
    hint_line "Ensure Docker host uses cgroup v2 and 'cgroup: host' is set in compose."
fi

PID1="$(cat /proc/1/comm 2>/dev/null || echo 'unknown')"
if [ "$PID1" = "systemd" ]; then
    row_ok  "PID 1"             "systemd"
else
    row_fail "PID 1"            "${PID1} (systemd expected)"
    hint_line "Container did not start correctly. Check: docker logs <container>"
fi

row_ok "Uptime"                 "$(uptime -p 2>/dev/null || echo 'n/a')"
row_ok "Architecture"           "$(dpkg --print-architecture 2>/dev/null || uname -m)"

render_table "System"

# ===========================================================================
# 2. UNIFI SERVICES
# ===========================================================================
_CAT="UniFi Services"

UNIFI_SERVICES=(
    "unifi-core:UniFi Core:required"
    "unifi:UniFi Network:required"
    "ulp-go:ULP / Protect:optional"
    "uid-agent:Identity Agent:optional"
    "ucs-agent:Credential Server Agent:optional"
    "unifi-directory:UniFi Directory:optional"
    "unifi-credential-server:Credential Server:optional"
)

for entry in "${UNIFI_SERVICES[@]}"; do
    svc="${entry%%:*}"; rest="${entry#*:}"; label="${rest%%:*}"; tier="${rest##*:}"

    if ! systemctl cat "${svc}.service" >/dev/null 2>&1; then
        [ "$tier" = "required" ] \
            && row_fail "$label" "unit not found — image may be incomplete" \
            || row_info "$label" "not installed (optional)"
        continue
    fi

    STATE="$(systemctl is-active "${svc}" 2>/dev/null || true)"
    ENABLED="$(systemctl is-enabled "${svc}" 2>/dev/null || true)"
    RESTART_N="$(systemctl show "${svc}" -p NRestarts --value 2>/dev/null || echo 0)"

    case "$STATE" in
        active)
            if [ "${RESTART_N:-0}" -ge 5 ]; then
                row_warn "$label" "active but restarted ${RESTART_N}x — unstable"
                analyze_journal "${svc}"
            else
                row_ok "$label" "running"
            fi ;;
        activating) row_warn "$label" "still starting (activating)" ;;
        failed)
            row_fail "$label" "FAILED"
            analyze_journal "${svc}" ;;
        inactive)
            [ "$ENABLED" = "disabled" ] \
                && row_info "$label" "inactive (disabled)" \
                || { row_warn "$label" "inactive but enabled"; analyze_journal "${svc}"; } ;;
        *) row_warn "$label" "unknown state: ${STATE}" ;;
    esac
done

render_table "UniFi Services"

# ===========================================================================
# 3. SUPPORTING SERVICES
# ===========================================================================
_CAT="Supporting Services"

PG_UNIT="$(systemctl list-units --all 'postgresql@*' --no-legend --plain 2>/dev/null \
    | awk 'NR==1{print $1}')"
PG_UNIT="${PG_UNIT:-postgresql@14-main}"

SUPPORT_SERVICES=(
    "${PG_UNIT}:PostgreSQL:required"
    "mongodb:MongoDB:required"
    "rabbitmq-server:RabbitMQ:required"
    "nginx:nginx:required"
)

for entry in "${SUPPORT_SERVICES[@]}"; do
    svc="${entry%%:*}"; rest="${entry#*:}"; label="${rest%%:*}"; tier="${rest##*:}"

    if ! systemctl cat "${svc}.service" >/dev/null 2>&1; then
        [ "$tier" = "required" ] \
            && row_fail "$label" "unit not found — image may be incomplete" \
            || row_info "$label" "not installed (optional)"
        continue
    fi

    STATE="$(systemctl is-active "${svc}" 2>/dev/null || true)"
    RESTART_N="$(systemctl show "${svc}" -p NRestarts --value 2>/dev/null || echo 0)"

    case "$STATE" in
        active)
            if [ "${RESTART_N:-0}" -ge 5 ]; then
                row_warn "$label" "active but restarted ${RESTART_N}x — crash loop"
                analyze_journal "${svc}"
            else
                row_ok "$label" "running"
            fi ;;
        failed)
            row_fail "$label" "FAILED"
            analyze_journal "${svc}" ;;
        activating) row_warn "$label" "still starting (activating)" ;;
        *)          row_warn "$label" "state: ${STATE}" ;;
    esac
done

render_table "Supporting Services"

# ===========================================================================
# 4. POSTGRESQL DATABASES
# ===========================================================================
_CAT="PostgreSQL"

PG_VERSION="$(printf '%s' "$PG_UNIT" | grep -oE '[0-9]+' | head -1 || echo '14')"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"
PG_DATA="/var/lib/postgresql/${PG_VERSION}/main"

if [ ! -f "${PG_DATA}/PG_VERSION" ]; then
    row_fail "Cluster" "not initialized — ${PG_DATA}/PG_VERSION missing"
    hint_line "Preseed step may have failed. Check: docker logs <container>"
elif ! systemctl is-active --quiet "${PG_UNIT}" 2>/dev/null; then
    row_warn "Databases" "PostgreSQL not running — skipped"
else
    ALL_DBS_OK=1
    for db in "ulp-go" "ulp-go-syslog" "uid" "unifi-credential-server" \
              "ucs-user-assets" "ucs-agent" "unifi-directory" "unifi-identity-update"; do
        EXISTS="$(runuser -u postgres -- "${PG_BIN}/psql" -tAc \
            "SELECT 1 FROM pg_database WHERE datname='${db}'" 2>/dev/null \
            | tr -d '[:space:]' || echo '')"
        if [ "$EXISTS" = "1" ]; then
            row_ok  "$db" "present"
        else
            row_fail "$db" "MISSING"
            ALL_DBS_OK=0
        fi
    done
    if [ "$ALL_DBS_OK" -eq 0 ]; then
        hint_line "Missing databases cause service failures. Restart container to re-trigger preseed."
    fi
fi

render_table "PostgreSQL Databases"

# ===========================================================================
# 5. NETWORK PORTS
# ===========================================================================
_CAT="Ports"

check_port() {
    local port="$1" proto="${2:-tcp}" label="$3"
    if ss -ln${proto} 2>/dev/null | awk '{print $5}' | grep -qE ":${port}$"; then
        row_ok  "${port}/${proto}" "$label"
    else
        row_fail "${port}/${proto}" "NOT listening — $label"
        hint_line "Check which service owns this port and review its journal."
    fi
}

check_port 443   tcp "UniFi OS web UI (host→11443)"
check_port 8080  tcp "Device communication / inform"
check_port 8443  tcp "UniFi Network application API"
check_port 3478  udp "STUN — device adoption"
check_port 10003 udp "Device discovery"

render_table "Network Ports"

# ===========================================================================
# 6. DISK & VOLUMES
# ===========================================================================
_CAT="Volumes"

for entry in \
    "/persistent:Persistent config" \
    "/data:Application data" \
    "/var/lib/unifi:UniFi data" \
    "/var/lib/postgresql:PostgreSQL data" \
    "/var/lib/mongodb:MongoDB data" \
    "/var/log:Log files"; do

    mnt="${entry%%:*}"; label="${entry##*:}"

    if mountpoint -q "$mnt" 2>/dev/null; then
        AVAIL_KB="$(df -k --output=avail "$mnt" 2>/dev/null | tail -1 | tr -d ' ' || echo 0)"
        AVAIL_MB=$(( AVAIL_KB / 1024 ))
        if   [ "$AVAIL_MB" -lt 200 ]; then
            row_fail "$label" "CRITICAL: ${AVAIL_MB} MB free  (${mnt})"
            hint_line "Disk critically low — services may crash."
        elif [ "$AVAIL_MB" -lt 500 ]; then
            row_warn "$label" "${AVAIL_MB} MB free  (${mnt})"
        else
            row_ok   "$label" "${AVAIL_MB} MB free  (${mnt})"
        fi
    else
        row_warn "$label" "not bind-mounted — data lost on restart"
        hint_line "Add a volume mount for '${mnt}' in docker-compose.yaml."
    fi
done

render_table "Disk & Persistent Volumes"

# ===========================================================================
# 7. CONFIGURATION
# ===========================================================================
_CAT="Config"

if [ -f /data/uos_uuid ]; then
    UUID="$(cat /data/uos_uuid)"
    printf '%s' "$UUID" | grep -Eq \
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-5[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$' \
        && row_ok  "UOS UUID" "$UUID" \
        || { row_fail "UOS UUID" "invalid format: ${UUID}"; }
else
    row_fail "UOS UUID" "missing"
    hint_line "Generated on first boot. Check: docker logs <container>"
fi

[ -f /usr/lib/version ] \
    && row_ok  "Version file" "$(cat /usr/lib/version)" \
    || row_fail "Version file" "missing"

[ -f /usr/lib/platform ] \
    && row_ok  "Platform"     "$(cat /usr/lib/platform)" \
    || row_fail "Platform"    "missing"

SYSPROPS="/var/lib/unifi/system.properties"
if [ -f "$SYSPROPS" ]; then
    SYSTEM_IP="$(grep '^system_ip=' "$SYSPROPS" 2>/dev/null | cut -d= -f2 || echo '')"
    if [ -n "$SYSTEM_IP" ]; then
        row_ok  "system_ip" "$SYSTEM_IP"
    else
        row_warn "system_ip" "not set in system.properties"
        hint_line "Set UOS_SYSTEM_IP in docker-compose.yaml for device adoption."
    fi
else
    row_warn "system_ip" "system.properties missing"
    hint_line "Devices cannot adopt without system_ip. Set UOS_SYSTEM_IP in compose."
fi

render_table "Configuration"

# ===========================================================================
# 8. RECENT ERRORS  (last 15 min, all units)
# ===========================================================================
printf "\n%s%s▶ Recent Errors %s(last 15 min, all units)%s\n" \
    "$BLUE" "$BOLD" "$DIM" "$R"
printf "%s  ──────────────────────────────────────────────%s\n" "$GRAY" "$R"

if ! systemctl is-active --quiet systemd-journald 2>/dev/null; then
    printf "  %s⚠%s  journald not running — cannot read error log\n" "$YELLOW" "$R"
    WARNINGS=$((WARNINGS+1))
else
    SYS_ERRORS="$(journalctl --since "15 minutes ago" -p err..emerg \
        --no-pager --output=short-iso 2>/dev/null | grep -v '^-- ' || true)"

    # F1 fix: || true suppresses exitcode 1 on zero matches without adding "0\n0"
    SYS_ERROR_COUNT="$(printf '%s\n' "$SYS_ERRORS" | grep -c '[^[:space:]]' || true)"

    if [ "${SYS_ERROR_COUNT:-0}" -eq 0 ]; then
        printf "  %s✔%s  No error-level journal entries in the last 15 minutes\n" "$GREEN" "$R"
    else
        printf "  %s⚠%s  %s%d error-level entries:%s\n\n" \
            "$YELLOW" "$R" "$YELLOW" "$SYS_ERROR_COUNT" "$R"
        WARNINGS=$((WARNINGS+1))

        printf '%s\n' "$SYS_ERRORS" | head -50 | while IFS= read -r line; do
            printf "  %s   │ %s%s\n" "$DIM" "$line" "$R"
        done
        [ "$SYS_ERROR_COUNT" -gt 50 ] && printf \
            "\n  %s   … %d total. Full view: journalctl -p err --since '15 min ago' --no-pager%s\n" \
            "$GRAY" "$SYS_ERROR_COUNT" "$R"

        printf '\n'
        # Crash-loop: F4 fix — extract unit via awk, not grep -P
        if printf '%s\n' "$SYS_ERRORS" | grep -q "restart counter is at"; then
            LOOP_SVCS="$(printf '%s\n' "$SYS_ERRORS" \
                | grep "restart counter is at" \
                | awk '{u=$3; sub(/\[[0-9]+\]:?$/,"",u); sub(/:$/,"",u); print u}' \
                | sort -u || true)"
            for ls in $LOOP_SVCS; do
                LOOP_N="$(printf '%s\n' "$SYS_ERRORS" | grep "$ls" \
                    | grep -oE 'restart counter is at [0-9]+' \
                    | grep -oE '[0-9]+' | tail -1 || echo '?')"
                printf "  %s   💡 Crash loop: %s has restarted %sx%s\n" "$CYAN" "$ls" "$LOOP_N" "$R"
            done
        fi
        printf '%s\n' "$SYS_ERRORS" | grep -qiE \
            'oom-kill|oom_reaper|Out of memory: (Kill|Killed) process|A process of this unit has been killed by the OOM killer' \
            && printf "  %s   💡 OOM kill detected — raise container memory limit.%s\n" "$CYAN" "$R"
        printf '%s\n' "$SYS_ERRORS" | grep -qiE 'status=6/ABRT' \
            && printf "  %s   💡 SIGABRT detected — assertion failure or Erlang crash.%s\n" "$CYAN" "$R"
        printf '%s\n' "$SYS_ERRORS" | grep -qiE 'permission denied|EACCES' \
            && printf "  %s   💡 Permission denied — check volume ownership.%s\n" "$CYAN" "$R"
        printf '%s\n' "$SYS_ERRORS" | grep -qiE 'bind\(\) failed|Address already in use|EADDRINUSE' \
            && printf "  %s   💡 Port conflict inside container — check: ss -tlnp%s\n" "$CYAN" "$R"
        printf '%s\n' "$SYS_ERRORS" | grep -qiE 'connection refused|ECONNREFUSED' \
            && printf "  %s   💡 Connection refused — dependency service may not be ready.%s\n" "$CYAN" "$R"
    fi
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
printf '\n%s  ════════════════════════════════════════════════════════%s\n' "$GRAY" "$R"
printf '  %sFailures  :%s ' "$GRAY" "$R"
[ "$ISSUES"   -eq 0 ] && printf '%s%s%d%s\n' "$GREEN"  "$BOLD" "$ISSUES"   "$R" \
                       || printf '%s%s%d%s\n' "$RED"    "$BOLD" "$ISSUES"   "$R"
printf '  %sWarnings  :%s ' "$GRAY" "$R"
[ "$WARNINGS" -eq 0 ] && printf '%s%s%d%s\n' "$GREEN"  "$BOLD" "$WARNINGS" "$R" \
                       || printf '%s%s%d%s\n' "$YELLOW" "$BOLD" "$WARNINGS" "$R"
printf '%s  ════════════════════════════════════════════════════════%s\n' "$GRAY" "$R"

if   [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    printf '\n  %s%s✔  All checks passed.%s\n\n' "$GREEN" "$BOLD" "$R"
    exit 0
elif [ "$ISSUES" -eq 0 ]; then
    printf '\n  %s%s⚠  %d warning(s) — no hard failures.%s\n' "$YELLOW" "$BOLD" "$WARNINGS" "$R"
    printf '  %s   Review warnings above.%s\n\n' "$DIM" "$R"
    exit 1
else
    printf '\n  %s%s✖  %d failure(s), %d warning(s).%s\n' "$RED" "$BOLD" "$ISSUES" "$WARNINGS" "$R"
    printf '  %s   Follow the 💡 hints above.%s\n' "$DIM" "$R"
    printf '  %s   Report: https://github.com/Gill-Bates/unifi-os-server/issues%s\n\n' "$CYAN" "$R"
    exit 1
fi
