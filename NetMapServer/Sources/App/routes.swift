import Vapor

func routes(_ app: Application) throws {

    // GET /health  — liveness probe
    app.get("health") { req -> [String: String] in
        ["status": "ok", "server": "NetMapServer", "version": req.application.serverVersion]
    }

    // WS /api/ws  — push notifications to authenticated browser clients.
    // The session cookie is checked as first message is not a handshake header;
    // authenticated via cookie (HttpOnly session, same as the dashboard REST calls).
    app.grouped(APIKeyOrBearerMiddleware()).webSocket("api", "ws") { req, ws in
        ws.onText { _, _ in }  // keep-alive / ping (client sends empty strings)
        ws.onClose.whenComplete { _ in }
        Task { await WebSocketBroadcaster.shared.add(ws) }
    }

    // API key is loaded into app.currentAPIKey by configure.swift (DB > env > default).
    try app.register(collection: RecordController())
    try app.register(collection: AuthController())
    try app.register(collection: VehicleController())
    try app.register(collection: AdminController())
    try app.register(collection: AssetTypeController())
    try app.register(collection: VehicleEventController())
    try app.register(collection: DriverBehaviorController())
    try app.register(collection: DeviceLifecycleController())
    try app.register(collection: JourneyStatsController())
}
