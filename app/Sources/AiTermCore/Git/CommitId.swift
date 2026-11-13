import Foundation

/// The rule for "a commit id" where a ref name, an option or `a:b` in its place would change what git
/// is told — a push's refspec, a local merge — or where only the commit asked about may be recorded
/// (`record_review`). One rule, on the maintainer's decision of 2026-11-12, where there were three:
///
/// - A push and a local merge take a full object name: 40 hexadecimal digits (SHA-1) or 64 (SHA-256),
///   in ASCII. The local merge took 40 or more digits as `Character.isHexDigit` reads them, fullwidth
///   ones included, and left the rest to git.
/// - `record_review` takes 4 to 64 ASCII hexadecimal digits, an abbreviation git expands. It took
///   fullwidth digits too.
public struct CommitId: Hashable, Sendable, CustomStringConvertible {
    public let text: String

    /// `nil` for anything that is not a full object name, by the push's rule.
    public init?(_ text: String) {
        guard Self.isFull(text) else { return nil }
        self.text = text
    }

    public var description: String { text }

    /// A full object name, the push's rule: 40 or 64 ASCII hexadecimal digits.
    public static func isFull(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64) && isASCIIHex(text)
    }

    /// Whether a local merge takes `text` as the commit to merge.
    public static func isMergeable(_ text: String) -> Bool {
        isFull(text)
    }

    /// Whether `text` can be an abbreviated object name git expands, for `record_review`. Git may still
    /// read it as a branch or tag named in hex, which its reader rules out itself.
    public static func isAbbreviation(_ text: String) -> Bool {
        (4...64).contains(text.utf8.count) && isASCIIHex(text)
    }

    private static func isASCIIHex(_ text: String) -> Bool {
        text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }
}
