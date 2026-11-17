import Foundation
import Observation
import Synchronization
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport
@testable import AiTerm

@MainActor
struct RowFlagsTests {
    private func flags() -> RowFlags {
        let workspace = WorkspaceStore(file: StateStore(url: ScratchFolder.path("row-flags-", suffix: ".json")))
        return RowFlags(workspace: workspace)
    }

    @Test func setReplacesMembershipAndContainsReadsEachMember() {
        let flags = flags()
        let a = UUID(), b = UUID(), c = UUID()
        #expect(flags.members.isEmpty)
        #expect(!flags.contains(a))
        flags.set([a, b])
        #expect(flags.members == [a, b])
        #expect(flags.contains(a) && flags.contains(b) && !flags.contains(c))
        flags.set([b, c])
        #expect(flags.members == [b, c])
        #expect(!flags.contains(a) && flags.contains(b) && flags.contains(c))
        flags.set([])
        #expect(flags.members.isEmpty)
        #expect(!flags.contains(a) && !flags.contains(b) && !flags.contains(c))
    }

    @Test func insertAndRemoveChangeOnlyTheirMember() {
        let flags = flags()
        let a = UUID(), b = UUID()
        flags.set([a])
        flags.insert(b)
        flags.insert(b)
        #expect(flags.members == [a, b])
        #expect(flags.contains(a) && flags.contains(b))
        flags.remove(a)
        flags.remove(a)
        #expect(flags.members == [b])
        #expect(!flags.contains(a) && flags.contains(b))
    }

    @Test func setInvalidatesOnlyTheRowWhoseMembershipChanges() {
        let flags = flags()
        let a = UUID(), b = UUID()
        for next: Set<UUID> in [[a], []] {
            let changed = Mutex(false), unchanged = Mutex(false)
            withObservationTracking { _ = flags.contains(a) } onChange: { changed.withLock { $0 = true } }
            withObservationTracking { _ = flags.contains(b) } onChange: { unchanged.withLock { $0 = true } }
            flags.set(next)
            #expect(changed.withLock { $0 })
            #expect(!unchanged.withLock { $0 })
            #expect(!invalidates({ _ = flags.contains(a) }, by: { flags.set(next) }))
        }
        #expect(!invalidates({ _ = flags.members }, by: { flags.insert(b) }), "whole membership is not observed")
    }
}
