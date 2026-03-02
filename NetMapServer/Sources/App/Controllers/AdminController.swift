import Vapor
import Fluent

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

    // ─── Helpers ─────────────────────────────────────────────────────────────

    private func randomKey() -> String {
        (0..<24).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func readablePassword() -> String {
        let words = ["netmap","sensor","asset","secure","access","reader","fleet","track","admin","device"]
        let word  = words.randomElement()!
        let num   = Int.random(in: 100...999)
        return "\(word)\(num)"
    }
}

struct APIKeyResponse: Content {
    var apiKey: String
}
