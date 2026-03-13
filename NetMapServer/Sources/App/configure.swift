import Vapor
import Fluent
import FluentSQLiteDriver

// Single source of truth for the server version, read from NetMapServer/VERSION at startup.
extension Application {
    private struct ServerVersionKey: StorageKey { typealias Value = String }
    var serverVersion: String {
        get { storage[ServerVersionKey.self] ?? "unknown" }
        set { storage[ServerVersionKey.self] = newValue }
    }
}

public func configure(_ app: Application) async throws {

    // ── Server version (read from VERSION file, single source of truth) ───
    let versionPath = app.directory.workingDirectory + "VERSION"
    app.serverVersion = (try? String(contentsOfFile: versionPath, encoding: .utf8))
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? "unknown"

    // ── TCP Port (override with PORT env var) ────────────────────────────
    let port = Int(Environment.get("PORT") ?? "") ?? 8092
    app.http.server.configuration.port     = port
    // Bind to localhost only — TLS is handled by nginx reverse proxy.
    // Set BIND_HOST=0.0.0.0 env var to expose directly (dev/debug only).
    app.http.server.configuration.hostname = Environment.get("BIND_HOST") ?? "127.0.0.1"

    // ── ISO-8601 JSON dates ──────────────────────────────────────────────
    // Custom decoder that also accepts fractional seconds (e.g. JS toISOString() → "2026-03-10T20:57:18.123Z")
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let dec = JSONDecoder()
    dec.dateDecodingStrategy = .custom { decoder in
        let s = try decoder.singleValueContainer().decode(String.self)
        let fmtFrac = ISO8601DateFormatter()
        fmtFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fmtFrac.date(from: s) { return d }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        if let d = fmt.date(from: s) { return d }
        throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(),
            debugDescription: "Cannot decode date: \(s)")
    }
    ContentConfiguration.global.use(encoder: enc, for: .json)
    ContentConfiguration.global.use(decoder: dec, for: .json)
    // Global request body cap to reduce DoS risk from oversized payloads.
    app.routes.defaultMaxBodySize = "1mb"

    // ── Static files from Public/ (serves index.html at /) ──────────────
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory, defaultFile: "index.html"))

    // ── SQLite (file path override with DB_PATH env var) ─────────────────
    let dbPath = Environment.get("DB_PATH") ?? "netmap_data.db"
    app.databases.use(.sqlite(.file(dbPath)), as: .sqlite)

    // ── Migrations ───────────────────────────────────────────────────────
    app.migrations.add(CreateSensorReading())
    app.migrations.add(CreateTrackerConfig())
    app.migrations.add(CreateUser())
    app.migrations.add(CreateUserToken())
    app.migrations.add(CreateLoginAttemptBucket())
    app.migrations.add(CreateVehicle())
    app.migrations.add(CreateAppSetting())
    app.migrations.add(CreateSecurityEvent())
    app.migrations.add(AddSecurityEventHashChain())
    app.migrations.add(MigrateUsernameToEmail())
    app.migrations.add(CreateAssetType())
    app.migrations.add(AddAssetFieldsToVehicle())
    app.migrations.add(AddIconKeyToVehicle())
    app.migrations.add(CreateUserAsset())
    app.migrations.add(AddSensorBatteryFields())   // pressure_bar nullable + battery_pct + charge_state
    app.migrations.add(AddSensorDetailFields())    // health_pct + charging_cycles + product_variant
    app.migrations.add(AddTotalSecondsField())      // total operating / discharge time
    app.migrations.add(AddGpsSatellitesField())     // GPS tracker: satellites in view
    app.migrations.add(CreateVehicleEvent())        // vehicle telemetry events (journey_start / driving / journey_end)
    app.migrations.add(MigrateVehicleEventSensorIDToIMEI()) // imei + sensor_name sur vehicle_events (migration depuis sensor_id)
    app.migrations.add(AddDriverIdAndJourneyFuelToVehicleEvent()) // driver_id + journey_fuel_consumed_l
    app.migrations.add(AddGpsSatellitesToVehicleEvents())         // gps_satellites on vehicle_events
    app.migrations.add(CreateDriverBehaviorEvent())               // driver behavior alerts (separate table)
    app.migrations.add(CreateDeviceLifecycleEvent())              // device power lifecycle events (boot/sleep/wake_up)
    app.migrations.add(AddVehicleEventIndexes())                  // idx_ve_imei_ts + idx_ve_journey (README_JOURNEY_API.md)
    app.migrations.add(AddGpsFixTypeToVehicleEvents())            // gps_fix_type on vehicle_events (spec v6)
    app.migrations.add(AddTelemetryToDriverBehaviorEvents())      // odometer/fuel/rpm/gps telemetry snapshot on driver_behavior_events
    app.migrations.add(AddLoadEstimationToVehicleEvents())        // load_confidence/samples/m_total_kg/m_load_kg on vehicle_events
    app.migrations.add(AddGpsToDeviceLifecycleEvents())           // GPS fields + gps_fix_type on device_lifecycle_events (spec v6)
    app.migrations.add(AddLastAppliedConfigVersion())             // last_applied_config_version on tracker_configs
    app.migrations.add(AddTelemetryCompositeIndexes())            // composite telemetry indexes for hot filters
    app.migrations.add(CreateDeviceJourneyStats())                // journey_stats device counters (spec v6)
    try await app.autoMigrate()   // non-blocking in async context

    // ── Seed built-in asset types if absent ─────────────────────
    let builtIns: [(slug: String, name: String, img: String, brands: String)] = [
        ("vehicle", "Vehicle", "car.fill",                    "michelin,airtag,ela"),
        ("tool",    "Tool",    "wrench.and.screwdriver.fill", "airtag,ela,stihl"),
    ]
    for bi in builtIns {
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

    // ── Normalise vehicles.asset_type_id so iOS slugs always match ───────
    // Built-in asset types get random UUIDs on first seed.
    // Any vehicle whose asset_type_id is one of those UUIDs must be
    // rewritten to the canonical slug ("vehicle", "tool", …) so the iOS
    // app — which uses slug IDs — can display them correctly.
    let allBuiltInTypes = try await AssetTypeModel.query(on: app.db)
        .filter(\.$isBuiltIn == true).all()
    if let sql = app.db as? SQLDatabase {
        for t in allBuiltInTypes {
            guard let uuid = t.id else { continue }
            let slug = t.name.lowercased()
            try await sql.raw("""
                UPDATE vehicles SET asset_type_id = \(bind: slug)
                WHERE asset_type_id = \(bind: uuid.uuidString)
                AND asset_type_id != \(bind: slug)
                """).run()
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

    // ── Safety check: refuse to start in production with the default key ─
    if app.environment == .production && app.currentAPIKey == "netmap-dev" {
        app.logger.critical("Refusing to start: default API key 'netmap-dev' must not be used in production. Set the API_KEY environment variable.")
        throw Abort(.internalServerError, reason: "Insecure default API key in production.")
    }

    // ── Periodic token cleanup ───────────────────────────────────────────
    app.lifecycle.use(TokenCleanupLifecycle())
    app.lifecycle.use(SecurityEventRetentionLifecycle())
    app.lifecycle.use(TelemetryIntegrityLifecycle())

    // ── Routes ───────────────────────────────────────────────────────────
    try routes(app)

    let bindHost = Environment.get("BIND_HOST") ?? "127.0.0.1"
    app.logger.info("NetMapServer listening on \(bindHost):\(port) — DB: \(dbPath)")
}
