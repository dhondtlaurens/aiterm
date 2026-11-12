import SwiftUI
import Testing
@testable import AiTermCore
@testable import AiTerm
@testable import AiTermTestSupport

@MainActor struct CreationLeafReadTests {
    @Test func taskStepOneBranchChoicesInvalidateTheirLeafOnly() {
        let model = TaskCreationModel(project: .make(),
                                      draft: TaskDraft(ticket: nil, baseBranch: "main", agent: .claude, model: "m", reasoning: nil),
                                      context: .scratch(git: NoPickerGit()), searchIssues: { _ in [] }, createTask: { _ in })
        let sheet = NewTaskSheet(model: model)
        let roots = invalidates({ _ = sheet.body }, by: { model.branches = ["main", "topic"] }) ? 1 : 0
        print("New Task root invalidations for branch choices: \(roots)")
        #expect(roots == 0, "baseline 1; final 0")
        let leaf = NewTaskFirstStep(model: model, ticketsOpen: .constant(false))
        #expect(invalidates({ _ = leaf.body }, by: { model.branches = ["main", "other"] }), "the leaf still reads the choices")
    }

    @Test func reviewStepOneBranchMatchesInvalidateTheirLeafOnly() {
        let model = ReviewCreationModel(project: .make(), draft: ReviewDraft(mr: nil, agent: .claude, model: "m", reasoning: nil),
                                        context: .scratch(git: NoPickerGit()), searchMergeRequests: { _ in [] },
                                        createReview: { _ in }, recover: { _ in })
        model.branches = ["main", "feat/cart"]
        let sheet = NewReviewSheet(model: model)
        let roots = invalidates({ _ = sheet.body }, by: { model.branchQuery = "feat" }) ? 1 : 0
        print("New Review root invalidations for branch matches: \(roots)")
        #expect(roots == 0, "baseline 1; final 0")
        let leaf = NewReviewFirstStep(model: model, mrOpen: .constant(false), branchOpen: .constant(false), ticketsOpen: .constant(false))
        #expect(invalidates({ _ = leaf.body }, by: { model.branchQuery = "cart" }), "the leaf still reads the matches")
    }
}
