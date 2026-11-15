import Foundation
import AiTermCore

/// One notification: what it says, and what a click on it opens — a broadcast's board, at a question's block under
/// Waiting on you when it is about one (spec §10.3; D1a, 5 Nov 2026). Its `id` replaces an earlier one with the same id.
/// `.task` opens a task's window, as notifications from before the list did.
struct OperatorNote: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case board(UUID), task(UUID)
        /// The board of `run`, at the block of its question `key`.
        case question(run: UUID, key: String)

        /// The target as a notification carries it: a question's key beside its board's run.
        var userInfo: [String: String] {
            switch self {
            case .board(let id): ["aiterm.overview": id.uuidString]
            case .task(let id): ["aiterm.task": id.uuidString]
            case .question(let run, let key): ["aiterm.overview": run.uuidString, "aiterm.question": key]
            }
        }

        /// A notification an older AiTerm posted, with no question, opens the board.
        init?(userInfo: [AnyHashable: Any]) {
            if let id = (userInfo["aiterm.overview"] as? String).flatMap(UUID.init(uuidString:)) {
                if let key = userInfo["aiterm.question"] as? String { self = .question(run: id, key: key) } else { self = .board(id) }
            }
            else if let id = (userInfo["aiterm.task"] as? String).flatMap(UUID.init(uuidString:)) { self = .task(id) }
            else { return nil }
        }
    }
    var id: String, title: String, body: String, target: Target
}

/// Where notes go: macOS's notification centre in the app, a recording in a test.
@MainActor
protocol OperatorNotifications: AnyObject {
    /// Asks macOS, once, whether AiTerm may post. Denied, the attention counts and the board still show everything.
    func requestAuthorization()
    func post(_ note: OperatorNote)
    /// Takes the notes with these ids away: out of the notification centre if shown, and unsent if not yet.
    func withdraw(ids: [String])
    /// The ids of the notes macOS shows now: read once at launch, for what an earlier run left behind.
    func readDelivered() async -> [String]
    /// Where a click on a note goes.
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)? { get set }
}

