import Foundation
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor
struct ConnectionBannerTests {
    @Test func aHelperProblemWaitsForTheGraceAndRepeatedReportsDoNotRestartIt() async throws {
        let controller = AppController(preferences: .scratch(), connectionGrace: .milliseconds(20))
        defer { controller.shutdown() }
        #expect(controller.helper.connectionBanner == nil)
        controller.helper.itermConnection = .helperUnreachable
        #expect(controller.helper.connectionBanner == nil)
        controller.helper.itermConnection = .helperUnreachable
        await eventually { controller.helper.connectionBanner != nil }
        #expect(controller.helper.connectionBanner == ItermConnection.helperUnreachable.banner(waited: true))
        controller.helper.itermConnection = .helperUnreachable
        #expect(controller.helper.connectionBanner != nil, "the same status does not restart the grace")
    }

    @Test func connectingBeforeTheGraceEndsCancelsTheBanner() async throws {
        let controller = AppController(preferences: .scratch(), connectionGrace: .milliseconds(20))
        defer { controller.shutdown() }
        controller.helper.itermConnection = .waitingForIterm
        #expect(controller.helper.connectionBanner == nil)
        controller.helper.itermConnection = .connected(version: nil)
        try await Task.sleep(for: .milliseconds(60))
        #expect(controller.helper.connectionBanner == nil)
    }

    @Test func shutdownCancelsTheGrace() async throws {
        let controller = AppController(preferences: .scratch(), connectionGrace: .milliseconds(20))
        controller.helper.itermConnection = .helperUnreachable
        controller.shutdown()
        try await Task.sleep(for: .milliseconds(60))
        #expect(controller.helper.connectionBanner == nil)
    }

    @Test func openingITermUsesTheLaunchPortOnce() {
        let launches = ControllerCallCounter()
        let controller = AppController(preferences: .scratch(), launchIterm: { launches.record() })
        controller.openIterm()
        #expect(launches.count == 1)
    }
}
