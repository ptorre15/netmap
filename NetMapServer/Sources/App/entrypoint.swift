import Vapor
import Logging

// ── In-memory ring buffer — stores the last 500 log lines ────────────────────
public actor LogBuffer {
    public static let shared = LogBuffer()
    public struct Entry: Sendable { public let index: Int; public let text: String }
    private var buffer: [Entry] = []
    private var counter = 0
    private let maxLines = 500

    public func append(_ line: String) {
        counter += 1
        buffer.append(Entry(index: counter, text: line))
        if buffer.count > maxLines { buffer.removeFirst() }
    }

    public func entries(since: Int) -> [Entry] {
        buffer.filter { $0.index > since }
    }
}

// ── Timestamped log handler ──────────────────────────────────────────────────
private struct TimestampedLogHandler: LogHandler {
    let label: String
    var logLevel: Logger.Level = .info
    private var _metadata: Logger.Metadata = [:]

    init(label: String, logLevel: Logger.Level = .info) {
        self.label = label
        self.logLevel = logLevel
    }

    var metadata: Logger.Metadata {
        get { _metadata }
        set { _metadata = newValue }
    }
    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { _metadata[key] }
        set { _metadata[key] = newValue }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func log(level: Logger.Level, message: Logger.Message, metadata: Logger.Metadata?,
             source: String, file: String, function: String, line: UInt) {
        let ts      = Self.formatter.string(from: Date())
        let lvl     = level.rawValue.uppercased().padding(toLength: 8, withPad: " ", startingAt: 0)
        let merged  = _metadata.merging(metadata ?? [:]) { _, new in new }
        let metaStr = merged.isEmpty ? "" : " \(merged)"
        let entry   = "\(ts) \(lvl) [\(label)]\(metaStr) \(message)"
        print(entry)
        Task { await LogBuffer.shared.append(entry) }
    }
}

// Seeds an admin user from ADMIN_USERNAME / ADMIN_PASSWORD env if no users exist yet.
private func seedAdminIfNeeded(_ app: Application) async throws {
    guard
        let email    = Environment.get("ADMIN_USERNAME"),   // treated as email
        let password = Environment.get("ADMIN_PASSWORD")
    else { return }
    let count = try await User.query(on: app.db).count()
    guard count == 0 else { return }
    let hash = try Bcrypt.hash(password)
    let user = User(email: email, passwordHash: hash, role: "admin")
    try await user.save(on: app.db)
    app.logger.info("Admin '\(email)' seeded from environment.")
}

@main
struct Entrypoint {
    static func main() async throws {
        var env = try Environment.detect()
        // Resolve log level from --log argument or LOG_LEVEL env var (Vapor convention)
        let logLevel: Logger.Level
        if let raw = Environment.get("LOG_LEVEL"), let lvl = Logger.Level(rawValue: raw) {
            logLevel = lvl
        } else {
            logLevel = env.isRelease ? .notice : .info
        }
        LoggingSystem.bootstrap { label in
            TimestampedLogHandler(label: label, logLevel: logLevel)
        }

        let app = try await Application.make(env)

        do {
            try await configure(app)
            try await seedAdminIfNeeded(app)
        } catch {
            app.logger.report(error: error)
            try? await app.asyncShutdown()
            throw error
        }

        do {
            try await app.execute()
        } catch {
            let port = app.http.server.configuration.port
            // NIO bridge: IOError errno maps to NSError.code
            if (error as NSError).code == Int(EADDRINUSE) {
                app.logger.critical("Port \(port) is already in use. Stop the other process first, or set a different port via the PORT environment variable (e.g. PORT=8766 swift run App).")
            } else {
                app.logger.critical("Server failed to start: \(error)")
            }
        }

        try await app.asyncShutdown()
    }
}
