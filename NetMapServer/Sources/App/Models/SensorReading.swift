import Fluent
import Vapor
import SQLKit

// MARK: - DTO (received from the iOS/macOS app)

struct SensorPayload: Content {
    var sensorID:          String
    var vehicleID:         String
    var vehicleName:       String
    var assetTypeID:       String?         // optional — used to auto-create vehicle record
    var brand:             String          // "michelin" | "stihl" | "ela" | "airtag" | …
    var wheelPosition:     String?         // "FL" | "FR" | "RL" | "RR" | nil
    var pressureBar:       Double?         // nil for non-TPMS sensors
    var temperatureC:      Double?
    var vbattVolts:        Double?
    var targetPressureBar: Double?
    var batteryPct:        Int?            // 0-100, for Stihl / ELA / AirTag
    var chargeState:       String?         // Stihl battery state: "Idle" | "Discharging" | "Charging" | "Full" | …
    var sensorName:        String?         // human-readable name: AirTag name, Stihl product, custom label…
    var healthPct:         Int?            // 0-100, Stihl Smart Battery health
    var chargingCycles:    Int?            // Stihl Smart Battery charge cycles
    var productVariant:    String?         // ELA product variant: "coin" | "puck" | "unknown"
    var totalSeconds:      Int?            // Stihl total operating / discharge time (seconds)
    var gpsSatellites:     Int?            // GPS tracker: number of satellites in view
    var latitude:          Double?
    var longitude:         Double?
    var timestamp:         Date
}

// MARK: - Fluent Model (SQLite row)

final class SensorReading: Model, Content {
    static let schema = "sensor_readings"

    @ID(key: .id)                                  var id:               UUID?
    @Field(key: "sensor_id")                       var sensorID:         String
    @Field(key: "vehicle_id")                      var vehicleID:        String
    @Field(key: "vehicle_name")                    var vehicleName:      String
    @Field(key: "brand")                           var brand:            String
    @OptionalField(key: "wheel_position")          var wheelPosition:    String?
    @OptionalField(key: "pressure_bar")            var pressureBar:      Double?   // nil for non-TPMS
    @OptionalField(key: "temperature_c")           var temperatureC:     Double?
    @OptionalField(key: "vbatt_volts")             var vbattVolts:       Double?
    @OptionalField(key: "target_pressure_bar")     var targetPressureBar: Double?
    @OptionalField(key: "battery_pct")             var batteryPct:       Int?
    @OptionalField(key: "charge_state")            var chargeState:      String?
    @OptionalField(key: "sensor_name")             var sensorName:       String?
    @OptionalField(key: "health_pct")              var healthPct:        Int?
    @OptionalField(key: "charging_cycles")         var chargingCycles:   Int?
    @OptionalField(key: "product_variant")         var productVariant:   String?
    @OptionalField(key: "total_seconds")           var totalSeconds:     Int?
    @OptionalField(key: "gps_satellites")          var gpsSatellites:    Int?
    @OptionalField(key: "latitude")                var latitude:         Double?
    @OptionalField(key: "longitude")               var longitude:        Double?
    @Field(key: "timestamp")                       var timestamp:        Date
    @Field(key: "received_at")                     var receivedAt:       Date

    init() {}

    init(from p: SensorPayload) {
        sensorID          = p.sensorID
        vehicleID         = p.vehicleID
        vehicleName       = p.vehicleName
        brand             = p.brand
        wheelPosition     = p.wheelPosition
        pressureBar       = p.pressureBar
        temperatureC      = p.temperatureC
        vbattVolts        = p.vbattVolts
        targetPressureBar = p.targetPressureBar
        batteryPct        = p.batteryPct
        chargeState       = p.chargeState
        sensorName        = p.sensorName
        healthPct         = p.healthPct
        chargingCycles    = p.chargingCycles
        productVariant    = p.productVariant
        totalSeconds      = p.totalSeconds
        gpsSatellites     = p.gpsSatellites
        latitude          = p.latitude
        longitude         = p.longitude
        timestamp         = p.timestamp
        receivedAt        = Date()
    }
}

// MARK: - Original migration (unchanged schema)

struct CreateSensorReading: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(SensorReading.schema)
            .id()
            .field("sensor_id",          .string,   .required)
            .field("vehicle_id",         .string,   .required)
            .field("vehicle_name",       .string,   .required)
            .field("brand",              .string,   .required)
            .field("wheel_position",     .string)
            .field("pressure_bar",       .double,   .required)
            .field("temperature_c",      .double)
            .field("vbatt_volts",        .double)
            .field("target_pressure_bar", .double)
            .field("latitude",           .double)
            .field("longitude",          .double)
            .field("timestamp",          .datetime, .required)
            .field("received_at",        .datetime, .required)
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(SensorReading.schema).delete()
    }
}

// MARK: - v2 migration: make pressure_bar nullable + add battery_pct / charge_state

/// SQLite does not support ALTER COLUMN, so we recreate the table.
struct AddSensorBatteryFields: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        // SQLite ne supporte pas ALTER COLUMN ni le multi-statement dans SQLKit.
        // On recrée la table en exécutant chaque statement individuellement.
        try await sql.raw("PRAGMA foreign_keys = OFF").run()
        try await sql.raw("ALTER TABLE sensor_readings RENAME TO sensor_readings_v1").run()
        try await sql.raw("""
            CREATE TABLE sensor_readings (\
                id TEXT PRIMARY KEY, \
                sensor_id TEXT NOT NULL, \
                vehicle_id TEXT NOT NULL, \
                vehicle_name TEXT NOT NULL, \
                brand TEXT NOT NULL, \
                wheel_position TEXT, \
                pressure_bar REAL, \
                temperature_c REAL, \
                vbatt_volts REAL, \
                target_pressure_bar REAL, \
                battery_pct INTEGER, \
                charge_state TEXT, \
                sensor_name TEXT, \
                latitude REAL, \
                longitude REAL, \
                timestamp REAL NOT NULL, \
                received_at REAL NOT NULL\
            )
            """).run()
        try await sql.raw("""
            INSERT INTO sensor_readings \
                SELECT id, sensor_id, vehicle_id, vehicle_name, brand, wheel_position, \
                       pressure_bar, temperature_c, vbatt_volts, target_pressure_bar, \
                       NULL, NULL, NULL, latitude, longitude, timestamp, received_at \
                FROM sensor_readings_v1
            """).run()
        try await sql.raw("DROP TABLE sensor_readings_v1").run()
        try await sql.raw("PRAGMA foreign_keys = ON").run()
    }
    func revert(on db: Database) async throws { /* data migration — no safe revert */ }
}

// MARK: - v4 migration: add total_seconds

struct AddTotalSecondsField: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw("ALTER TABLE sensor_readings ADD COLUMN total_seconds INTEGER").run()
    }
    func revert(on db: Database) async throws { /* SQLite does not support DROP COLUMN */ }
}

// MARK: - v5 migration: add gps_satellites

struct AddGpsSatellitesField: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw("ALTER TABLE sensor_readings ADD COLUMN gps_satellites INTEGER").run()
    }
    func revert(on db: Database) async throws { /* SQLite does not support DROP COLUMN */ }
}


struct AddSensorDetailFields: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw("ALTER TABLE sensor_readings ADD COLUMN health_pct INTEGER").run()
        try await sql.raw("ALTER TABLE sensor_readings ADD COLUMN charging_cycles INTEGER").run()
        try await sql.raw("ALTER TABLE sensor_readings ADD COLUMN product_variant TEXT").run()
    }
    func revert(on db: Database) async throws { /* SQLite does not support DROP COLUMN */ }
}


