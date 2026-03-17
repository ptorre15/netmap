import Vapor
import Fluent
import SQLKit
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Append-only audit log for privileged security-relevant actions.
final class SecurityEvent: Model, Content, @unchecked Sendable {
    static let schema = "security_events"

    @ID(key: .id)                              var id: UUID?
    @OptionalField(key: "actor_user_id")       var actorUserID: UUID?
    @OptionalField(key: "actor_email")         var actorEmail: String?
    @OptionalField(key: "actor_role")          var actorRole: String?
    @Field(key: "action")                      var action: String
    @OptionalField(key: "target_type")         var targetType: String?
    @OptionalField(key: "target_id")           var targetID: String?
    @OptionalField(key: "metadata_json")       var metadataJSON: String?
    @OptionalField(key: "ip_address")          var ipAddress: String?
    @OptionalField(key: "prev_hash")           var prevHash: String?
    @OptionalField(key: "event_hash")          var eventHash: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(
        actor: AuthUser?,
        action: String,
        targetType: String?,
        targetID: String?,
        metadataJSON: String?,
        ipAddress: String?,
        prevHash: String? = nil,
        eventHash: String? = nil
    ) {
        self.actorUserID = actor?.userID
        self.actorEmail = actor?.email
        self.actorRole = actor?.role
        self.action = action
        self.targetType = targetType
        self.targetID = targetID
        self.metadataJSON = metadataJSON
        self.ipAddress = ipAddress
        self.prevHash = prevHash
        self.eventHash = eventHash
    }
}

struct CreateSecurityEvent: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(SecurityEvent.schema)
            .id()
            .field("actor_user_id", .uuid)
            .field("actor_email", .string)
            .field("actor_role", .string)
            .field("action", .string, .required)
            .field("target_type", .string)
            .field("target_id", .string)
            .field("metadata_json", .string)
            .field("ip_address", .string)
            .field("prev_hash", .string)
            .field("event_hash", .string)
            .field("created_at", .datetime)
            .create()

        if let sql = db as? SQLDatabase {
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_security_events_created ON security_events (created_at)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_security_events_action  ON security_events (action)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_security_events_actor   ON security_events (actor_user_id)").run()
            try await sql.raw("CREATE INDEX IF NOT EXISTS idx_security_events_hash    ON security_events (event_hash)").run()
        }
    }

    func revert(on db: Database) async throws {
        try await db.schema(SecurityEvent.schema).delete()
    }
}

struct AddSecurityEventHashChain: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        let cols = try await sql.raw("PRAGMA table_info(security_events)").all()
        let hasPrevHash = cols.contains { (try? $0.decode(column: "name", as: String.self)) == "prev_hash" }
        let hasEventHash = cols.contains { (try? $0.decode(column: "name", as: String.self)) == "event_hash" }
        if !hasPrevHash {
            try await sql.raw("ALTER TABLE security_events ADD COLUMN prev_hash TEXT").run()
        }
        if !hasEventHash {
            try await sql.raw("ALTER TABLE security_events ADD COLUMN event_hash TEXT").run()
        }
        try await sql.raw("CREATE INDEX IF NOT EXISTS idx_security_events_hash ON security_events (event_hash)").run()
    }

    func revert(on db: Database) async throws { }
}

private func sha256Hex(_ input: String) -> String {
    let digest = SHA256.hash(data: Data(input.utf8))
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func securityEventLogPath() -> String {
    Environment.get("SECURITY_EVENT_LOG_PATH") ?? "/var/log/netmap/security_events.log"
}

private func securityEventRetentionDays() -> Int {
    let raw = Int(Environment.get("SECURITY_EVENT_RETENTION_DAYS") ?? "") ?? 90
    return max(0, raw)
}

private func appendSecurityEventLog(path: String, line: String, logger: Logger) {
    let url = URL(fileURLWithPath: path)
    do {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = Data((line + "\n").utf8)
        if !FileManager.default.fileExists(atPath: path) {
            try data.write(to: url, options: [.atomic])
            return
        }
        if #available(macOS 10.15.4, *) {
            let fh = try FileHandle(forWritingTo: url)
            defer { try? fh.close() }
            try fh.seekToEnd()
            try fh.write(contentsOf: data)
        } else {
            let fh = FileHandle(forWritingAtPath: path)!
            defer { fh.closeFile() }
            fh.seekToEndOfFile()
            fh.write(data)
        }
    } catch {
        logger.warning("Failed to append security event file log at \(path): \(error.localizedDescription)")
    }
}

extension Request {
    /// Best-effort audit append; never throws to avoid breaking the primary operation path.
    func auditSecurityEvent(
        action: String,
        targetType: String? = nil,
        targetID: String? = nil,
        metadata: [String: String] = [:]
    ) async {
        let now = Date()
        let payload: String?
        if metadata.isEmpty {
            payload = nil
        } else {
            if let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) {
                payload = String(data: data, encoding: .utf8)
            } else {
                payload = nil
            }
        }
        let prevHash: String?
        do {
            prevHash = try await SecurityEvent.query(on: self.db)
                .sort(\.$createdAt, .descending)
                .first()?
                .eventHash
        } catch {
            prevHash = nil
        }
        let ts = ISO8601DateFormatter().string(from: now)
        let hashInput = [
            prevHash ?? "",
            action,
            ts,
            targetType ?? "",
            targetID ?? "",
            payload ?? "",
            self.remoteAddress?.ipAddress ?? "",
            self.authUser?.email ?? ""
        ].joined(separator: "|")
        let eventHash = sha256Hex(hashInput)
        let event = SecurityEvent(
            actor: self.authUser,
            action: action,
            targetType: targetType,
            targetID: targetID,
            metadataJSON: payload,
            ipAddress: self.remoteAddress?.ipAddress,
            prevHash: prevHash,
            eventHash: eventHash
        )
        event.createdAt = now
        do {
            try await event.save(on: self.db)
            let encoded = [
                "created_at": ts,
                "action": action,
                "actor_email": self.authUser?.email ?? "",
                "target_type": targetType ?? "",
                "target_id": targetID ?? "",
                "ip_address": self.remoteAddress?.ipAddress ?? "",
                "metadata_json": payload ?? "",
                "prev_hash": prevHash ?? "",
                "event_hash": eventHash
            ]
            if let data = try? JSONSerialization.data(withJSONObject: encoded, options: [.sortedKeys]),
               let line = String(data: data, encoding: .utf8) {
                appendSecurityEventLog(path: securityEventLogPath(), line: line, logger: self.logger)
            }
        } catch {
            self.logger.warning("Failed to append security event: \(error.localizedDescription)")
        }
    }
}

struct SecurityEventRetentionLifecycle: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        let retentionDays = securityEventRetentionDays()
        guard retentionDays > 0 else {
            application.logger.info("SecurityEventRetention disabled (SECURITY_EVENT_RETENTION_DAYS=0)")
            return
        }
        Task {
            await purge(application, retentionDays: retentionDays)
            while true {
                do { try await Task.sleep(nanoseconds: 86_400_000_000_000) } catch { return }
                await purge(application, retentionDays: retentionDays)
            }
        }
    }

    private func purge(_ app: Application, retentionDays: Int) async {
        let cutoff = Date().addingTimeInterval(TimeInterval(-retentionDays * 86_400))
        do {
            let count = try await SecurityEvent.query(on: app.db)
                .filter(\.$createdAt < cutoff)
                .count()
            guard count > 0 else { return }
            try await SecurityEvent.query(on: app.db)
                .filter(\.$createdAt < cutoff)
                .delete()
            app.logger.info("SecurityEventRetention: purged \(count) event(s) older than \(retentionDays) day(s)")
        } catch {
            app.logger.error("SecurityEventRetention error: \(error)")
        }
    }
}
