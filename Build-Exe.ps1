<#
.SYNOPSIS
    Compiles Extractor-GUI.ps1 into Extractor.exe.

.DESCRIPTION
    Uses the ps2exe module. Run this from the folder that holds
    Extractor-GUI.ps1:

        powershell -ExecutionPolicy Bypass -File .\Build-Exe.ps1

    It will install the ps2exe module for your user if it isn't already
    present (needs internet the first time), then build Extractor.exe next
    to the script with no console window. If an app.ico sits next to the
    script it's embedded as the exe icon.

    You do NOT have to compile - you can just run Extractor-GUI.ps1 directly.
    Compiling only matters if you want a double-clickable .exe.
#>

[CmdletBinding()]
param(
    [string]$Source = '',
    [string]$Output = '',
    [string]$Icon   = ''
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 leaves $PSScriptRoot empty while param() defaults are
# evaluated, so work out the script's folder here instead.
$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($here) -and $MyInvocation.MyCommand.Path) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if ([string]::IsNullOrWhiteSpace($here)) { $here = (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($Source)) { $Source = Join-Path $here 'Extractor-GUI.ps1' }
if ([string]::IsNullOrWhiteSpace($Output)) { $Output = Join-Path $here 'Extractor.exe' }
if ([string]::IsNullOrWhiteSpace($Icon)) {
    $Icon = Join-Path $here 'app.ico'
    $legacy = Join-Path $here 'sonic-the-hedgehog-1.ico'
    if (-not (Test-Path -LiteralPath $Icon) -and (Test-Path -LiteralPath $legacy)) { $Icon = $legacy }
}

Write-Host "Episode Extractor - build to .exe" -ForegroundColor Cyan
Write-Host "  Source: $Source"
Write-Host "  Output: $Output"
Write-Host "  Icon  : $Icon"
Write-Host ""

if (-not (Test-Path -LiteralPath $Source)) {
    Write-Error "Can't find the source script: $Source"
    return
}
if (-not (Test-Path -LiteralPath $Icon)) {
    Write-Warning "Icon not found at $Icon - the exe will be built without a custom icon."
    $Icon = $null
}

# --- make sure ps2exe is available ---
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "Installing the ps2exe module for the current user..." -ForegroundColor Yellow
    # PS 5.1 defaults to old TLS, which the PowerShell Gallery rejects
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
    try {
        if (-not (Get-PackageProvider -ListAvailable -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
        }
    } catch { }
    try {
        Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber
    } catch {
        Write-Error "Could not install ps2exe automatically: $($_.Exception.Message)`nInstall it manually with:  Install-Module ps2exe -Scope CurrentUser"
        return
    }
}
Import-Module ps2exe

# --- build ---
$opts = @{
    inputFile  = $Source
    outputFile = $Output
    noConsole  = $true
    STA        = $true      # WPF window needs a single-threaded apartment
    title      = 'Episode Extractor'
    product    = 'Episode Extractor'
    description= 'Multi-part RAR episode extractor'
}
if ($Icon) { $opts['iconFile'] = $Icon }

Write-Host "Compiling..." -ForegroundColor Yellow
Invoke-ps2exe @opts

if (Test-Path -LiteralPath $Output) {
    Write-Host "`nDone -> $Output" -ForegroundColor Green
} else {
    Write-Error "Build finished but $Output was not created."
}
