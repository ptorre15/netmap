import Vapor
import Fluent

final class TrackerConfig: Model, @unchecked Sendable {
    static let schema = "tracker_configs"

    @ID(key: .id)                              var id: UUID?
    @Field(key: "schema_version")              var schemaVersion: Int
    @Field(key: "imei")                        var imei: String

    // system
    @Field(key: "ping_interval_min")           var pingIntervalMin: Int
    @Field(key: "sleep_delay_min")             var sleepDelayMin: Int
    @Field(key: "wake_up_sources_json")        var wakeUpSourcesJSON: String

    // driver behavior
    @Field(key: "th_harsh_braking")            var thresholdHarshBraking: Double
    @Field(key: "th_harsh_acceleration")       var thresholdHarshAcceleration: Double
    @Field(key: "th_harsh_cornering")          var thresholdHarshCornering: Double
    @Field(key: "th_overspeed_kmh")            var thresholdOverspeedKmh: Double
    @Field(key: "minimum_speed_kmh")           var minimumSpeedKmh: Int
    @Field(key: "beep_enabled")                var beepEnabled: Bool

    @OptionalField(key: "last_applied_config_version") var lastAppliedConfigVersion: Int?
    @OptionalField(key: "firmware_version")    var firmwareVersion: String?
    @OptionalField(key: "updated_by")          var updatedBy: String?
    @OptionalField(key: "profile_id")          var profileID: UUID?       // last applied TrackerConfigProfile
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

struct AddFirmwareVersionToTrackerConfig: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(TrackerConfig.schema)
            .field("firmware_version", .string)
            .update()
    }
    func revert(on db: Database) async throws {
        try await db.schema(TrackerConfig.schema)
            .deleteField("firmware_version")
            .update()
    }
}

struct AddLastAppliedConfigVersion: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(TrackerConfig.schema)
            .field("last_applied_config_version", .int)
            .update()
    }
    func revert(on db: Database) async throws {
        try await db.schema(TrackerConfig.schema)
            .deleteField("last_applied_config_version")
            .update()
    }
}

struct AddProfileIDToTrackerConfig: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(TrackerConfig.schema)
            .field("profile_id", .uuid)
            .update()
    }
    func revert(on db: Database) async throws {
        try await db.schema(TrackerConfig.schema)
            .deleteField("profile_id")
            .update()
    }
}

struct CreateTrackerConfig: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(TrackerConfig.schema)
            .id()
            .field("schema_version", .int, .required)
            .field("imei", .string, .required)
            .unique(on: "imei")
            .field("ping_interval_min", .int, .required)
            .field("sleep_delay_min", .int, .required)
            .field("wake_up_sources_json", .string, .required)
            .field("th_harsh_braking", .double, .required)
            .field("th_harsh_acceleration", .double, .required)
            .field("th_harsh_cornering", .double, .required)
            .field("th_overspeed_kmh", .double, .required)
            .field("minimum_speed_kmh", .int, .required)
            .field("beep_enabled", .bool, .required)
            .field("updated_by", .string)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(TrackerConfig.schema).delete()
    }
}
