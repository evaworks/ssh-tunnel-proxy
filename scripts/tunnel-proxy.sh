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
  tunnel-proxy server          show the relay server
  tunnel-proxy server user@host [--ssh-port N] [--tunnel-port N] [--cleanup-old]
                               point the tunnel at another relay server

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

# Write KEY=VALUE into tunnel.conf (replace the line, or append it).
config_set() {
    local key="$1" value="$2"
    if grep -q "^${key}=" "$CONFIG_FILE" 2>/dev/null; then
        sudo sed -i "s|^${key}=.*|${key}=${value}|" "$CONFIG_FILE"
    else
        printf '%s=%s\n' "$key" "$value" | sudo tee -a "$CONFIG_FILE" >/dev/null
    fi
    printf -v "$key" '%s' "$value"
}

# Refresh the managed "Host tunnel-proxy" entry in ~/.ssh/config.
update_ssh_config_entry() {
    local ssh_config="${HOME}/.ssh/config"
    local cfg_user="${LOCAL_USER:-$(id -un)}"
    local cfg_host="${LOCAL_HOST:-$(hostname -s 2>/dev/null || echo host)}"
    local server_jump="$SERVER"
    [[ "$SSH_PORT" -ne 22 ]] && server_jump="${SERVER}:${SSH_PORT}"

    mkdir -p "$(dirname "$ssh_config")" 2>/dev/null || true
    [[ -f "$ssh_config" ]] || : > "$ssh_config"

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
        echo "# ssh-tunnel-proxy: ${cfg_host}"
        echo "Host tunnel-proxy"
        echo "    HostName localhost"
        echo "    Port ${TUNNEL_PORT}"
        echo "    ProxyJump ${server_jump}"
        echo "    User ${cfg_user}"
        echo "    ServerAliveInterval 30"
        echo "    ServerAliveCountMax 3"
    } >> "$ssh_config"
    chmod 600 "$ssh_config" 2>/dev/null || true
}

# Best effort: revert GatewayPorts / close the tunnel port on a relay we are no
# longer using (needs key access to the old server).
cleanup_old_relay() {
    local old_server="$1" old_ssh_port="$2" old_tunnel_port="$3"
    local ssh_arg=()
    [[ "$old_ssh_port" -ne 22 ]] && ssh_arg=(-p "$old_ssh_port")
    echo "[tunnel-proxy] cleaning up old relay ${old_server} ..."
    if timeout 25 ssh -o BatchMode=yes -o ConnectTimeout=8 "${ssh_arg[@]+"${ssh_arg[@]}"}" "$old_server" \
            "sudo bash -s -- ${old_tunnel_port}" <<'OLDRELAY' 2>/dev/null
#!/usr/bin/env bash
set -euo pipefail
TUNNEL_PORT="${1:-}"
BACKUP_FILE="/etc/ssh/sshd_config.bak.ssh-tunnel-proxy"
if [[ -f "$BACKUP_FILE" ]]; then
    cp "$BACKUP_FILE" /etc/ssh/sshd_config
    rm -f "$BACKUP_FILE"
else
    sed -i -E '/^[[:space:]]*#*[[:space:]]*GatewayPorts[[:space:]]/d' /etc/ssh/sshd_config
fi
if sshd -t 2>/dev/null; then
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
fi
if [[ -n "$TUNNEL_PORT" ]]; then
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --remove-port="${TUNNEL_PORT}/tcp" --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
    elif command -v ufw &>/dev/null; then
        ufw delete allow "${TUNNEL_PORT}/tcp" 2>/dev/null || true
    elif command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "${TUNNEL_PORT}" -j ACCEPT 2>/dev/null || true
    fi
fi
echo "[old-relay] reverted GatewayPorts and closed port ${TUNNEL_PORT}"
OLDRELAY
    then
        echo "[tunnel-proxy] old relay cleaned up"
    else
        echo "[tunnel-proxy] WARNING: could not clean up ${old_server} (unreachable or no key)" >&2
        echo "[tunnel-proxy]   manual: ssh ${old_server} 'sudo sed -i \"/GatewayPorts/d\" /etc/ssh/sshd_config && sudo systemctl restart sshd'" >&2
    fi
    return 0
}

# Show or change the relay server (useful when you own several of them).
server_cmd() {
    local new_server="" new_ssh_port="" new_tunnel_port="" do_cleanup=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ssh-port)    new_ssh_port="${2:-}"; shift 2 ;;
            --tunnel-port) new_tunnel_port="${2:-}"; shift 2 ;;
            --cleanup-old) do_cleanup=true; shift ;;
            --*)  echo "Usage: tunnel-proxy server [user@host] [--ssh-port N] [--tunnel-port N] [--cleanup-old]" >&2; return 1 ;;
            *)    new_server="$1"; shift ;;
        esac
    done

    if [[ -z "$new_server" ]]; then
        echo "[tunnel-proxy] relay server : ${SERVER:-<unset>}"
        echo "[tunnel-proxy] ssh port     : ${SSH_PORT}"
        echo "[tunnel-proxy] tunnel port  : ${TUNNEL_PORT}"
        echo "[tunnel-proxy] to change    : sudo tunnel-proxy server user@host [--ssh-port N] [--tunnel-port N]"
        return 0
    fi

    if [[ "$new_server" != *"@"* ]]; then
        echo "[tunnel-proxy] ERROR: server must look like user@host (got: ${new_server})" >&2
        return 1
    fi
    local p
    for p in "$new_ssh_port" "$new_tunnel_port"; do
        [[ -z "$p" ]] && continue
        if [[ ! "$p" =~ ^[0-9]+$ ]] || (( 10#$p < 1 || 10#$p > 65535 )); then
            echo "[tunnel-proxy] ERROR: '${p}' is not a valid port (1-65535)" >&2
            return 1
        fi
    done
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "[tunnel-proxy] ERROR: ${CONFIG_FILE} not found" >&2
        return 1
    fi

    local old_server="$SERVER" old_ssh_port="$SSH_PORT" old_tunnel_port="$TUNNEL_PORT"
    local was_active=false
    if service_active tunnel-reverse.service || service_active tunnel-socks5.service; then
        was_active=true
    fi

    config_set SERVER "$new_server"
    [[ -n "$new_ssh_port" ]] && config_set SSH_PORT "$new_ssh_port"
    [[ -n "$new_tunnel_port" ]] && config_set TUNNEL_PORT "$new_tunnel_port"
    echo "[tunnel-proxy] relay server -> ${SERVER} (ssh port ${SSH_PORT}, tunnel port ${TUNNEL_PORT})"

    update_ssh_config_entry
    echo "[tunnel-proxy] updated ${HOME}/.ssh/config (Host tunnel-proxy)"

    if [[ "$was_active" == true ]]; then
        echo "[tunnel-proxy] restarting services..."
        sudo systemctl restart tunnel-reverse.service 2>/dev/null || true
        sudo systemctl restart tunnel-socks5.service 2>/dev/null || true
        if have_sshuttle && service_active tunnel-sshuttle.service; then
            sudo systemctl restart tunnel-sshuttle.service 2>/dev/null || true
        fi
    fi

    if [[ "$do_cleanup" == true && -n "$old_server" && "$old_server" != "$SERVER" ]]; then
        cleanup_old_relay "$old_server" "$old_ssh_port" "$old_tunnel_port"
    elif [[ -n "$old_server" && "$old_server" != "$SERVER" ]]; then
        echo "[tunnel-proxy] note: old relay ${old_server} was left untouched (use --cleanup-old to revert it)"
    fi

    echo "[tunnel-proxy] verify with: sudo tunnel-proxy doctor"
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

    config_set PROXY_MODE "$want"
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
        server)        shift; server_cmd "$@" ;;
        rescue)        rescue_network ;;
        *)             usage ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    run_command "$@"
fi
