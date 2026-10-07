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
LOCAL_ONLY=false
DEPLOY_REVERSE=true
DEPLOY_SOCKS5=true
BYPASS_LAN=true
BYPASS_SUBNETS="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
# env    -> inject proxy env vars into interactive shells
# global -> no env vars; sshuttle transparently proxies all TCP + DNS
PROXY_MODE=env

LOCAL_USER="$(whoami)"
LOCAL_HOST="$(hostname -s)"
SSH_KEY_TYPE="ed25519"
SSH_KEY_PATH="${HOME}/.ssh/id_${SSH_KEY_TYPE}"

CONFIG_DIR="/etc/ssh-tunnel-proxy"
CONFIG_FILE="${CONFIG_DIR}/tunnel.conf"
GNOME_STATE_FILE="${CONFIG_DIR}/gnome-proxy.state"
LOG_FILE="${TMPDIR:-/tmp}/ssh-tunnel-proxy-install.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"

SSH_OPTS=""

# Markers delimiting the managed block in ~/.bashrc / ~/.zshrc
SHELL_BLOCK_START="# ssh-tunnel-proxy: config"
SHELL_BLOCK_END="# ssh-tunnel-proxy: end"
LEGACY_BLOCK_START="# ssh-tunnel-proxy: auto ALL_PROXY"

# Port for the previous installation (used to clean up stale relay firewall rules)
PREV_TUNNEL_PORT=""

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

# Write a file as root, honouring --dry-run.
# Usage: write_file_sudo <path> <<'EOF' ... EOF
write_file_sudo() {
    local path="$1"
    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} write ${path}"
        cat > /dev/null
        return 0
    fi
    if [[ "$VERBOSE" == true ]]; then
        echo -e "${BLUE}[EXEC]${NC} write ${path}"
    fi
    sudo tee "$path" > /dev/null
    log "[WRITE] ${path}"
}

# ============================================
# Usage / fatal errors
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
  --global                 Route ALL traffic (TCP+DNS) through the tunnel via
                           sshuttle; implies --enable-sshuttle and disables the
                           shell proxy environment variables (PROXY_MODE=global)
  --proxy-mode <mode>      env (default) or global
  --no-bypass-lan          Route LAN traffic through the tunnel too (default: bypass LAN)
  --local-only             Configure this machine only (skip key copy + relay setup)
  --verbose                Show detailed execution output
  --dry-run                Print what would be done without executing
  --help                   Show this help message

Examples:
  curl -sSL https://.../install.sh | bash -s -- --server root@1.2.3.4
  ./install.sh --server root@1.2.3.4 --tunnel-port 8888 --enable-sshuttle
  ./install.sh --server root@1.2.3.4 --ssh-port 2222 --verbose
EOF
}

# Print an error, the usage text and exit non-zero.
die() {
    error "$*"
    echo "" >&2
    usage >&2
    exit 1
}

# Fail cleanly when an option has no value.
# Usage: require_value "$1" "${2:-}"
require_value() {
    local opt="$1"
    local val="${2:-}"
    if [[ -z "$val" ]]; then
        die "${opt} requires a value"
    fi
}

# Validate a TCP port number (1-65535).
validate_port() {
    local name="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        die "${name} must be a number (got: '${value}')"
    fi
    if (( value < 1 || value > 65535 )); then
        die "${name} must be between 1 and 65535 (got: ${value})"
    fi
}

# ============================================
# Parse arguments
# ============================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server)          require_value "$1" "${2:-}"; SERVER="$2"; shift 2 ;;
            --tunnel-port)     require_value "$1" "${2:-}"; TUNNEL_PORT="$2"; shift 2 ;;
            --socks5-port)     require_value "$1" "${2:-}"; SOCKS5_PORT="$2"; shift 2 ;;
            --ssh-port)        require_value "$1" "${2:-}"; SSH_PORT="$2"; shift 2 ;;
            --enable-sshuttle) ENABLE_SSHUTTLE=true; shift ;;
            --global)          ENABLE_SSHUTTLE=true; PROXY_MODE=global; shift ;;
            --proxy-mode)      require_value "$1" "${2:-}"
                               case "$2" in
                                   env|global) PROXY_MODE="$2" ;;
                                   *) die "--proxy-mode must be 'env' or 'global' (got: '$2')" ;;
                               esac
                               [[ "$PROXY_MODE" == "global" ]] && ENABLE_SSHUTTLE=true
                               shift 2 ;;
            --no-bypass-lan)   BYPASS_LAN=false; shift ;;
            --local-only)      LOCAL_ONLY=true; shift ;;
            --only-reverse)    DEPLOY_REVERSE=true; DEPLOY_SOCKS5=false; shift ;;
            --only-socks5)     DEPLOY_REVERSE=false; DEPLOY_SOCKS5=true; shift ;;
            --verbose)         VERBOSE=true; shift ;;
            --dry-run)         DRY_RUN=true; shift ;;
            --help)            usage; exit 0 ;;
            *)                 die "Unknown option: $1" ;;
        esac
    done

    if [[ -z "$SERVER" ]]; then
        die "--server is required"
    fi

    if [[ "$SERVER" != *"@"* ]]; then
        die "SERVER must be in user@host format (e.g. root@1.2.3.4)"
    fi

    # Validate ports (numeric and inside the valid TCP range)
    validate_port "TUNNEL_PORT" "$TUNNEL_PORT"
    validate_port "SOCKS5_PORT" "$SOCKS5_PORT"
    validate_port "SSH_PORT"    "$SSH_PORT"

    if [[ "$SSH_PORT" -ne 22 ]]; then
        SSH_OPTS="-p ${SSH_PORT}"
    fi

    # Validate deployment mode
    if [[ "$DEPLOY_REVERSE" == false && "$DEPLOY_SOCKS5" == false ]]; then
        die "Cannot use --only-reverse and --only-socks5 together"
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
        if ss -tln 2>/dev/null | grep -q ":${SOCKS5_PORT} "; then
            warn "Port ${SOCKS5_PORT} is already in use locally. Use --socks5-port to change it."
        fi
    fi

    # Reverse tunnel forwards to local sshd on port 22 - make sure something is there
    if [[ "$DEPLOY_REVERSE" == true ]]; then
        local local22=false
        if command -v ss &>/dev/null; then
            ss -tln 2>/dev/null | grep -q ":22 " && local22=true
        elif command -v netstat &>/dev/null; then
            netstat -tln 2>/dev/null | grep -q ":22 " && local22=true
        elif command -v sshd &>/dev/null; then
            local22=true
        fi
        if [[ "$local22" == true ]]; then
            info "Local SSH service detected (reverse tunnel target: localhost:22)"
        else
            warn "Nothing is listening on local port 22."
            warn "The reverse tunnel forwards to localhost:22, so remote access will fail"
            warn "until an SSH server (sshd) is installed and running on this machine."
        fi
    fi

    # Remote port check (irrelevant for --local-only)
    local SERVER_HOST="${SERVER#*@}"
    if [[ "$LOCAL_ONLY" != true ]] && command -v nc &>/dev/null; then
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

    # OpenSSH is assumed to be present. sshuttle is only needed when the optional
    # transparent proxy is requested, so do not touch the package manager otherwise.
    if [[ "$ENABLE_SSHUTTLE" != true ]]; then
        info "sshuttle not requested (use --enable-sshuttle to install it)"
        return
    fi

    if command -v sshuttle &>/dev/null; then
        info "sshuttle is already installed"
        return
    fi

    info "Installing: sshuttle"

    if   command -v apt    &>/dev/null; then sudo_run apt update -qq && sudo_run apt install -y -qq sshuttle
    elif command -v dnf    &>/dev/null; then sudo_run dnf install -y -q sshuttle
    elif command -v yum    &>/dev/null; then sudo_run yum install -y -q sshuttle
    elif command -v pacman &>/dev/null; then sudo_run pacman -S --noconfirm sshuttle
    elif command -v zypper &>/dev/null; then sudo_run zypper install -y sshuttle
    else
        warn "Unknown package manager. Install manually: sshuttle"
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

    # $1 = tunnel port, $2 = ssh port, $3 = tunnel port of a previous install (may be empty)
    ssh ${SSH_OPTS} "$SERVER" "sudo bash -s -- ${TUNNEL_PORT} ${SSH_PORT} ${PREV_TUNNEL_PORT}" << 'REMOTESCRIPT'
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
REMOTESCRIPT

    info "Relay server configured successfully"
}

# ============================================
# Local tunnel setup
# ============================================
# ============================================
# Config / shell integration helpers
# ============================================

# Remember the tunnel port of a previous installation so stale relay firewall
# rules can be removed when the port changes. Must run before local_setup()
# rewrites the config file.
load_previous_config() {
    PREV_TUNNEL_PORT=""
    if [[ -f "$CONFIG_FILE" ]]; then
        PREV_TUNNEL_PORT="$(sed -n 's/^TUNNEL_PORT=//p' "$CONFIG_FILE" | head -n 1)"
        if [[ -n "$PREV_TUNNEL_PORT" ]]; then
            info "Previous installation detected (tunnel port: ${PREV_TUNNEL_PORT})"
        fi
    fi
}

# Remove the managed block from a shell rc file.
# The range is only deleted when BOTH markers are present, so a missing or
# renamed end marker can never truncate the rest of the user's file.
remove_shell_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0

    if grep -q "^${SHELL_BLOCK_START}\$" "$file" 2>/dev/null && \
       grep -q "^${SHELL_BLOCK_END}\$" "$file" 2>/dev/null; then
        sed -i "/^${SHELL_BLOCK_START}\$/,/^${SHELL_BLOCK_END}\$/d" "$file"
        return 0
    fi

    if grep -q "^${SHELL_BLOCK_START}\$" "$file" 2>/dev/null; then
        warn "$(basename "$file"): found '${SHELL_BLOCK_START}' without the matching end marker."
        warn "  Leaving it untouched to avoid truncating your shell configuration."
    fi
    if grep -q "^${LEGACY_BLOCK_START}\$" "$file" 2>/dev/null; then
        warn "$(basename "$file"): legacy ssh-tunnel-proxy block without an end marker."
        warn "  Please remove it manually (search for 'ssh-tunnel-proxy')."
    fi
    return 0
}

# Install/refresh the `Host tunnel-proxy` entry in ~/.ssh/config.
# Replaces an existing generated entry so port/server changes take effect.
update_ssh_config() {
    local ssh_config="${HOME}/.ssh/config"
    local server_jump="$SERVER"
    if [[ "$SSH_PORT" -ne 22 ]]; then
        server_jump="${SERVER}:${SSH_PORT}"
    fi

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} would update ${ssh_config} (Host tunnel-proxy)"
        return 0
    fi

    run mkdir -p "${HOME}/.ssh"
    [[ -f "$ssh_config" ]] || : > "$ssh_config"

    # Drop a previously generated entry: the marker line, the matching Host
    # line, its indented options and one trailing blank line.
    if grep -q "^# ssh-tunnel-proxy:" "$ssh_config" 2>/dev/null; then
        local tmp
        tmp="$(mktemp)"
        awk '
            /^# ssh-tunnel-proxy:/ { inblock = 1; next }
            inblock && /^Host tunnel-proxy[[:space:]]*$/ { next }
            inblock && /^[[:space:]]/ { next }
            inblock && /^[[:space:]]*$/ { inblock = 0; next }
            { print }
        ' "$ssh_config" > "$tmp"
        mv "$tmp" "$ssh_config"
    fi

    {
        echo ""
        echo "# ssh-tunnel-proxy: ${LOCAL_HOST}"
        echo "Host tunnel-proxy"
        echo "    HostName localhost"
        echo "    Port ${TUNNEL_PORT}"
        echo "    ProxyJump ${server_jump}"
        echo "    User ${LOCAL_USER}"
        echo "    ServerAliveInterval 30"
        echo "    ServerAliveCountMax 3"
    } >> "$ssh_config"

    run chmod 600 "$ssh_config"
    info "Updated SSH config entry: Host tunnel-proxy (port ${TUNNEL_PORT})"
}

# Deploy /usr/local/bin/tunnel-proxy. Prefers the canonical script from the
# checkout and refreshes it on re-install; falls back to a bundled copy for
# `curl | bash` installs where scripts/ is not available.
install_tunnel_proxy_script() {
    local tunnel_script="/usr/local/bin/tunnel-proxy"
    local canonical_script="${SCRIPT_DIR}/scripts/tunnel-proxy.sh"

    if [[ -f "$canonical_script" ]]; then
        if [[ -f "$tunnel_script" ]] && cmp -s "$canonical_script" "$tunnel_script"; then
            info "tunnel-proxy control script is up to date"
        else
            sudo_run cp "$canonical_script" "$tunnel_script"
            info "Installed tunnel-proxy from scripts/tunnel-proxy.sh (canonical source)"
        fi
    elif [[ ! -f "$tunnel_script" ]]; then
        warn "scripts/tunnel-proxy.sh not available; writing bundled fallback copy"
        write_file_sudo "$tunnel_script" << 'TUNNELSCRIPT'
#!/usr/bin/env bash
#
# tunnel-proxy — Unified control for ssh-tunnel-proxy
#
# Usage: tunnel-proxy {start|stop|status|restart|check|doctor|env} [options]
#
#   start|stop|restart   control the systemd services + desktop proxy
#   status [--json]      show service/port state
#   check                validate /etc/ssh-tunnel-proxy/tunnel.conf
#   doctor [--json] [--quiet] [--deep] [--relay]
#                        end-to-end health check (exit 1 on failure)
#   env                  print shell exports for `eval "$(tunnel-proxy env)"`
#
# NOTE: install.sh embeds a byte-identical copy of this script as a fallback for
# `curl | bash` installs. If you change this file you must re-embed it, and
# tests/smoke.sh will fail if the two ever diverge.
#
set -euo pipefail

CONFIG_DIR="${SSH_TUNNEL_PROXY_CONF_DIR:-/etc/ssh-tunnel-proxy}"
CONFIG_FILE="$CONFIG_DIR/tunnel.conf"
GNOME_STATE_FILE="$CONFIG_DIR/gnome-proxy.state"
SYSTEMD_DIR="${SSH_TUNNEL_PROXY_SYSTEMD_DIR:-/etc/systemd/system}"

ORIGINAL_USER="${SUDO_USER:-$USER}"
ORIGINAL_UID="$(id -u "$ORIGINAL_USER" 2>/dev/null || echo 1000)"
DBUS_ADDR="unix:path=/run/user/${ORIGINAL_UID}/bus"

# ---- defaults, overridden by tunnel.conf ----------------------------------
TUNNEL_PORT=2222
SOCKS5_PORT=1080
SSH_PORT=22
SERVER=""
BYPASS_LAN=true
BYPASS_SUBNETS="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
DEPLOY_REVERSE=true
DEPLOY_SOCKS5=true
# env    -> proxy environment variables are injected into interactive shells
# global -> no env vars; sshuttle (transparent TCP + DNS proxy) carries traffic
PROXY_MODE=env

CFG_ERRORS=()

help_text() {
    cat <<'EOF'
tunnel-proxy - control the ssh-tunnel-proxy tunnels

Common:
  tunnel-proxy on [--global]   start tunnels (--global switches to all-traffic mode)
  tunnel-proxy off             stop tunnels and clear proxy variables
  tunnel-proxy status          show the current state (add --json for scripts)
  tunnel-proxy global | local  switch between all-traffic and proxy-variable mode

Advanced:
  tunnel-proxy doctor [--deep] [--relay]   end-to-end health check
  tunnel-proxy check                       validate /etc/ssh-tunnel-proxy/tunnel.conf
  tunnel-proxy env                         print exports for: eval "$(tunnel-proxy env)"
  tunnel-proxy rescue                      emergency: stop + remove leftover redirect rules
  tunnel-proxy start | stop | restart      aliases of on / off / restart
  tunnel-proxy mode [env|global]           alias of status / global / local
  tunnel-proxy help                        this text
EOF
}

usage() {
    help_text >&2
    exit 1
}

# Show a short summary and the few commands a human needs.
summary_cmd() {
    local listening="not-listening"
    port_listening "$SOCKS5_PORT" && listening="listening"
    printf '  %-16s %s\n' "Proxy mode" "$PROXY_MODE"
    printf '  %-16s %s\n' "Reverse tunnel" "$(unit_state tunnel-reverse.service tunnel-reverse.service)"
    printf '  %-16s %s\n' "SOCKS5" "$(unit_state tunnel-socks5.service tunnel-socks5.service) (port ${SOCKS5_PORT} ${listening})"
    if have_sshuttle; then
        printf '  %-16s %s\n' "Transparent" "$(unit_state tunnel-sshuttle.service tunnel-sshuttle.service)"
    fi
    if [[ ${#CFG_ERRORS[@]} -gt 0 ]]; then
        print_cfg_errors
    fi
    echo ""
    echo "  on / off / status / global / local / doctor / help"
}

# State of a unit: not-installed | active | inactive
unit_state() {
    [[ -f "${SYSTEMD_DIR}/$1" ]] || { echo "not-installed"; return 0; }
    if service_active "$2"; then echo "active"; else echo "inactive"; fi
}

# `tunnel-proxy on [--global]`
on_cmd() {
    local switch_mode=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --global) switch_mode="global"; shift ;;
            --env|--local) switch_mode="env"; shift ;;
            *) echo "Usage: tunnel-proxy on [--global]" >&2; return 1 ;;
        esac
    done
    if [[ -n "$switch_mode" ]]; then
        mode_cmd "$switch_mode" || return 1
        load_config
    fi
    start_services
}

# ---- configuration ---------------------------------------------------------
# Parse tunnel.conf with an explicit allow-list and validation instead of
# sourcing it: bad values are reported instead of silently breaking the tunnel.
load_config() {
    CFG_ERRORS=()
    [[ -r "$CONFIG_FILE" ]] || return 0

    local line key val
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue
        if [[ "$line" != *=* ]]; then
            CFG_ERRORS+=("unparsable line: ${line}")
            continue
        fi
        key="${line%%=*}"
        val="${line#*=}"
        key="${key//[[:space:]]/}"
        val="${val%\"}"; val="${val#\"}"

        case "$key" in
            TUNNEL_PORT|SOCKS5_PORT|SSH_PORT)
                if [[ ! "$val" =~ ^[0-9]+$ ]] || (( 10#$val < 1 || 10#$val > 65535 )); then
                    CFG_ERRORS+=("${key}=${val} is not a valid port (1-65535)")
                else
                    printf -v "$key" '%s' "$val"
                fi
                ;;
            SERVER)
                if [[ "$val" != *"@"* ]]; then
                    CFG_ERRORS+=("SERVER=${val} must be in user@host format")
                else
                    printf -v "$key" '%s' "$val"
                fi
                ;;
            BYPASS_LAN|DEPLOY_REVERSE|DEPLOY_SOCKS5)
                if [[ "$val" != "true" && "$val" != "false" ]]; then
                    CFG_ERRORS+=("${key}=${val} must be true or false")
                else
                    printf -v "$key" '%s' "$val"
                fi
                ;;
            BYPASS_SUBNETS)
                # Only characters that can appear in a subnet list; this value is
                # also used to build NO_PROXY and (on the shell side) eval'd.
                if [[ ! "$val" =~ ^[0-9a-zA-Z.,:/_-]+$ ]]; then
                    CFG_ERRORS+=("BYPASS_SUBNETS=${val} contains unexpected characters")
                else
                    printf -v "$key" '%s' "$val"
                fi
                ;;
            PROXY_MODE)
                if [[ "$val" != "env" && "$val" != "global" ]]; then
                    CFG_ERRORS+=("PROXY_MODE=${val} must be env or global")
                else
                    printf -v "$key" '%s' "$val"
                fi
                ;;
            LOCAL_USER|LOCAL_HOST|SSH_KEY_TYPE)
                printf -v "$key" '%s' "$val"
                ;;
            *)
                : # ignore unknown keys for forward compatibility
                ;;
        esac
    done < "$CONFIG_FILE"
    return 0
}

print_cfg_errors() {
    echo "[tunnel-proxy] invalid configuration: ${CONFIG_FILE}" >&2
    local e
    for e in "${CFG_ERRORS[@]}"; do
        echo "  - ${e}" >&2
    done
    echo "  fix the values and run: sudo systemctl restart tunnel-reverse tunnel-socks5" >&2
}

# ---- service / port helpers ------------------------------------------------
have_reverse()  { [[ -f "${SYSTEMD_DIR}/tunnel-reverse.service" ]]; }
have_socks5()   { [[ -f "${SYSTEMD_DIR}/tunnel-socks5.service" ]]; }
have_sshuttle() { [[ -f "${SYSTEMD_DIR}/tunnel-sshuttle.service" ]]; }

service_enabled() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

service_active() {
    command -v systemctl >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "$1" 2>/dev/null
}

# sshuttle installs nat chains named sshuttle-<pid>. If they survive while the
# service is gone, every packet is redirected into a dead tunnel.
sshuttle_rules_present() {
    command -v iptables >/dev/null 2>&1 || return 1
    iptables -t nat -L -n 2>/dev/null | grep -q 'sshuttle-'
}

cleanup_sshuttle_rules() {
    local helper="${SSHUTTLE_CLEANUP_BIN:-/usr/local/bin/sshuttle-cleanup}"
    if [[ -x "$helper" ]]; then
        sudo "$helper" 2>/dev/null || true
        return 0
    fi
    # Fallback when the helper is missing (e.g. partial install).
    command -v iptables >/dev/null 2>&1 || return 0
    local c
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
    return 0
}

port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q ":${port} " && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q ":${port} " && return 0
    fi
    return 1
}

# Name of the process listening on a port, or empty when it cannot be read.
port_owner() {
    local port="$1"
    command -v ss >/dev/null 2>&1 || return 0
    ss -tlnp 2>/dev/null | grep ":${port} " \
        | sed -n 's/.*users:((\"\([^"]*\)\".*/\1/p' | head -n 1
}

# Minimal SOCKS5 method negotiation: VER=5 NMETHODS=1 METHOD=no-auth -> 05 00
socks5_handshake() {
    local port="$1" out
    # Minimal SOCKS5 greeting (VER=5, NMETHODS=1, METHOD=no-auth); expect 05 00.
    out="$(timeout 3 bash -c "exec 3<>/dev/tcp/127.0.0.1/${port}; printf '\005\001\000' >&3; head -c 2 <&3 | od -An -tx1 | tr -d ' \n'" 2>/dev/null)" || true
    [[ "$out" == "0500" ]]
}

# ---- GNOME desktop proxy ---------------------------------------------------
gnome_available() {
    command -v gsettings >/dev/null 2>&1 && [[ -n "$ORIGINAL_USER" ]] && [[ -d "/run/user/${ORIGINAL_UID}" ]]
}

gsettings_cmd() {
    sudo -u "$ORIGINAL_USER" DBUS_SESSION_BUS_ADDRESS="$DBUS_ADDR" gsettings "$@" 2>/dev/null
}

save_gnome_state() {
    [[ -f "$GNOME_STATE_FILE" ]] && return 0
    local mode use_same ignore s_host s_port
    mode="$(gsettings_cmd get org.gnome.system.proxy mode || true)"
    use_same="$(gsettings_cmd get org.gnome.system.proxy use-same-proxy || true)"
    ignore="$(gsettings_cmd get org.gnome.system.proxy ignore-hosts || true)"
    s_host="$(gsettings_cmd get org.gnome.system.proxy.socks host || true)"
    s_port="$(gsettings_cmd get org.gnome.system.proxy.socks port || true)"

    sudo mkdir -p "$CONFIG_DIR"
    {
        printf 'GNOME_MODE=%s\n'        "${mode:-'none'}"
        printf 'GNOME_USE_SAME=%s\n'    "${use_same:-true}"
        printf 'GNOME_IGNORE=%s\n'      "${ignore:-@as []}"
        printf 'GNOME_SOCKS_HOST=%s\n'  "${s_host:-''}"
        printf 'GNOME_SOCKS_PORT=%s\n'  "${s_port:-0}"
    } | sudo tee "$GNOME_STATE_FILE" >/dev/null 2>&1 || true
}

enable_gnome_proxy() {
    save_gnome_state

    local hosts="'localhost'"
    local sub
    if [[ "$BYPASS_LAN" == "true" ]]; then
        IFS=',' read -ra _subs <<< "$BYPASS_SUBNETS"
        for sub in "${_subs[@]}"; do
            sub="${sub// /}"
            [[ -n "$sub" ]] && hosts+=", '${sub}'"
        done
    fi
    hosts+=", '*.local'"

    gsettings_cmd set org.gnome.system.proxy use-same-proxy true || true
    gsettings_cmd set org.gnome.system.proxy.socks host '127.0.0.1' || true
    gsettings_cmd set org.gnome.system.proxy.socks port "$SOCKS5_PORT" || true
    gsettings_cmd set org.gnome.system.proxy ignore-hosts "[$hosts]" || true
    gsettings_cmd set org.gnome.system.proxy mode 'manual' || true

    echo "[tunnel-proxy] GNOME system proxy enabled (SOCKS 127.0.0.1:${SOCKS5_PORT})"
}

disable_gnome_proxy() {
    if [[ -f "$GNOME_STATE_FILE" ]]; then
        local v
        v="$(sed -n 's/^GNOME_USE_SAME=//p' "$GNOME_STATE_FILE" | head -n 1)"
        [[ -n "$v" ]] && { gsettings_cmd set org.gnome.system.proxy use-same-proxy "$v" || true; }
        v="$(sed -n 's/^GNOME_SOCKS_HOST=//p' "$GNOME_STATE_FILE" | head -n 1)"
        [[ -n "$v" ]] && { gsettings_cmd set org.gnome.system.proxy.socks host "$v" || true; }
        v="$(sed -n 's/^GNOME_SOCKS_PORT=//p' "$GNOME_STATE_FILE" | head -n 1)"
        [[ -n "$v" ]] && { gsettings_cmd set org.gnome.system.proxy.socks port "$v" || true; }
        v="$(sed -n 's/^GNOME_IGNORE=//p' "$GNOME_STATE_FILE" | head -n 1)"
        [[ -n "$v" ]] && { gsettings_cmd set org.gnome.system.proxy ignore-hosts "$v" || true; }
        v="$(sed -n 's/^GNOME_MODE=//p' "$GNOME_STATE_FILE" | head -n 1)"
        [[ -n "$v" ]] && { gsettings_cmd set org.gnome.system.proxy mode "$v" || true; }

        sudo rm -f "$GNOME_STATE_FILE"
        echo "[tunnel-proxy] GNOME system proxy restored to previous settings"
    else
        gsettings_cmd set org.gnome.system.proxy mode 'none' || true
        gsettings_cmd set org.gnome.system.proxy ignore-hosts "[]" || true
        echo "[tunnel-proxy] GNOME system proxy disabled"
    fi
}

# ---- commands --------------------------------------------------------------

start_services() {
    if [[ ${#CFG_ERRORS[@]} -gt 0 ]]; then
        print_cfg_errors
        return 1
    fi

    echo "[tunnel-proxy] Starting services..."
    local rc=0

    if have_reverse && [[ "$DEPLOY_REVERSE" == "true" ]]; then
        if sudo systemctl start tunnel-reverse.service; then
            echo "[tunnel-proxy] Started: tunnel-reverse.service"
        else
            echo "[tunnel-proxy] WARNING: tunnel-reverse.service failed to start" >&2
            rc=1
        fi
    fi

    if have_socks5 && [[ "$DEPLOY_SOCKS5" == "true" ]]; then
        if sudo systemctl start tunnel-socks5.service; then
            echo "[tunnel-proxy] Started: tunnel-socks5.service"
        else
            echo "[tunnel-proxy] WARNING: tunnel-socks5.service failed to start" >&2
            rc=1
        fi
    fi

    # sshuttle is the transparent proxy used by PROXY_MODE=global; it is started
    # whenever the unit exists and was enabled at install time.
    local sshuttle_started=false
    # "on" means everything comes up: start sshuttle when it is enabled for boot
    # OR whenever global mode needs it, regardless of the enable state.
    if have_sshuttle && { service_enabled tunnel-sshuttle.service || [[ "$PROXY_MODE" == "global" ]]; }; then
        if sudo systemctl start tunnel-sshuttle.service; then
            sshuttle_started=true
            echo "[tunnel-proxy] Started: tunnel-sshuttle.service (transparent proxy)"
        else
            echo "[tunnel-proxy] WARNING: tunnel-sshuttle.service failed to start" >&2
            rc=1
        fi
    fi

    if [[ "$rc" -ne 0 ]]; then
        echo "[tunnel-proxy] One or more services failed; system proxy was NOT enabled." >&2
        echo "[tunnel-proxy] Inspect the logs: sudo journalctl -u tunnel-socks5 -n 50" >&2
        return 1
    fi

    if have_socks5 && [[ "$DEPLOY_SOCKS5" == "true" ]] && gnome_available && [[ "$PROXY_MODE" != "global" ]]; then
        enable_gnome_proxy
    fi

    echo "[tunnel-proxy] Services started"
    if [[ "$PROXY_MODE" == "global" ]]; then
        if [[ "$sshuttle_started" == true ]]; then
            echo "[tunnel-proxy] Global mode: all TCP + DNS traffic is routed through the tunnel"
            echo "[tunnel-proxy] (no shell environment variables are needed)"
        else
            echo "[tunnel-proxy] WARNING: PROXY_MODE=global but tunnel-sshuttle.service is not enabled" >&2
            echo "[tunnel-proxy]   enable it with: sudo systemctl enable --now tunnel-sshuttle.service" >&2
            return 1
        fi
    else
        echo "[tunnel-proxy] To update this terminal, run: eval \"\$(tunnel-proxy env)\""
    fi
    if [[ "$BYPASS_LAN" == "true" ]]; then
        echo "[tunnel-proxy] LAN bypass: ${BYPASS_SUBNETS}"
    fi
}

stop_services() {
    echo "[tunnel-proxy] Stopping services..."

    if have_reverse; then
        sudo systemctl stop tunnel-reverse.service 2>/dev/null || true
    fi
    if have_socks5; then
        sudo systemctl stop tunnel-socks5.service 2>/dev/null || true
    fi
    if have_sshuttle; then
        sudo systemctl stop tunnel-sshuttle.service 2>/dev/null || true
        # Defence in depth: ExecStopPost normally does this, but a hard crash can
        # leave the redirect rules behind - and then everything is blackholed.
        if sshuttle_rules_present; then
            cleanup_sshuttle_rules
            if sshuttle_rules_present; then
                echo "[tunnel-proxy] WARNING: sshuttle iptables rules could not be removed" >&2
                echo "[tunnel-proxy]   run manually: sudo /usr/local/bin/sshuttle-cleanup" >&2
            else
                echo "[tunnel-proxy] Removed leftover sshuttle iptables rules"
            fi
        fi
    fi

    if gnome_available; then
        disable_gnome_proxy
    fi

    echo "[tunnel-proxy] Services stopped"
    echo "[tunnel-proxy] To clear proxy env vars in this terminal, run: unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy"
}

# Emergency recovery: stop everything and make absolutely sure no leftover
# redirection rules keep the machine's traffic captive.
rescue_network() {
    echo "[tunnel-proxy] Emergency rescue: stopping tunnels and removing redirect rules..."

    local rc=0
    if have_reverse; then
        sudo systemctl stop tunnel-reverse.service 2>/dev/null || true
    fi
    if have_socks5; then
        sudo systemctl stop tunnel-socks5.service 2>/dev/null || true
    fi
    if have_sshuttle; then
        sudo systemctl stop tunnel-sshuttle.service 2>/dev/null || true
    fi

    cleanup_sshuttle_rules
    if sshuttle_rules_present; then
        rc=1
        echo "[tunnel-proxy] WARNING: sshuttle rules are still present" >&2
        echo "[tunnel-proxy]   inspect with: sudo iptables -t nat -L -n | grep sshuttle" >&2
    else
        echo "[tunnel-proxy] No sshuttle redirect rules remain - direct networking restored"
    fi

    echo "[tunnel-proxy] This terminal: unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy"
    echo "[tunnel-proxy] Other terminals: reopen them (proxy variables are per-shell)"
    echo "[tunnel-proxy] Restart later with: sudo tunnel-proxy start"
    return "$rc"
}

status_services() {
    local json=false
    [[ "${1:-}" == "--json" ]] && json=true

    local reverse_state socks_state sshuttle_state
    reverse_state="$(unit_state tunnel-reverse.service tunnel-reverse.service)"
    socks_state="$(unit_state tunnel-socks5.service tunnel-socks5.service)"
    sshuttle_state="$(unit_state tunnel-sshuttle.service tunnel-sshuttle.service)"

    local listening=false
    port_listening "$SOCKS5_PORT" && listening=true

    if [[ "$json" == true ]]; then
        printf '{"socks5Port":%s,"tunnelPort":%s,"server":"%s","proxyMode":"%s","listening":%s,' \
            "${SOCKS5_PORT:-0}" "${TUNNEL_PORT:-0}" "${SERVER//\"/}" "$PROXY_MODE" "$listening"
        printf '"services":{"tunnel-reverse":"%s","tunnel-socks5":"%s","tunnel-sshuttle":"%s"},' \
            "$reverse_state" "$socks_state" "$sshuttle_state"
        printf '"configErrors":%d}\n' "${#CFG_ERRORS[@]}"
        return 0
    fi

    echo "=== Reverse Tunnel ==="
    if have_reverse; then
        systemctl status tunnel-reverse.service 2>/dev/null || echo "  (${reverse_state})"
    else
        echo "  (not installed)"
    fi
    echo ""
    echo "=== SOCKS5 Proxy ==="
    if have_socks5; then
        systemctl status tunnel-socks5.service 2>/dev/null || echo "  (${socks_state})"
    else
        echo "  (not installed)"
    fi
    if have_sshuttle; then
        echo ""
        echo "=== Transparent Proxy (sshuttle) ==="
        systemctl status tunnel-sshuttle.service 2>/dev/null || echo "  (${sshuttle_state})"
    fi
    echo ""
    echo "=== Configuration ==="
    echo "  Proxy mode  : ${PROXY_MODE}"
    echo "  SOCKS5 port : ${SOCKS5_PORT} ($([[ "$listening" == true ]] && echo listening || echo not-listening))"
    echo "  Tunnel port : ${TUNNEL_PORT}"
    echo "  Relay server: ${SERVER:-<unset>}"
    if [[ "$BYPASS_LAN" == "true" ]]; then
        echo "  LAN bypass  : ${BYPASS_SUBNETS}"
    fi
    if [[ "$PROXY_MODE" == "global" ]]; then
        echo "  Traffic     : all TCP + DNS via sshuttle (no shell env vars needed)"
    fi
    if [[ ${#CFG_ERRORS[@]} -gt 0 ]]; then
        print_cfg_errors
    fi
}

check_config_cmd() {
    if [[ ${#CFG_ERRORS[@]} -gt 0 ]]; then
        print_cfg_errors
        return 1
    fi
    echo "[tunnel-proxy] configuration OK (${CONFIG_FILE})"
    return 0
}

# End-to-end health check. Exit 0 when nothing failed.
doctor() {
    local json=false quiet=false deep=false relay=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)  json=true; shift ;;
            --quiet) quiet=true; shift ;;
            --deep)  deep=true; shift ;;
            --relay) relay=true; shift ;;
            *) echo "[tunnel-proxy] unknown doctor option: $1" >&2; return 2 ;;
        esac
    done

    local -a names=() statuses=() details=()
    add_result() {
        names+=("$1")
        statuses+=("$2")
        details+=("${3//$'\n'/ }")
    }

    # 1. configuration
    if [[ ${#CFG_ERRORS[@]} -gt 0 ]]; then
        add_result config fail "${CFG_ERRORS[*]}"
    else
        add_result config ok "mode=${PROXY_MODE} socks5=${SOCKS5_PORT} tunnel=${TUNNEL_PORT} relay=${SERVER:-unset}"
    fi

    # 2. transparent proxy (sshuttle) - the only path to the internet in global mode
    if have_sshuttle; then
        if service_active tunnel-sshuttle.service; then
            add_result sshuttle ok "tunnel-sshuttle.service is active"
            if command -v iptables >/dev/null 2>&1; then
                if sshuttle_rules_present; then
                    add_result sshuttle_rules ok "iptables nat rules present"
                else
                    add_result sshuttle_rules fail "sshuttle is active but has no iptables rules"
                fi
            fi
        elif sshuttle_rules_present; then
            # Worst case: redirection is still installed but nothing carries it.
            add_result sshuttle fail "tunnel-sshuttle.service is not active"
            add_result sshuttle_rules fail "stale sshuttle iptables rules are still redirecting traffic (run: sudo tunnel-proxy rescue)"
        elif [[ "$PROXY_MODE" == "global" ]]; then
            add_result sshuttle fail "PROXY_MODE=global but tunnel-sshuttle.service is not active"
        else
            add_result sshuttle warn "tunnel-sshuttle.service is not active (not needed in env mode)"
        fi
    elif [[ "$PROXY_MODE" == "global" ]]; then
        add_result sshuttle fail "PROXY_MODE=global but tunnel-sshuttle.service is not installed"
    fi

    # 2. unit files + 3. service state
    if [[ "$DEPLOY_REVERSE" == "true" ]]; then
        if have_reverse; then
            add_result unit_reverse ok "tunnel-reverse.service present"
            if service_active tunnel-reverse.service; then
                add_result service_reverse ok "tunnel-reverse.service is active"
            else
                add_result service_reverse fail "tunnel-reverse.service is not active"
            fi
        else
            add_result unit_reverse fail "tunnel-reverse.service is missing"
        fi
    fi

    if [[ "$DEPLOY_SOCKS5" == "true" ]]; then
        if have_socks5; then
            add_result unit_socks5 ok "tunnel-socks5.service present"
            if service_active tunnel-socks5.service; then
                add_result service_socks5 ok "tunnel-socks5.service is active"
            else
                add_result service_socks5 fail "tunnel-socks5.service is not active"
            fi
        else
            add_result unit_socks5 fail "tunnel-socks5.service is missing"
        fi

        # 4. port listening
        if port_listening "$SOCKS5_PORT"; then
            add_result socks5_port ok "port ${SOCKS5_PORT} is listening"
            # 5. who owns the port
            local owner
            owner="$(port_owner "$SOCKS5_PORT")"
            if [[ -z "$owner" ]]; then
                add_result socks5_owner warn "cannot read the listener (run as root for details)"
            elif [[ "$owner" == ssh* ]]; then
                add_result socks5_owner ok "listener is '${owner}'"
            else
                add_result socks5_owner fail "port ${SOCKS5_PORT} is owned by '${owner}', not ssh"
            fi
            # 6. protocol handshake
            if socks5_handshake "$SOCKS5_PORT"; then
                add_result socks5_handshake ok "SOCKS5 method negotiation succeeded"
            else
                add_result socks5_handshake fail "no SOCKS5 response on 127.0.0.1:${SOCKS5_PORT}"
            fi
        else
            add_result socks5_port fail "nothing is listening on port ${SOCKS5_PORT}"
        fi

        # 7. real traffic through the proxy
        if [[ "$deep" == true ]]; then
            if command -v curl >/dev/null 2>&1; then
                if [[ "$PROXY_MODE" == "global" ]]; then
                    # No proxy variables: this only succeeds if sshuttle is
                    # transparently carrying the traffic for every process.
                    if timeout 12 env -u ALL_PROXY -u all_proxy -u HTTP_PROXY -u http_proxy \
                            -u HTTPS_PROXY -u https_proxy -u NO_PROXY -u no_proxy \
                            curl -sS -o /dev/null https://www.gstatic.com/generate_204 2>/dev/null; then
                        add_result egress ok "transparent HTTPS request succeeded (global mode)"
                    else
                        add_result egress fail "cannot reach the internet without a proxy (sshuttle not working?)"
                    fi
                elif timeout 12 curl -sS -o /dev/null \
                        --socks5-hostname "127.0.0.1:${SOCKS5_PORT}" \
                        https://www.gstatic.com/generate_204 2>/dev/null; then
                    add_result egress ok "HTTPS request through the tunnel succeeded"
                else
                    add_result egress fail "cannot reach the internet through the tunnel"
                fi
            else
                add_result egress warn "curl not available, skipped"
            fi
        fi

        # desktop proxy consistency (env mode only; global mode is transparent)
        if [[ "$PROXY_MODE" != "global" ]] && gnome_available; then
            local mode socks_port
            mode="$(gsettings_cmd get org.gnome.system.proxy mode || true)"
            socks_port="$(gsettings_cmd get org.gnome.system.proxy.socks port || true)"
            if [[ "$mode" == "'manual'" && "$socks_port" == "$SOCKS5_PORT" ]]; then
                add_result desktop_proxy ok "GNOME proxy points at 127.0.0.1:${SOCKS5_PORT}"
            else
                add_result desktop_proxy warn "GNOME proxy is ${mode:-unknown}/${socks_port:-unknown}; run 'tunnel-proxy start'"
            fi
        fi
    fi

    # 8. reverse tunnel reachable from the relay
    if [[ "$relay" == true && "$DEPLOY_REVERSE" == "true" ]]; then
        if [[ -z "$SERVER" ]]; then
            add_result relay warn "no SERVER configured"
        else
            local ssh_arg=()
            [[ "$SSH_PORT" -ne 22 ]] && ssh_arg=(-p "$SSH_PORT")
            if timeout 20 ssh -o BatchMode=yes -o ConnectTimeout=8 "${ssh_arg[@]+"${ssh_arg[@]}"}" "$SERVER" \
                    "ss -tln 2>/dev/null | grep -q ':${TUNNEL_PORT} '" 2>/dev/null; then
                add_result relay ok "relay is listening on port ${TUNNEL_PORT}"
            else
                add_result relay fail "relay is NOT listening on port ${TUNNEL_PORT} (GatewayPorts/firewall?)"
            fi
        fi
    fi

    # ---- output ----
    local fails=0 warns=0 i d
    for i in "${!names[@]}"; do
        [[ "${statuses[$i]}" == "fail" ]] && fails=$((fails + 1))
        [[ "${statuses[$i]}" == "warn" ]] && warns=$((warns + 1))
    done

    if [[ "$json" == true ]]; then
        if [[ "$fails" -eq 0 ]]; then printf '{"ok":true,"checks":['; else printf '{"ok":false,"checks":['; fi
        for i in "${!names[@]}"; do
            [[ "$i" -gt 0 ]] && printf ','
            d="${details[$i]//\"/\'}"
            printf '{"name":"%s","status":"%s","detail":"%s"}' "${names[$i]}" "${statuses[$i]}" "$d"
        done
        printf '],"failures":%d,"warnings":%d}\n' "$fails" "$warns"
    else
        if [[ "$quiet" == false ]]; then
            for i in "${!names[@]}"; do
                printf '  [%-4s] %-18s %s\n' "${statuses[$i]}" "${names[$i]}" "${details[$i]}"
            done
        fi
        for i in "${!names[@]}"; do
            if [[ "${statuses[$i]}" == "fail" ]]; then
                printf '[tunnel-proxy] FAIL %s: %s\n' "${names[$i]}" "${details[$i]}" >&2
            fi
        done
        if [[ "$quiet" == false ]]; then
            printf '[tunnel-proxy] doctor: %d failure(s), %d warning(s)\n' "$fails" "$warns"
        fi
    fi

    [[ "$fails" -eq 0 ]]
}

env_cmd() {
    if [[ ${#CFG_ERRORS[@]} -gt 0 ]]; then
        print_cfg_errors >&2
        return 1
    fi
    # In global mode traffic is carried transparently by sshuttle, so exporting
    # SOCKS variables would break tools that do not speak SOCKS (requests,
    # huggingface_hub, ...). Emit unsets so `eval` also clears stale values.
    if [[ "$PROXY_MODE" == "global" ]]; then
        printf 'unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy 2>/dev/null || true\n'
        return 0
    fi

    # No SOCKS5 service deployed (--only-reverse): there is nothing to point at.
    if [[ "$DEPLOY_SOCKS5" != "true" ]]; then
        echo "[tunnel-proxy] SOCKS5 is not deployed (--only-reverse); clearing proxy variables" >&2
        printf 'unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy 2>/dev/null || true\n'
        return 0
    fi

    local no_proxy="localhost,*.local"
    if [[ "$BYPASS_LAN" == "true" ]]; then
        no_proxy="${no_proxy},${BYPASS_SUBNETS}"
    fi
    printf 'export ALL_PROXY="socks5h://127.0.0.1:%s"\n' "$SOCKS5_PORT"
    printf 'export HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY" http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY"\n'
    printf 'export NO_PROXY="%s" no_proxy="%s"\n' "$no_proxy" "$no_proxy"
    return 0
}

# Switch between env mode (SOCKS proxy variables) and global mode (sshuttle
# transparent proxy) without re-running the installer.
mode_cmd() {
    local want="${1:-}"

    if [[ -z "$want" ]]; then
        echo "[tunnel-proxy] proxy mode: ${PROXY_MODE}"
        return 0
    fi

    case "$want" in
        env|global) ;;
        *) echo "Usage: tunnel-proxy mode [env|global]" >&2; return 1 ;;
    esac

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "[tunnel-proxy] ERROR: ${CONFIG_FILE} not found" >&2
        return 1
    fi

    if [[ "$want" == "global" ]]; then
        if ! have_sshuttle; then
            echo "[tunnel-proxy] ERROR: tunnel-sshuttle.service is not installed." >&2
            echo "[tunnel-proxy]   re-run the installer with --global:" >&2
            echo "[tunnel-proxy]     bash install.sh --server <user@relay> --global" >&2
            return 1
        fi
        if ! command -v sshuttle >/dev/null 2>&1; then
            echo "[tunnel-proxy] WARNING: 'sshuttle' is not in PATH; the service will fail to start" >&2
            echo "[tunnel-proxy]   install it first (e.g. sudo apt install sshuttle)" >&2
        fi
    fi

    if grep -q '^PROXY_MODE=' "$CONFIG_FILE" 2>/dev/null; then
        sudo sed -i "s/^PROXY_MODE=.*/PROXY_MODE=${want}/" "$CONFIG_FILE"
    else
        printf 'PROXY_MODE=%s\n' "$want" | sudo tee -a "$CONFIG_FILE" >/dev/null
    fi
    PROXY_MODE="$want"
    echo "[tunnel-proxy] PROXY_MODE=${want} written to ${CONFIG_FILE}"

    if [[ "$want" == "global" ]]; then
        if ! sudo systemctl enable --now tunnel-sshuttle.service; then
            echo "[tunnel-proxy] ERROR: could not start tunnel-sshuttle.service" >&2
            echo "[tunnel-proxy]   check: sudo journalctl -u tunnel-sshuttle -n 50" >&2
            return 1
        fi
        echo "[tunnel-proxy] Global mode enabled: all TCP+DNS now goes through the tunnel"
        echo "[tunnel-proxy] This terminal: eval \"\$(tunnel-proxy env)\"   # clears proxy variables"
    else
        sudo systemctl disable --now tunnel-sshuttle.service 2>/dev/null || true
        echo "[tunnel-proxy] Env mode enabled: transparent proxy stopped"
        echo "[tunnel-proxy] New terminals get SOCKS proxy variables; this one: eval \"\$(tunnel-proxy env)\""
    fi
    echo "[tunnel-proxy] Verify with: sudo tunnel-proxy doctor --deep"
    return 0
}

# ---- entry point -----------------------------------------------------------
# Allow the file to be sourced by tests without executing a command.

run_command() {
    load_config

    case "${1:-}" in
        "")            summary_cmd ;;
        help|--help|-h) help_text ;;
        on|start)      shift; on_cmd "$@" ;;
        off|stop)      stop_services ;;
        restart)       stop_services; sleep 1; start_services ;;
        status)        shift; status_services "${1:-}" ;;
        check)         check_config_cmd ;;
        doctor)        shift; doctor "$@" ;;
        env)           env_cmd ;;
        global)        mode_cmd global ;;
        local)         mode_cmd env ;;
        mode)          shift; mode_cmd "${1:-}" ;;
        rescue)        rescue_network ;;
        *)             usage ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_command "$@"
fi
TUNNELSCRIPT
        info "Deployed: ${tunnel_script} (standalone install)"
    else
        info "Keeping existing ${tunnel_script} (canonical source not available)"
    fi

    sudo_run chmod +x "$tunnel_script"
}

# Add the tunnel-proxy shell function and the proxy environment handling to a
# shell rc file. The block reads /etc/ssh-tunnel-proxy/tunnel.conf at runtime,
# so changing the SOCKS5 port never leaves a stale hardcoded port behind.
install_shell_block() {
    local file="$1"
    local name
    name="$(basename "$file")"

    remove_shell_block "$file"

    if [[ "$DRY_RUN" == true ]]; then
        echo -e "${YELLOW}[DRY-RUN]${NC} would install tunnel-proxy integration into ${file}"
        return 0
    fi

    [[ -f "$file" ]] || : > "$file"

    cat >> "$file" << 'SHELLBLOCK'
# ssh-tunnel-proxy: config
# Managed by install.sh - do not edit this block.
_ssh_tunnel_proxy_read_conf() {
    local conf="${SSH_TUNNEL_PROXY_CONF_DIR:-/etc/ssh-tunnel-proxy}/tunnel.conf"
    _STP_PORT=""
    _STP_BYPASS_LAN=""
    _STP_SUBNETS=""
    _STP_MODE=""
    if [ -r "$conf" ]; then
        _STP_PORT=$(sed -n 's/^SOCKS5_PORT=//p' "$conf" | head -n 1)
        _STP_BYPASS_LAN=$(sed -n 's/^BYPASS_LAN=//p' "$conf" | head -n 1)
        _STP_SUBNETS=$(sed -n 's/^BYPASS_SUBNETS=//p' "$conf" | head -n 1 | tr -d '"')
        _STP_MODE=$(sed -n 's/^PROXY_MODE=//p' "$conf" | head -n 1)
    fi
    [ -n "$_STP_PORT" ] || _STP_PORT=1080
    [ -n "$_STP_BYPASS_LAN" ] || _STP_BYPASS_LAN=true
    [ -n "$_STP_SUBNETS" ] || _STP_SUBNETS="127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    [ -n "$_STP_MODE" ] || _STP_MODE=env
}

_ssh_tunnel_proxy_enable() {
    _ssh_tunnel_proxy_read_conf
    # Global mode: sshuttle proxies everything transparently, so exporting SOCKS
    # variables would only break tools that cannot speak SOCKS.
    if [ "$_STP_MODE" = "global" ]; then
        _ssh_tunnel_proxy_disable
        return 0
    fi
    unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy 2>/dev/null || true
    export ALL_PROXY="socks5h://127.0.0.1:${_STP_PORT}"
    export HTTP_PROXY="$ALL_PROXY" HTTPS_PROXY="$ALL_PROXY" http_proxy="$ALL_PROXY" https_proxy="$ALL_PROXY"
    if [ "$_STP_BYPASS_LAN" = "true" ]; then
        export NO_PROXY="localhost,*.local,${_STP_SUBNETS}" no_proxy="localhost,*.local,${_STP_SUBNETS}"
    else
        export NO_PROXY="localhost,*.local" no_proxy="localhost,*.local"
    fi
}

_ssh_tunnel_proxy_disable() {
    unset ALL_PROXY all_proxy HTTP_PROXY http_proxy HTTPS_PROXY https_proxy NO_PROXY no_proxy 2>/dev/null || true
}

_ssh_tunnel_proxy_listening() {
    _ssh_tunnel_proxy_read_conf
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | grep -q ":${_STP_PORT} " && return 0
    fi
    if command -v netstat >/dev/null 2>&1; then
        netstat -tln 2>/dev/null | grep -q ":${_STP_PORT} " && return 0
    fi
    return 1
}

tunnel-proxy() {
    local cmd="${1:-}"
    case "$cmd" in
        on|start|restart)
            sudo /usr/local/bin/tunnel-proxy "$@" || return $?
            _ssh_tunnel_proxy_read_conf
            if [ "$_STP_MODE" = "global" ]; then
                # sshuttle carries everything; environment variables would only
                # break tools that cannot speak SOCKS.
                _ssh_tunnel_proxy_disable
                echo "[tunnel-proxy] Global mode: all TCP+DNS is proxied transparently"
                return 0
            fi
            local _stp_i=0
            while [ "$_stp_i" -lt 10 ] && ! _ssh_tunnel_proxy_listening; do
                sleep 0.5
                _stp_i=$((_stp_i + 1))
            done
            if _ssh_tunnel_proxy_listening; then
                _ssh_tunnel_proxy_enable
                echo "[tunnel-proxy] Proxy environment set for this shell"
            else
                _ssh_tunnel_proxy_disable
                echo "[tunnel-proxy] WARNING: SOCKS5 port is not listening - proxy env vars left unset" >&2
                return 1
            fi
            ;;
        off|stop)
            sudo /usr/local/bin/tunnel-proxy "$@" || return $?
            _ssh_tunnel_proxy_disable
            echo "[tunnel-proxy] Proxy environment cleared for this shell"
            ;;
        ""|env|check|doctor|status|mode|global|local|help|--help|-h)
            # These handle their own privileges: the read-only ones need none,
            # and mode switches call sudo only where it is required.
            /usr/local/bin/tunnel-proxy "$@"
            ;;
        *)
            sudo /usr/local/bin/tunnel-proxy "$@"
            ;;
    esac
}

# Configure this shell on startup only when the tunnel is actually up
if _ssh_tunnel_proxy_listening; then
    _ssh_tunnel_proxy_enable
else
    _ssh_tunnel_proxy_disable
fi
# ssh-tunnel-proxy: end
SHELLBLOCK

    info "Installed tunnel-proxy integration into ${name}"
}

# ---- systemd unit rendering ------------------------------------------------
# Units are produced by functions (instead of inline heredocs) so tests can
# render and validate them without writing to /etc.
# These units intentionally have NO StartLimit: a tunnel must keep reconnecting
# forever after a network/relay outage. `ExecStartPre` surfaces configuration
# errors immediately (journal + `tunnel-proxy check`/`doctor`).

render_unit_reverse() {
    cat << EOF
[Unit]
Description=ssh-tunnel-proxy: reverse tunnel (port ${TUNNEL_PORT})
Documentation=https://github.com/evaworks/ssh-tunnel-proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${LOCAL_USER}
EnvironmentFile=${CONFIG_FILE}
# NOTE: no StartLimit on purpose - these units must keep reconnecting forever
# after a relay/network outage. A config error is reported by `tunnel-proxy
# check`/`doctor` and in the journal instead of being rate-limited away.
ExecStartPre=/usr/local/bin/tunnel-proxy check
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
}

render_unit_socks5() {
    cat << EOF
[Unit]
Description=ssh-tunnel-proxy: SOCKS5 proxy (port ${SOCKS5_PORT})
Documentation=https://github.com/evaworks/ssh-tunnel-proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${LOCAL_USER}
EnvironmentFile=${CONFIG_FILE}
# NOTE: no StartLimit on purpose (see render_unit_reverse).
ExecStartPre=/usr/local/bin/tunnel-proxy check
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
}

# $1 = "--exclude a --exclude b" (already space separated)
render_unit_sshuttle() {
    local exclude_args="$1"
    cat << EOF
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
    ${exclude_args} \\
    0.0.0.0/0 --dns
# Always remove the redirect rules, whichever way the service exits - this is
# what makes unlimited retrying safe (no flapping without cleanup).
ExecStopPost=/usr/local/bin/sshuttle-cleanup
TimeoutStopSec=15
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
}

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
            # sshuttle does not depend on the SOCKS5 service; keep it when it was
            # explicitly requested (e.g. --global --only-reverse).
            if [[ "$ENABLE_SSHUTTLE" == false ]]; then
                sudo_run systemctl stop tunnel-sshuttle.service 2>/dev/null || true
                sudo_run systemctl disable tunnel-sshuttle.service 2>/dev/null || true
                sudo_run rm -f /etc/systemd/system/tunnel-sshuttle.service
                info "Removed: tunnel-socks5.service and tunnel-sshuttle.service (not in current deployment mode)"
            else
                info "Removed: tunnel-socks5.service (sshuttle kept: it was explicitly requested)"
            fi
        fi
        sudo_run systemctl daemon-reload
    fi

    # ---- Config directory ----
    sudo_run mkdir -p "$CONFIG_DIR"

    # ---- Environment file ----
    log "Writing config file: ${CONFIG_FILE}"
    write_file_sudo "$CONFIG_FILE" << EOF
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
BYPASS_LAN=${BYPASS_LAN}
BYPASS_SUBNETS="${BYPASS_SUBNETS}"
DEPLOY_REVERSE=${DEPLOY_REVERSE}
DEPLOY_SOCKS5=${DEPLOY_SOCKS5}
PROXY_MODE=${PROXY_MODE}
EOF
    sudo_run chmod 644 "$CONFIG_FILE"
    info "Config file: ${CONFIG_FILE}"

    # ---- Reverse tunnel service (system level) ----
    if [[ "$DEPLOY_REVERSE" == true ]]; then
        local reverse_svc="/etc/systemd/system/tunnel-reverse.service"
        render_unit_reverse | write_file_sudo "$reverse_svc"
        info "Created: tunnel-reverse.service (port ${TUNNEL_PORT} → localhost:22)"
    fi

    # ---- SOCKS5 proxy service (system level) ----
    if [[ "$DEPLOY_SOCKS5" == true ]]; then
        local socks5_svc="/etc/systemd/system/tunnel-socks5.service"
        render_unit_socks5 | write_file_sudo "$socks5_svc"
        info "Created: tunnel-socks5.service (SOCKS5 on 127.0.0.1:${SOCKS5_PORT})"
    fi

    # ---- sshuttle transparent proxy service (system level) ----
    # Written for SOCKS5 deployments (so it can be enabled later) and whenever
    # sshuttle is requested, including --global with --only-reverse: sshuttle
    # carries its own ssh connection and does not depend on the SOCKS5 service.
    if [[ "$DEPLOY_SOCKS5" == true || "$ENABLE_SSHUTTLE" == true ]]; then
        # Write iptables cleanup helper
        write_file_sudo /usr/local/bin/sshuttle-cleanup << 'CLEANUP'
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
        sudo_run chmod +x /usr/local/bin/sshuttle-cleanup

        local SSHUTTLE_EXCLUDE_ARGS=""
        if [[ "$BYPASS_LAN" == true ]]; then
            IFS=',' read -ra SUBNETS <<< "$BYPASS_SUBNETS"
            for subnet in "${SUBNETS[@]}"; do
                SSHUTTLE_EXCLUDE_ARGS+=" --exclude ${subnet}"
            done
        fi

        local sshuttle_svc="/etc/systemd/system/tunnel-sshuttle.service"
        render_unit_sshuttle "$SSHUTTLE_EXCLUDE_ARGS" | write_file_sudo "$sshuttle_svc"
        info "Created: tunnel-sshuttle.service (transparent TCP proxy with DNS)"
        if [[ "$BYPASS_LAN" == true ]]; then
            info "  LAN subnets excluded from tunnel: ${BYPASS_SUBNETS}"
        fi
    fi

    # ---- tunnel-proxy control script ----
    # Installed before the services are started: the units use
    # `ExecStartPre=/usr/local/bin/tunnel-proxy check`.
    install_tunnel_proxy_script

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

    if [[ "$ENABLE_SSHUTTLE" == true ]]; then
        sudo_run systemctl enable tunnel-sshuttle.service
        if [[ "$REDEPLOY" == true ]] && systemctl is-active --quiet tunnel-sshuttle.service 2>/dev/null; then
            sudo_run systemctl restart tunnel-sshuttle.service
            info "Restarted: tunnel-sshuttle.service"
        else
            sudo_run systemctl start tunnel-sshuttle.service
            info "Started: tunnel-sshuttle.service"
        fi
        if [[ "$PROXY_MODE" == "global" ]]; then
            info "Global mode: all TCP+DNS traffic will be routed through the tunnel"
        fi
    elif [[ "$DEPLOY_SOCKS5" == true ]]; then
        # Re-installing without --enable-sshuttle must actually turn it off,
        # otherwise a previously enabled sshuttle keeps running unnoticed.
        if systemctl is-enabled --quiet tunnel-sshuttle.service 2>/dev/null; then
            sudo_run systemctl disable --now tunnel-sshuttle.service
            info "Disabled: tunnel-sshuttle.service (use --enable-sshuttle to re-enable)"
        else
            info "sshuttle not auto-started. Enable with:"
            info "  sudo systemctl enable --now tunnel-sshuttle.service"
        fi
    fi

    # ---- SSH config for easy access ----
    if [[ "$DEPLOY_REVERSE" == true ]]; then
        update_ssh_config
    fi

    # ---- tunnel-proxy function + proxy env vars in ~/.bashrc (and ~/.zshrc) ----
    install_shell_block "${HOME}/.bashrc"
    if [[ -f "${HOME}/.zshrc" ]]; then
        install_shell_block "${HOME}/.zshrc"
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
    [[ "$ENABLE_SSHUTTLE" == true ]] && services+=("tunnel-sshuttle.service")

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            info "${svc}: active"
        else
            warn "${svc}: NOT active (check with: sudo systemctl status ${svc})"
            failed=1
        fi
    done

    # Re-use the installed doctor so that install-time verification and later
    # diagnosis always apply exactly the same checks (service state, port,
    # listener identity and a real SOCKS5 handshake).
    if [[ -x /usr/local/bin/tunnel-proxy ]]; then
        # Give ssh -D a moment to bind the port before probing it.
        if [[ "$DEPLOY_SOCKS5" == true ]] && command -v ss &>/dev/null; then
            local i=0
            while [[ "$i" -lt 10 ]] && ! ss -tln 2>/dev/null | grep -q ":${SOCKS5_PORT} "; do
                sleep 0.3
                i=$((i + 1))
            done
        fi
        if sudo /usr/local/bin/tunnel-proxy doctor --quiet; then
            info "doctor: all checks passed"
        else
            warn "doctor reported problems (run: sudo tunnel-proxy doctor)"
            failed=1
        fi
    fi

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
    if [[ "$BYPASS_LAN" == true ]]; then
        echo -e "  ${YELLOW}LAN bypass:${NC}"
        echo -e "    Local subnets excluded from proxy: ${BYPASS_SUBNETS}${NC}"
        echo -e "    Set NO_PROXY for current shell: export NO_PROXY=\"localhost,*.local,${BYPASS_SUBNETS}\"${NC}"
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
    # Initialize log (never follow a pre-existing symlink as root)
    if [[ -L "$LOG_FILE" ]]; then
        rm -f "$LOG_FILE" 2>/dev/null || true
    fi
    : > "$LOG_FILE" 2>/dev/null || true
    log "=== ssh-tunnel-proxy installer started ==="
    log "Args: $*"

    echo ""
    echo -e "${BLUE}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}  ║        ssh-tunnel-proxy              ║${NC}"
    echo -e "${BLUE}  ║     One-command SSH tunnel setup     ║${NC}"
    echo -e "${BLUE}  ╚══════════════════════════════════════╝${NC}"
    echo ""

    local exit_code=0

    parse_args "$@"
    preflight_check
    install_deps
    setup_ssh_key
    if [[ "$LOCAL_ONLY" != true ]]; then
        copy_ssh_key
        test_ssh_connectivity
        load_previous_config
        remote_setup
    else
        info "--local-only: skipping SSH key upload and relay server configuration"
    fi
    local_setup
    if ! verify_services; then
        warn "Installation finished, but some services are not active."
        exit_code=1
    fi
    print_instructions

    log "=== ssh-tunnel-proxy installer finished (exit ${exit_code}) ==="
    return "$exit_code"
}

# Allow the file to be sourced by tests without executing the installer.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
