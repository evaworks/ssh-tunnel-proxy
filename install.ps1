<#
.SYNOPSIS
    ssh-tunnel-proxy installer for Windows
.DESCRIPTION
    One-command setup for reverse SSH tunnel + SOCKS5 proxy on Windows.
    Uses NSSM to manage SSH processes as Windows services.
.PARAMETER Server
    Relay server address in format user@host (required)
.PARAMETER TunnelPort
    Reverse tunnel port on the relay server (default: 2222)
.PARAMETER Socks5Port
    Local SOCKS5 proxy port (default: 1080)
.PARAMETER SshPort
    SSH port on the relay server (default: 22)
.PARAMETER OnlyReverse
    Deploy reverse tunnel only (skip SOCKS5)
.PARAMETER OnlySocks5
    Deploy SOCKS5 proxy only (skip reverse tunnel)
.PARAMETER EnableSshuttle
    [Ignored on Windows] sshuttle is not supported on Windows
.PARAMETER Verbose
    Show detailed execution output
.EXAMPLE
    .\install.ps1 -Server root@1.2.3.4
.EXAMPLE
    .\install.ps1 -Server root@1.2.3.4 -TunnelPort 8888 -Verbose
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [int]$TunnelPort = 2222,
    [int]$Socks5Port = 1080,
    [int]$SshPort = 22,
    [switch]$OnlyReverse,
    [switch]$OnlySocks5,
    [switch]$EnableSshuttle,
    [switch]$Verbose
)

$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "ssh-tunnel-proxy installer"

# ---- Config paths ----
$ConfigDir = "$env:ProgramData\ssh-tunnel-proxy"
$ConfigFile = "$ConfigDir\tunnel.json"
$LogFile = "$env:TEMP\ssh-tunnel-proxy-install.log"
$SshKeyPath = "$env:USERPROFILE\.ssh\id_ed25519"
$SshConfigPath = "$env:USERPROFILE\.ssh\config"
$NssmDir = "$env:ProgramFiles\nssm"
$NssmExe = "$NssmDir\nssm.exe"
$NssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
$NssmZip = "$env:TEMP\nssm-2.24.zip"
$NssmTemp = "$env:TEMP\nssm-2.24"

$DeployReverse = -not $OnlySocks5
$DeploySocks5 = -not $OnlyReverse
$LocalUser = [Environment]::UserName
$LocalHost = [Environment]::MachineName

# ---- Colors via Write-Host ----
$CInfo = "Green"
$CWarn = "Yellow"
$CError = "Red"
$CHeader = "Cyan"
$CNC = "None"

$Separator = "=" * 45

function Log { param([string]$Msg) "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $Msg" | Out-File -FilePath $LogFile -Append }
function Info { Write-Host "[INFO]  $($args[0])" -ForegroundColor $CInfo; Log "[INFO] $($args[0])" }
function Warn { Write-Host "[WARN]  $($args[0])" -ForegroundColor $CWarn; Log "[WARN] $($args[0])" }
function ErrorOut { Write-Host "[ERROR] $($args[0])" -ForegroundColor $CError; Log "[ERROR] $($args[0])" }
function Header { 
    Write-Host "`n$Separator" -ForegroundColor $CHeader
    Write-Host "  $($args[0])" -ForegroundColor $CHeader
    Write-Host "$Separator" -ForegroundColor $CHeader
    Log "=== $($args[0]) ===" 
}

# ============================================
# Check admin rights
# ============================================
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

# ============================================
# Check OpenSSH client
# ============================================
function Check-OpenSSH {
    Header "Checking OpenSSH Client"
    
    $ssh = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($ssh) {
        $ver = & ssh -V 2>&1
        Info "OpenSSH Client found: $ver"
        return
    }

    Warn "OpenSSH Client is not installed. Installing..."
    try {
        Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0" -ErrorAction Stop | Out-Null
        Info "OpenSSH Client installed successfully"
    } catch {
        ErrorOut "Failed to install OpenSSH Client. Try manually:"
        ErrorOut "  Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0"
        exit 1
    }
}

# ============================================
# Install NSSM
# ============================================
function Install-NSSM {
    Header "Installing NSSM"

    if (Test-Path $NssmExe) {
        $ver = & $NssmExe --version 2>&1 | Out-String
        Info "NSSM already installed: $($ver.Trim())"
        return
    }

    Info "Downloading NSSM from $NssmUrl ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $NssmUrl -OutFile $NssmZip -ErrorAction Stop
    } catch {
        ErrorOut "Failed to download NSSM. Check internet connectivity."
        ErrorOut "Manual download: $NssmUrl"
        ErrorOut "Extract nssm.exe to: $NssmDir"
        exit 1
    }

    Info "Extracting NSSM..."
    try {
        Expand-Archive -Path $NssmZip -DestinationPath $NssmTemp -Force
        if (-not (Test-Path $NssmDir)) { New-Item -ItemType Directory -Path $NssmDir -Force | Out-Null }
        $arch = if ([Environment]::Is64BitOperatingSystem) { "win64" } else { "win32" }
        Copy-Item "$NssmTemp\nssm-2.24\$arch\nssm.exe" $NssmExe -Force
        Remove-Item $NssmTemp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item $NssmZip -Force -ErrorAction SilentlyContinue
        Info "NSSM installed to $NssmExe"
    } catch {
        ErrorOut "Failed to extract NSSM. Try manually."
        exit 1
    }
}

# ============================================
# SSH key setup
# ============================================
function Setup-SshKey {
    Header "SSH key setup"

    if (-not (Test-Path "$env:USERPROFILE\.ssh")) {
        New-Item -ItemType Directory -Path "$env:USERPROFILE\.ssh" -Force | Out-Null
    }

    if (Test-Path $SshKeyPath) {
        Info "Using existing SSH key: $SshKeyPath"
    } else {
        Info "Generating ed25519 SSH key..."
        & ssh-keygen -t ed25519 -N "" -f $SshKeyPath 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            ErrorOut "Failed to generate SSH key"
            exit 1
        }
        Info "Generated SSH key: $SshKeyPath"
    }
}

# ============================================
# Copy SSH key to relay server
# ============================================
function Copy-SshKey {
    Header "Copy SSH key to relay server"

    $serverHost = $Server -replace '^.*@', ''
    $pubkey = Get-Content "$SshKeyPath.pub" -Raw

    $sshOpts = ""
    if ($SshPort -ne 22) { $sshOpts = "-p $SshPort" }

    Write-Host "You will be prompted for the relay server's password (one time only)" -ForegroundColor Yellow

    $remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    try {
        $pubkey.Trim() | & ssh $sshOpts $Server $remoteCmd 2>&1
        if ($LASTEXITCODE -ne 0) { throw "ssh-copy failed" }
        Info "SSH key copied successfully"
    } catch {
        ErrorOut "Failed to copy SSH key to $Server"
        ErrorOut "Try manually: Get-Content $SshKeyPath.pub | ssh $Server 'cat >> ~/.ssh/authorized_keys'"
        exit 1
    }
}

# ============================================
# Test passwordless SSH
# ============================================
function Test-SshConnectivity {
    Header "Testing SSH connection"

    $sshOpts = "-o BatchMode=yes -o ConnectTimeout=5"
    if ($SshPort -ne 22) { $sshOpts += " -p $SshPort" }

    try {
        $result = & ssh $sshOpts $Server "echo connected" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Info "Passwordless SSH to $Server works"
        } else {
            throw "SSH connection failed"
        }
    } catch {
        ErrorOut "Passwordless SSH failed. Check your SSH key setup."
        ErrorOut "Try manually: ssh $Server"
        exit 1
    }
}

# ============================================
# Remote server setup (GatewayPorts + firewall)
# ============================================
function Invoke-RemoteSetup {
    Header "Configuring relay server"

    if (-not $DeployReverse) {
        Info "Reverse tunnel not enabled, skipping remote GatewayPorts/firewall setup"
        return
    }

    Info "Running remote setup script on $Server ..."

    $sshOpts = ""
    if ($SshPort -ne 22) { $sshOpts = "-p $SshPort" }

    $remoteScript = @"
#!/usr/bin/env bash
set -euo pipefail

TUNNEL_PORT=$TunnelPort
SSH_PORT=$SshPort
BACKUP_FILE="/etc/ssh/sshd_config.bak.ssh-tunnel-proxy"

echo "[REMOTE] GatewayPorts configuration..."

if [[ -f "\$BACKUP_FILE" ]]; then
    echo "[REMOTE] Backup already exists at \$BACKUP_FILE"
else
    cp /etc/ssh/sshd_config "\$BACKUP_FILE"
    echo "[REMOTE] Backed up sshd_config to \$BACKUP_FILE"
fi

if grep -q "^GatewayPorts yes" /etc/ssh/sshd_config 2>/dev/null; then
    echo "[REMOTE] GatewayPorts already enabled"
else
    sed -i 's/^#GatewayPorts yes/GatewayPorts yes/' /etc/ssh/sshd_config
    if ! grep -q "^GatewayPorts yes" /etc/ssh/sshd_config 2>/dev/null; then
        echo "GatewayPorts yes" >> /etc/ssh/sshd_config
    fi
    echo "[REMOTE] GatewayPorts enabled"
fi

echo "[REMOTE] Validating sshd configuration..."
if sshd -t 2>/dev/null; then
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
    cp "\$BACKUP_FILE" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo "[REMOTE] Rolled back sshd_config to original"
    exit 1
fi

echo "[REMOTE] Firewall configuration for port \${TUNNEL_PORT}..."
FIREWALL_OK=0
if command -v firewall-cmd &>/dev/null; then
    firewall-cmd --add-port="\${TUNNEL_PORT}/tcp" --permanent && firewall-cmd --reload
    echo "[REMOTE] firewalld: port \${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi
if command -v ufw &>/dev/null; then
    ufw allow "\${TUNNEL_PORT}/tcp"
    echo "[REMOTE] ufw: port \${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi
if command -v iptables &>/dev/null && ! command -v firewall-cmd &>/dev/null && ! command -v ufw &>/dev/null; then
    if ! iptables -C INPUT -p tcp --dport "\${TUNNEL_PORT}" -j ACCEPT 2>/dev/null; then
        iptables -A INPUT -p tcp --dport "\${TUNNEL_PORT}" -j ACCEPT
    fi
    if command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
    fi
    echo "[REMOTE] iptables: port \${TUNNEL_PORT} opened"
    FIREWALL_OK=1
fi
if [[ "\$FIREWALL_OK" -eq 0 ]]; then
    echo "[REMOTE] WARNING: No firewall tool detected. Ensure port \${TUNNEL_PORT} is open."
fi

echo "[REMOTE] Remote setup complete"
"@

    try {
        $remoteScript | & ssh $sshOpts $Server "sudo bash -s" 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { throw "Remote setup returned exit code $LASTEXITCODE" }
        Info "Relay server configured successfully"
    } catch {
        ErrorOut "Relay server setup failed. SSH connectivity issue?"
        ErrorOut "You can manually configure: GatewayPorts + open port $TunnelPort"
        exit 1
    }
}

# ============================================
# Local tunnel setup (NSSM services + config)
# ============================================
function Invoke-LocalSetup {
    Header "Configuring local tunnels"

    $redep = Test-Path $ConfigDir

    if ($redep) {
        Info "Existing installation detected, will restart services with new config"
    }

    # ---- Clean up services when switching deployment mode ----
    if ($redep) {
        if (-not $DeployReverse) { Remove-NssmService "ssh-tunnel-reverse" }
        if (-not $DeploySocks5) { Remove-NssmService "ssh-tunnel-socks5" }
    }

    # ---- Config directory ----
    if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }

    # ---- Config file (JSON) ----
    $config = @{
        tunnelPort  = $TunnelPort
        socks5Port  = $Socks5Port
        sshPort     = $SshPort
        server      = $Server
        localUser   = $LocalUser
        localHost   = $LocalHost
        installedAt = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $config | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    Info "Config file: $ConfigFile"

    # ---- SSH options ----
    $sshCommon = @(
        "-o", "ServerAliveInterval=30"
        "-o", "ServerAliveCountMax=3"
        "-o", "ExitOnForwardFailure=yes"
        "-o", "StrictHostKeyChecking=accept-new"
    )
    if ($SshPort -ne 22) {
        $sshCommon += "-p"; $sshCommon += "$SshPort"
    }

    # ---- Reverse tunnel service (NSSM) ----
    if ($DeployReverse) {
        $svcName = "ssh-tunnel-reverse"
        $sshArgs = $sshCommon + @("-N", "-R", "${TunnelPort}:localhost:22", $Server)
        $desc = "ssh-tunnel-proxy: reverse tunnel (port ${TunnelPort})"

        if (Test-NssmService $svcName) {
            Info "Stopping existing service: $svcName"
            & $NssmExe stop $svcName 2>$null
            Start-Sleep -Seconds 1
        }

        & $NssmExe install $svcName "ssh.exe" 2>&1 | Out-Null
        & $NssmExe set $svcName AppParameters ($sshArgs -join " ") 2>&1 | Out-Null
        & $NssmExe set $svcName DisplayName $svcName 2>&1 | Out-Null
        & $NssmExe set $svcName Description $desc 2>&1 | Out-Null
        & $NssmExe set $svcName Start SERVICE_AUTO_START 2>&1 | Out-Null
        & $NssmExe set $svcName AppRestartDelay 10000 2>&1 | Out-Null
        & $NssmExe set $svcName AppStdout "$ConfigDir\reverse-stdout.log" 2>&1 | Out-Null
        & $NssmExe set $svcName AppStderr "$ConfigDir\reverse-stderr.log" 2>&1 | Out-Null

        Info "Created service: $svcName"

        if ($redep -and (& $NssmExe status $svcName 2>$null) -match "SERVICE_RUNNING") {
            & $NssmExe restart $svcName 2>&1 | Out-Null
            Info "Restarted: $svcName"
        } else {
            & $NssmExe start $svcName 2>&1 | Out-Null
            Info "Started: $svcName"
        }
    }

    # ---- SOCKS5 proxy service (NSSM) ----
    if ($DeploySocks5) {
        $svcName = "ssh-tunnel-socks5"
        $sshArgs = $sshCommon + @("-N", "-D", "${Socks5Port}", $Server)
        $desc = "ssh-tunnel-proxy: SOCKS5 proxy (port ${Socks5Port})"

        if (Test-NssmService $svcName) {
            Info "Stopping existing service: $svcName"
            & $NssmExe stop $svcName 2>$null
            Start-Sleep -Seconds 1
        }

        & $NssmExe install $svcName "ssh.exe" 2>&1 | Out-Null
        & $NssmExe set $svcName AppParameters ($sshArgs -join " ") 2>&1 | Out-Null
        & $NssmExe set $svcName DisplayName $svcName 2>&1 | Out-Null
        & $NssmExe set $svcName Description $desc 2>&1 | Out-Null
        & $NssmExe set $svcName Start SERVICE_AUTO_START 2>&1 | Out-Null
        & $NssmExe set $svcName AppRestartDelay 10000 2>&1 | Out-Null
        & $NssmExe set $svcName AppStdout "$ConfigDir\socks5-stdout.log" 2>&1 | Out-Null
        & $NssmExe set $svcName AppStderr "$ConfigDir\socks5-stderr.log" 2>&1 | Out-Null

        Info "Created service: $svcName"

        if ($redep -and (& $NssmExe status $svcName 2>$null) -match "SERVICE_RUNNING") {
            & $NssmExe restart $svcName 2>&1 | Out-Null
            Info "Restarted: $svcName"
        } else {
            & $NssmExe start $svcName 2>&1 | Out-Null
            Info "Started: $svcName"
        }
    }

    # ---- sshuttle warning ----
    if ($EnableSshuttle) {
        Warn "--enable-sshuttle is ignored on Windows (sshuttle requires Linux iptables)"
    }

    # ---- Set system proxy in registry ----
    if ($DeploySocks5) {
        Set-SystemProxy $Socks5Port
    }

    # ---- SSH config for easy access ----
    if ($DeployReverse) {
        Add-SshConfig
    }
}

# ============================================
# NSSM helper functions
# ============================================
function Test-NssmService { param([string]$Name)
    $svcs = & $NssmExe list 2>$null
    return ($svcs -contains $Name)
}

function Remove-NssmService { param([string]$Name)
    if (Test-NssmService $Name) {
        Info "Removing existing service: $Name"
        & $NssmExe stop $Name 2>$null
        Start-Sleep -Seconds 1
        & $NssmExe remove $Name confirm 2>&1 | Out-Null
        Info "Removed: $Name"
    }
}

# ============================================
# Set system SOCKS5 proxy (registry)
# ============================================
function Set-SystemProxy { param([int]$Port)
    Header "Setting Windows system proxy"
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        Set-ItemProperty -Path $regPath -Name ProxyServer -Value "127.0.0.1:$Port" -ErrorAction Stop
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1 -ErrorAction Stop
        Info "System proxy set to SOCKS5 127.0.0.1:$Port"
        Info "Note: Not all applications respect Windows system proxy settings."
        Info "      For curl/cargo/etc, use: `$env:ALL_PROXY='socks5h://127.0.0.1:$Port'"
    } catch {
        Warn "Failed to set system proxy in registry: $_"
        Warn "You can set it manually: Settings → Network → Proxy"
    }
}

# ============================================
# Add SSH config entry
# ============================================
function Add-SshConfig {
    $serverJump = if ($SshPort -ne 22) { "$($Server):$SshPort" } else { $Server }

    $entry = @"
# ssh-tunnel-proxy: ${LocalHost}
Host tunnel-proxy
    HostName localhost
    Port ${TunnelPort}
    ProxyJump ${serverJump}
    User ${LocalUser}
    ServerAliveInterval 30
    ServerAliveCountMax 3
"@

    $sshDir = "$env:USERPROFILE\.ssh"
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }

    if (Test-Path $SshConfigPath) {
        $content = Get-Content $SshConfigPath -Raw
        if ($content -match "tunnel-proxy") {
            Info "SSH config entry already exists (~/.ssh/config)"
            return
        }
    }

    $entry | Out-File -FilePath $SshConfigPath -Append -Encoding UTF8
    Info "Added SSH config entry: Host tunnel-proxy"
    Info "  Connect with: ssh tunnel-proxy"
}

# ============================================
# Verify services
# ============================================
function Verify-Services {
    Header "Verifying services"

    if ($DeployReverse) {
        $status = & $NssmExe status "ssh-tunnel-reverse" 2>$null
        if ($status -match "SERVICE_RUNNING") {
            Info "ssh-tunnel-reverse: running"
        } else {
            Warn "ssh-tunnel-reverse: $status"
        }
    }

    if ($DeploySocks5) {
        $status = & $NssmExe status "ssh-tunnel-socks5" 2>$null
        if ($status -match "SERVICE_RUNNING") {
            Info "ssh-tunnel-socks5: running"
        } else {
            Warn "ssh-tunnel-socks5: $status"
        }
    }
}

# ============================================
# Print usage instructions
# ============================================
function Print-Instructions {
    Header "Installation Complete"
    $serverHost = $Server -replace '^.*@', ''
    $serverJump = if ($SshPort -ne 22) { "$($Server):$SshPort" } else { $Server }

    if ($DeployReverse) {
        Write-Host "`n  Access this machine from other devices:" -ForegroundColor Yellow
        Write-Host "    ssh -J ${serverJump} ${LocalUser}@localhost -p ${TunnelPort}"
        Write-Host "    ssh tunnel-proxy"
    }

    if ($DeploySocks5) {
        Write-Host "`n  Test internet access via SOCKS5 proxy:" -ForegroundColor Yellow
        Write-Host "    curl --socks5-hostname 127.0.0.1:${Socks5Port} https://www.google.com"
        Write-Host "`n  System proxy set to 127.0.0.1:${Socks5Port}" -ForegroundColor Yellow
    }

    Write-Host "`n  Manage services:" -ForegroundColor Yellow
    if ($DeployReverse) { Write-Host "    $NssmExe status ssh-tunnel-reverse" }
    if ($DeploySocks5) { Write-Host "    $NssmExe status ssh-tunnel-socks5" }
    Write-Host "`n  Config file:" -ForegroundColor Yellow
    Write-Host "    $ConfigFile"
    Write-Host "`n  Log file:" -ForegroundColor Yellow
    Write-Host "    $LogFile`n"
}

# ============================================
# Main
# ============================================
function Main {
    $null = New-Item -ItemType File -Path $LogFile -Force
    Log "=== ssh-tunnel-proxy installer started ==="

    Write-Host "`n  ╔══════════════════════════════════════╗" -ForegroundColor $CHeader
    Write-Host "  ║        ssh-tunnel-proxy              ║" -ForegroundColor $CHeader
    Write-Host "  ║     One-command SSH tunnel setup     ║" -ForegroundColor $CHeader
    Write-Host "  ╚══════════════════════════════════════╝" -ForegroundColor $CHeader

    Check-Admin
    Check-OpenSSH
    Install-NSSM
    Setup-SshKey
    Copy-SshKey
    Test-SshConnectivity
    Invoke-RemoteSetup
    Invoke-LocalSetup
    Verify-Services
    Print-Instructions

    Log "=== ssh-tunnel-proxy installer finished ==="
}

Main
