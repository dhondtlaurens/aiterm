import SwiftUI
import AiTermUI
import AiTermCore

/// Settings › Backpack's words, decided apart from the view so a test reads them.
enum BackpackPresentation {
    static func status(state: BackpackState, setup: BackpackSetup) -> SettingsStatus {
        if case .on(let status) = state {
            if !status.joined { return SettingsStatus(.attention, "On · not joined to \(status.network), rejoining when it’s in range") }
            if status.nearCutoff, let level = status.power.level {
                return SettingsStatus(.attention, "On · battery \(level) %, turns off at \(status.cutoff) %")
            }
            if status.power.onBattery, let level = status.power.level {
                return SettingsStatus(.ready, "On · joined \(status.network) · battery \(level) %")
            }
            return SettingsStatus(.ready, "On · joined \(status.network)")
        }
        if !setup.missingSteps.isEmpty { return SettingsStatus(.attention, "Needs setup") }
        guard let network = setup.network else { return SettingsStatus(.idle, "Off · choose a Wi-Fi network below") }
        return SettingsStatus(.idle, "Off · ⌘B turns it on when \(network) is in range")
    }

    static func steps(setup: BackpackSetup) -> [String] {
        setup.missingSteps.map {
            switch $0 {
            case .sleepRule: "Allow AiTerm to keep the Mac awake with the lid closed. Asks for your password once."
            case .location: "Allow Location access, so AiTerm can see which Wi-Fi networks are in range."
            }
        }
    }

    /// The header glyph's tooltip, VoiceOver label and menu line.
    static func summary(_ status: BackpackStatus) -> String {
        guard status.joined else { return "Backpack Mode is on · not joined to \(status.network)" }
        guard status.power.onBattery, let level = status.power.level else { return "Backpack Mode is on · \(status.network)" }
        return "Backpack Mode is on · \(status.network) · battery \(level) %, turns off at \(status.cutoff) %"
    }

    /// "None" first, then the chosen network if the Mac no longer lists it, then the known ones.
    static func choices(known: [String], current: String?) -> [String?] {
        let kept = current.map { known.contains($0) ? [] : [$0] } ?? []
        return [nil] + (kept + known).map(Optional.some)
    }
}

/// The round mark on the Backpack card: the SF Symbol on a neutral disc, as the service marks sit on theirs.
struct BackpackMark: View {
    let size: CGFloat
    /// The glyph's optical size inside a `Size.control` disc. One call site; a symbol's ink box is
    /// not a logo's, so `LogoFit` does not apply and no `Size` step fits.
    private static let glyphRatio: CGFloat = 0.5

    var body: some View {
        ZStack {
            Circle().fill(Palette.controlActive)
            Icon(.symbol("backpack.fill"), size: size * Self.glyphRatio, tint: Palette.text)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Settings › Backpack: one card. Set Up… and Remove Setup act at once, as a harness card's Install
/// does; the two fields wait for Save.
struct BackpackSettingsPane: View {
    let backpack: BackpackController
    let network: Binding<String?>
    let password: Binding<String>
    let cutoff: Binding<Int>
    let knownNetworks: [String]

    var body: some View {
        SettingsCard(title: "Backpack Mode", status: BackpackPresentation.status(state: backpack.state, setup: backpack.setup)) {
            BackpackMark(size: SettingsCard<EmptyView, EmptyView, EmptyView, EmptyView>.markSize)
        } chips: {
            EmptyView()
        } actions: {
            if !backpack.setup.missingSteps.isEmpty {
                Button("Set Up…") { Task { await backpack.setUp() } }.disabled(backpack.busy)
            } else {
                Button("Remove Setup") { Task { await backpack.removeSetup() } }.disabled(backpack.busy)
            }
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                let steps = BackpackPresentation.steps(setup: backpack.setup)
                if !steps.isEmpty { stepList(steps) }
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Wi-Fi network") {
                        Select(values: BackpackPresentation.choices(known: knownNetworks, current: network.wrappedValue),
                               selection: network, label: { $0 ?? "None" })
                        HelpText("Networks this Mac already knows.")
                    }
                    .frame(maxWidth: .infinity)
                    FormField("Password") {
                        Input(placeholder: "The network’s password", text: password, secure: true)
                        HelpText("Saved in Keychain. A phone shows it under Personal Hotspot.")
                    }
                    .frame(maxWidth: .infinity)
                }
                FormField("Turn off below") {
                    Select(values: BackpackSettings.cutoffChoices, selection: cutoff, label: { "\($0) % battery" })
                    HelpText("So the Mac can still sleep before it runs out.")
                }
                HelpText("Keeps the Mac awake with the lid closed and joins this network. It turns off on its own below the battery level and when AiTerm quits. A phone’s hotspot can only be found while its Personal Hotspot screen is open.")
            }
        }
    }

    /// `ItermSettingsCard`'s numbered steps.
    private func stepList(_ steps: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.base) {
                    Text("\(index + 1)").font(Typography.mono).foregroundStyle(Palette.muted)
                    Text(step).font(Typography.caption).foregroundStyle(Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
