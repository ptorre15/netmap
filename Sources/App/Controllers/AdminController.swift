import Vapor
import Fluent
import SQLKit

// MARK: - Admin Controller
// Routes requiring Bearer + Admin authentication for server administration.

struct AdminController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let admin = routes
            .grouped("api", "admin")
            .grouped(BearerAuthMiddleware())
            .grouped(AdminMiddleware())

        // API key management
        admin.post("api-key", "rotate", use: rotateAPIKey) // POST /api/admin/api-key/rotate
        admin.get ("api-key",           use: getAPIKey)    // GET  /api/admin/api-key

        // User management
        admin.get   ("users",            use: listUsers)   // GET    /api/admin/users
        admin.post  ("users",            use: createUser)  // POST   /api/admin/users
        admin.delete("users", ":userID", use: deleteUser)  // DELETE /api/admin/users/:id
        admin.patch ("users", ":userID", use: updateUser)  // PATCH  /api/admin/users/:id (role/name)

        // User ↔ Asset assignment
        admin.get   ("users", ":userID", "assets",           use: listUserAssets) // GET    /api/admin/users/:id/assets
        admin.post  ("users", ":userID", "assets",           use: linkAsset)      // POST   /api/admin/users/:id/assets
        admin.delete("users", ":userID", "assets", ":assetID", use: unlinkAsset)  // DELETE /api/admin/users/:id/assets/:assetID

        // Tracker ↔ Vehicle pairing (admin-only)
        admin.get   ("trackers",                       use: listTrackers)   // GET    /api/admin/trackers
        admin.post  ("trackers",                       use: createTracker)  // POST   /api/admin/trackers
        admin.post  ("trackers", "pair",               use: pairTracker)    // POST   /api/admin/trackers/pair
        admin.delete("trackers", ":imei",             use: deleteTracker)  // DELETE /api/admin/trackers/:imei
        admin.delete("trackers", ":imei", "pair",     use: unpairTracker)  // DELETE /api/admin/trackers/:imei/pair
        admin.patch ("trackers", ":imei",             use: renameTracker)  // PATCH  /api/admin/trackers/:imei
        admin.get   ("trackers", ":imei", "config",               use: getTrackerConfig)    // GET   /api/admin/trackers/:imei/config
        admin.put   ("trackers", ":imei", "config",               use: upsertTrackerConfig)  // PUT   /api/admin/trackers/:imei/config
        admin.patch ("trackers", ":imei", "config",               use: patchTrackerConfig)   // PATCH /api/admin/trackers/:imei/config
        admin.post  ("trackers", ":imei", "apply-profile", ":profileID", use: applyProfileToTracker) // POST  /api/admin/trackers/:imei/apply-profile/:profileID

        // General sensor rename (SensorPush, AirTag, STIHL, ELA, TPMS…)
        admin.patch ("sensors", ":sensorID",          use: renameSensor)   // PATCH  /api/admin/sensors/:sensorID

        // Server statistics
        admin.get("stats", use: getStats)               // GET  /api/admin/stats

        // Server log stream
        admin.get("logs", use: getLogs)               // GET  /api/admin/logs?since=N
        admin.webSocket("ws", "logs") { req, ws in    // WS   /api/admin/ws/logs
            ws.onText { _, _ in }                     // keep-alive pings
            Task { await LogBroadcaster.shared.add(ws) }
        }
        admin.get("security-events", use: listSecurityEvents) // GET /api/admin/security-events

        // OTA firmware management
        admin.get  ("ota", "versions",                          use: otaGetVersions)       // GET    /api/admin/ota/versions
        admin.get  ("ota", "trackers",                          use: otaGetTrackers)       // GET    /api/admin/ota/trackers
        admin.patch("ota", "trackers", ":imei",                 use: otaSetFirmwareVersion) // PATCH  /api/admin/ota/trackers/:imei
        admin.post ("ota", "trackers", ":imei", "upgrade",      use: otaRequestUpgrade)    // POST   /api/admin/ota/trackers/:imei/upgrade
        admin.get  ("ota", "upgrades",                          use: otaListUpgrades)      // GET    /api/admin/ota/upgrades
        admin.patch("ota", "upgrades", ":requestID",            use: otaUpdateUpgrade)     // PATCH  /api/admin/ota/upgrades/:requestID
        admin.get  ("ota", "settings",                          use: otaGetSettings)       // GET    /api/admin/ota/settings
        admin.put  ("ota", "settings",                          use: otaSaveSettings)      // PUT    /api/admin/ota/settings
    }

    // ─── Server Logs ──────────────────────────────────────────────────────────

    struct LogLineDTO: Content {
        let index: Int
        let text: String
    }

    struct SecurityEventDTO: Content {
        var id: String
        var actorUserID: String?
        var actorEmail: String?
        var actorRole: String?
        var action: String
        var targetType: String?
        var targetID: String?
        var metadataJSON: String?
        var ipAddress: String?
        var createdAt: Date?
    }

    struct SecurityEventListResponse: Content {
        var total: Int
        var limit: Int
        var offset: Int
        var items: [SecurityEventDTO]
    }

    /// GET /api/admin/security-events?action=&actor_email=&target_type=&target_id=&from=&to=&limit=&offset=
    /// Read-only audit stream endpoint. No delete route is exposed.
    func listSecurityEvents(req: Request) async throws -> SecurityEventListResponse {
        let rawLimit  = (try? req.query.get(Int.self, at: "limit")) ?? 100
        let rawOffset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        let limit = min(max(rawLimit, 1), 1000)
        let offset = max(rawOffset, 0)

        var q = SecurityEvent.query(on: req.db).sort(\.$createdAt, .descending)
        if let action = try? req.query.get(String.self, at: "action"), !action.isEmpty {
            q = q.filter(\.$action == action)
        }
        if let actorEmail = try? req.query.get(String.self, at: "actor_email"), !actorEmail.isEmpty {
            q = q.filter(\.$actorEmail == actorEmail)
        }
        if let targetType = try? req.query.get(String.self, at: "target_type"), !targetType.isEmpty {
            q = q.filter(\.$targetType == targetType)
        }
        if let targetID = try? req.query.get(String.self, at: "target_id"), !targetID.isEmpty {
            q = q.filter(\.$targetID == targetID)
        }
        if let from = parseISODate(try? req.query.get(String.self, at: "from")) {
            q = q.filter(\.$createdAt >= from)
        }
        if let to = parseISODate(try? req.query.get(String.self, at: "to")) {
            q = q.filter(\.$createdAt <= to)
        }

        let total = try await q.count()
        let rows = try await q.range(offset..<(offset + limit)).all()
        let items = rows.map { e in
            SecurityEventDTO(
                id: e.id?.uuidString ?? "",
                actorUserID: e.actorUserID?.uuidString,
                actorEmail: e.actorEmail,
                actorRole: e.actorRole,
                action: e.action,
                targetType: e.targetType,
                targetID: e.targetID,
                metadataJSON: e.metadataJSON,
                ipAddress: e.ipAddress,
                createdAt: e.createdAt
            )
        }
        return SecurityEventListResponse(total: total, limit: limit, offset: offset, items: items)
    }

    /// GET /api/admin/logs?since=N — returns buffered log lines newer than `since` index
    func getLogs(req: Request) async throws -> [LogLineDTO] {
        let since = (try? req.query.get(Int.self, at: "since")) ?? 0
        let entries = await LogBuffer.shared.entries(since: since)
        return entries.map { LogLineDTO(index: $0.index, text: $0.text) }
    }

    // ─── API Key ─────────────────────────────────────────────────────────────

    func getAPIKey(req: Request) async throws -> APIKeyResponse {
        let key = req.application.currentAPIKey
        if key.isEmpty {
            return APIKeyResponse(apiKey: "[Key is set securely -- rotate to generate a new displayable key]")
        }
        return APIKeyResponse(apiKey: key)
    }

    func rotateAPIKey(req: Request) async throws -> APIKeyResponse {
        let newKey  = randomKey()
        let stored  = "sha256v1:" + sha256Hex(newKey)
        if let existing = try await AppSetting.query(on: req.db).filter(\.$key == "api_key").first() {
            existing.value = stored
            try await existing.save(on: req.db)
        } else {
            try await AppSetting(key: "api_key", value: stored).save(on: req.db)
        }
        req.application.currentAPIKey     = newKey
        req.application.currentAPIKeyHash = sha256Hex(newKey)
        req.logger.warning("API key rotated by \(req.authUser?.email ?? "unknown").")
        await req.auditSecurityEvent(
            action: "api_key.rotate",
            targetType: "api_key",
            metadata: ["actor": req.authUser?.email ?? "unknown"]
        )
        return APIKeyResponse(apiKey: newKey)
    }

    // ─── User management ─────────────────────────────────────────────────────

    struct UserDetail: Content {
        var id: UUID?
        var email: String
        var displayName: String?
        var role: String
        var createdAt: Date?
        var assetIDs: [String]   // UUIDs of linked assets
    }

    /// GET /api/admin/users — list all users with their linked asset IDs
    func listUsers(req: Request) async throws -> [UserDetail] {
        let users  = try await User.query(on: req.db).sort(\.$createdAt, .ascending).all()
        let links  = try await UserAsset.query(on: req.db).all()
        let byUser = Dictionary(grouping: links, by: \.userID)
        return users.map { u in
            let ids = byUser[u.id ?? UUID()]?.map { $0.assetID.uuidString } ?? []
            return UserDetail(id: u.id, email: u.email, displayName: u.displayName,
                              role: u.role, createdAt: u.createdAt, assetIDs: ids)
        }
    }

    struct NewUserPayload: Content {
        var email: String
        var displayName: String?
        var role: String?
        var password: String?   // optional; server generates one if absent
    }
    struct NewUserResponse: Content {
        var id: UUID?
        var email: String
        var displayName: String?
        var role: String
        var password: String   // one-time password (shown once)
    }

    /// POST /api/admin/users
    func createUser(req: Request) async throws -> NewUserResponse {
        let body     = try req.content.decode(NewUserPayload.self)
        let email    = body.email.lowercased().trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { throw Abort(.badRequest, reason: "Valid email required.") }
        let exists   = try await User.query(on: req.db).filter(\.$email == email).count() > 0
        guard !exists else { throw Abort(.conflict, reason: "Email already registered.") }
        let password = body.password?.isEmpty == false ? body.password! : readablePassword()
        let role     = body.role == "admin" ? "admin" : "user"
        let user     = User(email: email, displayName: body.displayName,
                            passwordHash: try Bcrypt.hash(password), role: role)
        try await user.save(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.user.create",
            targetType: "user",
            targetID: user.id?.uuidString,
            metadata: ["email": email, "role": role]
        )
        return NewUserResponse(id: user.id, email: email, displayName: body.displayName,
                               role: role, password: password)
    }

    struct UpdateUserPayload: Content {
        var displayName: String?
        var role: String?
        var password: String?
    }

    /// PATCH /api/admin/users/:id
    func updateUser(req: Request) async throws -> HTTPStatus {
        guard let id   = req.parameters.get("userID", as: UUID.self),
              let user = try await User.find(id, on: req.db)
        else { throw Abort(.notFound) }
        let body = try req.content.decode(UpdateUserPayload.self)
        if let name = body.displayName { user.displayName = name }
        if let role = body.role        { user.role = (role == "admin") ? "admin" : "user" }
        if let pw   = body.password, !pw.isEmpty {
            user.passwordHash = try Bcrypt.hash(pw)
        }
        try await user.save(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.user.update",
            targetType: "user",
            targetID: user.id?.uuidString,
            metadata: [
                "updated_role": body.role ?? "",
                "password_changed": (body.password?.isEmpty == false) ? "true" : "false"
            ]
        )
        return .ok
    }

    /// DELETE /api/admin/users/:id
    func deleteUser(req: Request) async throws -> HTTPStatus {
        guard let id   = req.parameters.get("userID", as: UUID.self),
              let user = try await User.find(id, on: req.db)
        else { throw Abort(.notFound) }
        if user.role == "admin" {
            let count = try await User.query(on: req.db).filter(\.$role == "admin").count()
            guard count > 1 else { throw Abort(.forbidden, reason: "Cannot delete the last admin.") }
        }
        // Remove all user-asset links and tokens first
        try await UserAsset.query(on: req.db).filter(\.$userID == id).delete()
        try await UserToken.query(on: req.db).filter(\.$userID == id).delete()
        try await user.delete(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.user.delete",
            targetType: "user",
            targetID: id.uuidString,
            metadata: ["email": user.email, "role": user.role]
        )
        return .noContent
    }

    // ─── User ↔ Asset assignment ──────────────────────────────────────────────

    struct AssetLinkPayload:   Content { var assetID: String }
    struct AssetLinkResponse:  Content { var userID: String; var assetID: String }

    /// GET /api/admin/users/:id/assets
    func listUserAssets(req: Request) async throws -> [String] {
        guard let id = req.parameters.get("userID", as: UUID.self) else { throw Abort(.badRequest) }
        let links = try await UserAsset.query(on: req.db).filter(\.$userID == id).all()
        return links.map { $0.assetID.uuidString }
    }

    /// POST /api/admin/users/:id/assets  { "assetID": "uuid" }
    func linkAsset(req: Request) async throws -> HTTPStatus {
        guard let uid  = req.parameters.get("userID", as: UUID.self) else { throw Abort(.badRequest) }
        let body       = try req.content.decode(AssetLinkPayload.self)
        guard let aid  = UUID(uuidString: body.assetID) else {
            throw Abort(.badRequest, reason: "Invalid assetID UUID")
        }
        // Idempotent — ignore duplicate
        let exists = try await UserAsset.query(on: req.db)
            .filter(\.$userID == uid).filter(\.$assetID == aid).count() > 0
        if !exists {
            try await UserAsset(userID: uid, assetID: aid).save(on: req.db)
        }
        await req.auditSecurityEvent(
            action: "admin.user_asset.link",
            targetType: "user_asset",
            targetID: "\(uid.uuidString):\(aid.uuidString)"
        )
        return .created
    }

    /// DELETE /api/admin/users/:id/assets/:assetID
    func unlinkAsset(req: Request) async throws -> HTTPStatus {
        guard let uid = req.parameters.get("userID",  as: UUID.self),
              let aid = req.parameters.get("assetID", as: UUID.self)
        else { throw Abort(.badRequest) }
        try await UserAsset.query(on: req.db)
            .filter(\.$userID == uid).filter(\.$assetID == aid).delete()
        await req.auditSecurityEvent(
            action: "admin.user_asset.unlink",
            targetType: "user_asset",
            targetID: "\(uid.uuidString):\(aid.uuidString)"
        )
        return .noContent
    }

    // ─── Tracker ↔ Vehicle pairing ─────────────────────────────────────────────

    struct TrackerInfo: Content {
        var imei:         String
        var vehicleID:    String
        var vehicleName:  String
        var sensorName:   String?
        var readingCount: Int
    }

    struct TrackerPairPayload: Content {
        var imei:      String
        var vehicleID: String
    }

    struct TrackerCreatePayload: Content {
        var imei:       String
        var vehicleID:  String
        var sensorName: String?
    }

    struct TrackerConfigSystemPayload: Content {
        var pingIntervalMin: Int
        var sleepDelayMin: Int
        var wakeUpSourcesEnabled: [String]
    }

    struct TrackerConfigThresholdsPayload: Content {
        var harshBraking: Double
        var harshAcceleration: Double
        var harshCornering: Double
        var overspeed: Double
    }

    struct TrackerConfigDriverBehaviorPayload: Content {
        var thresholds: TrackerConfigThresholdsPayload
        var minimumSpeedKmh: Int
        var beepEnabled: Bool
    }

    struct TrackerConfigPayload: Content {
        var schemaVersion: Int?   // read-only in responses; ignored on input (server auto-manages)
        var imei: String
        var updatedAt: Date?
        var updatedBy: String?
        var profileID: String?    // UUID of the TrackerConfigProfile last applied (nil = custom)
        var system: TrackerConfigSystemPayload
        var driverBehavior: TrackerConfigDriverBehaviorPayload
    }

    struct TrackerConfigSystemPatchPayload: Content {
        var pingIntervalMin: Int?
        var sleepDelayMin: Int?
        var wakeUpSourcesEnabled: [String]?
    }

    struct TrackerConfigThresholdsPatchPayload: Content {
        var harshBraking: Double?
        var harshAcceleration: Double?
        var harshCornering: Double?
        var overspeed: Double?
    }

    struct TrackerConfigDriverBehaviorPatchPayload: Content {
        var thresholds: TrackerConfigThresholdsPatchPayload?
        var minimumSpeedKmh: Int?
        var beepEnabled: Bool?
    }

    struct TrackerConfigPatchPayload: Content {
        var imei: String?
        var system: TrackerConfigSystemPatchPayload?
        var driverBehavior: TrackerConfigDriverBehaviorPatchPayload?
    }

    /// POST /api/admin/trackers  { imei, vehicleID, sensorName? }
    /// Creates a tracker registration (SensorReading brand=tracker) linked to a vehicle.
    func createTracker(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(TrackerCreatePayload.self)
        let imei = body.imei.trimmingCharacters(in: .whitespaces)
        guard !imei.isEmpty else { throw Abort(.badRequest, reason: "imei is required") }
        guard let vid     = UUID(uuidString: body.vehicleID),
              let vehicle = try await Vehicle.find(vid, on: req.db)
        else { throw Abort(.notFound, reason: "Vehicle not found") }

        // Idempotent: if this IMEI already exists, just update its vehicle link
        let existing = try await SensorReading.query(on: req.db)
            .filter(\.$sensorID == imei)
            .filter(\.$brand    == "tracker")
            .first()

        if let sr = existing {
            sr.vehicleID   = vid.uuidString
            sr.vehicleName = vehicle.name
            if let name = body.sensorName, !name.isEmpty { sr.sensorName = name }
            try await sr.save(on: req.db)
        } else {
            let sr = SensorReading()
            sr.sensorID   = imei
            sr.vehicleID  = vid.uuidString
            sr.vehicleName = vehicle.name
            sr.brand      = "tracker"
            sr.sensorName = body.sensorName?.isEmpty == false ? body.sensorName : "Tracker \(imei)"
            sr.timestamp  = Date()
            sr.receivedAt = Date()
            try await sr.save(on: req.db)
        }
        req.logger.notice("Tracker \(imei) registered to \"\(vehicle.name)\" by \(req.authUser?.email ?? "?")")
        await req.auditSecurityEvent(
            action: "admin.tracker.create_or_register",
            targetType: "tracker",
            targetID: imei,
            metadata: ["vehicle_id": vid.uuidString, "vehicle_name": vehicle.name]
        )
        return .created
    }

    /// DELETE /api/admin/trackers/:imei  — removes all sensor_readings for this tracker IMEI
    func deleteTracker(req: Request) async throws -> HTTPStatus {
        guard let imei = req.parameters.get("imei") else { throw Abort(.badRequest) }
        try await SensorReading.query(on: req.db)
            .filter(\.$sensorID == imei)
            .filter(\.$brand    == "tracker")
            .delete()
        req.logger.notice("Tracker \(imei) deleted by \(req.authUser?.email ?? "?")")
        await req.auditSecurityEvent(
            action: "admin.tracker.delete",
            targetType: "tracker",
            targetID: imei
        )
        return .noContent
    }

    /// GET /api/admin/trackers — list all known tracker IMEIs with their current pairing
    func listTrackers(req: Request) async throws -> [TrackerInfo] {
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }
        struct Row: Decodable {
            var sensor_id:    String
            var vehicle_id:   String
            var vehicle_name: String
            var sensor_name:  String?
            var reading_count: Int
        }
        let rows = try await sql.raw("""
            SELECT sensor_id, vehicle_id, vehicle_name, sensor_name,
                   COUNT(*) AS reading_count
            FROM sensor_readings
            WHERE brand = 'tracker'
            GROUP BY sensor_id
            ORDER BY vehicle_name, sensor_id
            """).all(decoding: Row.self)
        return rows.map {
            TrackerInfo(imei: $0.sensor_id, vehicleID: $0.vehicle_id,
                        vehicleName: $0.vehicle_name, sensorName: $0.sensor_name,
                        readingCount: $0.reading_count)
        }
    }

    /// POST /api/admin/trackers/pair  { "imei": "…", "vehicleID": "UUID" }
    /// Links a tracker IMEI to a vehicle. Enforces: vehicle must exist, max 1 tracker per vehicle.
    func pairTracker(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(TrackerPairPayload.self)
        let imei = body.imei.trimmingCharacters(in: .whitespaces)
        guard !imei.isEmpty else { throw Abort(.badRequest, reason: "imei is required") }
        guard let vid     = UUID(uuidString: body.vehicleID),
              let vehicle = try await Vehicle.find(vid, on: req.db)
        else { throw Abort(.notFound, reason: "Vehicle not found") }

        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }

        // Enforce 1 tracker per vehicle: check for a different IMEI already paired
        struct Conflict: Decodable { var sensor_id: String }
        let conflicts = try await sql.raw("""
            SELECT DISTINCT sensor_id FROM sensor_readings
            WHERE UPPER(vehicle_id) = UPPER(\(bind: vid.uuidString))
              AND brand = 'tracker'
              AND sensor_id != \(bind: imei)
            LIMIT 1
            """).all(decoding: Conflict.self)
        if let other = conflicts.first {
            throw Abort(.conflict, reason:
                "Vehicle \"\(vehicle.name)\" already has tracker \(other.sensor_id) paired. Unpair it first.")
        }

        let vehicleID   = vid.uuidString
        let vehicleName = vehicle.name
        try await sql.raw("""
            UPDATE sensor_readings
            SET vehicle_id = \(bind: vehicleID), vehicle_name = \(bind: vehicleName)
            WHERE sensor_id = \(bind: imei) AND brand = 'tracker'
            """).run()
        try await sql.raw("""
            UPDATE vehicle_events
            SET vehicle_id = \(bind: vehicleID), vehicle_name = \(bind: vehicleName)
            WHERE imei = \(bind: imei)
            """).run()
        req.logger.notice("Tracker \(imei) paired to \"\(vehicleName)\" by \(req.authUser?.email ?? "?")")
        await req.auditSecurityEvent(
            action: "admin.tracker.pair",
            targetType: "tracker",
            targetID: imei,
            metadata: ["vehicle_id": vehicleID, "vehicle_name": vehicleName]
        )
        return .ok
    }

    /// PATCH /api/admin/trackers/:imei  { sensorName? }  — renames the tracker
    func renameTracker(req: Request) async throws -> HTTPStatus {
        guard let imei = req.parameters.get("imei") else { throw Abort(.badRequest) }
        struct Body: Content { var sensorName: String? }
        let body = try req.content.decode(Body.self)
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }
        let name = body.sensorName?.trimmingCharacters(in: .whitespaces)

        // 1. Update sensor_readings (the source-of-truth for the tracker label)
        try await sql.raw("""
            UPDATE sensor_readings
            SET sensor_name = \(bind: name)
            WHERE sensor_id = \(bind: imei) AND brand = 'tracker'
            """).run()

        // 2. Backfill vehicle_name in historical events so the journey list
        //    reflects the new name immediately (vehicle_name is display-only —
        //    journeys are still grouped by vehicleID, not vehicleName).
        if let newName = name, !newName.isEmpty {
            try await sql.raw("""
                UPDATE vehicle_events
                SET vehicle_name = \(bind: newName)
                WHERE imei = \(bind: imei)
                """).run()
            try await sql.raw("""
                UPDATE device_lifecycle_events
                SET vehicle_name = \(bind: newName)
                WHERE imei = \(bind: imei)
                """).run()
        }
        req.logger.notice("Tracker \(imei) renamed to \"\(name ?? "nil")\" by \(req.authUser?.email ?? "?")")
        await req.auditSecurityEvent(
            action: "admin.tracker.rename",
            targetType: "tracker",
            targetID: imei,
            metadata: ["sensor_name": name ?? ""]
        )
        return .ok
    }

    /// GET /api/admin/trackers/:imei/config
    func getTrackerConfig(req: Request) async throws -> TrackerConfigPayload {
        guard let imeiRaw = req.parameters.get("imei") else {
            throw Abort(.badRequest, reason: "imei is required")
        }
        let imei = imeiRaw.trimmingCharacters(in: .whitespaces)
        guard !imei.isEmpty else { throw Abort(.badRequest, reason: "imei is required") }
        guard try await trackerExists(imei: imei, on: req.db) else {
            throw Abort(.notFound, reason: "Tracker not found")
        }
        if let cfg = try await TrackerConfig.query(on: req.db).filter(\.$imei == imei).first() {
            return try buildTrackerConfigPayload(from: cfg)
        }
        return defaultTrackerConfigPayload(for: imei)
    }

    /// PUT /api/admin/trackers/:imei/config
    func upsertTrackerConfig(req: Request) async throws -> Response {
        guard let imeiRaw = req.parameters.get("imei") else {
            throw Abort(.badRequest, reason: "imei is required")
        }
        let imei = imeiRaw.trimmingCharacters(in: .whitespaces)
        guard !imei.isEmpty else { throw Abort(.badRequest, reason: "imei is required") }
        guard try await trackerExists(imei: imei, on: req.db) else {
            throw Abort(.notFound, reason: "Tracker not found")
        }

        let payload = try req.content.decode(TrackerConfigPayload.self)
        guard payload.imei == imei else {
            throw Abort(.badRequest, reason: "Payload imei must match URL imei")
        }
        try validateTrackerConfigPayload(payload)

        let actor = req.authUser?.email
        if let cfg = try await TrackerConfig.query(on: req.db).filter(\.$imei == imei).first() {
            try applyFullTrackerConfig(payload, to: cfg, actor: actor)
            try await cfg.save(on: req.db)
            await req.auditSecurityEvent(
                action: "admin.tracker.config.update",
                targetType: "tracker",
                targetID: imei,
                metadata: ["schema_version": String(cfg.schemaVersion)]
            )
            let out = try buildTrackerConfigPayload(from: cfg)
            return try await out.encodeResponse(status: .ok, for: req)
        }

        let cfg = TrackerConfig()
        cfg.imei = imei
        try applyFullTrackerConfig(payload, to: cfg, actor: actor)
        try await cfg.save(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.tracker.config.create",
            targetType: "tracker",
            targetID: imei,
            metadata: ["schema_version": String(cfg.schemaVersion)]
        )
        let out = try buildTrackerConfigPayload(from: cfg)
        return try await out.encodeResponse(status: .created, for: req)
    }

    /// PATCH /api/admin/trackers/:imei/config
    func patchTrackerConfig(req: Request) async throws -> TrackerConfigPayload {
        guard let imeiRaw = req.parameters.get("imei") else {
            throw Abort(.badRequest, reason: "imei is required")
        }
        let imei = imeiRaw.trimmingCharacters(in: .whitespaces)
        guard !imei.isEmpty else { throw Abort(.badRequest, reason: "imei is required") }
        guard let cfg = try await TrackerConfig.query(on: req.db).filter(\.$imei == imei).first() else {
            throw Abort(.notFound, reason: "Tracker config not found")
        }

        let payload = try req.content.decode(TrackerConfigPatchPayload.self)
        if let payloadIMEI = payload.imei, payloadIMEI != imei {
            throw Abort(.badRequest, reason: "Payload imei must match URL imei")
        }

        try applyPatchTrackerConfig(payload, to: cfg, actor: req.authUser?.email)
        try await cfg.save(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.tracker.config.patch",
            targetType: "tracker",
            targetID: imei,
            metadata: ["schema_version": String(cfg.schemaVersion)]
        )
        return try buildTrackerConfigPayload(from: cfg)
    }

    /// POST /api/admin/trackers/:imei/apply-profile/:profileID
    /// Stamps a TrackerConfigProfile onto the tracker, setting all config fields from the profile.
    func applyProfileToTracker(req: Request) async throws -> Response {
        guard let imeiRaw   = req.parameters.get("imei"),
              let pidStr    = req.parameters.get("profileID"),
              let profileID = UUID(uuidString: pidStr)
        else { throw Abort(.badRequest, reason: "imei and profileID are required") }
        let imei = imeiRaw.trimmingCharacters(in: .whitespaces)
        guard !imei.isEmpty else { throw Abort(.badRequest, reason: "imei is required") }
        guard try await trackerExists(imei: imei, on: req.db) else {
            throw Abort(.notFound, reason: "Tracker not found")
        }
        guard let profile = try await TrackerConfigProfile.find(profileID, on: req.db) else {
            throw Abort(.notFound, reason: "Profile not found")
        }
        let actor = req.authUser?.email

        let cfg: TrackerConfig
        if let existing = try await TrackerConfig.query(on: req.db).filter(\.$imei == imei).first() {
            cfg = existing
        } else {
            cfg = TrackerConfig()
            cfg.imei = imei
            cfg.schemaVersion = 0
        }
        cfg.pingIntervalMin            = profile.pingIntervalMin
        cfg.sleepDelayMin              = profile.sleepDelayMin
        cfg.wakeUpSourcesJSON          = profile.wakeUpSourcesJSON
        cfg.thresholdHarshBraking      = profile.thresholdHarshBraking
        cfg.thresholdHarshAcceleration = profile.thresholdHarshAcceleration
        cfg.thresholdHarshCornering    = profile.thresholdHarshCornering
        cfg.thresholdOverspeedKmh      = profile.thresholdOverspeedKmh
        cfg.minimumSpeedKmh            = profile.minimumSpeedKmh
        cfg.beepEnabled                = profile.beepEnabled
        cfg.profileID                  = profileID
        cfg.updatedBy                  = actor
        cfg.schemaVersion             += 1
        try await cfg.save(on: req.db)
        await req.auditSecurityEvent(
            action: "admin.tracker.config.apply_profile",
            targetType: "tracker",
            targetID: imei,
            metadata: [
                "profile_id":   profileID.uuidString,
                "profile_name": profile.name,
                "schema_version": String(cfg.schemaVersion)
            ]
        )
        let out = try buildTrackerConfigPayload(from: cfg)
        return try await out.encodeResponse(status: .ok, for: req)
    }

    /// PATCH /api/admin/sensors/:sensorID — renames any non-tracker sensor (SensorPush, AirTag, STIHL, ELA, TPMS…)
    func renameSensor(req: Request) async throws -> HTTPStatus {
        guard let sensorID = req.parameters.get("sensorID") else { throw Abort(.badRequest) }
        struct Body: Content { var sensorName: String? }
        let body = try req.content.decode(Body.self)
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }
        let name = body.sensorName?.trimmingCharacters(in: .whitespaces)
        try await sql.raw("""
            UPDATE sensor_readings
            SET sensor_name = \(bind: name)
            WHERE sensor_id = \(bind: sensorID) AND brand != 'tracker'
            """).run()
        req.logger.notice("Sensor \(sensorID) renamed to \"\(name ?? "nil")\" by \(req.authUser?.email ?? "?")")
        await req.auditSecurityEvent(
            action: "admin.sensor.rename",
            targetType: "sensor",
            targetID: sensorID,
            metadata: ["sensor_name": name ?? ""]
        )
        return .ok
    }

    /// DELETE /api/admin/trackers/:imei/pair  — removes the vehicle link for this tracker
    func unpairTracker(req: Request) async throws -> HTTPStatus {
        guard let imei = req.parameters.get("imei") else { throw Abort(.badRequest) }
        guard let sql  = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }
        let fallbackName = "Tracker \(imei)"
        try await sql.raw("""
            UPDATE sensor_readings
            SET vehicle_id = \(bind: imei), vehicle_name = \(bind: fallbackName)
            WHERE sensor_id = \(bind: imei) AND brand = 'tracker'
            """).run()
        try await sql.raw("""
            UPDATE vehicle_events
            SET vehicle_id = \(bind: imei), vehicle_name = \(bind: fallbackName)
            WHERE imei = \(bind: imei)
            """).run()
        req.logger.notice("Tracker \(imei) unpaired by \(req.authUser?.email ?? "?")")
        await req.auditSecurityEvent(
            action: "admin.tracker.unpair",
            targetType: "tracker",
            targetID: imei
        )
        return .noContent
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private func randomKey() -> String {
        (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    // Must match the wakeup cause strings emitted by the tracker firmware (netmap_reporter.c → wakeup_cause_to_str())
    private let allowedWakeSources: Set<String> = ["VOLTAGE_RISE", "CAN_ACTIVITY", "TIMER_BACKUP", "ESPNOW_HMI", "IMU_MOTION"]

    private func trackerExists(imei: String, on db: Database) async throws -> Bool {
        let inReadings = try await SensorReading.query(on: db)
            .filter(\.$sensorID == imei)
            .filter(\.$brand == "tracker")
            .count() > 0
        if inReadings { return true }
        let inVehicleEvents = try await VehicleEvent.query(on: db)
            .filter(\.$imei == imei)
            .count() > 0
        if inVehicleEvents { return true }
        let inBehavior = try await DriverBehaviorEvent.query(on: db)
            .filter(\.$imei == imei)
            .count() > 0
        if inBehavior { return true }
        return try await DeviceLifecycleEvent.query(on: db)
            .filter(\.$imei == imei)
            .count() > 0
    }

    private func defaultTrackerConfigPayload(for imei: String) -> TrackerConfigPayload {
        TrackerConfigPayload(
            schemaVersion: nil,
            imei: imei,
            updatedAt: nil,
            updatedBy: nil,
            profileID: nil,
            system: TrackerConfigSystemPayload(
                pingIntervalMin: 5,
                sleepDelayMin: 15,
                wakeUpSourcesEnabled: ["VOLTAGE_RISE", "CAN_ACTIVITY"]
            ),
            driverBehavior: TrackerConfigDriverBehaviorPayload(
                thresholds: TrackerConfigThresholdsPayload(
                    harshBraking: 3.2,
                    harshAcceleration: 3.0,
                    harshCornering: 2.8,
                    overspeed: 120
                ),
                minimumSpeedKmh: 20,
                beepEnabled: true
            )
        )
    }

    private func buildTrackerConfigPayload(from cfg: TrackerConfig) throws -> TrackerConfigPayload {
        let wake = try decodeWakeSources(cfg.wakeUpSourcesJSON)
        return TrackerConfigPayload(
            schemaVersion: cfg.schemaVersion,   // always populated in responses
            imei: cfg.imei,
            updatedAt: cfg.updatedAt ?? cfg.createdAt,
            updatedBy: cfg.updatedBy,
            profileID: cfg.profileID?.uuidString,
            system: TrackerConfigSystemPayload(
                pingIntervalMin: cfg.pingIntervalMin,
                sleepDelayMin: cfg.sleepDelayMin,
                wakeUpSourcesEnabled: wake
            ),
            driverBehavior: TrackerConfigDriverBehaviorPayload(
                thresholds: TrackerConfigThresholdsPayload(
                    harshBraking: cfg.thresholdHarshBraking,
                    harshAcceleration: cfg.thresholdHarshAcceleration,
                    harshCornering: cfg.thresholdHarshCornering,
                    overspeed: cfg.thresholdOverspeedKmh
                ),
                minimumSpeedKmh: cfg.minimumSpeedKmh,
                beepEnabled: cfg.beepEnabled
            )
        )
    }

    private func decodeWakeSources(_ json: String) throws -> [String] {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data) else {
            throw Abort(.internalServerError, reason: "Invalid stored tracker config")
        }
        return arr
    }

    private func validateWakeSources(_ values: [String]) throws {
        guard !values.isEmpty else {
            throw Abort(.badRequest, reason: "system.wakeUpSourcesEnabled cannot be empty")
        }
        var seen = Set<String>()
        for source in values {
            guard allowedWakeSources.contains(source) else {
                throw Abort(.badRequest, reason: "Invalid wake-up source: \(source)")
            }
            guard seen.insert(source).inserted else {
                throw Abort(.badRequest, reason: "Duplicate wake-up source: \(source)")
            }
        }
    }

    private func validateTrackerConfigPayload(_ payload: TrackerConfigPayload) throws {
        try validateSystem(
            pingIntervalMin: payload.system.pingIntervalMin,
            sleepDelayMin: payload.system.sleepDelayMin,
            wakeSources: payload.system.wakeUpSourcesEnabled
        )
        try validateDriverBehavior(
            harshBraking: payload.driverBehavior.thresholds.harshBraking,
            harshAcceleration: payload.driverBehavior.thresholds.harshAcceleration,
            harshCornering: payload.driverBehavior.thresholds.harshCornering,
            overspeed: payload.driverBehavior.thresholds.overspeed,
            minimumSpeedKmh: payload.driverBehavior.minimumSpeedKmh
        )
    }

    private func validateSystem(pingIntervalMin: Int, sleepDelayMin: Int, wakeSources: [String]) throws {
        guard (1...1440).contains(pingIntervalMin) else {
            throw Abort(.badRequest, reason: "system.pingIntervalMin must be between 1 and 1440")
        }
        guard (1...10080).contains(sleepDelayMin) else {
            throw Abort(.badRequest, reason: "system.sleepDelayMin must be between 1 and 10080")
        }
        try validateWakeSources(wakeSources)
    }

    private func validateDriverBehavior(
        harshBraking: Double,
        harshAcceleration: Double,
        harshCornering: Double,
        overspeed: Double,
        minimumSpeedKmh: Int
    ) throws {
        guard harshBraking > 0 else {
            throw Abort(.badRequest, reason: "driverBehavior.thresholds.harshBraking must be > 0")
        }
        guard harshAcceleration > 0 else {
            throw Abort(.badRequest, reason: "driverBehavior.thresholds.harshAcceleration must be > 0")
        }
        guard harshCornering > 0 else {
            throw Abort(.badRequest, reason: "driverBehavior.thresholds.harshCornering must be > 0")
        }
        guard overspeed >= 1, overspeed <= 300 else {
            throw Abort(.badRequest, reason: "driverBehavior.thresholds.overspeed must be between 1 and 300")
        }
        guard (0...250).contains(minimumSpeedKmh) else {
            throw Abort(.badRequest, reason: "driverBehavior.minimumSpeedKmh must be between 0 and 250")
        }
    }

    private func applyFullTrackerConfig(_ payload: TrackerConfigPayload, to cfg: TrackerConfig, actor: String?) throws {
        let newWakeJSON = try encodeWakeSources(payload.system.wakeUpSourcesEnabled)
        let oldWakeSorted = (try? decodeWakeSources(cfg.wakeUpSourcesJSON))?.sorted() ?? []
        let newWakeSorted = payload.system.wakeUpSourcesEnabled.sorted()
        let changed = cfg.pingIntervalMin != payload.system.pingIntervalMin
            || cfg.sleepDelayMin != payload.system.sleepDelayMin
            || oldWakeSorted != newWakeSorted
            || cfg.thresholdHarshBraking != payload.driverBehavior.thresholds.harshBraking
            || cfg.thresholdHarshAcceleration != payload.driverBehavior.thresholds.harshAcceleration
            || cfg.thresholdHarshCornering != payload.driverBehavior.thresholds.harshCornering
            || cfg.thresholdOverspeedKmh != payload.driverBehavior.thresholds.overspeed
            || cfg.minimumSpeedKmh != payload.driverBehavior.minimumSpeedKmh
            || cfg.beepEnabled != payload.driverBehavior.beepEnabled
        cfg.imei = payload.imei
        cfg.pingIntervalMin = payload.system.pingIntervalMin
        cfg.sleepDelayMin = payload.system.sleepDelayMin
        cfg.wakeUpSourcesJSON = newWakeJSON
        cfg.thresholdHarshBraking = payload.driverBehavior.thresholds.harshBraking
        cfg.thresholdHarshAcceleration = payload.driverBehavior.thresholds.harshAcceleration
        cfg.thresholdHarshCornering = payload.driverBehavior.thresholds.harshCornering
        cfg.thresholdOverspeedKmh = payload.driverBehavior.thresholds.overspeed
        cfg.minimumSpeedKmh = payload.driverBehavior.minimumSpeedKmh
        cfg.beepEnabled = payload.driverBehavior.beepEnabled
        cfg.updatedBy = actor ?? payload.updatedBy
        if changed { cfg.schemaVersion += 1 }
        cfg.profileID = nil   // manual full-replace breaks any profile link
    }

    private func applyPatchTrackerConfig(_ patch: TrackerConfigPatchPayload, to cfg: TrackerConfig, actor: String?) throws {
        // Snapshot to detect changes
        let snapPing = cfg.pingIntervalMin; let snapSleep = cfg.sleepDelayMin
        let snapWake = cfg.wakeUpSourcesJSON; let snapBraking = cfg.thresholdHarshBraking
        let snapAccel = cfg.thresholdHarshAcceleration; let snapCornering = cfg.thresholdHarshCornering
        let snapOverspeed = cfg.thresholdOverspeedKmh; let snapMinSpeed = cfg.minimumSpeedKmh
        let snapBeep = cfg.beepEnabled

        if let system = patch.system {
            let newPing = system.pingIntervalMin ?? cfg.pingIntervalMin
            let newSleep = system.sleepDelayMin ?? cfg.sleepDelayMin
            let currentWake = try decodeWakeSources(cfg.wakeUpSourcesJSON)
            let newWake = system.wakeUpSourcesEnabled ?? currentWake
            try validateSystem(pingIntervalMin: newPing, sleepDelayMin: newSleep, wakeSources: newWake)
            cfg.pingIntervalMin = newPing
            cfg.sleepDelayMin = newSleep
            cfg.wakeUpSourcesJSON = try encodeWakeSources(newWake)
        }
        if let behavior = patch.driverBehavior {
            let current = TrackerConfigThresholdsPayload(
                harshBraking: cfg.thresholdHarshBraking,
                harshAcceleration: cfg.thresholdHarshAcceleration,
                harshCornering: cfg.thresholdHarshCornering,
                overspeed: cfg.thresholdOverspeedKmh
            )
            let t = behavior.thresholds
            let newHarshBraking = t?.harshBraking ?? current.harshBraking
            let newHarshAcceleration = t?.harshAcceleration ?? current.harshAcceleration
            let newHarshCornering = t?.harshCornering ?? current.harshCornering
            let newOverspeed = t?.overspeed ?? current.overspeed
            let newMinSpeed = behavior.minimumSpeedKmh ?? cfg.minimumSpeedKmh
            try validateDriverBehavior(
                harshBraking: newHarshBraking,
                harshAcceleration: newHarshAcceleration,
                harshCornering: newHarshCornering,
                overspeed: newOverspeed,
                minimumSpeedKmh: newMinSpeed
            )
            cfg.thresholdHarshBraking = newHarshBraking
            cfg.thresholdHarshAcceleration = newHarshAcceleration
            cfg.thresholdHarshCornering = newHarshCornering
            cfg.thresholdOverspeedKmh = newOverspeed
            cfg.minimumSpeedKmh = newMinSpeed
            if let beep = behavior.beepEnabled { cfg.beepEnabled = beep }
        }
        cfg.updatedBy = actor ?? cfg.updatedBy

        // Auto-increment version if anything changed
        let oldWakeSorted = (try? decodeWakeSources(snapWake))?.sorted() ?? []
        let newWakeSorted = (try? decodeWakeSources(cfg.wakeUpSourcesJSON))?.sorted() ?? []
        let changed = snapPing != cfg.pingIntervalMin || snapSleep != cfg.sleepDelayMin
            || oldWakeSorted != newWakeSorted
            || snapBraking != cfg.thresholdHarshBraking || snapAccel != cfg.thresholdHarshAcceleration
            || snapCornering != cfg.thresholdHarshCornering || snapOverspeed != cfg.thresholdOverspeedKmh
            || snapMinSpeed != cfg.minimumSpeedKmh || snapBeep != cfg.beepEnabled
        if changed { cfg.schemaVersion += 1 }
        cfg.profileID = nil   // manual patch breaks any profile link
    }

    private func encodeWakeSources(_ values: [String]) throws -> String {
        try validateWakeSources(values)
        let data = try JSONEncoder().encode(values)
        guard let json = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to encode wake-up sources")
        }
        return json
    }

    private func readablePassword() -> String {
        let upper  = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let lower  = Array("abcdefghjkmnpqrstuvwxyz")
        let digits = Array("23456789")
        func group() -> String {
            "\(upper.randomElement()!)\(lower.randomElement()!)\(digits.randomElement()!)"
        }
        return "\(group())-\(group())-\(group())-\(group())"
    }

    private func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let basic = ISO8601DateFormatter()
        return iso.date(from: raw) ?? basic.date(from: raw) ?? Double(raw).map { Date(timeIntervalSince1970: $0) }
    }

    // ── GET /api/admin/stats ──────────────────────────────────────────────────
    struct DayCount: Content {
        var date: String
        var count: Int
    }
    struct TypeCount: Content {
        var type: String
        var count: Int
    }
    struct TrackerStat: Content {
        var imei: String
        var name: String?
        var events7d: Int
        var lastSeenAt: Date?
    }
    struct AdminStatsResponse: Content {
        var totalReadings: Int
        var totalVehicleEvents: Int
        var totalLifecycleEvents: Int
        var totalDriverBehaviorEvents: Int
        var totalVehicles: Int
        var totalUsers: Int
        var readingsLast30d: Int
        var vehicleEventsLast30d: Int
        var lifecycleEventsLast30d: Int
        var driverBehaviorEventsLast30d: Int
        var readingsPerDay: [DayCount]
        var vehicleEventsPerDay: [DayCount]
        var lifecyclePerDay: [DayCount]
        var driverBehaviorPerDay: [DayCount]
        var vehicleEventsByType: [TypeCount]
        var lifecycleByType: [TypeCount]
        var topTrackers: [TrackerStat]
        var oldestReading: Date?
        var newestReading: Date?
        var dbSizeBytes: Int?
        var uptimeSeconds: Int    // seconds since last server boot
    }

    func getStats(req: Request) async throws -> AdminStatsResponse {
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }

        struct CountRow:   Decodable { var n: Int }
        struct DayRow:     Decodable { var day: String; var n: Int }
        struct TypeRow:    Decodable { var t: String;   var n: Int }
        struct TrackerRow: Decodable { var imei: String; var name: String?; var n: Int; var last_ts: Double? }
        struct DateRow:    Decodable { var ts: Double? }
        struct PageRow:    Decodable { var page_count: Int; var page_size: Int }

        let threshold30 = Date().addingTimeInterval(-30 * 86400).timeIntervalSince1970
        let threshold7  = Date().addingTimeInterval(-7  * 86400).timeIntervalSince1970

        async let totalReadings   = sql.raw("SELECT COUNT(*) AS n FROM sensor_readings").first(decoding: CountRow.self)
        async let totalVehEv      = sql.raw("SELECT COUNT(*) AS n FROM vehicle_events").first(decoding: CountRow.self)
        async let totalLC         = sql.raw("SELECT COUNT(*) AS n FROM device_lifecycle_events").first(decoding: CountRow.self)
        async let totalDB         = sql.raw("SELECT COUNT(*) AS n FROM driver_behavior_events").first(decoding: CountRow.self)
        async let totalVehicles   = sql.raw("SELECT COUNT(*) AS n FROM vehicles WHERE deleted_at IS NULL").first(decoding: CountRow.self)
        async let totalUsers      = sql.raw("SELECT COUNT(*) AS n FROM users").first(decoding: CountRow.self)

        async let readings30d     = sql.raw("SELECT COUNT(*) AS n FROM sensor_readings WHERE timestamp >= \(bind: threshold30)").first(decoding: CountRow.self)
        async let vehEv30d        = sql.raw("SELECT COUNT(*) AS n FROM vehicle_events WHERE timestamp >= \(bind: threshold30)").first(decoding: CountRow.self)
        async let lc30d           = sql.raw("SELECT COUNT(*) AS n FROM device_lifecycle_events WHERE timestamp >= \(bind: threshold30)").first(decoding: CountRow.self)
        async let db30d           = sql.raw("SELECT COUNT(*) AS n FROM driver_behavior_events WHERE timestamp >= \(bind: threshold30)").first(decoding: CountRow.self)

        async let readPerDay      = sql.raw("SELECT date(timestamp,'unixepoch') AS day, COUNT(*) AS n FROM sensor_readings WHERE timestamp >= \(bind: threshold30) GROUP BY day ORDER BY day").all(decoding: DayRow.self)
        async let vehEvPerDay     = sql.raw("SELECT date(timestamp,'unixepoch') AS day, COUNT(*) AS n FROM vehicle_events WHERE timestamp >= \(bind: threshold30) GROUP BY day ORDER BY day").all(decoding: DayRow.self)
        async let lcPerDay        = sql.raw("SELECT date(timestamp,'unixepoch') AS day, COUNT(*) AS n FROM device_lifecycle_events WHERE timestamp >= \(bind: threshold30) GROUP BY day ORDER BY day").all(decoding: DayRow.self)
        async let dbPerDay        = sql.raw("SELECT date(timestamp,'unixepoch') AS day, COUNT(*) AS n FROM driver_behavior_events WHERE timestamp >= \(bind: threshold30) GROUP BY day ORDER BY day").all(decoding: DayRow.self)

        async let vehEvByType     = sql.raw("SELECT event_type AS t, COUNT(*) AS n FROM vehicle_events GROUP BY t ORDER BY n DESC").all(decoding: TypeRow.self)
        async let lcByType        = sql.raw("SELECT event_type AS t, COUNT(*) AS n FROM device_lifecycle_events GROUP BY t ORDER BY n DESC").all(decoding: TypeRow.self)

        async let topTrackers     = sql.raw("SELECT imei, sensor_name AS name, COUNT(*) AS n, MAX(timestamp) AS last_ts FROM vehicle_events WHERE timestamp >= \(bind: threshold7) GROUP BY imei ORDER BY n DESC LIMIT 10").all(decoding: TrackerRow.self)

        async let oldestR         = sql.raw("SELECT MIN(received_at) AS ts FROM sensor_readings").first(decoding: DateRow.self)
        async let newestR         = sql.raw("SELECT MAX(received_at) AS ts FROM sensor_readings").first(decoding: DateRow.self)
        async let dbPages         = sql.raw("SELECT page_count, page_size FROM pragma_page_count(), pragma_page_size()").first(decoding: PageRow.self)

        let (tr, tv, tlc, tdb, tvh, tu, r30, v30, l30, d30, rpd, vpd, lpd, dpd, vbt, lbt, top, oldest, newest, pages) = try await (
            totalReadings, totalVehEv, totalLC, totalDB, totalVehicles, totalUsers,
            readings30d, vehEv30d, lc30d, db30d,
            readPerDay, vehEvPerDay, lcPerDay, dbPerDay,
            vehEvByType, lcByType, topTrackers,
            oldestR, newestR, dbPages
        )

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        return AdminStatsResponse(
            totalReadings:              tr?.n  ?? 0,
            totalVehicleEvents:         tv?.n  ?? 0,
            totalLifecycleEvents:       tlc?.n ?? 0,
            totalDriverBehaviorEvents:  tdb?.n ?? 0,
            totalVehicles:              tvh?.n ?? 0,
            totalUsers:                 tu?.n  ?? 0,
            readingsLast30d:            r30?.n ?? 0,
            vehicleEventsLast30d:       v30?.n ?? 0,
            lifecycleEventsLast30d:     l30?.n ?? 0,
            driverBehaviorEventsLast30d: d30?.n ?? 0,
            readingsPerDay:    rpd.map { DayCount(date: $0.day, count: $0.n) },
            vehicleEventsPerDay: vpd.map { DayCount(date: $0.day, count: $0.n) },
            lifecyclePerDay:   lpd.map { DayCount(date: $0.day, count: $0.n) },
            driverBehaviorPerDay: dpd.map { DayCount(date: $0.day, count: $0.n) },
            vehicleEventsByType: vbt.map { TypeCount(type: $0.t, count: $0.n) },
            lifecycleByType:   lbt.map { TypeCount(type: $0.t, count: $0.n) },
            topTrackers: top.map { TrackerStat(imei: $0.imei, name: $0.name, events7d: $0.n, lastSeenAt: $0.last_ts.map { Date(timeIntervalSince1970: $0) }) },
            oldestReading: oldest?.ts.map { Date(timeIntervalSince1970: $0) } ?? nil,
            newestReading: newest?.ts.map { Date(timeIntervalSince1970: $0) } ?? nil,
            dbSizeBytes: pages.map { $0.page_count * $0.page_size },
            uptimeSeconds: Int(Date().timeIntervalSince(req.application.startedAt))
        )
    }
}

struct APIKeyResponse: Content {
    var apiKey: String
}

// MARK: - OTA Management
extension AdminController {

    struct OTAFirmwareFile: Content {
        var version: String
        var filename: String
        var size: Int?
        var uploadedAt: String?
    }

    struct OTAVersionsResponse: Content {
        var versions: [OTAFirmwareFile]
        var latest: String?
        var reachable: Bool?
    }

    struct OTATrackerStatus: Content {
        var imei: String
        var vehicleName: String
        var sensorName: String?
        var firmwareVersion: String?
        var pendingUpgradeVersion: String?
    }

    struct OTAFirmwarePatchBody: Content {
        var firmwareVersion: String?
    }

    struct OTAUpgradeRequestBody: Content {
        var targetVersion: String
        var notes: String?
    }

    struct OTAUpgradeStatusPatchBody: Content {
        var status: String   // cancelled | failed | pending
        var notes: String?
    }

    struct OTAUpgradeRequestDTO: Content {
        var id: String
        var imei: String
        var targetVersion: String
        var requestedBy: String
        var status: String
        var notes: String?
        var createdAt: Date?
        var updatedAt: Date?
        var completedAt: Date?
    }

    struct OTAUpgradeListResponse: Content {
        var total: Int
        var limit: Int
        var offset: Int
        var items: [OTAUpgradeRequestDTO]
    }

    struct OTASettingsBody: Content {
        var otaServerUrl: String
    }

    /// GET /api/admin/ota/versions — proxies OTA server firmware file listing
    func otaGetVersions(req: Request) async throws -> OTAVersionsResponse {
        // Always proxy via the internal address — the stored ota_server_url is the
        // public-facing URL used in firmware download links sent to trackers, and may
        // not be reachable from the server itself (e.g. HTTPS loopback issue).
        let otaURL = Environment.get("OTA_INTERNAL_URL") ?? "http://127.0.0.1:9000"
        do {
            let res = try await req.client.get(URI("\(otaURL)/api/firmware/files"))
            guard res.status == .ok else {
                return OTAVersionsResponse(versions: [], latest: nil, reachable: false)
            }
            var parsed = (try? res.content.decode(OTAVersionsResponse.self))
                ?? OTAVersionsResponse(versions: [], latest: nil)
            parsed.reachable = true
            return parsed
        } catch {
            req.logger.warning("OTA proxy failed: \(error)")
            return OTAVersionsResponse(versions: [], latest: nil, reachable: false)
        }
    }

    /// GET /api/admin/ota/trackers — all trackers with their known firmware version and any pending upgrade
    func otaGetTrackers(req: Request) async throws -> [OTATrackerStatus] {
        guard let sql = req.db as? SQLDatabase else {
            throw Abort(.internalServerError, reason: "SQL not available")
        }
        struct Row: Decodable {
            var sensor_id: String
            var vehicle_name: String
            var sensor_name: String?
            var firmware_version: String?
        }
        let rows = try await sql.raw("""
            SELECT sr.sensor_id, sr.vehicle_name, sr.sensor_name,
                   tc.firmware_version
            FROM sensor_readings sr
            LEFT JOIN tracker_configs tc ON UPPER(tc.imei) = UPPER(sr.sensor_id)
            WHERE sr.brand = 'tracker'
            GROUP BY sr.sensor_id
            ORDER BY sr.vehicle_name, sr.sensor_id
            """).all(decoding: Row.self)
        // Fetch pending / delivered upgrades to surface them per-tracker
        let pendingUpgrades = try await FirmwareUpgradeRequest.query(on: req.db)
            .filter(\.$status ~~ ["pending", "delivered"])
            .all()
        let pendingByImei = Dictionary(grouping: pendingUpgrades, by: { $0.imei.uppercased() })
        return rows.map {
            let pending = pendingByImei[$0.sensor_id.uppercased()]?.last
            return OTATrackerStatus(imei: $0.sensor_id, vehicleName: $0.vehicle_name,
                             sensorName: $0.sensor_name, firmwareVersion: $0.firmware_version,
                             pendingUpgradeVersion: pending?.targetVersion)
        }
    }

    /// POST /api/admin/ota/trackers/:imei/upgrade — create a firmware upgrade request
    func otaRequestUpgrade(req: Request) async throws -> HTTPStatus {
        guard let imei = req.parameters.get("imei") else { throw Abort(.badRequest) }
        let body = try req.content.decode(OTAUpgradeRequestBody.self)
        guard !body.targetVersion.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Abort(.badRequest, reason: "targetVersion is required")
        }
        let requestedBy = req.authUser?.email ?? "admin"
        let upgradeReq = FirmwareUpgradeRequest(
            imei: imei,
            targetVersion: body.targetVersion.trimmingCharacters(in: .whitespaces),
            requestedBy: requestedBy,
            status: "pending",
            notes: body.notes
        )
        try await upgradeReq.save(on: req.db)
        req.logger.info("OTA upgrade requested: imei=\(imei) target=\(body.targetVersion) by=\(requestedBy)")
        await req.auditSecurityEvent(
            action: "ota.upgrade.requested",
            targetType: "tracker", targetID: imei,
            metadata: ["target_version": body.targetVersion]
        )
        return .created
    }

    /// GET /api/admin/ota/upgrades — paginated list of all firmware upgrade requests
    func otaListUpgrades(req: Request) async throws -> OTAUpgradeListResponse {
        let rawLimit  = (try? req.query.get(Int.self, at: "limit"))  ?? 100
        let rawOffset = (try? req.query.get(Int.self, at: "offset")) ?? 0
        let limit  = min(max(rawLimit, 1), 500)
        let offset = max(rawOffset, 0)
        var q = FirmwareUpgradeRequest.query(on: req.db).sort(\.$createdAt, .descending)
        if let imei   = try? req.query.get(String.self, at: "imei"),   !imei.isEmpty  { q = q.filter(\.$imei == imei) }
        if let status = try? req.query.get(String.self, at: "status"), !status.isEmpty { q = q.filter(\.$status == status) }
        let total = try await q.count()
        let items = try await q.offset(offset).limit(limit).all()
        let dtos  = items.map { r in
            OTAUpgradeRequestDTO(
                id:            r.id?.uuidString ?? "",
                imei:          r.imei,
                targetVersion: r.targetVersion,
                requestedBy:   r.requestedBy,
                status:        r.status,
                notes:         r.notes,
                createdAt:     r.createdAt,
                updatedAt:     r.updatedAt,
                completedAt:   r.completedAt
            )
        }
        return OTAUpgradeListResponse(total: total, limit: limit, offset: offset, items: dtos)
    }

    /// PATCH /api/admin/ota/upgrades/:requestID — update status (cancel / mark failed)
    func otaUpdateUpgrade(req: Request) async throws -> HTTPStatus {
        guard let idStr = req.parameters.get("requestID"), let uuid = UUID(uuidString: idStr) else {
            throw Abort(.badRequest, reason: "Invalid request ID")
        }
        let body = try req.content.decode(OTAUpgradeStatusPatchBody.self)
        let allowed = ["pending", "cancelled", "failed"]
        guard allowed.contains(body.status) else {
            throw Abort(.badRequest, reason: "status must be one of: \(allowed.joined(separator: ", "))")
        }
        guard let upgradeReq = try await FirmwareUpgradeRequest.find(uuid, on: req.db) else {
            throw Abort(.notFound)
        }
        upgradeReq.status = body.status
        if let notes = body.notes { upgradeReq.notes = notes }
        if body.status == "completed" || body.status == "failed" || body.status == "cancelled" {
            upgradeReq.completedAt = Date()
        }
        try await upgradeReq.save(on: req.db)
        return .ok
    }

    /// PATCH /api/admin/ota/trackers/:imei — manually record firmware version for a tracker
    func otaSetFirmwareVersion(req: Request) async throws -> HTTPStatus {
        guard let imei = req.parameters.get("imei") else { throw Abort(.badRequest) }
        let body = try req.content.decode(OTAFirmwarePatchBody.self)
        if let config = try await TrackerConfig.query(on: req.db)
            .filter(\.$imei == imei).first() {
            config.firmwareVersion = body.firmwareVersion
            try await config.save(on: req.db)
        }
        return .ok
    }

    /// GET /api/admin/ota/settings
    func otaGetSettings(req: Request) async throws -> OTASettingsBody {
        let url = try await AppSetting.query(on: req.db)
            .filter(\.$key == "ota_server_url").first()?.value
            ?? Environment.get("OTA_SERVER_URL")
            ?? "http://127.0.0.1:9000"
        return OTASettingsBody(otaServerUrl: url)
    }

    /// PUT /api/admin/ota/settings
    func otaSaveSettings(req: Request) async throws -> HTTPStatus {
        let body = try req.content.decode(OTASettingsBody.self)
        let urlStr = body.otaServerUrl.trimmingCharacters(in: .whitespaces)
        guard !urlStr.isEmpty, URL(string: urlStr)?.scheme != nil else {
            throw Abort(.badRequest, reason: "Invalid URL")
        }
        if let existing = try await AppSetting.query(on: req.db)
            .filter(\.$key == "ota_server_url").first() {
            existing.value = urlStr
            try await existing.save(on: req.db)
        } else {
            try await AppSetting(key: "ota_server_url", value: urlStr).save(on: req.db)
        }
        return .ok
    }
}
