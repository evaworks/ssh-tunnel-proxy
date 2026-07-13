#!/usr/bin/env bash
#
# local-setup.sh
# Configure reverse tunnel, SOCKS5 proxy, and sshuttle on the local machine.
#
# Normally called by install.sh, but can be run standalone:
#   ./local-setup.sh --server user@host [--tunnel-port 2222] [--socks5-port 1080] [--ssh-port 22]
#
set -euo pipefail

# ---- Defaults ----
TUNNEL_PORT=2222
SOCKS5_PORT=1080
SSH_PORT=22
SERVER=""
ENABLE_SSHUTTLE=false
DEPLOY_REVERSE=true
DEPLOY_SOCKS5=true
LOCAL_USER="$(whoami)"
LOCAL_HOST="$(hostname -s)"
CONFIG_DIR="/etc/ssh-tunnel-proxy"
CONFIG_FILE="${CONFIG_DIR}/tunnel.conf"

# ---- Parse args ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)          SERVER="$2"; shift 2 ;;
        --tunnel-port)     TUNNEL_PORT="$2"; shift 2 ;;
        --socks5-port)     SOCKS5_PORT="$2"; shift 2 ;;
        --ssh-port)        SSH_PORT="$2"; shift 2 ;;
        --enable-sshuttle) ENABLE_SSHUTTLE=true; shift ;;
        --only-reverse)    DEPLOY_REVERSE=true; DEPLOY_SOCKS5=false; shift ;;
        --only-socks5)     DEPLOY_REVERSE=false; DEPLOY_SOCKS5=true; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [[ -z "$SERVER" ]]; then
    echo "Usage: $0 --server user@host [--tunnel-port 2222] [--socks5-port 1080] [--ssh-port 22] [--only-reverse] [--only-socks5]"
    exit 1
fi

# ---- Detect re-deployment ----
REDEPLOY=false
if [[ -d "$CONFIG_DIR" ]]; then
    REDEPLOY=true
    echo "[local-setup] Existing installation detected"

    # Clean up services no longer needed when switching deployment mode
    if [[ "$DEPLOY_REVERSE" == false ]]; then
        sudo systemctl stop tunnel-reverse.service 2>/dev/null || true
        sudo systemctl disable tunnel-reverse.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/tunnel-reverse.service
        echo "[local-setup] Removed: tunnel-reverse.service"
    fi
    if [[ "$DEPLOY_SOCKS5" == false ]]; then
        sudo systemctl stop tunnel-socks5.service 2>/dev/null || true
        sudo systemctl disable tunnel-socks5.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/tunnel-socks5.service
        sudo systemctl stop tunnel-sshuttle.service 2>/dev/null || true
        sudo systemctl disable tunnel-sshuttle.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/tunnel-sshuttle.service
        echo "[local-setup] Removed: tunnel-socks5.service and tunnel-sshuttle.service"
    fi
    sudo systemctl daemon-reload
fi

# ---- Config directory ----
sudo mkdir -p "$CONFIG_DIR"

# ---- Environment file ----
sudo tee "$CONFIG_FILE" > /dev/null << EOF
# ssh-tunnel-proxy configuration
TUNNEL_PORT=${TUNNEL_PORT}
SOCKS5_PORT=${SOCKS5_PORT}
SSH_PORT=${SSH_PORT}
SERVER=${SERVER}
LOCAL_USER=${LOCAL_USER}
LOCAL_HOST=${LOCAL_HOST}
EOF
sudo chmod 644 "$CONFIG_FILE"
echo "[local-setup] Config: ${CONFIG_FILE}"

# ---- Reverse tunnel service ----
if [[ "$DEPLOY_REVERSE" == true ]]; then
sudo tee "/etc/systemd/system/tunnel-reverse.service" > /dev/null << EOF
[Unit]
Description=ssh-tunnel-proxy: reverse tunnel (port ${TUNNEL_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${LOCAL_USER}
EnvironmentFile=${CONFIG_FILE}
ExecStart=/usr/bin/ssh \\
    -o "ServerAliveInterval=30" \\
    -o "ServerAliveCountMax=3" \\
    -o "ExitOnForwardFailure=yes" \\
    -o "StrictHostKeyChecking=accept-new" \\
    -p \${SSH_PORT} \\
    -N -R \${TUNNEL_PORT}:localhost:22 \${SERVER}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "[local-setup] Created: tunnel-reverse.service"
fi

# ---- SOCKS5 proxy service ----
if [[ "$DEPLOY_SOCKS5" == true ]]; then
sudo tee "/etc/systemd/system/tunnel-socks5.service" > /dev/null << EOF
[Unit]
Description=ssh-tunnel-proxy: SOCKS5 proxy (port ${SOCKS5_PORT})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${LOCAL_USER}
EnvironmentFile=${CONFIG_FILE}
ExecStart=/usr/bin/ssh \\
    -o "ServerAliveInterval=30" \\
    -o "ServerAliveCountMax=3" \\
    -o "StrictHostKeyChecking=accept-new" \\
    -p \${SSH_PORT} \\
    -N -D \${SOCKS5_PORT} \${SERVER}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "[local-setup] Created: tunnel-socks5.service"
fi

# ---- sshuttle service ----
if [[ "$DEPLOY_SOCKS5" == true ]]; then
# Write iptables cleanup helper
sudo tee /usr/local/bin/sshuttle-cleanup > /dev/null << 'CLEANUP'
#!/bin/sh
for c in $(iptables -t nat -L -n 2>/dev/null | sed -n 's/^Chain \(sshuttle-[0-9]*\).*/\1/p'); do
    iptables -t nat -D PREROUTING -j "$c" 2>/dev/null
    iptables -t nat -D OUTPUT -j "$c" 2>/dev/null
    iptables -t nat -F "$c" 2>/dev/null
    iptables -t nat -X "$c" 2>/dev/null
done
for c in $(iptables -L -n 2>/dev/null | sed -n 's/^Chain \(sshuttle-[0-9]*\).*/\1/p'); do
    iptables -D INPUT -j "$c" 2>/dev/null
    iptables -D OUTPUT -j "$c" 2>/dev/null
    iptables -F "$c" 2>/dev/null
    iptables -X "$c" 2>/dev/null
done
CLEANUP
sudo chmod +x /usr/local/bin/sshuttle-cleanup

sudo tee "/etc/systemd/system/tunnel-sshuttle.service" > /dev/null << EOF
[Unit]
Description=ssh-tunnel-proxy: sshuttle transparent proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${CONFIG_FILE}
ExecStart=/usr/bin/sshuttle -r \${SERVER} \\
    --ssh-cmd "ssh -p \${SSH_PORT}" \\
    0.0.0.0/0 --dns
ExecStopPost=/usr/local/bin/sshuttle-cleanup
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

echo "[local-setup] Created: tunnel-sshuttle.service (transparent TCP proxy with DNS)"
fi

# ---- Reload & start ----
sudo systemctl daemon-reload

if [[ "$DEPLOY_REVERSE" == true ]]; then
    sudo systemctl enable tunnel-reverse.service
    if [[ "$REDEPLOY" == true ]] && systemctl is-active --quiet tunnel-reverse.service 2>/dev/null; then
        sudo systemctl restart tunnel-reverse.service
        echo "[local-setup] Restarted: tunnel-reverse"
    else
        sudo systemctl start tunnel-reverse.service
        echo "[local-setup] Started: tunnel-reverse"
    fi
fi

if [[ "$DEPLOY_SOCKS5" == true ]]; then
    sudo systemctl enable tunnel-socks5.service
    if [[ "$REDEPLOY" == true ]] && systemctl is-active --quiet tunnel-socks5.service 2>/dev/null; then
        sudo systemctl restart tunnel-socks5.service
        echo "[local-setup] Restarted: tunnel-socks5"
    else
        sudo systemctl start tunnel-socks5.service
        echo "[local-setup] Started: tunnel-socks5"
    fi
fi

if [[ "$DEPLOY_SOCKS5" == true ]]; then
    if [[ "$ENABLE_SSHUTTLE" == true ]]; then
        sudo systemctl enable tunnel-sshuttle.service
        if [[ "$REDEPLOY" == true ]] && systemctl is-active --quiet tunnel-sshuttle.service 2>/dev/null; then
            sudo systemctl restart tunnel-sshuttle.service
            echo "[local-setup] Restarted: tunnel-sshuttle"
        else
            sudo systemctl start tunnel-sshuttle.service
            echo "[local-setup] Started: tunnel-sshuttle"
        fi
    else
        echo "[local-setup] sshuttle not started. Run: sudo systemctl enable --now tunnel-sshuttle.service"
    fi
elif [[ "$ENABLE_SSHUTTLE" == true ]]; then
    echo "[local-setup] WARNING: --enable-sshuttle ignored with --only-reverse"
fi

# ---- tunnel-proxy control script ----
if [[ ! -f "/usr/local/bin/tunnel-proxy" ]]; then
    sudo tee /usr/local/bin/tunnel-proxy > /dev/null << 'TUNNELSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/ssh-tunnel-proxy"
CONFIG_FILE="$CONFIG_DIR/tunnel.conf"
ORIGINAL_USER="${SUDO_USER:-$USER}"
ORIGINAL_UID=$(id -u "$ORIGINAL_USER" 2>/dev/null || echo 1000)
DBUS_ADDR="unix:path=/run/user/${ORIGINAL_UID}/bus"
SOCKS5_PORT=1080
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true

usage() { echo "Usage: tunnel-proxy {start|stop|status|restart}" >&2; exit 1; }
start_services() {
    echo "[tunnel-proxy] Starting services..."
    sudo systemctl start tunnel-reverse.service 2>/dev/null || true
    sudo systemctl start tunnel-socks5.service 2>/dev/null || true
    echo "[tunnel-proxy] Services started"
    if command -v gsettings &>/dev/null && [[ -n "$ORIGINAL_USER" ]]; then
        sudo -u "$ORIGINAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" gsettings set org.gnome.system.proxy mode 'manual' 2>/dev/null || true
        echo "[tunnel-proxy] GNOME system proxy enabled"
    fi
    echo "[tunnel-proxy] To update this terminal, run: source ~/.bashrc"
}
stop_services() {
    echo "[tunnel-proxy] Stopping services..."
    sudo systemctl stop tunnel-reverse.service 2>/dev/null || true
    sudo systemctl stop tunnel-socks5.service 2>/dev/null || true
    echo "[tunnel-proxy] Services stopped"
    if command -v gsettings &>/dev/null && [[ -n "$ORIGINAL_USER" ]]; then
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
}
case "${1:-}" in start) start_services ;; stop) stop_services ;; restart) stop_services; sleep 1; start_services ;; status) status_services ;; *) usage ;; esac
TUNNELSCRIPT
    sudo chmod +x /usr/local/bin/tunnel-proxy
    echo "[local-setup] Deployed: /usr/local/bin/tunnel-proxy"
fi

# ---- tunnel-proxy function + auto ALL_PROXY in bashrc ----
if [[ -f "${HOME}/.bashrc" ]] && ! grep -q "^tunnel-proxy()" "${HOME}/.bashrc" 2>/dev/null; then
    # Remove any old blocks
    sed -i '/^# ssh-tunnel-proxy:/,/^# ssh-tunnel-proxy: end$/d' "${HOME}/.bashrc" 2>/dev/null || true
    sed -i '/^export ALL_PROXY=socks5h/d' "${HOME}/.bashrc" 2>/dev/null || true
    {
        echo ""
        echo "# ssh-tunnel-proxy: config"
        echo "tunnel-proxy() {"
        echo "    local cmd=\"\${1:-}\""
        echo "    local socks5_port=${SOCKS5_PORT}"
        echo "    case \"\$cmd\" in"
        echo "        start|restart)"
        echo "            sudo /usr/local/bin/tunnel-proxy \"\$@\""
        echo "            unset all_proxy http_proxy https_proxy 2>/dev/null || true"
        echo "            export ALL_PROXY=socks5h://127.0.0.1:\$socks5_port"
        echo "            ;;"
        echo "        stop)"
        echo "            sudo /usr/local/bin/tunnel-proxy \"\$@\""
        echo "            unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy 2>/dev/null || true"
        echo "            ;;"
        echo "        status)"
        echo "            sudo /usr/local/bin/tunnel-proxy \"\$@\""
        echo "            ;;"
        echo "        *)"
        echo "            sudo /usr/local/bin/tunnel-proxy \"\$@\""
        echo "            ;;"
        echo "    esac"
        echo "}"
        echo "if ss -tlnp 2>/dev/null | grep -q \":${SOCKS5_PORT} \"; then"
        echo "    unset all_proxy http_proxy https_proxy 2>/dev/null || true"
        echo "    export ALL_PROXY=socks5h://127.0.0.1:${SOCKS5_PORT}"
        echo "else"
        echo "    unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy 2>/dev/null || true"
        echo "fi"
        echo "# ssh-tunnel-proxy: end"
    } >> "${HOME}/.bashrc" 2>/dev/null || true
    echo "[local-setup] Added tunnel-proxy function + auto ALL_PROXY to ~/.bashrc"
fi

echo "[local-setup] Complete"
