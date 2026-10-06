import Foundation
import Testing
@testable import AiTerm

@MainActor
struct LatestTaskTests {
    /// A run superseded by a newer one is cancelled and no longer current, and its end leaves the
    /// newer run in place; the newest run is let go when it ends.
    @Test func onlyTheLatestRunIsCurrent() async {
        let latest = LatestTask()
        let olderWasCurrent = Recorded<Bool>(), newerWasCurrent = Recorded<Bool>()
        let olderGate = AsyncStream<Void>.makeStream(), newerGate = AsyncStream<Void>.makeStream()
        let older = latest.run { isCurrent in
            for await _ in olderGate.stream { break }
            olderWasCurrent.values.append(isCurrent())
        }
        let newer = latest.run { isCurrent in
            for await _ in newerGate.stream { break }
            newerWasCurrent.values.append(isCurrent())
        }
        #expect(older.isCancelled)
        olderGate.continuation.finish()
        await older.value
        #expect(olderWasCurrent.values == [false])
        #expect(latest.task == newer, "the older run's end leaves the newer one's slot be")
        newerGate.continuation.finish()
        await newer.value
        #expect(newerWasCurrent.values == [true])
        #expect(latest.task == nil, "the newest run lets itself go")
    }

    /// `cancel()` makes the run in flight stale, and lets it go at once.
    @Test func cancellingMovesTheGenerationOn() {
        let latest = LatestTask()
        let before = latest.generation
        latest.run { _ in try? await Task.sleep(for: .seconds(60)) }
        let started = latest.generation
        latest.cancel()
        #expect(started > before)
        #expect(latest.generation > started)
        #expect(latest.task == nil)
    }
}

/// What a test's callbacks heard, in order.
@MainActor
private final class Recorded<Value> {
    var values: [Value] = []
}
