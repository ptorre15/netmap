# NetMap Vehicle Events API — Device Payload Specification (v6)

This document describes the JSON payload sent by the embedded device to the NetMap server via HTTP POST to `/api/vehicle-events`. It is intended as a reference for implementing or updating the server-side ingest logic.

---

## Transport

- **Method**: `POST`
- **URL**: `/api/vehicle-events`
- **Content-Type**: `application/json`
- **Auth header**: `X-API-Key: <api_key>`
- **Success response**: `201 Created`
- **Body**: a JSON **array** of one or more event objects (batch POST)

---

## Common fields (present in every event)

| Field | Type | Always present | Description |
|---|---|---|---|
| `imei` | string | ✅ | Device IMEI (15 digits) |
| `eventType` | string | ✅ | See event type table below |
| `timestamp` | string (ISO 8601 UTC) | when clock is valid | e.g. `"2026-03-06T14:32:00Z"`. Omitted if device has no time yet. |
| `gpsFixType` | integer | ✅ | Current GPS fix status: `0`=no fix, `2`=2D fix, `3`=3D fix, `4`=GNSS+dead-reckoning |

> **`gpsFixType` is new in v6** and is present in **every** event, including boot/sleep/wake. A value of `0` means no GPS fix at the time of the event. It does **not** indicate that position fields are absent — the device may supply a last-known position even when `gpsFixType=0` (see GPS fields below).

---

## GPS position fields (conditional)

Present only when the device has a position to report (lat or lon non-zero). For lifecycle events (boot, wake_up) this is the **last known position** retained from the previous session; `gpsFixType` will be `0` to indicate it is not a live fix.

| Field | Type | Description |
|---|---|---|
| `latitude` | number | WGS-84 decimal degrees |
| `longitude` | number | WGS-84 decimal degrees |
| `headingDeg` | number | Course over ground (degrees, 0–360) |
| `speedKmh` | number | Ground speed (km/h) |
| `gpsSatellites` | integer | Number of GPS satellites used (present when ≥ 0) |

---

## Event types

| `eventType` | Trigger | Extra fields |
|---|---|---|
| `boot` | Device power-on | `resetReason` |
| `sleep` | Device entering deep sleep | `batteryVoltageV`, GPS position, `speedKmh`, `headingDeg` |
| `wake_up` | Device waking from deep sleep | `wakeupSource`, `batteryVoltageV`, last-known GPS position |
| `journey_start` | Vehicle journey started | GPS, odometer, journey fields |
| `driving` | Periodic update while driving | GPS, odometer, journey fields, `engineRpm`, `fuelLevelPct` |
| `journey_end` | Vehicle journey ended | GPS, odometer, journey fields |
| `stopped` | Vehicle stopped | GPS, odometer |
| `idle_start` | Engine idling started | GPS |
| `idle_end` | Engine idling ended | GPS |
| `gps_acquired` | GPS fix first obtained | GPS |
| `gps_lost` | GPS fix lost | — |
| `driver_behavior` | Harsh driving alert | GPS, `driverBehaviorType`, `alertValueMax`, `alertDurationMs` |

---

## Optional fields by category

### Lifecycle

| Field | Type | Events | Description |
|---|---|---|---|
| `resetReason` | string | `boot` | `"POWERON"`, `"SW"`, `"PANIC"`, `"INT_WDT"`, `"TASK_WDT"`, `"WDT"`, `"DEEPSLEEP"`, `"BROWNOUT"`, `"SDIO"`, `"USB"`, `"JTAG"`, `"EFUSE"`, `"PWR_GLITCH"`, `"CPU_LOCKUP"` |
| `wakeupSource` | string | `wake_up` | `"NONE"`, `"POWER_ON"`, `"VOLTAGE_RISE"`, `"CAN_ACTIVITY"`, `"TIMER_BACKUP"`, `"ESPNOW_HMI"`, `"IMU_MOTION"`, `"UNKNOWN"` |
| `batteryVoltageV` | number | `sleep`, `wake_up` | Battery voltage in volts; omitted if unavailable |

### Vehicle / OBD

| Field | Type | Description |
|---|---|---|
| `odometerKm` | number | Total odometer (km); omitted if unavailable |
| `journeyDistanceKm` | number | Distance travelled this journey (km) |
| `journeyFuelConsumedL` | number | Fuel consumed this journey (L); omitted if unavailable |
| `engineRpm` | integer | Engine RPM; omitted if unavailable |
| `fuelLevelPct` | integer | Fuel tank level 0–100 %; omitted if unavailable |

### Driver identity

| Field | Type | Description |
|---|---|---|
| `driverIdent` | string | Driver identifier (iButton / NFC tag ID); omitted if no driver identified |

### Driver behavior (only for `driver_behavior` events)

| Field | Type | Description |
|---|---|---|
| `driverBehaviorType` | integer | Alert type code (0=accel, 1=brake, 2=cornering, 3=speeding, …) |
| `alertValueMax` | number | Peak value of the alert (km/h, g-force, rpm, or seconds depending on type) |
| `alertDurationMs` | integer | Duration of the alert in milliseconds |

---

## Timestamp correction (pre-sync events)

The device stores events immediately at startup before it has obtained real wall-clock time (via GPS or NTP). Such events are stored with an internal timestamp close to Unix epoch 0 (≈ seconds since boot). 

Before transmitting, the device corrects these timestamps: when the first reliable time sync occurs, it computes an offset (`wall_time_at_sync − uptime_seconds_at_sync`) and applies it to any stored timestamp below `1577836800` (2020-01-01). The server will therefore receive corrected ISO 8601 timestamps and does not need to handle epoch-0 values itself.

If the device never got a time sync before transmitting (rare degraded case), `timestamp` may be absent or very old — the server should treat events without a `timestamp` as having an unknown time.

---

## Example payloads

### Boot event (with last-known GPS position)
```json
[
  {
    "imei": "123456789012345",
    "eventType": "boot",
    "timestamp": "2026-03-06T14:00:01Z",
    "gpsFixType": 0,
    "latitude": 45.9992,
    "longitude": 6.1227,
    "resetReason": "POWERON"
  }
]
```

### Sleep event (with live GPS)
```json
[
  {
    "imei": "123456789012345",
    "eventType": "sleep",
    "timestamp": "2026-03-06T15:30:00Z",
    "gpsFixType": 3,
    "latitude": 45.9991,
    "longitude": 6.1226,
    "headingDeg": 270.5,
    "speedKmh": 0.0,
    "gpsSatellites": 9,
    "batteryVoltageV": 12.4
  }
]
```

### Driving event
```json
[
  {
    "imei": "123456789012345",
    "eventType": "driving",
    "timestamp": "2026-03-06T15:00:00Z",
    "gpsFixType": 3,
    "latitude": 45.9985,
    "longitude": 6.1230,
    "headingDeg": 91.2,
    "speedKmh": 62.5,
    "gpsSatellites": 11,
    "odometerKm": 12345.6,
    "journeyDistanceKm": 3.2,
    "journeyFuelConsumedL": 0.31,
    "engineRpm": 2100,
    "fuelLevelPct": 74,
    "driverIdent": "A1B2C3D4"
  }
]
```

### Driver behavior event
```json
[
  {
    "imei": "123456789012345",
    "eventType": "driver_behavior",
    "timestamp": "2026-03-06T15:05:12Z",
    "gpsFixType": 3,
    "latitude": 45.9978,
    "longitude": 6.1245,
    "headingDeg": 88.0,
    "speedKmh": 95.0,
    "gpsSatellites": 10,
    "driverBehaviorType": 3,
    "alertValueMax": 95.0,
    "alertDurationMs": 4200
  }
]
```

---

## Changes vs v5

| Change | Detail |
|---|---|
| **`gpsFixType` added** | New integer field present in **every** event. Values: `0`=no fix, `2`=2D, `3`=3D, `4`=GNSS+DR. |
| **`has_fix` removed** | The legacy boolean `has_fix` field is gone from the device. Use `gpsFixType > 0` as the equivalent check. If the server stored `has_fix`, migrate to `gpsFixType != 0`. |
| **GPS on boot/wake** | `boot` and `wake_up` events now include `latitude`/`longitude` when a previous session position is available (retained RAM). `gpsFixType` will be `0` for these. |
| **GPS on sleep** | `sleep` events now include full GPS fields (`latitude`, `longitude`, `speedKmh`, `headingDeg`, `gpsSatellites`, `gpsFixType`) captured at sleep time. |
| **DB table version** | Internal persistent storage bumped from `netmap_events_v5` to `netmap_events_v6`. Old events in v5 format will not be re-sent (different table name). |
