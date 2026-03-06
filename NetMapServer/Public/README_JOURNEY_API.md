# NetMapServer — Vehicle Event API Reference
## Firmware implementation spec (net-hub ESP32, March 2026)

> This document is generated from the firmware source and describes **exactly**
> what the device sends. Use it as the authoritative reference for server-side
> implementation and database schema.

---

## Transport

```
POST <CONFIG_NETMAP_SERVER_URL>/api/vehicle-events
Content-Type: application/json

[ <event>, <event>, ... ]   // JSON array, 1–50 events per request
```

- Events are persisted locally in SQLite before sending; they **survive reboots**
  and are retried until the server returns HTTP 200.
- Batch size: up to 50 events per POST (configurable via `CONFIG_NETMAP_BATCH_SIZE`).
- HTTP timeout: 20 s (configurable via `CONFIG_NETMAP_HTTP_TIMEOUT_MS`).
- The server identifies the tracker via the `imei` field present in every event.
- `journey_start` and `journey_end` are **flushed synchronously** before the
  device enters deep sleep to avoid data loss.

---

## Deduplication

The server may receive a batch more than once if the HTTP ACK is lost before
the device reads it. Use `(imei, timestamp, eventType)` as a deduplication key,
or assign a server-side UUID on first insert and discard subsequent duplicates.

---

## Common fields (every event)

| Field | Type | Condition | Description |
|---|---|---|---|
| `imei` | string | always | Modem IMEI — tracker identity |
| `eventType` | string | always | Event discriminator — see below |
| `timestamp` | string | always | ISO 8601 UTC e.g. `"2026-03-06T13:45:00Z"` |
| `latitude` | number | GPS valid | WGS-84 decimal degrees |
| `longitude` | number | GPS valid | WGS-84 decimal degrees |
| `headingDeg` | number | GPS valid | 0–360 °, true north |
| `speedKmh` | number | GPS valid | km/h |
| `gpsSatellites` | integer | GPS valid | satellite count used in fix |
| `fuelLevelPct` | integer | OBD available | 0–100 % tank level |
| `driverIdent` | string | set by user | driver identification string |
| `odometerKm` | number | OBD available | absolute odometer (km) |
| `journeyDistanceKm` | number | always | cumulative GPS distance since `journey_start` (km); 0 outside journey |
| `journeyFuelConsumedL` | number | OBD available | fuel burnt since `journey_start` (L) |
| `engineRpm` | integer | OBD available, not on `journey_end` | engine RPM |

Fields marked *"OBD available"* or *"GPS valid"* are **omitted entirely** from
the JSON when unavailable — never sent as null or -1.

---

## Event types

### `journey_start`
Vehicle journey begins.

**Trigger**: `journey_manager` transitions to active after ignition / CAN detection.

No extra fields. The device may use the **last saved journey-end position**
as GPS fallback if the fix has not yet been acquired after a reboot.

**Server**: open a new journey record; record start position and time.

---

### `driving`
Periodic position update while moving.

**Trigger**: any of these thresholds crossed since last `driving`/`journey_start`:
- distance travelled ≥ configured distance threshold
- elapsed time ≥ configured time threshold
- cumulative heading change ≥ configured heading threshold

No extra fields.

**Server**: append position point to the active journey track.

---

### `stopped`
Vehicle speed just reached zero while journey is active.

**Trigger**: debouncer confirms `speed = 0` (always followed by `idle_start` ~1 s later).

No extra fields.

**Server**: mark a stop point on the track; start timing idle duration.

---

### `idle_start`
Engine confirmed running at standstill (RPM > 0, speed = 0).

**Trigger**: ~1 s after `stopped`, once RPM is verified positive.

No extra fields.

**Server**: begin idle fuel / CO₂ waste timer.

---

### `idle_end`
Movement resumed after standstill.

**Trigger**: debouncer confirms `speed > 0` after `idle_start`.

No extra fields.

**Server**: close idle timer; record idle duration on the stop point.

---

### `journey_end`
Vehicle journey ends.

**Trigger**: `journey_manager` transitions to inactive (ignition off / idle timeout).

> `engineRpm` and `speedKmh` are **not included** on this event type.

No extra fields.

**Server**: close journey; compute totals (distance, fuel, duration).

---

### `driver_behavior`
Driver behaviour alert.

**Trigger**: `driver_behavior` module detects harsh event.

Extra fields:

| Field | Type | Description |
|---|---|---|
| `driverBehaviorType` | integer | Alert type (see table below) |
| `alertValueMax` | number | Peak value during the alert |
| `alertDurationMs` | integer | Duration of the alert (ms) |

**`driverBehaviorType` values** (firmware `alert_type_t`):

| Value | Name | `alertValueMax` unit |
|---|---|---|
| 0 | NONE | — |
| 1 | REVVING | RPM |
| 2 | BRAKE | g (deceleration) |
| 3 | ACCEL | g (acceleration) |
| 4 | CORNERING | g (lateral) |
| 5 | IDLING | seconds |
| 6 | OVERSPEED | km/h |

**Server**: attach alert to nearest journey point; update driver score.

---

### `gps_acquired`
GPS receiver obtained a valid fix.

**Trigger**: GPS debouncer transitions to valid. Sent regardless of journey state.

No extra fields. Position fields will be present (the newly acquired fix).

**Server**: log GPS fix time; update tracker status.

---

### `gps_lost`
GPS receiver lost fix (tunnel, garage, obstruction).

**Trigger**: GPS debouncer transitions to invalid. Sent regardless of journey state.

No extra fields. Position fields reflect the last valid fix.

**Server**: log GPS loss; flag subsequent positions as estimated/dead-reckoned.

---

### `boot`
Device powered on or reset.

**Trigger**: `app_main()` — sent once on every boot.

Extra fields:

| Field | Type | Description |
|---|---|---|
| `resetReason` | string | Reset cause (see table below) |

**`resetReason` values** (firmware `esp_reset_reason_t`):

| Value | Meaning |
|---|---|
| `POWERON` | Cold power-on |
| `SW` | Software-initiated reset (OTA, watchdog kick) |
| `PANIC` | Firmware crash / unhandled exception |
| `INT_WDT` | Interrupt watchdog timeout |
| `TASK_WDT` | Task watchdog timeout |
| `WDT` | Other watchdog |
| `DEEPSLEEP` | Normal wake from deep sleep |
| `BROWNOUT` | Supply voltage brownout |
| `EXT` | External reset pin |
| `UNKNOWN` | Unrecognised cause |

**Server**: log device lifecycle; flag any gap in tracking data.

---

### `sleep`
Device entering deep sleep.

**Trigger**: sleep manager state machine — vehicle idle, ignition off.

Extra fields:

| Field | Type | Condition | Description |
|---|---|---|---|
| `batteryVoltageV` | number | if available | Battery voltage (V) at sleep entry |

**Server**: mark tracker as sleeping; compute expected next wakeup window.

---

### `wake_up`
Device woke from deep sleep.

**Trigger**: `sleep_manager_should_full_wakeup()` confirms valid wakeup.
Sent on every true wakeup (not on false wakeups that return to sleep).

Extra fields:

| Field | Type | Condition | Description |
|---|---|---|---|
| `wakeupSource` | string | always | What triggered the wakeup (see table below) |
| `batteryVoltageV` | number | if available | Battery voltage (V) at wakeup |

**`wakeupSource` values** (firmware `sleep_wakeup_cause_t`):

| Value | Trigger |
|---|---|
| `VOLTAGE_RISE` | ULP ADC: battery > 13.5 V (engine start) |
| `CAN_ACTIVITY` | EXT1: CAN bus dominant state on GPIO 13 |
| `TIMER_BACKUP` | Periodic backup timer (default 12 h) |
| `ESPNOW_HMI` | ESP-NOW wake packet from HMI device |
| `IMU_MOTION` | EXT0: accelerometer Wake-on-Motion (door open / occupant) |
| `POWER_ON` | First boot after hard power-on reset |
| `NONE` | Undefined / debug |
| `UNKNOWN` | Unrecognised cause |

**Server**: mark tracker as active; correlate with prior `sleep` event.

---

## Event state machine (device-side)

```
[deep sleep]
     │  wake trigger (voltage / CAN / IMU / timer)
     ▼
  wake_up
     │
     │  (each power-on)
     ▼
   boot
     │
     │  CAN + journey_manager active
     ▼
journey_start ──────────────────────────────────────────────────────┐
     │                                                              │
     │  every N m / s / ° heading                                  │
     ├──▶ driving                                                   │
     │                                                              │
     │  speed → 0 (debounced)                                       │
     ├──▶ stopped                                                   │
     │         │  RPM > 0 confirmed                                 │
     │         ├──▶ idle_start                                      │
     │         │         │  speed > 0 again (debounced)             │
     │         │         └──▶ idle_end ──────────────────────────── ┤
     │                                                              │
     │  harsh event (accel / brake / cornering / overspeed / …)    │
     ├──▶ driver_behavior                                           │
     │                                                              │
     │  GPS fix acquired / lost (any time, any state)              │
     ├──▶ gps_acquired / gps_lost                                   │
     │                                                              │
     │  ignition off / idle timeout                                 │
     └──▶ journey_end
              │
              │  sleep manager idle timeout
              ▼
            sleep
```

---

## Database schema (recommended)

```sql
CREATE TABLE vehicle_events (
    id                       TEXT PRIMARY KEY,   -- server-assigned UUID
    imei                     TEXT    NOT NULL,
    journey_id               TEXT,               -- server-managed; NULL until journey_start
    event_type               TEXT    NOT NULL,   -- eventType string
    timestamp                REAL    NOT NULL,   -- Unix timestamp UTC
    received_at              REAL    NOT NULL,   -- server reception time

    -- GPS
    latitude                 REAL,
    longitude                REAL,
    heading_deg              REAL,
    speed_kmh                REAL,
    gps_satellites           INTEGER,

    -- CAN / OBD
    odometer_km              REAL,
    journey_distance_km      REAL,
    journey_fuel_consumed_l  REAL,
    engine_rpm               INTEGER,
    fuel_level_pct           INTEGER,

    -- Driver
    driver_ident             TEXT,

    -- Driver behavior (event_type = 'driver_behavior')
    driver_behavior_type     INTEGER,
    alert_value_max          REAL,
    alert_duration_ms        INTEGER,

    -- System lifecycle (event_type = 'boot' / 'sleep' / 'wake_up')
    reset_reason             TEXT,
    wakeup_source            TEXT,
    battery_voltage_v        REAL
);

-- Index for per-tracker queries
CREATE INDEX idx_ve_imei_ts ON vehicle_events (imei, timestamp);
-- Index for journey reconstruction
CREATE INDEX idx_ve_journey ON vehicle_events (journey_id, timestamp);
```

Journey records can be derived on the fly from `journey_start` / `journey_end`
pairs — no separate `journeys` table is required, but a materialised view or
summary table is recommended for performance.


