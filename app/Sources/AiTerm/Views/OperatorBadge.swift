import SwiftUI
import AiTermUI
import AiTermCore

/// Everything the Operator says on a status line (spec §7, §13, §14): its agent's mark (Claude's), the
/// Oracle's joining it while the Oracle is consulted, then the words of an `OperatorLine` in
/// `Typography.monoChip`. Always one `Size.chip` line: the words cut with an ellipsis rather than wrap,
/// the whole of them in the tooltip and VoiceOver's label. The third line of a driven task's row and of
/// the broadcast row, a card's last line on the board, the band under the board's title.
///
/// It reads its ground (`Surface`), as `RowCaption(warns:)` does:
/// - quiet: no box, the words in the surface's secondary ink;
/// - acting: no box, the words shimmering, a light band sweeping from the surface's secondary ink through
///   its ink every `shimmerPeriod`; standing still in the surface's ink under Reduce Motion and in the
///   snapshots;
/// - needs you: the attention chip's pair (`Palette.statusChipAttentionFill` and `Stroke`) with the words
///   in `Palette.text`, never amber; on `Surface.accent` the surface's `badgeWash` and ink, the amber left
///   to the row's `StatusMark`, since an amber wash on the selection's blue reads as mud.
///
/// The marks are `VendorMark`s at `Size.inlineMark`, the Oracle's overlapping the Operator's by
/// `Space.tight`, ringed in the surface's occluding colour as `AvatarGroupView` rings its marks.
struct OperatorBadge: View {
    let line: OperatorLine
    @Environment(\.surface) private var surface
    @Environment(\.interfaceScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.stillSpinners) private var still
    #else
    private let still = false
    #endif

    /// One sweep of the shimmer, in seconds: about 1.6 s, as picked (19 Oct 2026).
    static let shimmerPeriod = 1.6
    /// The ring that sets the Oracle's mark off the Operator's under it: a stroke, so it does not scale.
    private static let markRing: CGFloat = 1

    /// The box a look draws, when it draws one.
    struct Box: Equatable { var fill: Color; var stroke: Color? }

    /// Whether the words move: only while acting, never under Reduce Motion, never in a snapshot.
    static func shimmers(_ look: OperatorLine.Look, reduceMotion: Bool, still: Bool) -> Bool {
        look == .acting && !reduceMotion && !still
    }

    /// The words' ink. Shimmering, the band of the surface's ink sweeps over the secondary ink.
    static func ink(_ look: OperatorLine.Look, surface: Surface, shimmering: Bool) -> Color {
        switch look {
        case .quiet: surface.secondaryInk
        case .acting: shimmering ? surface.secondaryInk : surface.ink
        case .needsYou: surface.isOnAccent ? surface.ink : Palette.text
        }
    }

    /// Only needs-you has a box: the attention chip's fill and edge, or on the accent its wash alone.
    static func box(_ look: OperatorLine.Look, surface: Surface) -> Box? {
        guard look == .needsYou else { return nil }
        return surface.isOnAccent ? Box(fill: surface.badgeWash, stroke: nil)
            : Box(fill: Palette.statusChipAttentionFill, stroke: Palette.statusChipAttentionStroke)
    }

    /// The marks it leads with: the Operator's, and the Oracle's beside it while consulted.
    static func marks(_ line: OperatorLine) -> [SessionAgent] {
        [.claude] + (line.oracle ? [line.oracleAgent.session] : [])
    }

    var body: some View {
        let shimmering = Self.shimmers(line.look, reduceMotion: reduceMotion, still: still)
        let box = Self.box(line.look, surface: surface)
        HStack(spacing: scale(Space.tight)) {
            HStack(spacing: -scale(Space.tight)) {
                ForEach(Array(Self.marks(line).enumerated()), id: \.offset) { index, agent in
                    VendorMark(agent: agent, size: scale(Size.inlineMark))
                        .overlay {
                            if index > 0 { Circle().stroke(surface.occludingBackground, lineWidth: Self.markRing) }
                        }
                }
            }
            .fixedSize()
            words(shimmering: shimmering)
        }
        .padding(.horizontal, box == nil ? 0 : scale(Space.tight))
        .frame(height: scale(Size.chip))
        .background {
            if let box {
                RoundedRectangle(cornerRadius: scale(Radius.chip)).fill(box.fill)
                    .overlay { if let stroke = box.stroke { RoundedRectangle(cornerRadius: scale(Radius.chip)).strokeBorder(stroke) } }
            }
        }
        .help(line.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.tooltip)
    }

    private func words(shimmering: Bool) -> some View {
        Text(line.text)
            .font(Typography.monoChip)
            .foregroundStyle(Self.ink(line.look, surface: surface, shimmering: shimmering))
            .lineLimit(1)
            .truncationMode(.tail)
            .overlay {
                if shimmering {
                    ShimmerBand(ink: surface.ink, period: Self.shimmerPeriod)
                        .mask(Text(line.text).font(Typography.monoChip).lineLimit(1).truncationMode(.tail))
                }
            }
    }
}

/// The shimmer's light: a band of `ink`, fading in and out at its edges, swept across its width and off
/// it again every `period`. Its own view, so each time the words start acting the sweep starts afresh.
private struct ShimmerBand: View {
    let ink: Color
    let period: Double
    /// The band's width, as a share of the words'.
    private static let bandShare: CGFloat = 0.4
    // `@State` is a macro in the macOS 26 SDK and its plugin ships only with Xcode; this is the storage
    // the macro would generate.
    private var _swept = State(initialValue: false)
    private var swept: Bool {
        get { _swept.wrappedValue }
        nonmutating set { _swept.wrappedValue = newValue }
    }

    init(ink: Color, period: Double) { self.ink = ink; self.period = period }

    var body: some View {
        GeometryReader { geometry in
            let band = geometry.size.width * Self.bandShare
            LinearGradient(colors: [.clear, ink, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: band)
                .offset(x: swept ? geometry.size.width : -band)
        }
        .allowsHitTesting(false)
        .onAppear {
            withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) { swept = true }
        }
    }
}
