<#
.SYNOPSIS
    Static validation for the Windows scripts in this repository.

.DESCRIPTION
    Parses every PowerShell file with the language parser (works on Windows
    PowerShell 5.1 and PowerShell 7+) and optionally runs PSScriptAnalyzer
    when it is installed. Exits with a non-zero status when anything fails.

.EXAMPLE
    pwsh -NoProfile -File tests/windows-parse.ps1
#>

$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
if (-not $root) { $root = (Get-Location).Path }

$files = @(
    (Join-Path $root "install.ps1"),
    (Join-Path $root "uninstall.ps1"),
    (Join-Path $root "scripts\tunnel-proxy.ps1"),
    (Join-Path $root "scripts\local-setup.ps1")
)

$failed = $false

foreach ($file in $files) {
    if (-not (Test-Path $file)) {
        Write-Host "MISSING $file"
        $failed = $true
        continue
    }

    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$tokens, [ref]$errors)

    if ($errors -and $errors.Count -gt 0) {
        $failed = $true
        foreach ($e in $errors) {
            Write-Host ("ERROR {0}:{1}: {2}" -f $file, $e.Extent.StartLineNumber, $e.Message)
        }
    } else {
        Write-Host "OK    $file"
    }
}

# Optional: stricter checks when PSScriptAnalyzer is available.
if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer
    foreach ($file in $files) {
        $issues = Invoke-ScriptAnalyzer -Path $file -Severity Error
        foreach ($i in $issues) {
            Write-Host ("ANALYZER {0}:{1}: {2}" -f $file, $i.Line, $i.Message)
            $failed = $true
        }
    }
} else {
    Write-Host "NOTE  PSScriptAnalyzer not installed; skipped (Install-Module PSScriptAnalyzer)"
}

if ($failed) {
    Write-Host "PowerShell validation FAILED"
    exit 1
}

Write-Host "All PowerShell scripts parsed successfully."
