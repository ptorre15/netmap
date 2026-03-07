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

/// Normalizes persisted distance values to kilometers for API summaries.
/// Legacy tracker firmware stored meters in km-named fields; modern payloads are true km.
/// Heuristic: values >= 1000 are treated as meters.
func normalizeJourneyDistanceKm(_ raw: Double?) -> Double? {
    guard let raw, raw >= 0 else { return nil }
    return raw >= 1000 ? raw / 1000.0 : raw
}

// MARK: - Piggyback config response structs
struct PiggybackSystemPayload: Content {
    var pingIntervalMin: Int
    var sleepDelayMin: Int
    var wakeUpSourcesEnabled: [String]
}
struct PiggybackThresholdsPayload: Content {
    var harshBraking: Double
    var harshAcceleration: Double
    var harshCornering: Double
    var overspeed: Double
}
struct PiggybackDriverBehaviorPayload: Content {
    var thresholds: PiggybackThresholdsPayload
    var minimumSpeedKmh: Int
    var beepEnabled: Bool
}
struct PiggybackConfigPayload: Content {
    var schemaVersion: Int
    var imei: String
    var system: PiggybackSystemPayload
    var driverBehavior: PiggybackDriverBehaviorPayload
}
struct PushEventsResponse: Content {
    var received: Int
    var config: PiggybackConfigPayload?
}

struct VehicleEventController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let protected       = routes.grouped("api", "vehicle-events").grouped(APIKeyMiddleware())
        let protectedDelete = routes.grouped("api", "vehicle-events").grouped(APIKeyOrAdminMiddleware())
        let protectedRead   = routes.grouped("api", "vehicle-events").grouped(APIKeyOrBearerMiddleware())

        // Writes (require API key — tracker devices)
        protected.post(use: push)           // POST /api/vehicle-events  — single or array

        // Reads (API key or Bearer token)
        protectedRead.get(use: list)                 // GET  /api/vehicle-events?vehicle=&journey=&limit=
        protectedRead.get("journeys", use: journeys) // GET  /api/vehicle-events/journeys?vehicle=&limit=

        // Deletes — accept API key OR admin Bearer (web dashboard)
        protectedDelete.delete(":id", use: deleteOne)             // DELETE /api/vehicle-events/:id
        protectedDelete.delete("journeys", ":journeyID", use: deleteJourney)
        protectedDelete.delete(use: deletePeriod)  // DELETE /api/vehicle-events?imei=&from=ISO8601&to=ISO8601
    }

    // MARK: - POST /api/vehicle-events
    // N'accepte que l'IMEI + données télémétriques.
    // Le serveur résout vehicleID/vehicleName depuis sensor_readings et gère le journeyID.
    func push(req: Request) async throws -> Response {
        struct IngestStats {
            var received: Int = 0
            var savedVehicleEvents: Int = 0
            var savedDriverBehavior: Int = 0
            var savedLifecycle: Int = 0
            var savedSensorRows: Int = 0
            var deduped: Int = 0
            var nonStandardVehicleEventType: Int = 0
        }

        let payloads: [VehicleEventPayload]
        if let arr = try? req.content.decode([VehicleEventPayload].self) {
            payloads = arr
        } else {
            payloads = [try req.content.decode(VehicleEventPayload.self)]
        }
        guard !payloads.isEmpty else { throw Abort(.badRequest, reason: "Empty payload") }
        var stats = IngestStats(received: payloads.count)

        // Debug: log configVersion decoded from first payload
        if let first = payloads.first {
            req.logger.info("[push] imei=\(first.imei) configVersion=\(first.configVersion.map { String($0) } ?? "nil")")
        }

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
                stats.savedDriverBehavior += 1
                req.logger.info("🧠 [behavior] imei=\(imei) type=\(dbe.alertType) value=\(alertValue) ms=\(alertMs)")
                continue   // do NOT feed into journey state machine or vehicle_events
            }

            // ── 3. Device lifecycle events: store in separate table, skip journey logic ──
            if eventType == "boot" || eventType == "sleep" || eventType == "wake_up" || eventType == "ping"
                || eventType == "gps_acquired" || eventType == "gps_lost" {
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
                stats.savedLifecycle += 1
                if effectiveType == "ping" {
                    req.logger.info("📡 [ping] imei=\(imei) fix=\(p.gpsFixType.map{String($0)} ?? "?") lat=\(p.latitude.map{String($0)} ?? "-") lon=\(p.longitude.map{String($0)} ?? "-") sats=\(p.gpsSatellites.map{String($0)} ?? "-")")
                } else {
                    req.logger.info("⚡️ [lifecycle] imei=\(imei) type=\(effectiveType)\(effectiveType != eventType ? " (reclassified from \(eventType)/DEEPSLEEP)" : "")")
                }
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
                stats.deduped += 1
                req.logger.info("⚠️ [dedup] skipped duplicate imei=\(imei) type=\(eventType) ts=\(evTs)")
                continue
            }

            if eventType != "journey_start" && eventType != "driving" && eventType != "journey_end" {
                stats.nonStandardVehicleEventType += 1
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
            stats.savedVehicleEvents += 1

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
            stats.savedSensorRows += 1
        }

        req.logger.notice("[ingest.vehicle-events] received=\(stats.received) saved_vehicle=\(stats.savedVehicleEvents) saved_behavior=\(stats.savedDriverBehavior) saved_lifecycle=\(stats.savedLifecycle) saved_sensor_rows=\(stats.savedSensorRows) deduped=\(stats.deduped) non_standard_vehicle_type=\(stats.nonStandardVehicleEventType)")

        // ── Piggyback: inject pending config into response ───────────────
        // Only include config when the stored schemaVersion is newer than what
        // the tracker already has applied (tracker sends configVersion in payload).
        // nil configVersion means first boot — always send config.
        let imeis = Array(Set(payloads.map { $0.imei }))
        var piggybackConfig: PiggybackConfigPayload? = nil
        for batchImei in imeis {
            // Find the reported configVersion for this IMEI from the batch
            let reportedVersion = payloads.first(where: { $0.imei == batchImei })?.configVersion
            guard let cfg = try? await TrackerConfig.query(on: req.db)
                .filter(\.$imei == batchImei)
                .first() else { continue }

            // Always persist the tracker's reported version (so the UI can show sync status)
            if let v = reportedVersion, cfg.lastAppliedConfigVersion != v {
                cfg.lastAppliedConfigVersion = v
                try? await cfg.save(on: req.db)
            }

            // Gate: only piggyback if tracker hasn't seen this version yet
            guard cfg.schemaVersion > (reportedVersion ?? -1) else { break }
            let wake = (try? JSONDecoder().decode([String].self,
                from: Data(cfg.wakeUpSourcesJSON.utf8))) ?? []
            piggybackConfig = PiggybackConfigPayload(
                schemaVersion: cfg.schemaVersion,
                imei: cfg.imei,
                system: .init(pingIntervalMin: cfg.pingIntervalMin,
                              sleepDelayMin: cfg.sleepDelayMin,
                              wakeUpSourcesEnabled: wake),
                driverBehavior: .init(
                    thresholds: .init(harshBraking: cfg.thresholdHarshBraking,
                                      harshAcceleration: cfg.thresholdHarshAcceleration,
                                      harshCornering: cfg.thresholdHarshCornering,
                                      overspeed: cfg.thresholdOverspeedKmh),
                    minimumSpeedKmh: cfg.minimumSpeedKmh,
                    beepEnabled: cfg.beepEnabled)
            )
            break
        }
        let pushResponse = PushEventsResponse(received: payloads.count, config: piggybackConfig)
        return try await pushResponse.encodeResponse(status: .created, for: req)
    }

    // MARK: - GET /api/vehicle-events?imei=&vehicle=UUID&journey=UUID&event_type=driving&limit=1000
    func list(req: Request) async throws -> [VehicleEvent] {
        let limit = (try? req.query.get(Int.self, at: "limit")) ?? 1_000
        var q = VehicleEvent.query(on: req.db).sort(\.$timestamp, .ascending)
        if let auth = req.authUser, !auth.isAdmin {
            let allowedVehicleIDs = try await UserAsset.query(on: req.db)
                .filter(\.$userID == auth.userID)
                .all()
                .map { $0.assetID.uuidString }
            if allowedVehicleIDs.isEmpty { return [] }
            q = q.filter(\.$vehicleID ~~ allowedVehicleIDs)
        }
        if let v = try? req.query.get(String.self, at: "vehicle")    { q = q.filter(\.$vehicleID == v) }
        if let i = try? req.query.get(String.self, at: "imei")       { q = q.filter(\.$imei == i) }
        if let j = try? req.query.get(String.self, at: "journey")    { q = q.filter(\.$journeyID == j) }
        if let e = try? req.query.get(String.self, at: "event_type") { q = q.filter(\.$eventType == e) }
        // Date-range filter: timestamp column is REAL (Unix seconds). Fluent's SQLite
        // driver encodes Date as a Double (timeIntervalSince1970) so the comparison
        // is REAL vs REAL — correct.
        if let fromStr = try? req.query.get(String.self, at: "from"),
           let fromDate = QueryDateParser.parse(fromStr) {
            q = q.filter(\.$timestamp >= fromDate)
        }
        if let toStr = try? req.query.get(String.self, at: "to"),
           let toDate = QueryDateParser.parse(toStr) {
            q = q.filter(\.$timestamp <= toDate)
        }
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
            var started_at:               Double?
            var ended_at:                 Double?
            var total_distance_km:        Double?
            var total_fuel_consumed_l:    Double?
            var total_journey_fuel_consumed_l: Double?
            var event_count:              Int
        }

        // Clamp limit to a sane range and avoid raw interpolation.
        let rawLimit = (try? req.query.get(Int.self, at: "limit")) ?? 50
        let limit = min(max(rawLimit, 1), 500)
        let vehicleFilter = try? req.query.get(String.self, at: "vehicle")

        // Parse date-range params into Unix epoch Doubles so that HAVING comparisons
        // are REAL vs REAL.  The timestamp column is stored as a REAL (Unix seconds)
        // in SQLite; binding an ISO8601 string would create a TEXT-typed parameter and
        // SQLite's type ordering (REAL < TEXT) would make the comparison always false.
        let fromBound: Double = (try? req.query.get(String.self, at: "from"))
            .flatMap { QueryDateParser.parse($0) }
            .map     { $0.timeIntervalSince1970 } ?? 0.0
        let toBound: Double = (try? req.query.get(String.self, at: "to"))
            .flatMap { QueryDateParser.parse($0) }
            .map     { $0.timeIntervalSince1970 } ?? Double.greatestFiniteMagnitude
        var accessFilterSQL = ""
        if let auth = req.authUser, !auth.isAdmin {
            let allowedVehicleIDs = try await UserAsset.query(on: req.db)
                .filter(\.$userID == auth.userID)
                .all()
                .map { $0.assetID.uuidString.uppercased() }
            if allowedVehicleIDs.isEmpty { return [] }
            if let v = vehicleFilter, !v.isEmpty, !allowedVehicleIDs.contains(v.uppercased()) {
                return []
            }
            let quoted = allowedVehicleIDs.map { "'\($0)'" }.joined(separator: ",")
            accessFilterSQL = "UPPER(vehicle_id) IN (\(quoted))"
        }

        let rows: [Row]
        if let vehicleID = vehicleFilter, !vehicleID.isEmpty {
            if accessFilterSQL.isEmpty {
                rows = try await sql.raw("""
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
                    WHERE vehicle_id = \(bind: vehicleID)
                    GROUP BY journey_id
                    HAVING MIN(timestamp) >= \(bind: fromBound) AND MIN(timestamp) <= \(bind: toBound)
                    ORDER BY MIN(timestamp) DESC
                    LIMIT \(bind: limit)
                    """).all(decoding: Row.self)
            } else {
                rows = try await sql.raw("""
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
                    WHERE vehicle_id = \(bind: vehicleID) AND \(unsafeRaw: accessFilterSQL)
                    GROUP BY journey_id
                    HAVING MIN(timestamp) >= \(bind: fromBound) AND MIN(timestamp) <= \(bind: toBound)
                    ORDER BY MIN(timestamp) DESC
                    LIMIT \(bind: limit)
                    """).all(decoding: Row.self)
            }
        } else {
            let whereClause = accessFilterSQL.isEmpty ? "" : "WHERE \(accessFilterSQL)"
            rows = try await sql.raw("""
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
                \(unsafeRaw: whereClause)
                GROUP BY journey_id
                HAVING MIN(timestamp) >= \(bind: fromBound) AND MIN(timestamp) <= \(bind: toBound)
                ORDER BY MIN(timestamp) DESC
                LIMIT \(bind: limit)
                """).all(decoding: Row.self)
        }

        return rows.map { r in
            JourneySummary(
                journeyID:               r.journey_id,
                vehicleID:               r.vehicle_id,
                vehicleName:             r.vehicle_name,
                startedAt:               r.started_at.map { Date(timeIntervalSince1970: $0) },
                endedAt:                 r.ended_at.map { Date(timeIntervalSince1970: $0) },
                driverID:                r.driver_id,
                totalDistanceKm:         normalizeJourneyDistanceKm(r.total_distance_km),
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
        await req.auditSecurityEvent(
            action: "vehicle_events.delete_one",
            targetType: "vehicle_event",
            targetID: uuid.uuidString,
            metadata: ["imei": event.imei ?? "", "journey_id": event.journeyID]
        )
        return .noContent
    }

    // MARK: - DELETE /api/vehicle-events?imei=&from=ISO8601&to=ISO8601
    func deletePeriod(req: Request) async throws -> Response {
        guard let imei = try? req.query.get(String.self, at: "imei"), !imei.isEmpty
        else { throw Abort(.badRequest, reason: "imei is required") }
        guard let fromStr = try? req.query.get(String.self, at: "from"),
              let toStr   = try? req.query.get(String.self, at: "to")
        else { throw Abort(.badRequest, reason: "from and to are required") }

        guard let from = QueryDateParser.parse(fromStr, allowUnixSeconds: true),
              let to   = QueryDateParser.parse(toStr, allowUnixSeconds: true)
        else { throw Abort(.badRequest, reason: "Invalid date format") }

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }

        // Count first so we can return the number deleted
        struct CountRow: Decodable { var n: Int }
        let rows = try await sql.raw("""
            SELECT COUNT(*) AS n FROM vehicle_events
            WHERE imei = \(bind: imei)
              AND timestamp >= \(bind: from.timeIntervalSince1970)
              AND timestamp <= \(bind: to.timeIntervalSince1970)
            """).all(decoding: CountRow.self)
        let count = rows.first?.n ?? 0

        try await sql.raw("""
            DELETE FROM vehicle_events
            WHERE imei = \(bind: imei)
              AND timestamp >= \(bind: from.timeIntervalSince1970)
              AND timestamp <= \(bind: to.timeIntervalSince1970)
            """).run()

        req.logger.notice("Deleted \(count) vehicle_events for IMEI \(imei) from \(fromStr) to \(toStr)")
        await req.auditSecurityEvent(
            action: "vehicle_events.delete_period",
            targetType: "vehicle_event",
            targetID: imei,
            metadata: ["from": fromStr, "to": toStr, "deleted": String(count)]
        )
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
        await req.auditSecurityEvent(
            action: "vehicle_events.delete_journey",
            targetType: "journey",
            targetID: journeyID,
            metadata: ["deleted": String(count)]
        )
        return .noContent
    }
}
