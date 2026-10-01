import SwiftUI
import AiTermCore
import AiTermUI

/// The iTerm2 card's status line and, when something is broken, the numbered steps that fix it.
struct ItermCard: Equatable {
    var status: SettingsStatus
    var steps: [String] = []
}

enum ItermCardPresentation {
    static let summary = "AiTerm’s Python helper drives iTerm2 through its Python API."

    /// While a test runs the status line says so, but the steps stay: they are still what to do if
    /// the answer comes back the same, and dropping them would make the card jump.
    static func card(for connection: ItermConnection, environment: ItermEnvironment?, testing: Bool) -> ItermCard {
        let card = diagnose(connection, environment: environment)
        return testing ? ItermCard(status: SettingsStatus(.idle, "Testing…"), steps: card.steps) : card
    }

    /// The first broken link in the chain AiTerm → Python → helper → iTerm2 names the card.
    /// Helper-side states come from the helper itself; past it, the helper cannot tell an iTerm2
    /// that is missing, or has its API switched off, from one that is still launching, so iTerm2's
    /// own installation and preference answer that before the helper's view is shown.
    private static func diagnose(_ connection: ItermConnection, environment: ItermEnvironment?) -> ItermCard {
        switch connection {
        case .connected:
            return ItermCard(status: SettingsStatus(.ready, connection.status))
        case .starting, .helperUnreachable:
            return ItermCard(status: SettingsStatus(.idle, connection.status))
        case .pythonMissing:
            return ItermCard(status: SettingsStatus(.attention, connection.status), steps: [
                "Install it with brew install python",
                "Quit and reopen AiTerm",
            ])
        case .helperMissing:
            return ItermCard(status: SettingsStatus(.attention, connection.status), steps: [
                "Reinstall AiTerm.app, which bundles the helper",
                "Open it again; the helper starts by itself",
            ])
        case .helperFailing:
            return ItermCard(status: SettingsStatus(.attention, connection.status), steps: [
                "Read why in \(ItermConnection.logPath)",
                "Quit and reopen AiTerm once it is fixed",
            ])
        case .helperMismatch:
            return ItermCard(status: SettingsStatus(.attention, connection.status), steps: [
                "Quit and reopen AiTerm.app",
            ])
        case .waitingForIterm, .itermReconnecting, .refused:
            if environment?.installed == false {
                return ItermCard(status: SettingsStatus(.attention, "iTerm2 is not installed"), steps: [
                    "Download iTerm2 from iterm2.com",
                    "Move it to Applications and open it once",
                    "AiTerm connects on its own within a few seconds",
                ])
            }
            if environment?.pythonAPIEnabled == false {
                return ItermCard(status: SettingsStatus(.attention, "iTerm2’s Python API is off"), steps: [
                    "Open iTerm2 › Settings › General › Magic",
                    "Turn on “Enable Python API”",
                    "AiTerm reconnects on its own within a few seconds",
                ])
            }
            switch connection {
            case .refused:
                return ItermCard(status: SettingsStatus(.attention, connection.status), steps: [
                    "Open System Settings › Privacy & Security › Automation",
                    "Under AiTerm, turn on iTerm2",
                    "AiTerm retries on its own within a minute",
                ])
            default:
                return ItermCard(status: SettingsStatus(.idle, connection.status))
            }
        }
    }
}

/// The Integrations tab's first card: the connection AiTerm drives iTerm2 through. It has no fields —
/// below its rule it lists the numbered steps that mend the first broken link, or one line of
/// `HelpText` when nothing is broken.
struct ItermSettingsCard: View {
    let card: ItermCard

    var body: some View {
        SettingsCard(title: "iTerm2", status: card.status) {
            IntegrationMark(service: .iterm, size: Size.control)
        } content: {
            if card.steps.isEmpty {
                HelpText(ItermCardPresentation.summary)
            } else {
                steps
            }
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            ForEach(Array(card.steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.base) {
                    Text("\(index + 1)").font(Typography.mono).foregroundStyle(Palette.muted)
                    Text(step).font(Typography.caption).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
