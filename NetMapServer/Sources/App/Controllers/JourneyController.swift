import Vapor
import Fluent
import SQLKit

/// Returns `candidate` if it looks like a plausible device-generated timestamp (after 2020),
/// otherwise falls back to `Date()` (server reception time).
private let minValidDate = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01T00:00:00Z
private func validTimestamp(_ candidate: Date?) -> Date {
    guard let ts = candidate, ts >= minValidDate else { return Date() }
    return ts
}

struct VehicleEventController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let protected       = routes.grouped("api", "vehicle-events").grouped(APIKeyMiddleware())
        let protectedDelete = routes.grouped("api", "vehicle-events").grouped(APIKeyOrAdminMiddleware())
        let open            = routes.grouped("api", "vehicle-events")

        // Writes (require API key — tracker devices)
        protected.post(use: push)           // POST /api/vehicle-events  — single or array

        // Reads (public)
        open.get(use: list)                 // GET  /api/vehicle-events?vehicle=&journey=&limit=
        open.get("journeys", use: journeys) // GET  /api/vehicle-events/journeys?vehicle=&limit=

        // Deletes — accept API key OR admin Bearer (web dashboard)
        protectedDelete.delete(":id", use: deleteOne)             // DELETE /api/vehicle-events/:id
        protectedDelete.delete("journeys", ":journeyID", use: deleteJourney)
        protectedDelete.delete(use: deletePeriod)  // DELETE /api/vehicle-events?imei=&from=ISO8601&to=ISO8601
    }

    // MARK: - POST /api/vehicle-events
    // N'accepte que l'IMEI + données télémétriques.
    // Le serveur résout vehicleID/vehicleName depuis sensor_readings et gère le journeyID.
    func push(req: Request) async throws -> HTTPStatus {
        let payloads: [VehicleEventPayload]
        if let arr = try? req.content.decode([VehicleEventPayload].self) {
            payloads = arr
        } else {
            payloads = [try req.content.decode(VehicleEventPayload.self)]
        }
        guard !payloads.isEmpty else { throw Abort(.badRequest, reason: "Empty payload") }

        for p in payloads {
            let imei      = p.imei
            let eventType = p.eventType ?? "driving"

            req.logger.info("🛰 [tracker] imei=\(imei) type=\(eventType) ts=\(p.timestamp.map { String(format:"%.0f",$0.timeIntervalSince1970) } ?? "nil") lat=\(p.latitude.map{String($0)} ?? "nil") lon=\(p.longitude.map{String($0)} ?? "nil") spd=\(p.speedKmh.map{String($0)} ?? "nil") temp=\(p.engineTempC.map{String($0)} ?? "nil") fuel=\(p.fuelLevelPct.map{String($0)} ?? "nil")")

            // ── 1. Résolution du véhicule depuis l'IMEI ──────────────────────────
            let knownReading = try await SensorReading.query(on: req.db)
                .filter(\.$sensorID == imei)
                .filter(\.$brand    == "tracker")
                .sort(\.$timestamp, .descending)
                .first()

            let vehicleID   = knownReading?.vehicleID   ?? imei
            // sensorName takes priority as the display name if the user has set one
            let vehicleName: String = {
                if let n = knownReading?.sensorName, !n.trimmingCharacters(in: .whitespaces).isEmpty {
                    return n
                }
                return knownReading?.vehicleName ?? "Tracker \(imei)"
            }()

            // ── 2. Driver behavior: validate, store in separate table, skip journey logic ──
            if eventType == "driver_behavior" {
                guard let rawType = p.driverBehaviorType else {
                    throw Abort(.badRequest, reason: "driverBehaviorType required (integer)")
                }
                guard let alertValue = p.alertValueMax else {
                    throw Abort(.badRequest, reason: "alertValueMax required")
                }
                guard let alertMs = p.alertDurationMs, alertMs >= 0 else {
                    throw Abort(.badRequest, reason: "alertDurationMs required and must not be negative")
                }
                // Resolve journeyID — use the most recent open journey, "no-journey" if none
                let lastEvent = try await VehicleEvent.query(on: req.db)
                    .filter(\.$imei == imei)
                    .sort(\.$timestamp, .descending)
                    .first()
                let behaviorJourneyID: String
                if let last = lastEvent, last.eventType != "journey_end" {
                    behaviorJourneyID = last.journeyID
                } else {
                    behaviorJourneyID = lastEvent?.journeyID ?? "no-journey"
                }
                let dbe = DriverBehaviorEvent(
                    imei:            imei,
                    journeyID:       behaviorJourneyID,
                    vehicleID:       vehicleID,
                    vehicleName:     vehicleName,
                    alertTypeInt:    rawType,
                    alertValueMax:   alertValue,
                    alertDurationMs: alertMs,
                    timestamp:       validTimestamp(p.timestamp),
                    latitude:        p.latitude,
                    longitude:       p.longitude,
                    headingDeg:      p.headingDeg,
                    speedKmh:        p.speedKmh
                )
                try await dbe.save(on: req.db)
                req.logger.info("🧠 [behavior] imei=\(imei) type=\(dbe.alertType) value=\(alertValue) ms=\(alertMs)")
                continue   // do NOT feed into journey state machine or vehicle_events
            }

            // ── 3. Device lifecycle events: store in separate table, skip journey logic ──
            if eventType == "boot" || eventType == "sleep" || eventType == "wake_up" {
                // batteryVoltageV < 0 → treat as unavailable
                let rawVoltage = p.batteryVoltageV
                let safeVoltage: Double? = (rawVoltage != nil && rawVoltage! >= 0) ? rawVoltage : nil

                // Reclassify: boot with resetReason "DEEPSLEEP" is a wake from deep sleep,
                // not a true power-on/reboot — store as wake_up instead.
                let effectiveType: String
                if eventType == "boot" && p.resetReason == "DEEPSLEEP" {
                    effectiveType = "wake_up"
                } else {
                    effectiveType = eventType
                }

                let dle = DeviceLifecycleEvent(
                    imei:            imei,
                    vehicleID:       vehicleID,
                    vehicleName:     vehicleName,
                    eventType:       effectiveType,
                    timestamp:       validTimestamp(p.timestamp),
                    resetReason:     effectiveType == "boot"    ? p.resetReason  : nil,
                    wakeupSource:    effectiveType == "wake_up" ? p.wakeupSource : nil,
                    batteryVoltageV: (effectiveType == "sleep" || effectiveType == "wake_up") ? safeVoltage : nil,
                    gpsFixType:      p.gpsFixType,
                    latitude:        p.latitude,
                    longitude:       p.longitude,
                    headingDeg:      p.headingDeg,
                    speedKmh:        p.speedKmh,
                    gpsSatellites:   p.gpsSatellites
                )
                try await dle.save(on: req.db)
                req.logger.info("⚡️ [lifecycle] imei=\(imei) type=\(effectiveType)\(effectiveType != eventType ? " (reclassified from \(eventType)/DEEPSLEEP)" : "")")
                continue   // do NOT affect journey state machine or vehicle_events
            }

            // ── 4. Résolution / création du journeyID ────────────────────────────
            let journeyID: String
            if eventType == "journey_start" {
                journeyID = UUID().uuidString
            } else {
                let lastEvent = try await VehicleEvent.query(on: req.db)
                    .filter(\.$imei == imei)
                    .sort(\.$timestamp, .descending)
                    .first()
                journeyID = lastEvent?.journeyID ?? UUID().uuidString
            }

            // ── 5. Déduplication (imei, timestamp, eventType) per firmware spec ────
            let evTs = validTimestamp(p.timestamp)
            let isDuplicate = try await VehicleEvent.query(on: req.db)
                .filter(\.$imei      == imei)
                .filter(\.$eventType == eventType)
                .filter(\.$timestamp == evTs)
                .first() != nil
            if isDuplicate {
                req.logger.info("⚠️ [dedup] skipped duplicate imei=\(imei) type=\(eventType) ts=\(evTs)")
                continue
            }

            // ── 6. Sauvegarde de l'événement ─────────────────────────────────────
            let event = VehicleEvent(
                imei:        imei,
                journeyID:   journeyID,
                vehicleID:   vehicleID,
                vehicleName: vehicleName,
                eventType:   eventType,
                from:        p
            )
            try await event.save(on: req.db)

            // ── 7. Upsert SensorReading pour que le tracker apparaisse dans sensorsLatest ──
            let sp = SensorPayload(
                sensorID:          imei,
                vehicleID:         vehicleID,
                vehicleName:       vehicleName,
                assetTypeID:       "vehicle",
                brand:             "tracker",
                wheelPosition:     nil,
                pressureBar:       nil,
                temperatureC:      p.engineTempC,
                vbattVolts:        nil,
                targetPressureBar: nil,
                batteryPct:        nil,
                chargeState:       nil,
                sensorName:        nil,
                healthPct:         nil,
                chargingCycles:    nil,
                productVariant:    nil,
                totalSeconds:      nil,
                latitude:          p.latitude,
                longitude:         p.longitude,
                timestamp:         validTimestamp(p.timestamp)
            )
            try await SensorReading(from: sp).save(on: req.db)
        }

        req.logger.info("vehicle-events saved: \(payloads.count)")
        return .created
    }

    // MARK: - GET /api/vehicle-events?imei=&vehicle=UUID&journey=UUID&event_type=driving&limit=1000
    func list(req: Request) async throws -> [VehicleEvent] {
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 1_000
        var q = VehicleEvent.query(on: req.db).sort(\.$timestamp, .ascending)
        if let v = try? req.query.get(String.self, at: "vehicle")    { q = q.filter(\.$vehicleID == v) }
        if let i = try? req.query.get(String.self, at: "imei")       { q = q.filter(\.$imei == i) }
        if let j = try? req.query.get(String.self, at: "journey")    { q = q.filter(\.$journeyID == j) }
        if let e = try? req.query.get(String.self, at: "event_type") { q = q.filter(\.$eventType == e) }
        return try await q.limit(limit).all()
    }

    // MARK: - GET /api/vehicle-events/journeys?vehicle=UUID&limit=50
    // Returns one summary row per journey, derived entirely from the vehicle_events table.
    func journeys(req: Request) async throws -> [JourneySummary] {
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }

        struct Row: Decodable {
            var journey_id:               String
            var vehicle_id:               String
            var vehicle_name:             String
            var driver_id:                String?
            var started_at:               String?
            var ended_at:                 String?
            var total_distance_km:        Double?
            var total_fuel_consumed_l:    Double?
            var total_journey_fuel_consumed_l: Double?
            var event_count:              Int
        }

        var filter = ""
        if let v = try? req.query.get(String.self, at: "vehicle") {
            filter = "WHERE vehicle_id = '\(v)'"
        }
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 50

        let rows = try await sql.raw("""
            SELECT
                journey_id,
                vehicle_id,
                vehicle_name,
                MIN(driver_id) AS driver_id,
                MIN(timestamp) AS started_at,
                CASE WHEN SUM(CASE WHEN event_type = 'journey_end' THEN 1 ELSE 0 END) > 0
                     THEN MAX(timestamp) ELSE NULL END AS ended_at,
                MAX(journey_distance_km) AS total_distance_km,
                SUM(COALESCE(fuel_consumed_l, 0)) AS total_fuel_consumed_l,
                MAX(COALESCE(journey_fuel_consumed_l, 0)) AS total_journey_fuel_consumed_l,
                COUNT(*) AS event_count
            FROM vehicle_events
            \(unsafeRaw: filter)
            GROUP BY journey_id
            ORDER BY MIN(timestamp) DESC
            LIMIT \(unsafeRaw: String(limit))
            """).all(decoding: Row.self)

        let isoFull  = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoBasic = ISO8601DateFormatter()

        func parseDate(_ s: String?) -> Date? {
            guard let s else { return nil }
            return isoFull.date(from: s)
                ?? isoBasic.date(from: s)
                ?? Double(s).map { Date(timeIntervalSince1970: $0) }
        }

        return rows.map { r in
            JourneySummary(
                journeyID:               r.journey_id,
                vehicleID:               r.vehicle_id,
                vehicleName:             r.vehicle_name,
                startedAt:               parseDate(r.started_at),
                endedAt:                 parseDate(r.ended_at),
                driverID:                r.driver_id,
                totalDistanceKm:         r.total_distance_km.map { $0 / 1000.0 },   // tracker sends metres
                totalFuelConsumedL:      r.total_journey_fuel_consumed_l ?? r.total_fuel_consumed_l,
                eventCount:              r.event_count
            )
        }
    }

    // MARK: - DELETE /api/vehicle-events/:id
    func deleteOne(req: Request) async throws -> HTTPStatus {
        guard let idStr = req.parameters.get("id"),
              let uuid = UUID(uuidString: idStr) else {
            throw Abort(.badRequest, reason: "Invalid id")
        }
        guard let event = try await VehicleEvent.find(uuid, on: req.db) else {
            throw Abort(.notFound)
        }
        try await event.delete(on: req.db)
        return .noContent
    }

    // MARK: - DELETE /api/vehicle-events?imei=&from=ISO8601&to=ISO8601
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

        // Count first so we can return the number deleted
        struct CountRow: Decodable { var n: Int }
        let rows = try await sql.raw("""
            SELECT COUNT(*) AS n FROM vehicle_events
            WHERE imei = \(bind: imei)
              AND CAST(timestamp AS REAL) >= \(bind: from.timeIntervalSince1970)
              AND CAST(timestamp AS REAL) <= \(bind: to.timeIntervalSince1970)
            """).all(decoding: CountRow.self)
        let count = rows.first?.n ?? 0

        try await sql.raw("""
            DELETE FROM vehicle_events
            WHERE imei = \(bind: imei)
              AND CAST(timestamp AS REAL) >= \(bind: from.timeIntervalSince1970)
              AND CAST(timestamp AS REAL) <= \(bind: to.timeIntervalSince1970)
            """).run()

        req.logger.notice("Deleted \(count) vehicle_events for IMEI \(imei) from \(fromStr) to \(toStr)")
        struct Deleted: Content { var deleted: Int }
        return try await Deleted(deleted: count).encodeResponse(status: .ok, for: req)
    }

    // MARK: - DELETE /api/vehicle-events/journeys/:journeyID
    func deleteJourney(req: Request) async throws -> HTTPStatus {
        guard let journeyID = req.parameters.get("journeyID") else {
            throw Abort(.badRequest, reason: "Missing journeyID")
        }
        let count = try await VehicleEvent.query(on: req.db)
            .filter(\.$journeyID == journeyID).count()
        guard count > 0 else { throw Abort(.notFound, reason: "Journey not found") }
        try await VehicleEvent.query(on: req.db)
            .filter(\.$journeyID == journeyID).delete()
        return .noContent
    }
}
