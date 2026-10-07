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
