#!/usr/bin/env bash
# dsh-oneclick · macOS health check
# exit 0 healthy · 2 warnings · 1 broken
set -uo pipefail

ROOT="${HOME}/.dsh-oneclick"
DSH_HOME="${HOME}/.dsh"
GUI_PORT=19387
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="$2"; shift 2;;
    --dsh-home) DSH_HOME="$2"; shift 2;;
    --port) GUI_PORT="$2"; shift 2;;
    *) echo "unknown: $1" >&2; exit 2;;
  esac
done
issues=0; warns=0
head() { printf '\n\033[36m%s\033[0m\n' "$1"; }
pass() { printf '  \033[32m[ok]\033[0m %s\n' "$1"; }
warn() { warns=$((warns+1)); printf '  \033[33m[!!]\033[0m %s\n' "$1"; }
bad()  { issues=$((issues+1)); printf '  \033[31m[xx]\033[0m %s\n' "$1"; }

LOCK="$DSH_HOME/.lock/versions.json"
PIN_DSH="0.2.2-rc.5"
if [[ -f "$LOCK" ]]; then
  v="$(node -e 'const fs=require("fs");try{const j=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.stdout.write(j.pinned.dsh)}catch{}' "$LOCK" 2>/dev/null || true)"
  [[ -n "$v" ]] && PIN_DSH="$v"
fi

head versions
PKG="$ROOT/npm/lib/node_modules/@deepseek-ai/dsh/package.json"
if [[ -f "$PKG" ]]; then
  HAVE="$(node -p "require('$PKG').version" 2>/dev/null || echo unknown)"
  [[ "$HAVE" == "$PIN_DSH" ]] && pass "dsh $HAVE (pinned)" || warn "dsh $HAVE != pinned $PIN_DSH (dsh-lock --repair)"
else bad "dsh package missing"; fi

PURGE_PKG="$ROOT/npm/lib/node_modules/dsh-purge/package.json"
if [[ -f "$PURGE_PKG" ]]; then
  PV="$(node -p "require('$PURGE_PKG').version" 2>/dev/null || echo unknown)"
  pass "dsh-purge $PV"
else warn "dsh-purge missing"; fi

if [[ -x "$ROOT/node/bin/node" ]]; then pass "node $("$ROOT/node/bin/node" -v)"; else bad "node runtime missing"; fi

head 'purge patches'
if [[ -x "$ROOT/npm/bin/dsh-purge" ]]; then
  st="$("$ROOT/npm/bin/dsh-purge" 2>&1 || true)"
  rev="$(printf '%s' "$st" | grep -o 'apply:[^ ]*' | head -1)"
  applied="$(printf '%s' "$st" | grep -c 'applied' || true)"
  pending="$(printf '%s' "$st" | grep -o '[0-9]\+ *待清洗' | grep -o '^[0-9]\+' || true)"
  [[ -n "$rev" ]] && pass "state $rev, $applied applied" || warn 'purge state unreadable'
  [[ -n "$pending" && "$pending" -gt 0 ]] && warn "$pending patches pending -> dsh-purge --apply"
else bad 'dsh-purge shim missing'; fi

head 'anti-upgrade'
APP="/Applications/DeepSeek Harness.app"
if [[ -d "$APP" ]]; then
  RES="$APP/Contents/Resources"
  if [[ -f "$RES/app-update.yml.disabled" && ! -f "$RES/app-update.yml" ]]; then pass 'desktop auto-update disabled'
  elif [[ -f "$RES/app-update.yml" ]]; then warn 'desktop auto-update still active'
  else pass 'no auto-update feed present'; fi
else
  printf '  (cli mode - no desktop app)\n'
fi

head 'dsh home'
for f in prompt-inject.md profiles/desktop/cordis.yml profiles/desktop/cordis.patch.yml profiles/desktop/package.json; do
  [[ -f "$DSH_HOME/$f" ]] && pass "$f" || bad "missing $f"
done
[[ -f "$DSH_HOME/profiles/desktop/vendor/dsh-purge/package.json" ]] && pass 'purge vendored' || warn 'purge vendor missing'

head 'profile composition'
if [[ -x "$ROOT/npm/bin/dsh" ]]; then
  if "$ROOT/npm/bin/dsh" --profile desktop --dump-config >/dev/null 2>&1; then pass 'dump-config ok'; else bad 'dump-config failed'; fi
else bad 'dsh shim missing'; fi

head gui
if lsof -nP -iTCP:"$GUI_PORT" -sTCP:LISTEN >/dev/null 2>&1; then pass "listening on $GUI_PORT"; else warn "nothing on $GUI_PORT (start the app first)"; fi

echo
if [[ $issues -gt 0 ]]; then printf '  RESULT: %d error(s), %d warning(s)\n' "$issues" "$warns"; exit 1
elif [[ $warns -gt 0 ]]; then printf '  RESULT: healthy with %d warning(s)\n' "$warns"; exit 2
else printf '  RESULT: healthy\n'; exit 0; fi
