import Vapor
import Fluent

// MARK: - AssetType model (admin-managed asset categories)

final class AssetTypeModel: Model, Content, @unchecked Sendable {
    static let schema = "asset_types"

    @ID(key: .id)                               var id:            UUID?
    @Field(key: "name")                         var name:          String
    @Field(key: "system_image")                 var systemImage:   String
    @Field(key: "allowed_brands")               var allowedBrands: String   // comma-separated
    @Field(key: "is_built_in")                  var isBuiltIn:     Bool
    @Field(key: "created_by")                   var createdBy:     String
    @Timestamp(key: "created_at", on: .create)  var createdAt:     Date?
    @Timestamp(key: "updated_at", on: .update)  var updatedAt:     Date?

    init() {}

    init(id: UUID? = nil, name: String, systemImage: String,
         allowedBrands: [String], isBuiltIn: Bool, createdBy: String) {
        self.id            = id
        self.name          = name
        self.systemImage   = systemImage
        self.allowedBrands = allowedBrands.joined(separator: ",")
        self.isBuiltIn     = isBuiltIn
        self.createdBy     = createdBy
    }
}

// MARK: - DTO

struct AssetTypePayload: Content {
    var name:          String
    var systemImage:   String
    var allowedBrands: [String]   // e.g. ["tpms","airtag","ela"]
}

struct AssetTypeResponse: Content {
    var id:            String
    var name:          String
    var systemImage:   String
    var allowedBrands: [String]
    var isBuiltIn:     Bool
}

extension AssetTypeModel {
    func toResponse() -> AssetTypeResponse {
        // Built-in types use their name slug ("vehicle", "tool") as canonical ID —
        // this matches the iOS app's compiled-in AssetType constants.
        let resolvedID = isBuiltIn ? name.lowercased() : (self.id?.uuidString ?? "")
        return AssetTypeResponse(
            id:            resolvedID,
            name:          name,
            systemImage:   systemImage,
            allowedBrands: allowedBrands.split(separator: ",").map(String.init),
            isBuiltIn:     isBuiltIn
        )
    }
}

// MARK: - Migration

struct CreateAssetType: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(AssetTypeModel.schema)
            .id()
            .field("name",           .string, .required)
            .field("system_image",   .string, .required)
            .field("allowed_brands", .string, .required)
            .field("is_built_in",    .bool,   .required)
            .field("created_by",     .string, .required)
            .field("created_at",     .datetime)
            .field("updated_at",     .datetime)
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(AssetTypeModel.schema).delete()
    }
}
