import Foundation

public extension Array where Element == String {
    /// The items as a sentence lists them: `Jan`, `Jan and Piet`, `Jan, Piet and An`; empty for none.
    var sentenceList: String {
        guard let last, count > 1 else { return first ?? "" }
        return dropLast().joined(separator: ", ") + " and " + last
    }
}
