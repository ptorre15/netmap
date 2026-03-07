import Vapor
import Fluent
import SQLKit

let sessionCookieNames = ["__Host-session", "session"]

// MARK: - Auth context attached to each request

struct AuthUser: Sendable {
    let userID:  UUID
    let email:   String
    let role:    String
    var isAdmin: Bool { role == "admin" }
}

private struct AuthUserKey: StorageKey { typealias Value = AuthUser }

extension Request {
    var authUser: AuthUser? {
        get { storage[AuthUserKey.self] }
        set { storage[AuthUserKey.self] = newValue }
    }
}

// MARK: - User model

final class User: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id)                var id:           UUID?
    @Field(key: "email")         var email:        String
    @OptionalField(key: "display_name") var displayName: String?
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "role")          var role:         String   // "admin" | "user"
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(email: String, displayName: String? = nil, passwordHash: String, role: String = "user") {
        self.email        = email
        self.displayName  = displayName
        self.passwordHash = passwordHash
        self.role         = role
    }
}

// MARK: - UserToken model (bearer tokens, configurable TTL via TOKEN_TTL_DAYS)

final class UserToken: Model, @unchecked Sendable {
    static let schema = "user_tokens"

    @ID(key: .id)             var id:        UUID?
    @Field(key: "value")      var value:     String   // hex-encoded random 32 bytes
    @Field(key: "user_id")    var userID:    UUID
    @Field(key: "email")      var email:     String   // denormalised
    @Field(key: "role")       var role:      String   // denormalised
    @Field(key: "expires_at") var expiresAt: Date

    init() {}

    init(value: String, userID: UUID, email: String, role: String) {
        self.value    = value
        self.userID   = userID
        self.email    = email
        self.role     = role
        let ttlDays   = Double(Environment.get("TOKEN_TTL_DAYS") ?? "") ?? 7.0
        self.expiresAt = Date().addingTimeInterval(ttlDays * 86_400)
    }
}

// MARK: - Middleware

/// Validates the Bearer token and attaches `AuthUser` to the request.
struct BearerAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard let auth = try await authUserFromBearerOrCookie(request) else {
            throw Abort(.unauthorized, reason: "Valid Bearer token or session cookie required")
        }
        request.authUser = auth
        return try await next.respond(to: request)
    }
}

/// Attaches `AuthUser` if a valid Bearer token is present — does NOT fail on missing token.
/// Used on public routes that want to apply per-user filtering when authenticated.
struct OptionalBearerAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if let auth = try await authUserFromBearerOrCookie(request) {
            request.authUser = auth
        }
        return try await next.respond(to: request)
    }
}

func authUserFromBearerOrCookie(_ request: Request) async throws -> AuthUser? {
    let tokenValue: String? = {
        if let bearer = request.headers.bearerAuthorization {
            return bearer.token
        }
        for name in sessionCookieNames {
            if let cookie = request.cookies[name], !cookie.string.isEmpty {
                return cookie.string
            }
        }
        return nil
    }()
    guard let tokenValue else { return nil }
    guard let token = try await UserToken.query(on: request.db)
        .filter(\.$value == tokenValue)
        .filter(\.$expiresAt > Date())
        .first()
    else { return nil }
    return AuthUser(userID: token.userID, email: token.email, role: token.role)
}

/// Requires `authUser.role == "admin"`.
struct AdminMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        guard request.authUser?.isAdmin == true
        else { throw Abort(.forbidden, reason: "Admin role required") }
        return try await next.respond(to: request)
    }
}

// MARK: - Migrations

/// Creates the users table with email as primary identifier.
struct CreateUser: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(User.schema)
            .id()
            .field("email",         .string, .required)
            .unique(on: "email")
            .field("display_name",  .string)
            .field("password_hash", .string, .required)
            .field("role",          .string, .required)
            .field("created_at",    .datetime)
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(User.schema).delete()
    }
}

struct CreateUserToken: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(UserToken.schema)
            .id()
            .field("value",      .string,   .required)
            .unique(on: "value")
            .field("user_id",    .uuid,     .required)
            .field("email",      .string,   .required)
            .field("role",       .string,   .required)
            .field("expires_at", .datetime, .required)
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(UserToken.schema).delete()
    }
}

/// Migrates existing installations that used `username` column to `email`.
/// SQLite 3.25+ supports RENAME COLUMN — safe to run on new installs too (guarded).
struct MigrateUsernameToEmail: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        // Check if old column still exists before attempting rename
        let cols = try await sql.raw("PRAGMA table_info(users)").all()
        let hasUsername = cols.contains { (try? $0.decode(column: "name", as: String.self)) == "username" }
        if hasUsername {
            try await sql.raw("ALTER TABLE users RENAME COLUMN username TO email").run()
        }
        let hasDisplayName = cols.contains { (try? $0.decode(column: "name", as: String.self)) == "display_name" }
        if !hasDisplayName {
            try await sql.raw("ALTER TABLE users ADD COLUMN display_name TEXT").run()
        }
        // Same for user_tokens
        let tCols = try await sql.raw("PRAGMA table_info(user_tokens)").all()
        let tokHasUsername = tCols.contains { (try? $0.decode(column: "name", as: String.self)) == "username" }
        if tokHasUsername {
            try await sql.raw("ALTER TABLE user_tokens RENAME COLUMN username TO email").run()
        }
    }
    func revert(on db: Database) async throws { }
}
