import SwiftUI
import AiTermUI
import AiTermCore

/// What Backpack Mode needs from you while it is on. The cutoff wins over a lost hotspot: it is the
/// one that will turn the mode off.
enum BackpackNeed: Equatable { case lostHotspot, lowBattery(level: Int) }

/// The Mac's row in SYSTEM, decided apart from the view so a test reads it (spec 2026-10-05).
enum MacMode: Equatable {
    case desk
    case turningOn, on, needsYou(BackpackNeed), turningOff

    init(state: BackpackState, transition: BackpackTransition?) {
        switch transition {
        case .turningOn: self = .turningOn
        case .turningOff: self = .turningOff
        case nil:
            guard case .on(let status) = state else { self = .desk; return }
            if status.nearCutoff, let level = status.power.level { self = .needsYou(.lowBattery(level: level)) }
            else if !status.joined { self = .needsYou(.lostHotspot) }
            else { self = .on }
        }
    }

    var isDesk: Bool { if case .desk = self { true } else { false } }
    /// Where the Mac is: on a desk, or in a bag.
    var name: String { isDesk ? "desk mode" : "backpack mode" }
    /// The Mac on its own, or the Mac through the iPhone.
    var symbol: String { isDesk ? "macbook" : "iphone" }
    /// The task row's `StatusMark` after the name: the row's one colour. None at the desk.
    var mark: TaskStatus? {
        switch self {
        case .desk: nil
        case .turningOn, .turningOff: .working
        case .on: .done
        case .needsYou: .needsInput
        }
    }
}

/// One drawn line: the mode, and the tooltip and VoiceOver sentence.
struct MacModeLine: Equatable {
    let mode: MacMode
    let help: String
}

enum MacModePresentation {
    static func line(mode: MacMode, hotspot: String?, wifi: String?) -> MacModeLine {
        let phone = hotspot ?? "the iPhone"
        let cutoff = BackpackSettings.cutoff
        switch mode {
        case .desk:
            let on = wifi.map { $0 == hotspot ? " · still on \($0)" : " · \($0)" } ?? ""
            return MacModeLine(mode: mode, help: "desk mode\(on) · ⌘B turns on backpack mode")
        case .turningOn:
            return MacModeLine(mode: mode, help: "Turning on backpack mode · joining \(phone)")
        case .on:
            return MacModeLine(mode: mode, help: "Backpack mode on · \(phone) · ends when your agents stop, or at \(cutoff) %")
        case .needsYou(.lostHotspot):
            return MacModeLine(mode: mode, help: "Backpack mode needs you · lost \(phone), open Personal Hotspot on the iPhone")
        case .needsYou(.lowBattery(let level)):
            return MacModeLine(mode: mode, help: "Backpack mode needs you · battery at \(level) %, turns off at \(cutoff) %")
        case .turningOff:
            return MacModeLine(mode: mode, help: "Turning off backpack mode · rejoining Wi-Fi")
        }
    }
}
