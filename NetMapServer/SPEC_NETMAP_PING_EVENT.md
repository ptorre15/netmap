# NetMap Ping Event — Server Implementation Spec

## Purpose

The device sends a `ping` event at a configurable interval (default **60 seconds**,
range 10–3600 s) whenever the NetMap reporter is active.  Unlike journey events,
the ping carries **position data only** — its sole purpose is to provide a
continuous heartbeat and GPS track even when no journey is in progress.

---

## HTTP Request

```
POST <server_url>/api/vehicle-events
Content-Type: application/json
X-API-Key: <api_key>
```

The ping is batched with any other pending events using the standard JSON array
envelope.  The server must accept it in the same endpoint as all other event types.

---

## JSON Payload

The ping event shares the same JSON object structure as every other event type.
Fields that are unavailable for a ping are **omitted** entirely (never sent as `null`).

### Always-present fields

| Field        | Type   | Example                    | Notes                           |
|--------------|--------|----------------------------|---------------------------------|
| `imei`       | string | `"351561118065313"`        | Device identifier               |
| `eventType`  | string | `"ping"`                   | Fixed value                     |
| `timestamp`  | string | `"2025-07-04T12:00:00Z"`   | ISO 8601 UTC                    |
| `gpsFixType` | number | `3`                        | 0=no fix, 2=2D, 3=3D, 4=GNSS+DR |

### Conditional GPS fields (present when a valid fix exists)

| Field            | Type   | Example      | Notes                         |
|------------------|--------|--------------|-------------------------------|
| `latitude`       | number | `48.8566`    | WGS-84, decimal degrees       |
| `longitude`      | number | `2.3522`     | WGS-84, decimal degrees       |
| `headingDeg`     | number | `270.0`      | Degrees, 0=North              |
| `speedKmh`       | number | `0.0`        | km/h                          |
| `gpsSatellites`  | number | `8`          | Visible satellites used in fix |

All GPS fields are omitted together when `latitude == 0.0 && longitude == 0.0`
(GPS not yet acquired or fix lost).

### Fields never present in a ping

The following fields are **never included** in a ping event.  Server code must
not expect them:

- `odometerKm`
- `journeyDistanceKm`
- `journeyFuelConsumedL`
- `engineRpm`
- `fuelLevelPct`
- `driverBehaviorType`, `alertValueMax`, `alertDurationMs`
- `systemInfoInt`, `batteryVoltageV`

---

## Example Payload

```json
[
  {
    "imei": "351561118065313",
    "eventType": "ping",
    "timestamp": "2025-07-04T12:00:00Z",
    "latitude": 48.8566,
    "longitude": 2.3522,
    "headingDeg": 270.0,
    "speedKmh": 0.0,
    "gpsSatellites": 8,
    "gpsFixType": 3
  }
]
```

Example when GPS fix is not yet available:

```json
[
  {
    "imei": "351561118065313",
    "eventType": "ping",
    "timestamp": "2025-07-04T12:00:00Z",
    "gpsFixType": 0
  }
]
```

---

## Server Handling Recommendations

1. **Upsert device last-seen**: use the ping to update a `last_seen` timestamp
   and last known position for the device, independently of journey state.

2. **Do not create journey records**: a ping must not trigger a journey start.
   It must be ignored by any journey state machine.

3. **Geo-history / breadcrumb**: if the server stores a position history, the
   ping can be inserted as a passive breadcrumb point (distinct from driving
   track points).

4. **Dead-reckoning detection**: if no ping is received for > 2× the configured
   interval, treat the device as potentially offline or sleeping.

5. **Response**: return `201 Created` on success.  The device will retain the
   event in persistent storage and retry until it receives `201`.

---

## Firmware Configuration

| Kconfig symbol              | Default | Range      | Description                  |
|-----------------------------|---------|------------|------------------------------|
| `CONFIG_NETMAP_PING_INTERVAL_SEC` | `60` | `10–3600` | Seconds between ping events |

The timer starts immediately after `netmap_reporter_init()` (early boot).  The
first ping fires after the first full interval, so approximately 60 s after boot.
