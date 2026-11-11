import Foundation

/// The text rules shared by the repository clients; validation and refusal wording stay at each caller.
enum HostText {
    static func number(_ text: String, prefixes: String) -> Int? {
        guard text.range(of: "^[\(prefixes)]?\\d+$", options: .regularExpression) != nil else { return nil }
        return Int(text.drop { prefixes.contains($0) })
    }

    static func branchName(_ branch: String) -> String {
        branch.hasPrefix("refs/heads/") ? String(branch.dropFirst("refs/heads/".count)) : branch
    }

    static func protectionFailure(_ context: String, reason: String?) -> ProtectionUnknown {
        let why = (reason ?? "").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return .unreadable("\(context): \(why)")
    }
}
