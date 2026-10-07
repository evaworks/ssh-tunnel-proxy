<#
.SYNOPSIS
    ssh-tunnel-proxy local setup for Windows
.DESCRIPTION
    Configure reverse tunnel and SOCKS5 proxy on the local machine using NSSM.
    Normally called by install.ps1, but can be run standalone.
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
.NOTES
    Requires Administrator privileges (it creates Windows services).
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [int]$TunnelPort = 2222,
    [int]$Socks5Port = 1080,
    [int]$SshPort = 22,
    [switch]$OnlyReverse,
    [switch]$OnlySocks5,
    [switch]$NoBypassLan
)

$ErrorActionPreference = "Stop"

$ConfigDir = "$env:ProgramData\ssh-tunnel-proxy"
$ConfigFile = "$ConfigDir\tunnel.json"
$ProxyBackupFile = "$ConfigDir\proxy-backup.json"
$NssmDir = "$env:ProgramFiles\nssm"
$NssmExe = "$NssmDir\nssm.exe"
$SshConfigPath = "$env:USERPROFILE\.ssh\config"
$LocalUser = [Environment]::UserName
$LocalHost = [Environment]::MachineName
$DeployReverse = -not $OnlySocks5
$DeploySocks5 = -not $OnlyReverse
$BypassLan = -not $NoBypassLan
$BypassSubnets = "127.0.0.0/8,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
$ReverseService = "ssh-tunnel-reverse"
$Socks5Service = "ssh-tunnel-socks5"

function Info { Write-Host "[local-setup] $($args[0])" -ForegroundColor Green }
function Warn { Write-Host "[local-setup] WARNING: $($args[0])" -ForegroundColor Yellow }
function ErrorOut { Write-Host "[local-setup] ERROR: $($args[0])" -ForegroundColor Red }

function Check-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        ErrorOut "This script must be run as Administrator."
        ErrorOut "Right-click PowerShell and select 'Run as administrator'."
        exit 1
    }
}

# -OnlyReverse and -OnlySocks5 together would deploy nothing; fail loudly instead.
if ($OnlyReverse -and $OnlySocks5) {
    ErrorOut "-OnlyReverse and -OnlySocks5 cannot be used together"
    exit 1
}

Check-Admin

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
        $rc = Invoke-NssmCommand @("stop", $Name)
        if ($rc -ne 0) { Warn "nssm stop $Name failed (exit code $rc)" }
        Start-Sleep -Seconds 1
        $rc = Invoke-NssmCommand @("remove", $Name, "confirm")
        if ($rc -ne 0) { Warn "nssm remove $Name failed (exit code $rc)" }
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
        Info "Backed up original system proxy settings to $ProxyBackupFile"
    } catch {
        Warn "Failed to back up system proxy settings: $_"
    }
}

function Set-SystemProxy { param([int]$Port)
    Backup-SystemProxy
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    # WinINET needs a per-protocol list: ssh -D only provides SOCKS5, so a bare
    # "host:port" would wrongly be treated as an HTTP proxy for all protocols.
    Set-ItemProperty -Path $regPath -Name ProxyServer -Value "socks=127.0.0.1:$Port" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1 -ErrorAction SilentlyContinue
    if ($BypassLan) {
        $override = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>"
        Set-ItemProperty -Path $regPath -Name ProxyOverride -Value $override -ErrorAction SilentlyContinue
        Info "LAN bypass enabled (excluded from proxy)"
    } else {
        Set-ItemProperty -Path $regPath -Name ProxyOverride -Value "" -ErrorAction SilentlyContinue
    }
    Update-InternetSettings
    Info "System proxy set to SOCKS5 (socks=127.0.0.1:$Port)"
}

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

function Deploy-TunnelProxyScript {
    $scriptDir = "$env:ProgramData\ssh-tunnel-proxy"
    if (-not (Test-Path $scriptDir)) { New-Item -ItemType Directory -Path $scriptDir -Force | Out-Null }

    $scriptPath = "$scriptDir\tunnel-proxy.ps1"

    # $PSScriptRoot is empty when run through `iwr ... | iex`, and Join-Path
    # rejects an empty -Path (which would throw under $ErrorActionPreference="Stop").
    $canonicalScript = $null
    if ($PSScriptRoot) { $canonicalScript = Join-Path $PSScriptRoot "tunnel-proxy.ps1" }

    if ($canonicalScript -and (Test-Path $canonicalScript)) {
        Copy-Item -Path $canonicalScript -Destination $scriptPath -Force
        Info "Installed tunnel-proxy from $canonicalScript"
    } elseif (Test-Path $scriptPath) {
        Info "Keeping existing tunnel-proxy.ps1"
    } else {
        Warn "Could not locate tunnel-proxy.ps1; run install.ps1 to deploy it"
    }

    # Add to PATH for current user if not already there
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$scriptDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$scriptDir", "User")
        $env:Path += ";$scriptDir"
        Info "Added $scriptDir to user PATH"
    }
}

# ---- Detect re-deployment ----
$redep = Test-Path $ConfigDir
if ($redep) {
    Info "Existing installation detected"

    if (-not $DeployReverse) {
        Remove-NssmService $ReverseService
        Info "Removed: $ReverseService"
    }
    if (-not $DeploySocks5) {
        Remove-NssmService $Socks5Service
        Info "Removed: $Socks5Service"
    }
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
Info "Config: $ConfigFile"

# ---- SSH options ----
$sshCommon = @(
    "-o", "ServerAliveInterval=30"
    "-o", "ServerAliveCountMax=3"
    "-o", "ExitOnForwardFailure=yes"
    "-o", "StrictHostKeyChecking=accept-new"
    # BatchMode=yes: fail immediately instead of hanging on a password prompt, so
    # NSSM does not report SERVICE_RUNNING for a service that never authenticated.
    "-o", "BatchMode=yes"
)
if ($SshPort -ne 22) {
    $sshCommon += "-p"; $sshCommon += "$SshPort"
}

# ---- Reverse tunnel service (NSSM) ----
if ($DeployReverse) {
    $svcName = $ReverseService
    $sshArgs = $sshCommon + @("-N", "-R", "${TunnelPort}:localhost:22", $Server)
    $desc = "ssh-tunnel-proxy: reverse tunnel (port ${TunnelPort})"

    if (Test-NssmService $svcName) {
        $rc = Invoke-NssmCommand @("stop", $svcName)
        if ($rc -ne 0) { Warn "nssm stop $svcName failed (exit code $rc)" }
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

    # Run the service as the real user so it can read that user's SSH key under
    # $env:USERPROFILE\.ssh. NSSM may need the password on the command line for
    # `nssm set <svc> ObjectName <user> <password>`; this project assumes the
    # current user with a passwordless key. Report a failure instead of hiding it.
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
    Info "Created: $svcName"

    if ($redep -and ((Get-NssmOutput @("status", $svcName)) -match "SERVICE_RUNNING")) {
        $rc = Invoke-NssmCommand @("restart", $svcName)
        if ($rc -ne 0) { Warn "nssm restart $svcName failed (exit code $rc)" }
        Info "Restarted: $svcName"
    } else {
        $rc = Invoke-NssmCommand @("start", $svcName)
        if ($rc -ne 0) { Warn "nssm start $svcName failed (exit code $rc)" }
        Info "Started: $svcName"
    }
}

# ---- SOCKS5 proxy service (NSSM) ----
if ($DeploySocks5) {
    $svcName = $Socks5Service
    $sshArgs = $sshCommon + @("-N", "-D", "${Socks5Port}", $Server)
    $desc = "ssh-tunnel-proxy: SOCKS5 proxy (port ${Socks5Port})"

    if (Test-NssmService $svcName) {
        $rc = Invoke-NssmCommand @("stop", $svcName)
        if ($rc -ne 0) { Warn "nssm stop $svcName failed (exit code $rc)" }
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

    # See the reverse-tunnel service above.
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
    Info "Created: $svcName"

    if ($redep -and ((Get-NssmOutput @("status", $svcName)) -match "SERVICE_RUNNING")) {
        $rc = Invoke-NssmCommand @("restart", $svcName)
        if ($rc -ne 0) { Warn "nssm restart $svcName failed (exit code $rc)" }
        Info "Restarted: $svcName"
    } else {
        $rc = Invoke-NssmCommand @("start", $svcName)
        if ($rc -ne 0) { Warn "nssm start $svcName failed (exit code $rc)" }
        Info "Started: $svcName"
    }

    # ---- Set system proxy in registry ----
    Set-SystemProxy $Socks5Port
}

# ---- SSH config for easy access ----
if ($DeployReverse) {
    Add-SshConfig
}

# ---- Deploy tunnel-proxy.ps1 control script ----
Deploy-TunnelProxyScript

Info "Complete"
