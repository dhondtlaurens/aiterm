import Foundation

public extension Optional where Wrapped == String {
    /// Text trimmed of whitespace and newlines, or nil when nothing remains.
    var said: String? {
        map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.nonEmpty
    }

    /// The original text, or nil when it is empty. Whitespace is preserved.
    var nonEmpty: String? {
        flatMap { $0.isEmpty ? nil : $0 }
    }
}
