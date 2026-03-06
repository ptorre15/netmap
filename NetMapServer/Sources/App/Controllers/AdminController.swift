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

        // Server log stream
        admin.get("logs", use: getLogs)               // GET  /api/admin/logs?since=N
    }

    // ─── Server Logs ──────────────────────────────────────────────────────────

    struct LogLineDTO: Content {
        let index: Int
        let text: String
    }

    /// GET /api/admin/logs?since=N — returns buffered log lines newer than `since` index
    func getLogs(req: Request) async throws -> [LogLineDTO] {
        let since = (try? req.query.get(Int.self, at: "since")) ?? 0
        let entries = await LogBuffer.shared.entries(since: since)
        return entries.map { LogLineDTO(index: $0.index, text: $0.text) }
    }

    // ─── API Key ─────────────────────────────────────────────────────────────

    func getAPIKey(req: Request) async throws -> APIKeyResponse {
        APIKeyResponse(apiKey: req.application.currentAPIKey)
    }

    func rotateAPIKey(req: Request) async throws -> APIKeyResponse {
        let newKey = randomKey()
        if let existing = try await AppSetting.query(on: req.db).filter(\.$key == "api_key").first() {
            existing.value = newKey
            try await existing.save(on: req.db)
        } else {
            try await AppSetting(key: "api_key", value: newKey).save(on: req.db)
        }
        req.application.currentAPIKey = newKey
        req.logger.warning("API key rotated by \(req.authUser?.email ?? "unknown").")
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
        return .created
    }

    /// DELETE /api/admin/users/:id/assets/:assetID
    func unlinkAsset(req: Request) async throws -> HTTPStatus {
        guard let uid = req.parameters.get("userID",  as: UUID.self),
              let aid = req.parameters.get("assetID", as: UUID.self)
        else { throw Abort(.badRequest) }
        try await UserAsset.query(on: req.db)
            .filter(\.$userID == uid).filter(\.$assetID == aid).delete()
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
        return .noContent
    }

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private func randomKey() -> String {
        (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
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
}

struct APIKeyResponse: Content {
    var apiKey: String
}
