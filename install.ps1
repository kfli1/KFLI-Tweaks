#Requires -Version 5.1
<#
  PULSE | Gaming Tweak - Installer / Bootstrap
  --------------------------------------------
  This tiny script is the one meant to be run with:
      iwr -useb https://raw.githubusercontent.com/<user>/<repo>/main/install.ps1 | iex

  Why this file exists:
  The main script (KFLI_Gaming_Tweak.ps1) relies on $PSCommandPath to know its
  own location on disk (needed to relaunch itself elevated as Administrator).
  When code is piped into `iex`, there is no file on disk, so $PSCommandPath is
  empty and the main script would refuse to run.

  This installer downloads the real script to a local folder first, then runs
  it as an actual .ps1 file, so everything (elevation, restart, logo, log and
  backup files) works exactly as if the user had downloaded it manually.
#>

$ErrorActionPreference = 'Stop'

# --- EDIT THIS to match your repo ------------------------------------------
$RepoRawUrl = 'https://raw.githubusercontent.com/<user>/<repo>/main/KFLI_Gaming_Tweak.ps1'
# -----------------------------------------------------------------------------

try {
    $InstallDir = Join-Path $env:LOCALAPPDATA 'PULSE'
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    $Dest = Join-Path $InstallDir 'KFLI_Gaming_Tweak.ps1'

    Write-Host 'PULSE : downloading the latest version...' -ForegroundColor Cyan

    # TLS 1.2 for older Windows PowerShell 5.1 hosts
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    Invoke-WebRequest -Uri $RepoRawUrl -UseBasicParsing -OutFile $Dest

    if (-not (Test-Path -LiteralPath $Dest)) {
        throw 'Download finished but the file was not found on disk.'
    }

    # Downloaded via the network - clear the "Zone.Identifier" block so it runs cleanly
    Unblock-File -LiteralPath $Dest -ErrorAction SilentlyContinue

    Write-Host 'PULSE : launching...' -ForegroundColor Cyan

    # Run it as a real file (not dot-sourced / not iex) so $PSCommandPath is set
    # correctly inside it, which the script needs for self-elevation.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Dest
}
catch {
    Write-Host ('PULSE : install failed - ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
