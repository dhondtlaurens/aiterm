import SwiftUI
import AiTermUI
import AiTermCore

/// The operator's mark: `SymbolMark`'s `.paper` style — `Palette.markInk` on `Palette.markPaper`, the
/// vendor discs' recipe — with `headphones`, the operator on the line, the same for every operator; its
/// name says which (spec §10.2, picked 16 Oct 2026). Beside Codex's white disc, the glyph and the ring
/// tell them apart.
///
/// In a task's avatar group it comes first while the operator drives the task, ringed in the surface's
/// occluding colour as every mark there is. While the operator acts on the task it also wears a
/// `activityRing` accent ring just outside that one, which breathes — fading to `breathLow` and
/// back — and stands still at full strength under Reduce Motion and in the snapshots. A stroke: it
/// does not scale.
struct OperatorAvatar: View {
    static let symbol = "headphones"
    /// The breath's low point: the ring fades to this and back, never out, so it always reads as on.
    private static let breathLow = 0.35
    /// One breath, in or out, in seconds — slower than `StatusMark`'s spin, so the two never read as one motion.
    private static let breathDuration = 0.8
    /// The breathing accent ring's stroke width: a stroke, so it does not scale. Was `Size.activityRing`
    /// until the greenfield design dropped the ring (the operator badge replaces this mark); kept here,
    /// this mark's own number, while the mark is still drawn.
    private static let activityRing: CGFloat = 1.5
    let presence: OperatorPresence?
    /// Points on screen: the avatar group passes its own scaled `Size.avatar`.
    let size: CGFloat
    @Environment(\.surface) private var surface
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.stillSpinners) private var still
    #else
    private let still = false
    #endif
    // `@State` is a macro in the macOS 26 SDK and its plugin ships only with Xcode; this is the storage
    // the macro would generate.
    private var _faded = State(initialValue: false)
    private var faded: Bool {
        get { _faded.wrappedValue }
        nonmutating set { _faded.wrappedValue = newValue }
    }

    init(presence: OperatorPresence?, size: CGFloat) { self.presence = presence; self.size = size }

    /// Whether the ring moves: only while acting, never under Reduce Motion, never in a snapshot.
    static func breathes(_ presence: OperatorPresence?, reduceMotion: Bool, still: Bool) -> Bool {
        presence == .acting && !reduceMotion && !still
    }

    /// How far the accent ring's centre line sits outside the disc: past the occluding ring's outer
    /// half, then half its own width, so the two rings touch and do not overlap.
    private static var ringOutset: CGFloat { AvatarGroupView.ringWidth / 2 + Self.activityRing / 2 }

    var body: some View {
        SymbolMark(symbol: Self.symbol, size: size, style: .paper)
            .overlay(Circle().stroke(surface.occludingBackground, lineWidth: AvatarGroupView.ringWidth))
            .overlay {
                if presence == .acting {
                    Circle().stroke(Palette.accent, lineWidth: Self.activityRing)
                        .padding(-Self.ringOutset)
                        .opacity(faded ? Self.breathLow : 1)
                }
            }
            .onAppear(perform: breathe)
            .onChange(of: presence) { _, _ in breathe() }
            .accessibilityElement()
            .accessibilityLabel(presence == .acting ? "Operator, acting on this task" : "Operator")
    }

    private func breathe() {
        guard Self.breathes(presence, reduceMotion: reduceMotion, still: still) else { faded = false; return }
        withAnimation(.easeInOut(duration: Self.breathDuration).repeatForever(autoreverses: true)) { faded = true }
    }
}
