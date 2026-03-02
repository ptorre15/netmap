# NetMapServer

Serveur TCP/HTTP qui reçoit les données de capteurs BLE depuis l'app NetMap (iOS/macOS)  
et les stocke dans une base de données SQLite.

## Prérequis

- Swift 5.9+ (`swift --version`)
- macOS 13+ **ou** Linux (Ubuntu 22.04+)
- Linux uniquement : `sudo apt-get install libsqlite3-dev`

## Démarrage rapide

```bash
cd NetMapServer

# Compilation + lancement (port par défaut : 8765)
swift run App

# Port personnalisé
PORT=9000 swift run App

# Base de données dans un répertoire spécifique
DB_PATH=/var/lib/netmap/data.db swift run App
```

## Endpoints

| Méthode | URL | Description |
|---------|-----|-------------|
| GET  | `/health` | Statut serveur |
| POST | `/api/records` | Enregistrer un relevé |
| POST | `/api/records/batch` | Enregistrer plusieurs relevés (utilisé par l'app) |
| GET  | `/api/records` | Lister les relevés (`?limit=&vehicle=&sensor=&brand=`) |
| GET  | `/api/records/by-sensor/:sensorID` | Historique d'un capteur |
| GET  | `/api/records/by-vehicle/:vehicleID` | Historique d'un véhicule |
| DELETE | `/api/records/purge?older_than_days=30` | Purger les anciens relevés |

## Payload JSON (POST)

```json
{
  "sensorID":     "UUID-string",
  "vehicleID":    "UUID-string",
  "vehicleName":  "Mon Golf",
  "brand":        "michelin",
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
