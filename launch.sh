#!/bin/sh
# WireGuard VPN client manager pak for NextUI / TrimUI Brick

PLATFORM="${PLATFORM:-tg5040}"
PAK_DIR="$(dirname "$0")"
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
CONF_DIR="$SDCARD/wireguard"
STATE_FILE="/tmp/wg_pak_active"
WG_BIN="$PAK_DIR/bin/$PLATFORM/wg"
LOG="${LOGS_PATH:+$LOGS_PATH/wireguard.log}"
LOG="${LOG:-$SDCARD/wireguard/wireguard.log}"
LOGO="$SDCARD/.system/res/logo.png"

log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG"
}

die() {
    log "FATAL: $*"
    show_message "$*" 4
    exit 1
}

# ---------------------------------------------------------------------------
# UI — show2.elf is the display tool on this NextUI firmware
# ---------------------------------------------------------------------------

show_message() {
    msg="$1"
    timeout="${2:-3}"
    if command -v show2.elf >/dev/null 2>&1 && [ -f "$LOGO" ]; then
        show2.elf --mode=simple --image="$LOGO" --text="$msg" --timeout="$timeout"
    else
        echo "$msg" >&2
        sleep "$timeout"
    fi
}

# ---------------------------------------------------------------------------
# Tunnel management
# ---------------------------------------------------------------------------

wg_up() {
    conf="$1"
    iface="wg0"

    log "Connecting: $conf"

    # Parse wg-quick-only fields
    address=$(awk '/^\[Interface\]/,/^\[/' "$conf" | grep -i '^Address' | head -1 | cut -d= -f2 | tr -d ' ')
    dns=$(awk '/^\[Interface\]/,/^\[/' "$conf" | grep -i '^DNS' | head -1 | cut -d= -f2 | tr -d ' ')

    # Strip wg-quick-only keys (not valid wg(8) keys)
    tmpconf="/tmp/wg_stripped.conf"
    grep -iv '^\(Address\|DNS\|PreUp\|PostUp\|PreDown\|PostDown\)' "$conf" > "$tmpconf"

    if ! ip link add "$iface" type wireguard 2>>"$LOG"; then
        log "ERROR: ip link add $iface failed"
        show_message "Failed to create WG interface" 4
        return 1
    fi

    if ! "$WG_BIN" setconf "$iface" "$tmpconf" 2>>"$LOG"; then
        log "ERROR: wg setconf failed"
        ip link delete "$iface" 2>/dev/null
        show_message "Failed to apply WG config" 4
        return 1
    fi

    [ -n "$address" ] && ip addr add "$address" dev "$iface" 2>>"$LOG"

    ip link set "$iface" up 2>>"$LOG"

    # Add routes from AllowedIPs; skip default routes to preserve WiFi
    while IFS= read -r line; do
        case "$line" in
            AllowedIPs*|allowedips*)
                routes=$(echo "$line" | cut -d= -f2 | tr ',' '\n' | tr -d ' ')
                for route in $routes; do
                    case "$route" in
                        "0.0.0.0/0"|"::/0")
                            log "Skipping default route $route (WiFi preservation)"
                            continue ;;
                    esac
                    ip route add "$route" dev "$iface" 2>>"$LOG"
                done ;;
        esac
    done < "$conf"

    if [ -n "$dns" ]; then
        cp /etc/resolv.conf /tmp/resolv.conf.wg_bak 2>/dev/null
        printf 'nameserver %s\n' "$dns" > /etc/resolv.conf
        log "Set DNS: $dns"
    fi

    echo "$iface" > "$STATE_FILE"
    log "Connected $iface using $conf"
    return 0
}

wg_down() {
    iface=$(cat "$STATE_FILE" 2>/dev/null)
    [ -z "$iface" ] && return 0

    log "Disconnecting: $iface"
    ip link delete "$iface" 2>>"$LOG"

    if [ -f /tmp/resolv.conf.wg_bak ]; then
        mv /tmp/resolv.conf.wg_bak /etc/resolv.conf
        log "Restored DNS"
    fi

    rm -f "$STATE_FILE"
    log "Disconnected $iface"
    return 0
}

# ---------------------------------------------------------------------------
# Startup checks
# ---------------------------------------------------------------------------

[ -f "$WG_BIN" ] || die "wg binary not found at $WG_BIN"
[ -x "$WG_BIN" ] || chmod +x "$WG_BIN"

mkdir -p "$CONF_DIR"
log "pak launched"

# ---------------------------------------------------------------------------
# Main — toggle model: launch connects or disconnects
# ---------------------------------------------------------------------------

active_iface=$(cat "$STATE_FILE" 2>/dev/null)

if [ -n "$active_iface" ]; then
    show_message "Disconnecting $active_iface..." 2
    wg_down
    show_message "VPN disconnected" 3
else
    selected_conf=""
    conf_count=0
    for f in "$CONF_DIR"/*.conf; do
        [ -f "$f" ] || continue
        conf_count=$((conf_count + 1))
        [ -z "$selected_conf" ] && selected_conf="$f"
    done

    if [ "$conf_count" -eq 0 ]; then
        show_message "No .conf files in $CONF_DIR" 4
        log "No config files found"
    else
        name=$(basename "$selected_conf" .conf)
        [ "$conf_count" -gt 1 ] && log "Multiple confs found, using first: $name"
        show_message "Connecting: $name..." 2
        if wg_up "$selected_conf"; then
            show_message "Connected: $name" 3
        fi
    fi
fi

log "pak exited"
exit 0
