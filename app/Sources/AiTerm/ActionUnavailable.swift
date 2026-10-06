import Foundation

/// Why an action cannot go ahead, in words the person can act on — "Connect Jira in Settings › Integrations…".
/// Thrown by the app's workflows and the creation sheets' searches alike, and shown as is.
/// Its description is the message too, for the reports that interpolate the error they caught.
struct ActionUnavailable: LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
    var description: String { message }
}
