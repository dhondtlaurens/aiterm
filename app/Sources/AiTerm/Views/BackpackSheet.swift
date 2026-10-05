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
    static let title = "Backpack Mode"
    static let steps = ["Hotspot", "Connect"]
    static let remembered = "The hotspot you used last, and its password from Keychain."
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
            case .batteryLow(let level): "Battery at \(level) %: Backpack Mode stays off"
            case .needsSetup: "Backpack Mode needs lid sleep and network discovery"
            case .quitting: "AiTerm is quitting: Backpack Mode stays off"
            }
            return [ConnectCheck(text: text, mark: .idle, warns: true), awake]
        case .keychainRefused?:
            return [ConnectCheck(text: "Couldn’t save the hotspot password in Keychain", mark: .idle, warns: true), awake]
        }
    }

    static func safeHelp(hotspot: String) -> String {
        "On \(hotspot). Backpack Mode ends when your agents stop, or at \(BackpackSettings.cutoff) % battery."
    }

    /// "None" first, then the remembered network if the Mac no longer lists it, then the known ones.
    static func choices(known: [String], current: String?) -> [String?] {
        let kept = current.map { known.contains($0) ? [] : [$0] } ?? []
        return [nil] + (kept + known).map(Optional.some)
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
    var network: String?
    /// Empty keeps the saved password: the field shows dots over it.
    var password = ""
    private(set) var passwordSaved = false
    private(set) var knownNetworks: [String] = []
    /// From Connect until the connect it started returns: covers the turn before it sets `busy`.
    private var connecting = false

    init(backpack: BackpackController) {
        self.backpack = backpack
        network = backpack.network
    }

    /// Setup, the known networks and whether a password is saved — off the main actor where they block.
    func load() async {
        await backpack.refreshSetup()
        knownNetworks = await backpack.knownNetworks()
        passwordSaved = await backpack.hasPassword()
    }

    var choices: [String?] { BackpackSheetPresentation.choices(known: knownNetworks, current: network) }
    var missing: [BackpackSetup.Step] { backpack.setup.missingSteps }
    var canConnect: Bool { missing.isEmpty && network != nil && !backpack.busy }
    /// The dots stand for the remembered hotspot's Keychain password, and for no other hotspot's.
    var showsSavedPassword: Bool { passwordSaved && network != nil && network == backpack.network }
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
        .task { await model.load() }
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
                    Select(values: model.choices, selection: Binding(get: { model.network }, set: { model.network = $0 }),
                           label: { $0 ?? "None" })
                }
                .frame(maxWidth: .infinity)
                FormField("Password") {
                    Input(placeholder: model.showsSavedPassword ? "••••••••••••" : "The hotspot’s password",
                          text: Binding(get: { model.password }, set: { model.password = $0 }), secure: true)
                }
                .frame(maxWidth: .infinity)
            }
            HelpText(BackpackSheetPresentation.remembered)
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
