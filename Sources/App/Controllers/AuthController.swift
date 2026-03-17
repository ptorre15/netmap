import Vapor
import Fluent

// MARK: - Client IP resolution

/// Returns the real client IP, with trusted-proxy handling that resists XFF spoofing.
///
/// Trust is only granted when the direct TCP peer is in `trustedProxyIPs`.
/// In that case, we parse X-Forwarded-For as a chain and walk right-to-left
/// to find the first untrusted hop (the effective client IP).
private let trustedProxyIPs: Set<String> = {
    let defaults: Set<String> = ["127.0.0.1", "::1"]
    let extra = (Environment.get("TRUSTED_PROXY_IPS") ?? "")
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    if extra.isEmpty { return defaults }
    return defaults.union(extra)
}()

private func normaliseForwardedIP(_ raw: String) -> String {
    var v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if v.hasPrefix("for=") { v = String(v.dropFirst(4)) }
    v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    // RFC 3986 bracketed IPv6 with optional port, e.g. [2001:db8::1]:443
    if v.hasPrefix("["),
       let end = v.firstIndex(of: "]"),
       end > v.startIndex {
        return String(v[v.index(after: v.startIndex)..<end])
    }
    // IPv4:port -> IPv4
    if v.contains("."),
       v.filter({ $0 == ":" }).count == 1,
       let idx = v.lastIndex(of: ":") {
        return String(v[..<idx])
    }
    return v
}

func clientIP(for req: Request) -> String {
    let remote = req.remoteAddress?.ipAddress ?? ""
    guard !remote.isEmpty else { return "unknown" }

    // If connection is not from a trusted proxy, ignore forwarding headers.
    guard trustedProxyIPs.contains(remote) else { return remote }

    if let xff = req.headers.first(name: "X-Forwarded-For"), !xff.isEmpty {
        // Build chain with remote peer as last hop and walk from right to left.
        let chain = xff.split(separator: ",")
            .map { normaliseForwardedIP(String($0)) }
            .filter { !$0.isEmpty } + [remote]
        for hop in chain.reversed() where !trustedProxyIPs.contains(hop) {
            return hop
        }
    }
    if let forwarded = req.headers.first(name: "Forwarded"), !forwarded.isEmpty {
        // Minimal fallback parser for single-hop "for=..." values.
        let parts = forwarded.split(separator: ";").map { String($0) }
        if let forPart = parts.first(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("for=") }) {
            let ip = normaliseForwardedIP(forPart)
            if !ip.isEmpty, !trustedProxyIPs.contains(ip) { return ip }
        }
    }

    // All hops trusted or no valid forwarding info.
    return remote
}

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

    func login(req: Request) async throws -> Response {
        let body = try req.content.decode(LoginPayload.self)
        let ip = clientIP(for: req)
        let email = body.email.lowercased().trimmingCharacters(in: .whitespaces)
        guard try await !LoginRateLimiter.isBlocked(req: req, ip: ip, email: email) else {
            throw Abort(.tooManyRequests, reason: "Too many failed login attempts. Try again in 60 seconds.")
        }
        guard let user = try await User.query(on: req.db)
                .filter(\.$email == email).first()
        else {
            try await LoginRateLimiter.recordFailure(req: req, ip: ip, email: email)
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }
        guard try Bcrypt.verify(body.password, created: user.passwordHash) else {
            try await LoginRateLimiter.recordFailure(req: req, ip: ip, email: email)
            throw Abort(.unauthorized, reason: "Invalid credentials")
        }
        try await LoginRateLimiter.reset(on: req.db, ip: ip, email: email)
        try await UserToken.query(on: req.db).filter(\.$userID == user.id!).delete()
        let tok = UserToken(value: randomToken(), userID: user.id!, email: user.email, role: user.role)
        try await tok.save(on: req.db)
        let payload = LoginResponse(token: tok.value, email: tok.email, displayName: user.displayName, role: tok.role)
        let res = try await payload.encodeResponse(status: .ok, for: req)
        attachSessionCookie(to: res, token: tok)
        return res
    }

    // MARK: - POST /api/auth/setup  (only when zero users exist)

    func setup(req: Request) async throws -> Response {
        let count = try await User.query(on: req.db).count()
        guard count == 0
        else { throw Abort(.forbidden, reason: "Server already configured. Use /api/auth/login.") }
        let setupSecret = Environment.get("SETUP_SECRET")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let setupSecret, !setupSecret.isEmpty {
            let provided = req.headers.first(name: "X-Setup-Secret")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard provided == setupSecret else {
                throw Abort(.unauthorized, reason: "Invalid setup secret.")
            }
        } else if req.application.environment == .production {
            req.logger.critical("Blocked /api/auth/setup in production because SETUP_SECRET is not configured.")
            throw Abort(.forbidden, reason: "Initial setup is disabled until SETUP_SECRET is configured.")
        }
        let body  = try req.content.decode(LoginPayload.self)
        let email = body.email.lowercased().trimmingCharacters(in: .whitespaces)
        guard email.contains("@"), body.password.count >= 12
        else { throw Abort(.badRequest, reason: "Valid email required, password >= 12 chars.") }
        let user = User(email: email, passwordHash: try Bcrypt.hash(body.password), role: "admin")
        try await user.save(on: req.db)
        let tok = UserToken(value: randomToken(), userID: user.id!, email: user.email, role: user.role)
        try await tok.save(on: req.db)
        let payload = LoginResponse(token: tok.value, email: tok.email, displayName: nil, role: tok.role)
        let res = try await payload.encodeResponse(status: .ok, for: req)
        attachSessionCookie(to: res, token: tok)
        return res
    }

    // MARK: - GET /api/auth/status

    func status(req: Request) async throws -> StatusResponse {
        let count = try await User.query(on: req.db).count()
        return StatusResponse(needsSetup: count == 0)
    }

    // MARK: - POST /api/auth/logout

    func logout(req: Request) async throws -> Response {
        let bearerToken = req.headers.bearerAuthorization?.token
        let cookieToken = sessionCookieNames
            .compactMap { req.cookies[$0]?.string }
            .first { !$0.isEmpty }
        if let token = bearerToken ?? cookieToken {
            try await UserToken.query(on: req.db).filter(\.$value == token).delete()
        }
        let res = Response(status: .ok)
        clearSessionCookie(on: res)
        return res
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
        await req.auditSecurityEvent(
            action: "auth.user.delete",
            targetType: "user",
            targetID: id.uuidString,
            metadata: ["email": user.email, "role": user.role]
        )
        return .noContent
    }

    // MARK: - Helpers

    private func randomToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private func cookieSecureEnabled() -> Bool {
        if let raw = Environment.get("COOKIE_SECURE")?.lowercased() {
            return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
        }
        return Environment.get("ENV") == "production" || Environment.get("VAPOR_ENV") == "production"
    }

    private func sessionCookieName() -> String {
        cookieSecureEnabled() ? "__Host-session" : "session"
    }

    private func attachSessionCookie(to response: Response, token: UserToken) {
        response.cookies[sessionCookieName()] = HTTPCookies.Value(
            string: token.value,
            expires: token.expiresAt,
            maxAge: nil,
            domain: nil,
            path: "/",
            isSecure: cookieSecureEnabled(),
            isHTTPOnly: true,
            sameSite: .strict
        )
    }

    private func clearSessionCookie(on response: Response) {
        // Clear both possible cookie names to remove stale cookies from prior configs
        for name in ["__Host-session", "session"] {
            let secure = name.hasPrefix("__Host-")
            response.cookies[name] = HTTPCookies.Value(
                string: "",
                expires: Date(timeIntervalSince1970: 0),
                maxAge: 0,
                domain: nil,
                path: "/",
                isSecure: secure,
                isHTTPOnly: true,
                sameSite: .strict
            )
        }
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
