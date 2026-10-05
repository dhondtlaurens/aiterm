import SwiftUI
import AiTermUI
import AiTermCore

/// One live check on step 2: a `StatusMark` in a `Size.slot` column, then `Typography.caption`.
struct ConnectCheck: Equatable {
    let text: String
    let mark: TaskStatus
    let warns: Bool
}

/// The sheet's words, decided apart from the view so a test reads them.
enum BackpackSheetPresentation {
    static let title = "Backpack mode"
    static let steps = ["Hotspot", "Connect"]
    static let remembered = "The hotspot you used last, and its password from Keychain."
    /// In its place while no hotspot is chosen: the iPhone only shows it while Personal Hotspot is
    /// open, and the menu lists only what is in range. Connect stays disabled, and this says why.
    static let notShowingYet = "Open Settings › Personal Hotspot on the iPhone, and it shows up here."
    /// For a hotspot other than the remembered one: its password is typed, then kept.
    static let newHotspot = "Type its password; it is kept in Keychain once the Mac has joined."
    /// How often step 1 scans again, so the iPhone's hotspot appears soon after its screen opens.
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
            return [ConnectCheck(text: "Joined \(hotspot)", mark: .done, warns: false),
                    ConnectCheck(text: "Keeping the Mac awake", mark: .done, warns: false)]
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

    static func safeHelp(hotspot: String) -> String {
        "On \(hotspot). Backpack mode ends when your agents stop, or at \(BackpackSettings.cutoff) % battery."
    }

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
    enum Step: Equatable { case hotspot, connect }

    let id = UUID()
    let backpack: BackpackController
    var step: Step = .hotspot
    /// The chosen hotspot; set through `choose(_:)`, which fills or empties the password with it.
    private(set) var network: String?
    /// The field's text: the remembered hotspot's saved password, filled in as if typed, or what the
    /// person types. Empty sends none, and the saved one is used.
    var password = ""
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
    /// Step 1's line under the fields: how to make the hotspot show up, whose password is filled in,
    /// or that a new one's is typed.
    var hotspotHelp: String {
        guard let network else { return BackpackSheetPresentation.notShowingYet }
        return network == backpack.network ? BackpackSheetPresentation.remembered : BackpackSheetPresentation.newHotspot
    }
    var missing: [BackpackSetup.Step] { backpack.setup.missingSteps }
    var canConnect: Bool { missing.isEmpty && network != nil && !backpack.busy }
    /// Step 2 with nothing left to show: the mode turned off, or ended, under the sheet. A failure
    /// keeps its phase, and with it Back and Cancel.
    var isOver: Bool {
        step == .connect && !connecting && !backpack.busy && !backpack.isOn && backpack.phase == nil
    }

    func connect() {
        guard canConnect, let network else { return }
        step = .connect
        let typed = password.isEmpty ? nil : password
        connecting = true
        let backpack = self.backpack
        Task {
            await backpack.connect(network: network, password: typed)
            connecting = false
        }
    }

    func back() {
        step = .hotspot
        Task { await backpack.cancelConnect() }
    }

    @discardableResult
    func cancel() -> Task<Void, Never> {
        let backpack = self.backpack
        return Task { await backpack.cancelConnect() }
    }

    /// The lid closed: the sheet goes. On step 1 that is a Cancel, returned; on step 2 the attempt
    /// under way finishes on its own, but a hotspot not in range is no longer waited for.
    @discardableResult
    func lidClosed() -> Task<Void, Never>? {
        if step == .hotspot { return cancel() }
        backpack.finishWithoutSheet()
        return nil
    }
}

/// Backpack Mode's sheet, opened by every turn-on: 1 Hotspot, 2 Connect. Step 2 guides the phone and
/// ends on "Safe to close the lid." with Done. Closing the lid closes it from either step: on step 1
/// that is a cancel; on step 2 the attempt under way keeps going, but no retry follows it, and the
/// Mac row shows how it ends (`BackpackSheetModel.lidClosed()`).
struct BackpackSheet: View {
    let model: BackpackSheetModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetLayout(title: BackpackSheetPresentation.title, height: Sheet.height) {
            StepBar(step: model.step == .hotspot ? 1 : 2, names: BackpackSheetPresentation.steps)
        } content: {
            switch model.step {
            case .hotspot: hotspot
            case .connect: connect
            }
        } footer: {
            footer
        }
        .task {
            await model.load()
            // Again every few seconds on step 1: the iPhone shows its hotspot only while its Personal
            // Hotspot screen is open. Not on step 2, where a scan would get in the join's way.
            while !Task.isCancelled {
                try? await Task.sleep(for: BackpackSheetPresentation.rescan)
                if model.step == .hotspot, !model.backpack.busy { await model.refreshNetworks() }
            }
        }
        // Turned off or ended under the sheet: step 2 would show "Joining…" with nothing running.
        .onChange(of: model.isOver) { _, over in if over { dismiss() } }
        .task {
            for await _ in model.backpack.lidCloses() {
                model.lidClosed()
                dismiss()
                return
            }
        }
    }

    private var hotspot: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            if !model.missing.isEmpty {
                NumberedSteps(MacCardPresentation.steps(model.backpack.setup))
                HStack(spacing: Space.base) {
                    Button("Allow…") { Task { await model.backpack.setUp() } }.disabled(model.backpack.busy)
                    HelpText(MacCardPresentation.alsoInSettings)
                }
            }
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
            HelpText(model.hotspotHelp)
        }
    }

    private var connect: some View {
        let hotspot = model.network ?? ""
        return VStack(alignment: .leading, spacing: Space.block) {
            if model.backpack.phase == .safe {
                HStack(alignment: .top, spacing: Space.inset) {
                    ZStack {
                        Circle().fill(Palette.accent)
                        Icon(.symbol("checkmark"), size: Size.control / 2, tint: Palette.onAccent)
                    }
                    .frame(width: Size.control, height: Size.control)
                    VStack(alignment: .leading, spacing: Space.tight) {
                        Text("Safe to close the lid.").font(Typography.title).foregroundStyle(Palette.text)
                        HelpText(BackpackSheetPresentation.safeHelp(hotspot: hotspot))
                    }
                }
            } else {
                NumberedSteps(BackpackSheetPresentation.phoneSteps)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(BackpackSheetPresentation.checks(phase: model.backpack.phase, hotspot: hotspot), id: \.text) { check in
                    HStack(spacing: Space.snug) {
                        StatusMark(status: check.mark, size: Size.statusMark).frame(width: Size.slot)
                        Text(check.text).font(Typography.caption)
                            .foregroundStyle(check.warns ? Palette.amber : (check.mark == .idle ? Palette.muted : Palette.text))
                    }
                    .frame(height: Size.menuRow)
                }
            }
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.step {
        case .hotspot:
            SheetActionRow {
                EmptyView()
            } actions: {
                Button("Cancel") { model.cancel(); dismiss.afterThisEvent() }.keyboardShortcut(.cancelAction)
                SheetPrimaryButton(title: "Connect", enabled: model.canConnect) { model.connect() }
            }
        case .connect where model.backpack.phase == .safe:
            SheetActionRow {
                EmptyView()
            } actions: {
                SheetPrimaryButton(title: "Done") { dismiss.afterThisEvent() }
            }
        case .connect:
            SheetActionRow {
                Button("Back") { model.back() }
            } actions: {
                Button("Cancel") { model.cancel(); dismiss.afterThisEvent() }.keyboardShortcut(.cancelAction)
            }
        }
    }
}
