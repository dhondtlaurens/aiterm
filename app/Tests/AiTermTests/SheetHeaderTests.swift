import AppKit
import SwiftUI
import AiTermUI
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

/// The sheet's header and height: the stepper in the title row, a single-step sheet as tall as its
/// content, and one height for every step of a stepped flow.
@MainActor
@Suite(.serialized) struct SheetHeaderTests {
    // -- the stepper -----------------------------------------------------------------------

    private let names = ["Task", "Agent", "Prompt"]

    /// On the first step only it is named; the rest are numbered, none ticked.
    @Test func onTheFirstStepTheRestAreNumbered() {
        #expect(SheetStepper.marks(step: 1, names: names) == [.current("Task"), .ahead(2), .ahead(3)])
    }

    /// In the middle the step behind is ticked, the current one named and the one ahead numbered.
    @Test func inTheMiddleTheStepBehindIsTicked() {
        #expect(SheetStepper.marks(step: 2, names: names) == [.done, .current("Agent"), .ahead(3)])
    }

    /// On the last step every earlier one is ticked.
    @Test func onTheLastStepEveryEarlierOneIsTicked() {
        #expect(SheetStepper.marks(step: 3, names: names) == [.done, .done, .current("Prompt")])
        let broadcast = NewBroadcastModel.stepNames
        #expect(SheetStepper.marks(step: 3, names: broadcast) == [.done, .done, .current(broadcast[2]), .ahead(4), .ahead(5)])
    }

    /// VoiceOver reads the stepper as one sentence: where you are, of how many, and the step's name.
    @Test func itReadsAsOneSentence() {
        #expect(SheetStepper.accessibilityLabel(step: 2, names: names) == "Step 2 of 3, Agent")
        #expect(SheetStepper.accessibilityLabel(step: 1, names: NewBroadcastModel.stepNames)
                == "Step 1 of 5, \(NewBroadcastModel.stepNames[0])")
    }

    /// Beside New Broadcast's title, all five steps keep their size: the title gives way, cut in its
    /// middle, rather than the stepper.
    @Test func theTitleGivesWayBeforeTheStepper() {
        let stepper = NSHostingView(rootView: SheetStepper(step: 1, names: NewBroadcastModel.stepNames))
        let long = String(repeating: "A long broadcast title ", count: 8)
        let width = Box()
        let sheet = SheetLayout(title: long, height: .fixed(Sheet.height)) {
            SheetStepper(step: 1, names: NewBroadcastModel.stepNames)
                .background(GeometryReader { proxy in Color.clear.onAppear { width.value = proxy.size.width } })
        } header: {
            EmptyView()
        } content: {
            EmptyView()
        } footer: {
            EmptyView()
        }
        let host = testHost(sheet, size: CGSize(width: Sheet.width, height: Sheet.height))
        settle(host) { width.value > 0 }
        #expect(width.value == stepper.fittingSize.width)
        #expect(stepper.fittingSize.width < Sheet.width / 2, "five steps leave the title most of the row")
    }

    private final class Box { var value: CGFloat = 0 }

    // -- heights ---------------------------------------------------------------------------

    /// The height a sheet takes, as its window would size it.
    private func height(of view: some View) -> CGFloat { NSHostingView(rootView: view).fittingSize.height }

    /// A sheet of one field is as tall as that field, its title and its footer: well short of
    /// `Sheet.height`, and taller by exactly the line its help adds.
    @Test func aSingleStepSheetFollowsItsContent() {
        let plain = NameSheet(title: "Rename task", subtitle: "The branch and worktree keep their names.", fieldLabel: "Task name",
                              placeholder: "Name", confirmLabel: "Rename", initialName: "Checkout", canSubmit: true, submit: { _ in })
        let helped = NameSheet(title: "Rename task", subtitle: "The branch and worktree keep their names.", fieldLabel: "Task name",
                               placeholder: "Name", help: "Leave it empty for a plain rule.", confirmLabel: "Rename",
                               initialName: "Checkout", canSubmit: true, submit: { _ in })
        let short = height(of: plain), tall = height(of: helped)
        #expect(short < Sheet.fittingHeight(Sheet.height) / 2)
        #expect(tall > short)
        #expect(NSHostingView(rootView: plain).fittingSize.width == Sheet.width)
    }

    /// Content taller than the most stops there: the sheet is `Sheet.height` and its content scrolls.
    @Test func aSingleStepSheetNeverPassesItsMost() throws {
        let sheet = SheetLayout(title: "Tall", height: .fitting(upTo: Sheet.height)) {
            SheetSubtitle("More than fits.")
        } content: {
            Color.clear.frame(height: 2 * Sheet.height)
        } footer: {
            EmptyView()
        }
        #expect(height(of: sheet) == Sheet.fittingHeight(Sheet.height))
        let host = testHost(sheet, size: CGSize(width: Sheet.width, height: Sheet.fittingHeight(Sheet.height)))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host) { (host.firstDescendant(NSScrollView.self)?.documentView?.frame.height ?? 0) > 0 }
        let scroll = try #require(host.firstDescendant(NSScrollView.self))
        #expect((scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height, "the content scrolls")
    }

    /// Every step of New Task and New Review is `Sheet.creationHeight`, so the sheet does not jump between
    /// them, and none of their ordinary steps — a ticket or branch picked, the agent, the prompt with its
    /// checkbox, the command and where it opens — is cut short: nothing in them scrolls.
    @Test(arguments: ["step1-closed.png", "step1-picked.png", "step1-worktreeinclude.png", "step1-gitlab-picked.png",
                      "step2-agent.png", "step3-prompt.png",
                      "review-step1.png", "review-ticket-found.png", "review-request-found-ticket.png", "review-ticket-none.png",
                      "review-in-task.png", "review-step1-worktreeinclude.png", "review-step2.png", "review-step3.png",
                      "review-step3-ticket.png"])
    func everyCreationStepIsOneHeightAndFits(file: String) throws {
        let snapshot = try #require(SheetSnapshots.all.first { $0.file == file })
        let view = snapshot.view()
        #expect(height(of: view) == Sheet.fittingHeight(Sheet.creationHeight))
        let host = testHost(view, size: CGSize(width: Sheet.width, height: Sheet.fittingHeight(Sheet.creationHeight)))
        let window = testWindow(hosting: host, styleMask: [])
        defer { window.orderOut(nil) }
        settle(host) { host.firstDescendant(NSScrollView.self)?.documentView != nil }
        let scroll = try #require(host.firstDescendant(NSScrollView.self))
        let document = try #require(scroll.documentView)
        #expect(document.frame.height <= scroll.contentView.bounds.height + 0.5,
                "\(file): \(document.frame.height) of content in \(scroll.contentView.bounds.height)")
    }

    /// New Broadcast keeps `Sheet.height` on every step.
    @Test func newBroadcastKeepsTheSheetHeight() {
        for step in 1...5 {
            let model = NewBroadcastModel(projects: [], context: NewBroadcastContext(slices: .none), skills: { _, _ in [] }) { _ in UUID() }
            let sheet = NewBroadcastSheet(model: model).seeded(step: step)
            #expect(height(of: sheet) == Sheet.fittingHeight(Sheet.height), "step \(step)")
        }
    }
}
