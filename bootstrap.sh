#!/usr/bin/env bash
# dsh-oneclick · macOS one-line bootstrap
#   curl -fsSL https://raw.githubusercontent.com/jaydenchen969-bit/dsh-oneclick/main/bootstrap.sh | bash
#   curl -fsSL .../bootstrap.sh | bash -s -- --mode desktop --force
set -euo pipefail

REPO="${DSH_ONECLICK_REPO:-jaydenchen969-bit/dsh-oneclick}"
BRANCH="${DSH_ONECLICK_BRANCH:-main}"
URL="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

echo ""
echo "  dsh-oneclick bootstrap (${REPO}@${BRANCH})"
echo ""

TMP="$(mktemp -d "${TMPDIR:-/tmp}/dsh-oneclick.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
tar -xzf <(curl -fsSL --retry 3 "$URL") -C "$TMP" --strip-components=1
chmod +x "$TMP/install.sh"
bash "$TMP/install.sh" "$@"
