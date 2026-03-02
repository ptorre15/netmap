# NetMap — Architecture

## Vue d'ensemble

NetMap est un système de surveillance de pression de pneus (TPMS) en temps réel composé de deux sous-projets indépendants qui communiquent via une API REST JSON.

```
┌───────────────────────────────────┐        HTTP/REST         ┌────────────────────────────┐
│   NetMap (iOS/macOS app SwiftUI)  │ ◄──────────────────────► │  NetMapServer (Vapor 4)     │
│                                   │   port 8765               │                            │
│  BLE (TPMS sensors)               │                           │  SQLite  +  Static web     │
│  CoreLocation (GPS)               │                           │  dashboard                 │
└───────────────────────────────────┘                           └────────────────────────────┘
```

---

## 1. NetMapServer

### Stack technique
| Composant | Technologie |
|-----------|-------------|
| Framework | Vapor 4 (Swift async/await) |
| Base de données | SQLite via Fluent + FluentSQLiteDriver |
| Fichier DB | `netmap_data.db` (configurable via `DB_PATH`) |
| Port | 8765 (configurable via `PORT`) |
| Fichiers statiques | `Public/` servi par `FileMiddleware` |
| Format dates JSON | ISO 8601 |

### Démarrage
```bash
cd NetMapServer
swift run App
# Variables d'environnement optionnelles :
#   PORT=8765   DB_PATH=netmap_data.db
#   API_KEY=<secret>   ADMIN_USERNAME=admin   ADMIN_PASSWORD=<secret>
```

### Migrations (ordre d'application)
1. `CreateSensorReading` — table principale des relevés TPMS
2. `CreateUser` — comptes utilisateurs (admin / user)
3. `CreateUserToken` — tokens Bearer 7 jours
4. `CreateVehicle` — catalogue de véhicules

### Modèles de données

#### `SensorReading`
Stocke chaque relevé envoyé par l'application iOS.

| Champ | Type | Description |
|-------|------|-------------|
| `sensorID` | String | ID stable MAC-based (`TMS-A703BC`) |
| `vehicleID` | String | UUID du véhicule côté iOS |
| `vehicleName` | String | Nom lisible |
| `brand` | String | Marque du capteur TPMS |
| `wheelPosition` | String? | Position (FL, FR, RL, RR…) |
| `pressureBar` | Double | Pression en bar |
| `temperatureC` | Double? | Température °C |
| `vbattVolts` | Double? | Tension batterie capteur |
| `timestamp` | Date | Horodatage ISO 8601 |
| `latitude` / `longitude` | Double? | Position GPS du véhicule |

#### `User`
| Champ | Type | Description |
|-------|------|-------------|
| `username` | String | Unique |
| `passwordHash` | String | BCrypt |
| `role` | String | `"admin"` ou `"user"` |

#### `UserToken`
| Champ | Type | Description |
|-------|------|-------------|
| `value` | String | 32 octets hex aléatoires |
| `userID` | UUID | FK → User |
| `username` | String | Dénormalisé pour performance |
| `role` | String | Copie du rôle au moment de la création |
| `expiresAt` | Date | now + 7 jours |

#### `Vehicle`
| Champ | Type | Description |
|-------|------|-------------|
| `name` | String | Nom affiché |
| `brand` | String? | Marque |
| `modelName` | String? | Modèle |
| `year` | Int? | Année |
| `vrn` | String? | Plaque d'immatriculation |
| `vin` | String? | Numéro de série châssis |
| `createdBy` | String | Username de l'admin créateur |

### API REST

#### Authentification

| Méthode | Route | Auth requise | Description |
|---------|-------|-------------|-------------|
| `GET` | `/api/auth/status` | — | `{ needsSetup: Bool }` |
| `POST` | `/api/auth/setup` | — | Premier démarrage, crée l'admin |
| `POST` | `/api/auth/login` | — | Retourne `{ token, username, role }` |
| `POST` | `/api/auth/logout` | Bearer | Invalide le token |
| `GET` | `/api/auth/me` | Bearer | Infos utilisateur courant |
| `POST` | `/api/auth/users` | Bearer + Admin | Crée un utilisateur |

#### Relevés de capteurs

| Méthode | Route | Auth requise | Description |
|---------|-------|-------------|-------------|
| `POST` | `/api/records` | X-API-Key | Enregistre un relevé |
| `POST` | `/api/records/batch` | X-API-Key | Enregistre N relevés (préféré) |
| `DELETE` | `/api/records/purge` | X-API-Key | Supprime tous les relevés |
| `GET` | `/api/records` | — | Liste (filtres: vehicle, sensor, brand, limit) |
| `GET` | `/api/records/by-sensor/:id` | — | Historique d'un capteur (`?from=&to=`) |
| `GET` | `/api/records/by-vehicle/:id` | — | Historique d'un véhicule |
| `GET` | `/api/sensors/latest` | — | Dernier relevé par capteur (tableau de bord) |

#### Véhicules

| Méthode | Route | Auth requise | Description |
|---------|-------|-------------|-------------|
| `GET` | `/api/vehicles` | — | Liste tous les véhicules |
| `GET` | `/api/vehicles/:id` | — | Détail d'un véhicule |
| `POST` | `/api/vehicles` | Bearer + Admin | Crée un véhicule |
| `PATCH` | `/api/vehicles/:id` | Bearer + Admin | Modifie un véhicule |
| `DELETE` | `/api/vehicles/:id` | Bearer + Admin | Supprime un véhicule |

#### Infrastructure
| Méthode | Route | Description |
|---------|-------|-------------|
| `GET` | `/health` | `{ status: "ok", version, server }` |
| `GET` | `/` | Dashboard web (index.html) |

### Sécurité
- **X-API-Key** : utilisé par l'app iOS pour les écritures de relevés. Clé lue depuis `API_KEY` (défaut `netmap-dev` en dev).
- **Bearer Token** : généré à login/setup, stocké en DB, expiré à 7 jours. Contrôle l'accès aux routes d'administration.
- **AdminMiddleware** : middleware Vapor qui refuse si `token.role != "admin"`.
- **Seed admin** : au premier démarrage, si aucun utilisateur n'existe et que `ADMIN_USERNAME`/`ADMIN_PASSWORD` sont définis, un compte admin est créé automatiquement.

### Tableau de bord web (`Public/`)
- `index.html` + `style.css` + `app.js`
- Overlay de connexion / premier démarrage (mode `setup` ou `login`)
- Badge utilisateur en en-tête (nom, rôle coloré, bouton déconnexion)
- Liste des véhicules dans la barre latérale avec modal CRUD (admin seulement)
- Carte en temps réel, graphiques de pression/température, tableau de capteurs
- Les appels API embarquent `Authorization: Bearer <token>` sur toutes les routes nécessitant l'authentification

---

## 2. NetMap (app iOS/macOS)

### Stack technique
| Composant | Technologie |
|-----------|-------------|
| UI | SwiftUI |
| Bluetooth | CoreBluetooth (`CBCentralManager`) |
| Géolocalisation | CoreLocation |
| Persistance | UserDefaults (JSON encodé) |
| Réseau | `async/await` + `URLSession` |

### Services

#### `BLEScanner`
- Scanne en continu les paquets BLE advertisement des capteurs TPMS.
- Décode la trame propriétaire pour extraire pression, température, tension.
- Génère un `BLEDevice` par détection avec : `id` UUID (éphémère), `macAddress` (stable), `stableSensorID` (format `TMS-AABBCC`).
- Les `stableSensorID` sont persistés dans `UserDefaults` sous la clé `ble_tms_macs_v1` pour survivre aux réinstallations.

#### `LocationManager`
- Demande `requestAlwaysAuthorization` (background updates).
- Met à jour `currentLocation` via `@Published`.
- Filtre sur une précision horizontale ≤ 50 m.

#### `VehicleStore`
- Gère le catalogue de véhicules (`[VehicleConfig]`) en `UserDefaults`.
- Associe des capteurs BLE à des véhicules (`PairedSensor`).
- Synchronise le catalogue depuis le serveur via `syncFromServer([VehicleServerDTO])`.
- Matching par `serverVehicleID` (UUID) en priorité, puis par nom de véhicule.
- **N'stocke plus aucun historique localement** — seul le serveur conserve l'historique.

#### `NetMapServerClient`
- `@Published isEnabled: Bool` — contrôle l'activation de la synchronisation serveur.
- **`sendBatch([SensorPayload])`** — `POST /api/records/batch` avec `X-API-Key`.
- **`fetchVehicles()`** → `[VehicleServerDTO]` — synchronise le catalogue.
- **`fetchHistory(sensorID:from:to:)`** → `[PressureRecord]` — historique serveur pour un capteur donné, paramètres `from`/`to` ISO 8601.

### Modèles

#### `VehicleConfig`
- `id: UUID`, `name`, `brand`, `model`, `year`, `vrn`
- `sensors: [PairedSensor]`
- `serverVehicleID: UUID?` — identifiant côté serveur (optionnel, rétrocompatible)

#### `PairedSensor`
- `id: UUID`, `name`, `position`, `targetPressureBar`
- `macAddress: String?`
- `stableSensorID: String` (calculé : `"TMS-\(mac)"` ou fallback UUID)

#### `PressureRecord` (struct d'affichage — non persisté)
- `id, timestamp, pressureBar, temperatureC, vbattVolts, latitude, longitude`
- Populé uniquement à partir des réponses serveur.

### Vues principales
| Vue | Rôle |
|-----|------|
| `VehicleListView` | Liste des véhicules configurés |
| `VehicleDetailView` | Capteurs d'un véhicule, dernières valeurs BLE |
| `VehicleMapView` | Carte des véhicules avec marqueurs |
| `SensorHistoryView` | Graphiques et stats de l'historique **servi par le serveur** |
| `BLEDeviceListView` | Découverte et association de capteurs BLE |
| `ServerSettingsView` | URL serveur, clé API, activation du mode serveur |

### Flux de données

```
BLEScanner ──► [BLEDevice]
                    │
                    ▼
            NetMapApp (.onChange)
                    │
          ┌─────────┴─────────┐
          │                   │
          ▼                   ▼
   VehicleDetailView   NetMapServerClient
   (affichage live)    sendBatch(payloads)
                              │
                              ▼
                       NetMapServer (DB)
                              │
                              ▼
                   SensorHistoryView
                   (fetchHistory on demand)
```

### Identification stable des capteurs
Les capteurs TPMS BLE changent leur UUID Bluetooth à chaque scan. Pour garantir la continuité des données :
1. L'adresse MAC est extraite du payload advertisement et mise en cache dans `UserDefaults`.
2. `stableSensorID = "TMS-\(mac.dropColons)"` est utilisé comme clé dans toutes les écritures serveur et dans les requêtes d'historique.
3. Ce même format est présent côté `BLEDevice` (scanner) et `PairedSensor` (store), assurant la cohérence.

---

## 3. Interactions clés

### Premier démarrage serveur
```
curl POST /api/auth/setup { username, password }
  → 201 { token, username: "admin", role: "admin" }
```

### Synchronisation véhicules (app → serveur)
```
App launch (.task)
  └─ VehicleStore.syncFromServer()
       └─ NetMapServerClient.fetchVehicles()
            GET /api/vehicles
              → [{ id, name, brand, model, year, vrn, vin }]
            matchBy(serverVehicleID) || matchBy(name)
            updates VehicleConfig.serverVehicleID
```

### Envoi de relevé (BLE → serveur)
```
BLEScanner detects packet
  └─ NetMapApp.onChange(bleDevices)
       └─ NetMapServerClient.sendBatch([SensorPayload])
            POST /api/records/batch  (X-API-Key)
              → 201
```

### Consultation de l'historique
```
SensorHistoryView.task / .onChange
  └─ NetMapServerClient.fetchHistory(sensorID, from, to)
       GET /api/records/by-sensor/TMS-A703BC?from=...&to=...
         → [SensorReading]
       mapped to [PressureRecord]
       displayed in charts / stats
```
