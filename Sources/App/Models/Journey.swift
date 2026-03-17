import Fluent
import Vapor
import SQLKit

// MARK: - DTO
// Payload minimal envoyé par le tracker : seul l'IMEI est obligatoire.
// Le serveur résout vehicleID/vehicleName et gère le journeyID automatiquement.

struct VehicleEventPayload: Content {
    var imei:               String          // IMEI du tracker (identifiant unique)
    var eventType:          String?         // "journey_start" | "driving" | "journey_end" (défaut: "driving")
    var timestamp:          Date?           // défaut: now
    var latitude:           Double?
    var longitude:          Double?
    var headingDeg:         Double?
    var speedKmh:           Double?
    var driverIdent:        String?          // identifiant du conducteur (JSON key: "driverIdent")
    var odometerKm:         Double?
    var journeyDistanceKm:  Double?
    var fuelLevelPct:       Int?
    var journeyFuelConsumedL: Double?       // cumul carburant consommé depuis le début du trajet
    var engineRpm:          Int?

    // ── Driver behavior fields (only for eventType = "driver_behavior") ──
    var driverBehaviorType: Int?            // raw integer from device
    var alertValueMax:      Double?         // peak measured value
    var alertDurationMs:    Int?            // alert duration in milliseconds

    // ── GPS quality ────────────────────────────────────────────────────────────
    var gpsSatellites:      Int?            // number of satellites used for fix
    var gpsFixType:         Int?            // 0=no fix, 2=2D, 3=3D, 4=GNSS+DR (new in v6)

    // ── Device lifecycle fields (boot / sleep / wake_up) ──────────────────
    var resetReason:        String?         // boot: "POWERON" | "PANIC" | …
    var wakeupSource:       String?         // wake_up: "VOLTAGE_RISE" | "CAN_ACTIVITY" | …
    var batteryVoltageV:    Double?         // sleep / wake_up: battery voltage in volts

    // ── Config acknowledgment ──────────────────────────────────────────────
    var configVersion:      Int?            // schemaVersion the tracker currently has applied; nil = never received config

    // ── Firmware self-report (optional, sent after OTA reboot) ────────────
    var firmwareVersion:    String?         // running firmware version string (e.g. "1.4.2"); nil = unknown / not sent

    // ── OBFCM lifetime totals ─────────────────────────────────────────────
    var obfcmDistanceKm:    Double?         // OBFCM lifetime total distance (km)
    var obfcmFuelL:         Double?         // OBFCM lifetime total fuel consumed (L)

    // ── Journey stats counters (only for eventType = "journey_stats") ──────
    var journey:            JourneyStatsCounters?
    var boot:               JourneyStatsCounters?
    var lifetime:           JourneyStatsLifetime?

    // ── Load estimation (journey_start / driving / journey_end) ─────────────
    var load:               LoadEstimationPayload?
}

/// Load estimation snapshot sent by the tracker on driving events.
struct LoadEstimationPayload: Content {
    var confidence:  String   // "low" | "medium" | "high"
    var samples:     Int?
    var mTotalKg:    Double?  // estimated total vehicle mass; absent when unavailable
    var mLoadKg:     Double?  // estimated payload (total − empty); absent when unavailable
}

// MARK: - journey_stats counter structs

struct JourneyStatsCounters: Content {
    var dbEventsSent: Int
    var ffEventsSent: Int
    var postFailures: Int
}

struct JourneyStatsLifetime: Content {
    var dbEventsSent:     Int
    var ffEventsSent:     Int
    var postFailures:     Int
    var rebootsTotal:     Int
    var rebootsException: Int
    var rebootsBrownout:  Int
}

// MARK: - Fluent Model

final class VehicleEvent: Model, Content, @unchecked Sendable {
    static let schema = "vehicle_events"

    @ID(key: .id)                                  var id:                 UUID?
    @OptionalField(key: "imei")                    var imei:               String?
    @OptionalField(key: "sensor_name")             var sensorName:         String?
    @Field(key: "journey_id")                      var journeyID:          String
    @Field(key: "vehicle_id")                      var vehicleID:          String
    @Field(key: "vehicle_name")                    var vehicleName:        String
    @Field(key: "event_type")                      var eventType:          String
    @Field(key: "timestamp")                       var timestamp:          Date
    @OptionalField(key: "latitude")                var latitude:           Double?
    @OptionalField(key: "longitude")               var longitude:          Double?
    @OptionalField(key: "heading_deg")             var headingDeg:         Double?
    @OptionalField(key: "speed_kmh")               var speedKmh:           Double?
    @OptionalField(key: "odometer_km")             var odometerKm:         Double?
    @OptionalField(key: "journey_distance_km")     var journeyDistanceKm:  Double?
    @OptionalField(key: "fuel_level_pct")          var fuelLevelPct:       Int?
    @OptionalField(key: "engine_rpm")              var engineRpm:          Int?
    @OptionalField(key: "driver_id")               var driverID:           String?
    @OptionalField(key: "journey_fuel_consumed_l") var journeyFuelConsumedL: Double?
    @OptionalField(key: "gps_satellites")          var gpsSatellites:      Int?
    @OptionalField(key: "gps_fix_type")            var gpsFixType:         Int?
    @OptionalField(key: "load_confidence")         var loadConfidence:     String?
    @OptionalField(key: "load_samples")            var loadSamples:        Int?
    @OptionalField(key: "load_m_total_kg")         var loadMTotalKg:       Double?
    @OptionalField(key: "load_m_load_kg")          var loadMLoadKg:        Double?
    @OptionalField(key: "obfcm_distance_km")       var obfcmDistanceKm:    Double?
    @OptionalField(key: "obfcm_fuel_l")            var obfcmFuelL:         Double?
    @Field(key: "received_at")                     var receivedAt:         Date

    init() {}

    /// Initialisation avec les champs résolus côté serveur
    init(imei: String, journeyID: String, vehicleID: String, vehicleName: String,
         eventType: String, from p: VehicleEventPayload) {
        self.imei             = imei
        sensorName            = nil
        self.journeyID        = journeyID
        self.vehicleID        = vehicleID
        self.vehicleName      = vehicleName
        self.eventType        = eventType
        timestamp             = p.timestamp ?? Date()
        latitude              = p.latitude
        longitude             = p.longitude
        headingDeg            = p.headingDeg
        speedKmh              = p.speedKmh
        odometerKm            = p.odometerKm
        journeyDistanceKm     = p.journeyDistanceKm
        driverID              = p.driverIdent
        fuelLevelPct          = p.fuelLevelPct
        journeyFuelConsumedL  = p.journeyFuelConsumedL
        engineRpm             = p.engineRpm
        gpsSatellites         = p.gpsSatellites
        gpsFixType            = p.gpsFixType
        loadConfidence        = p.load?.confidence
        loadSamples           = p.load?.samples
        loadMTotalKg          = p.load?.mTotalKg
        loadMLoadKg           = p.load?.mLoadKg
        obfcmDistanceKm       = p.obfcmDistanceKm
        obfcmFuelL            = p.obfcmFuelL
        receivedAt            = Date()
    }
}

// MARK: - Journey summary (derived from events, no separate table needed)

struct JourneySummary: Content {
    var journeyID:          String
    var vehicleID:          String
    var vehicleName:        String
    var startedAt:          Date?
    var endedAt:            Date?
    var driverID:           String?
    var totalDistanceKm:    Double?
    var totalFuelConsumedL: Double?
    var maxSpeedKmh:        Double?
    var eventCount:         Int
    // Load estimation (best across the journey; nil when no data available)
    var loadConfidence:     String?
    var loadSamples:        Int?
    var loadMTotalKg:       Double?
    var loadMLoadKg:        Double?
}

// MARK: - Migration

struct CreateVehicleEvent: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(VehicleEvent.schema)
            .id()
            .field("journey_id",          .string,   .required)
            .field("vehicle_id",          .string,   .required)
            .field("vehicle_name",        .string,   .required)
            .field("event_type",          .string,   .required)
            .field("timestamp",           .datetime, .required)
            .field("latitude",            .double)
            .field("longitude",           .double)
            .field("heading_deg",         .double)
            .field("speed_kmh",           .double)
            .field("odometer_km",             .double)
            .field("journey_distance_km",     .double)
            .field("fuel_level_pct",           .int)
            .field("driver_id",                .string)
            .field("journey_fuel_consumed_l",  .double)
            .field("engine_rpm",               .int)
            .field("imei",                     .string)
            .field("sensor_name",          .string)
            .field("received_at",          .datetime, .required)
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(VehicleEvent.schema).delete()
    }
}

// MARK: - Migration: renomme sensor_id → imei et ajoute imei/sensor_name si absents
// Nécessaire pour les bases créées avant l'introduction du champ IMEI.

struct MigrateVehicleEventSensorIDToIMEI: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        // Ajoute la colonne imei si elle n'existe pas encore
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN imei TEXT").run()
        // Copie les valeurs de sensor_id vers imei pour les lignes existantes
        try? await sql.raw("UPDATE vehicle_events SET imei = sensor_id WHERE imei IS NULL AND sensor_id IS NOT NULL").run()
        // Ajoute sensor_name si absent (ancien schéma)
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN sensor_name TEXT").run()
    }
    func revert(on db: Database) async throws { /* SQLite ne supporte pas DROP COLUMN */ }
}

// MARK: - Migration: ajoute driver_id et journey_fuel_consumed_l

struct AddDriverIdAndJourneyFuelToVehicleEvent: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN driver_id TEXT").run()
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN journey_fuel_consumed_l REAL").run()
    }
    func revert(on db: Database) async throws { /* SQLite ne supporte pas DROP COLUMN */ }
}

// MARK: - Migration: ajoute gps_satellites sur vehicle_events

struct AddGpsSatellitesToVehicleEvents: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN gps_satellites INTEGER").run()
    }
    func revert(on db: Database) async throws { /* SQLite ne supporte pas DROP COLUMN */ }
}

// MARK: - Migration: indexes recommandés par la spec firmware (README_JOURNEY_API.md)

struct AddVehicleEventIndexes: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try? await sql.raw("CREATE INDEX IF NOT EXISTS idx_ve_imei_ts  ON vehicle_events (imei, timestamp)").run()
        try? await sql.raw("CREATE INDEX IF NOT EXISTS idx_ve_journey  ON vehicle_events (journey_id, timestamp)").run()
    }
    func revert(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try? await sql.raw("DROP INDEX IF EXISTS idx_ve_imei_ts").run()
        try? await sql.raw("DROP INDEX IF EXISTS idx_ve_journey").run()
    }
}

// MARK: - Migration: ajoute gps_fix_type sur vehicle_events (spec v6)

struct AddGpsFixTypeToVehicleEvents: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN gps_fix_type INTEGER").run()
    }
    func revert(on db: Database) async throws { /* SQLite ne supporte pas DROP COLUMN */ }
}

// MARK: - Migration: ajoute les champs load_estimator sur vehicle_events

struct AddLoadEstimationToVehicleEvents: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN load_confidence TEXT").run()
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN load_samples INTEGER").run()
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN load_m_total_kg REAL").run()
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN load_m_load_kg REAL").run()
    }
    func revert(on db: Database) async throws { /* SQLite does not support DROP COLUMN */ }
}

// MARK: - Migration: ajoute les champs OBFCM lifetime sur vehicle_events

struct AddObfcmToVehicleEvents: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN obfcm_distance_km REAL").run()
        try? await sql.raw("ALTER TABLE vehicle_events ADD COLUMN obfcm_fuel_l REAL").run()
    }
    func revert(on db: Database) async throws { /* SQLite does not support DROP COLUMN */ }
}
