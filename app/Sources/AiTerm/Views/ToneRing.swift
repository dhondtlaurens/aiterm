import SwiftUI
import AiTermUI

/// The three states every Settings card speaks, whether it describes a harness or a service, and
/// the footer's backpack line speaks too (proposal 2A, 6 Oct 2026): the Mac card says "Ready for
/// backpack mode" in this voice, so the footer says the mode is on in it.
enum SettingsTone: Equatable {
    case ready
    case attention
    case idle

    var color: Color {
        switch self {
        case .ready: Palette.green
        case .attention: Palette.amber
        case .idle: Palette.muted
        }
    }
}

/// A tone's ring, led into the words it colours: a Settings card's status line and the footer's
/// backpack line. Drawn to `StatusMark`'s recipe — a `size * 0.15` stroke inside `size` — so every
/// round mark is a ring (proposal 1A, 21 Oct 2026), but not a `StatusMark`, which is an agent's
/// state: the two kinds of ring keep one meaning each. `size` is points on screen — a card passes
/// `Size.statusMarkSmall`, the footer `scale(Size.statusMarkSmall)`.
struct ToneRing: View {
    let tone: SettingsTone
    let size: CGFloat

    var body: some View {
        Circle().strokeBorder(tone.color, lineWidth: size * 0.15).frame(width: size, height: size)
    }
}
