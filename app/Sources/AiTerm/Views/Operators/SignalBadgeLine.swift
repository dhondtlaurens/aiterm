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
    /// Whether the badge line plays the decode: only when an act ends on its own. Under the pointer the
    /// badges are simply there, so a row never animates text it was already showing.
    static func decodes(returning: Bool, hovering: Bool) -> Bool { returning && !hovering }
}

/// Replaces the entire badge line, preserving its height and its clickable badges on hover.
struct SignalBadgeLine<Badges: View>: View {
    let line: OperatorLine?
    let normalText: String
    let enabled: Bool
    @ViewBuilder var badges: () -> Badges
    @Environment(\.interfaceScale) private var scale
    @Environment(\.surface) private var surface
    @Environment(\.motionStill) private var motionStill
    @State private var pose = SignalBadgePose()
    @State private var hovering = false
    @State private var returning = false
    private struct Stamp: Equatable { var line: OperatorLine?; var hovering: Bool; var enabled: Bool }
    var body: some View {
        let shown = enabled ? (motionStill == .snapshot ? line : pose.display) : nil
        let normal = hovering || shown == nil
        let decoding = normal && SignalBadgePose.decodes(returning: returning, hovering: hovering)
        ZStack(alignment: .leading) {
            badges().opacity(normal && !decoding ? 1 : 0).allowsHitTesting(normal && !decoding)
            if decoding {
                DecodeWords(text: normalText, font: Typography.chip.scaled(by: scale).nsFont,
                            ink: surface.secondaryInk, duration: OperatorBadge.decodeDuration)
                    .allowsHitTesting(false).accessibilityHidden(true)
            } else if !normal, let shown { OperatorBadge(line: shown).allowsHitTesting(false) }
        }
        .frame(height: scale(Size.chip))
        .onHover { hovering = $0 }
        .task(id: Stamp(line: line, hovering: hovering, enabled: enabled)) {
            guard motionStill != .snapshot else { return }
            let wasNormal = hovering || pose.display == nil
            pose.update(enabled ? line : nil, at: ProcessInfo.processInfo.systemUptime)
            // Hover returns the badges at once, without a decode, even while a finished act is held.
            let wait = enabled ? pose.delay(at: ProcessInfo.processInfo.systemUptime) : 0
            if wait > 0 {
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                pose.update(line, at: ProcessInfo.processInfo.systemUptime)
            }
            if !hovering && pose.display == nil && !wasNormal && motionStill == nil {
                returning = true
                try? await Task.sleep(for: .seconds(OperatorBadge.decodeDuration))
                guard !Task.isCancelled else { return }
            }
            returning = false
        }
    }
}
