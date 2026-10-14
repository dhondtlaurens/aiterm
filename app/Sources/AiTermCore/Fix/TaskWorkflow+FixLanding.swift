import Foundation

extension TaskWorkflow {
    /// A checked fix brought into the project, on the queue creation, removal and pull use: it
    /// moves a branch, so nothing else of AiTerm's may interleave with it.
    public func landFix(from clone: FixClone, in project: Project) async throws(FixRefusal) -> FixLanding {
        let git = git
        return try await BackgroundWork.run(on: Self.queue) { () throws(FixRefusal) -> FixLanding in
            try Repository(project.path, git: git).landFix(from: clone)
        }
    }
}
