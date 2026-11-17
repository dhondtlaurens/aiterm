import Foundation
import Testing
@testable import AiTermCore

@Suite("AiTerm paths")
struct AiTermPathsTests {
    @Test func updatesLiveInCaches() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(AiTermPaths.updatesDirectory.path == home + "/Library/Caches/com.laurensdhondt.aiterm/Updates")
    }
}
