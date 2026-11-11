import Testing
import Foundation
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite struct JiraSettingsTests {
    @Test func credentialsAreTrimmedWhenSavedAndLoaded() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        let config = JiraConfig(siteURL: URL(string: "https://stub.invalid")!, email: "  me@example.invalid\n", token: "  secret\n")
        #expect(JiraSettings.save(config, store: store, defaults: defaults))
        #expect(store.get("jira.token") == "secret")
        #expect(JiraSettings.load(store: store, defaults: defaults)?.token == "secret")
        store.set("jira.token", "  legacy\n")
        #expect(JiraSettings.load(store: store, defaults: defaults)?.token == "legacy")
        store.set("jira.token", " \n")
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        #expect(defaults.string(forKey: "jira.email") == "me@example.invalid")
    }

    @Test func testSaveAndLoadSplitSecretFromDefaults() {
        let store = MemorySecretStore(), defaults = ScratchDefaults.make()
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        let cfg = JiraConfig(siteURL: URL(string: "http://alice:password@x.atlassian.net:80/")!,
                             email: "me@x.com", token: "secret")
        JiraSettings.save(cfg, store: store, defaults: defaults)
        #expect(JiraSettings.load(store: store, defaults: defaults) == cfg)
        #expect(defaults.string(forKey: "jira.site") == "http://x.atlassian.net")
        #expect(defaults.string(forKey: "jira.token") == nil)
        #expect(store.get("jira.token") == "secret")
        JiraSettings.save(nil, store: store, defaults: defaults)
        #expect(JiraSettings.load(store: store, defaults: defaults) == nil)
        #expect(store.get("jira.token") == nil)
    }
}
