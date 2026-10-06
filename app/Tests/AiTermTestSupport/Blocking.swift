// Debug only: the trait is swift-testing's, which a plain release build of the package (the library
// is built with it, though only tests use it) does not have.
#if DEBUG
import Foundation
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
struct BlockingTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        // The suite's own scope passes through: only a test case runs a body that blocks.
        guard testCase != nil else { return try await function() }
        try await withTaskExecutorPreference(ThreadPerJob.shared) { try await function() }
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
