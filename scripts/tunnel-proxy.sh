#!/usr/bin/env bash
#
# tunnel-proxy — Unified control for ssh-tunnel-proxy
# Usage: tunnel-proxy {start|stop|status|restart}
#
set -euo pipefail

CONFIG_DIR="/etc/ssh-tunnel-proxy"
CONFIG_FILE="$CONFIG_DIR/tunnel.conf"

ORIGINAL_USER="${SUDO_USER:-$USER}"
ORIGINAL_UID=$(id -u "$ORIGINAL_USER" 2>/dev/null || echo 1000)
DBUS_ADDR="unix:path=/run/user/${ORIGINAL_UID}/bus"

SOCKS5_PORT=1080
BYPASS_LAN=true
BYPASS_SUBNETS="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true

usage() {
    echo "Usage: tunnel-proxy {start|stop|status|restart}" >&2
    exit 1
}

start_services() {
    echo "[tunnel-proxy] Starting services..."
    sudo systemctl start tunnel-reverse.service 2>/dev/null || true
    sudo systemctl start tunnel-socks5.service 2>/dev/null || true
    echo "[tunnel-proxy] Services started"

    if command -v gsettings &>/dev/null && [[ -n "$ORIGINAL_USER" ]]; then
        sudo -u "$ORIGINAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" gsettings set org.gnome.system.proxy mode 'manual' 2>/dev/null || true
        if [[ "${BYPASS_LAN:-true}" == "true" ]]; then
            sudo -u "$ORIGINAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" gsettings set org.gnome.system.proxy ignore-hosts "['localhost', '127.0.0.0/8', '10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16', '*.local']" 2>/dev/null || true
        fi
        echo "[tunnel-proxy] GNOME system proxy enabled"
    fi

    echo "[tunnel-proxy] Proxy env vars will be set automatically in new terminals"
    echo "[tunnel-proxy] To update this terminal, run: source ~/.bashrc"
    if [[ "${BYPASS_LAN:-true}" == "true" ]]; then
        echo "[tunnel-proxy] LAN bypass: ${BYPASS_SUBNETS}"
    fi
}

stop_services() {
    echo "[tunnel-proxy] Stopping services..."
    sudo systemctl stop tunnel-reverse.service 2>/dev/null || true
    sudo systemctl stop tunnel-socks5.service 2>/dev/null || true
    echo "[tunnel-proxy] Services stopped"

    if command -v gsettings &>/dev/null && [[ -n "$ORIGINAL_USER" ]]; then
        sudo -u "$ORIGINAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" gsettings set org.gnome.system.proxy ignore-hosts "[]" 2>/dev/null || true
        sudo -u "$ORIGINAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null || true
        echo "[tunnel-proxy] GNOME system proxy disabled"
    fi

    echo "[tunnel-proxy] To clear proxy env vars in this terminal, run: source ~/.bashrc"
}

status_services() {
    echo "=== Reverse Tunnel ==="
    systemctl status tunnel-reverse.service 2>/dev/null || echo "  (not installed)"
    echo ""
    echo "=== SOCKS5 Proxy ==="
    systemctl status tunnel-socks5.service 2>/dev/null || echo "  (not installed)"
    if [[ "${BYPASS_LAN:-true}" == "true" ]]; then
        echo ""
        echo "=== LAN Bypass ==="
        echo "  Subnets: ${BYPASS_SUBNETS}"
    fi
}

case "${1:-}" in
    start)   start_services ;;
    stop)    stop_services ;;
    restart) stop_services; sleep 1; start_services ;;
    status)  status_services ;;
    *)       usage ;;
esac
