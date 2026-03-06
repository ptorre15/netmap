# NetMapServer — Device Lifecycle Events: Server-Side Implementation Spec

> This spec is a delta on top of the existing `POST /api/vehicle-events` API
> described in `README_JOURNEY_API.md`.  Read that document first.
> Implement only what is described here — do not modify existing event handling.

---

## Context

The embedded device (ESP32 net-hub) now emits three new event types that
report its power lifecycle:

| `eventType` | When emitted by the device |
|---|---|
| `boot` | Power-on reset only (`ESP_RST_POWERON`) |
| `sleep` | Immediately before entering deep sleep |
| `wake_up` | Immediately after waking from deep sleep |

These events arrive at the **existing** `POST /api/vehicle-events` endpoint
inside the normal batch array, mixed with `driving` / `journey_start` /
`journey_end` events.

The server must:
1. Accept `boot`, `sleep`, and `wake_up` events — no new ingest endpoint.
2. Store them in a **new table** `device_lifecycle_events` (separate from
   `vehicle_events` to keep that table's schema clean).
3. Expose read endpoints to query lifecycle history per device.

---

## 1. New event types

Three new values for the `eventType` field are added:

- `"boot"` — device performed a cold power-on reset.
- `"sleep"` — device is about to enter deep sleep.
- `"wake_up"` — device has just resumed from deep sleep.

They must **not** affect journey state-machine logic (do not open or close
a journey, do not update `lastJourneyID`).

---

## 2. Incoming JSON payloads

### 2a. `boot`

Sent once at device startup when the reset cause is a hardware power-on.

| Field | Type | Required | Description |
|---|---|---|---|
| `imei` | string | **Yes** | IMEI of the tracker |
| `eventType` | string | **Yes** | `"boot"` |
| `timestamp` | ISO 8601 UTC | Yes | Device wall-clock time at boot |
| `resetReason` | string | **Yes** | See reset reason strings below |

`timestamp` may be inaccurate (RTC not yet synced) — store as-is.

**Reset reason strings** sent by the device:

| String | Meaning |
|---|---|
| `"POWERON"` | Normal power-on (VCC applied) |
| `"SW"` | Software reset (`esp_restart()`) |
| `"PANIC"` | Firmware crash / assertion failure |
| `"INT_WDT"` | Interrupt watchdog timeout |
| `"TASK_WDT"` | Task watchdog timeout |
| `"WDT"` | Generic watchdog |
| `"BROWNOUT"` | Power supply brownout detected |
| `"DEEPSLEEP"` | Wake from deep sleep (will not appear for `boot`; included for completeness) |
| `"EXT"` | External reset pin |
| `"UNKNOWN"` | Unknown cause |

Store the string as-is.  Unknown strings must be accepted without error.

**Example:**

```jsonc
{
  "imei":        "357312098765432",
  "eventType":   "boot",
  "timestamp":   "2026-03-03T07:00:01Z",
  "resetReason": "POWERON"
}
```

---

### 2b. `sleep`

Sent just before the device powers down its modem and enters deep sleep.
The HTTP POST is performed synchronously before sleep, so delivery is
best-effort (no retry if the connection is down at that moment).

| Field | Type | Required | Description |
|---|---|---|---|
| `imei` | string | **Yes** | IMEI of the tracker |
| `eventType` | string | **Yes** | `"sleep"` |
| `timestamp` | ISO 8601 UTC | Yes | Device wall-clock time at sleep entry |
| `batteryVoltageV` | number | No | Battery voltage in volts at sleep entry |

**Example:**

```jsonc
{
  "imei":             "357312098765432",
  "eventType":        "sleep",
  "timestamp":        "2026-03-03T19:45:22Z",
  "batteryVoltageV":  12.4
}
```

---

### 2c. `wake_up`

Sent at the start of each full wakeup from deep sleep, after the modem
reconnects.

| Field | Type | Required | Description |
|---|---|---|---|
| `imei` | string | **Yes** | IMEI of the tracker |
| `eventType` | string | **Yes** | `"wake_up"` |
| `timestamp` | ISO 8601 UTC | Yes | Device wall-clock time at wakeup (may lag real time by a few seconds while modem syncs) |
| `wakeupSource` | string | **Yes** | See wakeup source strings below |
| `batteryVoltageV` | number | No | Battery voltage in volts just after wakeup |

**Wakeup source strings** sent by the device:

| String | Trigger |
|---|---|
| `"VOLTAGE_RISE"` | ULP coprocessor detected battery voltage > 13.5 V (engine start) |
| `"CAN_ACTIVITY"` | CAN bus activity detected on RX GPIO (EXT1 wakeup) |
| `"TIMER_BACKUP"` | 30-minute backup timer expired (periodic heartbeat) |
| `"ESPNOW_HMI"` | HMI device sent an ESP-NOW wake request (user interaction) |
| `"POWER_ON"` | First boot after power-on (should be rare here; `boot` is preferred) |
| `"NONE"` | Wakeup cause could not be determined |
| `"UNKNOWN"` | Unrecognised cause |

Store the string as-is.  Unknown strings must be accepted without error.

**Example:**

```jsonc
{
  "imei":             "357312098765432",
  "eventType":        "wake_up",
  "timestamp":        "2026-03-04T06:55:10Z",
  "wakeupSource":     "VOLTAGE_RISE",
  "batteryVoltageV":  13.9
}
```

---

### 2d. Mixed batch example

Lifecycle events arrive in the same batch array as journey events:

```jsonc
[
  { "imei": "357312098765432", "eventType": "wake_up",
    "timestamp": "2026-03-04T06:55:10Z",
    "wakeupSource": "VOLTAGE_RISE", "batteryVoltageV": 13.9 },
  { "imei": "357312098765432", "eventType": "journey_start",
    "timestamp": "2026-03-04T06:55:30Z",
    "latitude": 48.8566, "longitude": 2.3522, "speedKmh": 0 },
  { "imei": "357312098765432", "eventType": "driving",
    "timestamp": "2026-03-04T06:55:45Z",
    "latitude": 48.8572, "longitude": 2.3530, "speedKmh": 24.0 }
]
```

Each item in the batch is processed independently.  `wake_up` goes to
`device_lifecycle_events`; the others go to `vehicle_events` as usual.

---

## 3. Database schema

Create a new table.  Do not add columns to `vehicle_events`.

```sql
CREATE TABLE IF NOT EXISTS device_lifecycle_events (
    id              TEXT PRIMARY KEY,  -- UUID assigned by the server
    imei            TEXT NOT NULL,     -- IMEI of the tracker
    vehicle_id      TEXT NOT NULL,     -- resolved from IMEI (same logic as vehicle_events)
    vehicle_name    TEXT NOT NULL,
    event_type      TEXT NOT NULL,     -- "boot" | "sleep" | "wake_up"
    timestamp       REAL NOT NULL,     -- Unix timestamp UTC (device clock)
    -- boot-specific
    reset_reason    TEXT,              -- e.g. "POWERON", "PANIC" — NULL for non-boot events
    -- wake_up-specific
    wakeup_source   TEXT,              -- e.g. "VOLTAGE_RISE" — NULL for non-wake_up events
    -- sleep / wake_up
    battery_voltage_v REAL,            -- NULL if not provided
    received_at     REAL NOT NULL      -- Unix timestamp UTC (server reception time)
);

CREATE INDEX IF NOT EXISTS idx_dle_imei       ON device_lifecycle_events (imei);
CREATE INDEX IF NOT EXISTS idx_dle_vehicle    ON device_lifecycle_events (vehicle_id);
CREATE INDEX IF NOT EXISTS idx_dle_event_type ON device_lifecycle_events (event_type);
CREATE INDEX IF NOT EXISTS idx_dle_ts         ON device_lifecycle_events (timestamp);
```

---

## 4. VehicleID / vehicleName resolution

Reuse the **exact same logic** as `driving` events in `vehicle_events`:
- Look up `sensorID = <imei>` in `sensor_readings`, take `vehicleID` and
  `vehicleName`.
- If IMEI is unknown: `vehicleID = imei`, `vehicleName = "Tracker <imei>"`.

---

## 5. Journey state machine: no change

`boot`, `sleep`, and `wake_up` events must **not**:
- Open a new journey
- Close the current journey
- Update any `lastJourneyID` state

They are completely orthogonal to the journey lifecycle.

---

## 6. Read endpoints

### 6a. Lifecycle event history for a device

```
GET /api/device-lifecycle?imei={imei}
```

Optional query parameters:

| Parameter | Description |
|---|---|
| `imei=string` | Filter by IMEI (**recommended**) |
| `vehicle=UUID` | Filter by vehicleID |
| `event_type=boot` | Filter by `boot`, `sleep`, or `wake_up` |
| `since=ISO8601` | Return only events after this timestamp |
| `limit=N` | Max results (default: 200) |

Response — array sorted by `timestamp` descending (most recent first):

```jsonc
[
  {
    "id":               "c9a2d341-...",
    "imei":             "357312098765432",
    "vehicleID":        "47AC3E8E-...",
    "vehicleName":      "Phil's car",
    "eventType":        "wake_up",
    "timestamp":        "2026-03-04T06:55:10Z",
    "wakeupSource":     "VOLTAGE_RISE",
    "batteryVoltageV":  13.9,
    "receivedAt":       "2026-03-04T06:55:12Z"
  },
  {
    "id":               "a1b3e521-...",
    "imei":             "357312098765432",
    "vehicleID":        "47AC3E8E-...",
    "vehicleName":      "Phil's car",
    "eventType":        "sleep",
    "timestamp":        "2026-03-03T19:45:22Z",
    "batteryVoltageV":  12.4,
    "receivedAt":       "2026-03-03T19:45:24Z"
  },
  {
    "id":               "88f1c012-...",
    "imei":             "357312098765432",
    "vehicleID":        "47AC3E8E-...",
    "vehicleName":      "Phil's car",
    "eventType":        "boot",
    "timestamp":        "2026-03-03T07:00:01Z",
    "resetReason":      "POWERON",
    "receivedAt":       "2026-03-03T07:00:03Z"
  }
]
```

Fields that do not apply to the event type (`resetReason` for a `sleep`
event, etc.) must be **omitted** from the response object — do not return
them as `null`.

HTTP `200 OK`.  Empty array if no matching events.

---

### 6b. Summary for a device

```
GET /api/device-lifecycle/summary?imei={imei}
```

Returns aggregate counts and the most recent event of each type.

```jsonc
{
  "imei":        "357312098765432",
  "vehicleID":   "47AC3E8E-...",
  "vehicleName": "Phil's car",
  "boot": {
    "count":      3,
    "lastAt":     "2026-03-03T07:00:01Z",
    "lastReason": "POWERON"
  },
  "sleep": {
    "count":      12,
    "lastAt":     "2026-03-03T19:45:22Z",
    "lastVoltageV": 12.4
  },
  "wakeUp": {
    "count":      11,
    "lastAt":     "2026-03-04T06:55:10Z",
    "lastSource": "VOLTAGE_RISE",
    "lastVoltageV": 13.9,
    "sourceBreakdown": {
      "VOLTAGE_RISE":  8,
      "CAN_ACTIVITY":  2,
      "TIMER_BACKUP":  1,
      "ESPNOW_HMI":    0
    }
  }
}
```

Return `count: 0` and omit `lastAt` / `lastReason` / etc. if no events of
that type exist yet.  HTTP `200 OK`.

---

## 7. Validation and error handling

| Condition | Response |
|---|---|
| `eventType` is `"boot"` and `resetReason` is missing | Accept — store with `reset_reason = NULL` |
| `eventType` is `"wake_up"` and `wakeupSource` is missing | Accept — store with `wakeup_source = NULL` |
| `batteryVoltageV` is negative | Treat as unavailable — store as `NULL` |
| Unknown `resetReason` or `wakeupSource` string | Accept — store as-is |
| `eventType` is `"boot"`, `"sleep"`, or `"wake_up"` but `imei` is missing | `400 Bad Request` (same rule as all events) |

All other validation rules (auth, JSON structure) remain unchanged from the
existing `POST /api/vehicle-events` endpoint.

---

## 8. Non-goals (out of scope for this implementation)

- Push notifications or webhooks on boot / sleep / wake_up
- Modifying the `vehicle_events` table schema
- Sleep duration calculation (sleep end − sleep start): not part of this spec
- A new ingest URL — all ingestion goes through `POST /api/vehicle-events`

---

## 9. Test cases

The implementer must verify these scenarios:

1. **Single `boot` event** in isolation → stored in `device_lifecycle_events`
   with correct `reset_reason`, not in `vehicle_events`.
2. **Single `sleep` event** → stored with `battery_voltage_v`, journey state
   unchanged.
3. **Single `wake_up` event** with `wakeupSource = "CAN_ACTIVITY"` → stored
   with correct `wakeup_source = "CAN_ACTIVITY"`.
4. **Mixed batch** containing `wake_up` + `journey_start` + `driving` →
   `wake_up` in `device_lifecycle_events`, others in `vehicle_events`, all
   return `201`.
5. **`wake_up` with unknown wakeupSource** (e.g. `"CUSTOM_SOURCE"`) →
   accepted, stored as-is.
6. **`boot` without `resetReason`** → accepted, `reset_reason = NULL`.
7. **`GET /api/device-lifecycle?imei=...`** → returns correct records sorted
   descending, type-specific fields present only on matching event types.
8. **`GET /api/device-lifecycle/summary?imei=...`** → correct counts and
   `sourceBreakdown` for `wakeUp`.
9. **`GET /api/device-lifecycle?event_type=boot`** → only `boot` records
   returned.
