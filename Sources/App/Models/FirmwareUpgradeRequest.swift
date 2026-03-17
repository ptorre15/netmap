import Vapor
import Fluent

/// Persistent audit log of every OTA firmware upgrade request made from the admin panel.
/// Status lifecycle: pending → delivered → completed | failed | cancelled
final class FirmwareUpgradeRequest: Model, Content, @unchecked Sendable {
    static let schema = "firmware_upgrade_requests"

    @ID(key: .id)                                    var id:            UUID?
    @Field(key: "imei")                              var imei:          String
    @Field(key: "target_version")                    var targetVersion: String
    @Field(key: "requested_by")                      var requestedBy:   String
    /// pending | delivered | completed | failed | cancelled
    @Field(key: "status")                            var status:        String
    @OptionalField(key: "notes")                     var notes:         String?
    @OptionalField(key: "completed_at")              var completedAt:   Date?
    @Timestamp(key: "created_at", on: .create)       var createdAt:     Date?
    @Timestamp(key: "updated_at", on: .update)       var updatedAt:     Date?

    init() {}

    init(id: UUID? = nil, imei: String, targetVersion: String,
         requestedBy: String, status: String = "pending", notes: String? = nil) {
        self.id            = id
        self.imei          = imei
        self.targetVersion = targetVersion
        self.requestedBy   = requestedBy
        self.status        = status
        self.notes         = notes
    }
}

struct CreateFirmwareUpgradeRequests: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(FirmwareUpgradeRequest.schema)
            .id()
            .field("imei",           .string,   .required)
            .field("target_version", .string,   .required)
            .field("requested_by",   .string,   .required)
            .field("status",         .string,   .required)
            .field("notes",          .string)
            .field("completed_at",   .datetime)
            .field("created_at",     .datetime)
            .field("updated_at",     .datetime)
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(FirmwareUpgradeRequest.schema).delete()
    }
}
