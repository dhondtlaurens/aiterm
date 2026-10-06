import Foundation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

/// The cache the three resolvers share the machinery of, driven with closures instead of git.
struct WatchedFileCacheTests {
    /// A folder with one file in it, which is what the cache watches.
    private func directory() throws -> (path: String, file: String) {
        let path = try GitFixture.folder("watched-")
        let file = path + "/watched"
        try "1".write(toFile: file, atomically: true, encoding: .utf8)
        return (path, file)
    }

    private func timeout() -> GitError { GitError(args: ["status"], code: 15, stderr: "git status timed out after 10 s", timedOut: true) }

    private final class Calls: Sendable {
        private let counts = Mutex((locate: 0, read: 0))
        var locate: Int { counts.withLock { $0.locate } }
        var read: Int { counts.withLock { $0.read } }
        func located() { counts.withLock { $0.locate += 1 } }
        func didRead() { counts.withLock { $0.read += 1 } }
    }

    private final class Results: Sendable {
        private let values = Mutex<[Int]>([])
        var all: [Int] { values.withLock { $0 } }
        func add(_ value: Int) { values.withLock { $0.append(value) } }
    }

    private func value(_ cache: WatchedFileCache<Int>, _ directory: String, _ file: String, _ calls: Calls,
                       locate: () throws -> Void = {}, read: () throws -> Int = { 7 }) throws -> Int? {
        let answer = try cache.answer(for: directory, locate: { _ in calls.located(); try locate(); return [file] },
                                      read: { _, _ in calls.didRead(); return try read() })
        if case .found(let value) = answer { return value }
        return nil
    }

    /// A directory whose git takes its whole deadline to answer holds up nobody else's lookup: the
    /// cache used to keep one lock for every directory across the git it ran.
    @Test func aSlowDirectoryDoesNotHoldUpAnother() throws {
        let slow = try directory(), quick = try directory()
        let cache = WatchedFileCache<Int>(now: { Date(timeIntervalSince1970: 0) }, negativeTTL: 30)
        let inRead = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), quickDone = DispatchSemaphore(value: 0)
        let slowThread = Thread {
            _ = try? cache.answer(for: slow.path, locate: { _ in [slow.file] }, read: { _, _ in inRead.signal(); release.wait(); return 1 })
        }
        slowThread.start()
        #expect(inRead.wait(timeout: .now() + 10) == .success)
        let quickThread = Thread {
            _ = try? cache.answer(for: quick.path, locate: { _ in [quick.file] }, read: { _, _ in 2 })
            quickDone.signal()
        }
        quickThread.start()
        let finished = quickDone.wait(timeout: .now() + 5) == .success
        release.signal()
        #expect(finished, "the other directory waited for the slow one's git")
    }

    /// Two callers for one directory run its git once: the second waits for the first and then finds
    /// what it wrote.
    @Test func aDirectoryAskedAboutTwiceAtOnceIsResolvedOnce() throws {
        let dir = try directory(), calls = Calls()
        let cache = WatchedFileCache<Int>(now: { Date(timeIntervalSince1970: 0) }, negativeTTL: 30)
        let inRead = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let results = Results()
        func ask(slow: Bool) {
            Thread {
                let answer = try? cache.answer(for: dir.path, locate: { _ in [dir.file] }, read: { _, _ in
                    calls.didRead()
                    if slow { inRead.signal(); release.wait() }
                    return 5
                })
                if case .found(let value)? = answer { results.add(value) }
                done.signal()
            }.start()
        }
        ask(slow: true)
        #expect(inRead.wait(timeout: .now() + 10) == .success)
        ask(slow: false)
        Thread.sleep(forTimeInterval: 0.1)
        release.signal()
        #expect(done.wait(timeout: .now() + 10) == .success && done.wait(timeout: .now() + 10) == .success)
        #expect(calls.read == 1)
        #expect(results.all == [5, 5])
    }

    /// What is kept for a directory nobody asks about any more is dropped, negative entries too, so a
    /// tab's every past directory is not held for as long as the app runs.
    @Test func retainForgetsTheDirectoriesNoLongerLive() throws {
        let kept = try directory(), dropped = try directory(), calls = Calls()
        let cache = WatchedFileCache<Int>(now: { Date(timeIntervalSince1970: 0) }, negativeTTL: 30)
        _ = try value(cache, kept.path, kept.file, calls)
        _ = try value(cache, dropped.path, dropped.file, calls)
        #expect(calls.read == 2)
        cache.retain(only: [kept.path])
        _ = try value(cache, kept.path, kept.file, calls)
        #expect(calls.read == 2, "a live directory keeps its answer")
        _ = try value(cache, dropped.path, dropped.file, calls)
        #expect(calls.read == 3, "a forgotten one is resolved again")
    }

    /// A git that ran out of time is left alone for the backoff, not asked on every pass; the first
    /// call after it asks again. The pause is not an answer: nothing is stored.
    @Test func aTimeoutIsNotAskedAgainUntilItsBackoffIsOver() throws {
        let dir = try directory(), calls = Calls(), clock = TestClock()
        let cache = WatchedFileCache<Int>(now: { clock.now }, negativeTTL: 30)
        func failing() throws -> Int? { try value(cache, dir.path, dir.file, calls, locate: { throw timeout() }) }
        #expect(throws: GitError.self) { try failing() }
        #expect(calls.locate == 1)
        clock.advance(by: TimedOut.backoff - 1)
        #expect(throws: GitError.self) { try failing() }
        #expect(calls.locate == 1, "within the backoff git is not asked")
        clock.advance(by: 1)
        #expect(try value(cache, dir.path, dir.file, calls) == 7)
        #expect(calls.locate == 2, "after it, it is")
    }

    /// While git is being left alone the value already known stands, a changed file or not; the
    /// change is read once the backoff is over.
    @Test func theKnownValueStandsThroughTheBackoff() throws {
        let dir = try directory(), calls = Calls(), clock = TestClock()
        let cache = WatchedFileCache<Int>(now: { clock.now }, negativeTTL: 30)
        #expect(try value(cache, dir.path, dir.file, calls) == 7)
        try "changed, and longer".write(toFile: dir.file, atomically: true, encoding: .utf8)
        #expect(try value(cache, dir.path, dir.file, calls, read: { throw timeout() }) == 7)
        #expect(calls.read == 2)
        #expect(try value(cache, dir.path, dir.file, calls, read: { 9 }) == 7)
        #expect(calls.read == 2, "git is left alone")
        clock.advance(by: TimedOut.backoff)
        #expect(try value(cache, dir.path, dir.file, calls, read: { 9 }) == 9)
    }

    /// Only running out of time is held back: any other failure costs what a retry costs, and is retried.
    @Test func aFailureThatIsNotATimeoutIsAskedAgainAtOnce() throws {
        let dir = try directory(), calls = Calls()
        let cache = WatchedFileCache<Int>(now: { Date(timeIntervalSince1970: 0) }, negativeTTL: 30)
        let refusal = GitError(args: ["status"], code: 1, stderr: "fatal: no")
        #expect(throws: GitError.self) { try value(cache, dir.path, dir.file, calls, locate: { throw refusal }) }
        #expect(throws: GitError.self) { try value(cache, dir.path, dir.file, calls, locate: { throw refusal }) }
        #expect(calls.locate == 2)
    }
}
