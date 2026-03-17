import Vapor
import SQLKit

struct TelemetryIntegrityLifecycle: LifecycleHandler {
    func didBoot(_ application: Application) throws {
        let intervalSec = max(60, Int(Environment.get("TELEMETRY_INTEGRITY_INTERVAL_SEC") ?? "") ?? 900)
        let lookbackSec = max(60, Int(Environment.get("TELEMETRY_INTEGRITY_LOOKBACK_SEC") ?? "") ?? 900)

        Task {
            await runCheck(application, lookbackSec: lookbackSec)
            while true {
                do { try await Task.sleep(nanoseconds: UInt64(intervalSec) * 1_000_000_000) } catch { return }
                await runCheck(application, lookbackSec: lookbackSec)
            }
        }
    }

    private func runCheck(_ app: Application, lookbackSec: Int) async {
        guard let sql = app.db as? SQLDatabase else { return }
        let cutoff = Date().addingTimeInterval(TimeInterval(-lookbackSec)).timeIntervalSince1970
        struct Counts: Decodable {
            var ve_count: Int
            var dbe_count: Int
            var dle_count: Int
            var tracker_sr_count: Int
            var ve_without_sr_imei: Int
        }

        do {
            let rows = try await sql.raw("""
                SELECT
                    (SELECT COUNT(*) FROM vehicle_events WHERE received_at >= \(bind: cutoff)) AS ve_count,
                    (SELECT COUNT(*) FROM driver_behavior_events WHERE received_at >= \(bind: cutoff)) AS dbe_count,
                    (SELECT COUNT(*) FROM device_lifecycle_events WHERE received_at >= \(bind: cutoff)) AS dle_count,
                    (SELECT COUNT(*) FROM sensor_readings WHERE brand = 'tracker' AND received_at >= \(bind: cutoff)) AS tracker_sr_count,
                    (
                        SELECT COUNT(DISTINCT ve.imei)
                        FROM vehicle_events ve
                        WHERE ve.imei IS NOT NULL
                          AND ve.imei != ''
                          AND ve.received_at >= \(bind: cutoff)
                          AND NOT EXISTS (
                              SELECT 1
                              FROM sensor_readings sr
                              WHERE sr.sensor_id = ve.imei
                                AND sr.brand = 'tracker'
                                AND sr.received_at >= \(bind: cutoff)
                          )
                    ) AS ve_without_sr_imei
                """).all(decoding: Counts.self)

            guard let c = rows.first else { return }
            app.logger.info("[integrity.telemetry] lookback_sec=\(lookbackSec) ve=\(c.ve_count) dbe=\(c.dbe_count) dle=\(c.dle_count) tracker_sr=\(c.tracker_sr_count) ve_without_sr_imei=\(c.ve_without_sr_imei)")
        } catch {
            app.logger.warning("[integrity.telemetry] check failed: \(error.localizedDescription)")
        }
    }
}
