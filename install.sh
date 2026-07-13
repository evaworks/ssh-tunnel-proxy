#!/usr/bin/env bash
#
# ssh-tunnel-proxy — One-command SSH tunnel setup
# https://github.com/evaworks/ssh-tunnel-proxy
#
# Let any Linux device:
#   - access the internet via a relay server (SOCKS5 + sshuttle)
#   - be accessed from outside via reverse SSH tunnel
#
set -euo pipefail

# ============================================
# Configuration defaults
# ============================================
TUNNEL_PORT=2222
SOCKS5_PORT=1080
SSH_PORT=22
SERVER=""
ENABLE_SSHUTTLE=false
VERBOSE=false
DRY_RUN=false
DEPLOY_REVERSE=true
DEPLOY_SOCKS5=true

LOCAL_USER="$(whoami)"
LOCAL_HOST="$(hostname -s)"
SSH_KEY_TYPE="ed25519"
SSH_KEY_PATH="${HOME}/.ssh/id_${SSH_KEY_TYPE}"

CONFIG_DIR="/etc/ssh-tunnel-proxy"
CONFIG_FILE="${CONFIG_DIR}/tunnel.conf"
LOG_FILE="/tmp/ssh-tunnel-proxy-install.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"

SSH_OPTS=""
REMOTE_SSH_OPTS=""

# ============================================
# Colors
# ============================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()    { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"; }
info()   { echo -e "${GREEN}[INFO]${NC}  $*"; log "[INFO] $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; log "[WARN] $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*"; log "[ERROR] $*"; }
header() { echo -e "\n${BLUE}═══════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}═══════════════════════════════════════${NC}"; log "=== $* ==="; }

# ============================================
# Safe command execution
# ============================================
run() {
    log "[CMD] $*"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
        return 0
    fi
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[EXEC]${NC} $*"
    fi
    "$@"
}

sudo_run() {
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} sudo $*"
        return 0
    fi
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[EXEC]${NC} sudo $*"
    fi
    sudo "$@"
}

# ============================================
# Prompt helper (works with curl | bash)
# ============================================
prompt_yes_no() {
    local msg="$1"
    local default="${2:-n}"
    local resp

    if [[ -t 0 ]]; then
        read -r -p "$msg [y/N] " resp
    else
        read -r -p "$msg [y/N] " resp < /dev/tty 2>/dev/null || resp="$default"
    fi

    [[ "$resp" == "y" || "$resp" == "Y" ]]
}

# ============================================
# Usage
# ============================================
usage() {
    cat <<'EOF'
Usage: install.sh --server user@host [options]

Required:
  --server <user@host>     Hong Kong relay server (format: user@host)

Optional:
  --tunnel-port <port>     Reverse tunnel port on relay server (default: 2222)
  --socks5-port <port>     Local SOCKS5 proxy port (default: 1080)
  --ssh-port <port>        SSH port on relay server (default: 22)
  --only-reverse           Deploy reverse tunnel only (skip SOCKS5)
  --only-socks5            Deploy SOCKS5 proxy only (skip reverse tunnel)
  --enable-sshuttle        Enable sshuttle transparent proxy automatically
  --verbose                Show detailed execution output
  --dry-run                Print what would be done without executing
  --help                   Show this help message

Examples:
  curl -sSL https://.../install.sh | bash -s -- --server root@1.2.3.4
  ./install.sh --server root@1.2.3.4 --tunnel-port 8888 --enable-sshuttle
  ./install.sh --server root@1.2.3.4 --ssh-port 2222 --verbose
EOF
    exit 0
}

# ============================================
# Parse arguments
# ============================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)          SERVER="$2"; shift 2 ;;
            --tunnel-port)     TUNNEL_PORT="$2"; shift 2 ;;
            --socks5-port)     SOCKS5_PORT="$2"; shift 2 ;;
            --ssh-port)        SSH_PORT="$2"; shift 2 ;;
            --enable-sshuttle) ENABLE_SSHUTTLE=true; shift ;;
            --only-reverse)    DEPLOY_REVERSE=true; DEPLOY_SOCKS5=false; shift ;;
            --only-socks5)     DEPLOY_REVERSE=false; DEPLOY_SOCKS5=true; shift ;;
            --verbose)         VERBOSE=true; shift ;;
            --dry-run)         DRY_RUN=true; shift ;;
            --help)            usage ;;
            *) error "Unknown option: $1"; usage ;;
        esac
    done

    if [[ -z "$SERVER" ]]; then
        error "--server is required"
        usage
    fi

    if [[ "$SERVER" != *"@"* ]]; then
        error "SERVER must be in user@host format (e.g. root@1.2.3.4)"
        exit 1
    fi

    if [[ "$SSH_PORT" -ne 22 ]]; then
        SSH_OPTS="-p ${SSH_PORT}"
        REMOTE_SSH_OPTS="-p ${SSH_PORT}"
    fi

    # Validate ports are numbers
    for var in TUNNEL_PORT SOCKS5_PORT SSH_PORT; do
        if ! [[ "${!var}" =~ ^[0-9]+$ ]]; then
            error "$var must be a number"
            exit 1
        fi
    done

    # Validate deployment mode
    if [[ "$DEPLOY_REVERSE" == false && "$DEPLOY_SOCKS5" == false ]]; then
        error "Cannot use --only-reverse and --only-socks5 together"
        exit 1
    fi
}

# ============================================
# Pre-flight checks
# ============================================
preflight_check() {
    header "Pre-flight checks"

    info "System : $(uname -s) $(uname -m)"
    info "Host   : ${LOCAL_USER}@${LOCAL_HOST}"
    info "Server : ${SERVER} (SSH port: ${SSH_PORT})"

    if ! command -v sudo &>/dev/null; then
        error "sudo is required but not found"
        exit 1
    fi

    # Check local port availability
    if command -v ss &>/dev/null; then
        if ss -tlnp 2>/dev/null | grep -q ":${SOCKS5_PORT} "; then
            warn "Port ${SOCKS5_PORT} is already in use locally. Use --socks5-port to change it."
        fi
    fi

    # Remote port check
    local SERVER_HOST="${SERVER#*@}"
    if command -v nc &>/dev/null; then
        if nc -z -w 3 "$SERVER_HOST" "$SSH_PORT" 2>/dev/null; then
            info "Relay server ${SERVER_HOST}:${SSH_PORT} is reachable"
        else
            warn "Cannot reach ${SERVER_HOST}:${SSH_PORT}. Check network / firewall."
        fi
    fi
}

# ============================================
# Install dependencies
# ============================================
install_deps() {
    header "Installing dependencies"

    local need=()

    command -v sshuttle &>/dev/null || need+=("sshuttle")

    if [[ ${#need[@]} -eq 0 ]]; then
        info "sshuttle is already installed"
        return
    fi

    info "Installing: ${need[*]}"

    if   command -v apt    &>/dev/null; then sudo_run apt update -qq && sudo_run apt install -y -qq "${need[@]}"
    elif command -v dnf    &>/dev/null; then sudo_run dnf install -y -q "${need[@]}"
    elif command -v yum    &>/dev/null; then sudo_run yum install -y -q "${need[@]}"
    elif command -v pacman &>/dev/null; then sudo_run pacman -S --noconfirm "${need[@]}"
    elif command -v zypper &>/dev/null; then sudo_run zypper install -y "${need[@]}"
    else
        warn "Unknown package manager. Install manually: ${need[*]}"
        warn "  autossh : https://www.harding.motd.ca/autossh/"
        warn "  sshuttle: https://github.com/sshuttle/sshuttle"
    fi
}

# ============================================
# SSH key setup
# ============================================
setup_ssh_key() {
    header "SSH key setup"

    run mkdir -p "${HOME}/.ssh"
    run chmod 700 "${HOME}/.ssh"

    if [[ -f "$SSH_KEY_PATH" ]]; then
        info "Using existing SSH key: ${SSH_KEY_PATH}"
    else
        run ssh-keygen -t "$SSH_KEY_TYPE" -N "" -f "$SSH_KEY_PATH"
        info "Generated SSH key: ${SSH_KEY_PATH}"
    fi
}

# ============================================
# Copy SSH key to remote server
# ============================================
copy_ssh_key() {
    header "Copy SSH key to relay server"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would run: ssh-copy-id -i ${SSH_KEY_PATH}.pub ${SSH_OPTS} ${SERVER}"
        return
    fi

    # Try ssh-copy-id first, fall back to manual
    if command -v ssh-copy-id &>/dev/null; then
        info "You will be prompted for the relay server's password (one time only)"
        ssh-copy-id -i "${SSH_KEY_PATH}.pub" ${SSH_OPTS} "$SERVER"
    else
        warn "ssh-copy-id not found, copying key manually"
        info "You will be prompted for the relay server's password"
        local pubkey
        pubkey=$(cat "${SSH_KEY_PATH}.pub")
        ssh ${SSH_OPTS} "$SERVER" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${pubkey}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    fi

    info "SSH key copied successfully"
}

# ============================================
# Test passwordless SSH
# ============================================
test_ssh_connectivity() {
    header "Testing SSH connection"

    if run ssh -o BatchMode=yes -o ConnectTimeout=5 ${SSH_OPTS} "$SERVER" "echo connected" 2>/dev/null; then
        info "Passwordless SSH to ${SERVER} works"
    else
        error "Passwordless SSH failed. Check your SSH key setup."
        error "Try manually: ssh ${SSH_OPTS} ${SERVER}"
        exit 1
    fi
}

# ============================================
# Remote server setup (GatewayPorts + firewall)
# ============================================
remote_setup() {
    header "Configuring relay server"

    if [[ "$DEPLOY_REVERSE" == false ]]; then
        info "Reverse tunnel not enabled, skipping remote GatewayPorts/firewall setup"
        return
    fi

    info "Running remote setup script on ${SERVER}..."

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would configure GatewayPorts and firewall on ${SERVER}"
        return
    fi

    # Pass TUNNEL_PORT as $1 and SSH_PORT as $2 to the remote script
    ssh ${SSH_OPTS} "$SERVER" "sudo bash -s -- ${TUNNEL_PORT} ${SSH_PORT}" << 'REMOTESCRIPT'
#!/usr/bin/env bash
set -euo pipefail

TUNNEL_PORT="$1"
SSH_PORT="$2"
BACKUP_FILE="/etc/ssh/sshd_config.bak.ssh-tunnel-proxy"

echo "[REMOTE] GatewayPorts configuration..."

# Backup sshd_config (once)
if [[ ! -f "$BACKUP_FILE" ]]; then
    cp /etc/ssh/sshd_config "$BACKUP_FILE"
    echo "[REMOTE] Backed up sshd_config to ${BACKUP_FILE}"
fi

# Enable GatewayPorts
if grep -q "^GatewayPorts yes" /etc/ssh/sshd_config 2>/dev/null; then
    echo "[REMOTE] GatewayPorts already enabled"
else
    # Uncomment if commented out
    sed -i 's/^#GatewayPorts yes/GatewayPorts yes/' /etc/ssh/sshd_config
    # Append if not present
    if ! grep -q "^GatewayPorts yes" /etc/ssh/sshd_config 2>/dev/null; then
        echo "GatewayPorts yes" >> /etc/ssh/sshd_config
    fi
    echo "[REMOTE] GatewayPorts enabled"
fi

# Validate sshd config before restart
echo "[REMOTE] Validating sshd configuration..."
if sshd -t 2>/dev/null; then
    # Determine SSH service name
    if systemctl list-units --type=service 2>/dev/null | grep -q sshd.service; then
        systemctl restart sshd
    elif systemctl list-units --type=service 2>/dev/null | grep -q ssh.service; then
        systemctl restart ssh
    else
        echo "[REMOTE] WARNING: Could not find SSH service to restart"
    fi
    echo "[REMOTE] SSH service restarted successfully"
else
    echo "[REMOTE] ERROR: sshd config validation failed. Rolling back..."
    cp "$BACKUP_FILE" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo "[REMOTE] Rolled back sshd_config to original"
    exit 1
fi

echo "[REMOTE] Firewall configuration for port ${TUNNEL_PORT}..."

FIREWALL_OK=0

if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --add-port="${TUNNEL_PORT}/tcp" --permanent && firewall-cmd --reload
    echo "[REMOTE] firewalld: port ${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi

if command -v ufw &>/dev/null; then
    ufw allow "${TUNNEL_PORT}/tcp"
    echo "[REMOTE] ufw: port ${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi

if command -v iptables &>/dev/null && ! command -v firewall-cmd &>/dev/null && ! command -v ufw &>/dev/null; then
    if ! iptables -C INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT 2>/dev/null; then
        iptables -A INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT
    fi
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    echo "[REMOTE] iptables: port ${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi

if [[ "$FIREWALL_OK" -eq 0 ]]; then
    echo "[REMOTE] WARNING: No firewall tool detected. Ensure port ${TUNNEL_PORT} is open."
fi

echo "[REMOTE] Remote setup complete"
REMOTESCRIPT

    info "Relay server configured successfully"
}

# ============================================
# Local tunnel setup
# ============================================
local_setup() {
    header "Configuring local tunnels"

    local REDEPLOY=false
    if [[ -d "$CONFIG_DIR" ]]; then
        REDEPLOY=true
        info "Existing installation detected, will restart services with new config"
    fi

    # ---- Clean up services no longer needed when switching deployment mode ----
    if [[ "$REDEPLOY" == true ]]; then
        if [[ "$DEPLOY_REVERSE" == false ]]; then
            sudo_run systemctl stop tunnel-reverse.service 2>/dev/null || true
            sudo_run systemctl disable tunnel-reverse.service 2>/dev/null || true
            sudo_run rm -f /etc/systemd/system/tunnel-reverse.service
            info "Removed: tunnel-reverse.service (not in current deployment mode)"
        fi
        if [[ "$DEPLOY_SOCKS5" == false ]]; then
            sudo_run systemctl stop tunnel-socks5.service 2>/dev/null || true
            sudo_run systemctl disable tunnel-socks5.service 2>/dev/null || true
            sudo_run rm -f /etc/systemd/system/tunnel-socks5.service
            sudo_run systemctl stop tunnel-sshuttle.service 2>/dev/null || true
            sudo_run systemctl disable tunnel-sshuttle.service 2>/dev/null || true
            sudo_run rm -f /etc/systemd/system/tunnel-sshuttle.service
            info "Removed: tunnel-socks5.service and tunnel-sshuttle.service (not in current deployment mode)"
        fi
        sudo_run systemctl daemon-reload
    fi

    # ---- Config directory ----
    sudo_run mkdir -p "$CONFIG_DIR"

    # ---- Environment file ----
    log "Writing config file: ${CONFIG_FILE}"
    if [[ "$DRY_RUN" == false ]]; then
        sudo tee "$CONFIG_FILE" > /dev/null << EOF
# ssh-tunnel-proxy configuration
# Generated: $(date)
# Change values here and restart services to apply
TUNNEL_PORT=${TUNNEL_PORT}
SOCKS5_PORT=${SOCKS5_PORT}
SSH_PORT=${SSH_PORT}
SERVER=${SERVER}
LOCAL_USER=${LOCAL_USER}
LOCAL_HOST=${LOCAL_HOST}
SSH_KEY_TYPE=${SSH_KEY_TYPE}
EOF
        sudo chmod 644 "$CONFIG_FILE"
    fi
    info "Config file: ${CONFIG_FILE}"

    # ---- Reverse tunnel service (system level) ----
    if [[ "$DEPLOY_REVERSE" == true ]]; then
        local reverse_svc="/etc/systemd/system/tunnel-reverse.service"
        sudo tee "$reverse_svc" > /dev/null << EOF
[Unit]
Description=ssh-tunnel-proxy: reverse tunnel (port ${TUNNEL_PORT})
Documentation=https://github.com/evaworks/ssh-tunnel-proxy
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
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts" \\
    -p \${SSH_PORT} \\
    -N -R \${TUNNEL_PORT}:localhost:22 \${SERVER}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        info "Created: tunnel-reverse.service (port ${TUNNEL_PORT} → localhost:22)"
    fi

    # ---- SOCKS5 proxy service (system level) ----
    if [[ "$DEPLOY_SOCKS5" == true ]]; then
        local socks5_svc="/etc/systemd/system/tunnel-socks5.service"
        sudo tee "$socks5_svc" > /dev/null << EOF
[Unit]
Description=ssh-tunnel-proxy: SOCKS5 proxy (port ${SOCKS5_PORT})
Documentation=https://github.com/evaworks/ssh-tunnel-proxy
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
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts" \\
    -p \${SSH_PORT} \\
    -N -D \${SOCKS5_PORT} \${SERVER}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
        info "Created: tunnel-socks5.service (SOCKS5 on 127.0.0.1:${SOCKS5_PORT})"
    fi

    # ---- sshuttle transparent proxy service (system level) ----
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

        local sshuttle_svc="/etc/systemd/system/tunnel-sshuttle.service"
        sudo tee "$sshuttle_svc" > /dev/null << EOF
[Unit]
Description=ssh-tunnel-proxy: sshuttle transparent proxy
Documentation=https://github.com/evaworks/ssh-tunnel-proxy
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
        info "Created: tunnel-sshuttle.service (transparent TCP proxy with DNS)"
    fi

    # ---- Reload systemd ----
    sudo_run systemctl daemon-reload

    # ---- Enable and start/restart services ----
    if [[ "$REDEPLOY" == true ]]; then
        info "Re-deploy: restarting services with new configuration..."
    else
        info "Starting tunnel services..."
    fi

    if [[ "$DEPLOY_REVERSE" == true ]]; then
        sudo_run systemctl enable tunnel-reverse.service
        if [[ "$REDEPLOY" == true ]] && systemctl is-active --quiet tunnel-reverse.service 2>/dev/null; then
            sudo_run systemctl restart tunnel-reverse.service
            info "Restarted: tunnel-reverse.service"
        else
            sudo_run systemctl start tunnel-reverse.service
            info "Started: tunnel-reverse.service"
        fi
    fi

    if [[ "$DEPLOY_SOCKS5" == true ]]; then
        sudo_run systemctl enable tunnel-socks5.service
        if [[ "$REDEPLOY" == true ]] && systemctl is-active --quiet tunnel-socks5.service 2>/dev/null; then
            sudo_run systemctl restart tunnel-socks5.service
            info "Restarted: tunnel-socks5.service"
        else
            sudo_run systemctl start tunnel-socks5.service
            info "Started: tunnel-socks5.service"
        fi
    fi

    if [[ "$DEPLOY_SOCKS5" == true ]]; then
        if [[ "$ENABLE_SSHUTTLE" == true ]]; then
            sudo_run systemctl enable tunnel-sshuttle.service
            if [[ "$REDEPLOY" == true ]] && systemctl is-active --quiet tunnel-sshuttle.service 2>/dev/null; then
                sudo_run systemctl restart tunnel-sshuttle.service
                info "Restarted: tunnel-sshuttle.service"
            else
                sudo_run systemctl start tunnel-sshuttle.service
                info "Started: tunnel-sshuttle.service"
            fi
        else
            info "sshuttle not auto-started. Enable with:"
            info "  sudo systemctl enable --now tunnel-sshuttle.service"
        fi
    elif [[ "$ENABLE_SSHUTTLE" == true ]]; then
        warn "--enable-sshuttle is ignored with --only-reverse (sshuttle requires SOCKS5 mode)"
    fi

    # ---- SSH config for easy access ----
    if [[ "$DEPLOY_REVERSE" == true ]]; then
        local ssh_config="${HOME}/.ssh/config"

        local SERVER_JUMP="$SERVER"
        if [[ "$SSH_PORT" -ne 22 ]]; then
            SERVER_JUMP="${SERVER}:${SSH_PORT}"
        fi

        local ssh_entry="
# ssh-tunnel-proxy: ${LOCAL_HOST}
Host tunnel-proxy
    HostName localhost
    Port ${TUNNEL_PORT}
    ProxyJump ${SERVER_JUMP}
    User ${LOCAL_USER}
    ServerAliveInterval 30
    ServerAliveCountMax 3
"

        run mkdir -p "${HOME}/.ssh"
        if [[ -f "$ssh_config" ]] && grep -q "tunnel-proxy" "$ssh_config" 2>/dev/null; then
            info "SSH config entry already exists (~/.ssh/config)"
        else
            echo "$ssh_entry" >> "$ssh_config" 2>/dev/null || true
            run chmod 600 "$ssh_config" 2>/dev/null || true
            info "Added SSH config entry: Host tunnel-proxy"
        fi
    fi

    # ---- tunnel-proxy control script ----
    local TUNNEL_SCRIPT="/usr/local/bin/tunnel-proxy"
    if [[ ! -f "$TUNNEL_SCRIPT" ]]; then
        sudo_run tee "$TUNNEL_SCRIPT" > /dev/null << 'TUNNELSCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="/etc/ssh-tunnel-proxy"
CONFIG_FILE="$CONFIG_DIR/tunnel.conf"
ORIGINAL_USER="${SUDO_USER:-$USER}"
SOCKS5_PORT=1080
[[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" 2>/dev/null || true

usage() { echo "Usage: tunnel-proxy {start|stop|status|restart}" >&2; exit 1; }

start_services() {
    echo "[tunnel-proxy] Starting services..."
    sudo systemctl start tunnel-reverse.service 2>/dev/null || true
    sudo systemctl start tunnel-socks5.service 2>/dev/null || true
    echo "[tunnel-proxy] Services started"
    if command -v gsettings &>/dev/null && [[ -n "$ORIGINAL_USER" ]]; then
        sudo -u "$ORIGINAL_USER" gsettings set org.gnome.system.proxy mode 'manual' 2>/dev/null || true
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
        sudo -u "$ORIGINAL_USER" gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null || true
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
        sudo_run chmod +x "$TUNNEL_SCRIPT"
        info "Deployed: /usr/local/bin/tunnel-proxy"
    else
        info "Already exists: /usr/local/bin/tunnel-proxy"
    fi

    # ---- tunnel-proxy function + auto ALL_PROXY in bashrc ----
    local BASH_MARK="# ssh-tunnel-proxy: config"
    if [[ -f "${HOME}/.bashrc" ]] && grep -q "^tunnel-proxy()" "${HOME}/.bashrc" 2>/dev/null; then
        info "tunnel-proxy function already exists in ~/.bashrc"
    else
        # Remove any old static or dynamic ALL_PROXY blocks
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
        info "Added tunnel-proxy function + auto ALL_PROXY to ~/.bashrc"
    fi
}

# ============================================
# Verify services
# ============================================
verify_services() {
    header "Verifying services"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} Would verify services are running"
        return
    fi

    local failed=0
    local services=()

    [[ "$DEPLOY_REVERSE" == true ]] && services+=("tunnel-reverse.service")
    [[ "$DEPLOY_SOCKS5" == true ]] && services+=("tunnel-socks5.service")
    [[ "$DEPLOY_SOCKS5" == true && "$ENABLE_SSHUTTLE" == true ]] && services+=("tunnel-sshuttle.service")

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "${svc}: active"
        else
            warn "${svc}: NOT active (check with: sudo systemctl status ${svc})"
            failed=1
        fi
    done

    return "$failed"
}

# ============================================
# Print usage instructions
# ============================================
print_instructions() {
    header "Installation Complete"

    local SERVER_HOST="${SERVER#*@}"
    local SERVER_USER="${SERVER%@*}"
    local SERVER_JUMP="$SERVER"
    if [[ "$SSH_PORT" -ne 22 ]]; then
        SERVER_JUMP="${SERVER}:${SSH_PORT}"
    fi

    echo ""
    if [[ "$DEPLOY_REVERSE" == true ]]; then
        echo -e "  ${YELLOW}Access this machine from other devices:${NC}"
        echo -e "    ssh -J ${SERVER_JUMP} ${LOCAL_USER}@localhost -p ${TUNNEL_PORT}"
        echo -e "    ssh tunnel-proxy${NC}"
        echo ""
    fi
    if [[ "$DEPLOY_SOCKS5" == true ]]; then
        echo -e "  ${YELLOW}Test internet access via SOCKS5 proxy:${NC}"
        echo -e "    curl --socks5-hostname 127.0.0.1:${SOCKS5_PORT} https://www.google.com${NC}"
        echo ""
        echo -e "  ${YELLOW}Transparent proxy (sshuttle):${NC}"
        echo -e "    sudo systemctl enable --now tunnel-sshuttle.service${NC}"
        echo ""
    fi
    echo -e "  ${YELLOW}Manage services:${NC}"
    [[ "$DEPLOY_REVERSE" == true ]] && echo -e "    sudo systemctl status tunnel-reverse${NC}"
    [[ "$DEPLOY_SOCKS5" == true ]] && echo -e "    sudo systemctl status tunnel-socks5${NC}"
    [[ "$DEPLOY_SOCKS5" == true ]] && echo -e "    sudo systemctl status tunnel-sshuttle${NC}"
    echo ""
    echo -e "  ${YELLOW}Config file (edit & restart service to apply):${NC}"
    echo -e "    ${CONFIG_FILE}${NC}"
    echo ""
    echo -e "  ${YELLOW}Log file:${NC}"
    echo -e "    ${LOG_FILE}${NC}"
    echo ""
}

# ============================================
# Main
# ============================================
main() {
    # Initialize log
    > "$LOG_FILE" 2>/dev/null || true
    log "=== ssh-tunnel-proxy installer started ==="
    log "Args: $*"

    echo ""
    echo -e "${BLUE}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║        ssh-tunnel-proxy              ║${NC}"
    echo -e "${BLUE}  ║     One-command SSH tunnel setup     ║${NC}"
    echo -e "${BLUE}  ╚══════════════════════════════════════╝${NC}"
    echo ""

    parse_args "$@"
    preflight_check
    install_deps
    setup_ssh_key
    copy_ssh_key
    test_ssh_connectivity
    remote_setup
    local_setup
    verify_services || true
    print_instructions

    log "=== ssh-tunnel-proxy installer finished ==="
}

main "$@"
