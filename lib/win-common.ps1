# dsh-oneclick · shared Windows helpers
# Dot-source from install.ps1 / tools\*.ps1
Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('─' * 68) -ForegroundColor DarkGray
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('─' * 68) -ForegroundColor DarkGray
}
function Write-Step { param([string]$Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info { param([string]$Message) Write-Host "    $Message" -ForegroundColor Gray }
function Write-Ok   { param([string]$Message) Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-Warn2{ param([string]$Message) Write-Host "  [!!] $Message" -ForegroundColor Yellow }
function Write-Err2 { param([string]$Message) Write-Host "  [xx] $Message" -ForegroundColor Red }
function Die { param([string]$Message) Write-Err2 $Message; throw $Message }

function Get-PlatformKey {
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }
    if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $arch = 'arm64' }
    return "win32-$arch"
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-Sha256 {
    param([string]$Path)
    return (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

function Expand-ZipSafe {
    param([string]$Zip, [string]$Destination)
    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -Path $Zip -DestinationPath $Destination -Force
}

# Flatten a single-root archive extraction dir into the target dir.
function Move-SingleChild {
    param([string]$From, [string]$To)
    $children = @(Get-ChildItem -Path $From -Force)
    $root = $From
    if ($children.Count -eq 1 -and $children[0].PSIsContainer) { $root = $children[0].FullName }
    if (Test-Path $To) { Remove-Item $To -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path -Parent $To) -Force | Out-Null
    Move-Item -Path $root -Destination $To
}

function Add-UserPath {
    param([string]$Entry)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ([string]::IsNullOrEmpty($cur)) { $cur = '' }
    $parts = @($cur -split ';' | Where-Object { $_ -ne '' })
    $norm = $Entry.TrimEnd('\')
    $exists = $false
    foreach ($p in $parts) { if ($p.TrimEnd('\') -ieq $norm) { $exists = $true; break } }
    if (-not $exists) {
        $new = if ($cur.Trim() -eq '') { $Entry } else { "$cur;$Entry" }
        [Environment]::SetEnvironmentVariable('Path', $new, 'User')
        Write-Ok "PATH += $Entry"
    } else {
        Write-Info "PATH already contains $Entry"
    }
    if (-not (($env:Path -split ';') -contains $Entry)) { $env:Path = "$Entry;$env:Path" }
}

function Set-UserEnv {
    param([string]$Name, [string]$Value, [switch]$OnlyIfMissing)
    if ($OnlyIfMissing) {
        $cur = [Environment]::GetEnvironmentVariable($Name, 'User')
        if (-not [string]::IsNullOrEmpty($cur)) { Write-Info "$Name already set ($cur)"; Set-Item "env:$Name" $cur; return }
    }
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User')
    Set-Item "env:$Name" $Value
    Write-Ok "$Name = $Value"
}

function New-Backup {
    param([string]$Source, [string]$BackupRoot, [string]$Label, [string[]]$Exclude = @())
    if (-not (Test-Path $Source)) { return $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $dest = Join-Path $BackupRoot "$Label-$stamp"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $rcArgs = @($Source, $dest, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1')
    if ($Exclude.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $Exclude }
    & robocopy @rcArgs | Out-Null
    $code = $LASTEXITCODE
    if ($code -ge 8) { throw "backup failed for $Source (robocopy $code)" }
    Write-Ok "backup $Label -> $dest"
    return $dest
}

function Assert-Command {
    param([string]$Name, [string]$Hint)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $c) { Die "missing command '$Name'. $Hint" }
    return $c.Source
}

function Get-JsonFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return Get-Content $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Wait-Http {
    param([string]$Url, [int]$TimeoutSec = 60)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 3
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 500) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 700
    }
    return $false
}
