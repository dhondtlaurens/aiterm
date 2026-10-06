import Foundation
import Synchronization

/// Every agent's model list, for the New Task and New Review sheets and for Settings alike: one
/// entry point, so the two never disagree, and a `runner` that says how PI is found and launched,
/// so neither a test nor a snapshot launches the developer's CLI.
///
/// Reading a list is not free. Claude's means parsing `~/.claude.json`, often megabytes; PI's is a
/// launch of its CLI, up to a five-second deadline. So what was read is kept, against stamps of the
/// files it came from (`ModelCatalog.sources`), and read again only when one of them has changed:
/// a sheet opened twice, or an agent picked twice, costs a `stat` of each. A read that failed is
/// never kept — the next one tries again — and the last list that was read stands in for it.
///
/// Blocking, and meant to be called off the main actor, through `BackgroundWork`.
public final class ModelCatalogue: Sendable {
    public struct Reading: Equatable, Sendable {
        public var models: [AgentModel]
        /// `models` are the last ones read, offered because reading them again failed.
        public var stale: Bool
        /// Why the list could not be read just now: only PI's, a launch, can fail.
        public var failure: PiModelCatalogError?

        public init(models: [AgentModel], stale: Bool = false, failure: PiModelCatalogError? = nil) {
            self.models = models; self.stale = stale; self.failure = failure
        }

        /// What Settings' Models check says about a failed read.
        public var explanation: String? {
            guard let failure else { return nil }
            if case .unavailable = failure { return "PI couldn’t be launched." }
            return stale ? "The PI model catalogue couldn’t be refreshed." : "The PI model catalogue is unavailable."
        }
    }

    /// `read` is the number of the read it came from: reads of one agent can overlap, and an older
    /// one finishing last must not replace what a newer one found.
    private struct Entry { var stamps: FileStamps, models: [AgentModel], read: Int }
    private struct State { var entries: [AgentKind: Entry] = [:], reads = 0 }

    private let home: URL
    private let runner: HarnessCommandRunner
    private let state = Mutex(State())

    public init(home: URL, runner: HarnessCommandRunner) {
        self.home = home
        self.runner = runner
    }

    /// `agent`'s models. `executable` is PI's CLI when the caller has already found it. Without
    /// `refreshing`, a list read before is answered while its files are unchanged; Settings'
    /// probe refreshes, because it is the place that says whether PI can be launched at all.
    public func read(_ agent: AgentKind, executable: String? = nil, refreshing: Bool = false) -> Reading {
        let cli = agent == .pi ? executable ?? runner.locate("pi") : nil
        if agent == .pi, cli == nil { return fallback(agent, failure: .unavailable) }
        // Stamped before the read, so a file that changes while it runs is read again next time.
        let stamps = FileStamps(ModelCatalog.sources(for: agent, home: home, executable: cli))
        let (cached, read) = state.withLock { state -> ([AgentModel]?, Int) in
            state.reads += 1
            guard !refreshing, let entry = state.entries[agent], entry.stamps == stamps else { return (nil, state.reads) }
            return (entry.models, state.reads)
        }
        if let cached { return Reading(models: cached) }
        do {
            let models: [AgentModel]
            if let cli {
                models = try PiModelCatalog.discover(executable: cli, runner: runner)
            } else {
                models = ModelCatalog.fileModels(for: agent, home: home) ?? []
            }
            state.withLock { state in
                guard read > state.entries[agent]?.read ?? 0 else { return }
                state.entries[agent] = Entry(stamps: stamps, models: models, read: read)
            }
            return Reading(models: models)
        } catch {
            return fallback(agent, failure: error as? PiModelCatalogError ?? .unavailable)
        }
    }

    /// The list a sheet offers: the one read, or the last one when reading it again failed. With
    /// none to offer, why not — which the sheet shows in its place.
    public func models(for agent: AgentKind) throws -> [AgentModel] {
        let reading = read(agent)
        if let failure = reading.failure, reading.models.isEmpty { throw failure }
        return reading.models
    }

    private func fallback(_ agent: AgentKind, failure: PiModelCatalogError) -> Reading {
        let last = state.withLock { $0.entries[agent]?.models } ?? []
        return Reading(models: last, stale: !last.isEmpty, failure: failure)
    }
}
