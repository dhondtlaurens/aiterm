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
