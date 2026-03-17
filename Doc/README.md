# NetMapServer

TCP/HTTP server that receives BLE sensor data from the NetMap app (iOS/macOS)
and stores it in a SQLite database.

## Prerequisites

- Swift 5.9+ (`swift --version`)
- macOS 13+ **ou** Linux (Ubuntu 22.04+)
- Linux uniquement : `sudo apt-get install libsqlite3-dev`

## Quick start

```bash
cd NetMapServer

# Build + run (default port: 8765)
swift run App

# Port personnalisé
PORT=9000 swift run App

# Database in a specific directory
DB_PATH=/var/lib/netmap/data.db swift run App

# Configuration sécurité recommandée
API_KEY=change-me SETUP_SECRET=change-me-too swift run App

# Proxy trust (if running behind reverse proxy on another host/IP)
TRUSTED_PROXY_IPS=127.0.0.1,::1,10.0.0.5 swift run App

# Audit log sink + retention
SECURITY_EVENT_LOG_PATH=/var/log/netmap/security_events.log SECURITY_EVENT_RETENTION_DAYS=90 swift run App
```

## Endpoints

| Method | URL | Description |
|--------|-----|-------------|
| GET  | `/health` | Server status |
| POST | `/api/records` | Submit a reading |
| POST | `/api/records/batch` | Submit multiple readings (used by the app) |
| GET  | `/api/records` | List readings (`?limit=&vehicle=&sensor=&brand=`) |
| GET  | `/api/records/by-sensor/:sensorID` | Sensor history |
| GET  | `/api/records/by-vehicle/:vehicleID` | Vehicle history |
| DELETE | `/api/records/purge?older_than_days=30` | Purge old readings |

## Payload JSON (POST)

```json
{
  "sensorID":     "UUID-string",
  "vehicleID":    "UUID-string",
  "vehicleName":  "Mon Golf",
  "brand":        "tpms",
  "wheelPosition": "FL",
  "pressureBar":  2.35,
  "temperatureC": 23.5,
  "vbattVolts":   3.10,
  "latitude":     48.8566,
  "longitude":    2.3522,
  "timestamp":    "2026-03-01T12:00:00Z"
}
```

## Service systemd (Linux)

```ini
[Unit]
Description=NetMapServer
After=network.target

[Service]
WorkingDirectory=/opt/netmapserver
ExecStart=/opt/netmapserver/.build/release/App
Environment=PORT=8765
Environment=DB_PATH=/var/lib/netmap/data.db
Restart=on-failure

[Install]
WantedBy=multi-user.target
```
