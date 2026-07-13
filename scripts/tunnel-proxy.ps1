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
#>

param([Parameter(Mandatory=$true)][ValidateSet("start","stop","status","restart")][string]$Action)

$ConfigDir = "$env:ProgramData\ssh-tunnel-proxy"
$ConfigFile = "$ConfigDir\tunnel.json"
$NssmExe = "$env:ProgramFiles\nssm\nssm.exe"

$Socks5Port = 1080
if (Test-Path $ConfigFile) {
    try {
        $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($cfg.socks5Port) { $Socks5Port = $cfg.socks5Port }
    } catch {}
}

function Set-SystemProxy { param([int]$Port)
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty -Path $regPath -Name ProxyServer -Value "127.0.0.1:$Port" -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 1 -ErrorAction SilentlyContinue
    Write-Host "[tunnel-proxy] System proxy enabled (127.0.0.1:$Port)"
}

function Clear-SystemProxy {
    $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
    Set-ItemProperty -Path $regPath -Name ProxyEnable -Value 0 -ErrorAction SilentlyContinue
    Write-Host "[tunnel-proxy] System proxy disabled"
}

switch ($Action) {
    "start" {
        Write-Host "[tunnel-proxy] Starting services..."
        & $NssmExe start ssh-tunnel-reverse 2>$null
        & $NssmExe start ssh-tunnel-socks5 2>$null
        Write-Host "[tunnel-proxy] Services started"
        Set-SystemProxy $Socks5Port
    }
    "stop" {
        Write-Host "[tunnel-proxy] Stopping services..."
        & $NssmExe stop ssh-tunnel-reverse 2>$null
        & $NssmExe stop ssh-tunnel-socks5 2>$null
        Write-Host "[tunnel-proxy] Services stopped"
        Clear-SystemProxy
    }
    "restart" {
        & $NssmExe stop ssh-tunnel-reverse 2>$null
        & $NssmExe stop ssh-tunnel-socks5 2>$null
        Start-Sleep -Seconds 1
        & $NssmExe start ssh-tunnel-reverse 2>$null
        & $NssmExe start ssh-tunnel-socks5 2>$null
        Write-Host "[tunnel-proxy] Services restarted"
        Set-SystemProxy $Socks5Port
    }
    "status" {
        Write-Host "=== Reverse Tunnel ==="
        $s = & $NssmExe status ssh-tunnel-reverse 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "  $s" } else { Write-Host "  (not installed)" }
        Write-Host ""
        Write-Host "=== SOCKS5 Proxy ==="
        $s = & $NssmExe status ssh-tunnel-socks5 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "  $s" } else { Write-Host "  (not installed)" }
    }
}
