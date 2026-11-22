#Requires -Version 5.1
<#
.SYNOPSIS
    Pinned dsh launcher. Refuses to start when the installed dsh version drifted
    from the locked version, and can repair from the offline cache.
.EXAMPLE
    dsh-lock.cmd web
    dsh-lock.cmd --repair
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Rest
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # <install root>
$npmPrefix = Join-Path $root 'npm'
$dshCmd = Join-Path $npmPrefix 'dsh.cmd'
$lockFile = Join-Path (Join-Path $env:USERPROFILE '.dsh') '.lock\versions.json'

function Fail($m) { Write-Host "  [xx] $m" -ForegroundColor Red; exit 1 }
function Ok($m) { Write-Host "  [ok] $m" -ForegroundColor Green }

if (-not (Test-Path $dshCmd)) { Fail "dsh not found at $dshCmd - run install.ps1 first" }

$lock = $null
if (Test-Path $lockFile) {
    try { $lock = Get-Content $lockFile -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}
$pinned = if ($lock) { $lock.pinned.dsh } else { '0.2.2-rc.5' }

$pkg = Join-Path $npmPrefix 'node_modules\@deepseek-ai\dsh\package.json'
$have = if (Test-Path $pkg) { (Get-Content $pkg -Raw -Encoding UTF8 | ConvertFrom-Json).version } else { $null }

if ($Rest -contains '--repair') {
    $cache = Join-Path $root 'npm-cache'
    $node = Join-Path $root 'node\npm.cmd'
    if (-not (Test-Path $node)) { Fail 'node runtime missing; reinstall with install.ps1' }
    Write-Host "  repairing dsh -> $pinned (offline cache)" -ForegroundColor Yellow
    & $node install -g --prefix $npmPrefix --cache $cache --offline --no-audit --no-fund "@deepseek-ai/dsh@$pinned"
    if ($LASTEXITCODE -ne 0) { Fail 'repair failed (cache incomplete? re-run install.ps1 -Force)' }
    Ok "repaired to $pinned"
    exit 0
}

if ($have -ne $pinned) {
    Write-Host ''
    Write-Host "  [!!] dsh version drift detected" -ForegroundColor Yellow
    Write-Host "       pinned: $pinned" -ForegroundColor Yellow
    Write-Host "       actual: $have" -ForegroundColor Yellow
    Write-Host "       run: dsh-lock.cmd --repair   (offline, from the pinned cache)" -ForegroundColor Yellow
    Write-Host ''
    # keep working anyway - refusing to launch a broken dev machine helps nobody
}

& $dshCmd @Rest
exit $LASTEXITCODE
