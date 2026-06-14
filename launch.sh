#!/bin/sh
# WireGuard VPN client manager pak for NextUI / TrimUI Brick

PLATFORM="${PLATFORM:-tg5040}"
PAK_DIR="$(dirname "$0")"
SDCARD="${SDCARD_PATH:-/mnt/SDCARD}"
CONF_DIR="$SDCARD/wireguard"
STATE_FILE="/tmp/wg_pak_active"
ENDPOINT_FILE="/tmp/wg_pak_endpoint"
SETTINGS_FILE="$CONF_DIR/settings.json"
WG_BIN="$PAK_DIR/bin/$PLATFORM/wg"
WGGO_BIN="$PAK_DIR/bin/$PLATFORM/wireguard-go"
MINUI_LIST="$PAK_DIR/bin/$PLATFORM/minui-list"
MINUI_PRESENTER="$PAK_DIR/bin/$PLATFORM/minui-presenter"
JQ="$PAK_DIR/bin/$PLATFORM/jq"
LOG="${LOGS_PATH:+$LOGS_PATH/wireguard.log}"
LOG="${LOG:-$CONF_DIR/wireguard.log}"
MENU_INPUT="/tmp/wg_menu_in.json"
MENU_OUTPUT="/tmp/wg_menu_out.json"

export PATH="$PAK_DIR/bin/$PLATFORM:$PATH"

log() {
    mkdir -p "$(dirname "$LOG")" 2>/dev/null
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG"
}

die() {
    log "FATAL: $*"
    "$MINUI_PRESENTER" --message "$*" --timeout 4 2>/dev/null || true
    exit 1
}

show_message() {
    msg="$1"
    seconds="${2:-}"
    killall minui-presenter >/dev/null 2>&1 || true
    if [ -z "$seconds" ]; then
        "$MINUI_PRESENTER" --message "$msg" --timeout -1 &
    else
        "$MINUI_PRESENTER" --message "$msg" --timeout "$seconds"
    fi
}

# ---------------------------------------------------------------------------
# Tunnel management
# ---------------------------------------------------------------------------

wg_up() {
    conf="$1"
    tunnel_mode="$2"
    iface="wg0"

    log "Connecting: $conf (tunnel=$tunnel_mode)"

    address=$(awk '/^\[Interface\]/,/^\[/' "$conf" | grep -i '^Address' | head -1 | cut -d= -f2 | tr -d ' ')
    dns=$(awk '/^\[Interface\]/,/^\[/' "$conf" | grep -i '^DNS' | head -1 | cut -d= -f2 | tr -d ' ')
    endpoint=$(grep -i '^Endpoint' "$conf" | head -1 | cut -d= -f2 | tr -d ' ' | cut -d: -f1)

    tmpconf="/tmp/wg_stripped.conf"
    grep -iv '^\(Address\|DNS\|PreUp\|PostUp\|PreDown\|PostDown\)' "$conf" > "$tmpconf"

    ip link delete "$iface" 2>/dev/null || true
    killall wireguard-go 2>/dev/null || true
    "$WGGO_BIN" "$iface" 2>>"$LOG" &

    i=0
    while [ "$i" -lt 5 ]; do
        ip link show "$iface" >/dev/null 2>&1 && break
        sleep 1
        i=$((i + 1))
    done

    if ! ip link show "$iface" >/dev/null 2>&1; then
        log "ERROR: wireguard-go did not create interface (tun support missing?)"
        return 1
    fi

    if ! "$WG_BIN" setconf "$iface" "$tmpconf" 2>>"$LOG"; then
        log "ERROR: wg setconf failed"
        ip link delete "$iface" 2>/dev/null
        return 1
    fi

    [ -n "$address" ] && ip addr add "$address" dev "$iface" 2>>"$LOG"
    ip link set "$iface" up 2>>"$LOG"

    if [ "$tunnel_mode" = "full" ]; then
        # /1 pair outranks the WiFi 0/0 default without replacing it
        gw=$(ip route show default | awk '/default/ {print $3; exit}')
        wifi_dev=$(ip route show default | awk '/default/ {print $5; exit}')
        if [ -n "$endpoint" ] && [ -n "$gw" ]; then
            # Resolve hostname to IP — BusyBox `ip route` may not support hostname args
            endpoint_ip=$(ping -c 1 -W 1 "$endpoint" 2>/dev/null | awk -F'[()]' 'NR==1{print $2}')
            [ -z "$endpoint_ip" ] && endpoint_ip="$endpoint"
            ip route add "$endpoint_ip/32" via "$gw" dev "$wifi_dev" 2>>"$LOG"
            log "Endpoint host route: $endpoint_ip via $gw dev $wifi_dev"
            echo "$endpoint_ip" > "$ENDPOINT_FILE"
        fi
        ip route add 0.0.0.0/1 dev "$iface" 2>>"$LOG"
        ip route add 128.0.0.0/1 dev "$iface" 2>>"$LOG"
        log "Full tunnel routes added"
    else
        while IFS= read -r line; do
            case "$line" in
                AllowedIPs*|allowedips*)
                    routes=$(echo "$line" | cut -d= -f2 | tr ',' '\n' | tr -d ' ')
                    for route in $routes; do
                        case "$route" in
                            "0.0.0.0/0"|"::/0")
                                log "Skipping $route in split mode; use Full tunnel to route all traffic"
                                continue ;;
                        esac
                        ip route add "$route" dev "$iface" 2>>"$LOG"
                    done ;;
            esac
        done < "$conf"
    fi

    if [ -n "$dns" ]; then
        cp /etc/resolv.conf /tmp/resolv.conf.wg_bak 2>/dev/null
        # Write one nameserver line per entry (DNS may be comma-separated)
        printf '%s' "$dns" | tr ',' '\n' | while IFS= read -r ns; do
            printf 'nameserver %s\n' "$ns"
        done > /etc/resolv.conf
        # In split mode, ensure DNS servers are routed through the tunnel
        if [ "$tunnel_mode" = "split" ]; then
            printf '%s' "$dns" | tr ',' '\n' | while IFS= read -r ns; do
                ip route add "$ns/32" dev "$iface" 2>>"$LOG" || true
            done
        fi
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
    killall wireguard-go 2>/dev/null || true
    ip link delete "$iface" 2>>"$LOG"

    endpoint=$(cat "$ENDPOINT_FILE" 2>/dev/null)
    [ -n "$endpoint" ] && ip route del "$endpoint/32" 2>/dev/null
    rm -f "$ENDPOINT_FILE"

    if [ -f /tmp/resolv.conf.wg_bak ]; then
        mv /tmp/resolv.conf.wg_bak /etc/resolv.conf
        log "Restored DNS"
    fi

    rm -f "$STATE_FILE"
    log "Disconnected $iface"
}

get_vpn_ip() {
    ip addr show wg0 2>/dev/null | awk '$1 == "inet" {print $2; exit}'
}

settings_read() {
    [ -f "$SETTINGS_FILE" ] && "$JQ" -r ".$1 // empty" "$SETTINGS_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Startup checks
# ---------------------------------------------------------------------------

[ -f "$WG_BIN" ]          || die "wg binary not found at $WG_BIN"
[ -x "$WG_BIN" ]          || chmod +x "$WG_BIN"
[ -f "$WGGO_BIN" ]        || die "wireguard-go not found at $WGGO_BIN"
[ -x "$WGGO_BIN" ]        || chmod +x "$WGGO_BIN"
[ -f "$MINUI_LIST" ]      || die "minui-list not found at $MINUI_LIST"
[ -x "$MINUI_LIST" ]      || chmod +x "$MINUI_LIST"
[ -f "$MINUI_PRESENTER" ] || die "minui-presenter not found at $MINUI_PRESENTER"
[ -x "$MINUI_PRESENTER" ] || chmod +x "$MINUI_PRESENTER"
[ -f "$JQ" ]              || die "jq not found at $JQ"
[ -x "$JQ" ]              || chmod +x "$JQ"

mkdir -p "$CONF_DIR"
log "pak launched"

# ---------------------------------------------------------------------------
# Main menu loop
# ---------------------------------------------------------------------------

while true; do
    # Enumerate config files
    conf_options=""
    conf_count=0
    saved_conf=$(settings_read "config")
    saved_conf_idx=0

    for f in "$CONF_DIR"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        if [ -z "$conf_options" ]; then
            conf_options="\"$name\""
        else
            conf_options="$conf_options, \"$name\""
        fi
        [ "$name" = "$saved_conf" ] && saved_conf_idx=$conf_count
        conf_count=$((conf_count + 1))
    done

    if [ "$conf_count" -eq 0 ]; then
        show_message "No .conf files in $CONF_DIR" 4
        log "No config files found"
        break
    fi

    # Tunnel preference
    saved_tunnel=$(settings_read "tunnel")
    saved_tunnel="${saved_tunnel:-split}"
    tunnel_idx=0
    [ "$saved_tunnel" = "full" ] && tunnel_idx=1

    # VPN state — verify interface actually exists (clears stale state after reboot)
    active_iface=$(cat "$STATE_FILE" 2>/dev/null)
    vpn_enabled=0
    if [ -n "$active_iface" ] && ip link show "$active_iface" >/dev/null 2>&1; then
        vpn_enabled=1
    else
        rm -f "$STATE_FILE" "$ENDPOINT_FILE"
        active_iface=""
    fi

    if [ "$vpn_enabled" -eq 1 ]; then
        vpn_ip=$(get_vpn_ip)
        status_text="Connected${vpn_ip:+ ($vpn_ip)}"
    else
        status_text="Disconnected"
    fi

    cat > "$MENU_INPUT" <<EOF
{
  "settings": [
    {"name": "Status",  "options": ["$status_text"],    "selected": 0, "features": {"unselectable": true}},
    {"name": "VPN",     "options": ["Off", "On"],       "selected": $vpn_enabled},
    {"name": "Config",  "options": [$conf_options],     "selected": $saved_conf_idx},
    {"name": "Tunnel",  "options": ["Split", "Full"],   "selected": $tunnel_idx}
  ]
}
EOF

    rm -f "$MENU_OUTPUT"
    "$MINUI_LIST" \
        --disable-auto-sleep \
        --file "$MENU_INPUT" \
        --format json \
        --title "WireGuard VPN" \
        --confirm-text "SAVE" \
        --item-key "settings" \
        --write-value state \
        --write-location "$MENU_OUTPUT" >/dev/null
    list_exit=$?

    [ "$list_exit" -ne 0 ] && break
    [ ! -f "$MENU_OUTPUT" ] && break

    new_vpn=$("$JQ" -r '.settings[1].selected' "$MENU_OUTPUT")
    new_conf_idx=$("$JQ" -r '.settings[2].selected' "$MENU_OUTPUT")
    new_tunnel_idx=$("$JQ" -r '.settings[3].selected' "$MENU_OUTPUT")

    # Resolve conf index to path/name
    new_conf_name=""
    new_conf_path=""
    ci=0
    for f in "$CONF_DIR"/*.conf; do
        [ -f "$f" ] || continue
        if [ "$ci" -eq "$new_conf_idx" ]; then
            new_conf_name=$(basename "$f" .conf)
            new_conf_path="$f"
        fi
        ci=$((ci + 1))
    done

    new_tunnel="split"
    [ "$new_tunnel_idx" -eq 1 ] && new_tunnel="full"

    # Persist settings
    printf '{"config": "%s", "tunnel": "%s"}\n' "$new_conf_name" "$new_tunnel" > "$SETTINGS_FILE"

    # Apply changes
    if [ "$new_vpn" -eq 1 ] && [ "$vpn_enabled" -eq 0 ]; then
        show_message "Connecting: $new_conf_name..."
        if wg_up "$new_conf_path" "$new_tunnel"; then
            show_message "Connected: $new_conf_name" 2
        else
            show_message "Connection failed" 3
        fi
    elif [ "$new_vpn" -eq 0 ] && [ "$vpn_enabled" -eq 1 ]; then
        show_message "Disconnecting..."
        wg_down
        show_message "Disconnected" 2
    elif [ "$new_vpn" -eq 1 ] && [ "$vpn_enabled" -eq 1 ]; then
        if [ "$new_conf_name" != "$saved_conf" ] || [ "$new_tunnel" != "$saved_tunnel" ]; then
            show_message "Reconnecting: $new_conf_name..."
            wg_down
            if wg_up "$new_conf_path" "$new_tunnel"; then
                show_message "Connected: $new_conf_name" 2
            else
                show_message "Connection failed" 3
            fi
        fi
    fi
done

log "pak exited"
exit 0
