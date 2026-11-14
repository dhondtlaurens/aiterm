import Foundation
import AiTermCore

/// One loop per source and host. Equal reads share a pass; an incomplete pass publishes nothing
/// and advances no cursor. This owner is additive until activation wires its callback to ItemRouter.
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
    private let work: OperatorWork
    private let now: @MainActor () -> Date
    private let automatic: Bool
    private var registrations: [Registration] = []
    private var passes: [String: TickPass] = [:]
    private var loops: [String: PollLoop] = [:]
    private var progress: [String: Progress] = [:]
    private var generation = UUID()
    var onRead: @MainActor ([UUID], SignalRead) -> Void = { _, _ in }
    var onFailure: @MainActor ([UUID], String) -> Void = { _, _ in }

    init(work: OperatorWork, automatic: Bool = true, now: @escaping @MainActor () -> Date = { Date() }) {
        self.work = work; self.automatic = automatic; self.now = now
    }
    func replace(_ values: [Registration]) {
        stop()
        registrations = values
        let keys = Set(values.map { $0.sourceHost + ":" + $0.readKey })
        progress = progress.filter { keys.contains($0.key) }
        for host in Set(values.map(\.sourceHost)) {
            passes[host] = TickPass(work: work)
            if automatic {
                loops[host] = PollLoop(interval: .seconds(60)) { [weak self] in
                    guard let self else { return nil }
                    self.tick(host: host)
                    return .seconds(60)
                }
            }
        }
    }
    func stop() {
        generation = UUID()
        for pass in passes.values { pass.cancel() }
        for loop in loops.values { loop.cancel() }
        passes.removeAll(); loops.removeAll(); registrations = []
    }
    func tick() { for host in passes.keys { tick(host: host) } }
    private func tick(host: String) {
        let groups = Dictionary(grouping: registrations.filter { $0.sourceHost == host }, by: \.readKey)
        let firsts = groups.values.compactMap(\.first).sorted { $0.id.uuidString < $1.id.uuidString }
        let generation = generation
        passes[host]?.run(firsts.map(\.id)) { [weak self] id in
            guard let self, self.generation == generation, let registration = firsts.first(where: { $0.id == id }),
                  let sharing = groups[registration.readKey] else { return }
            let key = host + ":" + registration.readKey, at = self.now()
            let before = self.progress[key] ?? Progress()
            guard at >= before.next else { return }
            let full = !registration.isJira || before.lastFull.map { at.timeIntervalSince($0) >= 600 } != false
            do {
                let read = try await registration.reader.poll(since: full ? nil : before.cursor, full: full)
                guard !Task.isCancelled, self.generation == generation else { return }
                guard read.complete else { throw IncompleteRead("signal matches") }
                self.progress[key] = Progress(cursor: read.cursor ?? at, lastFull: full ? at : before.lastFull, next: at.addingTimeInterval(60))
                self.onRead(sharing.map(\.id), read)
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                var next = before; next.next = at.addingTimeInterval(300); self.progress[key] = next
                self.onFailure(sharing.map(\.id), error.localizedDescription)
            }
        }
    }
}
