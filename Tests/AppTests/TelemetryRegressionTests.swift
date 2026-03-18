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

    func testElaTemperatureFilteredForNonTempVariants() async throws {
        try await withApp { app in
            let tester = try app.testable()
            let now = ISO8601DateFormatter().string(from: Date())

            // ELA "coin" variant (no temperature sensor): temperature must be discarded
            let coinPayload = """
            [{
              "sensorID": "ELA-COIN-001",
              "vehicleID": "00000000-0000-0000-0000-000000000001",
              "vehicleName": "Test Vehicle",
              "brand": "ela",
              "productVariant": "coin",
              "batteryPct": 80,
              "temperatureC": 87.0,
              "timestamp": "\(now)"
            }]
            """
            try await tester.test(.POST, "api/records/batch", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: coinPayload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            })

            try await tester.test(.GET, "api/sensors/latest", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                let target = json.first { ($0["sensorID"] as? String) == "ELA-COIN-001" }
                XCTAssertNotNil(target, "ELA coin sensor should appear in /api/sensors/latest")
                XCTAssertNil(target?["latestTemperatureC"],
                             "Temperature must be nil for ELA 'coin' variant (no temperature sensor)")
            })

            // ELA "coin_t" variant (with temperature sensor): temperature must be stored
            let coinTPayload = """
            [{
              "sensorID": "ELA-COIN-T-001",
              "vehicleID": "00000000-0000-0000-0000-000000000001",
              "vehicleName": "Test Vehicle",
              "brand": "ela",
              "productVariant": "coin_t",
              "batteryPct": 75,
              "temperatureC": 22.5,
              "timestamp": "\(now)"
            }]
            """
            try await tester.test(.POST, "api/records/batch", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: coinTPayload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            })

            try await tester.test(.GET, "api/sensors/latest", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                let target = json.first { ($0["sensorID"] as? String) == "ELA-COIN-T-001" }
                XCTAssertNotNil(target, "ELA coin_t sensor should appear in /api/sensors/latest")
                XCTAssertNotNil(target?["latestTemperatureC"],
                                "Temperature must be stored for ELA 'coin_t' variant (has temperature sensor)")
                if let temp = target?["latestTemperatureC"] as? Double {
                    XCTAssertEqual(temp, 22.5, accuracy: 0.01)
                }
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

    // MARK: - Fix 6: new regression tests

    /// Rate limiter blocks an IP after 5 failed login attempts (ipLimit = 5).
    func testLoginRateLimiterIPBlocksAfterMaxAttempts() async throws {
        try await withApp { app in
            let tester = try app.testable()
            let payload = #"{"email":"nonexistent@example.com","password":"wrong"}"#

            // Attempts 1–5: each should return 401 (bad credentials) and increment the failure count.
            for _ in 1...5 {
                try await tester.test(.POST, "api/auth/login", beforeRequest: { req async throws in
                    req.headers.contentType = .json
                    req.body = .init(string: payload)
                }, afterResponse: { res async throws in
                    XCTAssertEqual(res.status, .unauthorized)
                })
            }

            // Attempt 6: the bucket is now full; login must be blocked before credential check.
            try await tester.test(.POST, "api/auth/login", beforeRequest: { req async throws in
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .tooManyRequests,
                               "6th attempt from the same IP should be rate-limited (429)")
            })
        }
    }

    /// An unknown eventType value must be rejected with HTTP 400.
    func testUnknownEventTypeReturns400() async throws {
        try await withApp { app in
            let tester = try app.testable()
            let payload = """
            {
              "imei": "TEST-IMEI-BAD-TYPE",
              "eventType": "completely_bogus_type_xyz",
              "timestamp": "2024-01-01T00:00:00Z",
              "latitude": 48.8566,
              "longitude": 2.3522
            }
            """
            try await tester.test(.POST, "api/vehicle-events", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .badRequest,
                               "An unrecognised eventType should be rejected with HTTP 400")
            })
        }
    }

    /// Posting the same telemetry event twice must store it only once (idempotent ingestion).
    func testTelemetryDeduplicationSkipsDuplicate() async throws {
        try await withApp { app in
            let tester = try app.testable()
            let fixedTimestamp = "2024-06-01T12:00:00Z"
            let payload = """
            {
              "imei": "TEST-IMEI-DEDUP-001",
              "eventType": "driving",
              "timestamp": "\(fixedTimestamp)",
              "latitude": 48.8566,
              "longitude": 2.3522,
              "speedKmh": 30.0
            }
            """

            // First POST: should be stored (201).
            try await tester.test(.POST, "api/vehicle-events", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            })

            // Second POST (identical payload): server responds 201 but dedup silently skips storage.
            try await tester.test(.POST, "api/vehicle-events", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created)
            })

            // The vehicle_events list must contain exactly one record for this IMEI.
            try await tester.test(.GET, "api/vehicle-events?imei=TEST-IMEI-DEDUP-001", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .ok)
                guard let data = res.body.string.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                    return XCTFail("Expected JSON array")
                }
                XCTAssertEqual(json.count, 1, "Duplicate telemetry event must be deduplicated — only 1 row expected")
            })
        }
    }

    /// `normalizeJourneyDistanceKm` must clamp values that would exceed 2 000 km after conversion.
    func testNormalizeJourneyDistanceKmClamp() {
        // 5 000 000 m → 5 000 km → clamped to 2 000 km
        XCTAssertEqual(normalizeJourneyDistanceKm(5_000_000.0) ?? -1, 2_000.0, accuracy: 0.001)
        // 3 000 000 m → 3 000 km → clamped to 2 000 km
        XCTAssertEqual(normalizeJourneyDistanceKm(3_000_000.0) ?? -1, 2_000.0, accuracy: 0.001)
        // 2 000 000 m → exactly 2 000 km → not clamped (boundary value)
        XCTAssertEqual(normalizeJourneyDistanceKm(2_000_000.0) ?? -1, 2_000.0, accuracy: 0.001)
        // 1 500 000 m → 1 500 km → not clamped
        XCTAssertEqual(normalizeJourneyDistanceKm(1_500_000.0) ?? -1, 1_500.0, accuracy: 0.001)
    }

    /// The API key middleware must accept valid keys and reject invalid ones with HTTP 401.
    func testAPIKeyHashValidation() async throws {
        try await withApp { app in
            let tester = try app.testable()
            let payload = """
            {
              "imei": "TEST-IMEI-APIKEY-001",
              "eventType": "driving",
              "timestamp": "2024-06-02T10:00:00Z",
              "latitude": 48.8566,
              "longitude": 2.3522,
              "speedKmh": 20.0
            }
            """

            // Correct API key → must be accepted.
            try await tester.test(.POST, "api/vehicle-events", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "test-key")
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .created,
                               "Valid API key should be accepted by the middleware")
            })

            // Wrong API key → must be rejected.
            try await tester.test(.POST, "api/vehicle-events", beforeRequest: { req async throws in
                req.headers.add(name: "X-API-Key", value: "wrong-key-should-fail")
                req.headers.contentType = .json
                req.body = .init(string: payload)
            }, afterResponse: { res async throws in
                XCTAssertEqual(res.status, .unauthorized,
                               "Invalid API key should be rejected with 401")
            })
        }
    }
}
