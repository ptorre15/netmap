import Foundation
import SwiftUI

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
    var latitude:          Double?
    var longitude:         Double?
    var timestamp:         Date
}

// MARK: - Server Vehicle DTO (returned by GET /api/vehicles)

struct VehicleServerDTO: Codable, Identifiable {
    var id:        UUID
    var name:      String
    var brand:     String?
    var modelName: String?
    var year:      Int?
    var vin:       String?
    var vrn:       String?
}

// MARK: - Server History Record (returned by GET /api/records/by-sensor/:id)

struct ServerRecord: Codable, Identifiable {
    var id:               UUID
    var sensorID:         String
    var vehicleID:        String
    var vehicleName:      String?
    var brand:            String?
    var wheelPosition:    String?
    var pressureBar:      Double?
    var temperatureC:     Double?
    var vbattVolts:       Double?
    var targetPressureBar: Double?
    var batteryPct:       Int?
    var chargeState:      String?
    var healthPct:        Int?
    var chargingCycles:   Int?
    var productVariant:   String?
    var latitude:         Double?
    var longitude:        Double?
    var timestamp:        Date
}

// MARK: - NetMapServerClient

@MainActor
final class NetMapServerClient: ObservableObject {

    // ── Published settings ─────────────────────────────────────────────
    @Published var isEnabled: Bool   = false { didSet { save() } }
    @Published var host:      String = "localhost" { didSet { save() } }
    @Published var port:      Int    = 8765 { didSet { save() } }
    @Published var apiKey:    String = "netmap-dev" { didSet { save(); apiKeyRejected = false; connectionStatus = .unknown } }    // ── Auth state ────────────────────────────────────────────────
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

    private enum Keys {
        static let enabled = "nmsc_enabled"
        static let host    = "nmsc_host"
        static let port    = "nmsc_port"
        static let sent    = "nmsc_total_sent"
        static let apiKey  = "nmsc_api_key"
        static let token   = "nmsc_auth_token"
        static let email   = "nmsc_auth_email"
        static let role    = "nmsc_auth_role"
    }

    // MARK: Init

    init() {
        let ud      = UserDefaults.standard
        _isEnabled  = Published(wrappedValue: ud.bool(forKey: Keys.enabled))
        _host       = Published(wrappedValue: ud.string(forKey: Keys.host) ?? "localhost")
        let p       = ud.integer(forKey: Keys.port)
        _port       = Published(wrappedValue: p > 0 ? p : 8765)
        _totalSent  = Published(wrappedValue: ud.integer(forKey: Keys.sent))
        _apiKey     = Published(wrappedValue: ud.string(forKey: Keys.apiKey) ?? "netmap-dev")
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
        ud.set(isEnabled, forKey: Keys.enabled)
        ud.set(host,      forKey: Keys.host)
        ud.set(port,      forKey: Keys.port)
        ud.set(totalSent, forKey: Keys.sent)
        ud.set(apiKey,    forKey: Keys.apiKey)
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
        guard isEnabled else { return }
        pendingQueue.append(payload)
        pendingCount = pendingQueue.count
        scheduleFlush()
    }

    private func scheduleFlush() {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            await self?.flush()
        }
    }

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
        } catch NetMapServerError.unauthorized {
            connectionStatus = .unauthorized
            apiKeyRejected   = true
            lastErrorMessage = "API key rejected — update it in Settings."
            // Do NOT re-queue: retrying with the same wrong key would just spam 401s.
        } catch {
            let msg = error.localizedDescription
            connectionStatus  = .failure(msg)
            lastErrorMessage  = msg
            // Re-queue (cap at 10 000)
            let space = max(0, 10_000 - pendingQueue.count)
            if space > 0 {
                pendingQueue.insert(contentsOf: batch.prefix(space), at: 0)
                pendingCount = pendingQueue.count
            }
        }
    }

    private func sendBatch(_ batch: [ServerSensorPayload]) async throws {
        guard let url = URL(string: "http://\(host):\(port)/api/records/batch") else {
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
        guard let url = URL(string: "http://\(host):\(port)/api/auth/login") else {
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
    }

    /// Logs out — invalidates server token and clears local session.
    func logout() async {
        if let token = UserDefaults.standard.string(forKey: Keys.token),
           let url = URL(string: "http://\(host):\(port)/api/auth/logout") {
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.httpMethod = "POST"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
        clearAuth()
    }

    /// Validates the stored token with the server. Call on app launch.
    func validateStoredToken() async {
        guard let token = UserDefaults.standard.string(forKey: Keys.token), !token.isEmpty else {
            clearAuth(); return
        }
        guard let url = URL(string: "http://\(host):\(port)/api/auth/me") else {
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
        guard let url = URL(string: "http://\(host):\(port)/health") else {
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

    // MARK: Fetch Vehicles

    func fetchVehicles() async throws -> [VehicleServerDTO] {
        guard let url = URL(string: "http://\(host):\(port)/api/vehicles") else {
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
        guard let url = URL(string: "http://\(host):\(port)/api/asset-types") else {
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
        guard let url = URL(string: "http://\(host):\(port)/api/asset-types") else {
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

    // MARK: Fetch History

    func fetchHistory(sensorID: String, from: Date, to: Date) async throws -> [PressureRecord] {
        let iso = ISO8601DateFormatter()
        let fromStr = iso.string(from: from).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let toStr   = iso.string(from: to).addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "http://\(host):\(port)/api/records/by-sensor/\(sensorID)?from=\(fromStr)&to=\(toStr)") else {
            throw NetMapServerError.invalidURL
        }
        var urlReq = URLRequest(url: url, timeoutInterval: 15)
        urlReq.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        let (data, response) = try await URLSession.shared.data(for: urlReq)
        guard let http = response as? HTTPURLResponse else {
            throw NetMapServerError.httpError(0)
        }
        if http.statusCode == 401 { throw NetMapServerError.unauthorized }
        guard (200...299).contains(http.statusCode) else {
            throw NetMapServerError.httpError(http.statusCode)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let serverRecords = try dec.decode([ServerRecord].self, from: data)
        return serverRecords
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { sr -> PressureRecord? in
                guard let p = sr.pressureBar else { return nil }
                return PressureRecord(
                    id:           sr.id,
                    timestamp:    sr.timestamp,
                    pressureBar:  p,
                    temperatureC: sr.temperatureC,
                    vbattVolts:   sr.vbattVolts,
                    latitude:     sr.latitude,
                    longitude:    sr.longitude
                )
            }
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
