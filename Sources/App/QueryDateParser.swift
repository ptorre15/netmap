import Foundation

enum QueryDateParser {
    private static let iso8601Fractional: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static let iso8601Basic = ISO8601DateFormatter()

    /// Parses ISO8601 date strings with or without fractional seconds.
    /// Optionally accepts Unix epoch seconds encoded as string.
    static func parse(_ raw: String, allowUnixSeconds: Bool = false) -> Date? {
        if let date = iso8601Fractional.date(from: raw) ?? iso8601Basic.date(from: raw) {
            return date
        }
        guard allowUnixSeconds else { return nil }
        guard let seconds = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
