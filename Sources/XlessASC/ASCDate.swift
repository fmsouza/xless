import Foundation

/// The dates App Store Connect sends, and the day xless shows of one.
public enum ASCDate {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }

    /// `2027-03-01T12:00:00.000+0000` (what App Store Connect sends) or plain ISO 8601.
    public static func parse(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX", "yyyy-MM-dd'T'HH:mm:ssXXXXX"] {
            if let d = formatter(format).date(from: text) { return d }
        }
        return nil
    }

    /// `2027-03-01`, in UTC.
    public static func day(_ date: Date) -> String { formatter("yyyy-MM-dd").string(from: date) }
}
