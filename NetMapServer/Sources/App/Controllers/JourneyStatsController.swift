import Vapor
import Fluent
import SQLKit

// MARK: - Model

final class DeviceJourneyStats: Model, Content, @unchecked Sendable {
    static let schema = "journey_stats_events"

    @ID(key: .id)                              var id:                UUID?
    @Field(key: "imei")                        var imei:              String
    @Field(key: "vehicle_id")                  var vehicleID:         String
    @Field(key: "vehicle_name")                var vehicleName:       String
    @Field(key: "journey_id")                  var journeyID:         String
    @Field(key: "timestamp")                   var timestamp:         Date

    // journey scope
    @Field(key: "j_db_events_sent")            var jDbEventsSent:     Int
    @Field(key: "j_ff_events_sent")            var jFfEventsSent:     Int
    @Field(key: "j_post_failures")             var jPostFailures:     Int

    // boot scope
    @Field(key: "b_db_events_sent")            var bDbEventsSent:     Int
    @Field(key: "b_ff_events_sent")            var bFfEventsSent:     Int
    @Field(key: "b_post_failures")             var bPostFailures:     Int

    // lifetime scope
    @Field(key: "lt_db_events_sent")           var ltDbEventsSent:    Int
    @Field(key: "lt_ff_events_sent")           var ltFfEventsSent:    Int
    @Field(key: "lt_post_failures")            var ltPostFailures:    Int
    @Field(key: "lt_reboots_total")            var ltRebootsTotal:    Int
    @Field(key: "lt_reboots_exception")        var ltRebootsException: Int
    @Field(key: "lt_reboots_brownout")         var ltRebootsBrownout: Int

    @Field(key: "received_at")                 var receivedAt:        Date

    init() {}

    init(imei: String, vehicleID: String, vehicleName: String,
         journeyID: String, timestamp: Date,
         journey: JourneyStatsCounters, boot: JourneyStatsCounters, lifetime: JourneyStatsLifetime) {
        self.imei              = imei
        self.vehicleID         = vehicleID
        self.vehicleName       = vehicleName
        self.journeyID         = journeyID
        self.timestamp         = timestamp
        self.jDbEventsSent     = journey.dbEventsSent
        self.jFfEventsSent     = journey.ffEventsSent
        self.jPostFailures     = journey.postFailures
        self.bDbEventsSent     = boot.dbEventsSent
        self.bFfEventsSent     = boot.ffEventsSent
        self.bPostFailures     = boot.postFailures
        self.ltDbEventsSent    = lifetime.dbEventsSent
        self.ltFfEventsSent    = lifetime.ffEventsSent
        self.ltPostFailures    = lifetime.postFailures
        self.ltRebootsTotal    = lifetime.rebootsTotal
        self.ltRebootsException = lifetime.rebootsException
        self.ltRebootsBrownout = lifetime.rebootsBrownout
        self.receivedAt        = Date()
    }
}

// MARK: - Migration

struct CreateDeviceJourneyStats: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(DeviceJourneyStats.schema)
            .id()
            .field("imei",                .string,   .required)
            .field("vehicle_id",          .string,   .required)
            .field("vehicle_name",        .string,   .required)
            .field("journey_id",          .string,   .required)
            .field("timestamp",           .datetime, .required)
            .field("j_db_events_sent",    .int,      .required)
            .field("j_ff_events_sent",    .int,      .required)
            .field("j_post_failures",     .int,      .required)
            .field("b_db_events_sent",    .int,      .required)
            .field("b_ff_events_sent",    .int,      .required)
            .field("b_post_failures",     .int,      .required)
            .field("lt_db_events_sent",   .int,      .required)
            .field("lt_ff_events_sent",   .int,      .required)
            .field("lt_post_failures",    .int,      .required)
            .field("lt_reboots_total",    .int,      .required)
            .field("lt_reboots_exception",.int,      .required)
            .field("lt_reboots_brownout", .int,      .required)
            .field("received_at",         .datetime, .required)
            .create()

        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_jse_imei_ts ON journey_stats_events (imei, timestamp DESC)").run()
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_jse_vehicle  ON journey_stats_events (vehicle_id)").run()
    }

    func revert(on db: Database) async throws {
        try await db.schema(DeviceJourneyStats.schema).delete()
    }
}

// MARK: - Response DTO

private struct JourneyStatsResponse: Encodable {
    let id:               String
    let imei:             String
    let vehicleID:        String
    let vehicleName:      String
    let journeyID:        String
    let timestamp:        Date
    let journey:          CountersResponse
    let boot:             CountersResponse
    let lifetime:         LifetimeResponse
    let receivedAt:       Date

    struct CountersResponse: Encodable {
        let dbEventsSent: Int
        let ffEventsSent: Int
        let postFailures: Int
    }
    struct LifetimeResponse: Encodable {
        let dbEventsSent:     Int
        let ffEventsSent:     Int
        let postFailures:     Int
        let rebootsTotal:     Int
        let rebootsException: Int
        let rebootsBrownout:  Int
    }
}

private extension DeviceJourneyStats {
    func toResponse() -> JourneyStatsResponse {
        JourneyStatsResponse(
            id:          id?.uuidString ?? "",
            imei:        imei,
            vehicleID:   vehicleID,
            vehicleName: vehicleName,
            journeyID:   journeyID,
            timestamp:   timestamp,
            journey:     .init(dbEventsSent: jDbEventsSent, ffEventsSent: jFfEventsSent, postFailures: jPostFailures),
            boot:        .init(dbEventsSent: bDbEventsSent, ffEventsSent: bFfEventsSent, postFailures: bPostFailures),
            lifetime:    .init(
                dbEventsSent:     ltDbEventsSent,
                ffEventsSent:     ltFfEventsSent,
                postFailures:     ltPostFailures,
                rebootsTotal:     ltRebootsTotal,
                rebootsException: ltRebootsException,
                rebootsBrownout:  ltRebootsBrownout
            ),
            receivedAt:  receivedAt
        )
    }
}

// MARK: - Controller

struct JourneyStatsController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let protected = routes
            .grouped("api", "vehicle-events", "journey-stats")
            .grouped(APIKeyOrBearerMiddleware())

        // GET /api/vehicle-events/journey-stats
        //   ?imei=<X>          — filter by device (optional)
        //   ?from=<ISO8601>    — lower bound (optional)
        //   ?to=<ISO8601>      — upper bound (optional)
        //   ?limit=<N>         — max rows returned (default 50, max 500)
        protected.get(use: list)

        // GET /api/vehicle-events/journey-stats/latest
        //   Returns the most recent entry per IMEI — fleet health overview.
        protected.get("latest", use: latest)
    }

    // MARK: - GET /api/vehicle-events/journey-stats

    func list(req: Request) async throws -> Response {
        let imei:  String? = req.query["imei"]
        let from:  Date?   = req.query["from"].flatMap { parseISO8601($0) }
        let to:    Date?   = req.query["to"].flatMap   { parseISO8601($0) }
        let limit: Int     = min(req.query["limit"].flatMap { Int($0) } ?? 50, 500)

        var query = DeviceJourneyStats.query(on: req.db)
            .sort(\.$timestamp, .descending)
            .limit(limit)

        if let imei { query = query.filter(\.$imei == imei) }
        if let from { query = query.filter(\.$timestamp >= from) }
        if let to   { query = query.filter(\.$timestamp <= to)   }

        let rows = try await query.all()
        let enc  = makeEncoder()
        let body = try enc.encode(rows.map { $0.toResponse() })
        return Response(status: .ok,
                        headers: ["Content-Type": "application/json"],
                        body: .init(data: body))
    }

    // MARK: - GET /api/vehicle-events/journey-stats/latest

    func latest(req: Request) async throws -> Response {
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL backend required")
        }

        // One row per IMEI: the most recent entry (SQLite-compatible subquery).
        let idRows = try await sql.raw("""
            SELECT id FROM journey_stats_events AS j1
            WHERE j1.timestamp = (
                SELECT MAX(j2.timestamp) FROM journey_stats_events j2
                WHERE j2.imei = j1.imei
            )
            """).all(decoding: UUIDRow.self)

        guard !idRows.isEmpty else {
            return Response(status: .ok,
                            headers: ["Content-Type": "application/json"],
                            body: .init(string: "[]"))
        }

        let rows = try await DeviceJourneyStats.query(on: req.db)
            .filter(\.$id ~~ idRows.map(\.id))
            .all()

        let enc  = makeEncoder()
        let body = try enc.encode(rows.map { $0.toResponse() })
        return Response(status: .ok,
                        headers: ["Content-Type": "application/json"],
                        body: .init(data: body))
    }

    // MARK: - Helpers

    private func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return enc
    }

    private func parseISO8601(_ s: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        return fmt.date(from: s)
    }
}

private struct UUIDRow: Decodable {
    let id: UUID
}
