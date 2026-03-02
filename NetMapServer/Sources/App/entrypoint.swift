import Vapor

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
        try LoggingSystem.bootstrap(from: &env)

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
