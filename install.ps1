#Requires -Version 5.1
<#
.SYNOPSIS
    dsh-oneclick — one-shot, offline-capable installer for DeepSeek Harness (dsh)
    + dsh-purge 1.1.71 on Windows.

.DESCRIPTION
    Pinned stack: dsh 0.2.2-rc.5 · dsh-purge 1.1.71 · desktop shell 0.2.0-rc.2
                  node 24.21.0 · pnpm 11.7.0 · profile "desktop"

    Everything is fetched from this repository's GitHub Release assets, or read
    from a local assets\ folder (-Offline). Nothing is pulled from the network
    when the cache archive is present.

.PARAMETER Mode
    desktop = desktop shell + CLI runtime (default)
    cli     = CLI + web GUI only (no desktop shell)

.PARAMETER Root
    Install root (node, npm prefix, npm cache). Default %LOCALAPPDATA%\dsh-oneclick

.PARAMETER DshHome
    dsh home. Default %USERPROFILE%\.dsh

.PARAMETER Assets
    Local asset folder. When omitted, .\assets next to this script is used,
    then the GitHub Release.

.PARAMETER RouterBase
    OpenAI-compatible router base URL written to DSH_ROUTER_BASE.

.PARAMETER RouterKey
    Value for DS9700_API_KEY (written to the user environment, never to disk in this repo).

.EXAMPLE
    .\install.ps1
    .\install.ps1 -Mode cli -Offline -Assets .\assets
    .\install.ps1 -DryRun -Force
#>
[CmdletBinding()]
param(
    [ValidateSet('desktop', 'cli')][string]$Mode = 'desktop',
    [string]$Root = (Join-Path $env:LOCALAPPDATA 'dsh-oneclick'),
    [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
    [string]$Assets = '',
    [string]$Repo = 'jaydenchen969-bit/dsh-oneclick',
    [string]$ReleaseTag = 'v1.0.0',
    [string]$DesktopDir = '',
    [string]$RouterBase = '',
    [string]$RouterKey = '',
    [switch]$Offline,
    [switch]$SkipDesktop,
    [switch]$SkipPurge,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoPath,
    [switch]$SkipEnv
)

. (Join-Path $PSScriptRoot 'lib\win-common.ps1')

$script:DesktopDir = $DesktopDir

# ─────────────────────────────── state ───────────────────────────────────────
$script:Root = [IO.Path]::GetFullPath($Root)
$script:DshHome = [IO.Path]::GetFullPath($DshHome)
$script:Assets = if ($Assets) { [IO.Path]::GetFullPath($Assets) } else { '' }
$script:Repo = $Repo
$script:ReleaseTag = $ReleaseTag
$script:Offline = [bool]$Offline
$script:DryRun = [bool]$DryRun
$script:Force = [bool]$Force
$script:CacheDir = Join-Path $script:Root 'npm-cache'
$script:NpmPrefix = Join-Path $script:Root 'npm'
$script:NodeDir = Join-Path $script:Root 'node'
$script:BinDir = Join-Path $script:Root 'bin'
$script:LogDir = Join-Path $script:Root 'logs'
$script:BackupRoot = Join-Path $script:Root 'backups'
$script:Platform = Get-PlatformKey
$script:Manifest = Get-JsonFile (Join-Path $PSScriptRoot 'manifest.json')
$script:Sums = @{}
$script:AssetCache = Join-Path $script:Root '_assets'
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Steps = New-Object System.Collections.Generic.List[string]

$logFile = Join-Path $script:LogDir ("install-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

function Log {
    param([string]$Line)
    Add-Content -Path $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Line) -Encoding UTF8
}

function Step-Done([string]$Text) { $script:Steps.Add($Text); Log "STEP OK: $Text" }
function Note-Warn([string]$Text) { $script:Warnings.Add($Text); Write-Warn2 $Text; Log "WARN: $Text" }

# ─────────────────────────────── assets ──────────────────────────────────────
function Initialize-Assets {
    foreach ($d in @($script:Root, $script:CacheDir, $script:NpmPrefix, $script:LogDir, $script:BackupRoot, $script:AssetCache, $script:BinDir)) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }
    Add-Content -Path $logFile -Value "=== dsh-oneclick install $(Get-Date -Format o) ===" -Encoding UTF8
    Write-Info "log: $logFile"
    Write-Info "root: $script:Root"
    Write-Info "dsh home: $script:DshHome"
    Write-Info "platform: $script:Platform"

    # SHA256SUMS: local folder first, then release
    $sumsLocal = @()
    if ($script:Assets) { $sumsLocal += (Join-Path $script:Assets 'SHA256SUMS.txt') }
    $sumsLocal += (Join-Path $PSScriptRoot 'assets\SHA256SUMS.txt')
    $sumsPath = $sumsLocal | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $sumsPath -and -not $script:Offline) {
        $tmp = Join-Path $script:AssetCache 'SHA256SUMS.txt'
        if (-not (Test-Path $tmp)) {
            try {
                Invoke-WebRequest -Uri "https://github.com/$script:Repo/releases/download/$script:ReleaseTag/SHA256SUMS.txt" -OutFile $tmp -UseBasicParsing -TimeoutSec 60
            } catch { Note-Warn "SHA256SUMS.txt unavailable; downloads will not be hash-verified" }
        }
        if (Test-Path $tmp) { $sumsPath = $tmp }
    }
    if ($sumsPath) {
        foreach ($line in Get-Content $sumsPath -Encoding UTF8) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
                $script:Sums[$Matches[2].Trim()] = $Matches[1].ToLower()
            }
        }
        Write-Ok "SHA256SUMS loaded ($($script:Sums.Count) entries)"
    }
}

function Get-Asset {
    param([string]$Name, [switch]$Optional)
    $local = @()
    if ($script:Assets) { $local += (Join-Path $script:Assets $Name) }
    $local += (Join-Path $PSScriptRoot "assets\$Name")
    foreach ($p in $local) {
        if (Test-Path $p) { Write-Info "asset(local): $Name"; return $p }
    }
    $cached = Join-Path $script:AssetCache $Name
    if (Test-Path $cached) { return $cached }
    if ($script:Offline) {
        if ($Optional) { Note-Warn "offline: optional asset missing -> $Name"; return $null }
        Die "offline mode: required asset missing -> $Name (looked in assets\)"
    }
    $url = "https://github.com/$script:Repo/releases/download/$script:ReleaseTag/$Name"
    Write-Info "downloading $Name ..."
    Log "download $url"
    if ($script:DryRun) { return $null }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-WebRequest -Uri $url -OutFile $cached -UseBasicParsing -TimeoutSec 3600
    } catch {
        if ($Optional) { Note-Warn "download failed (optional): $Name"; return $null }
        Die "download failed: $url`n$($_.Exception.Message)"
    }
    $sw.Stop()
    Write-Ok ("downloaded {0} ({1:N0} MB in {2:N0}s)" -f $Name, ((Get-Item $cached).Length / 1MB), $sw.Elapsed.TotalSeconds)
    if ($script:Sums.ContainsKey($Name)) {
        $want = $script:Sums[$Name]
        $got = Get-Sha256 $cached
        if ($got -ne $want) { Die "sha256 mismatch for ${Name}: want $want got $got" }
        Write-Ok "sha256 ok: $Name"
    }
    return $cached
}

function Expand-TarTo {
    param([string]$Archive, [string]$Destination, [string]$ExtractRoot)
    if ($script:DryRun) { Write-Info "[dry-run] tar -xf $Archive -C $Destination"; return }
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (-not (Test-Path $tar)) { Die 'tar.exe missing (Windows 10 1803+ required)' }
    if (Test-Path $ExtractRoot) { Remove-Item $ExtractRoot -Recurse -Force }
    New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
    & $tar -xf $Archive -C $ExtractRoot
    if ($LASTEXITCODE -ne 0) { Die "tar extraction failed: $Archive" }
    Move-SingleChild -From $ExtractRoot -To $Destination
}

# ─────────────────────────────── preflight ───────────────────────────────────
function Invoke-Preflight {
    Write-Step 'preflight'
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { Die 'this script targets Windows' }
    $ver = [Environment]::OSVersion.Version
    if ($ver.Major -lt 10) { Die "Windows 10+ required (found $ver)" }
    Write-Ok "Windows $ver ($script:Platform)"

    $drive = (Get-Item $script:Root).PSDrive
    if (-not $drive) { $drive = Get-PSDrive -Name ([IO.Path]::GetPathRoot($script:Root).Substring(0, 1)) }
    $freeGb = [math]::Round($drive.Free / 1GB, 1)
    Write-Info ("free space on {0}: {1} GB" -f $drive.Name, $freeGb)
    if ($freeGb -lt 5) { Note-Warn "less than 5 GB free on $($drive.Name):" }

    if (-not (Test-Path $script:Root)) { Write-Info "will create $script:Root" }
    Write-Ok 'preflight passed'
    Step-Done 'preflight'
}

# ─────────────────────────────── node ────────────────────────────────────────
function Install-NodeRuntime {
    $want = $script:Manifest.pinned.node
    $nodeExe = Join-Path $script:NodeDir 'node.exe'
    if (Test-Path $nodeExe) {
        $have = (& $nodeExe -v 2>$null) -replace '^v', ''
        if ($have -eq $want -and -not $script:Force) {
            Write-Ok "node $have already installed"
            Step-Done 'node'
            return
        }
        Write-Info "node $have present, want $want -> reinstalling"
    }
    $name = $script:Manifest.assets.node.$script:Platform
    if (-not $name) { Die "no node asset mapped for $script:Platform" }
    $zip = Get-Asset $name
    if ($script:DryRun) { Write-Info "[dry-run] install node $want from $name"; return }
    $staging = Join-Path $script:Root '_stage_node'
    Expand-ZipSafe -Zip $zip -Destination $staging
    Move-SingleChild -From $staging -To $script:NodeDir
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    $have = (& $nodeExe -v) -replace '^v', ''
    if ($have -ne $want) { Die "node version mismatch after install: $have != $want" }
    Write-Ok "node $have installed at $script:NodeDir"
    Step-Done 'node'
}

# ─────────────────────────────── npm cache ───────────────────────────────────
function Expand-NpmCache {
    $marker = Join-Path $script:CacheDir '.dsh-cache-ready'
    if (Test-Path $marker) { Write-Ok 'npm cache already expanded'; Step-Done 'npm-cache'; return }
    $name = $script:Manifest.assets.npmCache
    $archive = Get-Asset $name
    if ($script:DryRun) { Write-Info "[dry-run] expand $name -> $script:CacheDir"; return }
    Expand-TarTo -Archive $archive -Destination $script:CacheDir -ExtractRoot (Join-Path $script:Root '_stage_cache')
    Remove-Item (Join-Path $script:Root '_stage_cache') -Recurse -Force -ErrorAction SilentlyContinue
    Set-Content -Path $marker -Value (Get-Date -Format o) -Encoding UTF8
    Write-Ok 'npm cache ready'
    Step-Done 'npm-cache'
}

function Invoke-Npm {
    param([string[]]$NpmArgs, [switch]$AllowOnlineFallback)
    if ($script:DryRun) { Write-Info "[dry-run] npm $($NpmArgs -join ' ')"; return }
    $npm = Join-Path $script:NodeDir 'npm.cmd'
    if (-not (Test-Path $npm)) { Die "npm.cmd missing at $npm" }
    $env:npm_config_cache = $script:CacheDir
    $env:npm_config_prefix = $script:NpmPrefix
    $env:npm_config_update_notifier = 'false'
    $env:npm_config_fund = 'false'
    $env:npm_config_audit = 'false'
    $base = @('--prefix', $script:NpmPrefix, '--cache', $script:CacheDir, '--no-audit', '--no-fund', '--loglevel', 'error')
    $cmdline = @($NpmArgs) + $base
    Log ("npm " + ($NpmArgs -join ' '))
    if ($script:DryRun) { Write-Info "[dry-run] npm $($cmdline -join ' ')"; return }
    $offline = @()
    if ($script:Offline) { $offline = @('--offline') }
    & $npm @cmdline @offline
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $script:Offline -and $AllowOnlineFallback) {
        Write-Warn2 "offline install failed (exit $code); retrying online"
        Log "npm retry online"
        & $npm @cmdline
        $code = $LASTEXITCODE
    }
    if ($code -ne 0) { Die "npm exited $code" }
    return
}

# ─────────────────────────────── dsh ─────────────────────────────────────────
function Get-InstalledVersion {
    param([string]$PackagePath)
    $pkg = Join-Path $PackagePath 'package.json'
    if (-not (Test-Path $pkg)) { return $null }
    return (Get-JsonFile $pkg).version
}

function Install-Dsh {
    $want = $script:Manifest.pinned.dsh
    $pkgDir = Join-Path $script:NpmPrefix 'node_modules\@deepseek-ai\dsh'
    $have = Get-InstalledVersion $pkgDir
    if ($have -eq $want -and -not $script:Force) {
        Write-Ok "dsh $have already installed"
        Step-Done 'dsh'
        return
    }
    if ($have) { Write-Info "dsh $have found, pinning to $want" }
    $allow = '@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs'
    Invoke-Npm -NpmArgs @('install', '-g', "@deepseek-ai/dsh@$want", "--allow-scripts=$allow") -AllowOnlineFallback
    $now = Get-InstalledVersion $pkgDir
    if ($now -ne $want -and -not $script:DryRun) { Die "dsh version after install: $now (want $want)" }
    Write-Ok "dsh $want installed"
    Step-Done 'dsh'
}

function Install-Pnpm {
    $want = $script:Manifest.pinned.pnpm
    $pkgDir = Join-Path $script:NpmPrefix 'node_modules\pnpm'
    $have = Get-InstalledVersion $pkgDir
    if ($have -eq $want -and -not $script:Force) { Write-Ok "pnpm $have already installed"; Step-Done 'pnpm'; return }
    try {
        Invoke-Npm -NpmArgs @('install', '-g', "pnpm@$want") -AllowOnlineFallback
        Write-Ok "pnpm $want installed"
        Step-Done 'pnpm'
    } catch {
        Note-Warn "pnpm $want unavailable (offline cache miss?); profile dependency step will be skipped - purge still applies from the global install"
        Step-Done 'pnpm-skipped'
    }
}

function Install-Purge {
    if ($SkipPurge) { Write-Info 'purge skipped'; return }
    $want = $script:Manifest.pinned.dshPurge
    $pkgDir = Join-Path $script:NpmPrefix 'node_modules\dsh-purge'
    $have = Get-InstalledVersion $pkgDir
    if ($have -eq $want -and -not $script:Force) { Write-Ok "dsh-purge $have already installed"; Step-Done 'purge-package'; return }
    $tgz = Get-Asset $script:Manifest.assets.purge
    Invoke-Npm -NpmArgs @('install', '-g', $tgz) -AllowOnlineFallback
    $now = Get-InstalledVersion $pkgDir
    if ($now -ne $want -and -not $script:DryRun) { Die "dsh-purge version after install: $now (want $want)" }
    Write-Ok "dsh-purge $want installed"
    Step-Done 'purge-package'
}

# ─────────────────────────────── dsh home ────────────────────────────────────
function Deploy-DshHome {
    Write-Step 'deploy dsh home'
    $payload = Join-Path $PSScriptRoot 'payload\dsh-home'
    if (-not (Test-Path $payload)) { Die "payload missing: $payload" }
    if ($script:DryRun) { Write-Info "[dry-run] copy payload -> $script:DshHome"; Step-Done 'dsh-home'; return }
    if (Test-Path $script:DshHome) {
        New-Backup -Source $script:DshHome -BackupRoot $script:BackupRoot -Label 'dsh-home' -Exclude @('cache', 'sessions', 'storages', 'logs', 'dsh-runtimes')
    } else {
        New-Item -ItemType Directory -Path $script:DshHome -Force | Out-Null
    }

    Copy-Item (Join-Path $payload 'prompt-inject.md') (Join-Path $script:DshHome 'prompt-inject.md') -Force
    Write-Ok 'prompt-inject.md deployed'

    $profSrc = Join-Path $payload 'profiles\desktop'
    $profDst = Join-Path $script:DshHome 'profiles\desktop'
    New-Item -ItemType Directory -Path $profDst -Force | Out-Null
    foreach ($f in 'cordis.yml', 'cordis.patch.yml', 'pnpm-workspace.yaml', 'package.json') {
        Copy-Item (Join-Path $profSrc $f) (Join-Path $profDst $f) -Force
    }
    Write-Ok "desktop profile files deployed -> $profDst"

    # purge vendor inside the profile (portable, no absolute link:)
    $purgeVendor = Join-Path $profDst 'vendor\dsh-purge'
    $purgeLocal = Join-Path $PSScriptRoot 'payload\vendor\dsh-purge'
    if (Test-Path $purgeLocal) {
        if (Test-Path $purgeVendor) { Remove-Item $purgeVendor -Recurse -Force }
        New-Item -ItemType Directory -Path (Split-Path -Parent $purgeVendor) -Force | Out-Null
        Copy-Item $purgeLocal $purgeVendor -Recurse -Force
        Write-Ok 'dsh-purge vendored into profile'
    }

    $lockSrc = Join-Path $payload 'lock\versions.json'
    $lockDir = Join-Path $script:DshHome '.lock'
    New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    if (Test-Path $lockSrc) { Copy-Item $lockSrc (Join-Path $lockDir 'versions.json') -Force }
    Step-Done 'dsh-home'
}

function Update-ProfileMcp {
    Write-Step 'probe MCP servers'
    $gen = Join-Path $PSScriptRoot 'tools\gen-mcp.mjs'
    $patch = Join-Path $script:DshHome 'profiles\desktop\cordis.patch.yml'
    if (-not (Test-Path $gen)) { Note-Warn 'gen-mcp.mjs missing, keeping patch as-is'; return }
    if ($script:DryRun) { Write-Info '[dry-run] node gen-mcp.mjs'; return }
    $node = Join-Path $script:NodeDir 'node.exe'
    & $node $gen $patch
    if ($LASTEXITCODE -ne 0) { Note-Warn "MCP probe failed (exit $LASTEXITCODE); patch left unchanged" }
    else { Write-Ok 'MCP block regenerated for this machine' }
    Step-Done 'mcp-probe'
}

function Install-ProfileDeps {
    Write-Step 'install profile dependencies'
    $profDst = Join-Path $script:DshHome 'profiles\desktop'
    $pnpmCjs = Join-Path $script:NpmPrefix 'node_modules\pnpm\bin\pnpm.cjs'
    if (-not (Test-Path $pnpmCjs)) { Note-Warn 'pnpm.cjs missing; skipping profile install'; return }
    if ($script:DryRun) { Write-Info "[dry-run] pnpm install --dir $profDst"; return }
    $node = Join-Path $script:NodeDir 'node.exe'
    & $node $pnpmCjs install --dir $profDst --config.confirmModulesPurge=false --reporter=append-only
    if ($LASTEXITCODE -ne 0) { Note-Warn "pnpm install exited $LASTEXITCODE (profile will still boot; purge falls back to global install)" }
    else { Write-Ok 'profile dependencies installed' }
    Step-Done 'profile-deps'
}

function Invoke-PurgeApply {
    if ($SkipPurge) { return }
    Write-Step 'apply purge patch set'
    $exe = Join-Path $script:NpmPrefix 'dsh-purge.cmd'
    if (-not (Test-Path $exe)) { Note-Warn 'dsh-purge shim missing; skipping apply'; return }
    if ($script:DryRun) { Write-Info '[dry-run] dsh-purge --apply'; return }
    & $exe --apply 2>&1 | Tee-Object -FilePath (Join-Path $script:LogDir 'purge-apply.log') | Out-Null
    $code = $LASTEXITCODE
    if ($code -ne 0) { Note-Warn "dsh-purge --apply exited $code (see logs\purge-apply.log)" }
    else { Write-Ok 'purge applied' }
    Step-Done 'purge-apply'
}

# ─────────────────────────────── desktop shell ───────────────────────────────
function Install-DesktopShell {
    if ($Mode -ne 'desktop' -or $SkipDesktop) { Write-Info 'desktop shell skipped'; return }
    Write-Step 'desktop shell'
    if (-not $script:DesktopDir) {
        $script:DesktopDir = if (Test-Path 'D:\') { 'D:\dsh' } else { Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness' }
    }
    $DesktopDir = $script:DesktopDir
    $exe = Join-Path $DesktopDir 'DeepSeek Harness.exe'
    $want = $script:Manifest.pinned.desktop
    if (Test-Path $exe) {
        $have = (Get-Item $exe).VersionInfo.FileVersion
        if ($have -eq $want -and -not $script:Force) {
            Write-Ok "desktop shell $have already installed at $DesktopDir"
            Disable-DesktopAutoUpdate -DesktopDir $DesktopDir
            Step-Done 'desktop-shell'
            return
        }
        Write-Info "desktop shell $have present, want $want"
    }
    $name = $script:Manifest.assets.desktop.$script:Platform
    if (-not $name) { Note-Warn "no desktop asset for $script:Platform"; return }
    $setup = Get-Asset $name -Optional
    if (-not $setup) { Note-Warn 'desktop installer asset unavailable'; return }
    if ($script:DryRun) { Write-Info "[dry-run] $setup /S /D=$DesktopDir"; return }
    Write-Info "installing desktop shell silently -> $DesktopDir"
    $p = Start-Process -FilePath $setup -ArgumentList @('/S', "/D=$DesktopDir") -Wait -PassThru
    if ($p.ExitCode -ne 0) { Note-Warn "desktop installer exit code $($p.ExitCode)" }
    $deadline = (Get-Date).AddSeconds(120)
    while (-not (Test-Path $exe) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (-not (Test-Path $exe)) { Note-Warn "desktop exe not found at $exe after install"; return }
    Write-Ok "desktop shell installed at $DesktopDir"
    Disable-DesktopAutoUpdate -DesktopDir $DesktopDir
    Step-Done 'desktop-shell'
}

function Install-DesktopRuntime {
    if ($Mode -ne 'desktop' -or $SkipDesktop) { return }
    if (-not $script:Manifest.assets.runtime.$script:Platform) { Write-Info "no bundled runtime for $script:Platform (desktop shell downloads it on first launch)"; return }
    Write-Step 'desktop offline runtime'
    $rtDir = Join-Path $script:DshHome 'dsh-runtimes\dsh-primary-runtime'
    if ((Test-Path (Join-Path $rtDir 'runtime.json')) -and -not $script:Force) {
        Write-Ok 'runtime already present'
        Step-Done 'desktop-runtime'
        return
    }
    $name = $script:Manifest.assets.runtime.$script:Platform
    $archive = Get-Asset $name -Optional
    if (-not $archive) { return }
    if (-not $script:DryRun) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $rtDir) -Force | Out-Null
        Expand-TarTo -Archive $archive -Destination $rtDir -ExtractRoot (Join-Path $script:Root '_stage_runtime')
        Remove-Item (Join-Path $script:Root '_stage_runtime') -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Ok 'runtime deployed'
    Step-Done 'desktop-runtime'
}

function Disable-DesktopAutoUpdate {
    param([string]$DesktopDir)
    $res = Join-Path $DesktopDir 'resources'
    if (-not (Test-Path $res)) { return }
    $yml = Join-Path $res 'app-update.yml'
    $dis = Join-Path $res 'app-update.yml.disabled'
    if (Test-Path $yml) {
        if ($script:DryRun) { Write-Info "[dry-run] disable $yml"; return }
        if (Test-Path $dis) { Remove-Item $dis -Force }
        Move-Item $yml $dis -Force
        Write-Ok 'desktop auto-update disabled (app-update.yml -> .disabled)'
    } elseif (Test-Path $dis) {
        Write-Ok 'desktop auto-update already disabled'
    }
}

function Install-Tools {
    Write-Step 'install tools'
    $dstTools = Join-Path $script:Root 'tools'
    if ($script:DryRun) { Write-Info "[dry-run] copy tools -> $dstTools"; Step-Done 'tools'; return }
    New-Item -ItemType Directory -Path $dstTools -Force | Out-Null
    Copy-Item (Join-Path $PSScriptRoot 'tools\*') $dstTools -Recurse -Force
    Write-Ok "tools -> $dstTools  (verify.cmd / uninstall.cmd)"
    Step-Done 'tools'
}

# ─────────────────────────────── pin / lock ──────────────────────────────────
function Set-VersionLock {
    Write-Step 'pin versions (no auto-upgrade)'
    $lockDir = Join-Path $script:DshHome '.lock'
    if (-not $script:DryRun) { New-Item -ItemType Directory -Path $lockDir -Force | Out-Null }
    $dshPkg = Join-Path $script:NpmPrefix 'node_modules\@deepseek-ai\dsh\package.json'
    $dshHash = if (Test-Path $dshPkg) { Get-Sha256 $dshPkg } else { '' }
    $lock = [ordered]@{
        schema      = 1
        installer   = 'dsh-oneclick'
        release     = $script:Manifest.release
        pinned      = $script:Manifest.pinned
        installedAt = (Get-Date -Format o)
        platform    = $script:Platform
        paths       = [ordered]@{
            root       = $script:Root
            node       = $script:NodeDir
            npmPrefix  = $script:NpmPrefix
            npmCache   = $script:CacheDir
            dshHome    = $script:DshHome
            desktopDir = if ($script:DesktopDir) { $script:DesktopDir } else { '' }
        }
        integrity   = [ordered]@{
            dshPackageJsonSha256 = $dshHash
        }
        upgrades    = [ordered]@{
            desktop = 'disabled'
            dsh     = 'pinned'
            purge   = 'pinned'
            pnpm    = 'frozen'
        }
    }
    if (-not $script:DryRun) {
        $lock | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $lockDir 'versions.json') -Encoding UTF8
        Set-Content -Path (Join-Path $lockDir 'PINNED.txt') -Encoding UTF8 -Value @"
dsh            = $($script:Manifest.pinned.dsh)
dsh-purge      = $($script:Manifest.pinned.dshPurge)
desktop shell  = $($script:Manifest.pinned.desktop)
node           = $($script:Manifest.pinned.node)
pnpm           = $($script:Manifest.pinned.pnpm)
profile        = $($script:Manifest.pinned.profile)

Do not run: npm i -g @deepseek-ai/dsh@latest
Re-install with: dsh-oneclick install.ps1 -Force
Verify with:     %LOCALAPPDATA%\dsh-oneclick\tools\verify.cmd
"@
        Write-Ok "version lock written -> $lockDir"
    }

    # dsh-lock launcher: guards the pin, then delegates to the real shim
    if (-not $script:DryRun) {
        $guard = Join-Path $script:BinDir 'dsh-lock.ps1'
        Copy-Item (Join-Path $PSScriptRoot 'tools\dsh-lock.ps1') $guard -Force
        $cmd = Join-Path $script:BinDir 'dsh-lock.cmd'
        Set-Content -Path $cmd -Encoding ASCII -Value @"
@echo off
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0dsh-lock.ps1" %*
"@
        Write-Ok "pinned launcher -> $cmd"
    }
    Step-Done 'version-lock'
}

function Set-Environment {
    Write-Step 'environment'
    if ($SkipEnv) {
        $env:DSH_HOME = $script:DshHome
        $env:DSH_PROFILE = 'desktop'
        Write-Info 'process-scope env only (-SkipEnv)'
        Step-Done 'environment'
        return
    }
    if ($NoPath) { Write-Info 'PATH update skipped (-NoPath)' }
    if (-not $script:DryRun) {
        Set-UserEnv -Name 'DSH_HOME' -Value $script:DshHome
        Set-UserEnv -Name 'DSH_PROFILE' -Value $script:Manifest.pinned.profile
        $rb = if ($RouterBase) { $RouterBase } else { 'http://192.168.110.45:3425/v1' }
        Set-UserEnv -Name 'DSH_ROUTER_BASE' -Value $rb -OnlyIfMissing
        if ($RouterKey) { Set-UserEnv -Name 'DS9700_API_KEY' -Value $RouterKey }
        if (-not $NoPath) {
            Add-UserPath $script:NodeDir
            Add-UserPath $script:NpmPrefix
            Add-UserPath $script:BinDir
        }
    } else {
        Write-Info "[dry-run] set DSH_HOME / DSH_PROFILE / DSH_ROUTER_BASE / PATH"
    }
    Step-Done 'environment'
}

# ─────────────────────────────── verify ──────────────────────────────────────
function Invoke-SelfTest {
    Write-Step 'self test'
    if ($script:DryRun) { Write-Info '[dry-run] self test skipped'; return }
    $dsh = Join-Path $script:NpmPrefix 'dsh.cmd'
    if (-not (Test-Path $dsh)) { Note-Warn 'dsh.cmd missing'; return }
    $v = (& $dsh --version 2>&1 | Out-String).Trim()
    if ($v -match $script:Manifest.pinned.dsh) { Write-Ok "dsh --version -> $v" } else { Note-Warn "dsh --version -> $v (expected $($script:Manifest.pinned.dsh))" }

    $dump = & $dsh --profile desktop --dump-config 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0 -and $dump.Length -gt 200) { Write-Ok 'profile composes (dump-config ok)' }
    else { Note-Warn 'dump-config failed - check profile logs' }

    $purge = Join-Path $script:NpmPrefix 'dsh-purge.cmd'
    if ((Test-Path $purge) -and -not $SkipPurge) {
        $st = & $purge 2>&1 | Out-String
        $applied = ([regex]::Matches($st, 'applied')).Count
        $rev = ([regex]::Match($st, 'apply:(\S+)')).Groups[1].Value
        if ($rev) { Write-Ok "purge state: $rev, $applied applied patches" }
        else { Note-Warn 'purge state unreadable' }
    }
    Step-Done 'self-test'
}

# ─────────────────────────────── main ────────────────────────────────────────
try {
    Write-Banner "dsh-oneclick  release $($script:Manifest.release)  mode=$Mode  dryRun=$($script:DryRun)"
    Initialize-Assets
    Invoke-Preflight
    Install-NodeRuntime
    Expand-NpmCache
    Install-Dsh
    Install-Pnpm
    Install-Purge
    Deploy-DshHome
    Update-ProfileMcp
    Install-ProfileDeps
    Invoke-PurgeApply
    Install-DesktopShell
    Install-DesktopRuntime
    Install-Tools
    Set-VersionLock
    Set-Environment
    Invoke-SelfTest

    Write-Banner 'done'
    foreach ($s in $script:Steps) { Write-Ok $s }
    if ($script:Warnings.Count -gt 0) {
        Write-Host ''
        Write-Warn2 "completed with $($script:Warnings.Count) warning(s):"
        foreach ($w in $script:Warnings) { Write-Host "   - $w" -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host '  launch:' -ForegroundColor Cyan
    if ($Mode -eq 'desktop') {
        $exePath = Join-Path $script:DesktopDir 'DeepSeek Harness.exe'
        Write-Host "    desktop : $exePath"
    }
    Write-Host "    web gui : $script:NpmPrefix\dsh.cmd web   (http://127.0.0.1:19387)"
    Write-Host "    verify  : $script:Root\tools\verify.cmd  (after first run)"
    Write-Host "    log     : $logFile"
    Write-Host ''
    Log 'INSTALL COMPLETE'
    exit 0
} catch {
    Log ("INSTALL FAILED: " + $_.Exception.Message)
    Write-Host ''
    Write-Err2 "install failed: $($_.Exception.Message)"
    if (Test-Path (Join-Path $script:BackupRoot '')) {
        Write-Host "  backups: $script:BackupRoot" -ForegroundColor Yellow
    }
    Write-Host "  log:     $logFile" -ForegroundColor Yellow
    exit 1
}


