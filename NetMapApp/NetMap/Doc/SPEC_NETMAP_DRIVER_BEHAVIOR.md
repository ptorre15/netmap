# NetMapServer — Driver Behavior Events: Server-Side Implementation Spec

> This spec is a delta on top of the existing `POST /api/vehicle-events` API
> described in `README_JOURNEY_API.md`.  Read that document first.
> Implement only what is described here — do not modify existing event handling.

---

## Context

The embedded device (ESP32 net-hub) already sends `journey_start`, `driving`,
and `journey_end` events to `POST /api/vehicle-events`.

A new event type `driver_behavior` has been added on the device side.
It is emitted once each time a driving alert ends (harsh acceleration, hard
braking, cornering, overspeed, over-revving, or prolonged idling).

The server must:
1. Accept `driver_behavior` events at the **existing** `POST /api/vehicle-events`
   endpoint (no new ingest endpoint).
2. Store them in a **new table** `driver_behavior_events` (separate from
   `vehicle_events` to avoid sparse nullable columns).
3. Link each event to the active `journeyID` exactly as `driving` events are.
4. Expose read endpoints for querying alerts per journey and per vehicle.

---

## 1. New event type

`eventType = "driver_behavior"` is accepted at `POST /api/vehicle-events`
alongside the existing types.  It must **not** affect journey state-machine
logic (does not open or close a journey).

---

## 2. Incoming JSON payload

The device sends `driver_behavior` events as part of the existing batch array.
Fields already present on all events (`imei`, `timestamp`, GPS, etc.) keep
their exact semantics.  Three new fields are added exclusively for this event
type:

| Field | Type | Required | Description |
|---|---|---|---|
| `imei` | string | **Yes** | IMEI of the tracker |
| `eventType` | string | **Yes** | Must be `"driver_behavior"` |
| `timestamp` | ISO 8601 UTC string | Yes | Timestamp of alert **start** on device |
| `latitude` | number | Yes | GPS latitude at alert start (WGS-84) |
| `longitude` | number | Yes | GPS longitude at alert start (WGS-84) |
| `headingDeg` | number | No | Heading at alert start (degrees, 0 = North) |
| `speedKmh` | number | No | Speed at alert start (km/h) |
| `driverBehaviorType` | integer | **Yes** | Alert type — see enum below |
| `alertValueMax` | number | **Yes** | Peak measured value — unit depends on type |
| `alertDurationMs` | integer | **Yes** | Duration of the alert in milliseconds |

### `driverBehaviorType` enum

These integer values are sent by the device as-is (`alert_type_t` from
`driver_behavior.c`). The server must map them to a canonical string name for
storage and API responses.

| Integer | String key | `alertValueMax` unit | Description |
|---|---|---|---|
| `1` | `revving` | RPM | Engine over-rev |
| `2` | `braking` | m/s² (positive = deceleration) | Hard braking |
| `3` | `acceleration` | m/s² | Harsh acceleration |
| `4` | `cornering` | m/s² | Lateral g-force in corner |
| `5` | `idling` | seconds | Prolonged idle |
| `6` | `overspeed` | km/h | Speed threshold exceeded |

Any unknown integer must be stored with string key `"unknown"` — do not reject.

### Example payload

```jsonc
// Single driver_behavior event (may also arrive inside a batch array)
{
  "imei":               "357312098765432",
  "eventType":          "driver_behavior",
  "timestamp":          "2026-03-02T08:22:14Z",

  "latitude":           48.8590,
  "longitude":          2.3540,
  "headingDeg":         112.0,
  "speedKmh":           87.3,

  "driverBehaviorType": 3,
  "alertValueMax":      4.21,
  "alertDurationMs":    1340
}
```

```jsonc
// Mixed batch — driving events and one driver_behavior event together
[
  { "imei": "357312098765432", "eventType": "driving",         "timestamp": "2026-03-02T08:22:00Z",
    "latitude": 48.8580, "longitude": 2.3530, "speedKmh": 74.0, "journeyDistanceKm": 3.2 },
  { "imei": "357312098765432", "eventType": "driver_behavior", "timestamp": "2026-03-02T08:22:14Z",
    "latitude": 48.8590, "longitude": 2.3540, "speedKmh": 87.3,
    "driverBehaviorType": 3, "alertValueMax": 4.21, "alertDurationMs": 1340 },
  { "imei": "357312098765432", "eventType": "driving",         "timestamp": "2026-03-02T08:22:20Z",
    "latitude": 48.8595, "longitude": 2.3548, "speedKmh": 65.0, "journeyDistanceKm": 3.5 }
]
```

---

## 3. Database schema

Create a new table.  Do not add columns to the existing `vehicle_events` table.

```sql
CREATE TABLE IF NOT EXISTS driver_behavior_events (
    id                  TEXT PRIMARY KEY,   -- UUID assigned by the server
    imei                TEXT NOT NULL,      -- IMEI of the tracker
    journey_id          TEXT NOT NULL,      -- resolved from active journey (same logic as driving)
    vehicle_id          TEXT NOT NULL,      -- resolved from IMEI (same logic as all events)
    vehicle_name        TEXT NOT NULL,
    event_type          TEXT NOT NULL DEFAULT 'driver_behavior',
    alert_type_int      INTEGER NOT NULL,   -- raw driverBehaviorType from device
    alert_type          TEXT NOT NULL,      -- mapped string key (e.g. "acceleration")
    alert_value_max     REAL NOT NULL,      -- peak value
    alert_duration_ms   INTEGER NOT NULL,   -- duration in ms
    timestamp           REAL NOT NULL,      -- Unix timestamp UTC (alert start on device)
    latitude            REAL,
    longitude           REAL,
    heading_deg         REAL,
    speed_kmh           REAL,
    received_at         REAL NOT NULL       -- server reception time (Unix UTC)
);

-- Recommended indexes
CREATE INDEX IF NOT EXISTS idx_dbe_journey  ON driver_behavior_events (journey_id);
CREATE INDEX IF NOT EXISTS idx_dbe_vehicle  ON driver_behavior_events (vehicle_id);
CREATE INDEX IF NOT EXISTS idx_dbe_imei     ON driver_behavior_events (imei);
CREATE INDEX IF NOT EXISTS idx_dbe_ts       ON driver_behavior_events (timestamp);
```

---

## 4. JourneyID resolution

Reuse the **exact same logic** already used for `driving` events:

1. Look up the most recent `journey_id` in `vehicle_events` for this IMEI.
2. If a journey is open (no `journey_end` yet), use that `journey_id`.
3. If no journey is open, use `"no-journey"` as a sentinel value — **do not
   create a new journey** and do not reject the event.

---

## 5. VehicleID / vehicleName resolution

Reuse the existing logic exactly (same as `driving` events):
- Look up `sensorID = <imei>` in `sensor_readings`, take `vehicleID` and
  `vehicleName`.
- If IMEI is unknown: `vehicleID = imei`, `vehicleName = "Tracker <imei>"`.

---

## 6. Read endpoints

### 6a. All driver behavior events for a journey

```
GET /api/driver-behavior?journey={journeyID}
X-API-Key: (not required for reads)
```

Optional query parameters:

| Parameter | Description |
|---|---|
| `journey=UUID` | Filter by journeyID (**recommended**) |
| `vehicle=UUID` | Filter by vehicleID |
| `imei=string` | Filter by IMEI |
| `alert_type=acceleration` | Filter by string alert type |
| `limit=N` | Max results (default: 500) |

Response — array sorted by `timestamp` ascending:

```jsonc
[
  {
    "id":             "b3f7c821-...",
    "journeyID":      "A3E8F721-...",
    "vehicleID":      "47AC3E8E-...",
    "vehicleName":    "Phil's car",
    "alertType":      "acceleration",
    "alertTypeInt":   3,
    "alertValueMax":  4.21,
    "alertDurationMs": 1340,
    "timestamp":      "2026-03-02T08:22:14Z",
    "latitude":       48.8590,
    "longitude":      2.3540,
    "headingDeg":     112.0,
    "speedKmh":       87.3
  }
]
```

HTTP `200 OK`.  Empty array if no matching events.

---

### 6b. Driver behavior summary per journey

```
GET /api/driver-behavior/summary?journey={journeyID}
```

Aggregates all alerts for the journey into a score card.

Response:

```jsonc
{
  "journeyID":        "A3E8F721-...",
  "vehicleID":        "47AC3E8E-...",
  "vehicleName":      "Phil's car",
  "totalAlerts":      7,
  "byType": {
    "acceleration":   { "count": 2, "maxValue": 4.21, "totalDurationMs": 2900 },
    "braking":        { "count": 3, "maxValue": 5.80, "totalDurationMs": 4100 },
    "cornering":      { "count": 1, "maxValue": 3.10, "totalDurationMs": 800  },
    "overspeed":      { "count": 1, "maxValue": 142.0,"totalDurationMs": 12000 },
    "revving":        { "count": 0 },
    "idling":         { "count": 0 }
  }
}
```

Alert types with zero occurrences may be omitted or included — either is
acceptable.  HTTP `200 OK`.  Return the same shape with `totalAlerts: 0` and
empty `byType` if no events.

---

## 7. Validation and error handling

| Condition | Response |
|---|---|
| `driverBehaviorType` missing or not an integer | `400 Bad Request` with message `"driverBehaviorType required (integer)"` |
| `alertValueMax` missing | `400 Bad Request` |
| `alertDurationMs` missing or negative | `400 Bad Request` |
| Unknown `driverBehaviorType` integer | Accept — store with `alert_type = "unknown"` |
| `eventType = "driver_behavior"` without GPS (`latitude`/`longitude`) | Accept — store with `latitude = NULL`, `longitude = NULL` |

All other validation rules (auth, JSON structure) remain unchanged from the
existing endpoint.

---

## 8. Non-goals (out of scope for this implementation)

- Scoring algorithms or driver ranking — not part of this spec
- Push notifications or webhooks — not part of this spec
- Modifying the existing `vehicle_events` table schema
- A new ingest endpoint — all ingestion goes through the existing
  `POST /api/vehicle-events`

---

## 9. Test cases

The implementer must verify these scenarios:

1. **Single driver_behavior event** in isolation → stored with correct
   `alert_type` string, linked to current open journey.
2. **Mixed batch** containing `driving` + `driver_behavior` events → both
   event types stored correctly, `driving` in `vehicle_events`,
   `driver_behavior` in `driver_behavior_events`.
3. **driver_behavior with no open journey** → stored with `journey_id =
   "no-journey"`, no error.
4. **Unknown `driverBehaviorType`** (e.g. `99`) → accepted, stored with
   `alert_type = "unknown"`.
5. **Missing `alertDurationMs`** → `400` returned, nothing stored.
6. **`GET /api/driver-behavior?journey=UUID`** → returns correct subset,
   sorted ascending, correct field names.
7. **`GET /api/driver-behavior/summary?journey=UUID`** → correct `count`,
   `maxValue`, `totalDurationMs` per type.
