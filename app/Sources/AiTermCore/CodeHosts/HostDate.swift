import Foundation

/// Dates exchanged with the code hosts and Jira, using formatters constructed once.
enum HostDate {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let whole = ISO8601DateFormatter()
    private static let jiraFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    static func iso8601(_ text: String) -> Date? { fractional.date(from: text) ?? whole.date(from: text) }
    static func jira(_ text: String) -> Date? { jiraFormatter.date(from: text) }
    static func iso8601String(from date: Date) -> String { whole.string(from: date) }
}
