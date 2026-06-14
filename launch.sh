#!/bin/sh
# WireGuard VPN client manager pak for NextUI / TrimUI Brick

PLATFORM="${PLATFORM:-tg5040}"
PAK_DIR="$(dirname "$0")"
SDCARD="/mnt/SDCARD"
CONF_DIR="$SDCARD/wireguard"
STATE_FILE="/tmp/wg_pak_active"
WG_BIN="$PAK_DIR/bin/$PLATFORM/wg"
LOGS_PATH="${LOGS_PATH:-/tmp}"
LOG="$LOGS_PATH/wireguard.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S'): $*" >> "$LOG"
}

die() {
    log "FATAL: $*"
    show_message "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

# Search PATH then known NextUI system locations for a display tool.
_find_tool() {
    name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        command -v "$name"; return 0
    fi
    for dir in \
        "/mnt/SDCARD/.system/$PLATFORM/bin" \
        "/usr/trimui/bin" \
        "/opt/trimui/bin" \
        "$PAK_DIR/../../.system/$PLATFORM/bin"; do
        [ -x "$dir/$name" ] && { echo "$dir/$name"; return 0; }
    done
    return 1
}

MINUI_PRESENTER=$(_find_tool minui-presenter 2>/dev/null)
MINUI_LIST=$(_find_tool minui-list 2>/dev/null)

show_message() {
    msg="$1"
    timeout="${2:-4}"
    if [ -n "$MINUI_PRESENTER" ]; then
        echo "$msg" | "$MINUI_PRESENTER" --stdin --timeout "$timeout"
    else
        echo "$msg"
        sleep 2
    fi
}

# Present a list of options; prints the selected item to stdout.
# Returns exit code 1 if cancelled/nothing selected.
show_menu() {
    title="$1"
    shift
    if [ -n "$MINUI_LIST" ]; then
        list=""
        for item in "$@"; do
            list="${list}${item}
"
        done
        result=$(printf '%s' "$list" | "$MINUI_LIST" --title "$title" --stdin 2>/dev/null)
        rc=$?
        [ $rc -ne 0 ] && return 1
        echo "$result"
        return 0
    else
        echo ""
        echo "=== $title ==="
        i=1
        for item in "$@"; do
            echo "  $i) $item"
            i=$((i + 1))
        done
        echo ""
        printf "Select [1-%d] or 0 to exit: " "$#"
        read -r choice
        case "$choice" in
            ''|0) return 1 ;;
            *[!0-9]*) return 1 ;;
        esac
        if [ "$choice" -lt 1 ] || [ "$choice" -gt $# ]; then
            return 1
        fi
        i=1
        for item in "$@"; do
            if [ "$i" = "$choice" ]; then
                echo "$item"; return 0
            fi
            i=$((i + 1))
        done
        return 1
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

    # Create interface
    if ! ip link add "$iface" type wireguard 2>>"$LOG"; then
        log "ERROR: ip link add $iface failed"
        show_message "Failed to create WireGuard interface"
        return 1
    fi

    # Apply config
    if ! "$WG_BIN" setconf "$iface" "$tmpconf" 2>>"$LOG"; then
        log "ERROR: wg setconf failed"
        ip link delete "$iface" 2>/dev/null
        show_message "Failed to apply WireGuard config"
        return 1
    fi

    # Assign address
    if [ -n "$address" ]; then
        ip addr add "$address" dev "$iface" 2>>"$LOG"
    fi

    ip link set "$iface" up 2>>"$LOG"

    # Add routes for each peer's AllowedIPs (skip default routes to preserve WiFi)
    while IFS= read -r line; do
        case "$line" in
            AllowedIPs*|allowedips*)
                routes=$(echo "$line" | cut -d= -f2 | tr ',' '\n' | tr -d ' ')
                for route in $routes; do
                    case "$route" in
                        "0.0.0.0/0"|"::/0")
                            log "Skipping default route $route (WiFi preservation)"
                            continue
                            ;;
                    esac
                    ip route add "$route" dev "$iface" 2>>"$LOG"
                done
                ;;
        esac
    done < "$conf"

    # Update DNS if specified
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

wg_status() {
    iface=$(cat "$STATE_FILE" 2>/dev/null)
    if [ -z "$iface" ]; then
        show_message "No active WireGuard tunnel"
        return
    fi
    status=$("$WG_BIN" show "$iface" 2>&1)
    if [ -n "$MINUI_PRESENTER" ]; then
        echo "$status" | "$MINUI_PRESENTER" --stdin --timeout 10
    else
        echo "=== WireGuard Status: $iface ==="
        echo "$status"
        echo ""
        echo "Press Enter to continue..."
        read -r _
    fi
}

# ---------------------------------------------------------------------------
# Startup checks
# ---------------------------------------------------------------------------

[ -f "$WG_BIN" ] || die "wg binary not found at $WG_BIN"
[ -x "$WG_BIN" ] || chmod +x "$WG_BIN"

mkdir -p "$CONF_DIR"

log "pak launched, CONF_DIR=$CONF_DIR, presenter=${MINUI_PRESENTER:-none}, list=${MINUI_LIST:-none}"

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------

while true; do
    active_iface=$(cat "$STATE_FILE" 2>/dev/null)

    if [ -n "$active_iface" ]; then
        # Tunnel is up — show disconnect/status/exit menu
        choice=$(show_menu "WireGuard (Active: $active_iface)" \
            "Disconnect $active_iface" \
            "Status" \
            "Exit")
        rc=$?
        [ $rc -ne 0 ] && break
        case "$choice" in
            Disconnect*)
                wg_down
                show_message "Disconnected"
                ;;
            Status)
                wg_status
                ;;
            Exit)
                break
                ;;
        esac
    else
        # No tunnel — show available configs
        conf_list=""
        for f in "$CONF_DIR"/*.conf; do
            [ -f "$f" ] && conf_list="$conf_list $f"
        done

        if [ -z "$conf_list" ]; then
            show_message "No .conf files found in $CONF_DIR"
            log "No config files found in $CONF_DIR"
            break
        fi

        # Build menu items from basenames
        menu_items=""
        for f in $conf_list; do
            name=$(basename "$f" .conf)
            menu_items="$menu_items $name"
        done

        # Append Exit
        menu_items="$menu_items Exit"

        # shellcheck disable=SC2086
        choice=$(show_menu "WireGuard — Select Tunnel" $menu_items)
        rc=$?
        [ $rc -ne 0 ] && break

        case "$choice" in
            Exit)
                break
                ;;
            *)
                # Find the matching conf file
                selected_conf="$CONF_DIR/${choice}.conf"
                if [ -f "$selected_conf" ]; then
                    show_message "Connecting to $choice..."
                    if wg_up "$selected_conf"; then
                        show_message "Connected to $choice"
                    fi
                else
                    log "ERROR: conf not found: $selected_conf"
                    show_message "Config not found: $choice"
                fi
                ;;
        esac
    fi
done

log "pak exited"
exit 0
