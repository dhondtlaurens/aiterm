import SwiftUI
import AiTermUI
import AiTermCore

/// Settings › Backpack's words, decided apart from the view so a test reads them.
enum BackpackPresentation {
    /// Mac permissions' status line: what is missing, or Ready.
    static func permissions(setup: BackpackSetup) -> SettingsStatus {
        switch (setup.sleepRule, setup.location) {
        case (false, false): SettingsStatus(.attention, "Not set up")
        case (false, true): SettingsStatus(.attention, "Needs lid-sleep access")
        case (true, false): SettingsStatus(.attention, "Needs Location access")
        case (true, true): SettingsStatus(.ready, "Ready")
        }
    }

    /// `ItermSettingsCard`'s numbered steps, for what is missing.
    static func steps(setup: BackpackSetup) -> [String] {
        setup.missingSteps.map {
            switch $0 {
            case .sleepRule: "Allow AiTerm to keep the Mac awake with the lid closed. Asks for your Mac’s password once."
            case .location: "Allow AiTerm to see nearby Wi-Fi networks. macOS hides their names from apps without Location access; AiTerm never reads where you are."
            }
        }
    }

    static let permissionsSummary = "AiTerm can keep the Mac awake with the lid closed and see nearby Wi-Fi networks. Remove takes the lid-sleep rule out again."

    /// Hotspot's status line: the mode's own, beside the network it names.
    static func hotspot(state: BackpackState, setup: BackpackSetup) -> SettingsStatus {
        if case .on(let status) = state {
            return status.joined ? SettingsStatus(.ready, "On · joined \(status.network)")
                                 : SettingsStatus(.attention, "On · not joined to \(status.network), rejoining")
        }
        return setup.network == nil ? SettingsStatus(.idle, "Choose a network") : SettingsStatus(.idle, "Ready · ⌘B turns Backpack Mode on")
    }

    /// Battery's status line: the level and what the Mac runs on, amber close to the cutoff while on.
    static func battery(power: PowerReading, state: BackpackState, cutoff: Int) -> SettingsStatus {
        guard let level = power.level else { return SettingsStatus(.idle, "No battery") }
        if case .on(let status) = state, status.nearCutoff { return SettingsStatus(.attention, "\(level) % · turns off at \(cutoff) %") }
        return SettingsStatus(.idle, power.onBattery ? "\(level) % · on battery" : "\(level) % · on the charger")
    }

    /// The header glyph's tooltip, VoiceOver label and menu line.
    static func summary(_ status: BackpackStatus) -> String {
        guard status.joined else { return "Backpack Mode is on · not joined to \(status.network)" }
        guard status.power.onBattery, let level = status.power.level else { return "Backpack Mode is on · \(status.network)" }
        return "Backpack Mode is on · \(status.network) · battery \(level) %, turns off at \(status.cutoff) %"
    }

    /// The header menu's first line: the state, and what turning it on would do.
    static func menuLine(state: BackpackState, setup: BackpackSetup) -> String {
        if case .on(let status) = state { return summary(status) }
        guard setup.isComplete, let network = setup.network else { return "Backpack Mode needs setup" }
        return "Backpack Mode is off · joins \(network)"
    }

    /// "None" first, then the chosen network if the Mac no longer lists it, then the known ones.
    static func choices(known: [String], current: String?) -> [String?] {
        let kept = current.map { known.contains($0) ? [] : [$0] } ?? []
        return [nil] + (kept + known).map(Optional.some)
    }
}

/// A Settings card's round mark for something that is not a vendor: an SF Symbol on a neutral
/// disc, in the family of `IntegrationMark`.
struct SymbolMark: View {
    let symbol: String
    let size: CGFloat
    /// The glyph's optical size inside a `Size.control` disc. A symbol's ink box is not a logo's, so
    /// `LogoFit` does not apply, and no `Size` step fits.
    private static let glyphRatio: CGFloat = 0.5

    var body: some View {
        ZStack {
            Circle().fill(Palette.controlActive)
            Icon(.symbol(symbol), size: size * Self.glyphRatio, tint: Palette.text)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Settings › Backpack: Mac permissions, Hotspot and Battery, each a `SettingsCard` like the other
/// tabs'. Allow… and Remove act at once, as a harness card's Install does; the fields wait for Save.
struct BackpackSettingsPane: View {
    let backpack: BackpackController
    let network: Binding<String?>
    let password: Binding<String>
    let cutoff: Binding<Int>
    let knownNetworks: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            permissions
            hotspot
            battery
        }
    }

    /// A harness card's anatomy: checks beside the title, one action named by the state.
    private var permissions: some View {
        let setup = backpack.setup
        return SettingsCard(title: "Mac permissions", status: BackpackPresentation.permissions(setup: setup)) {
            SymbolMark(symbol: "lock.fill", size: Size.control)
        } chips: {
            check("Lid sleep", passed: setup.sleepRule)
            check("Location", passed: setup.location)
        } actions: {
            if backpack.busy { ProgressView().controlSize(.small) }
            if setup.missingSteps.isEmpty {
                Button("Remove") { Task { await backpack.removeSetup() } }.disabled(backpack.busy)
            } else {
                Button("Allow…") { Task { await backpack.setUp() } }.disabled(backpack.busy)
            }
        } content: {
            let steps = BackpackPresentation.steps(setup: setup)
            if steps.isEmpty { HelpText(BackpackPresentation.permissionsSummary) } else { stepList(steps) }
        }
    }

    /// A service card's anatomy: the fields side by side, then where the secret goes.
    private var hotspot: some View {
        SettingsCard(title: "Hotspot", status: BackpackPresentation.hotspot(state: backpack.state, setup: backpack.setup)) {
            SymbolMark(symbol: "personalhotspot", size: Size.control)
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Network") {
                        Select(values: BackpackPresentation.choices(known: knownNetworks, current: network.wrappedValue),
                               selection: network, label: { $0 ?? "None" })
                    }
                    .frame(maxWidth: .infinity)
                    FormField("Password") {
                        Input(placeholder: "The network’s password", text: password, secure: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                HelpText("Open Personal Hotspot on the phone before you turn it on. Save stores the password in Keychain.")
            }
        }
    }

    /// Sidebar size's control, under a card of its own for the level it reports.
    private var battery: some View {
        let status = BackpackPresentation.battery(power: backpack.power, state: backpack.state, cutoff: cutoff.wrappedValue)
        return SettingsCard(title: "Battery", status: status) {
            SymbolMark(symbol: "battery.75percent", size: Size.control)
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                FormField("Turn off below") {
                    SegmentedControl(values: BackpackSettings.cutoffChoices, selection: cutoff) { value, on in
                        Text("\(value) %").font(Typography.body).foregroundStyle(on ? Palette.text : Palette.muted)
                    }
                }
                HelpText("So the Mac can still sleep before it runs out. Only on battery power; on the charger it stays on.")
            }
        }
    }

    /// A harness card's check chip.
    private func check(_ label: String, passed: Bool) -> some View {
        Badge(label, icon: .symbol(passed ? "checkmark" : "exclamationmark"), iconTint: passed ? Palette.green : Palette.amber)
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
