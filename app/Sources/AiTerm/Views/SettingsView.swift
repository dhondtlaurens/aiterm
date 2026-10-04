import SwiftUI
import AiTermUI
import AiTermCore

enum SettingsTab: String, CaseIterable, Identifiable {
    case agents = "Agents"
    case integrations = "Integrations"
    case interface = "Interface"
    case backpack = "Backpack"
    var id: Self { self }

    /// ⌘1–⌘4 pick the tabs in the order the tab bar draws them.
    var key: KeyEquivalent {
        KeyEquivalent(Character(String(Self.allCases.firstIndex(of: self)! + 1)))
    }

    /// The tab Settings opens on: Integrations while something there is broken — iTerm2 is not
    /// connected, or a saved service's last test failed — and Agents otherwise. It is decided once,
    /// from what is known as Settings opens; a test answering afterwards never switches the tab.
    static func opening(iterm: ItermConnection, serviceTestFailed: Bool) -> SettingsTab {
        guard case .connected = iterm, !serviceTestFailed else { return .integrations }
        return .agents
    }
}

/// A service's connection test, held per card so its answer lands on that card. It runs when
/// Settings opens and again shortly after the card's fields stop changing; there is no Test button.
enum ConnectionTest: Equatable {
    case running
    case connected(String)
    case failed(String)
}

enum IntegrationCardPresentation {
    static func status(configured: Bool, test: ConnectionTest?) -> SettingsStatus {
        switch test {
        case .running: SettingsStatus(.idle, "Testing…")
        case .connected(let name): SettingsStatus(.ready, "Connected as \(name)")
        case .failed(let explanation): SettingsStatus(.attention, explanation)
        case nil: SettingsStatus(.idle, configured ? "Not tested yet" : "Not set up")
        }
    }
}

struct SettingsView: View {
    /// What the Interface tab opens on, and where Save puts the badge switches: the sidebar's rows
    /// read them there, so they redraw without a relaunch.
    let preferences: InterfacePreferences
    /// Stores the switch and, when it moved, applies it to iTerm2.
    let setMatchItermBackground: (Bool) -> Void
    /// Stores the size and, when it moved, redraws the sidebar and resizes its window. Called as a
    /// size is picked, so the sidebar behind the sheet follows at once, and by Cancel to put back
    /// `openingSize`.
    let setInterfaceSize: (InterfaceSize) -> Void
    /// The size the sheet opened on, which Cancel restores.
    private let openingSize: InterfaceSize
    @ObservedObject var harnessModel: HarnessSettingsModel
    /// The Integrations tab's fields and tests, made once per presentation from the connections
    /// Settings was opened with.
    @StateObject private var integrations: IntegrationSettingsModel
    /// The live state of the chain to iTerm2. A closure rather than a value so this view's own body
    /// reads the controller, and the card follows a reconnect while Settings is open.
    let itermConnection: () -> ItermConnection
    /// Asks the helper for a fresh snapshot and reads iTerm2's own installation and API setting.
    let checkIterm: () async -> ItermEnvironment
    @Environment(\.dismiss) private var dismiss
    // `@State` is a macro in the macOS 26 SDK and its SwiftUIMacros plugin ships only with Xcode,
    // which this machine does not have; these are the storage and accessors the macro would make.
    var _tab = State<SettingsTab>(initialValue: .agents)
    private var tab: SettingsTab { get { _tab.wrappedValue } nonmutating set { _tab.wrappedValue = newValue } }
    var _matchItermBackground: State<Bool>
    private var matchItermBackground: Bool { get { _matchItermBackground.wrappedValue } nonmutating set { _matchItermBackground.wrappedValue = newValue } }
    var _badgeDetails: State<BadgeDetails>
    private var badgeDetails: BadgeDetails { get { _badgeDetails.wrappedValue } nonmutating set { _badgeDetails.wrappedValue = newValue } }
    var _interfaceSize: State<InterfaceSize>
    private var interfaceSize: InterfaceSize { get { _interfaceSize.wrappedValue } nonmutating set { _interfaceSize.wrappedValue = newValue } }
    var _result = State<String?>(initialValue: nil)
    private var result: String? { get { _result.wrappedValue } nonmutating set { _result.wrappedValue = newValue } }
    var _itermEnvironment = State<ItermEnvironment?>(initialValue: nil)
    private var itermEnvironment: ItermEnvironment? { get { _itermEnvironment.wrappedValue } nonmutating set { _itermEnvironment.wrappedValue = newValue } }
    var _itermTesting = State<Bool>(initialValue: false)
    private var itermTesting: Bool { get { _itermTesting.wrappedValue } nonmutating set { _itermTesting.wrappedValue = newValue } }
    /// Backpack Mode: its state and setup live; its fields are held here until Save.
    let backpack: BackpackController
    var _backpackNetwork: State<String?>
    private var backpackNetwork: String? { get { _backpackNetwork.wrappedValue } nonmutating set { _backpackNetwork.wrappedValue = newValue } }
    var _backpackCutoff: State<Int>
    private var backpackCutoff: Int { get { _backpackCutoff.wrappedValue } nonmutating set { _backpackCutoff.wrappedValue = newValue } }
    var _backpackPassword: State<String>
    private var backpackPassword: String { get { _backpackPassword.wrappedValue } nonmutating set { _backpackPassword.wrappedValue = newValue } }
    var _knownNetworks = State<[String]>(initialValue: [])
    private var knownNetworks: [String] { get { _knownNetworks.wrappedValue } nonmutating set { _knownNetworks.wrappedValue = newValue } }

    init(jiraConfig: JiraConfig?, gitLabConfig: GitLabConfig?, gitHubConfig: GitHubConfig? = nil, harnessModel: HarnessSettingsModel,
         itermConnection: @escaping () -> ItermConnection,
         checkIterm: @escaping () async -> ItermEnvironment,
         preferences: InterfacePreferences,
         setMatchItermBackground: @escaping (Bool) -> Void,
         setInterfaceSize: @escaping (InterfaceSize) -> Void,
         initialTab: SettingsTab? = nil,
         testRecord: ServiceTestRecord = .shared,
         backpack: BackpackController = .inert()) {
        _tab = State(initialValue: initialTab
                     ?? .opening(iterm: itermConnection(), serviceTestFailed: testRecord.anyFailed))
        self.harnessModel = harnessModel
        _integrations = StateObject(wrappedValue: IntegrationSettingsModel(jira: jiraConfig, gitLab: gitLabConfig, gitHub: gitHubConfig,
                                                                           record: testRecord))
        self.itermConnection = itermConnection
        self.checkIterm = checkIterm
        self.preferences = preferences
        self.setMatchItermBackground = setMatchItermBackground
        self.setInterfaceSize = setInterfaceSize
        _matchItermBackground = State(initialValue: preferences.matchItermBackground)
        _badgeDetails = State(initialValue: preferences.badgeDetails)
        _interfaceSize = State(initialValue: preferences.interfaceSize)
        openingSize = preferences.interfaceSize
        self.backpack = backpack
        _backpackNetwork = State(initialValue: backpack.network)
        _backpackCutoff = State(initialValue: backpack.cutoff)
        _backpackPassword = State(initialValue: backpack.password ?? "")
    }

    var body: some View {
        SheetLayout(title: "Settings", height: Sheet.settingsHeight) {
            tabBar
        } content: {
            settingsContent
        } footer: {
            SheetActionRow {
                if let result { Text(result).font(Typography.caption).foregroundStyle(Palette.muted).lineLimit(2) }
            } actions: {
                Button("Cancel") { cancel(); dismiss.afterThisEvent() }.keyboardShortcut(.cancelAction)
                SheetPrimaryButton(title: "Save") { if save() { dismiss.afterThisEvent() } }
            }
        }
        // ⌘1–⌘4, on hidden buttons: a view carries one shortcut, and the tab bar's segments are
        // not buttons of their own.
        .background {
            ForEach(SettingsTab.allCases) { item in
                Button(item.rawValue) { select(item) }.keyboardShortcut(item.key, modifiers: .command)
            }
            .hidden()
        }
        // A result is only true for the moment it was taken, so every opening checks again rather
        // than showing a remembered answer: iTerm2, each saved service, then every harness.
        .task {
            testIterm()
            integrations.testConfigured()
            await harnessModel.load()
            await backpack.refreshSetup()
            knownNetworks = await backpack.knownNetworks()
        }
    }

    private var settingsContent: some View {
        Group {
            switch tab {
            case .agents: HarnessSettingsPane(model: harnessModel)
            case .integrations: integrationSettings
            case .interface:
                InterfaceSettingsPane(matchItermBackground: _matchItermBackground.projectedValue,
                                      badgeDetails: _badgeDetails.projectedValue,
                                      interfaceSize: Binding(get: { interfaceSize }, set: { pickInterfaceSize($0) }))
            case .backpack:
                BackpackSettingsPane(backpack: backpack, network: _backpackNetwork.projectedValue,
                                     password: _backpackPassword.projectedValue,
                                     cutoff: _backpackCutoff.projectedValue, knownNetworks: knownNetworks)
            }
        }
    }

    /// The same `SegmentedControl` the agent picker uses, in its accent style — which keeps keyboard
    /// focus without the outer ring — and clears the result when the selected tab changes.
    private var tabBar: some View {
        SegmentedControl(values: SettingsTab.allCases,
                       selection: Binding(get: { tab }, set: { select($0) }),
                       style: .accent) { item, on in
            // Weight never changes with `on`: selection is already communicated by the blue fill,
            // and changing weight too would make the tab label heavier than the primary action
            // beside it.
            Text(item.rawValue)
                .font(Typography.body)
                .foregroundStyle(on ? Surface.accent.ink : Palette.muted)
        }
    }

    /// iTerm2 first: AiTerm does nothing without it, while Jira, GitLab and GitHub are optional.
    private var integrationSettings: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            ItermSettingsCard(card: ItermCardPresentation.card(for: itermConnection(), environment: itermEnvironment,
                                                               testing: itermTesting))
            ServiceCard(title: "Jira", service: .jira, connection: integrations.jira) { fields in
                VStack(alignment: .leading, spacing: Space.block) {
                    FormField("Site URL") { Input(placeholder: "https://yourcompany.atlassian.net", text: fields.site) }
                    HStack(alignment: .top, spacing: Space.gap) {
                        FormField("Email") { Input(placeholder: "you@company.com", text: fields.email) }
                            .frame(maxWidth: .infinity)
                        FormField("API token") { Input(placeholder: "Atlassian API token", text: fields.token, secure: true) }
                            .frame(maxWidth: .infinity)
                    }
                    if !fields.wrappedValue.token.isEmpty { HelpText("Save stores your token in Keychain.") }
                }
            }
            ServiceCard(title: "GitLab", service: .gitlab, connection: integrations.gitLab) { fields in
                VStack(alignment: .leading, spacing: Space.block) {
                    HStack(alignment: .top, spacing: Space.gap) {
                        FormField("Host URL") { Input(placeholder: "https://gitlab.com", text: fields.host) }
                            .frame(maxWidth: .infinity)
                        FormField("Access token") { Input(placeholder: "Personal access token", text: fields.token, secure: true) }
                            .frame(maxWidth: .infinity)
                    }
                    if !fields.wrappedValue.token.isEmpty { HelpText("Save stores your token in Keychain.") }
                }
            }
            ServiceCard(title: "GitHub", service: .github, connection: integrations.gitHub) { fields in
                VStack(alignment: .leading, spacing: Space.block) {
                    FormField("Access token") {
                        Input(placeholder: "Fine-grained or classic personal access token", text: fields.token, secure: true)
                    }
                    HelpText("Needs read access to pull requests.")
                    if !fields.wrappedValue.token.isEmpty { HelpText("Save stores your token in Keychain.") }
                }
            }
        }
    }

    /// A tab picked by the bar or its key; the footer's result was about the tab left behind.
    private func select(_ item: SettingsTab) {
        tab = item
        result = nil
    }

    /// Jira, GitLab and GitHub are optional. Validate them before committing harness defaults so a failed
    /// save can still be cancelled without changing the models used by new tasks.
    private func save() -> Bool {
        if let failure = integrations.save() { tab = .integrations; result = failure; return false }
        saveInterface()
        saveBackpack()
        harnessModel.save()
        return true
    }

    /// Sidebar size is the one preference applied before Save: the sidebar sits behind the sheet,
    /// so the size shows there as it is picked.
    func pickInterfaceSize(_ size: InterfaceSize) {
        interfaceSize = size
        setInterfaceSize(size)
    }

    /// Cancel keeps nothing, so a size picked since the sheet opened is put back.
    func cancel() {
        setInterfaceSize(openingSize)
    }

    /// The Interface tab has nothing to validate, so it is stored and applied as it stands.
    func saveInterface() {
        setMatchItermBackground(matchItermBackground)
        preferences.badgeDetails = badgeDetails
        setInterfaceSize(interfaceSize)
    }

    /// Backpack's fields have nothing to validate. They take effect at the next turn-on; the
    /// password goes to the Keychain, and an empty one removes it.
    func saveBackpack() {
        backpack.network = backpackNetwork
        backpack.cutoff = backpackCutoff
        backpack.password = backpackPassword
    }

    /// The card follows `itermConnection` on its own; the test only refreshes it and the parts of
    /// iTerm2 the helper cannot see.
    private func testIterm() {
        itermTesting = true
        Task {
            itermEnvironment = await checkIterm()
            itermTesting = false
        }
    }
}

/// A service's Settings card — Jira, GitLab or GitHub: its mark, its connection's status line, a trailing
/// Disconnect while it holds saved credentials, and the fields `content` lays out from the
/// connection's own binding. It observes the connection, so an edit or a test answer redraws this
/// card and not the sheet.
struct ServiceCard<Fields: ServiceFields, Content: View>: View {
    let title: String
    let service: IntegrationMark.Service
    @ObservedObject var connection: ServiceConnection<Fields>
    @ViewBuilder let content: (Binding<Fields>) -> Content

    var body: some View {
        SettingsCard(title: title, status: connection.status) {
            IntegrationMark(service: service, size: Size.control)
        } chips: {
            EmptyView()
        } actions: {
            if connection.canDisconnect {
                Button("Disconnect") { connection.disconnect() }
            }
        } content: {
            content($connection.fields)
        }
    }
}
