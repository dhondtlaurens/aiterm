import Foundation

/// The rules for "a commit id" where a ref name, an option or `a:b` in its place would change what git
/// is told — a push's refspec, a local merge — or where only the commit asked about may be recorded
/// (`record_review`). Their one home; today they are three rules, as they were before 2026-11-10, and
/// `oneRule` makes them one.
///
/// - A push takes a full object name: 40 hexadecimal digits (SHA-1) or 64 (SHA-256), in ASCII.
/// - A local merge takes 40 or more hexadecimal digits, as `Character.isHexDigit` reads them, which
///   counts fullwidth digits; git refuses what is not a commit.
/// - `record_review` takes 4 to 64 such digits, an abbreviation git expands.
///
/// One rule — the push's for a merge, its ASCII digits for an abbreviation — changes which inputs the
/// local merge and `record_review` refuse, and with it their replies: the maintainer decides.
public struct CommitId: Hashable, Sendable, CustomStringConvertible {
    public let text: String

    /// `nil` for anything that is not a full object name, by the push's rule.
    public init?(_ text: String) {
        guard Self.isFull(text) else { return nil }
        self.text = text
    }

    public var description: String { text }

    /// Whether the merge and the review read ids by the push's rule. `false` keeps each reader's rule.
    static let oneRule = false

    /// A full object name, the push's rule: 40 or 64 ASCII hexadecimal digits.
    public static func isFull(_ text: String) -> Bool {
        (text.utf8.count == 40 || text.utf8.count == 64) && isASCIIHex(text)
    }

    /// Whether a local merge takes `text` as the commit to merge.
    public static func isMergeable(_ text: String) -> Bool {
        oneRule ? isFull(text) : text.count >= 40 && text.allSatisfy(\.isHexDigit)
    }

    /// Whether `text` can be an abbreviated object name git expands, for `record_review`. Git may still
    /// read it as a branch or tag named in hex, which its reader rules out itself.
    public static func isAbbreviation(_ text: String) -> Bool {
        oneRule ? (4...64).contains(text.utf8.count) && isASCIIHex(text)
                : (4...64).contains(text.count) && text.allSatisfy(\.isHexDigit)
    }

    private static func isASCIIHex(_ text: String) -> Bool {
        text.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || ($0 >= 65 && $0 <= 70) }
    }
}
