import Foundation
import AiTermCore

/// The Operator tick's poll step: one pass per source host at a time, over the read keys that are due. Equal reads share
/// a pass; an incomplete pass publishes nothing and advances no cursor.
@MainActor
final class SignalPoller {
    struct Registration {
        var id: UUID
        var sourceHost: String
        var readKey: String
        var isJira: Bool
        var reader: any SignalSourceReader
    }
    private struct Progress {
        var cursor: Date?
        var lastFull: Date?
        var next: Date = .distantPast
    }
    /// A failed read is tried again after this long.
    private static let failureBackOff: TimeInterval = 300
    /// A Jira read key reads every matching key again after this long, not only those changed since its cursor.
    private static let jiraSweep: TimeInterval = 600
    private let work: OperatorWork
    private let now: @MainActor () -> Date
    private var registrations: [Registration] = []
    /// Each source host's pass still reading.
    private var reading: [String: Task<Void, Never>] = [:]
    private var progress: [String: Progress] = [:]
    private var generation = UUID()
    var canPoll: @MainActor () -> Bool = { true }
    var onPass: @MainActor ([SignalObservation]) -> Void = { _ in }
    var onFailure: @MainActor ([UUID], String) -> Void = { _, _ in }

    init(work: OperatorWork, now: @escaping @MainActor () -> Date = { Date() }) {
        self.work = work; self.now = now
    }
    func replace(_ values: [Registration], refresh: Set<UUID> = []) {
        stop()
        registrations = values
        let keys = Set(values.map { $0.sourceHost + ":" + $0.readKey })
        let refreshed = Set(values.filter { refresh.contains($0.id) }.map { $0.sourceHost + ":" + $0.readKey })
        progress = progress.filter { keys.contains($0.key) && !refreshed.contains($0.key) }
    }
    /// Drops every pass still reading: what it reads afterwards is never published.
    func stop() {
        generation = UUID()
        for pass in reading.values { pass.cancel() }
        reading.removeAll(); registrations = []
    }
    /// Starts a pass for each source host with none still reading and a read key that is due.
    func tick() {
        guard canPoll() else { return }
        for host in Set(registrations.map(\.sourceHost)) where reading[host] == nil { tick(host: host) }
    }
    private func tick(host: String) {
        let groups = Dictionary(grouping: registrations.filter { $0.sourceHost == host }, by: \.readKey)
        let at = now()
        let due = groups.values.compactMap(\.first).filter { at >= (progress[host + ":" + $0.readKey]?.next ?? .distantPast) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
        guard !due.isEmpty else { return }
        let generation = generation
        reading[host] = work.start { [weak self] in
            var observations: [SignalObservation] = []
            for registration in due {
                guard !Task.isCancelled, let self, self.generation == generation, let sharing = groups[registration.readKey] else { return }
                if let observation = await self.read(registration, host: host, sharing: sharing, generation: generation) {
                    observations.append(observation)
                }
            }
            guard let self, self.generation == generation else { return }
            self.reading[host] = nil
            if !observations.isEmpty { self.onPass(observations) }
        }
    }
    private func read(_ registration: Registration, host: String, sharing: [Registration], generation: UUID) async -> SignalObservation? {
        let key = host + ":" + registration.readKey, at = now()
        let before = progress[key] ?? Progress()
        guard at >= before.next else { return nil }
        let full = !registration.isJira || before.lastFull.map { at.timeIntervalSince($0) >= Self.jiraSweep } != false
        do {
            let read = try await registration.reader.poll(since: full ? nil : before.cursor, full: full)
            guard !Task.isCancelled, self.generation == generation, canPoll() else { return nil }
            guard read.complete else { throw IncompleteRead("signal matches") }
            progress[key] = Progress(cursor: read.cursor ?? at, lastFull: full ? at : before.lastFull,
                                     next: at.addingTimeInterval(OperatorTiming.reconcileInterval))
            return SignalObservation(signals: sharing.map(\.id), read: read)
        } catch {
            guard !Task.isCancelled, self.generation == generation, canPoll() else { return nil }
            var next = before; next.next = at.addingTimeInterval(Self.failureBackOff); progress[key] = next
            onFailure(sharing.map(\.id), error.localizedDescription)
            return nil
        }
    }
}
