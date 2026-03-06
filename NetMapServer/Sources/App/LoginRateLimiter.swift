import Vapor

/// In-memory brute-force protection for the login endpoint.
/// Blocks an IP after `maxAttempts` consecutive failures within `windowSeconds`.
/// A successful login resets the counter for that IP.
actor LoginRateLimiter {

    static let shared = LoginRateLimiter()

    private struct Record {
        var count: Int
        var windowStart: Date
    }

    private var records: [String: Record] = [:]

    private let maxAttempts  = 5
    private let windowSeconds: TimeInterval = 60

    /// Returns true when the IP has exceeded the failure threshold.
    func isBlocked(ip: String) -> Bool {
        let now = Date()
        guard let r = records[ip] else { return false }
        if now.timeIntervalSince(r.windowStart) >= windowSeconds {
            records.removeValue(forKey: ip)
            return false
        }
        return r.count >= maxAttempts
    }

    /// Call on every failed authentication attempt.
    func recordFailure(ip: String) {
        let now = Date()
        if var r = records[ip], now.timeIntervalSince(r.windowStart) < windowSeconds {
            r.count += 1
            records[ip] = r
        } else {
            records[ip] = Record(count: 1, windowStart: now)
        }
    }

    /// Call on successful authentication to clear the failure counter.
    func reset(ip: String) {
        records.removeValue(forKey: ip)
    }
}
