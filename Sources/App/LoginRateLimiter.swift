import Vapor
import Fluent

private enum LoginBucketType: String {
    case ip
    case email
}

final class LoginAttemptBucket: Model, @unchecked Sendable {
    static let schema = "login_attempt_buckets"

    @ID(key: .id)                              var id: UUID?
    @Field(key: "bucket_type")                 var bucketType: String
    @Field(key: "bucket_key")                  var bucketKey: String
    @Field(key: "window_start")                var windowStart: Date
    @Field(key: "fail_count")                  var failCount: Int
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    fileprivate init(type: LoginBucketType, key: String, windowStart: Date, failCount: Int) {
        self.bucketType = type.rawValue
        self.bucketKey = key
        self.windowStart = windowStart
        self.failCount = failCount
    }
}

struct CreateLoginAttemptBucket: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(LoginAttemptBucket.schema)
            .id()
            .field("bucket_type", .string, .required)
            .field("bucket_key", .string, .required)
            .field("window_start", .datetime, .required)
            .field("fail_count", .int, .required)
            .field("updated_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "bucket_type", "bucket_key")
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(LoginAttemptBucket.schema).delete()
    }
}

/// Persistent brute-force protection with per-IP and per-email windows.
enum LoginRateLimiter {

    private static let ipLimit = 5
    private static let ipWindow: TimeInterval = 60
    private static let emailLimit = 10
    private static let emailWindow: TimeInterval = 300

    static func isBlocked(req: Request, ip: String, email: String) async throws -> Bool {
        let now = Date()
        let ipCount = try await activeCount(on: req.db, type: .ip, key: ip, now: now, window: ipWindow)
        let emailCount = try await activeCount(on: req.db, type: .email, key: email, now: now, window: emailWindow)
        return ipCount >= ipLimit || emailCount >= emailLimit
    }

    static func recordFailure(req: Request, ip: String, email: String) async throws {
        let now = Date()
        let ipCount = try await bump(on: req.db, type: .ip, key: ip, now: now, window: ipWindow)
        let emailCount = try await bump(on: req.db, type: .email, key: email, now: now, window: emailWindow)
        if ipCount == ipLimit || emailCount == emailLimit {
            await req.auditSecurityEvent(
                action: "auth.login.lockout",
                targetType: "auth",
                metadata: [
                    "ip": ip,
                    "email": email,
                    "ip_fail_count": String(ipCount),
                    "email_fail_count": String(emailCount)
                ]
            )
        }
    }

    static func reset(on db: Database, ip: String, email: String) async throws {
        try await LoginAttemptBucket.query(on: db)
            .group(.or) { q in
                q.group(.and) { qq in
                    qq.filter(\.$bucketType == LoginBucketType.ip.rawValue)
                    qq.filter(\.$bucketKey == ip)
                }
                q.group(.and) { qq in
                    qq.filter(\.$bucketType == LoginBucketType.email.rawValue)
                    qq.filter(\.$bucketKey == email)
                }
            }
            .delete()
    }

    private static func activeCount(
        on db: Database,
        type: LoginBucketType,
        key: String,
        now: Date,
        window: TimeInterval
    ) async throws -> Int {
        guard let row = try await LoginAttemptBucket.query(on: db)
            .filter(\.$bucketType == type.rawValue)
            .filter(\.$bucketKey == key)
            .first()
        else { return 0 }
        if now.timeIntervalSince(row.windowStart) >= window {
            try await row.delete(on: db)
            return 0
        }
        return row.failCount
    }

    private static func bump(
        on db: Database,
        type: LoginBucketType,
        key: String,
        now: Date,
        window: TimeInterval
    ) async throws -> Int {
        if let row = try await LoginAttemptBucket.query(on: db)
            .filter(\.$bucketType == type.rawValue)
            .filter(\.$bucketKey == key)
            .first() {
            if now.timeIntervalSince(row.windowStart) >= window {
                row.windowStart = now
                row.failCount = 1
            } else {
                row.failCount += 1
            }
            try await row.save(on: db)
            return row.failCount
        }
        let row = LoginAttemptBucket(type: type, key: key, windowStart: now, failCount: 1)
        try await row.save(on: db)
        return 1
    }
}
