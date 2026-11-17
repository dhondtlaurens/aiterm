import Foundation
import Testing
@testable import AiTerm
@testable import AiTermCore
@testable import AiTermTestSupport

@Suite @MainActor struct ProjectSheetModelTests {
    @Test func preparationAndLinkSelectionPersistOnlyWhenSaved() async {
        let prepared = ProjectPreparation(project: .make(path: "/projects/a"))
        let link = JiraProjectRef(id: "1", key: "PAY", name: "Payments", siteURL: URL(string: "https://jira.example")!)
        var saved: [JiraProjectRef] = []
        let model = ProjectSheetModel(preparation: prepared, editing: false, git: .hermetic(), canChange: { true },
                                      inspect: { _ in prepared }, chooseFolder: { nil }, loadProjects: { [link] },
                                      commit: { _, links, _ in saved = links })
        await model.loadProjects()
        model.linked = [link]
        #expect(saved.isEmpty && model.canSave)
        #expect(await model.save())
        #expect(saved == [link])
    }

    @Test func aChosenFolderReplacesThePreparationAndItsImportChoice() async {
        let first = ProjectPreparation(project: .make(path: "/projects/a"))
        let last = ProjectPreparation(project: .make(path: "/projects/b"),
                                      worktrees: [Worktree(path: "/projects/b/.worktrees/task", branch: "feat/task", lockReason: nil)], defaultBranch: "main")
        let entered = TestLatch(), release = TestLatch()
        var inspected: [String] = []
        let model = ProjectSheetModel(preparation: first, editing: false, git: .hermetic(), canChange: { true },
                                      inspect: { path in
                                          inspected.append(path); entered.signal(); await release.wait(); return last
                                      }, chooseFolder: { URL(fileURLWithPath: "/projects/b") }, loadProjects: { [] }, commit: { _, _, _ in })
        model.importWorktrees = false
        let choice = Task { await model.chooseFolder() }
        await entered.wait()
        #expect(model.preparing && !model.canSave)
        release.signal(); await choice.value
        #expect(inspected == ["/projects/b"])
        #expect(model.preparation.project.path == "/projects/b" && model.importWorktrees)
        #expect(!model.preparing && model.canSave)
    }

    @Test func aCancelledPanelChangesNothing() async {
        let prepared = ProjectPreparation(project: .make(path: "/projects/a"))
        let model = ProjectSheetModel(preparation: prepared, editing: false, git: .hermetic(), canChange: { true },
                                      inspect: { _ in Issue.record("A cancelled panel must not inspect"); return prepared },
                                      chooseFolder: { nil }, loadProjects: { [] }, commit: { _, _, _ in })
        model.importWorktrees = true
        await model.chooseFolder()
        #expect(model.preparation.project.path == prepared.project.path && model.importWorktrees)
        #expect(model.error == nil && !model.preparing && model.canSave)
    }

    @Test func aFailedChoiceKeepsThePreviousFolderAndStaysSaveableALockedWorkspaceCannotSave() async {
        let prepared = ProjectPreparation(project: .make(path: "/projects/a"))
        var savedPath: String?
        let model = ProjectSheetModel(preparation: prepared, editing: false, git: .hermetic(), canChange: { true },
                                      inspect: { _ in throw ActionUnavailable("Missing folder") },
                                      chooseFolder: { URL(fileURLWithPath: "/missing") }, loadProjects: { [] },
                                      commit: { preparation, _, _ in savedPath = preparation.project.path })
        await model.chooseFolder()
        #expect(model.error == "Missing folder" && model.canSave && !model.preparing)
        #expect(model.preparation.project.path == prepared.project.path)
        #expect(await model.save())
        #expect(savedPath == prepared.project.path)
        savedPath = nil
        let locked = ProjectSheetModel(preparation: prepared, editing: true, git: .hermetic(), canChange: { false }, inspect: { _ in prepared },
                                       chooseFolder: { nil }, loadProjects: { [] }, commit: { preparation, _, _ in savedPath = preparation.project.path })
        #expect(!(await locked.save()) && savedPath == nil)
    }

    @Test func aFailedSaveCanBeRetriedWithoutChangingTheFolder() async {
        let prepared = ProjectPreparation(project: .make(path: "/projects/a"))
        var failing = true
        let model = ProjectSheetModel(preparation: prepared, editing: false, git: .hermetic(), canChange: { true }, inspect: { _ in prepared },
                                      chooseFolder: { nil }, loadProjects: { [] }, commit: { _, _, _ in
                                          if failing { throw ActionUnavailable("Save failed") }
                                      })
        #expect(!(await model.save()))
        failing = false
        #expect(await model.save())
    }
}

extension AppController {
    /// The Add button of the prepared sheet, without presenting a real window in controller tests.
    func savePreparedProject(importWorktrees: Bool? = nil, sourceLocation: SourceLocation = #_sourceLocation) async {
        guard case .project(let model)? = sheet, !model.editing else {
            Issue.record("Add Project did not prepare its sheet", sourceLocation: sourceLocation); return
        }
        if let importWorktrees { model.importWorktrees = importWorktrees }
        let saved = await model.save()
        #expect(saved, "Project save failed: \(model.error ?? "no reason")", sourceLocation: sourceLocation)
        if saved { sheet = nil }
    }
}
