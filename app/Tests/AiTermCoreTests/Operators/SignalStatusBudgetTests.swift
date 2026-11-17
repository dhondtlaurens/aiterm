import Foundation
import Testing
@testable import AiTermCore
@testable import AiTermTestSupport

struct SignalStatusBudgetTests {
    @Test func theDefaultDigestFitsTheWireWithoutCappingTasksAndTaskStatusKeepsItsHistory() throws {
        var world = SignalWorld(); let signal = world.signal()
        world.state.signals[0].work.prompt = String(repeating: "Follow the project skills. ", count: 10)
        let entries = (0..<20).map { _ in TaskJournal.Entry(at: world.now, stage: 1, text: .ours(String(repeating: "A checked decision. ", count: 6))) }
        for index in 0..<1000 {
            let id = world.workingTask(signal: signal)
            let item = world.ticket("PAY-\(index + 1)").item
            world.state.updateSignalTask(id) { $0.current.item = item; $0.phase = .done; $0.journal = entries }
        }
        let digest = OperatorDigest(state: world.state, at: world.now, oracleOn: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try encoder.encode(digest)
        #expect(digest.tasks.count == 1000)
        #expect(bytes.count < DaemonProtocol.maximumFrameBytes, "1,000 retained task records: \(bytes.count) bytes")
        let detail = OperatorDigest(state: world.state, at: world.now, oracleOn: true, task: world.state.tasks[0].id)
        #expect(detail.tasks.first?.journal.count == 20 && detail.tasks.first?.prompt == world.state.signals[0].work.prompt)
    }
}
