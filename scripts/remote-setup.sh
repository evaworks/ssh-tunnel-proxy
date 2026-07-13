#!/usr/bin/env bash
#
# remote-setup.sh
# Run this on the relay server (Hong Kong) to enable GatewayPorts + firewall.
#
# Can be executed remotely via:
#   ssh user@hk-server 'sudo bash -s' < remote-setup.sh
#
# Or standalone on the server:
#   sudo bash remote-setup.sh [tunnel-port] [ssh-port]
#
set -euo pipefail

TUNNEL_PORT="${1:-2222}"
SSH_PORT="${2:-22}"
BACKUP_FILE="/etc/ssh/sshd_config.bak.ssh-tunnel-proxy"

echo "[remote-setup] GatewayPorts configuration..."

# Backup sshd_config (once)
if [[ ! -f "$BACKUP_FILE" ]]; then
    cp /etc/ssh/sshd_config "$BACKUP_FILE"
    echo "[remote-setup] Backed up sshd_config to ${BACKUP_FILE}"
fi

# Enable GatewayPorts
if grep -q "^GatewayPorts yes" /etc/ssh/sshd_config 2>/dev/null; then
    echo "[remote-setup] GatewayPorts already enabled"
else
    sed -i 's/^#GatewayPorts yes/GatewayPorts yes/' /etc/ssh/sshd_config
    if ! grep -q "^GatewayPorts yes" /etc/ssh/sshd_config 2>/dev/null; then
        echo "GatewayPorts yes" >> /etc/ssh/sshd_config
    fi
    echo "[remote-setup] GatewayPorts enabled"
fi

# Validate and restart
echo "[remote-setup] Validating sshd configuration..."
if sshd -t 2>/dev/null; then
    if systemctl list-units --type=service 2>/dev/null | grep -q sshd.service; then
        systemctl restart sshd
    elif systemctl list-units --type=service 2>/dev/null | grep -q ssh.service; then
        systemctl restart ssh
    else
        echo "[remote-setup] WARNING: Could not find SSH service"
    fi
    echo "[remote-setup] SSH service restarted"
else
    echo "[remote-setup] ERROR: sshd config invalid. Rolling back..."
    cp "$BACKUP_FILE" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo "[remote-setup] Rolled back sshd_config"
    exit 1
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
