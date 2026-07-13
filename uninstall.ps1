<#
.SYNOPSIS
    ssh-tunnel-proxy Uninstaller for Windows
.DESCRIPTION
    Stops and removes all NSSM services, cleans up config, and restores system proxy.
    If possible, also cleans up the relay server (GatewayPorts + firewall).
#>

$ErrorActionPreference = "Stop"

$ConfigDir = "$env:ProgramData\ssh-tunnel-proxy"
$ConfigFile = "$ConfigDir\tunnel.json"
$NssmExe = "$env:ProgramFiles\nssm\nssm.exe"

function Info { Write-Host "[INFO]  $($args[0])" -ForegroundColor Green }
function Warn { Write-Host "[WARN]  $($args[0])" -ForegroundColor Yellow }
function ErrorOut { Write-Host "[ERROR] $($args[0])" -ForegroundColor Red }

function Confirm-Uninstall {
    Write-Host "`nUninstall ssh-tunnel-proxy? This will stop all tunnels." -ForegroundColor Yellow
    $resp = Read-Host "[y/N]"
    if ($resp -ne "y" -and $resp -ne "Y") {
        Info "Cancelled."
        exit 0
    }
}

function Read-Config {
    if (Test-Path $ConfigFile) {
        try {
            $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            Info "Read config: server=$($config.server), tunnelPort=$($config.tunnelPort)"
            return $config
        } catch {
            Warn "Could not parse config file: $_"
            return $null
        }
    }
    return $null
}

function Remove-NssmService { param([string]$Name)
    if (-not (Test-Path $NssmExe)) { return }
    $svcs = & $NssmExe list 2>$null
    if ($svcs -contains $Name) {
        Info "Stopping and removing: $Name"
        & $NssmExe stop $Name 2>$null
        Start-Sleep -Seconds 1
        & $NssmExe remove $Name confirm 2>$null
        Info "Removed: $Name"
    }
}

function Restore-SystemProxy {
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0 -ErrorAction Stop
        Info "System proxy disabled"
    } catch {
        Warn "Failed to restore system proxy: $_"
    }
}

function Remove-SshConfig {
    $sshConfig = "$env:USERPROFILE\.ssh\config"
    if (-not (Test-Path $sshConfig)) { return }

    $content = Get-Content $sshConfig -Raw
    if ($content -match "tunnel-proxy") {
        $newContent = $content -replace '(?s)# ssh-tunnel-proxy: .*?\nHost tunnel-proxy\n.*?(?=\n\S|\z)', ''
        $newContent = $newContent.Trim()
        if ([string]::IsNullOrEmpty($newContent)) {
            Remove-Item $sshConfig -Force -ErrorAction SilentlyContinue
            Info "Removed SSH config file"
        } else {
            Set-Content -Path $sshConfig -Value $newContent -Encoding UTF8
            Info "Removed SSH config entry (Host tunnel-proxy)"
        }
    }
}

function Invoke-RemoteCleanup {
    param($config)
    if (-not $config -or -not $config.server) {
        Warn "No server config found, skipping relay cleanup"
        return
    }

    $server = $config.server
    $tunnelPort = if ($config.tunnelPort) { $config.tunnelPort } else { 2222 }
    $sshPort = if ($config.sshPort) { $config.sshPort } else { 22 }

    Write-Host ""
    Info "Cleaning up relay server $server ..."

    $sshOpts = "-o BatchMode=yes -o ConnectTimeout=5"
    if ($sshPort -ne 22) { $sshOpts += " -p $sshPort" }

    $remoteScript = @"
#!/usr/bin/env bash
set -euo pipefail

TUNNEL_PORT=$tunnelPort
BACKUP_FILE="/etc/ssh/sshd_config.bak.ssh-tunnel-proxy"

echo "[REMOTE] Reverting GatewayPorts..."
if [[ -f "\$BACKUP_FILE" ]]; then
    cp "\$BACKUP_FILE" /etc/ssh/sshd_config
    rm -f "\$BACKUP_FILE"
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

echo "[REMOTE] Removing firewall rule for port \${TUNNEL_PORT}..."
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --remove-port="\${TUNNEL_PORT}/tcp" --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
elif command -v ufw &>/dev/null; then
    ufw delete allow "\${TUNNEL_PORT}/tcp" 2>/dev/null || true
elif command -v iptables &>/dev/null; then
    iptables -D INPUT -p tcp --dport "\${TUNNEL_PORT}" -j ACCEPT 2>/dev/null || true
fi
echo "[REMOTE] Firewall rule removed"
echo "[REMOTE] Cleanup complete"
"@

    try {
        $remoteScript | & ssh $sshOpts $server "sudo bash -s" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -eq 0) {
            Info "Relay server cleaned up successfully"
        } else {
            Warn "Relay server cleanup returned exit code $LASTEXITCODE"
        }
    } catch {
        Warn "Relay server cleanup failed (SSH connectivity issue). Do it manually:"
        Warn "  ssh $server"
        Warn "  sudo sed -i '/^GatewayPorts yes/d' /etc/ssh/sshd_config"
        Warn "  sudo systemctl restart sshd"
    }
}

# ============================================
# Main
# ============================================
Write-Host "`n  ╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║     ssh-tunnel-proxy Uninstaller     ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor Cyan

Confirm-Uninstall

$config = Read-Config

# Stop and remove NSSM services
Remove-NssmService "ssh-tunnel-reverse"
Remove-NssmService "ssh-tunnel-socks5"

# Remove config directory
if (Test-Path $ConfigDir) {
    Remove-Item $ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    Info "Removed config directory: $ConfigDir"
}

# Restore system proxy
Restore-SystemProxy

# Remove SSH config entry
Remove-SshConfig

# Clean up relay server
Invoke-RemoteCleanup $config

Write-Host ""
Write-Host "ssh-tunnel-proxy has been uninstalled." -ForegroundColor Green
Write-Host ""
Write-Host "The following were left untouched (may be needed elsewhere):"
Write-Host "  - SSH keys:      $env:USERPROFILE\.ssh\id_ed25519*"
Write-Host "  - NSSM:          $NssmExe"
Write-Host "  - OpenSSH:       (Windows optional feature)"
Write-Host ""
