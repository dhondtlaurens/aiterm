import Foundation

/// A full git object name: 40 hexadecimal digits (SHA-1) or 64 (SHA-256), in ASCII. The one rule for
/// "a commit id", where a ref name, an option or `a:b` in its place would change what git is told —
/// a push's refspec, a local merge — and where only the commit asked about may be recorded.
public struct CommitId: Hashable, Sendable, CustomStringConvertible {
    public let text: String

    /// `nil` for anything that is not a full object name.
    public init?(_ text: String) {
        guard Self.isFull(text) else { return nil }
        self.text = text
    }

    public var description: String { text }

    public static func isFull(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64) && isHex(text)
    }

    /// Whether `text` can be an abbreviated object name git expands: 4 to 64 hexadecimal digits. Git
    /// may still read it as a branch or tag named in hex, which its reader rules out itself.
    public static func isAbbreviation(_ text: String) -> Bool {
        (4...64).contains(text.utf8.count) && isHex(text)
    }

    private static func isHex(_ text: String) -> Bool {
        text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }
}
