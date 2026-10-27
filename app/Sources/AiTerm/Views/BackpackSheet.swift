import SwiftUI
import AiTermUI
import AiTermCore

/// One live check under a connect: a `StatusMark` in a `Size.slot` column, then `Typography.caption`.
struct ConnectCheck: Equatable {
    let text: String
    let mark: TaskStatus
    let warns: Bool
}

/// The sheet's words, decided apart from the view so a test reads them.
enum BackpackSheetPresentation {
    static let title = "Backpack mode"
    static let subtitle = "Keeps your agents working with the lid closed, online through your iPhone."
    /// The iPhone steps' heading: help for the Hotspot menu, under it.
    static let onTheIPhone = "On the iPhone"
    static let remembered = "The hotspot you used last, and its password from Keychain."
    /// In its place, with a spinner, while no hotspot is chosen: the menu lists only what is in
    /// range, and the iPhone steps under it say how to make the hotspot show up.
    static let looking = "Looking for hotspots…"
    /// For a hotspot other than the remembered one: its password is typed, then kept.
    static let newHotspot = "Type its password; it is kept in Keychain once the Mac has joined."
    /// How often the sheet scans again, so the iPhone's hotspot appears soon after its screen opens.
    static let rescan: Duration = .seconds(5)
    static let phoneSteps = [
        "Unlock the iPhone and open Settings › Personal Hotspot.",
        "Turn on Allow Others to Join.",
        "Keep that screen open until the Mac has joined.",
    ]

    static func checks(phase: ConnectPhase?, hotspot: String) -> [ConnectCheck] {
        let awake = ConnectCheck(text: "Keeping the Mac awake", mark: .idle, warns: false)
        switch phase {
        case nil, .joining?:
            return [ConnectCheck(text: "Joining \(hotspot)…", mark: .working, warns: false), awake]
        case .notInRange?:
            return [ConnectCheck(text: "\(hotspot) isn’t showing its hotspot yet", mark: .working, warns: true), awake]
        case .keepingAwake?:
            return [ConnectCheck(text: "Joined \(hotspot)", mark: .done, warns: false),
                    ConnectCheck(text: "Keeping the Mac awake…", mark: .working, warns: false)]
        case .safe?:
            // The Mac card's status says it now; the checks have done their job.
            return []
        case .failed(let refusal)?:
            let text = switch refusal {
            case .notInRange(let network): "\(network) isn’t showing its hotspot yet"
            case .joinFailed(let network): "Couldn’t join \(network): check its password"
            case .batteryLow(let level): "Battery at \(level) %: backpack mode stays off"
            case .needsSetup: "Backpack mode needs lid sleep and network discovery"
            case .quitting: "AiTerm is quitting: backpack mode stays off"
            }
            return [ConnectCheck(text: text, mark: .idle, warns: true), awake]
        case .keychainRefused?:
            return [ConnectCheck(text: "Couldn’t save the hotspot password in Keychain", mark: .idle, warns: true), awake]
        }
    }

    /// The permission ask, while one is missing (spec §6.1): a `Notice` whose title is what the Mac
    /// card's status says is missing, and whose description is its steps, then where else to find them.
    /// Allow… is its one link. Nil once both are granted.
    static func permissionNotice(_ setup: BackpackSetup) -> (title: String, description: String)? {
        let steps = MacCardPresentation.steps(setup)
        guard !steps.isEmpty else { return nil }
        return (MacCardPresentation.status(setup).text, (steps + [MacCardPresentation.alsoInSettings]).joined(separator: " "))
    }

    /// Once safe the result is the Mac card's anatomy (proposal 1A · 2A, 27 Oct 2026): this its title, and
    /// its status the footer's `backpack enabled`, in the same ready tone.
    static let safeTitle = "Safe to close the lid."
    static let safeStatus = SettingsStatus(.ready, "Backpack mode enabled")

    /// The card's help, under its rule.
    static func safeHelp(hotspot: String, until: BackpackUntil) -> String {
        let ends = until == .turnedOff ? "stays on until you turn it off" : "ends when your agents stop"
        return "On \(hotspot). Backpack mode \(ends), or at \(BackpackSettings.cutoff) % battery."
    }

    /// Turns off's choices, ending with the work first: every sheet opens on it.
    static let untilChoices: [BackpackUntil] = [.agentsStop, .turnedOff]

    static func untilLabel(_ until: BackpackUntil) -> String {
        switch until {
        case .agentsStop: "When agents stop"
        case .turnedOff: "When I turn it off"
        }
    }

    /// Under Turns off: the cutoff is no choice.
    static let untilHelp = "Either way, at \(BackpackSettings.cutoff) % battery."

    /// "None", then the remembered hotspot when it is in range, then the rest of what is in range
    /// by name. A chosen network that dropped out of range stays listed, so the menu still holds it.
    static func choices(inRange: [String], remembered: String?, chosen: String?) -> [String?] {
        var names = Set(inRange.filter { !$0.isEmpty })
        if let chosen { names.insert(chosen) }
        let first = [remembered, chosen].compactMap { $0 }.filter { names.contains($0) }
        let lead = first.first.map { [$0] } ?? []
        let rest = names.subtracting(lead).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return [nil] + (lead + rest).map(Optional.some)
    }
}

/// The sheet's state, built once by `AppController.toggleBackpack()` and handed to `SheetKind`.
@MainActor
@Observable
final class BackpackSheetModel: Identifiable {
    let id = UUID()
    let backpack: BackpackController
    /// Connect was pressed: from then on the checks show, and the sheet closes once the mode is off
    /// and idle under it (`isOver`).
    private(set) var started = false
    /// The chosen hotspot; set through `choose(_:)`, which fills or empties the password with it.
    private(set) var network: String?
    /// The field's text: the remembered hotspot's saved password, filled in as if typed, or what the
    /// person types. Empty sends none, and the saved one is used.
    var password = ""
    /// Turns off: what ends the mode this trip. Never remembered — every sheet starts on
    /// `.agentsStop`, so a Mac is never left on in a bag by a choice made trips ago.
    var until: BackpackUntil = .agentsStop
    /// The Keychain's password, read once: it belongs to the remembered hotspot only.
    private var saved: String?
    private(set) var inRange: [String] = []
    /// From Connect until the connect it started returns: covers the turn before it sets `busy`.
    private var connecting = false

    init(backpack: BackpackController) {
        self.backpack = backpack
    }

    /// Setup, the saved password and one scan — off the main actor where they block. The remembered
    /// hotspot is chosen if the scan sees it.
    func load() async {
        await backpack.refreshSetup()
        saved = await backpack.savedPassword()
        await refreshNetworks()
    }

    /// Scans again. The remembered hotspot is chosen when it first shows up and nothing else is
    /// chosen; a choice the person made is never changed.
    func refreshNetworks() async {
        inRange = await backpack.networksInRange()
        if network == nil, let remembered = backpack.network, inRange.contains(remembered) { choose(remembered) }
    }

    /// The Hotspot menu's pick. The remembered hotspot brings its saved password back into the field;
    /// any other starts it empty.
    func choose(_ hotspot: String?) {
        network = hotspot
        password = hotspot != nil && hotspot == backpack.network ? (saved ?? "") : ""
    }

    var choices: [String?] {
        BackpackSheetPresentation.choices(inRange: inRange, remembered: backpack.network, chosen: network)
    }
    /// The line under the fields: that it is looking, whose password is filled in, or that a new
    /// one's is typed.
    var hotspotHelp: String {
        guard let network else { return BackpackSheetPresentation.looking }
        return network == backpack.network ? BackpackSheetPresentation.remembered : BackpackSheetPresentation.newHotspot
    }
    /// Nothing chosen: the help line spins.
    var isLooking: Bool { network == nil }
    /// The iPhone steps step back once a hotspot is chosen — the iPhone has done its part — but not
    /// while a connect waits for a hotspot that isn't showing, when they are the help again.
    var phoneStepsRecede: Bool { network != nil && backpack.phase != .notInRange }
    var missing: [BackpackSetup.Step] { backpack.setup.missingSteps }
    /// A connect is running: the fields hold still and Cancel is the only action.
    var isConnecting: Bool { connecting || backpack.busy }
    var isSafe: Bool { backpack.phase == .safe }
    /// Also Connect again after a failure: there is no Back, the fields stay live.
    var canConnect: Bool { missing.isEmpty && network != nil && !isConnecting }
    /// Nothing left to show once a connect started: the mode turned off, or ended, under the sheet.
    /// A failure keeps its phase, and with it the fields and Connect.
    var isOver: Bool {
        started && !connecting && !backpack.busy && !backpack.isOn && backpack.phase == nil
    }

    func connect() {
        guard canConnect, let network else { return }
        started = true
        let typed = password.isEmpty ? nil : password, until = self.until
        connecting = true
        let backpack = self.backpack
        Task {
            await backpack.connect(network: network, password: typed, until: until)
            connecting = false
        }
    }

    #if DEBUG
    /// Snapshots draw the sheet after Connect without connecting.
    func previewStarted() { started = true }
    #endif

    @discardableResult
    func cancel() -> Task<Void, Never> {
        let backpack = self.backpack
        return Task { await backpack.cancelConnect() }
    }

    /// The lid closed: the sheet goes. With no connect running — before Connect, or after a failure
    /// — that is a Cancel, returned, which puts back a Wi-Fi a failed join dropped. During a connect
    /// the attempt under way finishes on its own, but a hotspot not in range is no longer waited for.
    @discardableResult
    func lidClosed() -> Task<Void, Never>? {
        if !isConnecting { return cancel() }
        backpack.finishWithoutSheet()
        return nil
    }
}

/// Backpack Mode's sheet, opened by every turn-on: one sheet, in the order it is used. A `Notice`
/// asking for the Mac's permissions while one is missing, then the Hotspot and Password — the
/// remembered one filled in — and Turns off, then the iPhone's steps as the hotspot's help,
/// receding once one is chosen. Connect
/// (⌘↩) runs in place with its checks under the fields, and ends on "Safe to close the lid.", the Mac
/// card's anatomy, with Done; a failure leaves the fields live and Connect retries. Closing the lid
/// closes it: with nothing running that is a cancel; during a connect the attempt under way keeps
/// going, but no retry follows it, and the footer's backpack line shows how it ends
/// (`BackpackSheetModel.lidClosed()`).
struct BackpackSheet: View {
    let model: BackpackSheetModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetLayout(title: BackpackSheetPresentation.title, height: Sheet.height) {
            SheetSubtitle(BackpackSheetPresentation.subtitle)
        } content: {
            if model.isSafe { safe } else { form }
        } footer: {
            footer
        }
        .task {
            await model.load()
            // Again every few seconds: the iPhone shows its hotspot only while its Personal Hotspot
            // screen is open. Not during a connect, where a scan would get in the join's way.
            while !Task.isCancelled {
                do { try await Task.sleep(for: BackpackSheetPresentation.rescan) } catch { return }
                if !model.isConnecting, !model.isSafe { await model.refreshNetworks() }
            }
        }
        // Turned off or ended under the sheet: it would show "Joining…" with nothing running.
        .onChange(of: model.isOver) { _, over in if over { dismiss() } }
        .task {
            for await _ in model.backpack.lidCloses() {
                model.lidClosed()
                dismiss()
                return
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Space.section) {
            if let ask = BackpackSheetPresentation.permissionNotice(model.backpack.setup) {
                Notice(title: ask.title, description: ask.description) {
                    Button("Allow…") { Task { await model.backpack.setUp() } }.disabled(model.backpack.busy)
                }
            }
            VStack(alignment: .leading, spacing: Space.block) {
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Hotspot") {
                        Select(values: model.choices, selection: Binding(get: { model.network }, set: { model.choose($0) }),
                               label: { $0 ?? "None" })
                    }
                    .frame(maxWidth: .infinity)
                    FormField("Password") {
                        Input(placeholder: "The hotspot’s password",
                              text: Binding(get: { model.password }, set: { model.password = $0 }), secure: true,
                              caretAtEnd: true)
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(model.isConnecting)
                HStack(spacing: Space.snug) {
                    if model.isLooking { StatusMark(status: .working, size: Size.statusMark) }
                    HelpText(model.hotspotHelp)
                }
            }
            VStack(alignment: .leading, spacing: Space.block) {
                HStack(alignment: .top, spacing: Space.gap) {
                    FormField("Turns off") {
                        Select(values: BackpackSheetPresentation.untilChoices,
                               selection: Binding(get: { model.until }, set: { model.until = $0 }),
                               label: BackpackSheetPresentation.untilLabel)
                    }
                    .frame(maxWidth: .infinity)
                    Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
                }
                .disabled(model.isConnecting)
                HelpText(BackpackSheetPresentation.untilHelp)
            }
            FormField(BackpackSheetPresentation.onTheIPhone) {
                NumberedSteps(BackpackSheetPresentation.phoneSteps, receded: model.phoneStepsRecede)
            }
            if model.started, model.isConnecting || model.backpack.phase != nil { checks }
        }
    }

    /// The Mac card's anatomy, as on Settings › Integrations, with no checks: they have done their job.
    private var safe: some View {
        SettingsCard(title: BackpackSheetPresentation.safeTitle, status: BackpackSheetPresentation.safeStatus) {
            SymbolMark(symbol: SidebarFooter.macSymbol, size: Size.control)
        } content: {
            HelpText(BackpackSheetPresentation.safeHelp(hotspot: model.network ?? "", until: model.backpack.state.until))
        }
    }

    private var checks: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(BackpackSheetPresentation.checks(phase: model.backpack.phase, hotspot: model.network ?? ""), id: \.text) { check in
                HStack(spacing: Space.snug) {
                    StatusMark(status: check.mark, size: Size.statusMark).frame(width: Size.slot)
                    Text(check.text).font(Typography.caption)
                        .foregroundStyle(check.warns ? Palette.amber : (check.mark == .idle ? Palette.muted : Palette.text))
                }
                .frame(height: Size.menuRow)
            }
        }
    }

    /// Cancel and Connect; Cancel alone while a connect runs; Done alone once it is safe, which
    /// closes the sheet and leaves the mode on.
    private var footer: some View {
        SheetFooter(secondary: model.isSafe ? nil : "Cancel",
                    primary: model.isSafe ? "Done" : (model.isConnecting ? nil : "Connect"),
                    canSubmit: model.isSafe || model.canConnect,
                    cancel: { model.cancel(); dismiss.afterThisEvent() },
                    submit: { if model.isSafe { dismiss.afterThisEvent() } else { model.connect() } })
    }
}
