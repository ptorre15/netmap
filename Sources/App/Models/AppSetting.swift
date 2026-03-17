import Vapor
import Fluent

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

extension Application {
    /// The active X-API-Key used to protect sensor-write endpoints.
    /// Initialised from DB (persisted override) → env var API_KEY → default "netmap-dev".
    var currentAPIKey: String {
        get { storage[APIKeyStorageKey.self] ?? "netmap-dev" }
        set { storage[APIKeyStorageKey.self] = newValue }
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
