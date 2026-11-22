#!/usr/bin/env bash
# dsh-oneclick · macOS installer
# Pinned stack: dsh 0.2.2-rc.5 · dsh-purge 1.1.71 · node 24.21.0 · pnpm 11.7.0
# Desktop shell 0.2.0-rc.2 is optional (-Mode desktop); the CLI + web GUI path is
# fully offline.
set -euo pipefail

MODE="cli"
ROOT="${HOME}/.dsh-oneclick"
DSH_HOME="${HOME}/.dsh"
ASSETS=""
REPO="jaydenchen969-bit/dsh-oneclick"
TAG="v1.0.0"
OFFLINE=0
FORCE=0
DRY=0
NOPATH=0
SKIP_PURGE=0
ROUTER_BASE=""
ROUTER_KEY=""
MIRROR=""

usage() {
  cat <<'EOF'
usage: install.sh [options]
  --mode cli|desktop        cli = runtime + web GUI (default), desktop = also install the .app
  --root DIR                install root (default ~/.dsh-oneclick)
  --dsh-home DIR            dsh home (default ~/.dsh)
  --assets DIR              local assets directory (implies --offline when no network)
  --repo OWNER/REPO         default jaydenchen969-bit/dsh-oneclick
  --tag TAG                 release tag (default v1.0.0)
  --offline                 never touch the network
  --force                   reinstall even when versions match
  --dry-run                 print actions only
  --no-path                 do not modify shell profiles
  --skip-purge              install runtime only
  --router-base URL         DSH_ROUTER_BASE
  --router-key KEY          DS9700_API_KEY
  --mirror URL              prepend a download accelerator for release assets
                            e.g. --mirror https://ghfast.top
  -h, --help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode) MODE="$2"; shift 2;;
    --root) ROOT="$2"; shift 2;;
    --dsh-home) DSH_HOME="$2"; shift 2;;
    --assets) ASSETS="$2"; shift 2;;
    --repo) REPO="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --offline) OFFLINE=1; shift;;
    --force) FORCE=1; shift;;
    --dry-run) DRY=1; shift;;
    --no-path) NOPATH=1; shift;;
    --skip-purge) SKIP_PURGE=1; shift;;
    --router-base) ROUTER_BASE="$2"; shift 2;;
    --router-key) ROUTER_KEY="$2"; shift 2;;
    --mirror) MIRROR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CACHE_DIR="$ROOT/npm-cache"
NPM_PREFIX="$ROOT/npm"
NODE_DIR="$ROOT/node"
BIN_DIR="$ROOT/bin"
APP_DIR="${DSH_APP_DIR:-$HOME/Applications}"
APP_PATH="$APP_DIR/DeepSeek Harness.app"
LOG_DIR="$ROOT/logs"
BACKUP_ROOT="$ROOT/backups"
ASSET_CACHE="$ROOT/_assets"
LOG="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
WARNINGS=()

c_reset=$'\033[0m'; c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_gray=$'\033[90m'
step() { printf '\n%s==> %s%s\n' "$c_cyan" "$1" "$c_reset" >&2; log "STEP $1"; }
info() { printf '    %s\n' "$1" >&2; }
ok()   { printf '  %s[ok]%s %s\n' "$c_green" "$c_reset" "$1" >&2; }
warn() { WARNINGS+=("$1"); printf '  %s[!!]%s %s\n' "$c_yellow" "$c_reset" "$1" >&2; log "WARN $1"; }
die()  { printf '  %s[xx]%s %s\n' "$c_red" "$c_reset" "$1" >&2; log "FAIL $1"; exit 1; }
log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$1" >>"$LOG" 2>/dev/null || true; }
run()  { log "RUN $*"; if [[ $DRY -eq 1 ]]; then info "[dry-run] $*"; else "$@"; fi; }

case "$(uname -m)" in
  arm64) PLATFORM="darwin-arm64";;
  x86_64) PLATFORM="darwin-x64";;
  *) die "unsupported CPU: $(uname -m)";;
esac

manifest() {
  # NOTE: on a fresh Mac there is no node yet, so python3 comes first and node
  # is only the fallback. Getting this wrong breaks the very first step of the
  # install ("no node asset mapped for darwin-arm64").
  local key="$1" file="$SCRIPT_DIR/manifest.json" val=""
  if command -v python3 >/dev/null 2>&1; then
    val="$(python3 - "$file" "$key" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1]))
for k in sys.argv[2].split('.'):
    d = d[k]
sys.stdout.write('' if d is None else str(d))
PY
)"
  fi
  if [[ -z "$val" ]] && command -v node >/dev/null 2>&1; then
    val="$(node -e 'const fs=require("fs");let d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));for(const k of process.argv[2].split("."))d=d[k];process.stdout.write(d==null?"":String(d))' "$file" "$key" 2>/dev/null || true)"
  fi
  printf '%s' "$val"
}

PINNED_DSH="$(manifest pinned.dsh)"; PINNED_DSH="${PINNED_DSH:-0.2.2-rc.5}"
PINNED_PURGE="$(manifest pinned.dshPurge)"; PINNED_PURGE="${PINNED_PURGE:-1.1.71}"
PINNED_NODE="$(manifest pinned.node)"; PINNED_NODE="${PINNED_NODE:-24.21.0}"
PINNED_PNPM="$(manifest pinned.pnpm)"; PINNED_PNPM="${PINNED_PNPM:-11.7.0}"
PINNED_DESKTOP="$(manifest pinned.desktop)"; PINNED_DESKTOP="${PINNED_DESKTOP:-0.2.0-rc.2}"

mkdir -p "$ROOT" "$CACHE_DIR" "$NPM_PREFIX" "$LOG_DIR" "$BACKUP_ROOT" "$ASSET_CACHE" "$BIN_DIR"
: >"$LOG"
log "=== dsh-oneclick mac install $(date -u +%FT%TZ) mode=$MODE platform=$PLATFORM ==="

# ── assets ───────────────────────────────────────────────────────────────────
SUMS=""
load_sums() {
  local candidates=()
  [[ -n "$ASSETS" ]] && candidates+=("$ASSETS/SHA256SUMS.txt")
  candidates+=("$SCRIPT_DIR/assets/SHA256SUMS.txt")
  for c in "${candidates[@]}"; do
    if [[ -f "$c" ]]; then SUMS="$c"; break; fi
  done
  if [[ -z "$SUMS" && $OFFLINE -eq 0 ]]; then
    if curl -fsSL --max-time 60 "https://github.com/$REPO/releases/download/$TAG/SHA256SUMS.txt" -o "$ASSET_CACHE/SHA256SUMS.txt" 2>/dev/null; then
      SUMS="$ASSET_CACHE/SHA256SUMS.txt"
    else
      warn "SHA256SUMS.txt unavailable; downloads will not be verified"
    fi
  fi
  [[ -n "$SUMS" ]] && ok "SHA256SUMS loaded"
}

sha_state() { # file name -> 0 ok · 1 mismatch · 2 unchecked
  local file="$1" name="$2" want got
  [[ -z "$SUMS" ]] && return 2
  want="$(awk -v n="$name" '$2==n || $2=="*"n {print $1}' "$SUMS" | head -1)"
  [[ -z "$want" ]] && return 2
  got="$(shasum -a 256 "$file" | awk '{print $1}')"
  [[ "$want" == "$got" ]] && return 0
  return 1
}

get_asset() { # name [optional] -> prints the asset path on stdout, chatter on stderr
  local name="$1" optional="${2:-}"
  local p
  for p in ${ASSETS:+"$ASSETS/$name"} "$SCRIPT_DIR/assets/$name" "$ASSET_CACHE/$name"; do
    [[ -f "$p" ]] || continue
    sha_state "$p" "$name"
    case $? in
      0) ok "sha256 ok: $name" ;;
      1) warn "sha256 MISMATCH for local copy of $name - skipping $p"; continue ;;
      2) : ;; # no checksum available
    esac
    info "asset(local): $p"
    echo "$p"
    return 0
  done
  if [[ $OFFLINE -eq 1 ]]; then
    [[ -n "$optional" ]] && { warn "offline: optional asset missing -> $name"; return 1; }
    die "offline mode: required asset missing -> $name (looked in ${ASSETS:-assets/})"
  fi
  local url="https://github.com/$REPO/releases/download/$TAG/$name"
  if [[ -n "$MIRROR" ]]; then url="${MIRROR%/}/$url"; fi
  if [[ $DRY -eq 1 ]]; then info "[dry-run] would download $name"; return 1; fi
  info "downloading $name ..."
  log "download $url"
  curl -fL --retry 3 --connect-timeout 30 -o "$ASSET_CACHE/$name" "$url" || {
    [[ -n "$optional" ]] && { warn "download failed (optional): $name"; return 1; }
    die "download failed: $url"
  }
  local rc=0
  sha_state "$ASSET_CACHE/$name" "$name" || rc=$?
  case $rc in
    0) ok "sha256 ok: $name" ;;
    1) die "sha256 mismatch for $name (download corrupted, retry or use --mirror)" ;;
  esac
  echo "$ASSET_CACHE/$name"
}

# ── steps ────────────────────────────────────────────────────────────────────
preflight() {
  step "preflight"
  [[ "$(uname -s)" == "Darwin" ]] || die "macOS required"
  info "macOS $(sw_vers -productVersion) · $PLATFORM"
  local free
  free=$(df -g "$HOME" | awk 'NR==2 {print $4}')
  info "free space: ${free} GB"
  [[ "$free" -lt 5 ]] && warn "less than 5 GB free on $HOME"
  xcode-select -p >/dev/null 2>&1 || warn "Command Line Tools not found (only needed if a native dep must build)"
  ok "preflight passed"
}

install_node() {
  step "node $PINNED_NODE"
  if [[ -x "$NODE_DIR/bin/node" ]]; then
    local have; have="$("$NODE_DIR/bin/node" -v | sed 's/^v//')"
    if [[ "$have" == "$PINNED_NODE" && $FORCE -eq 0 ]]; then ok "node $have already installed"; return; fi
    info "node $have present, want $PINNED_NODE"
  fi
  local name; name="$(manifest "assets.node.$PLATFORM")"
  [[ -n "$name" ]] || die "no node asset mapped for $PLATFORM"
  local archive; archive="$(get_asset "$name")" || return 0
  local tmp="$ROOT/_stage_node"; rm -rf "$tmp"; mkdir -p "$tmp"
  if [[ $DRY -eq 1 ]]; then info "[dry-run] tar -xzf $archive -C $tmp"; return; fi
  tar -xzf "$archive" -C "$tmp" --strip-components 1
  rm -rf "$NODE_DIR"; mv "$tmp" "$NODE_DIR"
  local now; now="$("$NODE_DIR/bin/node" -v | sed 's/^v//')"
  [[ "$now" == "$PINNED_NODE" ]] || die "node version mismatch: $now"
  ok "node $now installed"
}

expand_cache() {
  step "offline npm cache"
  if [[ -f "$CACHE_DIR/.dsh-cache-ready" && $FORCE -eq 0 ]]; then ok "cache already expanded"; return; fi
  local archive; archive="$(get_asset "$(manifest assets.npmCache)")" || return 0
  [[ $DRY -eq 1 ]] && { info "[dry-run] expand $archive"; return; }
  local tmp="$ROOT/_stage_cache"; rm -rf "$tmp"; mkdir -p "$tmp"
  tar -xf "$archive" -C "$tmp" --strip-components 1
  rm -rf "$CACHE_DIR"; mv "$tmp" "$CACHE_DIR"
  date -u +%FT%TZ >"$CACHE_DIR/.dsh-cache-ready"
  ok "cache ready"
}

npm_run() {
  local has_offline=0
  if [[ $OFFLINE -eq 1 ]]; then has_offline=1; fi
  log "npm $*"
  if [[ $DRY -eq 1 ]]; then info "[dry-run] npm $*"; return 0; fi
  if [[ $has_offline -eq 1 ]]; then
    npm "$@" --prefix "$NPM_PREFIX" --cache "$CACHE_DIR" --offline --no-audit --no-fund --loglevel error \
      || { warn "npm $* failed (offline cache miss)"; return 1; }
  else
    npm "$@" --prefix "$NPM_PREFIX" --cache "$CACHE_DIR" --no-audit --no-fund --loglevel error \
      || npm "$@" --prefix "$NPM_PREFIX" --cache "$CACHE_DIR" --offline --no-audit --no-fund --loglevel error \
      || { warn "npm $* failed"; return 1; }
  fi
  return 0
}

install_packages() {
  step "dsh $PINNED_DSH / pnpm $PINNED_PNPM"
  export PATH="$NODE_DIR/bin:$NPM_PREFIX/bin:$PATH"
  export npm_config_cache="$CACHE_DIR"
  export npm_config_update_notifier=false
  local allow='@deepseek-ai/dsh-subprocess-local,koffi,node-pty,@google/genai,protobufjs'
  local cur=""
  if [[ -f "$NPM_PREFIX/lib/node_modules/@deepseek-ai/dsh/package.json" ]]; then
    cur="$(node -p "require('$NPM_PREFIX/lib/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || true)"
  fi
  if [[ "$cur" == "$PINNED_DSH" && $FORCE -eq 0 ]]; then
    ok "dsh $cur already installed"
  else
    npm_run install -g "@deepseek-ai/dsh@$PINNED_DSH" "--allow-scripts=$allow" || die "dsh install failed (offline cache incomplete)"
    ok "dsh $PINNED_DSH installed"
  fi
  local pv=""
  if [[ -f "$NPM_PREFIX/lib/node_modules/pnpm/package.json" ]]; then
    pv="$(node -p "require('$NPM_PREFIX/lib/node_modules/pnpm/package.json').version" 2>/dev/null || true)"
  fi
  if [[ "$pv" == "$PINNED_PNPM" && $FORCE -eq 0 ]]; then ok "pnpm $pv already installed"; else
    if npm_run install -g "pnpm@$PINNED_PNPM"; then ok "pnpm $PINNED_PNPM installed"
    else warn "pnpm $PINNED_PNPM unavailable offline; profile deps will be skipped (purge still applies)"; fi
  fi
}

install_purge_pkg() {
  [[ $SKIP_PURGE -eq 1 ]] && return 0
  step "dsh-purge $PINNED_PURGE"
  local cur=""
  if [[ -f "$NPM_PREFIX/lib/node_modules/dsh-purge/package.json" ]]; then
    cur="$(node -p "require('$NPM_PREFIX/lib/node_modules/dsh-purge/package.json').version" 2>/dev/null || true)"
  fi
  if [[ "$cur" == "$PINNED_PURGE" && $FORCE -eq 0 ]]; then ok "dsh-purge $cur already installed"; return; fi
  local tgz; tgz="$(get_asset "$(manifest assets.purge)")" || return 0
  if npm_run install -g "$tgz"; then ok "dsh-purge $PINNED_PURGE installed"
  else warn "dsh-purge install failed; copy payload/vendor/dsh-purge manually if needed"; fi
}

deploy_home() {
  step "deploy dsh home"
  local payload="$SCRIPT_DIR/payload/dsh-home"
  [[ -d "$payload" ]] || die "payload missing: $payload"
  if [[ -d "$DSH_HOME" ]]; then
    local stamp dest; stamp="$(date +%Y%m%d-%H%M%S)"; dest="$BACKUP_ROOT/dsh-home-$stamp"
    mkdir -p "$dest"
    ( cd "$DSH_HOME" && tar -cf - --exclude cache --exclude sessions --exclude storages --exclude dsh-runtimes . ) | tar -xf - -C "$dest"
    ok "backup dsh home -> $dest"
  fi
  run mkdir -p "$DSH_HOME/profiles/desktop" "$DSH_HOME/profiles/web" "$DSH_HOME/.lock"
  run cp -f "$payload/prompt-inject.md" "$DSH_HOME/prompt-inject.md"
  # the user patch layer always lands on the shipped `web` profile (that is what
  # a CLI/web-GUI boot uses; "desktop" is owned by the Electron app)
  run cp -f "$payload/profiles/desktop/cordis.patch.yml" "$DSH_HOME/profiles/web/cordis.patch.yml"
  ok "web profile patch deployed"
  if [[ "$MODE" == "desktop" ]]; then
    for f in cordis.yml cordis.patch.yml pnpm-workspace.yaml package.json; do
      run cp -f "$payload/profiles/desktop/$f" "$DSH_HOME/profiles/desktop/$f"
    done
    if [[ -d "$SCRIPT_DIR/payload/vendor/dsh-purge" ]]; then
      run rm -rf "$DSH_HOME/profiles/desktop/vendor/dsh-purge"
      run mkdir -p "$DSH_HOME/profiles/desktop/vendor"
      run cp -R "$SCRIPT_DIR/payload/vendor/dsh-purge" "$DSH_HOME/profiles/desktop/vendor/dsh-purge"
    fi
  else
    info "cli mode: desktop profile left to the Electron app"
  fi
  if [[ -f "$payload/lock/versions.json" ]]; then run cp -f "$payload/lock/versions.json" "$DSH_HOME/.lock/versions.json"; fi
  ok "dsh home deployed -> $DSH_HOME"
}

mcp_probe() {
  step "probe MCP servers"
  [[ -f "$SCRIPT_DIR/tools/gen-mcp.mjs" ]] || { warn "gen-mcp.mjs missing"; return; }
  local p
  for p in "$DSH_HOME/profiles/desktop/cordis.patch.yml" "$DSH_HOME/profiles/web/cordis.patch.yml"; do
    [[ -f "$p" ]] || continue
    if "$NODE_DIR/bin/node" "$SCRIPT_DIR/tools/gen-mcp.mjs" "$p" >/dev/null; then ok "MCP block regenerated: $(basename "$(dirname "$p")")"
    else warn "MCP probe failed for $p"; fi
  done
}

profile_deps() {
  step "install profile dependencies"
  if [[ ! -f "$DSH_HOME/profiles/desktop/package.json" ]]; then
    info "cli mode / no profile package.json - profile deps not needed"
    return 0
  fi
  local pnpm_cjs="$NPM_PREFIX/lib/node_modules/pnpm/bin/pnpm.cjs"
  [[ -f "$pnpm_cjs" ]] || { warn "pnpm.cjs missing; skipping"; return; }
  if [[ $DRY -eq 1 ]]; then info "[dry-run] pnpm install"; return; fi
  "$NODE_DIR/bin/node" "$pnpm_cjs" install --dir "$DSH_HOME/profiles/desktop" --config.confirmModulesPurge=false --reporter=append-only \
    && ok "profile dependencies installed" || warn "pnpm install failed (purge falls back to global install)"
}

apply_purge() {
  [[ $SKIP_PURGE -eq 1 ]] && return 0
  step "apply purge patch set"
  local bin="$NPM_PREFIX/bin/dsh-purge"
  [[ -x "$bin" ]] || { warn "dsh-purge shim missing"; return; }
  if [[ $DRY -eq 1 ]]; then info "[dry-run] dsh-purge --apply"; return; fi
  if "$bin" --apply >"$LOG_DIR/purge-apply.log" 2>&1; then ok "purge applied"; else warn "purge --apply exited $? (see logs/purge-apply.log)"; fi
}

install_desktop() {
  [[ "$MODE" == "desktop" ]] || return 0
  step "desktop shell $PINNED_DESKTOP"
  local name; name="$(manifest "assets.desktop.$PLATFORM")"
  [[ -n "$name" ]] || { warn "no desktop asset for $PLATFORM"; return 0; }
  local dmg; dmg="$(get_asset "$name")" || return 0
  if [[ -d "$APP_PATH" && $FORCE -eq 0 ]]; then
    ok "desktop app already present at $APP_PATH"
    disable_update
    return 0
  fi
  if [[ $DRY -eq 1 ]]; then info "[dry-run] hdiutil attach $dmg -> $APP_PATH"; return 0; fi
  local mnt="$ROOT/_mnt"; mkdir -p "$mnt" "$APP_DIR"
  hdiutil attach "$dmg" -nobrowse -readonly -mountpoint "$mnt" >/dev/null 2>&1 || die "hdiutil attach failed"
  local src; src="$(find "$mnt" -maxdepth 1 -name '*.app' | head -1)"
  if [[ -z "$src" ]]; then hdiutil detach "$mnt" >/dev/null 2>&1 || true; die "no .app inside dmg"; fi
  rm -rf "$APP_PATH"
  cp -R "$src" "$APP_PATH"
  hdiutil detach "$mnt" >/dev/null 2>&1 || true
  xattr -dr com.apple.quarantine "$APP_PATH" 2>/dev/null || true
  ok "desktop app installed -> $APP_PATH"
  disable_update
  return 0
}

pin_app_update() { # res dir
  # Renaming app-update.yml is not enough: the Electron shell restores it from
  # its asar on launch. Pin the feed to a dead URL and make the file read-only.
  local res="$1"
  [[ -d "$res" ]] || return 0
  local yml="$res/app-update.yml" orig="$res/app-update.yml.orig"
  if [[ ! -f "$yml" ]]; then
    if [[ -f "$res/app-update.yml.disabled" ]]; then
      mv -f "$res/app-update.yml.disabled" "$yml" 2>/dev/null || true
    fi
    if [[ ! -f "$yml" ]]; then info "no app-update.yml in $res"; return 0; fi
  fi
  if grep -q 'updates-disabled' "$yml" 2>/dev/null; then
    ok "auto-update already pinned: $(basename "$(dirname "$(dirname "$res")")")"
    return 0
  fi
  [[ -f "$orig" ]] || cp -f "$yml" "$orig" 2>/dev/null || true
  chmod 644 "$yml" 2>/dev/null || true
  if printf 'provider: generic\nurl: "http://127.0.0.1:9/updates-disabled/"\nchannel: disabled\nupdaterCacheDirName: disabled\n' > "$yml" 2>/dev/null; then
    chmod 444 "$yml" 2>/dev/null || true
    ok "auto-update pinned to a dead feed (read-only)"
  else
    warn "could not pin $yml (permission?)"
  fi
  rm -f "$res/app-update.yml.disabled" 2>/dev/null || true
  return 0
}

disable_update() {
  local app
  for app in "$APP_PATH" "/Applications/DeepSeek Harness.app"; do
    [[ -d "$app" ]] || continue
    if [[ $DRY -eq 1 ]]; then info "[dry-run] pin updates in $app"; continue; fi
    pin_app_update "$app/Contents/Resources"
  done
  return 0
}

write_lock() {
  step "pin versions"
  if [[ $DRY -eq 1 ]]; then info "[dry-run] write version lock"; return; fi
  local pkg="$NPM_PREFIX/lib/node_modules/@deepseek-ai/dsh/package.json"
  local hash=""
  if [[ -f "$pkg" ]]; then hash="$(shasum -a 256 "$pkg" | awk '{print $1}')"; fi
  cat >"$DSH_HOME/.lock/versions.json" <<JSON
{
  "schema": 1,
  "installer": "dsh-oneclick",
  "release": "$(manifest release)",
  "pinned": {
    "dsh": "$PINNED_DSH",
    "dshPurge": "$PINNED_PURGE",
    "desktop": "$PINNED_DESKTOP",
    "node": "$PINNED_NODE",
    "pnpm": "$PINNED_PNPM",
    "profile": "desktop"
  },
  "installedAt": "$(date -u +%FT%TZ)",
  "platform": "$PLATFORM",
  "paths": {
    "root": "$ROOT",
    "node": "$NODE_DIR",
    "npmPrefix": "$NPM_PREFIX",
    "npmCache": "$CACHE_DIR",
    "dshHome": "$DSH_HOME",
    "desktopDir": "$APP_PATH"
  },
  "integrity": { "dshPackageJsonSha256": "$hash" },
  "upgrades": { "desktop": "disabled", "dsh": "pinned", "purge": "pinned", "pnpm": "frozen" }
}
JSON
  cat >"$DSH_HOME/.lock/PINNED.txt" <<EOF
dsh           = $PINNED_DSH
dsh-purge     = $PINNED_PURGE
desktop shell = $PINNED_DESKTOP
node          = $PINNED_NODE
pnpm          = $PINNED_PNPM

Do not run: npm i -g @deepseek-ai/dsh@latest
Repair:     ~/.dsh-oneclick/bin/dsh-lock --repair
Verify:     ~/.dsh-oneclick/bin/dsh-oneclick-verify
EOF
  ok "version lock written"
}

write_launchers() {
  step "launchers"
  if [[ $DRY -eq 1 ]]; then info "[dry-run] write launchers"; return; fi
  cat >"$BIN_DIR/dsh-lock" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/node/bin:$ROOT/npm/bin:$PATH"
DSH="$ROOT/npm/bin/dsh"
LOCK="$HOME/.dsh/.lock/versions.json"
[[ -x "$DSH" ]] || { echo "dsh missing - run install.sh" >&2; exit 1; }
PKG="$ROOT/npm/lib/node_modules/@deepseek-ai/dsh/package.json"
PINNED="$(LOCK="$LOCK" node -e 'const fs=require("fs");try{console.log(JSON.parse(fs.readFileSync(process.env.LOCK,"utf8")).pinned.dsh)}catch{console.log("0.2.2-rc.5")}' 2>/dev/null || echo 0.2.2-rc.5)"
HAVE="$("$ROOT/node/bin/node" -p "require('$ROOT/npm/lib/node_modules/@deepseek-ai/dsh/package.json').version" 2>/dev/null || true)"
if [[ "${1:-}" == "--repair" ]]; then
  echo "repairing dsh -> $PINNED (offline cache)"
  "$ROOT/node/bin/npm" install -g --prefix "$ROOT/npm" --cache "$ROOT/npm-cache" --offline --no-audit --no-fund "@deepseek-ai/dsh@$PINNED"
  exit $?
fi
if [[ "$HAVE" != "$PINNED" ]]; then
  echo "  [!!] dsh drift: pinned=$PINNED actual=${HAVE:-none}" >&2
  echo "       run: dsh-lock --repair" >&2
fi
exec "$DSH" "$@"
SH
  chmod +x "$BIN_DIR/dsh-lock"

  cat >"$BIN_DIR/dsh-oneclick-verify" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="$ROOT/node/bin:$ROOT/npm/bin:$PATH"
exec bash "$ROOT/tools/verify.sh" --root "$ROOT"
SH
  chmod +x "$BIN_DIR/dsh-oneclick-verify"

  cat >"$BIN_DIR/dsh-web.command" <<'SH'
#!/usr/bin/env bash
exec "$HOME/.dsh-oneclick/bin/dsh-lock" web --port 19387
SH
  chmod +x "$BIN_DIR/dsh-web.command"
  ok "launchers -> $BIN_DIR"
}

write_env() {
  step "environment"
  if [[ $NOPATH -eq 1 ]]; then info "shell profile untouched (--no-path)"; return; fi
  local marker="# >>> dsh-oneclick >>>"
  local block
  block=$(cat <<EOF
$marker
export DSH_HOME="$DSH_HOME"
export DSH_PROFILE="desktop"
export DSH_ROUTER_BASE="\${DSH_ROUTER_BASE:-${ROUTER_BASE:-http://192.168.110.45:3425/v1}}"
export PATH="$BIN_DIR:$NPM_PREFIX/bin:$NODE_DIR/bin:\$PATH"
# <<< dsh-oneclick <<<
EOF
)
  if [[ -n "$ROUTER_KEY" ]]; then
    block="${block}"$'\n'"export DS9700_API_KEY=\"$ROUTER_KEY\""
  fi
  for rc in "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [[ -f "$rc" ]] || continue
    if [[ $DRY -eq 1 ]]; then info "[dry-run] update $rc"; continue; fi
    if grep -q "$marker" "$rc"; then
      # replace existing block without requiring python3
      local tmp; tmp="$(mktemp)"
      awk -v m="$marker" '
        $0==m {skip=1; next}
        skip && /# <<< dsh-oneclick <<</ {skip=0; next}
        !skip {print}
      ' "$rc" >"$tmp"
      printf '\n%s\n' "$block" >>"$tmp"
      mv "$tmp" "$rc"
    else
      printf '\n%s\n' "$block" >>"$rc"
    fi
    ok "updated $rc"
  done
  if [[ -n "$ROUTER_KEY" && $DRY -eq 0 ]]; then
    ok "DS9700_API_KEY written into the dsh-oneclick block of your shell profile"
  else
    info "no router key given: export DS9700_API_KEY=... later, or re-run with --router-key"
  fi
  return 0
}

install_tools() {
  step "install tools"
  if [[ $DRY -eq 1 ]]; then info "[dry-run] copy tools"; return 0; fi
  mkdir -p "$ROOT/tools"
  cp -R "$SCRIPT_DIR/tools/." "$ROOT/tools/" 2>/dev/null || true
  chmod +x "$ROOT/tools/"*.sh 2>/dev/null || true
  ok "tools -> $ROOT/tools"
  return 0
}

self_test() {
  step "self test"
  if [[ $DRY -eq 1 ]]; then info "[dry-run] self test"; return 0; fi
  export PATH="$NODE_DIR/bin:$NPM_PREFIX/bin:$PATH"
  local dsh="$NPM_PREFIX/bin/dsh"
  if [[ ! -x "$dsh" ]]; then warn "dsh shim missing"; return 0; fi
  local v; v="$("$dsh" --version 2>&1 | tr -d '\r' | tail -1)"
  [[ "$v" == *"$PINNED_DSH"* ]] && ok "dsh --version -> $v" || warn "dsh --version -> $v"

  local check="$SCRIPT_DIR/tools/check-yaml.mjs" pkg="$NPM_PREFIX/lib/node_modules/@deepseek-ai/dsh/package.json"
  if [[ -f "$check" ]]; then
    local f
    for f in "$DSH_HOME/profiles/web/cordis.patch.yml" "$DSH_HOME/profiles/desktop/cordis.patch.yml" "$DSH_HOME/profiles/desktop/cordis.yml"; do
      [[ -f "$f" ]] || continue
      local yrc=0
      "$NODE_DIR/bin/node" "$check" "$f" "$pkg" >/dev/null 2>&1 || yrc=$?
      case $yrc in
        0) ok "yaml ok: $(basename "$(dirname "$f")")/$(basename "$f")";;
        3) info "yaml check skipped (js-yaml unavailable)";;
        *) warn "yaml syntax error: $f";;
      esac
    done
  fi

  local dump; dump="$("$dsh" --profile web --dump-config 2>&1 | tr -d '\r' || true)"
  if [[ -n "$dump" && "$dump" == *id:* ]]; then
    ok "web profile composes"
    [[ "$dump" == *ds9700* ]] && ok "user patch layer applied" || warn "user patch layer not visible in dump"
  else warn "web profile dump-config failed"; fi

  if [[ $SKIP_PURGE -eq 0 && -x "$NPM_PREFIX/bin/dsh-purge" ]]; then
    local st; st="$("$NPM_PREFIX/bin/dsh-purge" 2>&1 | tr -d '\r' || true)"
    local ratio; ratio="$(printf '%s' "$st" | grep -oE '[0-9]+/[0-9]+' | head -1 | tr -d '\r' || true)"
    [[ -n "$ratio" ]] && ok "purge $ratio" || warn "purge state unreadable"
  fi
}

summary() {
  local reset=$'\033[0m'
  printf '\n%s─── done ───────────────────────────────────────────────────────────%s\n' "$c_cyan" "$reset"
  printf '  dsh      : %s\n' "$NPM_PREFIX/bin/dsh"
  printf '  launcher : %s\n' "$BIN_DIR/dsh-lock"
  printf '  web gui  : %s web --port 19387   (prints its token URL)\n' "$NPM_PREFIX/bin/dsh"
  printf '  gui app  : open "%s"\n' "$APP_PATH"
  printf '  verify   : %s\n' "$BIN_DIR/dsh-oneclick-verify"
  printf '  log      : %s\n' "$LOG"
  if ((${#WARNINGS[@]})); then
    printf '\n  %swarnings:%s\n' "$c_yellow" "$reset"
    for w in "${WARNINGS[@]}"; do printf '   - %s\n' "$w"; done
  fi
  printf '\n  open a new terminal (or: source ~/.zshrc) then run: dsh-lock web\n\n'
  return 0
}

main() {
  printf '\n%s dsh-oneclick  mode=%s  platform=%s  dryRun=%s %s\n' "$c_cyan" "$MODE" "$PLATFORM" "$DRY" "$c_reset"
  load_sums
  preflight
  install_node
  expand_cache
  install_packages
  install_purge_pkg
  deploy_home
  mcp_probe
  profile_deps
  apply_purge
  install_desktop
  write_lock
  install_tools
  write_launchers
  write_env
  self_test
  summary
}

main "$@"
