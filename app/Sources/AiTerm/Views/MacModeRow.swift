import SwiftUI
import AiTermUI
import AiTermCore

/// What Backpack Mode needs from you while it is on. The cutoff wins over a lost hotspot: it is the
/// one that will turn the mode off.
enum BackpackNeed: Equatable { case lostHotspot, lowBattery(level: Int) }

/// The Mac's row in SYSTEM, decided apart from the view so a test reads it (spec 2026-10-05).
enum MacMode: Equatable {
    case desk(ended: BackpackEnded?)
    case turningOn, on, needsYou(BackpackNeed), turningOff

    init(state: BackpackState, transition: BackpackTransition?, ended: BackpackEnded?) {
        switch transition {
        case .turningOn: self = .turningOn
        case .turningOff: self = .turningOff
        case nil:
            guard case .on(let status) = state else { self = .desk(ended: ended); return }
            if status.nearCutoff, let level = status.power.level { self = .needsYou(.lowBattery(level: level)) }
            else if !status.joined { self = .needsYou(.lostHotspot) }
            else { self = .on }
        }
    }

    var isDesk: Bool { if case .desk = self { true } else { false } }
    /// Where the Mac is: on a desk, or in a bag.
    var name: String { isDesk ? "desk" : "backpack" }
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

/// One drawn line: the mode, an optional muted note after the mark, and the tooltip and VoiceOver
/// sentence.
struct MacModeLine: Equatable {
    let mode: MacMode
    let note: String?
    let help: String
}

enum MacModePresentation {
    static func line(mode: MacMode, hotspot: String?, wifi: String?, calendar: Calendar) -> MacModeLine {
        let phone = hotspot ?? "the iPhone"
        let cutoff = BackpackSettings.cutoff
        switch mode {
        case .desk(let ended?):
            let time = clock(ended.at, calendar: calendar)
            let why = switch ended.cause {
            case .agentsStopped: "your agents stopped"
            case .batteryLow(let level): "battery at \(level) %"
            }
            return MacModeLine(mode: mode, note: "· backpack ended \(time)", help: "Backpack Mode ended at \(time): \(why)")
        case .desk(nil):
            let on = wifi.map { $0 == hotspot ? " · still on \($0)" : " · \($0)" } ?? ""
            return MacModeLine(mode: mode, note: nil, help: "desk\(on) · ⌘B turns on Backpack Mode")
        case .turningOn:
            return MacModeLine(mode: mode, note: nil, help: "Turning on Backpack Mode · joining \(phone)")
        case .on:
            return MacModeLine(mode: mode, note: nil, help: "Backpack Mode on · \(phone) · ends when your agents stop, or at \(cutoff) %")
        case .needsYou(.lostHotspot):
            return MacModeLine(mode: mode, note: nil, help: "Backpack Mode needs you · lost \(phone), open Personal Hotspot on the iPhone")
        case .needsYou(.lowBattery(let level)):
            return MacModeLine(mode: mode, note: nil, help: "Backpack Mode needs you · battery at \(level) %, turns off at \(cutoff) %")
        case .turningOff:
            return MacModeLine(mode: mode, note: nil, help: "Turning off Backpack Mode · rejoining Wi-Fi")
        }
    }

    /// 24-hour and padded, as the usage resets are: "14:32".
    static func clock(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
