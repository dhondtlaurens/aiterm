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
        let model = ProjectSheetModel(preparation: prepared, editing: false, canChange: { true },
                                      inspect: { _ in prepared }, chooseFolder: { nil }, loadProjects: { [link] },
                                      commit: { _, links, _ in saved = links })
        await model.loadProjects()
        model.linked = [link]
        #expect(saved.isEmpty && model.canSave)
        #expect(await model.save())
        #expect(saved == [link])
    }

    @Test func anOldFolderInspectionCannotReplaceTheNewerOne() async {
        let first = ProjectPreparation(project: .make(path: "/projects/a"))
        let last = ProjectPreparation(project: .make(path: "/projects/b"))
        let entered = TestLatch(), release = TestLatch()
        let model = ProjectSheetModel(preparation: first, editing: false, canChange: { true },
                                      inspect: { path in
                                          if path == "/projects/slow" { entered.signal(); await release.wait(); return first }
                                          return last
                                      }, chooseFolder: { nil }, loadProjects: { [] }, commit: { _, _, _ in })
        model.folder = "/projects/slow"
        let old = Task { await model.inspectFolder() }
        await entered.wait()
        model.folder = "/projects/b"
        await model.inspectFolder()
        release.signal(); await old.value
        #expect(model.preparation.project.path == "/projects/b" && model.canSave)
    }

    @Test func aLockedWorkspaceOrFailedInspectionCannotSaveAPreviousFolder() async {
        let prepared = ProjectPreparation(project: .make(path: "/projects/a"))
        var saved = false
        let model = ProjectSheetModel(preparation: prepared, editing: false, canChange: { true },
                                      inspect: { _ in throw ActionUnavailable("Missing folder") }, chooseFolder: { nil }, loadProjects: { [] },
                                      commit: { _, _, _ in saved = true })
        model.folder = "/missing"
        #expect(!model.canSave)
        await model.inspectFolder()
        let result = await model.save()
        #expect(!model.canSave && !result && !saved)
        model.folder = prepared.project.path
        await model.inspectFolder()
        #expect(model.canSave)
        let locked = ProjectSheetModel(preparation: prepared, editing: true, canChange: { false }, inspect: { _ in prepared },
                                       chooseFolder: { nil }, loadProjects: { [] }, commit: { _, _, _ in saved = true })
        #expect(!(await locked.save()) && !saved)
    }

    @Test func aFailedSaveCanBeRetriedWithoutChangingTheFolder() async {
        let prepared = ProjectPreparation(project: .make(path: "/projects/a"))
        var failing = true
        let model = ProjectSheetModel(preparation: prepared, editing: false, canChange: { true }, inspect: { _ in prepared },
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
