# NetMap

Real-time tire pressure monitoring system (TPMS) for fleet management. A native macOS/iOS app paired with a Swift backend server that collects BLE sensor telemetry, stores it, and visualizes it through the app and a web dashboard.

---

## Overview

```
┌───────────────────────────────────┐    HTTP/REST (batch)    ┌──────────────────────┐
│   NetMap App (SwiftUI)            │◄───────────────────────►│  NetMapServer        │
│                                   │   Port 8092 (default)   │  (Vapor 4, Swift)    │
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
| **GPS Tracker** | IMEI-based | Position, speed, satellites, journey events, driver behavior |

BLE sensors are identified by a stable MAC address extracted from their payload, stored as `TMS-AABBCC`. GPS trackers are identified by their IMEI. Both survive app reinstalls.

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
PORT=8092 DB_PATH=/var/lib/netmap/data.db API_KEY=your-key swift run App
```

First run in production: set `SETUP_SECRET` and call `POST /api/auth/setup` with header `X-Setup-Secret`.

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
| `GET` | `/api/sensors/latest` | X-API-Key or Bearer | Latest reading per sensor |
| `GET` | `/api/sensors/:id/puncture-risk` | — | Slow puncture risk score for a sensor |
| `POST` | `/api/sensors/pair` | X-API-Key | Register a sensor↔vehicle pairing |
| `DELETE` | `/api/sensors/pair/:sensorID` | X-API-Key or Admin | Remove a sensor pairing |
| `DELETE` | `/api/records/purge` | X-API-Key | Purge records (`?olderThanDays=90`) |

### Vehicles & Assets

`/api/assets` is an alias for `/api/vehicles`.

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/vehicles` | — | List all vehicles |
| `GET` | `/api/vehicles/:id` | — | Single vehicle detail |
| `POST` | `/api/vehicles` | Bearer + Admin | Create vehicle |
| `PATCH` | `/api/vehicles/:id` | Bearer + Admin | Update vehicle |
| `DELETE` | `/api/vehicles/:id` | Bearer + Admin | Delete vehicle |
| `GET` | `/api/asset-types` | — | Asset type catalog |
| `GET` | `/api/paired-sensors` | — | Sensor-to-vehicle associations |

### Vehicle Events & Journeys (GPS Trackers)

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `POST` | `/api/vehicle-events` | X-API-Key | Push event(s) from tracker (single or array) |
| `GET` | `/api/vehicle-events` | X-API-Key or Bearer | List events (filters: `vehicle`, `journey`, `imei`, `event_type`, `limit`) |
| `GET` | `/api/vehicle-events/journeys` | X-API-Key or Bearer | List journeys (`vehicle`, `limit`) |
| `DELETE` | `/api/vehicle-events/:id` | X-API-Key or Admin | Delete a single event |
| `DELETE` | `/api/vehicle-events/journeys/:journeyID` | X-API-Key or Admin | Delete all events in a journey |
| `DELETE` | `/api/vehicle-events` | X-API-Key or Admin | Delete events in period (`imei`, `from`, `to`) |

### Driver Behavior

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/driver-behavior` | X-API-Key or Bearer | List alerts (filters: `journey`, `vehicle`, `imei`, `alert_type`, `limit`) |
| `GET` | `/api/driver-behavior/summary` | X-API-Key or Bearer | Aggregated score for a journey |
| `DELETE` | `/api/driver-behavior/:id` | X-API-Key or Admin | Delete single alert |
| `DELETE` | `/api/driver-behavior` | X-API-Key or Admin | Delete alerts in period (`imei`, `from`, `to`) |

### Device Lifecycle

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/device-lifecycle` | X-API-Key or Bearer | List lifecycle events |
| `GET` | `/api/device-lifecycle/summary` | X-API-Key or Bearer | Summary per device |
| `DELETE` | `/api/device-lifecycle/:id` | X-API-Key or Admin | Delete single event |
| `DELETE` | `/api/device-lifecycle` | X-API-Key or Admin | Delete events in period (`imei`, `from`, `to`) |

### Admin

| Method | Endpoint | Auth | Description |
|--------|----------|------|-------------|
| `GET` | `/api/admin/security-events` | Bearer + Admin | Read-only security audit log (`action`, `actor_email`, `target_type`, `target_id`, `from`, `to`, `limit`, `offset`) |

### Misc

| Method | Endpoint | Description |
|--------|----------|-------------|
| `GET` | `/health` | Server health check |
| `GET` | `/` | Web dashboard |

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `8092` | HTTP listen port |
| `DB_PATH` | `netmap_data.db` | SQLite file path |
| `API_KEY` | `netmap-dev` | X-API-Key for sensor writes |
| `TRUSTED_PROXY_IPS` | `127.0.0.1,::1` | Comma-separated proxy IPs trusted for forwarded client IP (`X-Forwarded-For`) |
| `SETUP_SECRET` | — | Required in production for first admin bootstrap via `/api/auth/setup` (`X-Setup-Secret`) |
| `COOKIE_SECURE` | auto (`true` in production) | Force `Secure` attribute on auth session cookie |
| `TOKEN_TTL_DAYS` | `7` | User token/session lifetime in days |
| `SECURITY_EVENT_LOG_PATH` | `/var/log/netmap/security_events.log` | Append-only JSONL audit sink path |
| `SECURITY_EVENT_RETENTION_DAYS` | `90` | Purge security events older than this many days (`0` disables purge) |
| `ADMIN_USERNAME` | — | Auto-seed admin username (first run) |
| `ADMIN_PASSWORD` | — | Auto-seed admin password (first run) |

---

## Authentication Model

- **X-API-Key** — lightweight auth for sensor payloads sent by the app (telemetry writes)
- **Session cookie (`HttpOnly`, `SameSite=Strict`)** — browser dashboard authentication for admin operations.
- **Bearer token** — supported for API/iOS/tracker clients and admin endpoints. Tokens expire after `TOKEN_TTL_DAYS`.
- Passwords hashed with BCrypt.
- Non-admin Bearer users are automatically scoped to their linked assets on sensitive telemetry read endpoints.
- Privileged operations are recorded in append-only `security_events` audit logs (actor, action, target, metadata, IP).
- Audit entries include hash chaining (`prev_hash`, `event_hash`) and are mirrored to append-only JSONL file sink.

## CI Security Gates

- GitHub Actions workflow: [`.github/workflows/security.yml`](/Users/phil/Projects/NetMap/.github/workflows/security.yml)
- Includes:
  - Trivy filesystem vulnerability scan (fails on `HIGH`/`CRITICAL`)
  - Gitleaks secret scan
  - Semgrep SAST scan

> For production, place the server behind a TLS reverse proxy (Caddy or nginx). See `NetMapServer/Caddyfile` for a ready-to-use Caddy config.

---

## License

Private project — all rights reserved.
