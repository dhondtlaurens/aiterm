import Foundation
import AiTermCore

struct OperatorNote: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case operatorWindow, task(UUID)
        var userInfo: [String: String] {
            switch self { case .operatorWindow: ["aiterm.operator": "true"]; case .task(let id): ["aiterm.task": id.uuidString] }
        }
        init?(userInfo: [AnyHashable: Any]) {
            if userInfo["aiterm.operator"] as? String == "true" { self = .operatorWindow }
            else if let id = (userInfo["aiterm.task"] as? String).flatMap(UUID.init(uuidString:)) { self = .task(id) }
            else { return nil }
        }
    }
    var id: String, title: String, body: String, target: Target
}

enum SignalQuestionNotification {
    static let id = "aiterm.operator.questions"
    static func make(state: AppState) -> OperatorNote? {
        let questions = state.currentOperatorQuestions
        guard !questions.isEmpty else { return nil }
        func name(_ question: OperatorSession.Question) -> String {
            guard let task = question.task.flatMap({ state.task(id: $0) }) else { return "Operator" }
            return [task.jira?.key, task.title].compactMap { $0 }.joined(separator: " ")
        }
        let title = questions.count == 1 ? "The Operator has a question" : "The Operator has \(questions.count) questions"
        let body = questions.count == 1 ? name(questions[0]) + ": " + questions[0].text : questions.map(name).joined(separator: " · ")
        return OperatorNote(id: id, title: title, body: body, target: .operatorWindow)
    }
}

@MainActor protocol OperatorNotifications: AnyObject {
    func requestAuthorization()
    func post(_ note: OperatorNote)
    func withdraw(ids: [String])
    func readDelivered() async -> [String]
    var onOpen: (@MainActor (OperatorNote.Target) -> Void)? { get set }
}
