// Debug only: the trait is swift-testing's, which a plain release build of the package (the library
// is built with it, though only tests use it) does not have.
#if DEBUG
import Foundation
import Synchronization
import Testing

/// For a suite whose tests block their thread — waiting on `git`, `hdiutil`, a shell or a
/// semaphore — so each runs on threads of its own instead of a worker of Swift's cooperative pool.
///
/// The parallel runner calls a synchronous test from an async context, on that pool, which has one
/// worker per core. A dozen tests waiting on processes hold every worker for as long as the
/// processes take — tens of seconds, for disk images made side by side — and meanwhile no other
/// test's `await` resumes: an `eventually` whose condition has long held, a reply a client has
/// read, a URLSession delegate call all wait, and their deadlines run out. Off the pool, a test
/// that blocks costs only its own thread.
///
/// A `@MainActor` test keeps to the main actor; this moves only what runs off it.
///
/// Every suite whose tests do blocking work off the main actor — a process waited for
/// (`ProcessRunner`, `GitRunner`, a fixture's git), `Thread.sleep`, a semaphore — must be marked
/// `@Suite(.blocking)`; nothing checks that it is.
///
/// At most one of these test cases per core runs at once (`BlockingSlots`). Most of them start git dozens of
/// times, and with every one of them under way together the machine ran hundreds of gits side by
/// side, so a fixture's `git init` waited past `GitRunner.localTimeout` for a core. A case waits
/// for its slot before its body starts, so no time it measures includes the wait.
struct BlockingTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        // The suite's own scope passes through: only a test case runs a body that blocks.
        guard testCase != nil else { return try await function() }
        await BlockingSlots.shared.acquire()
        defer { BlockingSlots.shared.release() }
        try await withTaskExecutorPreference(ThreadPerJob.shared) { try await function() }
    }
}

/// The blocking test cases allowed to run at once: one per core, each waiting its turn without a
/// thread. A case never waits on another case, so holding a slot cannot deadlock.
final class BlockingSlots: Sendable {
    static let shared = BlockingSlots(limit: ProcessInfo.processInfo.activeProcessorCount)

    private struct State { var free: Int; var waiting: [CheckedContinuation<Void, Never>] = [] }
    private let state: Mutex<State>

    init(limit: Int) { state = Mutex(State(free: max(1, limit))) }

    func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let granted = state.withLock { state -> Bool in
                guard state.free > 0 else { state.waiting.append(continuation); return false }
                state.free -= 1
                return true
            }
            if granted { continuation.resume() }
        }
    }

    /// Hands the slot straight to the longest waiter, if there is one.
    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiting.isEmpty else { state.free += 1; return nil }
            return state.waiting.removeFirst()
        }
        next?.resume()
    }
}

extension Trait where Self == BlockingTrait {
    /// The suite's tests block their thread: run them off Swift's cooperative pool.
    static var blocking: Self { Self() }
}

/// Runs each job on a thread of its own, so one that blocks holds only that thread. A thread per
/// job rather than a few shared ones: a test's child tasks still run side by side, so callers it
/// starts to overlap (`async let`, a task group) cannot wait on each other for a thread.
final class ThreadPerJob: TaskExecutor {
    static let shared = ThreadPerJob()

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job), executor = asUnownedTaskExecutor()
        Thread { job.runSynchronously(on: executor) }.start()
    }
}
#endif
