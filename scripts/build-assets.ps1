#Requires -Version 5.1
<#
.SYNOPSIS
    Build the release asset bundle for dsh-oneclick (run on the SOURCE machine).
.DESCRIPTION
    Produces every file the installer downloads from the GitHub Release:
      node runtimes (win/mac) · offline npm cache · dsh-purge tgz
      desktop shell installers · desktop offline runtime · dsh-home config
      SHA256SUMS.txt
.EXAMPLE
    .\scripts\build-assets.ps1
    .\scripts\build-assets.ps1 -Verify -SkipRuntime
#>
[CmdletBinding()]
param(
    [string]$Dist = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
    [string]$CacheSource = (Join-Path $env:TEMP 'dsh-cache-probe'),
    [string]$DesktopAssets = (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'dsh-desktop-setup-assets'),
    [switch]$SkipDownload,
    [switch]$SkipRuntime,
    [switch]$SkipCache,
    [switch]$Verify
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$manifest = Get-Content (Join-Path $repo 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$nodeVersion = $manifest.pinned.node
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

function Info($m) { Write-Host "  $m" -ForegroundColor Gray }
function Ok($m) { Write-Host "  [ok] $m" -ForegroundColor Green }
function Warn($m) { Write-Host "  [!!] $m" -ForegroundColor Yellow }

# ── node runtimes ────────────────────────────────────────────────────────────
if (-not $SkipDownload) {
    Write-Host "`n== node $nodeVersion" -ForegroundColor Cyan
    $base = "https://nodejs.org/dist/v$nodeVersion"
    $sumsUrl = "$base/SHASUMS256.txt"
    $sumsFile = Join-Path $Dist 'node-SHASUMS256.txt'
    if (-not (Test-Path $sumsFile)) { Invoke-WebRequest -Uri $sumsUrl -OutFile $sumsFile -UseBasicParsing }
    $sums = @{}
    foreach ($l in Get-Content $sumsFile) { if ($l -match '^([0-9a-f]{64})\s+(.+)$') { $sums[$Matches[2]] = $Matches[1] } }

    $targets = @(
        @{ file = "node-v$nodeVersion-win-x64.zip"; out = $manifest.assets.node.'win32-x64' },
        @{ file = "node-v$nodeVersion-darwin-arm64.tar.gz"; out = $manifest.assets.node.'darwin-arm64' },
        @{ file = "node-v$nodeVersion-darwin-x64.tar.gz"; out = $manifest.assets.node.'darwin-x64' }
    )
    foreach ($t in $targets) {
        $out = Join-Path $Dist $t.out
        if (Test-Path $out) { Ok "exists $($t.out)"; continue }
        Info "downloading $($t.file)"
        Invoke-WebRequest -Uri "$base/$($t.file)" -OutFile $out -UseBasicParsing -TimeoutSec 1800
        $got = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
        if ($sums[$t.file] -and $sums[$t.file] -ne $got) { throw "sha256 mismatch for $($t.file)" }
        Ok ("$($t.out)  {0:N1} MB" -f ((Get-Item $out).Length / 1MB))
    }
}

# ── offline npm cache ────────────────────────────────────────────────────────
if (-not $SkipCache) {
    Write-Host "`n== offline npm cache" -ForegroundColor Cyan
    if (-not (Test-Path $CacheSource)) { throw "cache source not found: $CacheSource (run a warm install first)" }
    $macFiles = Get-ChildItem (Join-Path $CacheSource '_cacache\index-v5') -Recurse -File -ErrorAction SilentlyContinue |
        Select-String -Pattern 'sharp-darwin-arm64|sherpa-onnx-darwin-arm64|node-addon-require-builtin-darwin-arm64' -List
    if (-not $macFiles) { Warn 'cache has no darwin platform packages - mac install may need network' }
    else { Ok "cache includes darwin platform packages ($($macFiles.Count) index entries)" }

    $cacheTar = Join-Path $Dist $manifest.assets.npmCache
    if (-not (Test-Path $cacheTar)) {
        Info 'packing cache (this takes a few minutes)'
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $tar -cf $cacheTar -C $CacheSource .
        if ($LASTEXITCODE -ne 0) { throw 'tar failed for npm cache' }
        $sw.Stop()
        Ok ("$($manifest.assets.npmCache)  {0:N1} MB in {1:N0}s" -f ((Get-Item $cacheTar).Length / 1MB), $sw.Elapsed.TotalSeconds)
    } else { Ok "exists $($manifest.assets.npmCache)" }
}

# ── dsh-purge tgz ────────────────────────────────────────────────────────────
Write-Host "`n== dsh-purge $($manifest.pinned.dshPurge)" -ForegroundColor Cyan
$purgeSrc = Join-Path $repo 'payload\vendor\dsh-purge'
$purgeTgz = Join-Path $Dist $manifest.assets.purge
if (-not (Test-Path $purgeTgz)) {
    $stage = Join-Path $env:TEMP 'dsh-purge-pack'
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Copy-Item (Join-Path $purgeSrc '*') $stage -Recurse -Force
    Push-Location $stage
    npm pack --pack-destination $Dist 2>&1 | Out-Null
    Pop-Location
    $picked = Get-ChildItem $Dist -Filter 'dsh-purge-*.tgz' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $picked) { throw 'npm pack produced no tgz' }
    Move-Item $picked.FullName $purgeTgz -Force
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}
Ok ("$($manifest.assets.purge)  {0:N1} MB" -f ((Get-Item $purgeTgz).Length / 1MB))

# ── desktop shell installers ─────────────────────────────────────────────────
Write-Host "`n== desktop shell $($manifest.pinned.desktop)" -ForegroundColor Cyan
$map = @{
    $manifest.assets.desktop.'win32-x64'   = 'deepseek-harness-0.2.0-rc.2-win-x64.exe'
    $manifest.assets.desktop.'darwin-arm64' = 'deepseek-harness-0.2.0-rc.2-mac-arm64.dmg'
    $manifest.assets.desktop.'darwin-x64'   = 'deepseek-harness-0.2.0-rc.2-mac-x64.dmg'
}
foreach ($k in $map.Keys) {
    $srcFile = Join-Path $DesktopAssets $map[$k]
    $out = Join-Path $Dist $k
    if (-not (Test-Path $srcFile)) { Warn "missing source: $($map[$k])"; continue }
    if (-not (Test-Path $out)) { Copy-Item $srcFile $out -Force }
    Ok ("$k  {0:N1} MB" -f ((Get-Item $out).Length / 1MB))
}

# ── desktop offline runtime (windows) ────────────────────────────────────────
if (-not $SkipRuntime) {
    Write-Host "`n== desktop runtime (win32-x64)" -ForegroundColor Cyan
    $rtSrc = Join-Path $env:USERPROFILE '.dsh\dsh-runtimes'
    if (-not (Test-Path (Join-Path $rtSrc 'dsh-primary-runtime\runtime.json'))) {
        Warn 'no runtime on this machine; skipping runtime asset'
    } else {
        $rtOut = Join-Path $Dist $manifest.assets.runtime.'win32-x64'
        if (-not (Test-Path $rtOut)) {
            Info 'packing runtime with gzip (slow, ~400 MB)'
            $sw = [Diagnostics.Stopwatch]::StartNew()
            & $tar -czf $rtOut -C $rtSrc dsh-primary-runtime
            if ($LASTEXITCODE -ne 0) { throw 'tar failed for runtime' }
            $sw.Stop()
            Ok ("$($manifest.assets.runtime.'win32-x64')  {0:N1} MB in {1:N0}s" -f ((Get-Item $rtOut).Length / 1MB), $sw.Elapsed.TotalSeconds)
        } else { Ok "exists $($manifest.assets.runtime.'win32-x64')" }
    }
}

# ── dsh home config snapshot ─────────────────────────────────────────────────
Write-Host "`n== dsh home config" -ForegroundColor Cyan
$cfgOut = Join-Path $Dist $manifest.assets.homeConfig
if (-not (Test-Path $cfgOut)) {
    & $tar -czf $cfgOut -C (Join-Path $repo 'payload') dsh-home
    if ($LASTEXITCODE -ne 0) { throw 'tar failed for home config' }
}
Ok ("$($manifest.assets.homeConfig)  {0:N1} KB" -f ((Get-Item $cfgOut).Length / 1KB))

# ── checksums ────────────────────────────────────────────────────────────────
Write-Host "`n== checksums" -ForegroundColor Cyan
$sumsPath = Join-Path $Dist 'SHA256SUMS.txt'
$lines = foreach ($f in Get-ChildItem $Dist -File | Where-Object { $_.Name -notin @('SHA256SUMS.txt', 'node-SHASUMS256.txt') } | Sort-Object Name) {
    "{0}  {1}" -f (Get-FileHash $f.FullName -Algorithm SHA256).Hash.ToLower(), $f.Name
}
$lines | Set-Content $sumsPath -Encoding ASCII
Ok "SHA256SUMS.txt ($($lines.Count) files)"

Write-Host "`n== bundle" -ForegroundColor Cyan
$total = (Get-ChildItem $Dist -File | Measure-Object Length -Sum).Sum
Get-ChildItem $Dist -File | Sort-Object Name | ForEach-Object {
    "  {0,-52} {1,8:N1} MB" -f $_.Name, ($_.Length / 1MB)
}
"  {0,-52} {1,8:N1} MB" -f 'TOTAL', ($total / 1MB)

# ── end-to-end offline install test with the shipped node ────────────────────
if ($Verify) {
    Write-Host "`n== end-to-end offline verify (shipped node + cache)" -ForegroundColor Cyan
    $stage = Join-Path $env:TEMP 'dsh-e2e'
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    Expand-Archive -Path (Join-Path $Dist $manifest.assets.node.'win32-x64') -DestinationPath $stage -Force
    $nodeRoot = (Get-ChildItem $stage -Directory | Select-Object -First 1).FullName
    $npm = Join-Path $nodeRoot 'npm.cmd'
    $cacheStage = Join-Path $stage 'cache'
    New-Item -ItemType Directory -Path $cacheStage -Force | Out-Null
    & $tar -xf (Join-Path $Dist $manifest.assets.npmCache) -C $cacheStage
    if ($LASTEXITCODE -ne 0) { throw 'cache extract failed' }
    $prefix = Join-Path $stage 'prefix'
    $env:npm_config_update_notifier = 'false'
    & $npm install -g --prefix $prefix --cache $cacheStage --offline --no-audit --no-fund --loglevel error `
        "--allow-scripts=@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs" `
        "@deepseek-ai/dsh@$($manifest.pinned.dsh)"
    if ($LASTEXITCODE -ne 0) { throw "offline install failed with shipped node (exit $LASTEXITCODE)" }
    $v = & (Join-Path $prefix 'dsh.cmd') --version
    Ok "shipped node $(& (Join-Path $nodeRoot 'node.exe') -v) -> dsh $v (offline)"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n  dist: $Dist`n" -ForegroundColor Cyan
