#Requires -Version 5.1
<#
.SYNOPSIS
    Remove a dsh-oneclick install: PATH entries, user env vars, pinned launcher
    and install root. Keeps ~/.dsh data and backups unless -PurgeData is given.
.EXAMPLE
    .\uninstall.ps1
    .\uninstall.ps1 -PurgeData -UninstallDesktop
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'dsh-oneclick'),
    [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
    [switch]$PurgeData,
    [switch]$UninstallDesktop,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath($Root)
$dshHome = [IO.Path]::GetFullPath($DshHome)
$lockPath = Join-Path $dshHome '.lock\versions.json'
$lock = $null
if (Test-Path $lockPath) { $lock = Get-Content $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json }

function Remove-UserPathEntry([string]$Entry) {
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrEmpty($cur)) { return }
    $norm = $Entry.TrimEnd('\')
    $kept = @($cur -split ';' | Where-Object { $_ -ne '' -and $_.TrimEnd('\') -ine $norm })
    if ($kept.Count -ne ($cur -split ';' | Where-Object { $_ -ne '' }).Count) {
        $new = ($kept -join ';')
        if ($DryRun) { Write-Host "  [dry-run] PATH -= $Entry" } else { [Environment]::SetEnvironmentVariable('Path', $new, 'User'); Write-Host "  [ok] PATH -= $Entry" }
    }
}

Write-Host "`n== stopping running processes" -ForegroundColor Cyan
foreach ($n in 'DeepSeek Harness', 'dsh') {
    Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
        if ($DryRun) { Write-Host "  [dry-run] would stop $($_.ProcessName) ($($_.Id))" }
        else { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; Write-Host "  [ok] stopped $($_.ProcessName)" }
    }
}

Write-Host "`n== PATH / environment" -ForegroundColor Cyan
foreach ($p in @((Join-Path $root 'node'), (Join-Path $root 'npm'), (Join-Path $root 'bin'))) { Remove-UserPathEntry $p }
foreach ($v in 'DSH_HOME', 'DSH_PROFILE', 'DSH_ROUTER_BASE') {
    if ($DryRun) { Write-Host "  [dry-run] unset $v" }
    else { [Environment]::SetEnvironmentVariable($v, $null, 'User'); Write-Host "  [ok] unset $v" }
}

if ($UninstallDesktop -and $lock -and $lock.paths.desktopDir) {
    $un = Join-Path $lock.paths.desktopDir 'Uninstall DeepSeek Harness.exe'
    if (Test-Path $un) {
        if ($DryRun) { Write-Host "  [dry-run] $un /S" }
        else { Start-Process -FilePath $un -ArgumentList '/S' -Wait; Write-Host '  [ok] desktop shell uninstalled' }
    }
}

if (Test-Path $root) {
    if ($DryRun) { Write-Host "  [dry-run] remove $root" }
    else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $keep = Join-Path $root "backups"
        if (Test-Path $keep) {
            $to = Join-Path $env:USERPROFILE "dsh-oneclick-backups-$stamp"
            Move-Item $keep $to
            Write-Host "  [ok] backups preserved -> $to"
        }
        Remove-Item $root -Recurse -Force
        Write-Host "  [ok] removed $root"
    }
}

if ($PurgeData -and (Test-Path $dshHome)) {
    if ($DryRun) { Write-Host "  [dry-run] remove $dshHome" }
    else {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $to = "$dshHome.bak-$stamp"
        Move-Item $dshHome $to
        Write-Host "  [ok] dsh home moved -> $to"
    }
} elseif (Test-Path $dshHome) {
    Write-Host "  [ok] kept $dshHome (use -PurgeData to remove)" -ForegroundColor DarkGray
}

Write-Host "`nuninstall complete`n" -ForegroundColor Green
