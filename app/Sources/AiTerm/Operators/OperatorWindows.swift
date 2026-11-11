import Foundation
import AiTermCore

/// The Operator's window, as AiTerm opens it again and closes it (spec §3, §9, §13): a reopening — its conversation
/// resumed, or a fresh Operator briefed from the run — that opens no second window while one is being opened or iTerm2
/// has not listed it yet; what an End that came meanwhile could not undo; and the close of ended broadcasts' windows
/// once a connected snapshot shows what each holds. It remembers which broadcasts' conversation could not be resumed
/// (`reopenFailed`), which the board's footer says.
@MainActor
@Observable
final class OperatorWindows {
    @ObservationIgnored private let workspace: WorkspaceStore
    @ObservationIgnored private let live: LiveSessions
    @ObservationIgnored private let ports: OperatorPorts
    @ObservationIgnored private let daemon: @MainActor () -> (any DaemonCommands)?
    @ObservationIgnored private let taskFrame: @MainActor () -> Frame
    @ObservationIgnored private let transcripts: TranscriptLocator
    /// What a fresh Operator is told of where its broadcast stands.
    @ObservationIgnored private let statuses: RunStatusSource
    @ObservationIgnored private let listing: TabsListing
    /// The broadcasts whose Operator's window could not be reopened behind the board, its conversation
    /// gone (spec §13): the board's footer says so and offers Start Fresh. Cleared by a reopening that
    /// opens one, and by Start Fresh. Observed, so the board open in front of it changes at once.
    private(set) var reopenFailed: Set<UUID> = []
    /// The broadcasts whose operator window is being opened now (`reopen`, D16): a second click on the row meanwhile
    /// opens no second operator.
    @ObservationIgnored private var reopening: Set<UUID> = []
    /// Each broadcast's operator window `reopen` opened, until its tab is listed: a click in the gap before iTerm2 lists
    /// it (or past `launchAdoptAfter`) opens no second one.
    @ObservationIgnored private var reopened: [UUID: ListingWait] = [:]
    /// The close of ended broadcasts' operator windows after an attach (`closeEnded`): a later attach's replaces it, and
    /// `stop()` cancels it.
    @ObservationIgnored private var closing: Task<Void, Never>?

    init(workspace: WorkspaceStore, live: LiveSessions, ports: OperatorPorts, daemon: @escaping @MainActor () -> (any DaemonCommands)?,
         taskFrame: @escaping @MainActor () -> Frame, transcripts: TranscriptLocator, statuses: RunStatusSource, listing: TabsListing) {
        self.workspace = workspace
        self.live = live
        self.ports = ports
        self.daemon = daemon
        self.taskFrame = taskFrame
        self.transcripts = transcripts
        self.statuses = statuses
        self.listing = listing
    }

    /// The close of ended broadcasts' windows under way ends.
    func stop() {
        closing?.cancel()
        closing = nil
    }

    /// The tabs iTerm2 lists now: a reopened Operator whose tab has come is waited for no more.
    func tabsListed(_ sessions: [SessionInfo]) {
        for id in reopened.keys where OperatorController.operatorTab(of: id, in: sessions) != nil { reopened[id] = nil }
    }

    /// The broadcast's conversation could not be resumed: the board says so, and offers Start Fresh.
    func conversationGone(_ id: UUID) { reopenFailed.insert(id) }

    /// Start Fresh let the conversation go.
    func startedFresh(_ id: UUID) { reopenFailed.remove(id) }

    private func hasEnded(_ id: UUID) -> Bool { workspace.state.run(id: id)?.hasEnded ?? true }

    private func mutateRun(_ id: UUID, _ change: (inout OperatorRun) -> Void) {
        workspace.mutate { $0.updateRun(id: id, change) }
    }

    /// Why a reopening opened nothing: the conversation it would continue is not on this Mac any more.
    static let cannotResume = "Its conversation can’t be resumed."

    /// The operator's window opened again, in front: its conversation resumed under the same frozen
    /// profile, or — with no conversation to resume — a fresh operator, briefed with the broadcast and
    /// where it stands (`OperatorCommand.freshStartMessage`; `prepare` writes `first-message.md` only for a
    /// fresh start). A conversation whose file is gone from Claude's folder is refused (`cannotResume`): Start
    /// Fresh lets it go. The run folder is written afresh with its token kept. Nothing when its window is
    /// open, is being opened, or was opened a moment ago and iTerm2 has not listed its tab yet; refused
    /// while iTerm2's tabs are not known, as a tab not listed then is not a tab closed. A broadcast ended
    /// meanwhile (an await passed) is left ended: the token registered is revoked and the window opened is
    /// closed. Says whether it opened one, or left it to a reopening already under way (or within its
    /// wait): a caller that goes on to change the broadcast waits for that one instead. `background`
    /// opens it behind what is in front.
    @discardableResult
    func reopen(_ id: UUID, background: Bool = false) async throws -> OperatorReopening {
        guard let run = workspace.state.run(id: id) else { throw ActionUnavailable("This broadcast is no longer in AiTerm.") }
        guard !hasEnded(id) else { throw ActionUnavailable("This broadcast has ended.") }
        guard OperatorController.operatorTab(of: id, in: live.sessions) == nil else { return .done }
        guard !reopening.contains(id) else { return .underway }
        guard let daemon = daemon(), listing.known else { throw ActionUnavailable(OperationIssue.disconnected("again").title) }
        if reopened[id]?.waits(at: ports.now()) == true { return .underway }
        reopening.insert(id)
        defer { reopening.remove(id) }
        let projects = run.projectIds.compactMap(workspace.state.project(id:)), home = ports.home, folder = OperatorCommand.runFolder(id, home: ports.home)
        let transcripts = self.transcripts, claudeConfig = ports.claudeConfig
        let conversation = run.operatorConversation, cannotResume = Self.cannotResume
        // A fresh Operator is told where the broadcast stands; a resumed one remembers.
        let fresh = conversation == nil
            ? OperatorCommand.freshStartMessage(for: run, status: statuses.snapshot(of: run.id).flatMap { try? String(decoding: $0.json(), as: UTF8.self) } ?? "{}")
            : nil
        let prepared = try await BackgroundWork.run {
            if let conversation, transcripts.file(agent: .claude, conversation: conversation) == nil {
                throw ActionUnavailable(cannotResume, kind: .conversationGone)
            }
            let token = OperatorCommand.existingToken(in: folder) ?? OperatorCommand.makeToken()
            return try OperatorCommand.prepare(run: run, projects: projects, home: home, claudeConfig: claudeConfig, token: token,
                                               resuming: conversation, firstMessage: fresh)
        }
        // Ended while the folder was written: prepare made its token file again, and nothing was registered.
        guard !hasEnded(id) else {
            let file = folder.appendingPathComponent(OperatorCommand.tokenFile)
            await Log.workspace.attempt("Removing the token file of a broadcast ended while its operator reopened") {
                try await BackgroundWork.run { try FileManager.default.removeItem(at: file) }
            }
            return .done
        }
        try await daemon.registerOperator(runId: id.uuidString, token: prepared.token)
        // Ended while the token was registered: no window is opened for it, and the token goes again.
        guard !hasEnded(id) else {
            await revokeAfterEnd(id, window: nil, daemon: daemon)
            return .done
        }
        let window: String
        do {
            window = try await daemon.createTaskWindow(taskId: id.uuidString, cwd: prepared.folder.path, title: run.name,
                                                       agentCommand: prepared.command, frame: taskFrame(), background: background)
        } catch {
            if hasEnded(id) { await revokeAfterEnd(id, window: nil, daemon: daemon) }
            throw error
        }
        guard !hasEnded(id) else {
            await revokeAfterEnd(id, window: window, daemon: daemon)
            return .done
        }
        reopened[id] = ListingWait(since: ports.now())
        reopenFailed.remove(id)
        mutateRun(id) { $0.operatorWindowId = window }
        return .done
    }

    /// What an end that came while the operator opened or reopened could not undo itself: the token
    /// registered after its revoke goes again, and the window opened after its close is closed.
    func revokeAfterEnd(_ id: UUID, window: String?, daemon: any DaemonCommands) async {
        await Log.daemon.attempt("Revoking the token of broadcast \(id.uuidString) ended while its operator opened") {
            try await daemon.revokeOperator(runId: id.uuidString)
        }
        if let window {
            await Log.daemon.attempt("Closing the window of broadcast \(id.uuidString) ended while its operator opened") {
                try await daemon.closeWindowIfOpen(window)
            }
        }
    }

    /// The first connected snapshot after the helper attaches (spec §9): an ended broadcast whose operator
    /// tab is listed — one an end could not close, as no helper was there — has its window closed, once the
    /// snapshot shows it holds nothing else. No tab listed, nothing is closed: a recorded window id proves
    /// nothing about what a window holds now (iTerm2 restores windows under saved ids, and you may have
    /// added tabs of your own). The recorded ids are cleared once each run is handled.
    func closeEnded() {
        guard let daemon = daemon() else { return }
        let ended = workspace.state.runs.filter { $0.youAsked == .stop }.map(\.id)
        guard !ended.isEmpty else { return }
        closing?.cancel()
        closing = ports.work.start { [self] in
            for id in ended {
                guard !Task.isCancelled else { return }
                await closeIfOnlyItsOperator(id, daemon: daemon)
                mutateRun(id) { $0.operatorWindowId = nil; $0.operatorSessionId = nil }
            }
        }
    }

    /// Closes the window of the run's operator tab as the listed tabs show it, and only when every tab in
    /// it is the run's own: the daemon's close takes the whole window, force and all, and there is no
    /// closing of one tab. A window that holds other tabs is left, and said in the log; with the tabs not
    /// known, or none listed for the run, nothing is closed. Never a recorded window id.
    func closeIfOnlyItsOperator(_ id: UUID, daemon: any DaemonCommands) async {
        guard listing.known, let tab = OperatorController.operatorTab(of: id, in: live.sessions) else { return }
        guard live.sessions.allSatisfy({ $0.windowId != tab.windowId || $0.taskUUID == id }) else {
            Log.daemon.info("The window of the ended broadcast \(id.uuidString, privacy: .public) holds other tabs too, so it is left open")
            return
        }
        await Log.daemon.attempt("Closing the window of the ended broadcast \(id.uuidString)") { try await daemon.closeWindowIfOpen(tab.windowId) }
    }
}
