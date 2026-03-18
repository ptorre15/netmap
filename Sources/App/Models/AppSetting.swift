import Vapor
import Fluent
import Crypto

// MARK: - AppSetting model — key/value store for runtime configuration

final class AppSetting: Model, @unchecked Sendable {
    static let schema = "app_settings"

    @ID(key: .id)          var id:    UUID?
    @Field(key: "key")     var key:   String
    @Field(key: "value")   var value: String

    init() {}
    init(key: String, value: String) {
        self.key   = key
        self.value = value
    }
}

// MARK: - Migration

struct CreateAppSetting: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(AppSetting.schema)
            .id()
            .field("key",   .string, .required)
            .unique(on: "key")
            .field("value", .string, .required)
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(AppSetting.schema).delete()
    }
}

// MARK: - Application storage key for the active API key

private struct APIKeyStorageKey: StorageKey { typealias Value = String }
private struct APIKeyHashStorageKey: StorageKey { typealias Value = String }
private struct StartedAtKey: StorageKey { typealias Value = Date }

/// Produces a lowercase SHA-256 hex digest — used to store API keys at rest.
func sha256Hex(_ input: String) -> String {
    SHA256.hash(data: Data(input.utf8))
        .map { String(format: "%02x", $0) }.joined()
}

extension Application {
    /// The active X-API-Key in plaintext — available when loaded from env var or freshly rotated;
    /// empty string after a restart where the key was previously rotated (only hash is in DB).
    var currentAPIKey: String {
        get { storage[APIKeyStorageKey.self] ?? "" }
        set { storage[APIKeyStorageKey.self] = newValue }
    }

    /// SHA-256 hex hash of the active API key — always set; used for constant-time comparison.
    var currentAPIKeyHash: String {
        get { storage[APIKeyHashStorageKey.self] ?? "" }
        set { storage[APIKeyHashStorageKey.self] = newValue }
    }

    /// Returns true when `incoming` hashes to the stored API key hash.
    func isValidAPIKey(_ incoming: String) -> Bool {
        guard !incoming.isEmpty, !currentAPIKeyHash.isEmpty else { return false }
        return sha256Hex(incoming) == currentAPIKeyHash
    }

    /// Timestamp set at server boot — used for uptime reporting.
    var startedAt: Date {
        get { storage[StartedAtKey.self] ?? Date() }
        set { storage[StartedAtKey.self] = newValue }
    }
}

// MARK: - Periodic token cleanup lifecycle handler

struct TokenCleanupLifecycle: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        startBackground(application)
    }

    private func startBackground(_ app: Application) {
        Task {
            // Initial cleanup on startup
            await purge(app)
            // Then every hour
            while true {
                do { try await Task.sleep(nanoseconds: 3_600_000_000_000) } catch { return }
                await purge(app)
            }
        }
    }

    private func purge(_ app: Application) async {
        do {
            let n = try await UserToken.query(on: app.db)
                .filter(\.$expiresAt < Date())
                .count()
            if n > 0 {
                try await UserToken.query(on: app.db)
                    .filter(\.$expiresAt < Date())
                    .delete()
                app.logger.info("TokenCleanup: \(n) expired token(s) purged")
            }
        } catch {
            app.logger.error("TokenCleanup error: \(error)")
        }
    }
}
