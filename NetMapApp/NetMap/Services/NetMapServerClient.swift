import Foundation
import SwiftUI
import os.log
#if os(iOS)
import UIKit
#endif

private let netLog = Logger(subsystem: "com.phil.netmap.app", category: "Network")

// MARK: - Server Sensor Payload (JSON sent to NetMapServer)

struct ServerSensorPayload: Codable {
    var sensorID:          String
    var vehicleID:         String
    var vehicleName:       String
    var assetTypeID:       String? = nil   // "vehicle" | "tool" | custom — for server-side vehicle upsert
    var brand:             String          // "michelin" | "stihl" | "ela" | "airtag" | …
    var wheelPosition:     String?         // "FL" | "FR" | "RL" | "RR" | nil
    var pressureBar:       Double?         // nil for non-TPMS sensors
    var temperatureC:      Double?
    var vbattVolts:        Double?
    var targetPressureBar: Double?
    var batteryPct:        Int?            // 0-100, Stihl / ELA / AirTag
    var chargeState:       String?
    var sensorName:        String?         // human-readable device name         // Stihl battery: "Idle" | "Charging" | "Full" | …
    var healthPct:         Int?    = nil   // Stihl Smart Battery health %
    var chargingCycles:    Int?    = nil   // Stihl Smart Battery charge cycles
    var productVariant:    String? = nil   // ELA: "coin" | "puck" | "unknown"
    var totalSeconds:      Int?    = nil   // Stihl: total operating / discharge time (s)
    var gpsSatellites:     Int?    = nil   // GPS tracker: number of satellites in view
    var latitude:          Double?
    var longitude:         Double?
    var timestamp:         Date
}

// MARK: - Server Sensor DTO (returned by GET /api/sensors/latest)

/// Mirrors server-side SensorStat: fields to rebuild PairedSensor entries + latest telemetry.
struct SensorServerDTO: Codable {
    var sensorID:          String
    var vehicleID:         String
    var vehicleName:       String
    var brand:             String
    var wheelPosition:     String?
    var targetPressureBar: Double?
    var sensorName:        String?
    // ── Latest telemetry (nil when sensor hasn't reported yet) ──────────
    var latestLatitude:      Double?
    var latestLongitude:     Double?
    var latestGpsSatellites: Int?
    var latestBatteryPct:    Int?       // fuel % for trackers, battery % for others
    var latestChargeState:   String?
    var latestTemperatureC:  Double?
    var latestTimestamp:     Date?
    var readingCount:        Int?
}

// MARK: - Server Vehicle DTO (returned by GET /api/vehicles)

struct VehicleServerDTO: Codable, Identifiable {
    var id:           UUID
    var name:         String
    var assetTypeID:  String?
    var brand:        String?
    var modelName:    String?
    var year:         Int?
    var vin:          String?
    var vrn:          String?
    var serialNumber: String?
    var toolType:     String?
}

// MARK: - NetMapServerClient

@MainActor
final class NetMapServerClient: ObservableObject {

    // ── Published settings ─────────────────────────────────────────────
    @Published var isEnabled: Bool   = false { didSet { save() } }
    @Published var host:      String = "92-137-172-240.nip.io" { didSet { save() } }
    @Published var port:      Int    = 443 { didSet { save() } }
    @Published var useHTTPS:  Bool   = true  { didSet { save() } }
    @Published var apiKey:    String = "netmap-dev" { didSet { save(); apiKeyRejected = false; connectionStatus = .unknown } }
    /// Push interval in seconds (default 5 min, range 60 s – 43 200 s / 12 h)
    @Published var pushIntervalSeconds: Int = 300 { didSet { save() } }

    /// Computed base URL — omits port 443 (HTTPS) or 80 (HTTP) to keep URLs clean.
    var baseURL: String {
        if useHTTPS {
            return port == 443 ? "https://\(host)" : "https://\(host):\(port)"
        } else {
            return port == 80  ? "http://\(host)"  : "http://\(host):\(port)"
        }
    }    // ── Auth state ────────────────────────────────────────────────
    @Published private(set) var isAuthenticated:   Bool    = false
    @Published private(set) var currentUserEmail:  String? = nil
    @Published private(set) var currentUserRole:   String? = nil    // ── Observable state ───────────────────────────────────────────────
    @Published private(set) var connectionStatus: ConnectionStatus = .unknown
    @Published private(set) var pendingCount:      Int = 0
    @Published private(set) var totalSent:         Int = 0
    @Published private(set) var lastErrorMessage:  String?
    /// Set to true when the server rejects the API key (HTTP 401).
    /// Observe this to prompt the user to update their key in Settings.
    @Published private(set) var apiKeyRejected: Bool = false

    // MARK: Connection Status

    enum ConnectionStatus: Equatable {
        case unknown
        case ok
        case unauthorized          // API key rejected (HTTP 401)
        case failure(String)

        var label: String {
            switch self {
            case .unknown:        return "Not tested"
            case .ok:             return "Connected"
            case .unauthorized:   return "API key rejected"
            case .failure(let m): return m
            }
        }
        var color: Color {
            switch self {
            case .unknown:      return .secondary
            case .ok:           return .green
            case .unauthorized: return .orange
            case .failure:      return .red
            }
        }
        var systemImage: String {
            switch self {
            case .unknown:      return "questionmark.circle"
            case .ok:           return "checkmark.circle.fill"
            case .unauthorized: return "key.slash.fill"
            case .failure:      return "exclamationmark.triangle.fill"
            }
        }
    }

    // MARK: Internals

    private var pendingQueue: [ServerSensorPayload] = []
    private var flushTask: Task<Void, Never>?
#if os(iOS)
    private var pendingBgTask: UIBackgroundTaskIdentifier = .invalid
#endif

    private enum Keys {
        static let enabled      = "nmsc_enabled"
        static let host         = "nmsc_host"
        static let port         = "nmsc_port"
        static let https        = "nmsc_https"
        static let sent         = "nmsc_total_sent"
        static let apiKey       = "nmsc_api_key"
        static let token        = "nmsc_auth_token"
        static let email        = "nmsc_auth_email"
        static let role         = "nmsc_auth_role"
        static let pushInterval = "nmsc_push_interval"
    }

    // MARK: Init

    init() {
        let ud      = UserDefaults.standard
        _isEnabled  = Published(wrappedValue: ud.bool(forKey: Keys.enabled))

        // ── Migrate stale defaults (localhost / 8092 → production server) ──
        let savedHost = ud.string(forKey: Keys.host) ?? ""
        let savedPort = ud.integer(forKey: Keys.port)
        let migratedHost = (savedHost.isEmpty || savedHost == "localhost" || savedHost == "127.0.0.1")
            ? "92-137-172-240.nip.io" : savedHost
        let migratedPort = (savedPort == 0 || savedPort == 8092)
            ? 443 : savedPort
        _host = Published(wrappedValue: migratedHost)
        _port = Published(wrappedValue: migratedPort)
        // Persist migration immediately so next launch reads updated values
        ud.set(migratedHost, forKey: Keys.host)
        ud.set(migratedPort, forKey: Keys.port)

        // Default true; if key was never set (fresh install / migration) useHTTPS=true
        let httpsSet = ud.object(forKey: Keys.https) != nil
        _useHTTPS   = Published(wrappedValue: httpsSet ? ud.bool(forKey: Keys.https) : true)
        if !httpsSet { ud.set(true, forKey: Keys.https) }
        _totalSent  = Published(wrappedValue: ud.integer(forKey: Keys.sent))
        _apiKey     = Published(wrappedValue: ud.string(forKey: Keys.apiKey) ?? "netmap-dev")
        let pi      = ud.integer(forKey: Keys.pushInterval)
        _pushIntervalSeconds = Published(wrappedValue: pi > 0 ? pi : 300)
        // Restore saved auth session
        if let savedToken = ud.string(forKey: Keys.token),
           let savedEmail = ud.string(forKey: Keys.email),
           !savedToken.isEmpty {
            _isAuthenticated  = Published(wrappedValue: true)
            _currentUserEmail = Published(wrappedValue: savedEmail)
            _currentUserRole  = Published(wrappedValue: ud.string(forKey: Keys.role) ?? "user")
        } else {
            _isAuthenticated  = Published(wrappedValue: false)
            _currentUserEmail = Published(wrappedValue: nil)
            _currentUserRole  = Published(wrappedValue: nil)
        }
    }

    // MARK: Persistence

    func save() {
        let ud = UserDefaults.standard
        ud.set(isEnabled,           forKey: Keys.enabled)
        ud.set(host,                forKey: Keys.host)
        ud.set(port,                forKey: Keys.port)
        ud.set(useHTTPS,            forKey: Keys.https)
        ud.set(totalSent,           forKey: Keys.sent)
        ud.set(apiKey,              forKey: Keys.apiKey)
        ud.set(pushIntervalSeconds, forKey: Keys.pushInterval)
    }

    private func saveAuth(token: String, email: String, role: String) {
        let ud = UserDefaults.standard
        ud.set(token, forKey: Keys.token)
        ud.set(email, forKey: Keys.email)
        ud.set(role,  forKey: Keys.role)
        isAuthenticated  = true
        currentUserEmail = email
        currentUserRole  = role
    }

    private func clearAuth() {
        let ud = UserDefaults.standard
        ud.removeObject(forKey: Keys.token)
        ud.removeObject(forKey: Keys.email)
        ud.removeObject(forKey: Keys.role)
        isAuthenticated  = false
        currentUserEmail = nil
        currentUserRole  = nil
    }

    // MARK: Enqueue

    func enqueue(_ payload: ServerSensorPayload) {
        guard isEnabled else {
            netLog.error("[Net] enqueue skipped: server disabled")
            return
        }
        pendingQueue.append(payload)
        pendingCount = pendingQueue.count
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
#if os(iOS)
        // End any previous background task superseded by this reschedule.
        if pendingBgTask != .invalid {
            UIApplication.shared.endBackgroundTask(pendingBgTask)
            pendingBgTask = .invalid
        }
        let app = UIApplication.shared
        let appState = app.applicationState

        // BACKGROUND: no debounce, no Task, no async/await.
        // The Swift Concurrency cooperative pool may not be scheduled between CB wakeups.
        // URLSession.dataTask(completionHandler:) is scheduled directly by iOS and
        // fires even when the cooperative pool is paused.
        if appState != .active {
            pendingBgTask = app.beginBackgroundTask(withName: "NetMapFlush") { [weak self] in
                guard let self else { return }
                app.endBackgroundTask(self.pendingBgTask)
                self.pendingBgTask = .invalid
            }
            let capturedBgTask = pendingBgTask
            flushImmediate { [weak self] in
                guard let self else { return }
                if capturedBgTask != .invalid {
                    app.endBackgroundTask(capturedBgTask)
                }
                if self.pendingBgTask == capturedBgTask {
                    self.pendingBgTask = .invalid
                }
            }
            return
        }

        // FOREGROUND: 400ms debounce to batch rapid BLE events.
        pendingBgTask = app.beginBackgroundTask(withName: "NetMapFlush") { [weak self] in
            guard let self else { return }
            app.endBackgroundTask(self.pendingBgTask)
            self.pendingBgTask = .invalid
        }
        let capturedBgTask = pendingBgTask
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            await self?.flush()
            if capturedBgTask != .invalid { app.endBackgroundTask(capturedBgTask) }
            if self?.pendingBgTask == capturedBgTask { self?.pendingBgTask = .invalid }
        }
#else
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            await self?.flush()
        }
#endif
    }

#if os(iOS)
    /// Synchronous-dispatch flush using URLSession.dataTask(completionHandler:).
    /// Does NOT use async/await or Task — safe to call in background CB wakeup windows.
    private func flushImmediate(completion: @escaping () -> Void) {
        guard !pendingQueue.isEmpty, isEnabled else { completion(); return }
        let batch = pendingQueue
        pendingQueue.removeAll()
        pendingCount = 0

        guard let url = URL(string: "\(baseURL)/api/records/batch") else {
            completion(); return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let body = try? enc.encode(batch) else { completion(); return }
        req.httpBody = body

        URLSession.shared.dataTask(with: req) { [weak self] _, response, error in
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let errDesc = error?.localizedDescription ?? "none"
            if (200...299).contains(statusCode) {
                netLog.error("[Net] flush OK (bg) sent=\(batch.count) status=\(statusCode)")
            } else {
                netLog.error("[Net] flush ERROR (bg) status=\(statusCode) error=\(errDesc, privacy: .public)")
            }
            DispatchQueue.main.async {
                guard let self else { completion(); return }
                if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                    self.totalSent += batch.count
                    self.save()
                    self.connectionStatus = .ok
                    self.lastErrorMessage = nil
                } else if let http = response as? HTTPURLResponse, http.statusCode == 401 {
                    self.connectionStatus = .unauthorized
                    self.apiKeyRejected   = true
                    self.lastErrorMessage = "API key rejected — update it in Settings."
                } else {
                    let msg = error?.localizedDescription ?? "HTTP error"
                    self.connectionStatus = .failure(msg)
                    self.lastErrorMessage = msg
                    // Re-queue (cap at 10 000)
                    let space = max(0, 10_000 - self.pendingQueue.count)
                    if space > 0 {
                        self.pendingQueue.insert(contentsOf: batch.prefix(space), at: 0)
                        self.pendingCount = self.pendingQueue.count
                    }
                }
                completion()
            }
        }.resume()
    }
#endif

    private func flush() async {
        guard !pendingQueue.isEmpty, isEnabled else { return }
        let batch = pendingQueue
        pendingQueue.removeAll()
        pendingCount = 0
        do {
            try await sendBatch(batch)
            totalSent += batch.count
            save()
            connectionStatus  = .ok
            lastErrorMessage  = nil
            netLog.error("[Net] flush OK sent=\(batch.count) total=\(self.totalSent)")
        } catch NetMapServerError.unauthorized {
            connectionStatus = .unauthorized
            apiKeyRejected   = true
            lastErrorMessage = "API key rejected — update it in Settings."
            netLog.error("[Net] flush UNAUTHORIZED")
            // Do NOT re-queue: retrying with the same wrong key would just spam 401s.
        } catch {
            let msg = error.localizedDescription
            connectionStatus  = .failure(msg)
            lastErrorMessage  = msg
            netLog.error("[Net] flush ERROR \(msg, privacy: .public)")
            // Re-queue (cap at 10 000)
            let space = max(0, 10_000 - pendingQueue.count)
            if space > 0 {
                pendingQueue.insert(contentsOf: batch.prefix(space), at: 0)
                pendingCount = pendingQueue.count
            }
        }
    }

    private func sendBatch(_ batch: [ServerSensorPayload]) async throws {
        guard let url = URL(string: "\(baseURL)/api/records/batch") else {
            throw NetMapServerError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        req.httpBody = try enc.encode(batch)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NetMapServerError.httpError(0)
        }
        if http.statusCode == 401 { throw NetMapServerError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw NetMapServerError.httpError(http.statusCode)
        }
    }

    // MARK: Auth — Login / Logout / Session Validation

    struct AuthResponse: Codable {
        var token:       String
        var email:       String
        var displayName: String?
        var role:        String
    }

    /// Logs in with email + password. Saves token on success.
    func login(email: String, password: String) async throws {
        guard let url = URL(string: "\(baseURL)/api/auth/login") else {
            throw NetMapServerError.invalidURL
        }
        struct Payload: Encodable { var email: String; var password: String }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(Payload(email: email, password: password))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetMapServerError.httpError(0) }
        if http.statusCode == 401 { throw NetMapServerError.invalidCredentials }
        guard (200...299).contains(http.statusCode) else { throw NetMapServerError.httpError(http.statusCode) }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let auth = try dec.decode(AuthResponse.self, from: data)
        saveAuth(token: auth.token, email: auth.email, role: auth.role)
        connectionStatus = .ok
        lastErrorMessage = nil
        // Persist credentials in Keychain so Touch ID / Face ID can log in next time
        BiometricAuthService.shared.saveCredentials(email: email, password: password)
    }

    /// Logs out — invalidates server token and clears local session.
    func logout() async {
        if let token = UserDefaults.standard.string(forKey: Keys.token),
           let url = URL(string: "\(baseURL)/api/auth/logout") {
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
        clearAuth()
        BiometricAuthService.shared.removeCredentials()
    }
    func validateStoredToken() async {
        guard let token = UserDefaults.standard.string(forKey: Keys.token), !token.isEmpty else {
            clearAuth(); return
        }
        guard let url = URL(string: "\(baseURL)/api/auth/me") else {
            return   // keep cached auth if server unreachable
        }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 {
            clearAuth()   // token expired
        } else if (200...299).contains(http.statusCode),
                  let auth = try? JSONDecoder().decode(AuthResponse.self, from: data) {
            saveAuth(token: auth.token, email: auth.email, role: auth.role)
        }
    }

    /// Returns the stored Bearer token (used as Authorization header for admin operations).
    var bearerToken: String? { UserDefaults.standard.string(forKey: Keys.token) }

    // MARK: Test Connection

    func testConnection() async {
        guard let url = URL(string: "\(baseURL)/health") else {
            connectionStatus = .failure("Invalid URL")
            return
        }
        do {
            let req = URLRequest(url: url, timeoutInterval: 5)
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...299).contains(code) {
                connectionStatus = .ok
                lastErrorMessage = nil
            } else {
                connectionStatus = .failure("HTTP \(code)")
            }
        } catch {
            connectionStatus = .failure(error.localizedDescription)
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: Queue control

    func clearQueue() {
        pendingQueue.removeAll()
        pendingCount = 0
    }

    func retryNow() {
        scheduleFlush()
    }

    // MARK: Fetch Assets

    func fetchAssets() async throws -> [VehicleServerDTO] {
        guard let url = URL(string: "\(baseURL)/api/assets") else {
            throw NetMapServerError.invalidURL
        }
        let req = URLRequest(url: url, timeoutInterval: 10)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NetMapServerError.httpError(0)
        }
        if http.statusCode == 401 { throw NetMapServerError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw NetMapServerError.httpError(http.statusCode)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode([VehicleServerDTO].self, from: data)
    }

    // MARK: Fetch Asset Types

    struct AssetTypeServerDTO: Codable {
        var id:            String
        var name:          String
        var systemImage:   String
        var allowedBrands: [String]
        var isBuiltIn:     Bool

        func toAssetType() -> AssetType {
            AssetType(
                id:            id,
                name:          name,
                systemImage:   systemImage,
                allowedBrands: allowedBrands.compactMap { SensorBrandTag(rawValue: $0) },
                isBuiltIn:     isBuiltIn
            )
        }
    }

    func fetchAssetTypes() async throws -> [AssetType] {
        guard let url = URL(string: "\(baseURL)/api/asset-types") else {
            throw NetMapServerError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NetMapServerError.httpError(0)
        }
        let dtos = try JSONDecoder().decode([AssetTypeServerDTO].self, from: data)
        return dtos.map { $0.toAssetType() }
    }

    func createAssetType(name: String, systemImage: String, allowedBrands: [SensorBrandTag],
                         bearerToken: String) async throws -> AssetType {
        guard let url = URL(string: "\(baseURL)/api/asset-types") else {
            throw NetMapServerError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "name":          name,
            "systemImage":   systemImage,
            "allowedBrands": allowedBrands.map(\.rawValue)
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetMapServerError.httpError(0) }
        if http.statusCode == 401 { throw NetMapServerError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw NetMapServerError.httpError(http.statusCode) }
        let dto = try JSONDecoder().decode(AssetTypeServerDTO.self, from: data)
        return dto.toAssetType()
    }

    // MARK: Push Pairing

    struct PairingPayload: Encodable {
        var sensorID:          String
        var vehicleID:         String
        var vehicleName:       String
        var assetTypeID:       String?
        var brand:             String
        var wheelPosition:     String?
        var targetPressureBar: Double?
        var sensorName:        String?
    }

    /// DELETE /api/sensors/pair/:stableID — removes all server-side readings for a sensor.
    /// Called immediately when the user unpairs a sensor so the dashboard reflects the change.
    func pushUnpairing(stableID: String) async throws {
        let id = stableID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? stableID
        guard let url = URL(string: "\(baseURL)/api/sensors/pair/\(id)") else {
            throw NetMapServerError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "DELETE"
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetMapServerError.httpError(0) }
        if http.statusCode == 401 { throw NetMapServerError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw NetMapServerError.httpError(http.statusCode)
        }
    }

    /// POST /api/sensors/pair — registers a sensor<->vehicle pairing on the server immediately,
    /// without requiring a live BLE reading. The sensor appears in /api/sensors/latest right away.
    func pushPairing(_ payload: PairingPayload) async throws {
        guard let url = URL(string: "\(baseURL)/api/sensors/pair") else {
            throw NetMapServerError.invalidURL
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        req.httpBody = try enc.encode(payload)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw NetMapServerError.httpError(0) }
        if http.statusCode == 401 { throw NetMapServerError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw NetMapServerError.httpError(http.statusCode)
        }
    }

    // MARK: Fetch Paired Sensors

    /// GET /api/sensors/latest — returns the latest reading per sensor.
    /// The app uses this to rebuild its local pairedSensors list so that the server
    /// is the single source of truth for which sensors are paired to which vehicle.
    func fetchPairedSensors() async throws -> [SensorServerDTO] {
        guard let url = URL(string: "\(baseURL)/api/sensors/latest") else {
            throw NetMapServerError.invalidURL
        }
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10))
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NetMapServerError.httpError(0)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode([SensorServerDTO].self, from: data)
    }

}


// MARK: - Errors

enum NetMapServerError: LocalizedError {
    case invalidURL
    case unauthorized                     // HTTP 401 — API key rejected
    case invalidCredentials               // HTTP 401 — wrong email/password
    case httpError(Int)                   // any other non-2xx
    case noNetwork                        // NSURLErrorNotConnectedToInternet
    case timedOut                         // NSURLErrorTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidURL:         return "Invalid server URL — check Settings."
        case .unauthorized:       return "API key rejected — update it in Settings."
        case .invalidCredentials: return "Invalid email or password."
        case .httpError(let c):   return "Server returned HTTP \(c)."
        case .noNetwork:          return "No network connection."
        case .timedOut:           return "Server did not respond in time."
        }
    }

    /// Wraps a raw URLSession error into a typed NetMapServerError.
    static func from(_ error: Error) -> NetMapServerError {
        let code = (error as NSError).code
        if code == NSURLErrorNotConnectedToInternet || code == NSURLErrorNetworkConnectionLost {
            return .noNetwork
        }
        if code == NSURLErrorTimedOut { return .timedOut }
        return .httpError(0)
    }
}
