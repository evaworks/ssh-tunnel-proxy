<#
.SYNOPSIS
    ssh-tunnel-proxy Uninstaller for Windows
.DESCRIPTION
    Stops and removes all NSSM services, cleans up config, and restores system proxy.
    If possible, also cleans up the relay server (GatewayPorts + firewall).
.NOTES
    Requires Administrator privileges: run from an elevated PowerShell
    ("Run as administrator"), otherwise the script exits with an error.
#>

$ErrorActionPreference = "Stop"

$ConfigDir = "$env:ProgramData\ssh-tunnel-proxy"
$ConfigFile = "$ConfigDir\tunnel.json"
$ProxyBackupFile = "$ConfigDir\proxy-backup.json"
$NssmExe = "$env:ProgramFiles\nssm\nssm.exe"
$ReverseService = "ssh-tunnel-reverse"
$Socks5Service = "ssh-tunnel-socks5"

function Info { Write-Host "[INFO]  $($args[0])" -ForegroundColor Green }
function Warn { Write-Host "[WARN]  $($args[0])" -ForegroundColor Yellow }
function ErrorOut { Write-Host "[ERROR] $($args[0])" -ForegroundColor Red }

function Check-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        ErrorOut "This script must be run as Administrator."
        ErrorOut "Right-click PowerShell and select 'Run as administrator'."
        exit 1
    }
    Info "Running with administrator privileges"
}

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
    if (-not (Test-Path $NssmExe)) {
        Warn "nssm not found at $NssmExe - service $Name may be left behind"
        Warn "Remove it manually: sc.exe delete $Name"
        return
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $svcs = & $NssmExe list 2>$null
        if ($svcs -contains $Name) {
            Info "Stopping and removing: $Name"
            & $NssmExe stop $Name 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { Warn "nssm stop $Name returned exit code $LASTEXITCODE" }
            Start-Sleep -Seconds 1
            & $NssmExe remove $Name confirm 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Warn "nssm remove $Name returned exit code $LASTEXITCODE (service may remain)"
                Warn "Remove it manually: sc.exe delete $Name"
            } else {
                Info "Removed: $Name"
            }
        }
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

function Update-InternetSettings {
    try {
        if (-not ("Win32.WinInet" -as [type])) {
            Add-Type -Namespace Win32 -Name WinInet -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);
'@
        }
        # INTERNET_OPTION_SETTINGS_CHANGED = 39, INTERNET_OPTION_REFRESH = 37
        [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    } catch {
        # Best effort only; ignore failures.
    }
}

# Restore the original proxy settings from the backup made at install time and
# drop the backup file. Without a backup only ProxyEnable is turned off.
function Restore-SystemProxy {
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    if (Test-Path $ProxyBackupFile) {
        try {
            $backup = Get-Content $ProxyBackupFile -Raw | ConvertFrom-Json
            foreach ($name in @("ProxyServer", "ProxyEnable", "ProxyOverride")) {
                if (($backup.PSObject.Properties.Name -contains $name) -and $null -ne $backup.$name -and "$($backup.$name)" -ne "") {
                    Set-ItemProperty -Path $regPath -Name $name -Value $backup.$name -ErrorAction Stop
                } else {
                    Remove-ItemProperty -Path $regPath -Name $name -ErrorAction SilentlyContinue
                }
            }
            Remove-Item $ProxyBackupFile -Force -ErrorAction SilentlyContinue
            Update-InternetSettings
            Info "Restored original system proxy settings"
            return
        } catch {
            Warn "Failed to restore system proxy settings: $_"
        }
    }
    try {
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0 -ErrorAction Stop
        Update-InternetSettings
        Info "System proxy disabled"
    } catch {
        Warn "Failed to restore system proxy: $_"
    }
}

function Remove-SshConfig {
    $sshConfig = "$env:USERPROFILE\.ssh\config"
    if (-not (Test-Path $sshConfig)) { return }

    $content = Get-Content $sshConfig -Raw
    if (-not $content) { return }

    # Match the exact marker and Host line, so unrelated entries are untouched.
    if (-not (($content -match '(?m)^# ssh-tunnel-proxy:') -and ($content -match '(?m)^Host tunnel-proxy[ \t]*\r?$'))) {
        return
    }

    $blockPattern = '(?ms)^# ssh-tunnel-proxy:[^\r\n]*\r?\n^Host tunnel-proxy[ \t]*\r?\n(?:[ \t]+[^\r\n]*\r?\n?)*'
    $newContent = [regex]::Replace($content, $blockPattern, '').Trim()
    if ([string]::IsNullOrEmpty($newContent)) {
        Remove-Item $sshConfig -Force -ErrorAction SilentlyContinue
        Info "Removed SSH config file"
    } else {
        [IO.File]::WriteAllText($sshConfig, $newContent + "`r`n", (New-Object Text.UTF8Encoding($false)))
        Info "Removed SSH config entry (Host tunnel-proxy)"
    }
}

function Remove-TunnelProxyScript {
    # Delete the file first: the directory holding it is removed later, and doing
    # this after that removal would silently become a no-op.
    $scriptPath = "$ConfigDir\tunnel-proxy.ps1"
    if (Test-Path $scriptPath) {
        Remove-Item $scriptPath -Force -ErrorAction SilentlyContinue
        Info "Removed: tunnel-proxy.ps1"
    }

    $cmdPath = "$ConfigDir\tunnel-proxy.cmd"
    if (Test-Path $cmdPath) {
        Remove-Item $cmdPath -Force -ErrorAction SilentlyContinue
        Info "Removed: tunnel-proxy.cmd"
    }

    # Clean up PATH
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -like "*$ConfigDir*") {
        $newPath = ($userPath -split ';' | Where-Object { $_ -ne $ConfigDir }) -join ';'
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Info "Removed $ConfigDir from user PATH"
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

    # Argument array + splatting: a single string like "-p 2222" would be passed
    # to ssh as ONE argv and break option parsing.
    $sshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=5")
    if ($sshPort -ne 22) { $sshOpts += @("-p", "$sshPort") }

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
    sed -i -E '/^[[:space:]]*#*[[:space:]]*GatewayPorts[[:space:]]/d' /etc/ssh/sshd_config
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
        $remoteScript | & ssh @sshOpts $server "sudo bash -s" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -eq 0) {
            Info "Relay server cleaned up successfully"
        } else {
            Warn "Relay server cleanup returned exit code $LASTEXITCODE"
            Warn "Manual cleanup needed on server: $server (SSH port: $sshPort, tunnel port: $tunnelPort)"
        }
    } catch {
        Warn "Relay server cleanup failed (SSH connectivity issue). Do it manually:"
        Warn "  server: $server (SSH port: $sshPort, tunnel port: $tunnelPort)"
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

Check-Admin
Confirm-Uninstall

# Read the config first and keep it: it is needed by the relay cleanup below and
# for diagnostics if that cleanup fails.
$config = Read-Config

# Stop and remove NSSM services
Remove-NssmService $ReverseService
Remove-NssmService $Socks5Service

# Restore system proxy (reads proxy-backup.json from the config directory)
Restore-SystemProxy

# Remove SSH config entry
Remove-SshConfig

# Remove the tunnel-proxy control script before its directory is deleted below
Remove-TunnelProxyScript

# Clean up the relay server (needs $config, so it runs before the directory goes)
Invoke-RemoteCleanup $config

# Remove the config directory last: every step above may still need it
if (Test-Path $ConfigDir) {
    Remove-Item $ConfigDir -Recurse -Force -ErrorAction SilentlyContinue
    Info "Removed config directory: $ConfigDir"
}

Write-Host ""
Write-Host "ssh-tunnel-proxy has been uninstalled." -ForegroundColor Green
Write-Host ""
Write-Host "The following were left untouched (may be needed elsewhere):"
Write-Host "  - SSH keys:      $env:USERPROFILE\.ssh\id_ed25519*"
Write-Host "  - NSSM:          $NssmExe"
Write-Host "  - OpenSSH:       (Windows optional feature)"
Write-Host ""
