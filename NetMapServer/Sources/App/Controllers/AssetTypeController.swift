import Vapor
import Fluent

struct AssetTypeController: RouteCollection {

    func boot(routes: RoutesBuilder) throws {
        let api   = routes.grouped("api", "asset-types")
        let admin = api.grouped(BearerAuthMiddleware(), AdminMiddleware())

        api.grouped(APIKeyOrBearerMiddleware()).get(use: list) // GET  /api/asset-types
        admin.post(use: create)                     // POST /api/asset-types  (admin)
        admin.patch(":typeID", use: update)         // PATCH /api/asset-types/:id  (admin)
        admin.delete(":typeID", use: delete)        // DELETE /api/asset-types/:id (admin, non-built-in)
    }

    // MARK: GET /api/asset-types

    func list(req: Request) async throws -> [AssetTypeResponse] {
        let types = try await AssetTypeModel.query(on: req.db)
            .sort(\.$name)
            .all()
        return types.map { $0.toResponse() }
    }

    // MARK: POST /api/asset-types

    func create(req: Request) async throws -> AssetTypeResponse {
        let p = try req.content.decode(AssetTypePayload.self)
        guard !p.name.trimmingCharacters(in: .whitespaces).isEmpty
        else { throw Abort(.badRequest, reason: "Name is required") }
        guard !p.allowedBrands.isEmpty
        else { throw Abort(.badRequest, reason: "At least one allowed brand is required") }

        let user = req.authUser!
        let t = AssetTypeModel(
            name:          p.name,
            systemImage:   p.systemImage.isEmpty ? "questionmark.app" : p.systemImage,
            allowedBrands: p.allowedBrands,
            isBuiltIn:     false,
            createdBy:     user.email
        )
        try await t.save(on: req.db)
        return t.toResponse()
    }

    // MARK: PATCH /api/asset-types/:id

    func update(req: Request) async throws -> AssetTypeResponse {
        guard let id = req.parameters.get("typeID", as: UUID.self),
              let t  = try await AssetTypeModel.find(id, on: req.db)
        else { throw Abort(.notFound) }
        guard !t.isBuiltIn else { throw Abort(.forbidden, reason: "Built-in types cannot be modified") }

        let p = try req.content.decode(AssetTypePayload.self)
        if !p.name.trimmingCharacters(in: .whitespaces).isEmpty { t.name = p.name }
        if !p.systemImage.isEmpty                               { t.systemImage = p.systemImage }
        if !p.allowedBrands.isEmpty                            { t.allowedBrands = p.allowedBrands.joined(separator: ",") }
        try await t.save(on: req.db)
        return t.toResponse()
    }

    // MARK: DELETE /api/asset-types/:id

    func delete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("typeID", as: UUID.self),
              let t  = try await AssetTypeModel.find(id, on: req.db)
        else { throw Abort(.notFound) }
        guard !t.isBuiltIn else { throw Abort(.forbidden, reason: "Built-in types cannot be deleted") }
        try await t.delete(on: req.db)
        return .noContent
    }
}
