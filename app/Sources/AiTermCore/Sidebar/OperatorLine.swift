import Foundation

public struct OperatorLine: Equatable, Sendable {
    public enum Look: Equatable, Sendable { case quiet, ended, acting, needsYou }
    public var text: String
    public var look: Look
    /// The whole of what the line says: the request's sentence, or the words before they were cut.
    public var tooltip: String

    public init(_ text: String, look: Look = .quiet, tooltip: String? = nil) {
        self.text = text; self.look = look; self.tooltip = tooltip ?? text
    }

    /// The most characters a line says before its detail is cut: what the sidebar's status line holds, in
    /// `Typography.chip`, at the sidebar's narrowest.
    public static let maxLength = 40

    /// The Operator row's line while its session works and AiTerm carries out no act of its own.
    public static let working = OperatorLine("working", look: .acting)
    /// The Operator row's line while its window is closed.
    public static let windowClosed = OperatorLine("window closed")
    /// A paused worker's line once it has stopped. The row wears the pause sign with it.
    public static let paused = OperatorLine("paused")
}
