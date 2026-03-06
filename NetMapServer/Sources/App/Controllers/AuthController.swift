import Vapor
import Fluent

struct AuthController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let r = routes.grouped("api", "auth")
        r.post("login",  use: login)
        r.post("setup",  use: setup)
        r.get ("status", use: status)
        r.post("logout", use: logout)
        r.grouped(BearerAuthMiddleware()).get("me",     use: me)
        r.grouped(BearerAuthMiddleware()).get("users",  use: listUsers)
        r.grouped(BearerAuthMiddleware()).post("users", use: createUser)
        r.grouped(BearerAuthMiddleware()).delete("users", ":userID", use: deleteUser)
    }

    // MARK: - Shared DTOs

    struct LoginPayload:   Content { var email: String; var password: String }
    struct LoginResponse:  Content { var token: String; var email: String; var displayName: String?; var role: String }
    struct StatusResponse: Content { var needsSetup: Bool }

    // MARK: - POST /api/auth/login

    func login(req: Request) async throws -> LoginResponse {
        let ip = req.remoteAddress?.ipAddress ?? "unknown"
        guard await !LoginRateLimiter.shared.isBlocked(ip: ip) else {
            throw Abort(.tooManyRequests, reason: "Too many failed login attempts. Try again in 60 seconds.")
        }
        let body = try req.content.decode(LoginPayload.self)
        guard let user = try await User.query(on: req.db)
                .filter(\.$email == body.email.lowercased()).first()
        else {
            await LoginRateLimiter.shared.recordFailure(ip: ip)
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }
        guard try Bcrypt.verify(body.password, created: user.passwordHash) else {
            await LoginRateLimiter.shared.recordFailure(ip: ip)
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }
        await LoginRateLimiter.shared.reset(ip: ip)
        try await UserToken.query(on: req.db).filter(\.$userID == user.id!).delete()
        let tok = UserToken(value: randomToken(), userID: user.id!, email: user.email, role: user.role)
        try await tok.save(on: req.db)
        return LoginResponse(token: tok.value, email: tok.email, displayName: user.displayName, role: tok.role)
    }

    // MARK: - POST /api/auth/setup  (only when zero users exist)

    func setup(req: Request) async throws -> LoginResponse {
        let count = try await User.query(on: req.db).count()
        guard count == 0
        else { throw Abort(.forbidden, reason: "Server already configured. Use /api/auth/login.") }
        let body  = try req.content.decode(LoginPayload.self)
        let email = body.email.lowercased().trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), body.password.count >= 12
        else { throw Abort(.badRequest, reason: "Valid email required, password >= 12 chars.") }
        let user = User(email: email, passwordHash: try Bcrypt.hash(body.password), role: "admin")
        try await user.save(on: req.db)
        let tok = UserToken(value: randomToken(), userID: user.id!, email: user.email, role: user.role)
        try await tok.save(on: req.db)
        return LoginResponse(token: tok.value, email: tok.email, displayName: nil, role: tok.role)
    }

    // MARK: - GET /api/auth/status

    func status(req: Request) async throws -> StatusResponse {
        let count = try await User.query(on: req.db).count()
        return StatusResponse(needsSetup: count == 0)
    }

    // MARK: - POST /api/auth/logout

    func logout(req: Request) async throws -> HTTPStatus {
        guard let bearer = req.headers.bearerAuthorization else { return .ok }
        try await UserToken.query(on: req.db).filter(\.$value == bearer.token).delete()
        return .ok
    }

    // MARK: - GET /api/auth/me

    func me(req: Request) async throws -> LoginResponse {
        guard let auth = req.authUser else { throw Abort(.unauthorized) }
        let tok = try await UserToken.query(on: req.db)
            .filter(\.$email     == auth.email)
            .filter(\.$expiresAt >  Date())
            .first()
        let displayName = try await User.query(on: req.db).filter(\.$email == auth.email).first()?.displayName
        return LoginResponse(token: tok?.value ?? "", email: auth.email, displayName: displayName, role: auth.role)
    }

    // MARK: - GET /api/auth/users  (admin only)

    struct UserSummary: Content {
        var id: UUID?; var email: String; var displayName: String?; var role: String; var createdAt: Date?
    }

    func listUsers(req: Request) async throws -> [UserSummary] {
        guard req.authUser?.isAdmin == true else { throw Abort(.forbidden) }
        let users = try await User.query(on: req.db).sort(\.$createdAt, .ascending).all()
        return users.map { UserSummary(id: $0.id, email: $0.email, displayName: $0.displayName, role: $0.role, createdAt: $0.createdAt) }
    }

    // MARK: - POST /api/auth/users  (admin creates user, receives one-time password)

    struct NewUserPayload: Content { var email: String; var displayName: String?; var role: String? }
    struct NewUserResponse: Content { var email: String; var displayName: String?; var role: String; var password: String }

    func createUser(req: Request) async throws -> NewUserResponse {
        guard req.authUser?.isAdmin == true else { throw Abort(.forbidden) }
        let body  = try req.content.decode(NewUserPayload.self)
        let email = body.email.lowercased().trimmingCharacters(in: .whitespaces)
        guard email.contains("@") else { throw Abort(.badRequest, reason: "Valid email required.") }
        let exists = try await User.query(on: req.db).filter(\.$email == email).count() > 0
        guard !exists else { throw Abort(.conflict, reason: "Email already registered.") }
        let password = readablePassword()
        let role     = body.role == "admin" ? "admin" : "user"
        let user     = User(email: email, displayName: body.displayName,
                            passwordHash: try Bcrypt.hash(password), role: role)
        try await user.save(on: req.db)
        req.logger.info("User created: \(email) [\(role)]")
        return NewUserResponse(email: email, displayName: body.displayName, role: role, password: password)
    }

    // MARK: - DELETE /api/auth/users/:userID  (admin only)

    func deleteUser(req: Request) async throws -> HTTPStatus {
        guard req.authUser?.isAdmin == true else { throw Abort(.forbidden) }
        guard let id = req.parameters.get("userID", as: UUID.self) else { throw Abort(.badRequest) }
        guard let user = try await User.find(id, on: req.db) else { throw Abort(.notFound) }
        if user.role == "admin" {
            let adminCount = try await User.query(on: req.db).filter(\.$role == "admin").count()
            guard adminCount > 1 else { throw Abort(.forbidden, reason: "Cannot delete the last admin.") }
        }
        try await UserToken.query(on: req.db).filter(\.$userID == id).delete()
        try await user.delete(on: req.db)
        return .noContent
    }

    // MARK: - Helpers

    private func randomToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    /// Generates a readable initial password like "Kx3-Bm7-Rp2"
    private func readablePassword() -> String {
        let upper  = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
        let lower  = Array("abcdefghjkmnpqrstuvwxyz")
        let digits = Array("23456789")
        func group() -> String {
            "\(upper.randomElement()!)\(lower.randomElement()!)\(digits.randomElement()!)"
        }
        return "\(group())-\(group())-\(group())"
    }
}
