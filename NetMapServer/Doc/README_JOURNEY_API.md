# NetMapServer — Vehicle Events API

> Référence d'intégration pour dispositifs embarqués (OBD, ESP32, Raspberry Pi, modem 4G, etc.)
> qui poussent la télémétrie véhicule vers le NetMapServer.

---

## Concept

Le tracker est identifié par son **IMEI** — c'est le seul identifiant obligatoire.

Le serveur gère automatiquement :
- la résolution du véhicule associé (via le lien IMEI ↔ véhicule enregistré dans le dashboard)
- la création et la continuité des trajets (`journeyID`)

Les données sont poussées sous forme d'**événements** avec un `eventType` :

| `eventType` | Quand envoyer |
|---|---|
| `journey_start` | Une fois — allumage détecté / premier fix GPS |
| `driving` | Périodiquement en roulant (toutes les 5–30 s) |
| `journey_end` | Une fois — coupure moteur / arrêt du véhicule |

`eventType` est optionnel : si absent, le serveur utilise `"driving"` par défaut.

---

## Authentification

Tous les endpoints d'**écriture** requièrent la clé API :

```
X-API-Key: netmap-dev
```

Les endpoints de **lecture** (`GET`) sont publics — aucune clé requise.

---

## URL de base

```
http://<server-host>:8765
```

Exemple LAN : `http://192.168.1.18:8765`

---

## Pousser des événements

### `POST /api/vehicle-events`

Accepte un **objet unique** ou un **tableau d'événements**.

```
POST /api/vehicle-events
Content-Type: application/json
X-API-Key: netmap-dev
```

### Payload — événement minimal (seul l'IMEI est obligatoire)

```jsonc
{
  "imei": "357312098765432"
}
```

### Payload — événement complet

```jsonc
{
  "imei":                 "357312098765432",
  "eventType":            "driving",               // optionnel, défaut: "driving"
  "timestamp":            "2026-03-02T08:15:00Z",  // optionnel, défaut: heure serveur

  "driverID":             "driver-abc123",          // optionnel

  "latitude":             48.8566,
  "longitude":            2.3522,
  "headingDeg":           90.0,
  "speedKmh":             65.0,

  "odometerKm":           12350.4,
  "distanceElapsedKm":    0.18,
  "journeyDistanceKm":    4.7,
  "journeyFuelConsumedL": 0.41,                    // cumul carburant depuis journey_start

  "fuelLevelPct":         72,
  "fuelConsumedL":        0.03,                    // consommé depuis l'événement précédent

  "engineRpm":            2100,
  "engineTempC":          88.5,

  "obdCode":              null
}
```

### Exemples de séquence complète

```jsonc
// 1. Démarrage
{ "imei": "357312098765432", "eventType": "journey_start", "timestamp": "2026-03-02T08:00:00Z",
  "latitude": 48.8566, "longitude": 2.3522, "speedKmh": 0, "odometerKm": 12345.6,
  "fuelLevelPct": 75, "engineRpm": 850 }

// 2. En route (batch recommandé)
[
  { "imei": "357312098765432", "eventType": "driving", "timestamp": "2026-03-02T08:00:10Z",
    "latitude": 48.8570, "longitude": 2.3530, "speedKmh": 32.0,
    "journeyDistanceKm": 0.08, "journeyFuelConsumedL": 0.04, "engineRpm": 1800 },
  { "imei": "357312098765432", "eventType": "driving", "timestamp": "2026-03-02T08:00:20Z",
    "latitude": 48.8578, "longitude": 2.3545, "speedKmh": 48.5,
    "journeyDistanceKm": 0.22, "journeyFuelConsumedL": 0.09, "engineRpm": 2200 }
]

// 3. Arrivée
{ "imei": "357312098765432", "eventType": "journey_end", "timestamp": "2026-03-02T08:45:00Z",
  "latitude": 48.8600, "longitude": 2.3600, "speedKmh": 0, "odometerKm": 12365.1,
  "journeyDistanceKm": 19.5, "journeyFuelConsumedL": 1.8, "fuelLevelPct": 68 }
```

### Réponse

```
HTTP 201 Created
```

---

## Référence des champs

| Champ | Type | Obligatoire | Description |
|---|---|---|---|
| `imei` | string | **Oui** | IMEI du tracker. Identifiant unique permanent. |
| `eventType` | string | Non | Type d'événement. Défaut : `"driving"`. Valeurs possibles : <br>• `"journey_start"` — début de trajet (allumage / premier fix GPS) <br>• `"driving"` — point de route périodique <br>• `"journey_end"` — fin de trajet (coupure moteur / arrêt) |
| `timestamp` | ISO 8601 UTC | Non | Horodatage de la mesure sur le dispositif. Défaut : heure serveur. |
| `driverID` | string | Non | Identifiant du conducteur (UUID, badge NFC, nom d'utilisateur, etc.). |
| `latitude` | number | Non | Latitude WGS-84 en degrés décimaux. |
| `longitude` | number | Non | Longitude WGS-84 en degrés décimaux. |
| `headingDeg` | number | Non | Cap : 0 = Nord, 90 = Est, 180 = Sud, 270 = Ouest. |
| `speedKmh` | number | Non | Vitesse courante (km/h). |
| `odometerKm` | number | Non | Kilométrage absolu du véhicule (km). |
| `distanceElapsedKm` | number | Non | Distance depuis l'événement précédent (km). |
| `journeyDistanceKm` | number | Non | Distance cumulée depuis `journey_start` (km). |
| `journeyFuelConsumedL` | number | Non | Carburant cumulé consommé depuis `journey_start` (litres). Valeur recommandée pour le bilan de trajet. |
| `fuelLevelPct` | integer | Non | Niveau de carburant 0–100 %. |
| `fuelConsumedL` | number | Non | Carburant consommé depuis l'événement précédent (litres). |
| `engineRpm` | integer | Non | Régime moteur (tr/min). |
| `engineTempC` | number | Non | Température moteur / liquide de refroidissement (°C). |
| `obdCode` | string | Non | Code défaut OBD-II / DTC actif (ex. `"P0300"`). Envoyer `null` une fois effacé. |

---

## Logique serveur

### Résolution du véhicule

Le serveur recherche dans `sensor_readings` le dernier enregistrement avec `sensorID = <imei>` et `brand = "tracker"` pour obtenir `vehicleID` et `vehicleName`.

- **IMEI connu** (tracker déjà lié à un véhicule dans le dashboard) → ce véhicule est utilisé.
- **IMEI inconnu** → `vehicleID = imei`, `vehicleName = "Tracker <imei>"` (provisoire jusqu'à liaison manuelle dans le dashboard).

### Gestion automatique du journeyID

| `eventType` | Comportement |
|---|---|
| `journey_start` | Génère un nouveau `journeyID` (UUID) |
| `driving` | Reprend le `journeyID` du dernier événement enregistré pour cet IMEI |
| `journey_end` | Idem — reprend et clôt le trajet |

Si aucun trajet n'est en cours et qu'un `driving` arrive, un nouveau trajet est démarré automatiquement.

### Visibilité dans le dashboard

À chaque push, le serveur crée ou met à jour un `SensorReading` avec `brand = "tracker"` pour cet IMEI. Le tracker apparaît ainsi dans la liste des capteurs et peut être associé à un utilisateur.

---

## Endpoints de lecture

### Liste des événements

```
GET /api/vehicle-events
```

Filtres optionnels :

| Paramètre | Description |
|---|---|
| `imei=357312098765432` | Filtrer par IMEI du tracker |
| `vehicle=UUID` | Filtrer par vehicleID |
| `journey=UUID` | Filtrer par journeyID |
| `event_type=driving` | Filtrer par type d'événement |
| `limit=N` | Nombre max de résultats (défaut : 1000) |

Retourne un tableau d'événements triés par `timestamp` croissant (idéal pour tracer le trajet sur une carte).

### Résumé des trajets par véhicule

```
GET /api/vehicle-events/journeys?vehicle=UUID&limit=20
```

Retourne un résumé par trajet :

```jsonc
[
  {
    "journeyID":          "A3E8F721-...",
    "vehicleID":          "47AC3E8E-...",
    "vehicleName":        "Phil's car",
    "driverID":           "driver-abc123",
    "startedAt":          "2026-03-02T08:00:00Z",
    "endedAt":            "2026-03-02T08:45:00Z",   // null si trajet non clôturé
    "totalDistanceKm":    19.5,
    "totalFuelConsumedL": 1.8,
    "eventCount":         276
  }
]
```

`totalFuelConsumedL` utilise `MAX(journeyFuelConsumedL)` si disponible, sinon `SUM(fuelConsumedL)`.

`endedAt` est `null` si aucun événement `journey_end` n'a été reçu.

### Supprimer un trajet

```
DELETE /api/vehicle-events/journeys/{journeyID}
X-API-Key: netmap-dev
```

Supprime tous les événements du trajet. Retourne `204 No Content`.

---

## Guide d'implémentation dispositif

### Séquence de push

```
1. Allumage        → POST  eventType = "journey_start"
2. Toutes les N s  → POST  eventType = "driving"  (ou tableau batch)
3. Coupure moteur  → POST  eventType = "journey_end"
```

### Fréquence recommandée

| Scénario | Intervalle |
|---|---|
| Ville | 5 secondes |
| Route / autoroute | 10–15 secondes |
| Ralenti / arrêt prolongé | 30–60 secondes ou ignorer |

### Batching (recommandé)

Buffériser les événements localement et envoyer le tableau en un seul appel. Réduit la consommation radio et absorbe les coupures réseau courtes.

```jsonc
// Buffer 30 s, puis POST du tableau
POST /api/vehicle-events
[ event1, event2, ..., event6 ]
```

### Payload minimal viable

Seul `imei` est obligatoire. Le serveur remplit tout le reste. Ajouter les champs télémétriques selon les capacités du matériel.

---

## Codes HTTP

| Code | Signification |
|---|---|
| `201 Created` | Événements enregistrés |
| `204 No Content` | Trajet supprimé |
| `400 Bad Request` | Champ obligatoire manquant ou JSON invalide |
| `401 Unauthorized` | Clé `X-API-Key` manquante ou incorrecte |
| `404 Not Found` | journeyID inconnu (DELETE) |

---

## Schéma de la base de données

```sql
CREATE TABLE vehicle_events (
    id                      TEXT PRIMARY KEY,  -- UUID assigné par le serveur
    imei                    TEXT,              -- IMEI du tracker (identifiant unique)
    journey_id              TEXT NOT NULL,     -- UUID géré automatiquement par le serveur
    vehicle_id              TEXT NOT NULL,     -- résolu depuis l'IMEI
    vehicle_name            TEXT NOT NULL,
    event_type              TEXT NOT NULL,     -- journey_start | driving | journey_end
    timestamp               REAL NOT NULL,     -- Unix timestamp UTC
    driver_id               TEXT,
    latitude                REAL,
    longitude               REAL,
    heading_deg             REAL,
    speed_kmh               REAL,
    odometer_km             REAL,
    distance_elapsed_km     REAL,
    journey_distance_km     REAL,
    journey_fuel_consumed_l REAL,
    fuel_level_pct          INTEGER,
    fuel_consumed_l         REAL,
    engine_rpm              INTEGER,
    engine_temp_c           REAL,
    obd_code                TEXT,
    sensor_name             TEXT,
    received_at             REAL NOT NULL      -- heure de réception côté serveur
);
```

Les trajets sont dérivés à la volée — il n'y a pas de table `journeys` séparée.
### Distance Unit Compatibility Note

The tracker payload contract remains unchanged (`*Km` fields).
For backward compatibility with legacy firmware that sent meter values in these fields,
the server normalizes journey summary output to kilometers:

- values `< 1000` are treated as kilometers
- values `>= 1000` are treated as meters and divided by `1000`

Raw event storage keeps the original numeric value; normalization is applied when building journey summaries.
