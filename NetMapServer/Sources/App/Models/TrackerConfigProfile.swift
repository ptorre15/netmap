import Vapor
import Fluent
import SQLKit

/// A reusable named configuration template that can be stamped onto any tracker.
final class TrackerConfigProfile: Model, @unchecked Sendable {
    static let schema = "tracker_config_profiles"

    @ID(key: .id)                              var id: UUID?
    @Field(key: "name")                        var name: String
    @OptionalField(key: "description")         var description: String?

    // system
    @Field(key: "ping_interval_min")           var pingIntervalMin: Int
    @Field(key: "sleep_delay_min")             var sleepDelayMin: Int
    @Field(key: "wake_up_sources_json")        var wakeUpSourcesJSON: String

    // driver behavior thresholds
    @Field(key: "th_harsh_braking")            var thresholdHarshBraking: Double
    @Field(key: "th_harsh_acceleration")       var thresholdHarshAcceleration: Double
    @Field(key: "th_harsh_cornering")          var thresholdHarshCornering: Double
    @Field(key: "th_overspeed_kmh")            var thresholdOverspeedKmh: Double
    @Field(key: "minimum_speed_kmh")           var minimumSpeedKmh: Int
    @Field(key: "beep_enabled")                var beepEnabled: Bool

    @OptionalField(key: "version")             var version: Int?       // increments on each profile update; 1-based

    @OptionalField(key: "created_by")          var createdBy: String?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

struct AddVersionToTrackerConfigProfile: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(TrackerConfigProfile.schema)
            .field("version", .int)
            .update()
        // Back-fill: existing profiles become v1
        if let sql = db as? SQLDatabase {
            try await sql.raw("UPDATE tracker_config_profiles SET version = 1 WHERE version IS NULL").run()
        }
    }
    func revert(on db: Database) async throws {
        try await db.schema(TrackerConfigProfile.schema)
            .deleteField("version")
            .update()
    }
}

struct CreateTrackerConfigProfile: AsyncMigration {
    func prepare(on db: Database) async throws {
        try await db.schema(TrackerConfigProfile.schema)
            .id()
            .field("name",                  .string,   .required)
            .field("description",           .string)
            .field("ping_interval_min",     .int,      .required)
            .field("sleep_delay_min",       .int,      .required)
            .field("wake_up_sources_json",  .string,   .required)
            .field("th_harsh_braking",      .double,   .required)
            .field("th_harsh_acceleration", .double,   .required)
            .field("th_harsh_cornering",    .double,   .required)
            .field("th_overspeed_kmh",      .double,   .required)
            .field("minimum_speed_kmh",     .int,      .required)
            .field("beep_enabled",          .bool,     .required)
            .field("created_by",            .string)
            .field("created_at",            .datetime)
            .field("updated_at",            .datetime)
            .create()
    }

    func revert(on db: Database) async throws {
        try await db.schema(TrackerConfigProfile.schema).delete()
    }
}
