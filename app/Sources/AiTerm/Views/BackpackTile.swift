import SwiftUI
import AiTermUI
import AiTermCore

/// What Backpack's tile in the status bento draws, decided apart from the view so a test reads it.
/// A turn-on or turn-off under way wins over everything; on, the battery cutoff wins over a lost
/// hotspot, since it is the one that will turn the mode off.
enum BackpackTileState: Equatable {
    case setup, off, turningOn, on, nearCutoff, lostHotspot, turningOff

    init(state: BackpackState, setup: BackpackSetup, transition: BackpackTransition?) {
        switch transition {
        case .turningOn: self = .turningOn
        case .turningOff: self = .turningOff
        case nil:
            if case .on(let status) = state {
                self = status.nearCutoff ? .nearCutoff : (status.joined ? .on : .lostHotspot)
            } else {
                self = setup.isComplete ? .off : .setup
            }
        }
    }

    /// The task row's `StatusMark` on the mark's corner; none while off.
    var corner: TaskStatus? {
        switch self {
        case .setup, .off: nil
        case .turningOn, .turningOff: .working
        case .on: .done
        case .nearCutoff, .lostHotspot: .needsInput
        }
    }

    /// Where the switch points: where the mode is going, while it gets there.
    var switchIsOn: Bool {
        switch self {
        case .turningOn, .on, .nearCutoff, .lostHotspot: true
        case .setup, .off, .turningOff: false
        }
    }
}

/// Backpack Mode's tile in the status bento, one line: its mark, `backpack`, then the switch, or
/// "Set Up…" before setup. The state lives in the mark's corner; the words of it, the hotspot's name
/// included, are the tooltip and VoiceOver's. A right-click offers the settings; ⌘B still works
/// everywhere.
struct BackpackTile: View {
    let backpack: BackpackController
    let openSettings: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        let tile = BackpackTileState(state: backpack.state, setup: backpack.setup, transition: backpack.transition)
        StatusTile(lines: 1) {
            StatusLine { BackpackMark(tile: tile, size: scale(Size.vendorMark)) } words: {
                Text("backpack").foregroundStyle(Palette.muted)
                Spacer(minLength: 0)
                if tile == .setup {
                    Button("Set Up…", action: openSettings)
                        .buttonStyle(.plain)
                        .font(Typography.help)
                        .foregroundStyle(Palette.link)
                        .accessibilityLabel(BackpackPresentation.tileLabel(tile, state: backpack.state))
                } else {
                    SettingsSwitch(title: BackpackPresentation.tileLabel(tile, state: backpack.state),
                                   isOn: Binding(get: { tile.switchIsOn }, set: { _ in backpack.toggle() }))
                        .disabled(backpack.busy)
                }
            }
        }
        .help(BackpackPresentation.tileHelp(tile, state: backpack.state, setup: backpack.setup))
        .contextMenu { Button("Backpack Settings…", action: openSettings) }
    }
}

/// Backpack's mark: `SymbolMark` with the mode's glyph, in `Palette.muted` before setup, and the
/// state's `StatusMark` on its bottom-trailing corner at `Size.statusMarkSmall`, ringed in
/// `Palette.badgeSolid` (the tile's ground) so the dot reads apart from the disc.
struct BackpackMark: View {
    let tile: BackpackTileState
    let size: CGFloat
    @Environment(\.interfaceScale) private var scale
    /// How far the corner dot reaches past the disc: inside the `Space.snug` gap before the words,
    /// so it never reaches the text column. The dot's own geometry; no token fits.
    private static let overhang: CGFloat = 3
    /// The ring round the dot, in `badgeSolid`. A stroke-like edge, so it does not scale.
    private static let ring: CGFloat = 1

    var body: some View {
        SymbolMark(symbol: BackpackPresentation.symbol, size: size, tint: tile == .setup ? Palette.muted : Palette.text)
            .overlay(alignment: .bottomTrailing) {
                if let corner = tile.corner {
                    StatusMark(status: corner, size: scale(Size.statusMarkSmall))
                        .padding(Self.ring)
                        .background(Circle().fill(Palette.badgeSolid))
                        .offset(x: scale(Self.overhang), y: scale(Self.overhang))
                }
            }
    }
}
