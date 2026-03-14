#!/usr/bin/env bash
# =============================================================================
# NetMapServer — Déploiement d'une mise à jour depuis macOS
#
# Usage : ./deploy/update.sh <user>@<host>
#   ex : ./deploy/update.sh netmap@192.168.1.10
#        ./deploy/update.sh admin@mon-serveur.example.com
#
# Prérequis :
#   - accès SSH sans mot de passe (clé publique) vers le serveur
#   - Swift + service systemd déjà installés (deploy/install.sh)
# =============================================================================
set -euo pipefail

TARGET="${1:-}"
[[ -n "$TARGET" ]] || { echo "Usage: $0 <user>@<host>"; exit 1; }

SERVICE="netmap-server"
REMOTE_SRC="/opt/netmap/src"
REMOTE_BIN="/opt/netmap/bin/netmap-server"
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"  # racine NetMapServer/

info()    { echo -e "\033[1;34m▶\033[0m  $*"; }
success() { echo -e "\033[1;32m✓\033[0m  $*"; }
die()     { echo -e "\033[1;31m✗\033[0m  $*" >&2; exit 1; }

# ── 1. Synchronisation des sources ───────────────────────────────────────────
info "Synchronisation des sources vers $TARGET:$REMOTE_SRC ..."
ssh "$TARGET" "mkdir -p $REMOTE_SRC"
rsync -az --delete \
  --exclude='.build/' \
  --exclude='*.db' \
  --exclude='.DS_Store' \
  "$SCRIPT_DIR/" "$TARGET:$REMOTE_SRC/"
success "Sources synchronisées."

# ── 2. Build release sur le serveur ──────────────────────────────────────────
info "Compilation sur le serveur (mode Release)..."
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
success "Build terminé."

# ── 3. Redémarrage à chaud ────────────────────────────────────────────────────
info "Redémarrage du service..."
ssh "$TARGET" bash <<ENDSSH
set -euo pipefail
# Fichiers statiques (no-group to avoid chgrp permission errors)
rsync -a --no-group --delete /opt/netmap/src/Public/ /opt/netmap/Public/
# Version file at working directory root (read by configure.swift on startup)
sudo cp /opt/netmap/src/VERSION /opt/netmap/VERSION
sudo chown -R netmap:netmap /opt/netmap/Public /opt/netmap/VERSION
# Remplacement atomique du binaire
sudo mv /tmp/netmap-server.new /opt/netmap/bin/netmap-server
sudo chmod 755 /opt/netmap/bin/netmap-server
sudo chown netmap:netmap /opt/netmap/bin/netmap-server
# Redémarrage
sudo systemctl restart $SERVICE
sleep 2
sudo systemctl is-active --quiet $SERVICE && echo "Service actif." || { echo "ERREUR: service inactif." ; sudo journalctl -u $SERVICE -n 20; exit 1; }
ENDSSH
success "NetMapServer mis à jour et redémarré."

echo ""
echo "Logs en direct : ssh $TARGET 'journalctl -u $SERVICE -f'"
