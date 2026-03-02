import Vapor

func routes(_ app: Application) throws {

    // GET /health  — liveness probe
    app.get("health") { _ -> [String: String] in
        ["status": "ok", "server": "NetMapServer", "version": "1.0.0"]
    }

    // API key is loaded into app.currentAPIKey by configure.swift (DB > env > default).
    try app.register(collection: RecordController())
    try app.register(collection: AuthController())
    try app.register(collection: VehicleController())
    try app.register(collection: AdminController())
    try app.register(collection: AssetTypeController())
}
