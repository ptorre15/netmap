import Vapor
import Fluent
import FluentSQLiteDriver

public func configure(_ app: Application) async throws {

    // ── TCP Port (override with PORT env var) ────────────────────────────
    let port = Int(Environment.get("PORT") ?? "") ?? 8765
    app.http.server.configuration.port     = port
    app.http.server.configuration.hostname = "0.0.0.0"

    // ── ISO-8601 JSON dates ──────────────────────────────────────────────
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
    ContentConfiguration.global.use(encoder: enc, for: .json)
    ContentConfiguration.global.use(decoder: dec, for: .json)

    // ── Static files from Public/ (serves index.html at /) ──────────────
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory, defaultFile: "index.html"))

    // ── SQLite (file path override with DB_PATH env var) ─────────────────
    let dbPath = Environment.get("DB_PATH") ?? "netmap_data.db"
    app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)

    // ── Migrations ───────────────────────────────────────────────────────
    app.migrations.add(CreateSensorReading())
    app.migrations.add(CreateUser())
    app.migrations.add(CreateUserToken())
    app.migrations.add(CreateVehicle())
    app.migrations.add(CreateAppSetting())
    app.migrations.add(MigrateUsernameToEmail())
    app.migrations.add(CreateAssetType())
    app.migrations.add(AddAssetFieldsToVehicle())
    app.migrations.add(CreateUserAsset())
    app.migrations.add(AddSensorBatteryFields())   // pressure_bar nullable + battery_pct + charge_state
    app.migrations.add(AddSensorDetailFields())    // health_pct + charging_cycles + product_variant
    app.migrations.add(AddTotalSecondsField())      // total operating / discharge time
    try await app.autoMigrate()   // non-blocking in async context

    // ── Seed built-in asset types if absent ─────────────────────
    let builtIns: [(id: String, name: String, img: String, brands: String)] = [
        ("vehicle", "Vehicle",  "car.fill",                        "michelin,airtag,ela"),
        ("tool",    "Tool",     "wrench.and.screwdriver.fill",     "airtag,ela,stihl"),
    ]
    for bi in builtIns {
        guard let uuid = UUID(uuidString: bi.id) ?? Optional(UUID()) else { continue }
        // Use a stable deterministic UUID derived from the name so re-seeding is idempotent.
        // We just look up by name + isBuiltIn.
        let exists = try await AssetTypeModel.query(on: app.db)
            .filter(\.$name == bi.name)
            .filter(\.$isBuiltIn == true)
            .first()
        if exists == nil {
            let t = AssetTypeModel(
                name:          bi.name,
                systemImage:   bi.img,
                allowedBrands: bi.brands.split(separator: ",").map(String.init),
                isBuiltIn:     true,
                createdBy:     "system"
            )
            try await t.save(on: app.db)
            app.logger.info("Seeded built-in asset type: \(bi.name)")
        }
    }

    // ── Load API key (DB override > env var > dev default) ───────────────
    let envKey = Environment.get("API_KEY") ?? "netmap-dev"
    if let stored = try? await AppSetting.query(on: app.db).filter(\.$key == "api_key").first() {
        app.currentAPIKey = stored.value
        app.logger.info("API key loaded from database.")
    } else {
        app.currentAPIKey = envKey
        if envKey == "netmap-dev" {
            app.logger.warning("Using default API key 'netmap-dev'. Set API_KEY env var for production.")
        }
    }

    // ── Periodic token cleanup ───────────────────────────────────────────
    app.lifecycle.use(TokenCleanupLifecycle())

    // ── Routes ───────────────────────────────────────────────────────────
    try routes(app)

    app.logger.info("NetMapServer listening on 0.0.0.0:\(port) — DB: \(dbPath)")
}
