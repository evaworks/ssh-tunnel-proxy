#!/usr/bin/env bash
#
# Smoke tests for ssh-tunnel-proxy.
# Runs fully unprivileged and without network access.
#
# Usage: bash tests/smoke.sh
#
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS=0
FAIL=0
ok()  { echo "  ok   : $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL : $*" >&2; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "== 1. shell syntax =="
for f in install.sh uninstall.sh scripts/*.sh tests/smoke.sh; do
    if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f (bash -n)"; fi
done

echo "== 2. embedded copies match their canonical scripts =="
# Extract the body of a quoted heredoc: extract_heredoc <file> <opener-substring> <closing-line>
extract_heredoc() {
    awk -v open="$2" -v endmark="$3" '
        !f && index($0, open) { f = 1; next }
        f && $0 == endmark { f = 0; next }
        f { print }
    ' "$1"
}

extract_heredoc install.sh "<< 'TUNNELSCRIPT'" "TUNNELSCRIPT" > "$WORK/embedded_tp.sh"
if diff -q "$WORK/embedded_tp.sh" scripts/tunnel-proxy.sh >/dev/null; then
    ok "install.sh TUNNELSCRIPT == scripts/tunnel-proxy.sh"
else
    bad "install.sh TUNNELSCRIPT differs from scripts/tunnel-proxy.sh"
fi

extract_heredoc install.sh "<< 'REMOTESCRIPT'" "REMOTESCRIPT" > "$WORK/embedded_rs.sh"
if diff -q "$WORK/embedded_rs.sh" scripts/remote-setup.sh >/dev/null; then
    ok "install.sh REMOTESCRIPT == scripts/remote-setup.sh"
else
    bad "install.sh REMOTESCRIPT differs from scripts/remote-setup.sh"
fi

extract_heredoc install.ps1 "= @'" "'@" > "$WORK/embedded_tp.ps1"
if diff -q "$WORK/embedded_tp.ps1" scripts/tunnel-proxy.ps1 >/dev/null; then
    ok "install.ps1 fallback == scripts/tunnel-proxy.ps1"
else
    bad "install.ps1 embedded fallback differs from scripts/tunnel-proxy.ps1"
fi

echo "== 3. install.sh argument handling / exit codes =="
run_install() { bash install.sh "$@" >"$WORK/out" 2>&1; echo $?; }

rc="$(run_install)";                              [[ "$rc" == "1" ]] && ok "no args -> exit 1" || bad "no args -> exit $rc"
rc="$(run_install --help)";                       [[ "$rc" == "0" ]] && ok "--help -> exit 0" || bad "--help -> exit $rc"
rc="$(run_install --bogus)";                      [[ "$rc" == "1" ]] && ok "unknown option -> exit 1" || bad "unknown option -> exit $rc"
rc="$(run_install --server)";                     [[ "$rc" == "1" ]] && ok "--server without value -> exit 1" || bad "--server without value -> exit $rc"
grep -q -- "--server requires a value" "$WORK/out" && ok "missing value message is explicit" || bad "missing value message missing"
rc="$(run_install --server root@1.2.3.4 --socks5-port 99999)"
[[ "$rc" == "1" ]] && ok "port out of range -> exit 1" || bad "port out of range -> exit $rc"
rc="$(run_install --server root@1.2.3.4 --socks5-port abc)"
[[ "$rc" == "1" ]] && ok "non-numeric port -> exit 1" || bad "non-numeric port -> exit $rc"
rc="$(run_install --server root@1.2.3.4 --only-reverse --only-socks5)"
[[ "$rc" == "1" ]] && ok "--only-reverse + --only-socks5 -> exit 1" || bad "conflicting modes -> exit $rc"
rc="$(run_install --server 1.2.3.4)"
[[ "$rc" == "1" ]] && ok "server without user@ -> exit 1" || bad "server without user@ -> exit $rc"

echo "== 4. shell integration block (sourced install.sh) =="
(
    set -e
    cd "$ROOT"
    # shellcheck disable=SC1091
    source ./install.sh
    install_shell_block "$WORK/rc" >/dev/null 2>&1
    install_shell_block "$WORK/rc" >/dev/null 2>&1
    install_shell_block "$WORK/rc" >/dev/null 2>&1
) || bad "install_shell_block failed"
start_count="$(grep -c '^# ssh-tunnel-proxy: config$' "$WORK/rc" 2>/dev/null || echo 0)"
end_count="$(grep -c '^# ssh-tunnel-proxy: end$' "$WORK/rc" 2>/dev/null || echo 0)"
[[ "$start_count" == "1" && "$end_count" == "1" ]] && ok "block is idempotent (1 start / 1 end)" \
    || bad "block not idempotent (start=$start_count end=$end_count)"
bash -n "$WORK/rc" && ok "generated rc snippet is valid bash" || bad "generated rc snippet has a syntax error"
# Use an isolated config + a port nothing listens on, so this assertion does not
# depend on whether the real machine currently runs the tunnel.
mkdir -p "$WORK/rc-conf"
printf 'SOCKS5_PORT=59999\nBYPASS_LAN=true\nBYPASS_SUBNETS="10.0.0.0/8"\n' > "$WORK/rc-conf/tunnel.conf"
if SSH_TUNNEL_PROXY_CONF_DIR="$WORK/rc-conf" bash -c "source '$WORK/rc'; [ -z \"\${ALL_PROXY:-}\" ]"; then
    ok "proxy env vars stay unset when nothing listens"
else
    bad "proxy env vars set without a listener"
fi

# PROXY_MODE=global must never pollute the shell, even when the port is up.
mkdir -p "$WORK/globalconf"
printf 'SOCKS5_PORT=1080\nBYPASS_LAN=true\nBYPASS_SUBNETS="10.0.0.0/8"\nPROXY_MODE=global\n' > "$WORK/globalconf/tunnel.conf"
if SSH_TUNNEL_PROXY_CONF_DIR="$WORK/globalconf" bash -c "source '$WORK/rc'; [ -z \"\${ALL_PROXY:-}\" ]"; then
    ok "PROXY_MODE=global keeps the shell environment clean"
else
    bad "PROXY_MODE=global still exported proxy variables"
fi

echo "== 4b. --global / --proxy-mode parsing =="
parse_out="$(bash -c 'source ./install.sh; parse_args --server root@1.2.3.4 --global; echo "$ENABLE_SSHUTTLE $PROXY_MODE"' 2>/dev/null)"
[[ "$parse_out" == "true global" ]] && ok "--global implies --enable-sshuttle and PROXY_MODE=global" \
    || bad "--global produced '$parse_out'"
parse_out="$(bash -c 'source ./install.sh; parse_args --server root@1.2.3.4; echo "$ENABLE_SSHUTTLE $PROXY_MODE"' 2>/dev/null)"
[[ "$parse_out" == "false env" ]] && ok "default proxy mode is env" || bad "default mode was '$parse_out'"
rc="$(run_install --server root@1.2.3.4 --proxy-mode bogus)"
[[ "$rc" == "1" ]] && ok "--proxy-mode with an invalid value exits 1" || bad "invalid mode exit $rc"

echo "== 5. legacy block without end marker is preserved =="
printf 'before\n# ssh-tunnel-proxy: auto ALL_PROXY\nif true; then\n  export ALL_PROXY=x\nfi\nafter\n' > "$WORK/legacy"
(
    set -e
    source ./install.sh
    remove_shell_block "$WORK/legacy"
) >/dev/null 2>&1
if grep -q '^after$' "$WORK/legacy" && grep -q '^before$' "$WORK/legacy"; then
    ok "content after the legacy marker was not truncated"
else
    bad "legacy block handling truncated the file"
fi

echo "== 6. ~/.ssh/config entry is refreshed, not duplicated =="
mkdir -p "$WORK/home/.ssh"
printf 'Host other\n    HostName example.com\n' > "$WORK/home/.ssh/config"
(
    set -e
    source ./install.sh
    HOME="$WORK/home"
    TUNNEL_PORT=2222; SERVER="root@relay"; SSH_PORT=22; LOCAL_USER="tester"; LOCAL_HOST="host1"
    update_ssh_config
    TUNNEL_PORT=3333
    update_ssh_config
) >/dev/null 2>&1
count="$(grep -c '^Host tunnel-proxy$' "$WORK/home/.ssh/config" 2>/dev/null || echo 0)"
[[ "$count" == "1" ]] && ok "single Host tunnel-proxy entry" || bad "expected 1 entry, found $count"
grep -q '^    Port 3333$' "$WORK/home/.ssh/config" && ok "entry updated to the new port" || bad "port not updated"
grep -q '^Host other$' "$WORK/home/.ssh/config" && ok "unrelated Host entries preserved" || bad "unrelated Host entry lost"

echo "== 7. tunnel-proxy control script (stubbed systemctl/gsettings/sudo) =="
BIN="$WORK/bin"
mkdir -p "$BIN" "$WORK/etc" "$WORK/systemd"
cat > "$BIN/sudo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -u) shift 2 ;;
        *=*) shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF
cat > "$BIN/systemctl" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$BIN/gsettings" <<'EOF'
#!/bin/sh
# gsettings get <schema> <key>  /  gsettings set <schema> <key> <value>
if [ "$1" = "set" ]; then
    echo "$*" >> "$GSETTINGS_LOG"
    exit 0
fi
case "$2 $3" in
    *"proxy mode") echo "'auto'" ;;
    *"proxy use-same-proxy") echo "true" ;;
    *"proxy ignore-hosts") echo "@as []" ;;
    *"proxy.socks host") echo "''" ;;
    *"proxy.socks port") echo 0 ;;
    *) echo "''" ;;
esac
EOF
chmod +x "$BIN/sudo" "$BIN/systemctl" "$BIN/gsettings"
: > "$WORK/systemd/tunnel-socks5.service"
: > "$WORK/systemd/tunnel-reverse.service"
printf 'SOCKS5_PORT=1080\nBYPASS_LAN=true\nBYPASS_SUBNETS="10.0.0.0/8"\n' > "$WORK/etc/tunnel.conf"

(
    set -e
    export PATH="$BIN:$PATH"
    export SSH_TUNNEL_PROXY_CONF_DIR="$WORK/etc"
    export SSH_TUNNEL_PROXY_SYSTEMD_DIR="$WORK/systemd"
    export GSETTINGS_LOG="$WORK/gsettings.log"
    source ./scripts/tunnel-proxy.sh
    ORIGINAL_UID="$(id -u)"
    start_services >/dev/null
    stop_services  >/dev/null
)
if grep -q 'socks host 127.0.0.1' "$WORK/gsettings.log" 2>/dev/null; then
    ok "GNOME SOCKS host is configured explicitly"
else
    bad "GNOME SOCKS host was never set"
fi
grep -q 'socks port 1080' "$WORK/gsettings.log" 2>/dev/null && ok "GNOME SOCKS port uses the configured value" \
    || bad "GNOME SOCKS port not set"
grep -q "proxy mode manual" "$WORK/gsettings.log" 2>/dev/null && ok "GNOME proxy mode set to manual" \
    || bad "GNOME proxy mode not set"
grep -q "proxy mode 'auto'" "$WORK/gsettings.log" 2>/dev/null && ok "original GNOME mode restored on stop" \
    || bad "original GNOME mode not restored"
[[ ! -f "$WORK/etc/gnome-proxy.state" ]] && ok "state file cleaned up after restore" \
    || bad "state file left behind"

rc=0
bash scripts/tunnel-proxy.sh >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] && ok "no-arg invocation shows a summary and exits 0" || bad "no-arg exit code was $rc"
summary="$(bash scripts/tunnel-proxy.sh 2>/dev/null || true)"
case "$summary" in
    *"Proxy mode"*"on / off / status"*) ok "summary lists the common commands" ;;
    *) bad "summary is missing the common commands" ;;
esac
[[ "$(bash scripts/tunnel-proxy.sh help 2>/dev/null | head -n 1)" == "tunnel-proxy - control the ssh-tunnel-proxy tunnels" ]] \
    && ok "help prints the command reference and exits 0" || bad "help output unexpected"
bash scripts/tunnel-proxy.sh bogus >/dev/null 2>&1 && bad "unknown command did not fail" \
    || ok "unknown command exits 1"

echo "== 8. remote-setup.sh: GatewayPorts replacement + verification =="
RBIN="$WORK/rbin"; mkdir -p "$RBIN"
cat > "$RBIN/sshd" <<'EOF'
#!/bin/sh
case "$1" in
    -t) exit 0 ;;
    -T) echo "gatewayports yes"; exit 0 ;;
esac
exit 0
EOF
for t in systemctl firewall-cmd ufw iptables iptables-save; do
    printf '#!/bin/sh\nexit 0\n' > "$RBIN/$t"
done
chmod +x "$RBIN"/*

CONF="$WORK/sshd_config"
printf 'Port 22\n#GatewayPorts yes\nGatewayPorts no\n' > "$CONF"
rc=0
PATH="$RBIN:$PATH" SSHD_CONFIG="$CONF" bash scripts/remote-setup.sh 2222 22 >/dev/null 2>&1 || rc=$?
[[ "$rc" == "0" ]] && ok "remote-setup exits 0 on success" || bad "remote-setup exit $rc"
first="$(grep -i '^GatewayPorts' "$CONF" 2>/dev/null | head -1)"
[[ "$first" == "GatewayPorts yes" ]] && ok "existing 'GatewayPorts no' replaced (first value wins)" \
    || bad "effective GatewayPorts is '${first}'"
if grep -qiE '^GatewayPorts[[:space:]]+no' "$CONF"; then
    bad "stale 'GatewayPorts no' still present"
else
    ok "no stale 'GatewayPorts no' left"
fi
grep -q '^Port 22$' "$CONF" && ok "unrelated sshd_config lines preserved" || bad "unrelated lines lost"
[[ -f "${CONF}.bak.ssh-tunnel-proxy" ]] && ok "sshd_config backup created" || bad "no backup created"

# When the effective value is still wrong, the script must roll back and fail.
FBIN="$WORK/fbin"; mkdir -p "$FBIN"
cat > "$FBIN/sshd" <<'EOF'
#!/bin/sh
case "$1" in
    -t) exit 0 ;;
    -T) echo "gatewayports no"; exit 0 ;;
esac
exit 0
EOF
for t in systemctl firewall-cmd ufw iptables iptables-save; do
    printf '#!/bin/sh\nexit 0\n' > "$FBIN/$t"
done
chmod +x "$FBIN"/*
CONF2="$WORK/sshd_config2"
printf 'GatewayPorts no\n' > "$CONF2"
cp "$CONF2" "$WORK/sshd_config2.orig"
rc=0
PATH="$FBIN:$PATH" SSHD_CONFIG="$CONF2" bash scripts/remote-setup.sh 2222 22 >/dev/null 2>&1 || rc=$?
[[ "$rc" != "0" ]] && ok "failed 'sshd -T' verification exits non-zero" || bad "verification failure not detected"
diff -q "$CONF2" "$WORK/sshd_config2.orig" >/dev/null && ok "sshd_config rolled back after failure" \
    || bad "sshd_config was not rolled back"

echo "== 9. uninstall.sh block removal (sourced, no root) =="
mkdir -p "$WORK/uhome/.ssh"
cat > "$WORK/uhome/.bashrc" <<'EOF'
export PATH="$PATH:/opt/tools"
# ssh-tunnel-proxy: config
tunnel-proxy() { :; }
# ssh-tunnel-proxy: end
alias ll='ls -l'
EOF
cat > "$WORK/uhome/.ssh/config" <<'EOF'
Host other
    HostName example.com

# ssh-tunnel-proxy: host1
Host tunnel-proxy
    HostName localhost
    Port 2222
EOF
(
    set -e
    export HOME="$WORK/uhome"
    # shellcheck disable=SC1091
    source ./uninstall.sh
    remove_shell_block "$HOME/.bashrc"
    remove_ssh_config_entry
) >/dev/null 2>&1

if grep -q '^alias ll=' "$WORK/uhome/.bashrc" && grep -q '/opt/tools' "$WORK/uhome/.bashrc"; then
    ok "unrelated .bashrc content preserved"
else
    bad "unrelated .bashrc content lost"
fi
if grep -q 'tunnel-proxy' "$WORK/uhome/.bashrc"; then
    bad "managed block still present in .bashrc"
else
    ok "managed block removed from .bashrc"
fi
if grep -q '^Host other$' "$WORK/uhome/.ssh/config" && ! grep -q '^Host tunnel-proxy$' "$WORK/uhome/.ssh/config"; then
    ok "SSH config entry removed, unrelated Host kept"
else
    bad "SSH config cleanup incorrect"
fi

# Legacy safety: a start marker without an end marker must not be touched.
printf 'keep1\n# ssh-tunnel-proxy: config\nkeep2\n' > "$WORK/uhome/legacy_rc"
(
    set -e
    export HOME="$WORK/uhome"
    source ./uninstall.sh
    remove_shell_block "$WORK/uhome/legacy_rc"
) >/dev/null 2>&1
if grep -q '^keep1$' "$WORK/uhome/legacy_rc" && grep -q '^keep2$' "$WORK/uhome/legacy_rc"; then
    ok "uninstaller does not truncate on a marker without end"
else
    bad "uninstaller damaged a file with an unterminated block"
fi

echo "== 10. tunnel-proxy check / doctor / env / status =="
TBIN="$WORK/tbin"; mkdir -p "$TBIN"
cat > "$TBIN/sudo" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
    case "$1" in
        -u) shift 2 ;;
        *=*) shift ;;
        *) break ;;
    esac
done
exec "$@"
EOF
cat > "$TBIN/systemctl" <<'EOF'
#!/bin/sh
# is-active/is-enabled: succeed except for sshuttle when the marker is absent
case "$1" in
    enable)  [ -n "${SSHUTTLE_ON_MARKER:-}" ] && touch "$SSHUTTLE_ON_MARKER"; exit 0 ;;
    disable) [ -n "${SSHUTTLE_ON_MARKER:-}" ] && rm -f "$SSHUTTLE_ON_MARKER"; exit 0 ;;
    is-active|is-enabled)
        case "$3" in
            *sshuttle*) [ -n "${SSHUTTLE_ON_MARKER:-}" ] && [ -f "$SSHUTTLE_ON_MARKER" ] && exit 0 || exit 3 ;;
        esac
        exit 0 ;;
esac
exit 0
EOF
cat > "$TBIN/iptables" <<'EOF'
#!/bin/sh
# A "stale" sshuttle chain exists while the marker file is present; the cleanup
# sequence (-X) removes it.
case "$*" in
    *"-t nat -X"*) rm -f "$IPTABLES_RULES_MARKER"; exit 0 ;;
    *"-t nat -L -n"*) [ -n "${IPTABLES_RULES_MARKER:-}" ] && [ -f "$IPTABLES_RULES_MARKER" ] && echo 'Chain sshuttle-1 (1 references)'; exit 0 ;;
esac
exit 0
EOF
cat > "$TBIN/gsettings" <<'EOF'
#!/bin/sh
if [ "$1" = "set" ]; then exit 0; fi
case "$2 $3" in
    *"proxy mode") echo "'manual'" ;;
    *"proxy.socks port") echo 1080 ;;
    *) echo "''" ;;
esac
EOF
chmod +x "$TBIN"/*
export SSHUTTLE_ON_MARKER="$WORK/sshuttle_on"
export IPTABLES_RULES_MARKER="$WORK/iptables_rules"
# Use the inline cleanup path so the marker-based iptables stub above is used
# instead of a real /usr/local/bin/sshuttle-cleanup.
export SSHUTTLE_CLEANUP_BIN="$WORK/no-such-helper"
rm -f "$SSHUTTLE_ON_MARKER" "$IPTABLES_RULES_MARKER"

# A port that is free right now, used for the positive doctor scenario.
if command -v python3 >/dev/null 2>&1; then
    SPORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()' 2>/dev/null || echo 18080)"
    cat > "$TBIN/ss" <<EOF
#!/bin/sh
echo 'LISTEN 0 128 127.0.0.1:${SPORT} 0.0.0.0:* users:(("ssh",pid=1,fd=3))'
EOF
    cat > "$WORK/socks5_stub.py" <<'PY'
import socket, sys
port = int(sys.argv[1])
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(5)
while True:
    c, _ = s.accept()
    try:
        c.recv(3)
        c.sendall(b"\x05\x00")
    finally:
        c.close()
PY
    chmod +x "$TBIN/ss"
else
    SPORT=18080
fi

TETC="$WORK/tetc"; TSYS="$WORK/tsys"; mkdir -p "$TETC" "$TSYS"
touch "$TSYS/tunnel-socks5.service" "$TSYS/tunnel-reverse.service" "$TSYS/tunnel-sshuttle.service"
cat > "$TETC/tunnel.conf" <<EOF
TUNNEL_PORT=2222
SOCKS5_PORT=${SPORT}
SSH_PORT=22
SERVER=root@relay.example
BYPASS_LAN=true
BYPASS_SUBNETS="10.0.0.0/8"
DEPLOY_REVERSE=true
DEPLOY_SOCKS5=true
EOF
run_tp() {
    PATH="$TBIN:$PATH" SSH_TUNNEL_PROXY_CONF_DIR="$TETC" SSH_TUNNEL_PROXY_SYSTEMD_DIR="$TSYS" \
        bash scripts/tunnel-proxy.sh "$@"
}

if run_tp check >/dev/null 2>&1; then ok "check accepts a valid config"; else bad "check rejected a valid config"; fi

env_out="$(run_tp env 2>/dev/null)"
if ( eval "$env_out"; [ "$ALL_PROXY" = "socks5h://127.0.0.1:${SPORT}" ] && [ -n "$NO_PROXY" ] ); then
    ok "env output is eval-safe and sets ALL_PROXY/NO_PROXY"
else
    bad "env output did not produce the expected environment"
fi

# --only-reverse: no SOCKS5 service -> env must not point at a dead proxy
OETC="$WORK/oetc"; mkdir -p "$OETC"
cp "$TETC/tunnel.conf" "$OETC/tunnel.conf"
printf 'DEPLOY_REVERSE=true\nDEPLOY_SOCKS5=false\n' >> "$OETC/tunnel.conf"
oenv="$(SSH_TUNNEL_PROXY_CONF_DIR="$OETC" PATH="$TBIN:$PATH" bash scripts/tunnel-proxy.sh env 2>/dev/null || true)"
case "$oenv" in
    "unset ALL_PROXY"*) ok "env clears proxy variables when SOCKS5 is not deployed" ;;
    *) bad "env exported proxy variables without a SOCKS5 service" ;;
esac

printf 'SOCKS5_PORT=abc\nSERVER=not-a-host\nBYPASS_LAN=maybe\n' > "$TETC/tunnel.conf"
run_tp check >"$WORK/cfg.out" 2>&1 && bad "check accepted an invalid config" || ok "check rejects an invalid config"
grep -q "SOCKS5_PORT=abc is not a valid port" "$WORK/cfg.out" && ok "check names the invalid port" \
    || bad "check did not report the invalid port"
run_tp start >/dev/null 2>&1 && bad "start ran with an invalid config" || ok "start refuses an invalid config"
status_out="$(run_tp status 2>&1 || true)"
case "$status_out" in
    *"invalid configuration"*) ok "status surfaces configuration errors" ;;
    *) bad "status hid the configuration error" ;;
esac

cat > "$TETC/tunnel.conf" <<EOF
TUNNEL_PORT=2222
SOCKS5_PORT=${SPORT}
SSH_PORT=22
SERVER=root@relay.example
BYPASS_LAN=true
BYPASS_SUBNETS="10.0.0.0/8"
DEPLOY_REVERSE=true
DEPLOY_SOCKS5=true
EOF

if command -v python3 >/dev/null 2>&1; then
    run_tp status --json > "$WORK/status.json" 2>/dev/null
    if python3 -c "import json,sys; json.load(open('$WORK/status.json'))" 2>/dev/null; then
        ok "status --json emits valid JSON"
    else
        bad "status --json is not valid JSON"
    fi
fi

run_tp doctor --quiet >/dev/null 2>&1 && bad "doctor passed with nothing listening" \
    || ok "doctor fails when the SOCKS5 port is not listening"

if command -v python3 >/dev/null 2>&1; then
    python3 "$WORK/socks5_stub.py" "$SPORT" >/dev/null 2>&1 &
    SOCKS_PID=$!
    trap 'kill "$SOCKS_PID" 2>/dev/null || true; rm -rf "$WORK"' EXIT
    sleep 0.5
    if run_tp doctor --quiet; then
        ok "doctor passes with a working SOCKS5 listener"
    else
        bad "doctor failed with a working SOCKS5 listener"
    fi
    if run_tp doctor --json 2>/dev/null > "$WORK/doctor.json" || true; grep -q '"ok":true' "$WORK/doctor.json"; then
        ok "doctor --json reports ok"
    else
        bad "doctor --json did not report ok"
    fi
    doctor_out="$(run_tp doctor 2>&1 || true)"
    case "$doctor_out" in
        *"SOCKS5 method negotiation succeeded"*) ok "doctor verifies the SOCKS5 handshake" ;;
        *) bad "doctor handshake check missing" ;;
    esac

    # ---- global mode (PROXY_MODE=global + sshuttle) ----
    GETC="$WORK/getc"; mkdir -p "$GETC"
    cp "$TETC/tunnel.conf" "$GETC/tunnel.conf"
    echo "PROXY_MODE=global" >> "$GETC/tunnel.conf"
    run_tp_g() {
        PATH="$TBIN:$PATH" SSH_TUNNEL_PROXY_CONF_DIR="$GETC" SSH_TUNNEL_PROXY_SYSTEMD_DIR="$TSYS" \
            bash scripts/tunnel-proxy.sh "$@"
    }

    env_out="$(run_tp_g env 2>/dev/null || true)"
    if printf '%s\n' "$env_out" | head -n 1 | grep -q '^unset ALL_PROXY'; then
        ok "global mode: env emits unsets instead of exports"
    else
        bad "global mode: env still exports proxy variables"
    fi

    run_tp_g doctor --quiet >/dev/null 2>&1 && bad "doctor passed in global mode without sshuttle" \
        || ok "doctor fails in global mode when sshuttle is down"
    # doctor exits 1 here, so capture instead of piping (pipefail would mask grep)
    doctor_out="$(run_tp_g doctor 2>&1 || true)"
    case "$doctor_out" in
        *"PROXY_MODE=global but tunnel-sshuttle.service is not active"*)
            ok "doctor explains why global mode is broken" ;;
        *)
            bad "doctor did not report the missing sshuttle service" ;;
    esac

    touch "$SSHUTTLE_ON_MARKER" "$IPTABLES_RULES_MARKER"
    if run_tp_g doctor --quiet; then
        ok "doctor passes in global mode with sshuttle active"
    else
        bad "doctor failed in global mode with sshuttle active"
    fi

    # Circuit breaker: service gone but redirect rules still installed
    rm -f "$SSHUTTLE_ON_MARKER"
    doctor_out="$(run_tp_g doctor 2>&1 || true)"
    case "$doctor_out" in
        *"stale sshuttle iptables rules"*)
            ok "doctor detects stale sshuttle rules (blackhole risk)" ;;
        *)
            bad "doctor did not report stale sshuttle rules" ;;
    esac

    if run_tp_g rescue >/dev/null 2>&1 && [ ! -f "$IPTABLES_RULES_MARKER" ]; then
        ok "rescue removes leftover redirect rules"
    else
        bad "rescue did not clean up the leftover rules"
    fi

    touch "$IPTABLES_RULES_MARKER"
    stop_out="$(run_tp_g stop 2>&1 || true)"
    case "$stop_out" in
        *"Removed leftover sshuttle iptables rules"*) ok "stop also cleans leftover redirect rules" ;;
        *) bad "stop did not clean leftover rules" ;;
    esac
    rm -f "$SSHUTTLE_ON_MARKER" "$IPTABLES_RULES_MARKER"

    kill "$SOCKS_PID" 2>/dev/null || true
fi

# Switching modes after installation (no installer re-run needed)
METC="$WORK/metc"; mkdir -p "$METC"
cp "$TETC/tunnel.conf" "$METC/tunnel.conf"
run_tp_m() {
    PATH="$TBIN:$PATH" SSH_TUNNEL_PROXY_CONF_DIR="$METC" SSH_TUNNEL_PROXY_SYSTEMD_DIR="$TSYS" \
        bash scripts/tunnel-proxy.sh "$@"
}

mode_out="$(run_tp_m mode 2>/dev/null || true)"
case "$mode_out" in
    *"proxy mode: env"*) ok "mode reports the current mode" ;;
    *) bad "mode did not report the current mode" ;;
esac

if run_tp_m mode global >/dev/null 2>&1; then
    ok "mode global succeeds when the sshuttle unit exists"
else
    bad "mode global failed unexpectedly"
fi
grep -q '^PROXY_MODE=global$' "$METC/tunnel.conf" && ok "mode global writes PROXY_MODE=global" \
    || bad "mode global did not update the config"
env_out="$(run_tp_m env 2>/dev/null || true)"
case "$env_out" in
    "unset ALL_PROXY"*) ok "after mode global the shell env is cleared" ;;
    *) bad "env still exports proxy variables after mode global" ;;
esac

run_tp_m mode env >/dev/null 2>&1
grep -q '^PROXY_MODE=env$' "$METC/tunnel.conf" && ok "mode env switches back" \
    || bad "mode env did not update the config"

run_tp_m mode bogus >/dev/null 2>&1 && bad "mode accepted an invalid value" \
    || ok "mode rejects an invalid value"

# Relay server switching (several relays)
SHOME="$WORK/serverhome"; mkdir -p "$SHOME"
run_tp_s() {
    PATH="$TBIN:$PATH" HOME="$SHOME" SSH_TUNNEL_PROXY_CONF_DIR="$METC" SSH_TUNNEL_PROXY_SYSTEMD_DIR="$TSYS" \
        bash scripts/tunnel-proxy.sh "$@"
}
srv_out="$(run_tp_s server 2>/dev/null || true)"
case "$srv_out" in
    *"relay server :"*) ok "server reports the current relay" ;;
    *) bad "server did not report the current relay" ;;
esac

run_tp_s server root@relay2 --ssh-port 2200 >/dev/null 2>&1
grep -q '^SERVER=root@relay2$' "$METC/tunnel.conf" && ok "server switch writes SERVER" \
    || bad "server switch did not update SERVER"
grep -q '^SSH_PORT=2200$' "$METC/tunnel.conf" && ok "server switch writes the SSH port" \
    || bad "server switch did not update SSH_PORT"
grep -q 'ProxyJump root@relay2:2200' "$SHOME/.ssh/config" && ok "server switch refreshes ~/.ssh/config" \
    || bad "server switch did not refresh the SSH config entry"

run_tp_s server bogus >/dev/null 2>&1 && bad "server accepted a host without user@" \
    || ok "server requires user@host"
run_tp_s server root@x --ssh-port 99999 >/dev/null 2>&1 && bad "server accepted an invalid port" \
    || ok "server rejects an invalid port"

# Short aliases
run_tp_m global >/dev/null 2>&1
grep -q '^PROXY_MODE=global$' "$METC/tunnel.conf" && ok "global is a shortcut for mode global" \
    || bad "global alias did not switch the mode"
run_tp_m local >/dev/null 2>&1
grep -q '^PROXY_MODE=env$' "$METC/tunnel.conf" && ok "local is a shortcut for mode env" \
    || bad "local alias did not switch the mode"
run_tp_m on --global >/dev/null 2>&1
grep -q '^PROXY_MODE=global$' "$METC/tunnel.conf" && ok "on --global switches to global mode" \
    || bad "on --global did not switch the mode"
run_tp_m off >/dev/null 2>&1 && ok "off is accepted as an alias of stop" \
    || bad "off failed"
run_tp_m on >/dev/null 2>&1 && ok "on is accepted as an alias of start" \
    || bad "on failed"

mode_err="$(SSH_TUNNEL_PROXY_SYSTEMD_DIR="$WORK/empty" PATH="$TBIN:$PATH" \
    SSH_TUNNEL_PROXY_CONF_DIR="$METC" bash scripts/tunnel-proxy.sh mode global 2>&1 || true)"
case "$mode_err" in
    *"tunnel-sshuttle.service is not installed"*) ok "mode global explains what to do without the unit" ;;
    *) bad "mode global did not report the missing unit" ;;
esac

echo "== 11. rendered systemd units =="
if command -v systemd-analyze >/dev/null 2>&1; then
    (
        set -e
        source ./install.sh
        TUNNEL_PORT=2222; SOCKS5_PORT=1080; SSH_PORT=22; SERVER=root@relay
        LOCAL_USER="$(id -un)"; HOME="$WORK/uhome2"; CONFIG_FILE=/etc/ssh-tunnel-proxy/tunnel.conf
        mkdir -p "$HOME/.ssh"
        render_unit_reverse > "$WORK/r.service"
        render_unit_socks5  > "$WORK/s.service"
        render_unit_sshuttle "--exclude 10.0.0.0/8" > "$WORK/t.service"
    ) >/dev/null 2>&1
    for u in r s t; do
        # Only lines that reference our own unit file indicate a real problem;
        # systemd-analyze verify also inspects unrelated system units.
        if systemd-analyze verify "$WORK/$u.service" 2>&1 | grep -q "^$WORK/$u.service:"; then
            bad "$u.service failed systemd-analyze verify"
        else
            ok "$u.service passes systemd-analyze verify"
        fi
    done
    # Unquoted heredocs: a backtick would run a command while rendering.
    render_bodies="$(sed -n '/^render_unit_reverse() {/,/^}/p;/^render_unit_socks5() {/,/^}/p;/^render_unit_sshuttle() {/,/^}/p' install.sh)"
    if printf '%s' "$render_bodies" | grep -qF '`'; then
        bad "unit templates contain backticks (command substitution in an unquoted heredoc)"
    else
        ok "unit templates contain no backticks"
    fi
    grep -q "tunnel-proxy check" "$WORK/r.service" && ok "rendered unit keeps its comment text intact" \
        || bad "rendered unit lost comment text (substitution leaked)"

    if grep -q "^StartLimit" "$WORK/r.service" "$WORK/s.service" "$WORK/t.service"; then
        bad "tunnel units must not be rate-limited (would break reconnect-forever)"
    else
        ok "tunnel units keep retrying forever (no StartLimit)"
    fi
    grep -q "^Restart=always$" "$WORK/r.service" && ok "reverse unit restarts on any exit" \
        || bad "reverse unit lost Restart=always"
    grep -q "^ExecStartPre=/usr/local/bin/tunnel-proxy check$" "$WORK/s.service" \
        && ok "socks5 unit validates the config before starting" \
        || bad "socks5 unit is missing ExecStartPre"
    grep -q "^ExecStopPost=/usr/local/bin/sshuttle-cleanup$" "$WORK/t.service" \
        && ok "sshuttle unit always cleans up redirect rules" \
        || bad "sshuttle unit is missing ExecStopPost"
else
    echo "  skip : systemd-analyze not available"
fi

echo "== 12. docs/CLI.md documents every command =="
DOC="docs/CLI.md"
doc_missing=""

check_tokens() {
    local label="$1"; shift
    local tok
    for tok in "$@"; do
        [ -n "$tok" ] || continue
        grep -qF -- "$tok" "$DOC" || doc_missing="$doc_missing ${label}:${tok}"
    done
}

# tunnel-proxy 子命令（含别名）
check_tokens "tunnel-proxy" $(sed -n '/^run_command() {/,/^}/p' scripts/tunnel-proxy.sh \
    | grep -oE '^\s{8}[a-z0-9|_-]+\)' | tr -d ' )' | tr '|' '\n' | sed 's/^ *//' | sort -u)

# doctor 选项
check_tokens "doctor" $(sed -n '/^ *doctor() {/,/^}/p' scripts/tunnel-proxy.sh \
    | grep -oE '^\s+--[a-z]+' | sort -u)

# install.sh 选项
check_tokens "install.sh" $(sed -n '/^parse_args() {/,/^}/p' install.sh \
    | grep -oE '^\s+--[a-z0-9-]+' | tr -d ' ' | sort -u)

# Windows 参数与动作
check_tokens "install.ps1" $(grep -oE '^\s+\[(string|int|switch)\]\$[A-Za-z]+' install.ps1 | grep -oE '\$[A-Za-z]+' | tr -d '$')
check_tokens "local-setup.ps1" $(grep -oE '^\s+\[(string|int|switch)\]\$[A-Za-z]+' scripts/local-setup.ps1 | grep -oE '\$[A-Za-z]+' | tr -d '$')
check_tokens "tunnel-proxy.ps1" $(grep -oE 'ValidateSet\([^)]*\)' scripts/tunnel-proxy.ps1 | grep -oE '"[a-z]+"' | tr -d '"')

# 环境变量钩子
check_tokens "env-hook" SSH_TUNNEL_PROXY_CONF_DIR SSH_TUNNEL_PROXY_SYSTEMD_DIR SSHD_CONFIG SSHUTTLE_CLEANUP_BIN TMPDIR

if [ -z "$doc_missing" ]; then
    ok "every command/flag is documented in docs/CLI.md"
else
    bad "docs/CLI.md is missing:$doc_missing"
fi

echo "== 13. install log is never fatal =="
mkdir -p "$WORK/loghome"
fallback_log="$(bash -c '
    source ./install.sh
    LOG_FILE=/proc/self/definitely-not-writable.log
    HOME="$1"
    init_log
    printf "%s" "$LOG_FILE"
' _ "$WORK/loghome" 2>/dev/null)"
if [ "$fallback_log" = "$WORK/loghome/.ssh-tunnel-proxy-install.log" ]; then
    ok "unwritable log path falls back to \$HOME"
else
    bad "log fallback picked '$fallback_log'"
fi

survived="$(bash -c 'source ./install.sh; LOG_FILE=/proc/self/nope.log; log "hello"; echo survived' 2>/dev/null)"
case "$survived" in
    *survived*) ok "log() never fails the script" ;;
    *) bad "log() broke the script" ;;
esac

echo
echo "----------------------------------------"
echo "passed: $PASS   failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "ALL TESTS PASSED"
