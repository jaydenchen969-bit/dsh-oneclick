# dsh-oneclick · Windows one-line bootstrap
#   irm https://raw.githubusercontent.com/jaydenchen969-bit/dsh-oneclick/main/bootstrap.ps1 | iex
# With options:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/jaydenchen969-bit/dsh-oneclick/main/bootstrap.ps1))) -Mode cli
#
# Downloads the repo archive, then runs install.ps1 (release assets are fetched
# by the installer itself).

[CmdletBinding()]
param(
    [string]$Repo = 'jaydenchen969-bit/dsh-oneclick',
    [string]$Branch = 'main',
    [ValidateSet('desktop', 'cli')][string]$Mode = 'desktop',
    [switch]$Offline,
    [switch]$Force,
    [switch]$DryRun,
    [string]$Assets = ''
)

$ErrorActionPreference = 'Stop'
$progressPreference = 'SilentlyContinue'
Write-Host "`n  dsh-oneclick bootstrap ($Repo@$Branch)`n" -ForegroundColor Cyan

$tmp = Join-Path $env:TEMP ("dsh-oneclick-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$zip = Join-Path $tmp 'repo.zip'
$url = "https://github.com/$Repo/archive/refs/heads/$Branch.zip"
Write-Host "  downloading $url" -ForegroundColor Gray
try {
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -TimeoutSec 300
} catch {
    Write-Host "  download failed: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$repoDir = Get-ChildItem $tmp -Directory | Select-Object -First 1
if (-not $repoDir) { Write-Host '  archive layout unexpected' -ForegroundColor Red; exit 1 }

$installer = Join-Path $repoDir.FullName 'install.ps1'
if (-not (Test-Path $installer)) { Write-Host "  install.ps1 missing in archive" -ForegroundColor Red; exit 1 }

$fwd = @{ Mode = $Mode }
if ($Offline) { $fwd.Offline = $true }
if ($Force) { $fwd.Force = $true }
if ($DryRun) { $fwd.DryRun = $true }
if ($Assets) { $fwd.Assets = $Assets }

& $installer @fwd
exit $LASTEXITCODE
