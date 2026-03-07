# NetMapServer — Tracker Configuration API (Spec)

> Draft specification for a dedicated tracker configuration page and backend payload.
> Scope of this version: `system` and `driverBehavior` sections only.

---

## 1. Goal

Provide a single configuration object per tracker (identified by IMEI), editable from a dedicated UI page.

Current sections:
- `system`
- `driverBehavior`

Future sections can be added without breaking existing clients.

---

## 2. Tracker Identifier

- Primary identifier: `imei` (string)
- One active config per `imei`

---

## 3. Endpoints (proposed)

### Get current configuration

`GET /api/admin/trackers/:imei/config`

Auth:
- `Bearer + admin`

Response:
- `200 OK` with full config payload
- `404 Not Found` if tracker unknown

### Upsert full configuration

`PUT /api/admin/trackers/:imei/config`

Auth:
- `Bearer + admin`

Request body:
- Full configuration payload (see section 5)

Response:
- `200 OK` (updated)
- `201 Created` (new)
- `400 Bad Request` (validation error)

### Partial update (optional but recommended)

`PATCH /api/admin/trackers/:imei/config`

Auth:
- `Bearer + admin`

Request body:
- Partial payload (same shape, fields optional)

Response:
- `200 OK`
- `400 Bad Request` (validation error)

---

## 4. Data Model

Top-level object:
- `schemaVersion` (integer)
- `imei` (string)
- `updatedAt` (ISO 8601 UTC string)
- `updatedBy` (string, user email)
- `system` (object)
- `driverBehavior` (object)

Notes:
- `schemaVersion` starts at `1`.
- Unknown sections/fields must be ignored (forward compatibility).

---

## 5. Payload Description

### 5.1 Full payload (v1)

```json
{
  "schemaVersion": 1,
  "imei": "867280066365446",
  "updatedAt": "2026-03-07T12:00:00Z",
  "updatedBy": "admin@company.com",
  "system": {
    "pingIntervalMin": 5,
    "sleepDelayMin": 15,
    "wakeUpSourcesEnabled": [
      "ignition",
      "motion",
      "voltage_rise",
      "timer"
    ]
  },
  "driverBehavior": {
    "thresholds": {
      "harshBraking": 3.2,
      "harshAcceleration": 3.0,
      "harshCornering": 2.8,
      "overspeed": 120
    },
    "minimumSpeedKmh": 20,
    "beepEnabled": true
  }
}
```

---

## 6. Section Details

### 6.1 `system`

- `pingIntervalMin` (integer)
  - Description: telemetry ping period
  - Unit: minutes
  - Recommended range: `1..1440`

- `sleepDelayMin` (integer)
  - Description: inactivity delay before entering sleep
  - Unit: minutes
  - Recommended range: `1..10080`

- `wakeUpSourcesEnabled` (array of strings)
  - Description: enabled wake-up triggers
  - Allowed values (v1):
    - `ignition`
    - `motion`
    - `voltage_rise`
    - `timer`
  - Validation:
    - array cannot be empty
    - values must be unique

### 6.2 `driverBehavior`

- `thresholds` (object)
  - `harshBraking` (number)
  - `harshAcceleration` (number)
  - `harshCornering` (number)
  - `overspeed` (number, km/h)

- `minimumSpeedKmh` (integer)
  - Description: alerts ignored below this speed
  - Recommended range: `0..250`

- `beepEnabled` (boolean)
  - Description: enable local buzzer/beep for behavior alerts

Validation guidance (v1):
- all numeric thresholds must be `> 0`
- `overspeed` must be realistic (`1..300`)

---

## 7. Validation Error Format

Recommended `400` response body:

```json
{
  "error": "validation_failed",
  "message": "Invalid tracker configuration payload",
  "details": [
    {
      "field": "system.pingIntervalMin",
      "reason": "must be between 1 and 1440"
    }
  ]
}
```

---

## 8. UI Structure (Dedicated Tracker Config Page)

Sections:
1. `System`
- Ping interval (min)
- Delay before sleep (min)
- Wake-up sources enabled

2. `Driver behavior`
- Thresholds (harsh braking, harsh acceleration, harsh cornering, overspeed)
- Minimum speed for alerts
- Beep enabled

Buttons:
- `Save`
- `Reset to device defaults` (optional)

---

## 9. Extensibility Rules

- New sections can be added at top level (example: `power`, `geofencing`, `canBus`).
- Increment `schemaVersion` only on breaking changes.
- For non-breaking additions, keep same `schemaVersion` and add optional fields.

---

## 10. Device Sync — Piggyback Model (implemented)

Config is delivered to the tracker automatically inside the HTTP response of every `POST /api/vehicle-events` call. No extra request, no polling, no push channel needed.

### Version-based gating (how it is controlled)

The tracker reports the `schemaVersion` it already has applied by including a `configVersion` field in its event payload:

```json
{
  "imei": "867280066365446",
  "eventType": "driving",
  "configVersion": 2,
  ...
}
```

The server only includes `config` in the response when:

| Condition | Config in response? |
|---|---|
| `configVersion` absent / null (first boot) | ✅ Always sent |
| `stored schemaVersion > configVersion` | ✅ Sent (update available) |
| `stored schemaVersion <= configVersion` | ❌ Omitted (`config: null`) |

This means the config travels once per version change, not on every POST.

### Response format

`POST /api/vehicle-events` returns `201 Created` with a JSON body:

```json
{
  "received": 3,
  "config": {
    "schemaVersion": 3,
    "imei": "867280066365446",
    "system": {
      "pingIntervalMin": 5,
      "sleepDelayMin": 15,
      "wakeUpSourcesEnabled": ["ignition", "motion", "voltage_rise"]
    },
    "driverBehavior": {
      "thresholds": {
        "harshBraking": 3.2,
        "harshAcceleration": 3.0,
        "harshCornering": 2.8,
        "overspeed": 120
      },
      "minimumSpeedKmh": 20,
      "beepEnabled": true
    }
  }
}
```

When no update is pending, `config` is `null`:

```json
{ "received": 1, "config": null }
```

- `received` — number of events accepted in this batch.
- `config` — full config payload, or **`null`** if no config is in DB yet, or the tracker already has the latest version.

### Firmware integration guide

```
// Before sending: read stored appliedConfigVersion from NVS (default: null / absent)
POST /api/vehicle-events   body includes "configVersion": <appliedConfigVersion>

→ parse response body (JSON)
→ if response.config != null
    → apply system settings (ping interval, sleep delay, wake sources)
    → apply driverBehavior thresholds + beep flag
    → persist response.config.schemaVersion to NVS as appliedConfigVersion
    → (optional) log "config v{n} applied"
```

### Notes

- Safe to ignore unknown fields (forward compatibility).
- If no config has been stored server-side yet, `config` is `null` — firmware should fall back to hardcoded defaults.
- Config is sent at most once per version bump, avoiding unnecessary NVS writes on the device.

