import Vapor
import Fluent
import SQLKit

// MARK: - Model

final class DeviceLifecycleEvent: Model, Content {
    static let schema = "device_lifecycle_events"

    @ID(key: .id)                                var id:              UUID?
    @Field(key: "imei")                          var imei:            String
    @Field(key: "vehicle_id")                    var vehicleID:       String
    @Field(key: "vehicle_name")                  var vehicleName:     String
    @Field(key: "event_type")                    var eventType:       String
    @Field(key: "timestamp")                     var timestamp:       Date
    @OptionalField(key: "reset_reason")          var resetReason:     String?
    @OptionalField(key: "wakeup_source")         var wakeupSource:    String?
    @OptionalField(key: "battery_voltage_v")     var batteryVoltageV: Double?
    @OptionalField(key: "gps_fix_type")          var gpsFixType:      Int?
    @OptionalField(key: "latitude")              var latitude:        Double?
    @OptionalField(key: "longitude")             var longitude:       Double?
    @OptionalField(key: "heading_deg")           var headingDeg:      Double?
    @OptionalField(key: "speed_kmh")             var speedKmh:        Double?
    @OptionalField(key: "gps_satellites")        var gpsSatellites:   Int?
    @Field(key: "received_at")                   var receivedAt:      Date

    init() {}

    init(imei: String, vehicleID: String, vehicleName: String,
         eventType: String, timestamp: Date,
         resetReason: String?, wakeupSource: String?, batteryVoltageV: Double?,
         gpsFixType: Int?, latitude: Double?, longitude: Double?,
         headingDeg: Double?, speedKmh: Double?, gpsSatellites: Int?) {
        self.imei             = imei
        self.vehicleID        = vehicleID
        self.vehicleName      = vehicleName
        self.eventType        = eventType
        self.timestamp        = timestamp
        self.resetReason      = resetReason
        self.wakeupSource     = wakeupSource
        self.batteryVoltageV  = batteryVoltageV
        self.gpsFixType       = gpsFixType
        self.latitude         = latitude
        self.longitude        = longitude
        self.headingDeg       = headingDeg
        self.speedKmh         = speedKmh
        self.gpsSatellites    = gpsSatellites
        self.receivedAt       = Date()
    }
}

// MARK: - Migration

struct CreateDeviceLifecycleEvent: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(DeviceLifecycleEvent.schema)
            .id()
            .field("imei",             .string,   .required)
            .field("vehicle_id",       .string,   .required)
            .field("vehicle_name",     .string,   .required)
            .field("event_type",       .string,   .required)
            .field("timestamp",        .datetime, .required)
            .field("reset_reason",     .string)
            .field("wakeup_source",    .string)
            .field("battery_voltage_v",.double)
            .field("received_at",      .datetime, .required)
            .create()

        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_dle_imei       ON device_lifecycle_events (imei)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_dle_vehicle    ON device_lifecycle_events (vehicle_id)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_dle_event_type ON device_lifecycle_events (event_type)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_dle_ts         ON device_lifecycle_events (timestamp)").run()
    }

    func revert(on db: Database) async throws {
        try await db.schema(DeviceLifecycleEvent.schema).delete()
    }
}

// MARK: - Migration: ajoute GPS fields + gpsFixType sur device_lifecycle_events (spec v6)

struct AddGpsToDeviceLifecycleEvents: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try? await sql.raw("ALTER TABLE device_lifecycle_events ADD COLUMN gps_fix_type  INTEGER").run()
        try? await sql.raw("ALTER TABLE device_lifecycle_events ADD COLUMN latitude      REAL").run()
        try? await sql.raw("ALTER TABLE device_lifecycle_events ADD COLUMN longitude     REAL").run()
        try? await sql.raw("ALTER TABLE device_lifecycle_events ADD COLUMN heading_deg   REAL").run()
        try? await sql.raw("ALTER TABLE device_lifecycle_events ADD COLUMN speed_kmh     REAL").run()
        try? await sql.raw("ALTER TABLE device_lifecycle_events ADD COLUMN gps_satellites INTEGER").run()
    }
    func revert(on db: Database) async throws { /* SQLite ne supporte pas DROP COLUMN */ }
}

// MARK: - Response DTO

/// Response object whose optional fields are omitted (not written as null) when absent.
private struct LifecycleEventResponse: Encodable {
    let id:              String
    let imei:            String
    let vehicleID:       String
    let vehicleName:     String
    let eventType:       String
    let timestamp:       Date
    let resetReason:     String?
    let wakeupSource:    String?
    let batteryVoltageV: Double?
    let gpsFixType:      Int?
    let latitude:        Double?
    let longitude:       Double?
    let headingDeg:      Double?
    let speedKmh:        Double?
    let gpsSatellites:   Int?
    let receivedAt:      Date

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,           forKey: .id)
        try c.encode(imei,         forKey: .imei)
        try c.encode(vehicleID,    forKey: .vehicleID)
        try c.encode(vehicleName,  forKey: .vehicleName)
        try c.encode(eventType,    forKey: .eventType)
        try c.encode(timestamp,    forKey: .timestamp)
        try c.encodeIfPresent(resetReason,     forKey: .resetReason)
        try c.encodeIfPresent(wakeupSource,    forKey: .wakeupSource)
        try c.encodeIfPresent(batteryVoltageV, forKey: .batteryVoltageV)
        try c.encodeIfPresent(gpsFixType,      forKey: .gpsFixType)
        try c.encodeIfPresent(latitude,        forKey: .latitude)
        try c.encodeIfPresent(longitude,       forKey: .longitude)
        try c.encodeIfPresent(headingDeg,      forKey: .headingDeg)
        try c.encodeIfPresent(speedKmh,        forKey: .speedKmh)
        try c.encodeIfPresent(gpsSatellites,   forKey: .gpsSatellites)
        try c.encode(receivedAt,   forKey: .receivedAt)
    }

    enum CodingKeys: String, CodingKey {
        case id, imei, vehicleID, vehicleName, eventType, timestamp
        case resetReason, wakeupSource, batteryVoltageV
        case gpsFixType, latitude, longitude, headingDeg, speedKmh, gpsSatellites
        case receivedAt
    }
}

private extension DeviceLifecycleEvent {
    func toResponse() -> LifecycleEventResponse {
        LifecycleEventResponse(
            id:              id?.uuidString ?? "",
            imei:            imei,
            vehicleID:       vehicleID,
            vehicleName:     vehicleName,
            eventType:       eventType,
            timestamp:       timestamp,
            resetReason:     resetReason,
            wakeupSource:    wakeupSource,
            batteryVoltageV: batteryVoltageV,
            gpsFixType:      gpsFixType,
            latitude:        latitude,
            longitude:       longitude,
            headingDeg:      headingDeg,
            speedKmh:        speedKmh,
            gpsSatellites:   gpsSatellites,
            receivedAt:      receivedAt
        )
    }
}

// MARK: - Summary DTOs

private struct SummaryBootInfo: Encodable {
    let count:      Int
    let lastAt:     Date?
    let lastReason: String?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encodeIfPresent(lastAt,     forKey: .lastAt)
        try c.encodeIfPresent(lastReason, forKey: .lastReason)
    }
    enum CodingKeys: String, CodingKey { case count, lastAt, lastReason }
}

private struct SummarySleepInfo: Encodable {
    let count:        Int
    let lastAt:       Date?
    let lastVoltageV: Double?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encodeIfPresent(lastAt,       forKey: .lastAt)
        try c.encodeIfPresent(lastVoltageV, forKey: .lastVoltageV)
    }
    enum CodingKeys: String, CodingKey { case count, lastAt, lastVoltageV }
}

private struct SummaryWakeUpInfo: Encodable {
    let count:           Int
    let lastAt:          Date?
    let lastSource:      String?
    let lastVoltageV:    Double?
    let sourceBreakdown: [String: Int]

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(count, forKey: .count)
        try c.encodeIfPresent(lastAt,       forKey: .lastAt)
        try c.encodeIfPresent(lastSource,   forKey: .lastSource)
        try c.encodeIfPresent(lastVoltageV, forKey: .lastVoltageV)
        try c.encode(sourceBreakdown,       forKey: .sourceBreakdown)
    }
    enum CodingKeys: String, CodingKey { case count, lastAt, lastSource, lastVoltageV, sourceBreakdown }
}

private struct LifecycleSummaryResponse: Encodable {
    let imei:        String
    let vehicleID:   String
    let vehicleName: String
    let boot:        SummaryBootInfo
    let sleep:       SummarySleepInfo
    let wakeUp:      SummaryWakeUpInfo
}

// MARK: - Helper row types for raw SQL aggregates

private struct LifecycleCountRow: Decodable {
    let count: Int
}
private struct LifecycleLastRow: Decodable {
    let timestamp:        Date?
    let reset_reason:     String?
    let wakeup_source:    String?
    let battery_voltage_v: Double?
}
private struct SourceCountRow: Decodable {
    let wakeup_source: String?
    let cnt:           Int
}

// MARK: - Route Collection

struct DeviceLifecycleController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let open = routes.grouped("api", "device-lifecycle")
        open.get(use: list)                        // GET /api/device-lifecycle
        open.get("summary", use: summary)          // GET /api/device-lifecycle/summary
        open.delete(use: deletePeriod)             // DELETE /api/device-lifecycle?imei=&from=ISO8601&to=ISO8601
        open.delete(":id", use: deleteOne)         // DELETE /api/device-lifecycle/:id
    }

    // MARK: DELETE /api/device-lifecycle?imei=&from=ISO8601&to=ISO8601
    func deletePeriod(req: Request) async throws -> Response {
        guard let imei = try? req.query.get(String.self, at: "imei"), !imei.isEmpty
        else { throw Abort(.badRequest, reason: "imei is required") }
        guard let fromStr = try? req.query.get(String.self, at: "from"),
              let toStr   = try? req.query.get(String.self, at: "to")
        else { throw Abort(.badRequest, reason: "from and to are required") }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()
        func parse(_ s: String) -> Date? {
            iso.date(from: s) ?? isoBasic.date(from: s) ?? Double(s).map { Date(timeIntervalSince1970: $0) }
        }
        guard let from = parse(fromStr), let to = parse(toStr)
        else { throw Abort(.badRequest, reason: "Invalid date format") }

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }

        struct CountRow: Decodable { var n: Int }
        let rows = try await sql.raw("""
            SELECT COUNT(*) AS n FROM device_lifecycle_events
            WHERE imei = \(bind: imei)
              AND CAST(timestamp AS REAL) >= \(bind: from.timeIntervalSince1970)
              AND CAST(timestamp AS REAL) <= \(bind: to.timeIntervalSince1970)
            """).all(decoding: CountRow.self)
        let count = rows.first?.n ?? 0

        try await sql.raw("""
            DELETE FROM device_lifecycle_events
            WHERE imei = \(bind: imei)
              AND CAST(timestamp AS REAL) >= \(bind: from.timeIntervalSince1970)
              AND CAST(timestamp AS REAL) <= \(bind: to.timeIntervalSince1970)
            """).run()

        req.logger.notice("Deleted \(count) device_lifecycle_events for IMEI \(imei) from \(fromStr) to \(toStr)")
        struct Deleted: Content { var deleted: Int }
        return try await Deleted(deleted: count).encodeResponse(status: .ok, for: req)
    }

    // MARK: DELETE /api/device-lifecycle/:id
    func deleteOne(req: Request) async throws -> HTTPStatus {
        guard let idStr = req.parameters.get("id"),
              let uuid = UUID(uuidString: idStr) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }
        guard let event = try await DeviceLifecycleEvent.find(uuid, on: req.db) else {
            throw Abort(.notFound)
        }
        try await event.delete(on: req.db)
        return .noContent
    }

    // ── GET /api/device-lifecycle ──────────────────────────────────────────
    func list(req: Request) async throws -> Response {
        let imeiParam:      String? = req.query[String.self, at: "imei"]
        let vehicleParam:   String? = req.query[String.self, at: "vehicle"]
        let eventTypeParam: String? = req.query[String.self, at: "event_type"]
        let sinceParam:     String? = req.query[String.self, at: "since"]
        let limit:          Int     = req.query[Int.self, at: "limit"] ?? 200

        var query = DeviceLifecycleEvent.query(on: req.db)
        if let v = imeiParam      { query = query.filter(\.$imei      == v) }
        if let v = vehicleParam   { query = query.filter(\.$vehicleID == v) }
        if let v = eventTypeParam { query = query.filter(\.$eventType == v) }
        if let s = sinceParam {
            let fmt = ISO8601DateFormatter()
            fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fmt2 = ISO8601DateFormatter()  // without fractional seconds
            if let date = fmt.date(from: s) ?? fmt2.date(from: s) {
                query = query.filter(\.$timestamp >= date)
            }
        }

        let events = try await query
            .sort(\.$timestamp, .descending)
            .limit(limit)
            .all()

        let dtos = events.map { $0.toResponse() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(dtos)
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "application/json")]),
            body: .init(data: data)
        )
    }

    // ── GET /api/device-lifecycle/summary ─────────────────────────────────
    func summary(req: Request) async throws -> Response {
        let imei: String = req.query[String.self, at: "imei"] ?? ""

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL database unavailable")
        }

        // ── Resolve vehicleID / vehicleName ─────────────────────────────
        let knownReading = try await SensorReading.query(on: req.db)
            .filter(\.$sensorID == imei)
            .filter(\.$brand    == "tracker")
            .sort(\.$timestamp, .descending)
            .first()
        let vehicleID   = knownReading?.vehicleID   ?? imei
        let vehicleName = knownReading?.vehicleName ?? "Tracker \(imei)"

        // ── Boot ────────────────────────────────────────────────────────
        let bootCount: Int = try await {
            let rows = try await sql.raw("""
                SELECT COUNT(*) as count FROM device_lifecycle_events
                WHERE event_type = 'boot' AND imei = \(bind: imei)
            """).all(decoding: LifecycleCountRow.self)
            return rows.first?.count ?? 0
        }()

        let bootLast: LifecycleLastRow? = try await {
            guard bootCount > 0 else { return nil }
            return try await sql.raw("""
                SELECT timestamp, reset_reason, NULL as wakeup_source, NULL as battery_voltage_v
                FROM device_lifecycle_events
                WHERE event_type = 'boot' AND imei = \(bind: imei)
                ORDER BY timestamp DESC LIMIT 1
            """).all(decoding: LifecycleLastRow.self).first
        }()

        // ── Sleep ───────────────────────────────────────────────────────
        let sleepCount: Int = try await {
            let rows = try await sql.raw("""
                SELECT COUNT(*) as count FROM device_lifecycle_events
                WHERE event_type = 'sleep' AND imei = \(bind: imei)
            """).all(decoding: LifecycleCountRow.self)
            return rows.first?.count ?? 0
        }()

        let sleepLast: LifecycleLastRow? = try await {
            guard sleepCount > 0 else { return nil }
            return try await sql.raw("""
                SELECT timestamp, NULL as reset_reason, NULL as wakeup_source, battery_voltage_v
                FROM device_lifecycle_events
                WHERE event_type = 'sleep' AND imei = \(bind: imei)
                ORDER BY timestamp DESC LIMIT 1
            """).all(decoding: LifecycleLastRow.self).first
        }()

        // ── Wake up ─────────────────────────────────────────────────────
        let wakeCount: Int = try await {
            let rows = try await sql.raw("""
                SELECT COUNT(*) as count FROM device_lifecycle_events
                WHERE event_type = 'wake_up' AND imei = \(bind: imei)
            """).all(decoding: LifecycleCountRow.self)
            return rows.first?.count ?? 0
        }()

        let wakeLast: LifecycleLastRow? = try await {
            guard wakeCount > 0 else { return nil }
            return try await sql.raw("""
                SELECT timestamp, NULL as reset_reason, wakeup_source, battery_voltage_v
                FROM device_lifecycle_events
                WHERE event_type = 'wake_up' AND imei = \(bind: imei)
                ORDER BY timestamp DESC LIMIT 1
            """).all(decoding: LifecycleLastRow.self).first
        }()

        // ── Wake-up source breakdown ────────────────────────────────────
        let knownSources = ["VOLTAGE_RISE", "CAN_ACTIVITY", "TIMER_BACKUP", "ESPNOW_HMI"]
        var sourceBreakdown: [String: Int] = knownSources.reduce(into: [:]) { $0[$1] = 0 }

        if wakeCount > 0 {
            let rows = try await sql.raw("""
                SELECT wakeup_source, COUNT(*) as cnt
                FROM device_lifecycle_events
                WHERE event_type = 'wake_up' AND imei = \(bind: imei)
                GROUP BY wakeup_source
            """).all(decoding: SourceCountRow.self)
            for row in rows {
                let key = row.wakeup_source ?? "UNKNOWN"
                sourceBreakdown[key] = (sourceBreakdown[key] ?? 0) + row.cnt
            }
        }

        // ── Assemble response ───────────────────────────────────────────
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601

        let bootInfo = SummaryBootInfo(
            count:      bootCount,
            lastAt:     bootLast?.timestamp,
            lastReason: bootLast?.reset_reason
        )
        let sleepInfo = SummarySleepInfo(
            count:        sleepCount,
            lastAt:       sleepLast?.timestamp,
            lastVoltageV: sleepLast?.battery_voltage_v
        )
        let wakeInfo = SummaryWakeUpInfo(
            count:           wakeCount,
            lastAt:          wakeLast?.timestamp,
            lastSource:      wakeLast?.wakeup_source,
            lastVoltageV:    wakeLast?.battery_voltage_v,
            sourceBreakdown: sourceBreakdown
        )

        let response = LifecycleSummaryResponse(
            imei:        imei,
            vehicleID:   vehicleID,
            vehicleName: vehicleName,
            boot:        bootInfo,
            sleep:       sleepInfo,
            wakeUp:      wakeInfo
        )

        let data = try enc.encode(response)
        return Response(
            status: .ok,
            headers: HTTPHeaders([("Content-Type", "application/json")]),
            body: .init(data: data)
        )
    }
}
