# NetMap

Real-time tire pressure monitoring system (TPMS) for fleet management. A native macOS/iOS app paired with a Swift backend server that collects BLE sensor telemetry, stores it, and visualizes it through the app and a web dashboard.

---

## Overview

```
┌───────────────────────────────────┐    HTTP/REST (batch)    ┌──────────────────────┐
│   NetMap App (SwiftUI)            │◄───────────────────────►│  NetMapServer        │
│                                   │   Port 8765 (default)   │  (Vapor 4, Swift)    │
│  • CoreBluetooth (BLE scanning)   │                         │                      │
│  • CoreLocation (GPS)             │  Auth: X-API-Key        │  SQLite database     │
│  • Fleet & sensor management      │       + Bearer token    │  Web dashboard       │
└───────────────────────────────────┘                         └──────────────────────┘
```

**Data flow:**
1. App scans BLE advertisements from TPMS sensors
2. Decodes pressure, temperature, and battery from proprietary frames
3. Batches readings and posts them to the server
4. Server persists data in SQLite and exposes it via REST API
5. App and web dashboard retrieve history and display charts/maps

---

## Tech Stack

| Component | Technology |
|-----------|-----------|
| App | Swift 5.9+, SwiftUI, CoreBluetooth, CoreLocation |
| Server | Swift 5.9+, Vapor 4, Fluent ORM, SQLite |
| Web dashboard | HTML5, CSS3, vanilla JS, Chart.js |

---

## Supported Sensors

| Hardware | Company ID | Data |
|----------|-----------|------|
| **Michelin TPMS** | Official spec | Pressure (bar), temp (°C), battery (V), tire state |
| **Stihl Smart Connector** | `0x03DD` | Pressure, temp, battery, HW/SW version |
| **Stihl Smart Battery** | `0x03DD` | Charge %, health %, cycles, discharge time |
| **ELA Innovation Beacons** | `0x0757` | Position (RSSI), temp, battery |
| **Apple AirTag** | iBeacon | RSSI-based proximity tracking |

Sensors are identified by a stable MAC address extracted from their BLE payload, stored as `TMS-AABBCC`. This survives app reinstalls since the CBPeripheral UUID rotates on iOS.

---

## Project Structure

```
NetMap/
├── NetMapApp/          # Xcode project (SwiftUI app)
│   └── NetMap/
│       ├── App/        # Entry point, AppDelegate, environment
│       ├── Models/     # BLEDevice, VehicleConfig
│       ├── Services/   # BLEScanner, LocationManager, VehicleStore, NetMapServerClient
│       └── Views/      # VehicleList, VehicleDetail, VehicleMap, SensorHistory, …
└── NetMapServer/       # Vapor 4 server
    ├── Sources/App/
    │   ├── Controllers/    # Auth, Vehicle, Record, Journey, DriverBehavior, …
    │   └── Models/         # SensorReading, User, UserToken, Vehicle, …
    └── Public/             # Web dashboard (HTML/CSS/JS)
```

---

## Getting Started

### Server

```bash
cd NetMapServer

# Development (SQLite in current directory)
swift run App

# With custom config
PORT=8765 DB_PATH=/var/lib/netmap/data.db API_KEY=your-key swift run App
```

First run: set `ADMIN_USERNAME` and `ADMIN_PASSWORD` env vars to auto-create the admin account.

### App

Open `NetMapApp/NetMap.xcodeproj` in Xcode, select the **NetMap** scheme, and run on macOS or a connected iOS device.

In the app's **Server Settings**, enter the server URL and API key.

---

## Server API

### Authentication

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/auth/status` | — | Check if first-run setup is needed |
| `POST` | `/api/auth/setup` | — | Create initial admin (first run only) |
| `POST` | `/api/auth/login` | — | Login → returns Bearer token |
| `POST` | `/api/auth/logout` | Bearer | Invalidate token |
| `GET` | `/api/auth/me` | Bearer | Current user info |

### Sensor Records

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/api/records` | X-API-Key | Insert single reading |
| `POST` | `/api/records/batch` | X-API-Key | Insert array of readings |
| `GET` | `/api/records` | — | List records (filters: `vehicle`, `sensor`, `brand`, `limit`) |
| `GET` | `/api/records/by-sensor/:id` | — | Sensor history (`from`/`to` ISO 8601) |
| `GET` | `/api/records/by-vehicle/:id` | — | Vehicle history |
| `GET` | `/api/sensors/latest` | — | Latest reading per sensor |
| `DELETE` | `/api/records/purge` | X-API-Key | Purge records (`?olderThanDays=90`) |

### Vehicles

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/vehicles` | — | List all vehicles |
| `POST` | `/api/vehicles` | Bearer + Admin | Create vehicle |
| `PATCH` | `/api/vehicles/:id` | Bearer + Admin | Update vehicle |
| `DELETE` | `/api/vehicles/:id` | Bearer + Admin | Delete vehicle |
| `GET` | `/api/asset-types` | — | Asset type catalog |
| `GET` | `/api/paired-sensors` | — | Sensor-to-vehicle associations |

### Misc

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Server health check |
| `GET` | `/` | Web dashboard |

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8765` | HTTP listen port |
| `DB_PATH` | `netmap_data.db` | SQLite file path |
| `API_KEY` | `netmap-dev` | X-API-Key for sensor writes |
| `ADMIN_USERNAME` | — | Auto-seed admin username (first run) |
| `ADMIN_PASSWORD` | — | Auto-seed admin password (first run) |

---

## Authentication Model

- **X-API-Key** — lightweight auth for sensor payloads sent by the app (telemetry writes)
- **Bearer token** — full user authentication for admin operations (vehicle CRUD, user management). Tokens expire after 7 days.
- Passwords hashed with BCrypt.

> For production, place the server behind a TLS reverse proxy (Caddy or nginx). See `NetMapServer/Caddyfile` for a ready-to-use Caddy config.

---

## License

Private project — all rights reserved.
