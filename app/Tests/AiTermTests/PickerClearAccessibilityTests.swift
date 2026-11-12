import AppKit
import SwiftUI
import Testing
import AiTermCore
import AiTermUI
@testable import AiTerm
@testable import AiTermTestSupport

/// These host each real call site and read its button through AppKit's accessibility tree.
@MainActor @Suite(.serialized) struct PickerClearAccessibilityTests {
    enum Copy { case taskTicket, reviewTicket, mergeRequest, pullRequest, branch, linkedProject, chip }

    private let ticket = JiraTicket(key: "PAY-231", summary: "Cart drawer", description: nil,
                                    issueType: "Task", status: "Review", url: "https://example/PAY-231")

    private func field(_ copy: Copy) -> (AnyView, String) {
        switch copy {
        case .taskTicket:
            var draft = TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "m", reasoning: nil)
            draft.apply(ticket: ticket)
            let model = TaskCreationModel(project: .make(), draft: draft, context: .scratch(git: NoPickerGit()),
                                          searchIssues: { _ in [] }, createTask: { _ in })
            return (AnyView(NewTaskSheet(model: model)), "Clear ticket")
        case .reviewTicket, .mergeRequest, .pullRequest, .branch:
            var draft = ReviewDraft(mr: nil, agent: .claude, model: "m", reasoning: nil)
            if copy == .reviewTicket { draft.apply(ticket: ticket) }
            if copy == .branch { draft.setBranch("feat/cart") }
            let host: CodeHost = copy == .pullRequest ? .gitHub : .gitLab
            if copy == .mergeRequest || copy == .pullRequest {
                draft.apply(mr: MergeRequest(iid: 7, title: "Cart drawer", sourceBranch: "feat/cart", targetBranch: "main",
                                            author: nil, state: "opened", draft: false,
                                            url: host == .gitHub ? "https://github.com/acme/shop/pull/7" : "https://git.example/acme/shop/-/merge_requests/7"))
            }
            let model = ReviewCreationModel(project: .make(), draft: draft, context: .scratch(git: NoPickerGit()),
                                            codeHost: host, searchMergeRequests: { _ in [] }, createReview: { _ in }, recover: { _ in })
            let help = copy == .reviewTicket ? "Clear ticket" : copy == .branch ? "Change branch" : "Clear \(host.reviewNoun)"
            return (AnyView(NewReviewSheet(model: model)), help)
        case .linkedProject:
            let project = JiraProjectRef(id: "1", key: "PAY", name: "Payments", siteURL: URL(string: "https://example.atlassian.net")!)
            return (AnyView(JiraProjectSheet(projectName: "Shop", linked: [project], canSubmit: true,
                                            loadProjects: { [] }, submit: { _ in })), "Unlink PAY")
        case .chip:
            return (AnyView(PickChip(mark: .brand(Palette.jira), label: "PAY · Payments", remove: {})), "Remove PAY · Payments")
        }
    }

    private let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    /// Enhanced UI is an application attribute, so scope it to one synchronous host check.
    /// Restore the process's previous value on every exit, including a thrown test failure.
    private func withAccessibilityTree<T>(_ body: () throws -> T) rethrows -> T {
        let app = NSApplication.shared
        let previous = app.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        app.accessibilitySetValue(true, forAttribute: enhancedUI)
        defer { app.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        return try body()
    }

    private func check(_ copy: Copy) throws {
        try withAccessibilityTree { try checkHostedButton(copy) }
    }

    private func checkHostedButton(_ copy: Copy) throws {
        let (view, expected) = field(copy)
        let host = testHost(view, size: CGSize(width: Sheet.width, height: Sheet.height))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        func button() -> NSObject? {
            elements(host).first {
                value(.role, getter: "accessibilityRole", of: $0) as? String == NSAccessibility.Role.button.rawValue
                    && value(.help, getter: "accessibilityHelp", of: $0) as? String == expected
            }
        }
        settle(host, describing: "the \(expected) accessibility button") { button() != nil }
        let control = try #require(button())
        #expect(value(.description, getter: "accessibilityLabel", of: control) as? String == expected)
        #expect(value(.help, getter: "accessibilityHelp", of: control) as? String == expected, "the tooltip is unchanged")
    }

    @Test func enhancedAccessibilityIsRestoredAfterSuccessAndFailure() {
        let app = NSApplication.shared
        let original = app.accessibilityAttributeValue(enhancedUI) as? Bool ?? false
        defer { app.accessibilitySetValue(original, forAttribute: enhancedUI) }
        enum Probe: Error { case failed }
        for previous in [false, true] {
            for fails in [false, true] {
                app.accessibilitySetValue(previous, forAttribute: enhancedUI)
                do {
                    try withAccessibilityTree {
                        #expect(app.accessibilityAttributeValue(enhancedUI) as? Bool == true)
                        if fails { throw Probe.failed }
                    }
                } catch Probe.failed {
                } catch {
                    Issue.record(error)
                }
                #expect(app.accessibilityAttributeValue(enhancedUI) as? Bool == previous,
                        "restore enhanced UI \(previous) after \(fails ? "failure" : "success")")
            }
        }
    }

    /// SwiftUI's virtual nodes expose accessibility methods without conforming to the
    /// full NSAccessibilityProtocol. Read their public ObjC methods or legacy attributes.
    private func value(_ attribute: NSAccessibility.Attribute, getter: String, of node: NSObject) -> Any? {
        let selector = NSSelectorFromString(getter)
        if node.responds(to: selector), let value = node.perform(selector)?.takeUnretainedValue() { return value }
        return node.accessibilityAttributeValue(attribute)
    }

    private func elements(_ root: NSObject) -> [NSObject] {
        var seen: Set<ObjectIdentifier> = []
        func walk(_ node: NSObject, depth: Int) -> [NSObject] {
            guard depth < 32, seen.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children = value(.children, getter: "accessibilityChildren", of: node) as? [NSObject] ?? []
            return [node] + children.flatMap { walk($0, depth: depth + 1) }
        }
        return walk(root, depth: 0)
    }

    @Test func theNewTaskTicketClearButtonNamesItsAction() throws { try check(.taskTicket) }
    @Test func theNewReviewTicketClearButtonNamesItsAction() throws { try check(.reviewTicket) }
    @Test func theMergeRequestClearButtonNamesItsAction() throws { try check(.mergeRequest) }
    @Test func thePullRequestClearButtonNamesItsAction() throws { try check(.pullRequest) }
    @Test func theBranchClearButtonNamesItsAction() throws { try check(.branch) }
    @Test func theLinkedProjectClearButtonNamesItsAction() throws { try check(.linkedProject) }
    @Test func thePickChipKeepsItsExistingLabel() throws { try check(.chip) }
}

struct NoPickerGit: GitRunning {
    func run(_ args: [String], in dir: String, timeout: TimeInterval, environment: [String: String]) throws -> String {
        throw GitError(args: args, code: 128, stderr: "No checkout in this picker fixture")
    }
}
