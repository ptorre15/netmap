#!/usr/bin/env bash
# =============================================================================
# NetMapServer — Deploy an update from your workstation
#
# Usage: ./deploy/update.sh <user>@<host>
#   e.g. ./deploy/update.sh netmap@192.168.1.10
#        ./deploy/update.sh admin@your-server.example.com
#
# Prerequisites:
#   - passwordless SSH key access to the server
#   - Swift + systemd service already installed (deploy/install.sh)
# =============================================================================
set -euo pipefail

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "Usage: $0 <user>@<host>"; exit 1; }

SERVICE="netmap-server"
REMOTE_SRC="/opt/netmap/src"
REMOTE_BIN="/opt/netmap/bin/netmap-server"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"  # NetMapServer root

info()    { echo -e "\033[1;34m▶\033[0m  $*"; }
success() { echo -e "\033[1;32m✓\033[0m  $*"; }
die()     { echo -e "\033[1;31m✗\033[0m  $*" >&2; exit 1; }

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
swift build -c release 2>&1
BIN_PATH=$(swift build -c release --show-bin-path 2>/dev/null)/App
cp "$BIN_PATH" /tmp/netmap-server.new
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
sleep 2
sudo systemctl is-active --quiet $SERVICE && echo "Service running." || { echo "ERROR: service not running." ; sudo journalctl -u $SERVICE -n 20; exit 1; }
ENDSSH
success "NetMapServer updated and restarted."

echo ""
echo "Live logs: ssh $TARGET 'journalctl -u $SERVICE -f'"
