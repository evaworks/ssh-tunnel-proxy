#!/usr/bin/env bash
#
# ssh-tunnel-proxy Uninstaller
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

CONFIG_DIR="/etc/ssh-tunnel-proxy"
SERVICES=(tunnel-reverse tunnel-socks5 tunnel-sshuttle)

confirm() {
    echo -en "${YELLOW}Uninstall ssh-tunnel-proxy? This will stop all tunnels. [y/N]${NC} "
    if [[ -t 0 ]]; then
        read -r resp
    else
        read -r resp < /dev/tty 2>/dev/null || resp="n"
    fi
    [[ "$resp" == "y" || "$resp" == "Y" ]]
}

main() {
    echo ""
    echo -e "${BLUE}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║     ssh-tunnel-proxy Uninstaller     ║${NC}"
    echo -e "${BLUE}  ╚══════════════════════════════════════╝${NC}"
    echo ""

    if ! confirm; then
        info "Cancelled."
        exit 0
    fi

    # ---- Read config before removing it ----
    local SERVER=""
    local SSH_PORT="22"
    local TUNNEL_PORT="2222"
    if [[ -f "$CONFIG_DIR/tunnel.conf" ]]; then
        source "$CONFIG_DIR/tunnel.conf"
        info "Read config: SERVER=${SERVER}, TUNNEL_PORT=${TUNNEL_PORT}"
    fi

    # Stop and disable all services
    echo ""
    for svc in "${SERVICES[@]}"; do
        if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            sudo systemctl stop "${svc}.service"
            info "Stopped: ${svc}.service"
        fi
        if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
            sudo systemctl disable "${svc}.service"
            info "Disabled: ${svc}.service"
        fi
    done

    # Remove service files
    for svc in "${SERVICES[@]}"; do
        sudo rm -f "/etc/systemd/system/${svc}.service"
    done
    info "Removed service files from /etc/systemd/system/"

    # Clean up sshuttle iptables rules
    if command -v iptables &>/dev/null; then
        for c in $(iptables -t nat -L -n 2>/dev/null | sed -n 's/^Chain \(sshuttle-[0-9]*\).*/\1/p'); do
            sudo iptables -t nat -D PREROUTING -j "$c" 2>/dev/null || true
            sudo iptables -t nat -D OUTPUT -j "$c" 2>/dev/null || true
            sudo iptables -t nat -F "$c" 2>/dev/null || true
            sudo iptables -t nat -X "$c" 2>/dev/null || true
        done
        for c in $(iptables -L -n 2>/dev/null | sed -n 's/^Chain \(sshuttle-[0-9]*\).*/\1/p'); do
            sudo iptables -D INPUT -j "$c" 2>/dev/null || true
            sudo iptables -D OUTPUT -j "$c" 2>/dev/null || true
            sudo iptables -F "$c" 2>/dev/null || true
            sudo iptables -X "$c" 2>/dev/null || true
        done
    fi
    sudo rm -f /usr/local/bin/sshuttle-cleanup

    # Remove config directory
    if [[ -d "$CONFIG_DIR" ]]; then
        sudo rm -rf "$CONFIG_DIR"
        info "Removed config directory: ${CONFIG_DIR}"
    fi

    # Reload systemd
    sudo systemctl daemon-reload

    # Remove SSH config entry
    local ssh_config="${HOME}/.ssh/config"
    if [[ -f "$ssh_config" ]]; then
        local tmpfile
        tmpfile=$(mktemp)
        sed '/^# ssh-tunnel-proxy:/,/^[[:space:]]*$/d' "$ssh_config" > "$tmpfile" 2>/dev/null || true
        sed -i '/^Host tunnel-proxy$/,/^$/d' "$tmpfile" 2>/dev/null || true
        mv "$tmpfile" "$ssh_config"
        chmod 600 "$ssh_config" 2>/dev/null || true
        info "Removed SSH config entry (Host tunnel-proxy)"
    fi

    # Remove tunnel-proxy control script
    sudo rm -f /usr/local/bin/tunnel-proxy
    info "Removed: /usr/local/bin/tunnel-proxy"

    # Remove tunnel-proxy config from bashrc
    if [[ -f "${HOME}/.bashrc" ]]; then
        local tmpfile
        tmpfile=$(mktemp)
        sed '/^# ssh-tunnel-proxy: config/,/^# ssh-tunnel-proxy: end$/d' "${HOME}/.bashrc" > "$tmpfile" 2>/dev/null || true
        mv "$tmpfile" "${HOME}/.bashrc"
        info "Removed tunnel-proxy config from ~/.bashrc"
    fi

    # ---- Clean up relay server ----
    if [[ -n "$SERVER" ]]; then
        echo ""
        info "Cleaning up relay server ${SERVER}..."
        if ssh -o BatchMode=yes -o ConnectTimeout=5 -p "$SSH_PORT" "$SERVER" "sudo bash -s -- ${TUNNEL_PORT}" 2>/dev/null << 'REMOTECLEANUP'
#!/usr/bin/env bash
set -euo pipefail

TUNNEL_PORT="$1"
BACKUP_FILE="/etc/ssh/sshd_config.bak.ssh-tunnel-proxy"

echo "[REMOTE] Reverting GatewayPorts..."

if [[ -f "$BACKUP_FILE" ]]; then
    cp "$BACKUP_FILE" /etc/ssh/sshd_config
    rm -f "$BACKUP_FILE"
    echo "[REMOTE] Restored sshd_config from backup"
else
    sed -i '/^GatewayPorts yes/d' /etc/ssh/sshd_config
    echo "[REMOTE] Removed GatewayPorts from sshd_config"
fi

echo "[REMOTE] Validating sshd configuration..."
if sshd -t 2>/dev/null; then
    if systemctl list-units --type=service 2>/dev/null | grep -q sshd.service; then
        systemctl restart sshd
    elif systemctl list-units --type=service 2>/dev/null | grep -q ssh.service; then
        systemctl restart ssh
    fi
    echo "[REMOTE] SSH service restarted"
else
    echo "[REMOTE] WARNING: sshd config validation failed, check manually"
fi

echo "[REMOTE] Removing firewall rule for port ${TUNNEL_PORT}..."
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --remove-port="${TUNNEL_PORT}/tcp" --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
elif command -v ufw &>/dev/null; then
    ufw delete allow "${TUNNEL_PORT}/tcp" 2>/dev/null || true
elif command -v iptables &>/dev/null; then
    iptables -D INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT 2>/dev/null || true
fi
echo "[REMOTE] Firewall rule removed"

echo "[REMOTE] Cleanup complete"
REMOTECLEANUP
        then
            info "Relay server cleaned up successfully"
        else
            warn "Relay server cleanup failed (check SSH connectivity or do it manually)"
        fi
    fi

    echo ""
    echo -e "${GREEN}ssh-tunnel-proxy has been uninstalled.${NC}"
    echo ""
    echo "The following were left untouched (may be needed elsewhere):"
    echo "  - SSH keys:      ~/.ssh/id_ed25519*"
    echo "  - Packages:      sshuttle"
    echo ""
}

main
