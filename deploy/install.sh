#!/usr/bin/env bash
# =============================================================================
# NetMapServer — Bare metal install (Ubuntu 22.04 / 24.04 LTS)
# Must be run as root on the target server.
#
# Usage: sudo bash install.sh
#
# Optional environment variables:
#   PORT           NetMapServer listen port      (default: 8092)
#   API_KEY        Production API key            (default: auto-generated)
#   SETUP_SECRET   Secret for /auth/setup        (default: auto-generated)
#   ADMIN_USERNAME First admin email             (e.g. admin@example.com)
#   ADMIN_PASSWORD First admin password          (e.g. changeme123)
#   DATA_DIR       Data directory                (default: /opt/netmap/data)
#   NETMAP_DOMAIN  Public Caddy domain           (e.g. track.yourserver.com)
#   OTA_PORT       Public OTA port               (default: 9443)
#   OTA_INTERNAL_PORT Internal Flask/Gunicorn port (default: 9000)
# =============================================================================
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
APP_USER="netmap"
INSTALL_DIR="/opt/netmap"
SERVICE_NAME="netmap-server"
SWIFT_VERSION="6.0.3"          # https://swift.org/download/
PORT="${PORT:-8092}"
DATA_DIR="${DATA_DIR:-$INSTALL_DIR/data}"
API_KEY="${API_KEY:-$(openssl rand -hex 20)}"
SETUP_SECRET="${SETUP_SECRET:-$(openssl rand -hex 32)}"
NETMAP_DOMAIN="${NETMAP_DOMAIN:-}"
OTA_PORT="${OTA_PORT:-9443}"
OTA_INTERNAL_PORT="${OTA_INTERNAL_PORT:-9000}"

# Detect Ubuntu 22.04 vs 24.04
UBUNTU_RELEASE=$(lsb_release -rs 2>/dev/null || echo "22.04")
case "$UBUNTU_RELEASE" in
  24.04) SWIFT_PLATFORM="ubuntu2404" ; SWIFT_PLATFORM_NAME="ubuntu24.04" ;;
  *)     SWIFT_PLATFORM="ubuntu2204" ; SWIFT_PLATFORM_NAME="ubuntu22.04" ;;
esac

SWIFT_XZ="swift-${SWIFT_VERSION}-RELEASE-${SWIFT_PLATFORM_NAME}.tar.gz"
SWIFT_URL="https://download.swift.org/swift-${SWIFT_VERSION}-release/${SWIFT_PLATFORM}/swift-${SWIFT_VERSION}-RELEASE/${SWIFT_XZ}"
SWIFT_ROOT="/usr/local/swift"

# ── Colors ───────────────────────────────────────────────────────────────────
info()    { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
success() { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()    { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
die()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }

# ── Prerequisites ────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || die "This script must be run as root (sudo)."

info "Updating system packages..."
apt-get update -q
apt-get install -yq \
  binutils git gnupg2 libc6-dev libcurl4-openssl-dev \
  libedit2 libgcc-13-dev libsqlite3-dev libstdc++-13-dev \
  libxml2 libxml2-dev libz3-dev pkg-config tzdata unzip zlib1g-dev \
  curl rsync lsb-release openssl
ldconfig

# ── Dedicated system user ────────────────────────────────────────────────────
if ! id "$APP_USER" &>/dev/null; then
  info "Creating user $APP_USER..."
  useradd --system --shell /bin/false --home-dir "$INSTALL_DIR" --create-home "$APP_USER"
else
  info "User $APP_USER already exists."
fi

# ── Directories ──────────────────────────────────────────────────────────────
mkdir -p "$INSTALL_DIR"/{bin,Public} "$DATA_DIR"
chown -R "$APP_USER:$APP_USER" "$INSTALL_DIR" "$DATA_DIR"

# ── Swift toolchain ───────────────────────────────────────────────────────────
if "$SWIFT_ROOT/usr/bin/swift" --version 2>/dev/null | grep -q "$SWIFT_VERSION"; then
  success "Swift $SWIFT_VERSION already installed."
else
  info "Downloading Swift $SWIFT_VERSION for $SWIFT_PLATFORM_NAME..."
  TMP=$(mktemp -d)
  curl -fSL "$SWIFT_URL" -o "$TMP/$SWIFT_XZ"
  mkdir -p "$SWIFT_ROOT"
  tar -xf "$TMP/$SWIFT_XZ" --strip-components=1 -C "$SWIFT_ROOT"
  rm -rf "$TMP"
  success "Swift $SWIFT_VERSION installed to $SWIFT_ROOT."
fi

export PATH="$SWIFT_ROOT/usr/bin:$PATH"
swift --version

# ── Source: must be in $INSTALL_DIR/src ──────────────────────────────────────
SRC_DIR="$INSTALL_DIR/src"
if [[ ! -d "$SRC_DIR/Sources" ]]; then
  die "Sources not found in $SRC_DIR. Run deploy/update.sh first from your workstation."
fi

# ── Release build ────────────────────────────────────────────────────────────
info "Building in release mode..."
cd "$SRC_DIR"
swift build -c release 2>&1
BINARY=$(swift build -c release --show-bin-path 2>/dev/null)/App
[[ -f "$BINARY" ]] || die "Binary not found after build."

info "Installing binary..."
cp "$BINARY" "$INSTALL_DIR/bin/netmap-server"
chown "$APP_USER:$APP_USER" "$INSTALL_DIR/bin/netmap-server"
chmod 755 "$INSTALL_DIR/bin/netmap-server"

info "Syncing static files..."
rsync -a --delete "$SRC_DIR/Public/" "$INSTALL_DIR/Public/"
cp "$SRC_DIR/VERSION" "$INSTALL_DIR/VERSION"
chown -R "$APP_USER:$APP_USER" "$INSTALL_DIR/Public"

# ── Environment file ─────────────────────────────────────────────────────────
ENV_FILE="/etc/netmap/netmap-server.env"
mkdir -p /etc/netmap
if [[ ! -f "$ENV_FILE" ]]; then
  info "Creating environment file $ENV_FILE..."
  cat > "$ENV_FILE" <<EOF
PORT=$PORT
DB_PATH=$DATA_DIR/netmap_data.db
API_KEY=$API_KEY
SETUP_SECRET=$SETUP_SECRET
ADMIN_USERNAME=${ADMIN_USERNAME:-}
ADMIN_PASSWORD=${ADMIN_PASSWORD:-}
NETMAP_DOMAIN=$NETMAP_DOMAIN
OTA_PORT=$OTA_PORT
OTA_INTERNAL_PORT=$OTA_INTERNAL_PORT
EOF
  chmod 640 "$ENV_FILE"
  chown root:"$APP_USER" "$ENV_FILE"
  warn "Generated API_KEY     : $API_KEY  ← save this now, it will not be shown again."
  warn "Generated SETUP_SECRET: $SETUP_SECRET  ← save this now, it will not be shown again."
else
  info "Existing environment file preserved."
fi

# ── systemd service ──────────────────────────────────────────────────────────
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
info "Installing systemd service..."
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

# ── Verification ─────────────────────────────────────────────────────────────
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  success "NetMapServer started on port $PORT."
  success "Logs: journalctl -u $SERVICE_NAME -f"
else
  die "Service failed to start. Logs: journalctl -u $SERVICE_NAME -n 30"
fi

# Restore src ownership so the deploy user can rsync next time
DEPLOY_USER=$(stat -c '%U' "$(dirname "$SRC_DIR")" 2>/dev/null || echo "")
if [[ -n "$DEPLOY_USER" && "$DEPLOY_USER" != "root" ]]; then
  chown -R "$DEPLOY_USER:$DEPLOY_USER" "$SRC_DIR"
fi

echo ""
echo "════════════════════════════════════════════════════"
echo "  Installation complete"
echo "  URL      : http://$(hostname -I | awk '{print $1}'):$PORT"
echo "  Base DB  : $DATA_DIR/netmap_data.db"
echo "  Env      : $ENV_FILE"
echo "════════════════════════════════════════════════════"
