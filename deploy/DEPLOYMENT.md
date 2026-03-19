# NetMapServer — Bare metal deployment (Linux)

Supported targets: **Ubuntu 22.04 LTS** and **Ubuntu 24.04 LTS**.

Architecture:
- **Vapor 4** listens on `localhost:8092` (not directly exposed)
- **Caddy** serves HTTPS on port 443, reverse-proxies to Vapor
- The domain and all secrets are injected via **environment variables** — no sensitive values in the repository

---

## Prerequisites

- Linux server with root access
- SSH key-based access from your workstation
- Ports `80` and `443` open (Caddy + Let's Encrypt)
- Fixed or known public IP (for the domain name)

---

## First install

### 1. Copy sources to the server

From your workstation, inside the `NetMapServer/` folder:

```bash
SERVER=admin@192.168.1.x   # adjust to your server

ssh $SERVER "mkdir -p /opt/netmap/src"
rsync -az --exclude='.build/' --exclude='*.db' --exclude='.DS_Store' \
  ./ $SERVER:/opt/netmap/src/
```

### 2. Run the install script

On the server, pass your values as an environment prefix (anything not provided is auto-generated):

```bash
NETMAP_DOMAIN=track.yourserver.com \
ADMIN_USERNAME=admin@example.com \
ADMIN_PASSWORD=strongpassword \
sudo -E bash /opt/netmap/src/deploy/install.sh
```

> `API_KEY` and `SETUP_SECRET` are automatically generated via `openssl rand` and displayed **once** in the console — note them immediately.

The script automatically performs:

| Step | Detail |
|---|---|
| System dependencies | `libsqlite3-dev`, `libcurl4-openssl-dev`, etc. |
| Swift 6.0.3 | Installed to `/usr/local/swift` |
| System user | `netmap` (no shell) |
| Directories | `/opt/netmap/{bin,Public,data}` |
| Build | `swift build -c release` |
| Env file | `/etc/netmap/netmap-server.env` (created on first install, never overwritten) |
| systemd service | `netmap-server` enabled and started |

---

## Environment variables

The file `/etc/netmap/netmap-server.env` is created **once** by `install.sh` (never overwritten by updates).
It is mode `640`, owned by `root:netmap` — only the service can read it, never committed to git.

See [`.env.example`](../.env.example) for the full documented list of all variables.
Essential variables:

| Variable | Default / generation | Description |
|---|---|---|
| `PORT` | `8092` | Vapor TCP listen port (local only) |
| `DB_PATH` | `/opt/netmap/data/netmap_data.db` | SQLite database path |
| `API_KEY` | `openssl rand -hex 20` | API key required by the iOS app (**shown once**) |
| `SETUP_SECRET` | `openssl rand -hex 32` | Secret for `POST /api/auth/setup` (**shown once**) |
| `ADMIN_USERNAME` | *(pass at install time)* | First admin account email |
| `ADMIN_PASSWORD` | *(pass at install time)* | First admin account password |
| `NETMAP_DOMAIN` | *(pass at install time)* | Public domain served by Caddy |
| `OTA_PORT` | `9443` | Public OTA server port (ESP32) |
| `OTA_INTERNAL_PORT` | `9000` | Internal Flask/Gunicorn port |

To modify a value after installation:

```bash
sudo nano /etc/netmap/netmap-server.env
sudo systemctl restart netmap-server
```

---

## Caddy (HTTPS reverse proxy)

Caddy is installed separately and handles TLS automatically via Let's Encrypt.

```bash
# Install Caddy on Ubuntu
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update && apt-get install -y caddy
```

The `Caddyfile` uses environment variables — no need to edit it. Copy it and set the variables before starting Caddy:

```bash
cp /opt/netmap/src/Caddyfile /etc/caddy/Caddyfile
```

Add the Caddy variables to `/etc/caddy/caddy.env` (create the file):

```bash
NETMAP_DOMAIN=track.yourserver.com
PORT=8092
OTA_PORT=9443
OTA_INTERNAL_PORT=9000
```

Configure the Caddy service to read this file (`/etc/systemd/system/caddy.service.d/override.conf`):

```ini
[Service]
EnvironmentFile=/etc/caddy/caddy.env
```

```bash
systemctl daemon-reload && systemctl reload caddy
```

> Required open ports: **80** TCP (Let's Encrypt challenge) and **443** TCP (HTTPS).

---

## Updates

### Supported path: GitHub Actions deploy workflow

Use the `Deploy` workflow from the GitHub Actions UI. This is the primary and supported deploy process.

It performs the following steps:
1. Bumps the version in CI
2. Builds the Linux release binary in CI
3. Deploys matching `VERSION`, `Public/`, and binary artifacts
4. Restarts the service
5. Verifies `GET /health`
6. Opens or updates the follow-up version bump PR

Required GitHub configuration:
- `production` environment
- secrets: `DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_USER`, `NETMAP_DOMAIN`

### Legacy fallback: workstation script

The workstation script is now deprecated and should be used only as an emergency fallback when GitHub Actions is unavailable.

From your workstation, inside the `NetMapServer/` folder:

```bash
NETMAP_ALLOW_LEGACY_UPDATE=1 ./deploy/update.sh admin@192.168.1.x
```

This legacy script:
1. Syncs sources via `rsync`
2. Builds in release mode **on the server**
3. Atomically replaces the binary
4. Restarts the service
5. Verifies local `GET /health`

It is intentionally no longer the default path because it does not provide the same reproducibility, approvals, and artifact traceability as the GitHub Actions workflow.

---

## Useful commands (on the server)

```bash
# Service status
sudo systemctl status netmap-server

# Live logs
sudo journalctl -u netmap-server -f

# Last 50 log lines
sudo journalctl -u netmap-server -n 50

# Manual restart
sudo systemctl restart netmap-server

# Stop
sudo systemctl stop netmap-server
```

---

## Directory structure (on the server)

```
/opt/netmap/
├── bin/
│   └── netmap-server        ← compiled binary
├── data/
│   └── netmap_data.db       ← SQLite database (back this up)
├── Public/
│   ├── index.html
│   ├── app.js
│   └── style.css
└── src/                     ← synced sources
    ├── Sources/
    ├── Public/
    └── Package.swift

/etc/netmap/
├── netmap-server.env        ← environment variables (PORT, DB_PATH, API_KEY, SETUP_SECRET, …)
└── caddy.env                ← Caddy variables (NETMAP_DOMAIN, PORT, OTA_PORT, …)
```

---

## Backup

The only file to back up is the database:

```bash
/opt/netmap/data/netmap_data.db
```

Exemple de sauvegarde quotidienne via cron (`crontab -e` en root) :

```cron
0 3 * * * cp /opt/netmap/data/netmap_data.db /opt/netmap/data/netmap_data.db.$(date +\%Y\%m\%d)
```
