#Requires -Version 5.1
<#
.SYNOPSIS
    Health check for a dsh-oneclick install: pinned versions, purge patch count,
    disabled auto-update, profile composition, GUI port.
.OUTPUTS
    exit 0 = healthy, 2 = drift/warnings, 1 = broken
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'dsh-oneclick'),
    [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
    [int]$GuiPort = 19387
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($Root)
$dshHome = [IO.Path]::GetFullPath($DshHome)
$script:issues = 0
$script:warns = 0

function Head($t) { Write-Host "`n$t" -ForegroundColor Cyan }
function Pass($t) { Write-Host "  [ok] $t" -ForegroundColor Green }
function Warn($t) { $script:warns++; Write-Host "  [!!] $t" -ForegroundColor Yellow }
function Bad($t) { $script:issues++; Write-Host "  [xx] $t" -ForegroundColor Red }

$lockPath = Join-Path $dshHome '.lock\versions.json'
$lock = $null
if (Test-Path $lockPath) { $lock = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json }
if (-not $lock) { Bad "no version lock at $lockPath (install incomplete)" }

Head 'versions'
$pkg = Join-Path $root 'npm\node_modules\@deepseek-ai\dsh\package.json'
$have = if (Test-Path $pkg) { (Get-Content $pkg -Raw -Encoding UTF8 | ConvertFrom-Json).version } else { $null }
if (-not $have) { Bad 'dsh package missing' }
elseif ($lock -and $have -ne $lock.pinned.dsh) { Warn "dsh $have != pinned $($lock.pinned.dsh) (run dsh-lock.cmd --repair)" }
else { Pass "dsh $have (pinned)" }

$purgePkg = Join-Path $root 'npm\node_modules\dsh-purge\package.json'
$purgeVer = if (Test-Path $purgePkg) { (Get-Content $purgePkg -Raw -Encoding UTF8 | ConvertFrom-Json).version } else { $null }
if (-not $purgeVer) { Bad 'dsh-purge missing' }
elseif ($lock -and $purgeVer -ne $lock.pinned.dshPurge) { Warn "dsh-purge $purgeVer != pinned $($lock.pinned.dshPurge)" }
else { Pass "dsh-purge $purgeVer (pinned)" }

$nodeExe = Join-Path $root 'node\node.exe'
if (Test-Path $nodeExe) {
    $nv = (& $nodeExe -v) -replace '^v', ''
    if ($lock -and $nv -ne $lock.pinned.node) { Warn "node $nv != pinned $($lock.pinned.node)" } else { Pass "node $nv" }
} else { Bad 'node runtime missing' }

Head 'purge patches'
$purgeCmd = Join-Path $root 'npm\dsh-purge.cmd'
if (Test-Path $purgeCmd) {
    $st = & $purgeCmd 2>&1 | Out-String
    $rev = ([regex]::Match($st, 'apply:(\S+)')).Groups[1].Value
    $applied = ([regex]::Matches($st, 'applied')).Count
    $pending = ([regex]::Match($st, '(\d+)\s*待清洗')).Groups[1].Value
    $pendingText = if ($pending -and [int]$pending -gt 0) { ", $pending pending" } else { '' }
    if ($rev) { Pass "state $rev, $applied applied$pendingText" } else { Warn 'purge state not readable' }
    if ($pending -and [int]$pending -gt 0) { Warn "$pending patches pending -> run dsh-purge --apply" }
} else { Bad 'dsh-purge shim missing' }

Head 'anti-upgrade'
if ($lock -and $lock.upgrades.desktop -eq 'disabled') { Pass 'manifest records desktop updates disabled' } else { Warn 'manifest does not record update policy' }
$desktopDir = if ($lock -and $lock.paths.desktopDir) { $lock.paths.desktopDir } else { '' }
if ($desktopDir) {
    $res = Join-Path $desktopDir 'resources'
    if ((Test-Path (Join-Path $res 'app-update.yml.disabled')) -and -not (Test-Path (Join-Path $res 'app-update.yml'))) {
        Pass 'desktop app-update.yml disabled'
    } elseif (Test-Path (Join-Path $res 'app-update.yml')) {
        Warn 'desktop auto-update still active (app-update.yml present)'
    } elseif (-not (Test-Path $res)) {
        Warn "desktop dir recorded but missing: $desktopDir"
    }
} else { Write-Host '  (cli mode - no desktop shell)' -ForegroundColor DarkGray }

Head 'dsh home'
foreach ($f in 'prompt-inject.md', 'profiles\desktop\cordis.yml', 'profiles\desktop\cordis.patch.yml', 'profiles\desktop\package.json') {
    if (Test-Path (Join-Path $dshHome $f)) { Pass $f } else { Bad "missing $f" }
}
$vendor = Join-Path $dshHome 'profiles\desktop\vendor\dsh-purge\package.json'
if (Test-Path $vendor) { Pass 'purge vendored in profile' } else { Warn 'purge vendor missing (falling back to global dsh-purge)' }

Head 'profile composition'
$dshCmd = Join-Path $root 'npm\dsh.cmd'
if (Test-Path $dshCmd) {
    $dump = & $dshCmd --profile desktop --dump-config 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $dump.Length -gt 200) { Pass 'dump-config ok' } else { Bad 'dump-config failed (run: dsh --profile desktop --dump-config)' }
} else { Bad 'dsh shim missing' }

Head 'gui'
$conn = Get-NetTCPConnection -LocalPort $GuiPort -State Listen -ErrorAction SilentlyContinue
if ($conn) { Pass "something is listening on 127.0.0.1:$GuiPort" } else { Warn "nothing listening on $GuiPort (start the app first)" }

Write-Host ''
if ($script:issues -gt 0) { Write-Host "  RESULT: $($script:issues) error(s), $($script:warns) warning(s)" -ForegroundColor Red; exit 1 }
elseif ($script:warns -gt 0) { Write-Host "  RESULT: healthy with $($script:warns) warning(s)" -ForegroundColor Yellow; exit 2 }
else { Write-Host '  RESULT: healthy' -ForegroundColor Green; exit 0 }
