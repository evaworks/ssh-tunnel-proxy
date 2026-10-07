#!/usr/bin/env bash
#
# remote-setup.sh
# Run this on the relay server to enable GatewayPorts + open the tunnel port.
#
# Normally executed via install.sh, but can be run standalone:
#   ssh user@relay 'sudo bash -s -- 2222 22' < scripts/remote-setup.sh
#   sudo bash scripts/remote-setup.sh [tunnel-port] [ssh-port] [old-tunnel-port]
#
# NOTE: install.sh embeds an equivalent script inline for `curl | bash`.
# Keep the two in sync.
#
set -euo pipefail

TUNNEL_PORT="${1:-2222}"
SSH_PORT="${2:-22}"
OLD_TUNNEL_PORT="${3:-}"
SSHD_CONF="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
BACKUP_FILE="${SSHD_CONF}.bak.ssh-tunnel-proxy"

echo "[remote-setup] GatewayPorts configuration..."

# Backup sshd_config (once, before our first modification)
if [[ ! -f "$BACKUP_FILE" ]]; then
    cp "$SSHD_CONF" "$BACKUP_FILE"
    echo "[remote-setup] Backed up sshd_config to ${BACKUP_FILE}"
fi

# sshd uses the FIRST value found for a keyword, so every existing GatewayPorts
# directive must be replaced - appending at the end would be ignored.
if grep -qiE '^[[:space:]]*#*[[:space:]]*GatewayPorts[[:space:]]' "$SSHD_CONF"; then
    sed -i -E 's/^[[:space:]]*#*[[:space:]]*[Gg]ateway[Pp]orts[[:space:]]+.*/GatewayPorts yes/' "$SSHD_CONF"
    echo "[remote-setup] GatewayPorts set to yes (replaced existing directive)"
else
    echo "GatewayPorts yes" >> "$SSHD_CONF"
    echo "[remote-setup] GatewayPorts enabled"
fi

# Validate before restarting
echo "[remote-setup] Validating sshd configuration..."
if ! sshd -t -f "$SSHD_CONF" 2>/dev/null; then
    echo "[remote-setup] ERROR: sshd config validation failed. Rolling back..."
    if [[ -f "$BACKUP_FILE" ]]; then cp "$BACKUP_FILE" "$SSHD_CONF"; fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo "[remote-setup] Rolled back sshd_config to original"
    exit 1
fi

# Confirm the value that will actually be applied (first-value-wins semantics)
if sshd -T -f "$SSHD_CONF" >/dev/null 2>&1; then
    if ! sshd -T -f "$SSHD_CONF" 2>/dev/null | grep -qiE '^gatewayports[[:space:]]+yes'; then
        echo "[remote-setup] ERROR: GatewayPorts did not take effect. Rolling back..."
        if [[ -f "$BACKUP_FILE" ]]; then cp "$BACKUP_FILE" "$SSHD_CONF"; fi
        exit 1
    fi
    echo "[remote-setup] GatewayPorts verified via 'sshd -T'"
fi

# Restart the SSH service
if systemctl list-units --type=service 2>/dev/null | grep -q sshd.service; then
    systemctl restart sshd
elif systemctl list-units --type=service 2>/dev/null | grep -q ssh.service; then
    systemctl restart ssh
else
    echo "[remote-setup] WARNING: Could not find SSH service to restart"
fi
echo "[remote-setup] SSH service restarted successfully"

# Remove the firewall rule of a previous installation when the port changed
if [[ -n "$OLD_TUNNEL_PORT" && "$OLD_TUNNEL_PORT" != "$TUNNEL_PORT" ]]; then
    echo "[remote-setup] Removing stale firewall rule for old port ${OLD_TUNNEL_PORT}..."
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --remove-port="${OLD_TUNNEL_PORT}/tcp" --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
    fi
    if command -v ufw &>/dev/null; then
        ufw delete allow "${OLD_TUNNEL_PORT}/tcp" 2>/dev/null || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "${OLD_TUNNEL_PORT}" -j ACCEPT 2>/dev/null || true
    fi
fi

echo "[remote-setup] Firewall configuration for port ${TUNNEL_PORT}..."

FIREWALL_OK=0

if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --add-port="${TUNNEL_PORT}/tcp" --permanent && firewall-cmd --reload
    echo "[remote-setup] firewalld: port ${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi

if command -v ufw &>/dev/null; then
    ufw allow "${TUNNEL_PORT}/tcp"
    echo "[remote-setup] ufw: port ${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi

if command -v iptables &>/dev/null && ! command -v firewall-cmd &>/dev/null && ! command -v ufw &>/dev/null; then
    if ! iptables -C INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT 2>/dev/null; then
        iptables -A INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT
    fi
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    echo "[remote-setup] iptables: port ${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi

if [[ "$FIREWALL_OK" -eq 0 ]]; then
    echo "[remote-setup] WARNING: No firewall tool detected. Ensure port ${TUNNEL_PORT} is open."
fi

echo "[remote-setup] Complete"
