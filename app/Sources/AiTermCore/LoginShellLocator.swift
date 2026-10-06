import Foundation
import Synchronization

/// The one place the app asks the login shell where things are. A login shell costs the better
/// part of a second, and four consumers each started their own: the launch's agent probe, the
/// launch's Python lookup, and Settings' harness cards, one per agent on a first opening. Now one
/// shell answers for every agent CLI and every Python interpreter at once, its answers are kept, and
/// callers who ask while it runs wait for it rather than starting another.
///
/// A found path is kept for as long as it is still an executable. A name the shell did not find is
/// asked about again on the next lookup — one installed from a terminal shows up then — but with
/// every other name, in one shell. A shell that failed or ran out of time is not an answer and is
/// never kept. After an install `forget()` drops everything, since a CLI may now live elsewhere.
///
/// Blocking, and meant to be called off the main actor, through `BackgroundWork`.
public final class LoginShellLocator: Sendable {
    /// The app's: the launch probes, Settings, PI's catalogue and the installer all go through it,
    /// so none of them disagrees with another about a CLI or pays for a shell another just ran.
    public static let shared = LoginShellLocator()

    /// What one login shell said: the executable each asked name runs, and the output of
    /// `PythonLocator.candidateQuery`, which `PythonLocator` reads.
    public struct Answers: Equatable, Sendable {
        public let executables: [String: String]
        public let pythonOutput: String
    }

    private let names: [String]
    private let shell: @Sendable (String) -> String?
    private let isExecutable: @Sendable (String) -> Bool
    private struct Known { var answers: Answers?; var generation = 0 }
    private let known = Mutex(Known())
    private let resolution = SingleFlight<Answers?>()

    /// `shell` runs a command in the login shell (`LoginShell.run`); a test passes its own, and
    /// counts the shells it is asked to start.
    public init(names: [String] = AgentKind.allCases.map(\.rawValue),
                shell: @escaping @Sendable (String) -> String? = { LoginShell.run($0) },
                isExecutable: @escaping @Sendable (String) -> Bool = { LoginShell.isExecutableFile($0) }) {
        self.names = LoginShell.askable(names)
        self.shell = shell
        self.isExecutable = isExecutable
    }

    /// Both questions in one command. The Python half is printed after a marker line, so neither
    /// half's reader ever sees the other's lines; an rc file's banner comes before both.
    var query: String {
        LoginShell.locateQuery(names) + "; print -r -- \(Self.pythonMarker); " + PythonLocator.candidateQuery
    }

    static let pythonMarker = "--aiterm-python-candidates--"

    /// Where `name` runs from, or `nil` when the login shell does not find it — or could not be
    /// asked. A name outside the ones this locator asks about is looked up on its own, uncached.
    public func locate(_ name: String) -> String? {
        guard names.contains(name) else { return LoginShell.locate([name], runner: shell, isExecutable: isExecutable)?[name] }
        if let path = known.withLock({ $0.answers?.executables[name] }), isExecutable(path) { return path }
        return resolve()?.executables[name]
    }

    /// The answers already known, else a shell's.
    public func current() -> Answers? {
        known.withLock { $0.answers } ?? resolve()
    }

    /// A shell's answers: the one running now, if one is, else a new one. `nil` when it failed.
    public func resolve() -> Answers? {
        resolution.run {
            let generation = known.withLock { $0.generation }
            guard let output = shell(query) else { return nil }
            let answers = Self.answers(output, names: names, isExecutable: isExecutable)
            // A shell that started before a `forget()` may predate the install that called it.
            known.withLock { if $0.generation == generation { $0.answers = answers } }
            return answers
        }
    }

    /// Drops every answer, and lets no shell already running stand in for a new one.
    public func forget() {
        known.withLock { $0.answers = nil; $0.generation += 1 }
        resolution.detach()
    }

    static func answers(_ output: String, names: [String], isExecutable: (String) -> Bool) -> Answers {
        let lines = output.components(separatedBy: "\n")
        let marker = lines.lastIndex { $0.trimmingCharacters(in: .whitespacesAndNewlines) == pythonMarker }
        let located = marker.map { lines[..<$0] } ?? lines[...]
        let python = marker.map { lines[($0 + 1)...] } ?? []
        return Answers(executables: LoginShell.located(names, in: located.joined(separator: "\n"), isExecutable: isExecutable),
                       pythonOutput: python.joined(separator: "\n"))
    }
}

/// Work that several callers may ask for at once, done once: a caller that arrives while it runs
/// waits for that run and takes its answer instead of starting another. A caller that arrives
/// after it finished starts a new one — nothing is cached here.
final class SingleFlight<Value: Sendable>: Sendable {
    private final class Flight: Sendable {
        private let finished = DispatchGroup()
        private let value = Mutex<Value?>(nil)

        init() { finished.enter() }

        func finish(_ result: Value) {
            value.withLock { $0 = result }
            finished.leave()
        }

        func wait() -> Value {
            finished.wait()
            return value.withLock { $0! }
        }
    }

    private let running = Mutex<Flight?>(nil)

    func run(_ work: () -> Value) -> Value {
        let (flight, joined) = running.withLock { running in
            if let flight = running { return (flight, true) }
            let flight = Flight()
            running = flight
            return (flight, false)
        }
        if joined { return flight.wait() }
        let result = work()
        running.withLock { if $0 === flight { $0 = nil } }
        flight.finish(result)
        return result
    }

    /// The run under way, if any, finishes for whoever is already waiting on it; anyone who asks
    /// from now on starts a new one.
    func detach() { running.withLock { $0 = nil } }
}
