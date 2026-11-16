import SwiftUI
import AiTermCore
import AiTermUI

/// A short act keeps its place for three seconds; a new act replaces it immediately.
struct SignalBadgePose: Equatable {
    static let hold: TimeInterval = 3
    private(set) var display: OperatorLine?
    private var requested: OperatorLine?
    private var until: TimeInterval = 0
    mutating func update(_ line: OperatorLine?, at: TimeInterval) {
        if line?.look == .acting && line != requested { until = at + Self.hold; display = line }
        else if display?.look != .acting || at >= until { display = line }
        requested = line
    }
    func delay(at: TimeInterval) -> TimeInterval { display != requested ? max(0, until - at) : 0 }
}

/// A driven task's third line, under its badge line, which stays as any task's: what the Operator says of it,
/// in the operator badge, a short act held for `SignalBadgePose.hold`. While the Operator says nothing of a task
/// that works the line reads a quiet `working`, and otherwise it stays empty at its height, so the row is as tall
/// whatever the Operator says and never jumps.
struct SignalStatusLine: View {
    let line: OperatorLine?
    /// The row works (`working`, or `background`): the words it reads when the Operator says nothing.
    let working: Bool
    @Environment(\.interfaceScale) private var scale
    @Environment(\.motionStill) private var motionStill
    @State private var pose = SignalBadgePose()

    /// What the line reads while the Operator says nothing of a task that works.
    static let working = OperatorLine("working")

    /// The words drawn: the held act, else the line, else `working` while the row works.
    static func shown(held: OperatorLine?, line: OperatorLine?, working: Bool) -> OperatorLine? {
        held ?? line ?? (working ? Self.working : nil)
    }

    var body: some View {
        // Before its first update the pose holds nothing, and the line itself is what it would hold.
        let shown = Self.shown(held: motionStill == .snapshot ? nil : pose.display, line: line, working: working)
        ZStack(alignment: .leading) {
            if let shown { OperatorBadge(line: shown) }
        }
        .frame(maxWidth: .infinity, minHeight: scale(Size.chip), maxHeight: scale(Size.chip), alignment: .leading)
        .task(id: line) {
            guard motionStill != .snapshot else { return }
            pose.update(line, at: ProcessInfo.processInfo.systemUptime)
            let wait = pose.delay(at: ProcessInfo.processInfo.systemUptime)
            guard wait > 0 else { return }
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            pose.update(line, at: ProcessInfo.processInfo.systemUptime)
        }
    }
}
