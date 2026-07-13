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
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Server,
    [int]$TunnelPort = 2222,
    [int]$Socks5Port = 1080,
    [int]$SshPort = 22,
    [switch]$OnlyReverse,
    [switch]$OnlySocks5
)

$ErrorActionPreference = "Stop"

$ConfigDir = "$env:ProgramData\ssh-tunnel-proxy"
$ConfigFile = "$ConfigDir\tunnel.json"
$NssmDir = "$env:ProgramFiles\nssm"
$NssmExe = "$NssmDir\nssm.exe"
$LocalUser = [Environment]::UserName
$LocalHost = [Environment]::MachineName
$DeployReverse = -not $OnlySocks5
$DeploySocks5 = -not $OnlyReverse

function Info { Write-Host "[local-setup] $($args[0])" -ForegroundColor Green }
function Warn { Write-Host "[local-setup] WARNING: $($args[0])" -ForegroundColor Yellow }

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
    }
}

# ---- Detect re-deployment ----
$redep = Test-Path $ConfigDir
if ($redep) {
    Info "Existing installation detected"

    if (-not $DeployReverse) {
        Remove-NssmService "ssh-tunnel-reverse"
        Info "Removed: ssh-tunnel-reverse"
    }
    if (-not $DeploySocks5) {
        Remove-NssmService "ssh-tunnel-socks5"
        Info "Removed: ssh-tunnel-socks5"
    }
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
Info "Config: $ConfigFile"

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
    Info "Created: $svcName"

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
    Info "Created: $svcName"

    if ($redep -and (& $NssmExe status $svcName 2>$null) -match "SERVICE_RUNNING") {
        & $NssmExe restart $svcName 2>&1 | Out-Null
        Info "Restarted: $svcName"
    } else {
        & $NssmExe start $svcName 2>&1 | Out-Null
        Info "Started: $svcName"
    }
}

Info "Complete"
