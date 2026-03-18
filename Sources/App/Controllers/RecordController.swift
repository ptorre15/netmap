import Vapor
import Fluent
import SQLKit

// MARK: - API Key Middleware

struct APIKeyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard request.application.isValidAPIKey(request.headers.first(name: "X-API-Key") ?? "") else {
            throw Abort(.unauthorized, reason: "Invalid or missing API key. Set X-API-Key header.")
        }
        return try await next.respond(to: request)
    }
}

/// Accepts either a valid X-API-Key header OR a Bearer token with admin role.
/// Used for destructive operations that should be accessible from both tracker devices and the web dashboard admin.
struct APIKeyOrAdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Accept valid API key
        if request.application.isValidAPIKey(request.headers.first(name: "X-API-Key") ?? "") {
            return try await next.respond(to: request)
        }
        // Accept admin auth via Bearer token or session cookie
        if let auth = try await authUserFromBearerOrCookie(request), auth.isAdmin {
            request.authUser = auth
            return try await next.respond(to: request)
        }
        throw Abort(.unauthorized, reason: "Valid API key or admin Bearer token required.")
    }
}

/// Accepts either a valid X-API-Key header OR any valid Bearer token.
/// Used for read endpoints that must not be publicly accessible.
struct APIKeyOrBearerMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        // Accept valid API key
        if request.application.isValidAPIKey(request.headers.first(name: "X-API-Key") ?? "") {
            return try await next.respond(to: request)
        }
        // Accept valid auth via Bearer token or session cookie (any role)
        if let auth = try await authUserFromBearerOrCookie(request) {
            request.authUser = auth
            return try await next.respond(to: request)
        }
        throw Abort(.unauthorized, reason: "Valid API key or Bearer token required.")
    }
}

// MARK: - Sensor summary (used by web dashboard)

struct SensorStat: Content {
    var sensorID:            String
    var vehicleID:           String
    var vehicleName:         String
    var assetTypeID:         String
    var brand:               String
    var wheelPosition:       String?
    var latestPressureBar:   Double?    // nil for non-TPMS sensors
    var latestTemperatureC:  Double?
    var latestVbattVolts:    Double?
    var targetPressureBar:   Double?
    var latestBatteryPct:    Int?       // 0-100 for Stihl / ELA
    var latestChargeState:   String?    // Stihl battery: "Idle" | "Charging" | …
    var sensorName:          String?    // human-readable name from device
    var latestHealthPct:     Int?       // Stihl Smart Battery health %
    var latestChargingCycles: Int?      // Stihl Smart Battery charge cycles
    var latestProductVariant: String?   // ELA: "coin" | "puck" | "unknown"
    var latestTotalSeconds:  Int?       // Stihl total operating / discharge time (s)
    var latestTimestamp:     Date
    var readingCount:        Int
    var latestGpsSatellites: Int?          // GPS tracker: satellites in view
    var latestLatitude:      Double?
    var latestLongitude:     Double?
    var trackerServerConfigVersion:  Int?   // schemaVersion stored on server for this tracker
    var trackerAppliedConfigVersion: Int?   // last configVersion reported by the tracker
    var trackerProfileName:    String?      // active config profile name
    var trackerProfileVersion: Int?         // active config profile version
}

struct PunctureRiskResponse: Content {
    var sensorID:     String
    var hasRisk:      Bool
    var pressureDrop: Double    // baseline − recent (bar)
    var baseline:     Double?   // average pressure of first half of sample
    var recent:       Double?   // average pressure of second half of sample
    var readingCount: Int
    var message:      String
}

struct RecordController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let api       = routes.grouped("api", "records")
        let protected = api.grouped(APIKeyMiddleware())

        // Protected writes
        protected.post(use: createSingle)           // POST /api/records
        protected.post("batch", use: createBatch)   // POST /api/records/batch
        protected.delete("purge", use: purge)       // DELETE /api/records/purge

        // Pairing registration (no BLE data required)
        let sensorAPI = routes.grouped("api", "sensors").grouped(APIKeyMiddleware())
        sensorAPI.post("pair",          use: registerPairing)     // POST /api/sensors/pair

        // DELETE accepts both API key (from mobile app) and admin Bearer token (from web dashboard)
        routes.grouped("api", "sensors")
              .grouped(APIKeyOrAdminMiddleware())
              .delete("pair", ":sensorID", use: unregisterPairing) // DELETE /api/sensors/pair/:sensorID

        // Authenticated reads (API key or Bearer token)
        let protectedRead = api.grouped(APIKeyOrBearerMiddleware())
        protectedRead.get(use: list)                                       // GET /api/records
        protectedRead.get("by-sensor",  ":sensorID",  use: bySensor)      // GET /api/records/by-sensor/:sensorID
        protectedRead.get("by-vehicle", ":vehicleID", use: byVehicle)     // GET /api/records/by-vehicle/:vehicleID

        // Puncture risk analysis
        routes.grouped("api", "sensors")
              .grouped(APIKeyOrBearerMiddleware())
              .get(":sensorID", "puncture-risk", use: punctureRisk)
                                                                 // GET /api/sensors/:sensorID/puncture-risk
        // Dashboard summary — authenticated read; non-admin Bearer users are filtered to linked assets.
        routes.grouped("api", "sensors")
              .grouped(APIKeyOrBearerMiddleware())
              .get("latest", use: sensorsLatest)
    }

    // MARK: - Write

    /// POST /api/records  — single record
    func createSingle(req: Request) async throws -> HTTPStatus {
        let p = try req.content.decode(SensorPayload.self)
        try await SensorReading(from: p).save(on: req.db)
        try await upsertVehicles(from: [p], on: req.db)
        Task { await broadcastPayloads([p]) }
        return .created
    }

    /// POST /api/records/batch  — array of records (preferred from app)
    func createBatch(req: Request) async throws -> HTTPStatus {
        let payloads = try req.content.decode([SensorPayload].self)
        try await req.db.transaction { db in
            for p in payloads {
                try await SensorReading(from: p).save(on: db)
            }
        }
        try await upsertVehicles(from: payloads, on: req.db)
        Task { await broadcastPayloads(payloads) }
        // Log one line per brand so the web log viewer can filter by category
        let byBrand = Dictionary(grouping: payloads, by: \.brand)
        for (brand, items) in byBrand.sorted(by: { $0.key < $1.key }) {
            let tag = ["tpms", "ela", "stihl", "continental", "bridgestone", "pirelli"].contains(brand) ? "tms" : brand
            req.logger.info("📦 [\(tag)] \(brand)×\(items.count)")
        }
        return .created
    }

    /// Broadcast a minimal push event for each unique sensor in `payloads`.
    private func broadcastPayloads(_ payloads: [SensorPayload]) async {
        // Deduplicate: one message per sensor (last value wins)
        var bySensor: [String: SensorPayload] = [:]
        for p in payloads { bySensor[p.sensorID] = p }
        for p in bySensor.values {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            // Build a minimal event — only fields the dashboard needs for live update
            let event: [String: Any] = [
                "type":         "record",
                "sensorID":     p.sensorID,
                "vehicleID":    p.vehicleID,
                "brand":        p.brand,
                "pressureBar":  p.pressureBar as Any,
                "temperatureC": p.sanitizedTemperatureC as Any,
                "batteryPct":   p.batteryPct as Any,
                "timestamp":    ISO8601DateFormatter().string(from: p.timestamp),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: event),
               let json = String(data: data, encoding: .utf8) {
                await WebSocketBroadcaster.shared.broadcast(json)
            }
        }
    }

    /// Ensures all vehicles referenced in payloads exist in the `vehicles` table.
    /// Creates missing entries using the vehicleID as primary key so the link is stable.
    private func upsertVehicles(from payloads: [SensorPayload], on db: Database) async throws {
        var seen = Set<String>()
        for p in payloads {
            guard seen.insert(p.vehicleID).inserted else { continue }
            guard let uuid = UUID(uuidString: p.vehicleID) else { continue }
            // Already exists by UUID — nothing to do
            if try await Vehicle.find(uuid, on: db) != nil { continue }
            // Check by name — avoid creating a duplicate after app reinstall
            if let existing = try await Vehicle.query(on: db).filter(\.$name == p.vehicleName).first() {
                // The iOS app now has a different UUID for the same vehicle;
                // we cannot remap the UUID here, so just skip creating a dup.
                _ = existing
                continue
            }
            let v = Vehicle(name: p.vehicleName,
                            assetTypeID: p.assetTypeID ?? "vehicle",
                            createdBy: "system")
            v.id = uuid
            try await v.save(on: db)
        }
    }

    // MARK: - Read

    /// GET /api/records?limit=&vehicle=&sensor=&brand=
    /// Default: 1 000 rows. Max: 10 000 rows (pass ?limit= to customise within the cap).
    func list(req: Request) async throws -> [SensorReading] {
        let requested = (try? req.query.get(Int.self, at: "limit")) ?? 1_000
        let limit = min(max(1, requested), 10_000)
        var q = SensorReading.query(on: req.db).sort(\.$timestamp, .descending)
        if let v = try? req.query.get(String.self, at: "vehicle") { q = q.filter(\.$vehicleID == v) }
        if let s = try? req.query.get(String.self, at: "sensor")  { q = q.filter(\.$sensorID  == s) }
        if let b = try? req.query.get(String.self, at: "brand")   { q = q.filter(\.$brand     == b) }
        return try await q.limit(limit).all()
    }

    /// GET /api/records/by-sensor/:sensorID?from=ISO8601&to=ISO8601&limit=
    /// Default: 1 000 rows. Max: 10 000 rows.
    func bySensor(req: Request) async throws -> [SensorReading] {
        guard let id = req.parameters.get("sensorID") else { throw Abort(.badRequest) }
        let requested = (try? req.query.get(Int.self, at: "limit")) ?? 1_000
        let limit = min(max(1, requested), 10_000)
        var q = SensorReading.query(on: req.db)
            .filter(\.$sensorID == id)
            .sort(\.$timestamp, .descending)
        if let from = dateParam(req, key: "from") { q = q.filter(\.$timestamp >= from) }
        if let to   = dateParam(req, key: "to")   { q = q.filter(\.$timestamp <= to) }
        return try await q.limit(limit).all()
    }

    /// GET /api/records/by-vehicle/:vehicleID?from=ISO8601&to=ISO8601&limit=
    /// Default: 1 000 rows. Max: 10 000 rows.
    func byVehicle(req: Request) async throws -> [SensorReading] {
        guard let id = req.parameters.get("vehicleID") else { throw Abort(.badRequest) }
        let requested = (try? req.query.get(Int.self, at: "limit")) ?? 1_000
        let limit = min(max(1, requested), 10_000)
        var q = SensorReading.query(on: req.db)
            .filter(\.$vehicleID == id)
            .sort(\.$timestamp, .descending)
        if let from = dateParam(req, key: "from") { q = q.filter(\.$timestamp >= from) }
        if let to   = dateParam(req, key: "to")   { q = q.filter(\.$timestamp <= to) }
        return try await q.limit(limit).all()
    }

    /// GET /api/sensors/latest — one summary row per unique sensor (used by web dashboard).
    /// Single SQL GROUP BY query — no full-table scan.
    func sensorsLatest(req: Request) async throws -> [SensorStat] {
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }

        struct LatestRow: Decodable {
            var sensor_id:           String
            var vehicle_id:          String
            var vehicle_name:        String
            var asset_type_id:       String?
            var brand:               String
            var wheel_position:      String?
            var pressure_bar:        Double?
            var temperature_c:       Double?
            var vbatt_volts:         Double?
            var target_pressure_bar: Double?
            var battery_pct:         Int?
            var charge_state:        String?
            var sensor_name:         String?
            var health_pct:          Int?
            var charging_cycles:     Int?
            var product_variant:     String?
            var total_seconds:       Int?
            var gps_satellites:                  Int?
            var timestamp:                      Double
            var latitude:                       Double?
            var longitude:                      Double?
            var reading_count:                  Int
            var server_config_version:          Int?
            var last_applied_config_version:    Int?
            var profile_name:                   String?
            var profile_version:                Int?
        }

        // User filter clause (non-admin sees only their linked assets)
        var vehicleFilter = ""
        if let auth = req.authUser, !auth.isAdmin {
            let ids = try await UserAsset.query(on: req.db)
                .filter(\.$userID == auth.userID).all().map { $0.assetID.uuidString.uppercased() }
            if ids.isEmpty { return [] }
            let quoted = ids.map { "'\($0)'" }.joined(separator: ",")
            vehicleFilter = "WHERE UPPER(c.vehicle_id) IN (\(quoted))"
        }

        let rows = try await sql.raw("""
            WITH latest_sensor AS (
                SELECT sr.sensor_id, sr.vehicle_id, sr.vehicle_name, sr.brand,
                       sr.wheel_position, sr.pressure_bar, sr.temperature_c, sr.vbatt_volts,
                       sr.target_pressure_bar, sr.battery_pct, sr.charge_state, sr.sensor_name,
                       sr.health_pct, sr.charging_cycles, sr.product_variant,
                       sr.total_seconds, sr.gps_satellites,
                       CASE WHEN sr.brand = 'tracker'
                            THEN MAX(sr.timestamp,
                                     COALESCE(ve_max.max_ts, sr.timestamp),
                                     COALESCE(dle_max.max_ts, sr.timestamp))
                            ELSE sr.timestamp
                       END AS timestamp,
                       sr.latitude, sr.longitude,
                       grp.reading_count,
                       COALESCE(v.asset_type_id, 'vehicle') AS asset_type_id
                FROM sensor_readings sr
                INNER JOIN (
                    SELECT sensor_id, MAX(timestamp) AS max_ts, COUNT(*) AS reading_count
                    FROM sensor_readings
                    GROUP BY sensor_id
                ) grp ON sr.sensor_id = grp.sensor_id AND sr.timestamp = grp.max_ts
                LEFT JOIN vehicles v ON sr.vehicle_id = v.id
                LEFT JOIN (
                    SELECT imei, MAX(timestamp) AS max_ts
                    FROM vehicle_events
                    WHERE imei IS NOT NULL AND imei != ''
                    GROUP BY imei
                ) ve_max ON ve_max.imei = sr.sensor_id
                LEFT JOIN (
                    SELECT imei, MAX(timestamp) AS max_ts
                    FROM device_lifecycle_events
                    WHERE imei IS NOT NULL AND imei != ''
                    GROUP BY imei
                ) dle_max ON dle_max.imei = sr.sensor_id
                GROUP BY sr.sensor_id
            ),
            latest_orphan_tracker AS (
                SELECT ve.imei AS sensor_id,
                       ve.vehicle_id,
                       ve.vehicle_name,
                       'tracker' AS brand,
                       NULL AS wheel_position,
                       NULL AS pressure_bar,
                       NULL AS temperature_c,
                       NULL AS vbatt_volts,
                       NULL AS target_pressure_bar,
                       NULL AS battery_pct,
                       NULL AS charge_state,
                       ve.sensor_name AS sensor_name,
                       NULL AS health_pct,
                       NULL AS charging_cycles,
                       NULL AS product_variant,
                       NULL AS total_seconds,
                       ve.gps_satellites,
                       ve.timestamp,
                       ve.latitude,
                       ve.longitude,
                       stats.reading_count,
                       COALESCE(v.asset_type_id, 'vehicle') AS asset_type_id
                FROM vehicle_events ve
                INNER JOIN (
                    SELECT imei, MAX(timestamp) AS max_ts, COUNT(*) AS reading_count
                    FROM vehicle_events
                    WHERE imei IS NOT NULL AND imei != ''
                    GROUP BY imei
                ) stats ON stats.imei = ve.imei AND stats.max_ts = ve.timestamp
                LEFT JOIN sensor_readings sr ON sr.sensor_id = ve.imei
                LEFT JOIN vehicles v ON ve.vehicle_id = v.id
                WHERE ve.imei IS NOT NULL
                  AND ve.imei != ''
                  AND sr.sensor_id IS NULL
            ),
            combined AS (
                SELECT * FROM latest_sensor
                UNION ALL
                SELECT * FROM latest_orphan_tracker
            )
            SELECT c.*, tc.schema_version AS server_config_version,
                         tc.last_applied_config_version,
                         tcp.name    AS profile_name,
                         tcp.version AS profile_version
            FROM combined c
            LEFT JOIN tracker_configs tc ON tc.imei = c.sensor_id
            LEFT JOIN tracker_config_profiles tcp ON tcp.id = tc.profile_id
            \(unsafeRaw: vehicleFilter)
            ORDER BY c.vehicle_name, c.wheel_position
            """).all(decoding: LatestRow.self)

        return rows.map { r in
            return SensorStat(
                sensorID:           r.sensor_id,
                vehicleID:          r.vehicle_id,
                vehicleName:        r.vehicle_name,
                assetTypeID:        r.asset_type_id ?? "vehicle",
                brand:              r.brand,
                wheelPosition:      r.wheel_position,
                latestPressureBar:  r.pressure_bar,
                latestTemperatureC: r.temperature_c,
                latestVbattVolts:   r.vbatt_volts,
                targetPressureBar:  r.target_pressure_bar,
                latestBatteryPct:    r.battery_pct,
                latestChargeState:   r.charge_state,
                sensorName:          r.sensor_name,
                latestHealthPct:     r.health_pct,
                latestChargingCycles: r.charging_cycles,
                latestProductVariant: r.product_variant,
                latestTotalSeconds:   r.total_seconds,
                latestTimestamp:      Date(timeIntervalSince1970: r.timestamp),
                readingCount:         r.reading_count,
                latestGpsSatellites:          r.gps_satellites,
                latestLatitude:               r.latitude,
                latestLongitude:              r.longitude,
                trackerServerConfigVersion:   r.server_config_version,
                trackerAppliedConfigVersion:  r.last_applied_config_version,
                trackerProfileName:    r.profile_name,
                trackerProfileVersion: r.profile_version
            )
        }
    }

    // MARK: - Slow Puncture Detection

    /// GET /api/sensors/:sensorID/puncture-risk
    /// Analyses the last 60 readings and checks for a statistically significant downward pressure trend.
    func punctureRisk(req: Request) async throws -> PunctureRiskResponse {
        guard let sensorID = req.parameters.get("sensorID") else { throw Abort(.badRequest) }

        let readings = try await SensorReading.query(on: req.db)
            .filter(\.$sensorID == sensorID)
            .sort(\.$timestamp, .descending)
            .limit(60)
            .all()
            .reversed()   // chronological order

        guard readings.count >= 10 else {
            return PunctureRiskResponse(
                sensorID: sensorID, hasRisk: false,
                pressureDrop: 0, baseline: nil, recent: nil,
                readingCount: readings.count,
                message: "Not enough data (need ≥ 10 readings, got \(readings.count))"
            )
        }

        let mid      = readings.count / 2
        let first    = Array(readings.prefix(mid))
        let last     = Array(readings.suffix(mid))
        let baseline = first.compactMap(\.pressureBar).reduce(0, +) / Double(first.count)
        let recent   = last.compactMap(\.pressureBar).reduce(0, +)  / Double(last.count)
        let drop     = baseline - recent
        let dropPct  = baseline > 0 ? (drop / baseline) * 100 : 0
        let hasRisk  = drop > 0.08 && dropPct > 3.0   // >0.08 bar AND >3% drop

        let message: String
        if hasRisk {
            message = String(format: "Pressure dropped %.2f bar (%.1f%%) over the last %d readings — slow puncture likely.",
                             drop, dropPct, readings.count)
        } else if drop > 0.04 {
            message = String(format: "Minor pressure loss observed (%.2f bar, %.1f%%). Monitor closely.",
                             drop, dropPct)
        } else {
            message = "Pressure is stable."
        }

        return PunctureRiskResponse(
            sensorID: sensorID, hasRisk: hasRisk,
            pressureDrop: round(drop * 1000) / 1000,
            baseline: round(baseline * 100) / 100,
            recent:   round(recent   * 100) / 100,
            readingCount: readings.count,
            message: message
        )
    }

    // MARK: - Pairing registration

    /// POST /api/sensors/pair
    /// Registers a sensor <-> vehicle pairing immediately, without needing a live BLE reading.
    /// Creates/updates a SensorReading row with null pressure so the sensor appears in
    /// GET /api/sensors/latest and is visible in the web dashboard right away.
    func registerPairing(req: Request) async throws -> HTTPStatus {
        struct PairingPayload: Content {
            var sensorID:          String
            var vehicleID:         String
            var vehicleName:       String
            var assetTypeID:       String?
            var brand:             String
            var wheelPosition:     String?
            var targetPressureBar: Double?
            var sensorName:        String?
        }
        let p = try req.content.decode(PairingPayload.self)
        guard !p.sensorID.isEmpty, !p.vehicleID.isEmpty
        else { throw Abort(.badRequest, reason: "sensorID and vehicleID are required") }

        // Upsert the vehicle record so it exists in the vehicles table
        let syntheticPayload = SensorPayload(
            sensorID:      p.sensorID,
            vehicleID:     p.vehicleID,
            vehicleName:   p.vehicleName,
            assetTypeID:   p.assetTypeID,
            brand:         p.brand,
            wheelPosition: p.wheelPosition,
            pressureBar:   nil, temperatureC: nil, vbattVolts: nil,
            targetPressureBar: p.targetPressureBar,
            batteryPct:    nil, chargeState: nil,
            sensorName:    p.sensorName,
            healthPct:     nil, chargingCycles: nil,
            productVariant: nil, totalSeconds: nil,
            latitude:      nil, longitude: nil,
            timestamp:     Date()
        )
        try await upsertVehicles(from: [syntheticPayload], on: req.db)

        // Keep historical rows intact. Insert a fresh synthetic row so /api/sensors/latest
        // immediately reflects the new pairing without destroying telemetry history.
        let r = SensorReading(from: syntheticPayload)
        try await r.save(on: req.db)

        req.logger.info("Pairing registered: sensor \(p.sensorID) -> vehicle \(p.vehicleName) (\(p.vehicleID))")
        return .created
    }

    /// DELETE /api/sensors/pair/:sensorID
    /// Removes all server-side readings for a sensor so it disappears from the dashboard.
    func unregisterPairing(req: Request) async throws -> HTTPStatus {
        guard let sensorID = req.parameters.get("sensorID") else {
            throw Abort(.badRequest, reason: "sensorID path parameter is required")
        }
        let count = try await SensorReading.query(on: req.db)
            .filter(\.$sensorID == sensorID)
            .count()
        try await SensorReading.query(on: req.db)
            .filter(\.$sensorID == sensorID)
            .delete()
        req.logger.info("Unpairing: sensor \(sensorID) removed (\(count) readings deleted)")
        return .noContent
    }

    // MARK: - Helpers

    private func dateParam(_ req: Request, key: String) -> Date? {
        guard let s = try? req.query.get(String.self, at: key) else { return nil }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// DELETE /api/records/purge?older_than_days=30
    func purge(req: Request) async throws -> [String: Int] {
        let days   = (try? req.query.get(Int.self, at: "older_than_days")) ?? 30
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let count  = try await SensorReading.query(on: req.db).filter(\.$timestamp < cutoff).count()
        try await SensorReading.query(on: req.db).filter(\.$timestamp < cutoff).delete()
        return ["deleted": count]
    }
}
