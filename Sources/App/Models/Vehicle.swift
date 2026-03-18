import Vapor
import Fluent
import SQLKit

// MARK: - Asset model (server-authoritative registry)
// Renamed from "Vehicle" to "Asset" at the app level, but the DB schema/table stays
// "vehicles" for backward compatibility with existing sensor readings.

final class Vehicle: Model, Content, @unchecked Sendable {
    static let schema = "vehicles"

    @ID(key: .id)                              var id:            UUID?
    @Field(key: "name")                        var name:          String
    // Asset type — matches AssetType.id in the iOS app ("vehicle", "tool", custom UUID)
    @Field(key: "asset_type_id")               var assetTypeID:   String
    // Vehicle-specific
    @OptionalField(key: "brand")               var brand:         String?
    @OptionalField(key: "model_name")          var modelName:     String?
    @OptionalField(key: "year")                var year:          Int?
    @OptionalField(key: "vin")                 var vin:           String?
    @OptionalField(key: "vrn")                 var vrn:           String?
    // Tool-specific
    @OptionalField(key: "serial_number")       var serialNumber:  String?
    @OptionalField(key: "tool_type")           var toolType:      String?
    // Pictogram key (e.g. "car", "suv", "hgv", "bike", …)
    @OptionalField(key: "icon_key")            var iconKey:       String?
    // Metadata
    @Field(key: "created_by")                  var createdBy:     String
    @Timestamp(key: "created_at", on: .create) var createdAt:     Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt:     Date?
    @Timestamp(key: "deleted_at", on: .delete) var deletedAt:     Date?

    init() {}

    init(name: String, assetTypeID: String = "vehicle",
         brand: String? = nil, modelName: String? = nil, year: Int? = nil,
         vin: String? = nil, vrn: String? = nil,
         serialNumber: String? = nil, toolType: String? = nil,
         iconKey: String? = nil,
         createdBy: String) {
        self.name         = name
        self.assetTypeID  = assetTypeID
        self.brand        = brand
        self.modelName    = modelName
        self.year         = year
        self.vin          = vin
        self.vrn          = vrn
        self.serialNumber = serialNumber
        self.toolType     = toolType
        self.iconKey      = iconKey
        self.createdBy    = createdBy
    }
}

// MARK: - DTO (create / update payload)

struct VehiclePayload: Content {
    var name:         String
    var assetTypeID:  String?      // defaults to "vehicle" if absent
    var brand:        String?
    var modelName:    String?
    var year:         Int?
    var vin:          String?
    var vrn:          String?
    var serialNumber: String?
    var toolType:     String?
    var iconKey:      String?
}

// MARK: - Initial migration (original schema)

struct CreateVehicle: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(Vehicle.schema)
            .id()
            .field("name",       .string, .required)
            .field("brand",      .string)
            .field("model_name", .string)
            .field("year",       .int)
            .field("vin",        .string)
            .field("vrn",        .string)
            .field("created_by", .string, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }
    func revert(on db: Database) async throws {
        try await db.schema(Vehicle.schema).delete()
    }
}

// MARK: - Add asset fields migration (v2)

struct AddAssetFieldsToVehicle: AsyncMigration {
    func prepare(on db: Database) async throws {
        // Use raw SQL so we can set NOT NULL DEFAULT, which Fluent schema builder doesn't support
        guard let sql = db as? SQLDatabase else {
            // Fallback for non-SQLite (no NOT NULL default without raw SQL)
            try await db.schema(Vehicle.schema)
                .field("asset_type_id", .string)
                .field("serial_number", .string)
                .field("tool_type",     .string)
                .update()
            return
        }
        // SQLite: ADD COLUMN with DEFAULT fills all existing rows correctly
        try await sql.raw("ALTER TABLE vehicles ADD COLUMN asset_type_id TEXT NOT NULL DEFAULT 'vehicle'").run()
        try await sql.raw("ALTER TABLE vehicles ADD COLUMN serial_number TEXT").run()
        try await sql.raw("ALTER TABLE vehicles ADD COLUMN tool_type TEXT").run()
    }
    func revert(on db: Database) async throws {
        // SQLite does not support DROP COLUMN in all versions — no-op
    }
}

// MARK: - Add icon_key column migration (v3)

struct AddIconKeyToVehicle: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else {
            try await db.schema(Vehicle.schema).field("icon_key", .string).update()
            return
        }
        try await sql.raw("ALTER TABLE vehicles ADD COLUMN icon_key TEXT").run()
    }
    func revert(on db: Database) async throws {
        // SQLite: no DROP COLUMN — no-op
    }
}

// MARK: - Add soft-delete support migration (v4)

struct AddSoftDeleteToVehicle: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else {
            try await db.schema(Vehicle.schema).field("deleted_at", .datetime).update()
            return
        }
        // try? is intentional: idempotent if the column was already added manually
        try? await sql.raw("ALTER TABLE vehicles ADD COLUMN deleted_at DATETIME").run()
    }
    func revert(on db: Database) async throws {
        // SQLite does not support DROP COLUMN in older versions — no-op
    }
}
