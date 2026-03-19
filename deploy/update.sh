#!/usr/bin/env bash
# =============================================================================
# NetMapServer — Legacy workstation deploy (fallback only)
#
# This script is intentionally NOT the primary deploy path anymore.
# The supported deploy flow is the GitHub Actions "Deploy" workflow, which:
#   - bumps version in CI
#   - builds the Linux binary in CI
#   - deploys matching VERSION/Public/binary artifacts
#   - verifies /health after restart
#
# Usage (legacy fallback only):
#   NETMAP_ALLOW_LEGACY_UPDATE=1 ./deploy/update.sh <user>@<host>
# =============================================================================
set -euo pipefail

warn() { echo -e "\033[1;33m!\033[0m  $*"; }

if [[ "${NETMAP_ALLOW_LEGACY_UPDATE:-0}" != "1" ]]; then
  cat >&2 <<'EOF'
Legacy workstation deploy is deprecated.

Use the GitHub Actions "Deploy" workflow instead.

If you explicitly need the old emergency fallback path, rerun with:
  NETMAP_ALLOW_LEGACY_UPDATE=1 ./deploy/update.sh <user>@<host>
EOF
  exit 1
fi

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "Usage: $0 <user>@<host>"; exit 1; }

SERVICE="netmap-server"
REMOTE_SRC="/opt/netmap/src"
REMOTE_BIN="/opt/netmap/bin/netmap-server"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"  # NetMapServer root

info()    { echo -e "\033[1;34m▶\033[0m  $*"; }
success() { echo -e "\033[1;32m✓\033[0m  $*"; }
die()     { echo -e "\033[1;31m✗\033[0m  $*" >&2; exit 1; }

warn "Using deprecated legacy deploy path. Prefer the GitHub Actions Deploy workflow."

# ── 0. Bump version ──────────────────────────────────────────────────────────
info "Bumping patch version..."
"$SCRIPT_DIR/bump-version.sh" patch

# ── 1. Sync sources ──────────────────────────────────────────────────────────
info "Syncing sources to $TARGET:$REMOTE_SRC ..."
ssh "$TARGET" "mkdir -p $REMOTE_SRC"
rsync -az --delete \
  --exclude='.build/' \
  --exclude='*.db' \
  --exclude='.DS_Store' \
  "$SCRIPT_DIR/" "$TARGET:$REMOTE_SRC/"
success "Sources synced."

# ── 2. Release build on the server ──────────────────────────────────────────
info "Building on server (release mode)..."
ssh "$TARGET" bash <<'ENDSSH'
set -euo pipefail
export PATH="/usr/local/swift/usr/bin:$PATH"
cd /opt/netmap/src
# Clear any stale build lock from a previous failed build
sudo rm -f /tmp/_opt_netmap_src_*.lock
# Fix #8: build once; binary is always at .build/release/App for a single-target package
swift build -c release 2>&1
cp .build/release/App /tmp/netmap-server.new
ENDSSH
success "Build complete."

# ── 3. Hot restart ───────────────────────────────────────────────────────────
info "Restarting service..."
ssh "$TARGET" bash <<ENDSSH
set -euo pipefail
# Fichiers statiques — copy as root then fix ownership
sudo cp -a /opt/netmap/src/Public/. /opt/netmap/Public/
# Version file at working directory root (read by configure.swift on startup)
sudo cp /opt/netmap/src/VERSION /opt/netmap/VERSION
sudo chown -R netmap:netmap /opt/netmap/Public /opt/netmap/VERSION
# Atomic binary replacement
sudo mv /tmp/netmap-server.new /opt/netmap/bin/netmap-server
sudo chmod 755 /opt/netmap/bin/netmap-server
sudo chown netmap:netmap /opt/netmap/bin/netmap-server
# Restart
sudo systemctl restart $SERVICE
sleep 3
curl -sf --retry 5 --retry-delay 2 \
  "http://127.0.0.1:8092/health" > /dev/null \
  && echo "Service healthy." \
  || { echo "ERROR: service health check failed." ; sudo journalctl -u $SERVICE -n 20; exit 1; }
ENDSSH
success "NetMapServer updated and restarted."

echo ""
echo "Live logs: ssh $TARGET 'journalctl -u $SERVICE -f'"
