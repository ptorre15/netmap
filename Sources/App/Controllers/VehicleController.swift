import Vapor
import Fluent
import SQLKit

struct VehicleController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        // Legacy path kept for backward-compat with existing iOS app versions
        let api   = routes.grouped("api", "vehicles")
        // Canonical new path
        let assetApi = routes.grouped("api", "assets")
        let admin    = api.grouped(BearerAuthMiddleware(), AdminMiddleware())
        let adminA   = assetApi.grouped(BearerAuthMiddleware(), AdminMiddleware())

        // Authenticated reads — API key or Bearer; non-admin Bearer users see only their linked assets.
        let protectedRead  = api.grouped(APIKeyOrBearerMiddleware())
        let protectedReadA = assetApi.grouped(APIKeyOrBearerMiddleware())

        protectedRead.get(use: list)                          // GET  /api/vehicles
        protectedRead.get(":vehicleID", use: get)             // GET  /api/vehicles/:id
        protectedReadA.get(use: list)                         // GET  /api/assets
        protectedReadA.get(":vehicleID", use: get)            // GET  /api/assets/:id

        // Admin writes — /api/vehicles (legacy)
        admin.post(use: create)                    // POST   /api/vehicles
        admin.patch(":vehicleID", use: update)     // PATCH  /api/vehicles/:id
        admin.delete(":vehicleID", use: delete)    // DELETE /api/vehicles/:id
        // Admin writes — /api/assets (canonical)
        adminA.post(use: create)                   // POST   /api/assets
        adminA.patch(":vehicleID", use: update)    // PATCH  /api/assets/:id
        adminA.delete(":vehicleID", use: delete)   // DELETE /api/assets/:id
    }

    // MARK: - GET /api/vehicles  (or /api/assets)
    // Admins see all assets; authenticated non-admins see only their linked assets;
    // unauthenticated clients (API-key only) see all (for sensor data submission compatibility).

    func list(req: Request) async throws -> [Vehicle] {
        if let auth = req.authUser, !auth.isAdmin {
            let ids = try await UserAsset.query(on: req.db)
                .filter(\.$userID == auth.userID).all().map(\.assetID)
            return try await Vehicle.query(on: req.db)
                .filter(\.$id ~~ ids).sort(\.$name).all()
        }
        return try await Vehicle.query(on: req.db).sort(\.$name).all()
    }

    // MARK: - GET /api/vehicles/:id

    func get(req: Request) async throws -> Vehicle {
        guard let id = req.parameters.get("vehicleID", as: UUID.self),
              let v  = try await Vehicle.find(id, on: req.db)
        else { throw Abort(.notFound) }
        // Non-admin: must be linked to this asset
        if let auth = req.authUser, !auth.isAdmin {
            let linked = try await UserAsset.query(on: req.db)
                .filter(\.$userID == auth.userID)
                .filter(\.$assetID == id).count() > 0
            guard linked else { throw Abort(.forbidden) }
        }
        return v
    }

    // MARK: - POST

    func create(req: Request) async throws -> Vehicle {
        let p    = try req.content.decode(VehiclePayload.self)
        let name = p.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw Abort(.badRequest, reason: "Asset name is required") }
        let duplicate = try await Vehicle.query(on: req.db).filter(\.$name == name).count() > 0
        guard !duplicate else { throw Abort(.conflict, reason: "An asset named \"\(name)\" already exists.") }
        let user = req.authUser!
        let v    = Vehicle(
            name:         name,
            assetTypeID:  p.assetTypeID ?? "vehicle",
            brand:        p.brand,
            modelName:    p.modelName,
            year:         p.year,
            vin:          p.vin,
            vrn:          p.vrn,
            serialNumber: p.serialNumber,
            toolType:     p.toolType,
            iconKey:      p.iconKey,
            createdBy:    user.email
        )
        try await v.save(on: req.db)
        return v
    }

    // MARK: - PATCH

    func update(req: Request) async throws -> Vehicle {
        guard let id = req.parameters.get("vehicleID", as: UUID.self),
              let v  = try await Vehicle.find(id, on: req.db)
        else { throw Abort(.notFound) }
        let p = try req.content.decode(VehiclePayload.self)
        let newName = p.name.trimmingCharacters(in: .whitespaces)
        if !newName.isEmpty && newName != v.name {
            let duplicate = try await Vehicle.query(on: req.db).filter(\.$name == newName).count() > 0
            guard !duplicate else { throw Abort(.conflict, reason: "An asset named \"\(newName)\" already exists.") }
            v.name = newName
        }
        if let t = p.assetTypeID { v.assetTypeID = t }
        v.brand        = p.brand
        v.modelName    = p.modelName
        v.year         = p.year
        v.vin          = p.vin
        v.vrn          = p.vrn
        v.serialNumber = p.serialNumber
        v.toolType     = p.toolType
        v.iconKey      = p.iconKey
        try await v.save(on: req.db)
        return v
    }

    // MARK: - DELETE

    func delete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("vehicleID", as: UUID.self),
              let v  = try await Vehicle.find(id, on: req.db)
        else { throw Abort(.notFound) }
        // All cascade deletes run inside a single transaction so a mid-delete failure
        // cannot leave the database in a partially-cleaned state.
        try await req.db.transaction { db in
            try await UserAsset.query(on: db).filter(\.$assetID == id).delete()
            try await SensorReading.query(on: db).filter(\.$vehicleID == id.uuidString).delete()
            if let sql = db as? SQLDatabase {
                let vid = id.uuidString
                try await sql.raw("DELETE FROM vehicle_events          WHERE vehicle_id = \(bind: vid)").run()
                try await sql.raw("DELETE FROM driver_behavior_events  WHERE vehicle_id = \(bind: vid)").run()
                try await sql.raw("DELETE FROM device_lifecycle_events WHERE vehicle_id = \(bind: vid)").run()
                try await sql.raw("DELETE FROM journey_stats_events    WHERE vehicle_id = \(bind: vid)").run()
            }
            try await v.delete(on: db)
        }
        return .noContent
    }
}
