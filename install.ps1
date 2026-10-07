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
.PARAMETER NoBypassLan
    Route LAN traffic through the tunnel too (default: bypass LAN subnets)
.EXAMPLE
    .\install.ps1 -Server root@1.2.3.4
.EXAMPLE
    .\install.ps1 -Server root@1.2.3.4 -TunnelPort 8888 -Verbose
.NOTES
    Requires Administrator privileges: run from an elevated PowerShell
    ("Run as administrator"), otherwise the script exits with an error.
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
    [switch]$Verbose,
    [switch]$NoBypassLan
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
$BypassLan = -not $NoBypassLan
$BypassSubnets = "127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
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
# Validate options
# ============================================
# -OnlyReverse and -OnlySocks5 together would deploy nothing; fail loudly instead.
if ($OnlyReverse -and $OnlySocks5) {
    ErrorOut "-OnlyReverse and -OnlySocks5 cannot be used together"
    exit 1
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
        $ver = "(version unknown)"
        try { $ver = (& ssh -V 2>&1 | Out-String).Trim() } catch { }
        Info "OpenSSH Client found: $ver"
    } else {
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

    # The reverse tunnel forwards to localhost:22, so this machine needs a local
    # OpenSSH Server. We only warn about it (never auto-install) to avoid
    # modifying the user's system without consent.
    if ($DeployReverse) {
        $sshdSvc = Get-Service -Name sshd -ErrorAction SilentlyContinue
        if (-not $sshdSvc) {
            Warn "OpenSSH Server (sshd) not found, but the reverse tunnel targets localhost:22"
            Warn "  Reverse access will fail until a local SSH server is installed:"
            Warn "  Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"
        } elseif ($sshdSvc.Status -ne "Running") {
            Warn "OpenSSH Server (sshd) is installed but not running (status: $($sshdSvc.Status))"
            Warn "  Start it manually: Start-Service sshd; Set-Service sshd -StartupType Automatic"
        } else {
            Info "OpenSSH Server (sshd) is running"
        }
    }
}

# ============================================
# Install NSSM
# ============================================
function Install-NSSM {
    Header "Installing NSSM"

    if (Test-Path $NssmExe) {
        # `nssm version` is the supported form; a failure here does not stop the install.
        $ver = Get-NssmOutput @("version")
        if ([string]::IsNullOrWhiteSpace($ver)) { $ver = "(version unknown)" }
        Info "NSSM already installed: $ver"
        return
    }

    Info "Downloading NSSM from $NssmUrl ..."
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $NssmUrl -OutFile $NssmZip -UseBasicParsing -ErrorAction Stop
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

    if (-not (Test-Path "$SshKeyPath.pub")) {
        ErrorOut "Public key not found: $SshKeyPath.pub"
        ErrorOut "Regenerate the key pair with: ssh-keygen -t ed25519 -f $SshKeyPath"
        exit 1
    }

    # Argument array + splatting: a single string like "-p 2222" is passed to ssh
    # as ONE argv and ssh fails with "keyword ... extra arguments at end of line".
    # NOTE: no BatchMode here on purpose - this call needs the password prompt.
    $sshOpts = @()
    if ($SshPort -ne 22) { $sshOpts += @("-p", "$SshPort") }

    Write-Host "You will be prompted for the relay server's password (one time only)" -ForegroundColor Yellow

    $remoteCmd = "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
    try {
        $pubkey = Get-Content "$SshKeyPath.pub" -Raw
        $pubkey.Trim() | & ssh @sshOpts $Server $remoteCmd 2>&1
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

    # Argument array + splatting (see Copy-SshKey).
    $sshOpts = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=5")
    if ($SshPort -ne 22) { $sshOpts += @("-p", "$SshPort") }

    try {
        $result = & ssh @sshOpts $Server "echo connected" 2>&1
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

    # Argument array + splatting (see Copy-SshKey).
    $sshOpts = @()
    if ($SshPort -ne 22) { $sshOpts += @("-p", "$SshPort") }

    # Previous tunnel port (if any), so a stale relay firewall rule can be removed.
    $oldTunnelPort = ""
    if (Test-Path $ConfigFile) {
        try {
            $oldCfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
            if ($oldCfg.tunnelPort) { $oldTunnelPort = "$($oldCfg.tunnelPort)" }
        } catch { }
    }

    $remoteScript = @"
#!/usr/bin/env bash
set -euo pipefail

TUNNEL_PORT=$TunnelPort
SSH_PORT=$SshPort
OLD_TUNNEL_PORT="$oldTunnelPort"
BACKUP_FILE="/etc/ssh/sshd_config.bak.ssh-tunnel-proxy"

echo "[REMOTE] GatewayPorts configuration..."

if [[ ! -f "\$BACKUP_FILE" ]]; then
    cp /etc/ssh/sshd_config "\$BACKUP_FILE"
    echo "[REMOTE] Backed up sshd_config to \$BACKUP_FILE"
fi

# sshd uses the FIRST value found for a keyword, so replace every existing
# GatewayPorts directive - appending at the end would be ignored.
if grep -qiE '^[[:space:]]*#*[[:space:]]*GatewayPorts[[:space:]]' /etc/ssh/sshd_config; then
    sed -i -E 's/^[[:space:]]*#*[[:space:]]*[Gg]ateway[Pp]orts[[:space:]]+.*/GatewayPorts yes/' /etc/ssh/sshd_config
    echo "[REMOTE] GatewayPorts set to yes (replaced existing directive)"
else
    echo "GatewayPorts yes" >> /etc/ssh/sshd_config
    echo "[REMOTE] GatewayPorts enabled"
fi

echo "[REMOTE] Validating sshd configuration..."
if ! sshd -t 2>/dev/null; then
    echo "[REMOTE] ERROR: sshd config validation failed. Rolling back..."
    if [[ -f "\$BACKUP_FILE" ]]; then cp "\$BACKUP_FILE" /etc/ssh/sshd_config; fi
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    echo "[REMOTE] Rolled back sshd_config to original"
    exit 1
fi

if sshd -T >/dev/null 2>&1; then
    if ! sshd -T 2>/dev/null | grep -qiE '^gatewayports[[:space:]]+yes'; then
        echo "[REMOTE] ERROR: GatewayPorts did not take effect. Rolling back..."
        if [[ -f "\$BACKUP_FILE" ]]; then cp "\$BACKUP_FILE" /etc/ssh/sshd_config; fi
        exit 1
    fi
    echo "[REMOTE] GatewayPorts verified via 'sshd -T'"
fi

if systemctl list-units --type=service 2>/dev/null | grep -q sshd.service; then
    systemctl restart sshd
elif systemctl list-units --type=service 2>/dev/null | grep -q ssh.service; then
    systemctl restart ssh
else
    echo "[REMOTE] WARNING: Could not find SSH service to restart"
fi
echo "[REMOTE] SSH service restarted successfully"

if [[ -n "\$OLD_TUNNEL_PORT" && "\$OLD_TUNNEL_PORT" != "\$TUNNEL_PORT" ]]; then
    echo "[REMOTE] Removing stale firewall rule for old port \${OLD_TUNNEL_PORT}..."
    if command -v firewall-cmd &>/dev/null; then
        firewall-cmd --remove-port="\${OLD_TUNNEL_PORT}/tcp" --permanent 2>/dev/null && firewall-cmd --reload 2>/dev/null || true
    fi
    if command -v ufw &>/dev/null; then
        ufw delete allow "\${OLD_TUNNEL_PORT}/tcp" 2>/dev/null || true
    fi
    if command -v iptables &>/dev/null; then
        iptables -D INPUT -p tcp --dport "\${OLD_TUNNEL_PORT}" -j ACCEPT 2>/dev/null || true
    fi
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
        $remoteScript | & ssh @sshOpts $Server "sudo bash -s" 2>&1 | ForEach-Object { Write-Host $_ }
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
        tunnelPort      = $TunnelPort
        socks5Port      = $Socks5Port
        sshPort         = $SshPort
        server          = $Server
        localUser       = $LocalUser
        localHost       = $LocalHost
        bypassLan       = $BypassLan
        noProxySubnets  = $BypassSubnets
        deployReverse   = $DeployReverse
        deploySocks5    = $DeploySocks5
        installedAt     = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    }
    $config | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    Info "Config file: $ConfigFile"

    # ---- SSH options ----
    $sshCommon = @(
        "-o", "ServerAliveInterval=30"
        "-o", "ServerAliveCountMax=3"
        "-o", "ExitOnForwardFailure=yes"
        "-o", "StrictHostKeyChecking=accept-new"
        # BatchMode=yes: the service must fail immediately when authentication
        # fails instead of hanging on a password prompt. NSSM would otherwise
        # still report SERVICE_RUNNING (a false positive).
        "-o", "BatchMode=yes"
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

        $rc = Invoke-NssmCommand @("install", $svcName, "ssh.exe")
        if ($rc -ne 0) {
            ErrorOut "nssm install failed for $svcName (exit code $rc)"
            exit 1
        }

        $rc = Invoke-NssmCommand @("set", $svcName, "AppParameters", ($sshArgs -join " "))
        if ($rc -ne 0) {
            ErrorOut "nssm set AppParameters failed for $svcName (exit code $rc)"
            ErrorOut "The service would not be able to start; aborting."
            exit 1
        }

        # Run the service as the real user who ran this installer, so the service
        # can read that user's SSH key under $env:USERPROFILE\.ssh (LocalSystem
        # would look in the system profile directory instead and find no key).
        # NOTE: `nssm set <svc> ObjectName <user>` may require the password on the
        # command line (<user> <password>). This project assumes the current user
        # with a passwordless key, so no password is passed here. A failure is a
        # warning (not fatal), but it must never be silent.
        $rc = Invoke-NssmCommand @("set", $svcName, "ObjectName", "$env:USERDOMAIN\$env:USERNAME")
        if ($rc -ne 0) {
            Warn "nssm set ObjectName failed for $svcName (exit code $rc)"
            Warn "The service may run as LocalSystem and fail to find your SSH key."
            Warn "Fix manually: nssm set $svcName ObjectName $env:USERDOMAIN\$env:USERNAME <password>"
        }

        $rc = Invoke-NssmCommand @("set", $svcName, "AppDirectory", "$env:USERPROFILE")
        if ($rc -ne 0) { Warn "nssm set AppDirectory failed for $svcName (exit code $rc)" }

        Invoke-NssmCommand @("set", $svcName, "DisplayName", $svcName) | Out-Null
        Invoke-NssmCommand @("set", $svcName, "Description", $desc) | Out-Null
        Invoke-NssmCommand @("set", $svcName, "Start", "SERVICE_AUTO_START") | Out-Null
        Invoke-NssmCommand @("set", $svcName, "AppRestartDelay", "10000") | Out-Null
        Invoke-NssmCommand @("set", $svcName, "AppStdout", "$ConfigDir\reverse-stdout.log") | Out-Null
        Invoke-NssmCommand @("set", $svcName, "AppStderr", "$ConfigDir\reverse-stderr.log") | Out-Null
        # Rotate the service logs so a reconnect storm cannot fill the disk.
        Invoke-NssmCommand @("set", $svcName, "AppRotateFiles", "1") | Out-Null
        Invoke-NssmCommand @("set", $svcName, "AppRotateBytes", "10485760") | Out-Null

        Info "Created service: $svcName"

        if ($redep -and ((Get-NssmOutput @("status", $svcName)) -match "SERVICE_RUNNING")) {
            $rc = Invoke-NssmCommand @("restart", $svcName)
            if ($rc -ne 0) { Warn "nssm restart failed for $svcName (exit code $rc)" }
            Info "Restarted: $svcName"
        } else {
            $rc = Invoke-NssmCommand @("start", $svcName)
            if ($rc -ne 0) { Warn "nssm start failed for $svcName (exit code $rc)" }
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

        $rc = Invoke-NssmCommand @("install", $svcName, "ssh.exe")
        if ($rc -ne 0) {
            ErrorOut "nssm install failed for $svcName (exit code $rc)"
            exit 1
        }

        $rc = Invoke-NssmCommand @("set", $svcName, "AppParameters", ($sshArgs -join " "))
        if ($rc -ne 0) {
            ErrorOut "nssm set AppParameters failed for $svcName (exit code $rc)"
            ErrorOut "The service would not be able to start; aborting."
            exit 1
        }

        # See the reverse-tunnel service above: run as the real user so the
        # service can read the user's SSH key, and never fail ObjectName silently.
        $rc = Invoke-NssmCommand @("set", $svcName, "ObjectName", "$env:USERDOMAIN\$env:USERNAME")
        if ($rc -ne 0) {
            Warn "nssm set ObjectName failed for $svcName (exit code $rc)"
            Warn "The service may run as LocalSystem and fail to find your SSH key."
            Warn "Fix manually: nssm set $svcName ObjectName $env:USERDOMAIN\$env:USERNAME <password>"
        }

        $rc = Invoke-NssmCommand @("set", $svcName, "AppDirectory", "$env:USERPROFILE")
        if ($rc -ne 0) { Warn "nssm set AppDirectory failed for $svcName (exit code $rc)" }

        Invoke-NssmCommand @("set", $svcName, "DisplayName", $svcName) | Out-Null
        Invoke-NssmCommand @("set", $svcName, "Description", $desc) | Out-Null
        Invoke-NssmCommand @("set", $svcName, "Start", "SERVICE_AUTO_START") | Out-Null
        Invoke-NssmCommand @("set", $svcName, "AppRestartDelay", "10000") | Out-Null
        Invoke-NssmCommand @("set", $svcName, "AppStdout", "$ConfigDir\socks5-stdout.log") | Out-Null
        Invoke-NssmCommand @("set", $svcName, "AppStderr", "$ConfigDir\socks5-stderr.log") | Out-Null
        # Rotate the service logs so a reconnect storm cannot fill the disk.
        Invoke-NssmCommand @("set", $svcName, "AppRotateFiles", "1") | Out-Null
        Invoke-NssmCommand @("set", $svcName, "AppRotateBytes", "10485760") | Out-Null

        Info "Created service: $svcName"

        if ($redep -and ((Get-NssmOutput @("status", $svcName)) -match "SERVICE_RUNNING")) {
            $rc = Invoke-NssmCommand @("restart", $svcName)
            if ($rc -ne 0) { Warn "nssm restart failed for $svcName (exit code $rc)" }
            Info "Restarted: $svcName"
        } else {
            $rc = Invoke-NssmCommand @("start", $svcName)
            if ($rc -ne 0) { Warn "nssm start failed for $svcName (exit code $rc)" }
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

    # ---- Deploy tunnel-proxy.ps1 control script ----
    Deploy-TunnelProxyScript
}

# ============================================
# NSSM helper functions
# ============================================
function Test-NssmService { param([string]$Name)
    $svcs = & $NssmExe list 2>$null
    return ($svcs -contains $Name)
}

# Run an nssm command with its output suppressed and return the exit code.
# $ErrorActionPreference = "Stop" would otherwise turn the stderr of a failing
# nssm command into a terminating error instead of a checkable exit code.
function Invoke-NssmCommand { param([string[]]$NssmArgs)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $NssmExe @NssmArgs 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
}

# Return the text output of an nssm command (used for `nssm status`).
function Get-NssmOutput { param([string[]]$NssmArgs)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        return (& $NssmExe @NssmArgs 2>&1 | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $prevEap
    }
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
# System proxy backup / restore / refresh
# ============================================
$ProxyBackupFile = "$ConfigDir\proxy-backup.json"

# Save the original proxy settings once. An existing snapshot is never
# overwritten, so the very first snapshot stays the reference for restore.
function Backup-SystemProxy {
    if (Test-Path $ProxyBackupFile) { return }
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
        $origServer = $null
        $origEnable = $null
        $origOverride = $null
        if ($props.PSObject.Properties.Name -contains "ProxyServer") { $origServer = $props.ProxyServer }
        if ($props.PSObject.Properties.Name -contains "ProxyEnable") { $origEnable = $props.ProxyEnable }
        if ($props.PSObject.Properties.Name -contains "ProxyOverride") { $origOverride = $props.ProxyOverride }

        $backup = @{
            ProxyServer   = $origServer
            ProxyEnable   = $origEnable
            ProxyOverride = $origOverride
        }
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        $backup | ConvertTo-Json | Set-Content -Path $ProxyBackupFile -Encoding UTF8
        Info "Backed up original system proxy settings to $ProxyBackupFile"
    } catch {
        Warn "Failed to back up system proxy settings: $_"
    }
}

# Restore the original proxy settings from the backup, then drop the backup file.
# Without a backup only ProxyEnable is turned off.
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
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
    Update-InternetSettings
    Info "System proxy disabled"
}

# Notify WinINET that Internet Settings changed, so running applications pick
# the new proxy up without a restart. Best effort: failures are ignored.
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
        # Ignore: refreshing WinINET is best effort only.
    }
}

# ============================================
# Set system SOCKS5 proxy (registry)
# ============================================
function Set-SystemProxy { param([int]$Port)
    Header "Setting Windows system proxy"
    try {
        Backup-SystemProxy
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        # WinINET needs a per-protocol list. A bare "host:port" would be treated
        # as an HTTP proxy for every protocol, but ssh -D only speaks SOCKS5.
        Set-ItemProperty -Path $regPath -Name ProxyServer -Value "socks=127.0.0.1:$Port" -ErrorAction Stop
        Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1 -ErrorAction Stop
        if ($BypassLan) {
            $override = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>"
            Set-ItemProperty -Path $regPath -Name ProxyOverride -Value $override -ErrorAction Stop
            Info "LAN bypass enabled (excluded from proxy)"
        } else {
            Set-ItemProperty -Path $regPath -Name ProxyOverride -Value "" -ErrorAction SilentlyContinue
        }
        Update-InternetSettings
        Info "System proxy set to SOCKS5 (socks=127.0.0.1:$Port)"
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

    # Match the exact marker and Host line, so unrelated entries that merely
    # mention "tunnel-proxy" are left untouched.
    $existing = ""
    if (Test-Path $SshConfigPath) {
        $existing = Get-Content $SshConfigPath -Raw
        if ($null -eq $existing) { $existing = "" }
    }

    $blockPattern = '(?ms)^# ssh-tunnel-proxy:[^\r\n]*\r?\n^Host tunnel-proxy[ \t]*\r?\n(?:[ \t]+[^\r\n]*\r?\n?)*'
    $hadEntry = $false
    if (($existing -match '(?m)^# ssh-tunnel-proxy:') -and ($existing -match '(?m)^Host tunnel-proxy[ \t]*\r?$')) {
        # Remove the old block first, then append the fresh one: idempotent update
        # that also refreshes the entry when server/port change.
        $hadEntry = $true
        $stripped = [regex]::Replace($existing, $blockPattern, '').TrimEnd()
        if ($stripped) { $stripped += "`r`n" }
        [IO.File]::WriteAllText($SshConfigPath, $stripped, (New-Object Text.UTF8Encoding($false)))
    }

    # Make sure the file ends with a newline before appending.
    if (Test-Path $SshConfigPath) {
        $current = [IO.File]::ReadAllText($SshConfigPath)
        if ($current.Length -gt 0 -and -not $current.EndsWith("`n")) {
            [IO.File]::AppendAllText($SshConfigPath, "`r`n", (New-Object Text.UTF8Encoding($false)))
        }
    }

    # UTF8Encoding($false) avoids the BOM that PS 5.1's `-Encoding UTF8` writes.
    [IO.File]::AppendAllText($SshConfigPath, $entry.TrimEnd() + "`r`n", (New-Object Text.UTF8Encoding($false)))
    if ($hadEntry) {
        Info "Updated SSH config entry: Host tunnel-proxy"
    } else {
        Info "Added SSH config entry: Host tunnel-proxy"
    }
    Info "  Connect with: ssh tunnel-proxy"
}

# ============================================
# Deploy tunnel-proxy.ps1 to a PATH-accessible location
# ============================================
function Deploy-TunnelProxyScript {
    $scriptDir = "$env:ProgramData\ssh-tunnel-proxy"
    if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null }

    $scriptPath = "$scriptDir\tunnel-proxy.ps1"

    # Try canonical source first. $PSScriptRoot is empty when this script is run
    # through `iwr ... | iex`, and Join-Path rejects an empty -Path: combined with
    # $ErrorActionPreference = "Stop" that used to abort before the fallback ran.
    $canonicalScript = $null
    if ($PSScriptRoot) { $canonicalScript = Join-Path $PSScriptRoot "scripts\tunnel-proxy.ps1" }

    if ($canonicalScript -and (Test-Path $canonicalScript)) {
        Copy-Item -Path $canonicalScript -Destination $scriptPath -Force
        Info "Installed tunnel-proxy from scripts\tunnel-proxy.ps1 (canonical source)"
    } else {
        # Fallback for standalone installs
        $scriptContent = @'
<#
.SYNOPSIS
    tunnel-proxy — Unified control for ssh-tunnel-proxy (Windows)
.DESCRIPTION
    Start, stop, or check status of SSH tunnel services.
    Also manages Windows system proxy settings.
.EXAMPLE
    .\tunnel-proxy.ps1 start
    .\tunnel-proxy.ps1 stop
    .\tunnel-proxy.ps1 status
.NOTES
    start/stop/restart require Administrator privileges; status does not.
#>

param([Parameter(Mandatory=$true)][ValidateSet("start","stop","status","restart")][string]$Action)

$ConfigDir = "$env:ProgramData\ssh-tunnel-proxy"
$ConfigFile = "$ConfigDir\tunnel.json"
$ProxyBackupFile = "$ConfigDir\proxy-backup.json"
$NssmExe = "$env:ProgramFiles\nssm\nssm.exe"
$ReverseService = "ssh-tunnel-reverse"
$Socks5Service = "ssh-tunnel-socks5"

$Socks5Port = 1080
$BypassLan = $true
$NoProxySubnets = "127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
# Deployment flags are read from tunnel.json. Config files written by older
# versions do not contain them, so default to "both deployed" (backward compatible).
$DeploySocks5 = $true
$DeployReverse = $true
if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.socks5Port) { $Socks5Port = $cfg.socks5Port }
        if ($cfg.PSObject.Properties.Name -contains "bypassLan") { $BypassLan = $cfg.bypassLan }
        if ($cfg.noProxySubnets) { $NoProxySubnets = $cfg.noProxySubnets }
        if ($cfg.PSObject.Properties.Name -contains "deploySocks5") { $DeploySocks5 = [bool]$cfg.deploySocks5 }
        if ($cfg.PSObject.Properties.Name -contains "deployReverse") { $DeployReverse = [bool]$cfg.deployReverse }
    } catch {}
}

$script:Failures = @()

function Info { Write-Host "[tunnel-proxy] $($args[0])" }
function Warn { Write-Host "[tunnel-proxy] WARNING: $($args[0])" -ForegroundColor Yellow }
function ErrorOut { Write-Host "[tunnel-proxy] ERROR: $($args[0])" -ForegroundColor Red }

function Check-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        ErrorOut "This action requires Administrator privileges."
        ErrorOut "Right-click PowerShell and select 'Run as administrator'."
        exit 1
    }
}

function Test-ServiceExists { param([string]$Name)
    if (Test-Path $NssmExe) {
        $svcs = & $NssmExe list 2>$null
        if ($svcs -contains $Name) { return $true }
    }
    return ($null -ne (Get-Service -Name $Name -ErrorAction SilentlyContinue))
}

# Start/stop one service and record failures instead of aborting mid-way.
function Invoke-NssmAction { param([string]$Verb, [string]$Name)
    if (-not (Test-Path $NssmExe)) {
        Warn "nssm not found at $NssmExe"
        $script:Failures += "$Verb $Name"
        return $false
    }
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & $NssmExe $Verb $Name 2>&1 | Out-Null
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEap
    }
    if ($code -ne 0) {
        Warn "nssm $Verb $Name failed (exit code $code)"
        $script:Failures += "$Verb $Name"
        return $false
    }
    return $true
}

function Update-InternetSettings {
    try {
        if (-not ("Win32.WinInet" -as [type])) {
            # Kept as a single-line string (no here-string) so this file can be
            # embedded verbatim in install.ps1's standalone fallback.
            $memberDef = '[DllImport("wininet.dll", SetLastError = true, CharSet = CharSet.Auto)] public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);'
            Add-Type -Namespace Win32 -Name WinInet -MemberDefinition $memberDef
        }
        # INTERNET_OPTION_SETTINGS_CHANGED = 39, INTERNET_OPTION_REFRESH = 37
        [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
        [void][Win32.WinInet]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
    } catch {
        # Best effort only; ignore failures.
    }
}

# Save the original proxy settings once; an existing snapshot is never overwritten.
function Backup-SystemProxy {
    if (Test-Path $ProxyBackupFile) { return }
    try {
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
        $props = Get-ItemProperty -Path $regPath -ErrorAction Stop
        $origServer = $null
        $origEnable = $null
        $origOverride = $null
        if ($props.PSObject.Properties.Name -contains "ProxyServer") { $origServer = $props.ProxyServer }
        if ($props.PSObject.Properties.Name -contains "ProxyEnable") { $origEnable = $props.ProxyEnable }
        if ($props.PSObject.Properties.Name -contains "ProxyOverride") { $origOverride = $props.ProxyOverride }

        $backup = @{
            ProxyServer   = $origServer
            ProxyEnable   = $origEnable
            ProxyOverride = $origOverride
        }
        if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir -Force | Out-Null }
        $backup | ConvertTo-Json | Set-Content -Path $ProxyBackupFile -Encoding UTF8
    } catch {
        Warn "Could not back up system proxy settings: $_"
    }
}

# Restore the original proxy settings from the backup, then drop the backup file.
# Without a backup only ProxyEnable is turned off.
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
            Warn "Could not restore system proxy settings: $_"
        }
    }
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
    Update-InternetSettings
    Info "System proxy disabled"
}

function Set-SystemProxy { param([int]$Port)
    Backup-SystemProxy
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    # WinINET needs a per-protocol list. A bare "host:port" would be treated as an
    # HTTP proxy for every protocol, but ssh -D only speaks SOCKS5.
    Set-ItemProperty -Path $regPath -Name ProxyServer -Value "socks=127.0.0.1:$Port" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1 -ErrorAction SilentlyContinue
    if ($BypassLan) {
        $override = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>"
        Set-ItemProperty -Path $regPath -Name ProxyOverride -Value $override -ErrorAction SilentlyContinue
    } else {
        Set-ItemProperty -Path $regPath -Name ProxyOverride -Value "" -ErrorAction SilentlyContinue
    }
    Update-InternetSettings
    Info "System proxy enabled (socks=127.0.0.1:$Port)"
}

switch ($Action) {
    "start" {
        Check-Admin
        Info "Starting services..."
        $startedSocks = $false

        if ($DeployReverse) {
            if (Test-ServiceExists $ReverseService) {
                [void](Invoke-NssmAction "start" $ReverseService)
            } else {
                Warn "$ReverseService is not installed"
            }
        }

        if ($DeploySocks5) {
            if (Test-ServiceExists $Socks5Service) {
                $startedSocks = Invoke-NssmAction "start" $Socks5Service
            } else {
                Warn "$Socks5Service is not installed"
            }
            # Only touch the system proxy when the SOCKS5 service actually started.
            if ($startedSocks) {
                Set-SystemProxy $Socks5Port
                if ($BypassLan) { Info "LAN bypass: $NoProxySubnets" }
            } else {
                Warn "SOCKS5 is not running - system proxy left unchanged"
            }
        } else {
            Info "SOCKS5 was not deployed (-OnlyReverse); system proxy left unchanged"
        }
    }
    "stop" {
        Check-Admin
        Info "Stopping services..."
        if (Test-ServiceExists $ReverseService) { [void](Invoke-NssmAction "stop" $ReverseService) }
        if (Test-ServiceExists $Socks5Service) { [void](Invoke-NssmAction "stop" $Socks5Service) }
        Info "Services stopped"
        Restore-SystemProxy
    }
    "restart" {
        Check-Admin
        Info "Restarting services..."
        if (Test-ServiceExists $ReverseService) { [void](Invoke-NssmAction "stop" $ReverseService) }
        if (Test-ServiceExists $Socks5Service) { [void](Invoke-NssmAction "stop" $Socks5Service) }
        Start-Sleep -Seconds 1

        $startedSocks = $false
        if ($DeployReverse) {
            if (Test-ServiceExists $ReverseService) {
                [void](Invoke-NssmAction "start" $ReverseService)
            } else {
                Warn "$ReverseService is not installed"
            }
        }

        if ($DeploySocks5) {
            if (Test-ServiceExists $Socks5Service) {
                $startedSocks = Invoke-NssmAction "start" $Socks5Service
            } else {
                Warn "$Socks5Service is not installed"
            }
            if ($startedSocks) {
                Set-SystemProxy $Socks5Port
                if ($BypassLan) { Info "LAN bypass: $NoProxySubnets" }
            } else {
                Warn "SOCKS5 is not running - system proxy left unchanged"
            }
        } else {
            Info "SOCKS5 was not deployed (-OnlyReverse); system proxy left unchanged"
        }
    }
    "status" {
        Write-Host "=== Reverse Tunnel ==="
        if (Test-Path $NssmExe) {
            $s = & $NssmExe status $ReverseService 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Host "  $s" } else { Write-Host "  (not installed)" }
        } else {
            Write-Host "  (nssm not found: $NssmExe)"
        }
        Write-Host ""
        Write-Host "=== SOCKS5 Proxy ==="
        if (Test-Path $NssmExe) {
            $s = & $NssmExe status $Socks5Service 2>$null
            if ($LASTEXITCODE -eq 0) { Write-Host "  $s" } else { Write-Host "  (not installed)" }
        } else {
            Write-Host "  (nssm not found: $NssmExe)"
        }
        Write-Host ""
        Write-Host "  Deployed: reverse=$DeployReverse socks5=$DeploySocks5"
        if ($BypassLan) {
            Write-Host ""
            Write-Host "=== LAN Bypass ==="
            Write-Host "  Subnets: $NoProxySubnets"
        }
    }
}

if ($script:Failures.Count -gt 0) {
    ErrorOut "failed operations: $($script:Failures -join ', ')"
    exit 1
}
'@
        Set-Content -Path $scriptPath -Value $scriptContent -Encoding UTF8
        Info "Deployed: $scriptPath (standalone install)"
    }

    # Add to PATH for current user if not already there
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$scriptDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$scriptDir", "User")
        $env:Path += ";$scriptDir"
        Info "Added $scriptDir to user PATH"
    }

    # .PS1 is not part of PATHEXT, so a bare `tunnel-proxy start` would not
    # resolve. Ship a tiny cmd shim so the documented command works as written.
    $cmdPath = Join-Path $scriptDir "tunnel-proxy.cmd"
    $cmdContent = "@echo off`r`npowershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0tunnel-proxy.ps1`" %*`r`n"
    Set-Content -Path $cmdPath -Value $cmdContent -Encoding ASCII
    Info "Installed command shim: $cmdPath"

    Info "  Usage: tunnel-proxy {start|stop|status|restart}"
}

# ============================================
# Verify services
# ============================================
function Verify-Services {
    Header "Verifying services"

    $ok = $true

    if ($DeployReverse) {
        $status = Get-NssmOutput @("status", "ssh-tunnel-reverse")
        if ($status -match "SERVICE_RUNNING") {
            Info "ssh-tunnel-reverse: running"
        } else {
            Warn "ssh-tunnel-reverse: $status"
            Warn "  See log: $ConfigDir\reverse-stderr.log"
            $ok = $false
        }
    }

    if ($DeploySocks5) {
        $status = Get-NssmOutput @("status", "ssh-tunnel-socks5")
        if ($status -match "SERVICE_RUNNING") {
            Info "ssh-tunnel-socks5: running"
        } else {
            Warn "ssh-tunnel-socks5: $status"
            Warn "  See log: $ConfigDir\socks5-stderr.log"
            $ok = $false
        }
    }

    return $ok
}

# ============================================
# Print usage instructions
# ============================================
function Print-Instructions {
    Header "Installation Complete"
    $serverJump = if ($SshPort -ne 22) { "$($Server):$SshPort" } else { $Server }

    if ($DeployReverse) {
        Write-Host "`n  Access this machine from other devices:" -ForegroundColor Yellow
        Write-Host "    ssh -J ${serverJump} ${LocalUser}@localhost -p ${TunnelPort}"
        Write-Host "    ssh tunnel-proxy"
    }

    if ($DeploySocks5) {
        Write-Host "`n  Test internet access via SOCKS5 proxy:" -ForegroundColor Yellow
        Write-Host "    curl --socks5-hostname 127.0.0.1:${Socks5Port} https://www.google.com"
        Write-Host "`n  System proxy set to socks=127.0.0.1:${Socks5Port}" -ForegroundColor Yellow
    }

    if ($BypassLan) {
        Write-Host "`n  LAN bypass:" -ForegroundColor Yellow
        Write-Host "    Local subnets excluded from proxy: $BypassSubnets" -ForegroundColor Yellow
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
    $servicesOk = Verify-Services
    Print-Instructions

    if (-not $servicesOk) {
        ErrorOut "One or more services are not running (see the warnings above)."
        ErrorOut "Check the logs in $ConfigDir, then run: tunnel-proxy restart"
        Log "=== ssh-tunnel-proxy installer finished with errors ==="
        exit 1
    }

    Log "=== ssh-tunnel-proxy installer finished ==="
}

Main
