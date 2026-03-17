import Fluent
import SQLKit

/// Adds composite indexes for frequent telemetry filtering patterns.
struct AddTelemetryCompositeIndexes: AsyncMigration {
    func prepare(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_sr_sensor_ts ON sensor_readings (sensor_id, timestamp)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_dbe_imei_ts ON driver_behavior_events (imei, timestamp)"
        ).run()
        try await sql.raw(
            "CREATE INDEX IF NOT EXISTS idx_dle_imei_ts ON device_lifecycle_events (imei, timestamp)"
        ).run()
    }

    func revert(on db: Database) async throws {
        guard let sql = db as? SQLDatabase else { return }
        try await sql.raw("DROP INDEX IF EXISTS idx_sr_sensor_ts").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_dbe_imei_ts").run()
        try await sql.raw("DROP INDEX IF EXISTS idx_dle_imei_ts").run()
    }
}
