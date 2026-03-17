import Vapor
import Fluent

// MARK: - UserAsset — join table linking a user to an asset (vehicle)
// Admins implicitly see ALL assets; this table only affects non-admin users.

final class UserAsset: Model, Content, @unchecked Sendable {
    static let schema = "user_assets"

    @ID(key: .id)                              var id:        UUID?
    @Field(key: "user_id")                     var userID:    UUID
    @Field(key: "asset_id")                    var assetID:   UUID   // references vehicles.id
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(userID: UUID, assetID: UUID) {
        self.userID  = userID
        self.assetID = assetID
    }
}

// MARK: - Migration

struct CreateUserAsset: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(UserAsset.schema)
            .id()
            .field("user_id",    .uuid,     .required)
            .field("asset_id",   .uuid,     .required)
            .field("created_at", .datetime)
            .unique(on: "user_id", "asset_id")
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(UserAsset.schema).delete()
    }
}
