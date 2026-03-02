#!/usr/bin/env bash
# =============================================================================
# NetMapServer — Installation bare metal (Ubuntu 22.04 / 24.04 LTS)
# À exécuter en tant que root sur le serveur cible.
#
# Usage : sudo bash install.sh
#
# Variables d'environnement optionnelles :
#   PORT         Port d'écoute          (défaut : 8765)
#   API_KEY      Clé API production     (défaut : auto-générée)
#   DATA_DIR     Répertoire des données (défaut : /opt/netmap/data)
# =============================================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_USER="netmap"
INSTALL_DIR="/opt/netmap"
SERVICE_NAME="netmap-server"
SWIFT_VERSION="6.0.3"          # https://swift.org/download/
PORT="${PORT:-8765}"
DATA_DIR="${DATA_DIR:-$INSTALL_DIR/data}"
API_KEY="${API_KEY:-$(openssl rand -hex 20)}"

# Détecte Ubuntu 22.04 vs 24.04
UBUNTU_RELEASE=$(lsb_release -rs 2>/dev/null || echo "22.04")
case "$UBUNTU_RELEASE" in
  24.04) SWIFT_PLATFORM="ubuntu2404" ; SWIFT_PLATFORM_NAME="ubuntu24.04" ;;
  *)     SWIFT_PLATFORM="ubuntu2204" ; SWIFT_PLATFORM_NAME="ubuntu22.04" ;;
esac

SWIFT_XZ="swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM}.tar.gz"
SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM}/swift-${SWIFT_VERSION}-RELEASE/${SWIFT_XZ}"
SWIFT_ROOT="/usr/local/swift"

# ── Couleurs ──────────────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ── Prérequis ─────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "Ce script doit être exécuté en tant que root (sudo)."

info "Mise à jour des paquets système..."
apt-get update -q
apt-get install -yq \
  binutils git gnupg2 libc6-dev libcurl4-openssl-dev \
  libedit2 libgcc-13-dev libsqlite3-dev libstdc++-13-dev \
  libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev \
  curl rsync lsb-release openssl

# ── Utilisateur dédié ─────────────────────────────────────────────────────────
if ! id "$APP_USER" &>/dev/null; then
  info "Création de l'utilisateur $APP_USER..."
  useradd --system --shell /bin/false --home-dir "$INSTALL_DIR" --create-home "$APP_USER"
else
  info "Utilisateur $APP_USER déjà présent."
fi

# ── Répertoires ───────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"/{bin,Public} "$DATA_DIR"
chown -R "$APP_USER:$APP_USER" "$INSTALL_DIR" "$DATA_DIR"

# ── Swift toolchain ───────────────────────────────────────────────────────────
if "$SWIFT_ROOT/usr/bin/swift" --version 2>/dev/null | grep -q "$SWIFT_VERSION"; then
  success "Swift $SWIFT_VERSION déjà installé."
else
  info "Téléchargement de Swift $SWIFT_VERSION pour $SWIFT_PLATFORM_NAME..."
  TMP=$(mktemp -d)
  curl -fSL "$SWIFT_URL" -o "$TMP/$SWIFT_XZ"
  mkdir -p "$SWIFT_ROOT"
  tar -xf "$TMP/$SWIFT_XZ" --strip-components=1 -C "$SWIFT_ROOT"
  rm -rf "$TMP"
  success "Swift $SWIFT_VERSION installé dans $SWIFT_ROOT."
fi

export PATH="$SWIFT_ROOT/usr/bin:$PATH"
swift --version

# ── Source : doit être dans $INSTALL_DIR/src ──────────────────────────────────
SRC_DIR="$INSTALL_DIR/src"
if [[ ! -d "$SRC_DIR/Sources" ]]; then
  die "Sources non trouvées dans $SRC_DIR. Lancez d'abord deploy/update.sh depuis votre Mac."
fi

# ── Build release ─────────────────────────────────────────────────────────────
info "Compilation en mode Release..."
cd "$SRC_DIR"
swift build -c release 2>&1
BINARY=$(swift build -c release --show-bin-path 2>/dev/null)/App
[[ -f "$BINARY" ]] || die "Binaire introuvable après build."

info "Installation du binaire..."
cp "$BINARY" "$INSTALL_DIR/bin/netmap-server"
chown "$APP_USER:$APP_USER" "$INSTALL_DIR/bin/netmap-server"
chmod 755 "$INSTALL_DIR/bin/netmap-server"

info "Synchronisation des fichiers statiques..."
rsync -a --delete "$SRC_DIR/Public/" "$INSTALL_DIR/Public/"
chown -R "$APP_USER:$APP_USER" "$INSTALL_DIR/Public"

# ── Fichier d'environnement ───────────────────────────────────────────────────
ENV_FILE="/etc/netmap/netmap-server.env"
mkdir -p /etc/netmap
if [[ ! -f "$ENV_FILE" ]]; then
  info "Création du fichier d'environnement $ENV_FILE..."
  cat > "$ENV_FILE" <<EOF
PORT=$PORT
DB_PATH=$DATA_DIR/netmap_data.db
API_KEY=$API_KEY
EOF
  chmod 640 "$ENV_FILE"
  chown root:"$APP_USER" "$ENV_FILE"
  warn "API_KEY générée : $API_KEY  ← notez-la, elle ne sera plus affichée."
else
  info "Fichier d'environnement existant conservé."
fi

# ── Service systemd ───────────────────────────────────────────────────────────
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
info "Installation du service systemd..."
cat > "$UNIT_FILE" <<EOF
[Unit]
Description=NetMapServer (Vapor)
After=network.target

[Service]
Type=simple
User=$APP_USER
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$INSTALL_DIR/bin/netmap-server serve --env production
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=netmap-server
# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=$DATA_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME"
systemctl restart "$SERVICE_NAME"

# ── Vérification ──────────────────────────────────────────────────────────────
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  success "NetMapServer démarré sur le port $PORT."
  success "Logs : journalctl -u $SERVICE_NAME -f"
else
  die "Le service n'a pas démarré. Logs : journalctl -u $SERVICE_NAME -n 30"
fi

echo ""
echo "════════════════════════════════════════════════════"
echo "  Installation terminée"
echo "  URL      : http://$(hostname -I | awk '{print $1}'):$PORT"
echo "  Base DB  : $DATA_DIR/netmap_data.db"
echo "  Env      : $ENV_FILE"
echo "════════════════════════════════════════════════════"
