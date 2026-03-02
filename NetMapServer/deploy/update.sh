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
swift build -c release 2>&1
BIN_PATH=$(swift build -c release --show-bin-path 2>/dev/null)/App
cp "$BIN_PATH" /opt/netmap/bin/netmap-server.new
ENDSSH
success "Build terminé."

# ── 3. Redémarrage à chaud ────────────────────────────────────────────────────
info "Redémarrage du service..."
ssh "$TARGET" bash <<ENDSSH
set -euo pipefail
# Fichiers statiques
rsync -a --delete /opt/netmap/src/Public/ /opt/netmap/Public/
chown -R netmap:netmap /opt/netmap/Public
# Remplacement atomique du binaire
mv /opt/netmap/bin/netmap-server.new /opt/netmap/bin/netmap-server
chmod 755 /opt/netmap/bin/netmap-server
# Redémarrage
systemctl restart $SERVICE
sleep 2
systemctl is-active --quiet $SERVICE && echo "Service actif." || { echo "ERREUR: service inactif." ; journalctl -u $SERVICE -n 20; exit 1; }
ENDSSH
success "NetMapServer mis à jour et redémarré."

echo ""
echo "Logs en direct : ssh $TARGET 'journalctl -u $SERVICE -f'"
