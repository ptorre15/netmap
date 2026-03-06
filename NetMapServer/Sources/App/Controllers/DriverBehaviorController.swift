import Vapor
import Fluent
import SQLKit

// MARK: - Alert type mapping

private let behaviorTypeMap: [Int: String] = [
    1: "revving",
    2: "braking",
    3: "acceleration",
    4: "cornering",
    5: "idling",
    6: "overspeed",
]

func behaviorTypeName(_ raw: Int) -> String {
    behaviorTypeMap[raw] ?? "unknown"
}

// MARK: - Model

final class DriverBehaviorEvent: Model, Content {
    static let schema = "driver_behavior_events"

    @ID(key: .id)                              var id:              UUID?
    @Field(key: "imei")                        var imei:            String
    @Field(key: "journey_id")                  var journeyID:       String
    @Field(key: "vehicle_id")                  var vehicleID:       String
    @Field(key: "vehicle_name")                var vehicleName:     String
    @Field(key: "alert_type_int")              var alertTypeInt:    Int
    @Field(key: "alert_type")                  var alertType:       String
    @Field(key: "alert_value_max")             var alertValueMax:   Double
    @Field(key: "alert_duration_ms")           var alertDurationMs: Int
    @Field(key: "timestamp")                   var timestamp:       Date
    @OptionalField(key: "latitude")            var latitude:        Double?
    @OptionalField(key: "longitude")           var longitude:       Double?
    @OptionalField(key: "heading_deg")         var headingDeg:      Double?
    @OptionalField(key: "speed_kmh")           var speedKmh:        Double?
    @Field(key: "received_at")                 var receivedAt:      Date

    init() {}

    init(imei: String, journeyID: String, vehicleID: String, vehicleName: String,
         alertTypeInt: Int, alertValueMax: Double, alertDurationMs: Int,
         timestamp: Date, latitude: Double?, longitude: Double?,
         headingDeg: Double?, speedKmh: Double?) {
        self.imei            = imei
        self.journeyID       = journeyID
        self.vehicleID       = vehicleID
        self.vehicleName     = vehicleName
        self.alertTypeInt    = alertTypeInt
        self.alertType       = behaviorTypeName(alertTypeInt)
        self.alertValueMax   = alertValueMax
        self.alertDurationMs = alertDurationMs
        self.timestamp       = timestamp
        self.latitude        = latitude
        self.longitude       = longitude
        self.headingDeg      = headingDeg
        self.speedKmh        = speedKmh
        self.receivedAt      = Date()
    }
}

// MARK: - Migration

struct CreateDriverBehaviorEvent: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(DriverBehaviorEvent.schema)
            .id()
            .field("imei",             .string,   .required)
            .field("journey_id",       .string,   .required)
            .field("vehicle_id",       .string,   .required)
            .field("vehicle_name",     .string,   .required)
            .field("alert_type_int",   .int,      .required)
            .field("alert_type",       .string,   .required)
            .field("alert_value_max",  .double,   .required)
            .field("alert_duration_ms",.int,      .required)
            .field("timestamp",        .datetime, .required)
            .field("latitude",         .double)
            .field("longitude",        .double)
            .field("heading_deg",      .double)
            .field("speed_kmh",        .double)
            .field("received_at",      .datetime, .required)
            .create()

        // Indexes for common query patterns
        if let sql = db as? SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_dbe_journey  ON driver_behavior_events (journey_id)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_dbe_vehicle  ON driver_behavior_events (vehicle_id)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_dbe_imei     ON driver_behavior_events (imei)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_dbe_ts       ON driver_behavior_events (timestamp)").run()
        }
    }

    func revert(on db: Database) async throws {
        try await db.schema(DriverBehaviorEvent.schema).delete()
    }
}

// MARK: - Response DTOs

struct DriverBehaviorEventResponse: Content {
    var id:              String
    var journeyID:       String
    var vehicleID:       String
    var vehicleName:     String
    var alertType:       String
    var alertTypeInt:    Int
    var alertValueMax:   Double
    var alertDurationMs: Int
    var timestamp:       Date
    var latitude:        Double?
    var longitude:       Double?
    var headingDeg:      Double?
    var speedKmh:        Double?
}

struct BehaviorTypeStat: Content {
    var count:           Int
    var maxValue:        Double?
    var totalDurationMs: Int?
}

struct DriverBehaviorSummary: Content {
    var journeyID:   String
    var vehicleID:   String
    var vehicleName: String
    var totalAlerts: Int
    var byType:      [String: BehaviorTypeStat]
}

// MARK: - Controller

struct DriverBehaviorController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let base = routes.grouped("api", "driver-behavior")
        base.get(use: list)                        // GET /api/driver-behavior?journey=&vehicle=&imei=&alert_type=&limit=
        base.get("summary", use: summary)          // GET /api/driver-behavior/summary?journey=
        base.delete(use: deletePeriod)             // DELETE /api/driver-behavior?imei=&from=ISO8601&to=ISO8601
        base.delete(":id", use: deleteOne)         // DELETE /api/driver-behavior/:id
    }

    // MARK: DELETE /api/driver-behavior?imei=&from=ISO8601&to=ISO8601
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
            SELECT COUNT(*) AS n FROM driver_behavior_events
            WHERE imei = \(bind: imei)
              AND CAST(timestamp AS REAL) >= \(bind: from.timeIntervalSince1970)
              AND CAST(timestamp AS REAL) <= \(bind: to.timeIntervalSince1970)
            """).all(decoding: CountRow.self)
        let count = rows.first?.n ?? 0

        try await sql.raw("""
            DELETE FROM driver_behavior_events
            WHERE imei = \(bind: imei)
              AND CAST(timestamp AS REAL) >= \(bind: from.timeIntervalSince1970)
              AND CAST(timestamp AS REAL) <= \(bind: to.timeIntervalSince1970)
            """).run()

        req.logger.notice("Deleted \(count) driver_behavior_events for IMEI \(imei) from \(fromStr) to \(toStr)")
        struct Deleted: Content { var deleted: Int }
        return try await Deleted(deleted: count).encodeResponse(status: .ok, for: req)
    }

    // MARK: DELETE /api/driver-behavior/:id
    func deleteOne(req: Request) async throws -> HTTPStatus {
        guard let idStr = req.parameters.get("id"),
              let uuid = UUID(uuidString: idStr) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }
        guard let event = try await DriverBehaviorEvent.find(uuid, on: req.db) else {
            throw Abort(.notFound)
        }
        try await event.delete(on: req.db)
        return .noContent
    }

    // MARK: GET /api/driver-behavior
    func list(req: Request) async throws -> [DriverBehaviorEventResponse] {
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 500
        var q = DriverBehaviorEvent.query(on: req.db).sort(\.$timestamp, .ascending)
        if let j = try? req.query.get(String.self, at: "journey")    { q = q.filter(\.$journeyID == j) }
        if let v = try? req.query.get(String.self, at: "vehicle")    { q = q.filter(\.$vehicleID == v) }
        if let i = try? req.query.get(String.self, at: "imei")       { q = q.filter(\.$imei == i) }
        if let a = try? req.query.get(String.self, at: "alert_type") { q = q.filter(\.$alertType == a) }
        let rows = try await q.limit(limit).all()
        return rows.map { r in
            DriverBehaviorEventResponse(
                id:              r.id?.uuidString ?? "",
                journeyID:       r.journeyID,
                vehicleID:       r.vehicleID,
                vehicleName:     r.vehicleName,
                alertType:       r.alertType,
                alertTypeInt:    r.alertTypeInt,
                alertValueMax:   r.alertValueMax,
                alertDurationMs: r.alertDurationMs,
                timestamp:       r.timestamp,
                latitude:        r.latitude,
                longitude:       r.longitude,
                headingDeg:      r.headingDeg,
                speedKmh:        r.speedKmh
            )
        }
    }

    // MARK: GET /api/driver-behavior/summary
    func summary(req: Request) async throws -> DriverBehaviorSummary {
        let journeyID = (try? req.query.get(String.self, at: "journey")) ?? ""
        var q = DriverBehaviorEvent.query(on: req.db)
        if !journeyID.isEmpty { q = q.filter(\.$journeyID == journeyID) }
        if let v = try? req.query.get(String.self, at: "vehicle") { q = q.filter(\.$vehicleID == v) }
        let rows = try await q.all()

        var vehicleID   = rows.first?.vehicleID   ?? ""
        var vehicleName = rows.first?.vehicleName ?? ""
        var byType: [String: (count: Int, maxVal: Double, totalMs: Int)] = [:]

        for r in rows {
            vehicleID   = r.vehicleID
            vehicleName = r.vehicleName
            var s = byType[r.alertType] ?? (0, 0, 0)
            s.count  += 1
            s.maxVal  = max(s.maxVal, r.alertValueMax)
            s.totalMs += r.alertDurationMs
            byType[r.alertType] = s
        }

        let byTypeContent = byType.mapValues { s in
            BehaviorTypeStat(count: s.count, maxValue: s.maxVal, totalDurationMs: s.totalMs)
        }

        return DriverBehaviorSummary(
            journeyID:   journeyID,
            vehicleID:   vehicleID,
            vehicleName: vehicleName,
            totalAlerts: rows.count,
            byType:      byTypeContent
        )
    }
}
