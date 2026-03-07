import XCTest
@testable import App
import Vapor
import XCTVapor

final class TelemetryRegressionTests: XCTestCase {
    private func withApp(_ test: (Application) async throws -> Void) async throws {
        let dbPath = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("netmap-tests-\(UUID().uuidString).sqlite")
            .path
        setenv("DB_PATH", dbPath, 1)
        setenv("API_KEY", "test-key", 1)
        let app = try await Application.make(.testing)
        do {
            try await configure(app)
            try await test(app)
            try await app.asyncShutdown()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try? FileManager.default.removeItem(atPath: dbPath)
    }

    func testNormalizeJourneyDistanceKm() {
        XCTAssertNil(normalizeJourneyDistanceKm(nil))
        XCTAssertEqual(normalizeJourneyDistanceKm(19.5) ?? -1, 19.5, accuracy: 0.0001)
        XCTAssertEqual(normalizeJourneyDistanceKm(2500.0) ?? -1, 2.5, accuracy: 0.0001)
    }

    func testTrackerPushAppearsInListAndSensorsLatest() async throws {
        try await withApp { app in
            let tester = try app.testable()
            let now = ISO8601DateFormatter().string(from: Date())
            let payload = """
            {
              "imei": "TEST-IMEI-001",
              "eventType": "driving",
              "timestamp": "\(now)",
              "latitude": 48.8566,
              "longitude": 2.3522,
              "speedKmh": 42.0,
              "journeyDistanceKm": 1200.0
            }
            """

            try await tester.test(.POST, "api/vehicle-events", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            })

            try await tester.test(.GET, "api/vehicle-events?imei=TEST-IMEI-001", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                XCTAssertEqual(json.count, 1)
                XCTAssertEqual(json.first?["imei"] as? String, "TEST-IMEI-001")
            })

            try await tester.test(.GET, "api/sensors/latest", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                let target = json.first { ($0["sensorID"] as? String) == "TEST-IMEI-001" }
                XCTAssertNotNil(target, "Tracker should appear in /api/sensors/latest")
            })
        }
    }

    func testDriverBehaviorStoredInDedicatedEndpoint() async throws {
        try await withApp { app in
            let tester = try app.testable()
            let now = ISO8601DateFormatter().string(from: Date())
            let payload = """
            {
              "imei": "TEST-IMEI-DBE-001",
              "eventType": "driver_behavior",
              "timestamp": "\(now)",
              "driverBehaviorType": 2,
              "alertValueMax": 3.4,
              "alertDurationMs": 1200,
              "speedKmh": 51.0
            }
            """

            try await tester.test(.POST, "api/vehicle-events", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            })

            try await tester.test(.GET, "api/driver-behavior?imei=TEST-IMEI-DBE-001", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                XCTAssertEqual(json.count, 1)
                XCTAssertEqual(json.first?["alertTypeInt"] as? Int, 2)
            })

            try await tester.test(.GET, "api/vehicle-events?imei=TEST-IMEI-DBE-001", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                XCTAssertEqual(json.count, 0, "driver_behavior should not be stored in vehicle_events")
            })
        }
    }

    func testLifecycleEventStoredInDedicatedEndpoint() async throws {
        try await withApp { app in
            let tester = try app.testable()
            let now = ISO8601DateFormatter().string(from: Date())
            let payload = """
            {
              "imei": "TEST-IMEI-LIFE-001",
              "eventType": "ping",
              "timestamp": "\(now)",
              "latitude": 48.85,
              "longitude": 2.35,
              "gpsFixType": 3,
              "gpsSatellites": 9
            }
            """

            try await tester.test(.POST, "api/vehicle-events", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            })

            try await tester.test(.GET, "api/device-lifecycle?imei=TEST-IMEI-LIFE-001", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                XCTAssertEqual(json.count, 1)
                XCTAssertEqual(json.first?["eventType"] as? String, "ping")
            })

            try await tester.test(.GET, "api/vehicle-events?imei=TEST-IMEI-LIFE-001", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                XCTAssertEqual(json.count, 0, "lifecycle ping should not be stored in vehicle_events")
            })
        }
    }
}
