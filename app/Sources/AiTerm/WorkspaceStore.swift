import Foundation
import Synchronization
import AiTermCore

/// The workspace — every project, divider, task and terminal row, and what is remembered between
/// launches — and the one way it changes: `mutate`. A change is written to `state` once, the
/// owners that keep something per row hear of it once (`onChange`), and it is saved.
///
/// Saves are coalesced and written off the main actor. The first change after a save schedules
/// one `saveDelay` later, and that save writes the workspace as the last change left it, so a
/// burst of changes — a drag of the sidebar, a snapshot closing windows — is one write, and no
/// change waits longer than `saveDelay` for its save, however busy the main actor is. A failure is
/// reported back here, in `persistenceError`, a beat after the change. `flush()` saves at once, for
/// quitting and for a caller that goes on only once its change is on disk.
///
/// A crash loses at most the changes of the last `saveDelay`: the file is replaced atomically, so
/// it is always a whole earlier workspace, and its backup the one before that.
@MainActor
@Observable
final class WorkspaceStore {
    /// What the sidebar draws and every command reads. Written only through `mutate`, `load` and
    /// `restoreBackup`.
    private(set) var state = AppState.empty
    /// Whether `state` came from the file. Nothing is saved until it has: a workspace that failed to
    /// load must not be overwritten with an empty one.
    private(set) var loaded = false
    /// Why the latest save failed, until one succeeds.
    private(set) var persistenceError: String?
    /// Whether a command may change the workspace: loaded, and saving.
    var canChangeWorkspace: Bool { loaded && persistenceError == nil }

    /// The file `state` is saved to.
    let file: StateStore
    @ObservationIgnored private let writer: WorkspaceWriter
    /// Run once per change, in the order they were added.
    @ObservationIgnored private var hooks: [(hook: Hook, run: @MainActor () -> Void)] = []
    @ObservationIgnored private var hookCount = 0
    /// Moves on with every change: the writer skips a save of a revision the file already holds,
    /// and a result that arrives after a newer revision's is old news.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var reported = (revision: 0, saved: false)

    init(file: StateStore, saveDelay: Duration = .milliseconds(200)) {
        self.file = file
        writer = WorkspaceWriter(file: file, delay: saveDelay)
    }

    /// A hook added by `onChange`, for taking it out again.
    struct Hook: Equatable {
        fileprivate let serial: Int
    }

    /// Adds `hook` to what runs after every change, after the ones added before it.
    @discardableResult
    func onChange(_ hook: @escaping @MainActor () -> Void) -> Hook {
        hookCount += 1
        let added = Hook(serial: hookCount)
        hooks.append((added, hook))
        return added
    }

    /// Takes out a hook added by `onChange`, for an owner that goes before the workspace does.
    func removeHook(_ hook: Hook) {
        hooks.removeAll { $0.hook == hook }
    }

    /// Changes the workspace: `body` edits a copy, which becomes `state` in one write — once a
    /// workspace has loaded, one save is requested. A body that changes nothing writes and saves
    /// nothing. Returns what `body` does.
    @discardableResult
    func mutate<T>(_ body: (inout AppState) throws -> T) rethrows -> T {
        var next = state
        let result = try body(&next)
        guard next != state else { return result }
        state = next
        revision += 1
        if loaded {
            writer.saveSoon(next, revision: revision) { [weak self] revision, result in
                Task { @MainActor in self?.report(result, of: revision) }
            }
        }
        changed()
        return result
    }

    /// Reads the file, once.
    func load() throws {
        guard !loaded else { return }
        let file = self.file
        adopt(try writer.adopt(revision: revision + 1) {
            // A workspace with no file yet is written by the first save, even with nothing changed.
            (try file.load(), saved: FileManager.default.fileExists(atPath: file.url.path))
        })
    }

    /// Replaces the file with its backup, keeping the damaged one beside it, and adopts it.
    func restoreBackup() throws {
        let file = self.file
        adopt(try writer.adopt(revision: revision + 1) { (try file.restoreBackup(), saved: true) })
        persistenceError = nil
    }

    /// Saves now, in place of a save still waiting, once one under way has written, and says
    /// whether the file holds `state`. Quitting comes here, and so does a caller that goes on only
    /// once its change is saved; so does "Retry Saving", which writes even with nothing changed
    /// since the save that failed.
    @discardableResult
    func flush() -> Bool {
        guard loaded else { return false }
        report(writer.saveNow(state, revision: revision), of: revision)
        return persistenceError == nil
    }

    /// Takes the workspace the writer has just read or restored, as the revision handed to it.
    private func adopt(_ loaded: AppState) {
        revision += 1
        let changed = loaded != state
        state = loaded
        self.loaded = true
        if changed { self.changed() }
    }

    private func changed() {
        for hook in hooks { hook.run() }
    }

    /// A save's result, unless it is old news: a newer revision's result has been heard, or this
    /// revision has been saved already — by a flush, say, that overtook the save now failing late.
    private func report(_ result: Result<Void, any Error>, of revision: Int) {
        let succeeded = if case .success = result { true } else { false }
        if revision < reported.revision || (revision == reported.revision && reported.saved && !succeeded) { return }
        reported = (revision, succeeded)
        switch result {
        case .success:
            if persistenceError != nil { persistenceError = nil }
        case .failure(let error):
            persistenceError = "Changes haven’t been saved. " + error.localizedDescription
        }
    }
}

/// Writes the workspace file off the main actor, one save at a time. A background save runs on a
/// thread of its own — not on a dispatch queue's workers, which blocked git calls elsewhere can all
/// be holding, nor on the main actor, which a busy sidebar can hold — and a flush on the caller's.
/// A save of a revision the file already holds, or an older one, is not made.
private final class WorkspaceWriter: Sendable {
    private struct Waiting: Sendable {
        var state: AppState
        var revision: Int
    }

    private let file: StateStore
    private let delay: Duration
    /// The workspace as the latest change left it, while the save it rides along with waits.
    private let waiting = Mutex<Waiting?>(nil)
    /// The newest revision the file holds, written or loaded. Held while a save writes, which is
    /// what makes the saves one at a time.
    private let saved = Mutex(0)

    init(file: StateStore, delay: Duration) {
        self.file = file
        self.delay = delay
    }

    /// Hands over the workspace as a change left it. The first since the last save starts the wait,
    /// which a later change does not push back: a stream of them is still saved every `delay`.
    /// `done` hears how the save went, on the writer's thread.
    func saveSoon(_ state: AppState, revision: Int,
                  done: @escaping @Sendable (_ revision: Int, Result<Void, any Error>) -> Void) {
        let starts = waiting.withLock { waiting in
            defer { waiting = Waiting(state: state, revision: revision) }
            return waiting == nil
        }
        guard starts else { return }
        let delay = self.delay
        // Weak: a store gone by then has nothing left to save.
        Thread { [weak self] in
            Thread.sleep(forTimeInterval: Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18)
            guard let self, let latest = waiting.withLock({ waiting in defer { waiting = nil }; return waiting }) else { return }
            done(latest.revision, write(latest.state, revision: latest.revision))
        }.start()
    }

    /// Saves now, in place of the save waiting, once a save under way has written.
    func saveNow(_ state: AppState, revision: Int) -> Result<Void, any Error> {
        waiting.withLock { $0 = nil }
        return write(state, revision: revision)
    }

    /// Reads or restores the workspace as `revision`, once a save under way has written, and with
    /// no save let in until the file is known to hold it: nothing waiting from before is saved over
    /// it, and a save already past its wait finds the file newer than what it holds.
    func adopt(revision: Int, _ read: () throws -> (AppState, saved: Bool)) throws -> AppState {
        try saved.withLock { saved in
            let (state, isSaved) = try read()
            waiting.withLock { $0 = nil }
            if isSaved { saved = revision }
            return state
        }
    }

    private func write(_ state: AppState, revision: Int) -> Result<Void, any Error> {
        saved.withLock { saved in
            guard saved < revision else { return .success(()) }
            return Result {
                try file.save(state)
                saved = revision
            }
        }
    }
}
