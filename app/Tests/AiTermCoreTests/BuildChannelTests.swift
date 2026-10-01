import Testing
@testable import AiTermCore

@Suite struct BuildChannelTests {
    @Test func stampedBundleIsDev() {
        #expect(BuildChannel(infoDictionary: ["AiTermDevBuild": true]) == .dev)
    }

    @Test func unstampedBundleIsRelease() {
        #expect(BuildChannel(infoDictionary: ["CFBundleShortVersionString": "0.2.0"]) == .release)
        #expect(BuildChannel(infoDictionary: ["AiTermDevBuild": false]) == .release)
        #expect(BuildChannel(infoDictionary: nil) == .release)
    }
}
